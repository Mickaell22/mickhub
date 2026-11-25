import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'accounts.dart';
import 'change_groups.dart';
import 'change_groups_ui.dart';
import 'decor.dart';
import 'avatar.dart';
import 'summaries.dart';
import 'summaries_pane.dart';
import 'system.dart';
import 'diff_view.dart';
import 'git.dart';
import 'image_diff.dart';
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
          child: SizedBox(width: 5, child: VerticalDivider(width: 1, thickness: 1, color: Gh.border)),
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
          border: Border(bottom: Gh.divider),
        ),
        child: widget.child,
      ),
    ),
  );
}

/// Pantalla vacía. [scene]: con el fondo dibujado de la paleta (solo en los
/// paneles grandes; en una columna angosta estorba).
/// Esc en la ventana (sin desplegable abierto): el panel abierto suelta lo
/// elegido y vuelve a la vista vacía, como salir de un chat a la lista.
final escapeTick = ValueNotifier(0);

Widget emptyState(String title, [String? detail, List<Widget> actions = const [], bool scene = false]) => scene
    ? Stack(
        children: [
          const Positioned.fill(child: SceneBackdrop()),
          emptyState(title, detail, actions),
        ],
      )
    : Center(
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
            style: TextStyle(color: Gh.textSecondary),
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
  decoration: BoxDecoration(
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
    required this.onFocusFile,
    required this.trash,
    required this.editorCommand,
    this.account,
    this.summaries,
    this.onOpenSession,
  });
  final String repo;
  final String branch;
  final int tick;
  final Widget Function(Widget sidebar, Widget main) layout;
  final VoidCallback onCommitted;
  final ValueChanged<String> onOpenFolder;
  final VoidCallback onOpenEditor;

  /// Avisa qué archivo (y en qué línea) se está mirando, para que "Abrir en el
  /// editor" lo abra ahí. null si no hay ninguno.
  final ValueChanged<(String, int?)?> onFocusFile;
  final Trash trash;
  final String editorCommand;

  /// Cuenta del repo: si tiene nombre y email, los commits se firman con ellos.
  final Account? account;

  /// API de IA para escribir el mensaje del commit; null o apagada = sin botón.
  final SummaryApi? summaries;

  /// Retoma la sesión de Claude Code (por su id) que maneja un grupo.
  final void Function(String sessionId)? onOpenSession;

  @override
  State<ChangesPane> createState() => _ChangesPaneState();
}

/// Lo último que se leyó de cada repo, para mostrarlo al instante al volver a
/// él mientras se relee de git.
typedef _Snapshot = (List<FileChange>, List<Protected>, List<Shelf>, String?, MergeState, ChangeGroups, Map<String, String>);
final _snapshots = <String, _Snapshot>{};

/// Mensaje de commit a medio escribir de cada repo (resumen, descripción). El
/// panel se destruye al pasar a Historial o a otro repo y el mensaje que había
/// escrito la IA se perdía: había que volver a generarlo.
final _drafts = <String, (String, String)>{};

class _ChangesPaneState extends State<ChangesPane> {
  List<FileChange> _files = [];
  List<Protected> _protected = [];
  List<Shelf> _shelves = [];
  MergeState _merge = MergeState.none;
  final _hunks = <int>{}; // bloques marcados para apartar en el archivo elegido
  String? _gitIdentity; // la de git (repo o global), si el repo no tiene cuenta
  bool _showShelves = true;
  // Cerrada por defecto (pedido del dueño: siempre salía desplegada); si se abre,
  // queda abierta mientras la app siga abierta, aunque se cambie de pestaña o repo.
  static bool _showProtected = false;
  final _excluded = <String>{}; // filas (grupo + ruta, ver [_key]) que no entran al commit
  ChangeGroups _groups = ChangeGroups();
  Map<String, String> _splitDiffs = {}; // diff de los archivos repartidos entre grupos
  String? _selected;
  String _selGroup = ''; // grupo de la fila elegida (un archivo repartido aparece en varios)
  final _picked = <String>{}; // filas elegidas con Ctrl/Shift (ver [_key]) para acciones por lotes
  String? _anchor; // fila desde donde cuenta un Shift+clic
  String? _diff;
  final _summary = TextEditingController();
  final _description = TextEditingController();
  bool _committing = false;
  bool _drafting = false; // la IA está escribiendo el mensaje

  @override
  void initState() {
    super.initState();
    escapeTick.addListener(_deselect);
    final draft = _drafts[widget.repo];
    if (draft != null) {
      _summary.text = draft.$1;
      _description.text = draft.$2;
    }
    _summary.addListener(() {
      _saveDraft();
      setState(() {});
    });
    _description.addListener(_saveDraft);
    final snap = _snapshots[widget.repo];
    if (snap != null) _apply(snap);
    _load();
    _watchGroups();
  }

  // Claude Code (`mickhub`) reparte cambios en grupos.json mientras la app está
  // abierta: se relee solo, sin F5.
  StreamSubscription<FileSystemEvent>? _groupsWatch;
  Timer? _groupsDebounce;

  Future<void> _watchGroups() async {
    try {
      final sub = await ChangeGroups.watch(widget.repo, () {
        _groupsDebounce?.cancel();
        _groupsDebounce = Timer(const Duration(milliseconds: 250), () {
          if (mounted) _load();
        });
      });
      if (mounted) {
        _groupsWatch = sub;
      } else {
        sub.cancel();
      }
    } catch (_) {
      // sin carpeta .git legible: queda el F5 de siempre
    }
  }

  void _saveDraft() {
    if (_summary.text.isEmpty && _description.text.isEmpty) {
      _drafts.remove(widget.repo);
    } else {
      _drafts[widget.repo] = (_summary.text, _description.text);
    }
  }

  @override
  void didUpdateWidget(ChangesPane old) {
    super.didUpdateWidget(old);
    if (old.tick != widget.tick) _load();
  }

  @override
  void dispose() {
    escapeTick.removeListener(_deselect);
    _groupsWatch?.cancel();
    _groupsDebounce?.cancel();
    _summary.dispose();
    _description.dispose();
    super.dispose();
  }

  bool _loading = false, _reload = false;

  /// Commits sin subir: la cabecera de un grupo cuenta los suyos.
  Set<String> _unpushed = {};

  /// Sube con cada cambio de grupos hecho desde la app. Una lectura que empezó
  /// antes trae grupos viejos: no se aplica ni se guarda (si no, el grupo que se
  /// acaba de contraer se volvía a abrir solo, o al revés).
  int _mutations = 0;

  /// Relee todo de git (en paralelo). Si llega otro pedido mientras tanto, se
  /// hace una sola vuelta más al terminar en vez de dos lecturas pisándose.
  Future<void> _load() async {
    if (_loading) {
      _reload = true;
      return;
    }
    _loading = true;
    try {
      do {
        _reload = false;
        final m = _mutations;
        final (files, locked, shelved, identity, merge, loaded) = await (
          status(widget.repo),
          protectedFiles(widget.repo),
          shelves(widget.repo),
          gitIdentity(widget.repo),
          mergeState(widget.repo),
          ChangeGroups.load(widget.repo),
        ).wait;
        if (m != _mutations) {
          _reload = true;
          continue;
        }
        final paths = files.map((f) => f.path).toList();
        // Con cambios por asignar, se aplica sobre lo último del disco y con candado.
        final groups = loaded.sync(paths) ? await ChangeGroups.update(widget.repo, (g) => g.sync(paths)) : loaded;
        // Lo que entró a un grupo protegido se protege solo y se relee.
        if ((await protectJoined(widget.repo, groups, files)).isNotEmpty) {
          _reload = true;
          continue;
        }
        final split = [
          for (final f in files)
            if (groups.hunks.containsKey(f.path)) f,
        ];
        final diffs = await Future.wait(split.map((f) => fileDiff(widget.repo, f).catchError((_) => '')));
        final _Snapshot r = (
          files,
          locked,
          shelved,
          identity,
          merge,
          groups,
          {for (var i = 0; i < split.length; i++) split[i].path: diffs[i]},
        );
        if (!mounted) return;
        if (m != _mutations) {
          _reload = true;
          continue;
        }
        _snapshots[widget.repo] = r;
        setState(() => _apply(r));
        if (groups.commits.isNotEmpty) {
          final up = await unpushedCommits(widget.repo);
          if (mounted) setState(() => _unpushed = up);
        }
      } while (_reload);
    } finally {
      _loading = false;
    }
    _loadDiff();
  }

  void _deselect() {
    if (_selected == null && _picked.isEmpty) return;
    setState(() {
      _selected = null;
      _selGroup = '';
      _picked.clear();
    });
  }

  void _apply(_Snapshot r) {
    final (files, locked, shelved, identity, merge, groups, splitDiffs) = r;
    _groups = groups;
    _splitDiffs = splitDiffs;
    _merge = merge;
    _files = files;
    _protected = locked;
    _shelves = shelved;
    _gitIdentity = identity;
    final rows = _rows;
    _excluded.retainAll(rows.map((r) => _key(r.$1, r.$2.path)));
    _picked.retainAll(rows.map((r) => _key(r.$1, r.$2.path)));
    // No se abre ningún archivo solo (pedido del dueño: entrar a la vista vacía,
    // como la lista de chats); si el abierto se fue (commit, descarte), se vuelve a ella.
    if (!rows.any((r) => r.$2.path == _selected && r.$1 == _selGroup)) {
      final same = rows.where((r) => r.$2.path == _selected).firstOrNull;
      _selected = same?.$2.path;
      _selGroup = same?.$1 ?? '';
    }
  }

  // --- Grupos de cambios ---------------------------------------------------------

  static String _key(String group, String path) => '$group\u0000$path';

  /// Grupos en el orden de la lista; "Sin grupo" ('') al final.
  List<String> get _sections => [..._groups.names, ''];

  /// Grupos donde aparece [f]: uno, o varios si sus bloques están repartidos.
  List<String> _groupsOf(FileChange f) {
    final d = _splitDiffs[f.path];
    final hg = d == null ? const <String>[] : _groups.hunkGroups(f.path, d);
    if (hg.isEmpty) return [_groups.groupOf(f.path)];
    return [
      for (final g in _sections)
        if (hg.contains(g)) g,
    ];
  }

  /// Filas de la lista: (grupo, archivo), agrupadas en el orden de [_sections].
  List<(String, FileChange)> get _rows {
    final of = {for (final f in _files) f.path: _groupsOf(f)};
    return [
      for (final g in _sections)
        for (final f in _files)
          if (of[f.path]!.contains(g)) (g, f),
    ];
  }

  bool _included(String group, FileChange f) => !_excluded.contains(_key(group, f.path));

  /// Lo marcado, listo para commitear o apartar: archivos enteros y, de los
  /// repartidos con solo algunos grupos marcados, los índices de sus bloques.
  (List<FileChange>, Map<String, (String, Set<int>)>) _marked() {
    final whole = <FileChange>[];
    final parts = <String, (String, Set<int>)>{};
    for (final f in _files) {
      final gs = _groupsOf(f);
      final inc = gs.where((g) => _included(g, f)).toSet();
      if (inc.isEmpty) continue;
      if (inc.length == gs.length) {
        whole.add(f);
        continue;
      }
      final d = _splitDiffs[f.path]!;
      final hg = _groups.hunkGroups(f.path, d);
      parts[f.path] = (
        d,
        {
          for (var i = 0; i < hg.length; i++)
            if (inc.contains(hg[i])) i,
        },
      );
    }
    return (whole, parts);
  }

  Future<void> _saveGroups(void Function(ChangeGroups g) change) async {
    _mutations++;
    change(_groups);
    setState(() {});
    _groups = await ChangeGroups.update(widget.repo, change);
    await _load();
  }

  /// Olvida el grupo de archivos commiteados o descartados (no relee).
  Future<void> _forget(Iterable<String> paths) async {
    if (_groups.names.isEmpty) return;
    _mutations++;
    _groups = await ChangeGroups.update(widget.repo, (g) => g.forget(paths));
  }

  // --- Selección por lotes (Ctrl/Shift+clic) ---------------------------------------

  void _tapRow(String group, FileChange f) {
    final key = _key(group, f.path);
    final kb = HardwareKeyboard.instance;
    setState(() {
      if (kb.isControlPressed || kb.isMetaPressed) {
        if (_picked.isEmpty && _selected != null) _picked.add(_key(_selGroup, _selected!));
        _picked.contains(key) ? _picked.remove(key) : _picked.add(key);
        _anchor = key;
      } else if (kb.isShiftPressed && _anchor != null) {
        final keys = [for (final r in _rows) _key(r.$1, r.$2.path)];
        final (a, b) = (keys.indexOf(_anchor!), keys.indexOf(key));
        if (a >= 0 && b >= 0) {
          _picked
            ..clear()
            ..addAll(keys.sublist(a < b ? a : b, (a < b ? b : a) + 1));
        }
      } else {
        _picked.clear();
        _anchor = key;
      }
      _selected = f.path;
      _selGroup = group;
      _hunks.clear();
    });
    _loadDiff();
  }

  /// Archivos de las filas elegidas (sin repetir los repartidos).
  List<FileChange> get _pickedFiles {
    final seen = <String>{};
    return [
      for (final r in _rows)
        if (_picked.contains(_key(r.$1, r.$2.path)) && seen.add(r.$2.path)) r.$2,
    ];
  }

  /// Menú para varias filas elegidas a la vez.
  Future<void> _batchMenu(Offset at) async {
    final files = _pickedFiles;
    final n = files.length;
    final what = n == 1 ? '1 archivo' : '$n archivos';
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: [
        menuItem('group', Icons.folder_special_outlined, 'Mover $what a grupo…'),
        menuItem('shelve', Icons.inventory_2_outlined, 'Apartar $what…'),
        menuItem('protect', Icons.lock_outline, 'Proteger $what (nunca subirlos)'),
        const PopupMenuDivider(),
        menuItem('discard', Icons.delete_outline, 'Descartar $what…', danger: true),
      ],
    );
    switch (action) {
      case 'group':
        if (!mounted) return;
        final to = await pickGroup(context, at, _groups.names);
        if (to == null) return;
        await _saveGroups((g) {
          if (to.isNotEmpty && !g.names.contains(to)) g.add(to, _files.map((f) => f.path));
          for (final f in files) {
            g.moveFile(f.path, to);
          }
        });
        setState(_picked.clear);
      case 'shelve':
        // Si todos son de un mismo grupo, el apartado se llama como él.
        final gs = files.map((f) => _groups.groupOf(f.path)).toSet();
        await _shelve(files, suggested: gs.length == 1 && gs.first.isNotEmpty ? gs.first : null);
      case 'protect':
        await _guard(() async {
          for (final f in files) {
            await protect(widget.repo, f);
          }
        });
      case 'discard':
        if (!await _confirmDiscardMany(what)) return;
        await _guard(() async {
          for (final f in files) {
            await widget.trash.save(widget.repo, f.path);
            await discard(widget.repo, f);
          }
          await _forget(files.map((f) => f.path));
        });
        setState(_picked.clear);
    }
  }

  Future<bool> _confirmDiscardMany(String what) async =>
      await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text('Descartar $what', style: const TextStyle(fontSize: 14)),
          content: Text(
            'Vuelven a la versión del último commit (los nuevos se borran). '
            'Tu versión de cada uno queda en la papelera de MickHub.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Gh.deleted),
              onPressed: () => Navigator.pop(c, true),
              child: Text('Descartar $what'),
            ),
          ],
        ),
      ) ??
      false;

  /// Descarta todo lo de un grupo: archivos enteros y, de los repartidos, solo
  /// sus bloques. Antes guarda copia de cada uno en la papelera.
  Future<void> _discardGroup(String group, List<FileChange> files) async {
    final n = files.length;
    if (n == 0 || !await _confirmDiscardMany(n == 1 ? '1 archivo de "$group"' : '$n archivos de "$group"')) return;
    _mutations++;
    await _guard(() async {
      for (final f in files) {
        await widget.trash.save(widget.repo, f.path);
        if (_groupsOf(f).length > 1) {
          final d = _splitDiffs[f.path]!;
          final hg = _groups.hunkGroups(f.path, d);
          await discardHunks(widget.repo, d, {
            for (var i = 0; i < hg.length; i++)
              if (hg[i] == group) i,
          });
        } else {
          await discard(widget.repo, f);
          _groups.forget([f.path]);
        }
      }
      await _groups.save(widget.repo);
    });
  }

  Future<void> _newGroup({List<FileChange> take = const []}) async {
    final name = await askGroupName(context, title: 'Nuevo grupo de cambios', taken: _groups.names.toSet());
    if (name == null) return;
    // Queda activo: lo que se toque de ahora en adelante cae aquí.
    await _saveGroups((g) => g.add(name, _files.map((f) => f.path), take: take.map((f) => f.path)));
  }

  Future<void> _moveFileTo(FileChange f, Offset at) async {
    final to = await pickGroup(context, at, _groups.names, current: _groupsOf(f).length == 1 ? _groupsOf(f).single : null);
    if (to == null) return;
    await _saveGroups((g) {
      if (to.isNotEmpty && !g.names.contains(to)) g.add(to, _files.map((f) => f.path));
      g.moveFile(f.path, to);
    });
  }

  /// Mueve los bloques marcados del archivo elegido a otro grupo.
  Future<void> _moveHunksTo(FileChange f, Offset at) async {
    final to = await pickGroup(context, at, _groups.names, current: _selGroup);
    if (to == null) return;
    final full = _splitDiffs[f.path] ?? await fileDiff(widget.repo, f);
    // Los índices marcados son del diff que se ve (el de este grupo); se pasan
    // por su clave a índices del diff completo.
    final shown = hunkKeys(_diff ?? '');
    final keys = {
      for (final i in _hunks)
        if (i < shown.length) shown[i],
    };
    final all = hunkKeys(full);
    final indices = {
      for (var i = 0; i < all.length; i++)
        if (keys.contains(all[i])) i,
    };
    _hunks.clear();
    await _saveGroups((g) {
      if (to.isNotEmpty && !g.names.contains(to)) g.add(to, _files.map((f) => f.path));
      g.moveHunks(f.path, full, indices, to);
    });
  }

  void _toggleSection(String group) => _saveGroups((g) => g.collapsed.contains(group) ? g.collapsed.remove(group) : g.collapsed.add(group));

  Future<void> _groupMenu(String group, Offset at) async {
    final named = group.isNotEmpty;
    final active = named && _groups.active == group;
    final rows = _rows.where((r) => r.$1 == group).toList();
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: [
        if (named)
          menuItem('active', active ? Icons.star : Icons.star_outline, active ? 'Dejar de usar como activo' : 'Usar como grupo activo'),
        menuItem('only', Icons.check_box_outlined, 'Marcar solo este grupo para el commit'),
        if (named) ...[
          menuItem('shelve', Icons.inventory_2_outlined, 'Apartar grupo…'),
          _groups.protectedGroups.contains(group)
              ? menuItem('unprotect', Icons.lock_open, 'Desproteger grupo')
              : menuItem('protect', Icons.lock_outline, 'Proteger grupo (nunca subirlo, ni lo que entre después)'),
        ],
        if (rows.isNotEmpty) menuItem('discard', Icons.delete_outline, 'Descartar grupo…', danger: true),
        ..._sessionItems([group], _groups.sessions),
        const PopupMenuDivider(),
        menuItem('expand', Icons.unfold_more, 'Expandir todo'),
        menuItem('collapse', Icons.unfold_less, 'Contraer todo'),
        if (named) ...[
          const PopupMenuDivider(),
          menuItem('rename', Icons.edit_outlined, 'Renombrar…'),
          menuItem('describe', Icons.notes, _groups.descriptions[group] == null ? 'Agregar descripción…' : 'Editar descripción…'),
          menuItem('delete', Icons.delete_outline, 'Eliminar grupo (los cambios quedan)', danger: true),
        ],
      ],
    );
    switch (action) {
      case final a? when a.startsWith('session:'):
        widget.onOpenSession?.call(a.substring(8));
      case 'active':
        await _saveGroups((g) => g.active = active ? null : group);
      case 'only':
        setState(() {
          _excluded
            ..clear()
            ..addAll([
              for (final r in _rows)
                if (r.$1 != group) _key(r.$1, r.$2.path),
            ]);
        });
      case 'shelve':
        await _shelveGroup(group, rows.map((r) => r.$2).toList());
      case 'discard':
        await _discardGroup(group, rows.map((r) => r.$2).toList());
      case 'protect':
        await _guard(() async {
          final (_, split) = await protectGroup(widget.repo, group);
          if (split.isNotEmpty) _snack('Repartidos con otro grupo, no se protegen a medias: ${split.join(', ')}');
        });
      case 'unprotect':
        await _guard(() => unprotectGroup(widget.repo, group));
      case 'expand':
        await _saveGroups((g) => g.collapsed.clear());
      case 'collapse':
        await _saveGroups((g) => g.collapsed = _sections.toSet());
      case 'rename':
        if (!mounted) return;
        final to = await askGroupName(context, title: 'Renombrar grupo', initial: group, taken: _groups.names.toSet());
        if (to != null && to != group) await _saveGroups((g) => g.rename(group, to));
      case 'describe':
        if (!mounted) return;
        final d = await askGroupDescription(context, group: group, initial: _groups.descriptions[group]);
        if (d != null) await _saveGroups((g) => d.isEmpty ? g.descriptions.remove(group) : g.descriptions[group] = d);
      case 'delete':
        await _saveGroups((g) => g.remove(group));
    }
  }

  /// Aparta todo lo de un grupo en un solo apartado con su nombre: archivos
  /// enteros y, de los repartidos, solo sus bloques.
  Future<void> _shelveGroup(String group, List<FileChange> files) async {
    final parts = <String, (String, Set<int>)>{};
    for (final f in files.where((f) => _groupsOf(f).length > 1)) {
      final d = _splitDiffs[f.path]!;
      final hg = _groups.hunkGroups(f.path, d);
      parts[f.path] = (
        d,
        {
          for (var i = 0; i < hg.length; i++)
            if (hg[i] == group) i,
        },
      );
    }
    await _shelve(files, parts: parts, suggested: group);
  }

  Future<void> _loadDiff() async {
    final f = _files.where((f) => f.path == _selected).firstOrNull;
    if (f == null) {
      widget.onFocusFile(null);
      return setState(() => _diff = null);
    }
    try {
      var d = await fileDiff(widget.repo, f);
      // Un archivo repartido muestra solo los bloques del grupo elegido.
      if (_groupsOf(f).length > 1) {
        final hg = _groups.hunkGroups(f.path, d);
        d =
            selectHunks(d, {
              for (var i = 0; i < hg.length; i++)
                if (hg[i] == _selGroup) i,
            }) ??
            d;
      }
      if (mounted && _selected == f.path) {
        setState(() => _diff = d);
        widget.onFocusFile(f.status == FileStatus.deleted ? null : (f.path, _focusLine(f, d)));
      }
    } on GitException catch (e) {
      if (mounted) setState(() => _diff = null);
      debugPrint(e.toString());
    }
  }

  /// Línea donde abrir el archivo: el primer conflicto, o el primer cambio del diff.
  int? _focusLine(FileChange f, String diff) {
    if (f.status == FileStatus.conflicted) {
      final file = File('${widget.repo}/${f.path}');
      if (!file.existsSync()) return null;
      final i = file.readAsLinesSync().indexWhere((l) => l.startsWith('<<<<<<<'));
      return i < 0 ? null : i + 1;
    }
    final first = parseDiff(diff)?.where((l) => l.kind == LineKind.add || l.kind == LineKind.delete).firstOrNull;
    return first?.newNo ?? first?.oldNo;
  }

  Future<void> _openFileInEditor(FileChange f) async {
    String? d;
    try {
      d = await fileDiff(widget.repo, f);
    } on GitException {
      d = null;
    }
    try {
      await openInEditor(widget.editorCommand, widget.repo, file: f.path, line: d == null ? null : _focusLine(f, d));
    } catch (_) {
      if (mounted) _snack('No se encontró el editor "${widget.editorCommand}". ¿Está instalado y en el PATH?');
    }
  }

  void _snack(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  /// Barra sobre el diff para apartar solo algunos bloques del archivo.
  Widget _hunkBar(FileChange f, String diff) => Container(
    height: Gh.rowHeight + 6,
    padding: const EdgeInsets.symmetric(horizontal: Gh.sp),
    decoration: BoxDecoration(
      color: Gh.box,
      border: Border(bottom: Gh.divider),
    ),
    child: Row(
      children: [
        Icon(Icons.inventory_2_outlined, size: 14, color: Gh.textSecondary),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            _hunks.isEmpty
                ? 'Marca bloques para apartarlos o moverlos a otro grupo'
                : '${_hunks.length} ${_hunks.length == 1 ? 'bloque marcado' : 'bloques marcados'}',
            style: TextStyle(color: Gh.textSecondary),
          ),
        ),
        if (_hunks.isNotEmpty)
          Builder(
            builder: (b) => TextButton.icon(
              onPressed: () {
                final box = b.findRenderObject()! as RenderBox;
                _moveHunksTo(f, box.localToGlobal(Offset(0, box.size.height)));
              },
              icon: const Icon(Icons.folder_special_outlined, size: 14),
              label: const Text('Mover a grupo…'),
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
    disposeAfterDialog(ctrl);
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
    final stash = _merge == MergeState.stash;
    final what = _merge == MergeState.rebase ? 'rebase' : 'merge';
    return Container(
      padding: const EdgeInsets.all(Gh.sp),
      decoration: BoxDecoration(
        color: Gh.conflicted.withValues(alpha: 0.15),
        border: Border(bottom: Gh.divider),
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
                  left == 0
                      ? (stash ? 'Conflictos resueltos. Aprieta Listo.' : 'Conflictos resueltos. Termina el $what.')
                      : '$left ${left == 1 ? 'archivo' : 'archivos'} en conflicto',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          if (stash)
            Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text(
                'Tus cambios sin commitear chocaron con lo que trajo el pull. Elige con qué quedarte en cada archivo; '
                'mientras tanto tu copia completa sigue guardada en Apartados ("autostash").',
                style: TextStyle(fontSize: Gh.fontSizeSm, color: Gh.textSecondary),
              ),
            ),
          const SizedBox(height: 6),
          Row(
            children: [
              // Al volver a poner un apartado no hay nada que abortar: la copia
              // de los cambios sigue en Apartados.
              if (!stash) ...[
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _guard(() => abortMerge(widget.repo, _merge).then((_) => widget.onCommitted())),
                    child: Text('Abortar $what'),
                  ),
                ),
                const SizedBox(width: 6),
              ],
              Expanded(
                child: FilledButton(
                  onPressed: left > 0
                      ? null
                      : () => _guard(() async {
                          await finishMerge(widget.repo, _merge, identity: widget.account?.identityArgs ?? const []);
                          widget.onCommitted();
                        }),
                  child: Text(stash ? 'Listo' : 'Terminar'),
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
          decoration: BoxDecoration(border: Border(bottom: Gh.divider)),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              // Al volver a poner un apartado git pone primero lo que llegó y después lo tuyo.
              Text(
                _merge == MergeState.stash
                    ? 'Verde: lo que llegó del remoto · Azul: tus cambios.  '
                    : 'Verde: tu versión · Azul: la del remoto.  ',
                style: TextStyle(color: Gh.textSecondary),
              ),
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
                onPressed: () => _openFileInEditor(f),
                icon: const Icon(Icons.code, size: 16),
                label: const Text('Corregir en el editor'),
              ),
              FilledButton.icon(
                onPressed: parts.contains(ConflictPart.marker) ? null : () => _guard(() => markResolved(widget.repo, f.path)),
                icon: const Icon(Icons.check, size: 16),
                label: const Text('Marcar como resuelto'),
              ),
              if (rebase)
                Text('(en un rebase, "tu versión" es tu commit que se está reaplicando)', style: TextStyle(color: Gh.textSecondary)),
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
        menuItem('group', Icons.folder_special_outlined, 'Mover a grupo…'),
        const PopupMenuDivider(),
        if (f.status != FileStatus.deleted) menuItem('editor', Icons.code, 'Abrir en el editor'),
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
      case 'group':
        await _moveFileTo(f, at);
      case 'discard':
        if (await _confirmDiscard(f)) {
          await _guard(() async {
            await widget.trash.save(widget.repo, f.path);
            await discard(widget.repo, f);
            await _forget([f.path]);
          });
        }
      case 'editor':
        await _openFileInEditor(f);
      case 'copy':
        await Clipboard.setData(ClipboardData(text: f.path));
      case 'folder':
        widget.onOpenFolder(dir);
    }
  }

  /// Aparta [files] con un nombre: salen del working tree y quedan en
  /// "Apartados" hasta recuperarlos.
  /// [parts] son archivos de [files] que se apartan solo en parte (sus bloques).
  Future<void> _shelve(List<FileChange> files, {Map<String, (String, Set<int>)> parts = const {}, String? suggested}) async {
    if (files.isEmpty) return;
    final ctrl = TextEditingController(text: suggested);
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
              Text(
                'Se guardan con un nombre y desaparecen de Cambios; lo demás se queda. '
                'Puedes cambiar de rama, hacer otro commit y recuperarlos después desde "Apartados". '
                'Para que no se suban nunca pero sigan en tu copia, usa Proteger, no Apartar.',
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
    await _guard(() async {
      for (final p in parts.keys) {
        await widget.trash.save(widget.repo, p); // copia de seguridad por si acaso
      }
      await shelveGrouped(
        widget.repo,
        name,
        whole: [
          for (final f in files)
            if (!parts.containsKey(f.path)) ...[f.path, ?f.oldPath],
        ],
        parts: parts,
      );
      _mutations++;
      await reconcile(widget.repo);
    });
  }

  /// Recupera un apartado. Cada archivo vuelve al grupo que tenía al apartarlo
  /// ([unshelveGrouped]); los que ya estaban iguales se saltan.
  Future<void> _restoreShelf(Shelf sh) => _guard(() async {
    final r = await unshelveGrouped(widget.repo, sh);
    _mutations++;
    await reconcile(widget.repo);
    if (r.skipped.isNotEmpty && mounted) {
      _snack('${r.skipped.length} archivo(s) ya estaban iguales y no se tocaron: ${r.skipped.join(', ')}');
    }
  });

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
    if (action == 'restore') await _restoreShelf(sh);
    if (action == 'drop' && mounted) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          backgroundColor: Gh.bg,
          title: const Text('Eliminar apartado', style: TextStyle(fontSize: 14)),
          content: Text(
            '¿Eliminar "${sh.name}"? Desaparece de la lista; queda un respaldo '
            '(`mickhub apartados` lo muestra) por si fue un error.',
          ),
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
          decoration: BoxDecoration(
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

  /// Los protegidos siguen recordando su grupo (la asignación no se olvida),
  /// así que se muestran agrupados y se desprotege un grupo entero de una vez;
  /// al desprotegerlos vuelven a su grupo en Cambios.
  Widget _protectedSection() {
    Widget fileRow(Protected p, {bool indent = false}) => GhRow(
      child: Row(
        children: [
          if (indent) const SizedBox(width: Gh.sp * 1.5),
          Expanded(
            child: Tooltip(
              message: p.tracked ? 'Cambios ocultos con skip-worktree' : 'Archivo nuevo ignorado en .git/info/exclude',
              child: Text(
                p.path,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Gh.textSecondary),
              ),
            ),
          ),
          _rowAction(
            _groups.protectedGroups.contains(_groups.groupOf(p.path)) ? 'Desproteger (sale del grupo protegido)' : 'Desproteger',
            Icons.lock_open,
            () => _guard(() => unprotectFile(widget.repo, p)),
          ),
        ],
      ),
    );

    final byGroup = <String, List<Protected>>{};
    for (final p in _protected) {
      byGroup.putIfAbsent(_groups.groupOf(p.path), () => []).add(p);
    }
    final grouped = byGroup.keys.any((g) => g.isNotEmpty);
    final order = [..._groups.names.where(byGroup.containsKey), if (byGroup.containsKey('')) ''];
    return _section(
      icon: Icons.lock,
      color: Gh.modified,
      title: 'Protegidos (${_protected.length})',
      open: _showProtected,
      toggle: () => setState(() => _showProtected = !_showProtected),
      rows: !grouped
          ? [for (final p in _protected) fileRow(p)]
          : [
              for (final g in order) ...[
                GhRow(
                  child: Row(
                    children: [
                      Icon(g.isEmpty ? Icons.folder_off_outlined : Icons.folder_special_outlined, size: 14, color: Gh.textSecondary),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '${g.isEmpty ? 'Sin grupo' : g} (${byGroup[g]!.length})'
                          '${_groups.protectedGroups.contains(g) ? ' · lo que entre se protege solo' : ''}',
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      _rowAction(
                        g.isEmpty ? 'Desproteger los sin grupo' : 'Desproteger grupo',
                        Icons.lock_open,
                        () => _guard(() async {
                          if (g.isNotEmpty) {
                            await unprotectGroup(widget.repo, g);
                            return;
                          }
                          for (final p in byGroup[g]!) {
                            await unprotect(widget.repo, p);
                          }
                        }),
                      ),
                    ],
                  ),
                ),
                for (final p in byGroup[g]!) fileRow(p, indent: true),
              ],
            ],
    );
  }

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
                          [
                            sh.branch,
                            '${snap.data?.length ?? '…'} archivos',
                            // De qué grupos son: al recuperarlo vuelven a ellos.
                            ...{for (final f in snap.data ?? const <String>[]) _groups.groupOf(f)}.where((g) => g.isNotEmpty),
                            timeAgo(sh.date),
                          ].join(' · '),
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: Gh.fontSizeSm, color: Gh.textSecondary),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              _rowAction('Recuperar', Icons.unarchive_outlined, () => _restoreShelf(sh)),
            ],
          ),
        ),
    ],
  );

  /// Mensaje del commit con IA a partir de lo marcado, como Copilot. Antes
  /// pregunta (opcional) qué se hizo; lo escrito en Resumen viene como pista.
  Future<void> _draftMessage() async {
    final api = widget.summaries;
    if (api == null) return;
    final hint = await askCommitHint(context, initial: _summary.text.trim());
    if (hint == null || !mounted) return;
    setState(() => _drafting = true);
    try {
      final (whole, parts) = _marked();
      final diffs = [
        for (final f in whole) await fileDiff(widget.repo, f),
        for (final e in parts.entries) selectHunks(e.value.$1, e.value.$2) ?? '',
      ];
      final m = await api.draftMessage(widget.repo, diffs.join('\n'), hint: hint);
      if (!mounted) return;
      _summary.text = m.title;
      _description.text = m.description;
    } catch (e) {
      if (mounted) _snack('No se pudo escribir el mensaje: $e');
    } finally {
      if (mounted) setState(() => _drafting = false);
    }
  }

  Future<void> _commit() async {
    setState(() => _committing = true);
    try {
      final (whole, parts) = _marked();
      final used = <String, List<String>>{};
      for (final r in _rows) {
        if (_included(r.$1, r.$2)) used.putIfAbsent(r.$1, () => []).add(r.$2.path);
      }
      await commit(
        widget.repo,
        [
          for (final f in whole) ...[f.path, ?f.oldPath],
        ],
        _summary.text.trim(),
        _description.text,
        identity: widget.account?.identityArgs ?? const [],
        partial: {for (final e in parts.entries) e.key: selectHunks(e.value.$1, e.value.$2)!},
      );
      // El grupo viaja con el commit (Historial, y la cabecera no queda vacía).
      final hash = (await git(['rev-parse', 'HEAD'], cwd: widget.repo)).trim();
      _mutations++;
      _groups = await ChangeGroups.update(widget.repo, (g) {
        g.recordCommit(hash, used);
        g.committed(
          used.keys,
          whole.map((f) => f.path),
          parts.keys,
          changed: [
            for (final f in _files)
              if (!whole.contains(f)) f.path,
          ],
        ); // si vuelven a cambiar, es otro cambio
      });
      _groups = await reconcile(widget.repo);
      _summary.clear();
      _description.clear();
      widget.onCommitted();
    } on GitException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('No se pudo hacer el commit: ${e.message}')));
    } finally {
      if (mounted) setState(() => _committing = false);
    }
  }

  /// Menú del espacio vacío de la lista de cambios: acciones sobre todo el repo.
  Future<void> _listMenu(Offset at) async {
    final rows = _rows;
    final n = _files.length;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: [
        menuItem('group', Icons.create_new_folder_outlined, 'Nuevo grupo de cambios…'),
        if (n > 0) ...[
          menuItem('all', Icons.check_box_outlined, 'Marcar todo para el commit'),
          menuItem('none', Icons.check_box_outline_blank, 'Desmarcar todo'),
        ],
        const PopupMenuDivider(),
        menuItem('folder', Icons.folder_open_outlined, 'Abrir carpeta del repo'),
        menuItem('editor', Icons.code, 'Abrir en el editor'),
        if (n > 0) ...[
          const PopupMenuDivider(),
          menuItem('shelve', Icons.inventory_2_outlined, 'Apartar todos los cambios…'),
          menuItem('discard', Icons.delete_outline, 'Descartar todos los cambios…', danger: true),
        ],
      ],
    );
    switch (action) {
      case 'group':
        await _newGroup();
      case 'all':
        setState(_excluded.clear);
      case 'none':
        setState(() => _excluded.addAll(rows.map((r) => _key(r.$1, r.$2.path))));
      case 'folder':
        widget.onOpenFolder(widget.repo);
      case 'editor':
        widget.onOpenEditor();
      case 'shelve':
        await _shelve(_files);
      case 'discard':
        if (!await _confirmDiscardMany(n == 1 ? '1 archivo' : '$n archivos')) return;
        await _guard(() async {
          for (final f in _files) {
            await widget.trash.save(widget.repo, f.path);
            await discard(widget.repo, f);
          }
          await _forget(_files.map((f) => f.path));
        });
    }
  }

  /// Encabezado de un grupo: se contrae con un clic, su casilla marca o
  /// desmarca todo el grupo para el commit y el clic derecho abre sus acciones.
  int _groupCommits(String group) =>
      group.isEmpty ? 0 : _groups.commits.entries.where((e) => e.value.containsKey(group) && _unpushed.contains(e.key)).length;

  Widget _groupHeader(String group, List<(String, FileChange)> rows) {
    final open = !_groups.collapsed.contains(group);
    final inc = rows.where((r) => _included(r.$1, r.$2)).length;
    final active = group.isNotEmpty && _groups.active == group;
    return GestureDetector(
      onSecondaryTapUp: (d) => _groupMenu(group, d.globalPosition),
      child: InkWell(
        onTap: () => _toggleSection(group),
        child: Container(
          color: Gh.box,
          padding: const EdgeInsets.only(left: 2, right: Gh.sp),
          child: Row(
            children: [
              Icon(open ? Icons.expand_more : Icons.chevron_right, size: 16, color: Gh.textSecondary),
              Checkbox(
                tristate: true,
                value: rows.isEmpty ? false : (inc == rows.length ? true : (inc == 0 ? false : null)),
                onChanged: rows.isEmpty
                    ? null
                    : (_) => setState(() {
                        final keys = rows.map((r) => _key(r.$1, r.$2.path));
                        inc == rows.length ? _excluded.addAll(keys) : _excluded.removeAll(keys);
                      }),
              ),
              Icon(group.isEmpty ? Icons.folder_off_outlined : Icons.folder_special_outlined, size: 14, color: Gh.link),
              const SizedBox(width: 6),
              Expanded(
                child: Tooltip(
                  message: _groups.descriptions[group] ?? '',
                  waitDuration: const Duration(milliseconds: 400),
                  child: Text(
                    group.isEmpty ? 'Sin grupo' : group,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              if (_groups.descriptions[group] case final d? when d.isNotEmpty)
                Tooltip(
                  message: d,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Icon(Icons.notes, size: 13, color: Gh.textSecondary),
                  ),
                ),
              if (active)
                const Tooltip(
                  message: 'Grupo activo: lo nuevo que toques cae aquí',
                  child: Icon(Icons.star, size: 14, color: Gh.modified),
                ),
              if (_groupCommits(group) case final n when n > 0)
                Tooltip(
                  message: n == 1 ? '1 commit de este grupo sin subir' : '$n commits de este grupo sin subir',
                  child: Row(
                    children: [
                      Icon(Icons.arrow_upward, size: 12, color: Gh.textSecondary),
                      Text(
                        '$n',
                        style: TextStyle(fontSize: Gh.fontSizeSm, color: Gh.textSecondary),
                      ),
                    ],
                  ),
                ),
              Text(
                '  ${rows.length}',
                style: TextStyle(fontSize: Gh.fontSizeSm, color: Gh.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _fileRow(String group, FileChange f, {required bool indent}) {
    final split = _groupsOf(f).length > 1;
    final key = _key(group, f.path);
    return GhRow(
      selected: (f.path == _selected && group == _selGroup) || _picked.contains(key),
      onTap: () => _tapRow(group, f),
      // Clic derecho sobre una selección de varias filas: acciones por lotes.
      onSecondary: (at) => _picked.length > 1 && _picked.contains(key) ? _batchMenu(at) : _fileMenu(f, at),
      child: Row(
        children: [
          if (indent) const SizedBox(width: 18),
          Checkbox(
            value: _included(group, f),
            onChanged: (v) => setState(() => v! ? _excluded.remove(_key(group, f.path)) : _excluded.add(_key(group, f.path))),
          ),
          Expanded(
            child: Tooltip(
              message: split ? '${f.path}\nRepartido: aquí solo se ven los bloques de este grupo' : f.path,
              waitDuration: const Duration(seconds: 1),
              child: Text(f.path, overflow: TextOverflow.ellipsis),
            ),
          ),
          if (split)
            Padding(
              padding: EdgeInsets.only(left: 4),
              child: Icon(Icons.call_split, size: 12, color: Gh.textSecondary),
            ),
          const SizedBox(width: 4),
          statusIcon(f.status),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final n = _files.length;
    final rows = _rows;
    final checked = rows.where((r) => _included(r.$1, r.$2)).length;
    final grouped = _groups.names.isNotEmpty;
    // Elementos de la lista: encabezados de grupo (String) y filas (grupo, archivo).
    final items = <Object>[
      for (final g in grouped ? _sections : const [''])
        if (!grouped || g.isNotEmpty || rows.any((r) => r.$1 == g)) ...[
          if (grouped) g,
          if (!_groups.collapsed.contains(g) || !grouped) ...rows.where((r) => r.$1 == g),
        ],
    ];
    final sidebar = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_merge != MergeState.none) _mergeBanner(),
        Container(
          height: Gh.rowHeight,
          padding: const EdgeInsets.symmetric(horizontal: Gh.sp / 2),
          decoration: BoxDecoration(
            color: Gh.boxAlt,
            border: Border(bottom: Gh.divider),
          ),
          child: Row(
            children: [
              Checkbox(
                tristate: true,
                value: n == 0 ? false : (checked == rows.length ? true : (checked == 0 ? false : null)),
                onChanged: n == 0
                    ? null
                    : (_) => setState(
                        () => checked == rows.length ? _excluded.addAll(rows.map((r) => _key(r.$1, r.$2.path))) : _excluded.clear(),
                      ),
              ),
              Expanded(child: Text(n == 1 ? '1 archivo cambiado' : '$n archivos cambiados', textAlign: TextAlign.center)),
              IconButton(
                tooltip: 'Nuevo grupo de cambios',
                iconSize: 16,
                visualDensity: VisualDensity.compact,
                onPressed: () => _newGroup(),
                icon: const Icon(Icons.create_new_folder_outlined),
              ),
            ],
          ),
        ),
        Expanded(
          // Clic derecho en el espacio vacío (las filas y encabezados tienen el suyo).
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onSecondaryTapUp: (d) => _listMenu(d.globalPosition),
            child: ListView.builder(
              itemCount: items.length,
              itemExtent: Gh.rowHeight,
              itemBuilder: (_, i) => switch (items[i]) {
                final String g => _groupHeader(g, rows.where((r) => r.$1 == g).toList()),
                final (String, FileChange) r => _fileRow(r.$1, r.$2, indent: grouped),
                _ => const SizedBox(),
              },
            ),
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
      ], true),
      (_, null, _) => emptyState('Selecciona un archivo', 'Elige un archivo de la lista para ver sus cambios. Esc vuelve aquí.', const [], true),
      (_, final f?, _) when f.status == FileStatus.conflicted => _conflictView(f),
      // Imágenes: antes (último commit) y después (lo que hay en disco).
      (_, final f?, _) when isImagePath(f.path) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          fileHeader(f),
          Expanded(
            child: ImageDiff(
              key: ValueKey((f.path, widget.tick)),
              before: f.status == FileStatus.added ? null : () => blobAt(widget.repo, 'HEAD', f.oldPath ?? f.path),
              after: f.status == FileStatus.deleted ? null : () => File('${widget.repo}/${f.path}').readAsBytes(),
            ),
          ),
        ],
      ),
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
      decoration: BoxDecoration(
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
            enabled: !_drafting,
            style: const TextStyle(fontSize: Gh.fontSize),
            decoration: InputDecoration(
              hintText: _drafting ? 'La IA está escribiendo…' : 'Resumen (obligatorio)',
              suffixIcon: !(widget.summaries?.enabled ?? false)
                  ? null
                  : _drafting
                  ? const Padding(
                      padding: EdgeInsets.all(10),
                      child: SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                    )
                  : IconButton(
                      tooltip: 'Escribir el mensaje con IA (solo lo marcado)',
                      iconSize: 16,
                      onPressed: checked == 0 ? null : _draftMessage,
                      icon: const Icon(Icons.auto_awesome_outlined),
                    ),
            ),
          ),
          const SizedBox(height: Gh.sp),
          TextField(
            controller: _description,
            enabled: !_drafting,
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
                      : () {
                          final (whole, parts) = _marked();
                          _shelve([...whole, ..._files.where((f) => parts.containsKey(f.path))], parts: parts);
                        },
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
    this.editorCommand = '',
    this.summaries,
    this.onOpenSession,
    this.focusHash,
  });
  final String repo;
  final int ahead;

  /// Commit a abrir al entrar (elegido en la pestaña Resúmenes); puede no
  /// estar en la rama actual.
  final String? focusHash;
  final int tick;
  final Widget Function(Widget sidebar, Widget main) layout;

  /// Algo cambió el repo (revertir, deshacer): el Shell refresca rama y cambios.
  final VoidCallback onChanged;
  final Account? account;
  final String? originUrl;
  final String editorCommand;

  /// Resúmenes con IA; null o apagada = no se muestra el panel.
  final SummaryApi? summaries;

  /// Retoma la sesión de Claude Code (por su id) que maneja un grupo.
  final void Function(String sessionId)? onOpenSession;

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
  final _fileFilter = TextEditingController(); // busca entre los archivos del commit elegido
  CommitSummary? _summary;
  ({Commit? before, Commit? after}) _related = (before: null, after: null); // mismo trabajo en otros commits
  String? _summaryError; // null = cargando o sin pedir
  Map<String, Map<String, List<String>>> _commitGroups = {}; // hash -> grupo -> sus archivos en el commit
  // Grupos contraídos en la lista de archivos del commit ('' = "Sin grupo"). Se
  // mantienen al pasar de un commit a otro: si cierras "Config", sigue cerrado.
  final _closedGroups = <String>{};
  Map<String, String> _groupSessions = {}; // sesión de Claude Code -> su grupo
  Map<String, String> _groupDescriptions = {}; // grupo -> de qué se trata

  @override
  void initState() {
    super.initState();
    _fileFilter.addListener(() => setState(() {}));
    escapeTick.addListener(_deselect);
    _load();
  }

  void _deselect() {
    if (_selected != null) setState(() => _selected = null);
  }

  @override
  void didUpdateWidget(HistoryPane old) {
    super.didUpdateWidget(old);
    if (old.tick != widget.tick) _load();
  }

  @override
  void dispose() {
    escapeTick.removeListener(_deselect);
    _searchDebounce?.cancel();
    _fileFilter.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final (commits, groups) = await (log(widget.repo), ChangeGroups.load(widget.repo)).wait;
    if (!mounted) return;
    setState(() {
      _commits = commits;
      _commitGroups = groups.commits;
      _groupSessions = groups.sessions;
      _groupDescriptions = groups.descriptions;
      _hasMore = commits.length == logPage;
    });
    if (_query.trim().isNotEmpty) _search(_query);
    final focus = _selected == null && widget.focusHash != null
        ? commits.where((c) => c.hash == widget.focusHash).firstOrNull ?? await commitByHash(widget.repo, widget.focusHash!)
        : null;
    if (!mounted) return;
    if (_selected == null && widget.focusHash != null && focus == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Ese commit no está en este repo todavía: trae los cambios (fetch).')));
    }
    // Como en Cambios: no se abre el primero solo, solo el que ya estaba o el pedido.
    final keep = focus ?? commits.where((c) => c.hash == _selected?.hash).firstOrNull;
    if (keep != null) _select(keep);
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

  /// Archivos del commit. Si se hizo con grupos de cambios van agrupados como
  /// en Cambios (un commit grande se lee por partes); un archivo repartido sale
  /// en cada grupo.
  Widget _fileList(List<FileChange> files) {
    if (files.isEmpty) {
      return Padding(
        padding: EdgeInsets.all(Gh.sp),
        child: Text('Ningún archivo coincide.', style: TextStyle(color: Gh.textSecondary)),
      );
    }
    final groups = _commitGroups[_selected?.hash] ?? const <String, List<String>>{};
    final items = <Object>[];
    if (groups.values.any((ps) => ps.isNotEmpty)) {
      final placed = <String>{};
      for (final e in groups.entries) {
        final mine = [
          for (final f in files)
            if (e.value.contains(f.path)) f,
        ];
        if (mine.isEmpty) continue;
        items.addAll([(e.key, mine.length), if (!_closedGroups.contains(e.key)) ...mine]);
        placed.addAll(mine.map((f) => f.path));
      }
      final rest = files.where((f) => !placed.contains(f.path)).toList();
      if (rest.isNotEmpty) items.addAll([('', rest.length), if (!_closedGroups.contains('')) ...rest]);
    } else {
      items.addAll(files);
    }
    return ListView.builder(
      itemCount: items.length,
      itemExtent: Gh.rowHeight,
      itemBuilder: (_, i) {
        final item = items[i];
        if (item case (final String g, final int n)) {
          final open = !_closedGroups.contains(g);
          return InkWell(
            onTap: () => setState(() => open ? _closedGroups.add(g) : _closedGroups.remove(g)),
            child: Container(
              color: Gh.box,
              padding: const EdgeInsets.only(left: 2, right: Gh.sp),
              child: Row(
                children: [
                  Icon(open ? Icons.expand_more : Icons.chevron_right, size: 16, color: Gh.textSecondary),
                  const SizedBox(width: 2),
                  Icon(g.isEmpty ? Icons.folder_off_outlined : Icons.folder_special_outlined, size: 14, color: Gh.link),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      g.isEmpty ? 'Sin grupo' : g,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  Text(
                    '$n',
                    style: TextStyle(fontSize: Gh.fontSizeSm, color: Gh.textSecondary),
                  ),
                ],
              ),
            ),
          );
        }
        final f = item as FileChange;
        return GhRow(
          selected: f == _file,
          onTap: () => _selectFile(f),
          onSecondary: (at) => _commitFileMenu(f, at),
          child: Row(
            children: [
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
    );
  }

  Future<void> _select(Commit c) async {
    if (_selected?.hash != c.hash) _fileFilter.clear();
    setState(() => _selected = c);
    _loadSummary(c);
    final files = await commitFiles(widget.repo, c.hash);
    if (!mounted || _selected != c) return;
    setState(() {
      _files = files;
      _related = (before: null, after: null);
    });
    if (files.isNotEmpty) _selectFile(files.first);
    final related = await relatedCommits(widget.repo, c, files);
    if (mounted && _selected == c) setState(() => _related = related);
  }

  /// "Continúa a…" / "Sigue en…": otro commit del mismo trabajo, clicable.
  Widget _relatedLink(String label, Commit c) => Padding(
    padding: const EdgeInsets.only(top: 4),
    child: InkWell(
      onTap: () => _select(c),
      child: Text.rich(
        TextSpan(
          style: Theme.of(context).textTheme.bodySmall,
          children: [
            TextSpan(text: '$label '),
            TextSpan(
              text: '${c.shortHash} · ${c.summary}',
              style: TextStyle(color: Gh.link),
            ),
            TextSpan(text: ' (${timeAgo(c.date)})'),
          ],
        ),
        overflow: TextOverflow.ellipsis,
      ),
    ),
  );

  /// Pide el resumen de la IA al abrir el commit (si ya existe, la API lo
  /// devuelve sin volver a gastar tokens).
  Future<void> _loadSummary(Commit c) async {
    final api = widget.summaries;
    setState(() {
      _summary = null;
      _summaryError = null;
    });
    if (api == null || !api.enabled) return;
    try {
      final s = await api.summary(widget.repo, c);
      if (mounted && _selected == c) setState(() => _summary = s);
    } catch (e) {
      if (mounted && _selected == c) setState(() => _summaryError = '$e');
    }
  }

  Widget _summaryPanel(Commit c) {
    final style = Theme.of(context).textTheme.bodySmall;
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 180),
      padding: const EdgeInsets.fromLTRB(Gh.sp, 6, Gh.sp, 6),
      decoration: BoxDecoration(
        color: Gh.box,
        border: Border(bottom: Gh.divider),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.only(top: 1, right: 6),
            child: Icon(Icons.auto_awesome_outlined, size: 14, color: Gh.textSecondary),
          ),
          Expanded(
            child: switch ((_summary, _summaryError)) {
              (final s?, _) => SingleChildScrollView(
                child: SelectableText(s.truncated ? '${s.text}\n\n(El diff era muy grande: se resumió una parte.)' : s.text, style: style),
              ),
              (_, final e?) => Row(
                children: [
                  Expanded(
                    child: Text(e, style: style?.copyWith(color: Gh.deleted)),
                  ),
                  TextButton(onPressed: () => _loadSummary(c), child: const Text('Reintentar')),
                ],
              ),
              _ => Text('Resumiendo con IA…', style: style),
            },
          ),
        ],
      ),
    );
  }

  /// Clic derecho en un archivo de un commit.
  Future<void> _commitFileMenu(FileChange f, Offset at) async {
    final exists = File('${widget.repo}/${f.path}').existsSync();
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: [
        menuItem('copy', Icons.content_copy, 'Copiar ruta'),
        if (exists) ...[
          menuItem('editor', Icons.code, 'Abrir la versión actual en el editor'),
          menuItem('folder', Icons.folder_open_outlined, 'Abrir carpeta del archivo'),
        ],
      ],
    );
    switch (action) {
      case 'copy':
        await Clipboard.setData(ClipboardData(text: f.path));
      case 'editor':
        try {
          await openInEditor(widget.editorCommand, widget.repo, file: f.path);
        } catch (_) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('No se encontró el editor "${widget.editorCommand}".')));
          }
        }
      case 'folder':
        await openFolder(File('${widget.repo}/${f.path}').parent.path);
    }
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
        ..._sessionItems(_commitGroups[c.hash]?.keys ?? const [], _groupSessions),
        const PopupMenuDivider(),
        if (isLast && unpushed) menuItem('undo', Icons.undo, 'Deshacer este commit (vuelve a Cambios)'),
        menuItem('revert', Icons.settings_backup_restore, 'Revertir este commit…', danger: true),
      ],
    );
    if (!mounted) return;
    try {
      switch (action) {
        case final a? when a.startsWith('session:'):
          widget.onOpenSession?.call(a.substring(8));
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
                    for (final g in _commitGroups[c.hash]?.keys ?? const <String>[])
                      Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: Tooltip(message: _groupDescriptions[g] == null ? 'Grupo de cambios' : 'Grupo de cambios: ${_groupDescriptions[g]}', child: groupChip(g)),
                      ),
                    if (unpushed.contains(c.hash))
                      Tooltip(
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
        Divider(height: 1, color: Gh.border),
        Expanded(child: list),
      ],
    );

    final c = _selected;
    final main = c == null
        ? emptyState(_commits.isEmpty ? 'Sin commits' : 'Elige un commit', _commits.isEmpty ? null : 'Mira qué cambió y su resumen. Esc vuelve aquí.', const [], true)
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.all(Gh.sp),
                decoration: BoxDecoration(
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
                    if (_related.before case final b?) _relatedLink('Continúa a', b),
                    if (_related.after case final a?) _relatedLink('Sigue en', a),
                  ],
                ),
              ),
              if (widget.summaries?.enabled ?? false) _summaryPanel(c),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      width: 250,
                      child: Builder(
                        builder: (_) {
                          // Filtro por ruta: si hay varias palabras deben estar todas (p. ej. "api helper").
                          final words = _fileFilter.text.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
                          final shown = [
                            for (final f in _files)
                              if (words.every((w) => '${f.path} ${f.oldPath ?? ''}'.toLowerCase().contains(w))) f,
                          ];
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Padding(
                                padding: const EdgeInsets.all(6),
                                child: TextField(
                                  controller: _fileFilter,
                                  style: const TextStyle(fontSize: Gh.fontSize),
                                  decoration: InputDecoration(
                                    isDense: true,
                                    hintText: _files.length == 1 ? 'Buscar en 1 archivo' : 'Buscar en ${_files.length} archivos',
                                    prefixIcon: const Icon(Icons.search, size: 16),
                                    suffixIcon: _fileFilter.text.isEmpty
                                        ? null
                                        : IconButton(
                                            iconSize: 14,
                                            tooltip: 'Limpiar',
                                            onPressed: _fileFilter.clear,
                                            icon: const Icon(Icons.close),
                                          ),
                                  ),
                                  onSubmitted: (_) => shown.isEmpty ? null : _selectFile(shown.first),
                                ),
                              ),
                              if (_fileFilter.text.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                                  child: Text(
                                    '${shown.length} de ${_files.length}',
                                    style: TextStyle(fontSize: Gh.fontSizeSm, color: Gh.textSecondary),
                                  ),
                                ),
                              Expanded(child: _fileList(shown)),
                            ],
                          );
                        },
                      ),
                    ),
                    VerticalDivider(width: 1, thickness: 1, color: Gh.border),
                    Expanded(
                      child: switch ((_file, _diff)) {
                        // Imágenes: antes (primer padre) y después (el commit).
                        (final f?, _) when isImagePath(f.path) => ImageDiff(
                          key: ValueKey((_selected?.hash, f.path)),
                          before: f.status == FileStatus.added
                              ? null
                              : () => blobAt(widget.repo, '${_selected!.hash}^', f.oldPath ?? f.path),
                          after: f.status == FileStatus.deleted ? null : () => blobAt(widget.repo, _selected!.hash, f.path),
                        ),
                        (final f?, final d?) => DiffView(d, path: f.path),
                        _ => const SizedBox(),
                      },
                    ),
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

/// Etiqueta chica con el nombre de un grupo de cambios.
Widget groupChip(String name) => Container(
  constraints: const BoxConstraints(maxWidth: 140),
  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
  decoration: BoxDecoration(
    border: Border.all(color: Gh.border),
    borderRadius: BorderRadius.circular(Gh.radius),
  ),
  child: Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(Icons.folder_special_outlined, size: 11, color: Gh.link),
      const SizedBox(width: 3),
      Flexible(
        child: Text(
          name,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: Gh.fontSizeSm, color: Gh.textSecondary),
        ),
      ),
    ],
  ),
);

/// Opciones "Abrir la sesión de Claude" para las sesiones de `mickhub` que
/// manejan [groups] ([sessions]: id de sesión -> grupo). El valor es `session:<id>`.
List<PopupMenuEntry<String>> _sessionItems(Iterable<String> groups, Map<String, String> sessions) {
  final gs = groups.toList();
  final items = <PopupMenuEntry<String>>[
    for (final e in sessions.entries)
      if (gs.contains(e.value))
        menuItem(
          'session:${e.key}',
          Icons.smart_toy_outlined,
          gs.length > 1 ? 'Abrir la sesión de Claude de "${e.value}"' : 'Abrir la sesión de Claude que lo maneja',
        ),
  ];
  return items.isEmpty ? items : [const PopupMenuDivider(), ...items];
}
