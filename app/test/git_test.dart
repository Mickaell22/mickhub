import 'package:flutter_test/flutter_test.dart';
import 'package:mickhub/git.dart';
import 'package:mickhub/diff_view.dart';
import 'package:mickhub/github.dart';
import 'package:mickhub/panes.dart';
import 'package:mickhub/syntax.dart';

void main() {
  test('parseKeyValues respeta los = dentro del valor', () {
    final m = parseKeyValues('protocol=https\nhost=github.com\npassword=a=b\n');
    expect(m['host'], 'github.com');
    expect(m['password'], 'a=b');
  });

  test('nextLink encuentra la página siguiente o null', () {
    const h =
        '<https://api.github.com/user/repos?page=2>; rel="next", '
        '<https://api.github.com/user/repos?page=5>; rel="last"';
    expect(nextLink(h).toString(), 'https://api.github.com/user/repos?page=2');
    expect(nextLink('<https://x?page=1>; rel="prev"'), isNull);
    expect(nextLink(null), isNull);
  });

  test('parseStatus: nuevos, modificados, borrados, renombres y conflictos', () {
    final c = parseStatus('?? a.txt\x00 M b.dart\x00D  c\x00R  nuevo\x00viejo\x00UU d\x00');
    expect(
      [for (final f in c) '${f.path}:${f.status.name}'],
      ['a.txt:added', 'b.dart:modified', 'c:deleted', 'nuevo:renamed', 'd:conflicted'],
    );
    expect(c[3].oldPath, 'viejo');
  });

  test('parseLog separa campos y commits', () {
    final c = parseLog(
      'abc1234567\x1fAna\x1f2026-10-20T10:00:00-05:00\x1ffix: algo\x1e\nfff0000000\x1fLuis\x1f2026-10-19T09:00:00Z\x1fajustes\x1e\n',
    );
    expect(c.length, 2);
    expect(c[0].shortHash, 'abc1234');
    expect(c[1].summary, 'ajustes');
  });

  test('parseDiff numera líneas y detecta binarios', () {
    final l = parseDiff('diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -3,2 +3,2 @@ f\n ctx\n-viejo\n+nuevo\n\\ No newline at end of file\n')!;
    expect([for (final x in l) x.kind.name], ['hunk', 'context', 'delete', 'add']);
    expect((l[1].oldNo, l[1].newNo, l[2].oldNo, l[3].newNo), (3, 3, 4, 4));
    expect(parseDiff('diff --git a/i b/i\nBinary files a/i and b/i differ\n'), isNull);
  });

  test('remoteKey iguala URLs del mismo repo', () {
    expect(remoteKey('https://github.com/Mickaell22/MickHub.git'), remoteKey('https://user@github.com/mickaell22/mickhub'));
  });

  test('timeAgo en español', () {
    final now = DateTime(2026, 10, 25, 12);
    expect(timeAgo(now.subtract(const Duration(minutes: 5)), now: now), 'hace 5 min');
    expect(timeAgo(now.subtract(const Duration(days: 1)), now: now), 'hace 1 día');
    expect(timeAgo(now.subtract(const Duration(days: 400)), now: now), 'hace 1 año');
  });

  test('highlightLines colorea por línea y respeta comentarios multilínea', () {
    expect(languageFor('app/lib/main.dart'), 'dart');
    expect(languageFor('Dockerfile'), 'dockerfile');
    expect(languageFor('LICENSE'), isNull);
    final hl = highlightLines(['/* uno', 'dos */', "final x = 'a';"], 'dart')!;
    expect(hl.length, 3);
    expect(hl[1].single.style?.color, Syntax.comment);
    expect(hl[2].firstWhere((s) => s.text == 'final').style?.color, Syntax.keyword);
    expect(hl[2].firstWhere((s) => s.text == "'a'").style?.color, Syntax.string);
  });

  test('highlightInIsolate funciona fuera del hilo principal', () async {
    final hl = await highlightInIsolate(["final a = 'x';"], 'dart');
    expect(hl!.single.any((s) => s.text == 'final'), isTrue);
  });
}
