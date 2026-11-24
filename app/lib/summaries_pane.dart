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
  const SummariesPane({
    super.key,
    required this.repo,
    required this.api,
    required this.repoId,
    required this.layout,
    this.repos = const [],
    this.authorsOf,
    this.repoIdOf,
    this.onOpenCommit,
  });

  /// Abre el commit ([SummaryRow.repo], hash) en el Historial de su repo.
  final void Function(String repoId, String hash)? onOpenCommit;

  /// Ruta del repo abierto (para leer sus commits al resumir en lote).
  final String repo;
  final SummaryApi api;

  /// Identidad del repo abierto en la API ([repoId]).
  final String repoId;
  final Widget Function(Widget sidebar, Widget main) layout;

  /// Repos del perfil, para el reporte de "todos mis repos".
  final List<String> repos;

  /// Nombres y emails con que firma el dueño en un repo (los de su cuenta),
  /// para el reporte de "mis commits".
  final List<String> Function(String repo)? authorsOf;

  /// [repoId] de otro repo del perfil.
  final String Function(String repo)? repoIdOf;

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
  ({String title, String text, int commits, int cut})? _report;
  String? _reportStatus; // null = no se está armando un reporte

  /// Junta los commits del período, resume los que falten (lo ya resumido solo
  /// se consulta) y le pide a la API el reporte. Un commit que no se pudo
  /// resumir entra con su mensaje original.
  Future<void> _runReport() async {
    final cfg = await showDialog<ReportConfig>(context: context, builder: (_) => _ReportDialog(repo: widget.repo));
    if (cfg == null || !mounted) return;
    final (since, until) = cfg.period.range(DateTime.now());
    final base = cfg.base;
    final repos = base == null && cfg.allRepos && widget.repos.isNotEmpty ? widget.repos : [widget.repo];
    final branch = base == null ? '' : await currentBranchName(widget.repo);
    // Lo que va a la IA como período y lo que se muestra.
    final period = base == null ? cfg.period.label.toLowerCase() : 'lo que trae la rama $branch respecto de $base';
    setState(() => _reportStatus = 'Buscando commits…');
    try {
      final found = <({String repo, Commit commit})>[];
      for (final r in repos) {
        final authors = cfg.team ? const <String>[] : (widget.authorsOf?.call(r) ?? const <String>[]);
        if (!cfg.team && authors.isEmpty) continue; // repo sin cuenta: no se sabe cuáles son "míos"
        final commits = base == null ? await periodCommits(r, since, until, authors: authors) : await branchCommits(r, base, authors: authors);
        found.addAll([for (final c in commits) (repo: r, commit: c)]);
      }
      if (!mounted) return;
      if (found.isEmpty) {
        setState(() => _reportStatus = null);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(
          SnackBar(
            content: Text(
              base == null
                  ? 'No hay commits ${cfg.period.label.toLowerCase()}${cfg.team ? '' : ' tuyos'}.'
                  : 'La rama $branch no trae commits${cfg.team ? '' : ' tuyos'} que $base no tenga.',
            ),
          ),
        );
        return;
      }
      final items = <({String repo, Commit commit, String summary})>[];
      var next = 0;
      Future<void> worker() async {
        while (mounted && next < found.length) {
          final f = found[next++];
          String text;
          try {
            text = (await widget.api.summary(f.repo, f.commit)).text;
          } on SummaryException {
            text = f.commit.summary; // sin IA para este: va su mensaje
          }
          items.add((repo: widget.repoIdOf?.call(f.repo) ?? widget.repoId, commit: f.commit, summary: text));
          if (mounted) setState(() => _reportStatus = 'Resumiendo commits: ${items.length} de ${found.length}');
        }
      }

      await Future.wait([for (var i = 0; i < _parallel; i++) worker()]);
      if (!mounted) return;
      setState(() => _reportStatus = 'Escribiendo el reporte…');
      final r = await widget.api.report(period, cfg.team, items);
      if (!mounted) return;
      setState(() {
        _report = (
          title:
              base != null
              ? 'Lo que trae $branch · respecto de $base'
              : '${cfg.team ? 'Avance del equipo' : 'Mi avance'} · ${cfg.period.label}${repos.length > 1 ? ' · ${repos.length} repos' : ''}',
          text: r.text,
          commits: found.length,
          cut: r.cut,
        );
        _reportStatus = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _reportStatus = null);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('No se pudo armar el reporte: $e')));
    }
  }

  static const _page = 50;

  /// Cuántos commits resume el botón, y cuántos a la vez.
  static const _batchSize = 50, _parallel = 3;

  @override
  void initState() {
    super.initState();
    escapeTick.addListener(_deselect);
    _load();
  }

  void _deselect() {
    if (_selected != null || _report != null) {
      setState(() {
        _selected = null;
        _report = null;
      });
    }
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
    escapeTick.removeListener(_deselect);
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
        if (!more && !_rows.any((r) => r.hash == _selected?.hash)) _selected = null; // sin abrir el primero solo
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
            onTap: () => setState(() {
              _selected = r;
              _report = null;
            }),
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
        Padding(
          padding: const EdgeInsets.fromLTRB(Gh.sp, 0, Gh.sp, Gh.sp),
          child: _reportStatus == null
              ? OutlinedButton.icon(
                  onPressed: _batch == null ? _runReport : null,
                  icon: const Icon(Icons.summarize_outlined, size: 16),
                  label: const Text('Reporte del período…'),
                )
              : Row(
                  children: [
                    const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                    const SizedBox(width: Gh.sp),
                    Expanded(child: Text(_reportStatus!, style: small)),
                  ],
                ),
        ),
        Divider(height: 1, color: Gh.border),
        Expanded(child: list),
      ],
    );

    final r = _selected;
    final rep = _report;
    final main = rep != null
        ? _reportView(rep, small)
        : r == null
        ? emptyState('Resúmenes con IA', 'Elige un resumen de la lista.', const [], true)
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
                  if (widget.onOpenCommit != null)
                    TextButton.icon(
                      onPressed: () => widget.onOpenCommit!(r.repo, r.hash),
                      icon: const Icon(Icons.history, size: 14),
                      label: const Text('Ver en el Historial'),
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

  /// El reporte: "## " son encabezados (una persona en el del equipo), el resto
  /// texto. Se puede copiar tal cual para pegarlo en un chat del trabajo.
  Widget _reportView(({String title, String text, int commits, int cut}) rep, TextStyle? small) => ListView(
    padding: const EdgeInsets.all(Gh.sp * 2),
    children: [
      Row(
        children: [
          Expanded(
            child: Text(rep.title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          ),
          TextButton.icon(
            onPressed: () => Clipboard.setData(ClipboardData(text: rep.text)),
            icon: const Icon(Icons.content_copy, size: 14),
            label: const Text('Copiar'),
          ),
          IconButton(
            tooltip: 'Cerrar el reporte',
            iconSize: 16,
            onPressed: () => setState(() => _report = null),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
      Text('${rep.commits} commits sin merges${rep.cut > 0 ? ' · ${rep.cut} no entraron por tamaño' : ''}', style: small),
      const SizedBox(height: Gh.sp * 2),
      for (final line in rep.text.split('\n'))
        line.startsWith('## ')
            ? Padding(
                padding: const EdgeInsets.only(top: Gh.sp * 1.5, bottom: 4),
                child: SelectableText(line.substring(3), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              )
            : SelectableText(line, style: const TextStyle(height: 1.5)),
    ],
  );
}

/// Períodos del reporte. Las semanas empiezan el lunes.
enum ReportPeriod {
  today('Hoy'),
  yesterday('Ayer'),
  thisWeek('Esta semana'),
  lastWeek('La semana pasada'),
  last30('Los últimos 30 días');

  const ReportPeriod(this.label);
  final String label;

  /// Desde (incluido) y hasta (excluido), en hora local.
  (DateTime, DateTime) range(DateTime now) {
    final day = DateTime(now.year, now.month, now.day);
    // DateTime(...) y no subtract(Duration): con cambio de horario un día no dura 24 h.
    DateTime back(int days) => DateTime(day.year, day.month, day.day - days);
    final monday = back(day.weekday - DateTime.monday);
    return switch (this) {
      ReportPeriod.today => (day, now),
      ReportPeriod.yesterday => (back(1), day),
      ReportPeriod.thisWeek => (monday, now),
      ReportPeriod.lastWeek => (DateTime(monday.year, monday.month, monday.day - 7), monday),
      ReportPeriod.last30 => (back(30), now),
    };
  }
}

/// [base] != null: "lo que trae la rama" actual respecto de esa rama (solo este
/// repo, sin período).
typedef ReportConfig = ({ReportPeriod period, bool team, bool allRepos, String? base});

class _ReportDialog extends StatefulWidget {
  const _ReportDialog({required this.repo});
  final String repo;

  @override
  State<_ReportDialog> createState() => _ReportDialogState();
}

class _ReportDialogState extends State<_ReportDialog> {
  var _period = ReportPeriod.thisWeek;
  var _team = false, _allRepos = true, _branch = false;
  List<String> _bases = [];
  String? _base;

  @override
  void initState() {
    super.initState();
    baseBranches(widget.repo).then((b) {
      if (mounted) {
        setState(() {
          _bases = b.$1;
          _base = b.$2 ?? b.$1.firstOrNull;
        });
      }
    }, onError: (_) {}); // sin commits: no hay ramas que comparar
  }

  Widget _choice<T>(String label, T value, List<(T, String)> options, ValueChanged<T> onChanged) => Padding(
    padding: const EdgeInsets.only(bottom: Gh.sp * 1.5),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: Gh.textSecondary)),
        const SizedBox(height: 4),
        SegmentedButton<T>(
          showSelectedIcon: false,
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
          segments: [for (final (v, l) in options) ButtonSegment(value: v, label: Text(l))],
          selected: {value},
          onSelectionChanged: (v) => setState(() => onChanged(v.first)),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Row(
      children: [
        Icon(Icons.summarize_outlined, size: 18),
        SizedBox(width: 8),
        Text('Reporte del período', style: TextStyle(fontSize: 14)),
      ],
    ),
    content: SizedBox(
      width: 520,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _choice('Qué', _branch, const [(false, 'Un período'), (true, 'Lo que trae esta rama')], (v) => _branch = v),
          if (!_branch)
            _choice('Período', _period, [for (final p in ReportPeriod.values) (p, p.label)], (v) => _period = v)
          else
            Padding(
              padding: const EdgeInsets.only(bottom: Gh.sp * 1.5),
              child: Row(
                children: [
                  Text('Respecto de', style: TextStyle(color: Gh.textSecondary)),
                  const SizedBox(width: Gh.sp),
                  DropdownButton<String>(
                    value: _base,
                    isDense: true,
                    hint: const Text('Sin otras ramas'),
                    items: [for (final b in _bases) DropdownMenuItem(value: b, child: Text(b))],
                    onChanged: (v) => setState(() => _base = v),
                  ),
                ],
              ),
            ),
          _choice('De quién', _team, const [(false, 'Mis commits'), (true, 'Del equipo')], (v) => _team = v),
          if (!_branch)
            _choice('Dónde', _allRepos, const [(false, 'Este repo'), (true, 'Todos los repos del perfil')], (v) => _allRepos = v),
          Text(
            'Usa los resúmenes por commit (los que falten se hacen ahora, una sola vez) y no cuenta los merges. '
            '${_branch ? 'Solo los commits de la rama que la base todavía no tiene: lo que entró al ponerla al día no cuenta.' : 'Tus commits salen de todas las ramas, también de desarrollo.'}',
            style: TextStyle(fontSize: Gh.fontSizeSm, color: Gh.textSecondary),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
      FilledButton(
        onPressed: _branch && _base == null
            ? null
            : () => Navigator.pop(context, (period: _period, team: _team, allRepos: _allRepos, base: _branch ? _base : null)),
        child: const Text('Armar'),
      ),
    ],
  );
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
          Text(
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
