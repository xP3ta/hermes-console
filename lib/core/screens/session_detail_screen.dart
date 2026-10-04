// Detalle de sesión — página action-first (spec 080) sobre datos reales del
// Gateway.
//
// Fuentes (verificadas contra api_server.py del upstream y el servidor vivo):
//   GET  /api/sessions/{id}            → métricas client-safe (_session_response)
//   POST /api/sessions/{id}/fork       → ramifica (la original queda "branched")
//   DELETE /api/sessions/{id}          → borrado real
//
// Solo se muestran métricas que el servidor informa; nada derivado se
// presenta como dato del servidor.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../main.dart';
import '../../l10n/app_localizations.dart';
import '../design/hermes_design.dart';
import '../navigation/chat_route.dart';
import '../services/connection_manager.dart';
import '../services/session_archive.dart';
import '../services/session_deletion.dart';
import '../services/session_repository.dart';
import '../theme/app_theme.dart';
import '../utils/relative_time.dart';
import '../widgets/hermes_notice.dart';
import '../widgets/read_only.dart';
import '../widgets/session_deletion_dialogs.dart';
import '../widgets/session_context_usage.dart';
import 'chat_screen.dart';
import 'cron_screen.dart';
import 'session_branches_screen.dart';

class SessionDetailScreen extends StatefulWidget {
  final SavedConnection connection;
  final Session session;
  final ApiClient? client;
  final bool skipInitialSessionRefresh;
  final int? observedFirstTokenLatencyMs;

  /// Rows the caller already holds; the branch family is built from them.
  final List<Session> knownSessions;

  const SessionDetailScreen({
    required this.connection,
    required this.session,
    this.knownSessions = const [],
    @visibleForTesting this.client,
    @visibleForTesting this.observedFirstTokenLatencyMs,
    this.skipInitialSessionRefresh = false,
    super.key,
  });

  @override
  State<SessionDetailScreen> createState() => _SessionDetailScreenState();
}

class _SessionDetailScreenState extends State<SessionDetailScreen> {
  late final ApiClient _client;
  late final SessionRepository _repository;

  late Session _session;
  bool _refreshing = false;
  bool _technicalOpen = false;

  SessionArchive? _archive;
  bool _archivePending = false;
  bool? _archiveOptimistic;

  @override
  void initState() {
    super.initState();
    _session = widget.session;
    _client =
        widget.client ??
        ApiClient(
          baseUrl: widget.connection.baseUrl,
          apiKey: widget.connection.apiKey,
          connectionId: widget.connection.id,
        );
    _repository = SessionRepository.forConnection(
      widget.connection,
      gateway: _client,
    );
    _loadArchive();
    _refresh(refreshSession: !widget.skipInitialSessionRefresh);
  }

  SessionContextMetrics get _contextMetrics =>
      SessionContextMetrics.fromSession(
        _session,
        observedFirstTokenLatencyMs:
            widget.observedFirstTokenLatencyMs ??
            context
                .findAncestorStateOfType<HermesAppState>()
                ?.activeChats
                .observedFirstTokenLatencyMs(
                  widget.connection.id,
                  _session.id,
                  profile: _session.profile,
                ),
      );

  @override
  void dispose() {
    _archive?.removeListener(_onArchiveChanged);
    _repository.close();
    _client.close();
    super.dispose();
  }

  Future<void> _loadArchive() async {
    final prefs = await SharedPreferences.getInstance();
    final archive = await SessionArchive.load(prefs, widget.connection.id);
    if (!mounted) return;
    setState(() {
      _archive?.removeListener(_onArchiveChanged);
      _archive = archive;
      archive.addListener(_onArchiveChanged);
    });
  }

  void _onArchiveChanged() {
    if (!mounted) return;
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.idle ||
        phase == SchedulerPhase.postFrameCallbacks) {
      setState(() {});
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    }
  }

  Future<void> _refresh({bool refreshSession = true}) async {
    setState(() => _refreshing = true);
    if (refreshSession) {
      try {
        final fresh = await _client.getSession(
          _session.id,
          profile: _session.profile,
        );
        if (mounted) setState(() => _session = fresh);
      } catch (_) {
        // La copia recibida de la lista sigue siendo válida; no romper la vista.
      }
    }
    if (mounted) setState(() => _refreshing = false);
  }

  bool get _archived =>
      _archiveOptimistic ??
      _archive?.isSessionArchived(_session) ??
      _session.archived;

  SessionState get _state => _session.stateWithArchive(_archived);

  // ── Acciones ───────────────────────────────────────────────────────────

  void _resume() {
    openChatFromHome<void>(
      context,
      builder: (_) =>
          ChatScreen(connection: widget.connection, session: _session),
    ).then((_) {
      if (mounted) _refresh();
    });
  }

  void _openBranches() {
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => SessionBranchesScreen(
          sessions: widget.knownSessions,
          currentId: _session.id,
          titleOf: (row) => row.title.trim().isNotEmpty ? row.title : row.id,
          onOpen: (row) {
            Navigator.of(context).pop();
            openChatFromHome<void>(
              context,
              builder: (_) =>
                  ChatScreen(connection: widget.connection, session: row),
            );
          },
        ),
      ),
    );
  }

  void _openLinkedCron() {
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => CronScreen(
          connection: widget.connection,
          initialJobId: _session.cronJobId,
        ),
      ),
    );
  }

  Future<void> _toggleArchive() async {
    if (_archive == null || _archivePending) return;
    final archived = !_archived;
    setState(() {
      _archivePending = true;
      _archiveOptimistic = archived;
    });
    try {
      final app = context.findAncestorStateOfType<HermesAppState>();
      await _repository.setArchived(
        _session,
        archived,
        profile: app?.connManager.activeProfileFor(widget.connection.id),
      );
      await _archive!.unarchiveSession(_session);
      if (archived) await _archive!.unpinSession(_session);
      if (!mounted) return;
      setState(() {
        _session = _session.copyWith(archived: archived);
        _archiveOptimistic = null;
        _archivePending = false;
      });
      HermesNotice.of(context).showSnackBar(
        SnackBar(
          content: Text(
            archived
                ? Strings.of(context).slArchived
                : Strings.of(context).slRestored,
          ),
        ),
      );
    } on DashboardHttpException catch (error) {
      if (error.statusCode == 404 || error.statusCode == 405) {
        if (archived) {
          await _archive!.archiveSession(_session);
        } else if (!_session.archived) {
          await _archive!.unarchiveSession(_session);
        } else {
          _restoreArchiveAfterFailure();
          return;
        }
        if (!mounted) return;
        setState(() {
          _archiveOptimistic = null;
          _archivePending = false;
        });
        HermesNotice.of(context).showSnackBar(
          SnackBar(
            content: Text(
              archived
                  ? Strings.of(context).slArchivedLocalOnly
                  : Strings.of(context).slRestoredLocalOnly,
            ),
          ),
        );
        return;
      }
      _restoreArchiveAfterFailure();
    } catch (_) {
      _restoreArchiveAfterFailure();
    }
  }

  void _restoreArchiveAfterFailure() {
    if (!mounted) return;
    setState(() {
      _archiveOptimistic = null;
      _archivePending = false;
    });
    HermesNotice.of(context).showSnackBar(
      SnackBar(content: Text(Strings.of(context).slArchiveSyncFailed)),
      kind: HermesNoticeKind.error,
    );
  }

  Future<void> _fork() async {
    if (widget.connection.readOnly) {
      showReadOnlyNotice(context);
      return;
    }
    final s = Strings.of(context);
    final confirm = await showHermesDialog<bool>(
      context: context,
      title: s.sesUiDuplicateTitle,
      message: s.sesDuplicateContent,
      actions: [
        HermesDialogAction(
          label: s.sesUiCancel,
          value: false,
          style: HermesDialogActionStyle.cancel,
        ),
        HermesDialogAction(
          key: const ValueKey('session-detail-duplicate-confirm'),
          label: s.sesUiDuplicate,
          value: true,
        ),
      ],
    );
    if (confirm != true || !mounted) return;

    try {
      final fork = await _client.forkSession(
        _session.id,
        profile: _session.profile,
      );
      if (!mounted) return;
      HermesNotice.of(context).showSnackBar(
        SnackBar(content: Text(Strings.of(context).sesDuplicated(fork.title))),
        kind: HermesNoticeKind.success,
      );
      Navigator.pushReplacement(
        context,
        MaterialPageRoute<void>(
          builder: (_) =>
              SessionDetailScreen(connection: widget.connection, session: fork),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      HermesNotice.of(context).showSnackBar(
        SnackBar(
          content: Text(Strings.of(context).sesDuplicateFailed(e.toString())),
        ),
        kind: HermesNoticeKind.error,
      );
    }
  }

  Future<void> _delete() async {
    if (widget.connection.readOnly) {
      showReadOnlyNotice(context);
      return;
    }
    final s = Strings.of(context);
    var cronDeletion = LinkedCronDeletionMode.keepSchedule;
    if (_session.isJob) {
      final choice = await showCronConversationDeleteDialog(context, _session);
      if (choice == null || !mounted) return;
      cronDeletion = choice;
    } else {
      final confirm = await showHermesDialog<bool>(
        context: context,
        title: s.sesUiDeleteTitle,
        message: s.sesDeleteContent(_titleText(s)),
        actions: [
          HermesDialogAction(
            label: s.sesUiCancel,
            value: false,
            style: HermesDialogActionStyle.cancel,
          ),
          HermesDialogAction(
            key: const ValueKey('session-detail-delete-confirm'),
            label: s.sesUiDelete,
            value: true,
            style: HermesDialogActionStyle.destructive,
          ),
        ],
      );
      if (confirm != true || !mounted) return;
    }
    final app = context.findAncestorStateOfType<HermesAppState>();
    final dashboard =
        _session.isJob &&
            cronDeletion == LinkedCronDeletionMode.deleteSchedule &&
            app == null
        ? DashboardClient.lazy(widget.connection)
        : null;
    final ownerProfile = Session.profileOwner(_session.profile);
    try {
      final result = await deleteSessionWithResolvedLineage(
        _session,
        loadSessions: ({bool includeChildren = false}) => _client.getSessions(
          includeChildren: includeChildren,
          profile: ownerProfile,
        ),
        deleteSession: (sessionId) =>
            _client.deleteSession(sessionId, profile: ownerProfile),
        cronDeletion: cronDeletion,
        deleteCronJob:
            !_session.isJob ||
                cronDeletion == LinkedCronDeletionMode.keepSchedule
            ? null
            : (jobId) => app != null
                  ? app.connManager.deleteLinkedCronJob(
                      widget.connection,
                      jobId,
                      profile: ownerProfile,
                    )
                  : dashboard!.deleteCronJob(jobId, profile: ownerProfile),
      );
      if (!mounted) return;
      switch (result.status) {
        case LinkedSessionDeleteStatus.deleted:
          // Shared store first: every screen drops the row in this frame.
          unawaited(_archive?.markSessionDeleted(_session));
          app?.activeChats.globalActivity.clearSession(
            widget.connection.id,
            ownerProfile,
            _session.id,
          );
          await app?.activeChats.globalActivity.flushJournal();
          await app?.activeChats.forgetColdStartSession(
            connectionId: widget.connection.id,
            profile: ownerProfile,
            sessionId: _session.id,
          );
          if (!mounted) return;
          Navigator.pop(context, true);
          break;
        case LinkedSessionDeleteStatus.cancelled:
          break;
        case LinkedSessionDeleteStatus.sessionRejected:
          HermesNotice.of(context).showSnackBar(
            SnackBar(
              content: Text(
                result.cronDeleted
                    ? s.cronStoppedChatKept
                    : s.slOfferHideContent,
              ),
            ),
          );
          break;
        case LinkedSessionDeleteStatus.cronDeleteFailed:
          HermesNotice.of(context).showSnackBar(
            SnackBar(content: Text(sessionDeletionFailureMessage(s, result))),
            kind: HermesNoticeKind.error,
          );
          break;
        case LinkedSessionDeleteStatus.sessionDeleteFailed:
          HermesNotice.of(context).showSnackBar(
            SnackBar(content: Text(sessionDeletionFailureMessage(s, result))),
            kind: HermesNoticeKind.error,
          );
          break;
      }
    } finally {
      dashboard?.close();
    }
  }

  void _copySummary() {
    final s = _session;
    final str = Strings.of(context);
    final preview = s.cleanPreview;
    final lines = <String>[
      str.sesCopySessionLabel(s.title.isNotEmpty ? s.title : s.id),
      str.sesCopyStateLabel(_statusLabel(str)),
      str.sesCopyInstanceLabel(widget.connection.label),
      if (s.model.isNotEmpty) str.sesCopyModelLabel(s.model),
      str.sesCopyMessagesLabel(s.messageCount),
      if (s.toolCallCount > 0) 'Tool calls: ${s.toolCallCount}',
      if (s.totalTokens > 0)
        'Tokens: ${s.totalTokens} (in ${s.inputTokens} / out ${s.outputTokens})',
      if (s.sessionDuration != null)
        str.sesCopyDurationLabel(_formatDuration(s.sessionDuration!)),
      if (preview.isNotEmpty) str.sesCopyLastMessageLabel(preview),
      'ID: ${s.id}',
    ];
    Clipboard.setData(ClipboardData(text: lines.join('\n')));
    HermesNotice.of(context).showSnackBar(
      SnackBar(content: Text(Strings.of(context).sesCopiedSummary)),
      kind: HermesNoticeKind.success,
    );
  }

  static String _formatDuration(Duration d) {
    if (d.inMinutes < 1) return '${d.inSeconds}s';
    if (d.inHours < 1) return '${d.inMinutes}min';
    if (d.inDays < 1) return '${d.inHours}h ${d.inMinutes % 60}min';
    return '${d.inDays}d ${d.inHours % 24}h';
  }

  // ── Presentación ───────────────────────────────────────────────────────

  // A local rename lives in the shared archive, like Home and Conversations.
  String _titleText(Strings s) {
    final local = _archive?.titleFor(_session.logicalId, '').trim() ?? '';
    if (local.isNotEmpty) return local;
    return _session.title.trim().isNotEmpty
        ? _session.title.trim()
        : s.sesNoTitle;
  }

  String _statusLabel(Strings s) => switch (_state) {
    SessionState.active => s.sesUiStatusActive,
    SessionState.idle => s.sesUiStatusIdle,
    SessionState.stale || SessionState.unknown => s.sesUiStatusStale,
    SessionState.archived => s.sesUiStatusArchived,
    SessionState.broken => s.sesUiStatusBroken,
  };

  HermesStatusTone get _statusTone => switch (_state) {
    SessionState.active => HermesStatusTone.active,
    SessionState.idle => HermesStatusTone.ok,
    SessionState.broken => HermesStatusTone.error,
    _ => HermesStatusTone.neutral,
  };

  static String _compactNumber(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 10000) return '${(n / 1000).toStringAsFixed(0)}k';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return '$n';
  }

  /// Only metrics the server (or the app, for TTFT) really reports; empty
  /// ones are never painted as a misleading "0".
  List<(String, String)> _technicalRows(Strings s) {
    final session = _session;
    final usage = _contextMetrics;
    return [
      if (session.toolCallCount > 0)
        (s.sesUiToolCalls, '${session.toolCallCount}'),
      if (session.totalTokens > 0)
        (s.sesUiTokens, _compactNumber(session.totalTokens)),
      if (session.inputTokens > 0)
        (s.sesUiTokensIn, _compactNumber(session.inputTokens)),
      if (session.outputTokens > 0)
        (s.sesUiTokensOut, _compactNumber(session.outputTokens)),
      if (usage.cacheReadTokens != null)
        (s.sesUiCacheRead, _compactNumber(usage.cacheReadTokens!)),
      if (usage.cacheWriteTokens != null)
        (s.sesUiCacheWrite, _compactNumber(usage.cacheWriteTokens!)),
      if (usage.cacheReadPercent != null)
        (s.sesUiCachePercent, '${usage.cacheReadPercent!.toStringAsFixed(1)}%'),
      if (usage.observedFirstTokenLatencyMs != null)
        (s.sesUiTtft, '${usage.observedFirstTokenLatencyMs} ms'),
      if (session.sessionDuration != null)
        (s.sesUiDuration, _formatDuration(session.sessionDuration!)),
      if (session.apiCallCount > 0)
        (s.sesUiApiCalls, '${session.apiCallCount}'),
      if ((session.actualCostUsd ?? 0) > 0)
        (s.sesUiCost, '\$${session.actualCostUsd!.toStringAsFixed(4)}')
      else if ((session.estimatedCostUsd ?? 0) > 0)
        (s.sesUiCostEst, '\$${session.estimatedCostUsd!.toStringAsFixed(4)}'),
    ];
  }

  void _openContext() {
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => _SessionContextPage(
          session: _session,
          instanceLabel: widget.connection.label,
          metrics: _contextMetrics,
        ),
      ),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final session = _session;
    final readOnly = widget.connection.readOnly;
    final preview = session.cleanPreview;
    final branched =
        session.endReason == 'branched' || session.parentSessionId != null;
    final lang = Localizations.localeOf(context).languageCode;
    final technical = _technicalRows(s);
    final showModel =
        session.model.isNotEmpty && session.model != 'hermes-agent';

    return HermesDetailScaffold(
      listKey: const ValueKey('session-detail-list'),
      title: _titleText(s),
      eyebrow: readOnly
          ? HermesTag(
              label: s.sesUiReadOnlyTag,
              tone: HermesStatusTone.neutral,
              icon: Icons.lock_outline_rounded,
            )
          : null,
      status: HermesStatusText(
        key: const ValueKey('session-detail-status'),
        label: _statusLabel(s),
        tone: _statusTone,
        meta: s.sesUiLastActivity(
          relativeTime(session.lastActivityAt, languageCode: lang),
        ),
      ),
      reason: readOnly ? s.sesUiReadOnly : (branched ? s.sesUiBranched : null),
      primaryAction: HermesActionButton(
        key: const ValueKey('session-detail-resume'),
        primary: true,
        icon: Icons.play_arrow_rounded,
        label: s.sesUiResume,
        onPressed: _resume,
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.refresh_rounded, size: 20),
          tooltip: s.sesRefreshTooltip,
          onPressed: _refreshing ? null : _refresh,
        ),
      ],
      onRefresh: _refresh,
      sections: [
        if (preview.isNotEmpty) ...[
          HermesSectionHeader(s.sesUiLastMessage),
          HermesTextBlock(
            key: const ValueKey('session-detail-last-message'),
            text: preview,
            collapsedLines: 5,
            copyable: true,
            openTitle: s.sesUiLastMessage,
          ),
        ],
        HermesSectionHeader(s.sesUiActions),
        HermesListGroup(
          children: [
            if (session.isJob)
              HermesListRow(
                key: const ValueKey('session-detail-open-routine'),
                icon: Icons.schedule_rounded,
                title: s.sesUiOpenRoutine,
                onTap: _openLinkedCron,
              ),
            if (SessionBranchesScreen.isAvailable(
              widget.knownSessions,
              _session.id,
            ))
              HermesListRow(
                key: const ValueKey('session-detail-branches'),
                icon: Icons.account_tree_outlined,
                title: s.sesBranchesTitle,
                onTap: _openBranches,
              ),
            if (!readOnly)
              HermesListRow(
                key: const ValueKey('session-detail-duplicate'),
                icon: Icons.call_split_rounded,
                title: s.sesUiDuplicate,
                showChevron: false,
                onTap: _fork,
              ),
            HermesListRow(
              key: const ValueKey('session-detail-archive'),
              icon: _archived
                  ? Icons.unarchive_outlined
                  : Icons.archive_outlined,
              title: _archived ? s.sesUiUnarchive : s.sesUiArchive,
              showChevron: false,
              onTap: _archive == null || _archivePending
                  ? null
                  : _toggleArchive,
            ),
            HermesListRow(
              key: const ValueKey('session-detail-copy-summary'),
              icon: Icons.content_copy_outlined,
              title: s.sesUiCopySummary,
              showChevron: false,
              onTap: _copySummary,
            ),
            if (!readOnly)
              HermesListRow(
                key: const ValueKey('session-detail-delete'),
                icon: Icons.delete_outline_rounded,
                title: s.sesUiDelete,
                destructive: true,
                showChevron: false,
                onTap: _delete,
              ),
          ],
        ),
        HermesSectionHeader(s.sesUiDetails),
        HermesListGroup(
          children: [
            HermesListRow(
              icon: Icons.chat_bubble_outline_rounded,
              title: s.sesUiMessages,
              value: '${session.messageCount}',
            ),
            if (showModel)
              HermesListRow(
                icon: Icons.memory_rounded,
                title: s.sesUiModel,
                value: session.model,
              ),
            HermesListRow(
              icon: Icons.dns_outlined,
              title: s.sesUiInstance,
              value: widget.connection.label,
            ),
            HermesListRow(
              key: const ValueKey('session-detail-context'),
              icon: Icons.info_outline_rounded,
              title: s.sesUiContext,
              subtitle: s.sesUiContextHint,
              onTap: _openContext,
            ),
            if (technical.isNotEmpty) ...[
              HermesListRow(
                key: const ValueKey('session-detail-technical'),
                icon: Icons.tune_rounded,
                title: s.sesUiTechnical,
                onTap: () => setState(() => _technicalOpen = !_technicalOpen),
                trailing: Icon(
                  _technicalOpen
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  size: 20,
                  color: colors.textSecondary,
                ),
              ),
              if (_technicalOpen)
                for (final (label, value) in technical)
                  HermesListRow(title: label, value: value, muted: true),
            ],
          ],
        ),
      ],
    );
  }
}

/// Session context as its own page: identity, dates and cache data reported
/// by the Gateway. Identifiers copy on tap.
class _SessionContextPage extends StatelessWidget {
  final Session session;
  final String instanceLabel;
  final SessionContextMetrics metrics;

  const _SessionContextPage({
    required this.session,
    required this.instanceLabel,
    required this.metrics,
  });

  static String _formatTimestamp(double ts) {
    final dt = DateTime.fromMillisecondsSinceEpoch((ts * 1000).toInt());
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
        '${two(dt.hour)}:${two(dt.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final ids = <(String, String)>[
      (s.sesCtxId, session.id),
      if (session.parentSessionId != null)
        (s.sesCtxBranchedFrom, session.parentSessionId!),
    ];
    final origin = <(String, String)>[
      (s.sesCtxModel, session.model.isNotEmpty ? session.model : '—'),
      (s.sesCtxSource, session.source.isNotEmpty ? session.source : '—'),
      (s.sesCtxInstance, instanceLabel),
      (
        s.sesCtxSystemPrompt,
        session.hasSystemPrompt
            ? s.sesCtxSystemPromptDefined
            : s.sesCtxSystemPromptNone,
      ),
    ];
    final dates = <(String, String)>[
      (
        s.sesCtxCreated,
        session.startedAt > 0 ? _formatTimestamp(session.startedAt) : '—',
      ),
      if (session.updatedAt != null)
        (s.sesCtxLastActivity, _formatTimestamp(session.updatedAt!)),
      if (session.endedAt != null)
        (s.sesCtxClosed, _formatTimestamp(session.endedAt!)),
      if (session.endReason != null) (s.sesCtxCloseReason, session.endReason!),
    ];
    final cache = <(String, String)>[
      (
        s.chaContextObservedTtft,
        metrics.observedFirstTokenLatencyMs == null
            ? s.chaContextNotMeasured
            : '${metrics.observedFirstTokenLatencyMs} ms',
      ),
      (
        s.chaContextCacheRead,
        metrics.cacheReadTokens == null
            ? s.chaContextNotPublished
            : _SessionDetailScreenState._compactNumber(
                metrics.cacheReadTokens!,
              ),
      ),
      (
        s.chaContextCacheWrite,
        metrics.cacheWriteTokens == null
            ? s.chaContextNotPublished
            : _SessionDetailScreenState._compactNumber(
                metrics.cacheWriteTokens!,
              ),
      ),
      if (metrics.cacheReadPercent != null)
        (
          s.sesUiCachePercent,
          '${metrics.cacheReadPercent!.toStringAsFixed(1)}%',
        ),
      if (session.reasoningTokens > 0)
        (
          s.sesCtxReasoningTokens,
          _SessionDetailScreenState._compactNumber(session.reasoningTokens),
        ),
    ];

    // Legacy context labels are lowercase; rows use sentence case.
    String label(String raw) =>
        raw.isEmpty ? raw : raw[0].toUpperCase() + raw.substring(1);

    Widget copyRow((String, String) row) => HermesListRow(
      title: label(row.$1),
      subtitle: row.$2,
      subtitleMaxLines: 3,
      trailing: Icon(
        Icons.content_copy_outlined,
        size: 16,
        color: colors.textDisabled,
      ),
      onTap: () async {
        await Clipboard.setData(ClipboardData(text: row.$2));
        if (!context.mounted) return;
        HermesNotice.show(
          context,
          message: s.designCopied,
          kind: HermesNoticeKind.success,
        );
      },
    );
    Widget valueRow((String, String) row) => row.$2.length > 22
        ? HermesListRow(
            title: label(row.$1),
            subtitle: row.$2,
            subtitleMaxLines: 3,
          )
        : HermesListRow(title: label(row.$1), value: row.$2);

    return HermesPage(
      title: s.sesUiContext,
      listKey: const ValueKey('session-context-page'),
      children: [
        HermesListGroup(
          dividerIndent: HermesSpace.rowH,
          children: [for (final row in ids) copyRow(row)],
        ),
        HermesSectionHeader(s.sesUiContextOrigin),
        HermesListGroup(
          dividerIndent: HermesSpace.rowH,
          children: [for (final row in origin) valueRow(row)],
        ),
        HermesSectionHeader(s.sesUiContextDates),
        HermesListGroup(
          dividerIndent: HermesSpace.rowH,
          children: [for (final row in dates) valueRow(row)],
        ),
        HermesSectionHeader(s.sesUiContextCache),
        HermesListGroup(
          dividerIndent: HermesSpace.rowH,
          children: [for (final row in cache) valueRow(row)],
        ),
      ],
    );
  }
}
