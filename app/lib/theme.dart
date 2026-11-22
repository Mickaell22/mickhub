import 'package:flutter/material.dart';

import 'git.dart';

/// Colores y medidas del tema oscuro de GitHub Desktop 3.4 (sacados de sus SCSS,
/// `themes/_dark.scss` y `_variables.scss`; las funciones darken/lighten de Sass
/// ya están resueltas a hex). Los de superficie y el acento salen de la paleta
/// activa ([apply], `look.dart`); la de fábrica es exactamente la de Desktop. Los
/// de estado (agregado, borrado...) son significado, no decoración: fijos.
abstract final class Gh {
  static Color bg = const Color(0xff24292e); // gray-900
  static Color box = const Color(0xff1d2125); // darken(gray-900, 3%): toolbar, gutter
  static Color boxAlt = const Color(0xff2b3137); // lighten(gray-900, 3%): headers, caja de commit
  static Color border = const Color(0xff141414);
  static Color hover = const Color(0xff2f363d); // gray-800
  static Color selected = const Color(0xff444d56); // gray-700
  static Color blue = const Color(0xff0366d6);
  static Color link = const Color(0xff2e8fff);
  static Color text = const Color(0xfff6f8fa); // gray-100
  static Color textSecondary = const Color(0xff959da5); // gray-400
  static Color textMuted = const Color(0xff535a61);
  static Color diffHunkGutter = const Color(0xff171a1d);

  /// Los colores puestos ahora (para dibujar algo con otra paleta y volver).
  static GhColors current() => GhColors(
    bg: bg,
    box: box,
    boxAlt: boxAlt,
    border: border,
    hover: hover,
    selected: selected,
    accent: blue,
    link: link,
    text: text,
    textSecondary: textSecondary,
    textMuted: textMuted,
    gutter: diffHunkGutter,
  );

  /// Pone los colores de una paleta. Quien la cambia reconstruye todo el árbol
  /// (`rebuildAll`): nada guarda estos colores en un `const`.
  static void apply(GhColors c) {
    bg = c.bg;
    box = c.box;
    boxAlt = c.boxAlt;
    border = c.border;
    hover = c.hover;
    selected = c.selected;
    blue = c.accent;
    link = c.link;
    text = c.text;
    textSecondary = c.textSecondary;
    textMuted = c.textMuted;
    diffHunkGutter = c.gutter;
  }

  static const added = Color(0xff28a745);
  static const deleted = Color(0xffd73a49);
  static const modified = Color(0xffdbab09);
  static const renamed = Color(0xff0366d6);
  static const conflicted = Color(0xfff66a0a);

  static const diffAdd = Color(0xff113a1b);
  static const diffDelete = Color(0xff450c0f);

  static const toolbarHeight = 50.0;
  static const tabBarHeight = 29.0;
  static const rowHeight = 29.0;
  static const commitRowHeight = 50.0;
  static const sp = 10.0; // --spacing
  static const radius = 6.0;
  static const fontSize = 12.0;
  static const fontSizeSm = 11.0;

  static const mono = TextStyle(fontFamily: 'monospace', fontSize: fontSize, height: 1.5);
  static BorderSide get divider => BorderSide(color: border);
}

/// Los colores que cambian con la paleta.
class GhColors {
  const GhColors({
    required this.bg,
    required this.box,
    required this.boxAlt,
    required this.border,
    required this.hover,
    required this.selected,
    required this.accent,
    required this.link,
    required this.text,
    required this.textSecondary,
    required this.textMuted,
    required this.gutter,
  });
  final Color bg, box, boxAlt, border, hover, selected, accent, link, text, textSecondary, textMuted, gutter;

  /// GitHub Desktop 3.4, tema oscuro: la base que no se toca.
  static const desktop = GhColors(
    bg: Color(0xff24292e),
    box: Color(0xff1d2125),
    boxAlt: Color(0xff2b3137),
    border: Color(0xff141414),
    hover: Color(0xff2f363d),
    selected: Color(0xff444d56),
    accent: Color(0xff0366d6),
    link: Color(0xff2e8fff),
    text: Color(0xfff6f8fa),
    textSecondary: Color(0xff959da5),
    textMuted: Color(0xff535a61),
    gutter: Color(0xff171a1d),
  );

  /// Una paleta oscura derivada de un tono ([hue], [sat]) y un acento, con las
  /// mismas luminosidades que Desktop para que todas se sientan de la familia.
  factory GhColors.derive(double hue, double sat, Color accent, {Color? link}) {
    Color n(double l, [double s = 1]) => HSLColor.fromAHSL(1, hue, (sat * s).clamp(0, 1), l).toColor();
    final a = HSLColor.fromColor(accent);
    return GhColors(
      bg: n(.16),
      box: n(.13),
      boxAlt: n(.19),
      border: n(.075, .6),
      hover: n(.21),
      selected: n(.29),
      accent: accent,
      link: link ?? a.withLightness((a.lightness + .18).clamp(.55, .72)).toColor(),
      text: n(.97, .4),
      textSecondary: n(.62, .35),
      textMuted: n(.36, .3),
      gutter: n(.105),
    );
  }
}

/// Reconstruye todo debajo de [context] sin perder estado (como un hot reload):
/// al cambiar de paleta los colores de [Gh] cambian por debajo.
void rebuildAll(BuildContext context) {
  void mark(Element e) {
    e.markNeedsBuild();
    e.visitChildren(mark);
  }

  (context as Element).visitChildren(mark);
}

ThemeData ghTheme() {
  final base = ThemeData(brightness: Brightness.dark, colorSchemeSeed: Gh.blue, visualDensity: VisualDensity.compact);
  return base.copyWith(
    scaffoldBackgroundColor: Gh.bg,
    canvasColor: Gh.bg,
    dividerColor: Gh.border,
    colorScheme: base.colorScheme.copyWith(primary: Gh.blue, onPrimary: Colors.white, surface: Gh.bg, onSurface: Gh.text),
    textTheme: base.textTheme
        .apply(bodyColor: Gh.text, displayColor: Gh.text)
        .copyWith(
          bodyMedium: TextStyle(fontSize: Gh.fontSize, color: Gh.text),
          bodySmall: TextStyle(fontSize: Gh.fontSizeSm, color: Gh.textSecondary),
          labelLarge: const TextStyle(fontSize: Gh.fontSize, fontWeight: FontWeight.w600),
        ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: Gh.box,
      hintStyle: TextStyle(color: Gh.textSecondary, fontSize: Gh.fontSize),
      contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      border: OutlineInputBorder(
        borderSide: BorderSide(color: Gh.border),
        borderRadius: BorderRadius.all(Radius.circular(Gh.radius)),
      ),
      enabledBorder: OutlineInputBorder(
        borderSide: BorderSide(color: Gh.border),
        borderRadius: BorderRadius.all(Radius.circular(Gh.radius)),
      ),
      focusedBorder: OutlineInputBorder(
        borderSide: BorderSide(color: Gh.blue),
        borderRadius: BorderRadius.all(Radius.circular(Gh.radius)),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: Gh.blue,
        foregroundColor: Colors.white,
        textStyle: const TextStyle(fontSize: Gh.fontSize, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Gh.radius)),
      ),
    ),
    // Botón secundario de Desktop: gris (`--secondary-button-background`), texto claro.
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        backgroundColor: Gh.hover,
        foregroundColor: Gh.text,
        side: BorderSide(color: Gh.border),
        textStyle: const TextStyle(fontSize: Gh.fontSize),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Gh.radius)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: Gh.link)),
    checkboxTheme: CheckboxThemeData(
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Gh.blue : null),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: Gh.bg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Gh.radius), side: Gh.divider),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: Gh.boxAlt,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Gh.radius), side: Gh.divider),
    ),
    tooltipTheme: TooltipThemeData(
      textStyle: TextStyle(fontSize: Gh.fontSizeSm, color: Gh.text),
      decoration: BoxDecoration(color: Gh.box),
    ),
  );
}

/// Ícono de estado de archivo, como los octicons diff-added/modified/removed.
Widget statusIcon(FileStatus s) {
  final (icon, color) = switch (s) {
    FileStatus.added => (Icons.add_box_outlined, Gh.added),
    FileStatus.modified => (Icons.indeterminate_check_box_outlined, Gh.modified),
    FileStatus.deleted => (Icons.disabled_by_default_outlined, Gh.deleted),
    FileStatus.renamed => (Icons.arrow_circle_right_outlined, Gh.renamed),
    FileStatus.conflicted => (Icons.warning_amber_outlined, Gh.conflicted),
  };
  return Icon(icon, size: 16, color: color);
}

/// Íconos elegibles para los grupos de repos (clave guardada -> ícono).
const groupIcons = <String, IconData>{
  'carpeta': Icons.folder_outlined,
  'trabajo': Icons.work_outline,
  'apps': Icons.apps,
  'ia': Icons.smart_toy_outlined,
  'codigo': Icons.code,
  'web': Icons.language,
  'movil': Icons.phone_android,
  'base-datos': Icons.storage,
  'nube': Icons.cloud_outlined,
  'herramientas': Icons.build_outlined,
  'universidad': Icons.school_outlined,
  'ciencia': Icons.science_outlined,
  'persona': Icons.person_outline,
  'tienda': Icons.storefront_outlined,
  'restaurante': Icons.restaurant,
  'juegos': Icons.sports_esports_outlined,
  'musica': Icons.music_note_outlined,
  'libro': Icons.menu_book_outlined,
  'seguridad': Icons.shield_outlined,
  'bug': Icons.bug_report_outlined,
  'cohete': Icons.rocket_launch_outlined,
  'estrella': Icons.star_outline,
  'corazon': Icons.favorite_border,
  'casa': Icons.home_outlined,
};

IconData groupIcon(String? key) => groupIcons[key] ?? Icons.folder_outlined;

/// Opción de menú contextual con ícono; [danger] la pinta en rojo.
PopupMenuItem<T> menuItem<T>(T value, IconData icon, String text, {bool danger = false}) {
  final color = danger ? Gh.deleted : Gh.text;
  return PopupMenuItem<T>(
    value: value,
    height: 34,
    child: Row(
      children: [
        Icon(icon, size: 16, color: danger ? Gh.deleted : Gh.textSecondary),
        const SizedBox(width: Gh.sp),
        Text(
          text,
          style: TextStyle(fontSize: Gh.fontSize, fontWeight: FontWeight.normal, color: color),
        ),
      ],
    ),
  );
}

/// Libera el controlador de un diálogo que ya se cerró, pero después de su
/// animación de cierre: si se libera al instante, el campo todavía lo usa y
/// Flutter falla con `'_dependents.isEmpty'` (pantalla roja).
void disposeAfterDialog(ChangeNotifier c) => Future.delayed(const Duration(seconds: 1), c.dispose);
