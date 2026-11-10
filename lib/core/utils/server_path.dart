/// Paths belong to the remote host, not to Android's POSIX filesystem.
/// Windows paths use native separators; Unix paths remain case-sensitive.
///
/// Parsing is purely lexical and never throws: anything that is not an
/// absolute path of the server (relative, `~`, `%VAR%`, drive-relative
/// `D:foo`, `\\?\` / `\\.\` device namespaces, control characters,
/// `..` above the drive/share/root, invalid Windows names such as `CON`,
/// `a:stream`, `name.` or `name `) is rejected. The server still decides what
/// a path really resolves to (8.3 short names, symlinks, junctions).
bool isAbsoluteServerPath(String path) => _ServerPath.parse(path) != null;

String normalizeServerPath(String path) =>
    _ServerPath.parse(path)?.path ?? path.trim();

String serverPathRoot(String path) => _ServerPath.parse(path)?.root ?? '/';

String serverPathBaseName(String path) {
  final parsed = _ServerPath.parse(path);
  if (parsed == null) return path.trim();
  return parsed.parts.isEmpty ? parsed.root : parsed.parts.last;
}

String serverPathParent(String path) {
  final parsed = _ServerPath.parse(path);
  if (parsed == null || parsed.parts.isEmpty) return normalizeServerPath(path);
  return parsed.withParts(parsed.parts.take(parsed.parts.length - 1)).path;
}

/// Joins [name] under [parent]; throws [ArgumentError] when either is not
/// usable. Use [serverPathTryChild] for text that comes from outside.
String serverPathChild(String parent, String name) {
  final parsed = _ServerPath.parse(parent);
  if (parsed == null) throw ArgumentError.value(parent, 'parent');
  final joined = serverPathTryChild(parent, name);
  if (joined == null) throw ArgumentError.value(name, 'name');
  return joined;
}

/// Like [serverPathChild] but returns null instead of throwing. [name] must be
/// one plain entry name for the host that owns [parent].
String? serverPathTryChild(String parent, String name) {
  final parsed = _ServerPath.parse(parent);
  if (parsed == null) return null;
  if (!_ServerPath.validEntryName(name, windows: parsed.windows)) return null;
  final child = parsed.withParts([...parsed.parts, name]).path;
  return _ServerPath.parse(child) == null ? null : child;
}

/// Whether [name] is one plain entry name on the host that owns [parent].
bool isValidServerEntryName(String parent, String name) =>
    serverPathTryChild(parent, name) != null;

/// Stable key to compare two server paths the way their host does.
String serverPathKey(String path) =>
    _ServerPath.parse(path)?.key ??
    path.trim().replaceAll(RegExp(r'[/\\]+$'), '');

bool serverPathsEqual(String first, String second) {
  final a = _ServerPath.parse(first);
  final b = _ServerPath.parse(second);
  return a != null && b != null && a.key == b.key;
}

/// Compare normalized components, so sibling names and `..` cannot escape a
/// project root. Windows accepts either separator and compares without case.
bool serverPathIsWithin(String root, String path) {
  final base = _ServerPath.parse(root);
  final target = _ServerPath.parse(path);
  if (base == null || target == null || base.windows != target.windows) {
    return false;
  }
  final baseKey = base.key;
  final prefix = baseKey.endsWith(base.separator)
      ? baseKey
      : '$baseKey${base.separator}';
  return target.key == baseKey || target.key.startsWith(prefix);
}

List<(String, String)> serverPathBreadcrumbs(String root, String path) {
  final base = _ServerPath.parse(root);
  final target = _ServerPath.parse(path);
  final out = <(String, String)>[
    (serverPathBaseName(root), normalizeServerPath(root)),
  ];
  if (base == null || target == null || !serverPathIsWithin(root, path)) {
    return out;
  }
  var current = base;
  for (final part in target.parts.skip(base.parts.length)) {
    current = current.withParts([...current.parts, part]);
    out.add((part, current.path));
  }
  return out;
}

/// Longest Windows path (`\\?\` limit); no host accepts more.
const int _maxServerPathLength = 32767;
final RegExp _controlChars = RegExp(r'[\x00-\x1F\x7F]');
final RegExp _driveRoot = RegExp(r'^[a-zA-Z]:[/\\]');
final RegExp _uncRoot = RegExp(r'^//([^/]+)/([^/]+)(?:/|$)');
final RegExp _posixDeviceLike = RegExp(r'^//[.?](?:/|$)');
final RegExp _windowsBadChars = RegExp(r'[<>:"|?*]');
final RegExp _windowsDevice = RegExp(
  r'^(con|prn|aux|nul|com[0-9\u00B9\u00B2\u00B3]|lpt[0-9\u00B9\u00B2\u00B3]|conin\$|conout\$)$',
  caseSensitive: false,
);

final class _ServerPath {
  final String root;
  final List<String> parts;
  final bool windows;

  const _ServerPath(this.root, this.parts, {required this.windows});

  String get separator => windows ? r'\' : '/';
  String get path => '$root${parts.join(separator)}';
  String get key => windows ? path.toLowerCase() : path;

  _ServerPath withParts(Iterable<String> parts) =>
      _ServerPath(root, parts.toList(growable: false), windows: windows);

  /// One entry name: no separators, no control characters and, on Windows,
  /// none of `<>:"|?*` (so no `file:stream`), no trailing dot or space and no
  /// device names (`CON`, `NUL`, `AUX`, `COM1`... with or without extension).
  static bool validEntryName(String name, {required bool windows}) {
    if (name.isEmpty ||
        name == '.' ||
        name == '..' ||
        name.length > 255 ||
        name.contains('/') ||
        name.contains(_controlChars)) {
      return false;
    }
    if (!windows) return true;
    if (name.contains(r'\') ||
        name.contains(_windowsBadChars) ||
        name.endsWith(' ') ||
        name.endsWith('.')) {
      return false;
    }
    return !_windowsDevice.hasMatch(name.split('.').first.trimRight());
  }

  static _ServerPath? parse(String raw) {
    final value = raw.trim();
    if (value.isEmpty ||
        value.length > _maxServerPathLength ||
        value.contains(_controlChars)) {
      return null;
    }
    final String root;
    final String rest;
    final bool windows;
    final unc = value.replaceAll(r'\', '/');
    final uncMatch = _uncRoot.firstMatch(unc);
    // A leading // is also valid on POSIX. Only the native UNC prefix is
    // unambiguous without knowing the server's operating system.
    if (_driveRoot.hasMatch(value)) {
      windows = true;
      root = '${value.substring(0, 2)}\\';
      rest = value.substring(3).replaceAll(r'\', '/');
    } else if (value.startsWith(r'\\')) {
      if (uncMatch == null) return null;
      final host = uncMatch.group(1)!;
      final share = uncMatch.group(2)!;
      // Device namespaces have different semantics from ordinary UNC shares.
      if (host == '.' ||
          host == '?' ||
          host == '..' ||
          share == '.' ||
          share == '..') {
        return null;
      }
      if (host.contains(_windowsBadChars) || share.contains(_windowsBadChars)) {
        return null;
      }
      windows = true;
      root = '\\\\$host\\$share\\';
      rest = unc.substring(uncMatch.end);
    } else if (value.startsWith('/')) {
      // `//?/` and `//./` are device namespaces on a Windows host.
      if (_posixDeviceLike.hasMatch(value)) return null;
      windows = false;
      root = '/';
      rest = value.substring(1);
    } else {
      return null;
    }
    final parts = <String>[];
    for (final part in rest.split('/')) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') {
        if (parts.isEmpty) return null;
        parts.removeLast();
      } else {
        if (!validEntryName(part, windows: windows)) return null;
        parts.add(part);
      }
    }
    return _ServerPath(root, parts, windows: windows);
  }
}
