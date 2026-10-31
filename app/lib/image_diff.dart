import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'theme.dart';

/// Formatos que se muestran como imagen en vez de "archivo binario". SVG no
/// está: es texto y git lo muestra como diff normal.
bool isImagePath(String path) => RegExp(r'\.(png|jpe?g|gif|webp|bmp|ico)$', caseSensitive: false).hasMatch(path);

/// Imagen antes y después del cambio, lado a lado, como GitHub Desktop. Un lado
/// sin imagen (archivo nuevo o borrado) se muestra vacío con su leyenda.
/// Los bytes se piden una vez al crearse; cambiar de archivo debe cambiar la
/// `key` para que se vuelvan a pedir.
class ImageDiff extends StatefulWidget {
  const ImageDiff({super.key, required this.before, required this.after});

  /// Cargadores de cada versión; null = esa versión no existe.
  final Future<Uint8List?> Function()? before, after;

  @override
  State<ImageDiff> createState() => _ImageDiffState();
}

class _ImageDiffState extends State<ImageDiff> {
  late final Future<Uint8List?>? _before = widget.before?.call();
  late final Future<Uint8List?>? _after = widget.after?.call();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(Gh.sp * 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: Gh.sp * 2,
      children: [
        Expanded(child: _side('Antes', Gh.deleted, _before)),
        Expanded(child: _side('Después', Gh.added, _after)),
      ],
    ),
  );

  Widget _side(String title, Color color, Future<Uint8List?>? bytes) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
      const SizedBox(height: Gh.sp),
      Expanded(
        child: Container(
          decoration: BoxDecoration(
            color: Gh.box,
            border: Border.all(color: color.withValues(alpha: 0.5)),
            borderRadius: BorderRadius.circular(Gh.radius),
          ),
          padding: const EdgeInsets.all(Gh.sp),
          child: bytes == null
              ? Center(
                  child: Text(title == 'Antes' ? 'No existía' : 'Se borró', style: const TextStyle(color: Gh.textSecondary)),
                )
              : FutureBuilder(
                  future: bytes,
                  builder: (_, snap) => switch (snap) {
                    AsyncSnapshot(connectionState: ConnectionState.waiting) => const Center(
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    AsyncSnapshot(data: final b?) => Column(
                      children: [
                        Expanded(
                          child: Image.memory(
                            b,
                            fit: BoxFit.contain,
                            filterQuality: FilterQuality.medium,
                            errorBuilder: (_, _, _) => const Center(
                              child: Text('No se pudo mostrar la imagen', style: TextStyle(color: Gh.textSecondary)),
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _size(b.length),
                          style: const TextStyle(fontSize: Gh.fontSizeSm, color: Gh.textSecondary),
                        ),
                      ],
                    ),
                    _ => const Center(
                      child: Text('No se pudo leer', style: TextStyle(color: Gh.textSecondary)),
                    ),
                  },
                ),
        ),
      ),
    ],
  );

  static String _size(int n) => n < 1024
      ? '$n B'
      : n < 1024 * 1024
      ? '${(n / 1024).toStringAsFixed(1)} KB'
      : '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
}
