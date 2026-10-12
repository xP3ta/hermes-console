import '../models/connection.dart';

/// Enlace de emparejado de una instancia remota: codifica host + puerto + token
/// (y opcionalmente etiqueta, HTTPS, Dashboard y el acceso al Dashboard) en
/// una URI `hermes://pair?...`
/// que el servidor imprime como QR. La app la escanea (o se pega) y precarga la
/// instancia, evitando teclear IP y un token largo en el móvil.
///
/// Núcleo PURO (sin Flutter) para poder testearlo sin dispositivo.
class PairingLink {
  static const scheme = 'hermes';
  static const authority = 'pair';

  final String host;
  final int port;
  final String token;
  final String? label;
  final bool useHttps;
  final String? dashboardUrl;

  /// Existing Dashboard sign-in carried by the link (`dash_user` +
  /// `dash_pass`). Both or neither: half a login is no login. Secrets: they
  /// go to the Keystore on save and are never logged, shown or kept in prefs.
  final String? dashboardUser;
  final String? dashboardPassword;

  const PairingLink({
    required this.host,
    required this.port,
    required this.token,
    this.label,
    this.useHttps = false,
    this.dashboardUrl,
    this.dashboardUser,
    this.dashboardPassword,
  });

  /// True when the link carries a complete Dashboard sign-in.
  bool get hasDashboardLogin =>
      (dashboardUser?.trim().isNotEmpty ?? false) &&
      (dashboardPassword?.isNotEmpty ?? false);

  /// Construye la URI canónica `hermes://pair?host=...&port=...&token=...`.
  String build() {
    final q = <String, String>{
      'host': host,
      'port': port.toString(),
      'token': token,
      if (label != null && label!.trim().isNotEmpty) 'label': label!.trim(),
      if (useHttps) 'https': '1',
      if (dashboardUrl != null && dashboardUrl!.trim().isNotEmpty)
        'dashboard': dashboardUrl!.trim(),
      if (hasDashboardLogin) ...{
        'dash_user': dashboardUser!.trim(),
        'dash_pass': dashboardPassword!,
      },
    };
    return Uri(scheme: scheme, host: authority, queryParameters: q).toString();
  }

  /// Intenta parsear una URI de emparejado. Devuelve null si no es válida
  /// (esquema/authority incorrectos o faltan host/token).
  static PairingLink? tryParse(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    try {
      final uri = Uri.parse(text);
      if (uri.scheme.toLowerCase() != scheme) return null;
      if (uri.host.toLowerCase() != authority) return null;
      // Decode only the surviving fields. Unknown legacy values never become
      // object credentials, even when their encoding is malformed.
      const fields = {
        'host',
        'port',
        'token',
        'https',
        'dashboard',
        'label',
        'dash_user',
        'dash_pass',
      };
      final q = <String, String>{};
      for (final part in uri.query.split('&')) {
        final index = part.indexOf('=');
        final key = index < 0 ? part : part.substring(0, index);
        if (!fields.contains(key)) continue;
        final raw = index < 0 ? '' : part.substring(index + 1);
        if (key == 'dash_user' || key == 'dash_pass') {
          // Optional: a malformed Dashboard login is dropped, never a reason
          // to refuse the Gateway part of the link.
          try {
            q[key] = Uri.decodeQueryComponent(raw);
          } catch (_) {
            q.remove(key);
          }
          continue;
        }
        q[key] = Uri.decodeQueryComponent(raw);
      }
      final host = (q['host'] ?? '').trim();
      final token = (q['token'] ?? '').trim();
      if (host.isEmpty || token.isEmpty) return null;
      final port = int.tryParse((q['port'] ?? '').trim());
      if (port == null || port <= 0 || port > 65535) return null;
      final https = (q['https'] ?? '').trim();
      final dash = (q['dashboard'] ?? '').trim();
      final label = (q['label'] ?? '').trim();
      // A password keeps its exact characters; only the username is trimmed.
      final dashUser = (q['dash_user'] ?? '').trim();
      final dashPass = q['dash_pass'] ?? '';
      final dashLogin = dashUser.isNotEmpty && dashPass.isNotEmpty;
      return PairingLink(
        host: host,
        port: port,
        token: token,
        label: label.isEmpty ? null : label,
        useHttps: https == '1' || https.toLowerCase() == 'true',
        dashboardUrl: dash.isEmpty ? null : dash,
        dashboardUser: dashLogin ? dashUser : null,
        dashboardPassword: dashLogin ? dashPass : null,
      );
    } catch (_) {
      // Never log URI/FormatException text: it may contain credentials.
      return null;
    }
  }

  /// Borrador de instancia a precargar en el editor (el usuario revisa y guarda).
  SavedConnection toDraftConnection() {
    final lbl = (label != null && label!.trim().isNotEmpty)
        ? label!.trim()
        : host;
    return SavedConnection(
      id: 'pair_${DateTime.now().microsecondsSinceEpoch}',
      label: lbl,
      host: host,
      port: port,
      apiKey: token,
      useHttps: useHttps,
      dashboardUrl: (dashboardUrl != null && dashboardUrl!.trim().isNotEmpty)
          ? dashboardUrl!.trim()
          : null,
    );
  }
}
