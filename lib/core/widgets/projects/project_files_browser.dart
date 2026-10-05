import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../l10n/app_localizations.dart';
import 'package:file_picker/file_picker.dart';

import '../../design/list.dart' show HermesListGroup, HermesListRow;
import '../../design/modal.dart'
    show
        HermesAction,
        HermesDialogAction,
        HermesDialogActionStyle,
        showHermesDialog,
        showHermesFormDialog,
        showHermesMenu,
        showHermesSurface;
import '../../models/project_files.dart';
import '../../services/artifact_viewer_kind.dart';
import '../../services/desktop_control_gateway.dart';
import '../../theme/app_theme.dart';
import '../artifact_viewer/artifact_viewer_screen.dart';
import '../hermes_notice.dart';
import '../hermes_ui.dart' show HermesPanel;
import 'project_file_icons.dart';
import 'project_text_editor_screen.dart';

/// Server cap of the Dashboard upload routes (`_MANAGED_FILE_MAX_BYTES`).
const int projectUploadMaxBytes = 100 * 1024 * 1024;

/// A file picked on the phone for upload.
@immutable
class ProjectUploadPick {
  final String localPath;
  final String name;
  final int size;

  const ProjectUploadPick({
    required this.localPath,
    required this.name,
    required this.size,
  });
}

/// Picks one phone file; null when cancelled. Injectable for tests.
typedef ProjectUploadPicker = Future<ProjectUploadPick?> Function();

Future<ProjectUploadPick?> pickProjectUpload() async {
  final result = await FilePicker.platform.pickFiles(
    allowMultiple: false,
    withData: false,
  );
  if (result == null || result.files.isEmpty) return null;
  final picked = result.files.single;
  final path = picked.path;
  if (path == null || path.isEmpty) {
    return ProjectUploadPick(localPath: '', name: picked.name, size: 0);
  }
  return ProjectUploadPick(
    localPath: path,
    name: picked.name,
    size: picked.size,
  );
}

/// A single folder or file name, checked like Desktop's remote picker
/// (`validFolderName`): not empty, not `.`/`..`, no slashes, plus no control
/// characters. Returns the trimmed name or null.
String? validProjectEntryName(String raw) {
  final name = raw.trim();
  if (name.isEmpty || name == '.' || name == '..' || name.length > 255) {
    return null;
  }
  if (RegExp(r'[/\\\x00-\x1F\x7F]').hasMatch(name)) return null;
  return name;
}

/// `childPath` from Desktop's remote picker.
String projectChildPath(String parent, String name) {
  final base = parent.length > 1 && parent.endsWith('/')
      ? parent.substring(0, parent.length - 1)
      : parent;
  return base == '/' ? '/$name' : '$base/$name';
}

/// Where the read-only browser of one project currently is. Owned by the
/// project screen so the folder survives switching between Chats and
/// Archivos, and so system back can go up one folder first.
class ProjectFilesController extends ChangeNotifier {
  ProjectFilesController({
    required this.root,
    required this.gateway,
    this.writes,
    this.readOnlyConnection = false,
    this.pickFolders = false,
    String? initialPath,
  }) : _path = initialPath != null && _isInside(root, initialPath)
           ? initialPath
           : root;

  /// Project folder on the Hermes host; the browser never leaves it.
  final String root;

  /// Null when the connected gateway has no file surface at all.
  final HermesProjectFilesGateway? gateway;

  /// Null when the connected gateway cannot write files at all.
  final HermesProjectFileWritesGateway? writes;

  /// The saved connection is read-only: never offer a write.
  final bool readOnlyConnection;

  /// Server folder picker (new project / add folder): files are listed but
  /// not opened, and the only write offered is "Nueva carpeta", like
  /// Desktop's remote folder picker.
  final bool pickFolders;

  /// True when this connection must not write (read-only connection or
  /// gateway), as opposed to a server that simply lacks the routes.
  bool get writesBlockedByConnection =>
      writes != null &&
      (readOnlyConnection || !(writes?.projectFileWritesAllowed ?? false));

  /// Whether [action] may be offered right now.
  bool canWrite(ProjectFileWriteAction action) {
    final writes = this.writes;
    if (writes == null || writesBlockedByConnection) return false;
    if (pickFolders && action != ProjectFileWriteAction.createFolder) {
      return false;
    }
    return !writes.projectFileWriteKnownUnsupported(action);
  }

  bool get canWriteAnything => ProjectFileWriteAction.values.any(canWrite);

  String _path;
  final Map<String, ProjectDirectoryListing> _listings = {};
  Object? _failure;
  bool _loading = false;
  bool _unsupported = false;
  bool _started = false;
  bool _disposed = false;
  int _generation = 0;

  String get path => _path;
  bool get atRoot => _path == root;
  bool get loading => _loading;
  Object? get failure => _failure;
  ProjectDirectoryListing? get listing => _listings[_path];

  bool get unsupported =>
      _unsupported ||
      gateway == null ||
      (gateway?.projectFilesKnownUnsupported ?? true);

  /// Folders from the project root down to [path], as (label, path).
  List<(String, String)> get crumbs {
    final out = <(String, String)>[(_basename(root), root)];
    if (atRoot || !_inside(_path)) return out;
    var current = root == '/' ? '' : root;
    final rest = _path.substring(root == '/' ? 1 : root.length + 1);
    for (final part in rest.split('/')) {
      if (part.isEmpty) continue;
      current = '$current/$part';
      out.add((part, current));
    }
    return out;
  }

  /// First listing, done lazily the first time the Archivos tab shows.
  void ensureStarted() {
    if (_started) return;
    _started = true;
    unawaited(_read(_path));
  }

  Future<void> open(String folder) async {
    if (!_inside(folder)) return;
    _path = folder;
    _failure = null;
    _notify();
    if (!_listings.containsKey(folder)) await _read(folder);
  }

  /// Goes one folder up; false when already at the project root.
  bool up() {
    if (atRoot) return false;
    final cut = _path.lastIndexOf('/');
    unawaited(open(cut <= root.length ? root : _path.substring(0, cut)));
    return true;
  }

  Future<void> refresh() => _read(_path);

  /// Re-reads [folder] after a write when it is on screen; otherwise drops
  /// its cached listing so the next visit reads it again. The cached listing
  /// stays visible meanwhile so the view does not flash.
  Future<void> reload(String folder) async {
    if (folder == _path) return _read(folder);
    invalidate(folder);
  }

  /// Forgets [folder] and everything cached below it.
  void invalidate(String folder) {
    _listings.removeWhere(
      (key, _) => key == folder || key.startsWith('$folder/'),
    );
  }

  /// Repaints after a capability change learned from a write.
  void capabilitiesChanged() => _notify();

  Future<void> _read(String folder) async {
    final gateway = this.gateway;
    if (gateway == null || unsupported) {
      _notify();
      return;
    }
    final generation = ++_generation;
    _loading = true;
    _failure = null;
    _notify();
    try {
      final listing = await gateway.listProjectDirectory(folder);
      if (_disposed || generation != _generation) return;
      _listings[folder] = listing;
    } catch (error) {
      if (_disposed || generation != _generation) return;
      if (error is DesktopControlFailure &&
          error.kind == DesktopControlFailureKind.unsupported) {
        _unsupported = true;
      } else {
        _failure = error;
      }
    } finally {
      if (!_disposed && generation == _generation) {
        _loading = false;
        _notify();
      }
    }
  }

  bool _inside(String folder) => _isInside(root, folder);

  static bool _isInside(String root, String folder) =>
      folder == root ||
      (root == '/' ? folder.startsWith('/') : folder.startsWith('$root/'));

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

String _basename(String path) {
  final trimmed = path.endsWith('/') && path.length > 1
      ? path.substring(0, path.length - 1)
      : path;
  final cut = trimmed.lastIndexOf('/');
  return cut < 0 || cut == trimmed.length - 1
      ? trimmed
      : trimmed.substring(cut + 1);
}

/// Folder browser for the Archivos tab of a project: breadcrumbs, folders
/// first, tap a folder to enter it and a file to preview it in the in-app
/// artifact viewer. When the connection may write and the server has the
/// routes, it also creates folders and text files, edits text files, uploads
/// from the phone and deletes (with confirmation, never recursively), like
/// Hermes Desktop's remote mode.
class ProjectFilesBrowser extends StatefulWidget {
  const ProjectFilesBrowser({
    required this.controller,
    required this.failureText,
    this.uploadPicker,
    super.key,
  });

  final ProjectFilesController controller;
  final String Function(Object failure) failureText;

  /// Replaces the system file picker (tests).
  final ProjectUploadPicker? uploadPicker;

  @override
  State<ProjectFilesBrowser> createState() => _ProjectFilesBrowserState();
}

enum _WriteKind { folder, file, upload, edit, delete }

class _ProjectFilesBrowserState extends State<ProjectFilesBrowser> {
  String? _opening;
  bool _busy = false;
  final GlobalKey _addAnchor = GlobalKey();

  @override
  void initState() {
    super.initState();
    // Listing starts after this frame: notifying mid-build would mark the
    // enclosing builders dirty while the tree is still building.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.controller.ensureStarted();
    });
  }

  /// User-facing text for a failed write. Learning that a route is missing
  /// (404/405) also hides that action from now on.
  String _writeFailureText(
    Object error,
    _WriteKind kind, {
    bool folder = false,
  }) {
    final strings = Strings.of(context);
    if (error is! DesktopControlFailure) return strings.pw1215WriteFailed;
    switch (error.kind) {
      case DesktopControlFailureKind.unsupported:
        widget.controller.capabilitiesChanged();
        return strings.pw1215ActionUnsupported;
      case DesktopControlFailureKind.forbidden:
        return strings.pw1215NotAllowed;
      case DesktopControlFailureKind.rejected when error.code == 409:
        return kind == _WriteKind.delete && folder
            ? strings.pw1215FolderNotEmpty
            : strings.pw1215NameTaken;
      case DesktopControlFailureKind.unavailable when error.code == 413:
        return kind == _WriteKind.upload
            ? strings.pw1215UploadTooLarge
            : strings.pw1215SaveTooLarge;
      case DesktopControlFailureKind.unavailable when error.code == 404:
        return strings.pw1215Gone;
      default:
        return strings.pw1215WriteFailed;
    }
  }

  void _snack(String text, {HermesNoticeKind? kind}) {
    if (!mounted) return;
    HermesNotice.of(
      context,
    ).showSnackBar(SnackBar(content: Text(text)), kind: kind);
  }

  Future<void> _openFile(ProjectFsEntry entry) async {
    final gateway = widget.controller.gateway;
    if (gateway == null || _opening != null) return;
    final strings = Strings.of(context);
    final notice = HermesNotice.of(context);
    setState(() => _opening = entry.path);
    final kind = artifactViewerKindFor(name: entry.name, mimeType: '');
    Future<void> Function()? show;
    try {
      if (kind == ArtifactViewerKind.image) {
        final bytes = await gateway.readProjectFileBytes(entry.path);
        show = () => _pushViewer(entry.name, 'image/*', bytes, bytes.length);
      } else {
        final preview = await gateway.readProjectFileText(entry.path);
        if (preview.binary) {
          show = () => _showFileInfo(entry, preview.byteSize);
        } else {
          if (preview.truncated) {
            notice.showSnackBar(
              SnackBar(content: Text(strings.pf1215PreviewTruncated)),
            );
          }
          show = () => _pushTextViewer(entry, preview);
        }
      }
    } catch (error) {
      if (!mounted) return;
      final tooLarge = error is DesktopControlFailure && error.code == 413;
      notice.showSnackBar(
        SnackBar(
          content: Text(
            tooLarge
                ? strings.pf1215FileTooLarge
                : strings.pf1215FileReadFailed,
          ),
        ),
        kind: HermesNoticeKind.error,
      );
    } finally {
      // The row spinner stops before the preview opens, so it never keeps
      // animating under a floating surface.
      if (mounted) setState(() => _opening = null);
    }
    if (show != null && mounted) await show();
  }

  Future<void> _pushViewer(
    String name,
    String mimeType,
    Uint8List bytes,
    int size,
  ) => Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => ArtifactViewerScreen(
        name: name,
        mimeType: mimeType,
        loadBytes: () async => bytes,
        sizeBytes: size,
      ),
    ),
  );

  /// Text preview; editable only when complete (not "Vista parcial") and the
  /// connection may write it.
  Future<void> _pushTextViewer(
    ProjectFsEntry entry,
    ProjectFilePreview preview,
  ) {
    final controller = widget.controller;
    final files = controller.gateway!;
    final writes = controller.writes;
    final editable =
        !preview.truncated &&
        writes != null &&
        controller.canWrite(ProjectFileWriteAction.writeText);
    return Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => _EditableTextViewer(
          name: entry.name,
          path: entry.path,
          mimeType: preview.mimeType,
          initialText: preview.text,
          sizeBytes: preview.byteSize,
          files: files,
          writes: editable ? writes : null,
          canEdit: () => controller.canWrite(ProjectFileWriteAction.writeText),
          failureText: (error) => _writeFailureText(error, _WriteKind.edit),
        ),
      ),
    );
  }

  bool _nameTaken(String name) =>
      widget.controller.listing?.entries.any((e) => e.name == name) ?? false;

  /// Name dialog shared by "Nueva carpeta" and "Nuevo archivo": live
  /// validation like Desktop, "Crear" disabled until the name is usable.
  Future<String?> _askName({
    required String title,
    required String label,
  }) async {
    final strings = Strings.of(context);
    var text = '';
    String? errorFor(String raw) {
      if (raw.trim().isEmpty) return null;
      final name = validProjectEntryName(raw);
      if (name == null) return strings.pw1215InvalidName;
      if (_nameTaken(name)) return strings.pw1215NameTaken;
      return null;
    }

    bool usable(String raw) {
      final name = validProjectEntryName(raw);
      return name != null && !_nameTaken(name);
    }

    final ok = await showHermesFormDialog<bool>(
      context: context,
      title: title,
      surfaceKey: const ValueKey('pw1215-name-dialog'),
      enabled: (value) => !value || usable(text),
      // The field owns its controller, so it outlives the closing animation.
      body: (context, setState) => _NameField(
        label: label,
        errorText: errorFor(text),
        onChanged: (value) => setState(() => text = value),
        onSubmitted: () {
          if (usable(text)) Navigator.of(context).pop(true);
        },
      ),
      actions: [
        HermesDialogAction(
          label: strings.commonCancel,
          value: false,
          style: HermesDialogActionStyle.cancel,
        ),
        HermesDialogAction(
          key: const ValueKey('pw1215-name-create'),
          label: strings.pw1215Create,
          value: true,
        ),
      ],
    );
    if (ok != true) return null;
    final name = validProjectEntryName(text);
    return name == null || _nameTaken(name) ? null : name;
  }

  Future<void> _runWrite(Future<void> Function() body) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await body();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _newFolder() async {
    final controller = widget.controller;
    final writes = controller.writes;
    if (writes == null) return;
    final strings = Strings.of(context);
    final parent = controller.path;
    final name = await _askName(
      title: strings.pw1215NewFolder,
      label: strings.pw1215FolderName,
    );
    if (name == null || !mounted) return;
    await _runWrite(() async {
      try {
        final created = await writes.createProjectFolder(
          projectChildPath(parent, name),
        );
        controller.invalidate(parent);
        _snack(strings.pw1215FolderCreated, kind: HermesNoticeKind.success);
        // Desktop's picker navigates into the folder it just created.
        await controller.open(created);
      } catch (error) {
        _snack(
          _writeFailureText(error, _WriteKind.folder),
          kind: HermesNoticeKind.error,
        );
      }
    });
  }

  Future<void> _newFile() async {
    final controller = widget.controller;
    final writes = controller.writes;
    if (writes == null) return;
    final strings = Strings.of(context);
    final parent = controller.path;
    final name = await _askName(
      title: strings.pw1215NewFile,
      label: strings.pw1215FileName,
    );
    if (name == null || !mounted) return;
    final path = projectChildPath(parent, name);
    var created = false;
    await _runWrite(() async {
      try {
        await writes.writeProjectFileText(path, '');
        created = true;
        _snack(strings.pw1215FileCreated, kind: HermesNoticeKind.success);
        await controller.reload(parent);
      } catch (error) {
        _snack(
          _writeFailureText(error, _WriteKind.file),
          kind: HermesNoticeKind.error,
        );
      }
    });
    if (created && mounted) {
      await _openFile(
        ProjectFsEntry(name: name, path: path, isDirectory: false),
      );
    }
  }

  Future<void> _upload() async {
    final controller = widget.controller;
    final writes = controller.writes;
    if (writes == null) return;
    final strings = Strings.of(context);
    final parent = controller.path;
    final ProjectUploadPick? pick;
    try {
      pick = await (widget.uploadPicker ?? pickProjectUpload)();
    } catch (_) {
      _snack(strings.pw1215UploadUnreadable, kind: HermesNoticeKind.error);
      return;
    }
    if (pick == null || !mounted) return;
    final name = validProjectEntryName(pick.name);
    if (pick.localPath.isEmpty || name == null) {
      _snack(strings.pw1215UploadUnreadable, kind: HermesNoticeKind.error);
      return;
    }
    if (pick.size > projectUploadMaxBytes) {
      _snack(strings.pw1215UploadTooLarge, kind: HermesNoticeKind.error);
      return;
    }
    if (_nameTaken(name)) {
      _snack(strings.pw1215NameTaken, kind: HermesNoticeKind.error);
      return;
    }
    await _runWrite(() async {
      try {
        await writes.uploadProjectFile(
          projectChildPath(parent, name),
          localPath: pick!.localPath,
          filename: name,
        );
        _snack(strings.pw1215Uploaded, kind: HermesNoticeKind.success);
        await controller.reload(parent);
      } catch (error) {
        _snack(
          _writeFailureText(error, _WriteKind.upload),
          kind: HermesNoticeKind.error,
        );
      }
    });
  }

  Future<void> _openAddMenu() async {
    final strings = Strings.of(context);
    final controller = widget.controller;
    final action = await showHermesMenu<_WriteKind>(
      context: context,
      anchorKey: _addAnchor,
      surfaceKey: const ValueKey('pw1215-add-menu'),
      actions: [
        if (controller.canWrite(ProjectFileWriteAction.createFolder))
          HermesAction(
            key: const ValueKey('pw1215-add-folder'),
            value: _WriteKind.folder,
            icon: Icons.create_new_folder_outlined,
            label: strings.pw1215NewFolder,
          ),
        if (controller.canWrite(ProjectFileWriteAction.writeText))
          HermesAction(
            key: const ValueKey('pw1215-add-file'),
            value: _WriteKind.file,
            icon: Icons.note_add_outlined,
            label: strings.pw1215NewFile,
          ),
        if (controller.canWrite(ProjectFileWriteAction.upload))
          HermesAction(
            key: const ValueKey('pw1215-add-upload'),
            value: _WriteKind.upload,
            icon: Icons.upload_file_outlined,
            label: strings.pw1215Upload,
          ),
      ],
    );
    if (!mounted) return;
    switch (action) {
      case _WriteKind.folder:
        await _newFolder();
      case _WriteKind.file:
        await _newFile();
      case _WriteKind.upload:
        await _upload();
      default:
        break;
    }
  }

  Future<void> _openEntryMenu(ProjectFsEntry entry, GlobalKey anchor) async {
    final strings = Strings.of(context);
    final action = await showHermesMenu<String>(
      context: context,
      anchorKey: anchor,
      surfaceKey: const ValueKey('pw1215-entry-menu'),
      actions: [
        HermesAction(
          key: const ValueKey('pw1215-entry-copy-path'),
          value: 'copy',
          icon: Icons.copy_rounded,
          label: strings.pj1215MenuCopyPath,
        ),
        if (widget.controller.canWrite(ProjectFileWriteAction.delete))
          HermesAction(
            key: const ValueKey('pw1215-entry-delete'),
            value: 'delete',
            icon: Icons.delete_outline_rounded,
            label: strings.commonDelete,
            destructive: true,
          ),
      ],
    );
    if (!mounted) return;
    switch (action) {
      case 'copy':
        await Clipboard.setData(ClipboardData(text: entry.path));
        _snack(strings.pj1215PathCopied);
      case 'delete':
        await _delete(entry);
    }
  }

  Future<void> _delete(ProjectFsEntry entry) async {
    final controller = widget.controller;
    final writes = controller.writes;
    if (writes == null) return;
    final strings = Strings.of(context);
    // Only entries listed inside the project root are ever deletable, and
    // never the root itself.
    if (!entry.path.startsWith('${controller.root}/')) return;
    final parent = controller.path;
    final confirmed = await showHermesDialog<bool>(
      context: context,
      surfaceKey: const ValueKey('pw1215-delete-dialog'),
      title: strings.pw1215DeleteTitle(entry.name),
      message: entry.isDirectory
          ? strings.pw1215DeleteFolderBody
          : strings.pw1215DeleteFileBody,
      actions: [
        HermesDialogAction(
          label: strings.commonCancel,
          value: false,
          style: HermesDialogActionStyle.cancel,
        ),
        HermesDialogAction(
          key: const ValueKey('pw1215-delete-confirm'),
          label: strings.commonDelete,
          value: true,
          style: HermesDialogActionStyle.destructive,
        ),
      ],
    );
    if (confirmed != true || !mounted) return;
    await _runWrite(() async {
      try {
        await writes.deleteProjectEntry(entry.path);
        controller.invalidate(entry.path);
        _snack(strings.pw1215Deleted, kind: HermesNoticeKind.success);
        await controller.reload(parent);
      } catch (error) {
        _snack(
          _writeFailureText(
            error,
            _WriteKind.delete,
            folder: entry.isDirectory,
          ),
          kind: HermesNoticeKind.error,
        );
        if (error is DesktopControlFailure && error.code == 404) {
          await controller.reload(parent);
        }
      }
    });
  }

  Future<void> _showFileInfo(ProjectFsEntry entry, int size) =>
      showHermesSurface<void>(
        context: context,
        builder: (sheetContext) {
          final strings = Strings.of(sheetContext);
          final colors = Theme.of(sheetContext).hermes;
          return Padding(
            key: const ValueKey('pf1215-file-info'),
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  entry.name,
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '${strings.pf1215FileNoPreview} · '
                  '${formatArtifactViewerBytes(size)}',
                  style: TextStyle(color: colors.textSecondary, fontSize: 12.5),
                ),
                const SizedBox(height: 12),
                SelectableText(
                  entry.path,
                  style: TextStyle(
                    color: colors.textSecondary,
                    fontSize: 12,
                    fontFamily: 'monospace',
                  ),
                ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  key: const ValueKey('pf1215-file-copy-path'),
                  onPressed: () async {
                    final notice = HermesNotice.of(sheetContext);
                    await Clipboard.setData(ClipboardData(text: entry.path));
                    notice.showSnackBar(
                      SnackBar(content: Text(strings.pj1215PathCopied)),
                    );
                    if (sheetContext.mounted) {
                      Navigator.of(sheetContext).pop();
                    }
                  },
                  icon: const Icon(Icons.copy_rounded, size: 18),
                  label: Text(strings.pj1215MenuCopyPath),
                ),
              ],
            ),
          );
        },
      );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final controller = widget.controller;
    if (controller.unsupported) {
      return _FilesNotice(
        key: const ValueKey('pf1215-fs-unsupported'),
        icon: Icons.folder_off_outlined,
        message: strings.pf1215FilesUnsupported,
      );
    }
    final listing = controller.listing;
    final failure = controller.failure;
    final children = <Widget>[
      _Breadcrumbs(controller: controller),
      const SizedBox(height: 8),
    ];
    if (failure != null) {
      children.add(
        _FilesNotice(
          key: const ValueKey('pf1215-fs-error'),
          icon: Icons.cloud_off_outlined,
          message: widget.failureText(failure),
          action: OutlinedButton.icon(
            key: const ValueKey('pf1215-fs-retry'),
            onPressed: controller.refresh,
            icon: const Icon(Icons.refresh_rounded),
            label: Text(strings.commonRetry),
          ),
        ),
      );
    } else if (listing == null) {
      children.add(
        const Padding(
          padding: EdgeInsets.only(top: 24),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    } else if (listing.error != null) {
      children.add(
        _FilesNotice(
          key: const ValueKey('pf1215-fs-error'),
          icon: Icons.folder_off_outlined,
          message: switch (listing.error) {
            'EACCES' => strings.pf1215FolderNoPermission,
            'ENOENT' => strings.pf1215FolderMissing,
            _ => strings.pf1215FolderReadFailed,
          },
        ),
      );
    } else if (listing.entries.isEmpty) {
      children.add(
        _FilesNotice(
          key: const ValueKey('pf1215-fs-empty'),
          icon: Icons.folder_open_outlined,
          message: strings.pf1215FolderEmpty,
        ),
      );
    } else {
      final deletable = controller.canWrite(ProjectFileWriteAction.delete);
      children.add(
        HermesListGroup(
          children: [
            for (final entry in listing.entries)
              HermesListRow(
                key: ValueKey('pf1215-fs-entry-${entry.path}'),
                leading: Icon(
                  entry.isDirectory
                      ? Icons.folder_rounded
                      : projectFileIcon(entry.name),
                  size: 20,
                  color: entry.isDirectory
                      ? colors.accent
                      : colors.textSecondary,
                ),
                title: entry.name,
                showChevron: entry.isDirectory && !deletable,
                trailing: _opening == entry.path
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : deletable
                    ? _EntryMenuButton(
                        key: ValueKey('pw1215-fs-entry-menu-${entry.path}'),
                        tooltip: strings.pw1215EntryActions(entry.name),
                        onPressed: (anchor) =>
                            unawaited(_openEntryMenu(entry, anchor)),
                      )
                    : null,
                muted: controller.pickFolders && !entry.isDirectory,
                onTap: entry.isDirectory
                    ? () => unawaited(controller.open(entry.path))
                    : controller.pickFolders
                    ? null
                    : () => unawaited(_openFile(entry)),
              ),
          ],
        ),
      );
    }
    final canAdd =
        controller.canWrite(ProjectFileWriteAction.createFolder) ||
        controller.canWrite(ProjectFileWriteAction.writeText) ||
        controller.canWrite(ProjectFileWriteAction.upload);
    final writable = controller.canWriteAnything;
    if (!controller.pickFolders) {
      children.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 10, 6, 0),
          child: Text(
            controller.writesBlockedByConnection
                ? strings.pw1215FilesReadOnlyConnection
                : writable
                ? strings.pw1215FilesWritableNote
                : strings.pf1215FilesReadOnlyNote,
            style: TextStyle(color: colors.textSecondary, fontSize: 11.5),
          ),
        ),
      );
    }
    if (canAdd && failure == null) {
      children[0] = Row(
        children: [
          Expanded(child: _Breadcrumbs(controller: controller)),
          const SizedBox(width: 4),
          _busy
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : IconButton.filledTonal(
                  key: const ValueKey('pw1215-fs-add'),
                  tooltip: strings.pw1215AddTooltip,
                  onPressed: listing == null || listing.error != null
                      ? null
                      : () => unawaited(_openAddMenu()),
                  icon: KeyedSubtree(
                    key: _addAnchor,
                    child: const Icon(Icons.add_rounded),
                  ),
                ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}

class _Breadcrumbs extends StatelessWidget {
  const _Breadcrumbs({required this.controller});

  final ProjectFilesController controller;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final crumbs = controller.crumbs;
    return Semantics(
      label: Strings.of(context).pf1215Breadcrumbs,
      container: true,
      // Long paths keep the current folder in view (reverse scroll); short
      // ones still start at the left edge.
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          reverse: true,
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: constraints.maxWidth),
            child: Row(
              children: [
                for (var i = 0; i < crumbs.length; i++) ...[
                  if (i > 0)
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 16,
                      color: colors.textDisabled,
                    ),
                  TextButton(
                    key: ValueKey('pf1215-crumb-$i'),
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, 36),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      foregroundColor: i == crumbs.length - 1
                          ? colors.textPrimary
                          : colors.textSecondary,
                    ),
                    onPressed: i == crumbs.length - 1
                        ? null
                        : () => unawaited(controller.open(crumbs[i].$2)),
                    child: Text(
                      crumbs[i].$1,
                      style: TextStyle(
                        fontWeight: i == crumbs.length - 1
                            ? FontWeight.w700
                            : FontWeight.w500,
                        color: i == crumbs.length - 1
                            ? colors.textPrimary
                            : colors.textSecondary,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NameField extends StatefulWidget {
  const _NameField({
    required this.label,
    required this.errorText,
    required this.onChanged,
    required this.onSubmitted,
  });

  final String label;
  final String? errorText;
  final ValueChanged<String> onChanged;
  final VoidCallback onSubmitted;

  @override
  State<_NameField> createState() => _NameFieldState();
}

class _NameFieldState extends State<_NameField> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    key: const ValueKey('pw1215-name-field'),
    controller: _controller,
    autofocus: true,
    autocorrect: false,
    enableSuggestions: false,
    onChanged: widget.onChanged,
    onSubmitted: (_) => widget.onSubmitted(),
    decoration: InputDecoration(
      labelText: widget.label,
      errorText: widget.errorText,
      errorMaxLines: 3,
    ),
  );
}

class _EntryMenuButton extends StatefulWidget {
  const _EntryMenuButton({
    required this.tooltip,
    required this.onPressed,
    super.key,
  });

  final String tooltip;
  final void Function(GlobalKey anchor) onPressed;

  @override
  State<_EntryMenuButton> createState() => _EntryMenuButtonState();
}

class _EntryMenuButtonState extends State<_EntryMenuButton> {
  final GlobalKey _anchor = GlobalKey();

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: widget.tooltip,
    visualDensity: VisualDensity.compact,
    onPressed: () => widget.onPressed(_anchor),
    icon: KeyedSubtree(
      key: _anchor,
      child: Icon(
        Icons.more_vert_rounded,
        size: 20,
        color: Theme.of(context).hermes.textSecondary,
      ),
    ),
  );
}

class _FilesNotice extends StatelessWidget {
  const _FilesNotice({
    required this.icon,
    required this.message,
    this.action,
    super.key,
  });

  final IconData icon;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return HermesPanel(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Icon(icon, color: colors.textSecondary, size: 28),
            const SizedBox(height: 10),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.textSecondary, fontSize: 12.5),
            ),
            if (action != null) ...[const SizedBox(height: 12), action!],
          ],
        ),
      ),
    );
  }
}

/// Text preview from Projects with an "Editar" action when writable. Saving
/// in the editor reloads the shown text from what was written.
class _EditableTextViewer extends StatefulWidget {
  const _EditableTextViewer({
    required this.name,
    required this.path,
    required this.mimeType,
    required this.initialText,
    required this.sizeBytes,
    required this.files,
    required this.writes,
    required this.canEdit,
    required this.failureText,
  });

  final String name;
  final String path;
  final String mimeType;
  final String initialText;
  final int sizeBytes;
  final HermesProjectFilesGateway files;

  /// Null when the preview must stay read-only.
  final HermesProjectFileWritesGateway? writes;
  final bool Function() canEdit;
  final String Function(Object failure) failureText;

  @override
  State<_EditableTextViewer> createState() => _EditableTextViewerState();
}

class _EditableTextViewerState extends State<_EditableTextViewer> {
  late String _text = widget.initialText;
  int _revision = 0;

  Future<void> _edit() async {
    final writes = widget.writes;
    if (writes == null) return;
    final saved = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => ProjectTextEditorScreen(
          name: widget.name,
          path: widget.path,
          initialText: _text,
          files: widget.files,
          writes: writes,
          failureText: widget.failureText,
        ),
      ),
    );
    if (saved != null && mounted) {
      setState(() {
        _text = saved;
        _revision++;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = Uint8List.fromList(utf8.encode(_text));
    return ArtifactViewerScreen(
      key: ValueKey('pw1215-viewer-$_revision'),
      name: widget.name,
      mimeType: widget.mimeType,
      loadBytes: () async => bytes,
      sizeBytes: _revision == 0 ? widget.sizeBytes : bytes.length,
      onEdit: widget.writes != null && widget.canEdit()
          ? () => unawaited(_edit())
          : null,
    );
  }
}

/// Picks a folder on the Hermes host, never on the phone: Desktop's remote
/// folder picker (`selectDesktopPaths` in remote mode) seeded at the
/// server's default folder. The whole server filesystem is browsable;
/// "Nueva carpeta" is offered when the connection may write. Returns the
/// absolute server path, or null when cancelled.
Future<String?> showServerFolderPicker(
  BuildContext context, {
  required HermesProjectFilesGateway files,
  HermesProjectFileWritesGateway? writes,
  bool readOnlyConnection = false,
  String? startPath,
  required String Function(Object failure) failureText,
}) => Navigator.of(context).push<String>(
  MaterialPageRoute(
    builder: (_) => _ServerFolderPicker(
      controller: ProjectFilesController(
        root: '/',
        gateway: files,
        writes: writes,
        readOnlyConnection: readOnlyConnection,
        pickFolders: true,
        initialPath: startPath,
      ),
      failureText: failureText,
    ),
  ),
);

class _ServerFolderPicker extends StatefulWidget {
  const _ServerFolderPicker({
    required this.controller,
    required this.failureText,
  });

  final ProjectFilesController controller;
  final String Function(Object failure) failureText;

  @override
  State<_ServerFolderPicker> createState() => _ServerFolderPickerState();
}

class _ServerFolderPickerState extends State<_ServerFolderPicker> {
  @override
  void dispose() {
    widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final controller = widget.controller;
    return Scaffold(
      appBar: AppBar(title: Text(strings.pc1215PickFolderTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          ProjectFilesBrowser(
            controller: controller,
            failureText: widget.failureText,
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              final listing = controller.listing;
              final usable =
                  !controller.unsupported &&
                  listing != null &&
                  listing.error == null;
              return FilledButton.icon(
                key: const ValueKey('pc1215-pick-folder-use'),
                onPressed: usable
                    ? () => Navigator.of(context).pop(controller.path)
                    : null,
                icon: const Icon(Icons.check_rounded),
                label: Text(strings.pc1215PickFolderUse),
              );
            },
          ),
        ),
      ),
    );
  }
}
