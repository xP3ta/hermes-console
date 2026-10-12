import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../models/desktop_control_center.dart';
import '../navigation/chat_route.dart';
import '../design/modal.dart' show HermesAction, showHermesMenu;
import '../services/connection_manager.dart';
import '../services/desktop_control_gateway.dart';
import '../services/new_session_factory.dart';
import '../theme/app_theme.dart';
import '../utils/byte_bounded_lru_cache.dart';
import '../utils/short_server_path.dart';
import '../widgets/adaptive_list_detail.dart';
import '../shell/gesture_dock_state.dart' show GestureDockTab;
import '../widgets/general_dock_shell.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/hermes_notice.dart';
import '../widgets/hermes_premium_ui.dart'
    show HermesSearchField, showHermesFloatingSurface;
import '../widgets/projects/project_actions.dart';
import '../widgets/projects/project_create_sheet.dart';
import '../widgets/projects/project_files_browser.dart';
import '../widgets/projects/project_folder_widgets.dart';
import 'chat_screen.dart';
import '../widgets/console_loader.dart';

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

/// Opens a folder picker on the Hermes host at [startPath]; null = cancel.
typedef ServerFolderPickerLauncher =
    Future<String?> Function(BuildContext context, String? startPath);

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

  /// Replaces the server folder picker in widget tests.
  @visibleForTesting
  final ServerFolderPickerLauncher? folderPicker;

  const ProjectsCenterScreen({
    required this.connection,
    required this.connectionManager,
    required this.gateway,
    this.disposeGateway,
    this.chatLauncher,
    this.projectUploadPicker,
    this.folderPicker,
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

  /// Server folder picker (set by the screen); null without one.
  Future<String?> Function(BuildContext context)? pickFolder;

  _ProjectWriteContext(this.gateway, this.connection);

  HermesProjectManagementGateway? get management =>
      gateway is HermesProjectManagementGateway
      ? gateway as HermesProjectManagementGateway
      : null;

  HermesProjectCreationGateway? get creation =>
      gateway is HermesProjectCreationGateway
      ? gateway as HermesProjectCreationGateway
      : null;

  HermesProjectFilesGateway? get files => gateway is HermesProjectFilesGateway
      ? gateway as HermesProjectFilesGateway
      : null;

  HermesProjectFileWritesGateway? get fileWrites =>
      gateway is HermesProjectFileWritesGateway
      ? gateway as HermesProjectFileWritesGateway
      : null;

  /// Creating projects and adding folders (Desktop project dialog) needs
  /// `projects.create`/`projects.add_folder` and the server folder listing
  /// for the picker; read-only connections never get it.
  ProjectWriteBlock? get createBlock {
    final creation = this.creation;
    final files = this.files;
    if (creation == null ||
        files == null ||
        writesUnsupported ||
        creation.projectCreationKnownUnsupported ||
        files.projectFilesKnownUnsupported) {
      return ProjectWriteBlock.unsupportedServer;
    }
    if (connection.readOnly || !creation.projectWritesAllowed) {
      return ProjectWriteBlock.readOnly;
    }
    return null;
  }

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
    _writes = _newWriteContext();
    _snapshot = _memoryCache[widget.connection.id];
    _hidden = _readHidden();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant ProjectsCenterScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.gateway != widget.gateway ||
        oldWidget.connection.id != widget.connection.id) {
      _writes = _newWriteContext();
      _snapshot = _memoryCache[widget.connection.id];
      _failure = null;
      _hidden = _readHidden();
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _search.dispose();
    final close = widget.disposeGateway;
    if (close != null) unawaited(close());
    super.dispose();
  }

  _ProjectWriteContext _newWriteContext() =>
      _ProjectWriteContext(widget.gateway, widget.connection)
        ..pickFolder = _pickServerFolder;

  /// Desktop `pickProjectFolder`: the remote picker seeded at the server's
  /// default folder (`/api/fs/default-cwd`).
  Future<String?> _pickServerFolder(BuildContext context) async {
    final files = _writes.files;
    if (files == null) return null;
    final start = await _writes.creation?.projectDefaultFolder();
    if (!context.mounted) return null;
    final override = widget.folderPicker;
    if (override != null) return override(context, start);
    final strings = Strings.of(context);
    return showServerFolderPicker(
      context,
      files: files,
      writes: _writes.fileWrites,
      readOnlyConnection: widget.connection.readOnly,
      startPath: start,
      failureText: (error) => projectFailureText(error, strings),
    );
  }

  /// Owner of [folder] on a fresh tree (Desktop refreshes first so a repo
  /// cloned since the last scan enters its project instead of duplicating).
  Future<ProjectNode?> _ownerOf(String folder) async {
    await _load();
    return projectOwningFolder(_snapshot?.projects ?? const [], folder);
  }

  /// Opens the project [id] from the latest tree, if it is there.
  Future<void> _enter(String id) async {
    for (final project in _snapshot?.projects ?? const <ProjectNode>[]) {
      if (project.id == id) {
        await _openProject(project);
        return;
      }
    }
  }

  void _toast(String text) => HermesNotice.of(context).showSnackBar(
    SnackBar(content: Text(text), duration: const Duration(seconds: 3)),
  );

  Future<void> _createProject() async {
    final creation = _writes.creation;
    if (creation == null || _writes.createBlock != null) return;
    final strings = Strings.of(context);
    final outcome = await showProjectCreateSheet(
      context,
      creation: creation,
      pickFolder: () => _pickServerFolder(context),
      ownerOf: _ownerOf,
      failureText: (error) => projectFailureText(error, strings),
      ideaWriter: _writes.fileWrites,
      ideaFolderReader: _writes.files,
    );
    if (!mounted || outcome == null) return;
    switch (outcome) {
      case ProjectOpenExistingOutcome(:final project):
        await _enter(project.id);
      case ProjectCreatedOutcome(:final project, :final ideaNotWritten):
        switch (ideaNotWritten) {
          case ProjectIdeaNotWritten.exists:
            _toast(strings.pc1215IdeaExists);
          case ProjectIdeaNotWritten.unverified:
            _toast(strings.pc1215IdeaUnverified);
          case null:
            break;
        }
        await _load();
        if (!mounted) return;
        await _enter(project.id);
    }
  }

  /// Desktop "Open folder…": a folder covered by a project enters it, any
  /// other becomes a project named after it; either way a new chat starts
  /// in the folder.
  Future<void> _openFolder() async {
    final creation = _writes.creation;
    if (creation == null || _writes.createBlock != null) return;
    final strings = Strings.of(context);
    final picked = await _pickServerFolder(context);
    if (!mounted || picked == null) return;
    final target = normalizeServerFolder(picked);
    if (!target.startsWith('/')) return;
    final existing = await _ownerOf(target);
    if (!mounted) return;
    if (existing != null) {
      unawaited(_enter(existing.id));
    } else {
      try {
        final created = await creation.createProjectFromFolders(
          name: projectFolderBaseName(target),
          folders: [target],
          primaryPath: target,
        );
        await _load();
        if (!mounted) return;
        unawaited(_enter(created.id));
      } catch (error) {
        if (!mounted) return;
        if (_isUnsupported(error)) {
          setState(() => _writes.writesUnsupported = true);
        }
        _toast(strings.pc1215OpenFolderFailed);
      }
    }
    if (!mounted) return;
    _launch(context, ProjectChatRequest.newChat(target));
  }

  Future<void> _openAddMenu() async {
    final strings = Strings.of(context);
    final action = await showHermesMenu<String>(
      context: context,
      anchorKey: _addAnchor,
      surfaceKey: const ValueKey('pc1215-add-menu'),
      actions: [
        HermesAction(
          key: const ValueKey('pc1215-add-create'),
          value: 'create',
          icon: Icons.create_new_folder_outlined,
          label: strings.pc1215NewProject,
        ),
        HermesAction(
          key: const ValueKey('pc1215-add-open-folder'),
          value: 'open',
          icon: Icons.folder_open_outlined,
          label: strings.pc1215OpenFolder,
        ),
      ],
    );
    if (!mounted) return;
    switch (action) {
      case 'create':
        await _createProject();
      case 'open':
        await _openFolder();
    }
  }

  /// Manual refresh: like Desktop on a remote backend, ask the host to scan
  /// its discovery roots first so repositories without chats show up.
  Future<void> _refresh() async {
    final creation = _writes.creation;
    if (creation != null && _writes.createBlock == null) {
      await creation.scanProjectRepos();
      if (!mounted) return;
    }
    await _load();
  }

  final GlobalKey _addAnchor = GlobalKey();

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
    // From the screen's own context: on a tablet the project may sit in the
    // detail pane, but a chat still opens on the app navigator exactly as it
    // does on a phone.
    final host = mounted ? this.context : context;
    final launcher = widget.chatLauncher;
    if (launcher != null) {
      launcher(host, request);
    } else {
      _defaultChatLauncher(host, widget.connection, request);
    }
  }

  final GlobalKey<AdaptiveListDetailState> _panes =
      GlobalKey<AdaptiveListDetailState>(debugLabel: 'projects-panes');

  /// The project open in the tablet pane (single source of truth for the
  /// selection; rotation keeps it because the pane's navigator moves).
  String? _paneProjectId;

  Future<void> _openProject(ProjectNode project) async {
    final panes = _panes.currentState;
    final inPane = panes != null && panes.active;
    if (inPane && _paneProjectId == project.id && panes.hasDetail) return;
    final route = MaterialPageRoute<void>(
      settings: RouteSettings(name: 'project-pane:${project.id}'),
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
    );
    if (inPane) {
      _paneProjectId = project.id;
      await panes.show<void>(route);
      if (_paneProjectId == project.id) _paneProjectId = null;
    } else {
      await Navigator.of(context).push<void>(route);
    }
    if (mounted) setState(() {});
  }

  /// The window became phone-sized with a project open in the pane: continue
  /// with the phone flow instead of dropping back to the list.
  void _reopenPaneProjectFullScreen() {
    final id = _paneProjectId;
    _paneProjectId = null;
    if (id == null || !mounted) return;
    unawaited(_enter(id));
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

  final TextEditingController _search = TextEditingController();
  String _query = '';

  String _projectTitle(Strings strings, ProjectNode project) =>
      project.noProject
      ? strings.pb1215OtherChats
      : project.label.isEmpty
      ? strings.projectsCenterUnnamedProject
      : project.label;

  String _projectSummary(Strings strings, ProjectNode project) {
    final ago = project.sessionCount > 0
        ? projectAgo(strings, project.lastActive)
        : '';
    return [
      project.noProject
          ? strings.pb1215OtherChatsCount(project.sessionCount)
          : strings.pb1215ChatCount(project.sessionCount),
      if (ago.isNotEmpty) ago,
    ].join(' · ');
  }

  Widget _folderRow(Strings strings, ProjectNode project) => ProjectFolderRow(
    rowKey: ValueKey('pj1215-card-${project.id}'),
    title: _projectTitle(strings, project),
    summary: _projectSummary(strings, project),
    dimmed: _hidden.contains(project.id),
    glyph: _ProjectFolderIcon(project: project),
    onTap: () => _openProject(project),
    onOptions: project.noProject ? null : () => _menu(project),
  );

  bool _matches(Strings strings, ProjectNode project, String query) =>
      projectSearchFold(_projectTitle(strings, project)).contains(query) ||
      projectSearchFold(projectRootPath(project)).contains(query);

  bool _chatMatches(ProjectSessionPreview session, String query) =>
      projectSearchFold(session.title).contains(query) ||
      projectSearchFold(session.preview).contains(query);

  List<Widget> _divided(List<Widget> rows, {double indent = 74}) => [
    for (final (index, row) in rows.indexed) ...[
      if (index > 0) ProjectRowDivider(indent: indent),
      row,
    ],
  ];

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
      // Chats without a folder close the list, like a Files "Other" folder.
      for (final project in all)
        if (project.noProject && project.sessionCount > 0) project,
    ];
    final hiddenCount = all.where((p) => _hidden.contains(p.id)).length;
    final hasRealProjects = all.any((p) => !p.noProject);
    final createBlock = _writes.createBlock;
    final canCreate = createBlock == null;
    final query = projectSearchFold(_query.trim());
    final searching = query.isNotEmpty;

    final List<Widget> content;
    if (searching) {
      final projects = [
        for (final project in visible)
          if (_matches(strings, project, query)) project,
      ];
      final chats = [
        for (final project in visible)
          for (final session in project.previewSessions)
            if (_chatMatches(session, query)) (project, session),
      ];
      content = [
        if (projects.isNotEmpty) ...[
          _SectionLabel(strings.pb1215ProjectsSection),
          ..._divided([
            for (final project in projects) _folderRow(strings, project),
          ]),
        ],
        if (chats.isNotEmpty) ...[
          _SectionLabel(strings.pb1215ChatsSection),
          ..._divided(indent: 60, [
            for (final (project, session) in chats)
              ProjectChatRow(
                session: session,
                context: _projectTitle(strings, project),
                onTap: () =>
                    _launch(context, ProjectChatRequest.existing(session)),
              ),
          ]),
        ],
        if (projects.isEmpty && chats.isEmpty) _NoResults(query: _query.trim()),
      ];
    } else {
      content = [
        if (!hasRealProjects)
          ProjectEmptyState(
            stateKey: const ValueKey('pj1215-empty'),
            icon: Icons.folder_open_rounded,
            title: strings.projectsCenterEmptyTitle,
            body: canCreate
                ? strings.pb1215EmptyBody
                : strings.pb1215EmptyBodyReadOnly,
            action: canCreate
                ? FilledButton.icon(
                    key: const ValueKey('pc1215-empty-create'),
                    onPressed: _createProject,
                    icon: const Icon(Icons.create_new_folder_outlined),
                    label: Text(strings.pc1215NewProject),
                  )
                : null,
          ),
        ..._divided([
          for (final project in visible) _folderRow(strings, project),
        ]),
        if (hiddenCount > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: const ValueKey('pj1215-toggle-hidden'),
                onPressed: () => setState(() => _showHidden = !_showHidden),
                child: Text(
                  _showHidden
                      ? strings.pj1215HideHidden
                      : strings.pj1215ShowHidden(hiddenCount),
                ),
              ),
            ),
          ),
      ];
    }

    return Scaffold(
      appBar: HermesAppBar(
        title: Text(strings.projectsCenterTitle),
        actions: [
          IconButton(
            key: const ValueKey('pj1215-help'),
            tooltip: strings.pj1215WhatIsThis,
            onPressed: _showExplainer,
            icon: const Icon(Icons.help_outline_rounded),
          ),
          if (canCreate)
            IconButton(
              key: const ValueKey('pc1215-add'),
              tooltip: strings.pb1215NewProjectTooltip,
              onPressed: _openAddMenu,
              icon: KeyedSubtree(
                key: _addAnchor,
                child: const Icon(Icons.add_rounded),
              ),
            ),
        ],
      ),
      body: GeneralDockShell(
        connection: widget.connection,
        connManager: widget.connectionManager,
        gestureTab: GestureDockTab.projects,
        // Tablets: the open project lives beside the list (expanded) or in
        // place of it (medium) instead of on a route of its own.
        paneLayout: true,
        body: AdaptiveListDetail(
          key: _panes,
          placeholder: const _ProjectPanePlaceholder(),
          onCollapsedWithDetail: _reopenPaneProjectFullScreen,
          list: SafeArea(
            child: _loading && snapshot == null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(28),
                      child: ConsoleLoader.large(
                        label: strings.projectsCenterLoading,
                      ),
                    ),
                  )
                : _failure != null && snapshot == null
                ? _CenterFailure(
                    message: projectFailureText(_failure!, strings),
                    onRetry: _load,
                  )
                : RefreshIndicator(
                    onRefresh: _refresh,
                    // Pull-to-refresh has no TalkBack gesture: the same
                    // refresh is a custom action on the list.
                    child: Semantics(
                      customSemanticsActions: {
                        CustomSemanticsAction(
                          label: strings.projectsCenterRefreshTooltip,
                        ): () =>
                            unawaited(_refresh()),
                      },
                      child: ListView(
                        clipBehavior: hermesUnderHeader,
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(0, 4, 0, 28),
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                            child: HermesSearchField(
                              key: const ValueKey('pb1215-search'),
                              controller: _search,
                              hintText: strings.pb1215SearchHint,
                              clearTooltip: strings.pb1215SearchClear,
                              onChanged: (value) =>
                                  setState(() => _query = value),
                            ),
                          ),
                          if (_loading && snapshot != null)
                            const Padding(
                              padding: EdgeInsets.fromLTRB(16, 0, 16, 6),
                              child: LinearProgressIndicator(minHeight: 2),
                            ),
                          ...content,
                          if (_failure != null && snapshot != null)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
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
    addFolderBlock: writes.createBlock,
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
    case ProjectMenuAction.addFolder:
      final creation = writes.creation;
      final pick = writes.pickFolder;
      if (creation == null || pick == null) return;
      final folder = await pick(context);
      if (folder == null || !context.mounted) return;
      try {
        await creation.addProjectFolder(
          project.id,
          normalizeServerFolder(folder),
        );
        toast(strings.pc1215FolderAdded(label));
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

/// One folder of the browser: the chats that live directly in it and its
/// subfolders (worktrees, kanban lane, extra project folders).
final class _FolderModel {
  final List<ProjectSessionPreview> chats;
  final List<_SubfolderModel> subfolders;

  const _FolderModel(this.chats, this.subfolders);

  static const empty = _FolderModel([], []);
}

final class _SubfolderModel {
  final String id;
  final String label;
  final String path;
  final int count;
  final String tag;

  /// Kanban lanes are managed by the board: no "+" there (Desktop too).
  final bool canStartChat;
  final _FolderModel content;

  /// The owning project's folder tint, so subfolders read as its children.
  final Color? tint;

  const _SubfolderModel({
    required this.id,
    required this.label,
    required this.path,
    required this.count,
    required this.tag,
    required this.canStartChat,
    required this.content,
    required this.tint,
  });
}

String _pathKey(String path) => path.trim().replaceAll(RegExp(r'[/\\]+$'), '');

List<ProjectSessionPreview> _newestFirst(
  Iterable<ProjectSessionPreview> sessions,
) => sessions.toList()..sort((a, b) => b.lastActive.compareTo(a.lastActive));

/// A repository as a folder: its trunk chats directly inside, every linked
/// worktree / kanban lane as a subfolder.
_FolderModel _repoFolder(
  ProjectRepositoryNode repo,
  Strings strings,
  Color? tint,
) {
  final chats = <ProjectSessionPreview>[];
  final subfolders = <_SubfolderModel>[];
  // Older servers may not flag the trunk; its lane is the repo's own path.
  final flagged = repo.lanes.any((lane) => lane.isMain);
  for (final lane in repo.lanes) {
    final trunk =
        lane.isMain || (!flagged && _pathKey(lane.path) == _pathKey(repo.path));
    if (trunk) {
      chats.addAll(lane.sessions);
      continue;
    }
    subfolders.add(
      _SubfolderModel(
        id: lane.id,
        label: lane.label.isEmpty
            ? strings.projectsCenterBranchFallback
            : lane.label,
        path: lane.path,
        count: lane.sessions.length > lane.totalCount
            ? lane.sessions.length
            : lane.totalCount,
        tag: lane.isKanban
            ? strings.pj1215KanbanTag
            : strings.pj1215WorktreeTag,
        canStartChat: !lane.isKanban && lane.path.trim().isNotEmpty,
        content: _FolderModel(_newestFirst(lane.sessions), const []),
        tint: tint,
      ),
    );
  }
  return _FolderModel(_newestFirst(chats), subfolders);
}

/// The project as a folder (same grouping the server sent, never re-derived
/// from paths on the phone).
_FolderModel _projectFolder(ProjectNode project, Strings strings) {
  final tint = projectFolderTint(project);
  if (project.noProject) {
    return _FolderModel(
      _newestFirst([
        for (final repo in project.repositories)
          for (final lane in repo.lanes) ...lane.sessions,
      ]),
      const [],
    );
  }
  final repos = project.repositories;
  if (repos.isEmpty) return _FolderModel.empty;
  final root = _pathKey(projectRootPath(project));
  final primary = repos.firstWhere(
    (repo) => _pathKey(repo.path) == root,
    orElse: () => repos.first,
  );
  final base = _repoFolder(primary, strings, tint);
  return _FolderModel(base.chats, [
    ...base.subfolders,
    for (final repo in repos)
      if (!identical(repo, primary))
        _SubfolderModel(
          id: repo.id,
          label: repo.label.isEmpty ? shortServerPath(repo.path) : repo.label,
          path: repo.path,
          count: repo.sessionCount,
          tag: '',
          canStartChat: repo.path.trim().isNotEmpty,
          content: _repoFolder(repo, strings, tint),
          tint: tint,
        ),
  ]);
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

class _ProjectDetailScreenState extends State<_ProjectDetailScreen> {
  ProjectNode? _detail;
  Object? _failure;
  bool _showFiles = false;
  String _query = '';
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

  void _newChat([String? path]) {
    final root = projectRootPath(_project);
    final target = (path ?? root).trim();
    widget.launch(
      context,
      ProjectChatRequest.newChat(target.isEmpty ? null : target),
    );
  }

  void _openSubfolder(_SubfolderModel folder) {
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          settings: RouteSettings(name: 'project-folder:${folder.id}'),
          builder: (_) => _SubfolderScreen(
            folder: folder,
            launch: widget.launch,
            onRefresh: _reloadAll,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final project = _project;
    final loading = _detail == null;
    final title = project.noProject
        ? strings.pb1215OtherChats
        : project.label.isEmpty
        ? strings.projectsCenterUnnamedProject
        : project.label;
    final root = projectRootPath(project);
    final files = _files;
    final showFiles = files != null && _showFiles;
    final folder = loading
        ? _FolderModel.empty
        : _projectFolder(project, strings);
    final scaffold = Scaffold(
      appBar: HermesAppBar(
        titleSpacing: 0,
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (!showFiles)
            IconButton(
              key: const ValueKey('pj1215-detail-new-chat'),
              tooltip: root.isEmpty
                  ? strings.pj1215NewChatNoFolder
                  : strings.pb1215NewChatTooltip,
              onPressed: () => _newChat(),
              icon: const Icon(Icons.add_rounded),
            ),
          if (!project.noProject)
            IconButton(
              key: const ValueKey('pj1215-detail-menu'),
              tooltip: strings.pj1215MenuTooltip,
              onPressed: _menu,
              icon: const Icon(Icons.more_horiz_rounded),
            ),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: showFiles ? files.refresh : _reloadAll,
          child: ListView(
            clipBehavior: hermesUnderHeader,
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(0, 0, 0, 28),
            children: [
              _FolderHeader(
                path: root,
                body: project.noProject ? strings.pj1215HomeBucketBody : null,
              ),
              if (showFiles) ...[
                _FilesCrumb(projectTitle: title, onBack: _closeFiles),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: ProjectFilesBrowser(
                    key: const ValueKey('pf1215-files'),
                    controller: files,
                    failureText: (error) => projectFailureText(error, strings),
                    uploadPicker: widget.uploadPicker,
                  ),
                ),
              ] else
                ..._FolderBody(
                  folder: folder,
                  query: _query,
                  onQuery: (value) => setState(() => _query = value),
                  loading: loading,
                  stale: _failure != null,
                  canStartChat: true,
                  leading: [
                    if (files != null)
                      ProjectFolderRow(
                        rowKey: const ValueKey('pf1215-tab-files'),
                        glyph: ProjectFolderGlyph(
                          tint: projectFolderTint(project),
                          width: 36,
                        ),
                        title: strings.pb1215FilesFolder,
                        summary: strings.pb1215FilesFolderSubtitle,
                        onTap: () => setState(() => _showFiles = true),
                      ),
                  ],
                  onOpenChat: (session) => widget.launch(
                    context,
                    ProjectChatRequest.existing(session),
                  ),
                  onOpenSubfolder: _openSubfolder,
                ).children(context),
            ],
          ),
        ),
      ),
    );
    if (files == null) return scaffold;
    // Inside the files, back climbs one folder, then returns to the project.
    return ListenableBuilder(
      listenable: files,
      builder: (context, child) => PopScope(
        canPop: !showFiles,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop || !showFiles) return;
          if (files.atRoot) {
            _closeFiles();
          } else {
            files.up();
          }
        },
        child: child!,
      ),
      child: scaffold,
    );
  }

  void _closeFiles() => setState(() => _showFiles = false);
}

/// A subfolder (worktree, kanban lane or extra project folder) pushed like
/// a folder in a Files app: its chats, its own subfolders, and "+" to start
/// a chat right there.
class _SubfolderScreen extends StatefulWidget {
  final _SubfolderModel folder;
  final void Function(BuildContext, ProjectChatRequest) launch;
  final Future<void> Function() onRefresh;

  const _SubfolderScreen({
    required this.folder,
    required this.launch,
    required this.onRefresh,
  });

  @override
  State<_SubfolderScreen> createState() => _SubfolderScreenState();
}

class _SubfolderScreenState extends State<_SubfolderScreen> {
  String _query = '';

  void _open(_SubfolderModel folder) {
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          settings: RouteSettings(name: 'project-folder:${folder.id}'),
          builder: (_) => _SubfolderScreen(
            folder: folder,
            launch: widget.launch,
            onRefresh: widget.onRefresh,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final folder = widget.folder;
    return Scaffold(
      appBar: HermesAppBar(
        titleSpacing: 0,
        title: Text(folder.label, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (folder.canStartChat)
            IconButton(
              key: const ValueKey('pj1215-detail-new-chat'),
              tooltip: strings.pb1215NewChatTooltip,
              onPressed: () => widget.launch(
                context,
                ProjectChatRequest.newChat(folder.path.trim()),
              ),
              icon: const Icon(Icons.add_rounded),
            ),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: widget.onRefresh,
          child: ListView(
            clipBehavior: hermesUnderHeader,
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(0, 0, 0, 28),
            children: [
              _FolderHeader(path: folder.path),
              ..._FolderBody(
                folder: folder.content,
                query: _query,
                onQuery: (value) => setState(() => _query = value),
                loading: false,
                stale: false,
                canStartChat: folder.canStartChat,
                leading: const [],
                onOpenChat: (session) => widget.launch(
                  context,
                  ProjectChatRequest.existing(session),
                ),
                onOpenSubfolder: _open,
              ).children(context),
            ],
          ),
        ),
      ),
    );
  }
}

/// Where the folder lives on the server, in its short `~/…` form, small
/// and muted (the full path is in the project menu's Copy path).
class _FolderHeader extends StatelessWidget {
  final String path;
  final String? body;

  const _FolderHeader({required this.path, this.body});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final text = path.isNotEmpty ? shortServerPath(path) : body;
    if (text == null || text.isEmpty) return const SizedBox(height: 4);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
      child: Semantics(
        label: path.isNotEmpty
            ? strings.projectsCenterServerPathReadOnly
            : null,
        child: Text(
          text,
          key: path.isNotEmpty ? const ValueKey('pj1215-detail-path') : null,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: colors.textSecondary.withValues(alpha: 0.8),
            fontSize: 12,
          ),
        ),
      ),
    );
  }
}

/// "Project › Files" crumb above the file browser; the first crumb goes
/// back to the project's chats without losing the folder you were in.
class _FilesCrumb extends StatelessWidget {
  final String projectTitle;
  final VoidCallback onBack;

  const _FilesCrumb({required this.projectTitle, required this.onBack});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 16, 4),
      child: Row(
        children: [
          Flexible(
            child: TextButton.icon(
              key: const ValueKey('pf1215-tab-chats'),
              onPressed: onBack,
              icon: const Icon(Icons.chevron_left_rounded, size: 20),
              label: Text(
                projectTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          Icon(
            Icons.chevron_right_rounded,
            size: 18,
            color: colors.textDisabled,
          ),
          const SizedBox(width: 4),
          Text(
            strings.pb1215FilesFolder,
            key: const ValueKey('pf1215-tab-files'),
            style: TextStyle(
              color: colors.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// The shared body of a folder: search, subfolders, chats, empty states.
final class _FolderBody {
  final _FolderModel folder;
  final String query;
  final ValueChanged<String> onQuery;
  final bool loading;
  final bool stale;
  final bool canStartChat;
  final List<Widget> leading;
  final ValueChanged<ProjectSessionPreview> onOpenChat;
  final ValueChanged<_SubfolderModel> onOpenSubfolder;

  const _FolderBody({
    required this.folder,
    required this.query,
    required this.onQuery,
    required this.loading,
    required this.stale,
    required this.canStartChat,
    required this.leading,
    required this.onOpenChat,
    required this.onOpenSubfolder,
  });

  List<Widget> children(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final needle = projectSearchFold(query.trim());
    final searching = needle.isNotEmpty;
    final chats = [
      for (final session in folder.chats)
        if (!searching ||
            projectSearchFold(session.title).contains(needle) ||
            projectSearchFold(session.preview).contains(needle))
          session,
    ];
    final subfolders = [
      for (final sub in folder.subfolders)
        if (!searching || projectSearchFold(sub.label).contains(needle)) sub,
    ];
    final folderRows = <Widget>[
      if (!searching) ...leading,
      for (final sub in subfolders)
        ProjectFolderRow(
          rowKey: ValueKey('pb1215-subfolder-${sub.id}'),
          glyph: ProjectFolderGlyph(tint: sub.tint, width: 36),
          title: sub.label,
          summary: [
            strings.pb1215ChatCount(sub.count),
            if (sub.tag.isNotEmpty) sub.tag,
          ].join(' · '),
          onTap: () => onOpenSubfolder(sub),
        ),
    ];
    List<Widget> divided(List<Widget> rows, double indent) => [
      for (final (index, row) in rows.indexed) ...[
        if (index > 0) ProjectRowDivider(indent: indent),
        row,
      ],
    ];
    final hasSearch = folder.chats.length + folder.subfolders.length > 3;
    return [
      if (hasSearch || searching)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
          child: HermesSearchField(
            key: const ValueKey('pb1215-search'),
            hintText: strings.pb1215SearchInProjectHint,
            clearTooltip: strings.pb1215SearchClear,
            onChanged: onQuery,
          ),
        ),
      if (stale)
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
          child: Text(
            strings.projectsCenterDetailStale,
            style: TextStyle(color: colors.warning, fontSize: 12),
          ),
        ),
      if (folderRows.isNotEmpty) ...[
        _SectionLabel(strings.pb1215FoldersSection),
        ...divided(folderRows, 66),
      ],
      if (loading)
        const Padding(
          padding: EdgeInsets.only(top: 32),
          child: Center(child: ConsoleLoader.medium(showLabel: true)),
        )
      else if (chats.isNotEmpty) ...[
        _SectionLabel(strings.pb1215ChatsSection),
        ...divided([
          for (final session in chats)
            ProjectChatRow(session: session, onTap: () => onOpenChat(session)),
        ], 60),
      ] else if (searching) ...[
        if (subfolders.isEmpty) _NoResults(query: query.trim()),
      ] else
        ProjectEmptyState(
          stateKey: const ValueKey('pb1215-empty-folder'),
          icon: Icons.forum_outlined,
          title: strings.pb1215EmptyFolderTitle,
          body: canStartChat
              ? strings.pb1215EmptyFolderBody
              : strings.pb1215EmptyFolderReadOnly,
        ),
    ];
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

/// Detail pane of an expanded window before any project is opened.
class _ProjectPanePlaceholder extends StatelessWidget {
  const _ProjectPanePlaceholder();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.folder_open_rounded,
                size: 40,
                color: colors.textSecondary,
              ),
              const SizedBox(height: 12),
              Text(
                Strings.of(context).tabletPickProject,
                key: const ValueKey('projects-pane-placeholder'),
                textAlign: TextAlign.center,
                style: TextStyle(color: colors.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String label;

  const _SectionLabel(this.label);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
    child: Semantics(
      header: true,
      child: Text(
        label,
        style: TextStyle(
          color: Theme.of(context).hermes.textSecondary,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
  );
}

class _NoResults extends StatelessWidget {
  final String query;

  const _NoResults({required this.query});

  @override
  Widget build(BuildContext context) => ProjectEmptyState(
    stateKey: const ValueKey('pb1215-no-results'),
    icon: Icons.search_off_rounded,
    title: Strings.of(context).pb1215NoResults(query),
    body: '',
  );
}

/// The project's plain folder: its soft colour, graphite for the chats
/// without a project.
class _ProjectFolderIcon extends StatelessWidget {
  final ProjectNode project;

  const _ProjectFolderIcon({required this.project});

  @override
  Widget build(BuildContext context) => ProjectFolderGlyph(
    tint: projectFolderTint(project),
    neutral: project.noProject,
  );
}
