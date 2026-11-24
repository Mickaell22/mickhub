part of 'decor.dart';

// Escena del día (pedido del dueño: "uno por día, 365"). No son 365 dibujos a
// mano: se arman con piezas (terreno, lugar, hora, clima, bichos) y cada día del
// año toma una combinación distinta de una lista barajada fija, así nunca se
// repiten dentro del año y el mismo día siempre trae la misma. La luna sale con
// la fase real de esa fecha.

enum Terrain { montanas, colinas, dunas, mar, lago, ciudad, bosque, islas, canon, nevado, volcan, pradera }

enum Landmark { cabana, observatorio, antena, globos, molino, cometas, castillo, piramides, caravana, oasis, faro, velero, ballena, puente, carpa, noria, tren }

enum DayTime { noche, amanecer, atardecer, crepusculo, luna }

enum Weather { claro, nieve, lluvia, hojas, petalos, fugaces, niebla, luciernagas }

const _landmarksFor = {
  Terrain.montanas: [Landmark.cabana, Landmark.observatorio, Landmark.antena, Landmark.globos],
  Terrain.colinas: [Landmark.molino, Landmark.cabana, Landmark.cometas, Landmark.castillo],
  Terrain.dunas: [Landmark.piramides, Landmark.caravana, Landmark.oasis, Landmark.globos],
  Terrain.mar: [Landmark.faro, Landmark.velero, Landmark.ballena, Landmark.puente],
  Terrain.lago: [Landmark.cabana, Landmark.velero, Landmark.puente, Landmark.carpa],
  Terrain.ciudad: [Landmark.noria, Landmark.antena, Landmark.tren, Landmark.globos],
  Terrain.bosque: [Landmark.carpa, Landmark.cabana, Landmark.tren, Landmark.observatorio],
  // Sin oasis: sus palmeras salían del agua, no de una isla.
  Terrain.islas: [Landmark.faro, Landmark.velero, Landmark.puente, Landmark.ballena],
  Terrain.canon: [Landmark.tren, Landmark.puente, Landmark.globos, Landmark.caravana],
  Terrain.nevado: [Landmark.cabana, Landmark.observatorio, Landmark.tren, Landmark.carpa],
  Terrain.volcan: [Landmark.globos, Landmark.observatorio, Landmark.carpa, Landmark.antena],
  Terrain.pradera: [Landmark.molino, Landmark.cometas, Landmark.tren, Landmark.carpa],
};

const _terrainIn = {
  Terrain.montanas: 'en las montañas',
  Terrain.colinas: 'en las colinas',
  Terrain.dunas: 'en las dunas',
  Terrain.mar: 'en la costa',
  Terrain.lago: 'en el lago',
  Terrain.ciudad: 'en la ciudad',
  Terrain.bosque: 'en el bosque',
  Terrain.islas: 'entre islas',
  Terrain.canon: 'en el cañón',
  Terrain.nevado: 'en la nieve',
  Terrain.volcan: 'junto al volcán',
  Terrain.pradera: 'en la pradera',
};

const _landmarkName = {
  Landmark.cabana: 'Cabaña',
  Landmark.observatorio: 'Observatorio',
  Landmark.antena: 'Antena',
  Landmark.globos: 'Globos',
  Landmark.molino: 'Molino',
  Landmark.cometas: 'Cometas',
  Landmark.castillo: 'Castillo',
  Landmark.piramides: 'Pirámides',
  Landmark.caravana: 'Caravana',
  Landmark.oasis: 'Oasis',
  Landmark.faro: 'Faro',
  Landmark.velero: 'Velero',
  Landmark.ballena: 'Ballena',
  Landmark.puente: 'Puente',
  Landmark.carpa: 'Campamento',
  Landmark.noria: 'Noria',
  Landmark.tren: 'Tren',
};

const _timeName = {
  DayTime.noche: 'de noche',
  DayTime.amanecer: 'al amanecer',
  DayTime.atardecer: 'al atardecer',
  DayTime.crepusculo: 'al anochecer',
  DayTime.luna: 'bajo la luna',
};

const _weatherName = {
  Weather.claro: '',
  Weather.nieve: ', con nieve',
  Weather.lluvia: ', con lluvia',
  Weather.hojas: ', con hojas al viento',
  Weather.petalos: ', con pétalos',
  Weather.fugaces: ', con estrellas fugaces',
  Weather.niebla: ', con niebla',
  Weather.luciernagas: ', con luciérnagas',
};

/// La escena de un día del año.
class DailyScene {
  const DailyScene(this.day, this.terrain, this.landmark, this.time, this.weather);
  final int day; // 1..366
  final Terrain terrain;
  final Landmark landmark;
  final DayTime time;
  final Weather weather;

  String get name => '${_landmarkName[landmark]} ${_terrainIn[terrain]} ${_timeName[time]}${_weatherName[weather]}';

  bool get dark => time == DayTime.noche || time == DayTime.luna || time == DayTime.crepusculo;
}

/// Terrenos con suelo firme a la izquierda (donde puede ir un árbol).
const _land = {Terrain.montanas, Terrain.colinas, Terrain.dunas, Terrain.bosque, Terrain.canon, Terrain.nevado, Terrain.volcan, Terrain.pradera};

bool _fits(Terrain t, Landmark l, DayTime time, Weather w) {
  final night = time == DayTime.noche || time == DayTime.luna;
  // Cometas de noche, o cometas y globos bajo lluvia o nieve, no tienen sentido.
  if (l == Landmark.cometas && night) return false;
  if ((l == Landmark.cometas || l == Landmark.globos) && (w == Weather.lluvia || w == Weather.nieve)) return false;
  return _weatherFits(t, time, w);
}

bool _weatherFits(Terrain t, DayTime time, Weather w) => switch (w) {
  Weather.nieve => t != Terrain.dunas && t != Terrain.islas && t != Terrain.volcan && t != Terrain.canon,
  Weather.luciernagas => time != DayTime.amanecer && (t == Terrain.bosque || t == Terrain.lago || t == Terrain.pradera || t == Terrain.colinas),
  Weather.fugaces => time != DayTime.amanecer && time != DayTime.atardecer,
  Weather.hojas || Weather.petalos => t != Terrain.dunas && t != Terrain.nevado,
  _ => true,
};

/// Todas las combinaciones válidas, barajadas siempre igual.
final List<DailyScene> _allDays = () {
  final all = <DailyScene>[];
  for (final t in Terrain.values) {
    for (final l in _landmarksFor[t]!) {
      for (final time in DayTime.values) {
        for (final w in Weather.values) {
          if (_fits(t, l, time, w)) all.add(DailyScene(0, t, l, time, w));
        }
      }
    }
  }
  // Barajar con semilla fija; luego evitar que dos días seguidos compartan terreno.
  all.shuffle(Random(2026));
  final out = <DailyScene>[];
  final pool = [...all];
  while (out.length < 366 && pool.isNotEmpty) {
    final prev = out.isEmpty ? null : out.last;
    final i = pool.indexWhere((d) => prev == null || (d.terrain != prev.terrain && d.time != prev.time));
    final d = pool.removeAt(i < 0 ? 0 : i);
    out.add(DailyScene(out.length + 1, d.terrain, d.landmark, d.time, d.weather));
  }
  return out;
}();

int dayOfYear(DateTime d) => DateTime.utc(d.year, d.month, d.day).difference(DateTime.utc(d.year)).inDays + 1;

DailyScene dailyScene(int day) => _allDays[(day - 1).clamp(0, _allDays.length - 1)];

DailyScene dailySceneFor(DateTime d) => dailyScene(dayOfYear(d));

/// Fase de la luna en [d]: 0 nueva, .5 llena (mes sinódico desde una luna nueva conocida).
double moonPhase(DateTime d) {
  final days = d.toUtc().difference(DateTime.utc(2000, 1, 6, 18, 14)).inMinutes / 1440;
  return (days % 29.530588853) / 29.530588853;
}

extension on _P {
  void daily(DailyScene d, DateTime date) {
    final r = rnd(d.day * 7919);
    final night = d.dark;
    // Cielo: un velo de color según la hora, solo arriba.
    final skyCol = switch (d.time) {
      DayTime.amanecer => const Color(0xffff9a7a),
      DayTime.atardecer => const Color(0xffff7a3a),
      DayTime.crepusculo => const Color(0xff7a5cff),
      DayTime.luna => const Color(0xff4f7cff),
      DayTime.noche => const Color(0xff2a3a8a),
    };
    c.drawRect(
      Offset.zero & s,
      Paint()..shader = ui.Gradient.linear(Offset.zero, Offset(0, ground), [skyCol.withValues(alpha: strip ? .1 : .14), skyCol.withValues(alpha: 0)]),
    );
    if (night || d.weather == Weather.fugaces) stars(d.day, strip ? 14 : 60, maxY: .6);
    if (d.weather == Weather.fugaces) _shootingStars(d.day);
    // Luna con su fase real, o sol bajo.
    if (d.time == DayTime.amanecer || d.time == DayTime.atardecer) {
      final sun = Offset(w * (.2 + r.nextDouble() * .6), ground - (strip ? 8 : h * .18));
      for (var i = 3; i > 0; i--) {
        c.drawCircle(sun, (strip ? 10 : 40) * (1 + i * .4), fill(skyCol.withValues(alpha: .05)));
      }
      c.drawCircle(sun, strip ? 9 : 34, fill(tint(d.time == DayTime.amanecer ? const Color(0xffffc4a0) : const Color(0xffff9a4a), .7)));
    } else {
      final big = d.time == DayTime.luna;
      _phaseMoon(Offset(w * (.15 + r.nextDouble() * .7), strip ? h * .35 : h * (.14 + r.nextDouble() * .12)), strip ? 7 : (big ? 34 : 18), moonPhase(date));
    }
    if (d.terrain == Terrain.nevado && night) aurora3();
    // Nubes.
    final nClouds = d.weather == Weather.lluvia ? 6 : r.nextInt(4);
    for (var i = 0; i < nClouds; i++) {
      final rad = strip ? 6 + r.nextDouble() * 4 : 16 + r.nextDouble() * 20;
      final x = (r.nextDouble() * w + t * (3 + r.nextDouble() * 5)) % (w + rad * 5) - rad * 2.5;
      cloud(Offset(x, strip ? 10 + r.nextDouble() * 10 : h * (.1 + r.nextDouble() * .25)), rad, tint(d.weather == Weather.lluvia ? Gh.textMuted : Colors.white, d.weather == Weather.lluvia ? .5 : .12));
    }
    _terrain(d, far: true);
    final lx = w * (.18 + r.nextDouble() * .64);
    _landmark(d, lx);
    _terrain(d, far: false, clear: lx);
    _critters(d, r);
    _weather(d);
  }

  void aurora3() {
    for (var i = 0; i < 2; i++) {
      final path = Path();
      for (var x = 0.0; x <= w; x += 8) {
        final y = h * (strip ? .3 : .16) + i * (strip ? 3 : 14) + sin(x * .012 + t * .3 + i) * (strip ? 3 : 16);
        x == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
      }
      c.drawPath(
        path,
        Paint()
          ..color = (i == 0 ? const Color(0xff3cf0a0) : const Color(0xff8a6bff)).withValues(alpha: .14)
          ..style = PaintingStyle.stroke
          ..strokeWidth = strip ? 4 : 20
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
      );
    }
  }

  void _shootingStars(int seed) {
    for (var i = 0; i < 2; i++) {
      final period = 5.0 + i * 2.3;
      final k = ((t + i * 1.7) % period) / period;
      if (k > .18) continue;
      final cyc = ((t + i * 1.7) / period).floor();
      final rr = Random(seed + cyc * 13 + i);
      final p0 = Offset(w * (.2 + rr.nextDouble() * .7), h * (strip ? .1 : .05) + rr.nextDouble() * h * (strip ? .3 : .25));
      final p = p0 + Offset(-k / .18 * (strip ? 40 : 160), k / .18 * (strip ? 12 : 60));
      c.drawLine(
        p,
        p + const Offset(26, -9),
        Paint()
          ..shader = ui.Gradient.linear(p, p + const Offset(26, -9), [Colors.white.withValues(alpha: .9), Colors.white.withValues(alpha: 0)])
          ..strokeWidth = 1.6,
      );
    }
  }

  /// Luna con la parte iluminada según la fase (0 nueva, .5 llena).
  void _phaseMoon(Offset at, double r, double phase) {
    final lit = tint(const Color(0xfffff5d6), .85);
    c.drawCircle(at, r * 1.9, fill(lit.withValues(alpha: .05)));
    c.drawCircle(at, r, fill(tint(Gh.textMuted, .35)));
    // Terminador: elipse de ancho cos(fase) que tapa o completa la mitad.
    final waxing = phase < .5;
    final k = cos(phase * 2 * pi); // 1 nueva, -1 llena
    final half = Path()..addArc(Rect.fromCircle(center: at, radius: r), -pi / 2, waxing ? pi : -pi);
    final ell = Rect.fromCenter(center: at, width: 2 * r * k.abs(), height: 2 * r);
    final shape = k > 0
        ? Path.combine(PathOperation.difference, half, Path()..addOval(ell))
        : Path.combine(PathOperation.union, half, Path()..addOval(ell));
    c.drawPath(shape, fill(lit));
  }

  Color _ground(DailyScene d, double depth) {
    final base = switch (d.terrain) {
      Terrain.montanas => const Color(0xff4a5a78),
      Terrain.colinas => const Color(0xff3f7a44),
      Terrain.dunas => const Color(0xffc8955a),
      Terrain.mar || Terrain.islas => const Color(0xff1f6f8f),
      Terrain.lago => const Color(0xff2a6a8a),
      Terrain.ciudad => const Color(0xff3a3f52),
      Terrain.bosque => const Color(0xff2f6a3a),
      Terrain.canon => const Color(0xffb0603a),
      Terrain.nevado => const Color(0xffcfd8e8),
      Terrain.volcan => const Color(0xff5a3a3a),
      Terrain.pradera => const Color(0xff6a9a3a),
    };
    final warm = d.time == DayTime.atardecer || d.time == DayTime.amanecer;
    final c0 = warm ? Color.lerp(base, const Color(0xff8a3a4a), .25)! : base;
    return tint(c0, (d.dark ? .32 : .42) + depth * .3);
  }

  /// [clear]: x del lugar emblemático; los pinos de adelante del bosque lo esquivan
  /// (antes la cabaña o la carpa quedaban tapadas).
  void _terrain(DailyScene d, {required bool far, double? clear}) {
    final r = rnd(d.day * 31 + (far ? 1 : 2));
    final g = ground;
    final k = strip ? .18 : 1.0;
    final col = _ground(d, far ? 0 : 1);
    switch (d.terrain) {
      case Terrain.montanas || Terrain.nevado || Terrain.volcan:
        if (far) {
          final path = Path()..moveTo(0, g);
          var x = -20.0;
          while (x < w + 20) {
            final mw = (80 + r.nextDouble() * 140) * (strip ? .35 : 1), mh = (70 + r.nextDouble() * 120) * k + (strip ? 8 : 0);
            path
              ..lineTo(x + mw / 2, g - mh)
              ..lineTo(x + mw, g);
            if (d.terrain == Terrain.nevado || (d.terrain == Terrain.montanas && mh > 140 * k)) {
              c.drawPath(
                Path()
                  ..moveTo(x + mw / 2, g - mh)
                  ..lineTo(x + mw * .38, g - mh * .74)
                  ..lineTo(x + mw * .62, g - mh * .74)
                  ..close(),
                fill(tint(Colors.white, .5)),
              );
            }
            x += mw * .75;
          }
          c.drawPath(path..close(), fill(col));
          if (d.terrain == Terrain.volcan) {
            final top = Offset(w * .72, g - (strip ? 26 : 200));
            c.drawPath(
              Path()
                ..moveTo(top.dx - (strip ? 40 : 180), g)
                ..lineTo(top.dx - (strip ? 6 : 26), top.dy)
                ..lineTo(top.dx + (strip ? 6 : 26), top.dy)
                ..lineTo(top.dx + (strip ? 40 : 180), g)
                ..close(),
              fill(tint(const Color(0xff4a2a2a), .7)),
            );
            c.drawRect(Rect.fromCenter(center: top.translate(0, 2), width: strip ? 10 : 46, height: strip ? 2 : 6), fill(const Color(0xffff6a2a).withValues(alpha: twinkle(1, 2, .5))));
            // Humo.
            for (var i = 0; i < 5; i++) {
              final age = (t * .25 + i / 5) % 1;
              c.drawCircle(top + Offset(sin(age * 6 + i) * 8, -age * (strip ? 20 : 120)), (strip ? 3 : 12) + age * (strip ? 6 : 30), fill(tint(Gh.textSecondary, .25 * (1 - age))));
            }
          }
        } else {
          c.drawPath(wave(g - 10 * k - 2, 5 * k + 1, .01, 1), fill(col));
        }
      case Terrain.colinas || Terrain.pradera || Terrain.bosque:
        c.drawPath(wave(g - (far ? 70 : 24) * k - (strip ? 4 : 0), (far ? 22 : 10) * k + 1, far ? .006 : .011, d.day * .7 + (far ? 0 : 2)), fill(col));
        if (d.terrain == Terrain.bosque) {
          for (var x = -10.0; x < w; x += (strip ? 10 : 30) + r.nextDouble() * (strip ? 8 : 26)) {
            final size = (far ? 70 : 100) * (.6 + r.nextDouble() * .5) * (strip ? .22 : 1);
            if (!far && clear != null && (x - clear).abs() < (strip ? 22 : 110)) continue;
            pine(x, g - (far ? 50 : 14) * k, size, tint(const Color(0xff1f4a2a), far ? .5 : .8));
          }
        }
        if (d.terrain == Terrain.pradera && !far && !strip) {
          // Flores en el pasto.
          for (var i = 0; i < 40; i++) {
            c.drawCircle(Offset(r.nextDouble() * w, g - r.nextDouble() * 18), 1.6, fill([const Color(0xffffe05a), const Color(0xffff7ab0), Colors.white][i % 3].withValues(alpha: .7)));
          }
        }
      case Terrain.dunas:
        c.drawPath(wave(g - (far ? 50 : 16) * k - (strip ? 3 : 0), (far ? 18 : 10) * k + 1, far ? .005 : .008, d.day + (far ? 0 : 3)), fill(col));
      case Terrain.mar || Terrain.lago || Terrain.islas:
        if (far) {
          if (d.terrain == Terrain.islas) {
            for (var i = 0; i < 3; i++) {
              final cx = w * (.15 + i * .33) + r.nextDouble() * 40, iw = (strip ? 30 : 140) * (.6 + r.nextDouble() * .5);
              c.drawOval(Rect.fromCenter(center: Offset(cx, g - (strip ? 12 : 60) * 1), width: iw, height: strip ? 10 : 50), fill(tint(const Color(0xff3a6a3a), .5)));
            }
          }
          if (d.terrain == Terrain.lago) c.drawPath(wave(g - 90 * k - (strip ? 8 : 0), 18 * k, .007, 1), fill(tint(const Color(0xff2f5a3a), .45)));
          c.drawRect(Rect.fromLTRB(0, g - (strip ? 12 : 60), w, g + 1), fill(col));
        } else {
          for (var i = 0; i < 2; i++) {
            c.drawPath(wave(g - (strip ? 8 : 40) + i * (strip ? 4 : 18), strip ? 1.5 : 5, .02 + i * .006, t * (.7 + i * .3) * (i.isEven ? 1 : -1)), fill(_ground(d, .4 + i * .4)));
          }
        }
      case Terrain.ciudad:
        final layerR = rnd(d.day * 3 + (far ? 5 : 6));
        var x = -10.0;
        while (x < w) {
          final bw = (strip ? 8 : 20) + layerR.nextDouble() * (strip ? 14 : 40);
          final bh = ((far ? 90 : 50) + layerR.nextDouble() * (far ? 140 : 90)) * k + (strip ? 6 : 0);
          c.drawRect(Rect.fromLTWH(x, g - bh, bw, bh), fill(tint(far ? Gh.textMuted : Gh.border, far ? .45 : .9)));
          if (!far && d.dark) {
            final win = strip ? 2.0 : 3.0;
            for (var wy = g - bh + win * 2; wy < g - win * 2; wy += win * 3) {
              for (var wx = x + win; wx < x + bw - win; wx += win * 2.5) {
                if (sin(wx * 9.1 + wy * 3.7 + d.day + (t * .1).floor()) > .5) c.drawRect(Rect.fromLTWH(wx, wy, win, win), fill(const Color(0xffffd36b).withValues(alpha: .5)));
              }
            }
          }
          x += bw + 3;
        }
      case Terrain.canon:
        if (far) {
          // Mesetas de cima plana.
          var x = -20.0;
          while (x < w) {
            final mw = (strip ? 30 : 120) + r.nextDouble() * (strip ? 30 : 140), mh = (60 + r.nextDouble() * 120) * k + (strip ? 8 : 0);
            c.drawPath(
              Path()
                ..moveTo(x, g)
                ..lineTo(x + mw * .15, g - mh)
                ..lineTo(x + mw * .85, g - mh)
                ..lineTo(x + mw, g)
                ..close(),
              fill(col),
            );
            for (var b = 1; b < 4; b++) {
              c.drawRect(Rect.fromLTWH(x + mw * .15, g - mh + mh * b / 4, mw * .7, strip ? 1 : 2), fill(Colors.black.withValues(alpha: .12)));
            }
            x += mw + (strip ? 10 : 40);
          }
        } else {
          c.drawPath(wave(g - 8 * k - 1, 3 * k + .5, .02, 2), fill(_ground(d, 1)));
        }
    }
  }

  void _landmark(DailyScene d, double x) {
    final k = strip ? .2 : 1.0;
    final base = ground - (strip ? 3 : (d.terrain == Terrain.mar || d.terrain == Terrain.lago || d.terrain == Terrain.islas ? 46 : 20));
    final ink = tint(Gh.border, .95);
    final glow = const Color(0xffffd36b);
    switch (d.landmark) {
      case Landmark.faro:
        final hh = 150 * k + (strip ? 8 : 0), bw = 22 * k + (strip ? 3 : 0);
        c.drawPath(
          Path()
            ..moveTo(x - bw / 2, base)
            ..lineTo(x - bw / 3, base - hh)
            ..lineTo(x + bw / 3, base - hh)
            ..lineTo(x + bw / 2, base)
            ..close(),
          fill(tint(const Color(0xffe8e8f0), .6)),
        );
        for (var i = 1; i < 4; i++) {
          c.drawRect(Rect.fromLTWH(x - bw / 2, base - hh * i / 4, bw, hh * .07), fill(tint(const Color(0xffd23b3b), .7)));
        }
        final lamp = Offset(x, base - hh - 6 * k - 2);
        c.drawCircle(lamp, 6 * k + 1.5, fill(glow));
        // Haz que gira.
        final a = t * .8;
        final dir = cos(a);
        final len = (strip ? 60 : 420) * dir.abs();
        c.drawPath(
          Path()
            ..moveTo(lamp.dx, lamp.dy)
            ..lineTo(lamp.dx + len * dir.sign, lamp.dy - (strip ? 4 : 30))
            ..lineTo(lamp.dx + len * dir.sign, lamp.dy + (strip ? 4 : 30))
            ..close(),
          Paint()..shader = ui.Gradient.linear(lamp, lamp + Offset(len * dir.sign + .01, 0), [glow.withValues(alpha: .28), glow.withValues(alpha: 0)]),
        );
      case Landmark.molino:
        final hh = 110 * k + (strip ? 6 : 0);
        c.drawPath(
          Path()
            ..moveTo(x - 14 * k - 2, base)
            ..lineTo(x - 7 * k - 1, base - hh)
            ..lineTo(x + 7 * k + 1, base - hh)
            ..lineTo(x + 14 * k + 2, base)
            ..close(),
          fill(ink),
        );
        final hub = Offset(x, base - hh);
        for (var i = 0; i < 4; i++) {
          final a = t * .6 + i * pi / 2;
          final tip = hub + Offset(cos(a), sin(a)) * (70 * k + 6);
          c.drawLine(hub, tip, Paint()
            ..color = ink
            ..strokeWidth = 7 * k + 1.5);
        }
        c.drawCircle(hub, 4 * k + 1, fill(tint(glow, .6)));
      case Landmark.cabana:
        final u = 40 * k + (strip ? 4 : 0);
        c.drawRect(Rect.fromLTWH(x - u, base - u, u * 2, u), fill(ink));
        c.drawPath(
          Path()
            ..moveTo(x - u * 1.25, base - u)
            ..lineTo(x, base - u * 1.9)
            ..lineTo(x + u * 1.25, base - u)
            ..close(),
          fill(ink),
        );
        c.drawRect(Rect.fromLTWH(x - u * .6, base - u * .65, u * .4, u * .35), fill(glow.withValues(alpha: d.dark ? .8 : .35)));
        c.drawRect(Rect.fromLTWH(x + u * .5, base - u * 1.9, u * .25, u * .6), fill(ink));
        for (var i = 0; i < 5; i++) {
          final age = (t * .3 + i / 5) % 1;
          c.drawCircle(Offset(x + u * .62 + sin(age * 5 + i) * 6 * k, base - u * 1.9 - age * (strip ? 14 : 90)), (2 + age * 8) * k + 1, fill(tint(Gh.textSecondary, .3 * (1 - age))));
        }
      case Landmark.observatorio:
        final u = 36 * k + (strip ? 4 : 0);
        c.drawRect(Rect.fromLTWH(x - u, base - u, u * 2, u), fill(ink));
        c.drawArc(Rect.fromCircle(center: Offset(x, base - u), radius: u), pi, pi, true, fill(tint(const Color(0xffb8c0d0), .5)));
        c.save();
        c.translate(x, base - u * 1.4);
        c.rotate(-.6 + sin(t * .2) * .15);
        c.drawRect(Rect.fromLTWH(0, -u * .12, u * 1.1, u * .24), fill(ink));
        c.restore();
      case Landmark.antena:
        final hh = 190 * k + (strip ? 10 : 0);
        final p = Paint()
          ..color = ink
          ..strokeWidth = 2 * k + 1
          ..style = PaintingStyle.stroke;
        c.drawPath(
          Path()
            ..moveTo(x - 20 * k - 3, base)
            ..lineTo(x, base - hh)
            ..lineTo(x + 20 * k + 3, base),
          p,
        );
        for (var i = 1; i < 6; i++) {
          final y = base - hh * i / 6, half = (20 * k + 3) * (1 - i / 6);
          c.drawLine(Offset(x - half, y), Offset(x + half, y), p);
        }
        final on = (t * 1.2).floor().isEven;
        c.drawCircle(Offset(x, base - hh), 3 * k + 1.5, fill(on ? const Color(0xffff3a3a) : tint(const Color(0xffff3a3a), .3)));
        if (on) c.drawCircle(Offset(x, base - hh), 10 * k + 3, fill(const Color(0xffff3a3a).withValues(alpha: .15)));
      case Landmark.globos:
        final cols = [const Color(0xffff5a5a), const Color(0xffffc93a), const Color(0xff39b0ff)];
        for (var i = 0; i < 3; i++) {
          final bx = x + (i - 1) * (strip ? 40 : 160), by = (strip ? h * .35 : h * (.3 + i * .08)) + sin(t * .5 + i * 2) * (strip ? 2 : 10);
          final rad = (26 - i * 4) * k + (strip ? 3 : 0);
          c.drawOval(Rect.fromCenter(center: Offset(bx, by), width: rad * 2, height: rad * 2.3), fill(tint(cols[i], .65)));
          c.drawLine(Offset(bx - rad * .5, by + rad * 1.05), Offset(bx - rad * .25, by + rad * 1.6), Paint()..color = ink);
          c.drawLine(Offset(bx + rad * .5, by + rad * 1.05), Offset(bx + rad * .25, by + rad * 1.6), Paint()..color = ink);
          c.drawRect(Rect.fromLTWH(bx - rad * .28, by + rad * 1.6, rad * .56, rad * .4), fill(tint(const Color(0xff8a5a3a), .8)));
        }
      case Landmark.cometas:
        final cols = [const Color(0xffff4f7a), const Color(0xff39d0ff)];
        for (var i = 0; i < 2; i++) {
          final kx = x + (i == 0 ? -1 : 1) * (strip ? 30 : 120), ky = (strip ? h * .3 : h * (.22 + i * .1)) + sin(t * .9 + i) * (strip ? 3 : 12);
          final sz = 22 * k + 4;
          c.drawPath(
            Path()
              ..moveTo(kx, ky - sz)
              ..lineTo(kx + sz * .7, ky)
              ..lineTo(kx, ky + sz)
              ..lineTo(kx - sz * .7, ky)
              ..close(),
            fill(tint(cols[i], .75)),
          );
          final tail = Path()..moveTo(kx, ky + sz);
          for (var j = 1; j <= 8; j++) {
            tail.lineTo(kx + sin(t * 2 + j) * 6 * (strip ? .4 : 1), ky + sz + j * 8 * (strip ? .3 : 1));
          }
          c.drawPath(tail, Paint()
            ..color = tint(Gh.text, .4)
            ..style = PaintingStyle.stroke);
          c.drawLine(Offset(kx, ky + sz * .2), Offset(x, ground), Paint()..color = tint(Gh.text, .15));
        }
      case Landmark.castillo:
        final u = 9 * k + (strip ? 1 : 0);
        void tower(double tx, double th) {
          c.drawRect(Rect.fromLTWH(tx, base - th, u * 3, th), fill(ink));
          for (var i = 0; i < 3; i += 2) {
            c.drawRect(Rect.fromLTWH(tx + i * u, base - th - u, u, u), fill(ink));
          }
        }
        c.drawRect(Rect.fromLTWH(x - u * 6, base - u * 8, u * 12, u * 8), fill(ink));
        tower(x - u * 8, u * 13);
        tower(x + u * 5, u * 13);
        tower(x - u * 1.5, u * 17);
        c.drawRect(Rect.fromLTWH(x - u * .5, base - u * 13, u, u * 1.5), fill(glow.withValues(alpha: d.dark ? .7 : .3)));
      case Landmark.piramides:
        for (var i = 0; i < 3; i++) {
          final px0 = x + (i - 1) * (strip ? 30 : 120), ph = (120 - (i - 1).abs() * 40) * k + (strip ? 6 : 0);
          c.drawPath(
            Path()
              ..moveTo(px0 - ph, base)
              ..lineTo(px0, base - ph)
              ..lineTo(px0 + ph, base)
              ..close(),
            fill(tint(const Color(0xffd9a45a), .55)),
          );
          c.drawPath(
            Path()
              ..moveTo(px0, base - ph)
              ..lineTo(px0 + ph, base)
              ..lineTo(px0 + ph * .2, base)
              ..close(),
            fill(Colors.black.withValues(alpha: .15)),
          );
        }
      case Landmark.caravana:
        // Camellos en silueta que cruzan despacio.
        for (var i = 0; i < 3; i++) {
          final cx = (x + t * 6 + i * (strip ? 22 : 60)) % (w + 60) - 30;
          final u = 10 * k + (strip ? 1.2 : 0);
          final y = base - u * 2.2;
          c.drawOval(Rect.fromCenter(center: Offset(cx, y), width: u * 3.2, height: u * 1.6), fill(ink));
          c.drawCircle(Offset(cx - u * .3, y - u * .8), u * .7, fill(ink));
          c.drawLine(Offset(cx + u * 1.4, y), Offset(cx + u * 2.2, y - u * 1.6), Paint()
            ..color = ink
            ..strokeWidth = u * .5);
          c.drawCircle(Offset(cx + u * 2.4, y - u * 1.8), u * .45, fill(ink));
          for (final lx in [-1.0, -.4, .5, 1.1]) {
            c.drawLine(Offset(cx + lx * u, y + u * .5), Offset(cx + lx * u + sin(t * 3 + lx) * u * .2, base), Paint()
              ..color = ink
              ..strokeWidth = u * .3);
          }
        }
      case Landmark.oasis:
        for (var i = 0; i < 3; i++) {
          final px0 = x + (i - 1) * (strip ? 16 : 50), ph = (90 + i * 15) * k + (strip ? 6 : 0);
          final top = Offset(px0 + sin(t * .7 + i) * 3 * k, base - ph);
          c.drawPath(
            Path()
              ..moveTo(px0 - 3 * k - 1, base)
              ..quadraticBezierTo(px0, base - ph / 2, top.dx, top.dy)
              ..lineTo(top.dx + 2, top.dy)
              ..quadraticBezierTo(px0 + 2, base - ph / 2, px0 + 3 * k + 1, base)
              ..close(),
            fill(ink),
          );
          for (var j = 0; j < 5; j++) {
            final a = -pi + j * pi / 4 + sin(t + j) * .05;
            c.drawPath(
              Path()
                ..moveTo(top.dx, top.dy)
                ..quadraticBezierTo(top.dx + cos(a) * 20 * k, top.dy + sin(a) * 20 * k - 6 * k, top.dx + cos(a) * 34 * k + cos(a) * 3, top.dy + 10 * k),
              Paint()
                ..color = tint(const Color(0xff2f6a3a), .8)
                ..style = PaintingStyle.stroke
                ..strokeWidth = 4 * k + 1,
            );
          }
        }
      case Landmark.velero:
        final bx = (x + t * 5) % (w + 80) - 40, by = base + 10 * k + sin(t * 1.4) * 2;
        final u = 30 * k + (strip ? 4 : 0);
        c.drawPath(
          Path()
            ..moveTo(bx - u, by)
            ..lineTo(bx + u, by)
            ..lineTo(bx + u * .7, by + u * .35)
            ..lineTo(bx - u * .7, by + u * .35)
            ..close(),
          fill(ink),
        );
        c.drawPath(
          Path()
            ..moveTo(bx, by - u * 1.8)
            ..lineTo(bx, by - u * .1)
            ..lineTo(bx + u * .9, by - u * .1)
            ..close(),
          fill(tint(Colors.white, .6)),
        );
        c.drawPath(
          Path()
            ..moveTo(bx - u * .1, by - u * 1.5)
            ..lineTo(bx - u * .1, by - u * .1)
            ..lineTo(bx - u * .8, by - u * .1)
            ..close(),
          fill(tint(Colors.white, .45)),
        );
      case Landmark.ballena:
        final cyc = (t % 12) / 12;
        final u = 30 * k + (strip ? 4 : 0);
        if (cyc < .4) {
          // Cola que sale y se hunde.
          final up = sin(cyc / .4 * pi);
          final y = base + 14 * k - up * u;
          c.drawPath(
            Path()
              ..moveTo(x, y + u)
              ..quadraticBezierTo(x - u * .1, y + u * .3, x - u * .9, y)
              ..quadraticBezierTo(x - u * .3, y + u * .15, x, y + u * .2)
              ..quadraticBezierTo(x + u * .3, y + u * .15, x + u * .9, y)
              ..quadraticBezierTo(x + u * .1, y + u * .3, x, y + u)
              ..close(),
            fill(ink),
          );
        } else {
          // Chorro de agua.
          final k2 = (cyc - .4) / .6;
          if (k2 < .3) {
            for (var i = 0; i < 8; i++) {
              final a = -pi / 2 + (i - 3.5) * .15;
              c.drawCircle(Offset(x + cos(a) * k2 * u * 3, base + 10 * k + sin(a) * k2 * u * 3), 2 * k + 1, fill(tint(Colors.white, .5 * (1 - k2 / .3))));
            }
          }
        }
      case Landmark.puente:
        final span = strip ? 120.0 : w * .5;
        final x0 = x - span / 2, deck = base - (strip ? 6 : 40);
        c.drawRect(Rect.fromLTWH(x0, deck, span, 6 * k + 2), fill(ink));
        final p = Paint()
          ..color = ink
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3 * k + 1;
        for (final px0 in [x0 + span * .2, x0 + span * .8]) {
          c.drawRect(Rect.fromLTWH(px0 - 4 * k - 1, deck - 90 * k - 6, 8 * k + 2, 90 * k + 6 + (ground - deck)), fill(ink));
        }
        c.drawPath(
          Path()
            ..moveTo(x0, deck)
            ..quadraticBezierTo(x0 + span * .1, deck - 60 * k, x0 + span * .2, deck - 90 * k - 6)
            ..quadraticBezierTo(x, deck - 10 * k, x0 + span * .8, deck - 90 * k - 6)
            ..quadraticBezierTo(x0 + span * .9, deck - 60 * k, x0 + span, deck),
          p,
        );
        if (d.dark) {
          for (var i = 0; i < 9; i++) {
            c.drawCircle(Offset(x0 + span * (i + .5) / 9, deck - 2), 1.6, fill(glow.withValues(alpha: .8)));
          }
        }
      case Landmark.carpa:
        final u = 34 * k + (strip ? 4 : 0);
        c.drawPath(
          Path()
            ..moveTo(x - u, base)
            ..lineTo(x, base - u * 1.1)
            ..lineTo(x + u, base)
            ..close(),
          fill(tint(const Color(0xffd0743a), .6)),
        );
        c.drawPath(
          Path()
            ..moveTo(x - u * .2, base)
            ..lineTo(x, base - u * .6)
            ..lineTo(x + u * .2, base)
            ..close(),
          fill(ink),
        );
        // Fogata.
        final f = Offset(x + u * 1.8, base);
        c.drawCircle(f.translate(0, -u * .3), u * 1.2, fill(const Color(0xffff8a2a).withValues(alpha: .06 * twinkle(2, 7, .6))));
        for (var i = 0; i < 3; i++) {
          final fl = twinkle(i * 2.0, 9 + i.toDouble(), .6);
          c.drawOval(Rect.fromCenter(center: f.translate((i - 1) * u * .15, -u * .25 * fl), width: u * .22, height: u * .5 * fl), fill([const Color(0xffff6a2a), const Color(0xffffb02e), const Color(0xffffe45c)][i].withValues(alpha: .85)));
        }
      case Landmark.noria:
        final rad = 80 * k + (strip ? 8 : 0);
        final hub = Offset(x, base - rad - 8 * k);
        final p = Paint()
          ..color = ink
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2 * k + 1;
        c.drawCircle(hub, rad, p);
        c.drawLine(hub, Offset(x - rad * .6, base), p);
        c.drawLine(hub, Offset(x + rad * .6, base), p);
        for (var i = 0; i < 10; i++) {
          final a = t * .15 + i * 2 * pi / 10;
          final q = hub + Offset(cos(a), sin(a)) * rad;
          c.drawLine(hub, q, p);
          c.drawRect(Rect.fromCenter(center: q.translate(0, 5 * k + 1), width: 9 * k + 2, height: 8 * k + 2), fill(d.dark ? [glow, const Color(0xffff7ab0), const Color(0xff7ad8ff)][i % 3].withValues(alpha: .8) : ink));
        }
      case Landmark.tren:
        final u = 14 * k + (strip ? 2 : 0);
        final y = base - u * 2;
        // Desfasado para que el cuadro quieto (t = 3) lo muestre entero.
        final x0 = (t * (strip ? 20 : 40) + w * .45) % (w + u * 40) - u * 30;
        for (var i = 0; i < 5; i++) {
          final cx = x0 + i * u * 4.4;
          c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(cx, y, u * 4, u * 1.8), Radius.circular(u * .3)), fill(ink));
          for (var j = 0; j < 3; j++) {
            c.drawRect(Rect.fromLTWH(cx + u * (.4 + j * 1.2), y + u * .35, u * .8, u * .6), fill(glow.withValues(alpha: d.dark ? .75 : .3)));
          }
        }
        c.drawRect(Rect.fromLTWH(0, base - u * .2, w, u * .2), fill(ink));
        if (d.dark) c.drawCircle(Offset(x0 + 5 * u * 4.4 - u * .3, y + u), u * 2, fill(glow.withValues(alpha: .12)));
    }
  }

  void _critters(DailyScene d, Random r) {
    if (d.dark) {
      if (d.weather == Weather.luciernagas) {
        for (var i = 0; i < (strip ? 8 : 26); i++) {
          final ph = r.nextDouble() * 9;
          final at = Offset(r.nextDouble() * w + sin(t * .4 + ph) * 18, ground - (strip ? 6 + r.nextDouble() * 20 : 20 + r.nextDouble() * h * .3) + cos(t * .5 + ph) * 8);
          final a = twinkle(ph * 3, 2.2, 0);
          c.drawCircle(at, 6, fill(const Color(0xffd9ff6a).withValues(alpha: a * .12)));
          c.drawCircle(at, 1.6, fill(const Color(0xffeaffa0).withValues(alpha: a * .9)));
        }
      } else if (r.nextBool() && !strip && _land.contains(d.terrain)) {
        // Búho en un árbol seco (antes iba en una rama suelta y flotaba en el aire,
        // también sobre el mar o entre edificios).
        final tx = w * (.06 + r.nextDouble() * .14), top = ground - 150;
        final wood = tint(Gh.border, 1);
        c.drawPath(
          Path()
            ..moveTo(tx - 7, ground + 4)
            ..quadraticBezierTo(tx - 3, ground - 70, tx - 2, top)
            ..lineTo(tx + 2, top)
            ..quadraticBezierTo(tx + 4, ground - 70, tx + 8, ground + 4)
            ..close(),
          fill(wood),
        );
        final limb = Paint()
          ..color = wood
          ..strokeCap = StrokeCap.round;
        c.drawLine(Offset(tx, top + 22), Offset(tx + 46, top + 12), limb..strokeWidth = 4);
        c.drawLine(Offset(tx, top + 46), Offset(tx - 30, top + 30), limb..strokeWidth = 3);
        c.drawLine(Offset(tx - 1, top + 6), Offset(tx - 14, top - 10), limb..strokeWidth = 2.5);
        final o = Offset(tx + 30, top + 1);
        c.drawOval(Rect.fromCenter(center: o, width: 22, height: 30), fill(tint(const Color(0xff6a5040), .8)));
        // Orejas.
        for (final dx in [-7.0, 7.0]) {
          c.drawPath(
            Path()
              ..moveTo(o.dx + dx - 3, o.dy - 12)
              ..lineTo(o.dx + dx, o.dy - 19)
              ..lineTo(o.dx + dx + 3, o.dy - 12)
              ..close(),
            fill(tint(const Color(0xff6a5040), .8)),
          );
        }
        final blink = (t % 5) < .15;
        for (final dx in [-5.0, 5.0]) {
          c.drawCircle(o.translate(dx, -6), 4, fill(tint(const Color(0xffffd35a), .9)));
          c.drawCircle(o.translate(dx, -6), blink ? 0 : 1.8, fill(Colors.black));
        }
      }
    } else {
      // Bandada de pájaros.
      final bird = Paint()
        ..color = tint(Gh.text, .45)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.3;
      final x0 = (t * 16 + d.day * 37) % (w + 200) - 100, y0 = strip ? h * .3 : h * .22;
      for (var i = 0; i < (strip ? 3 : 7); i++) {
        final x = x0 - (i ~/ 2) * 16 * (strip ? .5 : 1), y = y0 + (i.isEven ? 1 : -1) * (i ~/ 2 + 1) * 8 * (strip ? .4 : 1) * (i == 0 ? 0 : 1);
        final flap = sin(t * 5 + i) * 3;
        c.drawPath(
          Path()
            ..moveTo(x - 6, y - flap)
            ..quadraticBezierTo(x - 3, y - 3, x, y)
            ..quadraticBezierTo(x + 3, y - 3, x + 6, y - flap),
          bird,
        );
      }
    }
  }

  void _weather(DailyScene d) {
    switch (d.weather) {
      case Weather.nieve:
        falling(d.day, strip ? 18 : 60, (at, rot, r) => c.drawCircle(at, strip ? 1.2 : 1 + r.nextDouble() * 2, fill(Colors.white.withValues(alpha: .7))), speed: strip ? 10 : 20);
      case Weather.lluvia:
        final p = Paint()
          ..color = const Color(0xffa8c8ff).withValues(alpha: .35)
          ..strokeWidth = 1;
        final r = rnd(d.day + 5);
        for (var i = 0; i < (strip ? 30 : 110); i++) {
          final x = r.nextDouble() * w, sp = 260 + r.nextDouble() * 120, ph = r.nextDouble() * 10;
          final y = (ph * 50 + t * sp) % (h + 20) - 10;
          c.drawLine(Offset(x, y), Offset(x - 2, y + (strip ? 5 : 10)), p);
        }
        // Relámpago de vez en cuando.
        if ((t % 13) < .12 && !strip) c.drawRect(Offset.zero & s, fill(Colors.white.withValues(alpha: .06)));
      case Weather.hojas:
        falling(d.day, strip ? 8 : 26, (at, rot, r) {
          c.save();
          c.translate(at.dx, at.dy);
          c.rotate(rot);
          final sz = strip ? 3.0 : 5 + r.nextDouble() * 3;
          c.drawPath(
            Path()
              ..moveTo(-sz, 0)
              ..quadraticBezierTo(0, -sz * .8, sz, 0)
              ..quadraticBezierTo(0, sz * .8, -sz, 0),
            fill(Color.lerp(const Color(0xffe0702a), const Color(0xffd7b84a), r.nextDouble())!.withValues(alpha: .75)),
          );
          c.restore();
        }, speed: 12);
      case Weather.petalos:
        falling(d.day, strip ? 10 : 34, (at, rot, r) {
          c.save();
          c.translate(at.dx, at.dy);
          c.rotate(rot);
          c.drawOval(Rect.fromCenter(center: Offset.zero, width: strip ? 3.5 : 6, height: strip ? 2 : 3.5), fill(const Color(0xffffb0cc).withValues(alpha: .75)));
          c.restore();
        }, speed: 11);
      case Weather.niebla:
        for (var i = 0; i < 3; i++) {
          final y = ground - (strip ? 6 + i * 5 : 30 + i * 40);
          final x = (t * (6 + i * 3)) % w;
          for (final dx in [x - w, x]) {
            c.drawRRect(
              RRect.fromRectAndRadius(Rect.fromLTWH(dx, y, w, strip ? 6 : 26), const Radius.circular(20)),
              Paint()
                ..color = Colors.white.withValues(alpha: .05)
                ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
            );
          }
        }
      case Weather.claro || Weather.fugaces || Weather.luciernagas:
        break;
    }
  }
}
