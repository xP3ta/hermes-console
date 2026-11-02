/// Paths belong to the remote host, not to Android's POSIX filesystem.
/// Windows paths use native separators; Unix paths remain case-sensitive.
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

String serverPathChild(String parent, String name) {
  final parsed = _ServerPath.parse(parent);
  if (parsed == null) throw ArgumentError.value(parent, 'parent');
  if (name.isEmpty ||
      name == '.' ||
      name == '..' ||
      name.contains('/') ||
      (parsed.windows && name.contains(r'\'))) {
    throw ArgumentError.value(name, 'name');
  }
  return parsed.withParts([...parsed.parts, name]).path;
}

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

  static _ServerPath? parse(String raw) {
    final value = raw.trim();
    if (value.isEmpty || value.contains('\u0000')) return null;
    final String root;
    final String rest;
    final bool windows;
    final unc = value.replaceAll(r'\', '/');
    final uncMatch = RegExp(r'^//([^/]+)/([^/]+)(?:/|$)').firstMatch(unc);
    // A leading // is also valid on POSIX. Only the native UNC prefix is
    // unambiguous without knowing the server's operating system.
    if (RegExp(r'^[a-zA-Z]:[/\\]').hasMatch(value)) {
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
      windows = true;
      root = '\\\\$host\\$share\\';
      rest = unc.substring(uncMatch.end);
    } else if (value.startsWith('/')) {
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
        parts.add(part);
      }
    }
    return _ServerPath(root, parts, windows: windows);
  }
}
