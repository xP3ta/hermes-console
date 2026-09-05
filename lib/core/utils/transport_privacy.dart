/// Clasificación de privacidad de transporte para la URL de un servidor
/// Hermes (gateway o dashboard), usada para avisar al usuario cuando una
/// conexión viajaría en claro (sin TLS) fuera de una red que controla.
///
/// La app permite cleartext (http/ws) porque el destino siempre lo elige el
/// propio usuario (self-hosted) y `network_security_config.xml` no puede
/// acotar el permiso por rango de IP. Esta clasificación es la mitigación de
/// UX: distingue "cleartext en red privada" (razonable: LAN, Tailscale,
/// localhost) de "cleartext hacia un host público" (el token y los mensajes
/// viajarían en claro por Internet).
enum TransportPrivacyClass {
  /// https:// o wss://: el transporte está cifrado, sin más que avisar.
  secure,

  /// http:// o ws:// hacia un host de red privada (loopback, LAN, CGNAT de
  /// Tailscale o `*.ts.net`). Cleartext pero dentro de una red que el
  /// usuario controla.
  privateCleartext,

  /// http:// o ws:// hacia cualquier otro host (dominio o IP pública). El
  /// token y las conversaciones viajarían en claro por una red no confiable.
  publicCleartext,
}

/// Helper puro (sin estado, sin I/O) para clasificar la privacidad de
/// transporte de una URL de servidor tal como la escribe el usuario.
class TransportPrivacy {
  const TransportPrivacy._();

  /// Clasifica [url] según su esquema y, si es cleartext, según si el host
  /// es de red privada o público.
  ///
  /// Acepta URLs sin esquema (p.ej. `192.168.1.5:8642`): se asume `http://`
  /// como la app hace al normalizar (ver `SavedConnection.normalizeHostAndPort`).
  /// URLs vacías o irreconocibles devuelven [TransportPrivacyClass.secure]
  /// (no hay host que avisar todavía).
  static TransportPrivacyClass classify(String url) {
    var raw = url.trim();
    if (raw.isEmpty) return TransportPrivacyClass.secure;

    if (!raw.contains('://')) {
      // Host IPv6 sin corchetes (p.ej. "::1" o "::1:8642" no es ambiguo,
      // pero para simplificar detectamos "más de un ':'" como IPv6 literal
      // y lo entrecomillamos para que Uri.parse lo acepte).
      if (!raw.startsWith('[') && ':'.allMatches(raw).length > 1) {
        raw = '[$raw]';
      }
      raw = 'http://$raw';
    }

    final uri = Uri.tryParse(raw);
    if (uri == null || uri.host.isEmpty) return TransportPrivacyClass.secure;

    final scheme = uri.scheme.toLowerCase();
    if (scheme == 'https' || scheme == 'wss') {
      return TransportPrivacyClass.secure;
    }
    return _isPrivateHost(uri.host)
        ? TransportPrivacyClass.privateCleartext
        : TransportPrivacyClass.publicCleartext;
  }

  /// Límite efectivo de release: HTTP/WS solo se acepta para loopback, LAN o
  /// Tailscale. La network security config de Android no entiende CIDR, así que
  /// esta comprobación debe ejecutarse antes de construir cualquier cliente.
  static String requireAllowed(String url) {
    if (classify(url) == TransportPrivacyClass.publicCleartext) {
      throw ArgumentError(
        'Public HTTP/WS blocked: configure HTTPS/WSS or use a private/Tailscale address.',
      );
    }
    return url;
  }

  /// True si [host] pertenece a una red que el usuario controla directamente:
  /// loopback, LAN privada (RFC 1918), CGNAT de Tailscale (100.64.0.0/10),
  /// MagicDNS de Tailscale (`*.ts.net`) o `localhost`/`*.local`.
  static bool _isPrivateHost(String host) {
    final h = host.toLowerCase();
    if (h.isEmpty) return false;
    if (h == 'localhost' || h.endsWith('.local')) return true;
    if (h.endsWith('.ts.net')) return true;
    if (!h.contains('.') || h.endsWith('.test') || h.endsWith('.example')) {
      return true;
    }
    if (h == '::1') return true;

    final octets = _ipv4Octets(h);
    if (octets == null) return false;
    final a = octets[0];
    final b = octets[1];
    if (a == 127) return true; // loopback 127.0.0.0/8
    if (a == 10) return true; // LAN 10.0.0.0/8
    if (a == 172 && b >= 16 && b <= 31) return true; // LAN 172.16.0.0/12
    if (a == 192 && b == 168) return true; // LAN 192.168.0.0/16
    if (a == 100 && b >= 64 && b <= 127) {
      return true; // CGNAT/Tailscale 100.64.0.0/10
    }
    return false;
  }

  /// Devuelve los 4 octetos de [host] si es una IPv4 literal, o null.
  static List<int>? _ipv4Octets(String host) {
    final parts = host.split('.');
    if (parts.length != 4) return null;
    final octets = <int>[];
    for (final p in parts) {
      final n = int.tryParse(p);
      if (n == null || n < 0 || n > 255) return null;
      octets.add(n);
    }
    return octets;
  }
}
