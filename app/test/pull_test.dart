import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mickhub/git.dart';

const _id = ['-c', 'user.name=t', '-c', 'user.email=t@t'];

/// Remoto con `f.txt` de 10 líneas y dos clones: [mio] (el del usuario) y
/// [otro] (un compañero que sube cambios).
Future<(String, String)> twoClones() async {
  final dir = await Directory.systemTemp.createTemp('mickhub_pull');
  addTearDown(() => dir.delete(recursive: true));
  final d = dir.path;
  await git(['init', '-q', '--bare', '-b', 'Mmoran', '$d/remoto.git']);
  await git(['clone', '-q', '$d/remoto.git', '$d/mio']);
  File('$d/mio/f.txt').writeAsStringSync('${[for (var i = 1; i <= 10; i++) 'l$i'].join('\n')}\n');
  await git(['add', '.'], cwd: '$d/mio');
  await git([..._id, 'commit', '-q', '-m', 'base'], cwd: '$d/mio');
  await git(['push', '-q', 'origin', 'HEAD'], cwd: '$d/mio');
  await git(['clone', '-q', '$d/remoto.git', '$d/otro']);
  return ('$d/mio', '$d/otro');
}

Future<void> edit(String repo, String from, String to) async {
  final f = File('$repo/f.txt');
  f.writeAsStringSync(f.readAsStringSync().replaceFirst('$from\n', '$to\n'));
}

Future<void> pushFromOther(String otro, String from, String to) async {
  await edit(otro, from, to);
  await git([..._id, 'commit', '-q', '-am', 'compañero'], cwd: otro);
  await git(['push', '-q'], cwd: otro);
}

void main() {
  test('pull con cambios sin commitear en el mismo archivo: git se niega y se detecta', () async {
    final (mio, otro) = await twoClones();
    await pushFromOther(otro, 'l9', 'REMOTO');
    await edit(mio, 'l2', 'MIO');
    try {
      await pull(mio, identity: _id);
      fail('git debía negarse');
    } on GitException catch (e) {
      expect(pullBlockedBy(e.message), ['f.txt']);
    }
    await pull(mio, identity: _id, autostash: true); // otras líneas: entra todo
    expect(File('$mio/f.txt').readAsStringSync(), contains('MIO'));
    expect(File('$mio/f.txt').readAsStringSync(), contains('REMOTO'));
    expect(await mergeState(mio), MergeState.none);
    expect(await shelves(mio), isEmpty);
  });

  test('si chocan en la misma línea: conflicto, "mi versión" es la mía y Listo borra el apartado', () async {
    final (mio, otro) = await twoClones();
    await pushFromOther(otro, 'l5', 'REMOTO5');
    await edit(mio, 'l5', 'MIO5');
    await pull(mio, identity: _id, autostash: true);
    expect(await mergeState(mio), MergeState.stash);
    expect((await shelves(mio)).single.name, 'autostash');

    await resolveWith(mio, 'f.txt', mine: true, state: MergeState.stash);
    await finishMerge(mio, MergeState.stash, identity: _id);
    final now = File('$mio/f.txt').readAsStringSync();
    expect(now, contains('MIO5'));
    expect(now, isNot(contains('<<<<<<<')));
    expect(await mergeState(mio), MergeState.none);
    expect(await shelves(mio), isEmpty);
    expect((await status(mio)).single.path, 'f.txt'); // vuelve a ser un cambio sin commitear
  });

  test('ramas divergentes (commits para subir y para traer): el pull hace merge sin fallar', () async {
    final (mio, otro) = await twoClones();
    await pushFromOther(otro, 'l9', 'REMOTO');
    await edit(mio, 'l2', 'MIO');
    await git([..._id, 'commit', '-q', '-am', 'mío'], cwd: mio);
    await git(['fetch', '-q'], cwd: mio);
    await pull(mio, identity: _id);
    final f = File('$mio/f.txt').readAsStringSync();
    expect(f, contains('MIO'));
    expect(f, contains('REMOTO'));

    // El historial muestra el merge con lo que trajo, no vacío.
    final merge = (await git(['rev-parse', 'HEAD'], cwd: mio)).trim();
    final files = await commitFiles(mio, merge);
    expect(files.map((f) => f.path), ['f.txt']);
    expect(await commitFileDiff(mio, merge, files.single), contains('+REMOTO'));
  });
}
