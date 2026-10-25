import 'dart:io';

import 'package:flutter/material.dart';

import 'clone_dialog.dart';
import 'git.dart';
import 'panes.dart';
import 'settings.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = Settings();
  await settings.load();
  runApp(MaterialApp(title: 'MickHub', debugShowCheckedModeBanner: false, theme: ghTheme(), home: Shell(settings: settings)));
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
  String? _repo;
  BranchState? _branch;
  Foldout _foldout = Foldout.none;
  RepoTab _tab = RepoTab.changes;
  int _tick = 0;
  bool _syncing = false;
  final _lastFetch = <String, DateTime>{};
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    // Como Desktop: al volver a la ventana se refresca el estado del repo.
    _lifecycle = AppLifecycleListener(onResume: _refresh);
    _loadRepos();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _loadRepos() async {
    final repos = s.localRepos();
    setState(() => _repos = repos);
    final current = repos.contains(s.currentRepo) ? s.currentRepo : (repos.isEmpty ? null : repos.first);
    if (current != null) await _open(current);
    for (final r in repos) {
      final url = await originUrl(r);
      if (url != null) _remotes[r] = remoteKey(url);
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
        await git(['pull'], cwd: repo);
      } else if (b.ahead > 0) {
        await git(['push'], cwd: repo);
      } else {
        await git(['fetch', '--prune'], cwd: repo);
        _lastFetch[repo] = DateTime.now();
      }
    } on GitException catch (e) {
      _snack(e.message);
    } finally {
      if (mounted) setState(() => _syncing = false);
      await _refresh();
    }
  }

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
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _toolbar(),
        Expanded(
          child: Stack(children: [
            Positioned.fill(child: _body()),
            if (_foldout != Foldout.none) ...[
              Positioned.fill(child: GestureDetector(onTap: () => setState(() => _foldout = Foldout.none), child: Container(color: Colors.black38))),
              Positioned(
                left: _foldout == Foldout.repos ? 0 : s.sidebarWidth,
                top: 0,
                bottom: 0,
                width: 365,
                child: Material(
                  color: Gh.bg,
                  elevation: 8,
                  child: _foldout == Foldout.repos ? _repoList() : _branchList(),
                ),
              ),
            ],
          ]),
        ),
      ]),
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
          Icons.sync
        ),
    };
    return Container(
      height: Gh.toolbarHeight,
      decoration: const BoxDecoration(color: Gh.box, border: Border(bottom: Gh.divider)),
      child: Row(children: [
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
      ]),
    );
  }

  Widget _body() {
    final repo = _repo;
    if (repo == null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('No hay ningún repositorio abierto', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
          const SizedBox(height: Gh.sp * 2),
          FilledButton.icon(onPressed: _clone, icon: const Icon(Icons.download, size: 16), label: const Text('Clonar un repositorio')),
          const SizedBox(height: Gh.sp),
          TextButton(onPressed: _addLocal, child: const Text('Agregar un repositorio local')),
        ]),
      );
    }
    Widget layout(Widget sidebar, Widget main) => SplitLayout(
          width: s.sidebarWidth,
          onResize: (dx) => setState(() => s.sidebarWidth = (s.sidebarWidth + dx).clamp(220.0, MediaQuery.sizeOf(context).width - 400)),
          onResizeEnd: () => s.update((_) {}),
          sidebar: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [_tabBar(), Expanded(child: sidebar)]),
          main: main,
        );
    return _tab == RepoTab.changes
        ? ChangesPane(key: ValueKey(repo), repo: repo, branch: _branch?.name ?? '', tick: _tick, layout: layout, onCommitted: _refresh)
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
    return SizedBox(height: Gh.tabBarHeight, child: Row(children: [tab(RepoTab.changes, 'Cambios'), tab(RepoTab.history, 'Historial')]));
  }

  Widget _repoList() => _FilterList(
        items: _repos,
        label: repoName,
        icon: Icons.book_outlined,
        selected: _repo,
        header: 'Repositorios locales',
        hint: 'Filtrar',
        emptyText: s.reposDir == null
            ? 'No hay repositorios. Clona uno o agrega uno local.'
            : 'No hay repositorios en ${s.reposDir}.',
        action: PopupMenuButton<VoidCallback>(
          tooltip: 'Agregar',
          onSelected: (f) => f(),
          itemBuilder: (_) => [
            PopupMenuItem(value: _clone, child: const Text('Clonar repositorio…')),
            PopupMenuItem(value: _addLocal, child: const Text('Agregar repositorio local…')),
          ],
          child: Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: Gh.sp),
            decoration: BoxDecoration(color: Gh.hover, borderRadius: BorderRadius.circular(Gh.radius)),
            child: const Row(children: [Text('Agregar'), Icon(Icons.arrow_drop_down, size: 18)]),
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
            decoration: const BoxDecoration(border: Border(right: BorderSide(color: Colors.black))),
            child: Row(children: [
              spinning
                  ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : Icon(icon, size: 16, color: fg),
              const SizedBox(width: Gh.sp),
              Expanded(
                child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (title.isNotEmpty)
                    Text(title, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: Gh.fontSizeSm, color: Gh.textSecondary)),
                  Text(label, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w600, color: fg)),
                ]),
              ),
              if (dropdown) Icon(open ? Icons.arrow_drop_up : Icons.arrow_drop_down, size: 18, color: fg),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Lista filtrable de los desplegables (repos, ramas), como `.filter-list`.
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
  });
  final List<String> items;
  final String Function(String) label;
  final IconData icon;
  final String? selected;
  final String header, hint, emptyText;
  final ValueChanged<String> onTap;
  final Widget? action;

  @override
  State<_FilterList> createState() => _FilterListState();
}

class _FilterListState extends State<_FilterList> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final shown = widget.items.where((i) => widget.label(i).toLowerCase().contains(_q.toLowerCase())).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.all(Gh.sp),
        child: Row(children: [
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
        ]),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gh.sp, vertical: 4),
        child: Text(widget.header, style: const TextStyle(fontWeight: FontWeight.w600)),
      ),
      Expanded(
        child: shown.isEmpty
            ? Padding(padding: const EdgeInsets.all(Gh.sp), child: Text(widget.emptyText, style: const TextStyle(color: Gh.textSecondary)))
            : ListView.builder(
                itemCount: shown.length,
                itemExtent: Gh.rowHeight,
                itemBuilder: (_, i) => GhRow(
                  selected: shown[i] == widget.selected,
                  onTap: () => widget.onTap(shown[i]),
                  child: Row(children: [
                    Icon(widget.icon, size: 14, color: Gh.textSecondary),
                    const SizedBox(width: Gh.sp),
                    Expanded(child: Text(widget.label(shown[i]), overflow: TextOverflow.ellipsis)),
                    if (shown[i] == widget.selected) const Icon(Icons.check, size: 14),
                  ]),
                ),
              ),
      ),
    ]);
  }
}
