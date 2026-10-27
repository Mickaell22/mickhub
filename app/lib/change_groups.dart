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
  }) : names = names ?? [],
       files = files ?? {},
       hunks = hunks ?? {},
       collapsed = collapsed ?? {};

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

  factory ChangeGroups.fromJson(Map<String, dynamic> j) => ChangeGroups(
    names: List<String>.from(j['groups'] ?? const []),
    active: j['active'],
    files: Map<String, String>.from(j['files'] ?? const {}),
    hunks: {for (final e in ((j['hunks'] ?? const {}) as Map).entries) e.key as String: Map<String, String>.from(e.value as Map)},
    collapsed: Set<String>.from(j['collapsed'] ?? const []),
  );

  Map<String, dynamic> toJson() => {'groups': names, 'active': active, 'files': files, 'hunks': hunks, 'collapsed': collapsed.toList()};

  static Future<File> _file(String repo) async =>
      File('${(await git(['rev-parse', '--absolute-git-dir'], cwd: repo)).trim()}/mickhub/grupos.json');

  static Future<ChangeGroups> load(String repo) async {
    try {
      final f = await _file(repo);
      if (!f.existsSync()) return ChangeGroups();
      return ChangeGroups.fromJson(jsonDecode(await f.readAsString()) as Map<String, dynamic>);
    } catch (_) {
      return ChangeGroups(); // JSON roto o repo raro: se empieza sin grupos
    }
  }

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
  /// nuevos caen en el grupo activo (o quedan sin grupo) y se olvidan los que
  /// ya no cambian. Sin grupos no hace nada, para no escribir el JSON en repos
  /// donde no se usan. Devuelve true si algo cambió.
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
      if (!now.contains(p) || !known.contains(files[p])) {
        files.remove(p);
        dirty = true;
      }
    }
    for (final p in hunks.keys.toList()) {
      hunks[p]!.removeWhere((_, g) => !known.contains(g));
      if (!now.contains(p) || hunks[p]!.isEmpty) {
        hunks.remove(p);
        dirty = true;
      }
    }
    for (final p in now) {
      if (!files.containsKey(p)) {
        files[p] = active ?? '';
        dirty = true;
      }
    }
    return dirty;
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
