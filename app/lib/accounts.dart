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

/// Organización de Azure DevOps a partir de lo que pegue el usuario: el nombre
/// solo, o cualquier URL de Azure (de la web, de "Clonar", con usuario...).
String azureOrgFrom(String input) {
  final t = input.trim();
  if (!t.contains('/') && !t.contains('.')) return t;
  for (final url in [t, 'https://$t']) {
    final r = parseRemote(url);
    if (r != null && r.isAzure && r.owner != null) return r.owner!;
  }
  return t;
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
Future<Map<String, String>?> credentialFor(Target t, {bool interactive = false}) async => (await _fill(t, interactive: interactive)).$1;

/// `git credential fill` devolviendo también el error del helper, para mostrarlo.
/// GitHub con gh es especial: `gh auth git-credential` entrega siempre la cuenta
/// activa, así que el token de una cuenta concreta se le pide a gh directo.
Future<(Map<String, String>?, String)> _fill(Target t, {bool interactive = false}) async {
  if (t.provider == Provider.github && t.name.isNotEmpty && await githubUsesGh()) {
    final login = await ghLogin(t.name);
    final token = login == null ? null : await _gh(['auth', 'token', '--hostname', 'github.com', '--user', login]);
    if (token == null || token.isEmpty) return (null, 'gh no tiene iniciada la cuenta ${t.name}');
    return ({'protocol': 'https', 'host': 'github.com', 'username': login!, 'password': token}, '');
  }
  try {
    final out = await git(['credential', 'fill'], stdin: t.credentialQuery(), env: {'GCM_INTERACTIVE': interactive ? 'auto' : 'never'});
    final kv = parseKeyValues(out);
    return (kv['password'] == null ? null : kv, '');
  } on GitException catch (e) {
    return (null, e.message);
  }
}

/// Verifica la sesión de un lugar pidiendo la credencial y probándola contra la API.
Future<Session> checkTarget(Target t) async {
  final cred = await credentialFor(t);
  if (cred == null) return const Session(SessionState.missing);
  return _verify(t, cred['password']!);
}

Future<Session> _verify(Target t, String token) async {
  try {
    final who = t.provider == Provider.github ? await _githubUser(token) : await _azureUser(t.name, token);
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

/// Por qué no se pudo iniciar sesión en un lugar. Si se arregla corriendo un
/// comando (gh en Linux no tiene login con ventana), [command] lo trae listo
/// para copiar.
class LoginIssue {
  const LoginIssue(this.message, {this.command});
  final String message;
  final String? command;
}

/// ¿GitHub pasa por gh (`gh auth git-credential`)? En ese caso no hay login con
/// ventana: hay que correr `gh auth login` en una terminal.
Future<bool> githubUsesGh() async {
  try {
    return (await git(['config', '--get-urlmatch', 'credential.helper', 'https://github.com'])).contains('gh auth');
  } on GitException {
    return false;
  }
}

/// Corre gh sin el GH_TOKEN del entorno (si no, gh devuelve ese y no el de la
/// cuenta pedida). Devuelve stdout, o null si gh no está o falló.
Future<String?> _gh(List<String> args) async {
  try {
    final r = await Process.run('gh', args, environment: {'GH_TOKEN': '', 'GITHUB_TOKEN': ''});
    return r.exitCode == 0 ? (r.stdout as String).trim() : null;
  } on ProcessException {
    return null;
  }
}

/// Login exacto con que gh guardó la cuenta [user] (gh distingue mayúsculas y
/// GitHub no: `Mickaell22Lucky` y `mickaell22Lucky` son la misma cuenta).
Future<String?> ghLogin(String user) async {
  final out = await _gh(['auth', 'status', '--json', 'hosts']);
  if (out == null) return null;
  try {
    final hosts = ((jsonDecode(out) as Map)['hosts'] as Map)['github.com'] as List? ?? const [];
    for (final h in hosts) {
      final login = (h as Map)['login'] as String?;
      if (login != null && login.toLowerCase() == user.toLowerCase()) return login;
    }
  } catch (_) {}
  return null;
}

/// Variables de entorno para que git use la cuenta de GitHub de [a] en un repo
/// de GitHub, aunque en gh esté activa otra (gh respeta GH_TOKEN). Vacío si no
/// hace falta o no se puede.
Future<Map<String, String>> gitAuthEnv(Account? a, String? originUrl) async {
  final user = a?.githubUser;
  if (user == null || user.isEmpty || targetOf(originUrl)?.provider != Provider.github) return const {};
  final cred = await credentialFor(Target(Provider.github, user));
  return cred == null ? const {} : {'GH_TOKEN': cred['password']!};
}

/// Comando para sumar la cuenta [user] a gh y volver después a la cuenta que
/// estaba activa (gh deja activa la última que inició sesión, y git usa la
/// activa en los remotos que no dicen usuario).
String ghLoginCommand(String user, {String? active}) =>
    'gh auth login --hostname github.com --git-protocol https --web'
    '${active != null && active.isNotEmpty && active.toLowerCase() != user.toLowerCase() ? ' && gh auth switch -u $active' : ''}';

/// Inicia sesión en un lugar: descarta la credencial vencida, deja que el
/// helper muestre su login (navegador del GCM) y guarda lo que devuelva si la
/// API la acepta. Devuelve null si quedó bien o, si no, por qué.
Future<LoginIssue?> loginTarget(Target t) async {
  final old = await credentialFor(t);
  if (old != null && (await _verify(t, old['password']!)).state != SessionState.ok) {
    await git(['credential', 'reject'], stdin: _credentialText(old), okCodes: {0, 1});
  }
  final (fresh, err) = await _fill(t, interactive: true);
  if (fresh == null) {
    if (t.provider == Provider.github && await githubUsesGh()) {
      final active = (await credentialFor(const Target(Provider.github, '')))?['username'];
      return LoginIssue(
        'Para conectar GitHub ${t.name}, corre este comando en una terminal. Cuando se abra el navegador, entra con '
        '${t.name} (si ahí ya tienes otra cuenta abierta, pega el código en github.com/login/device desde una ventana '
        'privada). Al terminar, aprieta Verificar.',
        command: ghLoginCommand(t.name, active: active),
      );
    }
    return LoginIssue('${t.label}: el Git Credential Manager no devolvió ninguna credencial${err.isEmpty ? '' : ': $err'}');
  }
  final s = await _verify(t, fresh['password']!);
  if (s.state == SessionState.ok) {
    await git(['credential', 'approve'], stdin: _credentialText(fresh), okCodes: {0, 1});
    return null;
  }
  // Se descarta para que el próximo intento deje elegir otra cuenta en vez de
  // reusar esta en silencio.
  await git(['credential', 'reject'], stdin: _credentialText(fresh), okCodes: {0, 1});
  final who = fresh['username'] ?? 'la cuenta elegida';
  return LoginIssue(switch (t.provider) {
    Provider.azure =>
      '${t.label}: se entró como $who, pero Azure DevOps no la aceptó (${s.detail.isEmpty ? s.label.toLowerCase() : s.detail}). '
          'Vuelve a intentar con la cuenta que tiene acceso a la organización ${t.name}; si el GCM no te deja '
          'elegir, corre "git credential-manager azure-repos unbind ${t.name}" y prueba de nuevo.',
    Provider.github => '${t.label}: se entró como $who, pero GitHub no la aceptó (${s.detail.isEmpty ? s.label.toLowerCase() : s.detail}).',
  });
}

/// Inicia sesión en todos los lugares de la cuenta que no estén conectados.
/// Devuelve los errores (vacío si todo quedó bien).
Future<List<LoginIssue>> login(Account a) async => [
  for (final t in a.targets)
    if ((await checkTarget(t)).state != SessionState.ok) ?await loginTarget(t),
];

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

/// Quién es el token dentro de la organización [org] (null si no lo acepta).
/// Se pregunta a la organización misma (`connectionData`) y no al servicio de
/// perfiles: ese rechaza tokens válidos de empresas con acceso condicional,
/// aunque sirvan para git. Azure acepta el token del GCM como Bearer (OAuth) o
/// un PAT como Basic; se prueban los dos. Un 203 con HTML o un redirect al
/// login son su forma de decir "no autorizado".
Future<String?> _azureUser(String org, String token) async {
  final url = Uri.parse('https://dev.azure.com/${Uri.encodeComponent(org)}/_apis/connectionData');
  for (final auth in azureAuthHeaders(token)) {
    final (status, body) = await _get(url, {'Authorization': auth});
    if (status == 200) {
      final who = azureConnectionUser(body);
      if (who != null) return who;
      continue;
    }
    if (status == 404) throw HttpException('No existe la organización "$org" en Azure DevOps');
    if (status != 401 && status != 203) throw HttpException('Azure DevOps respondió $status');
  }
  return null;
}

/// Email (o nombre) del usuario de una respuesta de `connectionData`; null si
/// es anónimo o no es JSON.
String? azureConnectionUser(String body) {
  try {
    final u = (jsonDecode(body) as Map)['authenticatedUser'] as Map?;
    // Sin token Azure responde 200 igual, con un usuario anónimo de acceso público.
    if (u == null || '${u['descriptor']}'.contains('PublicAccess')) return null;
    final email = ((u['properties'] as Map?)?['Account'] as Map?)?[r'$value'] as String?;
    final name = u['providerDisplayName'] as String?;
    final who = email != null && email.isNotEmpty ? email : name;
    return who == null || who.isEmpty || who.toLowerCase().contains('anonymous') ? null : who;
  } on FormatException {
    return null;
  }
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

Future<(int, String)> _get(Uri url, Map<String, String> headers) => _request('GET', url, headers);

/// Pedido HTTP con cuerpo JSON opcional. Un redirect cuenta como 401: Azure
/// manda al login en vez de responder "no autorizado".
Future<(int, String)> _request(String method, Uri url, Map<String, String> headers, {Object? json}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final req = await client.openUrl(method, url);
    headers.forEach(req.headers.set);
    req.headers.set('User-Agent', 'MickHub');
    req.followRedirects = false;
    if (json != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(json));
    }
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    return (res.isRedirect ? 401 : res.statusCode, body);
  } finally {
    client.close();
  }
}

// --- Publicar un repo nuevo ------------------------------------------------------

/// Proyectos de una organización de Azure DevOps (un repo de Azure vive en uno).
Future<List<String>> azureProjects(String org) async {
  final (status, body) = await _azure(org, 'GET', '_apis/projects?api-version=7.1');
  if (status != 200) throw HttpException('Azure DevOps respondió $status');
  return [for (final p in (jsonDecode(body) as Map)['value'] as List) p['name'] as String]..sort();
}

/// Crea el repo vacío en el destino y devuelve su URL para clonar/pushear.
/// GitHub: bajo el usuario dueño de la credencial. Azure: en [project].
Future<String> createRemoteRepo(Target t, String name, {bool private = true, String? project}) async {
  if (t.provider == Provider.github) {
    final cred = await credentialFor(t);
    if (cred == null) throw HttpException('${t.label} no tiene sesión iniciada');
    final (status, body) = await _request(
      'POST',
      Uri.parse('https://api.github.com/user/repos'),
      {'Authorization': 'Bearer ${cred['password']}', 'Accept': 'application/vnd.github+json'},
      json: {'name': name, 'private': private},
    );
    if (status != 201) throw HttpException('GitHub no creó el repo ($status): ${_apiMessage(body)}');
    return (jsonDecode(body) as Map)['clone_url'];
  }
  final projects = await _azureProjectIds(t.name);
  final id = projects[project];
  if (id == null) throw HttpException('No existe el proyecto "$project" en ${t.name}');
  final (status, body) = await _azure(
    t.name,
    'POST',
    '_apis/git/repositories?api-version=7.1',
    json: {
      'name': name,
      'project': {'id': id},
    },
  );
  if (status != 201 && status != 200) throw HttpException('Azure DevOps no creó el repo ($status): ${_apiMessage(body)}');
  return (jsonDecode(body) as Map)['remoteUrl'];
}

Future<Map<String, String>> _azureProjectIds(String org) async {
  final (status, body) = await _azure(org, 'GET', '_apis/projects?api-version=7.1');
  if (status != 200) throw HttpException('Azure DevOps respondió $status');
  return {for (final p in (jsonDecode(body) as Map)['value'] as List) p['name'] as String: p['id'] as String};
}

/// Pedido a la API de una organización probando Bearer y Basic (ver [azureAuthHeaders]).
Future<(int, String)> _azure(String org, String method, String path, {Object? json}) async {
  final cred = await credentialFor(Target(Provider.azure, org));
  if (cred == null) throw HttpException('La organización $org no tiene sesión iniciada');
  final url = Uri.parse('https://dev.azure.com/${Uri.encodeComponent(org)}/$path');
  var last = (401, '');
  for (final auth in azureAuthHeaders(cred['password']!)) {
    last = await _request(method, url, {'Authorization': auth}, json: json);
    if (last.$1 != 401 && last.$1 != 203) return last;
  }
  return last;
}

String _apiMessage(String body) {
  try {
    final j = jsonDecode(body);
    return (j is Map ? (j['message'] ?? j['errors']?.toString()) : null)?.toString() ?? body;
  } catch (_) {
    return body;
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
