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

  const InstanceStatusPanel({
    super.key,
    required this.connection,
    required this.bridgeManager,
    this.notifications,
    this.connManager,
    this.updater,
    this.reachable,
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
    final dashboard = await dashboardFuture;
    final bridge = await bridgeFuture;
    final notifications = await notificationFuture;
    if (!_current(generation)) return;

    final rows = <_RawRow>[];
    rows.add(
      _RawRow(
        isLocal ? _LabelKind.localAgent : _LabelKind.gateway,
        first ? _Health.ok : _Health.bad,
        isLocal
            ? (first ? _DetailKind.running : _DetailKind.stopped)
            : (first ? _DetailKind.connected : _DetailKind.offline),
      ),
    );
    if (!isLocal) {
      rows.add(
        _RawRow(
          _LabelKind.dashboard,
          dashboard == true ? _Health.ok : _Health.bad,
          dashboard == true ? _DetailKind.connected : _DetailKind.offline,
        ),
      );
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
