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

Future<BranchState> branchState(String repo) async {
  final name = (await git(['symbolic-ref', '--short', '-q', 'HEAD'], cwd: repo, okCodes: {0, 1})).trim();
  final branch = name.isEmpty ? 'HEAD desacoplado' : name;
  try {
    final up = (await git(['rev-parse', '--abbrev-ref', '@{upstream}'], cwd: repo)).trim();
    final counts = (await git(['rev-list', '--left-right', '--count', 'HEAD...@{upstream}'], cwd: repo)).trim().split(RegExp(r'\s+'));
    return BranchState(branch, upstream: up, ahead: int.parse(counts[0]), behind: int.parse(counts[1]));
  } on GitException {
    return BranchState(branch);
  }
}

Future<List<String>> localBranches(String repo) async =>
    LineSplitter.split(await git(['branch', '--format=%(refname:short)'], cwd: repo)).toList();

class Commit {
  const Commit(this.hash, this.author, this.date, this.summary);
  final String hash, author, summary;
  final DateTime date;

  String get shortHash => hash.substring(0, 7);
}

/// Parsea `git log` con campos separados por \x1f y commits por \x1e.
List<Commit> parseLog(String out) => [
  for (final rec in out.split('\x1e'))
    if (rec.trim().isNotEmpty)
      () {
        final f = rec.trim().split('\x1f');
        return Commit(f[0], f[1], DateTime.parse(f[2]), f[3]);
      }(),
];

// ponytail: solo los últimos 300 commits; paginar cuando haga falta más.
Future<List<Commit>> log(String repo) async {
  try {
    return parseLog(await git(['log', '-n', '300', '--format=%H%x1f%an%x1f%aI%x1f%s%x1e'], cwd: repo));
  } on GitException {
    return []; // repo sin commits
  }
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
Future<void> unshelve(String repo, Shelf s) => git(['stash', 'pop', s.ref], cwd: repo);

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
