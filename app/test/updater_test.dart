import 'package:flutter_test/flutter_test.dart';
import 'package:mickhub/updater.dart';

void main() {
  test('compareVersions entiende vX.Y.Z', () {
    expect(compareVersions('v0.1.1', 'v0.1.0'), greaterThan(0));
    expect(compareVersions('v0.10.0', 'v0.9.9'), greaterThan(0));
    expect(compareVersions('0.1.0', 'v0.1.0'), 0);
    expect(compareVersions('v1.0.0', 'v1.0.0-beta'), 0);
    expect(compareVersions('v0.2', 'v0.2.1'), lessThan(0));
  });

  test('expectedSha lee el formato de sha256sum', () {
    final sums = '${'a' * 64}  mickhub-linux-x64.tar.gz\n${'b' * 64} *mickhub-windows-x64.zip\n';
    expect(expectedSha(sums, 'mickhub-linux-x64.tar.gz'), 'a' * 64);
    expect(expectedSha(sums, 'mickhub-windows-x64.zip'), 'b' * 64);
    expect(expectedSha(sums, 'otro.zip'), isNull);
  });

  test('sin --dart-define (compilación local) el actualizador queda apagado', () async {
    expect(updaterEnabled, isFalse);
    expect(await checkForUpdate(), isNull);
  });
}
