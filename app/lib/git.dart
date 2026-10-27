import 'dart:convert';
import 'dart:io';

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
/// diff --no-index` sale con 1 cuando hay diferencias).
Future<String> git(
  List<String> args, {
  String? cwd,
  String? stdin,
  Set<int> okCodes = const {0},
  Map<String, String> env = const {},
}) async {
  final p = await Process.start('git', args, workingDirectory: cwd, environment: {'GIT_TERMINAL_PROMPT': '0', ...env});
  final out = p.stdout.transform(utf8.decoder).join();
  final err = p.stderr.transform(utf8.decoder).join();
  if (stdin != null) p.stdin.write(stdin);
  await p.stdin.close();
  if (!okCodes.contains(await p.exitCode)) throw GitException(args, (await err).trim());
  return out;
}

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
    parseStatus(await git(['status', '--porcelain=v1', '-z', '--untracked-files=all'], cwd: repo));

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
Future<void> commit(String repo, List<String> paths, String summary, String description, {List<String> identity = const []}) async {
  await git(['reset', '-q'], cwd: repo, okCodes: {0, 1, 128}); // 128: repo sin commits todavía
  await git(['add', '-A', '--', ...paths], cwd: repo);
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

Future<RepoSummary> repoSummary(String repo) async => parseSummary(await git(['status', '--porcelain=v2', '--branch'], cwd: repo));

Future<BranchState> branchState(String repo) async => (await repoSummary(repo)).branch;

/// Fetch en segundo plano: sin ventanas de login (si la sesión venció, falla
/// callado y el usuario se entera al sincronizar).
Future<void> backgroundFetch(String repo, {Map<String, String> env = const {}}) =>
    git(['fetch', '--prune', '--quiet'], cwd: repo, env: {'GCM_INTERACTIVE': 'never', ...env});

Future<List<String>> localBranches(String repo) async =>
    LineSplitter.split(await git(['branch', '--format=%(refname:short)'], cwd: repo)).toList();

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
  final out = await git(['show', '--format=', '--name-status', '-M', '-z', hash], cwd: repo);
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
    git(['show', '--format=', '-M', hash, '--', if (f.oldPath != null) f.oldPath!, f.path], cwd: repo);

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

Future<void> protect(String repo, FileChange f) async {
  if (await isTracked(repo, f.path)) {
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

Future<void> shelve(String repo, String name, List<String> paths) =>
    git(['stash', 'push', '--include-untracked', '-m', name, '--', ...paths], cwd: repo);

/// Devuelve los archivos del apartado al working tree y lo borra de la lista.
/// Si esos archivos tienen otros cambios ahora (p. ej. se apartaron solo unos
/// bloques), `stash pop` se niega; entonces se aplica el apartado como parche
/// sobre lo actual y, si entra limpio, se borra.
Future<void> unshelve(String repo, Shelf s) async {
  try {
    await git(['stash', 'pop', s.ref], cwd: repo);
  } on GitException catch (e) {
    if (!e.message.contains('would be overwritten')) rethrow;
    final patch = await git(['stash', 'show', '-p', '--include-untracked', s.ref], cwd: repo);
    try {
      await git(['apply', '-'], cwd: repo, stdin: patch);
    } on GitException {
      throw GitException([
        'stash',
        'pop',
      ], 'El apartado choca con tus cambios actuales en los mismos archivos. Commitéalos o apártalos y vuelve a intentar.');
    }
    await dropShelf(repo, s);
  }
}

Future<void> dropShelf(String repo, Shelf s) => git(['stash', 'drop', s.ref], cwd: repo);

Future<List<String>> shelfFiles(String repo, Shelf s) async =>
    LineSplitter.split(await git(['stash', 'show', '--name-only', '--include-untracked', s.ref], cwd: repo, okCodes: {0, 1})).toList();

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
Future<void> undoLastCommit(String repo) => git(['reset', '--soft', 'HEAD~1'], cwd: repo);

// --- Conflictos -----------------------------------------------------------------

enum MergeState { none, merge, rebase }

/// Si el repo quedó a mitad de un merge o un rebase (típico de un pull con conflictos).
Future<MergeState> mergeState(String repo) async {
  Future<bool> exists(String gitPath) async {
    final p = (await git(['rev-parse', '--git-path', gitPath], cwd: repo)).trim();
    final f = File(p).isAbsolute ? p : '$repo/$p';
    return FileSystemEntity.typeSync(f) != FileSystemEntityType.notFound;
  }

  if (await exists('MERGE_HEAD')) return MergeState.merge;
  if (await exists('rebase-merge') || await exists('rebase-apply')) return MergeState.rebase;
  return MergeState.none;
}

/// Resuelve un archivo en conflicto quedándose con una versión entera.
/// [mine] = mi versión local. Ojo: en un rebase git invierte ours/theirs (ours
/// es lo que viene del remoto), por eso depende de [state].
Future<void> resolveWith(String repo, String path, {required bool mine, required MergeState state}) async {
  final ours = state == MergeState.rebase ? !mine : mine;
  await git(['checkout', ours ? '--ours' : '--theirs', '--', path], cwd: repo);
  await git(['add', '--', path], cwd: repo);
}

/// Marca como resuelto un archivo que el usuario ya corrigió a mano.
Future<void> markResolved(String repo, String path) => git(['add', '--', path], cwd: repo);

Future<void> abortMerge(String repo, MergeState state) => git([state == MergeState.rebase ? 'rebase' : 'merge', '--abort'], cwd: repo);

/// Termina el merge (commit con el mensaje que propone git) o sigue el rebase.
Future<void> finishMerge(String repo, MergeState state, {List<String> identity = const []}) => state == MergeState.rebase
    ? git([...identity, 'rebase', '--continue'], cwd: repo, env: {'GIT_EDITOR': 'true'})
    : git([...identity, 'commit', '--no-edit'], cwd: repo, env: {'GIT_EDITOR': 'true'});

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
/// bloques y el archivo se queda con el resto de los cambios. Si algo falla a
/// mitad, el archivo vuelve a como estaba.
// ponytail: la granularidad es el bloque del diff con 3 líneas de contexto; dos
// cambios a menos de ~6 líneas caen en el mismo bloque. Upgrade: elegir líneas.
Future<void> shelveHunks(String repo, String path, String diff, Set<int> hunks, String name) async {
  final patch = selectHunks(diff, hunks);
  if (patch == null) return;
  final file = File('$repo/$path');
  final original = await file.readAsBytes();
  final patchFile = File('${(await Directory.systemTemp.createTemp('mickhub_patch')).path}/bloques.patch');
  await patchFile.writeAsString(patch);
  try {
    await git(['apply', '-R', patchFile.path], cwd: repo); // archivo = todo menos los bloques
    final rest = await file.readAsBytes();
    await git(['checkout', 'HEAD', '--', path], cwd: repo); // archivo = último commit
    await git(['apply', patchFile.path], cwd: repo); // + solo los bloques
    await shelve(repo, name, [path]); // se guardan y el archivo vuelve al commit
    await file.writeAsBytes(rest); // y recupera el resto
  } catch (_) {
    await file.writeAsBytes(original);
    rethrow;
  } finally {
    await patchFile.parent.delete(recursive: true);
  }
}
