import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class GitException implements Exception {
  GitException(this.args, this.message);
  final List<String> args;
  final String message;

  @override
  String toString() => 'git ${args.join(' ')}: $message';
}

/// Corre el `git` instalado en el sistema y devuelve su salida estándar.
/// Sin prompts de terminal: si falta una credencial, falla en vez de colgarse.
/// [okCodes] son los códigos de salida que no cuentan como error (p. ej. `git
/// diff --no-index` sale con 1 cuando hay diferencias). [lossy] cambia los bytes
/// que no son UTF-8 (archivos en Latin-1, comunes en Windows) por U+FFFD en vez
/// de fallar: solo para texto que no vuelve a git (lo que se manda a la IA); un
/// parche armado así y aplicado escribiría esos bytes cambiados.
// Los mensajes de git van siempre en inglés (`LANGUAGE=C`): MickHub reconoce
// errores por su texto (pull bloqueado, sesión vencida, conflictos) y con git en
// español no los detectaba. Solo cambia los mensajes, no las rutas ni el contenido.
Future<String> git(
  List<String> args, {
  String? cwd,
  String? stdin,
  Set<int> okCodes = const {0},
  Map<String, String> env = const {},
  bool lossy = false,
}) async {
  final p = await Process.start('git', args, workingDirectory: cwd, environment: {'GIT_TERMINAL_PROMPT': '0', 'LANGUAGE': 'C', ...env});
  final out = p.stdout.transform(Utf8Decoder(allowMalformed: lossy)).join();
  final err = p.stderr.transform(utf8.decoder).join();
  if (stdin != null) p.stdin.write(stdin);
  await p.stdin.close();
  if (!okCodes.contains(await p.exitCode)) throw GitException(args, (await err).trim());
  return out;
}

/// Contenido de [path] en la versión [rev] (`HEAD`, un hash, `<hash>^`...), en
/// bytes crudos: [git] decodifica como texto y rompería una imagen. Null si en
/// esa versión el archivo no existe.
Future<Uint8List?> blobAt(String repo, String rev, String path) async {
  final r = await Process.run('git', ['show', '$rev:$path'], workingDirectory: repo, stdoutEncoding: null);
  return r.exitCode == 0 ? Uint8List.fromList(r.stdout as List<int>) : null;
}

/// Para las lecturas que MickHub hace seguido (status): sin esto `git status`
/// toma un momento `.git/index.lock` para refrescar el índice y choca con un
/// commit o un cambio de rama hecho a la vez en GitHub Desktop o la terminal
/// ("index.lock: File exists"). Desktop hace lo mismo.
const readOnly = {'GIT_OPTIONAL_LOCKS': '0'};

/// Pares `clave=valor` del protocolo de credenciales de git.
Map<String, String> parseKeyValues(String s) => {
  for (final l in LineSplitter.split(s))
    if (l.contains('=')) l.substring(0, l.indexOf('=')): l.substring(l.indexOf('=') + 1),
};

/// Token para [host] pedido al credential helper de git (gh, Git Credential
/// Manager...). MickHub nunca guarda tokens: se los pide a git cada vez.
Future<String?> credentialToken(String host) async {
  try {
    final out = await git(['credential', 'fill'], stdin: 'protocol=https\nhost=$host\n\n');
    return parseKeyValues(out)['password'];
  } on GitException {
    return null;
  }
}

enum FileStatus { added, modified, deleted, renamed, conflicted }

class FileChange {
  const FileChange(this.path, this.status, {this.oldPath});
  final String path;
  final FileStatus status;
  final String? oldPath;
}

/// Parsea `git status --porcelain=v1 -z`. En un renombre la entrada trae el
/// destino y la siguiente entrada es el origen.
List<FileChange> parseStatus(String out) {
  final parts = out.split('\x00');
  final changes = <FileChange>[];
  for (var i = 0; i < parts.length; i++) {
    final e = parts[i];
    if (e.length < 4) continue;
    final x = e[0], y = e[1], path = e.substring(3);
    final xy = '$x$y';
    if (x == 'R' || y == 'R') {
      changes.add(FileChange(path, FileStatus.renamed, oldPath: parts[++i]));
    } else if (xy == '??' || x == 'A') {
      changes.add(FileChange(path, FileStatus.added));
    } else if (x == 'U' || y == 'U' || xy == 'AA' || xy == 'DD') {
      changes.add(FileChange(path, FileStatus.conflicted));
    } else if (x == 'D' || y == 'D') {
      changes.add(FileChange(path, FileStatus.deleted));
    } else {
      changes.add(FileChange(path, FileStatus.modified));
    }
  }
  return changes;
}

Future<List<FileChange>> status(String repo) async =>
    parseStatus(await git(['status', '--porcelain=v1', '-z', '--untracked-files=all'], cwd: repo, env: readOnly));

/// Diff de un archivo con cambios sin commitear (contra HEAD, o contra nada si
/// es nuevo).
Future<String> fileDiff(String repo, FileChange f) async {
  if (f.status == FileStatus.added && !await isTracked(repo, f.path)) {
    return git(['diff', '--no-index', '--', '/dev/null', f.path], cwd: repo, okCodes: {0, 1});
  }
  return git(['diff', 'HEAD', '-M', '--', if (f.oldPath != null) f.oldPath!, f.path], cwd: repo);
}

Future<bool> isTracked(String repo, String path) async {
  try {
    await git(['ls-files', '--error-unmatch', '--', path], cwd: repo);
    return true;
  } on GitException {
    return false;
  }
}

/// Commitea solo [paths], como GitHub Desktop: lo que no se eligió no entra
/// aunque estuviera en el stage.
/// [identity] son los `-c user.name=… -c user.email=…` de la cuenta del repo.
///
/// [partial] son archivos que entran solo en parte: ruta -> parche con los
/// bloques elegidos (de [selectHunks] sobre su diff contra HEAD).
Future<void> commit(
  String repo,
  List<String> paths,
  String summary,
  String description, {
  List<String> identity = const [],
  Map<String, String> partial = const {},
}) async {
  await git(['reset', '-q'], cwd: repo, okCodes: {0, 1, 128}); // 128: repo sin commits todavía
  if (paths.isNotEmpty) await git(['add', '-A', '--', ...paths], cwd: repo);
  for (final patch in partial.values) {
    await git(['apply', '--cached', '-'], cwd: repo, stdin: patch); // solo esos bloques al stage
  }
  await git([
    ...identity,
    'commit',
    '-m',
    summary,
    if (description.trim().isNotEmpty) ...['-m', description.trim()],
  ], cwd: repo);
}

class BranchState {
  const BranchState(this.name, {this.upstream, this.ahead = 0, this.behind = 0});
  final String name;
  final String? upstream;
  final int ahead, behind;
}

/// Rama y cantidad de archivos cambiados, en una sola llamada a git. Es lo que
/// muestra la lista de repos (punto de cambios, ↓↑) y la barra; barato a
/// propósito porque se pide para todos los repos.
class RepoSummary {
  const RepoSummary(this.branch, this.changes);
  final BranchState branch;
  final int changes;
}

/// Lee la salida de `git status --porcelain=v2 --branch`.
RepoSummary parseSummary(String out) {
  String? head, upstream;
  int? ahead, behind;
  var changes = 0;
  for (final l in LineSplitter.split(out)) {
    if (l.startsWith('# branch.head ')) {
      head = l.substring(14);
    } else if (l.startsWith('# branch.upstream ')) {
      upstream = l.substring(18);
    } else if (l.startsWith('# branch.ab ')) {
      final ab = l.substring(12).split(' ');
      ahead = int.parse(ab[0].substring(1));
      behind = int.parse(ab[1].substring(1));
    } else if (l.isNotEmpty && !l.startsWith('#')) {
      changes++;
    }
  }
  final name = head == null || head == '(detached)' ? 'HEAD desacoplado' : head;
  // Sin línea `branch.ab` el upstream no existe en el remoto (p. ej. lo
  // borraron): se trata como sin upstream, así sincronizar lo vuelve a publicar.
  if (ahead == null) return RepoSummary(BranchState(name), changes);
  return RepoSummary(BranchState(name, upstream: upstream, ahead: ahead, behind: behind!), changes);
}

Future<RepoSummary> repoSummary(String repo) async =>
    parseSummary(await git(['status', '--porcelain=v2', '--branch'], cwd: repo, env: readOnly));

Future<BranchState> branchState(String repo) async => (await repoSummary(repo)).branch;

/// Fetch en segundo plano: sin ventanas de login (si la sesión venció, falla
/// callado y el usuario se entera al sincronizar).
Future<void> backgroundFetch(String repo, {Map<String, String> env = const {}}) =>
    git(['fetch', '--prune', '--quiet'], cwd: repo, env: {'GCM_INTERACTIVE': 'never', ...env});

/// Ramas locales y, después, las remotas que no tienen local (`origin/x`): un
/// repo recién clonado solo tiene una local.
Future<(List<String> local, List<String> remote)> allBranches(String repo) async {
  final refs = LineSplitter.split(await git(['for-each-ref', '--format=%(refname)', 'refs/heads', 'refs/remotes'], cwd: repo)).toList();
  const heads = 'refs/heads/', remotes = 'refs/remotes/';
  final local = [
    for (final r in refs)
      if (r.startsWith(heads)) r.substring(heads.length),
  ];
  final remote = [
    for (final r in refs)
      if (r.startsWith(remotes) && !r.endsWith('/HEAD')) r.substring(remotes.length),
  ];
  return (
    local,
    [
      for (final r in remote)
        if (!local.contains(r.substring(r.indexOf('/') + 1))) r,
    ],
  );
}

class Commit {
  const Commit(this.hash, this.author, this.date, this.summary, {this.email = ''});
  final String hash, author, summary, email;
  final DateTime date;

  String get shortHash => hash.substring(0, 7);
}

/// Parsea `git log` con campos separados por \x1f y commits por \x1e.
List<Commit> parseLog(String out) => [
  for (final rec in out.split('\x1e'))
    if (rec.trim().isNotEmpty)
      () {
        final f = rec.trim().split('\x1f');
        // Campos: hash, autor, fecha, asunto y (opcional) email del autor.
        return Commit(f[0], f[1], DateTime.parse(f[2]), f[3], email: f.length > 4 ? f[4] : '');
      }(),
];

const _logFormat = '--format=%H%x1f%an%x1f%aI%x1f%s%x1f%ae%x1e';

/// Commits por página del historial.
const logPage = 200;

/// Una página del historial de la rama actual, empezando en [skip].
Future<List<Commit>> log(String repo, {int skip = 0}) async {
  try {
    return parseLog(await git(['log', '-n', '$logPage', '--skip', '$skip', _logFormat], cwd: repo));
  } on GitException {
    return []; // repo sin commits
  }
}

/// Commits hechos entre [since] y [until] en todas las ramas (locales, remotas
/// y tags), sin merges y sin repetir: un commit que llegó a varias ramas por
/// PR sale una vez. Con [authors], solo los de alguno de esos nombres o emails
/// (sin distinguir mayúsculas). `--all` no sirve: incluye los stashes y los
/// respaldos de MickHub, y el commit del índice de un stash no es un merge.
Future<List<Commit>> periodCommits(String repo, DateTime since, DateTime until, {List<String> authors = const []}) async {
  try {
    return parseLog(
      await git([
        'log',
        '--branches',
        '--remotes',
        '--tags',
        '--no-merges',
        '--since=${since.toIso8601String()}',
        '--until=${until.toIso8601String()}',
        ..._authorArgs(authors),
        _logFormat,
      ], cwd: repo),
    );
  } on GitException {
    return []; // repo sin commits
  }
}

/// `--author` por cada identidad (cualquiera calza), sin distinguir mayúsculas.
List<String> _authorArgs(List<String> authors) {
  final who = authors.where((a) => a.trim().isNotEmpty).toSet();
  return who.isEmpty ? const [] : ['-i', '--fixed-strings', for (final a in who) '--author=$a'];
}

/// Lo que trae la rama actual respecto de [base]: sus commits que [base] no
/// tiene, sin merges. Lo que entró al ponerla al día con la base (por merge,
/// rebase o fast-forward) ya está en [base] y no cuenta; lo ya llevado por un
/// PR tampoco.
Future<List<Commit>> branchCommits(String repo, String base, {List<String> authors = const []}) async {
  try {
    return parseLog(await git(['log', '$base..HEAD', '--no-merges', ..._authorArgs(authors), _logFormat], cwd: repo));
  } on GitException {
    return [];
  }
}

/// Nombre de la rama actual (o "HEAD" si está suelta).
Future<String> currentBranchName(String repo) async => (await git(['rev-parse', '--abbrev-ref', 'HEAD'], cwd: repo)).trim();

/// Ramas contra las que comparar (las remotas, al día tras el fetch; sin
/// remoto, las locales) y la principal del remoto, si se sabe.
Future<(List<String>, String?)> baseBranches(String repo) async {
  final remote = LineSplitter.split(await git(['for-each-ref', '--format=%(refname)', 'refs/remotes'], cwd: repo))
      .where((r) => !r.endsWith('/HEAD'))
      .map((r) => r.substring('refs/remotes/'.length))
      .toList();
  if (remote.isEmpty) return ((await allBranches(repo)).$1, null);
  String? main;
  try {
    main = (await git(['symbolic-ref', '-q', '--short', 'refs/remotes/origin/HEAD'], cwd: repo)).trim();
  } on GitException {
    main = null; // el remoto no dijo cuál es su principal
  }
  return (remote, remote.contains(main) ? main : null);
}

/// Un commit por su hash (de cualquier rama), o null si este repo no lo tiene.
Future<Commit?> commitByHash(String repo, String hash) async {
  try {
    return parseLog(await git(['log', '-n', '1', _logFormat, hash, '--'], cwd: repo)).firstOrNull;
  } on GitException {
    return null;
  }
}

/// Busca en todo el historial de la rama: mensaje y autor (sin distinguir
/// mayúsculas) y, si parece un hash, ese commit. Sin duplicados, más nuevos primero.
Future<List<Commit>> searchLog(String repo, String query) async {
  final q = query.trim();
  if (q.isEmpty) return log(repo);
  Future<List<Commit>> run(List<String> filter) async {
    try {
      return parseLog(await git(['log', '-n', '500', '-i', '--fixed-strings', ...filter, _logFormat], cwd: repo));
    } on GitException {
      return [];
    }
  }

  final results = await Future.wait([
    run(['--grep', q]),
    run(['--author', q]),
    if (RegExp(r'^[0-9a-fA-F]{4,40}$').hasMatch(q)) run(['-n', '1', '$q^{commit}', '--no-walk']),
  ]);
  final seen = <String>{};
  return [
    for (final c in results.expand((r) => r))
      if (seen.add(c.hash)) c,
  ]..sort((a, b) => b.date.compareTo(a.date));
}

/// Archivos tocados por un commit, con su estado.
Future<List<FileChange>> commitFiles(String repo, String hash) async {
  // Un merge se muestra contra su primer padre (la rama antes del merge), como
  // Desktop: lo que trajo. Sin esto git solo lista lo que tuvo conflicto, y
  // casi siempre sale vacío.
  final out = await git(['show', '--format=', '--name-status', '-M', '-z', '--diff-merges=first-parent', hash], cwd: repo);
  final p = out.split('\x00');
  final files = <FileChange>[];
  for (var i = 0; i + 1 < p.length; i++) {
    final s = p[i].trim();
    if (s.isEmpty) continue;
    if (s.startsWith('R')) {
      files.add(FileChange(p[i + 2], FileStatus.renamed, oldPath: p[i + 1]));
      i += 2;
    } else {
      final st = switch (s[0]) {
        'A' => FileStatus.added,
        'D' => FileStatus.deleted,
        _ => FileStatus.modified,
      };
      files.add(FileChange(p[++i], st));
    }
  }
  return files;
}

Future<String> commitFileDiff(String repo, String hash, FileChange f) =>
    git(['show', '--format=', '-M', '--diff-merges=first-parent', hash, '--', if (f.oldPath != null) f.oldPath!, f.path], cwd: repo, lossy: true); // solo se muestra

/// URL del remoto `origin`, o null si no tiene.
Future<String?> originUrl(String repo) async {
  try {
    return (await git(['remote', 'get-url', 'origin'], cwd: repo)).trim();
  } on GitException {
    return null;
  }
}

/// Clave para comparar URLs de remotos sin importar `.git`, mayúsculas ni el
/// usuario embebido (`https://user@host/...`).
String remoteKey(String url) =>
    url.toLowerCase().replaceFirst(RegExp(r'^https?://([^@/]+@)?'), '').replaceFirst(RegExp(r'\.git$'), '').replaceFirst(RegExp(r'/$'), '');

// --- Candado de cambios locales ---------------------------------------------
// Archivos versionados: `git update-index --skip-worktree`, así git deja de ver
// sus cambios. No versionados: una línea en `.git/info/exclude`, debajo de una
// marca propia para poder listarlos y quitarlos sin tocar lo demás del archivo.

const excludeMarker = '# MickHub: cambios locales protegidos';

class Protected {
  const Protected(this.path, {required this.tracked});
  final String path;
  final bool tracked;
}

Future<File> _excludeFile(String repo) async {
  final p = (await git(['rev-parse', '--git-path', 'info/exclude'], cwd: repo)).trim();
  final f = File(p);
  return f.isAbsolute ? f : File('$repo/$p');
}

/// Rutas protegidas en el bloque de MickHub del `exclude`.
List<String> parseExcludeBlock(String content) {
  final lines = LineSplitter.split(content).toList();
  final i = lines.indexOf(excludeMarker);
  if (i < 0) return [];
  return [
    for (final l in lines.skip(i + 1))
      if (l.startsWith('/')) l.substring(1),
  ];
}

/// Agrega o quita [path] del bloque de MickHub, dejando el resto intacto.
String editExcludeBlock(String content, String path, {required bool add}) {
  final lines = LineSplitter.split(content).toList();
  var i = lines.indexOf(excludeMarker);
  if (i < 0) {
    if (!add) return content;
    if (lines.isNotEmpty && lines.last.trim().isNotEmpty) lines.add('');
    lines.add(excludeMarker);
    i = lines.length - 1;
  }
  final entry = '/$path';
  final block = lines.sublist(i + 1).where((l) => l != entry).toList();
  if (add) block.add(entry);
  return '${[...lines.sublist(0, i + 1), ...block].join('\n')}\n';
}

Future<List<Protected>> protectedFiles(String repo) async {
  final skip = [
    for (final l in LineSplitter.split(await git(['ls-files', '-v'], cwd: repo)))
      if (l.startsWith('S ')) Protected(l.substring(2), tracked: true),
  ];
  final f = await _excludeFile(repo);
  final excl = f.existsSync() ? parseExcludeBlock(await f.readAsString()) : <String>[];
  return [...skip, for (final p in excl) Protected(p, tracked: false)];
}

/// Si [path] existe en el último commit. Un archivo nuevo añadido al índice
/// está en `ls-files` ([isTracked]) pero no aquí.
Future<bool> inHead(String repo, String path) async {
  try {
    await git(['cat-file', '-e', 'HEAD:$path'], cwd: repo);
    return true;
  } on GitException {
    return false;
  }
}

Future<void> protect(String repo, FileChange f) async {
  // Fuera del stage primero: skip-worktree sobre un archivo nuevo añadido al
  // índice lo dejaba ahí (un `git commit` lo subía), y sobre uno con cambios en
  // el stage el próximo `reset` del commit le borraba la marca.
  await git(['reset', '-q', '--', f.path], cwd: repo, okCodes: {0, 1, 128});
  if (await inHead(repo, f.path)) {
    await git(['update-index', '--skip-worktree', '--', f.path], cwd: repo);
  } else {
    final file = await _excludeFile(repo);
    await file.parent.create(recursive: true);
    final old = file.existsSync() ? await file.readAsString() : '';
    await file.writeAsString(editExcludeBlock(old, f.path, add: true));
  }
}

Future<void> unprotect(String repo, Protected p) async {
  if (p.tracked) {
    await git(['update-index', '--no-skip-worktree', '--', p.path], cwd: repo);
  } else {
    final file = await _excludeFile(repo);
    if (file.existsSync()) await file.writeAsString(editExcludeBlock(await file.readAsString(), p.path, add: false));
  }
}

/// Descarta los cambios de un archivo: los versionados vuelven a HEAD y los
/// nuevos se borran. Sin papelera: quien llama debe pedir confirmación.
/// Descarta solo algunos bloques de un archivo versionado (su diff contra HEAD
/// e índices de bloque); el resto de sus cambios se queda.
Future<void> discardHunks(String repo, String diff, Set<int> hunks) async {
  final patch = selectHunks(diff, hunks);
  if (patch != null) await git(['apply', '-R', '-'], cwd: repo, stdin: patch);
}

Future<void> discard(String repo, FileChange f) async {
  if (await isTracked(repo, f.path)) {
    await git(['restore', '--source=HEAD', '--staged', '--worktree', '--', f.path], cwd: repo);
  } else {
    await git(['reset', '-q', '--', f.path], cwd: repo, okCodes: {0, 1, 128});
    final file = File('$repo/${f.path}');
    if (file.existsSync()) await file.delete();
  }
  if (f.oldPath != null) {
    await git(['restore', '--source=HEAD', '--staged', '--worktree', '--', f.oldPath!], cwd: repo, okCodes: {0, 1});
  }
}

// --- Apartados (stash por archivos) ----------------------------------------
// "Apartar" guarda archivos elegidos con un nombre y los saca del working tree;
// el resto de los cambios se queda. Sirve para atender un fix rápido sin perder
// una implementación a medias. Por debajo es `git stash push -- <rutas>`.

class Shelf {
  const Shelf(this.ref, this.name, this.branch, this.date);
  final String ref; // stash@{n}
  final String name, branch;
  final DateTime date;
}

/// Parsea `git stash list --format=%gd%x1f%gs%x1f%cI`. El asunto viene como
/// "On rama: nombre" (o "WIP on rama: ..." si no se le dio nombre).
List<Shelf> parseShelves(String out) => [
  for (final l in LineSplitter.split(out))
    if (l.contains('\x1f'))
      () {
        final f = l.split('\x1f');
        final m = RegExp(r'^(?:WIP )?[Oo]n ([^:]+): (.*)$').firstMatch(f[1]);
        final name = m?[2] ?? f[1];
        // GitHub Desktop guarda sus stashes como "!!GitHub_Desktop<rama>".
        final ghd = RegExp(r'^!!GitHub_Desktop<(.+)>$').firstMatch(name);
        if (ghd != null) return Shelf(f[0], 'Guardado por GitHub Desktop', ghd[1]!, DateTime.parse(f[2]));
        return Shelf(f[0], name, m?[1] ?? '', DateTime.parse(f[2]));
      }(),
];

Future<List<Shelf>> shelves(String repo) async => parseShelves(await git(['stash', 'list', '--format=%gd%x1f%gs%x1f%cI'], cwd: repo));

/// Aparta [paths] y nada más. `git stash push -- <rutas>` guarda igual el
/// índice ENTERO: un archivo nuevo de otro grupo añadido al índice se colaba en
/// el apartado y al recuperarlo chocaba ("already exists"). MickHub no usa el
/// stage (el commit lo vacía antes), así que se vacía también aquí.
Future<void> shelve(String repo, String name, List<String> paths) async {
  await git(['reset', '-q'], cwd: repo, okCodes: {0, 1, 128});
  await git(['stash', 'push', '--include-untracked', '-m', name, '--', ...paths], cwd: repo);
}

/// Hash del commit de un apartado (sigue igual aunque cambie su `stash@{n}`).
Future<String> shelfHash(String repo, Shelf s) async => (await git(['rev-parse', s.ref], cwd: repo)).trim();

/// Lo que dejó [unshelve]: archivos que ya estaban iguales (no se tocaron).
class Restored {
  const Restored(this.skipped);
  final List<String> skipped;
}

/// Contenido de [path] en [rev] tal como lo dejaría un checkout (finales de
/// línea de Windows incluidos), o null si no existe ahí.
Future<List<int>?> _checkoutBytes(String repo, String rev, String path) async {
  final r = await Process.run('git', ['cat-file', '--filters', '$rev:$path'], workingDirectory: repo, stdoutEncoding: null);
  return r.exitCode == 0 ? r.stdout as List<int> : null;
}

bool _sameBytes(List<int>? a, List<int>? b) {
  if (a == null || b == null) return a == b;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Devuelve los archivos del apartado al working tree y lo borra de la lista
/// (antes deja un respaldo, ver [backupShelf]).
///
/// Va archivo por archivo y **todo o nada**: primero decide qué hacer con cada
/// uno y, si alguno choca, no toca ninguno y lo dice por archivo. Antes se
/// usaba `stash pop`, que al fallar a mitad ya había devuelto parte de los
/// archivos y dejaba el repo a medias. Por archivo:
/// - ya igual a lo apartado: se salta;
/// - sin cambios ahora y apartado sobre la misma versión: se escribe tal cual;
/// - si no (tiene otros cambios, p. ej. se apartaron solo unos bloques): se
///   aplica su parte del apartado como parche; si no entra, choca.
Future<Restored> unshelve(String repo, Shelf s) async {
  final w = await shelfHash(repo, s);
  final hasUntracked = (await git(['rev-parse', '--verify', '-q', '$w^3'], cwd: repo, okCodes: {0, 1})).trim().isNotEmpty;
  final skipped = <String>[], conflicts = <String>[];
  final writes = <String, List<int>?>{}; // ruta -> contenido (null = borrar)
  final patches = <String, String>{};
  for (final p in await shelfFiles(repo, s)) {
    final f = File('$repo/$p');
    final now = f.existsSync() ? await f.readAsBytes() : null;
    var target = await _checkoutBytes(repo, w, p);
    final untracked = target == null && hasUntracked ? await _checkoutBytes(repo, '$w^3', p) : null;
    target ??= untracked;
    if (_sameBytes(now, target)) {
      skipped.add(p);
      continue;
    }
    final head = await _checkoutBytes(repo, 'HEAD', p);
    final base = untracked != null ? null : await _checkoutBytes(repo, '$w^1', p);
    if (_sameBytes(now, head) && _sameBytes(base, head)) {
      writes[p] = target;
      continue;
    }
    final patch = untracked != null
        ? null // archivo nuevo apartado que ahora existe con otro contenido: no hay base común
        : await git(['diff', '--binary', '$w^1', w, '--', p], cwd: repo);
    if (patch == null || patch.trim().isEmpty) {
      conflicts.add(p);
      continue;
    }
    try {
      await git(['apply', '--check', '-'], cwd: repo, stdin: patch);
      patches[p] = patch;
    } on GitException {
      conflicts.add(p);
    }
  }
  if (conflicts.isNotEmpty) {
    throw GitException(
      ['stash', 'pop'],
      'No se recuperó nada: estos archivos tienen ahora otros cambios que chocan con el apartado:\n'
      '${conflicts.map((c) => '  $c').join('\n')}\n'
      'Commitéalos, apártalos o descártalos y vuelve a intentar. El apartado sigue en la lista.',
    );
  }
  for (final e in writes.entries) {
    final f = File('$repo/${e.key}');
    if (e.value == null) {
      if (f.existsSync()) await f.delete();
    } else {
      await f.parent.create(recursive: true);
      await f.writeAsBytes(e.value!);
    }
  }
  for (final patch in patches.values) {
    await git(['apply', '-'], cwd: repo, stdin: patch);
  }
  await dropShelf(repo, s);
  return Restored(skipped);
}

/// Prefijo de los respaldos: cada apartado que se recupera o elimina deja su
/// commit en `refs/mickhub/respaldos/<ms>`, así un error se deshace con
/// `git stash store -m <nombre> <hash>` (`mickhub apartados` los lista).
const backupPrefix = 'refs/mickhub/respaldos';

// ponytail: guarda los últimos 50; los más viejos se borran.
Future<void> backupShelf(String repo, String hash) async {
  await git(['update-ref', '$backupPrefix/${DateTime.now().millisecondsSinceEpoch}', hash], cwd: repo);
  final refs = LineSplitter.split(await git(['for-each-ref', '--format=%(refname)', '--sort=refname', backupPrefix], cwd: repo)).toList();
  for (final r in refs.take(refs.length > 50 ? refs.length - 50 : 0)) {
    await git(['update-ref', '-d', r], cwd: repo);
  }
}

/// Respaldos de apartados, del más nuevo al más viejo: (hash, nombre, fecha).
Future<List<(String, String, DateTime)>> shelfBackups(String repo) async => [
  for (final l in LineSplitter.split(
    await git([
      'for-each-ref',
      '--sort=-refname',
      '--format=%(objectname)%1f%(subject)%1f%(creatordate:iso-strict)',
      backupPrefix,
    ], cwd: repo),
  ))
    if (l.split('\x1f') case [final h, final s, final d]) (h, s.replaceFirst(RegExp(r'^(?:WIP )?[Oo]n [^:]+: '), ''), DateTime.parse(d)),
];

/// Borra el apartado dejando antes un respaldo recuperable.
Future<void> dropShelf(String repo, Shelf s) async {
  await backupShelf(repo, await shelfHash(repo, s));
  await git(['stash', 'drop', s.ref], cwd: repo);
}

/// Archivos de un apartado (los nuevos incluidos). Sin detectar renombres: con
/// ellos solo sale la ruta nueva y la vieja no se devolvería.
Future<List<String>> shelfFiles(String repo, Shelf s) async => LineSplitter.split(
  await git(['stash', 'show', '--name-only', '--no-renames', '--include-untracked', s.ref], cwd: repo, okCodes: {0, 1}),
).toList();

// --- Ramas locales ------------------------------------------------------------

/// Ramas desde las que se puede crear una nueva: locales y remotas.
Future<List<String>> branchBases(String repo) async => [
  for (final b in LineSplitter.split(await git(['branch', '-a', '--format=%(refname:short)'], cwd: repo)))
    if (!b.endsWith('/HEAD') && b != 'origin') b,
];

/// Crea una rama local desde [base] y se cambia a ella. Los cambios sin
/// commitear viajan con ella (comportamiento normal de git).
Future<void> createBranch(String repo, String name, String base) => git(['switch', '--no-track', '-c', name, base], cwd: repo);

/// Identidad con la que git firmaría en [repo] sin cuenta de MickHub (config del
/// repo o global): `Nombre <email>`, o null si no hay.
Future<String?> gitIdentity(String repo) async {
  final name = (await git(['config', 'user.name'], cwd: repo, okCodes: {0, 1})).trim();
  final email = (await git(['config', 'user.email'], cwd: repo, okCodes: {0, 1})).trim();
  return name.isEmpty && email.isEmpty ? null : '$name <$email>';
}

/// Crea un commit nuevo que deshace [hash]. Sirve aunque ya esté subido.
Future<void> revertCommit(String repo, String hash, {List<String> identity = const []}) =>
    git([...identity, 'revert', '--no-edit', hash], cwd: repo);

/// Deshace el último commit sin perder sus cambios: vuelven a Cambios. Solo
/// tiene sentido si todavía no se subió.
/// Commits de HEAD que no están en ningún remoto (sin subir); sirve también sin upstream.
Future<Set<String>> unpushedCommits(String repo) async {
  try {
    return (await git(['rev-list', 'HEAD', '--not', '--remotes'], cwd: repo, env: readOnly)).split('\n').where((l) => l.isNotEmpty).toSet();
  } on GitException {
    return {}; // repo sin commits
  }
}

Future<void> undoLastCommit(String repo) => git(['reset', '--soft', 'HEAD~1'], cwd: repo);

// --- Conflictos -----------------------------------------------------------------

/// `stash`: un pull que apartó los cambios sin commitear (`--autostash`) y al
/// volver a ponerlos chocaron con lo que llegó. No hay merge a medias: solo
/// archivos en conflicto, y la copia de los cambios sigue en el apartado.
enum MergeState { none, merge, rebase, stash }

/// Si el repo quedó a mitad de un merge o un rebase (típico de un pull con conflictos).
Future<MergeState> mergeState(String repo) async {
  Future<bool> exists(String gitPath) async {
    final p = (await git(['rev-parse', '--git-path', gitPath], cwd: repo)).trim();
    final f = File(p).isAbsolute ? p : '$repo/$p';
    return FileSystemEntity.typeSync(f) != FileSystemEntityType.notFound;
  }

  if (await exists('MERGE_HEAD')) return MergeState.merge;
  if (await exists('rebase-merge') || await exists('rebase-apply')) return MergeState.rebase;
  // Conflictos sin merge ni revert a medias: vienen de volver a poner un apartado.
  final unmerged = (await git(['diff', '--name-only', '--diff-filter=U'], cwd: repo)).trim();
  if (unmerged.isNotEmpty && !await exists('REVERT_HEAD') && !await exists('CHERRY_PICK_HEAD')) return MergeState.stash;
  return MergeState.none;
}

/// Resuelve un archivo en conflicto quedándose con una versión entera.
/// [mine] = mi versión local. Ojo: en un rebase y al volver a poner un apartado
/// git invierte ours/theirs (ours es lo que vino del remoto), por eso depende
/// de [state].
Future<void> resolveWith(String repo, String path, {required bool mine, required MergeState state}) async {
  final ours = state == MergeState.rebase || state == MergeState.stash ? !mine : mine;
  await git(['checkout', ours ? '--ours' : '--theirs', '--', path], cwd: repo);
  await git(['add', '--', path], cwd: repo);
}

/// Marca como resuelto un archivo que el usuario ya corrigió a mano.
Future<void> markResolved(String repo, String path) => git(['add', '--', path], cwd: repo);

Future<void> abortMerge(String repo, MergeState state) => git([state == MergeState.rebase ? 'rebase' : 'merge', '--abort'], cwd: repo);

/// Termina el merge (commit con el mensaje que propone git) o sigue el rebase.
/// En [MergeState.stash] no hay nada que commitear: los cambios resueltos
/// vuelven a quedar sin commitear (fuera del stage) y se borra el apartado que
/// dejó el pull, porque su contenido ya está en los archivos.
Future<void> finishMerge(String repo, MergeState state, {List<String> identity = const []}) async {
  switch (state) {
    case MergeState.rebase:
      await git([...identity, 'rebase', '--continue'], cwd: repo, env: {'GIT_EDITOR': 'true'});
    case MergeState.stash:
      await git(['reset', '-q'], cwd: repo);
      final auto = (await shelves(repo)).where((s) => s.name == 'autostash').firstOrNull;
      if (auto != null) await dropShelf(repo, auto);
    case MergeState.merge || MergeState.none:
      await git([...identity, 'commit', '--no-edit'], cwd: repo, env: {'GIT_EDITOR': 'true'});
  }
}

/// Pull como GitHub Desktop: con merge, salvo que el usuario haya configurado
/// `pull.rebase` (sin decirlo, git falla con "divergent branches" cuando hay
/// commits de los dos lados). Con [autostash] aparta los cambios sin commitear,
/// trae y los vuelve a poner; si chocan quedan en conflicto ([MergeState.stash]).
Future<void> pull(String repo, {List<String> identity = const [], Map<String, String> env = const {}, bool autostash = false}) async {
  final rebase = (await git(['config', '--get', 'pull.rebase'], cwd: repo, okCodes: {0, 1})).trim();
  await git([...identity, 'pull', if (rebase.isEmpty) '--no-rebase', if (autostash) '--autostash'], cwd: repo, env: env);
}

/// Archivos con cambios sin commitear que impiden un pull (git se niega para no
/// pisarlos). Null si el error es otro.
List<String>? pullBlockedBy(String message) {
  if (message.contains('cannot pull with rebase: You have unstaged changes')) return const [];
  final m = RegExp(r'would be overwritten by (?:merge|checkout):\n((?:\s+\S.*\n?)+)').firstMatch(message);
  if (m == null) return null;
  return [
    for (final l in m[1]!.split('\n'))
      if (l.trim().isNotEmpty && !l.contains('Please commit')) l.trim(),
  ];
}

/// Tramos de un archivo con marcas de conflicto, para pintarlo.
enum ConflictPart { normal, marker, mine, base, theirs }

List<ConflictPart> conflictParts(List<String> lines) {
  var part = ConflictPart.normal;
  return [
    for (final l in lines)
      if (l.startsWith('<<<<<<<'))
        () {
          part = ConflictPart.mine;
          return ConflictPart.marker;
        }()
      else if (l.startsWith('|||||||') && part != ConflictPart.normal)
        () {
          part = ConflictPart.base;
          return ConflictPart.marker;
        }()
      else if (l.startsWith('=======') && part != ConflictPart.normal)
        () {
          part = ConflictPart.theirs;
          return ConflictPart.marker;
        }()
      else if (l.startsWith('>>>>>>>') && part != ConflictPart.normal)
        () {
          part = ConflictPart.normal;
          return ConflictPart.marker;
        }()
      else
        part,
  ];
}

/// Crea un repo nuevo en [dir] con rama `main` y, si [readme], un README y el
/// primer commit (así ya se puede publicar).
Future<void> initRepo(String dir, String name, {bool readme = true, List<String> identity = const []}) async {
  await Directory(dir).create(recursive: true);
  await git(['init', '-q', '-b', 'main'], cwd: dir);
  if (readme) {
    await File('$dir/README.md').writeAsString('# $name\n');
    await git(['add', 'README.md'], cwd: dir);
    await git([...identity, 'commit', '-q', '-m', 'chore: commit inicial'], cwd: dir);
  }
}

/// Conecta el repo a [url] como `origin` y sube la rama actual.
Future<void> publishRepo(String repo, String url) async {
  await git(['remote', 'add', 'origin', url], cwd: repo);
  await git(['push', '-u', 'origin', 'HEAD'], cwd: repo);
}

// --- Apartar bloques sueltos -------------------------------------------------------

/// Parche con solo los bloques (`@@`) elegidos de un diff de un archivo.
/// [hunks] son índices de bloque desde 0. Null si no hay ninguno.
String? selectHunks(String diff, Set<int> hunks) {
  final lines = diff.split('\n');
  final first = lines.indexWhere((l) => l.startsWith('@@'));
  if (first < 0) return null;
  final out = lines.sublist(0, first);
  var idx = -1;
  for (final l in lines.skip(first)) {
    if (l.startsWith('@@')) idx++;
    if (hunks.contains(idx)) out.add(l);
  }
  if (out.length == first) return null;
  return '${out.join('\n').trimRight()}\n';
}

/// Aparta solo algunos bloques de un archivo versionado: el apartado guarda esos
/// bloques y el archivo se queda con el resto de los cambios.
Future<void> shelveHunks(String repo, String path, String diff, Set<int> hunks, String name) =>
    shelveParts(repo, name, whole: const [], parts: {path: (diff, hunks)});

/// Aparta en un solo apartado [whole] (archivos enteros) y, de [parts], solo
/// los bloques elegidos de cada archivo (su diff contra HEAD e índices de
/// bloque); esos archivos se quedan con el resto de sus cambios. Si algo falla a
/// mitad, los archivos repartidos vuelven a como estaban.
// ponytail: la granularidad es el bloque del diff con 3 líneas de contexto; dos
// cambios a menos de ~6 líneas caen en el mismo bloque. Upgrade: elegir líneas.
Future<void> shelveParts(String repo, String name, {required List<String> whole, required Map<String, (String, Set<int>)> parts}) async {
  final tmp = await Directory.systemTemp.createTemp('mickhub_patch');
  final originals = <String, List<int>>{};
  final rests = <String, List<int>>{};
  try {
    var i = 0;
    for (final MapEntry(key: path, value: (diff, hunks)) in parts.entries) {
      final patch = selectHunks(diff, hunks);
      if (patch == null) continue;
      final file = File('$repo/$path');
      final patchFile = File('${tmp.path}/${i++}.patch');
      await patchFile.writeAsString(patch);
      originals[path] = await file.readAsBytes();
      await git(['apply', '-R', patchFile.path], cwd: repo); // archivo = todo menos los bloques
      rests[path] = await file.readAsBytes();
      await git(['checkout', 'HEAD', '--', path], cwd: repo); // archivo = último commit
      await git(['apply', patchFile.path], cwd: repo); // + solo los bloques
    }
    final paths = [...whole, ...rests.keys];
    if (paths.isEmpty) return;
    await shelve(repo, name, paths); // se guardan; los archivos vuelven al commit
    for (final e in rests.entries) {
      await File('$repo/${e.key}').writeAsBytes(e.value); // y los repartidos recuperan el resto
    }
  } catch (_) {
    for (final e in originals.entries) {
      await File('$repo/${e.key}').writeAsBytes(e.value);
    }
    rethrow;
  } finally {
    await tmp.delete(recursive: true);
  }
}

/// Días que pueden separar dos partes de un mismo trabajo ("avance" y "final").
const relatedDays = 7;

/// Un commit de versión ("chore(release): 0.1.9", "v1.2.0", "Release 2.0"):
/// todos tocan los mismos archivos (pubspec, changelog) y no son un trabajo
/// partido, así que no se enlazan entre sí ni con otros.
bool isRelease(String subject) =>
    RegExp(r'^(\w+\(release\)!?:|release\b|bump version\b|v?\d+\.\d+(\.\d+)?\S*$)', caseSensitive: false).hasMatch(subject.trim());

/// El commit anterior y el siguiente que parecen el mismo trabajo partido en
/// varios commits: mismo autor, sin merges, a menos de [relatedDays] días y
/// casi los mismos archivos (la mitad o más de todos los que tocan entre los dos). Busca solo
/// en la historia de la rama actual.
// ponytail: heurística de archivos, no entiende el contenido; con más de 50
// archivos no se busca (línea de comandos larga y casi siempre es un refactor).
Future<({Commit? before, Commit? after})> relatedCommits(String repo, Commit c, List<FileChange> files) async {
  final mine = {for (final f in files) f.path};
  if (mine.isEmpty || mine.length > 50 || c.email.isEmpty || isRelease(c.summary)) return (before: null, after: null);
  final common = [
    'log',
    '--no-merges',
    '--fixed-strings',
    '--author=<${c.email}>',
    '--full-diff', // con filtro de rutas, que igual liste todos los archivos de cada commit
    '--name-only',
    '--format=%x1e%H%x1f%an%x1f%aI%x1f%s%x1f%ae',
  ];
  final paths = ['--', ...mine];
  Future<Commit?> nearest(List<String> range) async {
    final String out;
    try {
      out = await git([...common, ...range, ...paths], cwd: repo);
    } on GitException {
      return null; // primer commit (no tiene padre) o rango vacío
    }
    for (final rec in out.split('\x1e')) {
      final lines = rec.split('\n').where((l) => l.isNotEmpty).toList();
      if (lines.isEmpty) continue;
      final other = parseLog(lines.first).single;
      if (other.hash == c.hash || isRelease(other.summary) || other.date.difference(c.date).inDays.abs() >= relatedDays) continue;
      final theirs = lines.skip(1).toSet();
      // Archivos en común sobre todos los que tocan entre los dos (Jaccard).
      if (theirs.intersection(mine).length >= 0.5 * theirs.union(mine).length) return other;
    }
    return null;
  }

  final r = await Future.wait([
    nearest(['-n', '20', '${c.hash}^']), // más nuevo primero: el primero que calce es el más cercano
    nearest(['--reverse', '--ancestry-path', '${c.hash}..HEAD']), // de más viejo a más nuevo
  ]);
  return (before: r[0], after: r[1]);
}
