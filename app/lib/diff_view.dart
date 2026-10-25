import 'dart:isolate';

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

/// Resalta en otro isolate. Tiene que ser una función de nivel superior: una
/// closure creada dentro del State arrastra `this` (widgets, completers) y Dart
/// no puede mandarla a otro isolate.
Future<List<List<TextSpan>>?> highlightInIsolate(List<String> lines, String language) => Isolate.run(() => highlightLines(lines, language));

/// Diff unificado al estilo de GitHub Desktop: dos columnas de números de 50 px,
/// fondo verde/rojo por línea y resaltado de sintaxis según la extensión de [path].
class DiffView extends StatefulWidget {
  const DiffView(this.diff, {super.key, required this.path, this.selectedHunks, this.onToggleHunk});
  final String diff;
  final String path;

  /// Si se dan, cada bloque (`@@`) lleva una casilla para elegirlo (apartar bloques).
  final Set<int>? selectedHunks;
  final ValueChanged<int>? onToggleHunk;

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
    if (old.diff != widget.diff || old.path != widget.path) {
      _forceLarge = false;
      _parse();
    }
  }

  // ponytail: se resaltan juntas las líneas de contexto, borradas y agregadas;
  // si una línea borrada abre un comentario o string que la agregada no abre, el
  // color se corre hasta el final del bloque. Upgrade: resaltar por separado el
  // lado viejo (contexto + borradas) y el nuevo (contexto + agregadas).
  int _gen = 0; // descarta resaltados viejos si el diff cambió mientras tanto
  bool _forceLarge = false;
  List<int> _hunkOf = const []; // índice de bloque de cada línea

  /// Diffs de más de esto se ocultan hasta que el usuario los pida, como Desktop.
  static const _largeDiffBytes = 1024 * 1024;

  bool get _tooLarge => !_forceLarge && widget.diff.length > _largeDiffBytes;

  void _parse() {
    final gen = ++_gen;
    _spans.clear();
    if (_tooLarge) {
      _lines = const [];
      return;
    }
    final lines = _lines = parseDiff(widget.diff);
    if (lines == null) return;
    var h = -1;
    _hunkOf = [for (final l in lines) l.kind == LineKind.hunk ? ++h : h];
    final code = [
      for (var i = 0; i < lines.length; i++)
        if (lines[i].kind != LineKind.hunk) i,
    ];
    final texts = [for (final i in code) lines[i].text];
    final language = languageFor(widget.path);
    if (language == null) return;
    // El resaltado corre en otro isolate para no trabar la interfaz con diffs
    // grandes; mientras tanto se ve el texto sin color.
    highlightInIsolate(texts, language).then((hl) {
      if (!mounted || gen != _gen || hl == null) return;
      setState(() {
        for (var k = 0; k < code.length; k++) {
          _spans[code[k]] = hl[k];
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_tooLarge) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Este diff es muy grande', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: Gh.sp),
            Text(
              'Pesa ${(widget.diff.length / 1024 / 1024).toStringAsFixed(1)} MB; mostrarlo puede ir lento.',
              style: const TextStyle(color: Gh.textSecondary),
            ),
            const SizedBox(height: Gh.sp),
            OutlinedButton(
              onPressed: () => setState(() {
                _forceLarge = true;
                _parse();
              }),
              child: const Text('Mostrar de todos modos'),
            ),
          ],
        ),
      );
    }
    final lines = _lines;
    if (lines == null) return const _Centered('Este archivo es binario y no se puede mostrar.');
    if (lines.isEmpty) return const _Centered('Sin cambios de contenido (solo permisos o renombre).');
    return SelectionArea(
      child: ListView.builder(
        itemCount: lines.length,
        itemExtent: 18,
        itemBuilder: (_, i) => _line(lines[i], _spans[i], hunk: _hunkOf[i]),
      ),
    );
  }

  Widget _line(DiffLine l, List<TextSpan>? spans, {int? hunk}) {
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
    final prefix = switch (l.kind) {
      LineKind.add => '+',
      LineKind.delete => '-',
      _ => ' ',
    };
    return Container(
      color: bg,
      child: Row(
        children: [
          if (l.kind == LineKind.hunk && widget.onToggleHunk != null && hunk != null)
            Container(
              width: 100,
              color: gutter,
              alignment: Alignment.centerLeft,
              child: Transform.scale(
                scale: 0.7,
                child: Checkbox(value: widget.selectedHunks?.contains(hunk) ?? false, onChanged: (_) => widget.onToggleHunk!(hunk)),
              ),
            )
          else ...[
            no(l.oldNo),
            no(l.newNo),
          ],
          Expanded(
            child: Text.rich(
              TextSpan(
                style: Gh.mono.copyWith(color: l.kind == LineKind.hunk ? Gh.textSecondary : Gh.text),
                children: [
                  TextSpan(text: prefix),
                  ...(spans ?? [TextSpan(text: l.text)]),
                ],
              ),
              softWrap: false,
              overflow: TextOverflow.clip,
            ),
          ),
        ],
      ),
    );
  }
}

class _Centered extends StatelessWidget {
  const _Centered(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Center(
    child: Text(text, style: const TextStyle(color: Gh.textSecondary)),
  );
}
