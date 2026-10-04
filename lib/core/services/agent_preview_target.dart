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
  final uri = Uri.tryParse(candidate);
  if (uri == null || uri.host.isEmpty) return null;
  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return null;

  final serverOnly = _isServerOnlyHost(uri.host);
  // The tool defaults a bare host to http for the machine itself and https
  // for everything else.
  final url = _hasScheme.hasMatch(value)
      ? value
      : '${serverOnly ? 'http' : 'https'}://$value';
  return AgentPreviewTarget(
    url: url,
    reach: serverOnly ? AgentPreviewReach.serverOnly : AgentPreviewReach.web,
  );
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
  if (!path.startsWith('/') || path.length < 2) return null;
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
  // A numeric host in any notation (`2130706433`, `0x7f.1`, `127.1`) can
  // hide a loopback address: only a plain dotted quad is judged by range.
  final labels = host.split('.');
  if (labels.every((label) => _numericLabel.hasMatch(label))) {
    final octets = _dottedQuad(host);
    return octets == null || _isServerOnlyIpv4(octets);
  }
  // A single label has no public DNS name (`intranet`, `printer`).
  return !host.contains('.');
}

List<int>? _dottedQuad(String host) {
  final parts = host.split('.');
  if (parts.length != 4) return null;
  final octets = <int>[];
  for (final part in parts) {
    if (!RegExp(r'^\d{1,3}$').hasMatch(part)) return null;
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

bool _isServerOnlyIpv6(String host) {
  final address = host.startsWith('[')
      ? host.substring(1, host.length - 1)
      : host;
  final lower = address.toLowerCase();
  if (lower == '::' || lower == '::1') return true;
  // IPv4-mapped (`::ffff:127.0.0.1`): judge the embedded address.
  final mapped = RegExp(
    r'^(?:0:0:0:0:0:|::)ffff:(\d+\.\d+\.\d+\.\d+)$',
  ).firstMatch(lower);
  if (mapped != null) {
    final octets = _dottedQuad(mapped.group(1)!);
    return octets == null || _isServerOnlyIpv4(octets);
  }
  final first = lower.split(':').first;
  final head = first.isEmpty ? 0 : int.tryParse(first, radix: 16);
  if (head == null) return true;
  return (head & 0xfe00) == 0xfc00 || // fc00::/7 unique local
      (head & 0xffc0) == 0xfe80 || // fe80::/10 link-local
      (head & 0xff00) == 0xff00; // multicast
}
