import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../design/modal.dart'
    show HermesDialogAction, HermesDialogActionStyle, showHermesDialog;
import '../../models/desktop_control_center.dart';
import '../../services/desktop_control_gateway.dart';
import '../../theme/app_theme.dart';
import '../../utils/short_server_path.dart';
import '../hermes_premium_ui.dart' show showHermesFloatingSurface;
import 'project_idea_templates.dart';

/// Picks one folder on the Hermes host; null when cancelled.
typedef ProjectFolderPick = Future<String?> Function();

/// Owner of a server folder by longest path match over a FRESH project tree
/// (Desktop refreshes before `projectIdForCwd`), or null.
typedef ProjectFolderOwner = Future<ProjectNode?> Function(String folder);

/// How the new-project dialog ended.
sealed class ProjectCreateOutcome {
  const ProjectCreateOutcome();
}

/// `projects.create` succeeded.
final class ProjectCreatedOutcome extends ProjectCreateOutcome {
  final ProjectCreated project;
  const ProjectCreatedOutcome(this.project);
}

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

/// Desktop's "New project" dialog: name, one or more server folders (the
/// first is primary), an optional idea saved to IDEA.md in the primary
/// folder, "Generate idea" and template chips. Sends
/// `projects.create {name, folders, use: true}`; a failure keeps the dialog
/// open with the error.
Future<ProjectCreateOutcome?> showProjectCreateSheet(
  BuildContext context, {
  required HermesProjectCreationGateway creation,
  required ProjectFolderPick pickFolder,
  required ProjectFolderOwner ownerOf,
  required String Function(Object failure) failureText,
  HermesProjectFileWritesGateway? ideaWriter,
}) => showHermesFloatingSurface<ProjectCreateOutcome>(
  context: context,
  builder: (_) => _ProjectCreateSheet(
    creation: creation,
    pickFolder: pickFolder,
    ownerOf: ownerOf,
    failureText: failureText,
    ideaWriter: ideaWriter,
  ),
);

class _ProjectCreateSheet extends StatefulWidget {
  final HermesProjectCreationGateway creation;
  final ProjectFolderPick pickFolder;
  final ProjectFolderOwner ownerOf;
  final String Function(Object failure) failureText;
  final HermesProjectFileWritesGateway? ideaWriter;

  const _ProjectCreateSheet({
    required this.creation,
    required this.pickFolder,
    required this.ownerOf,
    required this.failureText,
    required this.ideaWriter,
  });

  @override
  State<_ProjectCreateSheet> createState() => _ProjectCreateSheetState();
}

class _ProjectCreateSheetState extends State<_ProjectCreateSheet> {
  final _name = TextEditingController();
  final _idea = TextEditingController();
  final List<String> _folders = [];
  List<ProjectIdeaTemplate> _templates = randomProjectIdeaTemplates();
  bool _picking = false;
  bool _pending = false;
  bool _generating = false;
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

  Future<void> _generate() async {
    if (_generating || _pending) return;
    setState(() => _generating = true);
    try {
      final text = await widget.creation.generateProjectIdea(_name.text);
      if (!mounted || text.isEmpty) return;
      setState(() => _idea.text = text);
    } finally {
      if (mounted) setState(() => _generating = false);
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
      if (idea.isNotEmpty && _ideaSupported && writer != null) {
        try {
          await writer.writeProjectFileText(
            '${primary == '/' ? '' : primary}/IDEA.md',
            idea.endsWith('\n') ? idea : '$idea\n',
          );
        } catch (_) {
          // Best effort, like Desktop: the project exists either way.
        }
      }
      if (!mounted) return;
      Navigator.of(context).pop(ProjectCreatedOutcome(created));
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
    final language = Localizations.localeOf(context).languageCode;
    final label = TextStyle(
      color: colors.textSecondary,
      fontSize: 12,
      fontWeight: FontWeight.w600,
    );
    return SingleChildScrollView(
      key: const ValueKey('pc1215-create-sheet'),
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            strings.pc1215NewProject,
            style: TextStyle(
              color: colors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            strings.pc1215CreateDesc,
            style: TextStyle(
              color: colors.textSecondary,
              fontSize: 12.5,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('pc1215-create-name'),
            controller: _name,
            enabled: !_pending,
            autofocus: true,
            maxLength: 120,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(hintText: strings.pc1215NameHint),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 4),
          Text(strings.pc1215FoldersLabel, style: label),
          const SizedBox(height: 4),
          if (_folders.isEmpty)
            Text(
              strings.pc1215NoFolders,
              style: TextStyle(color: colors.textDisabled, fontSize: 12.5),
            )
          else
            for (final (index, folder) in _folders.indexed)
              ListTile(
                key: ValueKey('pc1215-create-folder-$folder'),
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: Icon(
                  Icons.folder_outlined,
                  size: 20,
                  color: colors.textSecondary,
                ),
                title: Text(
                  shortServerPath(folder),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: colors.textPrimary, fontSize: 13.5),
                ),
                subtitle: index == 0
                    ? Text(
                        strings.pc1215PrimaryBadge,
                        style: TextStyle(
                          color: colors.textSecondary,
                          fontSize: 11,
                        ),
                      )
                    : null,
                trailing: IconButton(
                  key: ValueKey('pc1215-create-remove-$folder'),
                  tooltip: strings.pc1215RemoveFolder,
                  onPressed: _pending
                      ? null
                      : () => setState(() => _folders.remove(folder)),
                  icon: const Icon(Icons.close_rounded, size: 18),
                ),
              ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('pc1215-create-add-folder'),
              onPressed: _pending || _picking ? null : _addFolder,
              icon: const Icon(Icons.create_new_folder_outlined, size: 18),
              label: Text(strings.pc1215AddFolder),
            ),
          ),
          if (_ideaSupported) ...[
            const SizedBox(height: 8),
            Text(strings.pc1215IdeaLabel, style: label),
            const SizedBox(height: 4),
            TextField(
              key: const ValueKey('pc1215-create-idea'),
              controller: _idea,
              enabled: !_pending,
              minLines: 3,
              maxLines: 6,
              decoration: InputDecoration(
                hintText: strings.pc1215IdeaHint,
                suffixIcon: _generating
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : IconButton(
                        key: const ValueKey('pc1215-create-generate'),
                        tooltip: strings.pc1215IdeaGenerate,
                        onPressed: _pending ? null : _generate,
                        icon: const Icon(Icons.auto_awesome_outlined),
                      ),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final (index, template) in _templates.indexed)
                  ActionChip(
                    key: ValueKey('pc1215-idea-template-$index'),
                    avatar: Text(template.emoji),
                    label: Text(template.label(language)),
                    onPressed: _pending
                        ? null
                        : () => setState(
                            () => _idea.text = template.idea(language),
                          ),
                  ),
                IconButton(
                  key: const ValueKey('pc1215-create-shuffle'),
                  tooltip: strings.pc1215IdeaShuffle,
                  onPressed: _pending
                      ? null
                      : () => setState(
                          () => _templates = randomProjectIdeaTemplates(),
                        ),
                  icon: const Icon(Icons.casino_outlined, size: 20),
                ),
              ],
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 10),
            Column(
              key: const ValueKey('pc1215-create-error'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  strings.pc1215CreateFailed,
                  style: TextStyle(
                    color: colors.error,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  _error!,
                  style: TextStyle(color: colors.error, fontSize: 12),
                ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          FilledButton.icon(
            key: const ValueKey('pc1215-create-submit'),
            onPressed: _canSubmit ? _submit : null,
            icon: _pending
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check_rounded),
            label: Text(strings.pc1215Create),
          ),
        ],
      ),
    );
  }
}
