import 'dart:convert';
import 'dart:io';

class Repo {
  Repo({required this.name, required this.owner, required this.cloneUrl, required this.private, this.description});

  factory Repo.fromGithub(Map<String, dynamic> j) =>
      Repo(name: j['name'], owner: j['owner']['login'], cloneUrl: j['clone_url'], private: j['private'], description: j['description']);

  final String name, owner, cloneUrl;
  final bool private;
  final String? description;

  String get fullName => '$owner/$name';
}

/// URL de la página siguiente según la cabecera `Link` de GitHub.
Uri? nextLink(String? header) {
  final m = header == null ? null : RegExp(r'<([^>]+)>;\s*rel="next"').firstMatch(header);
  return m == null ? null : Uri.parse(m[1]!);
}

/// Todos los repos a los que tiene acceso el token: propios, de colaborador y
/// de organizaciones. Ordenados por el último push.
Future<List<Repo>> githubRepos(String token) async {
  final client = HttpClient();
  try {
    final repos = <Repo>[];
    Uri? url = Uri.parse('https://api.github.com/user/repos?per_page=100&sort=pushed');
    while (url != null) {
      final req = await client.getUrl(url);
      req.headers
        ..set('Authorization', 'Bearer $token')
        ..set('Accept', 'application/vnd.github+json')
        ..set('User-Agent', 'MickHub');
      final res = await req.close();
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) throw HttpException('GitHub respondió ${res.statusCode}', uri: url);
      repos.addAll((jsonDecode(body) as List).map((j) => Repo.fromGithub(j)));
      url = nextLink(res.headers.value('link'));
    }
    return repos;
  } finally {
    client.close();
  }
}
