import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';

/// Abre una carpeta en el explorador de archivos del sistema.
Future<void> openFolder(String path) =>
    Process.start(Platform.isWindows ? 'explorer' : (Platform.isMacOS ? 'open' : 'xdg-open'), [path], mode: ProcessStartMode.detached);

/// Terminal para "Abrir en la terminal": la elegida en ajustes
/// (`terminalCommand`); si no hay, la de `$TERMINAL` o la primera conocida que
/// esté instalada. En Windows, Windows Terminal y si no está, cmd.
Future<String?> findTerminal(String configured) async {
  if (configured.isNotEmpty) return configured;
  if (Platform.isWindows) return (await _which('wt')) ? 'wt' : 'cmd';
  final env = Platform.environment['TERMINAL'];
  if (env != null && env.isNotEmpty) return env;
  // ponytail: lista fija de terminales comunes; otra se configura en ajustes.
  for (final t in [
    'kitty',
    'alacritty',
    'foot',
    'wezterm',
    'ghostty',
    'konsole',
    'gnome-terminal',
    'xfce4-terminal',
    'x-terminal-emulator',
    'xterm',
  ]) {
    if (await _which(t)) return t;
  }
  return null;
}

Future<bool> _which(String cmd) async {
  try {
    return (await Process.run(Platform.isWindows ? 'where' : 'which', [cmd])).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

/// Abre [command] (una terminal) parada en [folder]. Las de Linux arrancan en
/// su carpeta de trabajo; Windows Terminal la recibe con `-d` y cmd con `start`.
Future<void> openTerminal(String command, String folder) {
  final name = command.split(RegExp(r'[\\/]')).last.toLowerCase().replaceFirst(RegExp(r'\.exe$'), '');
  if (Platform.isWindows && name == 'wt') return Process.start(command, ['-d', folder], mode: ProcessStartMode.detached);
  if (Platform.isWindows && name == 'cmd') {
    return Process.start('cmd', ['/c', 'start', 'cmd'], workingDirectory: folder, mode: ProcessStartMode.detached);
  }
  return Process.start(command, const [], workingDirectory: folder, mode: ProcessStartMode.detached, runInShell: Platform.isWindows);
}

// --- Sesiones de Claude Code (las de los grupos de cambios de `mickhub`) ----------

/// Carpeta donde corría la sesión [id] de Claude Code, leída de su transcript
/// (`~/.claude/projects/*/<id>.jsonl`); null si en este equipo no está.
Future<String?> claudeSessionDir(String id) async {
  final env = Platform.environment, sep = Platform.pathSeparator;
  final root = env['CLAUDE_CONFIG_DIR'] ?? '${env['HOME'] ?? env['USERPROFILE']}$sep.claude';
  final projects = Directory('$root${sep}projects');
  if (!projects.existsSync()) return null;
  for (final d in projects.listSync().whereType<Directory>()) {
    final f = File('${d.path}$sep$id.jsonl');
    if (!f.existsSync()) continue;
    await for (final line in f.openRead().transform(utf8.decoder).transform(const LineSplitter()).take(200)) {
      try {
        final cwd = (jsonDecode(line) as Map)['cwd'];
        if (cwd is String && cwd.isNotEmpty) return cwd;
      } catch (_) {
        // línea que no es JSON: se sigue
      }
    }
  }
  return null;
}

/// Argumentos para que la terminal [command] se abra en [folder] corriendo [run].
// ponytail: la forma de pasarle un comando cambia por terminal; una que no está
// aquí recibe `-e` (xterm y parecidas).
List<String> terminalRunArgs(String command, String folder, List<String> run) {
  final name = command.split(RegExp(r'[\\/]')).last.toLowerCase().replaceFirst(RegExp(r'\.exe$'), '');
  return switch (name) {
    'kitty' => ['--directory', folder, ...run],
    'foot' => ['-D', folder, ...run],
    'alacritty' => ['--working-directory', folder, '-e', ...run],
    'wezterm' => ['start', '--cwd', folder, '--', ...run],
    'ghostty' => ['--working-directory=$folder', '-e', ...run],
    'konsole' => ['--workdir', folder, '-e', ...run],
    'gnome-terminal' => ['--working-directory=$folder', '--', ...run],
    'xfce4-terminal' => ['--working-directory', folder, '-x', ...run],
    'wt' => ['-d', folder, ...run],
    _ => ['-e', ...run],
  };
}

/// Retoma en una terminal la sesión [id] de Claude Code (`claude --resume`),
/// parada en [folder], que es donde corría (si no, `--resume` no la encuentra).
Future<void> openClaudeSession(String terminal, String folder, String id) {
  // El id sale de un JSON que se puede editar a mano: que sea solo un uuid.
  if (!RegExp(r'^[0-9A-Za-z-]+$').hasMatch(id)) throw ArgumentError('id de sesión inválido: $id');
  final name = terminal.split(RegExp(r'[\\/]')).last.toLowerCase().replaceFirst(RegExp(r'\.exe$'), '');
  if (Platform.isWindows && name == 'cmd') {
    return Process.start(
      'cmd',
      ['/c', 'start', 'cmd', '/k', 'claude', '--resume', id],
      workingDirectory: folder,
      mode: ProcessStartMode.detached,
    );
  }
  // En Linux por un shell de login: abierta desde el dock, la app puede no
  // tener en el PATH la carpeta donde vive `claude`.
  final run = Platform.isWindows ? ['claude', '--resume', id] : [Platform.environment['SHELL'] ?? 'bash', '-lc', 'claude --resume $id'];
  return Process.start(terminal, terminalRunArgs(terminal, folder, run), workingDirectory: folder, mode: ProcessStartMode.detached);
}

/// Argumentos para abrir [folder] en el editor y, si se da, también [file]
/// (relativo a [folder]) en [line]. VS Code y sus variantes saltan a la línea
/// con `-g archivo:línea`; con otros editores se abre el archivo sin línea.
List<String> editorArgs(String command, String folder, {String? file, int? line}) {
  final isCode = RegExp(r'(^|[\\/])(code|code-insiders|codium|vscodium|cursor)(\.(cmd|exe))?$', caseSensitive: false).hasMatch(command);
  if (file == null) return [folder];
  final full = '$folder${Platform.pathSeparator}$file';
  return [
    folder,
    if (isCode && line != null) ...['-g', '$full:$line'] else full,
  ];
}

/// Abre [folder] con el editor configurado (por defecto `code`) y, si se da,
/// también [file] en [line].
Future<void> openInEditor(String command, String folder, {String? file, int? line}) => Process.start(
  command,
  editorArgs(command, folder, file: file, line: line),
  mode: ProcessStartMode.detached,
  runInShell: Platform.isWindows,
);

/// Selector nativo de carpetas. Devuelve null si se canceló.
Future<String?> pickFolder({String? initial, String confirm = 'Elegir'}) =>
    getDirectoryPath(initialDirectory: initial, confirmButtonText: confirm);
