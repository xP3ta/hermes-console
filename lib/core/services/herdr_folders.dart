// Choosing a folder on the server without typing its path: the listing of
// directories, the checks on a typed path and the creation of a folder, all
// over SFTP (the app's own SSH connection). Nothing here builds a shell line:
// a path goes to the server as an SFTP path, never as a command argument.
import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';

/// One folder of a listing.
class HerdrDirEntry {
  const HerdrDirEntry(this.name);

  final String name;

  bool get hidden => name.startsWith('.');
}

/// The folders inside one directory.
class HerdrDirListing {
  const HerdrDirListing({
    required this.path,
    required this.dirs,
    this.isGit = false,
    this.truncated = false,
  });

  /// The directory listed, absolute and without a trailing slash.
  final String path;

  /// Sub-folders only, sorted by name (case-insensitive).
  final List<HerdrDirEntry> dirs;

  /// The directory holds a `.git` entry: a repository's root.
  final bool isGit;

  /// There were more than [SftpFolderSource.maxEntries] folders.
  final bool truncated;
}

/// Where the folder browser reads and writes.
abstract interface class HerdrFolderSource {
  /// The user's home folder.
  Future<String> home();

  /// The folders of [path]; throws when it cannot be read.
  Future<HerdrDirListing> list(String path);

  /// Whether [path] exists and is a directory (links are followed).
  Future<bool> isDirectory(String path);

  /// Creates the folder at [path] (its parent must exist).
  Future<void> makeDirectory(String path);
}

/// Why a new folder's name was refused.
enum HerdrFolderNameProblem { empty, tooLong, slash, dots, control }

/// Longest name accepted for a new folder, in UTF-8 bytes (a file name is at
/// most 255 on the usual file systems).
const int herdrFolderNameMaxBytes = 120;

/// What is wrong with [raw] as the name of a new folder, or null when it is
/// fine: not empty, no `/`, not `.` or `..`, no control characters, a bounded
/// length.
HerdrFolderNameProblem? herdrFolderNameProblem(String raw) {
  final name = raw.trim();
  if (name.isEmpty) return HerdrFolderNameProblem.empty;
  if (name.contains('/') || name.contains(r'\')) {
    return HerdrFolderNameProblem.slash;
  }
  if (name == '.' || name == '..') return HerdrFolderNameProblem.dots;
  for (final rune in name.runes) {
    if (rune < 0x20 || rune == 0x7F || (rune >= 0x80 && rune <= 0x9F)) {
      return HerdrFolderNameProblem.control;
    }
  }
  if (utf8.encode(name).length > herdrFolderNameMaxBytes) {
    return HerdrFolderNameProblem.tooLong;
  }
  return null;
}

/// [base] + [name] as one absolute path. [name] must have passed
/// [herdrFolderNameProblem].
String herdrJoinPath(String base, String name) {
  final clean = name.trim();
  return base == '/' ? '/$clean' : '$base/$clean';
}

/// The folder above [path]; `/` stays `/`.
String herdrParentPath(String path) {
  if (path == '/' || !path.contains('/')) return '/';
  final cut = path.lastIndexOf('/');
  return cut <= 0 ? '/' : path.substring(0, cut);
}

/// One step of the breadcrumb: its label and the path it goes to.
class HerdrCrumb {
  const HerdrCrumb(this.label, this.path);

  final String label;
  final String path;
}

/// `/home/me/app` -> `/`, `home`, `me`, `app`, each with its own path.
List<HerdrCrumb> herdrBreadcrumbs(String path) {
  final crumbs = <HerdrCrumb>[const HerdrCrumb('/', '/')];
  var walked = '';
  for (final part in path.split('/')) {
    if (part.isEmpty) continue;
    walked = '$walked/$part';
    crumbs.add(HerdrCrumb(part, walked));
  }
  return crumbs;
}

/// SFTP-backed [HerdrFolderSource]. The SFTP channel is opened once, by
/// [open], and used for every call; a failed call drops it so the next one
/// opens a fresh channel.
class SftpFolderSource implements HerdrFolderSource {
  SftpFolderSource(this._open);

  /// Most folders one listing keeps.
  static const int maxEntries = 600;

  /// Most links stat-ed to learn whether they point at a folder.
  static const int maxLinkChecks = 40;

  static const Duration timeout = Duration(seconds: 12);

  final Future<SftpClient> Function() _open;
  Future<SftpClient>? _sftp;

  Future<SftpClient> _client() => _sftp ??= _open().timeout(timeout);

  Future<T> _use<T>(Future<T> Function(SftpClient sftp) body) async {
    try {
      return await body(await _client()).timeout(timeout);
    } catch (e) {
      _sftp = null;
      rethrow;
    }
  }

  @override
  Future<String> home() => _use((sftp) => sftp.absolute('.'));

  @override
  Future<HerdrDirListing> list(String path) => _use((sftp) async {
    final raw = await sftp.listdir(path);
    final dirs = <HerdrDirEntry>[];
    var git = false;
    var linkChecks = 0;
    var truncated = false;
    for (final entry in raw) {
      final name = entry.filename;
      if (name == '.' || name == '..' || name.isEmpty) continue;
      if (name == '.git') git = true;
      var isDir = entry.attr.isDirectory;
      if (!isDir && entry.attr.isSymbolicLink && linkChecks < maxLinkChecks) {
        // A listing reports the link itself: ask what it points at.
        linkChecks++;
        try {
          isDir = (await sftp.stat(herdrJoinPath(path, name))).isDirectory;
        } catch (_) {
          isDir = false;
        }
      }
      if (!isDir) continue;
      if (dirs.length >= maxEntries) {
        truncated = true;
        continue;
      }
      dirs.add(HerdrDirEntry(name));
    }
    dirs.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return HerdrDirListing(
      path: path,
      dirs: dirs,
      isGit: git,
      truncated: truncated,
    );
  });

  @override
  Future<bool> isDirectory(String path) => _use((sftp) async {
    try {
      return (await sftp.stat(path)).isDirectory;
    } on SftpStatusError {
      return false;
    }
  });

  @override
  Future<void> makeDirectory(String path) => _use((sftp) => sftp.mkdir(path));
}
