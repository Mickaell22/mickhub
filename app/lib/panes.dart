import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'accounts.dart';
import 'avatar.dart';
import 'system.dart';
import 'diff_view.dart';
import 'git.dart';
import 'theme.dart';
import 'trash.dart';

/// Columna lateral (tabs + contenido) a la izquierda y vista principal a la
/// derecha, con el borde arrastrable entre ambas, como `#repository` en Desktop.
class SplitLayout extends StatelessWidget {
  const SplitLayout({
    super.key,
    required this.width,
    required this.onResize,
    required this.onResizeEnd,
    required this.sidebar,
    required this.main,
  });
  final double width;
  final ValueChanged<double> onResize;
  final VoidCallback onResizeEnd;
  final Widget sidebar, main;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SizedBox(width: width, child: sidebar),
      MouseRegion(
        cursor: SystemMouseCursors.resizeLeftRight,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: (d) => onResize(d.delta.dx),
          onHorizontalDragEnd: (_) => onResizeEnd(),
          child: const SizedBox(width: 5, child: VerticalDivider(width: 1, thickness: 1, color: Gh.border)),
        ),
      ),
      Expanded(child: main),
    ],
  );
}

/// Fila de lista de 29 px con hover y selección.
class GhRow extends StatefulWidget {
  const GhRow({super.key, required this.child, this.selected = false, this.onTap, this.onSecondary, this.height = Gh.rowHeight});
  final Widget child;
  final bool selected;
  final VoidCallback? onTap;
  final ValueChanged<Offset>? onSecondary;
  final double height;

  @override
  State<GhRow> createState() => _GhRowState();
}

class _GhRowState extends State<GhRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _hover = true),
    onExit: (_) => setState(() => _hover = false),
    child: GestureDetector(
      onTap: widget.onTap,
      onSecondaryTapUp: widget.onSecondary == null ? null : (d) => widget.onSecondary!(d.globalPosition),
      child: Container(
        height: widget.height,
        padding: const EdgeInsets.symmetric(horizontal: Gh.sp),
        decoration: BoxDecoration(
          color: widget.selected ? Gh.selected : (_hover ? Gh.hover : null),
          border: const Border(bottom: Gh.divider),
        ),
        child: widget.child,
      ),
    ),
  );
}

Widget emptyState(String title, [String? detail, List<Widget> actions = const []]) => Center(
  child: Padding(
    padding: const EdgeInsets.all(Gh.sp * 3),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
        if (detail != null) ...[
          const SizedBox(height: Gh.sp),
          Text(
            detail,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Gh.textSecondary),
          ),
        ],
        if (actions.isNotEmpty) ...[
          const SizedBox(height: Gh.sp * 2),
          Wrap(spacing: Gh.sp, runSpacing: Gh.sp, alignment: WrapAlignment.center, children: actions),
        ],
      ],
    ),
  ),
);

/// Barra fina sobre el diff con la ruta del archivo.
Widget fileHeader(FileChange f) => Container(
  height: Gh.tabBarHeight,
  padding: const EdgeInsets.symmetric(horizontal: Gh.sp),
  decoration: const BoxDecoration(
    color: Gh.boxAlt,
    border: Border(bottom: Gh.divider),
  ),
  child: Row(
    children: [
      Expanded(child: Text(f.oldPath == null ? f.path : '${f.oldPath} → ${f.path}', overflow: TextOverflow.ellipsis)),
      statusIcon(f.status),
    ],
  ),
);

/// Tab "Cambios": archivos modificados con casillas, caja de commit y diff.
class ChangesPane extends StatefulWidget {
  const ChangesPane({
    super.key,
    required this.repo,
    required this.branch,
    required this.tick,
    required this.layout,
    required this.onCommitted,
    required this.onOpenFolder,
    required this.onOpenEditor,
    required this.trash,
    required this.editorCommand,
    this.account,
  });
  final String repo;
  final String branch;
  final int tick;
  final Widget Function(Widget sidebar, Widget main) layout;
  final VoidCallback onCommitted;
  final ValueChanged<String> onOpenFolder;
  final VoidCallback onOpenEditor;
  final Trash trash;
  final String editorCommand;

  /// Cuenta del repo: si tiene nombre y email, los commits se firman con ellos.
  final Account? account;

  @override
  State<ChangesPane> createState() => _ChangesPaneState();
}

class _ChangesPaneState extends State<ChangesPane> {
  List<FileChange> _files = [];
  List<Protected> _protected = [];
  List<Shelf> _shelves = [];
  MergeState _merge = MergeState.none;
  final _hunks = <int>{}; // bloques marcados para apartar en el archivo elegido
  String? _gitIdentity; // la de git (repo o global), si el repo no tiene cuenta
  bool _showShelves = true;
  bool _showProtected = true;
  final _excluded = <String>{};
  String? _selected;
  String? _diff;
  final _summary = TextEditingController();
  final _description = TextEditingController();
  bool _committing = false;

  @override
  void initState() {
    super.initState();
    _summary.addListener(() => setState(() {}));
    _load();
  }

  @override
  void didUpdateWidget(ChangesPane old) {
    super.didUpdateWidget(old);
    if (old.tick != widget.tick) _load();
  }

  @override
  void dispose() {
    _summary.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final files = await status(widget.repo);
    final locked = await protectedFiles(widget.repo);
    final shelved = await shelves(widget.repo);
    final identity = await gitIdentity(widget.repo);
    final merge = await mergeState(widget.repo);
    if (!mounted) return;
    setState(() {
      _merge = merge;
      _files = files;
      _protected = locked;
      _shelves = shelved;
      _gitIdentity = identity;
      _excluded.retainAll(files.map((f) => f.path));
      if (!files.any((f) => f.path == _selected)) {
        _selected = files.isEmpty ? null : files.first.path;
      }
    });
    _loadDiff();
  }

  Future<void> _loadDiff() async {
    final f = _files.where((f) => f.path == _selected).firstOrNull;
    if (f == null) return setState(() => _diff = null);
    try {
      final d = await fileDiff(widget.repo, f);
      if (mounted && _selected == f.path) setState(() => _diff = d);
    } on GitException catch (e) {
      if (mounted) setState(() => _diff = null);
      debugPrint(e.toString());
    }
  }

  void _snack(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  /// Barra sobre el diff para apartar solo algunos bloques del archivo.
  Widget _hunkBar(FileChange f, String diff) => Container(
    height: Gh.rowHeight + 6,
    padding: const EdgeInsets.symmetric(horizontal: Gh.sp),
    decoration: const BoxDecoration(
      color: Gh.box,
      border: Border(bottom: Gh.divider),
    ),
    child: Row(
      children: [
        const Icon(Icons.inventory_2_outlined, size: 14, color: Gh.textSecondary),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            _hunks.isEmpty
                ? 'Marca bloques para apartar solo esa parte del archivo'
                : '${_hunks.length} ${_hunks.length == 1 ? 'bloque marcado' : 'bloques marcados'}',
            style: const TextStyle(color: Gh.textSecondary),
          ),
        ),
        if (_hunks.isNotEmpty)
          TextButton.icon(
            onPressed: () => _shelveHunks(f, diff),
            icon: const Icon(Icons.inventory_2_outlined, size: 14),
            label: const Text('Apartar bloques…'),
          ),
      ],
    ),
  );

  Future<void> _shelveHunks(FileChange f, String diff) async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(
          'Apartar ${_hunks.length} ${_hunks.length == 1 ? 'bloque' : 'bloques'} de ${f.path}',
          style: const TextStyle(fontSize: 14),
        ),
        content: SizedBox(
          width: 420,
          child: TextField(
            controller: ctrl,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'Nombre (p. ej. Implementación de reportes)'),
            onSubmitted: (v) => Navigator.pop(c, v.trim().isEmpty ? null : v.trim()),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(c, ctrl.text.trim().isEmpty ? null : ctrl.text.trim()), child: const Text('Apartar')),
        ],
      ),
    );
    ctrl.dispose();
    if (name == null) return;
    final chosen = {..._hunks};
    _hunks.clear();
    await _guard(() async {
      await widget.trash.save(widget.repo, f.path); // copia de seguridad por si acaso
      await shelveHunks(widget.repo, f.path, diff, chosen, name);
    });
  }

  int get _conflicts => _files.where((f) => f.status == FileStatus.conflicted).length;

  /// Aviso de merge/rebase a medias: cuántos conflictos quedan, abortar o terminar.
  Widget _mergeBanner() {
    final left = _conflicts;
    final what = _merge == MergeState.rebase ? 'rebase' : 'merge';
    return Container(
      padding: const EdgeInsets.all(Gh.sp),
      decoration: BoxDecoration(
        color: Gh.conflicted.withValues(alpha: 0.15),
        border: const Border(bottom: Gh.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.warning_amber, size: 16, color: Gh.conflicted),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  left == 0 ? 'Conflictos resueltos. Termina el $what.' : '$left ${left == 1 ? 'archivo' : 'archivos'} en conflicto',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _guard(() => abortMerge(widget.repo, _merge).then((_) => widget.onCommitted())),
                  child: Text('Abortar $what'),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: FilledButton(
                  onPressed: left > 0
                      ? null
                      : () => _guard(() async {
                          await finishMerge(widget.repo, _merge, identity: widget.account?.identityArgs ?? const []);
                          widget.onCommitted();
                        }),
                  child: const Text('Terminar'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Archivo en conflicto: el contenido con las marcas, mi parte y la del remoto
  /// en colores, y las formas de resolverlo.
  Widget _conflictView(FileChange f) {
    final file = File('${widget.repo}/${f.path}');
    final lines = file.existsSync() ? file.readAsLinesSync() : <String>[];
    final parts = conflictParts(lines);
    final rebase = _merge == MergeState.rebase;
    Color? bg(ConflictPart p) => switch (p) {
      ConflictPart.marker => Gh.boxAlt,
      ConflictPart.mine => Gh.diffAdd,
      ConflictPart.theirs => const Color(0xff0b2a4a),
      ConflictPart.base => Gh.box,
      ConflictPart.normal => null,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        fileHeader(f),
        Container(
          padding: const EdgeInsets.all(Gh.sp),
          decoration: const BoxDecoration(border: Border(bottom: Gh.divider)),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Text('Verde: tu versión · Azul: la del remoto.  ', style: TextStyle(color: Gh.textSecondary)),
              OutlinedButton.icon(
                onPressed: () => _guard(() => resolveWith(widget.repo, f.path, mine: true, state: _merge)),
                icon: const Icon(Icons.person_outline, size: 16),
                label: const Text('Usar mi versión'),
              ),
              OutlinedButton.icon(
                onPressed: () => _guard(() => resolveWith(widget.repo, f.path, mine: false, state: _merge)),
                icon: const Icon(Icons.cloud_download_outlined, size: 16),
                label: const Text('Usar la del remoto'),
              ),
              OutlinedButton.icon(
                onPressed: () => openInEditor(widget.editorCommand, file.path),
                icon: const Icon(Icons.code, size: 16),
                label: const Text('Corregir en el editor'),
              ),
              FilledButton.icon(
                onPressed: parts.contains(ConflictPart.marker) ? null : () => _guard(() => markResolved(widget.repo, f.path)),
                icon: const Icon(Icons.check, size: 16),
                label: const Text('Marcar como resuelto'),
              ),
              if (rebase)
                const Text('(en un rebase, "tu versión" es tu commit que se está reaplicando)', style: TextStyle(color: Gh.textSecondary)),
            ],
          ),
        ),
        Expanded(
          child: SelectionArea(
            child: ListView.builder(
              itemCount: lines.length,
              itemExtent: 18,
              itemBuilder: (_, i) => Container(
                color: bg(parts[i]),
                padding: const EdgeInsets.only(left: Gh.sp),
                child: Text(
                  lines[i],
                  softWrap: false,
                  overflow: TextOverflow.clip,
                  style: Gh.mono.copyWith(color: parts[i] == ConflictPart.marker ? Gh.conflicted : Gh.text),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _fileMenu(FileChange f, Offset at) async {
    final dir = f.path.contains('/') ? '${widget.repo}/${f.path.substring(0, f.path.lastIndexOf('/'))}' : widget.repo;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: [
        menuItem('protect', Icons.lock_outline, 'Proteger cambio local (nunca subirlo)'),
        menuItem('shelve', Icons.inventory_2_outlined, 'Apartar este archivo…'),
        const PopupMenuDivider(),
        menuItem('copy', Icons.content_copy, 'Copiar ruta'),
        menuItem('folder', Icons.folder_open_outlined, 'Abrir carpeta del archivo'),
        const PopupMenuDivider(),
        menuItem('discard', Icons.delete_outline, 'Descartar cambios…', danger: true),
      ],
    );
    switch (action) {
      case 'protect':
        await _guard(() => protect(widget.repo, f));
      case 'shelve':
        await _shelve([f]);
      case 'discard':
        if (await _confirmDiscard(f)) {
          await _guard(() async {
            await widget.trash.save(widget.repo, f.path);
            await discard(widget.repo, f);
          });
        }
      case 'copy':
        await Clipboard.setData(ClipboardData(text: f.path));
      case 'folder':
        widget.onOpenFolder(dir);
    }
  }

  /// Aparta [files] con un nombre: salen del working tree y quedan en
  /// "Apartados" hasta recuperarlos.
  Future<void> _shelve(List<FileChange> files) async {
    if (files.isEmpty) return;
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: Gh.bg,
        title: Text(files.length == 1 ? 'Apartar 1 archivo' : 'Apartar ${files.length} archivos', style: const TextStyle(fontSize: 14)),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Se guardan con un nombre y desaparecen de Cambios; lo demás se queda. '
                'Puedes cambiar de rama, hacer otro commit y recuperarlos después desde "Apartados".',
                style: TextStyle(color: Gh.textSecondary),
              ),
              const SizedBox(height: Gh.sp),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 120),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final f in files)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(
                          children: [
                            statusIcon(f.status),
                            const SizedBox(width: 6),
                            Expanded(child: Text(f.path, overflow: TextOverflow.ellipsis)),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: Gh.sp),
              TextField(
                controller: ctrl,
                autofocus: true,
                decoration: const InputDecoration(hintText: 'Nombre (p. ej. Implementación de reportes)'),
                onSubmitted: (v) => Navigator.pop(c, v.trim().isEmpty ? null : v.trim()),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(c, ctrl.text.trim().isEmpty ? null : ctrl.text.trim()), child: const Text('Apartar')),
        ],
      ),
    );
    if (name == null) return;
    await _guard(
      () => shelve(widget.repo, name, [
        for (final f in files) ...[f.path, ?f.oldPath],
      ]),
    );
  }

  Future<void> _shelfMenu(Shelf sh, Offset at) async {
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: [
        menuItem('restore', Icons.unarchive_outlined, 'Recuperar'),
        const PopupMenuDivider(),
        menuItem('drop', Icons.delete_outline, 'Eliminar apartado…', danger: true),
      ],
    );
    if (action == 'restore') await _guard(() => unshelve(widget.repo, sh));
    if (action == 'drop' && mounted) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          backgroundColor: Gh.bg,
          title: const Text('Eliminar apartado', style: TextStyle(fontSize: 14)),
          content: Text('¿Eliminar "${sh.name}"? Sus cambios se pierden.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Gh.deleted),
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Eliminar'),
            ),
          ],
        ),
      );
      if (ok == true) await _guard(() => dropShelf(widget.repo, sh));
    }
  }

  Future<void> _guard(Future<void> Function() op) async {
    try {
      await op();
    } catch (e) {
      if (mounted) _snack(e is GitException ? e.message : '$e');
    }
    await _load();
  }

  Future<bool> _confirmDiscard(FileChange f) async =>
      await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          backgroundColor: Gh.bg,
          title: const Text('Descartar cambios', style: TextStyle(fontSize: 14)),
          content: Text(
            f.status == FileStatus.added
                ? '¿Borrar ${f.path}? Es un archivo nuevo; queda una copia en la papelera de MickHub.'
                : '¿Descartar los cambios de ${f.path}? Vuelve a la versión del último commit; tu versión queda en la papelera de MickHub.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Gh.deleted),
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Descartar'),
            ),
          ],
        ),
      ) ??
      false;

  /// Sección plegable bajo la lista de cambios (Protegidos, Apartados): siempre
  /// visible mientras tenga algo, para que no se olvide.
  Widget _section({
    required IconData icon,
    required Color color,
    required String title,
    required bool open,
    required VoidCallback toggle,
    required List<Widget> rows,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      InkWell(
        onTap: toggle,
        child: Container(
          height: Gh.rowHeight,
          padding: const EdgeInsets.symmetric(horizontal: Gh.sp),
          decoration: const BoxDecoration(
            color: Gh.boxAlt,
            border: Border(top: Gh.divider, bottom: Gh.divider),
          ),
          child: Row(
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 6),
              Expanded(
                child: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
              Icon(open ? Icons.expand_more : Icons.chevron_right, size: 16, color: Gh.textSecondary),
            ],
          ),
        ),
      ),
      if (open)
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: Gh.rowHeight * 4),
          child: ListView(shrinkWrap: true, children: rows),
        ),
    ],
  );

  Widget _rowAction(String tooltip, IconData icon, VoidCallback onPressed) =>
      IconButton(tooltip: tooltip, iconSize: 14, visualDensity: VisualDensity.compact, onPressed: onPressed, icon: Icon(icon));

  Widget _protectedSection() => _section(
    icon: Icons.lock,
    color: Gh.modified,
    title: 'Protegidos (${_protected.length})',
    open: _showProtected,
    toggle: () => setState(() => _showProtected = !_showProtected),
    rows: [
      for (final p in _protected)
        GhRow(
          child: Row(
            children: [
              Expanded(
                child: Tooltip(
                  message: p.tracked ? 'Cambios ocultos con skip-worktree' : 'Archivo nuevo ignorado en .git/info/exclude',
                  child: Text(
                    p.path,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Gh.textSecondary),
                  ),
                ),
              ),
              _rowAction('Desproteger', Icons.lock_open, () => _guard(() => unprotect(widget.repo, p))),
            ],
          ),
        ),
    ],
  );

  Widget _shelvesSection() => _section(
    icon: Icons.inventory_2_outlined,
    color: Gh.link,
    title: 'Apartados (${_shelves.length})',
    open: _showShelves,
    toggle: () => setState(() => _showShelves = !_showShelves),
    rows: [
      for (final sh in _shelves)
        GhRow(
          height: 40,
          onSecondary: (at) => _shelfMenu(sh, at),
          child: Row(
            children: [
              Expanded(
                child: FutureBuilder<List<String>>(
                  future: shelfFiles(widget.repo, sh),
                  builder: (_, snap) => Tooltip(
                    message: (snap.data ?? const []).join('\n'),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(sh.name, overflow: TextOverflow.ellipsis),
                        Text(
                          '${sh.branch} · ${snap.data?.length ?? '…'} archivos · ${timeAgo(sh.date)}',
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: Gh.fontSizeSm, color: Gh.textSecondary),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              _rowAction('Recuperar', Icons.unarchive_outlined, () => _guard(() => unshelve(widget.repo, sh))),
            ],
          ),
        ),
    ],
  );

  List<String> get _included => [
    for (final f in _files)
      if (!_excluded.contains(f.path)) ...[f.path, ?f.oldPath],
  ];

  Future<void> _commit() async {
    setState(() => _committing = true);
    try {
      await commit(widget.repo, _included, _summary.text.trim(), _description.text, identity: widget.account?.identityArgs ?? const []);
      _summary.clear();
      _description.clear();
      widget.onCommitted();
    } on GitException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('No se pudo hacer el commit: ${e.message}')));
    } finally {
      if (mounted) setState(() => _committing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final n = _files.length;
    final checked = n - _excluded.length;
    final sidebar = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_merge != MergeState.none) _mergeBanner(),
        Container(
          height: Gh.rowHeight,
          padding: const EdgeInsets.symmetric(horizontal: Gh.sp / 2),
          decoration: const BoxDecoration(
            color: Gh.boxAlt,
            border: Border(bottom: Gh.divider),
          ),
          child: Row(
            children: [
              Checkbox(
                tristate: true,
                value: n == 0 ? false : (checked == n ? true : (checked == 0 ? false : null)),
                onChanged: n == 0
                    ? null
                    : (_) => setState(() => checked == n ? _excluded.addAll(_files.map((f) => f.path)) : _excluded.clear()),
              ),
              Expanded(child: Text(n == 1 ? '1 archivo cambiado' : '$n archivos cambiados', textAlign: TextAlign.center)),
              const SizedBox(width: 32),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: n,
            itemExtent: Gh.rowHeight,
            itemBuilder: (_, i) {
              final f = _files[i];
              return GhRow(
                selected: f.path == _selected,
                onTap: () {
                  setState(() {
                    _selected = f.path;
                    _hunks.clear();
                  });
                  _loadDiff();
                },
                onSecondary: (at) => _fileMenu(f, at),
                child: Row(
                  children: [
                    Checkbox(
                      value: !_excluded.contains(f.path),
                      onChanged: (v) => setState(() => v! ? _excluded.remove(f.path) : _excluded.add(f.path)),
                    ),
                    Expanded(
                      child: Tooltip(
                        message: f.path,
                        waitDuration: const Duration(seconds: 1),
                        child: Text(f.path, overflow: TextOverflow.ellipsis),
                      ),
                    ),
                    const SizedBox(width: 4),
                    statusIcon(f.status),
                  ],
                ),
              );
            },
          ),
        ),
        if (_shelves.isNotEmpty) _shelvesSection(),
        if (_protected.isNotEmpty) _protectedSection(),
        _commitBox(checked),
      ],
    );

    final f = _files.where((f) => f.path == _selected).firstOrNull;
    final Widget main = switch ((n, f, _diff)) {
      (0, _, _) => emptyState('No hay cambios locales', 'No hay cambios sin commitear en este repositorio.', [
        OutlinedButton.icon(
          onPressed: () => widget.onOpenFolder(widget.repo),
          icon: const Icon(Icons.folder_open_outlined, size: 16),
          label: const Text('Abrir carpeta'),
        ),
        OutlinedButton.icon(
          onPressed: widget.onOpenEditor,
          icon: const Icon(Icons.code, size: 16),
          label: const Text('Abrir en el editor'),
        ),
      ]),
      (_, null, _) => emptyState('Selecciona un archivo', 'Elige un archivo de la lista para ver sus cambios.'),
      (_, final f?, _) when f.status == FileStatus.conflicted => _conflictView(f),
      (_, final f?, final d?) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          fileHeader(f),
          if (f.status == FileStatus.modified && RegExp('^@@', multiLine: true).allMatches(d).length > 1) _hunkBar(f, d),
          Expanded(
            child: DiffView(
              d,
              path: f.path,
              selectedHunks: f.status == FileStatus.modified ? _hunks : null,
              onToggleHunk: f.status == FileStatus.modified
                  ? (h) => setState(() => _hunks.contains(h) ? _hunks.remove(h) : _hunks.add(h))
                  : null,
            ),
          ),
        ],
      ),
      _ => const SizedBox(),
    };
    return widget.layout(sidebar, main);
  }

  /// "Commit como …": deja a la vista con qué cuenta se firma, para no subir un
  /// commit del trabajo con la cuenta personal (o al revés).
  Widget _commitAs() {
    final a = widget.account;
    final who = a != null && a.hasIdentity ? '${a.gitName} <${a.gitEmail}>' : _gitIdentity;
    final text = who == null ? 'Sin nombre/email de git configurado' : 'Commit como $who';
    return Tooltip(
      message: a == null ? 'Identidad de la configuración de git' : 'Cuenta ${a.label}',
      child: Row(
        children: [
          if (who == null)
            const Icon(Icons.person_off_outlined, size: 14, color: Gh.deleted)
          else
            Avatar(
              user: a?.githubUser,
              email: a != null && a.hasIdentity ? a.gitEmail : RegExp(r'<(.*)>').firstMatch(who)?[1],
              name: a?.gitName ?? who,
              size: 16,
            ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              a == null ? text : '$text · ${a.label}',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: Gh.fontSizeSm, color: who == null ? Gh.deleted : Gh.textSecondary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _commitBox(int checked) {
    final can = checked > 0 && _summary.text.trim().isNotEmpty && !_committing;
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.enter, control: true): () => can ? _commit() : null},
      child: _commitBoxBody(checked, can),
    );
  }

  Widget _commitBoxBody(int checked, bool can) {
    return Container(
      padding: const EdgeInsets.all(Gh.sp),
      decoration: const BoxDecoration(
        color: Gh.boxAlt,
        border: Border(top: Gh.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _commitAs(),
          const SizedBox(height: 6),
          TextField(
            controller: _summary,
            style: const TextStyle(fontSize: Gh.fontSize),
            decoration: const InputDecoration(hintText: 'Resumen (obligatorio)'),
          ),
          const SizedBox(height: Gh.sp),
          TextField(
            controller: _description,
            minLines: 4,
            maxLines: 4,
            style: const TextStyle(fontSize: Gh.fontSize),
            decoration: const InputDecoration(hintText: 'Descripción'),
          ),
          const SizedBox(height: Gh.sp),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: can ? _commit : null,
                  child: Text(_committing ? 'Haciendo commit…' : 'Commit a ${widget.branch}', overflow: TextOverflow.ellipsis),
                ),
              ),
              const SizedBox(width: 6),
              Tooltip(
                message: 'Apartar los archivos marcados',
                child: OutlinedButton(
                  onPressed: checked == 0
                      ? null
                      : () => _shelve([
                          for (final f in _files)
                            if (!_excluded.contains(f.path)) f,
                        ]),
                  style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 10), minimumSize: const Size(0, 36)),
                  child: const Icon(Icons.inventory_2_outlined, size: 16),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Tab "Historial": commits de la rama actual, archivos del elegido y su diff.
class HistoryPane extends StatefulWidget {
  const HistoryPane({
    super.key,
    required this.repo,
    required this.ahead,
    required this.tick,
    required this.layout,
    required this.onChanged,
    this.account,
    this.originUrl,
  });
  final String repo;
  final int ahead;
  final int tick;
  final Widget Function(Widget sidebar, Widget main) layout;

  /// Algo cambió el repo (revertir, deshacer): el Shell refresca rama y cambios.
  final VoidCallback onChanged;
  final Account? account;
  final String? originUrl;

  @override
  State<HistoryPane> createState() => _HistoryPaneState();
}

class _HistoryPaneState extends State<HistoryPane> {
  List<Commit> _commits = []; // páginas cargadas de la rama, en orden
  bool _hasMore = false, _loadingMore = false;
  String _query = '';
  List<Commit>? _results; // búsqueda en todo el historial; null = sin búsqueda
  Timer? _searchDebounce;
  Commit? _selected;
  List<FileChange> _files = [];
  FileChange? _file;
  String? _diff;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(HistoryPane old) {
    super.didUpdateWidget(old);
    if (old.tick != widget.tick) _load();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final commits = await log(widget.repo);
    if (!mounted) return;
    setState(() {
      _commits = commits;
      _hasMore = commits.length == logPage;
    });
    if (_query.trim().isNotEmpty) _search(_query);
    final keep = commits.where((c) => c.hash == _selected?.hash).firstOrNull;
    if (commits.isNotEmpty) _select(keep ?? commits.first);
  }

  /// Siguiente página, al llegar al final de la lista.
  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    _loadingMore = true;
    final more = await log(widget.repo, skip: _commits.length);
    if (!mounted) return;
    setState(() {
      _commits = [..._commits, ...more];
      _hasMore = more.length == logPage;
      _loadingMore = false;
    });
  }

  void _onQuery(String q) {
    setState(() => _query = q);
    _searchDebounce?.cancel();
    if (q.trim().isEmpty) {
      setState(() => _results = null);
      return;
    }
    _searchDebounce = Timer(const Duration(milliseconds: 300), () => _search(q));
  }

  Future<void> _search(String q) async {
    final r = await searchLog(widget.repo, q);
    if (mounted && q == _query) setState(() => _results = r);
  }

  Future<void> _select(Commit c) async {
    setState(() => _selected = c);
    final files = await commitFiles(widget.repo, c.hash);
    if (!mounted || _selected != c) return;
    setState(() => _files = files);
    if (files.isNotEmpty) _selectFile(files.first);
  }

  Future<void> _selectFile(FileChange f) async {
    setState(() {
      _file = f;
      _diff = null;
    });
    final d = await commitFileDiff(widget.repo, _selected!.hash, f);
    if (mounted && _file == f) setState(() => _diff = d);
  }

  /// Acciones simples sobre commits ya hechos: copiar el hash, abrirlo en la
  /// web, revertirlo (sirve aunque ya esté subido) y deshacer el último si
  /// todavía no se subió.
  Future<void> _commitMenu(Commit c, Offset at) async {
    final isLast = _commits.isNotEmpty && _commits.first.hash == c.hash;
    final unpushed = _commits.take(widget.ahead).any((x) => x.hash == c.hash);
    final web = commitWebUrl(widget.originUrl, c.hash);
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: [
        menuItem('copy', Icons.content_copy, 'Copiar hash'),
        if (web != null) menuItem('web', Icons.open_in_new, 'Ver en el navegador'),
        const PopupMenuDivider(),
        if (isLast && unpushed) menuItem('undo', Icons.undo, 'Deshacer este commit (vuelve a Cambios)'),
        menuItem('revert', Icons.settings_backup_restore, 'Revertir este commit…', danger: true),
      ],
    );
    if (!mounted) return;
    try {
      switch (action) {
        case 'copy':
          await Clipboard.setData(ClipboardData(text: c.hash));
        case 'web':
          await openFolder(web!); // xdg-open/explorer abren URLs igual que carpetas
        case 'undo':
          await undoLastCommit(widget.repo);
          widget.onChanged();
        case 'revert':
          final ok = await showDialog<bool>(
            context: context,
            builder: (d) => AlertDialog(
              title: const Text('Revertir commit', style: TextStyle(fontSize: 14)),
              content: Text(
                'Se crea un commit nuevo que deshace "${c.summary}" (${c.shortHash}). El commit original no se toca, '
                'así que sirve aunque ya esté subido.',
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancelar')),
                FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Revertir')),
              ],
            ),
          );
          if (ok == true) {
            await revertCommit(widget.repo, c.hash, identity: widget.account?.identityArgs ?? const []);
            widget.onChanged();
          }
      }
    } on GitException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final searching = _query.trim().isNotEmpty;
    final shown = searching ? (_results ?? const <Commit>[]) : _commits;
    // Los primeros `ahead` commits de la rama son los que todavía no se subieron.
    final unpushed = {for (final c in _commits.take(widget.ahead)) c.hash};
    final list = _commits.isEmpty
        ? emptyState('Sin commits', 'Esta rama todavía no tiene commits.')
        : shown.isEmpty
        ? emptyState(searching && _results == null ? 'Buscando…' : 'Sin resultados', 'Ningún commit coincide con "$_query".')
        : ListView.builder(
            itemCount: shown.length + (!searching && _hasMore ? 1 : 0),
            itemExtent: Gh.commitRowHeight,
            itemBuilder: (_, i) {
              if (i == shown.length) {
                // Fila final: al hacerse visible pide la página siguiente.
                WidgetsBinding.instance.addPostFrameCallback((_) => _loadMore());
                return const Center(child: SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)));
              }
              final c = shown[i];
              return GhRow(
                height: Gh.commitRowHeight,
                selected: c.hash == _selected?.hash,
                onTap: () => _select(c),
                onSecondary: (at) => _commitMenu(c, at),
                child: Row(
                  children: [
                    Avatar(email: c.email, name: c.author, size: 24),
                    const SizedBox(width: Gh.sp),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            c.summary,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${c.author} · ${timeAgo(c.date)}',
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    if (unpushed.contains(c.hash))
                      const Tooltip(
                        message: 'Sin subir',
                        child: Icon(Icons.arrow_upward, size: 14, color: Gh.textSecondary),
                      ),
                  ],
                ),
              );
            },
          );

    final sidebar = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(Gh.sp / 2),
          child: TextField(
            style: const TextStyle(fontSize: Gh.fontSize),
            decoration: const InputDecoration(hintText: 'Buscar por mensaje, autor o hash', prefixIcon: Icon(Icons.search, size: 16)),
            onChanged: _onQuery,
          ),
        ),
        const Divider(height: 1, color: Gh.border),
        Expanded(child: list),
      ],
    );

    final c = _selected;
    final main = c == null
        ? emptyState('Sin commits')
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.all(Gh.sp),
                decoration: const BoxDecoration(
                  color: Gh.boxAlt,
                  border: Border(bottom: Gh.divider),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SelectableText(c.summary, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Avatar(email: c.email, name: c.author, size: 18),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            '${c.author} · ${c.shortHash} · ${_files.length} archivos · ${timeAgo(c.date)}',
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      width: 250,
                      child: ListView.builder(
                        itemCount: _files.length,
                        itemExtent: Gh.rowHeight,
                        itemBuilder: (_, i) {
                          final f = _files[i];
                          return GhRow(
                            selected: f == _file,
                            onTap: () => _selectFile(f),
                            child: Row(
                              children: [
                                Expanded(child: Text(f.path, overflow: TextOverflow.ellipsis)),
                                const SizedBox(width: 4),
                                statusIcon(f.status),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                    const VerticalDivider(width: 1, thickness: 1, color: Gh.border),
                    Expanded(child: _diff == null ? const SizedBox() : DiffView(_diff!, path: _file!.path)),
                  ],
                ),
              ),
            ],
          );
    return widget.layout(sidebar, main);
  }
}

String timeAgo(DateTime d, {DateTime? now}) {
  final s = (now ?? DateTime.now()).difference(d);
  if (s.inMinutes < 1) return 'hace un momento';
  if (s.inHours < 1) return 'hace ${s.inMinutes} min';
  if (s.inDays < 1) return 'hace ${s.inHours} h';
  if (s.inDays < 30) return s.inDays == 1 ? 'hace 1 día' : 'hace ${s.inDays} días';
  if (s.inDays < 365) return s.inDays < 60 ? 'hace 1 mes' : 'hace ${s.inDays ~/ 30} meses';
  return s.inDays < 730 ? 'hace 1 año' : 'hace ${s.inDays ~/ 365} años';
}

/// Búsqueda del historial: texto en el mensaje o el autor, o prefijo del hash.
// ponytail: busca solo en los commits ya cargados (los últimos 300). Upgrade:
// pasar la búsqueda a `git log --grep/--author` para cubrir todo el historial.
bool matchesCommit(Commit c, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  return c.hash.startsWith(q) || c.summary.toLowerCase().contains(q) || c.author.toLowerCase().contains(q);
}
