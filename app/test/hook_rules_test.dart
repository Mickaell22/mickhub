import 'package:flutter_test/flutter_test.dart';
import 'package:mickhub/hook_rules.dart';

void main() {
  test('orden de subir: con y sin coma, y no si está negada', () {
    for (final yes in ['haz push', 'dale push', 'si dale, push y lo reviso', 'sí, push', 'commit y push', 'súbelo', 'sube los cambios', 'en el repo de github']) {
      expect(asksPush(yes), isTrue, reason: yes);
    }
    for (final no in ['solo commit y no push', 'no hagas push', 'sube la prioridad', 'revisa el código en github', 'el push lo hago yo']) {
      expect(asksPush(no), isFalse, reason: no);
    }
  });

  test('solo mueve cambios: todas las partes; un checkout al final ya no anula lo editado', () {
    expect(onlyMovesChanges('git stash pop'), isTrue);
    expect(onlyMovesChanges('cd repo && git switch main && git pull'), isTrue);
    expect(onlyMovesChanges('mickhub recuperar "README en curso"'), isTrue);
    // Lo que pasaba en casi cada comando: editar y al final restaurar un archivo.
    expect(onlyMovesChanges("python3 - <<'EOF'\nopen('a','w').write('x')\nEOF\nflutter analyze; git checkout -q pubspec.lock"), isFalse);
    expect(onlyMovesChanges("sed -i 's/a/b/' x.dart && mickhub estado"), isFalse);
    expect(onlyMovesChanges('echo "git stash pop"'), isFalse, reason: 'entre comillas no cuenta');
    expect(mixesMoves("sed -i 's/a/b/' x && git stash pop"), isTrue);
    expect(mixesMoves("sed -i 's/a/b/' x"), isFalse);
  });
}
