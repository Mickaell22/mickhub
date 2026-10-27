import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'accounts.dart';
import 'avatar.dart';
import 'settings.dart';
import 'theme.dart';

IconData targetIcon(Provider p) => p == Provider.github ? Icons.code : Icons.cloud_outlined;

Color sessionColor(SessionState? s) => switch (s) {
  SessionState.ok => Gh.added,
  SessionState.expired || SessionState.missing => Gh.deleted,
  SessionState.error => Gh.modified,
  null => Gh.textSecondary,
};

/// Foto de la cuenta: la de su usuario de GitHub, o la de su email.
Widget accountAvatar(Account a, {double size = 20}) =>
    Avatar(user: a.githubUser, email: a.gitEmail, name: a.gitName.isEmpty ? a.label : a.gitName, size: size);

/// Panel de cuentas: estado de cada sesión, iniciar sesión, agregar y editar.
/// [sessions] se actualiza en el lugar; [onChanged] avisa al Shell para que
/// repinte la barra.
Future<void> showAccountsDialog(BuildContext context, Settings s, Map<String, Session> sessions, VoidCallback onChanged) {
  final busy = <String>{}; // fuera del builder: sobrevive a los setD
  return showDialog<void>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, setD) {
        Future<void> run(Account a, Future<Session> Function() op) async {
          setD(() => busy.add(a.id));
          sessions[a.id] = await op();
          busy.remove(a.id);
          onChanged();
          if (c.mounted) setD(() {});
        }

        return AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.manage_accounts_outlined, size: 18),
              SizedBox(width: 8),
              Text('Cuentas', style: TextStyle(fontSize: 14)),
            ],
          ),
          content: SizedBox(
            width: 600,
            child: s.accounts.isEmpty
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                      'Agrega tus cuentas (la personal y la del trabajo) para ver si su sesión está activa y para que cada '
                      'repo haga commit con la suya.',
                      style: TextStyle(color: Gh.textSecondary),
                    ),
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final a in s.accounts)
                        Container(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          decoration: const BoxDecoration(border: Border(bottom: Gh.divider)),
                          child: Row(
                            children: [
                              accountAvatar(a, size: 36),
                              const SizedBox(width: Gh.sp),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(a.label, style: const TextStyle(fontWeight: FontWeight.w600)),
                                    Text(
                                      '${a.places.isEmpty ? 'Sin GitHub ni Azure' : a.places}'
                                      '${a.hasIdentity ? ' · firma como ${a.gitName} <${a.gitEmail}>' : ' · sin nombre/email para commits'}',
                                      style: const TextStyle(fontSize: Gh.fontSizeSm, color: Gh.textSecondary),
                                    ),
                                    Row(
                                      children: [
                                        Icon(Icons.circle, size: 8, color: sessionColor(sessions[a.id]?.state)),
                                        const SizedBox(width: 4),
                                        Flexible(
                                          child: Text(
                                            busy.contains(a.id)
                                                ? 'Verificando…'
                                                : sessions[a.id] == null
                                                ? 'Sin verificar'
                                                : '${sessions[a.id]!.label} · ${sessions[a.id]!.detail}',
                                            style: const TextStyle(fontSize: Gh.fontSizeSm),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              if (sessions[a.id] != null && sessions[a.id]!.state != SessionState.ok)
                                TextButton.icon(
                                  onPressed: busy.contains(a.id) ? null : () => run(a, () => loginWithFeedback(c, a)),
                                  icon: const Icon(Icons.login, size: 16),
                                  label: const Text('Iniciar sesión'),
                                ),
                              PopupMenuButton<String>(
                                tooltip: 'Más',
                                icon: const Icon(Icons.more_vert, size: 18),
                                onSelected: (v) async {
                                  if (v == 'check') await run(a, () => checkSession(a));
                                  if (v == 'edit' && c.mounted) {
                                    final edited = await editAccount(c, a);
                                    if (edited != null) {
                                      await s.update((x) => x.accounts = [for (final o in x.accounts) o.id == a.id ? edited : o]);
                                      await run(edited, () => checkSession(edited));
                                    }
                                  }
                                  if (v == 'delete') {
                                    await s.update((x) {
                                      x.accounts = [...x.accounts]..removeWhere((o) => o.id == a.id);
                                      x.repoAccounts = {...x.repoAccounts}..removeWhere((_, id) => id == a.id);
                                    });
                                    sessions.remove(a.id);
                                    onChanged();
                                    setD(() {});
                                  }
                                },
                                itemBuilder: (_) => [
                                  menuItem('check', Icons.refresh, 'Verificar sesión'),
                                  menuItem('edit', Icons.edit_outlined, 'Editar…'),
                                  const PopupMenuDivider(),
                                  menuItem('delete', Icons.delete_outline, 'Quitar cuenta', danger: true),
                                ],
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
          ),
          actions: [
            TextButton.icon(
              onPressed: () async {
                final a = await editAccount(c, null);
                if (a == null) return;
                await s.update((x) => x.accounts = [...x.accounts, a]);
                await run(a, () => checkSession(a));
              },
              icon: const Icon(Icons.person_add_alt, size: 16),
              label: const Text('Agregar cuenta'),
            ),
            FilledButton(onPressed: () => Navigator.pop(c), child: const Text('Cerrar')),
          ],
        );
      },
    ),
  );
}

/// Inicia sesión en [only] (o en todo lo vencido de la cuenta) y, si no se
/// pudo, explica qué hacer.
Future<Session> loginWithFeedback(BuildContext context, Account a, {Target? only}) async {
  final issues = only == null ? await login(a) : [?await loginTarget(only)];
  final session = await checkSession(a);
  if (issues.isNotEmpty && context.mounted) {
    // Si todo se arregla con un comando, no es un error: es un paso que falta.
    final justSteps = issues.every((i) => i.command != null);
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: Row(
          children: [
            Icon(justSteps ? Icons.terminal : Icons.error_outline, size: 18, color: justSteps ? Gh.link : Gh.deleted),
            const SizedBox(width: 8),
            Text(justSteps ? 'Falta un paso en la terminal' : 'No se pudo iniciar sesión', style: const TextStyle(fontSize: 14)),
          ],
        ),
        content: SizedBox(
          width: 560,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: Gh.sp * 1.5,
            children: [
              for (final i in issues) ...[SelectableText(i.message), if (i.command != null) _CommandBox(i.command!)],
            ],
          ),
        ),
        actions: [FilledButton(onPressed: () => Navigator.pop(c), child: const Text('Entendido'))],
      ),
    );
  }
  return session;
}

/// Comando en letra de código con un botón para copiarlo.
class _CommandBox extends StatefulWidget {
  const _CommandBox(this.command);
  final String command;

  @override
  State<_CommandBox> createState() => _CommandBoxState();
}

class _CommandBoxState extends State<_CommandBox> {
  bool _copied = false;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(Gh.sp, 4, 4, 4),
    decoration: BoxDecoration(
      color: Gh.box,
      borderRadius: BorderRadius.circular(Gh.radius),
      border: Border.all(color: Gh.border),
    ),
    child: Row(
      children: [
        Expanded(
          child: SelectableText(
            widget.command,
            style: const TextStyle(fontFamily: 'monospace', fontSize: Gh.fontSizeSm),
          ),
        ),
        TextButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: widget.command));
            if (mounted) setState(() => _copied = true);
          },
          icon: Icon(_copied ? Icons.check : Icons.copy, size: 14),
          label: Text(_copied ? 'Copiado' : 'Copiar'),
        ),
      ],
    ),
  );
}

/// Crea (con [current] null) o edita una cuenta.
Future<Account?> editAccount(BuildContext context, Account? current) async {
  final label = TextEditingController(text: current?.label);
  final gh = TextEditingController(text: current?.githubUser);
  final orgs = TextEditingController(text: current?.azureOrgs.join(', '));
  final name = TextEditingController(text: current?.gitName);
  final email = TextEditingController(text: current?.gitEmail);
  Widget field(TextEditingController ctrl, String hint, {String? help, IconData? icon}) => Padding(
    padding: const EdgeInsets.only(top: Gh.sp),
    child: TextField(
      controller: ctrl,
      style: const TextStyle(fontSize: Gh.fontSize),
      decoration: InputDecoration(
        labelText: hint,
        helperText: help,
        helperMaxLines: 2,
        prefixIcon: icon == null ? null : Icon(icon, size: 16),
      ),
    ),
  );
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(current == null ? 'Agregar cuenta' : 'Editar cuenta', style: const TextStyle(fontSize: 14)),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              field(label, 'Nombre de la cuenta (p. ej. Personal, Trabajo)', icon: Icons.badge_outlined),
              field(name, 'Nombre para los commits', icon: Icons.person_outline),
              field(
                email,
                'Email para los commits',
                icon: Icons.alternate_email,
                help: 'Con esto se firman los commits; también da la foto.',
              ),
              const Padding(
                padding: EdgeInsets.only(top: Gh.sp * 1.5),
                child: Text('Dónde están sus repos', style: TextStyle(fontWeight: FontWeight.w600)),
              ),
              field(gh, 'Usuario de GitHub (opcional)', icon: Icons.code),
              field(
                orgs,
                'Organizaciones de Azure DevOps (opcional)',
                icon: Icons.cloud_outlined,
                help: 'Pega la dirección de cualquier repo de Azure (o solo el nombre de la organización). Varias, separadas por coma.',
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(current == null ? 'Agregar' : 'Guardar')),
      ],
    ),
  );
  final orgList = [
    for (final o in orgs.text.split(','))
      if (o.trim().isNotEmpty) azureOrgFrom(o),
  ];
  final result = ok == true && label.text.trim().isNotEmpty
      ? Account(
          id: current?.id ?? DateTime.now().microsecondsSinceEpoch.toString(),
          label: label.text.trim(),
          githubUser: gh.text.trim().isEmpty ? null : gh.text.trim(),
          azureOrgs: orgList,
          gitName: name.text.trim(),
          gitEmail: email.text.trim(),
        )
      : null;
  for (final c in [label, gh, orgs, name, email]) {
    disposeAfterDialog(c);
  }
  return result;
}

/// Elige la cuenta de un repo: una concreta o "Automática" (según el remoto).
/// Devuelve '' para automática, null si se canceló.
Future<String?> pickAccount(BuildContext context, List<Account> accounts, String? current) => showDialog<String>(
  context: context,
  builder: (c) => SimpleDialog(
    title: const Text('Cuenta de este repositorio', style: TextStyle(fontSize: 14)),
    children: [
      SimpleDialogOption(
        onPressed: () => Navigator.pop(c, ''),
        child: Row(
          children: [
            Icon(current == null ? Icons.radio_button_checked : Icons.radio_button_off, size: 16),
            const SizedBox(width: Gh.sp),
            const Text('Automática (según el remoto)'),
          ],
        ),
      ),
      for (final a in accounts)
        SimpleDialogOption(
          onPressed: () => Navigator.pop(c, a.id),
          child: Row(
            children: [
              Icon(current == a.id ? Icons.radio_button_checked : Icons.radio_button_off, size: 16),
              const SizedBox(width: Gh.sp),
              accountAvatar(a, size: 18),
              const SizedBox(width: 6),
              Text(a.label),
            ],
          ),
        ),
    ],
  ),
);

/// La sesión de [a] en [target] venció en medio de una operación: ofrece
/// iniciar sesión. Devuelve true si quedó conectada (para reintentar).
Future<bool> askLogin(BuildContext context, Account a, Target? target) async {
  final go = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.lock_clock_outlined, size: 18, color: Gh.modified),
          const SizedBox(width: 8),
          Text('La sesión de ${a.label} venció', style: const TextStyle(fontSize: 14)),
        ],
      ),
      content: Text(
        target?.provider == Provider.azure
            ? 'Azure DevOps (${target!.name}) pide volver a iniciar sesión cada cierto tiempo. Se abrirá el login del '
                  'Git Credential Manager y después se reintenta la operación.'
            : 'El remoto rechazó la credencial. Inicia sesión otra vez y se reintenta la operación.',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Ahora no')),
        FilledButton.icon(
          onPressed: () => Navigator.pop(c, true),
          icon: const Icon(Icons.login, size: 16),
          label: const Text('Iniciar sesión'),
        ),
      ],
    ),
  );
  if (go != true || !context.mounted) return false;
  final s = await loginWithFeedback(context, a, only: target);
  return target == null ? s.state == SessionState.ok : (await checkTarget(target)).state == SessionState.ok;
}
