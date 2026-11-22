import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'look.dart';
import 'theme.dart';

// Decoración: escenas dibujadas en los espacios vacíos y una mascota en el hueco
// de la barra superior (pedido del dueño: "vida visual", que no se sienta todo
// código). Reglas: todo original con CustomPainter, nada encima de diffs, listas
// ni botones (solo pantallas vacías y el hueco de la barra), IgnorePointer salvo
// la mascota, un solo reloj lento compartido que se apaga sin nadie mirando o con
// la ventana oculta, y quieto si el sistema pide menos animaciones.

/// Reloj compartido de todas las animaciones: 10 cuadros por segundo (el pixel
/// art no necesita más), solo mientras alguien lo escucha y la ventana se ve.
class DecorClock extends ChangeNotifier {
  final _sw = Stopwatch()..start();
  Timer? _timer;
  var _listeners = 0;
  var _visible = true;

  /// Segundos desde que arrancó la app (no avanza con la ventana oculta).
  double get t => _sw.elapsedMilliseconds / 1000;

  set visible(bool v) {
    _visible = v;
    v ? _sw.start() : _sw.stop();
    _sync();
  }

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    _listeners++;
    _sync();
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    _listeners--;
    _sync();
  }

  void _sync() {
    final run = _visible && _listeners > 0;
    if (run && _timer == null) {
      _timer = Timer.periodic(const Duration(milliseconds: 100), (_) => notifyListeners());
    } else if (!run) {
      _timer?.cancel();
      _timer = null;
    }
  }
}

final decorClock = DecorClock();

/// Lo que está activo ahora (lo pone el Shell a partir de los ajustes).
class LookState extends ChangeNotifier {
  Look look = Look.desktop;
  Scene? scene = Scene.grafo; // null = sin escena
  String pet = 'gato'; // nombre de mascota o 'ninguna'
  bool decor = true;

  void set({required Look look, required Scene? scene, required String pet, required bool decor}) {
    if (look == this.look && scene == this.scene && pet == this.pet && decor == this.decor) return;
    this.look = look;
    this.scene = scene;
    this.pet = pet;
    this.decor = decor;
    notifyListeners();
  }
}

final lookState = LookState();

/// Sube en uno al commitear o subir: la mascota salta y suelta corazones.
final petCheer = ValueNotifier(0);

/// Fondo dibujado detrás de una pantalla vacía. Debajo del texto deja un velo
/// del color de fondo para que se siga leyendo.
class SceneBackdrop extends StatelessWidget {
  const SceneBackdrop({super.key, this.scene});

  /// Para la vista previa de Personalización; null = la activa.
  final Scene? scene;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: lookState,
    builder: (context, _) {
      final sc = scene ?? (lookState.decor ? lookState.scene : null);
      if (sc == null) return const SizedBox.shrink();
      return IgnorePointer(
        child: RepaintBoundary(
          child: CustomPaint(
            size: Size.infinite,
            painter: ScenePainter(sc, decorClock, still: MediaQuery.maybeDisableAnimationsOf(context) ?? false),
          ),
        ),
      );
    },
  );
}

/// El hueco de la barra superior: la tira de la escena y la mascota caminando.
class ToolbarDecor extends StatefulWidget {
  const ToolbarDecor({super.key});

  @override
  State<ToolbarDecor> createState() => _ToolbarDecorState();
}

class _ToolbarDecorState extends State<ToolbarDecor> {
  final _sim = PetSim();
  var _last = 0.0;

  @override
  void initState() {
    super.initState();
    decorClock.addListener(_tick);
    petCheer.addListener(_sim.cheer);
    _last = decorClock.t;
  }

  @override
  void dispose() {
    decorClock.removeListener(_tick);
    petCheer.removeListener(_sim.cheer);
    super.dispose();
  }

  var _width = 0.0;

  void _tick() {
    final now = decorClock.t;
    _sim.step((now - _last).clamp(0, .5), _width);
    _last = now;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: lookState,
    builder: (context, _) {
      if (!lookState.decor) return const SizedBox.expand();
      final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
      final pet = pets[lookState.pet];
      return LayoutBuilder(
        builder: (context, box) {
          _width = box.maxWidth;
          return Stack(
            fit: StackFit.expand,
            children: [
              if (lookState.scene != null)
                IgnorePointer(
                  child: RepaintBoundary(
                    child: CustomPaint(painter: ScenePainter(lookState.scene!, decorClock, strip: true, still: still)),
                  ),
                ),
              if (pet != null && box.maxWidth > 80)
                GestureDetector(
                  behavior: HitTestBehavior.deferToChild,
                  onTapUp: (d) => _sim.pet(d.localPosition, box.maxHeight),
                  child: RepaintBoundary(
                    child: CustomPaint(
                      painter: PetPainter(pet, _sim, decorClock, hat: lookState.look.hat, still: still),
                    ),
                  ),
                ),
            ],
          );
        },
      );
    },
  );
}

// ---------------------------------------------------------------------------
// Mascotas: pixel art original, 16 columnas, mirando a la derecha.
// '.' vacío, 'o' contorno, 'b' cuerpo, 'd' sombra, 'l' claro, 'e' ojo, 'w'
// blanco, 'p' rosa, 'y' amarillo, 'a' acento, 'r' rojo, 'k' negro, 'g' verde.

class Pet {
  const Pet(this.label, this.frames, this.colors, {required this.head});
  final String label;

  /// walk0, walk1, sit (dormir = sit con ojos cerrados).
  final Map<String, List<String>> frames;
  final Map<String, Color> colors;

  /// Columna y fila donde se apoya el gorro.
  final (int, int) head;

  int get rows => frames['sit']!.length;
}

List<String> _legs(List<String> top, List<String> legs) => [...top, ...legs];

const _catTop = [
  '..........o...o.',
  '.o.......opbbbpo',
  'obo......obdbdbo',
  'obo......obebebo',
  '.ob......olbpblo',
  '..ob......oaaao.',
  '..oooooooooooo..',
  '..obdbbdbbdbbo..',
  '..obbllllllbbo..',
  '..oooooooooooo..',
];

const _dogTop = [
  '.........oooo...',
  '........obbbbo..',
  '.o.....odbbebbo.',
  'obo....odbbbbbbo',
  '.ob....odbbbbbpo',
  '..o.....odaaao..',
  '..oooooooooooo..',
  '..obbddbbbbbbo..',
  '..obblllllbbbo..',
  '..oooooooooooo..',
];

const _duckTop = [
  '.........oooo...',
  '........obbbbo..',
  '........obbebo..',
  '........obbbbyyo',
  '.........obbbo..',
  'o.........obbo..',
  'oo.....ooobbbo..',
  'obooooobbbbbbo..',
  '.obbbddbbbbbbo..',
  '..ooollllllo....',
];

const _robotTop = [
  '..........a.....',
  '..........o.....',
  '.......ooooooo..',
  '.......obbbbbo..',
  '.......owewewo..',
  '.......obbbbbo..',
  '..oooooooooooo..',
  '..obdddddddbbo..',
  '..obbaaabbbbbo..',
  '..oooooooooooo..',
];

const _dragonTop = [
  '..........o..o..',
  '..o.o....obooboo',
  '.oddo....obbbbbo',
  'oddddo...obbebbo',
  '.oddo.o..obbbbyo',
  '..oo.ob..olllloo',
  '.....oooooooooo.',
  '....obbbbbbbbbo.',
  'oooobblllllbbbo.',
  '.....oooooooooo.',
];

final pets = <String, Pet>{
  'gato': Pet(
    'Gato',
    {
      'walk0': _legs(_catTop, ['...ob.....ob....', '...oo.....oo....']),
      'walk1': _legs(_catTop, ['..ob..ob.ob..ob.', '..oo..oo.oo..oo.']),
      'sit': _legs(_catTop, ['..obbo....obbo..', '..oooo....oooo..']),
    },
    const {
      'o': Color(0xff2b1d14),
      'b': Color(0xffe8913a),
      'd': Color(0xffb8642a),
      'l': Color(0xfff6d3a8),
      'e': Color(0xff1a1a1a),
      'p': Color(0xfff08a9a),
      'a': Color(0xff3a7bd5),
    },
    head: (12, 1),
  ),
  'perro': Pet(
    'Perro',
    {
      'walk0': _legs(_dogTop, ['...ob.....ob....', '...oo.....oo....']),
      'walk1': _legs(_dogTop, ['..ob..ob.ob..ob.', '..oo..oo.oo..oo.']),
      'sit': _legs(_dogTop, ['..obbo....obbo..', '..oooo....oooo..']),
    },
    const {
      'o': Color(0xff2a1a10),
      'b': Color(0xfff2e6d0),
      'd': Color(0xff9a5a2c),
      'l': Color(0xffffffff),
      'e': Color(0xff1a1a1a),
      'p': Color(0xff3a2418),
      'a': Color(0xffd23b3b),
    },
    head: (12, 0),
  ),
  'pato': Pet(
    'Pato',
    {
      'walk0': _legs(_duckTop, ['.....yy...yy....', '....yyy..yyy....']),
      'walk1': _legs(_duckTop, ['......yy.yy.....', '.....yyyyyy.....']),
      'sit': _legs(_duckTop, ['...oooooooo.....', '................']),
    },
    const {
      'o': Color(0xff3a3226),
      'b': Color(0xfffaf6ee),
      'd': Color(0xffd8d2c4),
      'l': Color(0xffece6d8),
      'e': Color(0xff111111),
      'y': Color(0xfff2a516),
    },
    head: (11, 0),
  ),
  'slime': Pet(
    'Slime',
    {
      'walk0': [
        '................',
        '................',
        '................',
        '................',
        '.....oooooo.....',
        '...oollllbboo...',
        '..olwlbbbbbbbo..',
        '.obbbbebbbebbbo.',
        '.obbbbbbbbbbbbo.',
        '.obbbbbbppbbbbo.',
        '..obbbbbbbbbbo..',
        '...oooooooooo...',
      ],
      'walk1': [
        '................',
        '................',
        '................',
        '................',
        '................',
        '................',
        '....oooooooo....',
        '..oollwlbbbboo..',
        '.obbbbebbbebbbo.',
        'obbbbbbbppbbbbbo',
        'obbbbbbbbbbbbbbo',
        '.oooooooooooooo.',
      ],
      'sit': [
        '................',
        '................',
        '................',
        '................',
        '................',
        '.....oooooo.....',
        '...oollllbboo...',
        '..olwlbbbbbbbo..',
        '.obbbbebbbebbbo.',
        '.obbbbbbbbbbbbo.',
        '.obbbbbbbbbbbbo.',
        '..oooooooooooo..',
      ],
    },
    const {
      'o': Color(0xff1f5c2e),
      'b': Color(0xff5fd17a),
      'l': Color(0xff9ff0b1),
      'w': Color(0xffffffff),
      'e': Color(0xff0f2a16),
      'p': Color(0xff2e8a46),
    },
    head: (8, 4),
  ),
  'robot': Pet(
    'Robot',
    {
      'walk0': _legs(_robotTop, ['....oo....oo....', '...oooo..oooo...']),
      'walk1': _legs(_robotTop, ['...oo......oo...', '..oooo....oooo..']),
      'sit': _legs(_robotTop, ['..oooooooooooo..', '................']),
    },
    const {
      'o': Color(0xff2a2f36),
      'b': Color(0xffaeb8c4),
      'd': Color(0xff7d8896),
      'w': Color(0xff9fe6ff),
      'e': Color(0xff1a6fa0),
      'a': Color(0xffff5a4e),
    },
    head: (10, 0),
  ),
  'dragon': Pet(
    'Dragón',
    {
      'walk0': _legs(_dragonTop, ['.....ob....ob...', '.....oo....oo...']),
      'walk1': _legs(_dragonTop, ['....ob..ob.ob.ob', '....oo..oo.oo.oo']),
      'sit': _legs(_dragonTop, ['....obbo...obbo.', '....oooo...oooo.']),
    },
    const {
      'o': Color(0xff1d3b2a),
      'b': Color(0xff4caf6e),
      'd': Color(0xff8e5cc7),
      'l': Color(0xffc8e6a0),
      'e': Color(0xff111111),
      'y': Color(0xffffb02e),
    },
    head: (12, 1),
  ),
};

/// Gorros: (filas, colores). Se dibujan centrados sobre `Pet.head`.
const _hats = <Hat, List<String>>{
  Hat.santa: ['...rw', '..rr.', '.rrr.', 'rrrrr', 'wwwww'],
  Hat.fiesta: ['..y..', '..a..', '.aya.', 'ayaya'],
  Hat.bruja: ['...k.', '..kk.', '.kkk.', '.kak.', 'kkkkkkk'],
  Hat.flor: ['.y.y.', 'yyyyy', '.yay.', '..g..'],
  Hat.corazon: ['.r.r.', 'rrrrr', '.rrr.', '..r..', '.....'],
  Hat.trebol: ['.g.g.', 'ggggg', '.ggg.', '..k..'],
  Hat.sol: ['y.y.y', '.yyy.', 'yyyyy', '.yyy.', 'y.y.y'],
};

const _hatColors = {
  'r': Color(0xffd8343f),
  'w': Color(0xfffafafa),
  'y': Color(0xffffc928),
  'a': Color(0xff3aa0e8),
  'k': Color(0xff2b1f3a),
  'g': Color(0xff3fae4f),
};

/// Comportamiento de la mascota: camina, se para, se sienta, duerme (más de
/// noche), salta de vez en cuando y al hacerle clic.
class PetSim {
  PetSim([Random? r]) : _r = r ?? Random();
  final Random _r;
  double x = 40, dir = 1, jump = 0, _vy = 0, _left = 4, _walkT = 0;
  String state = 'walk';
  final hearts = <({double x, double y, double age})>[];
  final zs = <({double x, double y, double age})>[];
  var _zT = 0.0;

  static const scale = 2.0, width = 16 * scale, speed = 22.0;

  int get frame => (_walkT * 4).floor() % 2;

  void step(double dt, double maxW) {
    if (maxW < width) return;
    _left -= dt;
    // Salto (física simple).
    if (jump > 0 || _vy != 0) {
      _vy -= 260 * dt;
      jump = max(0, jump + _vy * dt);
      if (jump == 0) _vy = 0;
    }
    switch (state) {
      case 'walk':
        _walkT += dt;
        x += dir * speed * dt;
        if (x < 2 || x > maxW - width - 2) {
          dir = x < 2 ? 1 : -1;
          x = x.clamp(2, maxW - width - 2);
        }
        if (_r.nextDouble() < dt * .08) hop();
        if (_left <= 0) _next(['idle', 'idle', 'sit', 'walk']);
      case 'idle':
        if (_left <= 0) _next(['walk', 'walk', 'sit']);
      case 'sit':
        if (_left <= 0) _next(['walk', 'sleep', 'idle']);
      case 'sleep':
        _zT += dt;
        if (_zT > 1.2) {
          _zT = 0;
          zs.add((x: x + (dir > 0 ? width - 4 : 4), y: 0, age: 0));
        }
        if (_left <= 0) _next(['walk', 'sit']);
    }
    x = x.clamp(2, max(2, maxW - width - 2));
    _age(hearts, dt);
    _age(zs, dt);
  }

  void _age(List<({double x, double y, double age})> l, double dt) {
    for (var i = l.length - 1; i >= 0; i--) {
      final h = l[i];
      if (h.age + dt > 2.2) {
        l.removeAt(i);
      } else {
        l[i] = (x: h.x + sin(h.age * 5) * .3, y: h.y + 14 * dt, age: h.age + dt);
      }
    }
  }

  void _next(List<String> options) {
    final night = DateTime.now().hour >= 23 || DateTime.now().hour < 6;
    var s = options[_r.nextInt(options.length)];
    if (night && s != 'sleep' && _r.nextDouble() < .4) s = 'sleep';
    state = s;
    _left = switch (s) {
      'walk' => 4 + _r.nextDouble() * 8,
      'idle' => 1 + _r.nextDouble() * 2,
      'sit' => 3 + _r.nextDouble() * 6,
      _ => 12 + _r.nextDouble() * 20,
    };
    if (s == 'walk' && _r.nextBool()) dir = -dir;
  }

  void hop() {
    if (jump == 0) _vy = 70;
  }

  /// Festejo (commit o push): se despierta, salta y suelta tres corazones.
  void cheer() {
    zs.clear();
    state = 'idle';
    _left = 2;
    hop();
    for (var i = 0; i < 3; i++) {
      hearts.add((x: x + width / 2 + (i - 1) * 8, y: -i * 6.0, age: 0));
    }
  }

  /// Clic: si cae sobre la mascota, salta, se despierta y suelta un corazón.
  void pet(Offset p, double height) {
    final top = height - 3 - 12 * scale - jump;
    if (p.dx < x - 4 || p.dx > x + width + 4 || p.dy < top - 6) return;
    if (state == 'sleep') zs.clear();
    state = 'idle';
    _left = 1.5;
    hop();
    hearts.add((x: x + width / 2, y: 0, age: 0));
  }
}

class PetPainter extends CustomPainter {
  PetPainter(this.pet, this.sim, this.clock, {this.hat = Hat.none, this.still = false}) : super(repaint: still ? null : clock);
  final Pet pet;
  final PetSim sim;
  final DecorClock clock;
  final Hat hat;
  final bool still;

  @override
  void paint(Canvas c, Size s) {
    const k = PetSim.scale;
    final rows = pet.rows;
    final name = still ? 'sit' : (sim.state == 'walk' ? 'walk${sim.frame}' : 'sit');
    final sprite = pet.frames[name]!;
    final top = s.height - 3 - rows * k - sim.jump;
    final x0 = sim.x;
    final flip = sim.dir < 0;
    final sleeping = !still && sim.state == 'sleep';
    // Sombra.
    c.drawOval(
      Rect.fromCenter(center: Offset(x0 + 8 * k, s.height - 3), width: 13 * k - sim.jump * .3, height: 3),
      Paint()..color = Colors.black.withValues(alpha: .25),
    );
    drawSprite(c, sprite, pet.colors, Offset(x0, top), k, flip: flip, closedEyes: sleeping);
    final h = _hats[hat];
    if (h != null) {
      final (hx, hy) = pet.head;
      final w = h.map((r) => r.length).reduce(max);
      final col = flip ? 15 - hx : hx;
      drawSprite(c, h, _hatColors, Offset(x0 + (col - w / 2 + .5).roundToDouble() * k, top + (hy - h.length) * k), k, flip: flip);
    }
    final ink = Gh.textSecondary;
    for (final z in sim.zs) {
      _text(c, 'z', Offset(z.x, top - 4 - z.y), 9 + z.age * 3, ink.withValues(alpha: (1 - z.age / 2.2).clamp(0, 1)));
    }
    for (final hrt in sim.hearts) {
      _heart(c, Offset(hrt.x, top - 6 - hrt.y), 5, const Color(0xffe8475f).withValues(alpha: (1 - hrt.age / 2.2).clamp(0, 1)));
    }
  }

  @override
  bool hitTest(Offset position) => position.dx >= sim.x - 4 && position.dx <= sim.x + PetSim.width + 4;

  @override
  bool shouldRepaint(PetPainter old) => old.pet != pet || old.hat != hat || old.still != still;
}

/// Dibuja un sprite de caracteres con píxeles de [k] de lado.
void drawSprite(Canvas c, List<String> rows, Map<String, Color> colors, Offset at, double k, {bool flip = false, bool closedEyes = false}) {
  final paint = Paint()..isAntiAlias = false;
  final w = rows.map((r) => r.length).reduce(max);
  for (var y = 0; y < rows.length; y++) {
    final row = rows[y];
    for (var x = 0; x < row.length; x++) {
      final ch = row[x];
      final color = colors[ch];
      if (color == null) continue;
      final px = flip ? w - 1 - x : x;
      if (ch == 'e' && closedEyes) {
        // Ojo cerrado: una rayita en la mitad de abajo del píxel.
        paint.color = colors['o'] ?? color;
        c.drawRect(Rect.fromLTWH(at.dx + px * k, at.dy + y * k + k * .55, k, k * .45), paint);
        continue;
      }
      paint.color = color;
      c.drawRect(Rect.fromLTWH(at.dx + px * k, at.dy + y * k, k + .02, k + .02), paint);
    }
  }
}

// ---------------------------------------------------------------------------
// Escenas.

class ScenePainter extends CustomPainter {
  ScenePainter(this.scene, this.clock, {this.strip = false, this.still = false})
    : colorsKey = Object.hash(Gh.bg, Gh.blue, Gh.textSecondary),
      super(repaint: still ? null : clock);
  final Scene scene;
  final DecorClock clock;

  /// Tira de la barra superior (baja) en vez de fondo de pantalla vacía.
  final bool strip;
  final bool still;

  /// Los colores salen de [Gh] al pintar: si cambia la paleta, hay que repintar.
  final int colorsKey;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final p = _P(canvas, size, still ? 3.0 : clock.t, strip);
    switch (scene) {
      case Scene.grafo:
        p.grafo();
      case Scene.ciudad:
        p.ciudad();
      case Scene.bosque:
        p.bosque();
      case Scene.olas:
        p.olas();
      case Scene.atardecer:
        p.atardecer();
      case Scene.nubes:
        p.nubes();
      case Scene.desierto:
        p.desierto();
      case Scene.aurora:
        p.aurora();
      case Scene.retro:
        p.retro();
      case Scene.arcade:
        p.arcade();
      case Scene.aventura:
        p.aventura();
      case Scene.espacio:
        p.espacio();
      case Scene.halloween:
        p.halloween();
      case Scene.muertos:
        p.muertos();
      case Scene.navidad:
        p.navidad();
      case Scene.anioNuevo:
        p.anioNuevo();
      case Scene.sanValentin:
        p.sanValentin();
      case Scene.carnaval:
        p.carnaval();
      case Scene.sanPatricio:
        p.sanPatricio();
      case Scene.diaTierra:
        p.diaTierra();
      case Scene.intiRaymi:
        p.intiRaymi();
      case Scene.cumple:
        p.cumple();
    }
    if (!strip) p.veil();
    canvas.restore();
  }

  @override
  bool shouldRepaint(ScenePainter old) => old.scene != scene || old.strip != strip || old.still != still || old.colorsKey != colorsKey;
}

/// Pinceles y escenas. En una tira (barra superior) todo va abajo y chico; en
/// un fondo, lo grande va en el tercio de abajo y el centro queda despejado.
class _P {
  _P(this.c, this.s, this.t, this.strip);
  final Canvas c;
  final Size s;
  final double t;
  final bool strip;

  double get w => s.width;
  double get h => s.height;

  /// Altura de "suelo": en la tira, el borde de abajo; en un fondo, el 82 %.
  double get ground => strip ? h : h * .86;

  /// Mezcla [col] con el fondo: los fondos van apagados para no competir.
  Color tint(Color col, double amount) => Color.lerp(Gh.bg, col, amount)!;
  Paint fill(Color col) => Paint()..color = col;

  Random rnd(int seed) => Random(seed);

  /// Parpadeo suave entre [lo] y 1.
  double twinkle(double phase, [double speed = 1.3, double lo = .25]) => lo + (1 - lo) * (.5 + .5 * sin(t * speed + phase));

  void veil() {
    // Velo radial del color de fondo en el centro, donde va el texto.
    final r = Rect.fromCenter(center: Offset(w / 2, h / 2), width: min(w, 560), height: min(h, 260));
    c.drawOval(
      r.inflate(40),
      Paint()
        ..shader = ui.Gradient.radial(r.center, r.longestSide / 2 + 40, [Gh.bg.withValues(alpha: .92), Gh.bg.withValues(alpha: 0)]),
    );
  }

  void stars(int seed, int n, {double maxY = .55, Color? color, double size = 1.4}) {
    final r = rnd(seed);
    final col = color ?? Gh.text;
    for (var i = 0; i < n; i++) {
      final x = r.nextDouble() * w, y = r.nextDouble() * h * maxY, ph = r.nextDouble() * 6.28;
      final a = twinkle(ph, .8 + r.nextDouble() * 1.5, .15);
      c.drawCircle(Offset(x, y), size * (.6 + r.nextDouble() * .7), fill(col.withValues(alpha: a * (strip ? .55 : .45))));
    }
  }

  Path wave(double base, double amp, double freq, double phase, {double? bottom}) {
    final p = Path()..moveTo(0, bottom ?? h);
    for (var x = 0.0; x <= w + 8; x += 8) {
      p.lineTo(x, base + amp * sin(x * freq + phase) + amp * .4 * sin(x * freq * 2.3 + phase * 1.7));
    }
    return p
      ..lineTo(w, bottom ?? h)
      ..close();
  }

  void pine(double x, double base, double height, Color col) {
    final p = Path()
      ..moveTo(x, base - height)
      ..lineTo(x - height * .32, base - height * .45)
      ..lineTo(x - height * .16, base - height * .45)
      ..lineTo(x - height * .4, base - height * .05)
      ..lineTo(x + height * .4, base - height * .05)
      ..lineTo(x + height * .16, base - height * .45)
      ..lineTo(x + height * .32, base - height * .45)
      ..close();
    c.drawPath(p, fill(col));
    c.drawRect(Rect.fromLTWH(x - height * .04, base - height * .06, height * .08, height * .06), fill(col));
  }

  void moon(Offset at, double r, Color col, {bool crescent = true}) {
    c.drawCircle(at, r * 1.9, fill(col.withValues(alpha: .06)));
    if (!crescent) {
      c.drawCircle(at, r, fill(col));
      return;
    }
    final p = Path.combine(
      PathOperation.difference,
      Path()..addOval(Rect.fromCircle(center: at, radius: r)),
      Path()..addOval(Rect.fromCircle(center: at + Offset(r * .45, -r * .2), radius: r * .85)),
    );
    c.drawPath(p, fill(col));
  }

  void cloud(Offset at, double r, Color col) {
    final p = Paint()..color = col;
    c.drawCircle(at, r, p);
    c.drawCircle(at + Offset(r * .9, r * .2), r * .75, p);
    c.drawCircle(at + Offset(-r * .9, r * .25), r * .7, p);
    c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTRB(at.dx - r * 1.5, at.dy, at.dx + r * 1.6, at.dy + r * .8), Radius.circular(r * .4)), p);
  }

  void heart(Offset at, double r, Color col) => _heart(c, at, r, col);

  /// Bloque "pixel": rectángulo alineado a una grilla de [k].
  void px(double x, double y, double ww, double hh, Color col, [double k = 4]) {
    c.drawRect(Rect.fromLTWH((x / k).floorToDouble() * k, (y / k).floorToDouble() * k, (ww / k).ceilToDouble() * k, (hh / k).ceilToDouble() * k), fill(col));
  }

  /// Partículas que caen (nieve, confeti, pétalos) con vaivén.
  void falling(int seed, int n, void Function(Offset at, double rot, Random r) draw, {double speed = 18}) {
    final r = rnd(seed);
    for (var i = 0; i < n; i++) {
      final x0 = r.nextDouble() * w, sp = speed * (.6 + r.nextDouble() * .8), ph = r.nextDouble() * 100;
      final y = (ph * 7 + t * sp) % (h + 20) - 10;
      final x = x0 + sin(t * .8 + ph) * 10;
      draw(Offset(x, y), t * (r.nextDouble() * 2 - 1) * 2 + ph, Random(i + seed));
    }
  }

  /// Partículas que suben (corazones, globos).
  void rising(int seed, int n, void Function(Offset at, Random r) draw, {double speed = 14}) {
    final r = rnd(seed);
    for (var i = 0; i < n; i++) {
      final x0 = r.nextDouble() * w, sp = speed * (.6 + r.nextDouble() * .8), ph = r.nextDouble() * 100;
      final y = h + 10 - (ph * 9 + t * sp) % (h + 30);
      draw(Offset(x0 + sin(t * .7 + ph) * 12, y), Random(i + seed * 7));
    }
  }

  // --- escenas ------------------------------------------------------------

  /// La de fábrica: ramas de commits como constelación, con un pulso que viaja.
  void grafo() {
    if (!strip) stars(1, 40);
    final acc = Gh.blue;
    final lanes = strip ? [h - 9.0] : [ground - 60, ground - 30, ground];
    final line = Paint()
      ..color = tint(acc, strip ? .55 : .5)
      ..strokeWidth = strip ? 1.5 : 2.2
      ..style = PaintingStyle.stroke;
    final dot = fill(tint(Gh.link, strip ? .8 : .6));
    for (var i = 0; i < lanes.length; i++) {
      c.drawLine(Offset(0, lanes[i]), Offset(w, lanes[i]), line);
    }
    final r = rnd(7);
    final step = strip ? 46.0 : 70.0;
    for (var x = 20.0; x < w; x += step) {
      final lane = r.nextInt(lanes.length);
      c.drawCircle(Offset(x, lanes[lane]), strip ? 3 : 4.5, dot);
      if (lanes.length > 1 && r.nextDouble() < .5) {
        // Merge: curva de una rama a la otra.
        final to = (lane + 1) % lanes.length;
        final path = Path()
          ..moveTo(x, lanes[lane])
          ..cubicTo(x + step * .5, lanes[lane], x + step * .5, lanes[to], x + step, lanes[to]);
        c.drawPath(path, line);
      }
    }
    // Pulso: un commit nuevo viajando por la rama principal.
    final px0 = (t * 60) % (w + 80) - 40;
    final y = lanes.last;
    c.drawCircle(Offset(px0, y), strip ? 6 : 9, fill(acc.withValues(alpha: .18)));
    c.drawCircle(Offset(px0, y), strip ? 2.5 : 3.5, fill(Gh.link.withValues(alpha: .9)));
  }

  void ciudad() {
    stars(2, strip ? 12 : 50, maxY: strip ? .5 : .45);
    if (!strip) moon(Offset(w * .82, h * .18), 18, tint(const Color(0xfffff3c4), .8));
    for (final (layer, seed) in [(0, 3), (1, 4)]) {
      final r = rnd(seed);
      final col = tint(layer == 0 ? Gh.textMuted : Gh.border, layer == 0 ? .5 : .9);
      var x = -10.0;
      while (x < w) {
        final bw = (strip ? 10 : 22) + r.nextDouble() * (strip ? 16 : 40);
        final bh = (strip ? 10 : 50) + r.nextDouble() * (strip ? 22 : 150) * (layer == 0 ? 1 : .7);
        final top = ground - bh;
        c.drawRect(Rect.fromLTWH(x, top, bw, bh), fill(col));
        if (layer == 1) {
          // Ventanas que se prenden y apagan despacio.
          final win = strip ? 2.0 : 4.0;
          for (var wy = top + win * 1.5; wy < ground - win * 2; wy += win * 2.5) {
            for (var wx = x + win; wx < x + bw - win; wx += win * 2.2) {
              final on = sin(wx * 12.9 + wy * 78.2 + (t * .15).floor() * 3.1) > .55;
              if (on) c.drawRect(Rect.fromLTWH(wx, wy, win, win), fill(const Color(0xffffd36b).withValues(alpha: strip ? .55 : .45)));
            }
          }
        }
        x += bw + (layer == 0 ? 2 : 4);
      }
    }
  }

  void bosque() {
    stars(5, strip ? 10 : 35, maxY: .4);
    final layers = strip ? 2 : 3;
    for (var l = 0; l < layers; l++) {
      final r = rnd(10 + l);
      final col = tint(Color.lerp(const Color(0xff2e6b3a), Gh.border, l / layers * .8)!, .35 + l * .25);
      final hgt = strip ? 22.0 - l * 4 : 130.0 - l * 30;
      for (var x = -20.0; x < w + 20; x += hgt * (.35 + r.nextDouble() * .3)) {
        pine(x, ground + (strip ? 0 : l * 6), hgt * (.6 + r.nextDouble() * .5), col);
      }
    }
    // Luciérnagas.
    final r = rnd(20);
    for (var i = 0; i < (strip ? 7 : 22); i++) {
      final bx = r.nextDouble() * w, by = strip ? h * (.3 + r.nextDouble() * .5) : h * (.5 + r.nextDouble() * .4), ph = r.nextDouble() * 9;
      final at = Offset(bx + sin(t * .4 + ph) * 18, by + cos(t * .55 + ph) * 8);
      final a = twinkle(ph * 3, 2.2, 0);
      c.drawCircle(at, 6, fill(const Color(0xffd9ff6a).withValues(alpha: a * .12)));
      c.drawCircle(at, 1.6, fill(const Color(0xffeaffa0).withValues(alpha: a * .9)));
    }
  }

  void olas() {
    if (!strip) {
      stars(6, 30, maxY: .35);
      final m = Offset(w * .2, h * .2);
      moon(m, 16, tint(const Color(0xfff2f6ff), .8), crescent: false);
      // Reflejo de la luna.
      for (var i = 0; i < 6; i++) {
        final y = ground - 70 + i * 12;
        final ww = 30 - i * 3 + sin(t * 2 + i) * 6;
        c.drawRect(Rect.fromCenter(center: Offset(m.dx, y), width: ww, height: 2), fill(Colors.white.withValues(alpha: .12)));
      }
    }
    final base = strip ? h - 14 : ground - 80;
    for (var i = 0; i < 3; i++) {
      final col = tint(Color.lerp(const Color(0xff1d6f8a), const Color(0xff0c3a55), i / 2)!, .35 + i * .2);
      c.drawPath(wave(base + i * (strip ? 4 : 26), strip ? 2.5 : 8, .018 + i * .004, t * (.8 + i * .3) * (i.isEven ? 1 : -1)), fill(col));
    }
    // Un pez que salta cada tanto.
    final cyc = (t % 9) / 9;
    if (cyc < .25 && !strip) {
      final k = cyc / .25;
      final fx = w * .65 + k * 90, fy = base + 10 - sin(k * pi) * 60;
      final fish = Path()
        ..addOval(Rect.fromCenter(center: Offset(fx, fy), width: 18, height: 8))
        ..moveTo(fx - 8, fy)
        ..lineTo(fx - 15, fy - 5)
        ..lineTo(fx - 15, fy + 5)
        ..close();
      c.drawPath(fish, fill(tint(const Color(0xffff9a52), .8)));
    }
  }

  void atardecer() {
    final sunC = Offset(w * .7, ground - (strip ? 6 : 40));
    final sunR = strip ? 16.0 : 70.0;
    for (var i = 4; i > 0; i--) {
      c.drawCircle(sunC, sunR * (1 + i * .35), fill(const Color(0xffff8a3d).withValues(alpha: .035)));
    }
    c.drawCircle(sunC, sunR, fill(tint(const Color(0xffff9a4a), .65)));
    if (!strip) {
      // Franjas del sol (horizontales, como un sol de los 80 pero tranquilo).
      for (var i = 0; i < 4; i++) {
        c.drawRect(Rect.fromLTWH(sunC.dx - sunR, sunC.dy + 10 + i * 12, sunR * 2, 3 + i.toDouble()), fill(Gh.bg.withValues(alpha: .7)));
      }
    }
    for (var i = 0; i < 2; i++) {
      c.drawPath(wave(ground - (strip ? 8 : 50) + i * (strip ? 5 : 30), strip ? 3 : 14, .006 + i * .003, i * 2.0), fill(tint(const Color(0xff4a2338), .45 + i * .3)));
    }
    // Pájaros.
    final r = rnd(30);
    final bird = Paint()
      ..color = tint(Gh.text, .45)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    for (var i = 0; i < (strip ? 2 : 5); i++) {
      final sp = 12 + r.nextDouble() * 10, y = strip ? 8 + r.nextDouble() * 14 : h * (.15 + r.nextDouble() * .3);
      final x = (r.nextDouble() * w + t * sp) % (w + 40) - 20;
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

  void nubes() {
    stars(8, strip ? 10 : 40, maxY: .6);
    if (!strip) moon(Offset(w * .78, h * .2), 22, tint(const Color(0xfffff6d8), .85));
    final r = rnd(9);
    for (var i = 0; i < (strip ? 4 : 7); i++) {
      final sp = 4 + r.nextDouble() * 6, rad = strip ? 6 + r.nextDouble() * 5 : 18 + r.nextDouble() * 22;
      final y = strip ? 12 + r.nextDouble() * (h - 26) : h * (.25 + r.nextDouble() * .6);
      final x = (r.nextDouble() * w + t * sp) % (w + rad * 5) - rad * 2.5;
      cloud(Offset(x, y), rad, tint(Color.lerp(Gh.blue, Colors.white, .6)!, .14 + r.nextDouble() * .1));
    }
  }

  void desierto() {
    final sun = Offset(w * .82, strip ? h * .35 : h * .22);
    c.drawCircle(sun, strip ? 9 : 26, fill(tint(const Color(0xffffc04d), .7)));
    for (var i = 0; i < 3; i++) {
      c.drawPath(wave(ground - (strip ? 10 : 70) + i * (strip ? 4 : 28), strip ? 3 : 16, .004 + i * .002, i * 1.7), fill(tint(const Color(0xffd9a45a), .25 + i * .18)));
    }
    final cactus = tint(const Color(0xff3f7a43), .6);
    final r = rnd(12);
    for (var i = 0; i < (strip ? 3 : 4); i++) {
      final x = w * (.1 + r.nextDouble() * .8), hh = strip ? 16.0 : 50 + r.nextDouble() * 30, wd = hh * .16;
      final base = ground - (strip ? 1 : 10);
      c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x - wd / 2, base - hh, wd, hh), Radius.circular(wd / 2)), fill(cactus));
      c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x - wd * 2, base - hh * .65, wd * .9, hh * .35), Radius.circular(wd / 2)), fill(cactus));
      c.drawRect(Rect.fromLTWH(x - wd * 2, base - hh * .38, wd * 1.6, wd * .8), fill(cactus));
    }
    // Planta rodadora de vez en cuando.
    final k = (t % 14) / 14;
    if (k < .5) {
      final x = k * 2 * (w + 40) - 20, y = ground - (strip ? 5 : 16) - (sin(k * 40).abs() * (strip ? 3 : 8));
      final p = Paint()
        ..color = tint(const Color(0xff9a7a4a), .7)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1;
      for (var a = 0.0; a < 6.28; a += .9) {
        c.drawCircle(Offset(x + cos(a + t * 4) * 2, y + sin(a + t * 4) * 2), strip ? 4 : 8, p);
      }
    }
  }

  void aurora() {
    stars(13, strip ? 12 : 45, maxY: .7);
    for (var i = 0; i < 3; i++) {
      final col = [const Color(0xff3cf0a0), const Color(0xff4fc3ff), const Color(0xffa06bff)][i];
      final path = Path();
      final base = strip ? h * .3 + i * 4 : h * (.18 + i * .07);
      for (var x = 0.0; x <= w; x += 6) {
        final y = base + sin(x * .01 + t * .35 + i) * (strip ? 4 : 22) + sin(x * .023 - t * .2) * (strip ? 2 : 10);
        x == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
      }
      c.drawPath(
        path,
        Paint()
          ..color = col.withValues(alpha: strip ? .22 : .16)
          ..style = PaintingStyle.stroke
          ..strokeWidth = strip ? 5 : 26
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
      );
    }
    // Montañas nevadas.
    final r = rnd(14);
    for (var x = -30.0; x < w + 30;) {
      final mw = strip ? 30 + r.nextDouble() * 30 : 120 + r.nextDouble() * 120, mh = strip ? 12 + r.nextDouble() * 12 : 60 + r.nextDouble() * 90;
      final peak = Offset(x + mw / 2, ground - mh);
      c.drawPath(
        Path()
          ..moveTo(x, ground)
          ..lineTo(peak.dx, peak.dy)
          ..lineTo(x + mw, ground)
          ..close(),
        fill(tint(const Color(0xff2a4a5a), .55)),
      );
      c.drawPath(
        Path()
          ..moveTo(peak.dx - mw * .12, peak.dy + mh * .24)
          ..lineTo(peak.dx, peak.dy)
          ..lineTo(peak.dx + mw * .12, peak.dy + mh * .24)
          ..lineTo(peak.dx + mw * .04, peak.dy + mh * .18)
          ..lineTo(peak.dx - mw * .03, peak.dy + mh * .22)
          ..close(),
        fill(tint(Colors.white, .55)),
      );
      x += mw * .7;
    }
  }

  /// Terminal de fósforo verde: líneas de barrido, montañas en escalones y un
  /// prompt con cursor que parpadea.
  void retro() {
    final green = const Color(0xff39ff6a);
    final k = strip ? 3.0 : 6.0;
    // Montañas en escalones.
    final r = rnd(15);
    for (var x = 0.0; x < w; x += k) {
      final hh = (strip ? 8 : 60) + (sin(x * .02) + sin(x * .047 + 1)) * (strip ? 4 : 30) + r.nextDouble() * k;
      px(x, ground - hh, k, hh, tint(green, .16 + (sin(x * .02) > 0 ? .06 : 0)), k);
    }
    // Sol en píxeles.
    final sc = Offset(w * .75, strip ? h * .4 : h * .3);
    final sr = strip ? 9.0 : 40.0;
    for (var y = -sr; y < sr; y += k) {
      final half = sqrt(max(0, sr * sr - y * y));
      px(sc.dx - half, sc.dy + y, half * 2, k, tint(green, .35), k);
    }
    if (!strip) {
      // Prompt.
      final lines = [r'$ git log --oneline', 'a1f3c2e  el pasado', r'$ _'];
      for (var i = 0; i < lines.length; i++) {
        var text = lines[i];
        if (i == 2) text = (t * 1.6).floor().isEven ? r'$ █' : r'$ ';
        _text(c, text, Offset(28, 28 + i * 18.0), 13, tint(green, .55), mono: true, anchorLeft: true);
      }
    }
    // Líneas de barrido.
    final scan = Paint()..color = Colors.black.withValues(alpha: .18);
    for (var y = 0.0; y < h; y += 3) {
      c.drawRect(Rect.fromLTWH(0, y, w, 1), scan);
    }
    final band = (t * 40) % (h + 60) - 30;
    c.drawRect(Rect.fromLTWH(0, band, w, 24), fill(green.withValues(alpha: .03)));
  }

  /// Sala de juegos: piso de neón en perspectiva que avanza, sol a franjas y
  /// montañas de contorno.
  void arcade() {
    final pink = const Color(0xffff3fa4), cyan = const Color(0xff36e7ff);
    stars(16, strip ? 14 : 50, maxY: .5, color: const Color(0xffffe9ff));
    final horizon = strip ? h * .55 : h * .58;
    final sun = Offset(w * .5, horizon);
    final sr = strip ? 14.0 : 80.0;
    c.save();
    c.clipRect(Rect.fromLTRB(0, 0, w, horizon));
    c.drawCircle(
      sun,
      sr,
      Paint()..shader = ui.Gradient.linear(sun - Offset(0, sr), sun, [const Color(0xffffd35a).withValues(alpha: .6), pink.withValues(alpha: .55)]),
    );
    for (var i = 0; i < 6; i++) {
      final y = sun.dy - sr * .55 + i * sr * .1;
      c.drawRect(Rect.fromLTWH(sun.dx - sr, y, sr * 2, 1.5 + i * .7), fill(Gh.bg));
    }
    c.restore();
    // Montañas de contorno.
    final mtn = Path()..moveTo(0, horizon);
    final r = rnd(17);
    for (var x = 0.0; x <= w; x += strip ? 14 : 40) {
      mtn.lineTo(x, horizon - (strip ? 2 + r.nextDouble() * 9 : 10 + r.nextDouble() * 60));
    }
    mtn.lineTo(w, horizon);
    c.drawPath(mtn, fill(Gh.bg));
    c.drawPath(
      mtn,
      Paint()
        ..color = cyan.withValues(alpha: .5)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
    // Piso.
    final grid = Paint()
      ..color = pink.withValues(alpha: .45)
      ..strokeWidth = 1;
    final depth = h - horizon;
    for (var i = 0; i < 10; i++) {
      final k = ((i + (t * .6) % 1) / 10);
      final y = horizon + depth * k * k;
      c.drawLine(Offset(0, y), Offset(w, y), grid..color = pink.withValues(alpha: .15 + .4 * k));
    }
    for (var i = -12; i <= 12; i++) {
      final x0 = w / 2 + i * (w / 24);
      c.drawLine(Offset(w / 2 + i * 6.0, horizon), Offset(w / 2 + (x0 - w / 2) * 3, h), grid..color = pink.withValues(alpha: .3));
    }
  }

  /// Aventura de 16 bits: colinas en capas, nubes en píxeles, un castillo y un
  /// caballerito original que camina por el sendero.
  void aventura() {
    final k = strip ? 2.0 : 4.0;
    // Nubes en píxeles.
    final r = rnd(18);
    for (var i = 0; i < (strip ? 3 : 5); i++) {
      final sp = 5 + r.nextDouble() * 5;
      final cw = (strip ? 14 : 48) + r.nextDouble() * (strip ? 10 : 30);
      final y = strip ? 6 + r.nextDouble() * 12 : h * (.08 + r.nextDouble() * .3);
      final x = (r.nextDouble() * w + t * sp) % (w + cw * 2) - cw;
      final col = tint(Colors.white, .22);
      px(x, y, cw, k * 2, col, k);
      px(x + k * 2, y - k * 2, cw - k * 4, k * 2, col, k);
      px(x + cw * .3, y - k * 4, cw * .35, k * 2, col, k);
    }
    // Colinas.
    final hills = [(const Color(0xff4c8a3a), .3, 70.0, .011), (const Color(0xff3a7030), .5, 40.0, .017), (const Color(0xff2c5a26), .75, 14.0, .023)];
    for (var i = 0; i < hills.length; i++) {
      final (col, a, off, f) = hills[i];
      for (var x = 0.0; x < w; x += k) {
        final top = ground - (strip ? off * .18 + 4 : off) - sin(x * f + i * 2) * (strip ? 3 : 18);
        px(x, top, k, ground - top + k, tint(col, a), k);
      }
    }
    // Castillo.
    final cx = w * .78, cb = ground - (strip ? 12 : 70);
    final stone = tint(const Color(0xff8c8c9a), .55), roof = tint(const Color(0xffb0403a), .6);
    final u = strip ? 2.0 : 5.0;
    px(cx, cb - u * 8, u * 10, u * 8, stone, k);
    px(cx - u * 2, cb - u * 12, u * 3, u * 12, stone, k);
    px(cx + u * 9, cb - u * 12, u * 3, u * 12, stone, k);
    for (final tx in [cx - u * 2, cx + u * 9]) {
      px(tx - u * .5, cb - u * 14, u * 4, u * 2, roof, k);
      px(tx + u * .5, cb - u * 15, u * 2, u, roof, k);
    }
    px(cx + u * 4, cb - u * 3, u * 2, u * 3, tint(Gh.bg, 1), k);
    // Bandera que flamea.
    px(cx + u * 10, cb - u * 19, u * .5, u * 5, stone, k);
    px(cx + u * 10.5, cb - u * (19 - (sin(t * 4) > 0 ? .5 : 0)), u * 2.5, u * 1.5, tint(Gh.blue, .9), k);
    // Caballerito: 8x8, capa del color de acento.
    if (!strip) {
      const knight = ['..kkk...', '.kssk...', '.kkkk...', 'aakkkk..', 'aakkkkm.', '.akkk.m.', '.k..k...', '.k..k...'];
      final kx = (t * 14) % (w * .7), ky = ground - 8 * 4.0 - 6;
      final step = (t * 4).floor().isEven;
      final rows = [...knight.take(6), if (step) '.k...k..' else '..k.k...', if (step) 'kk...kk.' else '.kk.kk..'];
      drawSprite(c, rows, {'k': tint(const Color(0xffc9ccd6), .9), 's': const Color(0xfff0c8a0), 'a': Gh.blue, 'm': const Color(0xffe0e0e0)}, Offset(kx, ky), 4);
    }
  }

  void espacio() {
    stars(19, strip ? 25 : 110, maxY: 1, size: 1.1);
    final pl = Offset(w * (strip ? .85 : .78), strip ? h * .45 : h * .32);
    final pr = strip ? 10.0 : 44.0;
    c.drawCircle(pl, pr, Paint()..shader = ui.Gradient.radial(pl - Offset(pr * .4, pr * .4), pr * 1.4, [tint(const Color(0xffc49bff), .75), tint(const Color(0xff3a2a6a), .6)]));
    final ring = Paint()
      ..color = tint(const Color(0xffffe1a8), .5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strip ? 1.5 : 4;
    c.save();
    c.translate(pl.dx, pl.dy);
    c.rotate(-.35);
    c.drawOval(Rect.fromCenter(center: Offset.zero, width: pr * 3.2, height: pr * .8), ring);
    c.restore();
    // Luna que orbita.
    final a = t * .3;
    c.drawCircle(pl + Offset(cos(a) * pr * 2.2, sin(a) * pr * .7), strip ? 2 : 6, fill(tint(Colors.white, .5)));
    // Cometa cada tanto.
    final k = (t % 11) / 11;
    if (k < .3) {
      final p0 = Offset(-40 + k / .3 * (w + 80), (strip ? 6 : h * .1) + k / .3 * (strip ? 14 : h * .3));
      c.drawLine(
        p0,
        p0 - const Offset(50, 16),
        Paint()
          ..shader = ui.Gradient.linear(p0, p0 - const Offset(50, 16), [Colors.white.withValues(alpha: .8), Colors.white.withValues(alpha: 0)])
          ..strokeWidth = 2,
      );
    }
  }

  void halloween() {
    final orange = const Color(0xffff8a1f);
    if (!strip) {
      moon(Offset(w * .8, h * .2), 34, tint(const Color(0xfffff0b3), .85), crescent: false);
      stars(21, 30, maxY: .5);
      // Telarañas en las esquinas de arriba.
      for (final right in [false, true]) {
        final o = Offset(right ? w : 0, 0);
        final web = Paint()
          ..color = tint(Gh.text, .3)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1;
        for (var i = 0; i <= 5; i++) {
          final a = (right ? pi / 2 : 0) + i * (pi / 2) / 5;
          c.drawLine(o, o + Offset(cos(a) * 110, sin(a) * 110), web);
        }
        for (var ring = 1; ring <= 4; ring++) {
          final path = Path();
          for (var i = 0; i <= 5; i++) {
            final a = (right ? pi / 2 : 0) + i * (pi / 2) / 5;
            final p = o + Offset(cos(a) * ring * 25, sin(a) * ring * 25);
            i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
          }
          c.drawPath(path, web);
        }
      }
      // Araña que baja y sube.
      final sy = 60 + sin(t * .6) * 40;
      final sx = w * .22;
      c.drawLine(Offset(sx, 0), Offset(sx, sy), Paint()..color = tint(Gh.text, .35));
      c.drawCircle(Offset(sx, sy), 6, fill(tint(const Color(0xff1a1020), 1)));
      for (var i = 0; i < 4; i++) {
        final leg = Paint()
          ..color = tint(const Color(0xff1a1020), 1)
          ..strokeWidth = 1.4;
        c.drawLine(Offset(sx, sy), Offset(sx - 10, sy - 6 + i * 4 + sin(t * 6 + i)), leg);
        c.drawLine(Offset(sx, sy), Offset(sx + 10, sy - 6 + i * 4 - sin(t * 6 + i)), leg);
      }
    }
    // Colina con calabazas que titilan.
    c.drawPath(wave(ground - (strip ? 6 : 30), strip ? 2 : 10, .008, 1), fill(tint(const Color(0xff2a1a3a), .8)));
    final r = rnd(22);
    for (var i = 0; i < (strip ? 4 : 6); i++) {
      final x = w * (.08 + r.nextDouble() * .84), rad = strip ? 5.0 : 13 + r.nextDouble() * 8;
      final at = Offset(x, ground - (strip ? 5 : 24) - rad * .5);
      c.drawOval(Rect.fromCenter(center: at, width: rad * 2.3, height: rad * 1.8), fill(tint(orange, .85)));
      c.drawLine(at.translate(0, -rad * .9), at.translate(rad * .2, -rad * 1.3), Paint()
        ..color = const Color(0xff3c6b2a)
        ..strokeWidth = strip ? 1.5 : 3);
      final glow = twinkle(i * 2.0, 6, .5);
      final face = fill(const Color(0xffffe45c).withValues(alpha: glow));
      for (final dx in [-.45, .45]) {
        c.drawPath(
          Path()
            ..moveTo(at.dx + rad * dx - rad * .2, at.dy - rad * .05)
            ..lineTo(at.dx + rad * dx, at.dy - rad * .4)
            ..lineTo(at.dx + rad * dx + rad * .2, at.dy - rad * .05)
            ..close(),
          face,
        );
      }
      c.drawRect(Rect.fromCenter(center: at.translate(0, rad * .35), width: rad * .9, height: rad * .2), face);
    }
    // Murciélagos.
    for (var i = 0; i < (strip ? 2 : 5); i++) {
      final ph = i * 1.7;
      final x = (t * (18 + i * 5) + i * 140) % (w + 60) - 30, y = (strip ? h * .35 : h * (.2 + .08 * i)) + sin(t * 1.5 + ph) * (strip ? 4 : 14);
      final flap = sin(t * 9 + ph) * (strip ? 3 : 6);
      final sz = strip ? 6.0 : 12.0;
      c.drawPath(
        Path()
          ..moveTo(x, y)
          ..quadraticBezierTo(x - sz * .6, y - sz * .4 - flap, x - sz * 1.3, y - flap)
          ..quadraticBezierTo(x - sz * .7, y + sz * .1, x, y + sz * .25)
          ..quadraticBezierTo(x + sz * .7, y + sz * .1, x + sz * 1.3, y - flap)
          ..quadraticBezierTo(x + sz * .6, y - sz * .4 - flap, x, y),
        fill(tint(const Color(0xff120a18), 1)),
      );
    }
  }

  void muertos() {
    // Papel picado colgando arriba.
    final colors = [const Color(0xffff4fa0), const Color(0xffffb000), const Color(0xff7c4dff), const Color(0xff00c2a8), const Color(0xffff6a3d)];
    final rope = Paint()
      ..color = tint(Gh.text, .35)
      ..strokeWidth = 1;
    final rows = strip ? 1 : 2;
    for (var row = 0; row < rows; row++) {
      final y0 = strip ? 2.0 : 10.0 + row * 70;
      c.drawLine(Offset(0, y0), Offset(w, y0), rope);
      final fw = strip ? 12.0 : 34.0, fh = strip ? 12.0 : 40.0;
      var i = 0;
      for (var x = 4.0 + row * fw / 2; x < w; x += fw + 6, i++) {
        final sway = sin(t * 1.4 + i * .7 + row) * (strip ? .8 : 2);
        final col = tint(colors[(i + row) % colors.length], strip ? .7 : .55);
        final flag = Path()
          ..moveTo(x, y0)
          ..lineTo(x + fw, y0)
          ..lineTo(x + fw + sway, y0 + fh)
          ..lineTo(x + fw * .5 + sway, y0 + fh - (strip ? 3 : 8))
          ..lineTo(x + sway, y0 + fh)
          ..close();
        c.drawPath(flag, fill(col));
        if (!strip) {
          // Calado: flor y rombos recortados.
          final cut = fill(Gh.bg);
          final cc = Offset(x + fw / 2 + sway * .5, y0 + fh * .45);
          for (var a = 0.0; a < 6.28; a += 1.05) {
            c.drawCircle(cc + Offset(cos(a) * 5, sin(a) * 5), 2.4, cut);
          }
          c.drawCircle(cc, 2, cut);
          c.drawRect(Rect.fromCenter(center: Offset(x + 6, y0 + 7), width: 3, height: 3), cut);
          c.drawRect(Rect.fromCenter(center: Offset(x + fw - 6, y0 + 7), width: 3, height: 3), cut);
        }
      }
    }
    // Pétalos de cempasúchil.
    falling(23, strip ? 8 : 30, (at, rot, r) {
      c.save();
      c.translate(at.dx, at.dy);
      c.rotate(rot);
      c.drawOval(Rect.fromCenter(center: Offset.zero, width: strip ? 4 : 7, height: strip ? 2.5 : 4), fill(const Color(0xffffa31a).withValues(alpha: .75)));
      c.restore();
    }, speed: 12);
    if (!strip) {
      // Velas y flores en el suelo.
      final r = rnd(24);
      for (var i = 0; i < 7; i++) {
        final x = w * (.06 + i * .14) + r.nextDouble() * 20;
        final hh = 22 + r.nextDouble() * 20;
        c.drawRect(Rect.fromLTWH(x, ground - hh, 10, hh), fill(tint(const Color(0xfff4ead8), .8)));
        final fl = twinkle(i * 1.3, 9, .7);
        c.drawOval(Rect.fromCenter(center: Offset(x + 5, ground - hh - 6), width: 6 * fl, height: 11 * fl), fill(const Color(0xffffc23a).withValues(alpha: .9)));
        c.drawCircle(Offset(x + 5, ground - hh - 6), 14, fill(const Color(0xffffb000).withValues(alpha: .07)));
        for (var j = 0; j < 3; j++) {
          final fc = Offset(x + 20 + j * 9, ground - 6 - (j % 2) * 5);
          for (var a = 0.0; a < 6.28; a += .9) {
            c.drawCircle(fc + Offset(cos(a) * 3, sin(a) * 3), 2.6, fill(tint(const Color(0xffff9a00), .9)));
          }
        }
      }
    }
  }

  void navidad() {
    final red = const Color(0xffe53945), green = const Color(0xff2e8b4a), gold = const Color(0xffffd54a);
    if (strip) {
      // Guirnalda con foquitos que parpadean.
      final path = Path()..moveTo(0, 4);
      final bulbs = <Offset>[];
      for (var x = 0.0; x < w; x += 60) {
        path.quadraticBezierTo(x + 30, 18, x + 60, 4);
        for (var k = 1; k < 5; k++) {
          final tt = k / 5;
          bulbs.add(Offset(x + 60 * tt, 4 + 28 * tt * (1 - tt))); // la misma curva que la guirnalda
        }
      }
      c.drawPath(
        path,
        Paint()
          ..color = tint(green, .8)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
      final cols = [red, gold, const Color(0xff4fc3ff), const Color(0xff7dff7a)];
      for (var i = 0; i < bulbs.length; i++) {
        final on = ((t * 2).floor() + i) % 3 != 0;
        final col = cols[i % cols.length];
        if (on) c.drawCircle(bulbs[i], 5, fill(col.withValues(alpha: .25)));
        c.drawCircle(bulbs[i] + const Offset(0, 1), 2.6, fill(on ? col : tint(col, .35)));
      }
    } else {
      stars(25, 30, maxY: .5);
      // Suelo nevado, pinos con luces y un muñeco de nieve.
      c.drawPath(wave(ground - 26, 6, .01, 0), fill(tint(Colors.white, .28)));
      final r = rnd(26);
      for (var i = 0; i < 5; i++) {
        final x = w * (.08 + i * .2) + r.nextDouble() * 30, hh = 70 + r.nextDouble() * 50;
        final base = ground - 22;
        pine(x, base, hh, tint(green, .6));
        for (var j = 0; j < 7; j++) {
          final ty = .2 + j * .1;
          final lx = x + (r.nextDouble() - .5) * hh * .5 * (ty + .3);
          final on = ((t * 1.5).floor() + j + i) % 3 != 0;
          c.drawCircle(Offset(lx, base - hh * (1 - ty)), 2.4, fill(on ? [red, gold, const Color(0xff4fc3ff)][j % 3] : tint(Gh.text, .2)));
        }
        _star(c, Offset(x, base - hh - 2), 6, tint(gold, .95));
      }
      final sm = Offset(w * .9, ground - 40);
      c.drawCircle(sm, 18, fill(tint(Colors.white, .75)));
      c.drawCircle(sm - const Offset(0, 26), 12, fill(tint(Colors.white, .8)));
      c.drawCircle(sm - const Offset(4, 28), 1.6, fill(Colors.black54));
      c.drawCircle(sm - const Offset(-4, 28), 1.6, fill(Colors.black54));
      c.drawPath(
        Path()
          ..moveTo(sm.dx, sm.dy - 25)
          ..lineTo(sm.dx + 9, sm.dy - 23)
          ..lineTo(sm.dx, sm.dy - 21)
          ..close(),
        fill(const Color(0xffff8a2a)),
      );
      c.drawRect(Rect.fromLTWH(sm.dx - 12, sm.dy - 16, 24, 4), fill(tint(red, .9)));
    }
    falling(27, strip ? 18 : 70, (at, rot, r) => c.drawCircle(at, strip ? 1.2 : 1 + r.nextDouble() * 2, fill(Colors.white.withValues(alpha: .7))), speed: strip ? 10 : 22);
  }

  void anioNuevo() {
    if (!strip) stars(28, 40, maxY: .6);
    // Silueta de ciudad.
    final r = rnd(29);
    for (var x = -10.0; x < w;) {
      final bw = (strip ? 10 : 24) + r.nextDouble() * (strip ? 14 : 40), bh = (strip ? 6 : 40) + r.nextDouble() * (strip ? 14 : 110);
      c.drawRect(Rect.fromLTWH(x, ground - bh, bw, bh), fill(tint(Gh.border, .9)));
      x += bw + 3;
    }
    // Fuegos artificiales en ciclo.
    final cols = [const Color(0xffffd54a), const Color(0xffff5a8a), const Color(0xff4fc3ff), const Color(0xff9dff6a), const Color(0xffc38bff)];
    final n = strip ? 3 : 5;
    for (var i = 0; i < n; i++) {
      const period = 3.2;
      final phase = i * period / n;
      final k = ((t + phase) % period) / period;
      final cycle = ((t + phase) / period).floor();
      final rr = Random(cycle * 31 + i);
      final cx = w * (.1 + rr.nextDouble() * .8), cy = strip ? h * (.25 + rr.nextDouble() * .3) : h * (.15 + rr.nextDouble() * .35);
      final col = cols[rr.nextInt(cols.length)];
      if (k < .25) {
        // Cohete subiendo.
        final y = ground - (ground - cy) * (k / .25);
        c.drawCircle(Offset(cx, y), 1.5, fill(col));
      } else {
        final e = (k - .25) / .75;
        final rad = (strip ? 14 : 60) * Curves.easeOut.transform(e);
        final a = (1 - e).clamp(0.0, 1.0);
        for (var j = 0; j < 14; j++) {
          final ang = j / 14 * 6.28;
          final p = Offset(cx + cos(ang) * rad, cy + sin(ang) * rad + e * e * (strip ? 4 : 20));
          c.drawCircle(p, strip ? 1.2 : 2, fill(col.withValues(alpha: a)));
        }
      }
    }
  }

  void sanValentin() {
    final pink = const Color(0xffff5d8f);
    if (!strip) {
      final r = rnd(30);
      for (var i = 0; i < 4; i++) {
        heart(Offset(w * (.1 + r.nextDouble() * .8), h * (.55 + r.nextDouble() * .3)), 30 + r.nextDouble() * 30, pink.withValues(alpha: .07));
      }
    }
    rising(31, strip ? 8 : 26, (at, r) => heart(at, strip ? 4 : 5 + r.nextDouble() * 8, Color.lerp(pink, const Color(0xffff9ec0), r.nextDouble())!.withValues(alpha: .7)), speed: strip ? 8 : 16);
  }

  void carnaval() {
    final cols = [const Color(0xffff4f7a), const Color(0xffffc93a), const Color(0xff39d0ff), const Color(0xff7dff6a), const Color(0xffb46bff)];
    // Serpentinas colgando.
    for (var i = 0; i < (strip ? 5 : 9); i++) {
      final x0 = w * (i + .5) / (strip ? 5 : 9);
      final path = Path()..moveTo(x0, 0);
      final len = strip ? h * .7 : h * .35;
      for (var y = 0.0; y <= len; y += 4) {
        path.lineTo(x0 + sin(y * .15 + t * 1.2 + i) * (strip ? 3 : 8), y);
      }
      c.drawPath(
        path,
        Paint()
          ..color = cols[i % cols.length].withValues(alpha: .6)
          ..style = PaintingStyle.stroke
          ..strokeWidth = strip ? 1.5 : 2.5,
      );
    }
    falling(32, strip ? 20 : 60, (at, rot, r) {
      c.save();
      c.translate(at.dx, at.dy);
      c.rotate(rot);
      c.drawRect(Rect.fromCenter(center: Offset.zero, width: strip ? 3 : 5, height: strip ? 2 : 3), fill(cols[r.nextInt(cols.length)].withValues(alpha: .8)));
      c.restore();
    });
  }

  void sanPatricio() {
    if (!strip) {
      // Arcoíris.
      final cols = [const Color(0xffe53935), const Color(0xffff9800), const Color(0xffffeb3b), const Color(0xff43a047), const Color(0xff1e88e5), const Color(0xff8e24aa)];
      for (var i = 0; i < cols.length; i++) {
        c.drawArc(
          Rect.fromCircle(center: Offset(w * .5, ground + 40), radius: w * .32 - i * 9),
          pi,
          pi,
          false,
          Paint()
            ..color = cols[i].withValues(alpha: .18)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 9,
        );
      }
    }
    c.drawPath(wave(ground - (strip ? 6 : 34), strip ? 2 : 12, .009, .5), fill(tint(const Color(0xff2f9e4a), .55)));
    falling(33, strip ? 8 : 24, (at, rot, r) => _clover(c, at, strip ? 3 : 5 + r.nextDouble() * 3, rot, const Color(0xff4fcf6a).withValues(alpha: .7)), speed: 10);
  }

  void diaTierra() {
    if (!strip) {
      final e = Offset(w * .78, h * .3);
      const er = 46.0;
      c.drawCircle(e, er, fill(tint(const Color(0xff2b7bd6), .7)));
      c.save();
      c.clipPath(Path()..addOval(Rect.fromCircle(center: e, radius: er)));
      final land = fill(tint(const Color(0xff4caf50), .8));
      final off = (t * 6) % (er * 4);
      for (var k = -1; k <= 1; k++) {
        final ox = e.dx - er * 2 + off + k * er * 4;
        c.drawOval(Rect.fromLTWH(ox, e.dy - er * .6, er * 1.1, er * .7), land);
        c.drawOval(Rect.fromLTWH(ox + er * 1.6, e.dy - er * .1, er * .9, er * .9), land);
        c.drawOval(Rect.fromLTWH(ox + er * .6, e.dy + er * .4, er * .7, er * .4), land);
      }
      c.restore();
      c.drawCircle(e, er * 1.15, fill(const Color(0xff7fd3ff).withValues(alpha: .07)));
    }
    c.drawPath(wave(ground - (strip ? 6 : 28), strip ? 2 : 9, .01, 2), fill(tint(const Color(0xff3c9a5f), .5)));
    falling(34, strip ? 8 : 26, (at, rot, r) {
      c.save();
      c.translate(at.dx, at.dy);
      c.rotate(rot);
      final s = strip ? 3.0 : 5 + r.nextDouble() * 3;
      c.drawPath(
        Path()
          ..moveTo(-s, 0)
          ..quadraticBezierTo(0, -s * .8, s, 0)
          ..quadraticBezierTo(0, s * .8, -s, 0),
        fill(Color.lerp(const Color(0xff6ccf6a), const Color(0xffd7c84a), r.nextDouble())!.withValues(alpha: .75)),
      );
      c.restore();
    }, speed: 9);
  }

  void intiRaymi() {
    final gold = const Color(0xffffc22e);
    final sun = Offset(w * (strip ? .9 : .5), strip ? h * .45 : h * .32);
    final sr = strip ? 9.0 : 40.0;
    final rays = Paint()
      ..color = gold.withValues(alpha: .45)
      ..strokeWidth = strip ? 1.5 : 3;
    for (var i = 0; i < 16; i++) {
      final a = i / 16 * 6.28 + t * .15;
      final len = sr * (i.isEven ? 1.9 : 1.5);
      c.drawLine(sun + Offset(cos(a), sin(a)) * sr * 1.15, sun + Offset(cos(a), sin(a)) * len, rays);
    }
    c.drawCircle(sun, sr, fill(tint(gold, .85)));
    if (!strip) {
      // Cara del sol: ojos y boca simples.
      final ink = fill(tint(const Color(0xff9a5a00), .9));
      c.drawCircle(sun + const Offset(-12, -6), 3, ink);
      c.drawCircle(sun + const Offset(12, -6), 3, ink);
      c.drawArc(Rect.fromCenter(center: sun + const Offset(0, 6), width: 20, height: 12), .2, pi - .4, false, Paint()
        ..color = ink.color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4);
    }
    // Cordillera.
    for (var i = 0; i < 3; i++) {
      final r = rnd(35 + i);
      final path = Path()..moveTo(0, ground);
      for (var x = 0.0; x <= w; x += strip ? 18 : 60) {
        path.lineTo(x, ground - (strip ? 6 + r.nextDouble() * 10 : 40 + r.nextDouble() * 80) * (1 - i * .25));
      }
      path
        ..lineTo(w, ground)
        ..close();
      c.drawPath(path, fill(tint(Color.lerp(const Color(0xff8a5a3a), const Color(0xff3a2a20), i / 2)!, .4 + i * .2)));
    }
  }

  void cumple() {
    final cols = [const Color(0xffff5a7a), const Color(0xffffc93a), const Color(0xff39d0ff), const Color(0xff7dff6a), const Color(0xffb46bff)];
    rising(36, strip ? 4 : 9, (at, r) {
      final col = cols[r.nextInt(cols.length)];
      final rad = strip ? 5.0 : 12 + r.nextDouble() * 6;
      c.drawLine(at + Offset(0, rad * 1.2), at + Offset(sin(t + at.dx) * 4, rad * 3.2), Paint()
        ..color = tint(Gh.text, .4)
        ..strokeWidth = 1);
      c.drawOval(Rect.fromCenter(center: at, width: rad * 1.7, height: rad * 2.1), fill(col.withValues(alpha: .65)));
      c.drawOval(Rect.fromCenter(center: at - Offset(rad * .3, rad * .4), width: rad * .4, height: rad * .6), fill(Colors.white.withValues(alpha: .35)));
    }, speed: strip ? 6 : 12);
    if (!strip) {
      // Torta con velas.
      final cx = w * .5, base = ground;
      c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(cx - 70, base - 50, 140, 50), const Radius.circular(8)), fill(tint(const Color(0xffff7aa2), .8)));
      c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(cx - 50, base - 85, 100, 38), const Radius.circular(8)), fill(tint(const Color(0xffffc98a), .85)));
      // Glaseado que chorrea en cada piso.
      for (final (y, x0, ww) in [(base - 50, cx - 70, 140.0), (base - 85, cx - 50, 100.0)]) {
        c.drawRect(Rect.fromLTWH(x0 + 4, y, ww - 8, 6), fill(tint(Colors.white, .85)));
        for (var dx = 10.0; dx < ww - 10; dx += 17) {
          c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x0 + dx, y + 4, 6, 6 + (dx * 7 % 9)), const Radius.circular(3)), fill(tint(Colors.white, .85)));
        }
      }
      for (var i = 0; i < 5; i++) {
        final x = cx - 36 + i * 18.0;
        c.drawRect(Rect.fromLTWH(x - 2, base - 104, 4, 19), fill(cols[i]));
        final fl = twinkle(i * 1.7, 10, .7);
        c.drawOval(Rect.fromCenter(center: Offset(x, base - 110), width: 5 * fl, height: 10 * fl), fill(const Color(0xffffc23a)));
      }
    }
    falling(37, strip ? 14 : 40, (at, rot, r) {
      c.save();
      c.translate(at.dx, at.dy);
      c.rotate(rot);
      c.drawRect(Rect.fromCenter(center: Offset.zero, width: strip ? 3 : 5, height: strip ? 2 : 3), fill(cols[r.nextInt(cols.length)].withValues(alpha: .8)));
      c.restore();
    });
  }
}

void _heart(Canvas c, Offset at, double r, Color col) {
  final p = Path()
    ..moveTo(at.dx, at.dy + r * .9)
    ..cubicTo(at.dx - r * 1.6, at.dy - r * .2, at.dx - r * .7, at.dy - r * 1.3, at.dx, at.dy - r * .4)
    ..cubicTo(at.dx + r * .7, at.dy - r * 1.3, at.dx + r * 1.6, at.dy - r * .2, at.dx, at.dy + r * .9);
  c.drawPath(p, Paint()..color = col);
}

void _star(Canvas c, Offset at, double r, Color col) {
  final p = Path();
  for (var i = 0; i < 10; i++) {
    final a = -pi / 2 + i * pi / 5, rr = i.isEven ? r : r * .45;
    final q = at + Offset(cos(a) * rr, sin(a) * rr);
    i == 0 ? p.moveTo(q.dx, q.dy) : p.lineTo(q.dx, q.dy);
  }
  c.drawPath(p..close(), Paint()..color = col);
}

void _clover(Canvas c, Offset at, double r, double rot, Color col) {
  c.save();
  c.translate(at.dx, at.dy);
  c.rotate(rot);
  final p = Paint()..color = col;
  for (var i = 0; i < 3; i++) {
    final a = -pi / 2 + i * 2 * pi / 3;
    c.drawCircle(Offset(cos(a), sin(a)) * r * .6, r * .55, p);
  }
  c.drawLine(Offset.zero, Offset(r * .3, r * 1.1), p..strokeWidth = r * .25);
  c.restore();
}

void _text(Canvas c, String text, Offset at, double size, Color col, {bool mono = false, bool anchorLeft = false}) {
  final tp = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(color: col, fontSize: size, fontFamily: mono ? 'monospace' : null, fontWeight: FontWeight.w600),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  tp.paint(c, anchorLeft ? at : at - Offset(tp.width / 2, tp.height / 2));
}
