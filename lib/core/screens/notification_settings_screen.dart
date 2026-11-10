import 'dart:async';
import 'dart:io';
// Notification settings. With the app open its own sockets raise local
// notices; with it closed the opt-in background listening keeps alerting; a running
// turn is also followed (30 min) and announced without it. The user
// chooses which events.
import 'package:flutter/material.dart';

import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/app_localizations.dart';
import '../../main.dart';
import '../design/hermes_design.dart' show HermesOption, HermesSelectField;
import '../services/notifications/background_listener.dart';
import '../services/notifications/cron_notice_policy.dart';
import '../services/notifications/notification_service.dart';
import '../services/notifications/rich_notifications.dart';
import '../theme/app_theme.dart';
import '../widgets/battery_optimization_row.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/hermes_ui.dart';
import '../feedback/feedback_policy.dart';
import '../design/modal.dart' show showHermesDialogRoute;
import '../theme/hermes_tokens.dart';

class NotificationSettingsScreen extends StatefulWidget {
  const NotificationSettingsScreen({super.key});

  @override
  State<NotificationSettingsScreen> createState() =>
      _NotificationSettingsScreenState();
}

class _NotificationSettingsScreenState
    extends State<NotificationSettingsScreen> {
  NotificationService? _notif;
  SharedPreferences? _prefs;
  bool _granted = false;
  ChannelStatus _channel = ChannelStatus.missing;
  bool _loading = true;

  /// Opt-in listening (same key and semantics as 1.3.1): the shared service
  /// polls Cron, Kanban and rooms while the app is closed. Off until the
  /// user switches it on here.
  bool _bgRunning = false;
  bool _bgBusy = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = context.findAncestorStateOfType<HermesAppState>();
    _notif ??= app?.notifications;
    _prefs ??= app?.connManager.prefs;
    if (_loading) _refresh();
  }

  Future<void> _refresh() async {
    final granted = await _notif?.permissionGranted() ?? false;
    final channel = await _notif?.alertChannelStatus() ?? ChannelStatus.missing;
    final optIn = _prefs?.getBool(BackgroundListener.prefKey) == true;
    if (!mounted) return;
    setState(() {
      _granted = granted;
      _channel = channel;
      _bgRunning = optIn;
      _loading = false;
    });
  }

  /// The 1.3.1 switch: turning it on needs the notification permission,
  /// writes the shared opt-in key, syncs the watched connections and starts
  /// the service; turning it off stops it and clears the key.
  Future<void> _toggleBackground(bool v) async {
    final app = context.findAncestorStateOfType<HermesAppState>();
    setState(() => _bgBusy = true);
    if (v && !_granted) {
      final granted = await _requestPermission();
      if (!granted) {
        if (mounted) setState(() => _bgBusy = false);
        return;
      }
    }
    if (v) {
      await _prefs?.setBool(BackgroundListener.prefKey, true);
      if (app != null) {
        await BackgroundCronWatch.syncConnections(
          app.connManager.getConnections(),
        );
      }
    }
    final ok = v ? await BackgroundListener.startForAutomation() : true;
    if (!v) await BackgroundListener.stopAutomation();
    if (v && ok) {
      await _prefs?.setBool(BackgroundListener.prefKey, true);
    } else if (_prefs != null) {
      await BackgroundListener.recordOptOut(_prefs!);
    }
    if (v && !ok) await BackgroundCronWatch.syncConnections(const []);
    if (!mounted) return;
    setState(() {
      _bgRunning = v && ok;
      _bgBusy = false;
    });
    if (v && !ok) {
      AppFeedback.notify(
        context,
        FeedbackKind.error,
        Strings.of(context).notifListenerStartFailed,
      );
    }
  }

  /// Pide el permiso y RE-COMPRUEBA contra el sistema (el diálogo puede ni
  /// mostrarse tras una denegación permanente en Android 13+). Devuelve si
  /// quedó concedido. Sin plugin de ajustes ni canal nativo para abrir la
  /// pantalla del sistema, si sigue denegado explicamos la ruta manual
  /// (spec 028 A-020).
  Future<bool> _requestPermission() async {
    final s = Strings.of(context);
    await _notif?.requestPermission();
    final ok = await _notif?.permissionGranted() ?? false;
    if (!mounted) return ok;
    setState(() => _granted = ok);
    if (!ok) {
      await showHermesDialogRoute<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(s.notifPermCardTitle),
          content: Text(s.notifPermManualRoute),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(s.commonClose),
            ),
          ],
        ),
      );
    }
    return ok;
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final notif = _notif;
    return Scaffold(
      backgroundColor: colors.background,
      appBar: HermesAppBar(title: Text(s.notifTitle)),
      body: notif == null
          ? Center(child: Text(s.commonNotAvailable))
          : ListView(
              clipBehavior: hermesUnderHeader,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
              children: [
                if (!_loading &&
                    (!_granted || _channel != ChannelStatus.active)) ...[
                  const SizedBox(height: 12),
                  _diagnosticsCard(colors, s),
                ],
                if (!_granted && !_loading) ...[
                  const SizedBox(height: 8),
                  _permissionCard(colors, s),
                ],
                HermesSectionHeader(s.nrdAlertsTitle),
                HermesGroup(
                  children: [
                    _masterSwitch(colors, notif, s),
                    ..._eventSwitches(colors, notif, s),
                    _foregroundSwitch(colors, notif, s),
                    if (Platform.isAndroid) _keepAliveSwitch(colors, notif, s),
                    if (Platform.isAndroid) _listenerSwitch(colors, notif, s),
                    if (Platform.isAndroid) _liveUpdatesRow(s),
                    // M6: si Android puede frenar la app en segundo plano.
                    if (Platform.isAndroid)
                      BatteryOptimizationRow(
                        prefs: _prefs,
                        load: PlatformRichNotifications().batteryStatus,
                        openSettings:
                            PlatformRichNotifications().openBatterySettings,
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                _testButton(colors, notif, s),
              ],
            ),
    );
  }

  /// Android 16 Live Updates of a turn or room at work: the system screen
  /// where the promotion can be allowed or refused. The ongoing card is
  /// posted by the app itself while it is alive.
  Widget _liveUpdatesRow(Strings s) {
    return ListTile(
      key: const ValueKey('notif-live-updates-settings'),
      dense: true,
      title: Text(s.notifLiveUpdatesTitle),
      subtitle: Text(s.notifLiveUpdatesSub),
      trailing: const Icon(Icons.open_in_new_rounded, size: 18),
      onTap: () =>
          unawaited(PlatformRichNotifications().openPromotionSettings()),
    );
  }

  /// Diagnóstico visible del estado real de las notificaciones. La causa más
  /// común de "no me llegan en el móvil" no es la app sino: permiso del sistema
  /// no concedido, o el canal bloqueado por el usuario. Lo mostramos sin rodeos.
  Widget _diagnosticsCard(HermesThemeColors colors, Strings s) {
    final channelOk = _channel == ChannelStatus.active;
    final (String channelLabel, bool channelGood) = switch (_channel) {
      ChannelStatus.active => (s.notifChannelActive, true),
      ChannelStatus.blocked => (s.notifChannelBlocked, false),
      ChannelStatus.missing => (s.notifChannelMissing, false),
    };
    return HermesPanel(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.health_and_safety_outlined,
                  size: 16,
                  color: colors.accent,
                ),
                const SizedBox(width: 8),
                Text(
                  s.notifDiagSection,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: colors.textPrimary,
                  ),
                ),
                const Spacer(),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: s.notifRefreshTooltip,
                  onPressed: _refresh,
                  icon: Icon(
                    Icons.refresh_rounded,
                    size: 18,
                    color: colors.textSecondary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            _diagRow(
              label: s.notifPermLabel,
              value: _granted ? s.notifPermGranted : s.notifPermDenied,
              good: _granted,
            ),
            const SizedBox(height: 6),
            _diagRow(
              label: s.notifChannelLabel,
              value: channelLabel,
              good: channelGood,
            ),
            if (!_granted) ...[
              const SizedBox(height: 10),
              Text(
                s.notifNoPermWarning,
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.4,
                  color: colors.textSecondary,
                ),
              ),
            ] else if (!channelOk) ...[
              const SizedBox(height: 10),
              Text(
                _channel == ChannelStatus.blocked
                    ? s.notifChannelBlockedWarning
                    : s.notifChannelMissingWarning,
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.4,
                  color: colors.textSecondary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _diagRow({
    required String label,
    required String value,
    required bool good,
  }) => HermesNotificationDiagnosticRow(label: label, value: value, good: good);

  Widget _permissionCard(HermesThemeColors colors, Strings s) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: colors.warning.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: colors.warning.withValues(alpha: 0.35)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.notifications_off_outlined,
                  size: 16,
                  color: colors.warning,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    s.notifPermCardTitle,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: colors.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              s.notifPermCardSub,
              style: TextStyle(
                fontSize: 11.5,
                color: colors.textSecondary,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                onPressed: _requestPermission,
                icon: const Icon(Icons.check_rounded, size: 16),
                label: Text(s.notifGrantButton),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _masterSwitch(
    HermesThemeColors colors,
    NotificationService notif,
    Strings s,
  ) {
    return HermesSwitchTile(
      secondary: Icon(
        Icons.notifications_active_outlined,
        color: colors.textSecondary,
      ),
      title: s.nrdMasterTitle,
      subtitle: s.nrdMasterSub,
      value: notif.enabled,
      onChanged: (v) async {
        if (!v) {
          // Master off ends the opt-in listening too (as in 1.3.1).
          await BackgroundListener.stopAutomation();
          if (mounted) setState(() => _bgRunning = false);
        }
        await notif.setEnabled(v);
        if (v && !_granted) await _requestPermission();
        if (mounted) setState(() {});
      },
    );
  }

  /// Approvals, questions and turn done are raised by the open app; goals and
  /// runs only while the app is open; scheduled jobs and Kanban cards also by
  /// the opt-in background listening.
  List<Widget> _eventSwitches(
    HermesThemeColors colors,
    NotificationService notif,
    Strings s,
  ) {
    final on = notif.enabled;
    return [
      _eventSwitch(
        colors,
        enabled: on,
        icon: Icons.verified_user_outlined,
        title: s.notifApprovalsTitle,
        subtitle: s.notifApprovalsSub,
        value: notif.notifyApprovals,
        onChanged: (v) async {
          await notif.setNotifyApprovals(v);
          if (mounted) setState(() {});
        },
      ),
      _eventSwitch(
        colors,
        enabled: on,
        icon: Icons.help_outline_rounded,
        title: s.nrdQuestionsTitle,
        subtitle: s.nrdQuestionsSub,
        value: notif.notifyQuestions,
        onChanged: (v) async {
          await notif.setNotifyQuestions(v);
          if (mounted) setState(() {});
        },
      ),
      _eventSwitch(
        colors,
        enabled: on,
        icon: Icons.chat_bubble_outline,
        title: s.nrdDoneTitle,
        subtitle: s.nrdDoneSub,
        value: notif.notifyReplies,
        onChanged: (v) async {
          await notif.setNotifyReplies(v);
          if (mounted) setState(() {});
        },
      ),
      _eventSwitch(
        colors,
        enabled: on,
        icon: Icons.flag_outlined,
        title: s.notifLocalAgentResultsTitle,
        subtitle: s.notifLocalAgentResultsSub,
        value: notif.notifyLocalAgentResults,
        onChanged: (v) async {
          await notif.setNotifyLocalAgentResults(v);
          if (mounted) setState(() {});
        },
      ),
      _eventSwitch(
        colors,
        enabled: on,
        icon: Icons.task_alt_outlined,
        title: s.notifRunsTitle,
        subtitle: s.notifRunsSub,
        value: notif.notifyRuns,
        onChanged: (v) async {
          await notif.setNotifyRuns(v);
          if (mounted) setState(() {});
        },
      ),
      Padding(
        padding: const EdgeInsets.all(HermesSpace.x4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            HermesSelectField<CronNoticeMode>(
              key: const ValueKey('notif-cron-mode'),
              title: s.pekCronSwitchTitle,
              decoration: InputDecoration(labelText: s.pekCronSwitchTitle),
              value: notif.cronNoticeMode,
              options: [
                HermesOption(
                  value: CronNoticeMode.automatic,
                  label: s.cronNoticeAutomatic,
                ),
                HermesOption(value: CronNoticeMode.all, label: s.cronNoticeAll),
                HermesOption(
                  value: CronNoticeMode.failuresOnly,
                  label: s.cronNoticeFailuresOnly,
                ),
                HermesOption(value: CronNoticeMode.off, label: s.cronNoticeOff),
              ],
              onChanged: on
                  ? (mode) async {
                      await notif.setCronNoticeMode(mode);
                      if (mounted) setState(() {});
                    }
                  : null,
            ),
            const SizedBox(height: HermesSpace.x2),
            Text(
              '${s.cronNoticeAutomaticHint}\n${s.cronNoticeAutomaticRepliesHint}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      _eventSwitch(
        colors,
        enabled: on,
        icon: Icons.view_kanban_outlined,
        title: s.pekKanbanSwitchTitle,
        subtitle: s.pekKanbanSwitchSub,
        value: notif.notifyKanbanResults,
        onChanged: (v) async {
          await notif.setNotifyKanbanResults(v);
          if (mounted) setState(() {});
        },
      ),
    ];
  }

  Widget _foregroundSwitch(
    HermesThemeColors colors,
    NotificationService notif,
    Strings s,
  ) {
    return _eventSwitch(
      colors,
      enabled: notif.enabled,
      icon: Icons.visibility_outlined,
      title: s.notifForegroundTitle,
      subtitle: s.notifForegroundSub,
      value: notif.evenInForeground,
      onChanged: (v) async {
        await notif.setEvenInForeground(v);
        if (mounted) setState(() {});
      },
    );
  }

  /// A running turn keeps its connection while the app is away (a short
  /// foreground service, see `TurnKeepAliveController`). Like Desktop's
  /// keep-awake «while working», on by default and independent of the
  /// alerts: it is about the connection, not about notices.
  Widget _keepAliveSwitch(
    HermesThemeColors colors,
    NotificationService notif,
    Strings s,
  ) {
    return KeyedSubtree(
      key: const ValueKey('notif-keepalive-while-working'),
      child: _eventSwitch(
        colors,
        enabled: true,
        icon: Icons.sync_alt_rounded,
        title: s.notifKeepAliveTitle,
        subtitle: s.notifKeepAliveSub,
        value: notif.keepAliveWhileWorking,
        onChanged: (v) async {
          await notif.setKeepAliveWhileWorking(v);
          if (mounted) setState(() {});
        },
      ),
    );
  }

  /// Opt-in listening for Cron, Kanban and rooms with the app closed. Never
  /// starts on its own: only this switch turns it on.
  Widget _listenerSwitch(
    HermesThemeColors colors,
    NotificationService notif,
    Strings s,
  ) {
    final on = _bgRunning && notif.enabled;
    return KeyedSubtree(
      key: const ValueKey('notif-background-listener'),
      child: Column(
        children: [
          HermesSwitchTile(
            secondary: _bgBusy
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    Icons.podcasts_rounded,
                    color: notif.enabled
                        ? colors.textSecondary
                        : colors.textDisabled,
                  ),
            title: s.notifBgTitle,
            subtitle: on ? s.notifBgActive : s.notifBgSub,
            value: on,
            onChanged: (notif.enabled && !_bgBusy) ? _toggleBackground : null,
          ),
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(16, 0, 16, 10),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(
                on ? s.notifBgRestartNotice : s.au1215BgNeededForAutomation,
                style: HermesType.support.copyWith(color: colors.textSecondary),
              ),
            ),
          ),
          // The fixed "Connected to Hermes" card is Android's condition for
          // staying connected; its own category screen is where it can be
          // minimised. Only there is a card while the listening runs.
          if (Platform.isAndroid && _bgRunning && on)
            ListTile(
              key: const ValueKey('notif-fixed-card-settings'),
              dense: true,
              title: Text(s.notifFixedCardTitle),
              subtitle: Text(s.notifFixedCardSub),
              trailing: const Icon(Icons.open_in_new_rounded, size: 18),
              onTap: () => unawaited(
                PlatformRichNotifications().openChannelSettings(
                  BackgroundListener.serviceChannelId,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _eventSwitch(
    HermesThemeColors colors, {
    required bool enabled,
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return HermesSwitchTile(
      secondary: Icon(
        icon,
        color: enabled ? colors.textSecondary : colors.textDisabled,
      ),
      title: title,
      subtitle: subtitle,
      value: value && enabled,
      onChanged: enabled ? onChanged : null,
    );
  }

  Widget _testButton(
    HermesThemeColors colors,
    NotificationService notif,
    Strings s,
  ) {
    return HermesSecondaryButton(
      icon: Icons.send_rounded,
      label: s.notifTestButton,
      onTap: () async {
        if (!_granted) await _requestPermission();
        if (!_granted) return;
        final sent = await notif.sendTest();
        await _refresh();
        if (!mounted) return;
        AppFeedback.notify(
          context,
          sent ? FeedbackKind.routine : FeedbackKind.error,
          sent ? s.notifTestSent : s.notifTestFailed,
        );
      },
    );
  }
}

/// Fila de diagnóstico que conserva la lectura natural con texto ampliado.
/// A escala normal mantiene el valor a la derecha; con accesibilidad alta lo
/// coloca debajo para no reducir la etiqueta a una columna de pocas letras.
class HermesNotificationDiagnosticRow extends StatelessWidget {
  final String label;
  final String value;
  final bool good;

  const HermesNotificationDiagnosticRow({
    super.key,
    required this.label,
    required this.value,
    required this.good,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final largeText = MediaQuery.textScalerOf(context).scale(1) > 1.3;
    final labelWidget = Text(
      label,
      style: TextStyle(fontSize: 12.5, color: colors.textPrimary),
    );
    final valueWidget = Text(
      value,
      textAlign: largeText ? TextAlign.start : TextAlign.end,
      style: TextStyle(
        fontSize: 12.5,
        fontWeight: FontWeight.w600,
        color: good ? colors.success : colors.warning,
      ),
    );

    return Row(
      crossAxisAlignment: largeText
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.center,
      children: [
        Icon(
          good ? Icons.check_circle_rounded : Icons.cancel_rounded,
          size: 16,
          color: good ? colors.success : colors.warning,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: largeText
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    labelWidget,
                    const SizedBox(height: 2),
                    valueWidget,
                  ],
                )
              : Row(
                  children: [
                    Expanded(child: labelWidget),
                    const SizedBox(width: 8),
                    Flexible(child: valueWidget),
                  ],
                ),
        ),
      ],
    );
  }
}
