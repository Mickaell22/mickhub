import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'avatar.dart';
import 'git.dart';
import 'panes.dart';
import 'summaries.dart';
import 'theme.dart';

/// Tabla de resúmenes guardados en la API: buscar qué se hizo, en este repo o
/// en todos, por texto del resumen, mensaje, autor o hash.
class SummariesPane extends StatefulWidget {
  const SummariesPane({super.key, required this.repo, required this.api, required this.repoId, required this.layout});

  /// Ruta del repo abierto (para leer sus commits al resumir en lote).
  final String repo;
  final SummaryApi api;

  /// Identidad del repo abierto en la API ([repoId]).
  final String repoId;
  final Widget Function(Widget sidebar, Widget main) layout;

  @override
  State<SummariesPane> createState() => _SummariesPaneState();
}

class _SummariesPaneState extends State<SummariesPane> {
  final _query = TextEditingController();
  Timer? _debounce;
  bool _allRepos = false;
  List<SummaryRow> _rows = [];
  bool _loading = true, _hasMore = false;
  String? _error;
  SummaryRow? _selected;
  int _request = 0; // descarta respuestas de búsquedas viejas
  ({int done, int total, int failed})? _batch; // null = no se está resumiendo en lote
  bool _cancel = false;

  static const _page = 50;

  /// Cuántos commits resume el botón, y cuántos a la vez.
  static const _batchSize = 50, _parallel = 3;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Resume los últimos [_batchSize] commits de la rama. Los ya resumidos
  /// solo se consultan (no gastan tokens). Un fallo no corta el lote.
  Future<void> _summarizeLatest() async {
    final commits = (await log(widget.repo)).take(_batchSize).toList();
    if (!mounted || commits.isEmpty) return;
    _cancel = false;
    setState(() => _batch = (done: 0, total: commits.length, failed: 0));
    var next = 0;
    Future<void> worker() async {
      while (!_cancel && mounted && next < commits.length) {
        final c = commits[next++];
        var failed = false;
        try {
          await widget.api.summary(widget.repo, c);
        } catch (_) {
          failed = true;
        }
        final b = _batch;
        if (!mounted || b == null) return;
        setState(() => _batch = (done: b.done + 1, total: b.total, failed: b.failed + (failed ? 1 : 0)));
      }
    }

    await Future.wait([for (var i = 0; i < _parallel; i++) worker()]);
    if (!mounted) return;
    final b = _batch!;
    setState(() => _batch = null);
    _load();
    if (b.failed > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se pudieron resumir ${b.failed} de ${b.total} commits. Vuelve a intentarlo: los hechos no se repiten.')),
      );
    }
  }

  @override
  void dispose() {
    _cancel = true;
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  Future<void> _load({bool more = false}) async {
    final id = ++_request;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await widget.api.search(
        q: _query.text.trim(),
        repo: _allRepos ? '' : widget.repoId,
        offset: more ? _rows.length : 0,
        limit: _page,
      );
      if (!mounted || id != _request) return;
      setState(() {
        _rows = more ? [..._rows, ...rows] : rows;
        _hasMore = rows.length == _page;
        _loading = false;
        if (!more) _selected = _rows.firstOrNull;
      });
    } catch (e) {
      if (mounted && id == _request) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  void _onQuery(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _load);
  }

  @override
  Widget build(BuildContext context) {
    final small = Theme.of(context).textTheme.bodySmall;
    final list = switch ((_error, _rows.isEmpty, _loading)) {
      (final e?, _, _) => emptyState('No se pudo buscar', e, [TextButton(onPressed: _load, child: const Text('Reintentar'))]),
      (_, true, true) => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      (_, true, false) => emptyState(
        'Sin resúmenes',
        _query.text.trim().isEmpty
            ? 'Todavía no hay commits resumidos${_allRepos ? '' : ' en este repo'}. Se resumen al abrirlos en el Historial.'
            : 'Ningún resumen coincide con "${_query.text.trim()}".',
      ),
      _ => ListView.builder(
        itemCount: _rows.length + (_hasMore ? 1 : 0),
        itemExtent: Gh.commitRowHeight,
        itemBuilder: (_, i) {
          if (i == _rows.length) {
            // Fila final: al hacerse visible pide la página siguiente.
            if (!_loading) WidgetsBinding.instance.addPostFrameCallback((_) => _load(more: true));
            return const Center(child: SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)));
          }
          final r = _rows[i];
          return GhRow(
            height: Gh.commitRowHeight,
            selected: r.hash == _selected?.hash,
            onTap: () => setState(() => _selected = r),
            child: Row(
              children: [
                Avatar(email: r.email, name: r.author, size: 24),
                const SizedBox(width: Gh.sp),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        r.title,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        [r.author, if (_allRepos) r.repo.split('/').last, timeAgo(r.date)].join(' · '),
                        overflow: TextOverflow.ellipsis,
                        style: small,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    };

    final sidebar = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(Gh.sp),
          child: TextField(
            controller: _query,
            onChanged: _onQuery,
            style: const TextStyle(fontSize: Gh.fontSize),
            decoration: const InputDecoration(
              isDense: true,
              hintText: 'Buscar en resumen, mensaje, autor o hash',
              prefixIcon: Icon(Icons.search, size: 16),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Gh.sp, 0, Gh.sp, Gh.sp),
          child: SegmentedButton<bool>(
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: const [
              ButtonSegment(value: false, label: Text('Este repo')),
              ButtonSegment(value: true, label: Text('Todos')),
            ],
            selected: {_allRepos},
            onSelectionChanged: (v) {
              setState(() => _allRepos = v.first);
              _load();
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Gh.sp, 0, Gh.sp, Gh.sp),
          child: switch (_batch) {
            null => OutlinedButton.icon(
              onPressed: _summarizeLatest,
              icon: const Icon(Icons.auto_awesome_outlined, size: 16),
              label: const Text('Resumir los últimos $_batchSize'),
            ),
            final b => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LinearProgressIndicator(value: b.total == 0 ? null : b.done / b.total),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _cancel ? 'Cancelando…' : 'Resumiendo ${b.done} de ${b.total}${b.failed > 0 ? ' · ${b.failed} con error' : ''}',
                        style: small,
                      ),
                    ),
                    TextButton(onPressed: _cancel ? null : () => setState(() => _cancel = true), child: const Text('Cancelar')),
                  ],
                ),
              ],
            ),
          },
        ),
        const Divider(height: 1, color: Gh.border),
        Expanded(child: list),
      ],
    );

    final r = _selected;
    final main = r == null
        ? emptyState('Resúmenes con IA', 'Elige un resumen de la lista.')
        : ListView(
            padding: const EdgeInsets.all(Gh.sp * 2),
            children: [
              SelectableText(r.title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: Gh.sp),
              Row(
                children: [
                  Avatar(email: r.email, name: r.author, size: 18),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text('${r.author} · ${r.repo} · ${timeAgo(r.date)}', overflow: TextOverflow.ellipsis, style: small),
                  ),
                  const SizedBox(width: 6),
                  TextButton.icon(
                    onPressed: () => Clipboard.setData(ClipboardData(text: r.hash)),
                    icon: const Icon(Icons.content_copy, size: 14),
                    label: Text(r.shortHash),
                  ),
                ],
              ),
              const SizedBox(height: Gh.sp * 2),
              SelectableText(r.summary.split('\n').skip(1).join('\n').trim(), style: const TextStyle(height: 1.5)),
              const SizedBox(height: Gh.sp * 2),
              Text('Mensaje original', style: small?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.all(Gh.sp),
                decoration: BoxDecoration(
                  color: Gh.box,
                  border: Border.all(color: Gh.border),
                  borderRadius: BorderRadius.circular(Gh.radius),
                ),
                child: SelectableText(r.message, style: small),
              ),
            ],
          );
    return widget.layout(sidebar, main);
  }
}

/// Pregunta qué se hizo antes de que la IA escriba el mensaje del commit.
/// '' = sin pista (que lo deduzca del diff); null = cancelado.
Future<String?> askCommitHint(BuildContext context, {String initial = ''}) => showDialog<String>(
  context: context,
  builder: (_) => _HintDialog(initial: initial),
);

/// Dueño de su controlador (ver el gotcha de diálogos en CLAUDE.md).
class _HintDialog extends StatefulWidget {
  const _HintDialog({required this.initial});
  final String initial;

  @override
  State<_HintDialog> createState() => _HintDialogState();
}

class _HintDialogState extends State<_HintDialog> {
  late final _ctrl = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, _ctrl.text.trim());

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Row(
      children: [
        Icon(Icons.auto_awesome_outlined, size: 18),
        SizedBox(width: 8),
        Text('Escribir el mensaje con IA', style: TextStyle(fontSize: 14)),
      ],
    ),
    content: SizedBox(
      width: 460,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Lee solo los cambios marcados. Si quieres, cuenta en pocas palabras qué hiciste y lo usa como guía.',
            style: TextStyle(color: Gh.textSecondary),
          ),
          const SizedBox(height: Gh.sp),
          TextField(
            controller: _ctrl,
            autofocus: true,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(hintText: '¿Qué hiciste? (opcional)'),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
      FilledButton(onPressed: _submit, child: const Text('Escribir')),
    ],
  );
}
