/// Read-only view of a project folder on the Hermes host, as returned by the
/// Dashboard file routes Hermes Desktop's remote file tree uses
/// (`GET /api/fs/list`, `GET /api/fs/read-text`, `GET /api/fs/read-data-url`).
library;

import 'package:flutter/foundation.dart';

/// Upper bound on rows kept from one listing; the phone never renders more.
const int projectFsListingLimit = 1000;

@immutable
final class ProjectFsEntry {
  final String name;
  final String path;
  final bool isDirectory;

  const ProjectFsEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
  });

  static ProjectFsEntry? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final name = raw['name'];
    final path = raw['path'];
    if (name is! String || path is! String) return null;
    if (name.trim().isEmpty || path.trim().isEmpty) return null;
    return ProjectFsEntry(
      name: name,
      path: path,
      isDirectory: raw['isDirectory'] == true,
    );
  }
}

/// One folder listing. [error] carries the server's errno-like code
/// (`ENOENT`, `EACCES`, `ENOTDIR`, …) when the folder could not be read;
/// the server answers 200 with an empty list in that case.
@immutable
final class ProjectDirectoryListing {
  final List<ProjectFsEntry> entries;
  final String? error;

  const ProjectDirectoryListing({required this.entries, this.error});
}

/// Text preview of a file (`/api/fs/read-text`): the server caps it at
/// 512 KB and flags [truncated]; [binary] means it is not worth showing.
@immutable
final class ProjectFilePreview {
  final String path;
  final String text;
  final bool binary;
  final bool truncated;
  final int byteSize;
  final String mimeType;

  const ProjectFilePreview({
    required this.path,
    required this.text,
    required this.binary,
    required this.truncated,
    required this.byteSize,
    required this.mimeType,
  });
}
