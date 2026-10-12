import 'package:hermes_android/core/models/project_files.dart';
import 'package:hermes_android/core/services/desktop_control_gateway.dart';

import 'pf1215_fake_files_gateway.dart';

/// Fake current Hermes that also serves the project file write routes
/// (`/api/files/mkdir`, `/api/fs/write-text`, `/api/files/upload-stream`,
/// `DELETE /api/files`). Writes mutate [folders]/[files] like the server, and
/// every call is recorded in [writeCalls] as `route:path[:extra]`.
class Pw1215FakeWritableFilesGateway extends Pf1215FakeFilesGateway
    implements HermesProjectFileWritesGateway {
  Pw1215FakeWritableFilesGateway({super.folders, super.files});

  factory Pw1215FakeWritableFilesGateway.sample() {
    final sample = Pf1215FakeFilesGateway.sample();
    return Pw1215FakeWritableFilesGateway(
        folders: sample.folders,
        files: sample.files,
      )
      ..images.addAll(sample.images)
      ..tree = sample.tree
      ..details.addAll(sample.details);
  }

  final List<String> writeCalls = [];
  bool fileWritesAllowed = true;
  final Set<ProjectFileWriteAction> unsupported = {};

  /// Failure thrown by the next write of that action (then cleared).
  final Map<ProjectFileWriteAction, Object> failNext = {};

  /// Text served by read-text after the editor opened (simulates a change on
  /// the server while editing).
  String? serverChangedText;

  @override
  bool get projectFileWritesAllowed => fileWritesAllowed;

  @override
  bool projectFileWriteKnownUnsupported(ProjectFileWriteAction action) =>
      unsupported.contains(action);

  void _guard(ProjectFileWriteAction action) {
    if (!fileWritesAllowed) {
      throw const DesktopControlFailure(DesktopControlFailureKind.forbidden);
    }
    final failure = failNext.remove(action);
    if (failure is DesktopControlFailure &&
        failure.kind == DesktopControlFailureKind.unsupported) {
      unsupported.add(action);
    }
    if (failure != null) throw failure;
  }

  String _parent(String path) => path.substring(0, path.lastIndexOf('/'));
  String _name(String path) => path.substring(path.lastIndexOf('/') + 1);

  void _addEntry(String path, {required bool isDirectory}) {
    final parent = _parent(path);
    final current = folders[parent];
    final entries =
        [
          ...?current?.entries.where((e) => e.path != path),
          ProjectFsEntry(
            name: _name(path),
            path: path,
            isDirectory: isDirectory,
          ),
        ]..sort((a, b) {
          if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        });
    folders[parent] = ProjectDirectoryListing(entries: entries);
  }

  @override
  Future<String> createProjectFolder(String path) async {
    writeCalls.add('mkdir:$path');
    _guard(ProjectFileWriteAction.createFolder);
    _addEntry(path, isDirectory: true);
    folders[path] ??= const ProjectDirectoryListing(entries: []);
    return path;
  }

  @override
  Future<void> writeProjectFileText(String path, String content) async {
    writeCalls.add('write-text:$path:$content');
    _guard(ProjectFileWriteAction.writeText);
    _addEntry(path, isDirectory: false);
    files[path] = ProjectFilePreview(
      path: path,
      text: content,
      binary: false,
      truncated: false,
      byteSize: content.length,
      mimeType: 'text/plain',
    );
  }

  @override
  Future<ProjectFilePreview> readProjectFileText(String path) async {
    final changed = serverChangedText;
    if (changed != null && files.containsKey(path)) {
      fsCalls.add('read-text:$path');
      return ProjectFilePreview(
        path: path,
        text: changed,
        binary: false,
        truncated: false,
        byteSize: changed.length,
        mimeType: files[path]!.mimeType,
      );
    }
    return super.readProjectFileText(path);
  }

  @override
  Future<String> uploadProjectFile(
    String path, {
    required String localPath,
    required String filename,
  }) async {
    writeCalls.add('upload:$path:$localPath:$filename');
    _guard(ProjectFileWriteAction.upload);
    _addEntry(path, isDirectory: false);
    return path;
  }

  @override
  Future<void> deleteProjectEntry(String path) async {
    writeCalls.add('delete:$path');
    _guard(ProjectFileWriteAction.delete);
    final parent = _parent(path);
    final current = folders[parent];
    if (current != null) {
      folders[parent] = ProjectDirectoryListing(
        entries: current.entries.where((e) => e.path != path).toList(),
      );
    }
    folders.remove(path);
    files.remove(path);
  }
}
