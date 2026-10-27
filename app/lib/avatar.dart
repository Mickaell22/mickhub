import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';

import 'theme.dart';

/// URL de la foto de GitHub de un email, como hace GitHub Desktop. Los emails
/// `123+user@users.noreply.github.com` llevan el id del usuario; los demás se
/// buscan por email (si no hay cuenta asociada, GitHub devuelve su identicon).
String avatarForEmail(String email, {int size = 64}) {
  final m = RegExp(r'^(\d+)\+[^@]+@users\.noreply\.github\.com$').firstMatch(email.toLowerCase());
  if (m != null) return 'https://avatars.githubusercontent.com/u/${m[1]}?s=$size';
  return 'https://avatars.githubusercontent.com/u/e?email=${Uri.encodeQueryComponent(email.toLowerCase())}&s=$size';
}

String avatarForUser(String user, {int size = 64}) => 'https://avatars.githubusercontent.com/${Uri.encodeComponent(user)}?s=$size';

/// Carpeta donde se guardan las fotos bajadas (la pone `main`). Así no se
/// vuelven a pedir a GitHub cada vez que se abre la app ni se ven parpadear.
Directory? avatarDir;

/// Las fotos se renuevan cada tanto por si el usuario cambió la suya.
const avatarMaxAge = Duration(days: 7);

final _ready = <String, Uint8List?>{}; // URL -> bytes ya leídos (null = no hay foto)
final _pending = <String, Future<Uint8List?>>{};

/// Bytes de la foto de [url]: de memoria, del disco o bajándola (una sola vez
/// por URL y por sesión). Sin internet usa la copia vieja si existe.
Future<Uint8List?> avatarBytes(String url) => _pending[url] ??= () async {
  final dir = avatarDir;
  final file = dir == null ? null : File('${dir.path}${Platform.pathSeparator}${sha1.convert(utf8.encode(url))}');
  if (file != null && file.existsSync() && DateTime.now().difference(file.lastModifiedSync()) < avatarMaxAge) {
    return _ready[url] = await file.readAsBytes();
  }
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final res = await (await client.getUrl(Uri.parse(url))).close();
    if (res.statusCode != 200) throw HttpException('${res.statusCode}');
    final bytes = Uint8List.fromList([for (final c in await res.toList()) ...c]);
    if (file != null) {
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes);
    }
    return _ready[url] = bytes;
  } catch (_) {
    return _ready[url] = file != null && file.existsSync() ? await file.readAsBytes() : null;
  } finally {
    client.close();
  }
}();

/// Foto redonda de un usuario. Mientras carga, o sin internet, muestra sus
/// iniciales sobre un color fijo por nombre.
class Avatar extends StatelessWidget {
  const Avatar({super.key, this.email, this.user, required this.name, this.size = 20});
  final String? email, user;
  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final px = (size * MediaQuery.devicePixelRatioOf(context)).ceil();
    final url = user != null && user!.isNotEmpty
        ? avatarForUser(user!, size: px)
        : (email != null && email!.contains('@') ? avatarForEmail(email!, size: px) : null);
    final fallback = _Initials(name: name, size: size);
    Widget image(Uint8List? bytes) => bytes == null
        ? fallback
        : Image.memory(bytes, width: size, height: size, fit: BoxFit.cover, cacheWidth: px, errorBuilder: (_, _, _) => fallback);
    return ClipOval(
      child: SizedBox.square(
        dimension: size,
        child: url == null
            ? fallback
            // Si ya está en memoria se dibuja directo, sin pasar por las iniciales.
            : _ready.containsKey(url)
            ? image(_ready[url])
            : FutureBuilder(future: avatarBytes(url), builder: (_, snap) => image(snap.data)),
      ),
    );
  }
}

class _Initials extends StatelessWidget {
  const _Initials({required this.name, required this.size});
  final String name;
  final double size;

  static const _colors = [Color(0xff0366d6), Color(0xff28a745), Color(0xffd73a49), Color(0xff6f42c1), Color(0xffe36209), Color(0xff1b7c83)];

  @override
  Widget build(BuildContext context) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    final initials = parts.isEmpty ? '?' : parts.take(2).map((p) => p[0].toUpperCase()).join();
    return Container(
      color: _colors[name.hashCode.abs() % _colors.length],
      alignment: Alignment.center,
      child: Text(
        initials,
        style: TextStyle(fontSize: size * 0.42, fontWeight: FontWeight.w600, color: Gh.text),
      ),
    );
  }
}
