import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../services/artifact_viewer_kind.dart';
import '../../services/desktop_control_gateway.dart';
import '../../utils/chat_file_path_policy.dart';
import 'chat_file_search.dart';

/// Why a file a reply names could not be shown. The viewer says each one in
/// its own words; none of them copies the path on its own.
enum ChatFileErrorKind {
  /// Nowhere it was looked for.
  notFound,

  /// The server refused (401/403): no permission, or a path outside what it
  /// serves. Shown as the server's answer; no other folder is tried.
  forbidden,

  /// The server rejected the request (400/409/412/422).
  denied,
  tooLarge,
  binary,
  timeout,

  /// No answer, or one that makes no sense.
  unreachable,

  /// The server has no file routes.
  unsupported,

  /// The server answered with a file outside the conversation's folders
  /// (a link out of it).
  outside,

  /// The path is not one that is asked for (a scheme, a NUL, `..` past the
  /// root…).
  badPath,

  /// A relative path and no folder to start from.
  noBase,

  /// A file that usually holds secrets, not yet confirmed. Nothing was read.
  needsConfirmation,
}

final class ChatFileLoadException implements Exception {
  const ChatFileLoadException(this.kind, {this.tried = const []});

  final ChatFileErrorKind kind;

  /// The folders the file was looked for in, in order (said on a miss so
  /// the user knows where it is not).
  final List<String> tried;

  @override
  String toString() => 'ChatFileLoadException($kind)';
}

/// More than one file of the conversation's folders carries the name the
/// reply dropped: the viewer asks which one to open. Nothing was read.
final class ChatFileChoiceException implements Exception {
  const ChatFileChoiceException(this.paths, {this.tried = const []});

  /// Absolute paths, most likely first. At least two.
  final List<String> paths;
  final List<String> tried;

  @override
  String toString() => 'ChatFileChoiceException(${paths.length})';
}

/// Where a bare or relative name may be looked for when it is in none of
/// its candidates: the folders the conversation is known to be about, and
/// the name as the reply wrote it (already free of `..`).
final class ChatFileSearchScope {
  const ChatFileSearchScope({
    required this.relative,
    required this.folders,
    this.timeout = chatFileSearchTimeout,
    this.cancelled,
  });

  final String relative;
  final List<String> folders;
  final Duration timeout;
  final bool Function()? cancelled;
}

/// A file read for the viewer. Held in memory only.
final class ChatFileContent {
  const ChatFileContent({
    required this.path,
    required this.name,
    required this.bytes,
    required this.mimeType,
    required this.truncated,
    required this.sensitive,
    required this.byteSize,
  });

  /// The absolute path that answered.
  final String path;
  final String name;
  final Uint8List bytes;
  final String mimeType;

  /// The server (or the client's own limit) cut the file.
  final bool truncated;

  /// A file that usually holds secrets (shown after the user said so).
  final bool sensitive;
  final int byteSize;
}

/// The longest wait for one read.
const Duration chatFileReadTimeout = Duration(seconds: 20);

/// Text kept from one read, in UTF-16 units. The server already cuts at
/// 512 KB; this is the client's own ceiling.
const int chatFileMaxTextChars = 2 * 1024 * 1024;

/// Largest image shown, decoded.
const int chatFileMaxImageBytes = 20 * 1024 * 1024;

ChatFileErrorKind _kindOf(Object error) {
  if (error is ChatFileLoadException) return error.kind;
  if (error is TimeoutException) return ChatFileErrorKind.timeout;
  if (error is DesktopControlFailure) {
    switch (error.kind) {
      case DesktopControlFailureKind.forbidden:
        return ChatFileErrorKind.forbidden;
      case DesktopControlFailureKind.rejected:
        return ChatFileErrorKind.denied;
      case DesktopControlFailureKind.unsupported:
        return ChatFileErrorKind.unsupported;
      case DesktopControlFailureKind.invalidResponse:
        return ChatFileErrorKind.unreachable;
      case DesktopControlFailureKind.unavailable:
        if (error.code == 404) return ChatFileErrorKind.notFound;
        if (error.code == 413) return ChatFileErrorKind.tooLarge;
        return ChatFileErrorKind.unreachable;
    }
  }
  return ChatFileErrorKind.unreachable;
}

/// What a read failure means, for the viewer and the folder browser.
ChatFileErrorKind chatFileErrorKindOf(Object error) => _kindOf(error);

/// Reads the first of [resolution]'s paths that exists, through the file
/// routes the conversation already uses (`/api/fs/read-text`,
/// `/api/fs/read-data-url`), and nothing else.
///
/// A path that is not there ([ChatFileErrorKind.notFound]) moves on to the
/// next candidate; any other answer stops the search, so a server that
/// denies a path is never asked for the same name elsewhere. A file that
/// usually holds secrets is not read until [confirmedSensitive]. The
/// content stays in memory: nothing is written to disk here.
///
/// When no candidate is there and [search] is given, the name is looked for
/// inside the folders of [search] ([chatFindFileByName]): one match is read
/// (after the same confirmation when it usually holds secrets), several
/// raise [ChatFileChoiceException], none a [ChatFileErrorKind.notFound]
/// that says where it was looked for. [onFound] hears the path one match
/// resolved to, so a later read (after a confirmation) skips the walk.
Future<ChatFileContent> loadChatFile({
  required HermesProjectFilesGateway files,
  required ChatPathResolution resolution,
  required List<String> roots,
  required bool askedRelative,
  bool confirmedSensitive = false,
  Duration timeout = chatFileReadTimeout,
  ChatFileSearchScope? search,
  void Function(String path)? onFound,
}) async {
  final problem = resolution.problem;
  if (problem != null) {
    throw ChatFileLoadException(
      problem == ChatPathProblem.noBase
          ? ChatFileErrorKind.noBase
          : ChatFileErrorKind.badPath,
    );
  }
  if (!confirmedSensitive &&
      resolution.candidates.any((c) => isSensitiveChatPath(c.path))) {
    throw const ChatFileLoadException(ChatFileErrorKind.needsConfirmation);
  }
  final tried = <String>[
    for (final candidate in resolution.candidates) _folderOf(candidate.path),
  ];
  Object? last;
  for (final candidate in resolution.candidates) {
    try {
      return await _read(
        files,
        candidate.path,
        roots: roots,
        askedRelative: askedRelative,
        confirmed: confirmedSensitive,
        timeout: timeout,
      );
    } catch (error) {
      last = error;
      if (_kindOf(error) != ChatFileErrorKind.notFound) {
        throw ChatFileLoadException(_kindOf(error), tried: tried);
      }
    }
  }
  if (search != null && last != null) {
    final result = await chatFindFileByName(
      files: files,
      relative: search.relative,
      folders: search.folders,
      timeout: search.timeout,
      cancelled: search.cancelled,
    );
    for (final folder in result.searched) {
      if (!tried.contains(folder)) tried.add(folder);
    }
    if (result.hits.length > 1) {
      throw ChatFileChoiceException(result.hits, tried: tried);
    }
    if (result.hits.length == 1) {
      final found = result.hits.single;
      onFound?.call(found);
      if (!confirmedSensitive && isSensitiveChatPath(found)) {
        throw const ChatFileLoadException(ChatFileErrorKind.needsConfirmation);
      }
      try {
        return await _read(
          files,
          found,
          roots: [...roots, ...search.folders],
          askedRelative: askedRelative,
          confirmed: confirmedSensitive,
          timeout: timeout,
        );
      } catch (error) {
        throw ChatFileLoadException(_kindOf(error), tried: tried);
      }
    }
  }
  throw ChatFileLoadException(
    last == null ? ChatFileErrorKind.notFound : _kindOf(last),
    tried: tried,
  );
}

/// The folder of [path] (`/` for a file at the root).
String _folderOf(String path) {
  final slash = path.lastIndexOf('/');
  return slash <= 0 ? '/' : path.substring(0, slash);
}

Future<ChatFileContent> _read(
  HermesProjectFilesGateway files,
  String path, {
  required List<String> roots,
  required bool askedRelative,
  required bool confirmed,
  required Duration timeout,
}) async {
  final slash = path.lastIndexOf('/');
  final name = slash < 0 ? path : path.substring(slash + 1);
  final sensitive = isSensitiveChatPath(path);
  if (artifactViewerKindFor(name: name, mimeType: '') ==
      ArtifactViewerKind.image) {
    final bytes = await files.readProjectFileBytes(path).timeout(timeout);
    if (bytes.length > chatFileMaxImageBytes) {
      throw const ChatFileLoadException(ChatFileErrorKind.tooLarge);
    }
    return ChatFileContent(
      path: path,
      name: name,
      bytes: bytes,
      mimeType: 'image/*',
      truncated: false,
      sensitive: sensitive,
      byteSize: bytes.length,
    );
  }
  final preview = await files.readProjectFileText(path).timeout(timeout);
  if (preview.binary) {
    throw const ChatFileLoadException(ChatFileErrorKind.binary);
  }
  final served = preview.path;
  if (chatServedPathEscapes(
    asked: path,
    served: served,
    roots: roots,
    askedWasRelative: askedRelative,
  )) {
    throw const ChatFileLoadException(ChatFileErrorKind.outside);
  }
  // A link the server followed may land on a file that holds secrets.
  if (!confirmed && served.startsWith('/') && isSensitiveChatPath(served)) {
    throw const ChatFileLoadException(ChatFileErrorKind.needsConfirmation);
  }
  var text = preview.text;
  var truncated = preview.truncated;
  if (text.length > chatFileMaxTextChars) {
    final cut = text.lastIndexOf('\n', chatFileMaxTextChars);
    text = text.substring(
      0,
      cut > chatFileMaxTextChars ~/ 2 ? cut : chatFileMaxTextChars,
    );
    truncated = true;
  }
  final bytes = Uint8List.fromList(utf8.encode(text));
  return ChatFileContent(
    path: path,
    name: name,
    bytes: bytes,
    mimeType: preview.mimeType,
    truncated: truncated,
    sensitive: sensitive || isSensitiveChatPath(served),
    byteSize: preview.byteSize,
  );
}
