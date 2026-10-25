import 'dart:io';

/// Abre una carpeta en el explorador de archivos del sistema.
Future<void> openFolder(String path) =>
    Process.start(Platform.isWindows ? 'explorer' : (Platform.isMacOS ? 'open' : 'xdg-open'), [path], mode: ProcessStartMode.detached);

/// Abre [path] con el comando de editor configurado (por defecto `code`).
Future<void> openInEditor(String command, String path) =>
    Process.start(command, [path], mode: ProcessStartMode.detached, runInShell: Platform.isWindows);
