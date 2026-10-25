import 'package:flutter/material.dart';

import 'syntax.dart';
import 'theme.dart';

enum LineKind { context, add, delete, hunk }

class DiffLine {
  const DiffLine(this.kind, this.text, {this.oldNo, this.newNo});
  final LineKind kind;
  final String text;
  final int? oldNo, newNo;
}

/// Parsea un diff unificado de un archivo. Devuelve null si git lo marcó binario.
List<DiffLine>? parseDiff(String diff) {
  final lines = <DiffLine>[];
  var oldNo = 0, newNo = 0;
  var inHunk = false;
  for (final l in diff.split('\n')) {
    if (!inHunk && l.startsWith('Binary files')) return null;
    final h = RegExp(r'^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@').firstMatch(l);
    if (h != null) {
      oldNo = int.parse(h[1]!);
      newNo = int.parse(h[2]!);
      inHunk = true;
      lines.add(DiffLine(LineKind.hunk, l));
    } else if (!inHunk || l.startsWith(r'\')) {
      continue; // cabeceras del diff y "\ No newline at end of file"
    } else if (l.startsWith('+')) {
      lines.add(DiffLine(LineKind.add, l.substring(1), newNo: newNo++));
    } else if (l.startsWith('-')) {
      lines.add(DiffLine(LineKind.delete, l.substring(1), oldNo: oldNo++));
    } else if (l.startsWith(' ')) {
      lines.add(DiffLine(LineKind.context, l.substring(1), oldNo: oldNo++, newNo: newNo++));
    }
  }
  return lines;
}

/// Diff unificado al estilo de GitHub Desktop: dos columnas de números de 50 px,
/// fondo verde/rojo por línea y resaltado de sintaxis según la extensión de [path].
class DiffView extends StatefulWidget {
  const DiffView(this.diff, {super.key, required this.path});
  final String diff;
  final String path;

  @override
  State<DiffView> createState() => _DiffViewState();
}

class _DiffViewState extends State<DiffView> {
  List<DiffLine>? _lines;
  final _spans = <int, List<TextSpan>>{}; // índice de línea -> tramos coloreados

  @override
  void initState() {
    super.initState();
    _parse();
  }

  @override
  void didUpdateWidget(DiffView old) {
    super.didUpdateWidget(old);
    if (old.diff != widget.diff || old.path != widget.path) _parse();
  }

  // ponytail: se resaltan juntas las líneas de contexto, borradas y agregadas;
  // si una línea borrada abre un comentario o string que la agregada no abre, el
  // color se corre hasta el final del bloque. Upgrade: resaltar por separado el
  // lado viejo (contexto + borradas) y el nuevo (contexto + agregadas).
  void _parse() {
    _lines = parseDiff(widget.diff);
    _spans.clear();
    final lines = _lines;
    if (lines == null) return;
    final code = [for (var i = 0; i < lines.length; i++) if (lines[i].kind != LineKind.hunk) i];
    final hl = highlightLines([for (final i in code) lines[i].text], languageFor(widget.path));
    if (hl == null) return;
    for (var k = 0; k < code.length; k++) {
      _spans[code[k]] = hl[k];
    }
  }

  @override
  Widget build(BuildContext context) {
    final lines = _lines;
    if (lines == null) return const _Centered('Este archivo es binario y no se puede mostrar.');
    if (lines.isEmpty) return const _Centered('Sin cambios de contenido (solo permisos o renombre).');
    return SelectionArea(
      child: ListView.builder(
        itemCount: lines.length,
        itemExtent: 18,
        itemBuilder: (_, i) => _line(lines[i], _spans[i]),
      ),
    );
  }

  Widget _line(DiffLine l, List<TextSpan>? spans) {
    final (bg, gutter) = switch (l.kind) {
      LineKind.add => (Gh.diffAdd, Gh.diffAdd),
      LineKind.delete => (Gh.diffDelete, Gh.diffDelete),
      LineKind.hunk => (Gh.box, Gh.diffHunkGutter),
      LineKind.context => (Gh.bg, Gh.box),
    };
    Widget no(int? n) => Container(
          width: 50,
          color: gutter,
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 6),
          child: Text(n?.toString() ?? '', style: Gh.mono.copyWith(color: Gh.textSecondary)),
        );
    final prefix = switch (l.kind) { LineKind.add => '+', LineKind.delete => '-', _ => ' ' };
    return Container(
      color: bg,
      child: Row(children: [
        no(l.oldNo),
        no(l.newNo),
        Expanded(
          child: Text.rich(
            TextSpan(
              style: Gh.mono.copyWith(color: l.kind == LineKind.hunk ? Gh.textSecondary : Gh.text),
              children: [TextSpan(text: prefix), ...(spans ?? [TextSpan(text: l.text)])],
            ),
            softWrap: false,
            overflow: TextOverflow.clip,
          ),
        ),
      ]),
    );
  }
}

class _Centered extends StatelessWidget {
  const _Centered(this.text);
  final String text;

  @override
  Widget build(BuildContext context) =>
      Center(child: Text(text, style: const TextStyle(color: Gh.textSecondary)));
}
