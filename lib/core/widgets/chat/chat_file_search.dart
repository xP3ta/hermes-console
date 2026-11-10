import 'dart:async';

import '../../models/project_files.dart';
import '../../services/desktop_control_gateway.dart';
import '../../utils/chat_folder_learning.dart';

/// The last resort for a name a reply drops (`pair.py`, `docs/sync/x.md`)
/// that is in none of the folders it was tried in: a small, bounded walk of
/// the folders the conversation is known to be about, through the listing
/// route it already uses (`/api/fs/list`), looking for a file whose path
/// ends with that name. Nothing outside those folders is ever listed, and a
/// link the server reports as pointing elsewhere is not followed.

/// Deepest folder listed below a starting folder.
const int chatFileSearchMaxDepth = 4;

/// Most entries read in one search, over every folder.
const int chatFileSearchMaxEntries = 300;

/// Most matches kept; past this the name is too common to choose from.
const int chatFileSearchMaxHits = 8;

/// The whole search, listings included, ends by this.
const Duration chatFileSearchTimeout = Duration(seconds: 8);

/// Folders never listed: generated, dependencies, version control.
const Set<String> chatFileSearchSkippedFolders = {
  'node_modules',
  '.git',
  'build',
  '.dart_tool',
  'venv',
  '.venv',
  '__pycache__',
  '.gradle',
  '.idea',
};

/// What a search found.
final class ChatFileSearchResult {
  const ChatFileSearchResult({
    required this.hits,
    required this.searched,
    required this.exhausted,
  });

  /// Absolute paths of the files that match, most recent folder first.
  final List<String> hits;

  /// The starting folders that were listed (said when nothing is found).
  final List<String> searched;

  /// True when the walk ended for lack of budget (entries or time), so a
  /// miss does not mean the file is not there.
  final bool exhausted;

  static const none = ChatFileSearchResult(
    hits: [],
    searched: [],
    exhausted: false,
  );
}

/// Whether [path] is [folder] or sits inside it.
bool _inside(String path, String folder) =>
    path == folder || path.startsWith('$folder/');

/// Whether [path] ends with `/[relative]`.
bool _matches(String path, String relative) =>
    path.length > relative.length + 1 &&
    path.endsWith(relative) &&
    path[path.length - relative.length - 1] == '/';

/// Looks for a file whose path ends with [relative] (a bare name or a
/// relative path, as the reply wrote it, already free of `..`) inside
/// [folders], in their order, breadth first. Stops at [maxDepth] below each
/// folder, after [maxEntries] entries in all, at [timeout], when [cancelled]
/// says so, or once [maxHits] files match. A folder the server cannot list
/// is skipped; a server without the route ends the search. A folder already
/// listed from another start is not listed twice.
Future<ChatFileSearchResult> chatFindFileByName({
  required HermesProjectFilesGateway files,
  required String relative,
  required List<String> folders,
  int maxDepth = chatFileSearchMaxDepth,
  int maxEntries = chatFileSearchMaxEntries,
  int maxHits = chatFileSearchMaxHits,
  Duration timeout = chatFileSearchTimeout,
  bool Function()? cancelled,
}) async {
  final name = relative.trim();
  if (name.isEmpty ||
      name.startsWith('/') ||
      name.split('/').any((s) => s.isEmpty || s == '.' || s == '..')) {
    return ChatFileSearchResult.none;
  }
  final starts = <String>[];
  for (final raw in folders) {
    final folder = chatCleanAbsolutePath(raw);
    if (folder != null && !starts.contains(folder)) starts.add(folder);
  }
  if (starts.isEmpty) return ChatFileSearchResult.none;
  // One clock for the whole walk: a listing still pending when it rings is
  // left behind (its late answer is dropped).
  final expiry = Completer<void>();
  final clock = Timer(timeout, expiry.complete);
  final listed = <String>{};
  final hits = <String>[];
  final searched = <String>[];
  var entries = 0;
  var exhausted = false;
  bool stop() {
    if (expiry.isCompleted) exhausted = true;
    return exhausted || hits.length >= maxHits || (cancelled?.call() ?? false);
  }

  try {
    for (final start in starts) {
      if (stop()) break;
      // Breadth first from this start; a folder is listed once per search.
      var frontier = <String>[start];
      var touched = false;
      for (var depth = 0; depth <= maxDepth && frontier.isNotEmpty; depth++) {
        final next = <String>[];
        for (final folder in frontier) {
          if (stop()) break;
          if (!listed.add(folder)) continue;
          final ProjectDirectoryListing listing;
          try {
            listing = await Future.any([
              files.listProjectDirectory(folder),
              expiry.future.then(
                (_) => throw TimeoutException('chat file search'),
              ),
            ]);
          } on TimeoutException {
            exhausted = true;
            break;
          } catch (error) {
            if (error is DesktopControlFailure &&
                error.kind == DesktopControlFailureKind.unsupported) {
              return ChatFileSearchResult(
                hits: List.unmodifiable(hits),
                searched: List.unmodifiable(searched),
                exhausted: false,
              );
            }
            // Denied or gone: this folder stays unread; the rest go on.
            continue;
          }
          if (listing.error != null) continue;
          touched = true;
          for (final entry in listing.entries) {
            if (entries++ >= maxEntries) {
              exhausted = true;
              break;
            }
            // A link the server reports outside the folder is not followed.
            if (!_inside(entry.path, folder)) continue;
            if (entry.isDirectory) {
              final lower = entry.name.toLowerCase();
              if (chatFileSearchSkippedFolders.contains(lower)) continue;
              if (depth < maxDepth) next.add(entry.path);
            } else if (_matches(entry.path, name) &&
                !hits.contains(entry.path)) {
              hits.add(entry.path);
              if (hits.length >= maxHits) break;
            }
          }
          if (exhausted) break;
        }
        if (stop()) break;
        frontier = next;
      }
      if (touched) searched.add(start);
    }
  } finally {
    clock.cancel();
  }
  return ChatFileSearchResult(
    hits: List.unmodifiable(hits),
    searched: List.unmodifiable(searched),
    exhausted: exhausted,
  );
}
