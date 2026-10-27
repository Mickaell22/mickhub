import 'package:flutter/material.dart';

import 'theme.dart';

/// Pide el nombre de un grupo de cambios. Null si se canceló.
Future<String?> askGroupName(BuildContext context, {required String title, String? initial, Set<String> taken = const {}}) =>
    showDialog<String>(
      context: context,
      builder: (_) => _NameDialog(title: title, initial: initial, taken: taken),
    );

/// El diálogo es dueño de su controlador y lo libera en su propio dispose: si
/// lo liberara quien lo abre, el campo todavía lo usa durante la animación de
/// cierre y Flutter falla (pantalla roja).
class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.title, this.initial, required this.taken});
  final String title;
  final String? initial;
  final Set<String> taken;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _ctrl = TextEditingController(text: widget.initial);
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final v = _ctrl.text.trim();
    if (v.isEmpty) return;
    if (v != widget.initial && widget.taken.contains(v)) return setState(() => _error = 'Ya hay un grupo con ese nombre');
    Navigator.pop(context, v);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Row(
      children: [
        const Icon(Icons.folder_special_outlined, size: 18),
        const SizedBox(width: 8),
        Text(widget.title, style: const TextStyle(fontSize: 14)),
      ],
    ),
    content: SizedBox(
      width: 420,
      child: TextField(
        controller: _ctrl,
        autofocus: true,
        decoration: InputDecoration(hintText: 'Qué estás implementando (p. ej. Buscador)', errorText: _error),
        onSubmitted: (_) => _submit(),
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
      FilledButton(onPressed: _submit, child: const Text('Guardar')),
    ],
  );
}

/// Menú para elegir a qué grupo mover algo: los grupos, "Sin grupo" y "Nuevo
/// grupo…". Devuelve el nombre ('' = sin grupo; uno nuevo si se creó) o null.
Future<String?> pickGroup(BuildContext context, Offset at, List<String> names, {String? current}) async {
  const newGroup = '\u0001nuevo';
  final choice = await showMenu<String>(
    context: context,
    position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
    items: [
      for (final n in names)
        if (n != current) menuItem(n, Icons.folder_special_outlined, n),
      if (current != '') menuItem('', Icons.folder_off_outlined, 'Sin grupo'),
      const PopupMenuDivider(),
      menuItem(newGroup, Icons.create_new_folder_outlined, 'Nuevo grupo…'),
    ],
  );
  if (choice != newGroup || !context.mounted) return choice;
  return askGroupName(context, title: 'Nuevo grupo de cambios', taken: names.toSet());
}
