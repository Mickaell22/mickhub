import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'accounts.dart';
import 'trash.dart';

/// Preferencias en un JSON chico, como en Surco (sin shared_preferences).
class Settings extends ChangeNotifier {
  /// Carpeta donde se clonan los repos; sus subcarpetas con `.git` aparecen
  /// solas en la lista de repos locales.
  String? reposDir;

  /// Repos locales agregados a mano, fuera de [reposDir].
  List<String> extraRepos = [];

  /// Repo abierto la última vez.
  String? currentRepo;

  double sidebarWidth = 250;

  /// Grupo de cada repo (ruta -> nombre del grupo), para ordenar y filtrar.
  Map<String, String> groups = {};

  /// Grupos creados (nombre -> clave de ícono de [groupIcons]). Un grupo existe
  /// aunque todavía no tenga repos.
  Map<String, String> groupIcons = {};

  /// Cuentas (GitHub, organizaciones de Azure DevOps) y con qué firman commits.
  List<Account> accounts = [];

  /// Cuenta forzada a mano para un repo (ruta -> id de cuenta); si no hay, se
  /// deduce del remoto con [accountFor].
  Map<String, String> repoAccounts = {};

  /// Comando para "Abrir en el editor".
  String editorCommand = 'code';

  File? _file;

  /// Ruta del JSON de ajustes. Se puede editar desde fuera (por ejemplo Claude
  /// Code agrupando repos) y la app lo recarga sola, ver [watch].
  String? get path => _file?.path;

  /// Avisa cuando el archivo de ajustes cambia en disco. Se vigila la carpeta y
  /// no el archivo porque los editores suelen reemplazarlo (otro inodo).
  StreamSubscription<FileSystemEvent>? watch(void Function() onChange) {
    final f = _file;
    if (f == null || !f.parent.existsSync()) return null;
    return f.parent
        .watch()
        .where((e) => e.path == f.path || (e is FileSystemMoveEvent && e.destination == f.path))
        .listen((_) => onChange());
  }

  Future<void> load() async {
    _file = File('${(await getApplicationSupportDirectory()).path}/settings.json');
    if (!await _file!.exists()) return;
    final j = jsonDecode(await _file!.readAsString()) as Map<String, dynamic>;
    reposDir = j['reposDir'];
    extraRepos = List<String>.from(j['extraRepos'] ?? []);
    currentRepo = j['currentRepo'];
    sidebarWidth = (j['sidebarWidth'] as num?)?.toDouble() ?? 250;
    groups = Map<String, String>.from(j['groups'] ?? {});
    editorCommand = j['editorCommand'] ?? 'code';
    groupIcons = Map<String, String>.from(j['groupIcons'] ?? {});
    accounts = [for (final a in j['accounts'] ?? const []) Account.fromJson(a)];
    repoAccounts = Map<String, String>.from(j['repoAccounts'] ?? {});
  }

  Future<void> update(void Function(Settings) change) async {
    change(this);
    notifyListeners();
    await _file?.parent.create(recursive: true);
    await _file?.writeAsString(
      jsonEncode({
        'reposDir': reposDir,
        'extraRepos': extraRepos,
        'currentRepo': currentRepo,
        'sidebarWidth': sidebarWidth,
        'groups': groups,
        'editorCommand': editorCommand,
        'groupIcons': groupIcons,
        'accounts': [for (final a in accounts) a.toJson()],
        'repoAccounts': repoAccounts,
      }),
    );
  }

  /// Todos los grupos: los creados y los que aparecen asignados a algún repo.
  List<String> allGroups() => ({...groupIcons.keys, ...groups.values}.toList()..sort());

  Trash get trash => Trash(Directory('${_file!.parent.path}${Platform.pathSeparator}papelera'));

  /// Repos locales: los de [reposDir] (un nivel) más los agregados a mano.
  List<String> localRepos() {
    final found = <String>{...extraRepos};
    final dir = reposDir == null ? null : Directory(reposDir!);
    if (dir != null && dir.existsSync()) {
      for (final e in dir.listSync().whereType<Directory>()) {
        if (Directory('${e.path}${Platform.pathSeparator}.git').existsSync()) found.add(e.path);
      }
    }
    final list = found.where((p) => Directory(p).existsSync()).toList();
    list.sort((a, b) => repoName(a).toLowerCase().compareTo(repoName(b).toLowerCase()));
    return list;
  }
}

String repoName(String path) => path.split(RegExp(r'[\\/]')).lastWhere((s) => s.isNotEmpty);
