// Detalle de sesión — vista premium sobre los datos reales del Gateway.
//
// Fuentes (verificadas contra api_server.py del upstream y el servidor vivo):
//   GET  /api/sessions/{id}            → métricas client-safe (_session_response)
//   GET  /api/sessions/{id}/messages   → transcript completo
//   POST /api/sessions/{id}/fork       → ramifica (la original queda "branched")
//   DELETE /api/sessions/{id}          → borrado real
//
// Solo se muestran métricas que el servidor informa; nada derivado se
// presenta como dato del servidor.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderAbstractViewport, RenderBox;
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../main.dart';
import '../../l10n/app_localizations.dart';
import '../models/desktop_session_snapshot.dart';
import '../models/generated_artifact.dart';
import '../models/session_artifact.dart';
import '../navigation/chat_route.dart';
import '../services/artifact_export_service.dart';
import '../services/artifact_index.dart';
import '../services/connection_manager.dart';
import '../services/generated_artifact_registry.dart';
import '../services/session_archive.dart';
import '../services/session_artifact_download_service.dart';
import '../services/session_deletion.dart';
import '../services/session_repository.dart';
import '../theme/app_theme.dart';
import '../utils/assistant_content.dart';
import '../utils/assistant_suggestions.dart';
import '../utils/relative_time.dart';
import '../utils/generated_artifact_markdown_scanner.dart';
import '../widgets/accent_card.dart';
import '../widgets/hermes_pill.dart';
import '../widgets/hermes_premium_ui.dart';
import '../widgets/hermes_ui.dart';
import '../widgets/generated_artifact_viewer.dart';
import '../widgets/read_only.dart';
import '../widgets/session_deletion_dialogs.dart';
import '../widgets/session_artifacts_sheet.dart';
import '../widgets/session_context_usage.dart';
import 'chat_screen.dart';
import 'cron_screen.dart';
import '../widgets/hermes_app_bar.dart';

class SessionDetailScreen extends StatefulWidget {
  final SavedConnection connection;
  final Session session;
  final ApiClient? client;
  final bool skipInitialSessionRefresh;
  final int? observedFirstTokenLatencyMs;

  const SessionDetailScreen({
    required this.connection,
    required this.session,
    @visibleForTesting this.client,
    @visibleForTesting this.observedFirstTokenLatencyMs,
    this.skipInitialSessionRefresh = false,
    super.key,
  });

  @override
  State<SessionDetailScreen> createState() => _SessionDetailScreenState();
}

class _SessionDetailScreenState extends State<SessionDetailScreen>
    with SingleTickerProviderStateMixin {
  late final ApiClient _client;
  late final SessionRepository _repository;
  late final TabController _tabs;

  late Session _session;
  bool _refreshing = false;

  List<Map<String, dynamic>>? _messages;
  String? _messagesError;
  int _messagesRevision = 0;
  ArtifactIndexSnapshot? _artifactIndex;
  final GeneratedArtifactRegistry _generatedArtifactRegistry =
      GeneratedArtifactRegistry.shared;
  static const ArtifactExportActions _artifactExporter =
      PlatformArtifactExportActions();
  final ScrollController _messagesScrollController = ScrollController();
  final Map<int, RenderBox> _messageAnchors = {};

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
    _tabs = TabController(length: 3, vsync: this);
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
    _tabs.dispose();
    _messagesScrollController.dispose();
    _repository.close();
    _client.close();
    super.dispose();
  }

  Future<void> _loadArchive() async {
    final prefs = await SharedPreferences.getInstance();
    final archive = await SessionArchive.load(prefs, widget.connection.id);
    if (mounted) setState(() => _archive = archive);
  }

  Future<void> _refresh({bool refreshSession = true}) async {
    setState(() => _refreshing = true);
    if (refreshSession) {
      try {
        final fresh = await _client.getSession(_session.id);
        if (mounted) setState(() => _session = fresh);
      } catch (_) {
        // La copia recibida de la lista sigue siendo válida; no romper la vista.
      }
    }
    try {
      final msgs = await _client.getMessages(_session.id);
      if (mounted) {
        _indexGeneratedArtifacts(msgs);
        setState(() {
          _messages = msgs;
          _messagesRevision++;
          _messageAnchors.clear();
          _messagesError = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _messagesError = e.toString().replaceFirst('Exception: ', ''),
        );
      }
    }
    if (mounted) setState(() => _refreshing = false);
  }

  void _indexGeneratedArtifacts(List<Map<String, dynamic>> messages) {
    final artifacts = <GeneratedArtifactInput>[];
    for (final message in messages) {
      if (message['role']?.toString().trim().toLowerCase() != 'assistant') {
        continue;
      }
      final content = message['content'];
      if (content is! String || content.trim().isEmpty) continue;
      final terminalAnswer = projectAssistantSuggestions(
        splitReasoning(content).answer,
      ).body;
      for (final artifact in GeneratedArtifactMarkdownScanner.scan(
        terminalAnswer,
      )) {
        artifacts.add(
          GeneratedArtifactInput(
            detection: artifact.detection,
            content: artifact.content,
          ),
        );
      }
    }
    _generatedArtifactRegistry.replaceSession(
      _generatedArtifactScope,
      artifacts,
    );
  }

  bool get _archived =>
      _archiveOptimistic ??
      _archive?.isSessionArchived(_session) ??
      _session.archived;

  SessionState get _state => _session.stateWithArchive(_archived);

  String get _generatedArtifactScope =>
      '${widget.connection.id}:${_session.logicalId}';

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

  List<SessionArtifact> _resolveSessionArtifacts() {
    final messages = _messages;
    if (messages == null) return const [];
    late final ArtifactIndexScope scope;
    try {
      scope = ArtifactIndexScope(
        connectionId: widget.connection.id,
        logicalSessionId: _session.logicalId,
      );
    } on FormatException {
      return const [];
    }
    final host = Uri.tryParse(widget.connection.baseUrl)?.host.toLowerCase();
    final policy = ArtifactAuthorizationPolicy(
      revision: 1,
      allowedManagedUriSchemes: host == null || host.isEmpty
          ? const ['hermes']
          : const ['hermes', 'http', 'https'],
      allowedManagedHosts: host == null || host.isEmpty ? const [] : [host],
    );
    final previous = _artifactIndex;
    if (previous != null &&
        previous.revision.scope == scope &&
        previous.revision.transcriptRevision == _messagesRevision &&
        previous.revision.policyRevision == policy.revision) {
      return previous.artifacts;
    }

    final entries = <ArtifactTranscriptEntry>[];
    for (var ordinal = 0; ordinal < messages.length; ordinal++) {
      final raw = messages[ordinal];
      if (!_messageMapMayContainArtifact(raw)) continue;
      final message = DesktopSessionMessage.tryParse(
        raw,
        serverOrdinal: ordinal,
      );
      if (message == null) continue;
      entries.add(
        ArtifactTranscriptEntry(
          message: message,
          messageOrdinal: ordinal,
          messageRevision: _messagesRevision,
          stableMessageId: message.stableId,
        ),
      );
    }
    _artifactIndex = ArtifactIndex.resolve(
      previous: previous,
      scope: scope,
      transcriptRevision: _messagesRevision,
      transcript: entries,
      policy: policy,
    );
    return _artifactIndex!.artifacts;
  }

  bool _messageMapMayContainArtifact(Map<String, dynamic> message) {
    final content = message['content'];
    if (content is Map || content is List) return true;
    final context = message['context'];
    if (message['role']?.toString().toLowerCase() == 'tool' &&
        (context is Map || context is List)) {
      return true;
    }
    for (final key in const {
      'attachment',
      'attachments',
      'artifact',
      'artifacts',
      'generated_image',
      'generated_images',
      'tool_result',
      'tool_results',
    }) {
      final value = message[key];
      if (value is Map || value is List) return true;
    }
    return false;
  }

  Future<void> _showSessionArtifacts() async {
    final artifacts = _resolveSessionArtifacts();
    final downloads = SessionArtifactDownloadService(
      connection: widget.connection,
    );
    await showHermesFloatingSurface<void>(
      context: context,
      surfaceKey: const ValueKey('session-artifacts-surface'),
      maxWidth: 620,
      maxHeightFactor: 0.82,
      builder: (sheetContext) => SessionArtifactsSheet(
        artifacts: artifacts,
        generatedArtifactRegistry: _generatedArtifactRegistry,
        generatedArtifactSessionId: _generatedArtifactScope,
        showDragHandle: false,
        onOpenGeneratedArtifact: (artifactId) {
          Navigator.of(sheetContext).pop();
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            unawaited(
              showGeneratedArtifactViewer(
                context: context,
                registry: _generatedArtifactRegistry,
                artifactId: artifactId,
                exporter: _artifactExporter,
              ),
            );
          });
        },
        canDownloadArtifact: downloads.canDownload,
        onDownloadArtifact: _downloadSessionArtifact,
        onJumpToSource: (source) {
          Navigator.of(sheetContext).pop();
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) unawaited(_jumpToArtifactSource(source));
          });
        },
      ),
    );
  }

  Future<void> _downloadSessionArtifact(SessionArtifact artifact) async {
    final strings = Strings.of(context);
    try {
      final result = await SessionArtifactDownloadService(
        connection: widget.connection,
      ).downloadAndSave(artifact, _artifactExporter);
      if (mounted && result == ArtifactSaveResult.saved) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(strings.artifactDownloadSaved)));
      }
    } on SessionArtifactDownloadException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              sessionArtifactDownloadMessage(strings, error.failure),
            ),
          ),
        );
      }
    } on ArtifactExportTooLarge {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(strings.artifactDownloadTooLarge)),
        );
      }
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(strings.artifactDownloadFailed)));
      }
    }
  }

  int? _messageIndexForArtifactSource(SessionArtifactSource source) {
    final messages = _messages;
    if (messages == null) return null;
    return messageIndexForArtifactSource(messages, source);
  }

  Future<void> _jumpToArtifactSource(SessionArtifactSource source) async {
    final targetIndex = _messageIndexForArtifactSource(source);
    if (targetIndex == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(Strings.of(context).artifactSourceUnavailable),
          ),
        );
      }
      return;
    }
    _tabs.animateTo(1);
    for (var frame = 0; frame < 30; frame++) {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      if (_messagesScrollController.hasClients) break;
    }
    if (!_messagesScrollController.hasClients) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(Strings.of(context).artifactSourceUnavailable),
          ),
        );
      }
      return;
    }
    final position = _messagesScrollController.position;

    Future<bool> alignIfMounted() async {
      final anchor = _messageAnchors[targetIndex];
      if (anchor == null || !anchor.attached) return false;
      final viewport = RenderAbstractViewport.maybeOf(anchor);
      if (viewport == null) return false;
      final target = viewport
          .getOffsetToReveal(anchor, 0)
          .offset
          .clamp(position.minScrollExtent, position.maxScrollExtent);
      await position.animateTo(
        target,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
      return true;
    }

    if (await alignIfMounted()) return;
    position.jumpTo(position.minScrollExtent);
    await WidgetsBinding.instance.endOfFrame;
    if (await alignIfMounted()) return;
    for (var attempt = 0; attempt < 80; attempt++) {
      if (!mounted || !_messagesScrollController.hasClients) return;
      if (position.pixels >= position.maxScrollExtent - 1) break;
      position.jumpTo(
        (position.pixels + position.viewportDimension * 0.9).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        ),
      );
      await WidgetsBinding.instance.endOfFrame;
      if (await alignIfMounted()) return;
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(Strings.of(context).artifactSourceUnavailable)),
      );
    }
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
      ScaffoldMessenger.of(context).showSnackBar(
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
        ScaffoldMessenger.of(context).showSnackBar(
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(Strings.of(context).slArchiveSyncFailed)),
    );
  }

  Future<void> _fork() async {
    if (widget.connection.readOnly) {
      showReadOnlyNotice(context);
      return;
    }
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(s.sesDuplicateTitle),
        content: Text(s.sesDuplicateContent),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(s.sesCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(s.sesDuplicate, style: TextStyle(color: colors.accent)),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    try {
      final fork = await _client.forkSession(_session.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(Strings.of(context).sesDuplicated(fork.title))),
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(Strings.of(context).sesDuplicateFailed(e.toString())),
        ),
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
      final colors = Theme.of(context).hermes;
      final confirm = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: Text(s.sesDeleteTitle),
          content: Text(s.sesDeleteContent(_session.title)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(s.sesCancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(s.sesDelete, style: TextStyle(color: colors.error)),
            ),
          ],
        ),
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
    try {
      final result = await deleteSessionWithResolvedLineage(
        _session,
        loadSessions: ({bool includeChildren = false}) =>
            _client.getSessions(includeChildren: includeChildren),
        deleteSession: _client.deleteSession,
        cronDeletion: cronDeletion,
        deleteCronJob:
            !_session.isJob ||
                cronDeletion == LinkedCronDeletionMode.keepSchedule
            ? null
            : (jobId) => app != null
                  ? app.connManager.deleteLinkedCronJob(
                      widget.connection,
                      jobId,
                      profile: app.connManager.activeProfileFor(
                        widget.connection.id,
                      ),
                    )
                  : dashboard!.deleteCronJob(jobId),
      );
      if (!mounted) return;
      switch (result.status) {
        case LinkedSessionDeleteStatus.deleted:
          Navigator.pop(context, true);
          break;
        case LinkedSessionDeleteStatus.cancelled:
          break;
        case LinkedSessionDeleteStatus.sessionRejected:
          ScaffoldMessenger.of(context).showSnackBar(
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
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(sessionDeletionFailureMessage(s, result))),
          );
          break;
        case LinkedSessionDeleteStatus.sessionDeleteFailed:
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(sessionDeletionFailureMessage(s, result))),
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
      str.sesCopyStateLabel(_state.label),
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(Strings.of(context).sesCopiedSummary)),
    );
  }

  static String _formatDuration(Duration d) {
    if (d.inMinutes < 1) return '${d.inSeconds}s';
    if (d.inHours < 1) return '${d.inMinutes}min';
    if (d.inDays < 1) return '${d.inHours}h ${d.inMinutes % 60}min';
    return '${d.inDays}d ${d.inHours % 24}h';
  }

  static String _formatTimestamp(double ts) {
    final dt = DateTime.fromMillisecondsSinceEpoch((ts * 1000).toInt());
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
        '${two(dt.hour)}:${two(dt.minute)}';
  }

  // ── Build ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final str = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return Scaffold(
      appBar: HermesAppBar(
        centerTitle: false,
        title: Text(
          str.sesScreenTitle,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 15,
            letterSpacing: 1.5,
            color: colors.accentHover,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.inventory_2_outlined, size: 20),
            tooltip: str.chaArtifactsAction,
            onPressed: _messages == null ? null : _showSessionArtifacts,
          ),
          IconButton(
            icon: const Icon(Icons.refresh, size: 20),
            tooltip: str.sesRefreshTooltip,
            onPressed: _refreshing ? null : _refresh,
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          labelStyle: const TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.8,
          ),
          tabs: [
            Tab(text: str.sesTabSummary),
            Tab(text: str.sesTabMessages),
            Tab(text: str.sesTabContext),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _buildSummaryTab(colors),
          _buildMessagesTab(colors),
          _buildContextTab(colors),
        ],
      ),
    );
  }

  // ── Tab: resumen ───────────────────────────────────────────────────────

  Widget _buildSummaryTab(HermesThemeColors colors) {
    final str = Strings.of(context);
    final s = _session;
    final preview = s.cleanPreview;
    final isOpen = _state == SessionState.active || _state == SessionState.idle;

    return RefreshIndicator(
      color: colors.accent,
      onRefresh: _refresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 24),
        children: [
          // Cabecera: título + estado + contexto de instancia.
          AccentCard(
            accent: isOpen ? colors.accent.withValues(alpha: 0.7) : null,
            background: colors.surface,
            borderColor: colors.divider,
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    HermesIconTile(
                      _state == SessionState.broken
                          ? Icons.error_outline
                          : Icons.chat_bubble_outline,
                      size: 38,
                      active: isOpen,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            s.title.isNotEmpty ? s.title : str.sesNoTitle,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: colors.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              HermesPill(
                                color: _stateColor(colors),
                                label: _state.label,
                              ),
                              if (s.model.isNotEmpty &&
                                  s.model != 'hermes-agent')
                                HermesBadge(
                                  s.model,
                                  color: colors.textSecondary,
                                  dot: false,
                                ),
                              if (widget.connection.readOnly)
                                const ReadOnlyBadge(compact: true),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  '${widget.connection.label} · '
                  '${str.sesLastActivity(relativeTime(s.lastActivityAt))}'
                  '${s.source.isNotEmpty ? ' · ${s.source}' : ''}',
                  style: TextStyle(fontSize: 10.5, color: colors.textSecondary),
                ),
              ],
            ),
          ),

          if (s.endReason == 'branched' || s.parentSessionId != null) ...[
            const SizedBox(height: 10),
            HermesInfoBanner(
              s.parentSessionId != null
                  ? str.sesBranchedFrom(s.parentSessionId!)
                  : str.sesBranchedInfo,
              icon: Icons.call_split,
            ),
          ],

          const SizedBox(height: 18),
          HermesSectionHeader(str.sesSectionMetrics),
          const SizedBox(height: 8),
          _buildMetricsGrid(colors, s),

          if (preview.isNotEmpty) ...[
            const SizedBox(height: 18),
            HermesSectionHeader(str.sesSectionLastMessage),
            const SizedBox(height: 8),
            HermesCard(
              padding: const EdgeInsets.all(12),
              child: Text(
                preview,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.45,
                  color: colors.textSecondary,
                ),
              ),
            ),
          ],

          const SizedBox(height: 18),
          HermesSectionHeader(str.sesSectionActions),
          const SizedBox(height: 8),
          if (widget.connection.readOnly) ...[
            HermesInfoBanner(str.sesReadOnlyNotice, icon: Icons.lock_outline),
            const SizedBox(height: 8),
          ],
          if (s.isJob) ...[
            HermesSecondaryButton(
              label: str.crnOpenFromConversation,
              icon: Icons.schedule_outlined,
              onTap: _openLinkedCron,
            ),
            const SizedBox(height: 8),
          ],
          HermesPrimaryButton(
            label: str.sesActionResume,
            icon: Icons.play_arrow_rounded,
            onTap: _resume,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: HermesSecondaryButton(
                  label: str.sesActionDuplicate,
                  icon: Icons.call_split,
                  onTap: widget.connection.readOnly ? null : _fork,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: HermesSecondaryButton(
                  label: _archived
                      ? str.sesActionUnarchive
                      : str.sesActionArchive,
                  icon: _archived
                      ? Icons.unarchive_outlined
                      : Icons.archive_outlined,
                  onTap: _archivePending ? null : _toggleArchive,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: HermesSecondaryButton(
                  label: str.sesActionCopySummary,
                  icon: Icons.content_copy_outlined,
                  onTap: _copySummary,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: HermesSecondaryButton(
                  label: str.sesActionDelete,
                  icon: Icons.delete_outline,
                  color: widget.connection.readOnly ? null : colors.error,
                  onTap: widget.connection.readOnly ? null : _delete,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            str.sesActionDisclaimer,
            style: TextStyle(fontSize: 10, color: colors.textDisabled),
          ),
        ],
      ),
    );
  }

  Color _stateColor(HermesThemeColors colors) => switch (_state) {
    SessionState.active => colors.success,
    SessionState.idle => colors.accent,
    SessionState.stale => colors.textDisabled,
    SessionState.archived => colors.textSecondary,
    SessionState.broken => colors.error,
    SessionState.unknown => colors.textSecondary,
  };

  Widget _buildMetricsGrid(HermesThemeColors colors, Session s) {
    final str = Strings.of(context);
    final usage = _contextMetrics;
    // Solo métricas que el servidor informa de verdad; las vacías no se
    // pintan como "0" engañoso salvo mensajes (siempre presente).
    final metrics = <(String, String)>[
      (str.sesMetricMessages, '${s.messageCount}'),
      if (s.toolCallCount > 0) (str.sesMetricToolCalls, '${s.toolCallCount}'),
      if (s.totalTokens > 0)
        (str.sesMetricTokens, _compactNumber(s.totalTokens)),
      if (s.inputTokens > 0)
        (str.sesMetricTokensIn, _compactNumber(s.inputTokens)),
      if (s.outputTokens > 0)
        (str.sesMetricTokensOut, _compactNumber(s.outputTokens)),
      if (usage.cacheReadTokens != null)
        (str.sesMetricCachedTokens, _compactNumber(usage.cacheReadTokens!)),
      if (usage.cacheWriteTokens != null)
        (str.chaContextCacheWrite, _compactNumber(usage.cacheWriteTokens!)),
      if (usage.cacheReadPercent != null)
        (
          str.sesMetricCachePercent,
          '${usage.cacheReadPercent!.toStringAsFixed(1)}%',
        ),
      if (usage.observedFirstTokenLatencyMs != null)
        (str.chaContextObservedTtft, '${usage.observedFirstTokenLatencyMs} ms'),
      if (s.sessionDuration != null)
        (str.sesMetricDuration, _formatDuration(s.sessionDuration!)),
      if (s.apiCallCount > 0) (str.sesMetricApiCalls, '${s.apiCallCount}'),
      if ((s.actualCostUsd ?? 0) > 0)
        (str.sesMetricCost, '\$${s.actualCostUsd!.toStringAsFixed(4)}')
      else if ((s.estimatedCostUsd ?? 0) > 0)
        (str.sesMetricCostEst, '\$${s.estimatedCostUsd!.toStringAsFixed(4)}'),
    ];

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final (label, value) in metrics)
          Container(
            width: (MediaQuery.of(context).size.width - 28 - 16) / 3,
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: colors.divider.withValues(alpha: 0.55)),
            ),
            child: Column(
              children: [
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: colors.accentHover,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  label,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 9,
                    letterSpacing: 0.6,
                    color: colors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  static String _compactNumber(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 10000) return '${(n / 1000).toStringAsFixed(0)}k';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return '$n';
  }

  // ── Tab: mensajes ──────────────────────────────────────────────────────

  Widget _buildMessagesTab(HermesThemeColors colors) {
    final str = Strings.of(context);
    if (_messages == null && _messagesError == null) {
      return Center(child: TuiLoader(label: str.sesLoadingMessages));
    }
    if (_messagesError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 36, color: colors.error),
              const SizedBox(height: 12),
              Text(
                str.sesMessagesError,
                style: TextStyle(fontSize: 14, color: colors.textPrimary),
              ),
              const SizedBox(height: 6),
              Text(
                _messagesError!,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11.5, color: colors.textSecondary),
              ),
              const SizedBox(height: 16),
              HermesSecondaryButton(
                label: str.sesMessagesRetry,
                icon: Icons.refresh,
                onTap: _refresh,
              ),
            ],
          ),
        ),
      );
    }
    final messages = _messages!;
    if (messages.isEmpty) {
      return Center(
        child: Text(
          str.sesNoMessages,
          style: TextStyle(fontSize: 12.5, color: colors.textDisabled),
        ),
      );
    }
    return RefreshIndicator(
      color: colors.accent,
      onRefresh: _refresh,
      child: ListView.builder(
        controller: _messagesScrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 20),
        itemCount: messages.length,
        itemBuilder: (_, i) => ChatAnswerAnchor(
          onLayout: (anchor) => _messageAnchors[i] = anchor,
          child: _MessageTile(message: messages[i]),
        ),
      ),
    );
  }

  // ── Tab: contexto ──────────────────────────────────────────────────────

  Widget _buildContextTab(HermesThemeColors colors) {
    final str = Strings.of(context);
    final s = _session;
    final usage = _contextMetrics;
    final rows = <(String, String, bool)>[
      // (label, valor, copiable)
      (str.sesCtxId, s.id, true),
      if (s.parentSessionId != null)
        (str.sesCtxBranchedFrom, s.parentSessionId!, true),
      (str.sesCtxModel, s.model.isNotEmpty ? s.model : '—', false),
      (str.sesCtxSource, s.source.isNotEmpty ? s.source : '—', false),
      (str.sesCtxInstance, widget.connection.label, false),
      (
        str.sesCtxCreated,
        s.startedAt > 0 ? _formatTimestamp(s.startedAt) : '—',
        false,
      ),
      if (s.updatedAt != null)
        (str.sesCtxLastActivity, _formatTimestamp(s.updatedAt!), false),
      if (s.endedAt != null)
        (str.sesCtxClosed, _formatTimestamp(s.endedAt!), false),
      if (s.endReason != null) (str.sesCtxCloseReason, s.endReason!, false),
      (
        str.sesCtxSystemPrompt,
        s.hasSystemPrompt
            ? str.sesCtxSystemPromptDefined
            : str.sesCtxSystemPromptNone,
        false,
      ),
      (
        str.chaContextObservedTtft,
        usage.observedFirstTokenLatencyMs == null
            ? str.chaContextNotMeasured
            : '${usage.observedFirstTokenLatencyMs} ms',
        false,
      ),
      (
        str.chaContextCacheRead,
        usage.cacheReadTokens == null
            ? str.chaContextNotPublished
            : _compactNumber(usage.cacheReadTokens!),
        false,
      ),
      (
        str.chaContextCacheWrite,
        usage.cacheWriteTokens == null
            ? str.chaContextNotPublished
            : _compactNumber(usage.cacheWriteTokens!),
        false,
      ),
      if (usage.cacheReadPercent != null)
        (
          str.sesMetricCachePercent,
          '${usage.cacheReadPercent!.toStringAsFixed(1)}%',
          false,
        ),
      if (s.reasoningTokens > 0)
        (str.sesCtxReasoningTokens, _compactNumber(s.reasoningTokens), false),
    ];

    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 24),
      children: [
        HermesSectionHeader(str.sesSectionContext),
        const SizedBox(height: 8),
        HermesCard(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Column(
            children: [
              for (final (label, value, copyable) in rows)
                InkWell(
                  onLongPress: copyable
                      ? () {
                          Clipboard.setData(ClipboardData(text: value));
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                Strings.of(context).sesCopiedMessage,
                              ),
                            ),
                          );
                        }
                      : null,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 118,
                          child: Text(
                            label,
                            style: TextStyle(
                              fontSize: 10.5,
                              letterSpacing: 0.4,
                              color: colors.textSecondary,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            value,
                            style: TextStyle(
                              fontSize: 11.5,
                              color: colors.textPrimary.withValues(alpha: 0.9),
                            ),
                          ),
                        ),
                        if (copyable)
                          Icon(
                            Icons.content_copy_outlined,
                            size: 12,
                            color: colors.textDisabled,
                          ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(
          Strings.of(context).sesCtxDisclaimer,
          style: TextStyle(fontSize: 10, color: colors.textDisabled),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Mensaje del transcript (read-only)
// ─────────────────────────────────────────────────────────────────────────────

class _MessageTile extends StatelessWidget {
  final Map<String, dynamic> message;

  const _MessageTile({required this.message});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final role = (message['role'] ?? '').toString();
    final content = (message['content'] ?? '').toString();
    final toolName = (message['tool_name'] ?? '').toString();
    final ts = message['timestamp'];

    final str = Strings.of(context);
    final isUser = role == 'user';
    final isTool = role == 'tool' || toolName.isNotEmpty;
    final label = isTool
        ? '${str.sesRoleTool}${toolName.isNotEmpty ? ' · $toolName' : ''}'
        : isUser
        ? str.sesRoleYou
        : str.sesRoleAgent;
    final accent = isUser
        ? colors.accent
        : isTool
        ? colors.textDisabled
        : colors.success;

    if (content.trim().isEmpty && !isTool) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onLongPress: content.isEmpty
            ? null
            : () {
                Clipboard.setData(ClipboardData(text: content));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(Strings.of(context).sesCopiedMessage)),
                );
              },
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(11),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: colors.divider.withValues(alpha: 0.55)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: accent,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 7),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 10,
                      letterSpacing: 0.6,
                      fontWeight: FontWeight.w600,
                      color: colors.textSecondary,
                    ),
                  ),
                  const Spacer(),
                  if (ts is num && ts > 0)
                    Text(
                      relativeTime(ts.toDouble()),
                      style: TextStyle(
                        fontSize: 9.5,
                        color: colors.textDisabled,
                      ),
                    ),
                ],
              ),
              if (content.trim().isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  content.length > 1200
                      ? '${content.substring(0, 1200)}…'
                      : content,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.45,
                    color: colors.textPrimary.withValues(alpha: 0.88),
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
