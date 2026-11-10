import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../l10n/app_localizations.dart';
import '../../services/desktop_control_gateway.dart';
import '../../utils/chat_file_path_policy.dart';
import '../../utils/chat_inline_refs.dart';
import '../hermes_notice.dart';
import 'chat_file_loader.dart';
import 'chat_file_viewer_screen.dart';

/// Copies [path] and tells the user so (what a file chip does when there is
/// nothing safe to open). [message] replaces the default notice.
Future<void> copyChatFilePath(
  BuildContext context,
  String path, {
  String? message,
}) async {
  final notice = HermesNotice.of(context);
  final strings = Localizations.of<Strings>(context, Strings);
  try {
    await Clipboard.setData(ClipboardData(text: path));
  } catch (_) {
    return;
  }
  final text = message ?? strings?.chcPathCopied;
  if (text == null) return;
  notice.showSnackBar(
    SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
  );
}

/// Opens the files and folders a reply mentions, on the machine the agent
/// runs on, through the file routes the conversation already uses (the
/// project-files gateway: `/api/fs/list`, `/api/fs/read-text`,
/// `/api/fs/read-data-url`) and nothing else.
///
/// A file opens in [ChatFileViewerScreen], a folder in the project explorer.
/// A relative path is tried against the conversation's folder, then [roots],
/// then the folders the conversation has been about ([learnedRoots]: where
/// its tools worked and the paths its replies cite); when it is in none of
/// them, a bounded walk of those learned folders looks for the name
/// (`chatFindFileByName`) and the viewer asks which one when several match.
/// An absolute path is asked as it is; `~/…` resolves only when the home
/// folder follows from the paths the conversation knows. The viewer says
/// why a file could not be read (it never silently copies the path), and
/// what the server refuses stays refused: no other folder is tried after a
/// denial. What cannot be read at all (archives, PDF, a server without the
/// routes, a path that is no path) is left to the chip, which copies it.
class ChatFileOpener {
  ChatFileOpener({
    required this.gateway,
    required this.cwd,
    this.roots,
    this.learnedRoots,
  });

  /// The conversation's gateway; it reads files only if it has the project
  /// file routes.
  final Object? Function() gateway;

  /// The conversation's folder, to resolve relative paths.
  final String? Function() cwd;

  /// Other folders the conversation may be about (the session's listed
  /// folder, the project's), tried after [cwd]. Read at tap time.
  final List<String> Function()? roots;

  /// The folders learned from the conversation itself (see
  /// `chatLearnFolders`), most recent first, tried after [roots] and walked
  /// as a last resort. Read only when a chip is tapped, never while the
  /// chips are built: [canOpen] does not depend on them.
  final List<String> Function()? learnedRoots;

  bool _opening = false;

  List<String> _allRoots({List<String> learned = const []}) {
    final out = <String>[];
    for (final r in [cwd(), ...?roots?.call(), ...learned]) {
      final v = r?.trim() ?? '';
      if (v.startsWith('/') && !out.contains(v)) out.add(v);
    }
    return out;
  }

  ChatPathResolution _resolution(
    ChatFileRef ref, {
    List<String> learned = const [],
  }) => chatResolveRef(ref, cwd: cwd(), roots: [...?roots?.call(), ...learned]);

  /// The name as the reply wrote it, free of `./`, to look for by name; null
  /// for an absolute or `~/` path, or one that climbs (`../x`): those are
  /// never searched.
  static String? _searchName(ChatFileRef ref) {
    if (ref.root != ChatPathRoot.relative) return null;
    final parts = ref.path.split('/').where((s) => s.isNotEmpty && s != '.');
    if (parts.isEmpty || parts.contains('..')) return null;
    return parts.join('/');
  }

  /// The absolute path on the agent's machine, or null when it cannot be
  /// told (`~/…` with no known home, a relative path with no absolute
  /// folder to start from, a path that is refused).
  String? resolve(ChatFileRef ref) => _resolution(ref).first?.path;

  HermesProjectFilesGateway? get _files {
    final g = gateway();
    return g is HermesProjectFilesGateway ? g : null;
  }

  /// Whether a tap can show [ref] instead of copying its path.
  bool canOpen(ChatFileRef ref) {
    switch (ref.kind) {
      case ChatFileKind.archive:
      case ChatFileKind.pdf:
        return false;
      case ChatFileKind.folder:
      case ChatFileKind.file:
      case ChatFileKind.markdown:
      case ChatFileKind.image:
      case ChatFileKind.code:
      case ChatFileKind.data:
        final files = _files;
        return files != null &&
            !files.projectFilesKnownUnsupported &&
            _resolution(ref).ok;
    }
  }

  /// The folder of [roots] that holds [path], to open the explorer inside it.
  String? _rootOf(String path) {
    String? best;
    for (final root in _allRoots()) {
      final inside = path == root || path.startsWith('$root/');
      if (inside && (best == null || root.length > best.length)) best = root;
    }
    return best;
  }

  /// Pushes the viewer (or the explorer, for a folder) and returns when it
  /// closes. Reading happens inside the page, with its own spinner, errors
  /// and retry.
  Future<void> open(BuildContext context, ChatFileRef ref) async {
    final files = _files;
    // The learned folders are read here, once per tap.
    final learned = [...?learnedRoots?.call()];
    final resolution = _resolution(ref, learned: learned);
    final first = resolution.first;
    if (files == null || first == null || _opening) {
      if (!_opening) await copyChatFilePath(context, ref.path);
      return;
    }
    final navigator = Navigator.of(context);
    final roots = _allRoots(learned: learned);
    // The walk by name ends with the page; where it landed is kept so a
    // confirmation does not walk again.
    var closed = false;
    String? found;
    final searchName = _searchName(ref);
    final search = searchName == null || learned.isEmpty
        ? null
        : ChatFileSearchScope(
            relative: searchName,
            folders: learned,
            cancelled: () => closed,
          );
    Future<ChatFileContent> loadAt(String path, {required bool confirmed}) =>
        loadChatFile(
          files: files,
          resolution: chatResolveFilePath(path),
          roots: roots,
          askedRelative: false,
          confirmedSensitive: confirmed,
        );
    _opening = true;
    try {
      if (ref.isFolder) {
        final root = _rootOf(first.path) ?? first.path;
        await navigator.push<void>(
          MaterialPageRoute(
            builder: (_) => ChatFolderScreen(
              files: files,
              root: root,
              initialPath: first.path,
            ),
          ),
        );
        return;
      }
      final parent = first.path.substring(0, first.path.lastIndexOf('/'));
      final root = _rootOf(first.path);
      await navigator.push<void>(
        MaterialPageRoute(
          builder: (viewerContext) => ChatFileViewerScreen(
            name: ref.name,
            path: first.path,
            line: ref.line,
            endLine: ref.endLine,
            load: ({required confirmed}) {
              final known = found;
              if (known != null) return loadAt(known, confirmed: confirmed);
              return loadChatFile(
                files: files,
                resolution: resolution,
                roots: roots,
                askedRelative: ref.root != ChatPathRoot.absolute,
                confirmedSensitive: confirmed,
                search: search,
                onFound: (path) => found = path,
              );
            },
            loadChosen: search == null ? null : loadAt,
            // The explorer opens only on folders the conversation is about.
            onOpenFolder: root == null
                ? null
                : () => unawaited(
                    Navigator.of(viewerContext).push<void>(
                      MaterialPageRoute(
                        builder: (_) => ChatFolderScreen(
                          files: files,
                          root: root,
                          initialPath: parent.isEmpty ? '/' : parent,
                        ),
                      ),
                    ),
                  ),
          ),
        ),
      );
    } finally {
      closed = true;
      _opening = false;
    }
  }
}

/// The opener for the messages below it. Without one (rooms, previews) a
/// file chip only copies its path.
class ChatFileChipScope extends InheritedWidget {
  const ChatFileChipScope({
    super.key,
    required this.opener,
    required super.child,
  });

  final ChatFileOpener? opener;

  /// Read at tap time: a new opener never rebuilds the messages.
  static ChatFileOpener? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<ChatFileChipScope>()?.opener;

  @override
  bool updateShouldNotify(ChatFileChipScope oldWidget) => false;
}
