import 'dart:io';

import 'package:flutter/material.dart';

import 'git.dart';
import 'github.dart';
import 'settings.dart';
import 'theme.dart';

enum CloneFilter { all, cloned, notCloned }

/// Diálogo "Clonar un repositorio": todos los repos de la cuenta, con filtros y
/// clonado en un clic. Devuelve la ruta del repo recién clonado, si hubo uno.
Future<String?> showCloneDialog(BuildContext context, Settings settings, Set<String> clonedRemotes) => showDialog<String>(
  context: context,
  builder: (_) => Dialog(
    backgroundColor: Gh.bg,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Gh.radius), side: Gh.divider),
    child: SizedBox(
      width: 640,
      height: 560,
      child: _CloneBody(settings: settings, clonedRemotes: clonedRemotes),
    ),
  ),
);

class _CloneBody extends StatefulWidget {
  const _CloneBody({required this.settings, required this.clonedRemotes});
  final Settings settings;
  final Set<String> clonedRemotes;

  @override
  State<_CloneBody> createState() => _CloneBodyState();
}

class _CloneBodyState extends State<_CloneBody> {
  List<Repo>? _repos;
  String? _error;
  String _query = '';
  String? _owner;
  CloneFilter _filter = CloneFilter.all;
  String? _cloning;
  late final _dir = TextEditingController(text: widget.settings.reposDir);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _dir.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _repos = null;
      _error = null;
    });
    final token = await credentialToken('github.com');
    if (token == null) {
      setState(
        () => _error =
            'Git no tiene credenciales de GitHub. Inicia sesión con '
            '"gh auth login" o con el Git Credential Manager y vuelve a cargar.',
      );
      return;
    }
    try {
      final repos = await githubRepos(token);
      if (mounted) setState(() => _repos = repos);
    } catch (e) {
      if (mounted) setState(() => _error = 'No se pudo traer la lista de repos: $e');
    }
  }

  bool _isCloned(Repo r) => widget.clonedRemotes.contains(remoteKey(r.cloneUrl));

  Future<void> _clone(Repo r) async {
    final dir = _dir.text.trim();
    if (dir.isEmpty || !Directory(dir).existsSync()) {
      _snack('La carpeta de destino no existe.');
      return;
    }
    if (dir != widget.settings.reposDir) await widget.settings.update((s) => s.reposDir = dir);
    // ponytail: se clona en <carpeta>/<nombre>; si ya existe una carpeta con ese
    // nombre git falla y se muestra el error. Upgrade: <carpeta>/<dueño>/<nombre>.
    final target = '$dir${Platform.pathSeparator}${r.name}';
    setState(() => _cloning = r.fullName);
    try {
      await git(['clone', r.cloneUrl, target]);
      if (mounted) Navigator.pop(context, target);
    } on GitException catch (e) {
      _snack('No se pudo clonar ${r.fullName}: ${e.message}');
      if (mounted) setState(() => _cloning = null);
    }
  }

  void _snack(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(Gh.sp * 1.5),
          decoration: const BoxDecoration(border: Border(bottom: Gh.divider)),
          child: Row(
            children: [
              const Text('Clonar un repositorio', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              const Spacer(),
              IconButton(tooltip: 'Recargar', iconSize: 16, onPressed: _load, icon: const Icon(Icons.refresh)),
              IconButton(tooltip: 'Cerrar', iconSize: 16, onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
            ],
          ),
        ),
        Expanded(child: _list()),
        Container(
          padding: const EdgeInsets.all(Gh.sp),
          decoration: const BoxDecoration(
            color: Gh.boxAlt,
            border: Border(top: Gh.divider),
          ),
          child: Row(
            children: [
              const Text('Carpeta de destino  '),
              Expanded(
                child: TextField(
                  controller: _dir,
                  style: const TextStyle(fontSize: Gh.fontSize),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _list() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!, textAlign: TextAlign.center),
        ),
      );
    }
    final repos = _repos;
    if (repos == null) return const Center(child: CircularProgressIndicator());

    final owners = {for (final r in repos) r.owner}.toList()..sort();
    final q = _query.toLowerCase();
    final shown = repos.where((r) {
      if (_owner != null && r.owner != _owner) return false;
      if (q.isNotEmpty && !'${r.fullName} ${r.description ?? ''}'.toLowerCase().contains(q)) return false;
      return switch (_filter) {
        CloneFilter.all => true,
        CloneFilter.cloned => _isCloned(r),
        CloneFilter.notCloned => !_isCloned(r),
      };
    }).toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(Gh.sp),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  autofocus: true,
                  style: const TextStyle(fontSize: Gh.fontSize),
                  decoration: const InputDecoration(prefixIcon: Icon(Icons.search, size: 16), hintText: 'Filtrar repositorios'),
                  onChanged: (v) => setState(() => _query = v),
                ),
              ),
              const SizedBox(width: Gh.sp),
              DropdownButton<String?>(
                value: _owner,
                isDense: true,
                style: const TextStyle(fontSize: Gh.fontSize, color: Gh.text),
                items: [
                  const DropdownMenuItem(value: null, child: Text('Todos los dueños')),
                  for (final o in owners) DropdownMenuItem(value: o, child: Text(o)),
                ],
                onChanged: (v) => setState(() => _owner = v),
              ),
              const SizedBox(width: Gh.sp),
              DropdownButton<CloneFilter>(
                value: _filter,
                isDense: true,
                style: const TextStyle(fontSize: Gh.fontSize, color: Gh.text),
                items: const [
                  DropdownMenuItem(value: CloneFilter.all, child: Text('Todos')),
                  DropdownMenuItem(value: CloneFilter.cloned, child: Text('Clonados')),
                  DropdownMenuItem(value: CloneFilter.notCloned, child: Text('Sin clonar')),
                ],
                onChanged: (v) => setState(() => _filter = v!),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gh.sp),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text('${shown.length} de ${repos.length}', style: Theme.of(context).textTheme.bodySmall),
          ),
        ),
        Expanded(
          child: shown.isEmpty
              ? const Center(
                  child: Text('Ningún repo coincide con los filtros.', style: TextStyle(color: Gh.textSecondary)),
                )
              : ListView.builder(itemCount: shown.length, itemExtent: 44, itemBuilder: (_, i) => _tile(shown[i])),
        ),
      ],
    );
  }

  Widget _tile(Repo r) {
    final Widget trailing;
    if (_cloning == r.fullName) {
      trailing = const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2));
    } else if (_isCloned(r)) {
      trailing = const Text('Clonado', style: TextStyle(color: Gh.textSecondary));
    } else {
      trailing = TextButton(onPressed: _cloning == null ? () => _clone(r) : null, child: const Text('Clonar'));
    }
    return Container(
      decoration: const BoxDecoration(border: Border(bottom: Gh.divider)),
      padding: const EdgeInsets.symmetric(horizontal: Gh.sp),
      child: Row(
        children: [
          Icon(r.private ? Icons.lock_outline : Icons.book_outlined, size: 16, color: Gh.textSecondary),
          const SizedBox(width: Gh.sp),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(r.fullName, overflow: TextOverflow.ellipsis),
                if (r.description != null)
                  Text(r.description!, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          trailing,
        ],
      ),
    );
  }
}
