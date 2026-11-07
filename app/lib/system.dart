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
