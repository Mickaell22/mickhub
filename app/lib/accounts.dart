import 'dart:convert';
import 'dart:io';

import 'git.dart';
import 'github.dart';

enum Provider { github, azure }

/// Una cuenta: dónde vive (GitHub o una organización de Azure DevOps) y con qué
/// nombre y email firma los commits. MickHub no guarda tokens: los pide al
/// credential helper de git (gh o Git Credential Manager) cada vez.
class Account {
  const Account({
    required this.id,
    required this.label,
    required this.provider,
    required this.org,
    this.username,
    this.gitName = '',
    this.gitEmail = '',
  });

  factory Account.fromJson(Map<String, dynamic> j) => Account(
    id: j['id'],
    label: j['label'],
    provider: Provider.values.byName(j['provider']),
    org: j['org'] ?? '',
    username: j['username'],
    gitName: j['gitName'] ?? '',
    gitEmail: j['gitEmail'] ?? '',
  );

  final String id, label;
  final Provider provider;

  /// GitHub: vacío. Azure DevOps: nombre de la organización (`dev.azure.com/<org>`).
  final String org;

  /// Usuario de la cuenta. En GitHub sirve para distinguir dos cuentas del mismo
  /// host (el credential helper elige por usuario).
  final String? username;
  final String gitName, gitEmail;

  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'provider': provider.name,
    'org': org,
    'username': username,
    'gitName': gitName,
    'gitEmail': gitEmail,
  };

  String get host => provider == Provider.github ? 'github.com' : 'dev.azure.com';

  /// Lo que se le pasa a `git credential` para esta cuenta. En Azure va el path
  /// con la organización porque el GCM guarda una credencial por organización
  /// (`credential.https://dev.azure.com.useHttpPath`).
  String credentialQuery() => [
    'protocol=https',
    'host=$host',
    if (provider == Provider.azure) 'path=$org',
    if (username != null && username!.isNotEmpty) 'username=$username',
    '',
    '',
  ].join('\n');

  bool get hasIdentity => gitName.trim().isNotEmpty && gitEmail.trim().isNotEmpty;

  /// Argumentos `-c` para firmar commits con esta cuenta sin tocar la config del repo.
  List<String> get identityArgs => hasIdentity ? ['-c', 'user.name=$gitName', '-c', 'user.email=$gitEmail'] : const [];
}

/// Partes útiles de la URL de un remoto (https o ssh).
class Remote {
  const Remote(this.host, this.segments, {this.user});
  final String host;
  final List<String> segments;
  final String? user;

  /// Azure: organización. GitHub: dueño del repo.
  String? get owner {
    if (host == 'ssh.dev.azure.com') return segments.length > 1 ? segments[1] : null; // v3/<org>/...
    if (host.endsWith('.visualstudio.com')) return host.split('.').first;
    return segments.isEmpty ? null : segments.first;
  }

  bool get isAzure => host == 'dev.azure.com' || host == 'ssh.dev.azure.com' || host.endsWith('.visualstudio.com');
  bool get isGithub => host == 'github.com';
}

Remote? parseRemote(String url) {
  final ssh = RegExp(r'^(?:([^@/]+)@)?([^:/]+):(?!//)(.+)$').firstMatch(url);
  if (ssh != null && !url.contains('://')) {
    return Remote(ssh[2]!.toLowerCase(), ssh[3]!.split('/').where((s) => s.isNotEmpty).toList(), user: ssh[1]);
  }
  final u = Uri.tryParse(url);
  if (u == null || u.host.isEmpty) return null;
  final user = u.userInfo.isEmpty ? null : Uri.decodeComponent(u.userInfo.split(':').first);
  return Remote(u.host.toLowerCase(), u.pathSegments.where((s) => s.isNotEmpty).toList(), user: user);
}

/// Cuenta que corresponde a un repo: la elegida a mano, si hay; si no, la que
/// calza con el remoto (organización en Azure; usuario o dueño en GitHub).
Account? accountFor(String? remoteUrl, List<Account> accounts, {String? overrideId}) {
  if (overrideId != null) {
    for (final a in accounts) {
      if (a.id == overrideId) return a;
    }
  }
  final r = remoteUrl == null ? null : parseRemote(remoteUrl);
  if (r == null) return null;
  if (r.isAzure) {
    final org = r.owner?.toLowerCase();
    return accounts.where((a) => a.provider == Provider.azure && a.org.toLowerCase() == org).firstOrNull;
  }
  if (r.isGithub) {
    final gh = accounts.where((a) => a.provider == Provider.github).toList();
    bool same(String? a, String? b) => a != null && b != null && a.toLowerCase() == b.toLowerCase();
    return gh.where((a) => same(a.username, r.user)).firstOrNull ??
        gh.where((a) => same(a.username, r.owner)).firstOrNull ??
        (gh.length == 1 ? gh.single : null);
  }
  return null;
}

// --- Estado de las sesiones -------------------------------------------------------

enum SessionState { ok, expired, missing, error }

class Session {
  const Session(this.state, [this.detail = '']);
  final SessionState state;
  final String detail; // usuario conectado, o el motivo del fallo

  String get label => switch (state) {
    SessionState.ok => 'Conectada',
    SessionState.expired => 'Sesión vencida',
    SessionState.missing => 'Sin iniciar sesión',
    SessionState.error => 'No se pudo verificar',
  };
}

/// Credencial de la cuenta sin abrir ventanas de login (el GCM no pregunta).
Future<Map<String, String>?> credentialFor(Account a, {bool interactive = false}) async {
  try {
    final out = await git(['credential', 'fill'], stdin: a.credentialQuery(), env: {'GCM_INTERACTIVE': interactive ? 'auto' : 'never'});
    final kv = parseKeyValues(out);
    return kv['password'] == null ? null : kv;
  } on GitException {
    return null;
  }
}

/// Verifica la sesión pidiendo la credencial y probándola contra la API.
Future<Session> checkSession(Account a) async {
  final cred = await credentialFor(a);
  if (cred == null) return const Session(SessionState.missing);
  try {
    final who = a.provider == Provider.github ? await _githubUser(cred['password']!) : await _azureUser(cred['password']!);
    return who == null ? const Session(SessionState.expired) : Session(SessionState.ok, who);
  } catch (e) {
    return Session(SessionState.error, '$e');
  }
}

/// Inicia sesión: deja que el credential helper muestre su login (navegador del
/// GCM) y guarda lo que devuelva con `credential approve`.
Future<bool> login(Account a) async {
  final old = await credentialFor(a);
  if (old != null && (await checkSession(a)).state != SessionState.ok) {
    // Credencial vencida: se descarta para que el helper pida una nueva.
    await git(['credential', 'reject'], stdin: _credentialText(old), okCodes: {0, 1});
  }
  final fresh = await credentialFor(a, interactive: true);
  if (fresh == null) return false;
  await git(['credential', 'approve'], stdin: _credentialText(fresh), okCodes: {0, 1});
  return (await checkSession(a)).state == SessionState.ok;
}

String _credentialText(Map<String, String> kv) => '${kv.entries.map((e) => '${e.key}=${e.value}').join('\n')}\n\n';

/// Mensajes de git que indican credencial faltante o vencida.
bool isAuthError(String message) => RegExp(
  r'Authentication failed|could not read Username|terminal prompts disabled|HTTP Basic: Access denied|'
  r'\b401\b|\b403\b|Invalid username or (password|token)|TF400813|not authorized',
  caseSensitive: false,
).hasMatch(message);

Future<String?> _githubUser(String token) async {
  final (status, body) = await _get(Uri.parse('https://api.github.com/user'), {'Authorization': 'Bearer $token'});
  if (status == 401) return null;
  if (status != 200) throw HttpException('GitHub respondió $status');
  return (jsonDecode(body) as Map)['login'];
}

/// Azure acepta el token del GCM como Bearer (OAuth) o un PAT como Basic; se
/// prueban los dos. Un 203 con HTML es su forma de decir "no autorizado".
Future<String?> _azureUser(String token) async {
  final url = Uri.parse('https://app.vssps.visualstudio.com/_apis/profile/profiles/me?api-version=7.1');
  for (final auth in azureAuthHeaders(token)) {
    final (status, body) = await _get(url, {'Authorization': auth});
    if (status == 200) {
      final j = jsonDecode(body) as Map;
      return j['emailAddress'] ?? j['displayName'];
    }
    if (status != 401 && status != 203) throw HttpException('Azure DevOps respondió $status');
  }
  return null;
}

List<String> azureAuthHeaders(String token) => ['Bearer $token', 'Basic ${base64Encode(utf8.encode(':$token'))}'];

/// Repos de una organización de Azure DevOps (de todos sus proyectos).
Future<List<Repo>> azureRepos(Account a) async {
  final cred = await credentialFor(a);
  if (cred == null) throw const HttpException('La cuenta no tiene sesión iniciada');
  final url = Uri.parse('https://dev.azure.com/${Uri.encodeComponent(a.org)}/_apis/git/repositories?api-version=7.1');
  for (final auth in azureAuthHeaders(cred['password']!)) {
    final (status, body) = await _get(url, {'Authorization': auth});
    if (status == 200) {
      return [
        for (final r in (jsonDecode(body) as Map)['value'] as List)
          if (r['isDisabled'] != true)
            Repo(name: r['name'], owner: r['project']['name'], cloneUrl: r['remoteUrl'], private: true, description: null),
      ];
    }
    if (status != 401 && status != 203) throw HttpException('Azure DevOps respondió $status');
  }
  throw const HttpException('La sesión de Azure DevOps venció');
}

Future<(int, String)> _get(Uri url, Map<String, String> headers) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final req = await client.getUrl(url);
    headers.forEach(req.headers.set);
    req.headers.set('User-Agent', 'MickHub');
    req.followRedirects = false; // Azure redirige al login en vez de dar 401
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    return (res.isRedirect ? 401 : res.statusCode, body);
  } finally {
    client.close();
  }
}
