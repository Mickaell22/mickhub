import 'package:flutter/painting.dart';
import 'package:highlight/highlight.dart' show highlight, Node;

/// Colores de sintaxis del tema oscuro de GitHub Desktop (`--syntax-*`).
abstract final class Syntax {
  static const keyword = Color(0xfff97583); // red-300: keyword, type, header
  static const string = Color(0xffffab70); // orange-300
  static const variable = Color(0xffb392f0); // purple-300: variable, attribute, qualifier
  static const atom = Color(0xff79b8ff); // blue-300: atom, alt-variable, link
  static const comment = Color(0xff959da5); // gray-400
  static const tag = Color(0xff34d058); // green-400: tag, quote
}

/// Clase de highlight.js -> color de Desktop. Lo que no está queda con el color
/// de texto normal.
const _colors = <String, Color>{
  'keyword': Syntax.keyword,
  'type': Syntax.keyword,
  'section': Syntax.keyword,
  'selector-tag': Syntax.keyword,
  'meta-keyword': Syntax.keyword,
  'string': Syntax.string,
  'regexp': Syntax.string,
  'meta-string': Syntax.string,
  'variable': Syntax.variable,
  'template-variable': Syntax.variable,
  'attr': Syntax.variable,
  'attribute': Syntax.variable,
  'title': Syntax.variable,
  'params': Syntax.variable,
  'number': Syntax.atom,
  'literal': Syntax.atom,
  'symbol': Syntax.atom,
  'built_in': Syntax.atom,
  'link': Syntax.atom,
  'meta': Syntax.atom,
  'comment': Syntax.comment,
  'doctag': Syntax.comment,
  'tag': Syntax.tag,
  'name': Syntax.tag,
  'quote': Syntax.tag,
  'selector-class': Syntax.tag,
  'selector-id': Syntax.tag,
  'bullet': Syntax.tag,
};

const _byExtension = {
  'dart': 'dart',
  'js': 'javascript',
  'jsx': 'javascript',
  'mjs': 'javascript',
  'cjs': 'javascript',
  'ts': 'typescript',
  'tsx': 'typescript',
  'py': 'python',
  'json': 'json',
  'yaml': 'yaml',
  'yml': 'yaml',
  'md': 'markdown',
  'html': 'xml',
  'htm': 'xml',
  'xml': 'xml',
  'svg': 'xml',
  'xaml': 'xml',
  'csproj': 'xml',
  'css': 'css',
  'scss': 'scss',
  'less': 'less',
  'sh': 'bash',
  'bash': 'bash',
  'zsh': 'bash',
  'cs': 'cs',
  'java': 'java',
  'kt': 'kotlin',
  'kts': 'kotlin',
  'go': 'go',
  'rs': 'rust',
  'c': 'cpp',
  'h': 'cpp',
  'cc': 'cpp',
  'cpp': 'cpp',
  'hpp': 'cpp',
  'sql': 'sql',
  'php': 'php',
  'rb': 'ruby',
  'swift': 'swift',
  'gradle': 'gradle',
  'toml': 'ini',
  'ini': 'ini',
  'vue': 'vue',
  'ps1': 'powershell',
  'bat': 'dos',
  'cmd': 'dos',
  'lua': 'lua',
  'cmake': 'cmake',
};

/// Lenguaje de highlight.js para una ruta, o null si no se reconoce.
String? languageFor(String path) {
  final name = path.split('/').last.toLowerCase();
  if (name == 'dockerfile') return 'dockerfile';
  if (name == 'cmakelists.txt') return 'cmake';
  if (name == 'makefile') return 'makefile';
  final dot = name.lastIndexOf('.');
  return dot < 0 ? null : _byExtension[name.substring(dot + 1)];
}

/// Resalta [lines] como un solo bloque (así los comentarios y strings de varias
/// líneas quedan bien) y devuelve los tramos de color de cada línea.
/// Devuelve null si el lenguaje no se reconoce o el parser falla.
List<List<TextSpan>>? highlightLines(List<String> lines, String? language) {
  if (language == null) return null;
  final List<Node> nodes;
  try {
    nodes = highlight.parse(lines.join('\n'), language: language).nodes ?? [];
  } catch (_) {
    return null;
  }
  final out = <List<TextSpan>>[[]];
  void walk(Node n, Color? inherited) {
    final color = _colors[n.className] ?? inherited;
    if (n.value != null) {
      final parts = n.value!.split('\n');
      for (var i = 0; i < parts.length; i++) {
        if (i > 0) out.add([]);
        if (parts[i].isNotEmpty) {
          out.last.add(
            TextSpan(
              text: parts[i],
              style: color == null ? null : TextStyle(color: color),
            ),
          );
        }
      }
    }
    for (final c in n.children ?? const <Node>[]) {
      walk(c, color);
    }
  }

  for (final n in nodes) {
    walk(n, null);
  }
  return out.length == lines.length ? out : null;
}
