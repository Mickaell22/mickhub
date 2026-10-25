import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'accounts.dart';
import 'accounts_ui.dart';
import 'clone_dialog.dart';
import 'git.dart';
import 'panes.dart';
import 'settings.dart';
import 'system.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = Settings();
  await settings.load();
  runApp(
    MaterialApp(
      title: 'MickHub',
      debugShowCheckedModeBanner: false,
      theme: ghTheme(),
      home: Shell(settings: settings),
    ),
  );
}

enum Foldout { none, repos, branches }

enum RepoTab { changes, history }

/// Ventana principal con la disposición de GitHub Desktop: barra de 50 px con
/// repositorio, rama y sincronización; abajo la columna lateral y el diff.
class Shell extends StatefulWidget {
  const Shell({super.key, required this.settings});
  final Settings settings;

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  Settings get s => widget.settings;

  List<String> _repos = [];
  final _remotes = <String, String>{}; // ruta -> remoteKey de origin
  final _origins = <String, String>{}; // ruta -> URL de origin
  final _sessions = <String, Session>{}; // id de cuenta -> estado de su sesión
  String? _repo;
  BranchState? _branch;
  Foldout _foldout = Foldout.none;
  RepoTab _tab = RepoTab.changes;
  int _tick = 0;
  bool _syncing = false;
  final _lastFetch = <String, DateTime>{};
  late final AppLifecycleListener _lifecycle;
  StreamSubscription<FileSystemEvent>? _settingsWatch;
  Timer? _reloadDebounce;

  @override
  void initState() {
    super.initState();
    // Como Desktop: al volver a la ventana se refresca el estado del repo.
    // Al volver a la ventana: refrescar el repo y revisar si alguna sesión venció.
    _lifecycle = AppLifecycleListener(
      onResume: () {
        _refresh();
        _checkSessions();
      },
    );
    _checkSessions();
    // Si alguien edita el JSON de ajustes desde fuera (Claude Code clonando o
    // agrupando repos), se recarga la lista sin reiniciar la app.
    _settingsWatch = s.watch(() {
      _reloadDebounce?.cancel();
      _reloadDebounce = Timer(const Duration(milliseconds: 300), () async {
        await s.load();
        if (mounted) await _loadRepos(reopen: false);
      });
    });
    _loadRepos();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _settingsWatch?.cancel();
    _reloadDebounce?.cancel();
    super.dispose();
  }

  Future<void> _loadRepos({bool reopen = true}) async {
    final repos = s.localRepos();
    setState(() => _repos = repos);
    final current = repos.contains(s.currentRepo) ? s.currentRepo : (repos.isEmpty ? null : repos.first);
    if (current != null && (reopen || current != _repo)) await _open(current);
    final urls = await Future.wait(repos.map(originUrl));
    for (var i = 0; i < repos.length; i++) {
      if (urls[i] != null) {
        _remotes[repos[i]] = remoteKey(urls[i]!);
        _origins[repos[i]] = urls[i]!;
      }
    }
  }

  Future<void> _open(String repo) async {
    setState(() {
      _repo = repo;
      _branch = null;
      _foldout = Foldout.none;
    });
    if (s.currentRepo != repo) await s.update((x) => x.currentRepo = repo);
    await _refresh();
  }

  Future<void> _refresh() async {
    final repo = _repo;
    if (repo == null || !Directory(repo).existsSync()) return;
    try {
      final b = await branchState(repo);
      if (mounted && repo == _repo) setState(() => _branch = b);
    } on GitException catch (e) {
      _snack(e.message);
    }
    if (mounted) setState(() => _tick++);
  }

  void _snack(String msg) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _clone() async {
    setState(() => _foldout = Foldout.none);
    final path = await showCloneDialog(context, s, _remotes.values.toSet());
    if (path == null) return;
    if (s.reposDir == null || !path.startsWith(s.reposDir!)) await s.update((x) => x.extraRepos = [...x.extraRepos, path]);
    await _loadRepos();
    await _open(path);
  }

  Future<void> _addLocal() async {
    setState(() => _foldout = Foldout.none);
    final ctrl = TextEditingController();
    final path = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: Gh.bg,
        title: const Text('Agregar repositorio local', style: TextStyle(fontSize: 14)),
        content: SizedBox(
          width: 420,
          child: TextField(
            controller: ctrl,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'Ruta de la carpeta del repositorio'),
            onSubmitted: (v) => Navigator.pop(c, v),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(c, ctrl.text), child: const Text('Agregar')),
        ],
      ),
    );
    ctrl.dispose();
    if (path == null || path.trim().isEmpty) return;
    try {
      final root = (await git(['rev-parse', '--show-toplevel'], cwd: path.trim())).trim();
      if (!s.extraRepos.contains(root)) await s.update((x) => x.extraRepos = [...x.extraRepos, root]);
      await _loadRepos();
      await _open(root);
    } catch (_) {
      _snack('Esa carpeta no es un repositorio de git.');
    }
  }

  Future<void> _sync() async {
    final repo = _repo, b = _branch;
    if (repo == null || b == null) return;
    setState(() => _syncing = true);
    try {
      if (b.upstream == null) {
        await git(['push', '-u', 'origin', 'HEAD'], cwd: repo);
      } else if (b.behind > 0) {
        await git([...?_account?.identityArgs, 'pull'], cwd: repo); // un pull puede crear un merge
      } else if (b.ahead > 0) {
        await git(['push'], cwd: repo);
      } else {
        await git(['fetch', '--prune'], cwd: repo);
        _lastFetch[repo] = DateTime.now();
      }
    } on GitException catch (e) {
      final locked = await protectedFiles(repo);
      final hit = locked.where((p) => e.message.contains(p.path)).map((p) => p.path).toList();
      final account = _account;
      if (hit.isNotEmpty) {
        await _protectedConflict(hit);
      } else if (isAuthError(e.message) && account != null && mounted) {
        // Típico de Azure: la sesión vence cada cierto tiempo. Login y reintento.
        if (await askLogin(context, account)) {
          _sessions[account.id] = const Session(SessionState.ok);
          if (mounted) setState(() => _syncing = false);
          return _sync();
        }
      } else {
        _snack(e.message);
      }
    } finally {
      if (mounted) setState(() => _syncing = false);
      await _refresh();
    }
  }

  /// Cuenta del repo abierto: la forzada a mano o la que calza con su remoto.
  Account? get _account => _repo == null ? null : accountFor(_origins[_repo], s.accounts, overrideId: s.repoAccounts[_repo]);

  Future<void> _checkSessions() async {
    final results = await Future.wait(s.accounts.map(checkSession));
    if (!mounted) return;
    setState(() {
      for (var i = 0; i < s.accounts.length && i < results.length; i++) {
        _sessions[s.accounts[i].id] = results[i];
      }
    });
  }

  bool get _sessionProblem => s.accounts.any((a) => _sessions[a.id] != null && _sessions[a.id]!.state != SessionState.ok);

  /// El remoto cambió un archivo que el usuario tiene protegido: git no puede
  /// traerlo sin pisar su versión local, así que se explica qué hacer.
  Future<void> _protectedConflict(List<String> paths) => showDialog(
    context: context,
    builder: (c) => AlertDialog(
      backgroundColor: Gh.bg,
      title: const Text('El remoto cambió archivos protegidos', style: TextStyle(fontSize: 14)),
      content: SizedBox(
        width: 460,
        child: Text(
          'No se pudo traer los cambios porque el remoto modificó archivos que tienes protegidos:\n\n'
          '${paths.map((p) => '  • $p').join('\n')}\n\n'
          'Para seguir: desprotégelos en la sección "Protegidos" de Cambios, guarda tu versión '
          '(cópiala o usa stash), vuelve a hacer pull y protégelos otra vez.',
        ),
      ),
      actions: [FilledButton(onPressed: () => Navigator.pop(c), child: const Text('Entendido'))],
    ),
  );

  Future<void> _switchBranch(String name) async {
    setState(() => _foldout = Foldout.none);
    try {
      await git(['switch', name], cwd: _repo);
    } on GitException catch (e) {
      _snack(e.message);
    }
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _toolbar(),
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(child: _body()),
                if (_foldout != Foldout.none) ...[
                  Positioned.fill(
                    child: GestureDetector(
                      onTap: () => setState(() => _foldout = Foldout.none),
                      child: Container(color: Colors.black38),
                    ),
                  ),
                  Positioned(
                    left: _foldout == Foldout.repos ? 0 : s.sidebarWidth,
                    top: 0,
                    bottom: 0,
                    width: 365,
                    child: Material(color: Gh.bg, elevation: 8, child: _foldout == Foldout.repos ? _repoList() : _branchList()),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _toolbar() {
    final b = _branch;
    final (syncTitle, syncLabel, syncIcon) = switch (b) {
      null => ('', 'Fetch origin', Icons.sync),
      BranchState(upstream: null) => ('Subir esta rama a GitHub', 'Publicar rama', Icons.cloud_upload_outlined),
      BranchState(behind: > 0) => ('${b.behind} commits para traer', 'Pull origin', Icons.arrow_downward),
      BranchState(ahead: > 0) => ('${b.ahead} commits para subir', 'Push origin', Icons.arrow_upward),
      _ => (
        _lastFetch[_repo] == null ? 'Sin fetch en esta sesión' : 'Último fetch ${timeAgo(_lastFetch[_repo]!)}',
        'Fetch origin',
        Icons.sync,
      ),
    };
    return Container(
      height: Gh.toolbarHeight,
      decoration: const BoxDecoration(
        color: Gh.box,
        border: Border(bottom: Gh.divider),
      ),
      child: Row(
        children: [
          ToolbarButton(
            width: s.sidebarWidth,
            icon: Icons.book_outlined,
            title: 'Repositorio actual',
            label: _repo == null ? 'Ninguno' : repoName(_repo!),
            open: _foldout == Foldout.repos,
            dropdown: true,
            onTap: () => setState(() => _foldout = _foldout == Foldout.repos ? Foldout.none : Foldout.repos),
          ),
          ToolbarButton(
            width: 230,
            icon: Icons.call_split,
            title: 'Rama actual',
            label: b?.name ?? '—',
            open: _foldout == Foldout.branches,
            dropdown: true,
            onTap: _repo == null ? null : () => setState(() => _foldout = _foldout == Foldout.branches ? Foldout.none : Foldout.branches),
          ),
          ToolbarButton(
            width: 230,
            icon: syncIcon,
            title: syncTitle,
            label: _syncing ? 'Sincronizando…' : syncLabel,
            spinning: _syncing,
            onTap: _repo == null || b == null || _syncing ? null : _sync,
          ),
          const Spacer(),
          IconButton(
            tooltip: _sessionProblem ? 'Cuentas: hay una sesión vencida' : 'Cuentas',
            iconSize: 18,
            onPressed: () => showAccountsDialog(context, s, _sessions, () => setState(() {})),
            icon: Badge(
              isLabelVisible: _sessionProblem,
              backgroundColor: Gh.deleted,
              smallSize: 8,
              child: const Icon(Icons.manage_accounts_outlined),
            ),
          ),
          if (_repo != null) ...[
            IconButton(
              tooltip: 'Abrir carpeta',
              iconSize: 18,
              onPressed: () => _openFolder(_repo!),
              icon: const Icon(Icons.folder_open_outlined),
            ),
            IconButton(tooltip: 'Abrir en el editor', iconSize: 18, onPressed: () => _openEditor(_repo!), icon: const Icon(Icons.code)),
            IconButton(tooltip: 'Papelera', iconSize: 18, onPressed: _showTrash, icon: const Icon(Icons.delete_outline)),
            const SizedBox(width: Gh.sp / 2),
          ],
        ],
      ),
    );
  }

  Future<void> _openFolder(String path) async {
    try {
      await openFolder(path);
    } catch (e) {
      _snack('No se pudo abrir la carpeta: $e');
    }
  }

  Future<void> _openEditor(String path) async {
    try {
      await openInEditor(s.editorCommand, path);
    } catch (_) {
      _snack('No se encontró el editor "${s.editorCommand}". ¿Está instalado y en el PATH?');
    }
  }

  Future<void> _repoMenu(String repo, Offset at) async {
    final group = s.groups[repo];
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: [
        menuItem('folder', Icons.folder_open_outlined, 'Abrir carpeta'),
        menuItem('editor', Icons.code, 'Abrir en el editor'),
        menuItem('copy', Icons.content_copy, 'Copiar ruta'),
        const PopupMenuDivider(),
        menuItem('group', Icons.drive_file_move_outlined, 'Mover a grupo…'),
        if (s.accounts.isNotEmpty) menuItem('account', Icons.badge_outlined, 'Cuenta de este repo…'),
        if (group != null) menuItem('ungroup', Icons.folder_off_outlined, 'Quitar del grupo "$group"'),
        if (s.extraRepos.contains(repo)) ...[
          const PopupMenuDivider(),
          menuItem('remove', Icons.playlist_remove, 'Quitar de la lista', danger: true),
        ],
      ],
    );
    switch (action) {
      case 'folder':
        await _openFolder(repo);
      case 'editor':
        await _openEditor(repo);
      case 'copy':
        await Clipboard.setData(ClipboardData(text: repo));
      case 'account':
        if (!mounted) return;
        final id = await pickAccount(context, s.accounts, s.repoAccounts[repo]);
        if (id != null) {
          await s.update((x) => x.repoAccounts = id.isEmpty ? ({...x.repoAccounts}..remove(repo)) : {...x.repoAccounts, repo: id});
          setState(() {});
        }
      case 'group':
        final name = await _askGroup(group);
        if (name != null) await s.update((x) => x.groups = {...x.groups, repo: name});
        setState(() {});
      case 'ungroup':
        await s.update((x) => x.groups = {...x.groups}..remove(repo));
        setState(() {});
      case 'remove':
        await s.update((x) => x.extraRepos = [...x.extraRepos]..remove(repo));
        await _loadRepos();
    }
  }

  /// Pide un grupo: uno existente con un clic, o crea uno nuevo.
  Future<String?> _askGroup(String? current) async {
    final existing = s.allGroups();
    final choice = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: Gh.bg,
        title: const Text('Mover a grupo', style: TextStyle(fontSize: 14)),
        content: SizedBox(
          width: 380,
          child: existing.isEmpty
              ? const Text('Todavía no hay grupos. Crea el primero.', style: TextStyle(color: Gh.textSecondary))
              : Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final g in existing)
                      ChoiceChip(
                        avatar: Icon(groupIcon(s.groupIcons[g]), size: 16),
                        label: Text(g),
                        selected: g == current,
                        onSelected: (_) => Navigator.pop(c, g),
                      ),
                  ],
                ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancelar')),
          FilledButton.icon(
            onPressed: () => Navigator.pop(c, '\u0000nuevo'),
            icon: const Icon(Icons.add, size: 16),
            label: const Text('Nuevo grupo…'),
          ),
        ],
      ),
    );
    if (choice != '\u0000nuevo') return choice;
    final created = await _editGroup();
    return created;
  }

  /// Crea un grupo, o edita [name] si se da: nombre, ícono y qué repos tiene.
  /// Devuelve el nombre final del grupo.
  Future<String?> _editGroup([String? name]) async {
    final ctrl = TextEditingController(text: name);
    var icon = s.groupIcons[name] ?? 'carpeta';
    var query = '';
    final members = {
      for (final e in s.groups.entries)
        if (e.value == name) e.key,
    };
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setD) => AlertDialog(
          backgroundColor: Gh.bg,
          title: Text(name == null ? 'Nuevo grupo' : 'Editar grupo', style: const TextStyle(fontSize: 14)),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: ctrl,
                  autofocus: true,
                  decoration: InputDecoration(hintText: 'Nombre (p. ej. Trabajo)', prefixIcon: Icon(groupIcon(icon), size: 18)),
                ),
                const SizedBox(height: Gh.sp),
                const Text('Ícono', style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: [
                    for (final e in groupIcons.entries)
                      IconButton(
                        tooltip: e.key,
                        isSelected: e.key == icon,
                        style: IconButton.styleFrom(
                          backgroundColor: e.key == icon ? Gh.blue : Gh.hover,
                          foregroundColor: e.key == icon ? Colors.white : Gh.text,
                        ),
                        iconSize: 18,
                        onPressed: () => setD(() => icon = e.key),
                        icon: Icon(e.value),
                      ),
                  ],
                ),
                const SizedBox(height: Gh.sp),
                Builder(
                  builder: (_) {
                    final shown = [
                      for (final r in _repos)
                        if ('${repoName(r)} ${s.groups[r] ?? ''}'.toLowerCase().contains(query.toLowerCase())) r,
                    ];
                    final allOn = shown.isNotEmpty && shown.every(members.contains);
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Text('Repositorios (${members.length})', style: const TextStyle(fontWeight: FontWeight.w600)),
                            const Spacer(),
                            TextButton(
                              onPressed: shown.isEmpty ? null : () => setD(() => allOn ? members.removeAll(shown) : members.addAll(shown)),
                              child: Text(allOn ? 'Desmarcar ${shown.length}' : 'Marcar ${shown.length}'),
                            ),
                          ],
                        ),
                        TextField(
                          style: const TextStyle(fontSize: Gh.fontSize),
                          decoration: const InputDecoration(hintText: 'Buscar repos', prefixIcon: Icon(Icons.search, size: 16)),
                          onChanged: (v) => setD(() => query = v),
                        ),
                        const SizedBox(height: 4),
                        SizedBox(
                          height: 220,
                          child: shown.isEmpty
                              ? const Center(
                                  child: Text('Ningún repo coincide.', style: TextStyle(color: Gh.textSecondary)),
                                )
                              : ListView(
                                  children: [
                                    for (final r in shown)
                                      CheckboxListTile(
                                        dense: true,
                                        visualDensity: VisualDensity.compact,
                                        controlAffinity: ListTileControlAffinity.leading,
                                        value: members.contains(r),
                                        title: Text(repoName(r)),
                                        subtitle: s.groups[r] != null && s.groups[r] != name ? Text('ahora en ${s.groups[r]}') : null,
                                        onChanged: (v) => setD(() => v! ? members.add(r) : members.remove(r)),
                                      ),
                                  ],
                                ),
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(name == null ? 'Crear' : 'Guardar')),
          ],
        ),
      ),
    );
    final newName = ctrl.text.trim();
    ctrl.dispose();
    if (ok != true || newName.isEmpty) return null;
    await s.update((x) {
      x.groupIcons = {...x.groupIcons}..remove(name);
      x.groupIcons[newName] = icon;
      x.groups = {
        for (final e in x.groups.entries)
          if (e.value != name && !members.contains(e.key)) e.key: e.value,
        for (final r in members) r: newName,
      };
    });
    setState(() {});
    return newName;
  }

  /// Menú "Agregar" del panel de repos. Se abre con el context del Shell y no
  /// con un PopupMenuButton dentro del panel: el panel se cierra al elegir una
  /// opción y, si el menú dependiera de él, Flutter falla en plena animación de
  /// salida ('_dependents.isEmpty').
  Future<void> _addMenu(BuildContext button) async {
    final box = button.findRenderObject()! as RenderBox;
    final at = box.localToGlobal(Offset(0, box.size.height));
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: [
        menuItem('clone', Icons.download, 'Clonar repositorio…'),
        menuItem('local', Icons.create_new_folder_outlined, 'Agregar repositorio local…'),
        const PopupMenuDivider(),
        menuItem('group', Icons.workspaces_outline, 'Nuevo grupo…'),
      ],
    );
    switch (action) {
      case 'clone':
        await _clone();
      case 'local':
        await _addLocal();
      case 'group':
        setState(() => _foldout = Foldout.none);
        await _editGroup();
    }
  }

  Future<void> _groupMenu(String group, Offset at) async {
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: [
        menuItem('edit', Icons.edit_outlined, 'Editar grupo (nombre, ícono, repos)…'),
        const PopupMenuDivider(),
        menuItem('delete', Icons.delete_outline, 'Eliminar grupo', danger: true),
      ],
    );
    if (action == 'edit') await _editGroup(group);
    if (action == 'delete') {
      // Los repos no se tocan: solo pasan a "Sin grupo".
      await s.update((x) {
        x.groupIcons = {...x.groupIcons}..remove(group);
        x.groups = {...x.groups}..removeWhere((_, g) => g == group);
      });
      setState(() {});
    }
  }

  Future<void> _newBranch() async {
    setState(() => _foldout = Foldout.none);
    final repo = _repo!;
    final bases = await branchBases(repo);
    final changes = await status(repo);
    if (!mounted) return;
    final ctrl = TextEditingController();
    var base = _branch?.name ?? bases.first;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setD) => AlertDialog(
          backgroundColor: Gh.bg,
          title: const Text('Nueva rama local', style: TextStyle(fontSize: 14)),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: ctrl,
                  autofocus: true,
                  decoration: const InputDecoration(hintText: 'Nombre (p. ej. fix-login)'),
                  onSubmitted: (_) => Navigator.pop(c, true),
                ),
                const SizedBox(height: Gh.sp),
                Row(
                  children: [
                    const Text('Basada en  '),
                    Expanded(
                      child: DropdownButton<String>(
                        value: bases.contains(base) ? base : null,
                        isExpanded: true,
                        isDense: true,
                        items: [
                          for (final b in bases)
                            DropdownMenuItem(
                              value: b,
                              child: Text(b, overflow: TextOverflow.ellipsis),
                            ),
                        ],
                        onChanged: (v) => setD(() => base = v!),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: Gh.sp),
                Text(
                  changes.isEmpty
                      ? 'Solo existe en tu máquina hasta que la publiques.'
                      : 'Los ${changes.length} archivos con cambios sin commitear viajan a la rama nueva. '
                            'Si alguno no debe ir (una implementación a medias), apártalo antes desde Cambios.',
                  style: const TextStyle(color: Gh.textSecondary),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Crear y cambiar')),
          ],
        ),
      ),
    );
    final name = ctrl.text.trim();
    ctrl.dispose();
    if (ok != true || name.isEmpty) return;
    try {
      await createBranch(repo, name, base);
    } on GitException catch (e) {
      _snack(e.message);
    }
    await _refresh();
  }

  Future<void> _showTrash() async {
    final trash = s.trash;
    await showDialog<void>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setD) {
          final entries = trash.list(repo: _repo);
          Future<void> act(Future<void> Function() f) async {
            try {
              await f();
            } catch (e) {
              _snack('$e');
            }
            setD(() {});
            await _refresh();
          }

          return AlertDialog(
            backgroundColor: Gh.bg,
            title: Row(
              children: [
                const Icon(Icons.delete_outline, size: 18),
                const SizedBox(width: 8),
                Text('Papelera de ${repoName(_repo!)}', style: const TextStyle(fontSize: 14)),
              ],
            ),
            content: SizedBox(
              width: 520,
              height: 360,
              child: entries.isEmpty
                  ? const Center(
                      child: Text('Vacía. Lo que descartes en Cambios aparece aquí.', style: TextStyle(color: Gh.textSecondary)),
                    )
                  : ListView(
                      children: [
                        for (final e in entries)
                          GhRow(
                            height: 40,
                            child: Row(
                              children: [
                                const Icon(Icons.insert_drive_file_outlined, size: 16, color: Gh.textSecondary),
                                const SizedBox(width: Gh.sp),
                                Expanded(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(e.path, overflow: TextOverflow.ellipsis),
                                      Text(
                                        'Descartado ${timeAgo(e.deletedAt)}',
                                        style: const TextStyle(fontSize: Gh.fontSizeSm, color: Gh.textSecondary),
                                      ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'Restaurar',
                                  iconSize: 16,
                                  onPressed: () => act(() => trash.restore(e)),
                                  icon: const Icon(Icons.restore),
                                ),
                                IconButton(
                                  tooltip: 'Borrar definitivamente',
                                  iconSize: 16,
                                  color: Gh.deleted,
                                  onPressed: () => act(() => trash.delete(e)),
                                  icon: const Icon(Icons.delete_forever_outlined),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
            ),
            actions: [
              if (entries.isNotEmpty)
                TextButton(
                  onPressed: () => act(() async {
                    for (final e in entries) {
                      await trash.delete(e);
                    }
                  }),
                  child: const Text('Vaciar'),
                ),
              FilledButton(onPressed: () => Navigator.pop(c), child: const Text('Cerrar')),
            ],
          );
        },
      ),
    );
  }

  Widget _body() {
    final repo = _repo;
    if (repo == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('No hay ningún repositorio abierto', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
            const SizedBox(height: Gh.sp * 2),
            FilledButton.icon(onPressed: _clone, icon: const Icon(Icons.download, size: 16), label: const Text('Clonar un repositorio')),
            const SizedBox(height: Gh.sp),
            TextButton(onPressed: _addLocal, child: const Text('Agregar un repositorio local')),
          ],
        ),
      );
    }
    Widget layout(Widget sidebar, Widget main) => SplitLayout(
      width: s.sidebarWidth,
      onResize: (dx) => setState(() => s.sidebarWidth = (s.sidebarWidth + dx).clamp(220.0, MediaQuery.sizeOf(context).width - 400)),
      onResizeEnd: () => s.update((_) {}),
      sidebar: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _tabBar(),
          Expanded(child: sidebar),
        ],
      ),
      main: main,
    );
    return _tab == RepoTab.changes
        ? ChangesPane(
            key: ValueKey(repo),
            repo: repo,
            branch: _branch?.name ?? '',
            tick: _tick,
            layout: layout,
            onCommitted: _refresh,
            onOpenFolder: _openFolder,
            onOpenEditor: () => _openEditor(repo),
            trash: s.trash,
            account: _account,
          )
        : HistoryPane(key: ValueKey(repo), repo: repo, ahead: _branch?.ahead ?? 0, tick: _tick, layout: layout);
  }

  Widget _tabBar() {
    Widget tab(RepoTab t, String label) => Expanded(
      child: InkWell(
        onTap: () => setState(() => _tab = t),
        hoverColor: Gh.hover,
        child: Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border(
              right: t == RepoTab.changes ? Gh.divider : BorderSide.none,
              bottom: _tab == t ? const BorderSide(color: Gh.blue, width: 3) : Gh.divider,
            ),
          ),
          child: Text(label, style: TextStyle(fontWeight: _tab == t ? FontWeight.w600 : FontWeight.normal)),
        ),
      ),
    );
    return SizedBox(
      height: Gh.tabBarHeight,
      child: Row(children: [tab(RepoTab.changes, 'Cambios'), tab(RepoTab.history, 'Historial')]),
    );
  }

  Widget _repoList() => _FilterList(
    items: _repos,
    label: repoName,
    icon: Icons.book_outlined,
    selected: _repo,
    header: 'Repositorios locales',
    group: (r) => s.groups[r],
    allGroups: s.allGroups(),
    groupIcon: (g) => groupIcon(s.groupIcons[g]),
    onGroupSecondary: _groupMenu,
    onSecondary: _repoMenu,
    hint: 'Filtrar',
    emptyText: s.reposDir == null ? 'No hay repositorios. Clona uno o agrega uno local.' : 'No hay repositorios en ${s.reposDir}.',
    action: Builder(
      builder: (button) => InkWell(
        borderRadius: BorderRadius.circular(Gh.radius),
        onTap: () => _addMenu(button),
        child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: Gh.sp),
          decoration: BoxDecoration(color: Gh.hover, borderRadius: BorderRadius.circular(Gh.radius)),
          child: const Row(children: [Text('Agregar'), Icon(Icons.arrow_drop_down, size: 18)]),
        ),
      ),
    ),
    onTap: _open,
  );

  Widget _branchList() => FutureBuilder<List<String>>(
    future: localBranches(_repo!),
    builder: (_, snap) => _FilterList(
      items: snap.data ?? const [],
      label: (b) => b,
      icon: Icons.call_split,
      selected: _branch?.name,
      header: 'Ramas locales',
      hint: 'Filtrar ramas',
      emptyText: snap.hasData ? 'No hay ramas.' : 'Cargando…',
      action: OutlinedButton.icon(onPressed: _newBranch, icon: const Icon(Icons.add, size: 16), label: const Text('Nueva rama')),
      onTap: (b) => b == _branch?.name ? setState(() => _foldout = Foldout.none) : _switchBranch(b),
    ),
  );
}

/// Botón de la barra: ícono, título chico gris arriba y etiqueta en negrita,
/// con borde negro a la derecha (`.toolbar-button` de Desktop).
class ToolbarButton extends StatelessWidget {
  const ToolbarButton({
    super.key,
    required this.width,
    required this.icon,
    required this.title,
    required this.label,
    this.onTap,
    this.open = false,
    this.dropdown = false,
    this.spinning = false,
  });
  final double width;
  final IconData icon;
  final String title, label;
  final VoidCallback? onTap;
  final bool open, dropdown, spinning;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final fg = enabled ? Gh.text : Gh.textSecondary;
    return SizedBox(
      width: width,
      child: Material(
        color: open ? Gh.bg : Colors.transparent,
        child: InkWell(
          onTap: onTap,
          hoverColor: Gh.hover,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: Gh.sp),
            decoration: const BoxDecoration(
              border: Border(right: BorderSide(color: Colors.black)),
            ),
            child: Row(
              children: [
                spinning
                    ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : Icon(icon, size: 16, color: fg),
                const SizedBox(width: Gh.sp),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (title.isNotEmpty)
                        Text(
                          title,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: Gh.fontSizeSm, color: Gh.textSecondary),
                        ),
                      Text(
                        label,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontWeight: FontWeight.w600, color: fg),
                      ),
                    ],
                  ),
                ),
                if (dropdown) Icon(open ? Icons.arrow_drop_up : Icons.arrow_drop_down, size: 18, color: fg),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Lista filtrable de los desplegables (repos, ramas), como `.filter-list`.
/// Si se da [group], los elementos se agrupan con su encabezado y aparece un
/// selector para filtrar por grupo; el texto también busca en el nombre del grupo.
class _FilterList extends StatefulWidget {
  const _FilterList({
    required this.items,
    required this.label,
    required this.icon,
    required this.selected,
    required this.header,
    required this.hint,
    required this.emptyText,
    required this.onTap,
    this.action,
    this.group,
    this.allGroups = const [],
    this.groupIcon,
    this.onGroupSecondary,
    this.onSecondary,
  });
  final List<String> items;
  final String Function(String) label;
  final IconData icon;
  final String? selected;
  final String header, hint, emptyText;
  final ValueChanged<String> onTap;
  final Widget? action;
  final String? Function(String)? group;
  final List<String> allGroups;
  final IconData Function(String group)? groupIcon;
  final void Function(String group, Offset at)? onGroupSecondary;
  final void Function(String item, Offset at)? onSecondary;

  @override
  State<_FilterList> createState() => _FilterListState();
}

class _FilterListState extends State<_FilterList> {
  String _q = '';
  String? _group;

  @override
  Widget build(BuildContext context) {
    final groupOf = widget.group ?? (_) => null;
    final q = _q.toLowerCase();
    final shown = widget.items.where((i) {
      if (_group != null && groupOf(i) != _group) return false;
      return '${widget.label(i)} ${groupOf(i) ?? ''}'.toLowerCase().contains(q);
    }).toList();
    final groups = {...widget.allGroups, for (final i in widget.items) ?groupOf(i)}.toList()..sort();

    // Encabezados de grupo (los con nombre primero, alfabéticos) y sus elementos.
    final rows = <Object>[]; // String = elemento, (String,) = encabezado
    final byGroup = <String, List<String>>{};
    for (final i in shown) {
      (byGroup[groupOf(i) ?? ''] ??= []).add(i);
    }
    final keys = byGroup.keys.toList()..sort((a, b) => a.isEmpty ? 1 : (b.isEmpty ? -1 : a.compareTo(b)));
    for (final k in keys) {
      rows.add((k.isEmpty ? (groups.isEmpty ? widget.header : 'Sin grupo') : k,));
      rows.addAll(byGroup[k]!);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(Gh.sp),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  autofocus: true,
                  style: const TextStyle(fontSize: Gh.fontSize),
                  decoration: InputDecoration(hintText: widget.hint, prefixIcon: const Icon(Icons.search, size: 16)),
                  onChanged: (v) => setState(() => _q = v),
                  onSubmitted: (_) => shown.isEmpty ? null : widget.onTap(shown.first),
                ),
              ),
              if (widget.action != null) ...[const SizedBox(width: Gh.sp), widget.action!],
            ],
          ),
        ),
        if (groups.isNotEmpty)
          SizedBox(
            height: 30,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: Gh.sp),
              children: [
                for (final g in [null, ...groups])
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      avatar: g == null || widget.groupIcon == null ? null : Icon(widget.groupIcon!(g), size: 14),
                      label: Text(g ?? 'Todos', style: const TextStyle(fontSize: Gh.fontSizeSm)),
                      selected: _group == g,
                      visualDensity: VisualDensity.compact,
                      onSelected: (_) => setState(() => _group = g),
                    ),
                  ),
              ],
            ),
          ),
        Expanded(
          child: shown.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(Gh.sp),
                  child: Text(widget.emptyText, style: const TextStyle(color: Gh.textSecondary)),
                )
              : ListView.builder(
                  itemCount: rows.length,
                  itemExtent: Gh.rowHeight,
                  itemBuilder: (_, i) {
                    final r = rows[i];
                    if (r is (String,)) {
                      final named = groups.contains(r.$1);
                      return GestureDetector(
                        onSecondaryTapUp: named && widget.onGroupSecondary != null
                            ? (d) => widget.onGroupSecondary!(r.$1, d.globalPosition)
                            : null,
                        child: Container(
                          alignment: Alignment.bottomLeft,
                          padding: const EdgeInsets.fromLTRB(Gh.sp, 0, Gh.sp, 4),
                          child: Row(
                            children: [
                              if (named && widget.groupIcon != null) ...[
                                Icon(widget.groupIcon!(r.$1), size: 14, color: Gh.link),
                                const SizedBox(width: 6),
                              ],
                              Text(r.$1, style: const TextStyle(fontWeight: FontWeight.w600)),
                            ],
                          ),
                        ),
                      );
                    }
                    final item = r as String;
                    return GhRow(
                      selected: item == widget.selected,
                      onTap: () => widget.onTap(item),
                      onSecondary: widget.onSecondary == null ? null : (at) => widget.onSecondary!(item, at),
                      child: Row(
                        children: [
                          Icon(widget.icon, size: 14, color: Gh.textSecondary),
                          const SizedBox(width: Gh.sp),
                          Expanded(child: Text(widget.label(item), overflow: TextOverflow.ellipsis)),
                          if (item == widget.selected) const Icon(Icons.check, size: 14),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
