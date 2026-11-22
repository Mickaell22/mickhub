import 'dart:math';

import 'package:flutter/material.dart';

import 'theme.dart';

/// Escena dibujada en los espacios vacíos (pantallas sin contenido) y en el
/// hueco de la barra superior. Todas son originales, hechas con CustomPainter
/// (`decor.dart`): nada de imágenes ni personajes de terceros.
enum Scene {
  diaria('Una distinta cada día'),
  grafo('Constelación de commits'),
  ciudad('Ciudad de noche'),
  bosque('Bosque con luciérnagas'),
  olas('Mar'),
  atardecer('Atardecer'),
  nubes('Nubes y luna'),
  desierto('Desierto'),
  aurora('Aurora'),
  retro('Pantalla retro'),
  arcade('Arcade'),
  aventura('Aventura de 16 bits'),
  espacio('Espacio'),
  halloween('Halloween'),
  muertos('Día de Muertos'),
  navidad('Navidad'),
  anioNuevo('Año Nuevo'),
  sanValentin('San Valentín'),
  carnaval('Carnaval'),
  sanPatricio('San Patricio'),
  diaTierra('Día de la Tierra'),
  intiRaymi('Inti Raymi'),
  cumple('Cumpleaños');

  const Scene(this.label);
  final String label;
}

/// Gorro o adorno que se pone la mascota en una fecha especial.
enum Hat { none, santa, fiesta, bruja, flor, corazon, trebol, sol }

enum LookKind { classic, themed, seasonal }

/// Una paleta de la app: colores de [Gh] y la escena que trae.
enum Look {
  desktop('GitHub Desktop', 'La de siempre', Scene.grafo),
  grafito('Grafito', 'Gris azulado', Scene.ciudad, hue: 215, sat: .14, accent: Color(0xff4f86c6)),
  bosque('Bosque', 'Pinos y musgo', Scene.bosque, hue: 130, sat: .16, accent: Color(0xff3f9a52)),
  oceano('Océano', 'Azul profundo', Scene.olas, hue: 195, sat: .3, accent: Color(0xff1d8fa6)),
  vino('Vino', 'Tinto y uva', Scene.atardecer, hue: 345, sat: .16, accent: Color(0xffb8405a)),
  lavanda('Lavanda', 'Violeta suave', Scene.nubes, hue: 262, sat: .18, accent: Color(0xff7b62c9)),
  arena('Arena', 'Dunas y sol', Scene.desierto, hue: 36, sat: .2, accent: Color(0xffc08a1e)),
  menta('Menta', 'Verde frío', Scene.aurora, hue: 165, sat: .2, accent: Color(0xff1f9e78)),
  cobre('Cobre', 'Óxido cálido', Scene.atardecer, hue: 18, sat: .2, accent: Color(0xffc0602e)),
  medianoche('Medianoche', 'Casi negro', Scene.espacio, hue: 230, sat: .25, accent: Color(0xff5468d4)),
  retro('Retro', 'Fósforo verde de terminal', Scene.retro, kind: LookKind.themed, hue: 120, sat: .35, accent: Color(0xff2fbf4f)),
  arcade('Arcade', 'Neón de sala de juegos', Scene.arcade, kind: LookKind.themed, hue: 280, sat: .4, accent: Color(0xffe0329b)),
  aventura('Aventura', '16 bits: praderas y castillo', Scene.aventura, kind: LookKind.themed, hue: 100, sat: .22, accent: Color(0xffd4a017)),
  espacio('Espacio', 'Estrellas y planetas', Scene.espacio, kind: LookKind.themed, hue: 240, sat: .3, accent: Color(0xff8a5cf6)),
  halloween('Halloween', 'Calabaza y noche', Scene.halloween, kind: LookKind.seasonal, hue: 270, sat: .2, accent: Color(0xffe8741c), hat: Hat.bruja),
  muertos('Día de Muertos', 'Cempasúchil y papel picado', Scene.muertos, kind: LookKind.seasonal, hue: 300, sat: .2, accent: Color(0xffe39b12), hat: Hat.flor),
  navidad('Navidad', 'Rojo y pino', Scene.navidad, kind: LookKind.seasonal, hue: 150, sat: .22, accent: Color(0xffc8303b), hat: Hat.santa),
  anioNuevo('Año Nuevo', 'Medianoche y dorado', Scene.anioNuevo, kind: LookKind.seasonal, hue: 228, sat: .3, accent: Color(0xffc9a227), hat: Hat.fiesta),
  sanValentin('San Valentín', 'Rosa suave', Scene.sanValentin, kind: LookKind.seasonal, hue: 340, sat: .2, accent: Color(0xffe0457b), hat: Hat.corazon),
  carnaval('Carnaval', 'Serpentinas y confeti', Scene.carnaval, kind: LookKind.seasonal, hue: 285, sat: .22, accent: Color(0xffd94a9a), hat: Hat.fiesta),
  sanPatricio('San Patricio', 'Trébol y verde', Scene.sanPatricio, kind: LookKind.seasonal, hue: 135, sat: .25, accent: Color(0xff2f9e4a), hat: Hat.trebol),
  diaTierra('Día de la Tierra', 'Hojas y planeta', Scene.diaTierra, kind: LookKind.seasonal, hue: 120, sat: .18, accent: Color(0xff3c9a5f), hat: Hat.flor),
  intiRaymi('Inti Raymi', 'Fiesta del sol', Scene.intiRaymi, kind: LookKind.seasonal, hue: 35, sat: .25, accent: Color(0xffe0a020), hat: Hat.sol),
  cumple('Cumpleaños', 'Vela y confeti', Scene.cumple, kind: LookKind.seasonal, hue: 190, sat: .2, accent: Color(0xff1fa3ad), hat: Hat.fiesta);

  const Look(this.label, this.hint, this.scene, {this.kind = LookKind.classic, this.hue = 0, this.sat = 0, this.accent, this.hat = Hat.none});
  final String label, hint;
  final Scene scene;
  final LookKind kind;
  final double hue, sat;
  final Color? accent;
  final Hat hat;

  GhColors get colors => accent == null ? GhColors.desktop : GhColors.derive(hue, sat, accent!);

  /// Las que entran en "una distinta cada día" / "al abrir" (no las de temporada).
  static List<Look> get pool => values.where((l) => l.kind != LookKind.seasonal).toList();

  static Look byName(String? n) => values.where((l) => l.name == n).firstOrNull ?? desktop;
}

/// Domingo de Pascua (algoritmo de Meeus/Jones/Butcher), para Carnaval.
DateTime easter(int y) {
  final a = y % 19, b = y ~/ 100, c = y % 100, d = b ~/ 4, e = b % 4;
  final f = (b + 8) ~/ 25, g = (b - f + 1) ~/ 3, h = (19 * a + b - d - g + 15) % 30;
  final i = c ~/ 4, k = c % 4, l = (32 + 2 * e + 2 * i - h - k) % 7;
  final m = (a + 11 * h + 22 * l) ~/ 451;
  final month = (h + l - 7 * m + 114) ~/ 31, day = (h + l - 7 * m + 114) % 31 + 1;
  return DateTime(y, month, day);
}

/// Temporada activa en [d], o null. Mismas fechas que Surco.
Look? seasonFor(DateTime d) {
  final day0 = DateTime(d.year, d.month, d.day);
  // Aritmética de calendario (DateTime(y, m, d - n)), no Duration: restar días
  // como horas cruza el cambio de horario y corre la fecha un día.
  DateTime minus(DateTime x, int days) => DateTime(x.year, x.month, x.day - days);
  bool within(DateTime from, DateTime to) => !day0.isBefore(from) && !day0.isAfter(to);
  final ash = minus(easter(d.year), 46); // Miércoles de Ceniza
  if (within(minus(ash, 4), minus(ash, 1))) return Look.carnaval;
  final (m, day) = (d.month, d.day);
  if (m == 10 && day >= 15) return Look.halloween;
  if (m == 11 && day <= 2) return Look.muertos;
  if (m == 12 && day <= 25) return Look.navidad;
  if ((m == 12 && day >= 26) || (m == 1 && day <= 6)) return Look.anioNuevo;
  if (m == 2 && day >= 7 && day <= 15) return Look.sanValentin;
  if (m == 3 && day == 17) return Look.sanPatricio;
  if (m == 4 && day == 22) return Look.diaTierra;
  if (m == 6 && day >= 20 && day <= 24) return Look.intiRaymi;
  return null;
}

/// Paleta del día para "una distinta cada día": estable durante el día y nunca
/// la misma que ayer (cada día salta 1..n-1 posiciones desde la de ayer).
// ponytail: recorre los días desde 2026-01-01, unos cientos de vueltas por año.
Look dailyLook(DateTime d) {
  final pool = Look.pool;
  final days = DateTime.utc(d.year, d.month, d.day).difference(DateTime.utc(2026)).inDays;
  var idx = 0;
  for (var i = 1; i <= days; i++) {
    idx = (idx + 1 + Random(i).nextInt(pool.length - 1)) % pool.length;
  }
  return pool[idx];
}

/// Clave de una temporada en un año ("navidad-2026"): elegir otra paleta a mano
/// durante una temporada la salta solo esa vez, el año que viene vuelve.
String seasonKey(Look season, DateTime d) => '${season.name}-${d.month == 1 && season == Look.anioNuevo ? d.year - 1 : d.year}';

/// Qué paleta toca. Prioridad: cumpleaños > temporada (si no se saltó) >
/// rotación (cada día / al abrir) > la elegida.
Look resolveLook({
  required DateTime now,
  required Look chosen,
  required String rotation,
  required bool seasonal,
  String birthday = '',
  String skippedSeason = '',
  Look? launch,
}) {
  final mmdd = '${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  if (seasonal && birthday == mmdd && skippedSeason != 'cumple-${now.year}') return Look.cumple;
  final season = seasonal ? seasonFor(now) : null;
  if (season != null && skippedSeason != seasonKey(season, now)) return season;
  return switch (rotation) {
    'dia' => dailyLook(now),
    'abrir' => launch ?? chosen,
    _ => chosen,
  };
}
