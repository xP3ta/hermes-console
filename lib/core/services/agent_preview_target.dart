/// Where an agent «preview» (the `desktop_preview` tool's target) can be
/// opened from the phone.
///
/// Desktop shows these in an Electron webview next to the chat; Console has no
/// such surface, so each target is either handed to the system browser, opened
/// through the existing server-file flow, or declared reachable only from the
/// machine the agent runs on.
library;

enum AgentPreviewReach {
  /// `http(s)` on a public host: the system browser can open it.
  web,

  /// A file on the Hermes server: the existing server-file flow opens it.
  serverFile,

  /// `localhost`, loopback, `0.0.0.0`, private ranges: the agent's own
  /// machine, not reachable from here.
  serverOnly,
}

final class AgentPreviewTarget {
  const AgentPreviewTarget({
    required this.url,
    required this.reach,
    this.filePath,
  });

  /// Normalized target, the identity used to open and to close a preview.
  final String url;
  final AgentPreviewReach reach;

  /// Absolute server path for [AgentPreviewReach.serverFile].
  final String? filePath;
}

const int _maxTargetLength = 2048;

final RegExp _controlChars = RegExp(r'[\u0000-\u001f\u007f]');
final RegExp _windowsDrive = RegExp(r'^[A-Za-z]:[\\/]');
final RegExp _hasScheme = RegExp(r'^[A-Za-z][A-Za-z0-9+.-]*://');

/// Normalizes [raw] like the tool does (`www.x.com` → `https://www.x.com`,
/// `localhost:3000` → `http://localhost:3000`, paths and `file:` kept) and
/// classifies it. Null when it is not a usable preview target.
AgentPreviewTarget? classifyAgentPreviewTarget(String raw) {
  final value = raw.trim();
  if (value.isEmpty ||
      value.length > _maxTargetLength ||
      value.contains(_controlChars)) {
    return null;
  }
  if (value.toLowerCase().startsWith('file:')) return _fileUrl(value);
  if (_looksLikePath(value)) {
    return AgentPreviewTarget(
      url: value,
      reach: AgentPreviewReach.serverFile,
      filePath: value,
    );
  }

  final String candidate;
  if (_hasScheme.hasMatch(value)) {
    candidate = value;
  } else if (value.contains(':') && !_bareHostPort.hasMatch(value)) {
    // `javascript:…`, `mailto:…`, `data:…`: a scheme without `//`.
    return null;
  } else {
    candidate = 'http://$value';
  }
  final parsed = Uri.tryParse(candidate);
  if (parsed == null || parsed.host.isEmpty || parsed.userInfo.isNotEmpty) {
    return null;
  }
  final scheme = parsed.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return null;

  final serverOnly = _isServerOnlyHost(parsed.host);
  // The tool defaults a bare host to http for the machine itself and https
  // for everything else.
  final uri = _hasScheme.hasMatch(value)
      ? parsed
      : Uri.tryParse('${serverOnly ? 'http' : 'https'}://$value');
  if (uri == null) return null;
  return AgentPreviewTarget(
    url: _canonicalWebUrl(uri),
    reach: serverOnly ? AgentPreviewReach.serverOnly : AgentPreviewReach.web,
  );
}

/// One spelling per target, so a `close` finds the `open` it undoes: scheme
/// and host in lower case, the scheme's default port dropped.
String _canonicalWebUrl(Uri uri) {
  final scheme = uri.scheme.toLowerCase();
  final host = uri.host.contains(':') ? '[${uri.host}]' : uri.host;
  final defaultPort = scheme == 'https' ? 443 : 80;
  final port = uri.hasPort && uri.port != defaultPort ? ':${uri.port}' : '';
  final query = uri.hasQuery ? '?${uri.query}' : '';
  final fragment = uri.hasFragment ? '#${uri.fragment}' : '';
  return '$scheme://$host$port${uri.path}$query$fragment';
}

final RegExp _numericLabel = RegExp(r'^(?:0x[0-9a-f]+|\d+)$');
final RegExp _bareHostPort = RegExp(r'^[^/?#\s:]+:\d{1,5}(?:[/?#].*)?$');

bool _looksLikePath(String value) =>
    value.startsWith('/') ||
    value.startsWith('~/') ||
    value.startsWith('./') ||
    value.startsWith('../') ||
    value.startsWith(r'\\') ||
    _windowsDrive.hasMatch(value);

AgentPreviewTarget? _fileUrl(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null || uri.scheme.toLowerCase() != 'file') return null;
  final String path;
  try {
    path = Uri.decodeComponent(uri.path);
  } on ArgumentError {
    return null;
  }
  if (!path.startsWith('/') ||
      path.length < 2 ||
      path.contains(_controlChars)) {
    return null;
  }
  return AgentPreviewTarget(
    url: value,
    reach: AgentPreviewReach.serverFile,
    filePath: path,
  );
}

/// Hosts the phone cannot (or must not) reach on the agent's behalf. When in
/// doubt a host is server-only: a tile that does not open is harmless, a tile
/// that reaches a private address is not.
bool _isServerOnlyHost(String rawHost) {
  var host = rawHost.toLowerCase();
  if (host.endsWith('.')) host = host.substring(0, host.length - 1);
  if (host.isEmpty) return true;
  if (host == 'localhost' ||
      host.endsWith('.localhost') ||
      host.endsWith('.local') ||
      host.endsWith('.internal') ||
      host.endsWith('.lan') ||
      host.endsWith('.home.arpa') ||
      host.endsWith('.ts.net')) {
    return true;
  }
  if (host.contains(':')) return _isServerOnlyIpv6(host);
  // A numeric host in any notation (`2130706433`, `0x7f.1`, `012.0.0.1`,
  // `127.1`) is read by a browser as an address that may be private: only a
  // canonical dotted quad is judged by range, everything else is refused.
  final labels = host.split('.');
  if (labels.every((label) => _numericLabel.hasMatch(label))) {
    final octets = _dottedQuad(host);
    return octets == null || _isServerOnlyIpv4(octets);
  }
  // A single label has no public DNS name (`intranet`, `printer`).
  return labels.length == 1;
}

/// Four decimal octets without leading zeros (`012` is octal to a browser).
List<int>? _dottedQuad(String host) {
  final parts = host.split('.');
  if (parts.length != 4) return null;
  final octets = <int>[];
  for (final part in parts) {
    if (!RegExp(r'^(?:0|[1-9]\d{0,2})$').hasMatch(part)) return null;
    final value = int.parse(part);
    if (value > 255) return null;
    octets.add(value);
  }
  return octets;
}

bool _isServerOnlyIpv4(List<int> o) {
  final a = o[0];
  final b = o[1];
  return a == 0 || // 0.0.0.0/8, including 0.0.0.0
      a == 10 ||
      a == 127 ||
      (a == 100 && b >= 64 && b <= 127) || // CGNAT / Tailscale
      (a == 169 && b == 254) || // link-local, cloud metadata
      (a == 172 && b >= 16 && b <= 31) ||
      (a == 192 && b == 168) ||
      a >= 224; // multicast, reserved, broadcast
}

bool _embeddedIpv4ServerOnly(int high, int low) =>
    _isServerOnlyIpv4([high >> 8, high & 0xff, low >> 8, low & 0xff]);

bool _isServerOnlyIpv6(String host) {
  final groups = _parseIpv6(host);
  if (groups == null) return true; // zone ids and anything odd: refuse
  final g = groups;
  final zeroHead = g.take(5).every((group) => group == 0);
  // `::`, `::1`, IPv4-compatible `::a.b.c.d` and IPv4-mapped `::ffff:a.b.c.d`
  // in every spelling (dotted, hex, expanded): judge the embedded address.
  if (zeroHead && (g[5] == 0 || g[5] == 0xffff)) {
    return _embeddedIpv4ServerOnly(g[6], g[7]);
  }
  // NAT64 `64:ff9b::/96` and 6to4 `2002::/16` carry an IPv4 address too.
  if (g[0] == 0x64 &&
      g[1] == 0xff9b &&
      g.skip(2).take(4).every((group) => group == 0)) {
    return _embeddedIpv4ServerOnly(g[6], g[7]);
  }
  if (g[0] == 0x2002) return _embeddedIpv4ServerOnly(g[1], g[2]);
  return (g[0] & 0xfe00) == 0xfc00 || // fc00::/7 unique local
      (g[0] & 0xffc0) == 0xfe80 || // fe80::/10 link-local
      (g[0] & 0xffc0) == 0xfec0 || // fec0::/10 site-local
      (g[0] & 0xff00) == 0xff00; // multicast
}

/// The eight 16-bit groups of [host], or null when it is not an IPv6 literal.
List<int>? _parseIpv6(String host) {
  if (host.contains('%')) return null;
  final compression = host.indexOf('::');
  if (compression != host.lastIndexOf('::')) return null;

  List<int>? side(String text) {
    if (text.isEmpty) return <int>[];
    final groups = <int>[];
    final tokens = text.split(':');
    for (var i = 0; i < tokens.length; i++) {
      final token = tokens[i];
      if (i == tokens.length - 1 && token.contains('.')) {
        final octets = _dottedQuad(token);
        if (octets == null) return null;
        groups
          ..add(octets[0] << 8 | octets[1])
          ..add(octets[2] << 8 | octets[3]);
        continue;
      }
      if (!RegExp(r'^[0-9a-f]{1,4}$').hasMatch(token)) return null;
      groups.add(int.parse(token, radix: 16));
    }
    return groups;
  }

  if (compression < 0) {
    final all = side(host);
    return all != null && all.length == 8 ? all : null;
  }
  final head = side(host.substring(0, compression));
  final tail = side(host.substring(compression + 2));
  if (head == null || tail == null || head.length + tail.length > 7) {
    return null;
  }
  return [...head, ...List.filled(8 - head.length - tail.length, 0), ...tail];
}
