import 'dart:io';

import 'package:flutter/material.dart';

import 'accounts.dart';
import 'accounts_ui.dart';
import 'git.dart';
import 'settings.dart';
import 'system.dart';
import 'theme.dart';

/// "Nuevo repositorio": nombre, carpeta y README opcional. Devuelve la ruta del
/// repo creado, o null si se canceló.
Future<String?> showNewRepoDialog(BuildContext context, Settings s) async {
  final name = TextEditingController();
  final dir = TextEditingController(text: s.reposDir);
  var readme = true;
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, setD) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.add_box_outlined, size: 18),
            SizedBox(width: 8),
            Text('Nuevo repositorio', style: TextStyle(fontSize: 14)),
          ],
        ),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: name,
                autofocus: true,
                style: const TextStyle(fontSize: Gh.fontSize),
                decoration: const InputDecoration(labelText: 'Nombre', prefixIcon: Icon(Icons.book_outlined, size: 16)),
              ),
              const SizedBox(height: Gh.sp),
              TextField(
                controller: dir,
                style: const TextStyle(fontSize: Gh.fontSize),
                decoration: InputDecoration(
                  labelText: 'Dentro de la carpeta',
                  prefixIcon: const Icon(Icons.folder_outlined, size: 16),
                  suffixIcon: IconButton(
                    tooltip: 'Elegir carpeta',
                    iconSize: 16,
                    icon: const Icon(Icons.folder_open_outlined),
                    onPressed: () async {
                      final d = await pickFolder(initial: dir.text.isEmpty ? null : dir.text);
                      if (d != null) dir.text = d;
                    },
                  ),
                ),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: readme,
                onChanged: (v) => setD(() => readme = v!),
                title: const Text('Crear un README y el primer commit'),
                subtitle: const Text('Sin commits no se puede publicar.', style: TextStyle(fontSize: Gh.fontSizeSm)),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Crear')),
        ],
      ),
    ),
  );
  final n = name.text.trim(), parent = dir.text.trim();
  name.dispose();
  dir.dispose();
  if (ok != true || n.isEmpty || parent.isEmpty) return null;
  final path = '$parent${Platform.pathSeparator}$n';
  if (Directory(path).existsSync() && Directory(path).listSync().isNotEmpty) {
    throw FileSystemException('Ya existe una carpeta con ese nombre y no está vacía', path);
  }
  await initRepo(path, n, readme: readme);
  return path;
}

/// "Publicar repositorio": crea el repo en GitHub o en un proyecto de Azure,
/// agrega el remoto y sube. Devuelve la URL del remoto, o null si se canceló.
Future<String?> showPublishDialog(BuildContext context, Settings s, String repo) async {
  final targets = [
    for (final a in s.accounts)
      for (final t in a.targets) (a, t),
  ];
  if (targets.isEmpty) {
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Publicar repositorio', style: TextStyle(fontSize: 14)),
        content: const Text('Primero agrega una cuenta con su GitHub o su organización de Azure DevOps (botón Cuentas).'),
        actions: [FilledButton(onPressed: () => Navigator.pop(c), child: const Text('Entendido'))],
      ),
    );
    return null;
  }
  final name = TextEditingController(text: repo.split(RegExp(r'[\\/]')).last);
  var target = targets.first;
  var private = true;
  String? project;
  List<String>? projects;
  String? error;
  var busy = false, loadingProjects = false;
  final url = await showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (c) => StatefulBuilder(
      builder: (c, setD) {
        Future<void> loadProjects() async {
          projects = null;
          error = null;
          setD(() {});
          try {
            projects = await azureProjects(target.$2.name);
            project = projects!.firstOrNull;
          } catch (e) {
            error = '$e';
          }
          if (c.mounted) setD(() {});
        }

        final azure = target.$2.provider == Provider.azure;
        if (azure && projects == null && error == null && !loadingProjects) {
          loadingProjects = true; // una vez por destino
          loadProjects().then((_) => loadingProjects = false);
        }
        return AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.cloud_upload_outlined, size: 18),
              SizedBox(width: 8),
              Text('Publicar repositorio', style: TextStyle(fontSize: 14)),
            ],
          ),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropdownButtonFormField<(Account, Target)>(
                  initialValue: target,
                  decoration: const InputDecoration(labelText: 'Publicar en'),
                  items: [
                    for (final t in targets)
                      DropdownMenuItem(
                        value: t,
                        child: Row(
                          children: [
                            Icon(targetIcon(t.$2.provider), size: 14),
                            const SizedBox(width: 6),
                            Text('${t.$1.label} · ${t.$2.label}'),
                          ],
                        ),
                      ),
                  ],
                  onChanged: (v) => setD(() {
                    target = v!;
                    projects = null;
                    error = null;
                  }),
                ),
                const SizedBox(height: Gh.sp),
                TextField(
                  controller: name,
                  style: const TextStyle(fontSize: Gh.fontSize),
                  decoration: const InputDecoration(labelText: 'Nombre del repo'),
                ),
                const SizedBox(height: Gh.sp),
                if (!azure)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: private,
                    onChanged: (v) => setD(() => private = v),
                    title: const Text('Privado'),
                  )
                else if (projects == null && error == null)
                  const Padding(
                    padding: EdgeInsets.all(8),
                    child: Text('Cargando proyectos…', style: TextStyle(color: Gh.textSecondary)),
                  )
                else if (projects != null)
                  DropdownButtonFormField<String>(
                    initialValue: project,
                    decoration: const InputDecoration(labelText: 'Proyecto de Azure DevOps'),
                    items: [for (final p in projects!) DropdownMenuItem(value: p, child: Text(p))],
                    onChanged: (v) => setD(() => project = v),
                  ),
                if (error != null) Text(error!, style: const TextStyle(color: Gh.deleted)),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancelar')),
            FilledButton(
              onPressed: busy || name.text.trim().isEmpty || (azure && project == null)
                  ? null
                  : () async {
                      setD(() {
                        busy = true;
                        error = null;
                      });
                      try {
                        final remote = await createRemoteRepo(target.$2, name.text.trim(), private: private, project: project);
                        await publishRepo(repo, remote);
                        if (c.mounted) Navigator.pop(c, remote);
                      } catch (e) {
                        setD(() {
                          busy = false;
                          error = e is GitException ? e.message : '$e';
                        });
                      }
                    },
              child: Text(busy ? 'Publicando…' : 'Publicar'),
            ),
          ],
        );
      },
    ),
  );
  name.dispose();
  return url;
}
