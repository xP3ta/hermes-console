// Ajustes de notificaciones locales. Privacidad: todo on-device, sin FCM ni
// Google; las dispara la propia app. El usuario elige qué eventos avisan.
import 'package:flutter/material.dart';

import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/app_localizations.dart';
import '../../main.dart';
import '../services/notifications/background_listener.dart';
import '../services/notifications/notification_service.dart';
import '../theme/app_theme.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/hermes_ui.dart';

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
  bool _bgRunning = false;
  bool _bgBusy = false;
  bool _loading = true;

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
    final bg = await BackgroundListener.isRunning();
    if (!mounted) return;
    setState(() {
      _granted = granted;
      _channel = channel;
      _bgRunning = bg;
      _loading = false;
    });
  }

  Future<void> _toggleBackground(bool v) async {
    setState(() => _bgBusy = true);
    if (v && !_granted) {
      final granted = await _requestPermission();
      if (!granted) {
        // Sin permiso ninguna alerta puede mostrarse: el switch no se
        // enciende ni se arranca el listener (spec 028 A-021).
        await _prefs?.setBool(BackgroundListener.prefKey, false);
        if (mounted) setState(() => _bgBusy = false);
        return;
      }
    }
    final ok = v ? await BackgroundListener.startForAutomation() : true;
    if (!v) {
      await BackgroundListener.stop();
      await _notif?.setNotifyCronResults(false);
      await _notif?.setNotifyKanbanResults(false);
    }
    await _prefs?.setBool(BackgroundListener.prefKey, v && ok);
    if (!mounted) return;
    setState(() {
      _bgRunning = v && ok;
      _bgBusy = false;
    });
    if (v && !ok) {
      // Mensaje propio del arranque del servicio, no el de la notificación
      // de prueba (spec 028 A-021).
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(Strings.of(context).notifListenerStartFailed)),
      );
    }
  }

  Future<void> _toggleCronResults(NotificationService notif, bool value) async {
    setState(() => _bgBusy = true);
    if (value && !_granted) {
      final granted = await _requestPermission();
      if (!granted) {
        await notif.setNotifyCronResults(false);
        if (mounted) setState(() => _bgBusy = false);
        return;
      }
    }

    if (!mounted) return;
    var enabled = value;
    if (value) {
      final app = context.findAncestorStateOfType<HermesAppState>();
      if (app != null) {
        await BackgroundCronWatch.syncConnections(
          app.connManager.getConnections(),
        );
      }
      enabled = await BackgroundListener.startForAutomation();
      await _prefs?.setBool(BackgroundListener.prefKey, enabled);
    }
    await notif.setNotifyCronResults(enabled);
    if (!mounted) return;
    setState(() {
      _bgRunning = enabled || _bgRunning;
      _bgBusy = false;
    });
    if (value && !enabled) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(Strings.of(context).notifListenerStartFailed)),
      );
    }
  }

  /// Kanban tiene opt-in propio: descubrir transiciones también necesita el
  /// listener en segundo plano, pero activar/desactivar Kanban no toca Cron.
  Future<void> _toggleKanbanResults(
    NotificationService notif,
    bool value,
  ) async {
    setState(() => _bgBusy = true);
    if (value && !_granted) {
      final granted = await _requestPermission();
      if (!granted) {
        await notif.setNotifyKanbanResults(false);
        if (mounted) setState(() => _bgBusy = false);
        return;
      }
    }

    if (!mounted) return;
    var enabled = value;
    if (value) {
      enabled = await BackgroundListener.startForAutomation();
      await _prefs?.setBool(BackgroundListener.prefKey, enabled);
    }
    await notif.setNotifyKanbanResults(enabled);
    if (!mounted) return;
    setState(() {
      _bgRunning = enabled || _bgRunning;
      _bgBusy = false;
    });
    if (value && !enabled) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(Strings.of(context).notifListenerStartFailed)),
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
      await showDialog<void>(
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
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
              children: [
                if (!_loading &&
                    (!_granted || _channel != ChannelStatus.active)) ...[
                  _diagnosticsCard(colors, s),
                  const SizedBox(height: 8),
                ],
                if (!_granted && !_loading) _permissionCard(colors, s),
                // Interruptor maestro + eventos en UNA sola superficie.
                HermesGroup(
                  children: [
                    _masterSwitch(colors, notif, s),
                    ..._eventSwitches(colors, notif, s),
                  ],
                ),
                const SizedBox(height: 8),
                _backgroundCard(colors, notif, s),
                const SizedBox(height: 16),
                _testButton(colors, notif, s),
              ],
            ),
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
      title: s.notifMasterTitle,
      subtitle: s.notifMasterSub,
      value: notif.enabled,
      onChanged: (v) async {
        await notif.setEnabled(v);
        if (v && !_granted) await _requestPermission();
        if (mounted) setState(() {});
      },
    );
  }

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
        icon: Icons.schedule_rounded,
        title: s.notifCronResultsTitle,
        subtitle: s.notifCronResultsSub,
        value: notif.notifyCronResults,
        onChanged: (v) => _toggleCronResults(notif, v),
      ),
      _eventSwitch(
        colors,
        enabled: on,
        icon: Icons.view_kanban_outlined,
        title: s.notifKanbanResultsTitle,
        subtitle: s.notifKanbanResultsSub,
        value: notif.notifyKanbanResults,
        onChanged: (v) => _toggleKanbanResults(notif, v),
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
      _eventSwitch(
        colors,
        enabled: on,
        icon: Icons.chat_bubble_outline,
        title: s.notifRepliesTitle,
        subtitle: s.notifRepliesSub,
        value: notif.notifyReplies,
        onChanged: (v) async {
          await notif.setNotifyReplies(v);
          if (mounted) setState(() {});
        },
      ),
      _eventSwitch(
        colors,
        enabled: on,
        icon: Icons.visibility_outlined,
        title: s.notifForegroundTitle,
        subtitle: s.notifForegroundSub,
        value: notif.evenInForeground,
        onChanged: (v) async {
          await notif.setEvenInForeground(v);
          if (mounted) setState(() {});
        },
      ),
    ];
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

  Widget _backgroundCard(
    HermesThemeColors colors,
    NotificationService notif,
    Strings s,
  ) {
    final on = notif.enabled;
    return HermesPanel(
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
                    color: on ? colors.accent : colors.textDisabled,
                  ),
            title: s.notifBgTitle,
            subtitle: s.notifBgSub,
            value: _bgRunning && on,
            onChanged: (on && !_bgBusy) ? _toggleBackground : null,
          ),
          if (_bgRunning)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Row(
                children: [
                  Icon(Icons.circle, size: 9, color: colors.success),
                  const SizedBox(width: 8),
                  Text(
                    s.notifBgActive,
                    style: TextStyle(fontSize: 11, color: colors.textSecondary),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _testButton(
    HermesThemeColors colors,
    NotificationService notif,
    Strings s,
  ) {
    return OutlinedButton.icon(
      onPressed: () async {
        if (!_granted) await _requestPermission();
        if (!_granted) return;
        final sent = await notif.sendTest();
        await _refresh();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(sent ? s.notifTestSent : s.notifTestFailed)),
        );
      },
      icon: const Icon(Icons.send_rounded, size: 16),
      label: Text(s.notifTestButton),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 14),
        side: BorderSide(color: colors.accent.withValues(alpha: 0.4)),
        foregroundColor: colors.accentHover,
      ),
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
