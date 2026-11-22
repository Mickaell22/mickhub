import 'dart:math';

import 'package:flutter/material.dart';

import 'decor.dart';
import 'look.dart';
import 'settings.dart';
import 'theme.dart';

// Al abrir: la paleta de "al abrir" y la mascota "al azar" se sortean una vez
// por sesión (estables mientras la app siga abierta).
final _launchLook = Look.pool[Random().nextInt(Look.pool.length)];
final _launchPet = pets.keys.elementAt(Random().nextInt(pets.length));

/// Lo que toca según los ajustes y la fecha.
({Look look, Scene? scene, String pet}) currentLook(Settings s, [DateTime? now]) {
  final look = resolveLook(
    now: now ?? DateTime.now(),
    chosen: Look.byName(s.look),
    rotation: s.rotation,
    seasonal: s.seasonal,
    birthday: s.birthday,
    skippedSeason: s.skippedSeason,
    launch: _launchLook,
  );
  final scene = switch (s.scene) {
    'auto' => look.scene,
    'ninguna' => null,
    // Una por día del año, salvo cuando una fiesta llega sola por la fecha: ahí
    // gana su escena. Si la paleta de fiesta la eligió él, va la del día.
    'diaria' => look.kind == LookKind.seasonal && look.name != s.look ? look.scene : Scene.diaria,
    final n => Scene.values.where((x) => x.name == n).firstOrNull ?? look.scene,
  };
  final pet = s.pet == 'azar' ? _launchPet : s.pet;
  return (look: look, scene: scene, pet: pet);
}

/// Aplica la paleta a [Gh] y avisa a la decoración. Devuelve si cambió algo
/// (quien llama reconstruye el árbol).
bool applyLook(Settings s) {
  final cur = currentLook(s);
  final before = (lookState.look, lookState.scene, lookState.pet, lookState.decor);
  Gh.apply(cur.look.colors);
  lookState.set(look: cur.look, scene: cur.scene, pet: cur.pet, decor: s.decor);
  return before != (lookState.look, lookState.scene, lookState.pet, lookState.decor);
}

Future<void> showPersonalize(BuildContext context, Settings s) => showDialog<void>(
  context: context,
  builder: (_) => _PersonalizeDialog(settings: s),
);

class _PersonalizeDialog extends StatefulWidget {
  const _PersonalizeDialog({required this.settings});
  final Settings settings;

  @override
  State<_PersonalizeDialog> createState() => _PersonalizeDialogState();
}

class _PersonalizeDialogState extends State<_PersonalizeDialog> {
  Settings get s => widget.settings;

  Future<void> _change(void Function(Settings) f) async {
    await s.update(f);
    if (mounted) setState(() {});
  }

  /// Elegir una paleta a mano durante una temporada la salta este año.
  Future<void> _pick(Look l) => _change((x) {
    x.look = l.name;
    final now = DateTime.now();
    final season = seasonFor(now);
    final mmdd = '${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    if (x.birthday == mmdd && l != Look.cumple) {
      x.skippedSeason = 'cumple-${now.year}';
    } else if (season != null && l != season) {
      x.skippedSeason = seasonKey(season, now);
    }
    if (x.rotation != 'fija') x.rotation = 'fija';
  });

  Widget _section(String title, [String? hint]) => Padding(
    padding: const EdgeInsets.only(top: Gh.sp * 1.6, bottom: Gh.sp * .6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        if (hint != null) ...[
          const SizedBox(width: Gh.sp),
          Flexible(
            child: Text(
              hint,
              style: TextStyle(fontSize: Gh.fontSizeSm, color: Gh.textSecondary),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ],
    ),
  );

  Widget _swatch(Look l, Look active) {
    final c = l.colors;
    final on = l == active;
    return Tooltip(
      message: l.hint,
      waitDuration: const Duration(milliseconds: 400),
      child: InkWell(
        borderRadius: BorderRadius.circular(Gh.radius),
        onTap: () => _pick(l),
        child: Container(
          width: 124,
          height: 70,
          decoration: BoxDecoration(
            color: c.bg,
            borderRadius: BorderRadius.circular(Gh.radius),
            border: Border.all(color: on ? c.accent : c.border, width: on ? 2 : 1),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            children: [
              // Miniatura quieta de su escena (sin reloj: no se anima).
              Positioned.fill(
                top: 26,
                child: Opacity(
                  opacity: .9,
                  child: CustomPaint(painter: _ThumbPainter(l)),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                height: 22,
                child: Container(
                  color: c.box,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Row(
                    children: [
                      Container(width: 8, height: 8, decoration: BoxDecoration(color: c.accent, shape: BoxShape.circle)),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(
                          l.label,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 10.5, color: c.text, fontWeight: on ? FontWeight.w700 : FontWeight.w500),
                        ),
                      ),
                      if (on) Icon(Icons.check, size: 12, color: c.accent),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _petTile(String key, String label) {
    final on = s.pet == key;
    final pet = pets[key];
    return InkWell(
      borderRadius: BorderRadius.circular(Gh.radius),
      onTap: () => _change((x) => x.pet = key),
      child: Container(
        width: 84,
        height: 74,
        decoration: BoxDecoration(
          color: Gh.box,
          borderRadius: BorderRadius.circular(Gh.radius),
          border: Border.all(color: on ? Gh.blue : Gh.border, width: on ? 2 : 1),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 48,
              height: 40,
              child: pet == null
                  ? Icon(key == 'azar' ? Icons.casino_outlined : Icons.block, color: Gh.textSecondary)
                  : CustomPaint(painter: _PetThumb(pet, decorClock, still: MediaQuery.maybeDisableAnimationsOf(context) ?? false)),
            ),
            const SizedBox(height: 4),
            Text(label, style: const TextStyle(fontSize: Gh.fontSizeSm)),
          ],
        ),
      ),
    );
  }

  /// Día del año que se está mirando en el explorador de escenas diarias.
  late int _day = dayOfYear(DateTime.now());

  /// Recorre las 365 escenas del año: la de hoy y las que vienen.
  Widget _dayBrowser() {
    final today = dayOfYear(DateTime.now());
    final d = dailyScene(_day);
    final date = DateTime(DateTime.now().year, 1, _day);
    return Padding(
      padding: const EdgeInsets.only(top: Gh.sp),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              IconButton(
                tooltip: 'Día anterior',
                onPressed: () => setState(() => _day = _day == 1 ? 365 : _day - 1),
                icon: const Icon(Icons.chevron_left, size: 18),
              ),
              Expanded(
                child: Column(
                  children: [
                    Text(d.name, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w600)),
                    Text(
                      '${date.day} de ${_months[date.month - 1]} · día $_day${_day == today ? ' (hoy)' : ''}',
                      style: TextStyle(fontSize: Gh.fontSizeSm, color: Gh.textSecondary),
                    ),
                  ],
                ),
              ),
              if (_day != today) TextButton(onPressed: () => setState(() => _day = today), child: const Text('Hoy')),
              IconButton(
                tooltip: 'Día siguiente',
                onPressed: () => setState(() => _day = _day % 365 + 1),
                icon: const Icon(Icons.chevron_right, size: 18),
              ),
            ],
          ),
          ClipRRect(
            borderRadius: BorderRadius.circular(Gh.radius),
            child: Container(
              height: 150,
              decoration: BoxDecoration(color: Gh.bg, border: Border.all(color: Gh.border)),
              child: CustomPaint(
                painter: ScenePainter(Scene.diaria, decorClock, day: _day, still: MediaQuery.maybeDisableAnimationsOf(context) ?? false),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _seasonLine(DateTime now) {
    final season = seasonFor(now);
    if (season == null) return 'Hoy no hay ninguna fecha especial.';
    final skipped = s.skippedSeason == seasonKey(season, now);
    return skipped ? 'Hoy es ${season.label}, pero elegiste otra paleta.' : 'Hoy es ${season.label}: se aplica sola.';
  }

  Future<void> _pickBirthday() async {
    final now = DateTime.now();
    final parts = s.birthday.split('-');
    final initial = parts.length == 2 ? DateTime(now.year, int.tryParse(parts[0]) ?? 1, int.tryParse(parts[1]) ?? 1) : now;
    final d = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(now.year, 1, 1),
      lastDate: DateTime(now.year, 12, 31),
      helpText: 'Tu cumpleaños (solo día y mes)',
    );
    if (d != null) await _change((x) => x.birthday = '${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}');
  }

  static const _months = ['enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio', 'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre'];

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final active = lookState.look;
    final small = TextStyle(fontSize: Gh.fontSizeSm, color: Gh.textSecondary);
    final bday = s.birthday.split('-');
    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(20, 16, 12, 0),
      contentPadding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      title: Row(
        children: [
          const Icon(Icons.palette_outlined, size: 18),
          const SizedBox(width: 8),
          const Text('Personalización', style: TextStyle(fontSize: 14)),
          const Spacer(),
          IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close, size: 18), tooltip: 'Cerrar'),
        ],
      ),
      content: SizedBox(
        width: 700,
        height: 560,
        child: ListView(
          children: [
            // Vista previa en vivo: la barra con la mascota y un pedazo de fondo.
            ClipRRect(
              borderRadius: BorderRadius.circular(Gh.radius),
              child: Container(
                height: 170,
                decoration: BoxDecoration(color: Gh.bg, border: Border.all(color: Gh.border)),
                child: Column(
                  children: [
                    Container(height: Gh.toolbarHeight, color: Gh.box, child: const ToolbarDecor()),
                    Expanded(
                      child: Stack(
                        children: [
                          const Positioned.fill(child: SceneBackdrop()),
                          Center(
                            child: Text(
                              lookState.decor ? '${active.label} · ${lookState.scene?.label ?? 'sin fondo'}' : '${active.label} · sin decoración',
                              style: const TextStyle(fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            _section('Paleta', 'La de GitHub Desktop es la de fábrica; las demás cambian fondo, paneles y acento.'),
            Wrap(spacing: 8, runSpacing: 8, children: [for (final l in Look.values.where((l) => l.kind == LookKind.classic)) _swatch(l, active)]),
            _section('Temáticas', 'Con su propia escena.'),
            Wrap(spacing: 8, runSpacing: 8, children: [for (final l in Look.values.where((l) => l.kind == LookKind.themed)) _swatch(l, active)]),
            _section('De temporada', 'Llegan solas en su fecha; también se pueden elegir para siempre.'),
            Wrap(spacing: 8, runSpacing: 8, children: [for (final l in Look.values.where((l) => l.kind == LookKind.seasonal)) _swatch(l, active)]),
            _section('Cambiar sola'),
            Row(
              children: [
                SegmentedButton<String>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(visualDensity: VisualDensity.compact),
                  segments: const [
                    ButtonSegment(value: 'fija', label: Text('Fija')),
                    ButtonSegment(value: 'dia', label: Text('Una distinta cada día')),
                    ButtonSegment(value: 'abrir', label: Text('Al azar al abrir')),
                  ],
                  selected: {s.rotation},
                  onSelectionChanged: (v) => _change((x) => x.rotation = v.first),
                ),
              ],
            ),
            _section('Fechas especiales'),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              value: s.seasonal,
              onChanged: (v) => _change((x) => x.seasonal = v),
              title: const Text('Halloween, Día de Muertos, Navidad, Año Nuevo, Carnaval, Inti Raymi…'),
              subtitle: Text(_seasonLine(now), style: small),
            ),
            if (seasonFor(now) case final season? when s.skippedSeason == seasonKey(season, now))
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(onPressed: () => _change((x) => x.skippedSeason = ''), child: Text('Volver a ${season.label}')),
              ),
            Row(
              children: [
                Icon(Icons.cake_outlined, size: 16, color: Gh.textSecondary),
                const SizedBox(width: 8),
                Text(
                  bday.length == 2 ? 'Cumpleaños: ${int.parse(bday[1])} de ${_months[int.parse(bday[0]) - 1]}' : 'Cumpleaños: sin poner',
                ),
                const SizedBox(width: 8),
                TextButton(onPressed: _pickBirthday, child: Text(bday.length == 2 ? 'Cambiar' : 'Poner')),
                if (bday.length == 2) TextButton(onPressed: () => _change((x) => x.birthday = ''), child: const Text('Quitar')),
              ],
            ),
            _section('Decoración', 'Solo en espacios vacíos y en el hueco de la barra; se pausa con la ventana oculta.'),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              value: s.decor,
              onChanged: (v) => _change((x) => x.decor = v),
              title: const Text('Escenas y mascota'),
            ),
            if (s.decor)
              Row(
                children: [
                  const Text('Fondo'),
                  const SizedBox(width: Gh.sp),
                  DropdownButton<String>(
                    value: s.scene,
                    isDense: true,
                    items: [
                      DropdownMenuItem(value: 'auto', child: Text('El de la paleta (${active.scene.label})')),
                      const DropdownMenuItem(value: 'ninguna', child: Text('Ninguno')),
                      for (final sc in Scene.values) DropdownMenuItem(value: sc.name, child: Text(sc == Scene.diaria ? '${sc.label} (365)' : sc.label)),
                    ],
                    onChanged: (v) => _change((x) => x.scene = v ?? 'auto'),
                  ),
                ],
              ),
            if (s.decor && s.scene == 'diaria') _dayBrowser(),
            if (s.decor) ...[
              _section('Mascota', 'Camina por la barra de arriba. Hazle clic.'),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _petTile('ninguna', 'Ninguna'),
                  _petTile('azar', 'Al azar'),
                  for (final e in pets.entries) _petTile(e.key, e.value.label),
                ],
              ),
            ],
            const SizedBox(height: Gh.sp * 2),
          ],
        ),
      ),
    );
  }
}

/// Miniatura quieta de la escena de una paleta, con sus colores.
class _ThumbPainter extends CustomPainter {
  _ThumbPainter(this.look);
  final Look look;

  @override
  void paint(Canvas canvas, Size size) {
    // La escena pinta con los colores de Gh: se cambian un momento y se devuelven.
    final saved = Gh.current();
    Gh.apply(look.colors);
    canvas.save();
    // Se dibuja a 2x de tamaño y se achica, para que entre la escena completa.
    canvas.scale(.5);
    ScenePainter(look.scene, decorClock, still: true).paint(canvas, size * 2);
    canvas.restore();
    Gh.apply(saved);
  }

  @override
  bool shouldRepaint(_ThumbPainter old) => old.look != look;
}

/// Mascota caminando en el lugar (para elegirla).
class _PetThumb extends CustomPainter {
  _PetThumb(this.pet, this.clock, {this.still = false}) : super(repaint: still ? null : clock);
  final Pet pet;
  final DecorClock clock;
  final bool still;

  @override
  void paint(Canvas canvas, Size size) {
    final frame = still ? 'sit' : 'walk${(clock.t * 4).floor() % 2}';
    const k = 2.5;
    drawSprite(canvas, pet.frames[frame]!, pet.colors, Offset((size.width - 16 * k) / 2, size.height - pet.rows * k), k);
  }

  @override
  bool shouldRepaint(_PetThumb old) => old.pet != pet || old.still != still;
}
