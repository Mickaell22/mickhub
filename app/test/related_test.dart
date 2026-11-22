import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mickhub/git.dart';

void main() {
  test('relatedCommits une "avance" y "final" del mismo trabajo', () async {
    final r = (await Directory.systemTemp.createTemp('mickhub_rel')).path;
    await git(['init', '-q', '-b', 'main'], cwd: r);
    Future<void> commit(String msg, Map<String, String> files, {String who = 'ana', required String date}) async {
      files.forEach((p, v) => File('$r/$p').writeAsStringSync(v));
      await git(['add', '-A'], cwd: r);
      await git(
        ['-c', 'user.name=$who', '-c', 'user.email=$who@x', 'commit', '-q', '-m', msg],
        cwd: r,
        env: {'GIT_AUTHOR_DATE': date, 'GIT_COMMITTER_DATE': date},
      );
    }

    await commit('init', {'a': '0', 'b': '0', 'c': '0'}, date: '2026-01-01T10:00:00Z');
    await commit('avance', {'a': '1', 'b': '1'}, date: '2026-01-10T10:00:00Z');
    await commit('otra cosa', {'c': '1'}, date: '2026-01-11T10:00:00Z'); // no comparte archivos
    await commit('de luis', {'a': '2', 'b': '2'}, who: 'luis', date: '2026-01-11T12:00:00Z'); // otro autor
    await commit('final', {'a': '3', 'b': '3', 'c': '2'}, date: '2026-01-12T10:00:00Z');
    await commit('mucho después', {'a': '4', 'b': '4'}, date: '2026-03-01T10:00:00Z'); // fuera de plazo

    final all = await log(r);
    Commit byMsg(String m) => all.firstWhere((c) => c.summary == m);
    Future<({Commit? before, Commit? after})> rel(String m) async => relatedCommits(r, byMsg(m), await commitFiles(r, byMsg(m).hash));

    final avance = await rel('avance');
    expect(avance.after?.summary, 'final');
    final fin = await rel('final');
    expect(fin.before?.summary, 'avance');
    expect(fin.after, isNull); // "mucho después" queda fuera de los 7 días
    expect((await rel('mucho después')).before, isNull);
    expect((await rel('de luis')).before, isNull);

    // Las releases tocan siempre lo mismo (pubspec): no se enlazan.
    await commit('chore(release): 0.1.0', {'pubspec': '0.1.0'}, date: '2026-03-02T10:00:00Z');
    await commit('chore(release): 0.1.1', {'pubspec': '0.1.1'}, date: '2026-03-03T10:00:00Z');
    final rel1 = (await log(r)).first;
    expect(rel1.summary, 'chore(release): 0.1.1');
    expect((await relatedCommits(r, rel1, await commitFiles(r, rel1.hash))).before, isNull);
    for (final m in ['chore(release): 0.1.9', 'build(release)!: 2.0', 'v1.2.3', '0.4', 'Release 2.0', 'bump version to 3']) {
      expect(isRelease(m), isTrue, reason: m);
    }
    for (final m in ['feat(release-notes): agrega', 'fix: release del lock', 'releases: lista']) {
      expect(isRelease(m), isFalse, reason: m);
    }
    await Directory(r).delete(recursive: true);
  });
}
