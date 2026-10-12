import 'dart:convert';
import 'dart:typed_data';

import 'package:hermes_android/core/models/project_files.dart';
import 'package:hermes_android/core/services/desktop_control_gateway.dart';

import 'pj1215_fake_projects_gateway.dart';

/// Fake current Hermes that also serves the read-only `/api/fs/*` routes.
/// [folders] maps a folder path to its listing; [files] maps a file path to its
/// text preview; [images] to raw bytes.
class Pf1215FakeFilesGateway extends Pj1215FakeProjectsGateway
    implements HermesProjectFilesGateway {
  final Map<String, ProjectDirectoryListing> folders;
  final Map<String, ProjectFilePreview> files;
  final Map<String, Uint8List> images;
  final List<String> fsCalls = [];
  Object? listFailure;
  Object? readFailure;
  bool knownUnsupported = false;

  Pf1215FakeFilesGateway({
    Map<String, ProjectDirectoryListing>? folders,
    Map<String, ProjectFilePreview>? files,
    Map<String, Uint8List>? images,
  }) : folders = folders ?? {},
       files = files ?? {},
       images = images ?? {};

  factory Pf1215FakeFilesGateway.sample() {
    final sample = Pj1215FakeProjectsGateway.sample();
    return Pf1215FakeFilesGateway(
        folders: pf1215SampleFolders(),
        files: pf1215SampleFiles(),
        images: {'$pf1215Root/assets/logo.png': base64Decode(_onePixelPng)},
      )
      ..tree = sample.tree
      ..details.addAll(sample.details);
  }

  @override
  bool get projectFilesKnownUnsupported => knownUnsupported;

  @override
  Future<ProjectDirectoryListing> listProjectDirectory(String path) async {
    fsCalls.add('list:$path');
    final failure = listFailure;
    if (failure != null) throw failure;
    return folders[path] ??
        const ProjectDirectoryListing(entries: [], error: 'ENOENT');
  }

  @override
  Future<ProjectFilePreview> readProjectFileText(String path) async {
    fsCalls.add('read-text:$path');
    final failure = readFailure;
    if (failure != null) throw failure;
    final file = files[path];
    if (file == null) {
      throw const DesktopControlFailure(
        DesktopControlFailureKind.unavailable,
        code: 404,
      );
    }
    return file;
  }

  @override
  Future<Uint8List> readProjectFileBytes(String path) async {
    fsCalls.add('read-data-url:$path');
    final failure = readFailure;
    if (failure != null) throw failure;
    final bytes = images[path];
    if (bytes == null) {
      throw const DesktopControlFailure(
        DesktopControlFailureKind.unavailable,
        code: 404,
      );
    }
    return bytes;
  }
}

const String pf1215Root = '/home/demo/code/hermes-console';

ProjectFsEntry _dir(String parent, String name) =>
    ProjectFsEntry(name: name, path: '$parent/$name', isDirectory: true);

ProjectFsEntry _file(String parent, String name) =>
    ProjectFsEntry(name: name, path: '$parent/$name', isDirectory: false);

Map<String, ProjectDirectoryListing> pf1215SampleFolders() => {
  pf1215Root: ProjectDirectoryListing(
    entries: [
      _dir(pf1215Root, 'android'),
      _dir(pf1215Root, 'assets'),
      _dir(pf1215Root, 'docs'),
      _dir(pf1215Root, 'lib'),
      _dir(pf1215Root, 'test'),
      _file(pf1215Root, '.gitignore'),
      _file(pf1215Root, 'AGENTS.md'),
      _file(pf1215Root, 'analysis_options.yaml'),
      _file(pf1215Root, 'app.keystore'),
      _file(pf1215Root, 'pubspec.yaml'),
      _file(pf1215Root, 'README.md'),
    ],
  ),
  '$pf1215Root/lib': ProjectDirectoryListing(
    entries: [
      _dir('$pf1215Root/lib', 'core'),
      _dir('$pf1215Root/lib', 'l10n'),
      _file('$pf1215Root/lib', 'main.dart'),
    ],
  ),
  '$pf1215Root/lib/core': ProjectDirectoryListing(
    entries: [_dir('$pf1215Root/lib/core', 'screens')],
  ),
  '$pf1215Root/lib/core/screens': const ProjectDirectoryListing(entries: []),
  '$pf1215Root/assets': ProjectDirectoryListing(
    entries: [_file('$pf1215Root/assets', 'logo.png')],
  ),
  '$pf1215Root/docs': const ProjectDirectoryListing(
    entries: [],
    error: 'EACCES',
  ),
};

Map<String, ProjectFilePreview> pf1215SampleFiles() => {
  '$pf1215Root/lib/main.dart': const ProjectFilePreview(
    path: '$pf1215Root/lib/main.dart',
    text: 'void main() => runApp(const HermesApp());\n',
    binary: false,
    truncated: false,
    byteSize: 42,
    mimeType: 'text/x-dart',
  ),
  '$pf1215Root/README.md': const ProjectFilePreview(
    path: '$pf1215Root/README.md',
    text: '# Hermes Console\n',
    binary: false,
    truncated: true,
    byteSize: 900000,
    mimeType: 'text/markdown',
  ),
  '$pf1215Root/app.keystore': const ProjectFilePreview(
    path: '$pf1215Root/app.keystore',
    text: '\u0000\u0001',
    binary: true,
    truncated: false,
    byteSize: 2048,
    mimeType: 'application/octet-stream',
  ),
};

const String _onePixelPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==';
