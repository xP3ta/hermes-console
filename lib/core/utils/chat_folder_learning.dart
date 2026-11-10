import '../models/deferred_tool_call.dart';
import 'chat_file_path_policy.dart';

/// The folders a conversation has been about, learned from what it already
/// holds: the absolute paths the agent's tools were given (`workdir`, `cwd`,
/// `path`, `file_path`… of a terminal, a read, a write, a patch) and the
/// absolute paths its replies cite. A reply that names `pair.py` after
/// working in another repository than the conversation's folder is resolved
/// against these folders too. Pure Dart: no I/O, no widgets, nothing is
/// asked of the agent's machine. Called when a chip is tapped, never while
/// a message is built.

/// Most folders handed to the opener.
const int chatLearnedFolderLimit = 24;

/// Most transcript rows read for paths.
const int chatLearnedFolderMaxRows = 400;

/// Most raw paths kept from the transcript.
const int chatLearnedPathLimit = 64;

/// Above a file's folder, how many parents are learned too (`docs/sync/x.md`
/// is usually said from the repository root, not from the folder of the file
/// the tool last touched).
const int chatLearnedAncestorLevels = 4;

/// Tool arguments that name a file or a folder, as the Hermes tools call
/// them (`terminal {command, workdir}`, `read_file {path}`, `write_file
/// {path}`, `patch {path}`, `search_files {path}`…).
const Set<String> _pathArgumentKeys = {
  'workdir',
  'cwd',
  'working_dir',
  'working_directory',
  'directory',
  'dir',
  'path',
  'file_path',
  'filepath',
  'file',
  'filename',
  'target',
  'root',
};

/// Arguments that hold a shell command: absolute paths inside are learned
/// too (`cd /srv/x && …`).
const Set<String> _commandArgumentKeys = {'command', 'cmd', 'script'};

/// Pseudo file systems: never a folder of the conversation.
const Set<String> _neverLearned = {'/dev', '/proc', '/sys'};

final RegExp _controlChars = RegExp(
  r'[\u0000-\u001F\u007F-\u009F\u202A-\u202E\u2066-\u2069]',
);

/// A URL, dropped before paths are read from prose (`https://x/y/z` holds
/// no folder of the machine).
final RegExp _url = RegExp(
  r'\b[A-Za-z][A-Za-z0-9+.\-]*://[^\s)\]>"'
  "'"
  r']+',
);

/// An absolute Posix path with at least two segments, not glued to a word
/// or another path on its left.
final RegExp _absolutePath = RegExp(
  r'(?<![\w/~.\-\\])/(?:[\w.@+\-]+/)+[\w.@+\-]*',
);

/// Characters a sentence hangs on a path's end (`/srv/a/b.py.` or
/// `(/srv/a/b)`), never part of the name as written.
final RegExp _trailingPunctuation = RegExp(
  r'[.,;:!?)\]}>'
  "'"
  r'"`]+$',
);

/// [raw] as a clean absolute path (`.` and `..` applied, no empty segment,
/// no trailing `/`), or null when it is not one: relative, with a NUL or
/// control character, a backslash, over-long, a `..` above the root, or a
/// pseudo file system.
String? chatCleanAbsolutePath(String raw) {
  final text = raw.trim();
  if (text.isEmpty ||
      text.length > chatFilePathMaxLength ||
      !text.startsWith('/') ||
      text.contains('\\') ||
      _controlChars.hasMatch(text)) {
    return null;
  }
  final out = <String>[];
  for (final segment in text.split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') {
      if (out.isEmpty) return null;
      out.removeLast();
      continue;
    }
    out.add(segment);
  }
  if (out.isEmpty) return null;
  final path = '/${out.join('/')}';
  for (final banned in _neverLearned) {
    if (path == banned || path.startsWith('$banned/')) return null;
  }
  return path;
}

/// The absolute paths [text] names, in order of appearance, each at most
/// once. URLs are skipped; a trailing `.` or `)` is not part of the path.
List<String> chatAbsolutePathsInText(String text, {int limit = 16}) {
  if (text.isEmpty || !text.contains('/')) return const [];
  final out = <String>[];
  final seen = <String>{};
  // Bounded: a very long reply is read only in part.
  final source = text.length > 64 * 1024 ? text.substring(0, 64 * 1024) : text;
  final cleaned = source.replaceAll(_url, ' ');
  for (final match in _absolutePath.allMatches(cleaned)) {
    if (out.length >= limit) break;
    final raw = match.group(0)!.replaceFirst(_trailingPunctuation, '');
    final path = chatCleanAbsolutePath(raw);
    if (path != null && seen.add(path)) out.add(path);
  }
  return out;
}

/// The absolute paths one tool call was given: its path-like arguments
/// first, then the ones inside its command. [args] may be the decoded map
/// or the JSON text the transcript keeps. A deferred-tool bridge call
/// (`tool_call {calls: […]}`) yields the paths of every tool it wraps.
List<String> chatToolArgumentPaths(String tool, Object? args, {int limit = 8}) {
  final wrapped = unwrapDeferredToolCall(tool, args);
  if (wrapped != null) {
    final out = <String>[];
    for (final call in wrapped) {
      for (final path in chatToolArgumentPaths(call.name, call.arguments)) {
        if (out.length >= limit) return out;
        if (!out.contains(path)) out.add(path);
      }
    }
    return out;
  }
  final decoded = decodeToolArguments(args);
  if (decoded is! Map) return const [];
  final out = <String>[];
  void add(String? path) {
    if (path != null && out.length < limit && !out.contains(path)) {
      out.add(path);
    }
  }

  for (final key in _pathArgumentKeys) {
    final value = decoded[key];
    if (value is String) add(chatCleanAbsolutePath(value));
  }
  for (final key in _commandArgumentKeys) {
    final value = decoded[key];
    if (value is String) chatAbsolutePathsInText(value, limit: 4).forEach(add);
  }
  return out;
}

/// The absolute paths a transcript (newest row first, as the chat keeps it)
/// names: the arguments of every tool call its assistant rows carry and the
/// paths their text cites. Newest first; each path once; at most [limit]
/// paths from at most [maxRows] rows.
List<String> chatTranscriptFilePaths(
  Iterable<Map<String, dynamic>> rowsNewestFirst, {
  int maxRows = chatLearnedFolderMaxRows,
  int limit = chatLearnedPathLimit,
}) {
  final out = <String>[];
  final seen = <String>{};
  void add(String path) {
    if (out.length < limit && seen.add(path)) out.add(path);
  }

  var rows = 0;
  for (final row in rowsNewestFirst) {
    if (rows++ >= maxRows || out.length >= limit) break;
    if (row['role'] != 'assistant') continue;
    final calls = row['tool_calls'];
    if (calls is List) {
      for (final call in calls) {
        if (call is! Map) continue;
        final function = call['function'];
        final name = (function is Map ? function['name'] : call['name'])
            ?.toString();
        if (name == null || name.isEmpty) continue;
        final args = function is Map
            ? function['arguments']
            : (call['arguments'] ?? call['args']);
        chatToolArgumentPaths(name, args).forEach(add);
      }
    }
    for (final key in const ['display_content', 'content']) {
      final text = row[key];
      if (text is String) chatAbsolutePathsInText(text).forEach(add);
    }
  }
  return out;
}

/// The folders to try for a file a reply names, from the paths the
/// conversation knows ([pathsNewestFirst], files or folders): each path's
/// own folder first, then up to [ancestorLevels] parents of it, never the
/// home folder itself nor anything above the second segment (`/srv/x`), and
/// never a folder of [known] (the conversation's own, already tried). At
/// most [limit] folders, newest first, each once.
List<String> chatLearnFolders(
  Iterable<String> pathsNewestFirst, {
  List<String> known = const [],
  int limit = chatLearnedFolderLimit,
  int ancestorLevels = chatLearnedAncestorLevels,
}) {
  final skip = <String>{for (final k in known) ?chatCleanAbsolutePath(k)};
  final out = <String>[];
  for (final raw in pathsNewestFirst) {
    if (out.length >= limit) break;
    final path = chatCleanAbsolutePath(raw);
    if (path == null) continue;
    final home = chatHomeFolderOf(path);
    final parts = path.split('/').where((s) => s.isNotEmpty).toList();
    // A path with an extension is a file: its folder is the first learned.
    // A folder (no extension on its last segment) is a candidate itself.
    final last = parts.last;
    final looksLikeFile = last.contains('.') && !last.startsWith('.');
    var depth = looksLikeFile ? parts.length - 1 : parts.length;
    var levels = 0;
    while (depth >= 2 && levels <= ancestorLevels && out.length < limit) {
      final folder = '/${parts.take(depth).join('/')}';
      if (folder == home) break;
      if (!skip.contains(folder)) {
        skip.add(folder);
        out.add(folder);
      }
      depth--;
      levels++;
    }
  }
  return out;
}
