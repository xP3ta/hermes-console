import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../models/desktop_control_center.dart';
import '../navigation/chat_route.dart';
import '../services/connection_manager.dart';
import '../services/desktop_control_gateway.dart';
import '../services/new_session_factory.dart';
import '../theme/app_theme.dart';
import '../utils/byte_bounded_lru_cache.dart';
import '../utils/short_server_path.dart';
import '../widgets/general_dock_shell.dart';
import '../widgets/hermes_notice.dart';
import '../widgets/hermes_premium_ui.dart'
    show HermesSegment, HermesSegmentedControl, showHermesFloatingSurface;
import '../widgets/hermes_ui.dart';
import '../widgets/projects/project_actions.dart';
import '../widgets/projects/project_files_browser.dart';
import 'chat_screen.dart';

/// What a project surface asks to open: an existing conversation, or a new
/// chat anchored to a server folder (null workspace = no folder, the Home
/// bucket's "+").
final class ProjectChatRequest {
  final ProjectSessionPreview? existing;
  final String? workspace;

  const ProjectChatRequest.existing(ProjectSessionPreview session)
    : existing = session,
      workspace = null;

  const ProjectChatRequest.newChat(this.workspace) : existing = null;

  bool get isNewChat => existing == null;
}

typedef ProjectChatLauncher =
    void Function(BuildContext context, ProjectChatRequest request);

/// Mobile projection of Hermes Desktop's Projects sidebar.
///
/// The phone never scans host paths or invents project membership: the list
/// and grouping come from `projects.tree` / `projects.project_sessions`, and
/// every write uses the same RPC or Dashboard route Desktop uses. Writes are
/// offered only when the gateway exposes them; otherwise they are shown
/// disabled with the reason.
class ProjectsCenterScreen extends StatefulWidget {
  final SavedConnection connection;
  final ConnectionManager connectionManager;
  final HermesDesktopControlGateway gateway;
  final Future<void> Function()? disposeGateway;

  /// Replaces chat navigation in widget tests.
  @visibleForTesting
  final ProjectChatLauncher? chatLauncher;

  /// Replaces the system file picker for project uploads in widget tests.
  @visibleForTesting
  final ProjectUploadPicker? projectUploadPicker;

  const ProjectsCenterScreen({
    required this.connection,
    required this.connectionManager,
    required this.gateway,
    this.disposeGateway,
    this.chatLauncher,
    this.projectUploadPicker,
    super.key,
  });

  /// Conexiones con árbol de proyectos cacheado en memoria (proceso).
  @visibleForTesting
  static int get memoryCacheLengthForTesting =>
      _ProjectsCenterScreenState._memoryCache.length;

  @override
  State<ProjectsCenterScreen> createState() => _ProjectsCenterScreenState();
}

/// Shared write/capability state between the list and the entered project.
class _ProjectWriteContext {
  final HermesDesktopControlGateway gateway;
  final SavedConnection connection;
  bool writesUnsupported = false;
  bool gitUnsupported = false;

  _ProjectWriteContext(this.gateway, this.connection);

  HermesProjectManagementGateway? get management =>
      gateway is HermesProjectManagementGateway
      ? gateway as HermesProjectManagementGateway
      : null;

  ProjectWriteBlock? get writeBlock {
    final management = this.management;
    if (management == null || writesUnsupported) {
      return ProjectWriteBlock.unsupportedServer;
    }
    if (connection.readOnly || !management.projectWritesAllowed) {
      return ProjectWriteBlock.readOnly;
    }
    return null;
  }

  ProjectGitBlock? get gitBlock {
    final management = this.management;
    if (management == null || gitUnsupported) {
      return ProjectGitBlock.unsupportedServer;
    }
    if (connection.readOnly || !management.projectWritesAllowed) {
      return ProjectGitBlock.readOnly;
    }
    return null;
  }
}

String projectFailureText(Object failure, Strings strings) {
  if (failure is DesktopControlFailure) {
    return switch (failure.kind) {
      DesktopControlFailureKind.unsupported =>
        strings.projectsCenterFailureUnsupported,
      DesktopControlFailureKind.forbidden =>
        strings.projectsCenterFailureForbidden,
      DesktopControlFailureKind.invalidResponse =>
        strings.projectsCenterFailureInvalidResponse,
      DesktopControlFailureKind.unavailable =>
        strings.projectsCenterFailureUnavailable,
      DesktopControlFailureKind.rejected => strings.pj1215ActionRejected,
    };
  }
  return strings.projectsCenterFailureUnknown;
}

bool _isUnsupported(Object error) =>
    error is DesktopControlFailure &&
    error.kind == DesktopControlFailureKind.unsupported;

void _defaultChatLauncher(
  BuildContext context,
  SavedConnection connection,
  ProjectChatRequest request,
) {
  final existing = request.existing;
  if (existing != null) {
    openChatFromHome<void>(
      context,
      builder: (_) => ChatScreen(
        connection: connection,
        session: Session(
          id: existing.id,
          title: existing.title,
          model: '',
          source: 'desktop',
          messageCount: existing.messageCount,
          isActive: false,
          preview: existing.preview,
          startedAt: existing.lastActive,
          updatedAt: existing.lastActive,
        ),
      ),
    );
    return;
  }
  final draft = NewSessionFactory().create(
    title: Strings.of(context).drawerNewChat,
  );
  openChatFromHome<void>(
    context,
    builder: (_) => ChatScreen(
      connection: connection,
      session: draft,
      requestComposerFocus: true,
      newChatWorkspace: request.workspace,
    ),
  );
}

String _hiddenKey(String connectionId) =>
    'pj1215.hiddenAutoProjects.$connectionId';

class _ProjectsCenterScreenState extends State<ProjectsCenterScreen> {
  static const int _cacheLimit = 8;
  // Nombres/rutas de proyectos de una autoridad concreta: se vacía con los
  // cambios de autoridad igual que las cachés de render del chat.
  static final Map<String, ProjectTreeSnapshot> _memoryCache =
      _createMemoryCache();

  static Map<String, ProjectTreeSnapshot> _createMemoryCache() {
    final cache = <String, ProjectTreeSnapshot>{};
    PrivateRenderCaches.register(cache.clear);
    return cache;
  }

  ProjectTreeSnapshot? _snapshot;
  Object? _failure;
  bool _loading = true;
  bool _showHidden = false;
  late _ProjectWriteContext _writes;
  Set<String> _hidden = {};

  @override
  void initState() {
    super.initState();
    _writes = _ProjectWriteContext(widget.gateway, widget.connection);
    _snapshot = _memoryCache[widget.connection.id];
    _hidden = _readHidden();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant ProjectsCenterScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.gateway != widget.gateway ||
        oldWidget.connection.id != widget.connection.id) {
      _writes = _ProjectWriteContext(widget.gateway, widget.connection);
      _snapshot = _memoryCache[widget.connection.id];
      _failure = null;
      _hidden = _readHidden();
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    final close = widget.disposeGateway;
    if (close != null) unawaited(close());
    super.dispose();
  }

  Set<String> _readHidden() =>
      (widget.connectionManager.prefs.getStringList(
                _hiddenKey(widget.connection.id),
              ) ??
              const <String>[])
          .toSet();

  Future<void> _writeHidden(Set<String> hidden) async {
    setState(() => _hidden = hidden);
    await widget.connectionManager.prefs.setStringList(
      _hiddenKey(widget.connection.id),
      hidden.toList()..sort(),
    );
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _failure = null;
      });
    }
    try {
      final snapshot = await widget.gateway.projectTree();
      if (!mounted) return;
      _memoryCache.remove(widget.connection.id);
      _memoryCache[widget.connection.id] = snapshot;
      while (_memoryCache.length > _cacheLimit) {
        _memoryCache.remove(_memoryCache.keys.first);
      }
      setState(() => _snapshot = snapshot);
    } catch (error) {
      if (!mounted) return;
      setState(() => _failure = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _launch(BuildContext context, ProjectChatRequest request) {
    final launcher = widget.chatLauncher;
    if (launcher != null) {
      launcher(context, request);
    } else {
      _defaultChatLauncher(context, widget.connection, request);
    }
  }

  Future<void> _openProject(ProjectNode project) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => _ProjectDetailScreen(
          project: project,
          connection: widget.connection,
          gateway: widget.gateway,
          writes: _writes,
          isActive: () => _snapshot?.activeId == project.id,
          launch: _launch,
          onChanged: _load,
          onHide: (id) => _writeHidden({..._hidden, id}),
          uploadPicker: widget.projectUploadPicker,
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _menu(ProjectNode project) async {
    await _runProjectMenu(
      context,
      project: project,
      repositories: project.repositories,
      writes: _writes,
      isActive: _snapshot?.activeId == project.id,
      launch: _launch,
      reload: _load,
      hide: (id) => _writeHidden({..._hidden, id}),
      onRemoved: () {},
    );
    if (mounted) setState(() {});
  }

  void _showExplainer() {
    showHermesFloatingSurface<void>(
      context: context,
      builder: (sheetContext) => const _ProjectsExplainer(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final snapshot = _snapshot;
    final all = snapshot?.projects ?? const <ProjectNode>[];
    final visible = <ProjectNode>[
      for (final project in all)
        if (!project.noProject &&
            (_showHidden || !_hidden.contains(project.id)))
          project,
      for (final project in all)
        if (project.noProject && project.sessionCount > 0) project,
    ];
    final hiddenCount = all.where((p) => _hidden.contains(p.id)).length;
    final hasRealProjects = all.any((p) => !p.noProject);
    return Scaffold(
      appBar: AppBar(
        title: Text(strings.projectsCenterTitle),
        actions: [
          IconButton(
            key: const ValueKey('pj1215-help'),
            tooltip: strings.pj1215WhatIsThis,
            onPressed: _showExplainer,
            icon: const Icon(Icons.help_outline_rounded),
          ),
          IconButton(
            tooltip: strings.projectsCenterRefreshTooltip,
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: GeneralDockShell(
        connection: widget.connection,
        connManager: widget.connectionManager,
        body: SafeArea(
          child: _loading && snapshot == null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(),
                        const SizedBox(height: 18),
                        Text(
                          strings.projectsCenterLoading,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: colors.textSecondary,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              : _failure != null && snapshot == null
              ? _CenterFailure(
                  message: projectFailureText(_failure!, strings),
                  onRetry: _load,
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
                    children: [
                      if (_loading && snapshot != null)
                        const Padding(
                          padding: EdgeInsets.only(bottom: 10),
                          child: LinearProgressIndicator(minHeight: 2),
                        ),
                      _IntroLine(onMore: _showExplainer),
                      if (!hasRealProjects)
                        _EmptyProjects(onMore: _showExplainer)
                      else
                        HermesSectionHeader(
                          strings.projectsCenterWorkspacesSection,
                        ),
                      for (final project in visible)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: _ProjectCard(
                            project: project,
                            active: snapshot?.activeId == project.id,
                            hidden: _hidden.contains(project.id),
                            onTap: () => _openProject(project),
                            onMenu: () => _menu(project),
                          ),
                        ),
                      if (hiddenCount > 0)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            key: const ValueKey('pj1215-toggle-hidden'),
                            onPressed: () =>
                                setState(() => _showHidden = !_showHidden),
                            icon: Icon(
                              _showHidden
                                  ? Icons.visibility_off_outlined
                                  : Icons.visibility_outlined,
                              size: 18,
                            ),
                            label: Text(
                              _showHidden
                                  ? strings.pj1215HideHidden
                                  : strings.pj1215ShowHidden(hiddenCount),
                            ),
                          ),
                        ),
                      _DesktopOnlyCreate(),
                      if (_failure != null && snapshot != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            strings.projectsCenterStaleView(
                              projectFailureText(_failure!, strings),
                            ),
                            style: TextStyle(
                              color: colors.warning,
                              fontSize: 12,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}

/// Runs the Desktop project menu for [project] and performs the chosen
/// action with the same RPCs Desktop uses. Shared by the list and the
/// entered project so both offer exactly the same actions.
Future<void> _runProjectMenu(
  BuildContext context, {
  required ProjectNode project,
  required List<ProjectRepositoryNode> repositories,
  required _ProjectWriteContext writes,
  required bool isActive,
  required void Function(BuildContext, ProjectChatRequest) launch,
  required Future<void> Function() reload,
  required Future<void> Function(String id) hide,
  required VoidCallback onRemoved,
}) async {
  final action = await showProjectMenu(
    context,
    project: project,
    isActive: isActive,
    writeBlock: writes.writeBlock,
    gitBlock: writes.gitBlock,
  );
  if (action == null || !context.mounted) return;
  await _performProjectAction(
    context,
    action,
    project: project,
    repositories: repositories,
    writes: writes,
    launch: launch,
    reload: reload,
    hide: hide,
    onRemoved: onRemoved,
  );
}

Future<void> _performProjectAction(
  BuildContext context,
  ProjectMenuAction action, {
  required ProjectNode project,
  required List<ProjectRepositoryNode> repositories,
  required _ProjectWriteContext writes,
  required void Function(BuildContext, ProjectChatRequest) launch,
  required Future<void> Function() reload,
  required Future<void> Function(String id) hide,
  required VoidCallback onRemoved,
}) async {
  final strings = Strings.of(context);
  final notice = HermesNotice.of(context);
  final root = projectRootPath(project);
  final label = project.label.isEmpty
      ? strings.projectsCenterUnnamedProject
      : project.label;
  void toast(String text) => notice.showSnackBar(
    SnackBar(content: Text(text), duration: const Duration(seconds: 3)),
  );
  void fail(Object error) {
    if (_isUnsupported(error)) {
      writes.writesUnsupported = true;
      toast(strings.pj1215NeedsNewerHermes);
      return;
    }
    toast(projectFailureText(error, strings));
  }

  void gitFail(Object error) {
    if (_isUnsupported(error)) {
      writes.gitUnsupported = true;
      toast(strings.pj1215WorktreeStaleBackend);
      return;
    }
    toast(projectFailureText(error, strings));
  }

  final management = writes.management;
  switch (action) {
    case ProjectMenuAction.newChat:
      launch(context, ProjectChatRequest.newChat(root.isEmpty ? null : root));
    case ProjectMenuAction.copyPath:
      if (root.isEmpty) return;
      await Clipboard.setData(ClipboardData(text: root));
      toast(strings.pj1215PathCopied);
    case ProjectMenuAction.hide:
      await hide(project.id);
      toast(strings.pj1215HiddenNotice(label));
      onRemoved();
    case ProjectMenuAction.rename:
      if (management == null) return;
      final name = await showProjectRenameDialog(context, current: label);
      if (name == null || name == label || !context.mounted) return;
      try {
        await management.updateProject(project.id, name: name);
        toast(strings.pj1215Renamed(name));
        await reload();
      } catch (error) {
        fail(error);
      }
    case ProjectMenuAction.appearance:
      if (management == null) return;
      final patch = await showProjectAppearanceSheet(context, project: project);
      if (patch == null || !context.mounted) return;
      try {
        if (isSavedProject(project)) {
          await management.updateProject(
            project.id,
            color: patch.color,
            icon: patch.icon,
          );
        } else {
          // Desktop adopts an auto repo as a saved project on its first
          // appearance change, carrying any look it already had.
          final color = patch.color ?? project.color;
          final icon = patch.icon ?? project.icon;
          await management.createProject(
            name: label,
            primaryPath: root,
            color: color.isEmpty ? null : color,
            icon: icon.isEmpty ? null : icon,
          );
        }
        await reload();
      } catch (error) {
        fail(error);
      }
    case ProjectMenuAction.setActive:
      if (management == null) return;
      try {
        await management.setActiveProject(project.id);
        toast(strings.pj1215ActiveNotice(label));
        await reload();
      } catch (error) {
        fail(error);
      }
    case ProjectMenuAction.delete:
      if (management == null) return;
      if (!await confirmProjectDelete(context, label)) return;
      try {
        await management.deleteProject(project.id);
        toast(strings.pj1215Deleted(label));
        onRemoved();
        await reload();
      } catch (error) {
        fail(error);
      }
    case ProjectMenuAction.newWorktree:
    case ProjectMenuAction.openBranch:
      if (management == null) return;
      final path = await showWorktreeSheet(
        context,
        gateway: management,
        repositories: repositories,
        fallbackRepoPath: root,
        startInConvertMode: action == ProjectMenuAction.openBranch,
        onFailure: gitFail,
      );
      if (path == null || !context.mounted) return;
      unawaited(reload());
      launch(context, ProjectChatRequest.newChat(path));
  }
}

class _IntroLine extends StatelessWidget {
  final VoidCallback onMore;

  const _IntroLine({required this.onMore});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 4, 2, 0),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(text: '${strings.pj1215Intro} '),
            WidgetSpan(
              alignment: PlaceholderAlignment.baseline,
              baseline: TextBaseline.alphabetic,
              child: GestureDetector(
                key: const ValueKey('pj1215-intro-more'),
                onTap: onMore,
                child: Text(
                  strings.pj1215WhatIsThis,
                  style: TextStyle(
                    color: colors.accent,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ),
        style: TextStyle(
          color: colors.textSecondary,
          fontSize: 12.5,
          height: 1.4,
        ),
      ),
    );
  }
}

class _ProjectsExplainer extends StatelessWidget {
  const _ProjectsExplainer();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    Widget point(IconData icon, String title, String body) => Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: colors.accent),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  body,
                  style: TextStyle(
                    color: colors.textSecondary,
                    fontSize: 12.5,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
      child: Column(
        key: const ValueKey('pj1215-explainer'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            strings.pj1215ExplainTitle,
            style: TextStyle(
              color: colors.textPrimary,
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 14),
          point(
            Icons.folder_outlined,
            strings.pj1215ExplainFolderTitle,
            strings.pj1215ExplainFolderBody,
          ),
          point(
            Icons.auto_awesome_outlined,
            strings.pj1215ExplainAutoTitle,
            strings.pj1215ExplainAutoBody,
          ),
          point(
            Icons.call_split_rounded,
            strings.pj1215ExplainWorktreeTitle,
            strings.pj1215ExplainWorktreeBody,
          ),
          point(
            Icons.add_comment_outlined,
            strings.pj1215ExplainNewChatTitle,
            strings.pj1215ExplainNewChatBody,
          ),
          point(
            Icons.lock_outline_rounded,
            strings.pj1215ExplainSafeTitle,
            strings.pj1215ExplainSafeBody,
          ),
        ],
      ),
    );
  }
}

class _DesktopOnlyCreate extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: ListTile(
        key: const ValueKey('pj1215-create-desktop-only'),
        enabled: false,
        contentPadding: const EdgeInsets.symmetric(horizontal: 4),
        leading: Icon(
          Icons.create_new_folder_outlined,
          color: colors.textDisabled,
        ),
        title: Text(
          strings.pj1215CreateProject,
          style: TextStyle(color: colors.textDisabled, fontSize: 14),
        ),
        subtitle: Text(
          strings.pj1215CreateProjectDesktopOnly,
          style: TextStyle(color: colors.textSecondary, fontSize: 12),
        ),
      ),
    );
  }
}

class _ProjectCard extends StatelessWidget {
  final ProjectNode project;
  final bool active;
  final bool hidden;
  final VoidCallback onTap;
  final VoidCallback onMenu;

  const _ProjectCard({
    required this.project,
    required this.active,
    required this.hidden,
    required this.onTap,
    required this.onMenu,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final label = project.noProject
        ? strings.pj1215HomeBucket
        : project.label.isEmpty
        ? strings.projectsCenterUnnamedProject
        : project.label;
    final root = projectRootPath(project);
    final branch = projectMainBranch(project);
    final ago = projectAgo(strings, project.lastActive);
    final meta = [
      strings.projectsCenterConversationCount(project.sessionCount),
      if (ago.isNotEmpty) ago,
    ].join(' · ');
    return Semantics(
      label: strings.projectsCenterProjectSemantics(
        label,
        project.sessionCount,
      ),
      child: Opacity(
        opacity: hidden ? 0.55 : 1,
        child: HermesCard(
          key: ValueKey('pj1215-card-${project.id}'),
          onTap: onTap,
          onLongPress: project.noProject ? null : onMenu,
          padding: const EdgeInsets.fromLTRB(14, 12, 4, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ProjectGlyph(project: project, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: colors.textPrimary,
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if (active) ...[
                          const SizedBox(width: 8),
                          _Tag(
                            text: strings.pj1215ActiveTag,
                            color: colors.success,
                          ),
                        ],
                        if (project.automatic) ...[
                          const SizedBox(width: 8),
                          _Tag(
                            text: strings.pj1215AutoTag,
                            color: colors.textSecondary,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    if (project.noProject)
                      Text(
                        strings.pj1215HomeBucketBody,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.textSecondary,
                          fontSize: 12,
                        ),
                      )
                    else if (root.isNotEmpty)
                      Text(
                        shortServerPath(root),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.textSecondary,
                          fontSize: 12,
                          fontFamily: 'monospace',
                        ),
                      ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        if (branch.isNotEmpty) ...[
                          Icon(
                            Icons.fork_right_rounded,
                            size: 13,
                            color: colors.textSecondary,
                          ),
                          const SizedBox(width: 2),
                          Flexible(
                            flex: 0,
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 110),
                              child: Text(
                                branch,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: colors.textSecondary,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ),
                          Text(
                            ' · ',
                            style: TextStyle(
                              color: colors.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                        ],
                        Expanded(
                          child: Text(
                            meta,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: colors.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (project.noProject)
                Padding(
                  padding: const EdgeInsets.only(top: 8, right: 8),
                  child: Icon(
                    Icons.chevron_right_rounded,
                    color: colors.textDisabled,
                  ),
                )
              else
                IconButton(
                  key: ValueKey('pj1215-card-menu-${project.id}'),
                  tooltip: strings.pj1215MenuTooltip,
                  onPressed: onMenu,
                  icon: Icon(
                    Icons.more_vert_rounded,
                    color: colors.textSecondary,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  final String text;
  final Color color;

  const _Tag({required this.text, required this.color});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      text,
      style: TextStyle(
        color: color,
        fontSize: 10.5,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

class _ProjectDetailScreen extends StatefulWidget {
  final ProjectNode project;
  final SavedConnection connection;
  final HermesDesktopControlGateway gateway;
  final _ProjectWriteContext writes;
  final bool Function() isActive;
  final void Function(BuildContext, ProjectChatRequest) launch;
  final Future<void> Function() onChanged;
  final Future<void> Function(String id) onHide;
  final ProjectUploadPicker? uploadPicker;

  const _ProjectDetailScreen({
    required this.project,
    required this.connection,
    required this.gateway,
    required this.writes,
    required this.isActive,
    required this.launch,
    required this.onChanged,
    required this.onHide,
    this.uploadPicker,
  });

  @override
  State<_ProjectDetailScreen> createState() => _ProjectDetailScreenState();
}

enum _ProjectDetailTab { chats, files }

class _ProjectDetailScreenState extends State<_ProjectDetailScreen> {
  static const int _lanePage = 5;
  ProjectNode? _detail;
  Object? _failure;
  final Set<String> _expandedLanes = {};
  _ProjectDetailTab _tab = _ProjectDetailTab.chats;
  late final ProjectFilesController? _files;

  ProjectNode get _project => _detail ?? widget.project;

  @override
  void initState() {
    super.initState();
    final root = projectRootPath(widget.project);
    final gateway = widget.gateway;
    _files = root.isEmpty || widget.project.noProject
        ? null
        : ProjectFilesController(
            root: root,
            gateway: gateway is HermesProjectFilesGateway
                ? gateway as HermesProjectFilesGateway
                : null,
            writes: gateway is HermesProjectFileWritesGateway
                ? gateway as HermesProjectFileWritesGateway
                : null,
            readOnlyConnection: widget.connection.readOnly,
          );
    unawaited(_load());
  }

  @override
  void dispose() {
    _files?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final detail = await widget.gateway.projectSessions(widget.project.id);
      if (!mounted) return;
      setState(() {
        _failure = null;
        _detail = detail == null
            ? widget.project
            : _project.withHydrated(detail);
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _failure = error;
        _detail ??= widget.project;
      });
    }
  }

  Future<void> _reloadAll() async {
    await widget.onChanged();
    await _load();
  }

  Future<void> _menu() =>
      _runProjectMenu(
        context,
        project: _project,
        repositories: _project.repositories,
        writes: widget.writes,
        isActive: widget.isActive(),
        launch: widget.launch,
        reload: _reloadAll,
        hide: widget.onHide,
        onRemoved: () {
          if (mounted) Navigator.of(context).maybePop();
        },
      ).whenComplete(() {
        if (mounted) setState(() {});
      });

  Future<void> _worktrees() =>
      _performProjectAction(
        context,
        ProjectMenuAction.newWorktree,
        project: _project,
        repositories: _project.repositories,
        writes: widget.writes,
        launch: widget.launch,
        reload: _reloadAll,
        hide: widget.onHide,
        onRemoved: () {},
      ).whenComplete(() {
        if (mounted) setState(() {});
      });

  void _newChat([String? path]) {
    final root = projectRootPath(_project);
    final target = (path ?? root).trim();
    widget.launch(
      context,
      ProjectChatRequest.newChat(target.isEmpty ? null : target),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final project = _project;
    final loading = _detail == null;
    final title = project.noProject
        ? strings.pj1215HomeBucket
        : project.label.isEmpty
        ? strings.projectsCenterUnnamedProject
        : project.label;
    final root = projectRootPath(project);
    final lanes = [
      for (final repo in project.repositories)
        for (final lane in repo.lanes) lane,
    ];
    final files = _files;
    final showFiles = files != null && _tab == _ProjectDetailTab.files;
    final worktreesEnabled = widget.writes.gitBlock == null && root.isNotEmpty;
    final scaffold = Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            ProjectGlyph(project: project, size: 16),
            const SizedBox(width: 10),
            Expanded(
              child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
        actions: [
          if (!project.noProject)
            IconButton(
              key: const ValueKey('pj1215-detail-menu'),
              tooltip: strings.pj1215MenuTooltip,
              onPressed: _menu,
              icon: const Icon(Icons.more_vert_rounded),
            ),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: showFiles ? files.refresh : _reloadAll,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
            children: [
              // Header: where this project lives on the Hermes host.
              if (root.isNotEmpty)
                Semantics(
                  label: strings.projectsCenterServerPathReadOnly,
                  child: SelectableText(
                    root,
                    key: const ValueKey('pj1215-detail-path'),
                    style: TextStyle(
                      color: colors.textSecondary,
                      fontSize: 11.5,
                      fontFamily: 'monospace',
                    ),
                  ),
                )
              else if (project.noProject)
                Text(
                  strings.pj1215HomeBucketBody,
                  style: TextStyle(color: colors.textSecondary, fontSize: 12.5),
                ),
              const SizedBox(height: 14),
              // Primary actions.
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      key: const ValueKey('pj1215-detail-new-chat'),
                      onPressed: () => _newChat(),
                      icon: const Icon(Icons.add_comment_outlined),
                      label: Text(
                        root.isEmpty
                            ? strings.pj1215NewChatNoFolder
                            : strings.pj1215NewChatHere,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  if (!project.noProject) ...[
                    const SizedBox(width: 10),
                    Tooltip(
                      message: strings.pf1215WorktreesHint,
                      child: OutlinedButton.icon(
                        key: const ValueKey('pf1215-detail-worktree'),
                        onPressed: worktreesEnabled ? _worktrees : null,
                        icon: const Icon(Icons.call_split_rounded, size: 18),
                        label: Text(strings.pf1215Worktrees),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 6),
              Text(
                root.isEmpty
                    ? strings.pj1215NewChatNoFolderHint
                    : strings.pj1215NewChatHereHint(shortServerPath(root)),
                style: TextStyle(color: colors.textSecondary, fontSize: 11.5),
              ),
              if (files != null) ...[
                const SizedBox(height: 18),
                HermesSegmentedControl<_ProjectDetailTab>(
                  value: _tab,
                  onChanged: (tab) => setState(() => _tab = tab),
                  segments: [
                    HermesSegment(
                      key: const ValueKey('pf1215-tab-chats'),
                      value: _ProjectDetailTab.chats,
                      label: strings.pf1215TabChats,
                      count: project.sessionCount > 0
                          ? project.sessionCount
                          : null,
                    ),
                    HermesSegment(
                      key: const ValueKey('pf1215-tab-files'),
                      value: _ProjectDetailTab.files,
                      label: strings.pf1215TabFiles,
                    ),
                  ],
                ),
                const SizedBox(height: 6),
              ],
              if (showFiles)
                ProjectFilesBrowser(
                  key: const ValueKey('pf1215-files'),
                  controller: files,
                  failureText: (error) => projectFailureText(error, strings),
                  uploadPicker: widget.uploadPicker,
                )
              else ...[
                if (_failure != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      strings.projectsCenterDetailStale,
                      style: TextStyle(color: colors.warning, fontSize: 12),
                    ),
                  ),
                if (loading)
                  const Padding(
                    padding: EdgeInsets.only(top: 24),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (lanes.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: _EmptyCenter(
                      icon: Icons.forum_outlined,
                      title: strings.projectsCenterNoBranchesTitle,
                      body: strings.pj1215NoSessionsBody,
                    ),
                  )
                else
                  for (final repo in project.repositories) ...[
                    if (project.repositories.length > 1 || !project.noProject)
                      HermesSectionHeader(
                        repo.label.isEmpty
                            ? shortServerPath(repo.path)
                            : repo.label,
                      )
                    else
                      const SizedBox(height: 14),
                    for (final lane in repo.lanes)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _LaneGroup(
                          lane: lane,
                          showHeader: !project.noProject,
                          expanded: _expandedLanes.contains(lane.id),
                          page: _lanePage,
                          onExpand: () =>
                              setState(() => _expandedLanes.add(lane.id)),
                          onOpen: (session) => widget.launch(
                            context,
                            ProjectChatRequest.existing(session),
                          ),
                          onNewChat: lane.isKanban || lane.path.isEmpty
                              ? null
                              : () => _newChat(lane.path),
                        ),
                      ),
                  ],
              ],
            ],
          ),
        ),
      ),
    );
    if (files == null) return scaffold;
    // Inside a subfolder, back goes up one folder before leaving the project.
    return ListenableBuilder(
      listenable: files,
      builder: (context, child) => PopScope(
        canPop: !showFiles || files.atRoot,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && showFiles) files.up();
        },
        child: child!,
      ),
      child: scaffold,
    );
  }
}

class _LaneGroup extends StatelessWidget {
  final ProjectLane lane;
  final bool showHeader;
  final bool expanded;
  final int page;
  final VoidCallback onExpand;
  final ValueChanged<ProjectSessionPreview> onOpen;
  final VoidCallback? onNewChat;

  const _LaneGroup({
    required this.lane,
    required this.showHeader,
    required this.expanded,
    required this.page,
    required this.onExpand,
    required this.onOpen,
    required this.onNewChat,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final sessions = expanded ? lane.sessions : lane.sessions.take(page);
    final remaining = lane.sessions.length - page;
    final label = lane.label.isEmpty
        ? strings.projectsCenterBranchFallback
        : lane.label;
    return HermesGroup(
      key: ValueKey('pj1215-lane-${lane.id}'),
      children: [
        if (showHeader)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 4, 6),
            child: Row(
              children: [
                Icon(
                  lane.isMain
                      ? Icons.fork_right_rounded
                      : Icons.call_split_rounded,
                  size: 18,
                  color: colors.textSecondary,
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                    ),
                  ),
                ),
                if (!lane.isMain) ...[
                  const SizedBox(width: 8),
                  _Tag(
                    text: lane.isKanban
                        ? strings.pj1215KanbanTag
                        : strings.pj1215WorktreeTag,
                    color: colors.accent,
                  ),
                ],
                const Spacer(),
                Text(
                  '${lane.totalCount}',
                  style: TextStyle(color: colors.textSecondary, fontSize: 12),
                ),
                if (onNewChat != null)
                  IconButton(
                    key: ValueKey('pj1215-lane-new-${lane.id}'),
                    tooltip: strings.pj1215NewChatInLane(label),
                    onPressed: onNewChat,
                    icon: Icon(Icons.add_rounded, color: colors.accent),
                  )
                else
                  const SizedBox(width: 12),
              ],
            ),
          ),
        if (lane.sessions.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
            child: Text(
              strings.projectsCenterLaneEmpty,
              style: TextStyle(color: colors.textSecondary, fontSize: 12),
            ),
          ),
        for (final session in sessions)
          Material(
            type: MaterialType.transparency,
            child: ListTile(
              key: ValueKey('pj1215-session-${session.id}'),
              minTileHeight: 52,
              title: Text(
                session.title.isEmpty
                    ? (session.preview.isEmpty
                          ? strings.projectsCenterConversationFallback
                          : session.preview)
                    : session.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: colors.textPrimary, fontSize: 14),
              ),
              subtitle: Text(
                projectAgo(strings, session.lastActive),
                style: TextStyle(color: colors.textSecondary, fontSize: 11.5),
              ),
              trailing: Icon(
                Icons.chevron_right_rounded,
                color: colors.textDisabled,
              ),
              onTap: () => onOpen(session),
            ),
          ),
        if (!expanded && remaining > 0)
          TextButton(
            key: ValueKey('pj1215-lane-more-${lane.id}'),
            onPressed: onExpand,
            child: Text(strings.pj1215ShowMore(remaining)),
          ),
      ],
    );
  }
}

class _EmptyProjects extends StatelessWidget {
  final VoidCallback onMore;

  const _EmptyProjects({required this.onMore});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 8),
      child: HermesPanel(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            key: const ValueKey('pj1215-empty'),
            children: [
              Icon(
                Icons.folder_open_outlined,
                color: colors.textSecondary,
                size: 32,
              ),
              const SizedBox(height: 10),
              Text(
                strings.projectsCenterEmptyTitle,
                style: TextStyle(
                  color: colors.textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                strings.projectsCenterEmptyBody,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: colors.textSecondary,
                  fontSize: 12.5,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: onMore,
                icon: const Icon(Icons.help_outline_rounded, size: 18),
                label: Text(strings.pj1215WhatIsThis),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CenterFailure extends StatelessWidget {
  final String message;
  final Future<void> Function() onRetry;

  const _CenterFailure({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off_outlined, size: 36),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: Text(Strings.of(context).commonRetry),
          ),
        ],
      ),
    ),
  );
}

class _EmptyCenter extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;

  const _EmptyCenter({
    required this.icon,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return HermesPanel(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Icon(icon, color: colors.textSecondary, size: 30),
            const SizedBox(height: 10),
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(
              body,
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.textSecondary, fontSize: 12.5),
            ),
          ],
        ),
      ),
    );
  }
}
