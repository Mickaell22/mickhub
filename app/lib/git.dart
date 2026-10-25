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
Future<String> git(List<String> args, {String? cwd, String? stdin, Set<int> okCodes = const {0}}) async {
  final p = await Process.start('git', args,
      workingDirectory: cwd, environment: {'GIT_TERMINAL_PROMPT': '0'});
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
Future<void> commit(String repo, List<String> paths, String summary, String description) async {
  await git(['reset', '-q'], cwd: repo, okCodes: {0, 1, 128}); // 128: repo sin commits todavía
  await git(['add', '-A', '--', ...paths], cwd: repo);
  await git(['commit', '-m', summary, if (description.trim().isNotEmpty) ...['-m', description.trim()]], cwd: repo);
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
      final st = switch (s[0]) { 'A' => FileStatus.added, 'D' => FileStatus.deleted, _ => FileStatus.modified };
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
String remoteKey(String url) => url
    .toLowerCase()
    .replaceFirst(RegExp(r'^https?://([^@/]+@)?'), '')
    .replaceFirst(RegExp(r'\.git$'), '')
    .replaceFirst(RegExp(r'/$'), '');
