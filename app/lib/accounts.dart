import 'dart:convert';
import 'dart:io';

import 'git.dart';
import 'github.dart';

enum Provider { github, azure }

/// Un lugar donde la cuenta tiene repos: GitHub (con su usuario) o una
/// organización de Azure DevOps. Cada uno tiene su propia credencial y sesión.
class Target {
  const Target(this.provider, this.name);
  final Provider provider;

  /// GitHub: usuario. Azure DevOps: organización (`dev.azure.com/<org>`).
  final String name;

  String get host => provider == Provider.github ? 'github.com' : 'dev.azure.com';
  String get label => provider == Provider.github ? 'GitHub $name' : 'Azure $name';

  /// Lo que se le pasa a `git credential`. En GitHub va el usuario para que el
  /// helper elija la cuenta correcta si hay dos; en Azure, el path con la
  /// organización (el GCM guarda una credencial por organización:
  /// `credential.https://dev.azure.com.useHttpPath`).
  String credentialQuery() => [
    'protocol=https',
    'host=$host',
    if (provider == Provider.azure) 'path=$name',
    if (provider == Provider.github && name.isNotEmpty) 'username=$name',
    '',
    '',
  ].join('\n');

  @override
  bool operator ==(Object other) => other is Target && other.provider == provider && other.name.toLowerCase() == name.toLowerCase();
  @override
  int get hashCode => Object.hash(provider, name.toLowerCase());
}

/// Una cuenta es una identidad: con qué nombre y email firma los commits, y en
/// qué lugares tiene repos. Por ejemplo "Trabajo": el GitHub del trabajo más la
/// organización de Azure DevOps donde están los repos de la empresa. MickHub no
/// guarda tokens: los pide al credential helper de git (gh o GCM) cada vez.
class Account {
  const Account({required this.id, required this.label, this.githubUser, this.azureOrgs = const [], this.gitName = '', this.gitEmail = ''});

  /// Lee también el formato viejo (`provider` + `org`/`username`).
  factory Account.fromJson(Map<String, dynamic> j) {
    final old = j['provider'];
    return Account(
      id: j['id'],
      label: j['label'],
      githubUser: j['githubUser'] ?? (old == 'github' ? j['username'] : null),
      azureOrgs: [...List<String>.from(j['azureOrgs'] ?? const []), if (old == 'azure' && (j['org'] ?? '').isNotEmpty) j['org']],
      gitName: j['gitName'] ?? '',
      gitEmail: j['gitEmail'] ?? '',
    );
  }

  final String id, label;
  final String? githubUser;
  final List<String> azureOrgs;
  final String gitName, gitEmail;

  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'githubUser': githubUser,
    'azureOrgs': azureOrgs,
    'gitName': gitName,
    'gitEmail': gitEmail,
  };

  List<Target> get targets => [
    if (githubUser != null && githubUser!.isNotEmpty) Target(Provider.github, githubUser!),
    for (final o in azureOrgs) Target(Provider.azure, o),
  ];

  bool get hasIdentity => gitName.trim().isNotEmpty && gitEmail.trim().isNotEmpty;

  /// Argumentos `-c` para firmar commits con esta cuenta sin tocar la config del repo.
  List<String> get identityArgs => hasIdentity ? ['-c', 'user.name=$gitName', '-c', 'user.email=$gitEmail'] : const [];

  /// Resumen de dónde vive: "GitHub mmoran-lucky · Azure LuckyERP".
  String get places => targets.map((t) => t.label).join(' · ');
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

/// Lugar (GitHub o una organización de Azure) al que apunta un remoto.
Target? targetOf(String? remoteUrl) {
  final r = remoteUrl == null ? null : parseRemote(remoteUrl);
  if (r == null) return null;
  if (r.isAzure && r.owner != null) return Target(Provider.azure, r.owner!);
  if (r.isGithub) return Target(Provider.github, r.user ?? r.owner ?? '');
  return null;
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
  bool same(String? a, String? b) => a != null && b != null && a.toLowerCase() == b.toLowerCase();
  if (r.isAzure) {
    return accounts.where((a) => a.azureOrgs.any((o) => same(o, r.owner))).firstOrNull;
  }
  if (r.isGithub) {
    final gh = accounts.where((a) => a.githubUser != null && a.githubUser!.isNotEmpty).toList();
    return gh.where((a) => same(a.githubUser, r.user)).firstOrNull ??
        gh.where((a) => same(a.githubUser, r.owner)).firstOrNull ??
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

/// Credencial de un lugar. Sin [interactive] no abre ventanas de login (el GCM
/// no pregunta); con él, deja que el helper muestre su login.
Future<Map<String, String>?> credentialFor(Target t, {bool interactive = false}) async {
  try {
    final out = await git(['credential', 'fill'], stdin: t.credentialQuery(), env: {'GCM_INTERACTIVE': interactive ? 'auto' : 'never'});
    final kv = parseKeyValues(out);
    return kv['password'] == null ? null : kv;
  } on GitException {
    return null;
  }
}

/// Verifica la sesión de un lugar pidiendo la credencial y probándola contra la API.
Future<Session> checkTarget(Target t) async {
  final cred = await credentialFor(t);
  if (cred == null) return const Session(SessionState.missing);
  try {
    final who = t.provider == Provider.github ? await _githubUser(cred['password']!) : await _azureUser(cred['password']!);
    return who == null ? const Session(SessionState.expired) : Session(SessionState.ok, who);
  } catch (e) {
    return Session(SessionState.error, '$e');
  }
}

/// Estado de la cuenta: el peor de sus lugares, con el detalle de cada uno.
Future<Session> checkSession(Account a) async {
  final ts = a.targets;
  if (ts.isEmpty) return const Session(SessionState.missing, 'sin GitHub ni Azure configurado');
  final rs = await Future.wait(ts.map(checkTarget));
  const order = [SessionState.expired, SessionState.missing, SessionState.error, SessionState.ok];
  final worst = order.firstWhere((st) => rs.any((r) => r.state == st));
  return Session(
    worst,
    [
      for (var i = 0; i < ts.length; i++) '${ts[i].label}: ${rs[i].state == SessionState.ok ? rs[i].detail : rs[i].label.toLowerCase()}',
    ].join(' · '),
  );
}

/// Inicia sesión en un lugar: descarta la credencial vencida, deja que el
/// helper muestre su login (navegador del GCM) y guarda lo que devuelva.
Future<bool> loginTarget(Target t) async {
  final old = await credentialFor(t);
  if (old != null && (await checkTarget(t)).state != SessionState.ok) {
    await git(['credential', 'reject'], stdin: _credentialText(old), okCodes: {0, 1});
  }
  final fresh = await credentialFor(t, interactive: true);
  if (fresh == null) return false;
  await git(['credential', 'approve'], stdin: _credentialText(fresh), okCodes: {0, 1});
  return (await checkTarget(t)).state == SessionState.ok;
}

/// Inicia sesión en todos los lugares de la cuenta que no estén conectados.
Future<bool> login(Account a) async {
  var ok = true;
  for (final t in a.targets) {
    if ((await checkTarget(t)).state != SessionState.ok) ok = await loginTarget(t) && ok;
  }
  return ok;
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
Future<List<Repo>> azureRepos(String org) async {
  final cred = await credentialFor(Target(Provider.azure, org));
  if (cred == null) throw HttpException('La organización $org no tiene sesión iniciada');
  final url = Uri.parse('https://dev.azure.com/${Uri.encodeComponent(org)}/_apis/git/repositories?api-version=7.1');
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

/// Página web de un commit en GitHub o Azure DevOps, según el remoto.
String? commitWebUrl(String? remoteUrl, String hash) {
  final r = remoteUrl == null ? null : parseRemote(remoteUrl);
  if (r == null) return null;
  final seg = [for (final s in r.segments) s.endsWith('.git') ? s.substring(0, s.length - 4) : s];
  if (r.isGithub && seg.length >= 2) return 'https://github.com/${seg[0]}/${seg[1]}/commit/$hash';
  if (r.host == 'dev.azure.com' && seg.length >= 4) return 'https://dev.azure.com/${seg[0]}/${seg[1]}/_git/${seg[3]}/commit/$hash';
  if (r.host.endsWith('.visualstudio.com') && seg.length >= 3) {
    return 'https://${r.host}/${seg[0]}/_git/${seg[2]}/commit/$hash';
  }
  return null;
}
