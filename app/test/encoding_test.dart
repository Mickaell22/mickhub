import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mickhub/change_groups.dart';
import 'package:mickhub/diff_view.dart';
import 'package:mickhub/git.dart';

/// Archivos en Windows-1252 (Latin-1), como los de los backends del trabajo:
/// git los entrega con bytes que no son UTF-8.
void main() {
  test('decodeGit/encodeGit no pierden bytes y readable los muestra como Windows-1252', () {
    final samples = [
      latin1.encode('año café'),
      [0x80, 0x93, 0x94, 0x81], // € “ ” y uno que Windows-1252 no define
      utf8.encode('ya es UTF-8: ñ € 😀 \u{10080}'),
      [0xC3, 0x28, 0xE2, 0x82, 0xF0, 0x9F, 0x98], // secuencias rotas y cortadas
      [0xED, 0xA0, 0x80, 0xC0, 0xAF, 0xF5, 0x80], // surrogate en UTF-8, overlong, fuera de rango
      [...utf8.encode('mezcla ñ '), ...latin1.encode('ñ')],
    ];
    for (final b in samples) {
      expect(encodeGit(decodeGit(b)), b, reason: '$b');
    }
    expect(readable(decodeGit(latin1.encode('año café'))), 'año café');
    expect(readable(decodeGit([0x80, 0x93, 0x94, 0x81])), '€“”�');
    expect(readable(decodeGit(utf8.encode('😀 \u{10080}'))), '😀 \u{10080}', reason: 'pares válidos no se tocan');
    expect(readable(decodeGit([...utf8.encode('mezcla ñ '), ...latin1.encode('ñ')])), 'mezcla ñ ñ');
  });

  test('un archivo Latin-1: diff legible, commit parcial, descartar y apartar bloques con los bytes exactos', () async {
    final r = (await Directory.systemTemp.createTemp('mickhub_latin1')).path;
    addTearDown(() => Directory(r).delete(recursive: true));
    await git(['init', '-q', '-b', 'main'], cwd: r);
    Future<void> commitAll(String m) async {
      await git(['add', '-A'], cwd: r);
      await git(['-c', 'user.name=a', '-c', 'user.email=a@x', 'commit', '-q', '-m', m], cwd: r);
    }

    final f = File('$r/Servicio.cs');
    List<int> enc(List<String> lines) => latin1.encode('${lines.join('\r\n')}\r\n');
    final base = [for (var i = 1; i <= 30; i++) '// línea $i'];
    f.writeAsBytesSync(enc(base));
    await commitAll('base');
    final edited = [...base];
    edited[1] = '// año de la campaña'; // bloque 0
    edited[25] = '// descripción del cálculo'; // bloque 1
    f.writeAsBytesSync(enc(edited));

    final change = (await status(r)).single;
    final diff = await fileDiff(r, change); // antes: FormatException
    final shown = parseDiff(diff)!.map((l) => l.text).join('\n');
    expect(shown, contains('año de la campaña'));
    expect(hunkKeys(diff).toSet().length, 2);

    // Commit solo del bloque 0: el blob guardado tiene los bytes Latin-1 exactos.
    final only0 = [...base]..[1] = edited[1];
    await commit(r, const [], 'parcial', '', identity: ['-c', 'user.name=a', '-c', 'user.email=a@x'], partial: {'Servicio.cs': selectHunks(diff, {0})!});
    expect(await blobAt(r, 'HEAD', 'Servicio.cs'), enc(only0));
    expect(f.readAsBytesSync(), enc(edited), reason: 'el archivo sigue con todo');

    // Descartar el bloque que queda (el 1): vuelve a lo commiteado.
    final rest = await fileDiff(r, (await status(r)).single);
    await discardHunks(r, rest, {0});
    expect(f.readAsBytesSync(), enc(only0));

    // Apartar un bloque y recuperarlo.
    final again = [...only0]..[25] = edited[25];
    f.writeAsBytesSync(enc(again));
    final d2 = await fileDiff(r, (await status(r)).single);
    await shelveHunks(r, 'Servicio.cs', d2, {0}, 'cálculo');
    expect(f.readAsBytesSync(), enc(only0));
    await unshelve(r, (await shelves(r)).single);
    expect(f.readAsBytesSync(), enc(again));
  });
}
