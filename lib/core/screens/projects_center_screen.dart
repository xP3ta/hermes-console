import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../models/desktop_control_center.dart';
import '../navigation/chat_route.dart';
import '../services/connection_manager.dart';
import '../services/desktop_control_gateway.dart';
import '../theme/app_theme.dart';
import '../widgets/general_dock_shell.dart';
import '../widgets/hermes_ui.dart';
import 'chat_screen.dart';

/// Mobile projection of Hermes Desktop's authoritative `projects.tree`.
///
/// The phone never scans host paths or invents project membership. It renders
/// only the grouping returned by the selected Hermes instance.
class ProjectsCenterScreen extends StatefulWidget {
  final SavedConnection connection;
  final ConnectionManager connectionManager;
  final HermesDesktopControlGateway gateway;
  final Future<void> Function()? disposeGateway;

  const ProjectsCenterScreen({
    required this.connection,
    required this.connectionManager,
    required this.gateway,
    this.disposeGateway,
    super.key,
  });

  @override
  State<ProjectsCenterScreen> createState() => _ProjectsCenterScreenState();
}

class _ProjectsCenterScreenState extends State<ProjectsCenterScreen> {
  static const int _cacheLimit = 8;
  static final Map<String, ProjectTreeSnapshot> _memoryCache = {};

  ProjectTreeSnapshot? _snapshot;
  Object? _failure;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _snapshot = _memoryCache[widget.connection.id];
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant ProjectsCenterScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.gateway != widget.gateway ||
        oldWidget.connection.id != widget.connection.id) {
      _snapshot = _memoryCache[widget.connection.id];
      _failure = null;
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    final close = widget.disposeGateway;
    if (close != null) unawaited(close());
    super.dispose();
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

  String _failureText(Object failure, Strings strings) {
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
        DesktopControlFailureKind.rejected =>
          strings.projectsCenterFailureRejected,
      };
    }
    return strings.projectsCenterFailureUnknown;
  }

  Future<void> _openProject(ProjectNode project) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => _ProjectDetailScreen(
          project: project,
          connection: widget.connection,
          gateway: widget.gateway,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final snapshot = _snapshot;
    return Scaffold(
      appBar: AppBar(
        title: Text(strings.projectsCenterTitle),
        actions: [
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
                  message: _failureText(_failure!, strings),
                  onRetry: _load,
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
                    children: [
                      if (_loading && snapshot != null)
                        const Padding(
                          padding: EdgeInsets.only(bottom: 10),
                          child: LinearProgressIndicator(minHeight: 2),
                        ),
                      HermesPanel(
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                Icons.info_outline_rounded,
                                color: colors.accent,
                                size: 21,
                              ),
                              const SizedBox(width: 11),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      strings.projectsCenterHowItWorksTitle,
                                      style: TextStyle(
                                        color: colors.textPrimary,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      strings.projectsCenterIntro,
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
                        ),
                      ),
                      HermesSectionHeader(
                        strings.projectsCenterWorkspacesSection,
                      ),
                      if (snapshot == null || snapshot.projects.isEmpty)
                        _EmptyCenter(
                          icon: Icons.folder_open_outlined,
                          title: strings.projectsCenterEmptyTitle,
                          body: strings.projectsCenterEmptyBody,
                        )
                      else
                        ...snapshot.projects.map(
                          (project) => Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: _ProjectCard(
                              project: project,
                              active: snapshot.activeId == project.id,
                              onTap: () => _openProject(project),
                            ),
                          ),
                        ),
                      if (_failure != null && snapshot != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            strings.projectsCenterStaleView(
                              _failureText(_failure!, strings),
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

class _ProjectCard extends StatelessWidget {
  final ProjectNode project;
  final bool active;
  final VoidCallback onTap;

  const _ProjectCard({
    required this.project,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final label = project.label.isEmpty
        ? strings.projectsCenterUnnamedProject
        : project.label;
    return Semantics(
      button: true,
      label: strings.projectsCenterProjectSemantics(
        label,
        project.sessionCount,
      ),
      child: HermesCard(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(15),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  HermesIconTile(
                    project.noProject
                        ? Icons.inbox_outlined
                        : Icons.folder_copy_outlined,
                  ),
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
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '${strings.projectsCenterConversationCount(project.sessionCount)} · ${strings.projectsCenterRepositoryCount(project.repositories.length)}',
                          style: TextStyle(
                            color: colors.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (active)
                    Icon(Icons.check_circle_rounded, color: colors.success),
                  const SizedBox(width: 4),
                  Icon(Icons.chevron_right_rounded, color: colors.textDisabled),
                ],
              ),
              if (project.previewSessions.isNotEmpty) ...[
                const SizedBox(height: 12),
                Divider(height: 1, color: colors.divider),
                const SizedBox(height: 10),
                for (final preview in project.previewSessions.take(3))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 5),
                    child: Text(
                      '• ${preview.title.isEmpty ? preview.preview : preview.title}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ProjectDetailScreen extends StatefulWidget {
  final ProjectNode project;
  final SavedConnection connection;
  final HermesDesktopControlGateway gateway;

  const _ProjectDetailScreen({
    required this.project,
    required this.connection,
    required this.gateway,
  });

  @override
  State<_ProjectDetailScreen> createState() => _ProjectDetailScreenState();
}

class _ProjectDetailScreenState extends State<_ProjectDetailScreen> {
  ProjectNode? _detail;
  Object? _failure;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final detail = await widget.gateway.projectSessions(widget.project.id);
      if (!mounted) return;
      setState(() => _detail = detail ?? widget.project);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _failure = error;
        _detail = widget.project;
      });
    }
  }

  void _openSession(ProjectSessionPreview preview) {
    openChatFromHome<void>(
      context,
      builder: (_) => ChatScreen(
        connection: widget.connection,
        session: Session(
          id: preview.id,
          title: preview.title,
          model: '',
          source: 'desktop',
          messageCount: 0,
          isActive: false,
          preview: preview.preview,
          startedAt: preview.lastActive,
          updatedAt: preview.lastActive,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final project = _detail;
    final title = widget.project.label.isEmpty
        ? strings.projectsCenterUnnamedProject
        : widget.project.label;
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: project == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
              children: [
                if (project.path.isNotEmpty)
                  Semantics(
                    label: strings.projectsCenterServerPathReadOnly,
                    child: SelectableText(
                      project.path,
                      style: TextStyle(
                        color: colors.textSecondary,
                        fontSize: 11.5,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                if (_failure != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      strings.projectsCenterDetailStale,
                      style: TextStyle(color: colors.warning, fontSize: 12),
                    ),
                  ),
                HermesSectionHeader(strings.projectsCenterReposSection),
                if (project.repositories.isEmpty)
                  _EmptyCenter(
                    icon: Icons.account_tree_outlined,
                    title: strings.projectsCenterNoBranchesTitle,
                    body: strings.projectsCenterNoBranchesBody,
                  )
                else
                  for (final repository in project.repositories)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: HermesGroup(
                        children: [
                          Padding(
                            padding: const EdgeInsets.all(15),
                            child: Row(
                              children: [
                                const Icon(Icons.source_outlined, size: 20),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    repository.label.isEmpty
                                        ? repository.id
                                        : repository.label,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                Text('${repository.sessionCount}'),
                              ],
                            ),
                          ),
                          for (final lane in repository.lanes)
                            _ProjectLaneTile(lane: lane, onOpen: _openSession),
                        ],
                      ),
                    ),
              ],
            ),
    );
  }
}

class _ProjectLaneTile extends StatelessWidget {
  final ProjectLane lane;
  final ValueChanged<ProjectSessionPreview> onOpen;

  const _ProjectLaneTile({required this.lane, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    return Material(
      type: MaterialType.transparency,
      child: ExpansionTile(
        leading: const Icon(Icons.fork_right_rounded, size: 20),
        title: Text(
          lane.label.isEmpty
              ? strings.projectsCenterBranchFallback
              : lane.label,
        ),
        subtitle: Text(
          strings.projectsCenterConversationCount(lane.totalCount),
        ),
        children: lane.sessions.isEmpty
            ? [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: Text(
                    strings.projectsCenterLaneEmpty,
                    style: TextStyle(color: colors.textSecondary, fontSize: 12),
                  ),
                ),
              ]
            : lane.sessions
                  .map(
                    (session) => ListTile(
                      minTileHeight: 48,
                      title: Text(
                        session.title.isEmpty
                            ? strings.projectsCenterConversationFallback
                            : session.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: session.preview.isEmpty
                          ? null
                          : Text(
                              session.preview,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => onOpen(session),
                    ),
                  )
                  .toList(growable: false),
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
