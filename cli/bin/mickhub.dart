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
  if (args.first == 'hook') return _hook();
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
// ponytail: el candado es solo entre procesos de `mickhub`; la app guarda sin
// él. Si chocan, se pierde una asignación (se arregla moviendo el archivo).
// Upgrade: que la app también tome `grupos.lock`.
Future<T> _locked<T>(String repo, Future<T> Function(ChangeGroups g, Directory dir) change) async {
  final dir = await ChangeGroups.dir(repo);
  await dir.create(recursive: true);
  final lock = File('${dir.path}/grupos.lock');
  for (var i = 0; ; i++) {
    try {
      lock.createSync(exclusive: true);
      break;
    } on FileSystemException {
      final stale = lock.existsSync() && DateTime.now().difference(lock.statSync().modified).inSeconds > 10;
      if (stale || i > 250) {
        try {
          lock.deleteSync(); // quedó de un proceso que murió
        } on FileSystemException {
          // otro lo borró primero
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }
  try {
    final g = await ChangeGroups.load(repo);
    final before = jsonEncode(g.toJson());
    final r = await change(g, dir);
    if (jsonEncode(g.toJson()) != before) await g.save(repo);
    return r;
  } finally {
    try {
      lock.deleteSync();
    } on FileSystemException {
      // ya no estaba
    }
  }
}

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
  final files = await status(repo);
  final g = await ChangeGroups.load(repo);
  final mine = g.sessions[_session];
  stdout.writeln(
    'Rama ${b.name}${b.upstream == null ? ' (sin publicar)' : ''}${b.ahead > 0 ? ' · ${b.ahead} para subir' : ''}'
    '${b.behind > 0 ? ' · ${b.behind} para traer' : ''}',
  );
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
  final changed = {for (final f in await status(repo)) f.path};
  await _locked(repo, (g, _) async {
    final group = opt ?? g.sessionGroup(_session.isEmpty ? _fail('Falta --grupo (no hay sesión).') : _session);
    if (!g.names.contains(group)) g.names = [...g.names, group];
    for (final p in rest) {
      final rel = _relative(repo, p);
      if (!changed.contains(rel)) stderr.writeln('Sin cambios (igual queda asignado): $rel');
      g.moveFile(rel, group);
    }
  });
}

/// Ruta relativa al repo, con `/`.
String _relative(String repo, String p) {
  final abs = _norm(File(p).absolute.path), root = _norm(repo);
  return abs.startsWith('$root/') ? abs.substring(root.length + 1) : _norm(p);
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

  final files = await status(repo);
  final g = await ChangeGroups.load(repo);
  final group = opt ?? g.sessions[_session];
  if (group == null) _fail('Tu sesión todavía no tiene grupo (no editó nada). Usa --grupo o `mickhub mover`.');
  final diffs = await _diffs(repo, files.where((f) => g.hunks.containsKey(f.path)).toList());
  final whole = <FileChange>[];
  final partial = <String, String>{};
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
      partial[f.path] = selectHunks(diffs[f.path]!, idx)!;
    }
  }
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
  await _locked(repo, (g, _) async => g.forget(whole.map((f) => f.path)));
  stdout.write(await git(['log', '-1', '--format=%h %s'], cwd: repo));
  stdout.writeln(
    '${whole.length + partial.length} archivo(s) del grupo "$group"${partial.isEmpty ? '' : ' (${partial.length} en parte)'}.',
  );
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
final _gitWrite = RegExp(
  r'''(^|[;&|(\s])git\s+(?:(?:-[cC]|--git-dir|--work-tree)\s+(?:"[^"]*"|'[^']*'|\S+)\s+|--?\S+\s+)*(commit|push)\b''',
);
final _dirArg = RegExp(r'''(?:\bcd|\s-C)\s+("[^"]*"|'[^']*'|[^\s;&|)]+)''');

final _quoted = RegExp('"(?:[^"\\\\]|\\\\.)*"|\'[^\']*\'');

const _editTools = {'Edit', 'Write', 'MultiEdit', 'NotebookEdit'};

/// Lo llama Claude Code antes y después de cada Bash/Edit/Write. Nunca debe
/// romper la sesión: cualquier error se ignora, salvo el bloqueo a propósito.
Future<void> _hook() async {
  Map<String, dynamic> input;
  try {
    input = jsonDecode(await stdin.transform(utf8.decoder).join()) as Map<String, dynamic>;
  } catch (_) {
    return;
  }
  final event = input['hook_event_name'], tool = input['tool_name'] as String? ?? '';
  final session = input['session_id'] as String? ?? '';
  final cwd = input['cwd'] as String? ?? Directory.current.path;
  final toolInput = (input['tool_input'] as Map?) ?? const {};
  final repos = _mickhubRepos();

  if (event == 'PreToolUse' && tool == 'Bash') {
    final cmd = toolInput['command'] as String? ?? '';
    // Lo que va entre comillas (un mensaje que dice "git push") no cuenta.
    if (_gitWrite.hasMatch(cmd.replaceAll(_quoted, 'Q'))) {
      final dirs = [cwd, for (final m in _dirArg.allMatches(cmd)) _resolve(cwd, m[1]!.replaceAll(RegExp('^["\']|["\']\$'), ''))];
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
    final repo = await _toplevel(path == null ? cwd : File(path).parent.path);
    if (repo == null || !repos.contains(_norm(repo))) return;
    final rel = path == null ? null : _relative(repo, path);
    final snapFile = File('${(await ChangeGroups.dir(repo)).path}/sesiones/$session.json');

    if (event == 'PreToolUse') {
      // Foto de los bloques de antes: lo que aparezca después es de esta sesión.
      final files = [
        for (final f in await status(repo))
          if (rel == null || f.path == rel) f,
      ];
      if (files.length > 300) return; // ponytail: repo con miles de cambios (build sin ignorar); no se reparte
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
          if (rel == null || f.path == rel) f,
      ];
      if (files.length > 300) return;
      final diffs = await _diffs(repo, files);
      await _locked(repo, (g, _) async {
        final snap = _readSnap(snapFile);
        final paths = snap['paths'] as Map<String, dynamic>;
        for (final f in files) {
          final known = paths[f.path] as List?;
          if (known == null && snap['all'] != true) continue; // sin foto de antes: no se adivina
          final before = {...?known?.cast<String>()};
          if (hunkKeys(diffs[f.path] ?? '').every(before.contains)) continue;
          g.claim(f.path, diffs[f.path] ?? '', before, g.sessionGroup(session));
        }
        if (rel == null) {
          snapFile.deleteSync();
        } else {
          paths.remove(rel);
          snapFile.writeAsStringSync(jsonEncode(snap));
        }
      });
    }
  } catch (_) {
    // el hook nunca corta el trabajo de Claude
  }
}

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
