// Cron detail page (spec 080, mock screen 1): ONE page scroll, inline
// status (no boxed "SCHEDULED" pill), Run now + Pause, "What it does" as a
// HermesTextBlock, visible notification toggles and the last runs as rows.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../design/hermes_design.dart';
import '../models/cron_job.dart';
import '../models/session.dart';
import '../utils/session_title.dart';
import '../services/cron_repository.dart';
import '../services/notifications/notification_mute_store.dart';
import '../services/notifications/notification_service.dart';
import '../models/agent_profile.dart';
import '../services/tui_gateway_client.dart';
import '../theme/app_theme.dart';
import '../widgets/hermes_notice.dart';
import '../widgets/mission_profile_avatar.dart';

@visibleForTesting
const cronDetailRefreshInterval = Duration(seconds: 60);

bool _isCronRefreshEvent(TuiGatewayEvent event) =>
    event.type == 'cron.changed' || event.type == 'sessions.changed';

/// Human status of a job: label + tone. Normal scheduling stays neutral.
({String label, HermesStatusTone tone}) cronStatusOf(Strings s, CronJob job) {
  String cap(String v) => v.isEmpty ? v : v[0].toUpperCase() + v.substring(1);
  return switch (job.state) {
    CronJobState.enabled || CronJobState.scheduled => (
      label: cap(s.crnStatusActive),
      tone: HermesStatusTone.ok,
    ),
    CronJobState.running => (
      label: cap(s.crnStatusRunning),
      tone: HermesStatusTone.active,
    ),
    CronJobState.paused => (
      label: cap(s.crnStatusPaused),
      tone: HermesStatusTone.warn,
    ),
    CronJobState.disabled => (
      label: cap(s.crnStatusDisabled),
      tone: HermesStatusTone.neutral,
    ),
    CronJobState.error => (
      label: cap(s.crnStatusError),
      tone: HermesStatusTone.error,
    ),
    CronJobState.completed => (
      label: cap(s.crnStatusCompleted),
      tone: HermesStatusTone.neutral,
    ),
    CronJobState.unknown => (
      label: cap(s.crnStatusActive),
      tone: HermesStatusTone.neutral,
    ),
  };
}

DateTime? cronParseTime(Object? raw) {
  if (raw == null) return null;
  if (raw is num && raw.isFinite) {
    return DateTime.fromMillisecondsSinceEpoch((raw * 1000).round());
  }
  return DateTime.tryParse(raw.toString())?.toLocal();
}

/// Short, human time: "18:30" today, "Mon 28, 18:30" otherwise.
String cronShortTime(Strings s, Object? raw, {DateTime? now}) {
  final date = cronParseTime(raw);
  if (date == null) return raw == null ? s.crnNever : raw.toString();
  return hermesFormatNextRun(s, date, now: now);
}

/// Human schedule of a job (from the real expression, never a fixed 09:00
/// and never the raw cron / interval syntax).
String cronScheduleLabel(Strings s, CronJob job) {
  final expr = job.scheduleExpression.trim();
  return describeHermesSchedule(
    s,
    expr.isNotEmpty ? expr : job.scheduleDisplay,
  );
}

/// Human name of a bot profile: its Bot Mode title, the profile display
/// name, else the slug made readable (`console-radar` → `Console radar`).
String cronBotName(String profile, {AgentProfile? info}) {
  final title = info?.botTitle?.trim();
  if (title != null && title.isNotEmpty) return title;
  final display = info?.displayName.trim() ?? '';
  if (display.isNotEmpty) return display;
  final words = profile.trim().replaceAll(RegExp(r'[-_]+'), ' ').trim();
  if (words.isEmpty) return profile;
  return '${words[0].toUpperCase()}${words.substring(1)}';
}

/// Human destination: `local` → "Only save on the server", `bot-chat` /
/// `bot-chat:<bot>` → "Atlas chat", `telegram:123` → "Telegram".
String cronDeliveryLabel(
  String value,
  Strings s, {
  String ownProfile = '',
  AgentProfile? Function(String profile)? profileInfo,
}) {
  final v = value.trim();
  if (v.isEmpty || v == 'local') return s.crnDeliveryLocal;
  final colon = v.indexOf(':');
  final platform = colon < 0 ? v : v.substring(0, colon);
  final target = colon < 0 ? '' : v.substring(colon + 1).trim();
  if (platform == 'bot-chat') {
    final bot = target.isEmpty || target == '(own)'
        ? (ownProfile.isEmpty ? 'default' : ownProfile)
        : target;
    return s.crnDeliveryBotChat(cronBotName(bot, info: profileInfo?.call(bot)));
  }
  if (platform == 'origin') return s.crnDeliveryOrigin;
  final words = platform.replaceAll(RegExp(r'[-_]+'), ' ').trim();
  return words.isEmpty
      ? v
      : words
            .split(' ')
            .map(
              (w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}',
            )
            .join(' ');
}

/// Owner of a bot routine: the bot's face + "Radar's routine".
class CronOwnerLine extends StatelessWidget {
  final String profile;
  final AgentProfile? info;
  final MissionProfileAvatarCache? avatarCache;
  final double faceSize;
  final String? trailing;

  const CronOwnerLine({
    super.key,
    required this.profile,
    this.info,
    this.avatarCache,
    this.faceSize = 20,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final name = cronBotName(profile, info: info);
    final label = trailing == null ? s.crnOwnerBot(name) : '$name · $trailing';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        MissionProfileAvatar(
          profileName: profile,
          hasAvatar: info?.hasAvatar ?? false,
          cache: avatarCache,
          size: faceSize,
          shape: info?.botFaceShape,
          colorHex: info?.botColorHex,
          imageKind: info?.botImageKind,
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: HermesType.support.copyWith(color: colors.textSecondary),
          ),
        ),
      ],
    );
  }
}

/// The detail route. Owns its authoritative job snapshot; every mutation
/// updates this route and reports the read-back to the list via [onChanged].
class CronJobDetailPage extends StatefulWidget {
  final CronJob initialJob;
  final CronRepository repository;
  final bool readOnly;
  final Stream<TuiGatewayEvent>? eventStream;
  final String connectionId;
  final String profile;
  final NotificationService? notifications;

  /// Opens the editor; returns the updated job or null when cancelled.
  final Future<CronJob?> Function(CronJob job)? onEdit;

  /// Confirms and deletes; true when the job is gone.
  final Future<bool> Function(CronJob job)? onDelete;
  final ValueChanged<CronJob>? onChanged;
  final ValueChanged<Session> onOpenRun;

  /// Opens notification settings when the global Cron opt-in is off.
  final VoidCallback? onOpenNotificationSettings;

  /// Bot profile metadata (face, title) by profile name, when known.
  final AgentProfile? Function(String profile)? profileInfo;
  final MissionProfileAvatarCache? avatarCache;

  const CronJobDetailPage({
    super.key,
    required this.initialJob,
    required this.repository,
    required this.readOnly,
    required this.connectionId,
    required this.profile,
    required this.onOpenRun,
    this.eventStream,
    this.notifications,
    this.onEdit,
    this.onDelete,
    this.onChanged,
    this.onOpenNotificationSettings,
    this.profileInfo,
    this.avatarCache,
  });

  @override
  State<CronJobDetailPage> createState() => _CronJobDetailPageState();
}

class _CronJobDetailPageState extends State<CronJobDetailPage>
    with WidgetsBindingObserver {
  late CronJob _job = widget.initialJob;
  CronRuns? _runs;
  Timer? _timer;
  Timer? _debounce;
  StreamSubscription<TuiGatewayEvent>? _events;
  bool _loading = true;
  bool _fetching = false;
  bool _busy = false;
  final GlobalKey _moreKey = GlobalKey(debugLabel: 'cron-detail-more');

  bool get _refreshAllowed =>
      mounted &&
      WidgetsBinding.instance.lifecycleState != AppLifecycleState.paused &&
      WidgetsBinding.instance.lifecycleState != AppLifecycleState.hidden &&
      ModalRoute.of(context)?.isCurrent != false;

  /// Backstop refresh while visible. It sleeps while the app is hidden or
  /// paused and restarts on resume after an immediate refresh.
  void _armRefreshTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(cronDetailRefreshInterval, (_) {
      if (_refreshAllowed) unawaited(_refresh());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        if (_timer != null) return;
        _armRefreshTimer();
        if (_refreshAllowed) unawaited(_refresh());
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _timer?.cancel();
        _timer = null;
      case AppLifecycleState.inactive:
        break;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh());
    _armRefreshTimer();
    _events = widget.eventStream?.listen((event) {
      if (!_refreshAllowed || !_isCronRefreshEvent(event)) return;
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 350), () {
        if (_refreshAllowed) unawaited(_refresh());
      });
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _debounce?.cancel();
    unawaited(_events?.cancel());
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

  void _apply(CronJob updated) {
    if (!mounted) return;
    setState(() => _job = updated.id.isEmpty ? _job : updated);
    widget.onChanged?.call(_job);
  }

  void _failure(Object error) {
    if (!mounted) return;
    HermesNotice.show(
      context,
      message: Strings.of(context).crnFailed(error.toString()),
      kind: HermesNoticeKind.error,
    );
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      _failure(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _trigger() => _run(() async {
    final updated = await widget.repository.trigger(_job);
    _apply(updated);
    if (mounted) {
      HermesNotice.show(
        context,
        message: Strings.of(context).crnJobTriggered,
        kind: HermesNoticeKind.success,
      );
    }
    unawaited(_refresh());
  });

  Future<void> _pauseResume() => _run(() async {
    final wasPaused = _job.isPaused;
    final updated = await widget.repository.pauseOrResume(_job);
    _apply(updated);
    if (mounted) {
      final s = Strings.of(context);
      HermesNotice.show(
        context,
        message: wasPaused ? s.crnJobResumed : s.crnJobPaused,
      );
    }
  });

  Future<void> _editSchedule() async {
    if (widget.readOnly ||
        _job.isScriptOnly && _job.scheduleExpression.isEmpty) {
      return;
    }
    final cron = await showHermesScheduleBuilder(
      context,
      initialCron: _job.scheduleExpression,
    );
    if (cron == null || !mounted || cron == _job.scheduleExpression) return;
    await _run(() async {
      final updated = await widget.repository.update(
        _job,
        name: _job.name,
        prompt: _job.prompt,
        schedule: cron,
        deliver: _job.deliver,
        model: _job.model,
        provider: _job.provider,
      );
      _apply(updated);
      if (mounted) {
        HermesNotice.show(
          context,
          message: Strings.of(context).crnJobUpdated,
          kind: HermesNoticeKind.success,
        );
      }
    });
  }

  Future<void> _more() async {
    final s = Strings.of(context);
    final action = await showHermesMenu<String>(
      context: context,
      anchorKey: _moreKey,
      surfaceKey: const ValueKey('cron-detail-menu'),
      actions: [
        if (widget.onEdit != null)
          HermesAction(
            key: const ValueKey('cron-detail-edit'),
            value: 'edit',
            icon: Icons.edit_outlined,
            label: s.commonEdit,
          ),
        if (widget.onDelete != null)
          HermesAction(
            key: const ValueKey('cron-detail-delete'),
            value: 'delete',
            icon: Icons.delete_outline_rounded,
            label: s.crnDeleteTask,
            destructive: true,
          ),
      ],
    );
    if (!mounted) return;
    if (action == 'edit') {
      final updated = await widget.onEdit!(_job);
      if (updated != null) _apply(updated);
    } else if (action == 'delete') {
      final deleted = await widget.onDelete!(_job);
      if (deleted && mounted) Navigator.of(context).pop();
    }
  }

  // ── notifications ────────────────────────────────────────────────────────

  CronNotifyPolicy get _policy =>
      widget.notifications?.muteStore.cronPolicy(
        connId: widget.connectionId,
        profile: _job.profile.isNotEmpty ? _job.profile : widget.profile,
        jobId: _job.id,
      ) ??
      CronNotifyPolicy.all;

  Future<void> _setPolicy(CronNotifyPolicy policy) async {
    final notif = widget.notifications;
    if (notif == null) return;
    await notif.muteStore.setCronPolicy(
      connId: widget.connectionId,
      profile: _job.profile.isNotEmpty ? _job.profile : widget.profile,
      jobId: _job.id,
      policy: policy,
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final status = cronStatusOf(s, _job);
    final next = _job.isPaused ? null : _job.nextRunAt;
    final meta = next == null
        ? (_job.lastRunAt == null
              ? null
              : s.crnLastShort(cronShortTime(s, _job.lastRunAt)))
        : s.crnNextShort(cronShortTime(s, next));
    final notif = widget.notifications;
    final policy = _policy;
    final notifyOn = policy != CronNotifyPolicy.off;
    final globalOff = notif != null && !notif.notifyCronResults;
    final canMutate = !widget.readOnly;
    final hasMore =
        canMutate && (widget.onEdit != null || widget.onDelete != null);

    final owner = _job.ownerBot;
    final jobProfile = _job.profile.isNotEmpty ? _job.profile : widget.profile;
    return HermesDetailScaffold(
      listKey: const ValueKey('cron-job-detail'),
      title: _job.title,
      eyebrow: owner == null
          ? null
          : CronOwnerLine(
              key: const ValueKey('cron-detail-owner'),
              profile: owner,
              info: widget.profileInfo?.call(owner),
              avatarCache: widget.avatarCache,
            ),
      onRefresh: _refresh,
      status: HermesStatusText(
        key: const ValueKey('cron-detail-status'),
        label: status.label,
        tone: status.tone,
        meta: meta,
      ),
      primaryAction: canMutate
          ? HermesActionButton(
              key: const ValueKey('cron-detail-run'),
              primary: true,
              icon: Icons.play_arrow_rounded,
              label: s.crnRunNow,
              onPressed: _busy ? null : _trigger,
            )
          : null,
      secondaryAction: canMutate
          ? HermesActionButton(
              key: const ValueKey('cron-detail-pause'),
              label: _job.isPaused ? s.crnResume : s.crnPause,
              onPressed: _busy ? null : _pauseResume,
            )
          : null,
      actions: [
        if (hasMore)
          IconButton(
            key: _moreKey,
            tooltip: s.crnMore,
            icon: const Icon(Icons.more_vert_rounded),
            onPressed: _more,
          ),
      ],
      sections: [
        if (_job.lastError != null) ...[
          const SizedBox(height: HermesSpace.x3),
          HermesInlineNotice(
            key: const ValueKey('cron-detail-error'),
            icon: Icons.error_outline_rounded,
            tone: HermesStatusTone.error,
            message: _job.lastError!,
          ),
        ],
        HermesSectionHeader(s.crnWhen),
        HermesListGroup(
          children: [
            HermesListRow(
              key: const ValueKey('cron-detail-schedule'),
              icon: Icons.schedule_rounded,
              title: cronScheduleLabel(s, _job),
              subtitle: next == null
                  ? null
                  : s.schNextRun(cronShortTime(s, next)),
              onTap: canMutate ? _editSchedule : null,
            ),
          ],
        ),
        if (_job.preview.isNotEmpty) ...[
          HermesSectionHeader(s.crnWhatItDoes),
          HermesTextBlock(
            key: const ValueKey('cron-detail-prompt'),
            text: _job.preview,
            mono: _job.isScriptOnly && _job.prompt.isEmpty,
            copyable: true,
            openTitle: _job.title,
          ),
        ],
        HermesSectionHeader(s.crnNotifications),
        HermesListGroup(
          dividerIndent: HermesSpace.rowH,
          children: [
            HermesToggleRow(
              key: const ValueKey('cron-detail-notify'),
              switchKey: const ValueKey('cron-notify-switch'),
              title: s.crnNotifyFinish,
              value: notifyOn,
              onChanged: notif == null
                  ? null
                  : (v) => _setPolicy(
                      v ? CronNotifyPolicy.all : CronNotifyPolicy.off,
                    ),
            ),
            HermesToggleRow(
              key: const ValueKey('cron-detail-notify-fail'),
              switchKey: const ValueKey('cron-notify-fail-switch'),
              title: s.crnNotifyFailOnly,
              value: policy == CronNotifyPolicy.failuresOnly,
              onChanged: notif == null || !notifyOn
                  ? null
                  : (v) => _setPolicy(
                      v ? CronNotifyPolicy.failuresOnly : CronNotifyPolicy.all,
                    ),
            ),
          ],
        ),
        if (globalOff) ...[
          const SizedBox(height: HermesSpace.x1),
          HermesInlineNotice(
            key: const ValueKey('cron-detail-global-off'),
            icon: Icons.notifications_off_outlined,
            message: s.crnNotifyGlobalOff,
            actionLabel: widget.onOpenNotificationSettings == null
                ? null
                : s.crnNotifyGlobalOffAction,
            onAction: widget.onOpenNotificationSettings,
          ),
        ],
        HermesSectionHeader(s.crnDetails),
        HermesListGroup(
          dividerIndent: HermesSpace.rowH,
          children: [
            HermesListRow(
              key: const ValueKey('cron-detail-delivery'),
              title: s.crnDeliveryLabel,
              value: cronDeliveryLabel(
                _job.deliver,
                s,
                ownProfile: jobProfile,
                profileInfo: widget.profileInfo,
              ),
            ),
            if (_job.model.isNotEmpty)
              HermesListRow(title: s.crnModelLabel, value: _job.model),
            HermesListRow(
              title: s.crnLastRunLabel,
              value: cronShortTime(s, _job.lastRunAt),
            ),
            if (jobProfile.isNotEmpty)
              HermesListRow(
                key: const ValueKey('cron-detail-profile'),
                title: s.crnProfileLabel,
                value: cronBotName(
                  jobProfile,
                  info: widget.profileInfo?.call(jobProfile),
                ),
              ),
          ],
        ),
        HermesSectionHeader(
          _runs?.sessions.isNotEmpty ?? false
              ? '${s.crnLastRuns} · ${_runs!.sessions.length}'
              : s.crnLastRuns,
        ),
        _runsGroup(s, colors),
      ],
    );
  }

  Widget _runsGroup(Strings s, HermesThemeColors colors) {
    if (_loading) {
      return const HermesListGroup(
        children: [
          SizedBox(
            height: 52,
            child: Center(
              child: SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
        ],
      );
    }
    final runs = _runs;
    if (runs == null || runs.sessions.isEmpty || !runs.available) {
      return HermesListGroup(
        children: [
          HermesListRow(
            muted: true,
            title: runs?.available == false
                ? s.crnHistoryUnavailable
                : s.crnNoRuns,
          ),
        ],
      );
    }
    return HermesListGroup(
      dividerIndent: HermesSpace.rowH,
      children: [
        for (final session in runs.sessions.take(10))
          _RunRow(session: session, onTap: () => widget.onOpenRun(session)),
      ],
    );
  }
}

class _RunRow extends StatelessWidget {
  final Session session;
  final VoidCallback onTap;

  const _RunRow({required this.session, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final reason = (session.endReason ?? '').toLowerCase();
    final failed =
        reason.contains('error') ||
        reason.contains('fail') ||
        reason.contains('exception');
    final (String label, HermesStatusTone tone) = session.isActive
        ? (s.crnRunRunning, HermesStatusTone.active)
        : failed
        ? (s.crnRunFailed, HermesStatusTone.error)
        : (s.crnRunCompleted, HermesStatusTone.ok);
    final started = session.startedAt > 0
        ? DateTime.fromMillisecondsSinceEpoch(
            (session.startedAt * 1000).round(),
          )
        : null;
    final ended = session.endedAt;
    String? duration;
    if (ended != null && session.startedAt > 0 && ended >= session.startedAt) {
      final secs = (ended - session.startedAt).round();
      duration = secs < 90 ? '$secs s' : '${(secs / 60).round()} min';
    }
    final when = started == null
        ? localizedSessionTitle(s, session)
        : hermesFormatNextRun(s, started);
    return Semantics(
      button: true,
      label: '${s.crnOpenRun}: $when, $label',
      excludeSemantics: true,
      child: HermesListRow(
        leading: Container(
          width: 8,
          height: 8,
          margin: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(
            color: tone.colorIn(colors),
            shape: BoxShape.circle,
          ),
        ),
        title: when,
        value: [label, ?duration].join(' · '),
        onTap: onTap,
      ),
    );
  }
}
