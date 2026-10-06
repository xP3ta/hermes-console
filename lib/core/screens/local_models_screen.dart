import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../design/hermes_design.dart';
import '../services/connection_manager.dart';
import '../services/local_models_client.dart';
import '../theme/app_theme.dart';
import '../widgets/hermes_notice.dart';
import '../widgets/provider_logo.dart';
import '../widgets/read_only.dart';

/// Server local models: the Hermes-managed llama.cpp runtime that Desktop
/// shows in local mode (Settings → Providers → Local). Every action calls
/// the same `/api/local-models/*` route Desktop calls; long work (downloads,
/// activation, engine install) is a server job polled like Desktop does
/// (`GET /api/local-models/jobs`, ~0.7 s while running, 3 s while paused).
class LocalModelsScreen extends StatefulWidget {
  const LocalModelsScreen({
    required this.connection,
    this.profile = '',
    this.client,
    this.pollInterval = const Duration(milliseconds: 800),
    this.pausedPollInterval = const Duration(seconds: 3),
    super.key,
  });

  final SavedConnection connection;
  final String profile;

  /// Client to reuse (the Models screen shares its Dashboard session);
  /// null builds one from [connection].
  final LocalModelsClient? client;
  final Duration pollInterval;
  final Duration pausedPollInterval;

  @override
  State<LocalModelsScreen> createState() => _LocalModelsScreenState();
}

enum _ModelAction { use, eject, delete }

class _LocalModelsScreenState extends State<LocalModelsScreen> {
  DashboardClient? _dashboard;
  late final LocalModelsClient _client;

  LocalModelsStatus? _status;
  List<LocalCatalogModel> _catalog = const [];
  List<LocalRuntimeJob> _jobs = const [];
  bool _loading = true;
  bool _unavailable = false;
  String? _error;
  final Set<String> _busy = {};

  Timer? _poll;
  bool _polling = false;

  /// Last seen status per job id: a running → done/error transition
  /// refreshes status/catalog and tells the user, once.
  final Map<String, String> _seenJobStatus = {};

  /// Display names of activations started here, by job id.
  final Map<String, String> _activationNames = {};

  @override
  void initState() {
    super.initState();
    final shared = widget.client;
    if (shared != null) {
      _client = shared;
    } else {
      _dashboard = DashboardClient.lazy(widget.connection);
      _client = LocalModelsClient(_dashboard!, profile: widget.profile);
    }
    _load();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _dashboard?.close();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = _status == null;
      _error = null;
    });
    try {
      final status = await _client.status();
      final results = await Future.wait<Object?>([
        _client.catalog().then<Object?>((v) => v, onError: (_) => null),
        _client.jobs().then<Object?>((v) => v, onError: (_) => null),
      ]);
      if (!mounted) return;
      final jobs = results[1] as List<LocalRuntimeJob>?;
      setState(() {
        _status = status;
        _catalog = (results[0] as List<LocalCatalogModel>?) ?? _catalog;
        if (jobs != null) {
          _jobs = jobs;
          for (final job in jobs) {
            _seenJobStatus[job.jobId] = job.status;
          }
        }
        _unavailable = false;
        _loading = false;
      });
      _schedulePoll();
    } on LocalModelsUnavailable {
      if (!mounted) return;
      setState(() {
        _unavailable = true;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _schedulePoll() {
    _poll?.cancel();
    if (!mounted) return;
    final running = _jobs.any((j) => j.isRunning);
    final paused = _jobs.any((j) => j.isPaused);
    if (!running && !paused) return;
    _poll = Timer(
      running ? widget.pollInterval : widget.pausedPollInterval,
      _pollJobs,
    );
  }

  Future<void> _pollJobs() async {
    if (_polling || !mounted) return;
    _polling = true;
    try {
      final jobs = await _client.jobs();
      if (!mounted) return;
      var settled = false;
      final s = Strings.of(context);
      for (final job in jobs) {
        final before = _seenJobStatus[job.jobId];
        _seenJobStatus[job.jobId] = job.status;
        if (before == null || before == job.status) continue;
        if (job.status == 'done') {
          settled = true;
          final name = _activationNames.remove(job.jobId);
          _notice(
            job.kind == 'model-activate'
                ? s.lm1215Activated(name ?? job.target)
                : s.lm1215JobDone(job.target),
          );
        } else if (job.status == 'error') {
          settled = true;
          _activationNames.remove(job.jobId);
          _notice(
            job.error == null || job.error!.isEmpty
                ? s.lm1215JobFailed(job.target)
                : '${s.lm1215JobFailed(job.target)} · ${job.error}',
            error: true,
          );
        }
      }
      setState(() => _jobs = jobs);
      if (settled) await _refreshState();
    } catch (_) {
      // A missed poll is retried by the next tick; the rows keep their
      // last known progress instead of flashing an error.
    } finally {
      _polling = false;
      _schedulePoll();
    }
  }

  /// Re-reads status and catalog after a write (no full-page loader).
  Future<void> _refreshState() async {
    try {
      final status = await _client.status();
      final catalog = await _client.catalog().then<List<LocalCatalogModel>?>(
        (v) => v,
        onError: (_) => null,
      );
      if (!mounted) return;
      setState(() {
        _status = status;
        if (catalog != null) _catalog = catalog;
      });
    } catch (_) {
      // Keep the last good state; pull-to-refresh retries.
    }
  }

  /// Starts watching jobs right after a job-starting POST.
  Future<void> _watchJobs() async {
    _poll?.cancel();
    await _pollJobs();
  }

  void _notice(String message, {bool error = false}) {
    if (!mounted) return;
    HermesNotice.of(context).showSnackBar(
      SnackBar(content: Text(message)),
      kind: error ? HermesNoticeKind.error : HermesNoticeKind.success,
    );
  }

  String _failure(Object e) {
    final detail = e is LocalModelsException && e.detail.isNotEmpty
        ? e.detail
        : e.toString();
    return Strings.of(context).lm1215ActionFailed(detail);
  }

  bool _guardWrite() {
    if (!widget.connection.readOnly) return true;
    showReadOnlyNotice(context);
    return false;
  }

  Future<void> _run(String busyKey, Future<void> Function() action) async {
    if (!_guardWrite() || _busy.contains(busyKey)) return;
    setState(() => _busy.add(busyKey));
    try {
      await action();
    } catch (e) {
      _notice(_failure(e), error: true);
    } finally {
      if (mounted) setState(() => _busy.remove(busyKey));
    }
  }

  // ── actions ──────────────────────────────────────────────────────────

  Future<void> _activate(String modelId) => _run('use:$modelId', () async {
    final jobId = await _client.activate(modelId);
    if (jobId != null) {
      _activationNames[jobId] = modelId;
      _seenJobStatus[jobId] = 'running';
    }
    await _watchJobs();
  });

  Future<void> _eject(String modelId) => _run('eject:$modelId', () async {
    final s = Strings.of(context);
    await _client.eject(modelId);
    _notice(s.lm1215Ejected);
    await _refreshState();
  });

  Future<void> _delete(String modelId) async {
    if (!_guardWrite()) return;
    final s = Strings.of(context);
    final isActive = _status?.activeModelId == modelId;
    final ok = await showHermesDialog<bool>(
      context: context,
      surfaceKey: const ValueKey('lm1215-delete-dialog'),
      title: s.lm1215DeleteTitle(modelId),
      message: isActive ? s.lm1215DeleteActiveBody : s.lm1215DeleteBody,
      actions: [
        HermesDialogAction(
          label: s.lm1215Cancel,
          value: false,
          style: HermesDialogActionStyle.cancel,
        ),
        HermesDialogAction(
          key: const ValueKey('lm1215-delete-confirm'),
          label: s.lm1215Delete,
          value: true,
          style: HermesDialogActionStyle.destructive,
        ),
      ],
    );
    if (ok != true || !mounted) return;
    await _run('delete:$modelId', () async {
      await _client.delete(modelId);
      _notice(s.lm1215Deleted(modelId));
      await _refreshState();
    });
  }

  Future<void> _download(LocalCatalogModel model) =>
      _run('download:${model.id}', () async {
        final s = Strings.of(context);
        final start = await _client.download(model.id);
        if (start.alreadyDownloaded || start.jobId == null) {
          _notice(s.lm1215AlreadyDownloaded);
          await _refreshState();
          return;
        }
        // Like Desktop, the progress row is the feedback: no toast that
        // would queue ahead of the "ready" notice.
        _seenJobStatus[start.jobId!] = 'running';
        await _watchJobs();
      });

  Future<void> _pause(LocalRuntimeJob job) =>
      _run('pause:${job.jobId}', () async {
        await _client.pause(job.jobId);
        await _watchJobs();
      });

  Future<void> _resume(LocalRuntimeJob job) =>
      _run('resume:${job.jobId}', () async {
        await _client.resume(job.jobId);
        await _watchJobs();
      });

  Future<void> _toggleServer() async {
    final status = _status;
    if (status == null || !_guardWrite()) return;
    final s = Strings.of(context);
    if (status.serverRunning) {
      final ok = await showHermesDialog<bool>(
        context: context,
        surfaceKey: const ValueKey('lm1215-stop-dialog'),
        title: s.lm1215StopTitle,
        message: s.lm1215StopBody,
        actions: [
          HermesDialogAction(
            label: s.lm1215Cancel,
            value: false,
            style: HermesDialogActionStyle.cancel,
          ),
          HermesDialogAction(
            key: const ValueKey('lm1215-stop-confirm'),
            label: s.lm1215StopServer,
            value: true,
            style: HermesDialogActionStyle.destructive,
          ),
        ],
      );
      if (ok != true || !mounted) return;
    }
    await _run('server', () async {
      await _client.setServer(running: !status.serverRunning);
      _notice(
        status.serverRunning ? s.lm1215ServerStopped : s.lm1215ServerStarted,
      );
      await _refreshState();
    });
  }

  Future<void> _installRuntime() async {
    if (!_guardWrite()) return;
    final s = Strings.of(context);
    final ok = await showHermesDialog<bool>(
      context: context,
      surfaceKey: const ValueKey('lm1215-install-dialog'),
      title: s.lm1215InstallTitle,
      message: s.lm1215InstallBody,
      actions: [
        HermesDialogAction(
          label: s.lm1215Cancel,
          value: false,
          style: HermesDialogActionStyle.cancel,
        ),
        HermesDialogAction(
          key: const ValueKey('lm1215-install-confirm'),
          label: s.lm1215Install,
          value: true,
        ),
      ],
    );
    if (ok != true || !mounted) return;
    await _run('install', () async {
      final jobId = await _client.installRuntime();
      if (jobId != null) _seenJobStatus[jobId] = 'running';
      await _watchJobs();
    });
  }

  Future<void> _openMenu(LocalStagedModel model, GlobalKey anchor) async {
    final s = Strings.of(context);
    final status = _status!;
    final isActive = status.activeModelId == model.id;
    final action = await showHermesMenu<_ModelAction>(
      context: context,
      anchorKey: anchor,
      title: model.id,
      actions: [
        if (!isActive)
          HermesAction(
            key: const ValueKey('lm1215-action-use'),
            value: _ModelAction.use,
            label: s.lm1215ActionUse,
            icon: Icons.check_circle_outline_rounded,
          ),
        if (status.isLoaded(model.id))
          HermesAction(
            key: const ValueKey('lm1215-action-eject'),
            value: _ModelAction.eject,
            label: s.lm1215ActionEject,
            icon: Icons.eject_rounded,
          ),
        HermesAction(
          key: const ValueKey('lm1215-action-delete'),
          value: _ModelAction.delete,
          label: s.lm1215ActionDelete,
          icon: Icons.delete_outline_rounded,
          destructive: true,
        ),
      ],
    );
    switch (action) {
      case _ModelAction.use:
        await _activate(model.id);
      case _ModelAction.eject:
        await _eject(model.id);
      case _ModelAction.delete:
        await _delete(model.id);
      case null:
        break;
    }
  }

  Future<void> _openSearch() async {
    if (!_guardWrite()) return;
    final started = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => LocalModelsSearchScreen(client: _client),
      ),
    );
    if (started == true && mounted) await _watchJobs();
  }

  // ── UI ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final status = _status;
    final children = <Widget>[];
    if (_loading) {
      children.add(
        const Padding(
          padding: EdgeInsets.only(top: 48),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    } else if (_unavailable) {
      children.add(
        _Message(
          key: const ValueKey('lm1215-unavailable'),
          icon: Icons.memory_outlined,
          text: s.lm1215Unavailable,
        ),
      );
    } else if (status == null) {
      children.addAll([
        _Message(
          icon: Icons.cloud_off_rounded,
          text: s.lm1215LoadFailed,
          detail: _error,
        ),
        const SizedBox(height: 12),
        HermesActionButton(
          key: const ValueKey('lm1215-retry'),
          label: s.lm1215Retry,
          onPressed: _load,
        ),
      ]);
    } else {
      children.addAll(_content(s, colors, status));
    }
    return HermesPage(
      title: s.lm1215Title,
      onRefresh: _load,
      actions: [
        IconButton(
          tooltip: s.lm1215Refresh,
          icon: const Icon(Icons.refresh_rounded),
          onPressed: _loading ? null : _load,
        ),
      ],
      children: children,
    );
  }

  List<Widget> _content(
    Strings s,
    HermesThemeColors colors,
    LocalModelsStatus status,
  ) {
    final activeJobs = _jobs.where((j) => j.isActive).toList();
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(6, 0, 6, 4),
        child: Text(
          s.lm1215Intro,
          style: HermesType.caption.copyWith(
            color: colors.textSecondary,
            fontSize: 12.5,
            height: 1.35,
            letterSpacing: 0,
          ),
        ),
      ),
      HermesSectionHeader(s.lm1215RuntimeTitle),
      HermesListGroup(children: [_runtimeRow(s, colors, status)]),
      if (activeJobs.isNotEmpty) ...[
        HermesSectionHeader(s.lm1215JobsTitle),
        HermesListGroup(
          dividerIndent: 16,
          children: [for (final job in activeJobs) _jobRow(s, colors, job)],
        ),
      ],
      HermesSectionHeader(s.lm1215InstalledTitle),
      if (status.models.isEmpty)
        HermesListGroup(
          children: [
            HermesListRow(
              icon: Icons.inventory_2_outlined,
              title: s.lm1215InstalledEmpty,
              muted: true,
              showChevron: false,
            ),
          ],
        )
      else
        HermesListGroup(
          children: [
            for (final model in status.models)
              _modelRow(s, colors, status, model),
          ],
        ),
      HermesSectionHeader(s.lm1215SearchTitle),
      HermesListGroup(
        children: [
          HermesListRow(
            key: const ValueKey('lm1215-search-entry'),
            icon: Icons.travel_explore_rounded,
            title: s.lm1215SearchTitle,
            subtitle: s.lm1215SearchSubtitle,
            onTap: _openSearch,
          ),
        ],
      ),
      if (_catalog.isNotEmpty) ...[
        HermesSectionHeader(s.lm1215CatalogTitle),
        HermesListGroup(
          children: [for (final m in _catalog) _catalogRow(s, colors, m)],
        ),
      ],
    ];
  }

  Widget _runtimeRow(
    Strings s,
    HermesThemeColors colors,
    LocalModelsStatus status,
  ) {
    if (!status.runtimeInstalled) {
      return HermesListRow(
        icon: Icons.download_for_offline_outlined,
        title: s.lm1215RuntimeMissing,
        showChevron: false,
        trailing: _SmallButton(
          key: const ValueKey('lm1215-install-runtime'),
          label: s.lm1215InstallRuntime,
          busy: _busy.contains('install'),
          onPressed: _installRuntime,
        ),
      );
    }
    final backend = status.runtimeBackend ?? '';
    return HermesListRow(
      icon: Icons.memory_rounded,
      iconColor: status.serverRunning ? colors.success : null,
      title: status.serverRunning ? s.lm1215ServerOn : s.lm1215ServerOff,
      subtitle: s.lm1215RuntimeReady(status.tag, backend),
      showChevron: false,
      trailing: _SmallButton(
        key: const ValueKey('lm1215-server-toggle'),
        label: status.serverRunning ? s.lm1215StopServer : s.lm1215StartServer,
        busy: _busy.contains('server'),
        onPressed: _toggleServer,
      ),
    );
  }

  Widget _jobRow(Strings s, HermesThemeColors colors, LocalRuntimeJob job) {
    final total = job.totalBytes;
    final progress = total != null && total > 0
        ? s.lm1215Progress(
            formatLocalBytes(job.doneBytes),
            formatLocalBytes(total),
          )
        : job.detail;
    final percent = job.percent;
    return Padding(
      key: ValueKey('lm1215-job-${job.jobId}'),
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  job.target,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: HermesType.body.copyWith(
                    color: colors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    minHeight: 5,
                    value: percent == null ? null : percent / 100,
                    backgroundColor: colors.divider,
                    color: job.isPaused ? colors.textDisabled : colors.accent,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  job.isPaused
                      ? s.lm1215Paused
                      : [
                          if (percent != null) '$percent %',
                          if (progress.isNotEmpty) progress,
                        ].join(' · '),
                  style: HermesType.caption.copyWith(
                    color: colors.textSecondary,
                    letterSpacing: 0,
                  ),
                ),
              ],
            ),
          ),
          if (job.canPause)
            IconButton(
              key: ValueKey('lm1215-job-pause-${job.jobId}'),
              tooltip: s.lm1215Pause,
              icon: const Icon(Icons.pause_rounded),
              onPressed: _busy.contains('pause:${job.jobId}')
                  ? null
                  : () => _pause(job),
            )
          else if (job.canResume)
            IconButton(
              key: ValueKey('lm1215-job-resume-${job.jobId}'),
              tooltip: s.lm1215Resume,
              icon: const Icon(Icons.play_arrow_rounded),
              onPressed: _busy.contains('resume:${job.jobId}')
                  ? null
                  : () => _resume(job),
            ),
        ],
      ),
    );
  }

  final Map<String, GlobalKey> _menuAnchors = {};

  Widget _modelRow(
    Strings s,
    HermesThemeColors colors,
    LocalModelsStatus status,
    LocalStagedModel model,
  ) {
    final isActive = status.activeModelId == model.id;
    final activating = _jobs.any(
      (j) => j.kind == 'model-activate' && j.isRunning && j.modelId == model.id,
    );
    final stateLabel = activating
        ? s.lm1215Activating
        : status.isLoading(model.id)
        ? s.lm1215StateLoading(status.loadingPercent[model.id] ?? 0)
        : status.isLoaded(model.id)
        ? s.lm1215StateLoaded
        : s.lm1215StateOnDisk;
    final subtitle = [
      model.sizeLabel,
      if (model.quant != null) model.quant!,
      stateLabel,
    ].where((e) => e.isNotEmpty).join(' · ');
    final anchor = _menuAnchors.putIfAbsent(model.id, GlobalKey.new);
    final busy = _busy.any((k) => k.endsWith(':${model.id}'));
    return HermesListRow(
      key: ValueKey('lm1215-model-${model.id}'),
      leading: ProviderLogo(
        key: ValueKey('provider-logo-local-${model.id}'),
        model: model.id,
        size: 20,
        selected: isActive,
      ),
      title: model.id,
      subtitle: subtitle,
      subtitleMaxLines: 2,
      showChevron: false,
      onTap: () => _openMenu(model, anchor),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isActive)
            HermesTag(
              key: ValueKey('lm1215-active-${model.id}'),
              label: s.lm1215StateDefault,
              tone: HermesStatusTone.active,
            ),
          if (busy)
            const Padding(
              padding: EdgeInsets.all(12),
              child: SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              key: ValueKey('lm1215-model-menu-${model.id}'),
              tooltip: s.lm1215MoreActions,
              icon: Icon(Icons.more_vert_rounded, key: anchor),
              onPressed: () => _openMenu(model, anchor),
            ),
        ],
      ),
    );
  }

  Widget _catalogRow(
    Strings s,
    HermesThemeColors colors,
    LocalCatalogModel model,
  ) {
    final downloading = _jobs.any(
      (j) => j.kind == 'model-download' && j.isActive && j.modelId == model.id,
    );
    final meta = [
      model.sizeLabel,
      if (model.quant != null) model.quant!,
      if (model.recommended) s.lm1215Recommended,
    ].where((e) => e.isNotEmpty).join(' · ');
    final summary = model.fitSummary.isNotEmpty
        ? model.fitSummary
        : model.description;
    Widget trailing;
    if (model.downloaded) {
      trailing = HermesTag(
        label: s.lm1215Downloaded,
        tone: HermesStatusTone.ok,
      );
    } else if (model.needsEngine) {
      trailing = HermesTag(label: s.lm1215NeedsEngine);
    } else if (!model.fits) {
      trailing = HermesTag(label: s.lm1215TooBig, tone: HermesStatusTone.error);
    } else {
      trailing = _SmallButton(
        key: ValueKey('lm1215-catalog-${model.id}'),
        label: s.lm1215Download,
        busy: downloading || _busy.contains('download:${model.id}'),
        onPressed: () => _download(model),
      );
    }
    return HermesListRow(
      key: ValueKey('lm1215-catalog-row-${model.id}'),
      icon: model.recommended
          ? Icons.auto_awesome_rounded
          : Icons.cloud_download_outlined,
      iconColor: model.recommended ? colors.accent : null,
      title: model.displayName,
      subtitle: [meta, summary].where((e) => e.isNotEmpty).join('\n'),
      subtitleMaxLines: 3,
      showChevron: false,
      trailing: trailing,
    );
  }
}

/// Hugging Face browser (`/api/local-models/search`, `/search/files`,
/// `/download-browsed`), Desktop's "Browse more models". Pops `true` when a
/// download job started so the caller resumes job polling.
class LocalModelsSearchScreen extends StatefulWidget {
  const LocalModelsSearchScreen({required this.client, super.key});

  final LocalModelsClient client;

  @override
  State<LocalModelsSearchScreen> createState() =>
      _LocalModelsSearchScreenState();
}

class _LocalModelsSearchScreenState extends State<LocalModelsSearchScreen> {
  final _query = TextEditingController();
  List<HfSearchHit>? _hits;
  bool _searching = false;
  String? _error;
  String? _openingRepo;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final q = _query.text.trim();
    if (q.isEmpty) return;
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final hits = await widget.client.search(q);
      if (!mounted) return;
      setState(() => _hits = hits);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is LocalModelsException && e.detail.isNotEmpty
            ? e.detail
            : e.toString();
      });
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  String _fitLabel(Strings s, String fit) => switch (fit) {
    'fits-gpu' => s.lm1215FitGpu,
    'needs-ram' => s.lm1215FitRam,
    'too-big' => s.lm1215FitTooBig,
    _ => s.lm1215FitUnknown,
  };

  Future<void> _openRepo(HfSearchHit hit) async {
    final s = Strings.of(context);
    setState(() => _openingRepo = hit.repo);
    List<HfFileGroup> files;
    try {
      files = await widget.client.repoFiles(hit.repo);
    } catch (e) {
      if (!mounted) return;
      setState(() => _openingRepo = null);
      _notice(
        s.lm1215ActionFailed(
          e is LocalModelsException && e.detail.isNotEmpty
              ? e.detail
              : e.toString(),
        ),
        error: true,
      );
      return;
    }
    if (!mounted) return;
    setState(() => _openingRepo = null);
    if (files.isEmpty) {
      _notice(s.lm1215FilesEmpty, error: true);
      return;
    }
    final picked = await showHermesOptions<HfFileGroup>(
      context: context,
      title: s.lm1215FilesTitle,
      subtitle: hit.repo,
      options: [
        for (final group in files)
          HermesOption(
            key: ValueKey('lm1215-file-${group.label}'),
            value: group,
            label: group.label,
            subtitle:
                '${formatLocalBytes(group.totalBytes)} · ${_fitLabel(s, group.fit)}',
            icon: Icons.download_rounded,
            enabled: group.fit != 'too-big' && group.paths.isNotEmpty,
          ),
      ],
      equals: (a, b) => a.label == b.label,
    );
    if (picked == null || !mounted) return;
    try {
      final start = await widget.client.downloadBrowsed(hit.repo, picked.paths);
      if (!mounted) return;
      if (start.alreadyDownloaded || start.jobId == null) {
        _notice(s.lm1215AlreadyDownloaded);
        Navigator.of(context).pop(false);
        return;
      }
      _notice(s.lm1215DownloadStarted(start.modelId ?? picked.label));
      Navigator.of(context).pop(true);
    } catch (e) {
      _notice(
        s.lm1215ActionFailed(
          e is LocalModelsException && e.detail.isNotEmpty
              ? e.detail
              : e.toString(),
        ),
        error: true,
      );
    }
  }

  void _notice(String message, {bool error = false}) {
    if (!mounted) return;
    HermesNotice.of(context).showSnackBar(
      SnackBar(content: Text(message)),
      kind: error ? HermesNoticeKind.error : HermesNoticeKind.success,
    );
  }

  String _compact(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)} M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)} k';
    return '$n';
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final hits = _hits;
    return HermesPage(
      title: s.lm1215SearchTitle,
      children: [
        TextField(
          key: const ValueKey('lm1215-search-field'),
          controller: _query,
          autofocus: true,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _search(),
          decoration: InputDecoration(
            hintText: s.lm1215SearchHint,
            prefixIcon: const Icon(Icons.search_rounded),
            suffixIcon: _searching
                ? const Padding(
                    padding: EdgeInsets.all(14),
                    child: SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : IconButton(
                    key: const ValueKey('lm1215-search-go'),
                    icon: const Icon(Icons.arrow_forward_rounded),
                    tooltip: s.designSearch,
                    onPressed: _search,
                  ),
          ),
        ),
        const SizedBox(height: 6),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Text(
            s.lm1215SearchSubtitle,
            style: HermesType.caption.copyWith(
              color: colors.textSecondary,
              letterSpacing: 0,
            ),
          ),
        ),
        if (_error != null)
          _Message(icon: Icons.cloud_off_rounded, text: _error!)
        else if (hits != null && hits.isEmpty)
          _Message(icon: Icons.search_off_rounded, text: s.lm1215SearchEmpty)
        else if (hits != null) ...[
          const SizedBox(height: 12),
          HermesListGroup(
            children: [
              for (final hit in hits)
                HermesListRow(
                  key: ValueKey('lm1215-hit-${hit.repo}'),
                  icon: Icons.inventory_2_outlined,
                  title: hit.repo,
                  subtitle: hit.gated
                      ? s.lm1215SearchGated
                      : s.lm1215SearchStats(
                          _compact(hit.downloads),
                          _compact(hit.likes),
                        ),
                  trailing: _openingRepo == hit.repo
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : null,
                  onTap: _openingRepo == null ? () => _openRepo(hit) : null,
                ),
            ],
          ),
        ],
      ],
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.text,
    this.detail,
    super.key,
  });

  final IconData icon;
  final String text;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 40, 12, 12),
      child: Column(
        children: [
          Icon(icon, size: 36, color: colors.textDisabled),
          const SizedBox(height: 12),
          Text(
            text,
            textAlign: TextAlign.center,
            style: HermesType.body.copyWith(color: colors.textPrimary),
          ),
          if (detail != null) ...[
            const SizedBox(height: 6),
            Text(
              detail!,
              textAlign: TextAlign.center,
              style: HermesType.caption.copyWith(
                color: colors.textSecondary,
                letterSpacing: 0,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SmallButton extends StatelessWidget {
  const _SmallButton({
    required this.label,
    required this.onPressed,
    this.busy = false,
    super.key,
  });

  final String label;
  final VoidCallback onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    if (busy) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16),
        child: SizedBox.square(
          dimension: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(foregroundColor: colors.accentHover),
      child: Text(label),
    );
  }
}
