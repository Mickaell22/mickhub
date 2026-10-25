import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mickhub/git.dart';
import 'package:mickhub/panes.dart';

void main() {
  test('el bloque de MickHub en exclude se agrega y quita sin tocar lo demás', () {
    var s = editExcludeBlock('# de git\n*.log\n', 'config/local.json', add: true);
    s = editExcludeBlock(s, 'tmp.txt', add: true);
    expect(parseExcludeBlock(s), ['config/local.json', 'tmp.txt']);
    s = editExcludeBlock(s, 'config/local.json', add: false);
    expect(parseExcludeBlock(s), ['tmp.txt']);
    expect(s.startsWith('# de git\n*.log\n'), isTrue);
  });

  test('matchesCommit busca en mensaje, autor y prefijo de hash', () {
    final c = Commit('abc123ff', 'Ana Pérez', DateTime(2026), 'fix: login');
    expect(matchesCommit(c, ''), isTrue);
    expect(matchesCommit(c, 'LOGIN'), isTrue);
    expect(matchesCommit(c, 'pérez'), isTrue);
    expect(matchesCommit(c, 'abc1'), isTrue);
    expect(matchesCommit(c, 'zzz'), isFalse);
  });

  test('proteger oculta el archivo de status y desproteger lo devuelve; descartar restaura', () async {
    final dir = await Directory.systemTemp.createTemp('mickhub_test');
    final r = dir.path;
    addTearDown(() => dir.delete(recursive: true));
    await git(['init', '-q'], cwd: r);
    await git(['-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q', '--allow-empty', '-m', 'init'], cwd: r);
    File('$r/app.cfg').writeAsStringSync('v1\n');
    await git(['add', 'app.cfg'], cwd: r);
    await git(['-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q', '-m', 'cfg'], cwd: r);

    File('$r/app.cfg').writeAsStringSync('local\n');
    File('$r/nuevo.txt').writeAsStringSync('x');
    var changes = await status(r);
    expect(changes.map((c) => c.path), containsAll(['app.cfg', 'nuevo.txt']));

    for (final c in changes) {
      await protect(r, c);
    }
    expect(await status(r), isEmpty);
    final locked = await protectedFiles(r);
    expect({for (final p in locked) p.path: p.tracked}, {'app.cfg': true, 'nuevo.txt': false});

    for (final p in locked) {
      await unprotect(r, p);
    }
    expect(await protectedFiles(r), isEmpty);
    changes = await status(r);
    expect(changes.length, 2);

    for (final c in changes) {
      await discard(r, c);
    }
    expect(await status(r), isEmpty);
    expect(File('$r/app.cfg').readAsStringSync(), 'v1\n');
    expect(File('$r/nuevo.txt').existsSync(), isFalse);
  });
}
