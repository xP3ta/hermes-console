// Mobile Cron manager aligned with the current Hermes Desktop contract.
//
// Canonical endpoints:
//   GET    /api/cron/jobs
//   GET    /api/cron/jobs/:id/runs
//   GET    /api/cron/delivery-targets
//   GET    /api/cron/blueprints
//   GET    /api/model/options
//   POST   /api/cron/jobs | /pause | /resume | /trigger
//   PUT    /api/cron/jobs/:id
//   DELETE /api/cron/jobs/:id
import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../main.dart';
import '../models/agent_profile.dart';
import '../models/cron_job.dart';
import '../models/dock_config.dart' show DockItemId;
import '../navigation/chat_route.dart';
import '../services/connection_manager.dart';
import '../services/cron_repository.dart';
import '../services/dock_preferences_store.dart';
import '../design/hermes_design.dart';
import '../services/notifications/notification_mute_store.dart';
import '../services/notifications/notification_service.dart';
import '../services/tui_gateway_client.dart';
import '../theme/app_theme.dart';
import '../utils/api_error.dart';
import '../widgets/feature_dependency_notice.dart';
import '../widgets/general_dock_shell.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/hermes_notice.dart';
import '../widgets/hermes_pill.dart' show TuiLoader;
import '../widgets/hermes_premium_ui.dart'
    show HermesSegment, HermesSegmentedControl;
import '../widgets/hermes_ui.dart' show HermesField;
import '../widgets/mission_profile_avatar.dart';
import '../widgets/read_only.dart';
import 'bridge_file_editor_screen.dart';
import 'cron_detail_page.dart';
import 'chat_screen.dart';
import 'instance_edit_screen.dart';
import 'notification_settings_screen.dart';

@visibleForTesting
const cronBackstopRefreshInterval = Duration(seconds: 60);

@visibleForTesting
bool isCronRefreshEvent(TuiGatewayEvent event) =>
    event.type == 'cron.changed' || event.type == 'sessions.changed';

class CronScreen extends StatefulWidget {
  final SavedConnection connection;
  final DashboardClient? clientOverride;
  final Stream<TuiGatewayEvent>? eventStreamOverride;
  final String? initialJobId;
  final String? profileOverride;
  final bool botRoutines;

  /// Cuando no es null, esta pantalla se envuelve con [GeneralDockShell]
  /// (mismo dock flotante que ya usan Ajustes y la lista de sesiones), con
  /// el "+" contextual abriendo un popover anclado en vez de navegar. Null
  /// en los call sites que todavía no tienen un `ConnectionManager` a mano
  /// (p.ej. dentro de una conversación abierta): la pantalla sigue
  /// funcionando igual, simplemente sin el dock.
  final ConnectionManager? connManager;

  const CronScreen({
    required this.connection,
    this.connManager,
    @visibleForTesting this.clientOverride,
    @visibleForTesting this.eventStreamOverride,
    this.initialJobId,
    this.profileOverride,
    this.botRoutines = false,
    super.key,
  });

  @override
  State<CronScreen> createState() => _CronScreenState();
}

class _CronScreenState extends State<CronScreen> with WidgetsBindingObserver {
  late final DashboardClient _client;
  late CronRepository _repository;
  final TextEditingController _searchController = TextEditingController();
  Timer? _refreshTimer;
  Timer? _eventRefreshDebounce;
  Timer? _eventReconnectTimer;
  Timer? _eventStableTimer;
  final GatewayReconnectBackoff _eventReconnectBackoff =
      GatewayReconnectBackoff();
  StreamSubscription<TuiGatewayEvent>? _eventSubscription;
  TuiGatewayClient? _ownedEventClient;
  Stream<TuiGatewayEvent>? _eventStream;
  List<CronJob> _jobs = const [];

  /// Bot profiles by name (title, face) for owner lines and destinations.
  Map<String, AgentProfile> _profiles = const {};
  MissionProfileAvatarCache? _avatarCache;
  String _profile = '';
  String _query = '';
  CronProfileScope _profileScope = CronProfileScope.active;
  String? _error;
  bool _loading = true;
  bool _fetching = false;
  bool _refreshQueued = false;
  bool _started = false;
  bool _foreground = true;
  bool _initialJobOpened = false;
  bool _legacyAllProfilesFallback = false;

  DashboardDependencyFailure _dependencyFailure =
      DashboardDependencyFailure.other;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _client = widget.clientOverride ?? DashboardClient.lazy(widget.connection);
    _repository = CronRepository(_client);
    _refreshTimer = Timer.periodic(cronBackstopRefreshInterval, (_) {
      if (_refreshAllowed && !_fetching) {
        unawaited(_loadJobs(showLoader: false));
      }
    });
    _startEventUpdates();
    final gateway = _ownedEventClient;
    if (gateway != null) {
      _avatarCache = MissionProfileAvatarCache(
        loader: gateway.profileAvatar,
        connectionId: widget.connection.id,
      );
    }
    unawaited(_loadProfiles());
  }

  /// Best effort: without profile metadata the owner line still shows the
  /// procedural face and a readable name. The gateway roster carries the
  /// Bot Mode title and face; the dashboard list is the fallback.
  Future<void> _loadProfiles() async {
    try {
      final gateway = _ownedEventClient;
      List<AgentProfile> profiles;
      try {
        profiles = gateway == null
            ? await _client.getProfiles()
            : await gateway.listProfiles();
      } catch (_) {
        profiles = await _client.getProfiles();
      }
      if (!mounted) return;
      setState(() => _profiles = {for (final p in profiles) p.name: p});
    } catch (_) {}
  }

  AgentProfile? _profileInfo(String name) => _profiles[name];

  bool get _refreshAllowed =>
      mounted && _foreground && ModalRoute.of(context)?.isCurrent != false;

  void _startEventUpdates() {
    final override = widget.eventStreamOverride;
    if (override != null) {
      _eventStream = override;
    } else if (widget.clientOverride == null) {
      final client = TuiGatewayClient(widget.connection);
      _ownedEventClient = client;
      _eventStream = client.events;
      unawaited(_connectEventClient());
    }
    _eventSubscription = _eventStream?.listen(
      _onDesktopEvent,
      onError: (_) {
        _eventStableTimer?.cancel();
        _eventStableTimer = null;
        _scheduleEventReconnect();
      },
    );
  }

  Future<void> _connectEventClient() async {
    final client = _ownedEventClient;
    if (client == null || client.isConnected) return;
    try {
      await client.connect();
      _eventStableTimer?.cancel();
      _eventStableTimer = Timer(GatewayReconnectBackoff.stableInterval, () {
        _eventStableTimer = null;
        if (_refreshAllowed) _eventReconnectBackoff.markHealthy();
      });
    } catch (_) {
      _scheduleEventReconnect();
    }
  }

  void _scheduleEventReconnect({bool immediate = false}) {
    final client = _ownedEventClient;
    if (!_refreshAllowed ||
        client == null ||
        client.isConnected ||
        _eventReconnectTimer != null) {
      return;
    }
    final delay = immediate
        ? Duration.zero
        : _eventReconnectBackoff.nextDelay();
    _eventReconnectTimer = Timer(delay, () {
      _eventReconnectTimer = null;
      if (_refreshAllowed) unawaited(_connectEventClient());
    });
  }

  void _onDesktopEvent(TuiGatewayEvent event) {
    if (!_refreshAllowed || !isCronRefreshEvent(event)) return;
    _eventRefreshDebounce?.cancel();
    _eventRefreshDebounce = Timer(const Duration(milliseconds: 350), () {
      if (mounted && _foreground) unawaited(_loadJobs(showLoader: false));
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final manager = context
        .findAncestorStateOfType<HermesAppState>()
        ?.connManager;
    final activeProfile = manager?.activeProfileFor(widget.connection.id) ?? '';
    final override = widget.profileOverride?.trim() ?? '';
    final profile = override.isNotEmpty ? override : activeProfile;
    if (!_started || profile != _profile) {
      _started = true;
      _profile = profile;
      _repository = CronRepository(
        _client,
        profile: profile,
        botRoutines: widget.botRoutines,
      );
      unawaited(_loadJobs(showLoader: true));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      _scheduleEventReconnect(immediate: true);
      if (!_fetching) unawaited(_loadJobs(showLoader: false));
    } else {
      _eventReconnectTimer?.cancel();
      _eventReconnectTimer = null;
      _eventStableTimer?.cancel();
      _eventStableTimer = null;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _refreshTimer?.cancel();
    _eventRefreshDebounce?.cancel();
    _eventReconnectTimer?.cancel();
    _eventStableTimer?.cancel();
    unawaited(_eventSubscription?.cancel());
    unawaited(_ownedEventClient?.close());
    _searchController.dispose();
    _client.close();
    super.dispose();
  }

  Future<void> _loadJobs({bool showLoader = false}) async {
    if (_fetching) {
      _refreshQueued = true;
      return;
    }
    _fetching = true;
    if (mounted && (showLoader || _jobs.isEmpty)) {
      setState(() {
        _loading = true;
        _error = null;
        _dependencyFailure = DashboardDependencyFailure.other;
      });
    }
    try {
      final listing = await _repository.listJobsForScope(_profileScope);
      final jobs = listing.jobs;
      if (!mounted) return;
      setState(() {
        _jobs = jobs;
        _loading = false;
        _error = null;
        _legacyAllProfilesFallback = listing.usedLegacyActiveFallback;
      });
      _openInitialJobIfAvailable(jobs);
    } catch (error) {
      if (!mounted) return;
      final message = localizedApiError(Strings.of(context), error);
      setState(() {
        _loading = false;
        _error = message;
        _dependencyFailure = classifyDashboardDependencyFailure(error);
      });
    } finally {
      _fetching = false;
      if (_refreshQueued && mounted) {
        _refreshQueued = false;
        unawaited(_loadJobs(showLoader: false));
      }
    }
  }

  bool get _mutationsDisabled =>
      widget.connection.readOnly || _profileScope == CronProfileScope.all;

  /// Explains why a mutation is blocked: a read-only instance, or only the
  /// aggregated "All profiles" view on an instance that is writable.
  void _showMutationsDisabledNotice() {
    if (widget.connection.readOnly) return showReadOnlyNotice(context);
    HermesNotice.of(context).showSnackBar(
      SnackBar(
        content: Text(
          Strings.of(context).crnAllScopeReadOnly,
          style: const TextStyle(fontSize: 13),
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  void _selectProfileScope(Set<CronProfileScope> selection) {
    final scope = selection.firstOrNull;
    if (scope == null || scope == _profileScope) return;
    setState(() {
      _profileScope = scope;
      _legacyAllProfilesFallback = false;
    });
    unawaited(_loadJobs(showLoader: true));
  }

  void _openInitialJobIfAvailable(List<CronJob> jobs) {
    final requested = widget.initialJobId?.trim();
    if (_initialJobOpened || requested == null || requested.isEmpty) return;
    for (final job in jobs) {
      if (job.id != requested && job.name != requested) continue;
      _initialJobOpened = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showJobDetail(job);
      });
      return;
    }
  }

  Future<void> _configureDependencies() async {
    final app = context.findAncestorStateOfType<HermesAppState>();
    if (app == null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => InstanceEditScreen(
          connManager: app.connManager,
          initial: widget.connection,
        ),
      ),
    );
    if (mounted) await _loadJobs(showLoader: true);
  }

  void _replaceJob(CronJob updated) {
    if (updated.id.isEmpty) {
      unawaited(_loadJobs(showLoader: false));
      return;
    }
    final index = _jobs.indexWhere((job) => job.id == updated.id);
    setState(() {
      if (index < 0) {
        _jobs = [..._jobs, updated];
      } else {
        final copy = [..._jobs];
        copy[index] = updated;
        _jobs = copy;
      }
    });
  }

  Future<void> _pauseOrResume(CronJob job) async {
    if (_mutationsDisabled) return _showMutationsDisabledNotice();
    try {
      final updated = await _repository.pauseOrResume(job);
      if (!mounted) return;
      _replaceJob(updated);
      HermesNotice.of(context).showSnackBar(
        SnackBar(
          content: Text(
            job.isPaused
                ? Strings.of(context).crnJobResumed
                : Strings.of(context).crnJobPaused,
          ),
        ),
      );
    } catch (error) {
      _showFailure(error);
    }
  }

  Future<void> _trigger(CronJob job) async {
    if (_mutationsDisabled) return _showMutationsDisabledNotice();
    try {
      final updated = await _repository.trigger(job);
      if (!mounted) return;
      _replaceJob(updated);
      HermesNotice.of(context).showSnackBar(
        SnackBar(content: Text(Strings.of(context).crnJobTriggered)),
        kind: HermesNoticeKind.success,
      );
    } catch (error) {
      _showFailure(error);
    }
  }

  void _showFailure(Object error) {
    if (!mounted) return;
    final s = Strings.of(context);
    HermesNotice.of(context).showSnackBar(
      SnackBar(
        content: Text(s.crnFailed(localizedApiError(s, error))),
        backgroundColor: Theme.of(context).hermes.warning,
      ),
      kind: HermesNoticeKind.error,
    );
  }

  Future<bool> _delete(CronJob job) async {
    if (_mutationsDisabled) {
      _showMutationsDisabledNotice();
      return false;
    }
    final s = Strings.of(context);
    final confirmed = await showHermesDialog<bool>(
      context: context,
      surfaceKey: const ValueKey('cron-delete-dialog'),
      title: s.crnDeleteTitle,
      message: s.crnDeleteConfirm(job.title),
      actions: [
        HermesDialogAction(
          label: s.commonCancel,
          value: false,
          style: HermesDialogActionStyle.cancel,
        ),
        HermesDialogAction(
          key: const ValueKey('cron-delete-confirm'),
          label: s.commonDelete,
          value: true,
          style: HermesDialogActionStyle.destructive,
        ),
      ],
    );
    if (confirmed != true || !mounted) return false;

    try {
      final manager = context
          .findAncestorStateOfType<HermesAppState>()
          ?.connManager;
      if (manager != null) {
        await manager.deleteLinkedCronJob(
          widget.connection,
          job.id,
          profile: _profile,
        );
      } else {
        await _client.deleteCronJob(job.id, profile: _profile);
      }
      if (!mounted) return true;
      setState(() => _jobs = _jobs.where((row) => row.id != job.id).toList());
      HermesNotice.of(context).showSnackBar(
        SnackBar(content: Text(Strings.of(context).crnJobDeleted(job.title))),
        kind: HermesNoticeKind.success,
      );
      return true;
    } on CronDeleteRejectedException {
      if (mounted) {
        HermesNotice.of(context).showSnackBar(
          SnackBar(
            content: Text(Strings.of(context).crnDeleteRejected),
            backgroundColor: Theme.of(context).hermes.warning,
          ),
          kind: HermesNoticeKind.warning,
        );
      }
    } catch (error) {
      if (!mounted) return false;
      final strings = Strings.of(context);
      HermesNotice.of(context).showSnackBar(
        SnackBar(
          content: Text(
            strings.crnDeleteFailed(localizedApiError(strings, error)),
          ),
          backgroundColor: Theme.of(context).hermes.warning,
        ),
        kind: HermesNoticeKind.error,
      );
    }
    return false;
  }

  NotificationService? get _notifications =>
      context.findAncestorStateOfType<HermesAppState>()?.notifications;

  /// Create/edit is a full page (spec 080): a long form never lives in a
  /// floating card; its pickers are floating surfaces.
  Future<CronJob?> _showEditor({CronJob? job}) async {
    if (_mutationsDisabled) {
      _showMutationsDisabledNotice();
      return null;
    }
    final notif = _notifications;
    final result = await Navigator.of(context).push<_CronEditorResult>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _CronEditorPage(
          repository: _repository,
          job: job,
          initialPolicy: job == null || notif == null
              ? CronNotifyPolicy.all
              : notif.muteStore.cronPolicy(
                  connId: widget.connection.id,
                  profile: job.profile.isNotEmpty ? job.profile : _profile,
                  jobId: job.id,
                ),
          notificationsAvailable: notif != null,
        ),
      ),
    );
    return _applyEditorResult(result, job);
  }

  /// The dock's contextual "+" opens the same editor page.
  Future<void> _showAnchoredEditor(GlobalKey anchorKey) async {
    await _showEditor();
  }

  Future<CronJob?> _applyEditorResult(
    _CronEditorResult? result,
    CronJob? job,
  ) async {
    if (result == null || !mounted) return null;
    try {
      final CronJob updated;
      switch (result) {
        case _ManualCronResult(:final values):
          updated = job == null
              ? await _repository.create(
                  name: values.name,
                  prompt: values.prompt,
                  schedule: values.schedule,
                  deliver: values.deliver,
                  model: values.model,
                  provider: values.provider,
                )
              : await _repository.update(
                  job,
                  name: values.name,
                  prompt: values.prompt,
                  schedule: values.schedule,
                  deliver: values.deliver,
                  model: values.model,
                  provider: values.provider,
                );
        case _BlueprintCronResult(:final blueprint, :final values):
          updated = await _repository.instantiateBlueprint(blueprint, values);
      }
      final notif = _notifications;
      final jobId = updated.id.isNotEmpty ? updated.id : job?.id ?? '';
      if (notif != null && jobId.isNotEmpty) {
        await notif.muteStore.setCronPolicy(
          connId: widget.connection.id,
          profile: updated.profile.isNotEmpty ? updated.profile : _profile,
          jobId: jobId,
          policy: result.policy,
        );
      }
      if (!mounted) return updated;
      _replaceJob(updated);
      HermesNotice.of(context).showSnackBar(
        SnackBar(
          content: Text(
            job == null
                ? Strings.of(context).crnJobCreated
                : Strings.of(context).crnJobUpdated,
          ),
        ),
      );
      unawaited(_loadJobs(showLoader: false));
      return updated;
    } catch (error) {
      if (!mounted) return null;
      final strings = Strings.of(context);
      final message = job == null
          ? strings.crnAddFailed(localizedApiError(strings, error))
          : strings.crnUpdateFailed(localizedApiError(strings, error));
      HermesNotice.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Theme.of(context).hermes.warning,
        ),
        kind: HermesNoticeKind.warning,
      );
      return null;
    }
  }

  Future<void> _openRun(Session session) async {
    await openChatFromHome<void>(
      context,
      builder: (_) =>
          ChatScreen(connection: widget.connection, session: session),
    );
  }

  Future<void> _showJobDetail(CronJob job) async {
    final detailRepository =
        _profileScope == CronProfileScope.all && job.profile.isNotEmpty
        ? CronRepository(_client, profile: job.profile)
        : _repository;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => CronJobDetailPage(
          initialJob: job,
          repository: detailRepository,
          readOnly: _mutationsDisabled,
          eventStream: _eventStream,
          connectionId: widget.connection.id,
          profile: _profile,
          notifications: _notifications,
          onEdit: (current) => _showEditor(job: current),
          onDelete: _delete,
          onChanged: _replaceJob,
          onOpenRun: _openRun,
          profileInfo: _profileInfo,
          avatarCache: _avatarCache,
          onOpenNotificationSettings: () => Navigator.of(context).push<void>(
            MaterialPageRoute(
              builder: (_) => const NotificationSettingsScreen(),
            ),
          ),
        ),
      ),
    );
    if (mounted) unawaited(_loadJobs(showLoader: false));
  }

  Future<void> _showJobMenu(CronJob job, BuildContext anchor) async {
    final s = Strings.of(context);
    final action = await showHermesMenu<String>(
      context: context,
      originRect: hermesOriginOf(anchor),
      surfaceKey: ValueKey('cron-job-menu-surface-${job.id}'),
      actions: [
        HermesAction(
          value: 'trigger',
          icon: Icons.play_arrow_rounded,
          label: s.crnRunNow,
        ),
        HermesAction(
          value: 'edit',
          icon: Icons.edit_outlined,
          label: s.commonEdit,
        ),
        HermesAction(
          value: 'toggle',
          icon: job.isPaused
              ? Icons.play_circle_outline
              : Icons.pause_circle_outline,
          label: job.isPaused ? s.crnResume : s.crnPause,
        ),
        HermesAction(
          value: 'delete',
          icon: Icons.delete_outline_rounded,
          label: s.commonDelete,
          destructive: true,
        ),
      ],
    );
    switch (action) {
      case 'trigger':
        await _trigger(job);
      case 'edit':
        await _showEditor(job: job);
      case 'toggle':
        await _pauseOrResume(job);
      case 'delete':
        await _delete(job);
    }
  }

  Future<void> _showScreenMenu(BuildContext anchor) async {
    final s = Strings.of(context);
    final action = await showHermesMenu<String>(
      context: context,
      originRect: hermesOriginOf(anchor),
      surfaceKey: const ValueKey('cron-screen-menu'),
      actions: [
        HermesAction(
          value: 'raw',
          icon: Icons.data_object_rounded,
          label: s.crnEditJobsJson,
        ),
      ],
    );
    if (action != 'raw' || !mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => BridgeFileEditorScreen(
          connectionId: widget.connection.id,
          target: 'cron',
          titleLabel: s.crnJobsJsonLabel,
          readOnly: widget.connection.readOnly,
          lockReason: s.crnApplyJobsJson,
        ),
      ),
    );
  }

  List<CronJob> get _visibleJobs {
    final query = _query.trim().toLowerCase();
    final rows = query.isEmpty
        ? [..._jobs]
        : _jobs.where((job) {
            final s = Strings.of(context);
            return [
              job.title,
              job.preview,
              cronScheduleLabel(s, job),
              job.scheduleExpression,
              cronDeliveryLabel(job.deliver, s, ownProfile: job.profile),
              job.profile,
              if (job.ownerBot != null)
                cronBotName(job.ownerBot!, info: _profiles[job.ownerBot]),
            ].any((value) => value.toLowerCase().contains(query));
          }).toList();
    rows.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    return Scaffold(
      appBar: HermesAppBar(
        centerTitle: false,
        title: Text(s.crnTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (widget.connection.readOnly)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Center(
                child: HermesTag(
                  label: _capitalize(s.statusReadOnly),
                  tone: HermesStatusTone.warn,
                ),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: s.crnRetry,
            onPressed: _fetching ? null : () => _loadJobs(showLoader: false),
          ),
          if (_profileScope == CronProfileScope.active)
            Builder(
              builder: (anchor) => IconButton(
                key: const ValueKey('cron-screen-more'),
                tooltip: MaterialLocalizations.of(context).moreButtonTooltip,
                icon: const Icon(Icons.more_vert_rounded),
                onPressed: () => _showScreenMenu(anchor),
              ),
            ),
        ],
      ),
      body: _wrapWithDock(_buildBody()),
      // Con el dock activo y presente, su "+" contextual reemplaza a este FAB.
      // Con el interruptor global "Usar dock flotante" apagado, el FAB debe
      // reaparecer o la única forma de crear un cron job desaparecería.
      floatingActionButton: ListenableBuilder(
        listenable: DockPreferencesController.instance.listenable,
        builder: (context, _) {
          final dockActive =
              widget.connManager != null &&
              DockPreferencesController.instance.value.useDock;
          if (dockActive || _mutationsDisabled) return const SizedBox.shrink();
          return FloatingActionButton(
            tooltip: s.crnAddNew,
            onPressed: _loading ? null : () => _showEditor(),
            child: const Icon(Icons.add),
          );
        },
      ),
    );
  }

  Widget _wrapWithDock(Widget body) {
    final connManager = widget.connManager;
    if (connManager == null) return body;
    return GeneralDockShell(
      connection: widget.connection,
      connManager: connManager,
      onCreateAnchored: _showAnchoredEditor,
      currentDestination: DockItemId.cron,
      body: body,
    );
  }

  Widget _scopeHeader() {
    final s = Strings.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: HermesSpace.x2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HermesSegmentedControl<CronProfileScope>(
            key: const ValueKey('cron-profile-scope'),
            value: _profileScope,
            onChanged: (scope) => _selectProfileScope({scope}),
            segments: [
              HermesSegment(
                value: CronProfileScope.active,
                label: s.crnScopeThisProfile,
              ),
              HermesSegment(value: CronProfileScope.all, label: s.crnScopeAll),
            ],
          ),
          if (_profileScope == CronProfileScope.all) ...[
            const SizedBox(height: HermesSpace.x2),
            HermesInlineNotice(
              key: const ValueKey('cron-profile-all-readonly'),
              icon: Icons.visibility_outlined,
              message: _capitalize(s.statusReadOnly),
            ),
          ],
          if (_legacyAllProfilesFallback)
            HermesInlineNotice(
              key: const ValueKey('cron-profile-all-legacy'),
              message: '${s.commonNotAvailable} · ${s.crnScopeThisProfile}',
            ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    final s = Strings.of(context);
    if (_loading && _jobs.isEmpty) return const Center(child: TuiLoader());

    if (_error != null && _jobs.isEmpty) {
      final needsDashboard =
          _dependencyFailure == DashboardDependencyFailure.credentials;
      return Padding(
        padding: const EdgeInsets.all(20),
        child: FeatureDependencyNotice(
          noticeId:
              'cron-${needsDashboard ? 'dashboard' : 'load'}-${widget.connection.id}',
          kind: needsDashboard
              ? FeatureDependencyKind.dashboard
              : FeatureDependencyKind.gateway,
          title: needsDashboard
              ? s.dependencyDashboardTitle
              : s.dependencyLoadFailedTitle,
          message: needsDashboard
              ? s.dependencyDashboardBody
              : s.dependencyLoadFailedBody(_error!),
          primaryActionLabel: needsDashboard ? s.dependencyConfigure : null,
          onPrimaryAction: needsDashboard ? _configureDependencies : null,
          retryLabel: s.dependencyRetry,
          onRetry: () => _loadJobs(showLoader: true),
          dismissible: false,
        ),
      );
    }

    final jobs = _visibleJobs;
    final notif = _notifications;
    return RefreshIndicator(
      onRefresh: () => _loadJobs(showLoader: false),
      child: ListView(
        key: const ValueKey('cron-list'),
        padding: EdgeInsets.fromLTRB(
          HermesSpace.pageH,
          HermesSpace.pageTop,
          HermesSpace.pageH,
          96 + MediaQuery.paddingOf(context).bottom,
        ),
        children: [
          _scopeHeader(),
          if (_jobs.isEmpty)
            HermesEmptyStateView(
              icon: Icons.schedule_outlined,
              title: s.crnEmpty,
              body: s.crnCreateDescription,
              actionLabel: _mutationsDisabled ? null : s.crnAddJob,
              onAction: _mutationsDisabled ? null : () => _showEditor(),
            )
          else ...[
            TextField(
              key: const ValueKey('cron-search'),
              controller: _searchController,
              onChanged: (value) => setState(() => _query = value),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: s.crnSearch,
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _query = '');
                        },
                        icon: const Icon(Icons.close, size: 18),
                      ),
              ),
            ),
            const SizedBox(height: HermesSpace.x3),
            if (jobs.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 48),
                child: Text(
                  s.designNoMatches,
                  textAlign: TextAlign.center,
                  style: HermesType.support.copyWith(
                    color: Theme.of(context).hermes.textSecondary,
                  ),
                ),
              )
            else
              HermesListGroup(
                dividerIndent: HermesSpace.rowH,
                children: [
                  for (final job in jobs)
                    _CronJobRow(
                      key: ValueKey('cron-job-${job.id}'),
                      job: job,
                      readOnly: _mutationsDisabled,
                      notifies:
                          notif == null ||
                          notif.muteStore.cronPolicy(
                                connId: widget.connection.id,
                                profile: job.profile.isNotEmpty
                                    ? job.profile
                                    : _profile,
                                jobId: job.id,
                              ) !=
                              CronNotifyPolicy.off,
                      showProfile: _profileScope == CronProfileScope.all,
                      profileInfo: _profileInfo,
                      avatarCache: _avatarCache,
                      onTap: () => _showJobDetail(job),
                      onMenu: (anchor) => _showJobMenu(job, anchor),
                    ),
                ],
              ),
          ],
        ],
      ),
    );
  }
}

String _capitalize(String v) =>
    v.isEmpty ? v : v[0].toUpperCase() + v.substring(1);

/// Editorial job row: title, inline status + schedule, one-line preview.
class _CronJobRow extends StatelessWidget {
  final CronJob job;
  final bool readOnly;
  final bool notifies;
  final bool showProfile;
  final AgentProfile? Function(String profile) profileInfo;
  final MissionProfileAvatarCache? avatarCache;
  final VoidCallback onTap;
  final ValueChanged<BuildContext> onMenu;

  const _CronJobRow({
    super.key,
    required this.job,
    required this.readOnly,
    required this.notifies,
    required this.showProfile,
    required this.profileInfo,
    required this.avatarCache,
    required this.onTap,
    required this.onMenu,
  });

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final status = cronStatusOf(s, job);
    // Status + human schedule only: the next run lives in the detail header,
    // which keeps every row within the three-line budget.
    final meta = cronScheduleLabel(s, job);
    final owner = job.ownerBot;
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 64),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(HermesSpace.rowH, 10, 2, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            job.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: HermesType.body.copyWith(
                              color: colors.textPrimary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (!notifies) ...[
                          const SizedBox(width: 6),
                          Icon(
                            Icons.notifications_off_outlined,
                            size: 15,
                            color: colors.textDisabled,
                            semanticLabel: s.crnNotifyFinish,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    HermesStatusText(
                      label: status.label,
                      tone: status.tone,
                      meta: meta.isEmpty ? null : meta,
                      // The schedule is the row's point: wrap, never cut.
                      maxLines: 2,
                    ),
                    if (owner != null) ...[
                      const SizedBox(height: 3),
                      // Line 3: the owner bot's face + name, then the task.
                      CronOwnerLine(
                        key: ValueKey('cron-job-owner-${job.id}'),
                        profile: owner,
                        info: profileInfo(owner),
                        avatarCache: avatarCache,
                        faceSize: 16,
                        trailing: job.preview.isEmpty
                            ? null
                            : Session.stripCronPreamble(job.preview),
                      ),
                    ] else if (job.preview.isNotEmpty || showProfile) ...[
                      const SizedBox(height: 2),
                      Text(
                        [
                          if (showProfile && job.profile.isNotEmpty)
                            cronBotName(
                              job.profile,
                              info: profileInfo(job.profile),
                            ),
                          if (job.preview.isNotEmpty) job.preview,
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HermesType.support.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (!readOnly)
                Builder(
                  builder: (anchor) => IconButton(
                    key: ValueKey('cron-job-menu-${job.id}'),
                    tooltip: s.crnMore,
                    icon: Icon(
                      Icons.more_vert_rounded,
                      color: colors.textSecondary,
                    ),
                    onPressed: () => onMenu(anchor),
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.only(top: 12, right: 10),
                  child: Icon(
                    Icons.chevron_right_rounded,
                    size: 18,
                    color: colors.textDisabled,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

sealed class _CronEditorResult {
  final CronNotifyPolicy policy;
  const _CronEditorResult(this.policy);
}

class _ManualCronResult extends _CronEditorResult {
  final _CronEditorValues values;
  const _ManualCronResult(this.values, super.policy);
}

class _BlueprintCronResult extends _CronEditorResult {
  final AutomationBlueprint blueprint;
  final Map<String, String> values;
  const _BlueprintCronResult(this.blueprint, this.values, super.policy);
}

class _CronEditorValues {
  final String name;
  final String prompt;
  final String schedule;
  final String deliver;
  final String model;
  final String provider;

  const _CronEditorValues({
    required this.name,
    required this.prompt,
    required this.schedule,
    required this.deliver,
    required this.model,
    required this.provider,
  });
}

/// Create/edit page (spec 080): text fields, select rows opening floating
/// pickers, the schedule builder for "When", and the notification toggles.
class _CronEditorPage extends StatefulWidget {
  final CronRepository repository;
  final CronJob? job;
  final CronNotifyPolicy initialPolicy;
  final bool notificationsAvailable;

  const _CronEditorPage({
    required this.repository,
    required this.initialPolicy,
    required this.notificationsAvailable,
    this.job,
  });

  @override
  State<_CronEditorPage> createState() => _CronEditorPageState();
}

class _CronEditorPageState extends State<_CronEditorPage> {
  static const _defaultModel = HermesModelChoice.defaultModel();

  late final TextEditingController _nameController;
  late final TextEditingController _promptController;
  CronEditorResources? _resources;
  AutomationBlueprint? _blueprint;
  Map<String, String> _blueprintValues = {};
  bool _loadingResources = true;
  late String _schedule;
  late String _deliver;
  late HermesModelChoice _model;
  late CronNotifyPolicy _policy;
  String? _error;

  bool get _editing => widget.job != null;
  bool get _scriptOnly => widget.job?.isScriptOnly == true;

  @override
  void initState() {
    super.initState();
    final job = widget.job;
    // The technical `[bot:<name>]` owner prefix is kept out of the field and
    // restored on save.
    _nameController = TextEditingController(
      text: job == null ? '' : CronJob.displayName(job.name),
    );
    _promptController = TextEditingController(text: job?.prompt ?? '');
    _schedule = job?.scheduleExpression.isNotEmpty == true
        ? job!.scheduleExpression
        : '0 9 * * *';
    _deliver = job?.deliver.isNotEmpty == true
        ? job!.deliver
        : widget.repository.botRoutines
        ? 'bot-chat'
        : 'local';
    _model = job?.model.isNotEmpty == true
        ? HermesModelChoice(job!.provider, job.model)
        : _defaultModel;
    _policy = widget.initialPolicy;
    unawaited(_loadResources());
  }

  Future<void> _loadResources() async {
    try {
      final resources = await widget.repository.editorResources();
      if (!mounted) return;
      setState(() {
        _resources = resources;
        _loadingResources = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _resources = const CronEditorResources(
          deliveryTargets: [CronDeliveryTarget.local],
          modelProviders: [],
          blueprints: [],
        );
        _loadingResources = false;
        _error = localizedApiError(Strings.of(context), error);
      });
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _promptController.dispose();
    super.dispose();
  }

  List<CronDeliveryTarget> get _targets {
    final targets = [...?_resources?.deliveryTargets];
    if (!targets.any((target) => target.id == _deliver)) {
      targets.add(
        CronDeliveryTarget(id: _deliver, name: _deliver, homeTargetSet: true),
      );
    }
    return targets;
  }

  Future<void> _pickTemplate(BuildContext anchor) async {
    final s = Strings.of(context);
    const custom = '__custom__';
    final picked = await showHermesOptions<String>(
      context: context,
      surfaceKey: const ValueKey('cron-template-surface'),
      originRect: hermesOriginOf(anchor),
      title: s.crnStartFrom,
      selected: _blueprint?.key ?? custom,
      options: [
        HermesOption(value: custom, label: s.crnCustomSetup),
        for (final item in _resources!.blueprints)
          HermesOption(
            value: item.key,
            label: item.title,
            subtitle: item.description,
          ),
      ],
    );
    if (picked == null || !mounted) return;
    setState(() {
      _error = null;
      if (picked == custom) {
        _blueprint = null;
        _blueprintValues = {};
      } else {
        _blueprint = _resources!.blueprints.firstWhere((b) => b.key == picked);
        _blueprintValues = _blueprint!.initialValues();
      }
    });
  }

  Future<void> _pickSchedule() async {
    final cron = await showHermesScheduleBuilder(
      context,
      initialCron: _schedule,
    );
    if (cron != null && mounted) {
      setState(() {
        _schedule = cron;
        _error = null;
      });
    }
  }

  Future<String?> _pickDelivery(BuildContext anchor, String current) {
    final s = Strings.of(context);
    return showHermesOptions<String>(
      context: context,
      surfaceKey: const ValueKey('cron-delivery-surface'),
      originRect: hermesOriginOf(anchor),
      title: s.crnDeliveryLabel,
      selected: current,
      options: [
        for (final target in _targets)
          HermesOption(
            key: ValueKey('cron-delivery-${target.id}'),
            value: target.id,
            label: _deliveryTargetLabel(target, s),
          ),
      ],
    );
  }

  Future<void> _pickModel(BuildContext anchor) async {
    final s = Strings.of(context);
    final groups = [
      for (final provider
          in _resources?.modelProviders ?? const <ModelProvider>[])
        if (provider.models.isNotEmpty)
          HermesModelGroup(
            slug: provider.slug,
            name: provider.name,
            models: provider.models,
          ),
    ];
    final picked = await showHermesModelPicker(
      context: context,
      surfaceKey: const ValueKey('cron-model-picker'),
      keyPrefix: 'cron-model',
      originRect: hermesOriginOf(anchor),
      title: s.crnModelLabel,
      defaultLabel: s.crnModelDefault,
      current: _model,
      groups: groups,
    );
    if (picked != null && mounted) setState(() => _model = picked);
  }

  String _ownedName(String name) {
    final owner = widget.job?.ownerBot;
    if (owner == null || name.isEmpty) return name;
    return '[bot:$owner] $name';
  }

  void _submit() {
    final s = Strings.of(context);
    if (_blueprint != null) {
      for (final field in _blueprint!.fields) {
        if (!field.optional &&
            (_blueprintValues[field.name] ?? '').trim().isEmpty) {
          setState(() => _error = s.crnFieldRequired);
          return;
        }
      }
      Navigator.pop(
        context,
        _BlueprintCronResult(_blueprint!, Map.of(_blueprintValues), _policy),
      );
      return;
    }
    final prompt = _promptController.text.trim();
    final schedule = _schedule.trim();
    if (schedule.isEmpty) {
      setState(() => _error = s.crnScheduleRequired);
      return;
    }
    if (prompt.isEmpty && !_scriptOnly) {
      setState(() => _error = s.crnPromptRequired);
      return;
    }
    Navigator.pop(
      context,
      _ManualCronResult(
        _CronEditorValues(
          name: _ownedName(_nameController.text.trim()),
          prompt: prompt,
          schedule: schedule,
          deliver: _deliver,
          model: _model.isDefault ? '' : _model.model,
          provider: _model.isDefault ? '' : _model.provider,
        ),
        _policy,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    return Scaffold(
      appBar: HermesAppBar(
        centerTitle: false,
        leading: IconButton(
          tooltip: s.commonCancel,
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(_editing ? s.crnEditJob : s.crnAddJob),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: FilledButton(
              key: const ValueKey('cron-editor-submit'),
              onPressed: _loadingResources ? null : _submit,
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(HermesRadius.control),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 18),
              ),
              child: Text(
                _blueprint != null
                    ? s.crnBlueprintCreate
                    : (_editing ? s.commonSave : s.crnAdd),
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: _loadingResources
            ? const Center(child: TuiLoader())
            : ListView(
                key: const ValueKey('cron-editor'),
                padding: const EdgeInsets.fromLTRB(
                  HermesSpace.pageH,
                  HermesSpace.pageTop,
                  HermesSpace.pageH,
                  HermesSpace.pageBottom + 24,
                ),
                children: [
                  if (!_editing &&
                      (_resources?.blueprints.isNotEmpty ?? false)) ...[
                    HermesListGroup(
                      children: [
                        Builder(
                          builder: (anchor) => HermesSelectRow(
                            key: const ValueKey('cron-template-row'),
                            icon: Icons.auto_awesome_outlined,
                            title: s.crnStartFrom,
                            value: _blueprint?.title ?? s.crnCustomSetup,
                            subtitle: _blueprint?.description,
                            onTap: () => _pickTemplate(anchor),
                          ),
                        ),
                      ],
                    ),
                  ],
                  if (_blueprint != null)
                    ..._buildBlueprintFields()
                  else
                    ..._buildManualFields(),
                  HermesSectionHeader(s.crnNotifications),
                  HermesListGroup(
                    dividerIndent: HermesSpace.rowH,
                    children: [
                      HermesToggleRow(
                        switchKey: const ValueKey('cron-editor-notify'),
                        title: s.crnNotifyFinish,
                        value: _policy != CronNotifyPolicy.off,
                        onChanged: widget.notificationsAvailable
                            ? (v) => setState(
                                () => _policy = v
                                    ? CronNotifyPolicy.all
                                    : CronNotifyPolicy.off,
                              )
                            : null,
                      ),
                      HermesToggleRow(
                        switchKey: const ValueKey('cron-editor-notify-fail'),
                        title: s.crnNotifyFailOnly,
                        value: _policy == CronNotifyPolicy.failuresOnly,
                        onChanged:
                            widget.notificationsAvailable &&
                                _policy != CronNotifyPolicy.off
                            ? (v) => setState(
                                () => _policy = v
                                    ? CronNotifyPolicy.failuresOnly
                                    : CronNotifyPolicy.all,
                              )
                            : null,
                      ),
                    ],
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: HermesSpace.x3),
                    HermesInlineNotice(
                      key: const ValueKey('cron-editor-error'),
                      icon: Icons.error_outline_rounded,
                      tone: HermesStatusTone.error,
                      message: _error!,
                    ),
                  ],
                ],
              ),
      ),
    );
  }

  List<Widget> _buildManualFields() {
    final s = Strings.of(context);
    final schedule = HermesSchedule.parse(_schedule);
    final next = schedule.nextRun(DateTime.now());
    final hasModels = (_resources?.modelProviders ?? const <ModelProvider>[])
        .any((p) => p.models.isNotEmpty);
    return [
      const SizedBox(height: HermesSpace.x3),
      HermesField(
        key: const ValueKey('cron-name-field'),
        controller: _nameController,
        label: s.crnFieldName,
        hint: s.crnFieldNameHint,
      ),
      const SizedBox(height: 14),
      if (_scriptOnly) ...[
        HermesInlineNotice(message: s.crnScriptOnlyHint),
        const SizedBox(height: 10),
      ],
      HermesField(
        key: const ValueKey('cron-prompt-field'),
        controller: _promptController,
        label: s.crnPromptLabel,
        hint: s.crnFieldPromptHint,
        minLines: 3,
        maxLines: 8,
      ),
      HermesSectionHeader(s.crnWhen),
      HermesListGroup(
        children: [
          HermesListRow(
            key: const ValueKey('cron-schedule-row'),
            icon: Icons.schedule_rounded,
            title: schedule.describe(s),
            subtitle: next == null
                ? null
                : s.schNextRun(hermesFormatNextRun(s, next)),
            onTap: _pickSchedule,
          ),
        ],
      ),
      HermesSectionHeader(s.crnDetails),
      HermesListGroup(
        children: [
          Builder(
            builder: (anchor) => HermesSelectRow(
              key: const ValueKey('cron-delivery-row'),
              icon: Icons.send_outlined,
              title: s.crnDeliveryLabel,
              value: _deliveryTargetLabel(
                _targets.firstWhere((t) => t.id == _deliver),
                s,
              ),
              onTap: () async {
                final picked = await _pickDelivery(anchor, _deliver);
                if (picked != null && mounted) {
                  setState(() => _deliver = picked);
                }
              },
            ),
          ),
          if (!_scriptOnly)
            Builder(
              builder: (anchor) => HermesSelectRow(
                key: const ValueKey('cron-model-row'),
                icon: Icons.memory_rounded,
                title: s.crnModelLabel,
                value: _model.isDefault ? s.crnModelDefault : _model.model,
                subtitle: hasModels ? null : s.crnModelUnavailable,
                onTap: () => _pickModel(anchor),
              ),
            ),
        ],
      ),
    ];
  }

  List<Widget> _buildBlueprintFields() {
    final s = Strings.of(context);
    final rows = <Widget>[];
    final texts = <Widget>[];
    for (final field in _blueprint!.fields) {
      final value = _blueprintValues[field.name] ?? '';
      if (field.name == 'deliver') {
        rows.add(
          Builder(
            builder: (anchor) => HermesSelectRow(
              key: ValueKey('${_blueprint!.key}-${field.name}'),
              title: field.label,
              subtitle: field.help.isEmpty ? null : field.help,
              value: _deliveryTargetLabel(
                _targets.firstWhere(
                  (t) => t.id == value,
                  orElse: () => CronDeliveryTarget.local,
                ),
                s,
              ),
              onTap: () async {
                final picked = await _pickDelivery(anchor, value);
                if (picked != null && mounted) {
                  setState(() => _blueprintValues[field.name] = picked);
                }
              },
            ),
          ),
        );
      } else if (field.type == AutomationBlueprintFieldType.time) {
        rows.add(
          HermesSelectRow(
            key: ValueKey('${_blueprint!.key}-${field.name}'),
            icon: Icons.schedule_rounded,
            title: field.label,
            subtitle: field.help.isEmpty ? null : field.help,
            value: value.isEmpty ? '09:00' : value,
            onTap: () async {
              final parts = (value.isEmpty ? '09:00' : value).split(':');
              final initial = TimeOfDay(
                hour: int.tryParse(parts.first) ?? 9,
                minute: parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0,
              );
              final picked = await showHermesTimePicker(context, initial);
              if (picked != null && mounted) {
                setState(
                  () => _blueprintValues[field.name] =
                      HermesSchedule.formatTime24(picked.hour, picked.minute),
                );
              }
            },
          ),
        );
      } else if (field.type == AutomationBlueprintFieldType.enumValue ||
          field.type == AutomationBlueprintFieldType.weekdays) {
        final options = [...field.options];
        if (value.isNotEmpty && !options.contains(value)) {
          options.insert(0, value);
        }
        rows.add(
          Builder(
            builder: (anchor) => HermesSelectRow(
              key: ValueKey('${_blueprint!.key}-${field.name}'),
              title: field.label,
              subtitle: field.help.isEmpty ? null : field.help,
              value: value,
              onTap: () async {
                final picked = await showHermesOptions<String>(
                  context: context,
                  originRect: hermesOriginOf(anchor),
                  title: field.label,
                  selected: value,
                  options: [
                    for (final option in options)
                      HermesOption(value: option, label: option),
                  ],
                );
                if (picked != null && mounted) {
                  setState(() => _blueprintValues[field.name] = picked);
                }
              },
            ),
          ),
        );
      } else {
        texts.add(
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: TextFormField(
              key: ValueKey('${_blueprint!.key}-${field.name}'),
              initialValue: value,
              decoration: InputDecoration(
                labelText: field.label,
                hintText: field.help.isEmpty ? null : field.help,
              ),
              onChanged: (next) => _blueprintValues[field.name] = next,
            ),
          ),
        );
      }
    }
    return [
      ...texts,
      if (rows.isNotEmpty) ...[
        HermesSectionHeader(s.crnDetails),
        HermesListGroup(dividerIndent: HermesSpace.rowH, children: rows),
      ],
    ];
  }
}

String _deliveryTargetLabel(CronDeliveryTarget target, Strings s) {
  final base = target.id == 'local'
      ? s.crnDeliveryLocal
      : target.id.startsWith('bot-chat') || target.id == target.name
      ? cronDeliveryLabel(target.id, s)
      : target.name;
  return target.id != 'local' && !target.homeTargetSet
      ? '$base — ${s.crnDeliveryNeedsHome}'
      : base;
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
