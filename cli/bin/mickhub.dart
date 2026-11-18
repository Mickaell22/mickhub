// `mickhub`: MickHub desde la terminal, pensado para Claude Code.
//
// Cada sesión de Claude Code tiene su grupo de cambios: lo que edita cae solo
// ahí (hooks `PreToolUse`/`PostToolUse` -> `mickhub hook`) y `mickhub commit`
// commitea solo ese grupo, firmado con la cuenta del repo. En los repos de
// MickHub el hook bloquea `git commit`/`git push` directos.
//
// Compilar (desde cli/): `dart pub get && dart compile exe bin/mickhub.dart -o ~/.local/bin/mickhub`.
// Es un paquete aparte porque las dependencias de Flutter traen build hooks que
// `dart compile` no acepta; usa los archivos de la app que no dependen de Flutter.
import 'dart:convert';
import 'dart:io';

import '../../app/lib/accounts.dart';
import '../../app/lib/change_groups.dart';
import '../../app/lib/git.dart';

const _help = '''
mickhub: MickHub desde la terminal (para Claude Code).

  mickhub estado                      grupos de cambios del repo y cuál es el tuyo
  mickhub grupo <nombre>              nombra el grupo de tu sesión (si ya existe, te unes)
  mickhub mover <ruta>... [--grupo G] mueve archivos enteros a tu grupo (o a G)
  mickhub commit -m <título> [-m <descripción>] [--grupo G]
                                      commitea solo tu grupo, con la cuenta del repo
  mickhub push [args de git push]     sube con la cuenta del repo
  mickhub pull                        trae con la cuenta del repo

  mickhub apartados                   apartados (stash) con sus grupos, y respaldos
  mickhub apartar [--grupo G] [-m <nombre>]
                                      aparta tu grupo (o G), solo sus archivos y bloques
  mickhub recuperar <n|nombre>        devuelve un apartado, cada archivo a su grupo
  mickhub protegidos                  archivos protegidos (nunca se commitean), por grupo
  mickhub proteger <ruta>... | --grupo G
  mickhub desproteger <ruta>... | --grupo G

Opción global: -C <carpeta> (por defecto, la actual).
La sesión sale de CLAUDE_CODE_SESSION_ID.''';

Future<void> main(List<String> argv) async {
  final args = [...argv];
  var dir = Directory.current.path;
  final c = args.indexOf('-C');
  if (c >= 0 && c + 1 < args.length) {
    dir = args[c + 1];
    args.removeRange(c, c + 2);
  }
  if (args.isEmpty || args.first == '-h' || args.first == '--help') {
    stdout.writeln(_help);
    return;
  }
  if (args.first == 'hook') {
    await _hook();
    // Salida explícita: si stdin quedó abierto (tope de [_hook]), la VM seguiría
    // viva esperándolo y Claude Code cortaría el hook a los 10 s.
    await stdout.flush();
    exit(exitCode);
  }
  try {
    final repo = await _toplevel(dir);
    if (repo == null) _fail('No es un repo de git: $dir');
    final rest = args.sublist(1);
    switch (args.first) {
      case 'estado':
        await _status(repo);
      case 'grupo':
        await _name(repo, rest.join(' ').trim());
      case 'mover':
        await _move(repo, rest);
      case 'commit':
        await _commit(repo, rest);
      case 'push':
        await _push(repo, rest);
      case 'pull':
        await _pull(repo);
      case 'apartados':
        await _shelves(repo);
      case 'apartar':
        await _shelve(repo, rest);
      case 'recuperar':
        await _restore(repo, rest.join(' ').trim());
      case 'protegidos':
        await _protected(repo);
      case 'proteger':
        await _protect(repo, rest, on: true);
      case 'desproteger':
        await _protect(repo, rest, on: false);
      default:
        _fail('Comando desconocido: ${args.first}\n\n$_help');
    }
  } on GitException catch (e) {
    _fail(isAuthError(e.message) ? '${e.message}\n\nLa sesión de la cuenta venció: abre MickHub e inicia sesión.' : e.message);
  }
}

Never _fail(String msg) {
  stderr.writeln(msg);
  exit(1);
}

String get _session => Platform.environment['CLAUDE_CODE_SESSION_ID'] ?? '';

// --- Ajustes de la app --------------------------------------------------------------

/// El settings.json de la app (ver CLAUDE.md). MICKHUB_SETTINGS lo reemplaza.
File _settingsFile() {
  final env = Platform.environment;
  final custom = env['MICKHUB_SETTINGS'];
  if (custom != null && custom.isNotEmpty) return File(custom);
  if (Platform.isWindows) return File('${env['APPDATA']}\\com.mickaell\\mickhub\\settings.json');
  final data = env['XDG_DATA_HOME'] ?? '${env['HOME']}/.local/share';
  return File('$data/com.mickaell.mickhub/settings.json');
}

Map<String, dynamic>? _settingsCache;
Map<String, dynamic> get _settings {
  if (_settingsCache != null) return _settingsCache!;
  try {
    return _settingsCache = jsonDecode(_settingsFile().readAsStringSync()) as Map<String, dynamic>;
  } catch (_) {
    return _settingsCache = {};
  }
}

String _norm(String p) {
  var s = p.replaceAll('\\', '/');
  while (s.length > 1 && s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  return Platform.isWindows ? s.toLowerCase() : s;
}

/// Repos que MickHub tiene en su lista (como `Settings.localRepos`).
Set<String> _mickhubRepos() {
  final s = _settings;
  final found = <String>{for (final p in List<String>.from(s['extraRepos'] ?? const [])) _norm(p)};
  final reposDir = s['reposDir'] as String?;
  if (reposDir != null && Directory(reposDir).existsSync()) {
    for (final e in Directory(reposDir).listSync().whereType<Directory>()) {
      if (Directory('${e.path}/.git').existsSync()) found.add(_norm(e.path));
    }
  }
  return found;
}

Future<String?> _toplevel(String dir) async {
  var d = Directory(dir).absolute;
  while (!d.existsSync() && d.parent.path != d.path) {
    d = d.parent; // archivo nuevo en una carpeta que aún no existe
  }
  try {
    return (await git(['rev-parse', '--show-toplevel'], cwd: d.path)).trim();
  } on Object {
    return null;
  }
}

Account? _account(String repo, String? origin) {
  final s = _settings;
  final accounts = [for (final a in s['accounts'] ?? const []) Account.fromJson(a as Map<String, dynamic>)];
  final forced = Map<String, String>.from(s['repoAccounts'] ?? const {});
  final id = forced.entries.where((e) => _norm(e.key) == _norm(repo)).firstOrNull?.value;
  return accountFor(origin, accounts, overrideId: id);
}

// --- Grupos con candado ---------------------------------------------------------------

/// Lee, cambia y guarda grupos.json sin pisar a otra sesión que hace lo mismo.
// El mismo candado lo toma la app (ChangeGroups.update).
Future<T> _locked<T>(String repo, Future<T> Function(ChangeGroups g, Directory dir) change) => ChangeGroups.withLock(repo, (dir) async {
  final g = await ChangeGroups.load(repo);
  final before = jsonEncode(g.toJson());
  final r = await change(g, dir);
  if (jsonEncode(g.toJson()) != before) await g.save(repo);
  return r;
});

/// Diff contra HEAD de cada archivo con cambios, con una sola llamada a git
/// para los versionados (los hooks corren en cada comando de Claude).
Future<Map<String, String>> _diffs(String repo, List<FileChange> files) async {
  final out = <String, String>{};
  try {
    final all = await git(['-c', 'core.quotePath=false', 'diff', 'HEAD', '-M', '--no-color', '--no-ext-diff'], cwd: repo);
    for (final block in all.split(RegExp(r'^(?=diff --git )', multiLine: true))) {
      if (!block.startsWith('diff --git ')) continue;
      final lines = block.split('\n');
      String? path;
      for (final l in lines) {
        if (l.startsWith('+++ b/')) path = l.substring(6);
        if (path == null && l.startsWith('rename to ')) path = l.substring(10);
        if (l.startsWith('@@')) break;
      }
      path ??= lines.where((l) => l.startsWith('--- a/')).map((l) => l.substring(6)).firstOrNull;
      path ??= lines.first.substring(lines.first.lastIndexOf(' b/') + 3);
      out[path] = block;
    }
  } on GitException {
    // repo sin commits: va archivo por archivo
  }
  for (final f in files) {
    if (!out.containsKey(f.path)) out[f.path] = await fileDiff(repo, f).catchError((_) => '');
  }
  return out;
}

// --- Comandos ---------------------------------------------------------------------------

Future<void> _status(String repo) async {
  final b = await branchState(repo);
  final g = await reconcile(repo); // lo mismo que calcula la app antes de mostrar
  final files = await status(repo);
  final mine = g.sessions[_session];
  stdout.writeln(
    'Rama ${b.name}${b.upstream == null ? ' (sin publicar)' : ''}${b.ahead > 0 ? ' · ${b.ahead} para subir' : ''}'
    '${b.behind > 0 ? ' · ${b.behind} para traer' : ''}',
  );
  final (locked, shelved) = await (protectedFiles(repo), shelves(repo)).wait;
  if (locked.isNotEmpty) stdout.writeln('Protegidos: ${locked.length} (`mickhub protegidos`)');
  if (shelved.isNotEmpty) stdout.writeln('Apartados: ${shelved.length} (`mickhub apartados`)');
  if (files.isEmpty) return stdout.writeln('Sin cambios.');
  final diffs = await _diffs(repo, files.where((f) => g.hunks.containsKey(f.path)).toList());
  final byGroup = <String, List<String>>{};
  for (final f in files) {
    final gs = g.hunks.containsKey(f.path) ? g.hunkGroups(f.path, diffs[f.path] ?? '').toSet() : {g.groupOf(f.path)};
    for (final x in gs) {
      byGroup.putIfAbsent(x, () => []).add('${f.path}${gs.length > 1 ? ' (en parte)' : ''}');
    }
  }
  for (final name in [...g.names, '']) {
    final list = byGroup[name];
    if (list == null && name != mine) continue;
    final owners = [
      for (final e in g.sessions.entries)
        if (e.value == name) e.key.substring(0, 4),
    ];
    stdout.writeln(
      '\n${name.isEmpty ? 'Sin grupo' : name}${name == mine ? '  <- tu grupo' : ''}'
      '${owners.isNotEmpty ? '  [sesión ${owners.join(', ')}]' : ''}',
    );
    for (final p in list ?? const <String>[]) {
      stdout.writeln('  $p');
    }
  }
}

Future<void> _name(String repo, String name) async {
  if (name.isEmpty) _fail('Uso: mickhub grupo <nombre>');
  if (_session.isEmpty) _fail('Falta CLAUDE_CODE_SESSION_ID: el grupo es de una sesión de Claude Code.');
  await _locked(repo, (g, _) async {
    final old = g.sessions[_session];
    if (old == null || !g.names.contains(old)) {
      if (!g.names.contains(name)) g.names = [...g.names, name];
    } else if (old != name) {
      g.names.contains(name) ? g.merge(old, name) : g.rename(old, name);
    }
    g.sessions[_session] = name;
  });
  stdout.writeln('Tu grupo es "$name".');
}

Future<void> _move(String repo, List<String> rest) async {
  final opt = _option(rest, '--grupo');
  if (rest.isEmpty) _fail('Uso: mickhub mover <ruta>... [--grupo G]');
  final changed = [for (final f in await status(repo)) f.path];
  final moved = <String>[];
  final group = await _locked(repo, (g, _) async {
    final group = opt ?? g.sessionGroup(_session.isEmpty ? _fail('Falta --grupo (no hay sesión).') : _session);
    if (!g.names.contains(group)) g.names = [...g.names, group];
    for (final p in rest) {
      final rel = _match(changed, _relative(repo, p));
      if (rel == null) {
        stderr.writeln('Sin cambios, no se asigna: ${_relative(repo, p)}');
        continue;
      }
      g.moveFile(rel, group);
      moved.add(rel);
    }
    return group;
  });
  // Se relee del disco: lo que se confirma es lo que después muestra `estado`.
  final g = await ChangeGroups.load(repo);
  for (final p in moved) {
    stdout.writeln('${g.groupOf(p) == group ? 'En "$group"' : 'NO quedó en "$group" (está en "${g.groupOf(p)}")'}: $p');
  }
  if (moved.length < rest.length) exitCode = 1;
}

/// La ruta de git que corresponde a [rel] (en Windows sin distinguir mayúsculas:
/// "notas.sql" y "Notas.sql" son el mismo archivo y la clave debe ser la de git).
String? _match(Iterable<String> paths, String rel) => paths.where((p) => _norm(p) == _norm(rel)).firstOrNull;

/// Ruta relativa al repo, con `/`. Conserva las mayúsculas: antes salía de
/// [_norm], que en Windows la pasaba a minúsculas, y el grupo se guardaba con
/// una clave que no coincidía con la de git (el archivo seguía "Sin grupo").
String _relative(String repo, String p) {
  final abs = File(p).absolute.path.replaceAll('\\', '/');
  final root = _norm(repo);
  return _norm(abs).startsWith('$root/') ? abs.substring(root.length + 1) : p.replaceAll('\\', '/');
}

String? _option(List<String> args, String name) {
  final i = args.indexOf(name);
  if (i < 0 || i + 1 >= args.length) return null;
  final v = args[i + 1];
  args.removeRange(i, i + 2);
  return v;
}

/// Trailers y firmas que nunca van en un commit (regla dura del dueño).
final _forbidden = RegExp(
  r'co-authored-by|generated with|assisted-by|made with|claude-session|claude\.ai|claude\.com',
  caseSensitive: false,
);

Future<void> _commit(String repo, List<String> rest) async {
  final messages = <String>[];
  for (String? m; (m = _option(rest, '-m')) != null;) {
    messages.add(m!);
  }
  final opt = _option(rest, '--grupo');
  if (messages.isEmpty || messages.first.trim().isEmpty) _fail('Uso: mickhub commit -m <título> [-m <descripción>] [--grupo G]');
  final text = messages.join('\n');
  if (_forbidden.hasMatch(text)) _fail('El mensaje trae una firma o trailer de autoría prohibido. Quítalo.');

  final g = await reconcile(repo);
  final group = opt ?? g.sessions[_session];
  if (group == null) _fail('Tu sesión todavía no tiene grupo (no editó nada). Usa --grupo o `mickhub mover`.');
  if (g.protectedGroups.contains(group)) _fail('El grupo "$group" está protegido: nunca se commitea. `mickhub desproteger --grupo "$group"` lo libera.');
  final (whole, parts) = await _groupParts(repo, g, group);
  final partial = {for (final e in parts.entries) e.key: selectHunks(e.value.$1, e.value.$2)!};
  if (whole.isEmpty && partial.isEmpty) _fail('El grupo "$group" no tiene cambios. `mickhub estado` muestra qué hay.');

  final origin = await originUrl(repo);
  await commit(
    repo,
    [
      for (final f in whole) ...[f.path, ?f.oldPath],
    ],
    messages.first.trim(),
    messages.skip(1).join('\n\n'),
    identity: _account(repo, origin)?.identityArgs ?? const [],
    partial: partial,
  );
  final hash = (await git(['rev-parse', 'HEAD'], cwd: repo)).trim();
  String? renamed;
  final still = [for (final f in await status(repo)) f.path]; // lo que sigue con cambios tras el commit
  await _locked(repo, (g, _) async {
    g.recordCommit(hash, {
      group: [...whole.map((f) => f.path), ...partial.keys],
    }); // el grupo viaja con el commit (Historial)
    g.committed([group], whole.map((f) => f.path), partial.keys, changed: still); // un grupo que quedó vacío sale de la lista
    // Un grupo que llegó al commit sin nombre toma el del commit.
    if (opt == null && _autoName.hasMatch(group)) {
      final title = messages.first.trim();
      var name = title.contains(': ') ? title.substring(title.indexOf(': ') + 2) : title;
      if (name.length > 40) name = '${name.substring(0, 39)}…';
      g.names.contains(name) ? g.merge(group, name) : g.rename(group, name);
      renamed = name;
    }
  });
  await reconcile(repo);
  stdout.write(await git(['log', '-1', '--format=%h %s'], cwd: repo));
  stdout.writeln(
    '${whole.length + partial.length} archivo(s) del grupo "$group"${partial.isEmpty ? '' : ' (${partial.length} en parte)'}.',
  );
  if (renamed != null) stdout.writeln('El grupo no tenía nombre: ahora se llama "$renamed" (`mickhub grupo` lo cambia).');
}

/// Lo de [group]: archivos enteros y, de los repartidos con otros grupos, su
/// diff y los índices de sus bloques. Lo protegido no sale en `status`, así que
/// nunca entra (ni con `--grupo`).
Future<(List<FileChange>, Map<String, (String, Set<int>)>)> _groupParts(String repo, ChangeGroups g, String group) async {
  final files = await status(repo);
  final diffs = await _diffs(repo, files.where((f) => g.hunks.containsKey(f.path)).toList());
  final whole = <FileChange>[];
  final parts = <String, (String, Set<int>)>{};
  for (final f in files) {
    if (!g.hunks.containsKey(f.path)) {
      if (g.groupOf(f.path) == group) whole.add(f);
      continue;
    }
    final hg = g.hunkGroups(f.path, diffs[f.path]!);
    final idx = {
      for (var i = 0; i < hg.length; i++)
        if (hg[i] == group) i,
    };
    if (idx.length == hg.length && idx.isNotEmpty) {
      whole.add(f);
    } else if (idx.isNotEmpty) {
      parts[f.path] = (diffs[f.path]!, idx);
    }
  }
  return (whole, parts);
}

// --- Apartados y protegidos ---------------------------------------------------------------
// Lo mismo que la app (secciones Apartados y Protegidos), para que desde la
// terminal se pueda ver y arreglar sin abrirla.

Future<void> _shelves(String repo) async {
  final g = await ChangeGroups.load(repo);
  final list = await shelves(repo);
  if (list.isEmpty) stdout.writeln('Sin apartados.');
  for (var i = 0; i < list.length; i++) {
    final s = list[i];
    final files = await shelfFiles(repo, s);
    final rec = g.shelved[await shelfHash(repo, s)] ?? const {};
    final groups = {for (final f in files) rec[f] ?? g.groupOf(f)}.where((x) => x.isNotEmpty);
    stdout.writeln('$i  ${s.name}  (${s.branch}, ${files.length} archivo(s)${groups.isEmpty ? '' : ', grupo ${groups.join(', ')}'})');
    for (final f in files) {
      stdout.writeln('     $f');
    }
  }
  final backups = await shelfBackups(repo);
  if (backups.isEmpty) return;
  stdout.writeln('\nRespaldos de apartados recuperados o eliminados (el más nuevo primero):');
  for (final (h, name, date) in backups.take(10)) {
    stdout.writeln('  ${h.substring(0, 10)}  $name  ${date.toLocal()}');
  }
  stdout.writeln('Para volver a ponerlo en la lista: git stash store -m "<nombre>" <hash>');
}

Future<void> _shelve(String repo, List<String> rest) async {
  final opt = _option(rest, '--grupo');
  final name = _option(rest, '-m');
  final g = await reconcile(repo);
  final group = opt ?? g.sessions[_session] ?? _fail('Tu sesión no tiene grupo: usa --grupo G.');
  if (!g.names.contains(group)) _fail('No existe el grupo "$group". `mickhub estado` muestra los grupos.');
  final (whole, parts) = await _groupParts(repo, g, group);
  if (whole.isEmpty && parts.isEmpty) _fail('El grupo "$group" no tiene cambios.');
  final title = name ?? group;
  await shelveGrouped(
    repo,
    title,
    whole: [
      for (final f in whole) ...[f.path, ?f.oldPath],
    ],
    parts: parts,
  );
  await reconcile(repo);
  stdout.writeln(
    'Apartado "$title": ${whole.length + parts.length} archivo(s) de "$group"'
    '${parts.isEmpty ? '' : ' (${parts.length} en parte)'}. `mickhub recuperar "$title"` lo devuelve.',
  );
}

Future<void> _restore(String repo, String which) async {
  if (which.isEmpty) _fail('Uso: mickhub recuperar <n|nombre>');
  final list = await shelves(repo);
  final n = int.tryParse(which);
  final s =
      (n != null && n >= 0 && n < list.length ? list[n] : list.where((s) => s.name == which).firstOrNull) ??
      _fail('No hay un apartado "$which". `mickhub apartados` los lista.');
  final r = await unshelveGrouped(repo, s);
  await reconcile(repo);
  stdout.writeln('Recuperado "${s.name}" (queda un respaldo, ver `mickhub apartados`).');
  if (r.skipped.isNotEmpty) stdout.writeln('Ya estaban iguales, no se tocaron: ${r.skipped.join(', ')}');
}

Future<void> _protected(String repo) async {
  final g = await ChangeGroups.load(repo);
  final list = await protectedFiles(repo);
  if (list.isEmpty) return stdout.writeln('Sin protegidos.');
  final by = <String, List<Protected>>{};
  for (final p in list) {
    by.putIfAbsent(g.groupOf(p.path), () => []).add(p);
  }
  for (final e in by.entries) {
    stdout.writeln(
      '${e.key.isEmpty ? 'Sin grupo' : e.key} (${e.value.length})'
      '${g.protectedGroups.contains(e.key) ? '  [grupo protegido: lo que entre se protege solo]' : ''}',
    );
    for (final p in e.value) {
      stdout.writeln('  ${p.path}${p.tracked ? '' : '  (nuevo: .git/info/exclude)'}');
    }
  }
}

Future<void> _protect(String repo, List<String> rest, {required bool on}) async {
  final opt = _option(rest, '--grupo');
  if (opt == null && rest.isEmpty) _fail('Uso: mickhub ${on ? '' : 'des'}proteger <ruta>... | --grupo G');
  final g = await reconcile(repo);
  final done = <String>[];
  if (opt != null) {
    if (!g.names.contains(opt)) _fail('No existe el grupo "$opt".');
    if (on) {
      final (prot, split) = await protectGroup(repo, opt);
      for (final p in split) {
        stderr.writeln('Repartido con otro grupo, no se protege a medias: $p');
      }
      stdout.writeln('Grupo "$opt" protegido: ${prot.length} archivo(s) ahora y lo que entre después.');
    } else {
      final un = await unprotectGroup(repo, opt);
      stdout.writeln('Grupo "$opt" desprotegido: ${un.length} archivo(s) vuelven a Cambios.');
    }
    return;
  }
  if (on) {
    final files = await status(repo);
    final targets = opt != null
        ? files.where((f) => g.groupOf(f.path) == opt || (g.hunks[f.path]?.containsValue(opt) ?? false)).toList()
        : [
            for (final p in rest)
              files.where((f) => _norm(f.path) == _norm(_relative(repo, p))).firstOrNull ?? _fail('Sin cambios: ${_relative(repo, p)}'),
          ];
    for (final f in targets) {
      if (g.hunks.containsKey(f.path)) {
        stderr.writeln('Repartido con otro grupo, no se protege a medias: ${f.path}');
        continue;
      }
      await protect(repo, f);
      done.add(f.path);
    }
  } else {
    final locked = await protectedFiles(repo);
    final targets = opt != null
        ? locked.where((p) => g.groupOf(p.path) == opt).toList()
        : [
            for (final r in rest)
              locked.where((p) => _norm(p.path) == _norm(_relative(repo, r))).firstOrNull ?? _fail('No está protegido: ${_relative(repo, r)}'),
          ];
    for (final p in targets) {
      await unprotectFile(repo, p);
      done.add(p.path);
    }
  }
  if (done.isEmpty) _fail('Nada que ${on ? '' : 'des'}proteger${opt == null ? '' : ' en "$opt"'}.');
  stdout.writeln('${on ? 'Protegidos' : 'Desprotegidos'} ${done.length}: ${done.join(', ')}');
}

Future<void> _push(String repo, List<String> rest) async {
  final origin = await originUrl(repo);
  final env = await gitAuthEnv(_account(repo, origin), origin);
  final b = await branchState(repo);
  final args = rest.isNotEmpty ? rest : (b.upstream == null ? ['-u', 'origin', 'HEAD'] : <String>[]);
  if (rest.isEmpty && b.behind > 0) _fail('Hay ${b.behind} commit(s) para traer antes de subir: `mickhub pull`.');
  await git(['push', ...args], cwd: repo, env: env);
  stdout.writeln('Subido${rest.isEmpty ? ' ${b.name}' : ''}.');
}

Future<void> _pull(String repo) async {
  final origin = await originUrl(repo);
  final account = _account(repo, origin);
  try {
    await pull(repo, identity: account?.identityArgs ?? const [], env: await gitAuthEnv(account, origin));
  } on GitException catch (e) {
    final blocked = pullBlockedBy(e.message);
    if (blocked == null) rethrow;
    _fail(
      'El pull pisaría cambios sin commitear en: ${blocked.join(', ')}.\nResuélvelo desde MickHub (apartar, traer y volver a ponerlos).',
    );
  }
  stdout.writeln('Al día.');
}

// --- Hooks de Claude Code -----------------------------------------------------------------

/// `git commit` o `git push` (con o sin opciones antes del subcomando).
/// Órdenes de subir: "haz push", "dale push", "commit y push", "pushea", "súbelo",
/// "sube lo de lucky", "sube los cambios", "en el repo de github", "a github".
/// Una palabra suelta no basta: "solo commit y no push" no debe dar permiso.
final _pushOrder = RegExp(
  r'\b(haz|hazle|has|dale|hacer|y)\s+(el\s+|un\s+)?push\b|\bpushea\w*|\bs[uú]bel[oa]s?\b|\bs[uú]be\s+(lo|los|todo|eso|esto)\b|\b(a|al|en\s+el)\s+(repo\s+(de\s+)?)?github\b',
  caseSensitive: false,
);

/// El mensaje pide subir y esa orden no está negada ("no hagas push", "y no push").
bool _asksPush(String prompt) => _pushOrder
    .allMatches(prompt)
    .any((m) => !RegExp(r'\bno\b[^.,;!?]{0,12}$', caseSensitive: false).hasMatch(prompt.substring(0, m.start)));
final _gitPush = RegExp(r'''(^|[;&|(\s])git\s+(?:(?:-[cC]|--git-dir|--work-tree)\s+(?:"[^"]*"|'[^']*'|\S+)\s+|--?\S+\s+)*push\b''');
final _mickhubPush = RegExp(r'''(^|[;&|(\s])mickhub(\.exe)?\s+(?:-C\s+(?:"[^"]*"|'[^']*'|\S+)\s+)?push\b''');

String _cacheDir() {
  final env = Platform.environment;
  return Platform.isWindows ? '${env['LOCALAPPDATA']}\\mickhub' : '${env['XDG_CACHE_HOME'] ?? '${env['HOME']}/.cache'}/mickhub';
}

final _gitWrite = RegExp(
  r'''(^|[;&|(\s])git\s+(?:(?:-[cC]|--git-dir|--work-tree)\s+(?:"[^"]*"|'[^']*'|\S+)\s+|--?\S+\s+)*(commit|push)\b''',
);
final _dirArg = RegExp(r'''(?:\bcd|\s-C)\s+("[^"]*"|'[^']*'|[^\s;&|)]+)''');

final _quoted = RegExp('"(?:[^"\\\\]|\\\\.)*"|\'[^\']*\'');

// ponytail: mira el comando entero; `git stash pop && sed -i ...` tampoco
// reparte lo del sed. Upgrade: foto antes y después de cada parte del comando.
final _movesChanges = RegExp(
  r'''(^|[;&|(\s])(git\s+(?:(?:-[cC]|--git-dir|--work-tree)\s+(?:"[^"]*"|'[^']*'|\S+)\s+|--?\S+\s+)*'''
  r'''(stash|checkout|switch|restore|reset|pull|merge|rebase|cherry-pick|revert|am)\b|mickhub(\.exe)?\s)''',
);

const _editTools = {'Edit', 'Write', 'MultiEdit', 'NotebookEdit'};

/// Lo llama Claude Code antes y después de cada Bash/Edit/Write. Nunca debe
/// romper la sesión: cualquier error se ignora, salvo el bloqueo a propósito.
Future<void> _hook() async {
  Map<String, dynamic> input;
  try {
    // Con tope: si stdin no se cierra, mejor no hacer nada que pasar los 10 s
    // del hook (Claude Code lo corta y avisa en cada mensaje).
    input = jsonDecode(await stdin.transform(utf8.decoder).join().timeout(const Duration(seconds: 3))) as Map<String, dynamic>;
  } catch (_) {
    return;
  }
  final event = input['hook_event_name'], tool = input['tool_name'] as String? ?? '';
  final session = input['session_id'] as String? ?? '';
  final cwd = input['cwd'] as String? ?? Directory.current.path;
  final toolInput = (input['tool_input'] as Map?) ?? const {};

  // Regla del dueño: Claude commitea pero no sube; el push lo hace él, salvo
  // que lo pida textualmente en su mensaje. Cada mensaje enciende o apaga el
  // permiso para ese turno.
  final pushFlag = File('${_cacheDir()}/push/${session.isEmpty ? 'sin-sesion' : session}');
  if (event == 'UserPromptSubmit') {
    if (_asksPush(input['prompt'] as String? ?? '')) {
      pushFlag.parent.createSync(recursive: true);
      pushFlag.writeAsStringSync('ok');
    } else if (pushFlag.existsSync()) {
      pushFlag.deleteSync();
    }
    return;
  }
  // Recién aquí: recorrer la carpeta de repos no hace falta para el mensaje del
  // dueño, que es el hook que se le cortaba por tiempo en Windows.
  final repos = _mickhubRepos();
  if (event == 'PreToolUse' && tool == 'Bash') {
    final cmd = toolInput['command'] as String? ?? '';
    final bare = cmd.replaceAll(_quoted, 'Q');
    if ((_gitPush.hasMatch(bare) || _mickhubPush.hasMatch(bare)) && !pushFlag.existsSync()) {
      stderr.writeln(
        'Push bloqueado: el dueño sube a mano. Haz solo el commit y dile que quedó listo para subir; '
        'el push va únicamente si lo pide textualmente en su mensaje ("haz push", "súbelo").',
      );
      exit(2);
    }
    // Lo que va entre comillas (un mensaje que dice "git push") no cuenta.
    if (_gitWrite.hasMatch(cmd.replaceAll(_quoted, 'Q'))) {
      final dirs = _dirs(cwd, cmd);
      for (final d in dirs) {
        final top = await _toplevel(d);
        if (top != null && repos.contains(_norm(top))) {
          stderr.writeln(
            'En los repos de MickHub los commits y push van por MickHub, no por git directo:\n'
            '  mickhub commit -m "<título>" [-m "<descripción>"]   (solo el grupo de tu sesión)\n'
            '  mickhub push\n'
            '`mickhub estado` muestra tu grupo; `mickhub grupo "<nombre>"` le pone nombre.',
          );
          exit(2);
        }
      }
    }
  }
  if (session.isEmpty) return;

  try {
    final String? path = _editTools.contains(tool) ? (toolInput['file_path'] ?? toolInput['notebook_path']) as String? : null;
    if (tool != 'Bash' && path == null) return;
    // En un Bash, el repo de la sesión y los de cada `cd`/`-C` del comando.
    final command = toolInput['command'] as String? ?? '';
    // Un comando que solo mueve cambios que ya existían (recuperar un apartado,
    // cambiar de rama, traer) no es trabajo de esta sesión: antes se los
    // quedaba y lo recuperado caía en "Sesión xxxx" en vez de en su grupo.
    if (path == null && _movesChanges.hasMatch(command.replaceAll(_quoted, 'Q'))) return;
    final dirs = path != null ? [File(path).parent.path] : _dirs(cwd, command);
    final seen = <String>{};
    final created = <String>[];
    for (final d in dirs) {
      final repo = await _toplevel(d);
      if (repo == null || !repos.contains(_norm(repo)) || !seen.add(_norm(repo))) continue;
      final g = await _track(repo, path == null ? null : _relative(repo, path), event as String?, session);
      if (g != null) created.add('"$g" (en ${repo.split(RegExp(r'[\\/]')).last})');
    }
    if (created.isNotEmpty) {
      // Para que el grupo no quede como "Sesión a3bf": Claude ya sabe en qué trabaja.
      stdout.writeln(
        jsonEncode({
          'hookSpecificOutput': {
            'hookEventName': 'PostToolUse',
            'additionalContext':
                'MickHub: lo que editas cae en tu grupo ${created.join(', ')}. Ponle nombre según la tarea '
                'con `mickhub grupo "<tarea>"` desde esa carpeta (si ya existe un grupo con ese nombre, te unes a él).',
          },
        }),
      );
    }
  } catch (_) {
    // el hook nunca corta el trabajo de Claude
  }
}

/// Nombre que pone [ChangeGroups.sessionGroup] mientras Claude no elige uno.
final _autoName = RegExp(r'^Sesión [0-9a-zA-Z-]{1,4}( \(\d+\))?$');

/// Foto antes de la herramienta y reparto después (ver [_hook]). [rel] es el
/// archivo que edita (null = un Bash: todo el repo). Devuelve el grupo si lo
/// acaba de crear (para pedirle a Claude que lo nombre).
Future<String?> _track(String repo, String? rel, String? event, String session) async {
  final snapFile = File('${(await ChangeGroups.dir(repo)).path}/sesiones/$session.json');
  String? created;

  if (event == 'PreToolUse') {
    // Foto de los bloques de antes: lo que aparezca después es de esta sesión.
    final files = [
      for (final f in await status(repo))
        if (rel == null || _norm(f.path) == _norm(rel)) f,
    ];
    if (files.length > 300) return null; // ponytail: repo con miles de cambios (build sin ignorar); no se reparte
    final diffs = await _diffs(repo, files);
    await _locked(repo, (_, _) async {
      final snap = _readSnap(snapFile);
      if (rel == null) snap['all'] = true;
      final paths = (snap['paths'] as Map<String, dynamic>);
      if (rel != null) paths[rel] = <String>[];
      for (final f in files) {
        paths[f.path] = hunkKeys(diffs[f.path] ?? '');
      }
      await snapFile.parent.create(recursive: true);
      snapFile.writeAsStringSync(jsonEncode(snap));
    });
  } else if (event == 'PostToolUse') {
    final files = [
      for (final f in await status(repo))
        if (rel == null || _norm(f.path) == _norm(rel)) f,
    ];
    if (files.length > 300) return null;
    final diffs = await _diffs(repo, files);
    await _locked(repo, (g, _) async {
      final snap = _readSnap(snapFile);
      final paths = snap['paths'] as Map<String, dynamic>;
      for (final f in files) {
        final known = paths[f.path] as List?;
        if (known == null && snap['all'] != true) continue; // sin foto de antes: no se adivina
        final before = {...?known?.cast<String>()};
        if (hunkKeys(diffs[f.path] ?? '').every(before.contains)) continue;
        final isNew = !g.sessions.containsKey(session);
        g.claim(f.path, diffs[f.path] ?? '', before, g.sessionGroup(session));
        if (isNew) created = g.sessions[session];
      }
      if (rel == null) {
        snapFile.deleteSync();
      } else {
        paths.remove(rel);
        snapFile.writeAsStringSync(jsonEncode(snap));
      }
    });
  }
  return created;
}

/// La carpeta actual y las de cada `cd <dir>` o `git -C <dir>` del comando.
List<String> _dirs(String cwd, String cmd) => [
  cwd,
  for (final m in _dirArg.allMatches(cmd)) _resolve(cwd, m[1]!.replaceAll(RegExp('^["\']|["\']\$'), '')),
];

String _resolve(String cwd, String p) {
  if (p.startsWith('~/')) p = '${Platform.environment['HOME']}${p.substring(1)}';
  return p.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(p) ? p : '$cwd/$p';
}

Map<String, dynamic> _readSnap(File f) {
  try {
    final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    j['paths'] = Map<String, dynamic>.from(j['paths'] as Map? ?? const {});
    return j;
  } catch (_) {
    return {'paths': <String, dynamic>{}};
  }
}
