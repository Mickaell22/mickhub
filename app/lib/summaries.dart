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

/// Una fila guardada en la API (para la tabla de resúmenes).
class SummaryRow {
  SummaryRow.fromJson(Map<String, dynamic> j)
    : hash = j['hash'],
      repo = j['repo'],
      author = j['author'],
      email = j['email'],
      date = DateTime.parse(j['date']).toLocal(),
      message = j['message'],
      summary = j['summary'],
      isMerge = j['is_merge'] == true;
  final String hash, repo, author, email, message, summary;
  final DateTime date;
  final bool isMerge;

  String get shortHash => hash.substring(0, 7);
  String get title => summary.split('\n').first;
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
        'diff': info.parents > 1 ? '' : _cap(readable(await git(['show', '--format=', '--no-color', c.hash], cwd: repo))),
      });
    }
    return _cache[c.hash] = CommitSummary(j!['summary'] as String, isMerge: j['is_merge'] == true, truncated: j['truncated'] == true);
  }

  /// Propone título y descripción para commitear [diff] (lo marcado en
  /// Cambios). [hint] es lo que el usuario cuenta que hizo (opcional); los
  /// últimos mensajes del repo van para que siga su estilo.
  Future<({String title, String description})> draftMessage(String repo, String diff, {String hint = ''}) async {
    List<String> recent;
    try {
      recent = (await git(['log', '-n', '15', '--no-merges', '--format=%s'], cwd: repo)).split('\n').where((l) => l.isNotEmpty).toList();
    } on GitException {
      recent = []; // repo sin commits
    }
    final j = await _call('POST', '/commit-message', {'diff': _cap(diff), 'hint': hint, 'recent': recent});
    return (title: j!['title'] as String, description: j['description'] as String);
  }

  /// Reporte de avance de un período a partir de los resúmenes por commit
  /// ([items]: repo, autor, fecha y resumen). [team] = por persona.
  Future<({String text, int cut})> report(String period, bool team, List<({String repo, Commit commit, String summary})> items) async {
    final j = await _call('POST', '/report', {
      'period': period,
      'team': team,
      'items': [
        for (final i in items)
          {'repo': i.repo, 'author': i.commit.author, 'date': i.commit.date.toUtc().toIso8601String(), 'summary': i.summary},
      ],
    });
    return (text: j!['report'] as String, cut: j['cut'] as int);
  }

  /// Resúmenes guardados, más nuevos primero. [repo] vacío = todos los repos.
  Future<List<SummaryRow>> search({String q = '', String repo = '', int offset = 0, int limit = 50}) async {
    final query = Uri(queryParameters: {'q': q, 'repo': repo, 'offset': '$offset', 'limit': '$limit'}).query;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.getUrl(Uri.parse('$base/summaries?$query'));
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      final res = await req.close().timeout(const Duration(seconds: 30));
      final text = await res.transform(utf8.decoder).join();
      if (res.statusCode == 401) throw const SummaryException('La API rechazó el token (apiToken en los ajustes).');
      if (res.statusCode != 200) throw SummaryException('La API respondió ${res.statusCode}');
      return [for (final j in jsonDecode(text) as List) SummaryRow.fromJson(j as Map<String, dynamic>)];
    } on SocketException {
      throw const SummaryException('No se pudo conectar con la API de resúmenes.');
    } finally {
      client.close();
    }
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

/// La API usa solo el principio del diff (MAX_DIFF_CHARS); mandar un commit
/// inicial de varios MB entero sería subirlo para nada. Este tope es mayor que
/// el de la API, así ella sigue marcando `truncated`.
const _maxDiffSent = 200000;
String _cap(String diff) => diff.length > _maxDiffSent ? diff.substring(0, _maxDiffSent) : diff;

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
