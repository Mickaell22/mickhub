import 'package:flutter/material.dart';

import 'git.dart';

/// Colores y medidas del tema oscuro de GitHub Desktop 3.4 (sacados de sus SCSS,
/// `themes/_dark.scss` y `_variables.scss`; las funciones darken/lighten de Sass
/// ya están resueltas a hex).
abstract final class Gh {
  static const bg = Color(0xff24292e); // gray-900
  static const box = Color(0xff1d2125); // darken(gray-900, 3%): toolbar, gutter
  static const boxAlt = Color(0xff2b3137); // lighten(gray-900, 3%): headers, caja de commit
  static const border = Color(0xff141414);
  static const hover = Color(0xff2f363d); // gray-800
  static const selected = Color(0xff444d56); // gray-700
  static const blue = Color(0xff0366d6);
  static const link = Color(0xff2e8fff);
  static const text = Color(0xfff6f8fa); // gray-100
  static const textSecondary = Color(0xff959da5); // gray-400
  static const textMuted = Color(0xff535a61);

  static const added = Color(0xff28a745);
  static const deleted = Color(0xffd73a49);
  static const modified = Color(0xffdbab09);
  static const renamed = Color(0xff0366d6);
  static const conflicted = Color(0xfff66a0a);

  static const diffAdd = Color(0xff113a1b);
  static const diffDelete = Color(0xff450c0f);
  static const diffHunkGutter = Color(0xff171a1d);

  static const toolbarHeight = 50.0;
  static const tabBarHeight = 29.0;
  static const rowHeight = 29.0;
  static const commitRowHeight = 50.0;
  static const sp = 10.0; // --spacing
  static const radius = 6.0;
  static const fontSize = 12.0;
  static const fontSizeSm = 11.0;

  static const mono = TextStyle(fontFamily: 'monospace', fontSize: fontSize, height: 1.5);
  static const divider = BorderSide(color: border);
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
          bodyMedium: const TextStyle(fontSize: Gh.fontSize, color: Gh.text),
          bodySmall: const TextStyle(fontSize: Gh.fontSizeSm, color: Gh.textSecondary),
          labelLarge: const TextStyle(fontSize: Gh.fontSize, fontWeight: FontWeight.w600),
        ),
    inputDecorationTheme: const InputDecorationTheme(
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
        side: const BorderSide(color: Gh.border),
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
    tooltipTheme: const TooltipThemeData(
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
