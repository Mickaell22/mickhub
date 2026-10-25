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

/// Foto redonda de un usuario. Mientras carga, o sin internet, muestra sus
/// iniciales sobre un color fijo por nombre. Flutter cachea la imagen por URL,
/// así que cada autor se descarga una sola vez por sesión.
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
    return ClipOval(
      child: SizedBox.square(
        dimension: size,
        child: url == null
            ? fallback
            : Image.network(
                url,
                width: size,
                height: size,
                fit: BoxFit.cover,
                cacheWidth: px,
                frameBuilder: (_, child, frame, _) => frame == null ? fallback : child,
                errorBuilder: (_, _, _) => fallback,
              ),
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
