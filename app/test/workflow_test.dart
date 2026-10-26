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
  historyAndConflicts();
  newRepoTests();
  hunkTests();
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

/// Commitea todo lo pendiente en [r].
Future<void> commitAll(String r, String msg) async {
  await git(['add', '-A'], cwd: r);
  await git(['-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q', '-m', msg], cwd: r);
}

void historyAndConflicts() {
  test('historial paginado y búsqueda en todo el historial', () async {
    final r = await tempRepo();
    for (var i = 0; i < logPage + 5; i++) {
      File('$r/a.txt').writeAsStringSync('v$i');
      await commitAll(r, i == 3 ? 'fix: login roto' : 'cambio $i');
    }
    final p1 = await log(r);
    final p2 = await log(r, skip: p1.length);
    expect(p1.length, logPage);
    expect(p2.length, 6); // 5 + el commit inicial
    expect({...p1.map((c) => c.hash)}.intersection({...p2.map((c) => c.hash)}), isEmpty);

    final found = await searchLog(r, 'LOGIN ROTO'); // está en la página 2: busca en todo
    expect(found.single.summary, 'fix: login roto');
    expect((await searchLog(r, found.single.shortHash)).single.hash, found.single.hash);
  });

  test('pull con conflicto: se detecta, se resuelve con una versión y se termina el merge', () async {
    final remote = await tempRepo();
    final dir = await Directory.systemTemp.createTemp('mickhub_clone');
    addTearDown(() => dir.delete(recursive: true));
    final local = '${dir.path}/local';
    await git(['clone', '-q', remote, local]);
    File('$remote/a.txt').writeAsStringSync('del remoto\n');
    await commitAll(remote, 'remoto');
    File('$local/a.txt').writeAsStringSync('mío\n');
    await commitAll(local, 'local');

    await expectLater(
      git(['-c', 'user.name=t', '-c', 'user.email=t@t', '-c', 'pull.rebase=false', 'pull', '-q'], cwd: local),
      throwsA(isA<GitException>()),
    );
    expect(await mergeState(local), MergeState.merge);
    expect((await status(local)).single.status, FileStatus.conflicted);
    final lines = File('$local/a.txt').readAsLinesSync();
    expect(conflictParts(lines), [ConflictPart.marker, ConflictPart.mine, ConflictPart.marker, ConflictPart.theirs, ConflictPart.marker]);

    await resolveWith(local, 'a.txt', mine: true, state: MergeState.merge);
    await finishMerge(local, MergeState.merge, identity: ['-c', 'user.name=t', '-c', 'user.email=t@t']);
    expect(await mergeState(local), MergeState.none);
    expect(File('$local/a.txt').readAsStringSync(), 'mío\n');
  });
}

void newRepoTests() {
  test('nuevo repo: init con README y commit, y publicar a un remoto', () async {
    final dir = await Directory.systemTemp.createTemp('mickhub_new');
    addTearDown(() => dir.delete(recursive: true));
    final repo = '${dir.path}/mi-proyecto';
    await initRepo(repo, 'mi-proyecto', identity: ['-c', 'user.name=t', '-c', 'user.email=t@t']);
    expect(File('$repo/README.md').readAsStringSync(), '# mi-proyecto\n');
    expect((await log(repo)).single.summary, 'chore: commit inicial');
    expect(await originUrl(repo), isNull);

    final bare = '${dir.path}/remoto.git';
    await git(['init', '-q', '--bare', bare]);
    await publishRepo(repo, bare);
    expect(await originUrl(repo), bare);
    expect((await branchState(repo)).upstream, 'origin/main');
  });
}

void hunkTests() {
  test('apartar un bloque: la implementación se va, la barra de búsqueda se queda, y vuelve al recuperar', () async {
    final r = await tempRepo();
    final base = [for (var i = 1; i <= 30; i++) 'línea $i'];
    File('$r/app.dart').writeAsStringSync('${base.join('\n')}\n');
    await commitAll(r, 'base');

    final edited = [...base];
    edited[1] = 'barra de búsqueda'; // bloque 0 (arriba)
    edited[25] = 'implementación grande'; // bloque 1 (abajo, lejos)
    File('$r/app.dart').writeAsStringSync('${edited.join('\n')}\n');

    final f = (await status(r)).single;
    final diff = await fileDiff(r, f);
    expect(RegExp('^@@', multiLine: true).allMatches(diff).length, 2);
    await shelveHunks(r, 'app.dart', diff, {1}, 'Implementación');

    final now = File('$r/app.dart').readAsStringSync();
    expect(now, contains('barra de búsqueda'));
    expect(now, isNot(contains('implementación grande')));

    await unshelve(r, (await shelves(r)).single);
    expect(File('$r/app.dart').readAsStringSync(), '${edited.join('\n')}\n');
  });
}
