import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../../main.dart';
import '../services/app_lock.dart';
import '../services/connection_manager.dart';
import '../services/notifications/notification_service.dart';
import '../services/screen_security.dart';
import '../theme/app_theme.dart';
import '../widgets/hermes_notice.dart';
import '../widgets/hermes_ui.dart';
import 'lock_screen.dart';
import '../widgets/hermes_app_bar.dart';

/// Centro de seguridad: bloqueo local accionable (PIN/biometría), gestión de
/// credenciales y el modelo de seguridad de la app. Las afirmaciones
/// informativas deben mantenerse en sincronía con docs/SECURITY_POLICY.md.
class SecurityInfoScreen extends StatefulWidget {
  final ConnectionManager connManager;
  const SecurityInfoScreen({required this.connManager, super.key});

  @override
  State<SecurityInfoScreen> createState() => _SecurityInfoScreenState();
}

class _SecurityInfoScreenState extends State<SecurityInfoScreen> {
  AppLockService? _lock;
  NotificationService? _notifications;
  late ScreenSecurityService _screenSecurity;
  bool _biometricsSupported = false;
  bool _servicesLoaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_lock == null) {
      final app = context.findAncestorStateOfType<HermesAppState>();
      _lock = app?.appLock;
      _notifications = app?.notifications;
      _screenSecurity = ScreenSecurityService(widget.connManager.prefs);
      _servicesLoaded = true;
      _checkBiometrics();
    }
  }

  Future<void> _checkBiometrics() async {
    final supported = await _lock?.canUseBiometrics() ?? false;
    if (mounted) setState(() => _biometricsSupported = supported);
  }

  // ── Bloqueo local ─────────────────────────────────────────────────────

  /// Pide un PIN nuevo (dos veces) en una RUTA dedicada. Devuelve el PIN o
  /// null si se canceló.
  ///
  /// Antes era un `showDialog` con dos `TextField`: al descartarlo con un campo
  /// enfocado saltaba `_dependents.isEmpty` (un `EditableText` seguía
  /// registrado como dependiente del FocusScope que se desmontaba). Ahora es
  /// una pantalla propia ([_PinSetupScreen]) que SIEMPRE suelta el foco antes
  /// de hacer pop — misma estrategia robusta que la LockScreen.
  Future<String?> _askNewPin() {
    return Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        fullscreenDialog: true,
        builder: (_) => const _PinSetupScreen(),
      ),
    );
  }

  Future<void> _toggleLock(bool enable) async {
    final lock = _lock;
    if (lock == null) return;
    if (enable) {
      final pin = await _askNewPin();
      if (pin == null) return;
      await lock.setPin(pin);
      await lock.enable();
    } else {
      if (!mounted) return;
      final s = Strings.of(context);
      final ok = await LockScreen.verify(
        context,
        lock,
        reason: s.secVerifyDisableLock,
      );
      if (!ok) return;
      await lock.disable();
    }
    if (mounted) setState(() {});
  }

  Future<void> _changePin() async {
    final lock = _lock;
    if (lock == null) return;
    final s = Strings.of(context);
    final ok = await LockScreen.verify(
      context,
      lock,
      reason: s.secVerifyChangePin,
    );
    if (!ok || !mounted) return;
    final pin = await _askNewPin();
    if (pin == null) return;
    await lock.setPin(pin);
    if (!mounted) return;
    HermesNotice.of(context).showSnackBar(
      SnackBar(content: Text(Strings.of(context).secPinUpdated)),
      kind: HermesNoticeKind.success,
    );
  }

  Future<void> _toggleBiometric(bool value) async {
    final lock = _lock;
    if (lock == null) return;
    if (value) {
      final s = Strings.of(context);
      final ok = await lock.authenticateBiometric(
        reason: s.secVerifyBiometrics,
      );
      if (!ok) return;
    }
    await lock.setBiometricEnabled(value);
    if (mounted) setState(() {});
  }

  // ── Credenciales ──────────────────────────────────────────────────────

  Future<void> _wipeCredentials() async {
    final lock = _lock;
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    if (lock != null) {
      final verified = await LockScreen.verify(
        context,
        lock,
        reason: s.secVerifyWipe,
      );
      if (!verified || !mounted) return;
    }
    final count = widget.connManager.getConnections().length;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.secWipeTitle),
        content: Text(s.secWipeContent(count)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(s.secCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(s.secWipeButton, style: TextStyle(color: colors.error)),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    await widget.connManager.wipeAllApiKeys();
    if (!mounted) return;
    HermesNotice.of(context).showSnackBar(
      SnackBar(content: Text(Strings.of(context).secKeysWiped)),
      kind: HermesNoticeKind.success,
    );
  }

  SavedConnection? _activeConnection() {
    final activeId =
        widget.connManager.activeConnectionId.value ??
        widget.connManager.prefs.getString(ConnectionManager.lastConnKey);
    for (final connection in widget.connManager.getConnections()) {
      if (connection.id == activeId) return connection;
    }
    final connections = widget.connManager.getConnections();
    return connections.isEmpty ? null : connections.first;
  }

  ({String label, String detail, bool ok}) _connectionStatus(Strings s) {
    final connection = _activeConnection();
    if (connection == null) {
      return (
        label: s.secConnectionNone,
        detail: s.secConnectionNoneSub,
        ok: false,
      );
    }
    if (connection.useHttps) {
      return (
        label: s.secConnectionHttps,
        detail: s.secConnectionFor(connection.label),
        ok: true,
      );
    }
    // Recalcular desde el host: conexiones antiguas pueden conservar `kind=vps`
    // aunque su host haya cambiado después a LAN, Tailscale o loopback.
    final networkKind = inferInstanceKind(connection.host);
    if (networkKind == InstanceKind.tailscale) {
      return (
        label: s.secConnectionTailscale,
        detail: s.secConnectionFor(connection.label),
        ok: true,
      );
    }
    if (networkKind == InstanceKind.homelab ||
        networkKind == InstanceKind.localhost) {
      return (
        label: s.secConnectionPrivateHttp,
        detail: s.secConnectionFor(connection.label),
        ok: true,
      );
    }
    return (
      label: s.secConnectionPublicHttp,
      detail: s.secConnectionPublicHttpSub(connection.label),
      ok: false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final lock = _lock;
    final notifications = _notifications;
    final connectionStatus = _connectionStatus(s);
    return Scaffold(
      appBar: HermesAppBar(
        title: Text(
          s.secTitle,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            letterSpacing: 1.5,
            color: colors.accentHover,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _SectionLabel(s.secSectionLock),
          Card(
            margin: const EdgeInsets.only(bottom: 10),
            child: Column(
              children: [
                HermesSwitchTile(
                  secondary: Icon(Icons.lock_outline, color: colors.accent),
                  title: s.secLockTitle,
                  subtitle: s.secLockSubtitle,
                  value: lock?.enabled ?? false,
                  onChanged: lock == null ? null : _toggleLock,
                ),
                if (lock != null && lock.enabled) ...[
                  Divider(
                    height: 0,
                    indent: 16,
                    endIndent: 16,
                    color: colors.divider,
                  ),
                  HermesSwitchTile(
                    secondary: Icon(
                      Icons.fingerprint,
                      color: _biometricsSupported
                          ? colors.accent
                          : colors.textDisabled,
                    ),
                    title: s.secBioTitle,
                    subtitle: _biometricsSupported
                        ? s.secBioSubtitle
                        : s.secBioUnavailable,
                    value: lock.biometricEnabled && _biometricsSupported,
                    onChanged: _biometricsSupported ? _toggleBiometric : null,
                  ),
                  Divider(
                    height: 0,
                    indent: 16,
                    endIndent: 16,
                    color: colors.divider,
                  ),
                  ListTile(
                    leading: Icon(
                      Icons.timer_outlined,
                      color: colors.textSecondary,
                    ),
                    title: Text(s.secLockTimeout),
                    trailing: DropdownButton<int>(
                      value: lock.timeoutSeconds,
                      style: Theme.of(context).dropdownMenuTheme.textStyle,
                      underline: const SizedBox.shrink(),
                      items: [
                        DropdownMenuItem(
                          value: 0,
                          child: Text(s.secTimeoutInstant),
                        ),
                        DropdownMenuItem(
                          value: 60,
                          child: Text(s.secTimeout1min),
                        ),
                        DropdownMenuItem(
                          value: 300,
                          child: Text(s.secTimeout5min),
                        ),
                        DropdownMenuItem(
                          value: 900,
                          child: Text(s.secTimeout15min),
                        ),
                      ],
                      onChanged: (v) async {
                        if (v == null) return;
                        await lock.setTimeoutSeconds(v);
                        setState(() {});
                      },
                    ),
                  ),
                  Divider(
                    height: 0,
                    indent: 16,
                    endIndent: 16,
                    color: colors.divider,
                  ),
                  ListTile(
                    leading: Icon(
                      Icons.pin_outlined,
                      color: colors.textSecondary,
                    ),
                    title: Text(s.secChangePin),
                    trailing: Icon(
                      Icons.chevron_right,
                      color: colors.textDisabled,
                    ),
                    onTap: _changePin,
                  ),
                ],
              ],
            ),
          ),
          _SectionLabel(s.secSectionPrivacy),
          Card(
            margin: const EdgeInsets.only(bottom: 10),
            child: Column(
              children: [
                HermesSwitchTile(
                  secondary: Icon(
                    Icons.notifications_off_outlined,
                    color: colors.accent,
                  ),
                  title: s.secHideNotificationsTitle,
                  subtitle: s.secHideNotificationsSub,
                  value: notifications?.hideSensitiveContent ?? false,
                  onChanged: notifications == null
                      ? null
                      : (value) async {
                          await notifications.setHideSensitiveContent(value);
                          if (mounted) setState(() {});
                        },
                ),
                Divider(
                  height: 0,
                  indent: 16,
                  endIndent: 16,
                  color: colors.divider,
                ),
                HermesSwitchTile(
                  secondary: Icon(
                    Icons.screenshot_monitor_outlined,
                    color: colors.accent,
                  ),
                  title: s.secBlockScreenshotsTitle,
                  subtitle: s.secBlockScreenshotsSub,
                  value: _servicesLoaded && _screenSecurity.enabled,
                  onChanged: !_servicesLoaded
                      ? null
                      : (value) async {
                          await _screenSecurity.setEnabled(value);
                          if (mounted) setState(() {});
                        },
                ),
              ],
            ),
          ),
          _SectionLabel(s.secSectionStatus),
          Card(
            margin: const EdgeInsets.only(bottom: 10),
            child: Column(
              children: [
                _SecurityStatusRow(
                  icon: connectionStatus.ok
                      ? Icons.enhanced_encryption_outlined
                      : Icons.warning_amber_rounded,
                  title: s.secConnectionTitle,
                  status: connectionStatus.label,
                  detail: connectionStatus.detail,
                  ok: connectionStatus.ok,
                ),
                Divider(
                  height: 0,
                  indent: 16,
                  endIndent: 16,
                  color: colors.divider,
                ),
                _SecurityStatusRow(
                  icon: Icons.key_outlined,
                  title: s.secCredentialStorageTitle,
                  status: s.secStatusProtected,
                  detail: s.secCredentialStorageSub,
                  ok: true,
                ),
                Divider(
                  height: 0,
                  indent: 16,
                  endIndent: 16,
                  color: colors.divider,
                ),
                _SecurityStatusRow(
                  icon: lock?.enabled == true
                      ? Icons.lock_outline
                      : Icons.lock_open_outlined,
                  title: s.secLockTitle,
                  status: lock?.enabled == true
                      ? s.secStatusProtected
                      : s.secStatusReview,
                  detail: lock?.enabled == true
                      ? s.secLockStatusOn
                      : s.secLockStatusOff,
                  ok: lock?.enabled == true,
                ),
              ],
            ),
          ),
          _SectionLabel(s.secSectionCredentials),
          Card(
            margin: const EdgeInsets.only(bottom: 10),
            child: ListTile(
              leading: Icon(Icons.key_off_outlined, color: colors.error),
              title: Text(
                s.secWipeKeysTitle,
                style: TextStyle(color: colors.error),
              ),
              subtitle: Text(
                s.secWipeKeysSubtitle,
                style: TextStyle(fontSize: 12, color: colors.textSecondary),
              ),
              onTap: _wipeCredentials,
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String label;
  const _SectionLabel(this.label);

  @override
  Widget build(BuildContext context) {
    return HermesSectionHeader(
      label,
      padding: const EdgeInsets.fromLTRB(2, 12, 2, 8),
    );
  }
}

class _SecurityStatusRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String status;
  final String detail;
  final bool ok;

  const _SecurityStatusRow({
    required this.icon,
    required this.title,
    required this.status,
    required this.detail,
    required this.ok,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final stateColor = ok ? colors.success : colors.warning;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 13, 14, 13),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 22, color: stateColor),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                          color: colors.textPrimary,
                        ),
                      ),
                    ),
                    Text(
                      status,
                      style: TextStyle(
                        color: stateColor,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  detail,
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.45,
                    color: colors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Pantalla dedicada para configurar/cambiar el PIN (PIN x2 + validación).
///
/// Es una RUTA (no un diálogo) y suelta el foco antes de cualquier `pop`: así
/// no deja un `EditableText` enfocado dependiente del FocusScope que se
/// desmonta —la causa del crash `_dependents.isEmpty` que tenía el diálogo
/// anterior. Devuelve el PIN elegido vía `Navigator.pop`, o null si se cancela.
class _PinSetupScreen extends StatefulWidget {
  const _PinSetupScreen();

  @override
  State<_PinSetupScreen> createState() => _PinSetupScreenState();
}

class _PinSetupScreenState extends State<_PinSetupScreen> {
  final _pinCtrl = TextEditingController();
  final _repeatCtrl = TextEditingController();
  String? _error;

  void _releaseFocus() {
    final f = FocusManager.instance.primaryFocus;
    if (f != null && f.hasFocus) f.unfocus();
  }

  void _cancel() {
    _releaseFocus();
    Navigator.of(context).pop();
  }

  void _save() {
    final s = Strings.of(context);
    final p = _pinCtrl.text;
    if (p.length < 4 || int.tryParse(p) == null) {
      setState(() => _error = s.secPinErrorLength);
      return;
    }
    if (p != _repeatCtrl.text) {
      setState(() => _error = s.secPinErrorMismatch);
      return;
    }
    _releaseFocus();
    Navigator.of(context).pop(p);
  }

  @override
  void deactivate() {
    // Red de seguridad: soltar el foco antes de desmontar pase lo que pase
    // (back del sistema, pop programático).
    _releaseFocus();
    super.deactivate();
  }

  @override
  void dispose() {
    _pinCtrl.dispose();
    _repeatCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return Scaffold(
      appBar: HermesAppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: _cancel,
          tooltip: s.secCancel,
        ),
        title: Text(
          s.secSetupPinTitle,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            letterSpacing: 1.2,
            color: colors.accentHover,
          ),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              s.secPinDescription,
              style: TextStyle(fontSize: 13, color: colors.textSecondary),
            ),
            const SizedBox(height: 20),
            HermesField(
              controller: _pinCtrl,
              autofocus: true,
              obscure: true,
              keyboardType: TextInputType.number,
              label: s.secPinLabel,
              inputFormatters: [LengthLimitingTextInputFormatter(8)],
            ),
            const SizedBox(height: 12),
            HermesField(
              controller: _repeatCtrl,
              obscure: true,
              keyboardType: TextInputType.number,
              label: s.secPinRepeatLabel,
              errorText: _error,
              inputFormatters: [LengthLimitingTextInputFormatter(8)],
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _save,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(s.secPinSave),
              ),
            ),
            const SizedBox(height: 8),
            TextButton(onPressed: _cancel, child: Text(s.secCancel)),
          ],
        ),
      ),
    );
  }
}
