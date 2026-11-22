import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mickhub/decor.dart';
import 'package:mickhub/look.dart';

void main() {
  test('temporadas: fechas fijas y móviles (Carnaval sale de la Pascua)', () {
    expect(seasonFor(DateTime(2026, 10, 31)), Look.halloween);
    expect(seasonFor(DateTime(2026, 11, 2)), Look.muertos);
    expect(seasonFor(DateTime(2026, 11, 21)), isNull);
    expect(seasonFor(DateTime(2026, 12, 24)), Look.navidad);
    expect(seasonFor(DateTime(2026, 12, 31)), Look.anioNuevo);
    expect(seasonFor(DateTime(2027, 1, 6)), Look.anioNuevo);
    expect(seasonFor(DateTime(2027, 1, 7)), isNull);
    expect(seasonFor(DateTime(2026, 6, 21)), Look.intiRaymi);
    // Pascua 2027: 28 de marzo; Ceniza 10 de febrero; Carnaval del 6 al 9.
    expect(easter(2027), DateTime(2027, 3, 28));
    expect(seasonFor(DateTime(2027, 2, 6)), Look.carnaval);
    expect(seasonFor(DateTime(2027, 2, 9)), Look.carnaval);
    expect(seasonFor(DateTime(2027, 2, 10)), Look.sanValentin, reason: 'Carnaval terminó; San Valentín va del 7 al 15 y Carnaval gana solo en sus días');
  });

  test('qué paleta toca: cumpleaños > temporada no saltada > rotación > elegida', () {
    final xmas = DateTime(2026, 12, 20);
    Look go(DateTime d, {String rot = 'fija', bool seasonal = true, String bday = '', String skip = ''}) =>
        resolveLook(now: d, chosen: Look.bosque, rotation: rot, seasonal: seasonal, birthday: bday, skippedSeason: skip, launch: Look.arcade);
    expect(go(xmas), Look.navidad);
    expect(go(xmas, seasonal: false), Look.bosque);
    expect(go(xmas, skip: seasonKey(Look.navidad, xmas)), Look.bosque, reason: 'la eligió a mano durante la temporada');
    expect(go(DateTime(2027, 12, 20), skip: 'navidad-2026'), Look.navidad, reason: 'el año siguiente vuelve');
    expect(go(xmas, bday: '12-20'), Look.cumple);
    expect(go(xmas, bday: '12-20', skip: 'cumple-2026'), Look.navidad);
    expect(go(DateTime(2026, 11, 21), rot: 'abrir'), Look.arcade);
    expect(go(DateTime(2026, 11, 21), rot: 'dia').kind, isNot(LookKind.seasonal));
    // Año Nuevo cruza el año: el 3 de enero cuenta como la temporada del año anterior.
    expect(seasonKey(Look.anioNuevo, DateTime(2027, 1, 3)), seasonKey(Look.anioNuevo, DateTime(2026, 12, 28)));
  });

  test('una distinta cada día: nunca repite la de ayer', () {
    var prev = dailyLook(DateTime(2026, 1, 1));
    for (var d = 2; d < 120; d++) {
      final l = dailyLook(DateTime(2026, 1, d));
      expect(l, isNot(prev));
      prev = l;
    }
  });

  test('sprites: filas de 16, mismo alto en todos los cuadros y colores para cada letra', () {
    for (final MapEntry(key: name, value: p) in pets.entries) {
      final heights = p.frames.values.map((f) => f.length).toSet();
      expect(heights.length, 1, reason: '$name: cuadros de distinto alto');
      for (final MapEntry(key: f, value: rows) in p.frames.entries) {
        for (final r in rows) {
          expect(r.length, 16, reason: '$name/$f: "$r"');
          for (final ch in r.split('')) {
            expect(ch == '.' || p.colors.containsKey(ch), isTrue, reason: '$name/$f: letra "$ch" sin color');
          }
        }
      }
    }
  });

  test('la mascota no se sale de la barra, duerme y despierta con un clic', () {
    final sim = PetSim(Random(1));
    for (var i = 0; i < 6000; i++) {
      sim.step(.1, 300);
      expect(sim.x, inInclusiveRange(2, 300 - PetSim.width - 2));
    }
    sim.state = 'sleep';
    sim.pet(Offset(sim.x + 10, 40), 50);
    expect(sim.state, 'idle');
    expect(sim.hearts, isNotEmpty);
    // Un clic lejos no la toca.
    sim.state = 'sleep';
    sim.pet(Offset(sim.x + 200, 40), 50);
    expect(sim.state, 'sleep');
    // Al commitear festeja aunque esté dormida.
    sim.hearts.clear();
    sim.cheer();
    expect((sim.state, sim.hearts.length, sim.zs.length), ('idle', 3, 0));
  });
}
