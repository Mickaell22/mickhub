import 'dart:convert';
import 'dart:io';

import 'git.dart';

/// Resumen de un commit hecho por la IA en la API de MickHub (v2).
class CommitSummary {
  const CommitSummary(this.text, {this.isMerge = false, this.truncated = false});
  final String text;
  final bool isMerge, truncated;
}

class SummaryException implements Exception {
  const SummaryException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Habla con la API de resúmenes. Sin URL o sin token queda apagada.
class SummaryApi {
  SummaryApi(String url, this.token) : base = url.trim().replaceAll(RegExp(r'/+$'), '');
  final String base, token;

  bool get enabled => base.isNotEmpty && token.isNotEmpty;

  // Resúmenes ya traídos en esta sesión: volver a un commit no vuelve a pedirlo.
  static final _cache = <String, CommitSummary>{};

  /// El resumen de [c]. Primero pregunta si ya existe (no manda el diff); si
  /// no, manda el diff y la API lo resume una sola vez por hash.
  Future<CommitSummary> summary(String repo, Commit c) async {
    final hit = _cache[c.hash];
    if (hit != null) return hit;
    var j = await _call('GET', '/summaries/${c.hash}');
    if (j == null) {
      final info = await commitInfo(repo, c.hash);
      j = await _call('POST', '/summaries', {
        'hash': c.hash,
        'repo': repoId(await originUrl(repo), repo),
        'author': c.author,
        'email': c.email,
        'date': c.date.toUtc().toIso8601String(),
        'message': info.message,
        'parents': info.parents,
        // Los merges no van a la IA: no hace falta leer su diff.
        'diff': info.parents > 1 ? '' : await git(['show', '--format=', '--no-color', c.hash], cwd: repo),
      });
    }
    return _cache[c.hash] = CommitSummary(j!['summary'] as String, isMerge: j['is_merge'] == true, truncated: j['truncated'] == true);
  }

  /// null = 404 (no existe todavía).
  Future<Map<String, dynamic>?> _call(String method, String path, [Map<String, dynamic>? body]) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.openUrl(method, Uri.parse('$base$path'));
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.add(utf8.encode(jsonEncode(body)));
      }
      // Resumir un commit nuevo tarda lo que tarde DeepSeek (varios segundos).
      final res = await req.close().timeout(const Duration(minutes: 3));
      final text = await res.transform(utf8.decoder).join();
      if (res.statusCode == 404 && method == 'GET') return null;
      if (res.statusCode == 401) throw const SummaryException('La API rechazó el token (apiToken en los ajustes).');
      if (res.statusCode != 200) {
        final detail = (() {
          try {
            return (jsonDecode(text) as Map)['detail'];
          } catch (_) {
            return null;
          }
        })();
        throw SummaryException('La API respondió ${res.statusCode}${detail != null ? ': $detail' : ''}');
      }
      return jsonDecode(text) as Map<String, dynamic>;
    } on SocketException {
      throw const SummaryException('No se pudo conectar con la API de resúmenes.');
    } finally {
      client.close();
    }
  }
}

/// Mensaje completo y cantidad de padres de un commit.
Future<({String message, int parents})> commitInfo(String repo, String hash) async {
  final out = await git(['show', '-s', '--format=%P%x00%B', hash], cwd: repo);
  final i = out.indexOf('\x00');
  return (message: out.substring(i + 1).trim(), parents: out.substring(0, i).trim().split(' ').where((p) => p.isNotEmpty).length);
}

/// Nombre estable del repo para la API, igual en todos los dispositivos: el
/// remoto sin esquema, credenciales ni `.git` (`github.com/dueño/repo`). Sin
/// remoto, el nombre de la carpeta.
String repoId(String? remote, String path) {
  if (remote == null || remote.isEmpty) return path.split(RegExp(r'[/\\]')).where((p) => p.isNotEmpty).last;
  var r = remote.trim().replaceFirst(RegExp(r'^[a-z+]+://'), '').replaceFirst(RegExp(r'^[^@/]+@'), '');
  r = r.replaceFirstMapped(RegExp(r'^([^/:]+):(?!\d)'), (m) => '${m[1]}/'); // git@host:dueño/repo
  return r.replaceFirst(RegExp(r'\.git/?$'), '').replaceFirst(RegExp(r'/$'), '');
}
