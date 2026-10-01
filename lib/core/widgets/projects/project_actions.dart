import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../l10n/app_localizations.dart';
import '../../design/content.dart' show HermesSelectRow;
import '../../design/modal.dart'
    show
        HermesDialogAction,
        HermesDialogActionStyle,
        HermesOption,
        showHermesDialog,
        showHermesFormDialog,
        showHermesOptions,
        showHermesSurface;
import '../../models/desktop_control_center.dart';
import '../../services/desktop_control_gateway.dart';
import '../../theme/app_theme.dart';
import '../../utils/short_server_path.dart';
import '../hermes_premium_ui.dart'
    show DisposeControllersOnUnmount, showHermesFloatingSurface;
import 'project_appearance.dart';

/// What the project menu asked the screen to do. The screen owns navigation
/// and reloads; the sheet only reports the choice.
enum ProjectMenuAction {
  newChat,
  rename,
  appearance,
  setActive,
  copyPath,
  newWorktree,
  openBranch,
  hide,
  delete,
}

/// Why a write action is unavailable, so the copy can say so honestly.
enum ProjectWriteBlock {
  /// The gateway has no project write surface (older Hermes / legacy fake).
  unsupportedServer,

  /// This connection is configured read-only.
  readOnly,
}

/// Whether worktree helpers are known to be missing on this server.
enum ProjectGitBlock { unsupportedServer, readOnly }

/// Root working folder of a project: its primary path, else the first repo
/// that has one (Desktop `projectRootCwd`). Empty for the Home bucket.
String projectRootPath(ProjectNode project) {
  if (project.path.trim().isNotEmpty) return project.path.trim();
  for (final repo in project.repositories) {
    if (repo.path.trim().isNotEmpty) return repo.path.trim();
  }
  return '';
}

/// Saved projects carry a `p_<hex>` id; auto-discovered ones use their path.
bool isSavedProject(ProjectNode project) =>
    !project.automatic && !project.noProject && project.id.startsWith('p_');

/// Main branch label shown on the card (the repo's trunk lane), if known.
String projectMainBranch(ProjectNode project) {
  for (final repo in project.repositories) {
    for (final lane in repo.lanes) {
      if (lane.isMain && lane.label.isNotEmpty) return lane.label;
    }
  }
  for (final repo in project.repositories) {
    if (repo.lanes.isNotEmpty && repo.lanes.first.label.isNotEmpty) {
      return repo.lanes.first.label;
    }
  }
  return '';
}

/// Relative "last activity" copy with natural wording in both locales.
String projectAgo(Strings strings, double epochSeconds, {DateTime? now}) {
  if (epochSeconds <= 0) return '';
  final seconds = epochSeconds > 1e12 ? epochSeconds / 1000 : epochSeconds;
  final at = DateTime.fromMillisecondsSinceEpoch((seconds * 1000).round());
  final diff = (now ?? DateTime.now()).difference(at);
  if (diff.isNegative || diff.inMinutes < 1) return strings.pj1215AgoNow;
  if (diff.inHours < 1) return strings.pj1215AgoMinutes(diff.inMinutes);
  if (diff.inDays < 1) return strings.pj1215AgoHours(diff.inHours);
  if (diff.inDays < 30) return strings.pj1215AgoDays(diff.inDays);
  return strings.pj1215AgoDate('${at.day}/${at.month}/${at.year}');
}

/// Colored glyph used on cards, headers and the menu.
class ProjectGlyph extends StatelessWidget {
  final ProjectNode project;
  final double size;

  const ProjectGlyph({required this.project, this.size = 22, super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final tint = parseProjectColor(project.color);
    return Container(
      width: size + 16,
      height: size + 16,
      decoration: BoxDecoration(
        color: (tint ?? colors.textSecondary).withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(
        projectGlyph(project),
        size: size,
        color: tint ?? colors.textSecondary,
      ),
    );
  }
}

/// Floating surface with the Desktop project menu. Items that need the desktop
/// computer (folder picker / file manager) stay visible but disabled with
/// "Solo desde Desktop", so the phone never pretends to do them.
Future<ProjectMenuAction?> showProjectMenu(
  BuildContext context, {
  required ProjectNode project,
  required bool isActive,
  required ProjectWriteBlock? writeBlock,
  required ProjectGitBlock? gitBlock,
}) {
  return showHermesSurface<ProjectMenuAction>(
    context: context,
    builder: (sheetContext) {
      final strings = Strings.of(sheetContext);
      final colors = Theme.of(sheetContext).hermes;
      final saved = isSavedProject(project);
      final root = projectRootPath(project);
      final label = project.label.isEmpty
          ? strings.projectsCenterUnnamedProject
          : project.label;
      String? writeNote() => switch (writeBlock) {
        ProjectWriteBlock.unsupportedServer => strings.pj1215NeedsNewerHermes,
        ProjectWriteBlock.readOnly => strings.pj1215ReadOnlyConnection,
        null => null,
      };
      String? gitNote() => switch (gitBlock) {
        ProjectGitBlock.unsupportedServer => strings.pj1215NeedsNewerHermes,
        ProjectGitBlock.readOnly => strings.pj1215ReadOnlyConnection,
        null => root.isEmpty ? strings.pj1215NoFolder : null,
      };

      Widget item(
        ProjectMenuAction? action,
        IconData icon,
        String title, {
        String? note,
        bool destructive = false,
        Key? key,
      }) {
        final enabled = action != null && note == null;
        final tint = destructive ? colors.error : colors.textPrimary;
        return ListTile(
          key: key,
          enabled: enabled,
          leading: Icon(
            icon,
            color: enabled ? tint : colors.textDisabled,
            size: 21,
          ),
          title: Text(
            title,
            style: TextStyle(
              color: enabled ? tint : colors.textDisabled,
              fontWeight: FontWeight.w600,
              fontSize: 14.5,
            ),
          ),
          subtitle: note == null
              ? null
              : Text(
                  note,
                  style: TextStyle(color: colors.textSecondary, fontSize: 12),
                ),
          onTap: enabled ? () => Navigator.of(sheetContext).pop(action) : null,
        );
      }

      return SingleChildScrollView(
        padding: const EdgeInsets.only(top: 18, bottom: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Row(
                children: [
                  ProjectGlyph(project: project, size: 18),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colors.textPrimary,
                            fontWeight: FontWeight.w700,
                            fontSize: 16,
                          ),
                        ),
                        if (root.isNotEmpty)
                          Text(
                            shortServerPath(root),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: colors.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            item(
              ProjectMenuAction.newChat,
              Icons.add_comment_outlined,
              strings.pj1215MenuNewChat,
              key: const ValueKey('pj1215-menu-new-chat'),
            ),
            if (!project.noProject) ...[
              if (saved)
                item(
                  ProjectMenuAction.rename,
                  Icons.edit_outlined,
                  strings.pj1215MenuRename,
                  note: writeNote(),
                  key: const ValueKey('pj1215-menu-rename'),
                ),
              item(
                ProjectMenuAction.appearance,
                Icons.palette_outlined,
                strings.pj1215MenuAppearance,
                // An auto project is adopted through its folder (Desktop).
                note:
                    writeNote() ??
                    (!saved && root.isEmpty ? strings.pj1215NoFolder : null),
                key: const ValueKey('pj1215-menu-appearance'),
              ),
              if (saved)
                item(
                  isActive ? null : ProjectMenuAction.setActive,
                  Icons.track_changes_rounded,
                  isActive
                      ? strings.pj1215MenuIsActive
                      : strings.pj1215MenuSetActive,
                  note: isActive ? null : writeNote(),
                  key: const ValueKey('pj1215-menu-set-active'),
                ),
              const Divider(height: 12),
              item(
                ProjectMenuAction.newWorktree,
                Icons.call_split_rounded,
                strings.pj1215MenuNewWorktree,
                note: gitNote(),
                key: const ValueKey('pj1215-menu-new-worktree'),
              ),
              item(
                ProjectMenuAction.openBranch,
                Icons.alt_route_rounded,
                strings.pj1215MenuOpenBranch,
                note: gitNote(),
                key: const ValueKey('pj1215-menu-open-branch'),
              ),
              item(
                root.isEmpty ? null : ProjectMenuAction.copyPath,
                Icons.copy_rounded,
                strings.pj1215MenuCopyPath,
                key: const ValueKey('pj1215-menu-copy-path'),
              ),
              const Divider(height: 12),
              if (saved)
                item(
                  null,
                  Icons.create_new_folder_outlined,
                  strings.pj1215MenuAddFolder,
                  note: strings.pj1215DesktopOnly,
                  key: const ValueKey('pj1215-menu-add-folder'),
                ),
              item(
                null,
                Icons.folder_open_outlined,
                strings.pj1215MenuReveal,
                note: strings.pj1215DesktopOnly,
                key: const ValueKey('pj1215-menu-reveal'),
              ),
              const Divider(height: 12),
              if (saved)
                item(
                  ProjectMenuAction.delete,
                  Icons.delete_outline_rounded,
                  strings.pj1215MenuDelete,
                  note: writeNote(),
                  destructive: true,
                  key: const ValueKey('pj1215-menu-delete'),
                )
              else
                item(
                  ProjectMenuAction.hide,
                  Icons.visibility_off_outlined,
                  strings.pj1215MenuHide,
                  key: const ValueKey('pj1215-menu-hide'),
                ),
            ],
          ],
        ),
      );
    },
  );
}

/// Rename dialog. Returns the trimmed new name, or null when cancelled.
Future<String?> showProjectRenameDialog(
  BuildContext context, {
  required String current,
}) async {
  final strings = Strings.of(context);
  final controller = TextEditingController(text: current);
  final saved = await showHermesFormDialog<bool>(
    context: context,
    title: strings.pj1215RenameTitle,
    body: (dialogContext, setState) => DisposeControllersOnUnmount(
      controllers: [controller],
      child: TextField(
        key: const ValueKey('pj1215-rename-field'),
        controller: controller,
        autofocus: true,
        maxLength: 120,
        textInputAction: TextInputAction.done,
        onChanged: (_) => setState(() {}),
        onSubmitted: (value) {
          if (value.trim().isEmpty) return;
          Navigator.of(dialogContext).pop(true);
        },
        decoration: InputDecoration(hintText: strings.pj1215RenameHint),
      ),
    ),
    enabled: (value) => !value || controller.text.trim().isNotEmpty,
    actions: [
      HermesDialogAction(
        label: strings.commonCancel,
        value: false,
        style: HermesDialogActionStyle.cancel,
      ),
      HermesDialogAction(
        key: const ValueKey('pj1215-rename-save'),
        label: strings.commonSave,
        value: true,
      ),
    ],
  );
  if (saved != true) return null;
  final value = controller.text.trim();
  return value.isEmpty ? null : value;
}

/// Destructive confirmation for `projects.delete`, with Desktop's promise
/// that files, repositories and worktrees are left untouched.
Future<bool> confirmProjectDelete(BuildContext context, String label) async {
  final strings = Strings.of(context);
  final confirmed = await showHermesDialog<bool>(
    context: context,
    title: strings.pj1215DeleteTitle(label),
    message: strings.pj1215DeleteBody,
    actions: [
      HermesDialogAction(
        label: strings.commonCancel,
        value: false,
        style: HermesDialogActionStyle.cancel,
      ),
      HermesDialogAction(
        key: const ValueKey('pj1215-delete-confirm'),
        label: strings.pj1215DeleteConfirm,
        value: true,
        style: HermesDialogActionStyle.destructive,
      ),
    ],
  );
  return confirmed == true;
}

/// Appearance choice: `color`/`icon` are wire values; '' clears.
typedef ProjectAppearancePatch = ({String? color, String? icon});

/// Color swatches + icon grid, the same vocabulary as Desktop's picker.
Future<ProjectAppearancePatch?> showProjectAppearanceSheet(
  BuildContext context, {
  required ProjectNode project,
}) {
  return showHermesSurface<ProjectAppearancePatch>(
    context: context,
    builder: (sheetContext) {
      final strings = Strings.of(sheetContext);
      final colors = Theme.of(sheetContext).hermes;
      final currentColor = project.color;
      final currentIcon = project.icon;
      final tint = parseProjectColor(currentColor) ?? colors.textSecondary;
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              strings.pj1215AppearanceTitle,
              style: TextStyle(
                color: colors.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (project.automatic) ...[
              const SizedBox(height: 6),
              Text(
                strings.pj1215AppearanceAdoptNote,
                style: TextStyle(color: colors.textSecondary, fontSize: 12),
              ),
            ],
            const SizedBox(height: 14),
            Text(
              strings.pj1215AppearanceColor,
              style: TextStyle(color: colors.textSecondary, fontSize: 12.5),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                _SwatchButton(
                  key: const ValueKey('pj1215-color-none'),
                  color: null,
                  selected: currentColor.isEmpty,
                  label: strings.pj1215AppearanceNoColor,
                  onTap: () =>
                      Navigator.of(sheetContext).pop((color: '', icon: null)),
                ),
                for (final (index, swatch) in projectColorSwatches.indexed)
                  _SwatchButton(
                    key: ValueKey('pj1215-color-$index'),
                    color: parseProjectColor(swatch),
                    selected: currentColor == swatch,
                    label: strings.pj1215AppearanceColorN(index + 1),
                    onTap: () => Navigator.of(
                      sheetContext,
                    ).pop((color: swatch, icon: null)),
                  ),
              ],
            ),
            const SizedBox(height: 18),
            Text(
              strings.pj1215AppearanceIcon,
              style: TextStyle(color: colors.textSecondary, fontSize: 12.5),
            ),
            const SizedBox(height: 8),
            GridView.count(
              crossAxisCount: 7,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 6,
              crossAxisSpacing: 6,
              children: [
                for (final (name, icon) in projectIconChoices)
                  Semantics(
                    button: true,
                    selected: currentIcon == name,
                    label: name,
                    child: InkWell(
                      key: ValueKey('pj1215-icon-$name'),
                      borderRadius: BorderRadius.circular(10),
                      // Tapping the chosen icon again clears it (Desktop).
                      onTap: () => Navigator.of(sheetContext).pop((
                        color: null,
                        icon: currentIcon == name ? '' : name,
                      )),
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          color: currentIcon == name
                              ? tint.withValues(alpha: 0.18)
                              : null,
                        ),
                        child: Icon(
                          icon,
                          size: 22,
                          color: currentIcon == name
                              ? tint
                              : colors.textSecondary,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      );
    },
  );
}

class _SwatchButton extends StatelessWidget {
  final Color? color;
  final bool selected;
  final String label;
  final VoidCallback onTap;

  const _SwatchButton({
    required this.color,
    required this.selected,
    required this.label,
    required this.onTap,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: InkResponse(
        onTap: onTap,
        radius: 24,
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
            border: Border.all(
              color: selected ? colors.textPrimary : colors.divider,
              width: selected ? 2.5 : 1,
            ),
          ),
          child: color == null
              ? Icon(Icons.block_rounded, size: 18, color: colors.textSecondary)
              : null,
        ),
      ),
    );
  }
}

/// The "new worktree" / "open existing branch" flow, mirroring Desktop's
/// WorktreeDialog: a branch name sanitised as a git ref plus a base-branch
/// picker, or a branch list where each row says what tapping it does.
/// Returns the folder where the new chat should start, or null.
Future<String?> showWorktreeSheet(
  BuildContext context, {
  required HermesProjectManagementGateway gateway,
  required List<ProjectRepositoryNode> repositories,
  required String fallbackRepoPath,
  bool startInConvertMode = false,
  required void Function(Object error) onFailure,
}) {
  final repos = <(String, String)>[
    for (final repo in repositories)
      if (repo.path.trim().isNotEmpty)
        (
          repo.label.isEmpty ? shortServerPath(repo.path) : repo.label,
          repo.path,
        ),
  ];
  if (repos.isEmpty && fallbackRepoPath.trim().isNotEmpty) {
    repos.add((shortServerPath(fallbackRepoPath), fallbackRepoPath.trim()));
  }
  return showHermesFloatingSurface<String>(
    context: context,
    builder: (_) => _WorktreeSheet(
      gateway: gateway,
      repos: repos,
      startInConvertMode: startInConvertMode,
      onFailure: onFailure,
    ),
  );
}

/// Desktop `gitRef` sanitiser, reduced to what a phone keyboard produces.
String sanitizeGitRef(String raw) {
  var value = raw.replaceAll(RegExp(r'\s+'), '-');
  value = value.replaceAll(RegExp(r'[~^:?*\[\]\\\x00-\x1F\x7F]'), '');
  value = value.replaceAll(RegExp(r'\.{2,}'), '.');
  value = value.replaceAll(RegExp(r'/{2,}'), '/');
  value = value.replaceAll('@{', '');
  return value;
}

bool isValidGitRef(String value) {
  final v = value.trim();
  if (v.isEmpty || v.length > 200) return false;
  if (v.startsWith('-') || v.startsWith('/') || v.startsWith('.')) {
    return false;
  }
  if (v.endsWith('/') || v.endsWith('.') || v.endsWith('.lock')) return false;
  return sanitizeGitRef(v) == v;
}

class _WorktreeSheet extends StatefulWidget {
  final HermesProjectManagementGateway gateway;
  final List<(String, String)> repos;
  final bool startInConvertMode;
  final void Function(Object error) onFailure;

  const _WorktreeSheet({
    required this.gateway,
    required this.repos,
    required this.startInConvertMode,
    required this.onFailure,
  });

  @override
  State<_WorktreeSheet> createState() => _WorktreeSheetState();
}

class _WorktreeSheetState extends State<_WorktreeSheet> {
  final _name = TextEditingController();
  late String _repoPath = widget.repos.isEmpty ? '' : widget.repos.first.$2;
  late bool _convert = widget.startInConvertMode;
  bool _pending = false;
  bool _loadingBases = false;
  bool _loadingBranches = false;
  List<ProjectGitBaseBranch> _bases = const [];
  List<ProjectGitBranch> _branches = const [];
  String _base = '';
  int _loadToken = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final token = ++_loadToken;
    final repo = _repoPath;
    if (repo.isEmpty) return;
    if (_convert) {
      setState(() => _loadingBranches = true);
      try {
        final list = await widget.gateway.listBranches(repo);
        if (!mounted || token != _loadToken) return;
        setState(() => _branches = list);
      } catch (error) {
        if (!mounted || token != _loadToken) return;
        setState(() => _branches = const []);
        widget.onFailure(error);
      } finally {
        if (mounted && token == _loadToken) {
          setState(() => _loadingBranches = false);
        }
      }
    } else {
      setState(() => _loadingBases = true);
      try {
        final list = await widget.gateway.listBaseBranches(repo);
        if (!mounted || token != _loadToken) return;
        final fallback = list
            .where((b) => b.isDefault)
            .followedBy(list)
            .map((b) => b.name)
            .firstOrNull;
        setState(() {
          _bases = list;
          if (_base.isEmpty || !list.any((b) => b.name == _base)) {
            _base = fallback ?? '';
          }
        });
      } catch (error) {
        if (!mounted || token != _loadToken) return;
        setState(() => _bases = const []);
        widget.onFailure(error);
      } finally {
        if (mounted && token == _loadToken) {
          setState(() => _loadingBases = false);
        }
      }
    }
  }

  Future<void> _create() async {
    final branch = _name.text.trim();
    if (_pending || !isValidGitRef(branch) || _repoPath.isEmpty) return;
    setState(() => _pending = true);
    try {
      final result = await widget.gateway.addWorktree(
        _repoPath,
        branch: branch,
        base: _base.isEmpty ? null : _base,
      );
      if (!mounted) return;
      Navigator.of(context).pop(result.path);
    } catch (error) {
      if (!mounted) return;
      setState(() => _pending = false);
      widget.onFailure(error);
    }
  }

  Future<void> _openBranch(ProjectGitBranch branch) async {
    if (_pending || _repoPath.isEmpty) return;
    setState(() => _pending = true);
    try {
      final String path;
      if (branch.worktreePath.isNotEmpty) {
        path = branch.worktreePath;
      } else if (branch.isDefault) {
        await widget.gateway.switchBranch(_repoPath, branch.name);
        path = _repoPath;
      } else {
        final result = await widget.gateway.addWorktree(
          _repoPath,
          existingBranch: branch.name,
        );
        path = result.path;
      }
      if (!mounted) return;
      Navigator.of(context).pop(path);
    } catch (error) {
      if (!mounted) return;
      setState(() => _pending = false);
      widget.onFailure(error);
    }
  }

  String _repoLabel() {
    for (final (label, path) in widget.repos) {
      if (path == _repoPath) return label;
    }
    return '';
  }

  String _baseLabel(Strings strings) {
    for (final base in _bases) {
      if (base.name != _base) continue;
      return base.isDefault
          ? strings.pj1215WorktreeBaseDefault(base.name)
          : base.name;
    }
    return '';
  }

  Future<void> _pickRepo() async {
    final strings = Strings.of(context);
    final value = await showHermesOptions<String>(
      context: context,
      title: strings.pj1215WorktreeRepo,
      selected: _repoPath,
      options: [
        for (final (label, path) in widget.repos)
          HermesOption(
            key: ValueKey('pj1215-worktree-repo-$path'),
            value: path,
            label: label,
          ),
      ],
    );
    if (!mounted || _pending || value == null || value == _repoPath) return;
    setState(() {
      _repoPath = value;
      _base = '';
      _bases = const [];
      _branches = const [];
    });
    _load();
  }

  Future<void> _pickBase() async {
    final strings = Strings.of(context);
    final value = await showHermesOptions<String>(
      context: context,
      title: strings.pj1215WorktreeBase,
      selected: _base.isEmpty ? null : _base,
      options: [
        for (final base in _bases)
          HermesOption(
            key: ValueKey('pj1215-worktree-base-${base.name}'),
            value: base.name,
            label: base.isDefault
                ? strings.pj1215WorktreeBaseDefault(base.name)
                : base.name,
          ),
      ],
    );
    if (!mounted || _pending || value == null) return;
    setState(() => _base = value);
  }

  String _branchAction(Strings strings, ProjectGitBranch branch) {
    if (branch.checkedOut || branch.worktreePath.isNotEmpty) {
      return strings.pj1215BranchOpen;
    }
    if (branch.isRemote) return strings.pj1215BranchTrackRemote;
    if (branch.isDefault) return strings.pj1215BranchSwitchHome;
    return strings.pj1215BranchNewWorktree;
  }

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _convert
                ? strings.pj1215OpenBranchTitle
                : strings.pj1215WorktreeTitle,
            style: TextStyle(
              color: colors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _convert
                ? strings.pj1215OpenBranchBody
                : strings.pj1215WorktreeBody,
            style: TextStyle(
              color: colors.textSecondary,
              fontSize: 12.5,
              height: 1.4,
            ),
          ),
          if (widget.repos.length > 1) ...[
            const SizedBox(height: 12),
            HermesSelectRow(
              key: const ValueKey('pj1215-worktree-repo'),
              title: strings.pj1215WorktreeRepo,
              value: _repoLabel(),
              onTap: _pending ? null : _pickRepo,
            ),
          ],
          const SizedBox(height: 12),
          if (_convert)
            ..._branchList(strings, colors)
          else ...[
            TextField(
              key: const ValueKey('pj1215-worktree-name'),
              controller: _name,
              enabled: !_pending,
              autofocus: true,
              autocorrect: false,
              enableSuggestions: false,
              inputFormatters: [
                TextInputFormatter.withFunction(
                  (old, next) => next.copyWith(
                    text: sanitizeGitRef(next.text),
                    selection: TextSelection.collapsed(
                      offset: sanitizeGitRef(
                        next.text.substring(
                          0,
                          next.selection.end.clamp(0, next.text.length),
                        ),
                      ).length,
                    ),
                  ),
                ),
              ],
              decoration: InputDecoration(
                labelText: strings.pj1215WorktreeBranch,
                hintText: strings.pj1215WorktreeBranchHint,
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _create(),
            ),
            const SizedBox(height: 12),
            if (_loadingBases)
              const LinearProgressIndicator(minHeight: 2)
            else if (_bases.isEmpty)
              Text(
                strings.pj1215WorktreeNoBases,
                style: TextStyle(color: colors.textSecondary, fontSize: 12),
              )
            else
              HermesSelectRow(
                key: const ValueKey('pj1215-worktree-base'),
                title: strings.pj1215WorktreeBase,
                value: _baseLabel(strings),
                onTap: _pending ? null : _pickBase,
              ),
            const SizedBox(height: 18),
            FilledButton.icon(
              key: const ValueKey('pj1215-worktree-create'),
              onPressed: _pending || !isValidGitRef(_name.text)
                  ? null
                  : _create,
              icon: _pending
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.call_split_rounded),
              label: Text(strings.pj1215WorktreeCreate),
            ),
          ],
          const SizedBox(height: 6),
          TextButton(
            key: const ValueKey('pj1215-worktree-switch-mode'),
            onPressed: _pending
                ? null
                : () {
                    setState(() => _convert = !_convert);
                    _load();
                  },
            child: Text(
              _convert
                  ? strings.pj1215WorktreeNewInstead
                  : strings.pj1215WorktreeConvertInstead,
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _branchList(Strings strings, HermesThemeColors colors) {
    if (_loadingBranches) {
      return [
        const LinearProgressIndicator(minHeight: 2),
        const SizedBox(height: 8),
        Text(
          strings.pj1215BranchesLoading,
          style: TextStyle(color: colors.textSecondary, fontSize: 12),
        ),
      ];
    }
    if (_branches.isEmpty) {
      return [
        Text(
          strings.pj1215BranchesEmpty,
          style: TextStyle(color: colors.textSecondary, fontSize: 12),
        ),
      ];
    }
    return [
      for (final branch in _branches.take(60))
        ListTile(
          key: ValueKey('pj1215-branch-${branch.name}'),
          contentPadding: EdgeInsets.zero,
          enabled: !_pending,
          leading: Icon(
            branch.isRemote ? Icons.cloud_outlined : Icons.fork_right_rounded,
            size: 20,
            color: colors.textSecondary,
          ),
          title: Text(
            branch.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: colors.textPrimary, fontSize: 14),
          ),
          trailing: Text(
            _branchAction(strings, branch),
            style: TextStyle(color: colors.accent, fontSize: 12),
          ),
          onTap: () => _openBranch(branch),
        ),
    ];
  }
}
