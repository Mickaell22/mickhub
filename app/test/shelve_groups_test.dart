import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mickhub/change_groups.dart';
import 'package:mickhub/git.dart';

// Regresión del 17/11/2026: "Apartar" un grupo se llevó los archivos nuevos de
// otro grupo que estaban añadidos al índice, al recuperar falló con "already
// exists" a medias, y lo recuperado cayó en el grupo de una sesión de Claude.

const _id = ['-c', 'user.name=t', '-c', 'user.email=t@t'];

/// Repo con tres grupos: A (a.txt modificado + a_nuevo.txt sin seguimiento),
/// B (b_nuevo.txt nuevo AÑADIDO al índice) y C (c.txt modificado).
Future<String> _repo() async {
  final dir = await Directory.systemTemp.createTemp('mickhub_shelf');
  addTearDown(() => dir.delete(recursive: true));
  final r = dir.path;
  await git(['init', '-q', '-b', 'main'], cwd: r);
  for (final f in ['a.txt', 'c.txt']) {
    File('$r/$f').writeAsStringSync('base $f\n');
  }
  await git(['add', '.'], cwd: r);
  await git([..._id, 'commit', '-q', '-m', 'init'], cwd: r);

  File('$r/a.txt').writeAsStringSync('base a.txt\ncambio A\n');
  File('$r/a_nuevo.txt').writeAsStringSync('nuevo de A\n');
  File('$r/b_nuevo.txt').writeAsStringSync('nuevo de B\n');
  await git(['add', 'b_nuevo.txt'], cwd: r);
  File('$r/c.txt').writeAsStringSync('base c.txt\ncambio C\n');

  final g = ChangeGroups()..add('A', const [], take: ['a.txt', 'a_nuevo.txt']);
  g.add('B', const [], take: ['b_nuevo.txt']);
  g.add('C', const [], take: ['c.txt']);
  g.active = null;
  await g.save(r);
  return r;
}

Future<Map<String, String>> _contents(String r) async => {
  for (final f in await status(r)) f.path: File('$r/${f.path}').readAsStringSync(),
};

void main() {
  test('apartar el grupo A guarda solo sus archivos; B (en el índice) y C quedan intactos', () async {
    final r = await _repo();
    await shelveGrouped(r, 'A', whole: ['a.txt', 'a_nuevo.txt']);

    final sh = (await shelves(r)).single;
    expect((await shelfFiles(r, sh))..sort(), ['a.txt', 'a_nuevo.txt']);
    expect({for (final f in await status(r)) f.path}, {'b_nuevo.txt', 'c.txt'});
    expect(File('$r/b_nuevo.txt').readAsStringSync(), 'nuevo de B\n');
  });

  test('ida y vuelta: apartar y recuperar deja todo igual y cada archivo en su grupo', () async {
    final r = await _repo();
    final before = await _contents(r);
    await shelveGrouped(r, 'A', whole: ['a.txt', 'a_nuevo.txt']);

    // Mientras está apartado, algo reclama sus archivos (lo que hacía el hook de
    // la sesión de Claude) y la limpieza corre: igual deben volver a A.
    await ChangeGroups.update(r, (g) => g.files['a.txt'] = 'C');
    await reconcile(r);

    final res = await unshelveGrouped(r, (await shelves(r)).single);
    expect(res.skipped, isEmpty);
    expect(await shelves(r), isEmpty);
    expect(await _contents(r), before);
    final g = await reconcile(r);
    expect({for (final p in before.keys) p: g.groupOf(p)}, {'a.txt': 'A', 'a_nuevo.txt': 'A', 'b_nuevo.txt': 'B', 'c.txt': 'C'});
    expect(g.shelved, isEmpty);
  });

  test('recuperar con un archivo ya existente: igual se salta, distinto avisa sin tocar nada', () async {
    final r = await _repo();
    await shelveGrouped(r, 'A', whole: ['a.txt', 'a_nuevo.txt']);

    File('$r/a_nuevo.txt').writeAsStringSync('nuevo de A\n'); // idéntico
    final ok = await unshelveGrouped(r, (await shelves(r)).single);
    expect(ok.skipped, ['a_nuevo.txt']);
    expect(File('$r/a.txt').readAsStringSync(), 'base a.txt\ncambio A\n');

    await shelveGrouped(r, 'A otra vez', whole: ['a.txt', 'a_nuevo.txt']);
    File('$r/a_nuevo.txt').writeAsStringSync('otra cosa\n'); // distinto
    final antes = await _contents(r);
    await expectLater(
      unshelveGrouped(r, (await shelves(r)).single),
      throwsA(isA<GitException>().having((e) => e.message, 'mensaje', allOf(contains('a_nuevo.txt'), contains('No se recuperó nada')))),
    );
    expect(await _contents(r), antes); // ni a.txt se tocó
    expect((await shelves(r)).length, 1); // el apartado sigue
  });

  test('regresión exacta: apartado viejo que se llevó el índice de otro grupo se recupera sin "already exists"', () async {
    final r = await _repo();
    // Como lo hacía la versión anterior: stash con rutas sin vaciar el índice.
    await git(['stash', 'push', '--include-untracked', '-m', 'Boton de busqueda', '--', 'a.txt', 'a_nuevo.txt'], cwd: r);
    final sh = (await shelves(r)).single;
    expect(await shelfFiles(r, sh), contains('b_nuevo.txt')); // el bug: B dentro del apartado

    final res = await unshelve(r, sh);
    expect(res.skipped, ['b_nuevo.txt']);
    expect(File('$r/a.txt').readAsStringSync(), 'base a.txt\ncambio A\n');
    expect(File('$r/a_nuevo.txt').readAsStringSync(), 'nuevo de A\n');
    expect(await shelves(r), isEmpty);
  });

  test('eliminar o recuperar un apartado deja un respaldo recuperable', () async {
    final r = await _repo();
    await shelveGrouped(r, 'Para borrar', whole: ['c.txt']);
    await dropShelf(r, (await shelves(r)).single);
    expect(await shelves(r), isEmpty);

    final backups = await shelfBackups(r);
    expect(backups.single.$2, 'Para borrar');
    await git(['stash', 'store', '-m', 'Para borrar', backups.single.$1], cwd: r);
    await unshelve(r, (await shelves(r)).single);
    expect(File('$r/c.txt').readAsStringSync(), 'base c.txt\ncambio C\n');
  });

  test('proteger un archivo nuevo añadido al índice lo saca del índice y nunca se commitea', () async {
    final r = await _repo();
    final b = (await status(r)).firstWhere((f) => f.path == 'b_nuevo.txt');
    await protect(r, b);
    expect((await status(r)).map((f) => f.path), isNot(contains('b_nuevo.txt')));
    expect(await protectedFiles(r), hasLength(1));

    await git([..._id, 'commit', '-q', '-a', '-m', 'todo lo demás'], cwd: r);
    expect(await git(['show', '--name-only', '--format=', 'HEAD'], cwd: r), isNot(contains('b_nuevo.txt')));
    expect(File('$r/b_nuevo.txt').existsSync(), isTrue);
  });

  test('proteger un grupo de N archivos deja exactamente N protegidos, que recuerdan su grupo', () async {
    final r = await _repo();
    final files = (await status(r)).where((f) => f.path.startsWith('a')).toList();
    for (final f in files) {
      await protect(r, f);
    }
    final locked = await protectedFiles(r);
    expect(locked.map((p) => p.path).toSet(), {'a.txt', 'a_nuevo.txt'});
    final g = await reconcile(r); // la limpieza no olvida el grupo de lo protegido
    expect(locked.map((p) => g.groupOf(p.path)).toSet(), {'A'});
  });

  test('un grupo protegido protege lo que entra después; desproteger un archivo lo saca del grupo', () async {
    final r = await _repo();
    final (prot, split) = await protectGroup(r, 'C');
    expect(prot, ['c.txt']);
    expect(split, isEmpty);

    // Un archivo nuevo entra al grupo protegido (como con `mickhub mover`).
    File('$r/c_nuevo.txt').writeAsStringSync('local\n');
    await ChangeGroups.update(r, (g) => g.files['c_nuevo.txt'] = 'C');
    await reconcile(r);
    expect((await protectedFiles(r)).map((p) => p.path).toSet(), {'c.txt', 'c_nuevo.txt'});
    expect((await status(r)).map((f) => f.path), isNot(anyOf(contains('c.txt'), contains('c_nuevo.txt'))));

    // Suelto: sale a "Sin grupo"; si no, la limpieza lo volvería a proteger.
    await unprotectFile(r, (await protectedFiles(r)).firstWhere((p) => p.path == 'c_nuevo.txt'));
    final g = await reconcile(r);
    expect(g.groupOf('c_nuevo.txt'), '');
    expect((await protectedFiles(r)).map((p) => p.path), ['c.txt']);

    // El grupo entero: quita la marca y todo vuelve a Cambios en su grupo.
    expect(await unprotectGroup(r, 'C'), ['c.txt']);
    final after = await reconcile(r);
    expect(after.protectedGroups, isEmpty);
    expect(after.groupOf('c.txt'), 'C');
    expect(await protectedFiles(r), isEmpty);
  });

  test('renombrar o fusionar un grupo protegido conserva la marca', () {
    final g = ChangeGroups(names: ['Local', 'Otro'], protectedGroups: {'Local'});
    g.rename('Local', 'Config local');
    expect(g.protectedGroups, {'Config local'});
    g.merge('Config local', 'Otro');
    expect(g.protectedGroups, {'Otro'});
    g.remove('Otro');
    expect(g.protectedGroups, isEmpty);
  });

  test('la limpieza borra entradas de archivos sin cambios, ni apartados ni protegidos', () async {
    final r = await _repo();
    await ChangeGroups.update(r, (g) => g.files['viejo/sin_cambios.dart'] = 'A');
    await shelveGrouped(r, 'C', whole: ['c.txt']);
    final g = await reconcile(r);
    expect(g.files.keys.toSet(), {'a.txt', 'a_nuevo.txt', 'b_nuevo.txt', 'c.txt'}); // c.txt sigue: está apartado
    final json = jsonDecode(File('${(await ChangeGroups.dir(r)).path}/grupos.json').readAsStringSync()) as Map;
    expect((json['files'] as Map).containsKey('viejo/sin_cambios.dart'), isFalse);
  });
}
