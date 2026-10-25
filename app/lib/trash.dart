import 'dart:convert';
import 'dart:io';

/// Papelera propia de MickHub: antes de descartar cambios se guarda una copia del
/// archivo, para poder restaurarlo. Igual en Windows y Linux (no usa la del
/// sistema). Cada entrada es una carpeta con `meta.json` y `contenido`.
// ponytail: guarda el archivo entero; se vacía sola con [purge] al abrir la app.
class TrashEntry {
  TrashEntry(this.dir, this.repo, this.path, this.deletedAt);
  final Directory dir;
  final String repo, path;
  final DateTime deletedAt;

  File get content => File('${dir.path}/contenido');
}

class Trash {
  Trash(this.root);
  final Directory root;

  /// Copia el archivo [path] de [repo] a la papelera. No hace nada si el archivo
  /// no existe en disco (p. ej. un borrado: descartarlo lo devuelve, no se pierde nada).
  Future<void> save(String repo, String path) async {
    final src = File('$repo/$path');
    if (!src.existsSync()) return;
    final now = DateTime.now();
    final dir = Directory('${root.path}/${now.microsecondsSinceEpoch}');
    await dir.create(recursive: true);
    await src.copy('${dir.path}/contenido');
    await File('${dir.path}/meta.json').writeAsString(jsonEncode({'repo': repo, 'path': path, 'deletedAt': now.toIso8601String()}));
  }

  /// Entradas de la papelera, las más nuevas primero. Si se da [repo], solo las suyas.
  List<TrashEntry> list({String? repo}) {
    if (!root.existsSync()) return [];
    final out = <TrashEntry>[];
    for (final d in root.listSync().whereType<Directory>()) {
      final meta = File('${d.path}/meta.json');
      if (!meta.existsSync()) continue;
      final j = jsonDecode(meta.readAsStringSync()) as Map<String, dynamic>;
      if (repo != null && j['repo'] != repo) continue;
      out.add(TrashEntry(d, j['repo'], j['path'], DateTime.parse(j['deletedAt'])));
    }
    return out..sort((a, b) => b.deletedAt.compareTo(a.deletedAt));
  }

  /// Devuelve la copia a su lugar (pisando lo que haya) y la saca de la papelera.
  Future<void> restore(TrashEntry e) async {
    final dest = File('${e.repo}/${e.path}');
    await dest.parent.create(recursive: true);
    await e.content.copy(dest.path);
    await e.dir.delete(recursive: true);
  }

  Future<void> delete(TrashEntry e) => e.dir.delete(recursive: true);

  /// Borra lo descartado hace más de [maxAge]. Devuelve cuántas entradas borró.
  Future<int> purge(Duration maxAge, {DateTime? now}) async {
    final limit = (now ?? DateTime.now()).subtract(maxAge);
    final old = list().where((e) => e.deletedAt.isBefore(limit)).toList();
    for (final e in old) {
      await delete(e);
    }
    return old.length;
  }
}
