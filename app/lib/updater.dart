import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// Versión y repo de releases: los pone el workflow de release al compilar
/// (`--dart-define`). En una compilación local quedan vacíos y el actualizador
/// no hace nada.
const appVersion = String.fromEnvironment('MICKHUB_VERSION');
const releaseRepo = String.fromEnvironment('MICKHUB_REPO');

bool get updaterEnabled => appVersion.isNotEmpty && releaseRepo.isNotEmpty;

/// Nombre del paquete portable de esta plataforma en el release.
String? get platformAsset => Platform.isLinux
    ? 'mickhub-linux-x64.tar.gz'
    : Platform.isWindows
    ? 'mickhub-windows-x64.zip'
    : null;

class Release {
  const Release(this.tag, this.notes, this.assets);
  final String tag, notes;
  final Map<String, String> assets; // nombre -> URL de descarga
}

/// Compara versiones `vX.Y.Z` (o sin `v`); los sufijos se ignoran.
int compareVersions(String a, String b) {
  List<int> parts(String v) => [
    for (final p in v.replaceFirst(RegExp('^v'), '').split(RegExp(r'[-+]')).first.split('.')) int.tryParse(p) ?? 0,
  ];
  final pa = parts(a), pb = parts(b);
  for (var i = 0; i < 3; i++) {
    final x = i < pa.length ? pa[i] : 0, y = i < pb.length ? pb[i] : 0;
    if (x != y) return x.compareTo(y);
  }
  return 0;
}

/// Último release publicado, si es más nuevo que esta versión; si no, null.
Future<Release?> checkForUpdate() async {
  if (!updaterEnabled) return null;
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final req = await client.getUrl(Uri.parse('https://api.github.com/repos/$releaseRepo/releases/latest'));
    req.headers
      ..set('Accept', 'application/vnd.github+json')
      ..set('User-Agent', 'MickHub');
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    if (res.statusCode != 200) return null;
    final j = jsonDecode(body) as Map<String, dynamic>;
    final tag = j['tag_name'] as String;
    if (compareVersions(tag, appVersion) <= 0) return null;
    return Release(tag, (j['body'] ?? '') as String, {
      for (final a in j['assets'] as List) a['name'] as String: a['browser_download_url'] as String,
    });
  } catch (_) {
    return null; // sin red o GitHub caído: se reintenta más tarde
  } finally {
    client.close();
  }
}

/// SHA256 esperado de [file] según un `SHA256SUMS.txt` (formato de sha256sum).
String? expectedSha(String sums, String file) {
  for (final l in LineSplitter.split(sums)) {
    final m = RegExp(r'^([0-9a-f]{64})\s+\*?(.+)$').firstMatch(l.trim());
    if (m != null && m[2] == file) return m[1];
  }
  return null;
}

/// Carpeta donde está instalado MickHub (la del ejecutable).
Directory get installDir => File(Platform.resolvedExecutable).parent;

bool canWriteInstallDir() {
  try {
    final probe = File('${installDir.path}${Platform.pathSeparator}.mickhub-escritura');
    probe.writeAsStringSync('');
    probe.deleteSync();
    return true;
  } catch (_) {
    return false;
  }
}

Future<List<int>> _download(String url) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(Uri.parse(url));
    req.headers.set('User-Agent', 'MickHub');
    final res = await req.close(); // GitHub redirige al CDN; HttpClient lo sigue
    if (res.statusCode != 200) throw HttpException('Descarga falló (${res.statusCode})', uri: Uri.parse(url));
    return [for (final chunk in await res.toList()) ...chunk];
  } finally {
    client.close();
  }
}

/// Descarga el paquete, verifica su SHA256, lo descomprime y deja corriendo un
/// script que espera a que MickHub se cierre, copia los archivos nuevos encima
/// y la vuelve a abrir. Quien llama debe cerrar la app justo después.
Future<void> downloadAndApply(Release r) async {
  final asset = platformAsset;
  final url = asset == null ? null : r.assets[asset];
  final sumsUrl = r.assets['SHA256SUMS.txt'];
  if (url == null || sumsUrl == null) throw StateError('El release ${r.tag} no trae el paquete de este sistema');

  final bytes = await _download(url);
  final sums = utf8.decode(await _download(sumsUrl));
  if (sha256.convert(bytes).toString() != expectedSha(sums, asset!)) {
    throw StateError('La descarga no coincide con SHA256SUMS.txt; no se instaló nada');
  }

  final work = await Directory.systemTemp.createTemp('mickhub_update');
  final pkg = File('${work.path}${Platform.pathSeparator}$asset');
  await pkg.writeAsBytes(bytes);
  final out = Directory('${work.path}${Platform.pathSeparator}nuevo')..createSync();
  final ProcessResult x;
  if (Platform.isWindows) {
    x = await Process.run('powershell', [
      '-NoProfile',
      '-Command',
      'Expand-Archive -LiteralPath "${pkg.path}" -DestinationPath "${out.path}"',
    ]);
  } else {
    x = await Process.run('tar', ['-xzf', pkg.path, '-C', out.path]);
  }
  if (x.exitCode != 0) throw StateError('No se pudo descomprimir: ${x.stderr}');
  final fresh = '${out.path}${Platform.pathSeparator}MickHub';
  final dest = installDir.path;
  final exe = Platform.resolvedExecutable;

  if (Platform.isWindows) {
    final script =
        'Wait-Process -Id $pid -ErrorAction SilentlyContinue; '
        'Copy-Item -Path "$fresh\\*" -Destination "$dest" -Recurse -Force; '
        'Start-Process -FilePath "$exe"; '
        'Remove-Item -Recurse -Force "${work.path}"';
    await Process.start('powershell', ['-NoProfile', '-WindowStyle', 'Hidden', '-Command', script], mode: ProcessStartMode.detached);
  } else {
    final script =
        'while kill -0 $pid 2>/dev/null; do sleep 0.3; done; '
        'cp -rf "$fresh/." "$dest/" && "$exe" >/dev/null 2>&1 & '
        'sleep 2; rm -rf "${work.path}"';
    await Process.start('sh', ['-c', script], mode: ProcessStartMode.detached);
  }
}
