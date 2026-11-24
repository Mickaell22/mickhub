// Reglas de texto de los hooks de `mickhub` (cli/bin/mickhub.dart). Viven aquí,
// sin Flutter, para poder probarlas con los tests de la app (`hook_rules_test`).

/// Órdenes de subir: "haz push", "dale push", "dale, push", "sí, push", "commit y
/// push", "pushea", "súbelo", "sube lo de lucky", "sube los cambios", "en el
/// repo de github", "a github". Una palabra suelta no basta: "solo commit y no
/// push" no debe dar permiso.
final pushOrder = RegExp(
  r'\b(haz|hazle|has|dale|hacer|y|s[ií])[\s,]+(el\s+|un\s+)?push\b|\bpushea\w*|\bs[uú]bel[oa]s?\b|\bs[uú]be\s+(lo|los|todo|eso|esto)\b|\b(a|al|en\s+el)\s+(repo\s+(de\s+)?)?github\b',
  caseSensitive: false,
);

/// El mensaje pide subir y esa orden no está negada ("no hagas push", "y no push").
bool asksPush(String prompt) => pushOrder
    .allMatches(prompt)
    .any((m) => !RegExp(r'\bno\b[^.,;!?]{0,12}$', caseSensitive: false).hasMatch(prompt.substring(0, m.start)));

/// Un comando de git (o `mickhub`) que solo mueve cambios que ya existían:
/// recuperar un apartado, cambiar de rama, traer, restaurar un archivo.
final movesChanges = RegExp(
  r'''(^|[;&|(\s])(git\s+(?:(?:-[cC]|--git-dir|--work-tree)\s+(?:"[^"]*"|'[^']*'|\S+)\s+|--?\S+\s+)*'''
  r'''(stash|checkout|switch|restore|reset|pull|merge|rebase|cherry-pick|revert|am)\b|mickhub(\.exe)?\s)''',
);

final _quoted = RegExp('"(?:[^"\\\\]|\\\\.)*"|\'[^\']*\'');

/// El Bash entero solo mueve cambios: cada parte (separada por `&&`, `||`,
/// `;`, `|` o salto de línea) es un `cd` o un comando de [movesChanges]. Antes
/// se miraba el comando entero y bastaba un `git checkout -q archivo` o un
/// `mickhub estado` al final para que lo editado en el resto quedara en "Sin
/// grupo" (pasó en casi todos los comandos de una sesión).
bool onlyMovesChanges(String command) {
  final parts = command.replaceAll(_quoted, 'Q').split(RegExp(r'&&|\|\||[;|\n]')).map((p) => p.trim()).where((p) => p.isNotEmpty);
  if (parts.isEmpty) return false;
  return parts.every((p) => RegExp(r'^cd(\s|$)').hasMatch(p) || movesChanges.hasMatch(p));
}

/// Hay alguna parte que mueve cambios (aunque el comando haga más cosas).
bool mixesMoves(String command) => movesChanges.hasMatch(command.replaceAll(_quoted, 'Q'));
