import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'git.dart';

/// Grupos de cambios, como las changelists de JetBrains: repartir los cambios
/// de un repo por tarea ("Buscador", "Reportes"...) para commitear, apartar o
/// proteger por grupo en vez de archivo por archivo.
///
/// Un archivo va entero a un grupo, salvo que se repartan sus bloques: entonces
/// cada bloque va al suyo y el archivo aparece en los dos grupos. Los bloques se
/// reconocen por su contenido ([hunkKeys]), así siguen en su grupo aunque
/// cambien de línea. Lo nuevo que se toca cae en el grupo [active].
///
/// Se guarda en `<.git>/mickhub/grupos.json`: es local, nunca se sube, y Claude
/// Code lo puede editar (la app lo relee al refrescar).
class ChangeGroups {
  ChangeGroups({
    List<String>? names,
    this.active,
    Map<String, String>? files,
    Map<String, Map<String, String>>? hunks,
    Set<String>? collapsed,
    Map<String, String>? sessions,
    Map<String, Map<String, List<String>>>? commits,
  }) : names = names ?? [],
       files = files ?? {},
       hunks = hunks ?? {},
       collapsed = collapsed ?? {},
       sessions = sessions ?? {},
       commits = commits ?? {};

  /// Grupos en el orden en que se muestran.
  List<String> names;

  /// Grupo donde caen los archivos nuevos que se tocan (null = "Sin grupo").
  String? active;

  /// Ruta -> grupo del archivo entero ('' = sin grupo, puesto a propósito o
  /// porque ya estaba cuando no había grupo activo; así no se lo lleva el activo).
  Map<String, String> files;

  /// Ruta -> (clave de bloque -> grupo), solo para archivos repartidos. Un
  /// bloque sin entrada sigue al grupo del archivo.
  Map<String, Map<String, String>> hunks;

  /// Grupos contraídos en la lista ('' = "Sin grupo").
  Set<String> collapsed;

  /// Sesión de Claude Code -> su grupo (`bin/mickhub.dart`): lo que edita
  /// cada sesión cae solo en su grupo, así dos sesiones a la vez no se mezclan.
  Map<String, String> sessions;

  /// Hash de commit -> (grupo -> archivos suyos que entraron). El grupo "viaja"
  /// con el commit: el Historial muestra sus archivos agrupados aunque ya esté
  /// subido, y el grupo no se ve vacío mientras tenga commits sin subir. Se
  /// conserva aunque el grupo se borre.
  Map<String, Map<String, List<String>>> commits;

  /// Anota qué archivos de cada grupo entraron en [hash] ("Sin grupo" no se anota).
  // ponytail: solo los últimos 5000 commits; los más viejos pierden la etiqueta.
  void recordCommit(String hash, Map<String, Iterable<String>> byGroup) {
    final m = {
      for (final e in byGroup.entries)
        if (e.key.isNotEmpty) e.key: e.value.toSet().toList(),
    };
    if (m.isEmpty) return;
    commits[hash] = m;
    while (commits.length > 5000) {
      commits.remove(commits.keys.first);
    }
  }

  void _relabelCommits(String from, String to) {
    for (final m in commits.values) {
      final moved = m.remove(from);
      if (moved != null) m[to] = {...?m[to], ...moved}.toList();
    }
  }

  factory ChangeGroups.fromJson(Map<String, dynamic> j) => ChangeGroups(
    names: List<String>.from(j['groups'] ?? const []),
    active: j['active'],
    files: Map<String, String>.from(j['files'] ?? const {}),
    hunks: {for (final e in ((j['hunks'] ?? const {}) as Map).entries) e.key as String: Map<String, String>.from(e.value as Map)},
    collapsed: Set<String>.from(j['collapsed'] ?? const []),
    sessions: Map<String, String>.from(j['sessions'] ?? const {}),
    commits: {
      for (final e in ((j['commits'] ?? const {}) as Map).entries)
        e.key as String: e.value is List
            ? {for (final g in e.value as List) g as String: <String>[]} // formato del primer día: solo nombres
            : {for (final g in (e.value as Map).entries) g.key as String: List<String>.from(g.value as List)},
    },
  ).._extra = Map.of(j);

  /// Todo lo leído del JSON, también claves que esta versión no conoce: se
  /// vuelven a escribir para no borrarlas (una app vieja borraba `sessions` y
  /// `commits` de `mickhub` al guardar).
  Map<String, dynamic> _extra = {};

  Map<String, dynamic> toJson() => {
    ..._extra,
    'groups': names,
    'active': active,
    'files': files,
    'hunks': hunks,
    'collapsed': collapsed.toList(),
    'sessions': sessions,
    'commits': commits,
  };

  /// Carpeta `<.git>/mickhub` del repo (grupos, candado y fotos de sesiones).
  static Future<Directory> dir(String repo) async =>
      Directory('${(await git(['rev-parse', '--absolute-git-dir'], cwd: repo)).trim()}/mickhub');

  static Future<File> _file(String repo) async => File('${(await dir(repo)).path}/grupos.json');

  /// Avisa cuando el JSON cambia en disco (Claude Code moviendo cambios).
  static Future<StreamSubscription<FileSystemEvent>> watch(String repo, void Function() onChange) async {
    final f = await _file(repo);
    await f.parent.create(recursive: true);
    return f.parent
        .watch()
        .where((e) => e.path == f.path || (e is FileSystemMoveEvent && e.destination == f.path))
        .listen((_) => onChange());
  }

  static Future<ChangeGroups> load(String repo) async {
    try {
      final f = await _file(repo);
      if (!f.existsSync()) return ChangeGroups();
      return ChangeGroups.fromJson(jsonDecode(await f.readAsString()) as Map<String, dynamic>);
    } catch (_) {
      return ChangeGroups(); // JSON roto o repo raro: se empieza sin grupos
    }
  }

  /// Corre [body] con el candado `grupos.lock` del repo: la app y cada
  /// `mickhub` (una sesión de Claude por proceso) escriben el mismo JSON.
  static Future<T> withLock<T>(String repo, Future<T> Function(Directory dir) body) async {
    final d = await dir(repo);
    await d.create(recursive: true);
    final lock = File('${d.path}/grupos.lock');
    for (var i = 0; ; i++) {
      try {
        lock.createSync(exclusive: true);
        break;
      } on FileSystemException {
        final stale = lock.existsSync() && DateTime.now().difference(lock.statSync().modified).inSeconds > 10;
        if (stale || i > 250) {
          try {
            lock.deleteSync(); // quedó de un proceso que murió
          } on FileSystemException {
            // otro lo borró primero
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
    try {
      return await body(d);
    } finally {
      try {
        lock.deleteSync();
      } on FileSystemException {
        // ya no estaba
      }
    }
  }

  /// Lee lo último del disco, le aplica [change] y lo guarda si cambió, todo
  /// con el candado: así no se pisa lo que otro proceso escribió entre medio
  /// (pasaba: la app guardaba una lectura vieja encima de un hook de mickhub).
  static Future<ChangeGroups> update(String repo, FutureOr<void> Function(ChangeGroups g) change) => withLock(repo, (_) async {
    final g = await load(repo);
    final before = jsonEncode(g.toJson());
    await change(g);
    if (jsonEncode(g.toJson()) != before) await g.save(repo);
    return g;
  });

  /// Escribe atómico (temporal + rename), por si Claude Code lo lee a la vez.
  Future<void> save(String repo) async {
    final f = await _file(repo);
    await f.parent.create(recursive: true);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(toJson()));
    await tmp.rename(f.path);
  }

  /// Grupo del archivo entero ('' = sin grupo).
  String groupOf(String path) => files[path] ?? '';

  /// Pone al día las asignaciones con los archivos que tienen cambios: los
  /// nuevos caen en el grupo activo (o quedan sin grupo). Lo asignado a un grupo,
  /// "Sin grupo" incluido, **se recuerda aunque ahora no tenga cambios**: al apartar o al cambiar de
  /// rama (GitHub Desktop aparta solo) los cambios se van y vuelven, y deben
  /// volver a su grupo. Se olvida con [forget], al commitear o descartar. Sin
  /// grupos no hace nada, para no escribir el JSON en repos donde no se usan.
  /// Devuelve true si algo cambió.
  // ponytail: si se commitea fuera de MickHub, el archivo vuelve a su grupo la
  // próxima vez que cambie (se mueve con un clic). Upgrade: guardar con la
  // asignación el hash del blob para saber si es el mismo cambio.
  bool sync(Iterable<String> changed) {
    if (names.isEmpty && files.isEmpty && hunks.isEmpty) return false;
    final now = changed.toSet();
    var dirty = false;
    final known = {...names, ''};
    if (active != null && !known.contains(active)) {
      active = null;
      dirty = true;
    }
    for (final p in files.keys.toList()) {
      if (!known.contains(files[p])) {
        files[p] = ''; // su grupo ya no existe
        dirty = true;
      }
    }
    for (final p in hunks.keys.toList()) {
      final before = hunks[p]!.length;
      hunks[p]!.removeWhere((_, g) => !known.contains(g));
      if (hunks[p]!.isEmpty) hunks.remove(p);
      if (hunks[p]?.length != before) dirty = true;
    }
    for (final p in now) {
      if (!files.containsKey(p)) {
        files[p] = active ?? '';
        dirty = true;
      }
    }
    return dirty;
  }

  /// Olvida el grupo de [paths]: se commitearon o descartaron, así que si
  /// vuelven a cambiar es otro cambio (va al grupo activo).
  void forget(Iterable<String> paths) {
    for (final p in paths) {
      files.remove(p);
      hunks.remove(p);
    }
  }

  /// Después de un commit de [groups]: olvida lo commiteado ([whole] enteros,
  /// los bloques de esos grupos en [partial]) y quita de la lista los grupos que
  /// quedaron sin cambios (pedido del dueño: no dejar grupos vacíos). Su
  /// etiqueta en [commits] y su sesión se conservan: si la sesión vuelve a
  /// editar, el grupo reaparece con el mismo nombre.
  void committed(Iterable<String> groups, Iterable<String> whole, Iterable<String> partial) {
    final gs = groups.where((g) => g.isNotEmpty).toSet();
    forget(whole);
    for (final p in partial) {
      final m = hunks[p];
      if (m == null) continue;
      m.removeWhere((_, g) => gs.contains(g));
      if (m.isEmpty) {
        hunks.remove(p);
      } else if (gs.contains(files[p])) {
        files[p] = m.values.first; // ponytail: lo que queda del archivo pasa al grupo de otro bloque
      }
    }
    for (final g in gs) {
      if (files.containsValue(g) || hunks.values.any((m) => m.containsValue(g))) continue;
      names.remove(g);
      if (active == g) active = null;
      collapsed.remove(g);
    }
  }

  /// Grupo de cada bloque de [diff] (de [path]), en orden.
  List<String> hunkGroups(String path, String diff) {
    final own = hunks[path] ?? const {};
    return [for (final k in hunkKeys(diff)) own[k] ?? groupOf(path)];
  }

  /// Mueve el archivo entero a [group] ('' = sin grupo) y deshace su reparto.
  void moveFile(String path, String group) {
    hunks.remove(path);
    files[path] = group;
  }

  /// Crea un grupo y lo deja activo. Los archivos que ya tienen cambios quedan
  /// donde estaban (los sin grupo, sin grupo); [take] se mueven al nuevo.
  void add(String name, Iterable<String> changed, {Iterable<String> take = const []}) {
    for (final p in changed) {
      files.putIfAbsent(p, () => '');
    }
    names = [...names, name];
    active = name;
    for (final p in take) {
      moveFile(p, name);
    }
  }

  /// Mueve algunos bloques de un archivo a [group]. Si al final todos sus
  /// bloques quedan en el mismo grupo, el archivo deja de estar repartido.
  void moveHunks(String path, String diff, Set<int> indices, String group) {
    final keys = hunkKeys(diff);
    final current = hunkGroups(path, diff);
    final next = [for (var i = 0; i < keys.length; i++) indices.contains(i) ? group : current[i]];
    if (next.toSet().length <= 1) return moveFile(path, next.isEmpty ? group : next.first);
    hunks[path] = {
      for (var i = 0; i < keys.length; i++)
        if (next[i] != groupOf(path)) keys[i]: next[i],
    };
  }

  void rename(String from, String to) {
    names = [for (final n in names) n == from ? to : n];
    if (active == from) active = to;
    sessions.updateAll((_, g) => g == from ? to : g);
    _relabelCommits(from, to);
    files.updateAll((_, g) => g == from ? to : g);
    for (final m in hunks.values) {
      m.updateAll((_, g) => g == from ? to : g);
    }
    if (collapsed.remove(from)) collapsed.add(to);
  }

  /// Borra el grupo; sus cambios pasan a "Sin grupo" (no se toca ningún archivo).
  void remove(String group) {
    names.remove(group);
    if (active == group) active = null;
    files.updateAll((_, g) => g == group ? '' : g);
    for (final m in hunks.values) {
      m.removeWhere((_, g) => g == group);
    }
    hunks.removeWhere((_, m) => m.isEmpty);
    collapsed.remove(group);
    sessions.removeWhere((_, g) => g == group);
  }

  /// Pasa todo lo de [from] a [to] (que ya existe) y borra [from].
  void merge(String from, String to) {
    files.updateAll((_, g) => g == from ? to : g);
    for (final m in hunks.values) {
      m.updateAll((_, g) => g == from ? to : g);
    }
    sessions.updateAll((_, g) => g == from ? to : g);
    _relabelCommits(from, to);
    names.remove(from);
    if (active == from) active = to;
    collapsed.remove(from);
  }

  /// Grupo de la sesión [id] de Claude Code; si no tiene, crea "Sesión xxxx".
  String sessionGroup(String id) {
    var g = sessions[id];
    if (g == null) {
      final base = 'Sesión ${id.length > 4 ? id.substring(0, 4) : id}';
      var name = base;
      for (var n = 2; names.contains(name); n++) {
        name = '$base ($n)';
      }
      g = sessions[id] = name;
    }
    if (!names.contains(g)) names = [...names, g];
    return g;
  }

  /// Después de que una sesión editó [path]: los bloques de [diff] que no
  /// estaban en [before] (las claves de antes de editar) son de [group]; los
  /// que ya estaban siguen en el suyo. Así, si el archivo tenía cambios de
  /// otra sesión o del dueño, no se los lleva. Devuelve true si algo cambió.
  bool claim(String path, String diff, Set<String> before, String group) {
    final keys = hunkKeys(diff);
    final old = hunkGroups(path, diff);
    final base = files[path] ?? active ?? '';
    final next = [
      for (var i = 0; i < keys.length; i++)
        if (hunks[path]?[keys[i]] != null) old[i] else if (before.contains(keys[i])) base else group,
    ];
    if (!next.contains(group)) return false; // la edición no dejó bloques nuevos
    final was = jsonEncode([files[path], hunks[path]]);
    if (next.toSet().length == 1) {
      moveFile(path, group);
    } else {
      files[path] = base;
      hunks[path] = {
        for (var i = 0; i < keys.length; i++)
          if (next[i] != base) keys[i]: next[i],
      };
    }
    return was != jsonEncode([files[path], hunks[path]]);
  }
}

/// Clave de cada bloque (`@@`) de un diff: un hash de sus líneas cambiadas, sin
/// números de línea ni contexto, para reconocerlo aunque se mueva en el archivo.
/// Dos bloques idénticos en el mismo archivo se distinguen por su orden.
List<String> hunkKeys(String diff) {
  final keys = <String>[];
  final seen = <String, int>{};
  StringBuffer? cur;
  void close() {
    if (cur == null) return;
    final h = sha1.convert(utf8.encode(cur.toString())).toString().substring(0, 16);
    final n = seen[h] = (seen[h] ?? 0) + 1;
    keys.add(n == 1 ? h : '$h#$n');
  }

  for (final l in diff.split('\n')) {
    if (l.startsWith('@@')) {
      close();
      cur = StringBuffer();
    } else if (cur != null && (l.startsWith('+') || l.startsWith('-'))) {
      cur.writeln(l);
    }
  }
  close();
  return keys;
}
