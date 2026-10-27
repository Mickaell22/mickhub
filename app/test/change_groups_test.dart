import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mickhub/change_groups.dart';
import 'package:mickhub/git.dart';

const _id = ['-c', 'user.name=t', '-c', 'user.email=t@t'];

/// Repo temporal con `app.dart` de 30 líneas commiteado y dos cambios lejanos
/// (dos bloques): arriba la barra de búsqueda, abajo la implementación grande.
Future<(String, List<String>)> repoWithTwoHunks() async {
  final dir = await Directory.systemTemp.createTemp('mickhub_cg');
  addTearDown(() => dir.delete(recursive: true));
  final r = dir.path;
  await git(['init', '-q', '-b', 'Mmoran'], cwd: r);
  final base = [for (var i = 1; i <= 30; i++) 'línea $i'];
  File('$r/app.dart').writeAsStringSync('${base.join('\n')}\n');
  await git(['add', '.'], cwd: r);
  await git([..._id, 'commit', '-q', '-m', 'base'], cwd: r);
  final edited = [...base];
  edited[1] = 'barra de búsqueda';
  edited[25] = 'implementación grande';
  File('$r/app.dart').writeAsStringSync('${edited.join('\n')}\n');
  return (r, edited);
}

void main() {
  test('hunkKeys reconoce un bloque aunque cambie de línea', () {
    const a = '@@ -1,3 +1,3 @@\n x\n-a\n+b\n@@ -20,3 +20,3 @@\n y\n-c\n+d\n';
    const moved = '@@ -5,3 +5,3 @@\n z\n-a\n+b\n';
    expect(hunkKeys(a).length, 2);
    expect(hunkKeys(moved).single, hunkKeys(a).first);
    expect(hunkKeys('@@ -1 +1 @@\n-a\n+b\n@@ -9 +9 @@\n-a\n+b\n').toSet().length, 2); // iguales, distintos por orden
  });

  test('sync: lo nuevo cae en el activo y se olvida lo que ya no cambia', () {
    final g = ChangeGroups(names: ['Buscador', 'Reportes'], active: 'Buscador', files: {'viejo.dart': 'Reportes', 'r.dart': 'Reportes'});
    expect(g.sync(['r.dart', 'nuevo.dart']), isTrue);
    expect(g.files, {'r.dart': 'Reportes', 'nuevo.dart': 'Buscador'});
    expect(g.sync(['r.dart', 'nuevo.dart']), isFalse);
    g.remove('Reportes');
    expect(g.groupOf('r.dart'), '');
    expect(ChangeGroups().sync(['a.dart']), isFalse); // sin grupos no se guarda nada
  });

  test('crear un grupo no se lleva lo que ya estaba sin grupo; solo lo nuevo', () {
    final g = ChangeGroups()..add('Buscador', ['ya.dart', 'llevar.dart'], take: ['llevar.dart']);
    g.sync(['ya.dart', 'llevar.dart', 'nuevo.dart']);
    expect(g.groupOf('ya.dart'), '');
    expect(g.groupOf('llevar.dart'), 'Buscador');
    expect(g.groupOf('nuevo.dart'), 'Buscador');
    g.active = null;
    g.sync(['ya.dart', 'llevar.dart', 'nuevo.dart', 'otro.dart']);
    expect(g.groupOf('otro.dart'), '');
  });

  test('moveHunks reparte un archivo y lo junta si todo vuelve al mismo grupo', () {
    const diff = '@@ -1,3 +1,3 @@\n-a\n+b\n@@ -20,3 +20,3 @@\n-c\n+d\n';
    final g = ChangeGroups(names: ['A', 'B'], files: {'f': 'A'});
    g.moveHunks('f', diff, {1}, 'B');
    expect(g.hunkGroups('f', diff), ['A', 'B']);
    g.rename('B', 'Bis');
    expect(g.hunkGroups('f', diff), ['A', 'Bis']);
    g.moveHunks('f', diff, {1}, 'A');
    expect(g.hunks, isEmpty);
    expect(g.groupOf('f'), 'A');
  });

  test('se guarda en .git y se vuelve a leer', () async {
    final (r, _) = await repoWithTwoHunks();
    final g = ChangeGroups(names: ['A'], active: 'A', files: {'app.dart': 'A'}, collapsed: {''});
    await g.save(r);
    expect(File('$r/.git/mickhub/grupos.json').existsSync(), isTrue);
    final back = await ChangeGroups.load(r);
    expect(back.names, ['A']);
    expect(back.active, 'A');
    expect(back.files, {'app.dart': 'A'});
    expect(back.collapsed, {''});
    expect((await status(r)).map((f) => f.path), ['app.dart']); // no aparece como cambio del repo
  });

  test('commit de un grupo con un archivo repartido: entra solo su bloque', () async {
    final (r, edited) = await repoWithTwoHunks();
    final f = (await status(r)).single;
    final diff = await fileDiff(r, f);
    await commit(
      r,
      const [],
      'barra',
      '',
      identity: _id,
      partial: {
        'app.dart': selectHunks(diff, {0})!,
      },
    );
    final committed = await git(['show', 'HEAD:app.dart'], cwd: r);
    expect(committed, contains('barra de búsqueda'));
    expect(committed, isNot(contains('implementación grande')));
    expect(File('$r/app.dart').readAsStringSync(), '${edited.join('\n')}\n'); // el archivo no se toca
  });

  test('apartar un grupo: un archivo entero y un bloque de otro, en un solo apartado', () async {
    final (r, edited) = await repoWithTwoHunks();
    File('$r/impl.dart').writeAsStringSync('nuevo módulo');
    final diff = await fileDiff(r, (await status(r)).firstWhere((f) => f.path == 'app.dart'));
    await shelveParts(
      r,
      'Implementación',
      whole: ['impl.dart'],
      parts: {
        'app.dart': (diff, {1}),
      },
    );

    expect(File('$r/impl.dart').existsSync(), isFalse);
    final now = File('$r/app.dart').readAsStringSync();
    expect(now, contains('barra de búsqueda'));
    expect(now, isNot(contains('implementación grande')));
    expect((await shelves(r)).length, 1);

    await unshelve(r, (await shelves(r)).single);
    expect(File('$r/app.dart').readAsStringSync(), '${edited.join('\n')}\n');
    expect(File('$r/impl.dart').readAsStringSync(), 'nuevo módulo');
  });
}
