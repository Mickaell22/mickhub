import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mickhub/git.dart';
import 'package:mickhub/trash.dart';

/// Repo temporal con un commit y un archivo versionado `a.txt`.
Future<String> tempRepo() async {
  final dir = await Directory.systemTemp.createTemp('mickhub_wf');
  addTearDown(() => dir.delete(recursive: true));
  final r = dir.path;
  await git(['init', '-q', '-b', 'Mmoran'], cwd: r);
  File('$r/a.txt').writeAsStringSync('base\n');
  await git(['add', '.'], cwd: r);
  await git(['-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q', '-m', 'init'], cwd: r);
  return r;
}

void main() {
  test('parseShelves saca nombre y rama del asunto del stash', () {
    final s = parseShelves(
      'stash@{0}\x1fOn Mmoran: Implementación grande\x1f2026-10-25T10:00:00-05:00\n'
      'stash@{1}\x1fWIP on main: abc123 msg\x1f2026-10-24T10:00:00Z\n'
      'stash@{2}\x1fOn fix/x: !!GitHub_Desktop<fix/x>\x1f2026-10-24T10:00:00Z\n',
    );
    expect(
      [for (final x in s) (x.ref, x.branch, x.name)],
      [
        ('stash@{0}', 'Mmoran', 'Implementación grande'),
        ('stash@{1}', 'main', 'abc123 msg'),
        ('stash@{2}', 'fix/x', 'Guardado por GitHub Desktop'),
      ],
    );
  });

  test('caso del fix rápido: apartar la implementación, rama local con la barra, recuperar', () async {
    final r = await tempRepo();
    File('$r/a.txt').writeAsStringSync('implementación grande\n'); // versionado y modificado
    File('$r/impl.dart').writeAsStringSync('nuevo módulo'); // nuevo
    File('$r/barra.dart').writeAsStringSync('barra de búsqueda'); // nuevo, viaja

    await shelve(r, 'Implementación grande', ['a.txt', 'impl.dart']);
    expect((await status(r)).map((f) => f.path), ['barra.dart']);
    expect(File('$r/a.txt').readAsStringSync(), 'base\n');

    await createBranch(r, 'fix-login', 'Mmoran');
    expect((await branchState(r)).name, 'fix-login');
    expect(File('$r/barra.dart').existsSync(), isTrue); // la barra viajó

    await git(['switch', 'Mmoran'], cwd: r);
    final list = await shelves(r);
    expect(list.single.name, 'Implementación grande');
    expect(await shelfFiles(r, list.single), containsAll(['a.txt', 'impl.dart']));
    await unshelve(r, list.single);
    expect(await shelves(r), isEmpty);
    expect(File('$r/a.txt').readAsStringSync(), 'implementación grande\n');
    expect(File('$r/impl.dart').existsSync(), isTrue);
  });

  test('la papelera guarda una copia antes de descartar y la restaura', () async {
    final r = await tempRepo();
    final trashDir = await Directory.systemTemp.createTemp('mickhub_trash');
    addTearDown(() => trashDir.delete(recursive: true));
    final trash = Trash(trashDir);

    File('$r/a.txt').writeAsStringSync('mi trabajo\n');
    final f = (await status(r)).single;
    await trash.save(r, f.path);
    await discard(r, f);
    expect(File('$r/a.txt').readAsStringSync(), 'base\n');

    final e = trash.list(repo: r).single;
    expect(e.path, 'a.txt');
    await trash.restore(e);
    expect(File('$r/a.txt').readAsStringSync(), 'mi trabajo\n');
    expect(trash.list(), isEmpty);
  });
}
