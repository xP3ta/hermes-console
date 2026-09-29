import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../l10n/app_localizations.dart';
import '../../main.dart';
import '../screens/local_instance_control_screen.dart';
import '../screens/onboarding/server_setup_screen.dart';
import '../services/bridge_client.dart';
import '../services/bridge_manager.dart';
import '../services/bridge_repair_service.dart';
import '../services/bridge_update_service.dart';
import '../services/connection_manager.dart';
import '../services/notifications/notification_service.dart';
import '../theme/app_theme.dart';
import '../utils/transport_privacy.dart';
import 'hermes_premium_ui.dart';

typedef StatusReachabilityProbe = Future<bool> Function(String url);

/// Outcome of logging in to the Dashboard with the saved credentials.
enum DashboardAuthCheck { ok, loginRequired, invalidCredentials, unknown }

typedef DashboardAuthProbe =
    Future<DashboardAuthCheck> Function(SavedConnection connection);

/// Outcome of calling the Gateway API with the saved key.
enum GatewayKeyCheck { ok, rejected, unknown }

typedef GatewayKeyProbe =
    Future<GatewayKeyCheck> Function(SavedConnection connection);

Future<void> showInstanceStatusSheet(
  BuildContext context,
  SavedConnection connection,
) {
  final appState = context.findAncestorStateOfType<HermesAppState>();
  return showHermesFloatingSurface<void>(
    context: context,
    surfaceKey: const ValueKey('instance-status-surface'),
    maxWidth: 520,
    maxHeightFactor: 0.84,
    builder: (_) => InstanceStatusPanel(
      connection: connection,
      bridgeManager: appState?.bridgeManager,
      notifications: appState?.notifications,
      connManager: appState?.connManager,
    ),
  );
}

enum _Health { ok, warn, bad, unknown }

enum _LabelKind { gateway, dashboard, bridge, localAgent, notifications }

enum _DetailKind {
  connected,
  offline,
  notEnabled,
  needsToken,
  wrongPassword,
  loginRequired,
  keyRejected,
  running,
  stopped,
  enabled,
  disabled,
}

class _RawRow {
  final _LabelKind label;
  final _Health health;
  final _DetailKind detail;
  const _RawRow(this.label, this.health, this.detail);
}

class InstanceStatusPanel extends StatefulWidget {
  final SavedConnection connection;
  final BridgeManagerContract? bridgeManager;
  final NotificationService? notifications;
  final ConnectionManager? connManager;
  final BridgeRepairUpdater? updater;
  final StatusReachabilityProbe? reachable;
  final DashboardAuthProbe? dashboardAuth;
  final GatewayKeyProbe? gatewayKey;

  const InstanceStatusPanel({
    super.key,
    required this.connection,
    required this.bridgeManager,
    this.notifications,
    this.connManager,
    this.updater,
    this.reachable,
    this.dashboardAuth,
    this.gatewayKey,
  });

  @override
  State<InstanceStatusPanel> createState() => _InstanceStatusPanelState();
}

class _InstanceStatusPanelState extends State<InstanceStatusPanel> {
  bool _loading = false;
  bool _repairing = false;
  List<_RawRow>? _rows;
  BridgeState? _bridgeState;
  BridgeRepairStage? _stage;
  BridgeRepairResult? _repairResult;
  int _generation = 0;

  bool _current(int generation) => mounted && generation == _generation;

  @override
  void initState() {
    super.initState();
    _probe();
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  Future<void> _probe() async {
    if (_loading || _repairing) return;
    final generation = ++_generation;
    setState(() => _loading = true);
    final conn = widget.connection;
    final isLocal = conn.kind == InstanceKind.localhost;

    final firstFuture = _reachable(
      isLocal
          ? '${conn.effectiveDashboardUrl}/api/status'
          : '${conn.gatewayUrl}/health',
    );
    final dashboardFuture = isLocal
        ? null
        : _reachable('${conn.effectiveDashboardUrl}/api/status');
    final bridgeFuture = widget.bridgeManager
        ?.probe(conn.id)
        .timeout(
          const Duration(seconds: 6),
          onTimeout: () => BridgeState.unknown,
        );
    final notificationFuture = widget.notifications?.permissionGranted();

    final first = await firstFuture;
    // /health answers without the key; the chat API needs it, so a reachable
    // remote Gateway is only "connected" once the saved key is accepted.
    final key = first && !isLocal
        ? await _gatewayKey(conn)
        : GatewayKeyCheck.unknown;
    final dashboard = await dashboardFuture;
    // A public /api/status only proves the Dashboard is up; chat and Bot Mode
    // need the saved login too, so check it before calling the row healthy.
    final auth = dashboard == true
        ? await _dashboardAuth(conn)
        : DashboardAuthCheck.unknown;
    final bridge = await bridgeFuture;
    final notifications = await notificationFuture;
    if (!_current(generation)) return;

    final rows = <_RawRow>[];
    rows.add(
      isLocal
          ? _RawRow(
              _LabelKind.localAgent,
              first ? _Health.ok : _Health.bad,
              first ? _DetailKind.running : _DetailKind.stopped,
            )
          : !first
          ? const _RawRow(_LabelKind.gateway, _Health.bad, _DetailKind.offline)
          : key == GatewayKeyCheck.rejected
          ? const _RawRow(
              _LabelKind.gateway,
              _Health.warn,
              _DetailKind.keyRejected,
            )
          : const _RawRow(
              _LabelKind.gateway,
              _Health.ok,
              _DetailKind.connected,
            ),
    );
    if (!isLocal) {
      rows.add(switch ((dashboard == true, auth)) {
        (false, _) => const _RawRow(
          _LabelKind.dashboard,
          _Health.bad,
          _DetailKind.offline,
        ),
        (true, DashboardAuthCheck.invalidCredentials) => const _RawRow(
          _LabelKind.dashboard,
          _Health.warn,
          _DetailKind.wrongPassword,
        ),
        (true, DashboardAuthCheck.loginRequired) => const _RawRow(
          _LabelKind.dashboard,
          _Health.warn,
          _DetailKind.loginRequired,
        ),
        (true, _) => const _RawRow(
          _LabelKind.dashboard,
          _Health.ok,
          _DetailKind.connected,
        ),
      });
    }
    if (bridge != null) {
      _bridgeState = bridge;
      final mapped = switch (bridge.status) {
        BridgeStatus.connected => (_Health.ok, _DetailKind.connected),
        BridgeStatus.needsToken ||
        BridgeStatus.authFailed => (_Health.warn, _DetailKind.needsToken),
        _ => (_Health.unknown, _DetailKind.notEnabled),
      };
      rows.add(_RawRow(_LabelKind.bridge, mapped.$1, mapped.$2));
    }
    if (notifications != null) {
      rows.add(
        _RawRow(
          _LabelKind.notifications,
          notifications ? _Health.ok : _Health.warn,
          notifications ? _DetailKind.enabled : _DetailKind.disabled,
        ),
      );
    }
    setState(() {
      _rows = rows;
      _loading = false;
    });
  }

  Future<void> _repair() async {
    final manager = widget.bridgeManager;
    final initial = _bridgeState;
    if (manager == null || initial == null || _repairing) return;
    final generation = ++_generation;
    setState(() {
      _repairing = true;
      _stage = BridgeRepairStage.contacting;
      _repairResult = null;
    });
    // Let the immediate contacting state reach the screen before any synchronous
    // stage callback advances the repair workflow.
    await WidgetsBinding.instance.endOfFrame;
    if (!_current(generation)) return;
    final updater = widget.updater ?? _defaultUpdater;
    final service = BridgeRepairService(manager: manager, updater: updater);
    final result = await service.repair(
      widget.connection,
      initial: initial,
      onStage: (stage) {
        if (_current(generation)) setState(() => _stage = stage);
      },
    );
    if (!_current(generation)) return;
    setState(() {
      _repairing = false;
      _stage = null;
      _repairResult = result;
      if (result.success) {
        _bridgeState = BridgeState(
          status: BridgeStatus.connected,
          url: '',
          urlIsDerived: true,
          hasToken: true,
          caps: const BridgeCapabilities(online: true, authValid: true),
        );
        final index =
            _rows?.indexWhere((row) => row.label == _LabelKind.bridge) ?? -1;
        if (index >= 0) {
          _rows![index] = const _RawRow(
            _LabelKind.bridge,
            _Health.ok,
            _DetailKind.connected,
          );
        }
      }
    });
  }

  Future<BridgeUpdateResult> _defaultUpdater(
    SavedConnection connection, {
    void Function(BridgeRepairStage stage)? onProgress,
  }) => BridgeUpdateService.update(
    connection,
    forceRemoteRepair: true,
    onProgress: (_) => onProgress?.call(BridgeRepairStage.restarting),
    verificationTimeout: const Duration(seconds: 24),
    verificationRetryDelay: const Duration(seconds: 2),
  );

  Future<DashboardAuthCheck> _dashboardAuth(SavedConnection conn) async {
    final injected = widget.dashboardAuth;
    if (injected != null) return injected(conn);
    final manager = widget.connManager;
    if (manager == null) return DashboardAuthCheck.unknown;
    DashboardClient? client;
    try {
      final secrets = await manager.getDashboardSecrets(conn.id);
      client = DashboardClient.forConnection(conn, secrets: secrets);
      await client.authHeadersForDiagnostics().timeout(
        const Duration(seconds: 6),
      );
      return DashboardAuthCheck.ok;
    } on DashboardAuthException catch (error) {
      return switch (error.code) {
        DashboardAuthFailureCode.invalidCredentials =>
          DashboardAuthCheck.invalidCredentials,
        DashboardAuthFailureCode.loginRequired =>
          DashboardAuthCheck.loginRequired,
        _ => DashboardAuthCheck.unknown,
      };
    } catch (_) {
      return DashboardAuthCheck.unknown;
    } finally {
      client?.close();
    }
  }

  Future<GatewayKeyCheck> _gatewayKey(SavedConnection conn) async {
    final injected = widget.gatewayKey;
    if (injected != null) return injected(conn);
    final client = http.Client();
    try {
      final base = TransportPrivacy.requireAllowed(conn.gatewayUrl);
      final res = await client
          .get(
            Uri.parse('$base/api/sessions'),
            headers: {'Authorization': 'Bearer ${conn.apiKey}'},
          )
          .timeout(const Duration(seconds: 6));
      if (res.statusCode == 401 || res.statusCode == 403) {
        return GatewayKeyCheck.rejected;
      }
      return res.statusCode == 200
          ? GatewayKeyCheck.ok
          : GatewayKeyCheck.unknown;
    } catch (_) {
      return GatewayKeyCheck.unknown;
    } finally {
      client.close();
    }
  }

  Future<bool> _reachable(String url) async {
    final injected = widget.reachable;
    if (injected != null) return injected(url);
    final client = http.Client();
    try {
      final safeUrl = TransportPrivacy.requireAllowed(url);
      final response = await client
          .get(Uri.parse(safeUrl))
          .timeout(const Duration(seconds: 6));
      return response.statusCode >= 200 && response.statusCode < 500;
    } catch (_) {
      return false;
    } finally {
      client.close();
    }
  }

  void _openLocalControl() {
    final manager = widget.connManager;
    if (manager == null) return;
    final navigator = Navigator.of(context);
    navigator.pop();
    navigator.push(
      MaterialPageRoute(
        builder: (_) => LocalInstanceControlScreen(
          connection: widget.connection,
          connManager: manager,
        ),
      ),
    );
  }

  void _openManualSetup() {
    final manager = widget.connManager;
    if (manager == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ServerSetupScreen(connManager: manager),
      ),
    );
  }

  String _label(_LabelKind kind, Strings s) => switch (kind) {
    _LabelKind.gateway => 'Gateway',
    _LabelKind.dashboard => 'Dashboard',
    _LabelKind.bridge => 'Mobile Bridge',
    _LabelKind.localAgent => s.statusLocalAgent,
    _LabelKind.notifications => s.statusNotifications,
  };

  String _detail(_DetailKind kind, Strings s) => switch (kind) {
    _DetailKind.connected => s.statusConnected,
    _DetailKind.offline => s.statusOffline,
    _DetailKind.wrongPassword => s.statusWrongPassword,
    _DetailKind.loginRequired => s.statusLoginRequired,
    _DetailKind.keyRejected => s.statusKeyRejected,
    _DetailKind.notEnabled => s.statusNotEnabled,
    _DetailKind.needsToken => s.statusNeedsToken,
    _DetailKind.running => s.statusRunning,
    _DetailKind.stopped => s.statusStopped,
    _DetailKind.enabled => s.statusEnabled,
    _DetailKind.disabled => s.statusDisabled,
  };

  String _stageText(Strings s) => switch (_stage) {
    BridgeRepairStage.contacting => s.statusBridgeContacting,
    BridgeRepairStage.reprovisioning => s.statusBridgeReprovisioning,
    BridgeRepairStage.installing ||
    BridgeRepairStage.restarting => s.statusBridgeInstalling,
    BridgeRepairStage.verifying => s.statusBridgeVerifying,
    null => '',
  };

  String _failureText(
    BridgeRepairFailure failure,
    Strings s,
  ) => switch (failure) {
    BridgeRepairFailure.timeout => s.statusBridgeErrorTimeout,
    BridgeRepairFailure.unreachable => s.statusBridgeErrorUnreachable,
    BridgeRepairFailure.tls => s.statusBridgeErrorTls,
    BridgeRepairFailure.authRejected => s.statusBridgeErrorAuth,
    BridgeRepairFailure.provisionDisabled =>
      s.statusBridgeErrorProvisionDisabled,
    BridgeRepairFailure.unexpectedHttp => s.statusBridgeErrorHttp,
    BridgeRepairFailure.invalidResponse => s.statusBridgeErrorInvalidResponse,
    BridgeRepairFailure.secureStorage => s.statusBridgeErrorStorage,
    BridgeRepairFailure.repairUnsupported => s.statusBridgeErrorUnsupported,
    BridgeRepairFailure.repairFailed => s.statusBridgeErrorFailed,
    BridgeRepairFailure.verificationFailed => s.statusBridgeErrorVerification,
    BridgeRepairFailure.readOnly => s.statusBridgeErrorReadOnly,
    BridgeRepairFailure.missingApiKey => s.statusBridgeErrorMissingKey,
    BridgeRepairFailure.localControlRequired => s.statusBridgeLocalControl,
  };

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 12, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    s.statusPanelTitle,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.6,
                      color: colors.accentHover,
                    ),
                  ),
                ),
                if (_loading)
                  const SizedBox.square(
                    dimension: 24,
                    child: Padding(
                      padding: EdgeInsets.all(4),
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else
                  IconButton(
                    icon: const Icon(Icons.refresh, size: 18),
                    tooltip: s.statusRefresh,
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    color: colors.accentHover,
                    onPressed: _repairing ? null : _probe,
                  ),
              ],
            ),
            if (_rows == null && _loading)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(s.statusChecking),
              )
            else
              for (final row in _rows ?? const <_RawRow>[])
                _rowTile(row, colors, s),
          ],
        ),
      ),
    );
  }

  Widget _rowTile(_RawRow row, HermesThemeColors colors, Strings s) {
    final mapped = switch (row.health) {
      _Health.ok => (Icons.circle, colors.success),
      _Health.warn => (Icons.circle, colors.warning),
      _Health.bad => (Icons.circle, colors.error),
      _Health.unknown => (Icons.circle_outlined, colors.textSecondary),
    };
    final bridge = row.label == _LabelKind.bridge;
    final down = bridge && row.health != _Health.ok;
    final local = widget.connection.kind == InstanceKind.localhost;
    final result = bridge ? _repairResult : null;

    return Padding(
      key: ValueKey('instance-status-row-${row.label.name}'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Row(
              children: [
                Icon(mapped.$1, size: 11, color: mapped.$2),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _label(row.label, s),
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                Text(
                  _detail(row.detail, s),
                  style: TextStyle(fontSize: 12, color: colors.textSecondary),
                ),
              ],
            ),
          ),
          if (down || result != null) ...[
            if (_repairing && bridge)
              Semantics(
                liveRegion: true,
                label: _stageText(s),
                child: Row(
                  children: [
                    const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: Text(_stageText(s))),
                  ],
                ),
              )
            else if (result?.success == true)
              Semantics(
                liveRegion: true,
                child: Text(s.statusBridgeRepairSuccess),
              )
            else if (result?.category != null)
              Semantics(
                liveRegion: true,
                child: Text(
                  _failureText(result!.category!, s),
                  style: TextStyle(color: colors.error),
                ),
              ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (!_repairing && !local)
                  Semantics(
                    button: true,
                    label: result == null
                        ? s.statusBridgeRepair
                        : s.statusBridgeRetry,
                    child: FilledButton.tonal(
                      onPressed: widget.connection.readOnly ? null : _repair,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(48, 48),
                      ),
                      child: Text(
                        result == null
                            ? s.statusBridgeRepair
                            : s.statusBridgeRetry,
                      ),
                    ),
                  ),
                if (!_repairing && local)
                  FilledButton.tonal(
                    onPressed: _bridgeState?.running == true
                        ? _repair
                        : _openLocalControl,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(48, 48),
                    ),
                    child: Text(
                      _bridgeState?.running == true
                          ? s.statusBridgeRepair
                          : s.statusBridgeLocalControl,
                    ),
                  ),
                if (!_repairing && result?.manualAction == true)
                  OutlinedButton(
                    onPressed: widget.connManager == null
                        ? null
                        : _openManualSetup,
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(48, 48),
                    ),
                    child: Text(s.statusBridgeManualSetup),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
