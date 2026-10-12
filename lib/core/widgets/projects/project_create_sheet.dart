import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../design/modal.dart'
    show HermesDialogAction, HermesDialogActionStyle, showHermesDialog;
import '../../models/desktop_control_center.dart';
import '../../models/project_files.dart';
import '../../services/desktop_control_gateway.dart';
import '../../theme/app_theme.dart';
import '../../utils/short_server_path.dart';
import '../../design/list.dart' show HermesListGroup, HermesSectionHeader;
import '../../design/tokens.dart';
import '../form_page.dart';
import '../hermes_ui.dart' show HermesField;

/// Picks one folder on the Hermes host; null when cancelled.
typedef ProjectFolderPick = Future<String?> Function();

/// Owner of a server folder by longest path match over a FRESH project tree
/// (Desktop refreshes before `projectIdForCwd`), or null.
typedef ProjectFolderOwner = Future<ProjectNode?> Function(String folder);

/// How the new-project dialog ended.
sealed class ProjectCreateOutcome {
  const ProjectCreateOutcome();
}

/// Why the typed idea was not saved to IDEA.md.
enum ProjectIdeaNotWritten {
  /// The primary folder already has an IDEA.md; it is never overwritten.
  exists,

  /// The folder listing failed or was incomplete, so an existing IDEA.md
  /// could not be ruled out; nothing was written.
  unverified,
}

/// `projects.create` succeeded. [ideaNotWritten] is set when an idea was
/// typed but IDEA.md was deliberately left alone.
final class ProjectCreatedOutcome extends ProjectCreateOutcome {
  final ProjectCreated project;
  final ProjectIdeaNotWritten? ideaNotWritten;
  const ProjectCreatedOutcome(this.project, {this.ideaNotWritten});
}

/// Whether [folder] on the Hermes host already holds `IDEA.md` in any case,
/// from the same `GET /api/fs/list` the file browser uses. Returns
/// [ProjectIdeaNotWritten.exists] when it does, `unverified` when the
/// listing failed, reported an error or hit the row cap, and null only when
/// a complete listing shows no IDEA.md.
Future<ProjectIdeaNotWritten?> projectIdeaBlocker(
  HermesProjectFilesGateway? files,
  String folder,
) async {
  if (files == null || files.projectFilesKnownUnsupported) {
    return ProjectIdeaNotWritten.unverified;
  }
  final ProjectDirectoryListing listing;
  try {
    listing = await files.listProjectDirectory(folder);
  } catch (_) {
    return ProjectIdeaNotWritten.unverified;
  }
  final ideaName = projectIdeaFileName.toLowerCase();
  if (listing.entries.any((entry) => entry.name.toLowerCase() == ideaName)) {
    return ProjectIdeaNotWritten.exists;
  }
  if (listing.error != null ||
      listing.entries.length >= projectFsListingLimit) {
    return ProjectIdeaNotWritten.unverified;
  }
  return null;
}

/// File Desktop saves the project idea to, in the primary folder.
const String projectIdeaFileName = 'IDEA.md';

/// The user chose to open the project that already covers a picked folder.
final class ProjectOpenExistingOutcome extends ProjectCreateOutcome {
  final ProjectNode project;
  const ProjectOpenExistingOutcome(this.project);
}

/// Last path segment, the name Desktop gives a project made from a folder.
String projectFolderBaseName(String path) {
  final trimmed = path.replaceAll(RegExp(r'/+$'), '');
  if (trimmed.isEmpty) return path;
  final cut = trimmed.lastIndexOf('/');
  return cut < 0 ? trimmed : trimmed.substring(cut + 1);
}

/// Server folder without trailing slashes (`/` stays `/`).
String normalizeServerFolder(String path) {
  final trimmed = path.trim().replaceAll(RegExp(r'/+$'), '');
  return trimmed.isEmpty && path.trim().startsWith('/') ? '/' : trimmed;
}

bool _isUnderPath(String root, String path) {
  final base = normalizeServerFolder(root);
  if (base.isEmpty) return false;
  return path == base || path.startsWith(base == '/' ? '/' : '$base/');
}

/// Desktop `projectIdForCwd`: the project (saved or detected) owning
/// [folder] by longest match over project, repository and worktree paths.
ProjectNode? projectOwningFolder(List<ProjectNode> projects, String folder) {
  final target = normalizeServerFolder(folder);
  ProjectNode? best;
  var bestLength = -1;
  for (final project in projects) {
    if (project.noProject) continue;
    final paths = [
      project.path,
      for (final repo in project.repositories) ...[
        repo.path,
        for (final lane in repo.lanes) lane.path,
      ],
    ];
    for (final raw in paths) {
      final path = normalizeServerFolder(raw);
      if (path.isNotEmpty &&
          _isUnderPath(path, target) &&
          path.length > bestLength) {
        bestLength = path.length;
        best = project;
      }
    }
  }
  return best;
}

/// Asks whether to open the project that already covers a picked folder.
/// Returns true to open it, false to use the folder anyway (only offered for
/// a detected repo, which Desktop also lets you name), null to cancel.
Future<bool?> confirmCoveredFolder(
  BuildContext context,
  ProjectNode owner,
) async {
  final strings = Strings.of(context);
  final label = owner.label.isEmpty
      ? strings.projectsCenterUnnamedProject
      : owner.label;
  final choice = await showHermesDialog<String>(
    context: context,
    surfaceKey: const ValueKey('pc1215-covered-dialog'),
    title: strings.pc1215CoveredTitle(label),
    message: owner.automatic
        ? strings.pc1215CoveredAutoBody
        : strings.pc1215CoveredBody,
    actions: [
      HermesDialogAction(
        label: strings.commonCancel,
        value: 'cancel',
        style: HermesDialogActionStyle.cancel,
      ),
      if (owner.automatic)
        HermesDialogAction(
          key: const ValueKey('pc1215-covered-add'),
          label: strings.pc1215CoveredAdd,
          value: 'add',
        ),
      HermesDialogAction(
        key: const ValueKey('pc1215-covered-open'),
        label: strings.pc1215CoveredOpen,
        value: 'open',
      ),
    ],
  );
  return switch (choice) {
    'open' => true,
    'add' => false,
    _ => null,
  };
}

/// Desktop's "New project" dialog as a full-screen form: name, one or more
/// server folders (the first is primary, with a path preview), and an
/// optional idea saved to IDEA.md in the primary folder (templates prefill
/// it). Sends `projects.create {name, folders, use: true}`; a failure keeps
/// the form open with the error.
///
/// Desktop's "Generate idea" (`llm.oneshot`) is deliberately absent: on the
/// owner's server every call failed (the auxiliary model rejected the
/// request) and the failure was silent, so the button only looked broken.
Future<ProjectCreateOutcome?> showProjectCreateSheet(
  BuildContext context, {
  required HermesProjectCreationGateway creation,
  required ProjectFolderPick pickFolder,
  required ProjectFolderOwner ownerOf,
  required String Function(Object failure) failureText,
  HermesProjectFileWritesGateway? ideaWriter,
  HermesProjectFilesGateway? ideaFolderReader,
}) => pushHermesFormPage<ProjectCreateOutcome>(
  context,
  name: 'project-create',
  builder: (_) => _ProjectCreateSheet(
    creation: creation,
    pickFolder: pickFolder,
    ownerOf: ownerOf,
    failureText: failureText,
    ideaWriter: ideaWriter,
    ideaFolderReader: ideaFolderReader,
  ),
);

class _ProjectCreateSheet extends StatefulWidget {
  final HermesProjectCreationGateway creation;
  final ProjectFolderPick pickFolder;
  final ProjectFolderOwner ownerOf;
  final String Function(Object failure) failureText;
  final HermesProjectFileWritesGateway? ideaWriter;
  final HermesProjectFilesGateway? ideaFolderReader;

  const _ProjectCreateSheet({
    required this.creation,
    required this.pickFolder,
    required this.ownerOf,
    required this.failureText,
    required this.ideaWriter,
    required this.ideaFolderReader,
  });

  @override
  State<_ProjectCreateSheet> createState() => _ProjectCreateSheetState();
}

class _ProjectCreateSheetState extends State<_ProjectCreateSheet> {
  final _name = TextEditingController();
  final _idea = TextEditingController();
  final List<String> _folders = [];
  bool _picking = false;
  bool _pending = false;
  String? _error;

  bool get _ideaSupported {
    final writer = widget.ideaWriter;
    return writer != null &&
        writer.projectFileWritesAllowed &&
        !writer.projectFileWriteKnownUnsupported(
          ProjectFileWriteAction.writeText,
        );
  }

  bool get _canSubmit =>
      !_pending && _name.text.trim().isNotEmpty && _folders.isNotEmpty;

  bool get _dirty =>
      _name.text.trim().isNotEmpty ||
      _folders.isNotEmpty ||
      _idea.text.trim().isNotEmpty;

  @override
  void dispose() {
    _name.dispose();
    _idea.dispose();
    super.dispose();
  }

  Future<void> _addFolder() async {
    if (_picking || _pending) return;
    setState(() => _picking = true);
    try {
      final picked = await widget.pickFolder();
      if (!mounted || picked == null) return;
      final folder = normalizeServerFolder(picked);
      if (!folder.startsWith('/') || _folders.contains(folder)) return;
      // A folder that already belongs to a project opens that project
      // instead of minting a duplicate (Desktop "Open folder…" upsert).
      final owner = await widget.ownerOf(folder);
      if (!mounted) return;
      if (owner != null) {
        final open = await confirmCoveredFolder(context, owner);
        if (!mounted || open == null) return;
        if (open) {
          Navigator.of(context).pop(ProjectOpenExistingOutcome(owner));
          return;
        }
      }
      setState(() {
        _folders.add(folder);
        _error = null;
        if (_name.text.trim().isEmpty) {
          _name.text = projectFolderBaseName(folder);
        }
      });
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _submit() async {
    if (!_canSubmit) return;
    final name = _name.text.trim();
    final idea = _idea.text.trim();
    setState(() {
      _pending = true;
      _error = null;
    });
    try {
      final created = await widget.creation.createProjectFromFolders(
        name: name,
        folders: List.of(_folders),
      );
      final writer = widget.ideaWriter;
      final primary = normalizeServerFolder(
        created.primaryPath.isEmpty ? _folders.first : created.primaryPath,
      );
      ProjectIdeaNotWritten? ideaNotWritten;
      if (idea.isNotEmpty && _ideaSupported && writer != null) {
        // Desktop (`writeProjectIdea`) writes blindly and the server's
        // write-text replaces an existing file; the phone never overwrites
        // an IDEA.md the folder already has, and skips the write when it
        // cannot tell.
        ideaNotWritten = await projectIdeaBlocker(
          widget.ideaFolderReader,
          primary,
        );
        if (ideaNotWritten == null) {
          try {
            await writer.writeProjectFileText(
              '${primary == '/' ? '' : primary}/$projectIdeaFileName',
              idea.endsWith('\n') ? idea : '$idea\n',
            );
          } catch (_) {
            // Best effort, like Desktop: the project exists either way.
          }
        }
      }
      if (!mounted) return;
      Navigator.of(
        context,
      ).pop(ProjectCreatedOutcome(created, ideaNotWritten: ideaNotWritten));
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _pending = false;
        _error = widget.failureText(error);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final primary = _folders.isEmpty ? null : _folders.first;
    final previewStyle = TextStyle(
      color: colors.textSecondary,
      fontSize: 12.5,
      height: 1.4,
    );
    return HermesFormPage(
      bodyKey: const ValueKey('pc1215-create-sheet'),
      title: strings.pc1215NewProject,
      submitLabel: strings.pc1215Create,
      submitKey: const ValueKey('pc1215-create-submit'),
      onSubmit: _canSubmit ? _submit : null,
      busy: _pending,
      dirty: _dirty,
      children: [
        // Shown at the top, where the user is after tapping Create.
        if (_error != null) ...[
          const SizedBox(height: HermesSpace.x3),
          Column(
            key: const ValueKey('pc1215-create-error'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                strings.pc1215CreateFailed,
                style: TextStyle(
                  color: colors.error,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                _error!,
                style: TextStyle(color: colors.error, fontSize: 12.5),
              ),
            ],
          ),
        ],
        const SizedBox(height: HermesSpace.x4),
        HermesField(
          fieldKey: const ValueKey('pc1215-create-name'),
          controller: _name,
          label: strings.fp1215NameLabel,
          hint: strings.pc1215NameHint,
          enabled: !_pending,
          autofocus: true,
          maxLength: 120,
          textInputAction: TextInputAction.done,
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _submit(),
        ),
        HermesSectionHeader(strings.pc1215FoldersLabel),
        HermesListGroup(
          children: [
            if (_folders.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  HermesSpace.rowH,
                  HermesSpace.x4,
                  HermesSpace.rowH,
                  HermesSpace.x2,
                ),
                child: Text(
                  strings.pc1215NoFolders,
                  style: TextStyle(color: colors.textSecondary, fontSize: 13.5),
                ),
              ),
            for (final (index, folder) in _folders.indexed)
              _FolderRow(
                key: ValueKey('pc1215-create-folder-$folder'),
                folder: folder,
                primary: index == 0,
                removeKey: ValueKey('pc1215-create-remove-$folder'),
                onRemove: _pending
                    ? null
                    : () => setState(() => _folders.remove(folder)),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: HermesSpace.x1,
                  vertical: HermesSpace.x1,
                ),
                child: TextButton.icon(
                  key: const ValueKey('pc1215-create-add-folder'),
                  style: TextButton.styleFrom(
                    foregroundColor: colors.accentText,
                  ),
                  onPressed: _pending || _picking ? null : _addFolder,
                  icon: const Icon(Icons.create_new_folder_outlined, size: 20),
                  label: Text(strings.pc1215AddFolder),
                ),
              ),
            ),
          ],
        ),
        if (primary != null)
          Padding(
            key: const ValueKey('pc1215-create-path-preview'),
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
            child: Text(
              strings.fp1215ProjectPathPreview(primary),
              style: previewStyle,
            ),
          ),
        if (_ideaSupported) ...[
          HermesFormSection(
            child: HermesField(
              fieldKey: const ValueKey('pc1215-create-idea'),
              controller: _idea,
              label: strings.pc1215IdeaLabel,
              hint: strings.pc1215IdeaHint,
              enabled: !_pending,
              keyboardType: TextInputType.multiline,
              minLines: 6,
              maxLines: null,
              onChanged: (_) => setState(() {}),
            ),
          ),
          if (primary != null && _idea.text.trim().isNotEmpty)
            Padding(
              key: const ValueKey('pc1215-create-idea-preview'),
              padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
              child: Text(
                strings.fp1215IdeaPathPreview(
                  '${primary == '/' ? '' : primary}/$projectIdeaFileName',
                ),
                style: previewStyle,
              ),
            ),
        ],
      ],
    );
  }
}

/// One picked server folder: the full path (wrapping, never a one-line
/// stub), "primary" under the first, and a remove button.
class _FolderRow extends StatelessWidget {
  final String folder;
  final bool primary;
  final Key removeKey;
  final VoidCallback? onRemove;

  const _FolderRow({
    super.key,
    required this.folder,
    required this.primary,
    required this.removeKey,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: HermesSpace.rowMin),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(HermesSpace.rowH, 6, 4, 6),
        child: Row(
          children: [
            Icon(Icons.folder_outlined, size: 22, color: colors.textSecondary),
            const SizedBox(width: HermesSpace.x3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    shortServerPath(folder),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (primary)
                    Text(
                      strings.pc1215PrimaryBadge,
                      style: TextStyle(
                        color: colors.accent,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                ],
              ),
            ),
            IconButton(
              key: removeKey,
              tooltip: strings.pc1215RemoveFolder,
              onPressed: onRemove,
              icon: const Icon(Icons.remove_circle_outline_rounded, size: 20),
            ),
          ],
        ),
      ),
    );
  }
}
