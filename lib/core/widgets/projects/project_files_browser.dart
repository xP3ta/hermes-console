import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../l10n/app_localizations.dart';
import '../../design/list.dart' show HermesListGroup, HermesListRow;
import '../../design/modal.dart' show showHermesSurface;
import '../../models/project_files.dart';
import '../../services/artifact_viewer_kind.dart';
import '../../services/desktop_control_gateway.dart';
import '../../theme/app_theme.dart';
import '../artifact_viewer/artifact_viewer_screen.dart';
import '../hermes_notice.dart';
import '../hermes_ui.dart' show HermesPanel;

/// Where the read-only browser of one project currently is. Owned by the
/// project screen so the folder survives switching between Chats and
/// Archivos, and so system back can go up one folder first.
class ProjectFilesController extends ChangeNotifier {
  ProjectFilesController({required this.root, required this.gateway})
    : _path = root;

  /// Project folder on the Hermes host; the browser never leaves it.
  final String root;

  /// Null when the connected gateway has no file surface at all.
  final HermesProjectFilesGateway? gateway;

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
    if (atRoot || !_path.startsWith('$root/')) return out;
    var current = root;
    for (final part in _path.substring(root.length + 1).split('/')) {
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

  bool _inside(String folder) => folder == root || folder.startsWith('$root/');

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

/// Read-only folder browser for the Archivos tab of a project: breadcrumbs,
/// folders first, tap a folder to enter it and a file to preview it in the
/// in-app artifact viewer. Nothing here writes to the server.
class ProjectFilesBrowser extends StatefulWidget {
  const ProjectFilesBrowser({
    required this.controller,
    required this.failureText,
    super.key,
  });

  final ProjectFilesController controller;
  final String Function(Object failure) failureText;

  @override
  State<ProjectFilesBrowser> createState() => _ProjectFilesBrowserState();
}

class _ProjectFilesBrowserState extends State<ProjectFilesBrowser> {
  String? _opening;

  @override
  void initState() {
    super.initState();
    // Listing starts after this frame: notifying mid-build would mark the
    // enclosing builders dirty while the tree is still building.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.controller.ensureStarted();
    });
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
          final bytes = Uint8List.fromList(utf8.encode(preview.text));
          show = () => _pushViewer(
            entry.name,
            preview.mimeType,
            bytes,
            preview.byteSize,
          );
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
      children.add(
        HermesListGroup(
          children: [
            for (final entry in listing.entries)
              HermesListRow(
                key: ValueKey('pf1215-fs-entry-${entry.path}'),
                leading: Icon(
                  entry.isDirectory
                      ? Icons.folder_rounded
                      : Icons.insert_drive_file_outlined,
                  size: 20,
                  color: entry.isDirectory
                      ? colors.accent
                      : colors.textSecondary,
                ),
                title: entry.name,
                showChevron: entry.isDirectory,
                trailing: _opening == entry.path
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : null,
                onTap: entry.isDirectory
                    ? () => unawaited(controller.open(entry.path))
                    : () => unawaited(_openFile(entry)),
              ),
          ],
        ),
      );
    }
    children.add(
      Padding(
        padding: const EdgeInsets.fromLTRB(6, 10, 6, 0),
        child: Text(
          strings.pf1215FilesReadOnlyNote,
          style: TextStyle(color: colors.textSecondary, fontSize: 11.5),
        ),
      ),
    );
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
