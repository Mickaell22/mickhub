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

  /// Grupos contraídos en la lista de repos ('' = "Sin grupo").
  List<String> collapsedGroups = [];

  /// Grupos marcados en el filtro de la lista de repos (vacío = todos).
  List<String> groupFilter = [];

  /// Cuentas (GitHub, organizaciones de Azure DevOps) y con qué firman commits.
  List<Account> accounts = [];

  /// Cuenta forzada a mano para un repo (ruta -> id de cuenta); si no hay, se
  /// deduce del remoto con [accountFor].
  Map<String, String> repoAccounts = {};

  /// Días que se guarda lo descartado en la papelera antes de borrarse solo.
  int trashDays = 30;

  /// Comando para "Abrir en el editor".
  String editorCommand = 'code';

  /// Comando para "Abrir en la terminal"; vacío = detectarla sola (findTerminal).
  String terminalCommand = '';

  /// Perfil de la lista de repos: id de cuenta ('' = todos).
  String profile = '';

  /// Carpeta de clonado propia de una cuenta (id -> carpeta); sin entrada, [reposDir].
  Map<String, String> profileDirs = {};

  String? cloneDirFor(String? accountId) => profileDirs[accountId] ?? reposDir;

  /// API de resúmenes con IA (v2). Vacíos = resúmenes apagados.
  String apiUrl = '';
  String apiToken = '';

  /// Personalización (`look.dart`, `decor.dart`). [look]: paleta elegida
  /// (nombre de [Look]); [rotation]: 'fija', 'dia' (una distinta cada día) o
  /// 'abrir' (una al azar cada vez que se abre).
  String look = 'desktop';
  String rotation = 'fija';

  /// Fechas especiales (Halloween, Navidad...) activas por defecto.
  bool seasonal = true;

  /// Temporada saltada a mano (`seasonKey`): eligió otra paleta durante ella.
  String skippedSeason = '';

  /// Cumpleaños ('MM-DD', vacío = sin cumpleaños): ese día, paleta de fiesta.
  String birthday = '';

  /// Escenas y mascota. [scene]: 'auto' (la de la paleta), 'ninguna' o el
  /// nombre de una [Scene]. [pet]: 'ninguna', 'azar' o el nombre de una mascota.
  bool decor = true;
  String scene = 'auto';
  String pet = 'gato';

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
    terminalCommand = j['terminalCommand'] ?? '';
    profile = j['profile'] ?? '';
    profileDirs = Map<String, String>.from(j['profileDirs'] ?? {});
    apiUrl = j['apiUrl'] ?? '';
    apiToken = j['apiToken'] ?? '';
    trashDays = (j['trashDays'] as num?)?.toInt() ?? 30;
    groupIcons = Map<String, String>.from(j['groupIcons'] ?? {});
    accounts = [for (final a in j['accounts'] ?? const []) Account.fromJson(a)];
    repoAccounts = Map<String, String>.from(j['repoAccounts'] ?? {});
    collapsedGroups = List<String>.from(j['collapsedGroups'] ?? []);
    groupFilter = List<String>.from(j['groupFilter'] ?? []);
    look = j['look'] ?? 'desktop';
    rotation = j['rotation'] ?? 'fija';
    seasonal = j['seasonal'] ?? true;
    skippedSeason = j['skippedSeason'] ?? '';
    birthday = j['birthday'] ?? '';
    decor = j['decor'] ?? true;
    scene = j['scene'] ?? 'auto';
    pet = j['pet'] ?? 'gato';
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
        'terminalCommand': terminalCommand,
        'profile': profile,
        'profileDirs': profileDirs,
        'apiUrl': apiUrl,
        'apiToken': apiToken,
        'trashDays': trashDays,
        'groupIcons': groupIcons,
        'accounts': [for (final a in accounts) a.toJson()],
        'repoAccounts': repoAccounts,
        'collapsedGroups': collapsedGroups,
        'groupFilter': groupFilter,
        'look': look,
        'rotation': rotation,
        'seasonal': seasonal,
        'skippedSeason': skippedSeason,
        'birthday': birthday,
        'decor': decor,
        'scene': scene,
        'pet': pet,
      }),
    );
  }

  /// Todos los grupos: los creados y los que aparecen asignados a algún repo.
  List<String> allGroups() => ({...groupIcons.keys, ...groups.values}.toList()..sort());

  /// Carpeta de datos de la app (la de este JSON).
  Directory get dataDir => _file!.parent;

  Trash get trash => Trash(Directory('${dataDir.path}${Platform.pathSeparator}papelera'));

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
