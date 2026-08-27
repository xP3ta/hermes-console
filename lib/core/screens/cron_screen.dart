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
import '../models/cron_job.dart';
import '../navigation/chat_route.dart';
import '../services/connection_manager.dart';
import '../services/cron_repository.dart';
import '../services/session_deletion.dart';
import '../services/tui_gateway_client.dart';
import '../theme/app_theme.dart';
import '../utils/api_error.dart';
import '../widgets/accent_card.dart';
import '../widgets/feature_dependency_notice.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/hermes_pill.dart';
import '../widgets/hermes_premium_ui.dart';
import '../widgets/hermes_ui.dart';
import '../widgets/read_only.dart';
import 'bridge_file_editor_screen.dart';
import 'chat_screen.dart';
import 'instance_edit_screen.dart';
import 'lock_screen.dart';

@visibleForTesting
const cronBackstopRefreshInterval = Duration(seconds: 60);

@visibleForTesting
bool isCronRefreshEvent(TuiGatewayEvent event) =>
    event.type == 'cron.changed' || event.type == 'sessions.changed';

class CronScreen extends StatefulWidget {
  final SavedConnection connection;
  final DashboardClient? clientOverride;
  final Stream<TuiGatewayEvent>? eventStreamOverride;
  @visibleForTesting
  final Future<bool> Function()? verifyHistoryCleanupForTesting;
  final String? initialJobId;
  final String? profileOverride;

  const CronScreen({
    required this.connection,
    @visibleForTesting this.clientOverride,
    @visibleForTesting this.eventStreamOverride,
    @visibleForTesting this.verifyHistoryCleanupForTesting,
    this.initialJobId,
    this.profileOverride,
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
  StreamSubscription<TuiGatewayEvent>? _eventSubscription;
  TuiGatewayClient? _ownedEventClient;
  Stream<TuiGatewayEvent>? _eventStream;
  List<CronJob> _jobs = const [];
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
  bool _cleaningConversations = false;
  DashboardDependencyFailure _dependencyFailure =
      DashboardDependencyFailure.other;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _client = widget.clientOverride ?? DashboardClient.lazy(widget.connection);
    _repository = CronRepository(_client);
    _refreshTimer = Timer.periodic(cronBackstopRefreshInterval, (_) {
      if (_foreground && !_fetching) unawaited(_loadJobs(showLoader: false));
    });
    _startEventUpdates();
  }

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
        // El backstop y el refresh manual siguen disponibles en legacy/offline.
      },
    );
  }

  Future<void> _connectEventClient() async {
    final client = _ownedEventClient;
    if (client == null || client.isConnected) return;
    try {
      await client.connect();
    } catch (_) {
      // Un Dashboard sin WebSocket conserva el contrato REST y el backstop.
    }
  }

  void _onDesktopEvent(TuiGatewayEvent event) {
    if (!_foreground || !isCronRefreshEvent(event)) return;
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
      _repository = CronRepository(_client, profile: profile);
      unawaited(_loadJobs(showLoader: true));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      unawaited(_connectEventClient());
      if (!_fetching) unawaited(_loadJobs(showLoader: false));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _refreshTimer?.cancel();
    _eventRefreshDebounce?.cancel();
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
    if (_mutationsDisabled) return showReadOnlyNotice(context);
    try {
      final updated = await _repository.pauseOrResume(job);
      if (!mounted) return;
      _replaceJob(updated);
      ScaffoldMessenger.of(context).showSnackBar(
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
    if (_mutationsDisabled) return showReadOnlyNotice(context);
    try {
      final updated = await _repository.trigger(job);
      if (!mounted) return;
      _replaceJob(updated);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(Strings.of(context).crnJobTriggered)),
      );
    } catch (error) {
      _showFailure(error);
    }
  }

  void _showFailure(Object error) {
    if (!mounted) return;
    final s = Strings.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(s.crnFailed(localizedApiError(s, error))),
        backgroundColor: Theme.of(context).hermes.warning,
      ),
    );
  }

  Future<void> _delete(CronJob job) async {
    if (_mutationsDisabled) return showReadOnlyNotice(context);
    final s = Strings.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(s.crnDeleteTitle),
        content: Text(s.crnDeleteConfirm(job.title)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(s.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).hermes.error,
            ),
            child: Text(s.commonDelete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

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
      if (!mounted) return;
      setState(() => _jobs = _jobs.where((row) => row.id != job.id).toList());
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(Strings.of(context).crnJobDeleted(job.title))),
      );
    } on CronDeleteRejectedException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(Strings.of(context).crnDeleteRejected),
            backgroundColor: Theme.of(context).hermes.warning,
          ),
        );
      }
    } catch (error) {
      if (!mounted) return;
      final strings = Strings.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            strings.crnDeleteFailed(localizedApiError(strings, error)),
          ),
          backgroundColor: Theme.of(context).hermes.warning,
        ),
      );
    }
  }

  Future<bool> Function() _captureHistoryCleanupVerifier() {
    final override = widget.verifyHistoryCleanupForTesting;
    if (override != null) return override;
    final lock = context.findAncestorStateOfType<HermesAppState>()?.appLock;
    final reason = Strings.of(context).setVerifyToClear;
    return () => lock == null
        ? Future<bool>.value(true)
        : LockScreen.verify(context, lock, reason: reason);
  }

  Future<bool> _authorizeHistoryCleanup({
    required bool readOnly,
    required Future<bool> Function() verifier,
  }) async {
    final allowed = await authorizeHistoryCleanup(
      readOnly: readOnly,
      verifyAppLock: verifier,
    );
    if (!mounted) return false;
    if (!allowed && readOnly) {
      showReadOnlyNotice(context);
    }
    return allowed;
  }

  Future<void> _cleanCronConversations() async {
    if (_cleaningConversations) return;
    final readOnly = _mutationsDisabled;
    final verifier = _captureHistoryCleanupVerifier();
    setState(() => _cleaningConversations = true);

    try {
      if (!await _authorizeHistoryCleanup(
        readOnly: readOnly,
        verifier: verifier,
      )) {
        return;
      }
      final preview = await _repository.previewConversationCleanup();
      if (!mounted) return;
      final s = Strings.of(context);
      if (preview.isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(s.crnCleanupEmpty)));
        return;
      }
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          scrollable: true,
          title: Text(s.crnCleanupTitle),
          content: Text(s.crnCleanupBody(preview.count)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(s.commonCancel),
            ),
            FilledButton(
              key: const ValueKey('cron-cleanup-confirm'),
              onPressed: () => Navigator.pop(dialogContext, true),
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(dialogContext).hermes.error,
              ),
              child: Text(s.commonDelete),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;

      final result = await _repository.deleteCronConversations(preview);
      if (!mounted) return;
      if (result.deleted > 0) {
        historyCleanupInvalidations.publish(
          connectionId: widget.connection.id,
          scope: HistoryCleanupScope.cronResults,
        );
      }
      final message = result.preserved == 0
          ? s.crnCleanupDone(result.deleted)
          : s.crnCleanupPartial(result.deleted, result.preserved);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (error) {
      if (!mounted) return;
      final s = Strings.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(s.crnCleanupFailed(localizedApiError(s, error))),
          backgroundColor: Theme.of(context).hermes.warning,
        ),
      );
    } finally {
      if (mounted) setState(() => _cleaningConversations = false);
    }
  }

  Future<void> _showEditor({CronJob? job}) async {
    if (_mutationsDisabled) return showReadOnlyNotice(context);
    final result = await showDialog<_CronEditorResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _CronEditorDialog(repository: _repository, job: job),
    );
    if (result == null || !mounted) return;
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
      if (!mounted) return;
      _replaceJob(updated);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            job == null
                ? Strings.of(context).crnJobCreated
                : Strings.of(context).crnJobUpdated,
          ),
        ),
      );
      unawaited(_loadJobs(showLoader: false));
    } catch (error) {
      if (!mounted) return;
      final strings = Strings.of(context);
      final message = job == null
          ? strings.crnAddFailed(localizedApiError(strings, error))
          : strings.crnUpdateFailed(localizedApiError(strings, error));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Theme.of(context).hermes.warning,
        ),
      );
    }
  }

  Future<void> _openRun(Session session) async {
    await openChatFromHome<void>(
      context,
      builder: (_) =>
          ChatScreen(connection: widget.connection, session: session),
    );
  }

  void _showJobDetail(CronJob job) {
    final detailRepository =
        _profileScope == CronProfileScope.all && job.profile.isNotEmpty
        ? CronRepository(_client, profile: job.profile)
        : _repository;
    showHermesFloatingSurface<void>(
      context: context,
      surfaceKey: const ValueKey('cron-job-detail-surface'),
      maxWidth: 620,
      maxHeightFactor: 0.92,
      builder: (surfaceContext) => _CronJobDetail(
        initialJob: job,
        repository: detailRepository,
        readOnly: _mutationsDisabled,
        eventStream: _eventStream,
        onEdit: () {
          Navigator.pop(surfaceContext);
          _showEditor(job: job);
        },
        onPauseResume: () async {
          Navigator.pop(surfaceContext);
          await _pauseOrResume(job);
        },
        onTrigger: () async {
          Navigator.pop(surfaceContext);
          await _trigger(job);
        },
        onDelete: () async {
          Navigator.pop(surfaceContext);
          await _delete(job);
        },
        onOpenRun: (session) {
          Navigator.pop(surfaceContext);
          _openRun(session);
        },
      ),
    );
  }

  List<CronJob> get _visibleJobs {
    final query = _query.trim().toLowerCase();
    final rows = query.isEmpty
        ? [..._jobs]
        : _jobs.where((job) {
            return [
              job.title,
              job.preview,
              job.scheduleDisplay,
              job.scheduleExpression,
              job.deliver,
              job.profile,
            ].any((value) => value.toLowerCase().contains(query));
          }).toList();
    rows.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return Scaffold(
      appBar: HermesAppBar(
        title: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(s.crnTitle),
                if (widget.connection.readOnly) ...[
                  const SizedBox(width: 8),
                  const ReadOnlyBadge(compact: true),
                ],
              ],
            ),
            if (_profile.isNotEmpty || _profileScope == CronProfileScope.all)
              Text(
                s.crnProfile(
                  _profileScope == CronProfileScope.all &&
                          !_legacyAllProfilesFallback
                      ? s.commonAll
                      : (_profile.isEmpty ? 'default' : _profile),
                ),
                style: TextStyle(fontSize: 10.5, color: colors.textSecondary),
              ),
          ],
        ),
        actions: [
          if (_profileScope == CronProfileScope.active)
            IconButton(
              key: const ValueKey('cron-cleanup-conversations'),
              tooltip: s.crnCleanupTooltip,
              onPressed: _mutationsDisabled || _cleaningConversations
                  ? null
                  : _cleanCronConversations,
              icon: _cleaningConversations
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.delete_sweep_outlined),
            ),
          if (_profileScope == CronProfileScope.active)
            PopupMenuButton<String>(
              tooltip: MaterialLocalizations.of(context).moreButtonTooltip,
              onSelected: (value) {
                if (value != 'raw') return;
                Navigator.of(context).push<void>(
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
              },
              itemBuilder: (_) => [
                PopupMenuItem(value: 'raw', child: Text(s.crnEditJobsJson)),
              ],
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: s.crnRetry,
            onPressed: _fetching ? null : () => _loadJobs(showLoader: false),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: SegmentedButton<CronProfileScope>(
                    key: const ValueKey('cron-profile-scope'),
                    segments: [
                      ButtonSegment(
                        value: CronProfileScope.active,
                        icon: const Icon(Icons.person_outline, size: 18),
                        label: Text(s.crnProfile(s.crnStatusActive)),
                      ),
                      ButtonSegment(
                        value: CronProfileScope.all,
                        icon: const Icon(Icons.groups_outlined, size: 18),
                        label: Text(s.commonAll),
                      ),
                    ],
                    selected: {_profileScope},
                    onSelectionChanged: _selectProfileScope,
                    showSelectedIcon: false,
                  ),
                ),
                if (_profileScope == CronProfileScope.all) ...[
                  const SizedBox(width: 8),
                  HermesPill(label: s.statusReadOnly, color: colors.warning),
                ],
              ],
            ),
          ),
          if (_legacyAllProfilesFallback)
            Padding(
              key: const ValueKey('cron-profile-all-legacy'),
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 16,
                    color: colors.textSecondary,
                  ),
                  const SizedBox(width: 7),
                  Text(
                    '${s.commonNotAvailable} · ${s.crnProfile(_profile.isEmpty ? 'default' : _profile)}',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: colors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          Expanded(child: _buildBody()),
        ],
      ),
      floatingActionButton: _mutationsDisabled
          ? null
          : FloatingActionButton(
              tooltip: s.crnAddNew,
              onPressed: _loading ? null : () => _showEditor(),
              child: const Icon(Icons.add),
            ),
    );
  }

  Widget _buildBody() {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
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

    if (_jobs.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.schedule_outlined, size: 38, color: colors.accent),
              const SizedBox(height: 14),
              Text(
                s.crnEmpty,
                style: Theme.of(context).textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                s.crnCreateDescription,
                style: TextStyle(fontSize: 13, color: colors.textSecondary),
                textAlign: TextAlign.center,
              ),
              if (!_mutationsDisabled) ...[
                const SizedBox(height: 18),
                FilledButton.icon(
                  onPressed: () => _showEditor(),
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(s.crnAddJob),
                ),
              ],
            ],
          ),
        ),
      );
    }

    final jobs = _visibleJobs;
    return RefreshIndicator(
      onRefresh: () => _loadJobs(showLoader: false),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
        children: [
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
          const SizedBox(height: 12),
          if (jobs.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 48),
              child: Text(
                s.crnEmpty,
                textAlign: TextAlign.center,
                style: TextStyle(color: colors.textSecondary),
              ),
            )
          else
            for (final job in jobs)
              _CronJobTile(
                job: job,
                readOnly: _mutationsDisabled,
                onTap: () => _showJobDetail(job),
                onTrigger: () => _trigger(job),
                onEdit: () => _showEditor(job: job),
                onPauseResume: () => _pauseOrResume(job),
                onDelete: () => _delete(job),
              ),
        ],
      ),
    );
  }
}

class _CronJobTile extends StatelessWidget {
  final CronJob job;
  final bool readOnly;
  final VoidCallback onTap;
  final VoidCallback onTrigger;
  final VoidCallback onEdit;
  final VoidCallback onPauseResume;
  final VoidCallback onDelete;

  const _CronJobTile({
    required this.job,
    required this.readOnly,
    required this.onTap,
    required this.onTrigger,
    required this.onEdit,
    required this.onPauseResume,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final presentation = _statePresentation(job.state, context);
    return AccentCard(
      margin: const EdgeInsets.only(bottom: 8),
      accent: job.state == CronJobState.error
          ? colors.error.withValues(alpha: 0.65)
          : null,
      background: colors.surfaceVariant.withValues(alpha: 0.38),
      borderRadius: const BorderRadius.all(Radius.circular(14)),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    job.isScriptOnly
                        ? Icons.terminal_outlined
                        : Icons.schedule_outlined,
                    size: 20,
                    color: presentation.color,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      job.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  HermesPill(
                    label: presentation.label,
                    color: presentation.color,
                  ),
                  if (!readOnly)
                    PopupMenuButton<String>(
                      key: ValueKey('cron-job-menu-${job.id}'),
                      padding: EdgeInsets.zero,
                      onSelected: (action) => switch (action) {
                        'trigger' => onTrigger(),
                        'edit' => onEdit(),
                        'toggle' => onPauseResume(),
                        'delete' => onDelete(),
                        _ => null,
                      },
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: 'trigger',
                          child: _MenuRow(
                            icon: Icons.play_arrow,
                            label: Strings.of(context).crnRunNow,
                          ),
                        ),
                        PopupMenuItem(
                          value: 'edit',
                          child: _MenuRow(
                            icon: Icons.edit_outlined,
                            label: Strings.of(context).commonEdit,
                          ),
                        ),
                        PopupMenuItem(
                          value: 'toggle',
                          child: _MenuRow(
                            icon: job.isPaused
                                ? Icons.play_circle_outline
                                : Icons.pause_circle_outline,
                            label: job.isPaused
                                ? Strings.of(context).crnResume
                                : Strings.of(context).crnPause,
                          ),
                        ),
                        PopupMenuItem(
                          value: 'delete',
                          child: _MenuRow(
                            icon: Icons.delete_outline,
                            label: Strings.of(context).commonDelete,
                          ),
                        ),
                      ],
                    ),
                ],
              ),
              if (job.scheduleDisplay.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  job.scheduleDisplay,
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.accent,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
              if (job.profile.isNotEmpty) ...[
                const SizedBox(height: 5),
                Text(
                  Strings.of(context).crnProfile(job.profile),
                  style: TextStyle(fontSize: 11, color: colors.textDisabled),
                ),
              ],
              if (job.preview.isNotEmpty) ...[
                const SizedBox(height: 5),
                Text(
                  job.preview,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: colors.textSecondary),
                ),
              ],
              if (job.nextRunAt != null) ...[
                const SizedBox(height: 8),
                Text(
                  '${Strings.of(context).crnNextRunLabel}: ${_formatTimestamp(job.nextRunAt, Strings.of(context))}',
                  style: TextStyle(fontSize: 11, color: colors.textDisabled),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  final IconData icon;
  final String label;

  const _MenuRow({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) => Row(
    children: [Icon(icon, size: 18), const SizedBox(width: 10), Text(label)],
  );
}

class _CronJobDetail extends StatefulWidget {
  final CronJob initialJob;
  final CronRepository repository;
  final bool readOnly;
  final Stream<TuiGatewayEvent>? eventStream;
  final VoidCallback onEdit;
  final VoidCallback onPauseResume;
  final VoidCallback onTrigger;
  final VoidCallback onDelete;
  final ValueChanged<Session> onOpenRun;

  const _CronJobDetail({
    required this.initialJob,
    required this.repository,
    required this.readOnly,
    required this.eventStream,
    required this.onEdit,
    required this.onPauseResume,
    required this.onTrigger,
    required this.onDelete,
    required this.onOpenRun,
  });

  @override
  State<_CronJobDetail> createState() => _CronJobDetailState();
}

class _CronJobDetailState extends State<_CronJobDetail> {
  late CronJob _job = widget.initialJob;
  CronRuns? _runs;
  Timer? _timer;
  Timer? _eventRefreshDebounce;
  StreamSubscription<TuiGatewayEvent>? _eventSubscription;
  bool _loading = true;
  bool _fetching = false;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    _timer = Timer.periodic(cronBackstopRefreshInterval, (_) => _refresh());
    _eventSubscription = widget.eventStream?.listen((event) {
      if (!isCronRefreshEvent(event)) return;
      _eventRefreshDebounce?.cancel();
      _eventRefreshDebounce = Timer(
        const Duration(milliseconds: 350),
        _refresh,
      );
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _eventRefreshDebounce?.cancel();
    unawaited(_eventSubscription?.cancel());
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_fetching) return;
    _fetching = true;
    try {
      final results = await Future.wait<Object?>([
        widget.repository.getJob(_job.id),
        widget.repository.listRuns(_job.id),
      ]);
      if (!mounted) return;
      setState(() {
        _job = (results[0] as CronJob?) ?? _job;
        _runs = results[1] as CronRuns;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    } finally {
      _fetching = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final presentation = _statePresentation(_job.state, context);
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _job.title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 6),
                  HermesPill(
                    label: presentation.label,
                    color: presentation.color,
                  ),
                ],
              ),
            ),
            if (!widget.readOnly)
              IconButton(
                icon: const Icon(Icons.edit_outlined, size: 20),
                tooltip: s.commonEdit,
                onPressed: widget.onEdit,
              ),
          ],
        ),
        const SizedBox(height: 16),
        _MetadataGrid(
          rows: [
            (s.crnFieldFrequency, _job.scheduleDisplay),
            (s.crnLastRunLabel, _formatTimestamp(_job.lastRunAt, s)),
            (s.crnNextRunLabel, _formatTimestamp(_job.nextRunAt, s)),
            (s.crnDeliveryLabel, _deliveryLabel(_job.deliver, s)),
            if (_job.model.isNotEmpty) (s.crnModelLabel, _job.model),
          ],
        ),
        if (_job.lastError != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: colors.error.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  size: 18,
                  color: colors.error,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _job.lastError!,
                    style: TextStyle(fontSize: 12, color: colors.error),
                  ),
                ),
              ],
            ),
          ),
        ],
        if (_job.preview.isNotEmpty) ...[
          const SizedBox(height: 18),
          Text(
            s.crnPromptLabel,
            style: Theme.of(
              context,
            ).textTheme.labelLarge?.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: 7),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colors.surfaceVariant.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(12),
            ),
            child: SelectableText(
              _job.preview,
              style: const TextStyle(fontSize: 13, height: 1.4),
            ),
          ),
        ],
        if (!widget.readOnly) ...[
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                onPressed: widget.onTrigger,
                icon: const Icon(Icons.play_arrow, size: 18),
                label: Text(s.crnRunNow),
              ),
              OutlinedButton.icon(
                onPressed: widget.onPauseResume,
                icon: Icon(
                  _job.isPaused
                      ? Icons.play_circle_outline
                      : Icons.pause_circle_outline,
                  size: 18,
                ),
                label: Text(_job.isPaused ? s.crnResume : s.crnPause),
              ),
              IconButton(
                onPressed: widget.onDelete,
                icon: Icon(Icons.delete_outline, color: colors.error),
                tooltip: s.commonDelete,
              ),
            ],
          ),
        ],
        const SizedBox(height: 20),
        Divider(color: colors.divider),
        const SizedBox(height: 12),
        Text(
          '${s.crnRunHistory}${(_runs?.sessions.isNotEmpty ?? false) ? ' · ${_runs!.sessions.length}' : ''}',
          style: Theme.of(
            context,
          ).textTheme.labelLarge?.copyWith(color: colors.textSecondary),
        ),
        const SizedBox(height: 8),
        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Align(
              alignment: Alignment.centerLeft,
              child: SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          )
        else if (_runs?.available == false)
          Text(s.crnHistoryUnavailable, style: _mutedStyle(colors))
        else if (_runs == null || _runs!.sessions.isEmpty)
          Text(s.crnNoRuns, style: _mutedStyle(colors))
        else
          for (final session in _runs!.sessions)
            _CronRunRow(
              session: session,
              onTap: () => widget.onOpenRun(session),
            ),
      ],
    );
  }

  TextStyle _mutedStyle(HermesThemeColors colors) => TextStyle(
    fontSize: 12,
    color: colors.textSecondary,
    fontStyle: FontStyle.italic,
  );
}

class _MetadataGrid extends StatelessWidget {
  final List<(String, String)> rows;

  const _MetadataGrid({required this.rows});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: colors.surfaceVariant.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          for (var index = 0; index < rows.length; index++) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 120,
                    child: Text(
                      rows[index].$1,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: colors.textSecondary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      rows[index].$2.isEmpty ? '—' : rows[index].$2,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
            if (index < rows.length - 1)
              Divider(height: 1, color: colors.divider),
          ],
        ],
      ),
    );
  }
}

class _CronRunRow extends StatelessWidget {
  final Session session;
  final VoidCallback onTap;

  const _CronRunRow({required this.session, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Semantics(
      button: true,
      label: '${Strings.of(context).crnOpenRun}: ${session.displayTitle}',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
          child: Row(
            children: [
              Icon(Icons.chat_bubble_outline, size: 17, color: colors.accent),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  session.displayTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _formatTimestamp(session.lastActivityAt, Strings.of(context)),
                style: TextStyle(fontSize: 10.5, color: colors.textDisabled),
              ),
              const SizedBox(width: 3),
              Icon(Icons.chevron_right, size: 17, color: colors.textDisabled),
            ],
          ),
        ),
      ),
    );
  }
}

sealed class _CronEditorResult {
  const _CronEditorResult();
}

class _ManualCronResult extends _CronEditorResult {
  final _CronEditorValues values;
  const _ManualCronResult(this.values);
}

class _BlueprintCronResult extends _CronEditorResult {
  final AutomationBlueprint blueprint;
  final Map<String, String> values;
  const _BlueprintCronResult(this.blueprint, this.values);
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

class _CronEditorDialog extends StatefulWidget {
  final CronRepository repository;
  final CronJob? job;

  const _CronEditorDialog({required this.repository, this.job});

  @override
  State<_CronEditorDialog> createState() => _CronEditorDialogState();
}

class _CronEditorDialogState extends State<_CronEditorDialog> {
  static const _defaultModel = '__default__';
  static const _customTemplate = '__custom__';

  late final TextEditingController _nameController;
  late final TextEditingController _promptController;
  late final TextEditingController _scheduleController;
  CronEditorResources? _resources;
  AutomationBlueprint? _blueprint;
  Map<String, String> _blueprintValues = {};
  bool _loadingResources = true;
  String _preset = 'daily';
  String _deliver = 'local';
  String _modelChoice = _defaultModel;
  String? _error;

  bool get _editing => widget.job != null;
  bool get _scriptOnly => widget.job?.isScriptOnly == true;

  @override
  void initState() {
    super.initState();
    final job = widget.job;
    _nameController = TextEditingController(text: job?.name ?? '');
    _promptController = TextEditingController(text: job?.prompt ?? '');
    _scheduleController = TextEditingController(
      text: job?.scheduleExpression.isNotEmpty == true
          ? job!.scheduleExpression
          : '0 9 * * *',
    );
    _preset = _presetFor(_scheduleController.text);
    _deliver = job?.deliver.isNotEmpty == true ? job!.deliver : 'local';
    _modelChoice = job?.model.isNotEmpty == true
        ? '${job!.provider}:${job.model}'
        : _defaultModel;
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
    _scheduleController.dispose();
    super.dispose();
  }

  void _selectTemplate(String? key) {
    if (key == null || key == _customTemplate) {
      setState(() {
        _blueprint = null;
        _blueprintValues = {};
        _error = null;
      });
      return;
    }
    final blueprint = _resources?.blueprints
        .where((item) => item.key == key)
        .firstOrNull;
    if (blueprint == null) return;
    setState(() {
      _blueprint = blueprint;
      _blueprintValues = blueprint.initialValues();
      _error = null;
    });
  }

  void _selectPreset(String? preset) {
    if (preset == null) return;
    final option = _scheduleOptions.firstWhere((row) => row.key == preset);
    setState(() {
      _preset = preset;
      _error = null;
      if (option.expression != null) {
        _scheduleController.text = option.expression!;
      } else if (_presetFor(_scheduleController.text) != 'custom') {
        _scheduleController.clear();
      }
    });
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
        _BlueprintCronResult(_blueprint!, Map.of(_blueprintValues)),
      );
      return;
    }

    final prompt = _promptController.text.trim();
    final schedule = _scheduleController.text.trim();
    if (prompt.isEmpty && schedule.isEmpty && !_scriptOnly) {
      setState(() => _error = s.crnPromptScheduleRequired);
      return;
    }
    if (schedule.isEmpty) {
      setState(() => _error = s.crnScheduleRequired);
      return;
    }
    if (prompt.isEmpty && !_scriptOnly) {
      setState(() => _error = s.crnPromptRequired);
      return;
    }

    final separator = _modelChoice == _defaultModel
        ? -1
        : _modelChoice.indexOf(':');
    final provider = separator < 0 ? '' : _modelChoice.substring(0, separator);
    final model = separator < 0 ? '' : _modelChoice.substring(separator + 1);
    Navigator.pop(
      context,
      _ManualCronResult(
        _CronEditorValues(
          name: _nameController.text.trim(),
          prompt: prompt,
          schedule: schedule,
          deliver: _deliver,
          model: model,
          provider: provider,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 560,
          maxHeight: MediaQuery.sizeOf(context).height * 0.9,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 12, 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _editing ? s.crnEditJob : s.crnAddJob,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _editing
                              ? s.crnEditDescription
                              : s.crnCreateDescription,
                          style: TextStyle(
                            fontSize: 12.5,
                            color: colors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).closeButtonTooltip,
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: colors.divider),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: _loadingResources
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: 48),
                        child: Center(child: TuiLoader()),
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (!_editing &&
                              (_resources?.blueprints.isNotEmpty ?? false)) ...[
                            _fieldLabel(s.crnStartFrom, colors),
                            _dropdown<String>(
                              value: _blueprint?.key ?? _customTemplate,
                              items: [
                                DropdownMenuItem(
                                  value: _customTemplate,
                                  child: Text(s.crnCustomSetup),
                                ),
                                for (final item in _resources!.blueprints)
                                  DropdownMenuItem(
                                    value: item.key,
                                    child: Text(
                                      item.title,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                              ],
                              onChanged: _selectTemplate,
                            ),
                            if (_blueprint?.description.isNotEmpty == true) ...[
                              const SizedBox(height: 6),
                              Text(
                                _blueprint!.description,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: colors.textSecondary,
                                ),
                              ),
                            ],
                            const SizedBox(height: 16),
                          ],
                          if (_blueprint != null)
                            ..._buildBlueprintFields(colors)
                          else
                            ..._buildManualFields(colors),
                          if (_error != null) ...[
                            const SizedBox(height: 14),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: colors.error.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                _error!,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: colors.error,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
              ),
            ),
            Divider(height: 1, color: colors.divider),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(s.commonCancel),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _loadingResources ? null : _submit,
                    child: Text(
                      _blueprint != null
                          ? s.crnBlueprintCreate
                          : (_editing ? s.commonSave : s.crnAdd),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildManualFields(HermesThemeColors colors) {
    final s = Strings.of(context);
    final targets = [...?_resources?.deliveryTargets];
    if (!targets.any((target) => target.id == _deliver)) {
      targets.add(
        CronDeliveryTarget(id: _deliver, name: _deliver, homeTargetSet: true),
      );
    }
    final modelItems = _modelItems();
    return [
      HermesField(
        key: const ValueKey('cron-name-field'),
        controller: _nameController,
        label: s.crnFieldName,
        hint: s.crnFieldNameHint,
      ),
      const SizedBox(height: 14),
      if (_scriptOnly) ...[
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: colors.accent.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            s.crnScriptOnlyHint,
            style: TextStyle(fontSize: 11.5, color: colors.textSecondary),
          ),
        ),
        const SizedBox(height: 14),
      ],
      HermesField(
        key: const ValueKey('cron-prompt-field'),
        controller: _promptController,
        label: s.crnPromptLabel,
        hint: s.crnFieldPromptHint,
        minLines: 3,
        maxLines: 6,
      ),
      const SizedBox(height: 16),
      _fieldLabel(s.crnFieldFrequency, colors),
      _dropdown<String>(
        key: const ValueKey('cron-frequency-field'),
        value: _preset,
        items: [
          for (final option in _scheduleOptions)
            DropdownMenuItem(
              value: option.key,
              child: Text(_scheduleOptionLabel(option.key, s)),
            ),
        ],
        onChanged: _selectPreset,
      ),
      const SizedBox(height: 8),
      if (_preset == 'custom')
        TextField(
          key: const ValueKey('cron-custom-schedule-field'),
          controller: _scheduleController,
          style: const TextStyle(fontSize: 13),
          decoration: InputDecoration(
            labelText: s.crnFieldCronExpr,
            hintText: '0 9 * * *',
          ),
        )
      else
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: colors.surfaceVariant.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _describeCron(_scheduleController.text, s),
                  style: const TextStyle(fontSize: 12.5),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _scheduleController.text,
                style: TextStyle(
                  fontSize: 11,
                  color: colors.textSecondary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      const SizedBox(height: 16),
      _fieldLabel(s.crnDeliveryLabel, colors),
      _dropdown<String>(
        key: const ValueKey('cron-delivery-field'),
        value: _deliver,
        items: [
          for (final target in targets)
            DropdownMenuItem(
              value: target.id,
              child: Text(
                _deliveryTargetLabel(target, s),
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: (value) {
          if (value != null) setState(() => _deliver = value);
        },
      ),
      if (!_scriptOnly) ...[
        const SizedBox(height: 16),
        _fieldLabel(s.crnModelLabel, colors),
        _dropdown<String>(
          key: const ValueKey('cron-model-field'),
          value: _modelChoice,
          items: modelItems,
          onChanged: (value) {
            if (value != null) setState(() => _modelChoice = value);
          },
        ),
        if (modelItems.length == 1) ...[
          const SizedBox(height: 6),
          Text(
            s.crnModelUnavailable,
            style: TextStyle(fontSize: 11, color: colors.textSecondary),
          ),
        ],
      ],
    ];
  }

  List<DropdownMenuItem<String>> _modelItems() {
    final s = Strings.of(context);
    final items = <DropdownMenuItem<String>>[
      DropdownMenuItem(value: _defaultModel, child: Text(s.crnModelDefault)),
    ];
    final known = <String>{_defaultModel};
    for (final provider
        in _resources?.modelProviders ?? const <ModelProvider>[]) {
      if (provider.models.isEmpty) continue;
      for (final model in provider.models) {
        final value = '${provider.slug}:$model';
        known.add(value);
        items.add(
          DropdownMenuItem(
            value: value,
            child: Text(
              '${provider.name.isEmpty ? provider.slug : provider.name} · $model',
              overflow: TextOverflow.ellipsis,
            ),
          ),
        );
      }
    }
    if (!known.contains(_modelChoice)) {
      items.insert(
        1,
        DropdownMenuItem(
          value: _modelChoice,
          child: Text(
            _modelChoice.substring(_modelChoice.indexOf(':') + 1),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
    }
    return items;
  }

  List<Widget> _buildBlueprintFields(HermesThemeColors colors) {
    final widgets = <Widget>[];
    for (final field in _blueprint!.fields) {
      widgets.add(_fieldLabel(field.label, colors));
      if (field.name == 'deliver') {
        final targets = _resources!.deliveryTargets;
        var value = _blueprintValues[field.name] ?? 'local';
        if (!targets.any((target) => target.id == value)) value = 'local';
        widgets.add(
          _dropdown<String>(
            value: value,
            items: [
              for (final target in targets)
                DropdownMenuItem(
                  value: target.id,
                  child: Text(
                    _deliveryTargetLabel(target, Strings.of(context)),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (next) {
              if (next != null) {
                setState(() => _blueprintValues[field.name] = next);
              }
            },
          ),
        );
      } else if (field.type == AutomationBlueprintFieldType.enumValue ||
          field.type == AutomationBlueprintFieldType.weekdays) {
        final options = [...field.options];
        final value = _blueprintValues[field.name] ?? '';
        if (value.isNotEmpty && !options.contains(value)) {
          options.insert(0, value);
        }
        widgets.add(
          _dropdown<String>(
            value: value,
            items: [
              for (final option in options)
                DropdownMenuItem(value: option, child: Text(option)),
            ],
            onChanged: (next) {
              if (next != null) {
                setState(() => _blueprintValues[field.name] = next);
              }
            },
          ),
        );
      } else {
        widgets.add(
          TextFormField(
            key: ValueKey('${_blueprint!.key}-${field.name}'),
            initialValue: _blueprintValues[field.name] ?? '',
            keyboardType: field.type == AutomationBlueprintFieldType.time
                ? TextInputType.datetime
                : TextInputType.text,
            decoration: InputDecoration(
              hintText: field.type == AutomationBlueprintFieldType.time
                  ? '09:00'
                  : (field.help.isEmpty ? field.label : field.help),
            ),
            onChanged: (value) => _blueprintValues[field.name] = value,
          ),
        );
      }
      if (field.help.isNotEmpty && field.name != 'deliver') {
        widgets.add(const SizedBox(height: 5));
        widgets.add(
          Text(
            field.help,
            style: TextStyle(fontSize: 11, color: colors.textSecondary),
          ),
        );
      }
      widgets.add(const SizedBox(height: 14));
    }
    return widgets;
  }

  Widget _fieldLabel(String label, HermesThemeColors colors) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      label,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: colors.textSecondary,
      ),
    ),
  );

  Widget _dropdown<T>({
    Key? key,
    required T value,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> onChanged,
  }) => DropdownButtonFormField<T>(
    key: key ?? ValueKey(value),
    initialValue: value,
    isExpanded: true,
    style: Theme.of(context).dropdownMenuTheme.textStyle,
    items: items,
    onChanged: onChanged,
    decoration: const InputDecoration(isDense: true),
  );
}

class _ScheduleOption {
  final String key;
  final String? expression;
  const _ScheduleOption(this.key, this.expression);
}

const _scheduleOptions = <_ScheduleOption>[
  _ScheduleOption('daily', '0 9 * * *'),
  _ScheduleOption('weekdays', '0 9 * * 1-5'),
  _ScheduleOption('weekly', '0 9 * * 1'),
  _ScheduleOption('monthly', '0 9 1 * *'),
  _ScheduleOption('hourly', '0 * * * *'),
  _ScheduleOption('every-15-minutes', '*/15 * * * *'),
  _ScheduleOption('custom', null),
];

String _presetFor(String expression) {
  final normalized = expression.trim().replaceAll(RegExp(r'\s+'), ' ');
  for (final option in _scheduleOptions) {
    if (option.expression == normalized) return option.key;
  }
  final parts = normalized.split(' ');
  if (parts.length != 5) return 'custom';
  final minute = parts[0];
  final hour = parts[1];
  final dayOfMonth = parts[2];
  final month = parts[3];
  final dayOfWeek = parts[4];
  final integer = RegExp(r'^\d+$');
  if (dayOfMonth == '*' &&
      month == '*' &&
      dayOfWeek == '*' &&
      integer.hasMatch(minute) &&
      integer.hasMatch(hour)) {
    return 'daily';
  }
  if (dayOfMonth == '*' &&
      month == '*' &&
      dayOfWeek == '1-5' &&
      integer.hasMatch(minute) &&
      integer.hasMatch(hour)) {
    return 'weekdays';
  }
  if (dayOfMonth == '*' &&
      month == '*' &&
      integer.hasMatch(dayOfWeek) &&
      integer.hasMatch(minute) &&
      integer.hasMatch(hour)) {
    return 'weekly';
  }
  if (month == '*' &&
      dayOfWeek == '*' &&
      integer.hasMatch(dayOfMonth) &&
      integer.hasMatch(minute) &&
      integer.hasMatch(hour)) {
    return 'monthly';
  }
  if (hour == '*' &&
      dayOfMonth == '*' &&
      month == '*' &&
      dayOfWeek == '*' &&
      integer.hasMatch(minute)) {
    return 'hourly';
  }
  return 'custom';
}

String _scheduleOptionLabel(String key, Strings s) => switch (key) {
  'daily' => s.crnFreqDailyMorning,
  'weekdays' => s.crnFreqWeekdays,
  'weekly' => s.crnFreqWeekly,
  'monthly' => s.crnFreqMonthly,
  'hourly' => s.crnFreqHourly,
  'every-15-minutes' => s.crnFreqEvery15m,
  _ => s.crnFreqCustom,
};

String _describeCron(String expression, Strings s) {
  final key = _presetFor(expression);
  return switch (key) {
    'daily' => s.crnDescDailyAt('09'),
    'weekdays' => s.crnDescWeekdaysAt('09'),
    'weekly' => s.crnDescWeeklyAt(s.crnDayMon, '09'),
    'monthly' => s.crnDescMonthly,
    'hourly' => s.crnDescHourly,
    'every-15-minutes' => s.crnFreqEvery15m,
    _ => expression,
  };
}

({String label, Color color}) _statePresentation(
  CronJobState state,
  BuildContext context,
) {
  final s = Strings.of(context);
  final colors = Theme.of(context).hermes;
  return switch (state) {
    CronJobState.enabled || CronJobState.scheduled => (
      label: s.crnStatusScheduled,
      color: colors.success,
    ),
    CronJobState.running => (label: s.crnStatusRunning, color: colors.accent),
    CronJobState.paused => (label: s.crnStatusPaused, color: colors.warning),
    CronJobState.disabled => (
      label: s.crnStatusDisabled,
      color: colors.textDisabled,
    ),
    CronJobState.error => (label: s.crnStatusError, color: colors.error),
    CronJobState.completed => (
      label: s.crnStatusCompleted,
      color: colors.textDisabled,
    ),
    CronJobState.unknown => (
      label: s.crnStatusActive,
      color: colors.textSecondary,
    ),
  };
}

String _deliveryTargetLabel(CronDeliveryTarget target, Strings s) {
  final base = target.id == 'local' ? s.crnDeliveryLocal : target.name;
  return target.id != 'local' && !target.homeTargetSet
      ? '$base — ${s.crnDeliveryNeedsHome}'
      : base;
}

String _deliveryLabel(String value, Strings s) =>
    value == 'local' ? s.crnDeliveryLocal : value;

String _formatTimestamp(Object? raw, Strings s) {
  if (raw == null) return s.crnNever;
  DateTime? date;
  if (raw is num && raw.isFinite) {
    date = DateTime.fromMillisecondsSinceEpoch((raw * 1000).round());
  } else {
    date = DateTime.tryParse(raw.toString())?.toLocal();
  }
  if (date == null) return raw.toString();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(date.day)}/${two(date.month)}/${date.year} · ${two(date.hour)}:${two(date.minute)}';
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
