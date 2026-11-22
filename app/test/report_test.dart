import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mickhub/git.dart';
import 'package:mickhub/summaries_pane.dart';

void main() {
  test('ReportPeriod: semanas desde el lunes, hasta excluido', () {
    final now = DateTime(2026, 11, 20, 15, 30); // viernes
    expect(ReportPeriod.today.range(now), (DateTime(2026, 11, 20), now));
    expect(ReportPeriod.yesterday.range(now), (DateTime(2026, 11, 19), DateTime(2026, 11, 20)));
    expect(ReportPeriod.thisWeek.range(now), (DateTime(2026, 11, 16), now));
    expect(ReportPeriod.lastWeek.range(now), (DateTime(2026, 11, 9), DateTime(2026, 11, 16)));
    expect(ReportPeriod.last30.range(now).$1, DateTime(2026, 10, 21));
    // Un lunes, "esta semana" empieza hoy; un domingo, el lunes anterior.
    expect(ReportPeriod.thisWeek.range(DateTime(2026, 11, 16, 9)).$1, DateTime(2026, 11, 16));
    expect(ReportPeriod.thisWeek.range(DateTime(2026, 11, 22, 9)).$1, DateTime(2026, 11, 16));
    // Cruce de mes y de año.
    expect(ReportPeriod.lastWeek.range(DateTime(2027, 1, 2)), (DateTime(2026, 12, 21), DateTime(2026, 12, 28)));
  });

  test('periodCommits: todas las ramas, sin merges, sin stashes, sin repetir y filtrando autor', () async {
    final tmp = await Directory.systemTemp.createTemp('mickhub-reporte');
    addTearDown(() => tmp.delete(recursive: true));
    final repo = tmp.path;
    Future<void> commit(String who, String msg, String date) async {
      await File('$repo/${msg.replaceAll(' ', '_')}').writeAsString(msg);
      await git(['add', '-A'], cwd: repo);
      await git(
        ['-c', 'user.name=$who', '-c', 'user.email=${who.toLowerCase()}@x.com', 'commit', '-q', '-m', msg],
        cwd: repo,
        env: {'GIT_AUTHOR_DATE': date, 'GIT_COMMITTER_DATE': date},
      );
    }

    await git(['init', '-q', '-b', 'desarrollo', repo]);
    await commit('Otro', 'viejo', '2026-11-01T10:00:00');
    await git(['switch', '-q', '-c', 'U_Yo'], cwd: repo);
    await commit('Yo', 'mio en mi rama', '2026-11-17T10:00:00');
    await git(['switch', '-q', 'desarrollo'], cwd: repo);
    await commit('Otro', 'de otro', '2026-11-18T10:00:00');
    await commit('mickaell22Lucky', 'mio en desarrollo', '2026-11-18T11:00:00');
    // Merge de mi rama en desarrollo (como un PR) y luego desarrollo en mi rama:
    // mi commit queda en las dos ramas y hay dos merges.
    await git(
      ['-c', 'user.name=Otro', '-c', 'user.email=otro@x.com', 'merge', '-q', '--no-ff', '-m', 'Merged PR 1', 'U_Yo'],
      cwd: repo,
      env: {'GIT_AUTHOR_DATE': '2026-11-19T10:00:00', 'GIT_COMMITTER_DATE': '2026-11-19T10:00:00'},
    );
    // Un stash (su commit del índice no es merge) no debe contar.
    await File('$repo/suelto').writeAsString('x');
    await git(['add', 'suelto'], cwd: repo);
    await git(['-c', 'user.name=Yo', '-c', 'user.email=yo@x.com', 'stash', '-q'], cwd: repo);

    final since = DateTime(2026, 11, 16), until = DateTime(2026, 11, 21);
    final all = await periodCommits(repo, since, until);
    expect(all.map((c) => c.summary).toSet(), {'mio en mi rama', 'de otro', 'mio en desarrollo'});
    expect(all.length, 3, reason: 'cada commit una vez aunque esté en dos ramas');

    // Mis commits: por email, por nombre o por usuario de GitHub, sin distinguir mayúsculas.
    final mine = await periodCommits(repo, since, until, authors: ['yo@x.com', 'MICKAELL22LUCKY', '']);
    expect(mine.map((c) => c.summary).toSet(), {'mio en mi rama', 'mio en desarrollo'});

    // El período corta: "viejo" (1 de noviembre) no entra.
    expect((await periodCommits(repo, DateTime(2026, 10, 1), DateTime(2026, 11, 2))).map((c) => c.summary), ['viejo']);

    // Abrir desde Resúmenes: un commit de otra rama se encuentra por hash; uno ajeno no.
    final other = all.firstWhere((c) => c.summary == 'mio en mi rama');
    expect((await commitByHash(repo, other.hash))?.summary, 'mio en mi rama');
    expect(await commitByHash(repo, 'f' * 40), isNull);

    // Lo que trae la rama: tras ponerla al día con desarrollo (merge), solo cuenta lo propio sin llevar.
    await git(['switch', '-q', 'U_Yo'], cwd: repo);
    await git(['-c', 'user.name=Otro', '-c', 'user.email=otro@x.com', 'merge', '-q', '--no-ff', '-m', 'al dia', 'desarrollo'], cwd: repo);
    await commit('Yo', 'nuevo en mi rama', '2026-11-20T10:00:00');
    expect((await branchCommits(repo, 'desarrollo')).map((c) => c.summary), ['nuevo en mi rama']);
    expect(await branchCommits(repo, 'desarrollo', authors: ['otro@x.com']), isEmpty);
    expect((await baseBranches(repo)).$1, containsAll(['desarrollo', 'U_Yo']));
  });
}
