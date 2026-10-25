import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

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

  File? _file;

  Future<void> load() async {
    _file = File('${(await getApplicationSupportDirectory()).path}/settings.json');
    if (!await _file!.exists()) return;
    final j = jsonDecode(await _file!.readAsString()) as Map<String, dynamic>;
    reposDir = j['reposDir'];
    extraRepos = List<String>.from(j['extraRepos'] ?? []);
    currentRepo = j['currentRepo'];
    sidebarWidth = (j['sidebarWidth'] as num?)?.toDouble() ?? 250;
  }

  Future<void> update(void Function(Settings) change) async {
    change(this);
    notifyListeners();
    await _file?.parent.create(recursive: true);
    await _file?.writeAsString(jsonEncode({
      'reposDir': reposDir,
      'extraRepos': extraRepos,
      'currentRepo': currentRepo,
      'sidebarWidth': sidebarWidth,
    }));
  }

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
