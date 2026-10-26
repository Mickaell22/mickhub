import 'dart:io';

import 'package:file_selector/file_selector.dart';

/// Abre una carpeta en el explorador de archivos del sistema.
Future<void> openFolder(String path) =>
    Process.start(Platform.isWindows ? 'explorer' : (Platform.isMacOS ? 'open' : 'xdg-open'), [path], mode: ProcessStartMode.detached);

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
