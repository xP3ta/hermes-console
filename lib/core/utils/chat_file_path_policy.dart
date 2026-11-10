import 'chat_inline_refs.dart';

/// What decides if a file a reply names may be asked of the agent's machine:
/// the path is cleaned and made absolute here (never sent with `..`, a NUL, a
/// scheme or a Windows form), and the files that usually hold secrets are
/// told apart so the viewer asks before showing them. Pure Dart: no I/O, no
/// widgets. What the server allows is decided by the server; nothing here
/// widens it.

/// Why a path was refused before any request.
enum ChatPathProblem {
  empty,
  tooLong,

  /// A NUL, a control character or a bidirectional override.
  control,

  /// `file://`, `http://`, `C:\`… anything that is not a Posix path.
  scheme,

  /// A relative path with no absolute folder to start from.
  noBase,

  /// `..` above the root of the machine.
  escapesRoot,
}

/// A path ready to ask for, with the line it pointed at.
final class ChatResolvedPath {
  const ChatResolvedPath(this.path, {this.line, this.endLine});

  /// Absolute, with no `.`, `..` or empty segments.
  final String path;
  final int? line;
  final int? endLine;

  @override
  bool operator ==(Object other) =>
      other is ChatResolvedPath &&
      other.path == path &&
      other.line == line &&
      other.endLine == endLine;

  @override
  int get hashCode => Object.hash(path, line, endLine);

  @override
  String toString() => 'ChatResolvedPath($path:$line-$endLine)';
}

/// The outcome of [chatResolveFilePath]: the paths to try in order, or why
/// there are none.
final class ChatPathResolution {
  const ChatPathResolution.ok(this.candidates) : problem = null;
  const ChatPathResolution.refused(ChatPathProblem this.problem)
    : candidates = const [];

  final List<ChatResolvedPath> candidates;
  final ChatPathProblem? problem;

  bool get ok => problem == null && candidates.isNotEmpty;
  ChatResolvedPath? get first => candidates.isEmpty ? null : candidates.first;
}

/// Longest path asked of the server (what the routes themselves take).
const int chatFilePathMaxLength = 4096;

final RegExp _controlChars = RegExp(
  r'[\u0000-\u001F\u007F-\u009F\u202A-\u202E\u2066-\u2069]',
);
final RegExp _scheme = RegExp(r'^[A-Za-z][A-Za-z0-9+.\-]*:');
final RegExp _trailingLines = RegExp(
  r'^(.*?)(?::(\d{1,6})(?:-(\d{1,6})|:\d{1,6})?|#L(\d{1,6})(?:-L?(\d{1,6}))?)$',
);

/// Splits `a.dart:120`, `a.dart:10-20`, `a.dart:10:5`, `a.dart#L10` and
/// `a.dart#L10-L20` into the path and the lines. A path with no such suffix
/// comes back as it is.
(String, int?, int?) chatSplitLineSuffix(String raw) {
  final m = _trailingLines.firstMatch(raw);
  if (m == null) return (raw, null, null);
  final from = int.tryParse(m.group(2) ?? m.group(4) ?? '');
  final to = int.tryParse(m.group(3) ?? m.group(5) ?? '');
  if (from == null || from < 1 || m.group(1)!.isEmpty) {
    return (raw, null, null);
  }
  return (m.group(1)!, from, to != null && to >= from ? to : null);
}

/// [segments] of an absolute path with `.` and `..` applied; null when a
/// `..` would climb above the root.
List<String>? _collapse(Iterable<String> segments) {
  final out = <String>[];
  for (final s in segments) {
    if (s.isEmpty || s == '.') continue;
    if (s == '..') {
      if (out.isEmpty) return null;
      out.removeLast();
    } else {
      out.add(s);
    }
  }
  return out;
}

/// The home folder implied by [path] on the usual layouts
/// (`/home/<user>`, `/Users/<user>`, `/root`), or null when it cannot be
/// told. The agent's machine is not asked for it.
String? chatHomeFolderOf(String? path) {
  final p = path?.trim() ?? '';
  final parts = p.split('/').where((s) => s.isNotEmpty).toList();
  if (!p.startsWith('/') || parts.isEmpty) return null;
  final first = parts.first.toLowerCase();
  if (first == 'root') return '/root';
  if ((first == 'home' || first == 'users') && parts.length >= 2) {
    return '/${parts[0]}/${parts[1]}';
  }
  return null;
}

/// The path of [ref] (or of the raw text) as absolute candidates, in the
/// order to try them: the conversation's folder first, then [roots] (the
/// other folders the conversation may be about). An absolute path has one
/// candidate; `~/…` resolves against the home implied by [cwd] or [roots].
///
/// Refuses (no candidates) a path with a NUL or control character, a scheme
/// (`file:`, `http:`), a drive letter or a backslash, an over-long one, and a
/// `..` that would leave the machine's root. The result never holds `..`.
ChatPathResolution chatResolveFilePath(
  String raw, {
  String? cwd,
  List<String> roots = const [],
  int? line,
  int? endLine,
}) {
  var text = raw.trim();
  if (text.isEmpty) {
    return const ChatPathResolution.refused(ChatPathProblem.empty);
  }
  if (text.length > chatFilePathMaxLength) {
    return const ChatPathResolution.refused(ChatPathProblem.tooLong);
  }
  if (_controlChars.hasMatch(text)) {
    return const ChatPathResolution.refused(ChatPathProblem.control);
  }
  if (line == null) {
    final (path, from, to) = chatSplitLineSuffix(text);
    text = path;
    line = from;
    endLine = to;
  }
  if (text.contains('\\') || _scheme.hasMatch(text)) {
    return const ChatPathResolution.refused(ChatPathProblem.scheme);
  }
  List<String> bases() {
    final out = <String>[];
    for (final b in [cwd, ...roots]) {
      final base = b?.trim() ?? '';
      if (base.startsWith('/') && !out.contains(base)) out.add(base);
    }
    return out;
  }

  ChatPathResolution result(Iterable<List<String>?> options) {
    final seen = <String>{};
    final list = <ChatResolvedPath>[];
    var escaped = false;
    for (final parts in options) {
      if (parts == null) {
        escaped = true;
        continue;
      }
      final path = '/${parts.join('/')}';
      if (seen.add(path)) {
        list.add(ChatResolvedPath(path, line: line, endLine: endLine));
      }
    }
    if (list.isEmpty) {
      return ChatPathResolution.refused(
        escaped ? ChatPathProblem.escapesRoot : ChatPathProblem.noBase,
      );
    }
    return ChatPathResolution.ok(list);
  }

  if (text.startsWith('/')) return result([_collapse(text.split('/'))]);
  if (text == '~' || text.startsWith('~/')) {
    final home =
        chatHomeFolderOf(cwd) ??
        roots.map(chatHomeFolderOf).whereType<String>().firstOrNull;
    if (home == null) {
      return const ChatPathResolution.refused(ChatPathProblem.noBase);
    }
    return result([
      _collapse([...home.split('/'), ...text.split('/').skip(1)]),
    ]);
  }
  final starts = bases();
  if (starts.isEmpty) {
    return const ChatPathResolution.refused(ChatPathProblem.noBase);
  }
  return result([
    for (final base in starts)
      _collapse([...base.split('/'), ...text.split('/')]),
  ]);
}

/// The same for a recognised chip.
ChatPathResolution chatResolveRef(
  ChatFileRef ref, {
  String? cwd,
  List<String> roots = const [],
}) => chatResolveFilePath(
  ref.path,
  cwd: cwd,
  roots: roots,
  line: ref.line,
  endLine: ref.endLine,
);

/// Names of files that hold secrets, whatever the folder.
const Set<String> _sensitiveNames = {
  '.env',
  '.netrc',
  '_netrc',
  '.npmrc',
  '.pypirc',
  '.pgpass',
  '.my.cnf',
  '.git-credentials',
  '.htpasswd',
  '.dockercfg',
  'id_rsa',
  'id_dsa',
  'id_ecdsa',
  'id_ed25519',
  'id_xmss',
  'secrets.json',
  'secrets.yaml',
  'secrets.yml',
  'secrets.toml',
  'secret.json',
  'service-account.json',
  'authorized_keys',
  'known_hosts',
  'shadow',
  'master.key',
  'wp-config.php',
};

const Set<String> _sensitiveExtensions = {
  'pem',
  'key',
  'p12',
  'pfx',
  'jks',
  'keystore',
  'kdbx',
  'ppk',
  'gpg',
  'secret',
  'secrets',
  'token',
  'tfvars',
  'ovpn',
};

/// Folders whose whole content is private.
const Set<String> _sensitiveFolders = {'.ssh', '.gnupg', '.aws', '.kube'};

/// `.env.example` and the like.
const Set<String> _templateEnds = {'example', 'sample', 'template', 'dist'};

/// Whether [path] is a file that usually holds secrets (`.env`, private
/// keys, credentials, `.netrc`, tokens…): the viewer asks before it shows
/// one and never keeps its content. A name check, not a promise: other files
/// may hold secrets too.
bool isSensitiveChatPath(String path) {
  final parts = path.split('/').where((s) => s.isNotEmpty).toList();
  if (parts.isEmpty) return false;
  final name = parts.last.toLowerCase();
  final dot = name.lastIndexOf('.');
  final ext = dot > 0 ? name.substring(dot + 1) : '';
  // Templates and public keys carry no secret by design.
  if (_templateEnds.contains(ext) || ext == 'pub') return false;
  for (final folder in parts.take(parts.length - 1)) {
    if (_sensitiveFolders.contains(folder.toLowerCase())) return true;
  }
  if (_sensitiveNames.contains(name)) return true;
  if (name == '.env' || name.startsWith('.env.') || name.endsWith('.env')) {
    return true;
  }
  if (_sensitiveExtensions.contains(ext)) return true;
  if (name.startsWith('credentials') || name.startsWith('.credentials')) {
    return true;
  }
  if (name.startsWith('id_') && ext != 'pub') return true;
  if (name.startsWith('secret') && ext != 'md') return true;
  return false;
}

/// Whether the file the server says it served ([served]) is the one asked
/// for ([asked]) or sits inside one of [roots]. A different path outside
/// every folder of the conversation means the server followed a link out of
/// it: the viewer refuses to show it. An absolute path the user was shown
/// carries no such expectation. Only what the answer says can be told: a
/// server that reports the asked path for a link is not caught here.
bool chatServedPathEscapes({
  required String asked,
  required String served,
  required List<String> roots,
  required bool askedWasRelative,
}) {
  if (!askedWasRelative) return false;
  if (!served.startsWith('/')) return false;
  final cleaned = _collapse(served.split('/'));
  if (cleaned == null) return true;
  final normalized = '/${cleaned.join('/')}';
  if (normalized == asked) return false;
  for (final root in roots) {
    final base = '/${(_collapse(root.split('/')) ?? const []).join('/')}';
    if (base == '/') return false;
    if (normalized == base || normalized.startsWith('$base/')) return false;
    // The server may name the folder by its real path (a linked home): the
    // same tail under another prefix is that folder, not a way out of it.
    if (asked.startsWith('$base/') &&
        normalized.endsWith(asked.substring(base.length))) {
      return false;
    }
  }
  return true;
}
