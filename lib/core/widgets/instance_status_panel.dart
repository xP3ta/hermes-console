import 'dart:async';

import 'package:flutter/material.dart';
import '../services/origin_bound_http_client.dart';
import '../screens/dashboard_sign_in.dart';

import '../../l10n/app_localizations.dart';
import '../../main.dart';
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

/// Logs in to the Dashboard of [conn] with its saved credentials.
Future<DashboardAuthCheck> checkSavedDashboardLogin(
  ConnectionManager manager,
  SavedConnection conn,
) async {
  DashboardClient? client;
  try {
    final secrets = await manager.getDashboardSecrets(conn.id);
    client = DashboardClient.forConnection(conn, secrets: secrets);
    // A saved token/header is not proof that the server accepts it.
    final data = await client
        .apiGet('sessions')
        .timeout(const Duration(seconds: 6));
    return data['sessions'] is List
        ? DashboardAuthCheck.ok
        : DashboardAuthCheck.unknown;
  } on DashboardAuthException catch (error) {
    return switch (error.code) {
      DashboardAuthFailureCode.invalidCredentials =>
        DashboardAuthCheck.invalidCredentials,
      DashboardAuthFailureCode.loginRequired =>
        DashboardAuthCheck.loginRequired,
      _ => DashboardAuthCheck.unknown,
    };
  } on DashboardHttpException catch (error) {
    return error.statusCode == 401 || error.statusCode == 403
        ? DashboardAuthCheck.loginRequired
        : DashboardAuthCheck.unknown;
  } catch (_) {
    return DashboardAuthCheck.unknown;
  } finally {
    client?.close();
  }
}

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
      notifications: appState?.notifications,
      connManager: appState?.connManager,
    ),
  );
}

enum _Health { ok, warn, bad, unknown }

enum _LabelKind { dashboard, notifications }

enum _DetailKind {
  connected,
  offline,
  unavailable,
  wrongPassword,
  loginRequired,
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
  final NotificationService? notifications;
  final ConnectionManager? connManager;
  final StatusReachabilityProbe? reachable;
  final DashboardAuthProbe? dashboardAuth;

  const InstanceStatusPanel({
    super.key,
    required this.connection,
    this.notifications,
    this.connManager,
    this.reachable,
    this.dashboardAuth,
  });

  @override
  State<InstanceStatusPanel> createState() => _InstanceStatusPanelState();
}

class _InstanceStatusPanelState extends State<InstanceStatusPanel> {
  bool _loading = false;
  List<_RawRow>? _rows;
  int _generation = 0;
  Listenable? _ownerChanges;
  Listenable? _ownerWillChange;

  bool _current(int generation) => mounted && generation == _generation;

  @override
  void initState() {
    super.initState();
    _followOwner();
    _probe();
  }

  @override
  void didUpdateWidget(covariant InstanceStatusPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.connection != widget.connection ||
        oldWidget.connManager != widget.connManager) {
      _unfollowOwner();
      _followOwner();
      _restartProbe();
    }
  }

  void _followOwner() {
    final manager = widget.connManager;
    if (manager == null) return;
    final id = widget.connection.id;
    _ownerChanges = Listenable.merge([
      manager.connectionRevisionFor(id),
      manager.activeProfileRevisionFor(id),
    ])..addListener(_restartProbe);
    _ownerWillChange = manager.connectionWillChangeFor(id)
      ..addListener(_retireProbe);
  }

  void _unfollowOwner() {
    _ownerChanges?.removeListener(_restartProbe);
    _ownerWillChange?.removeListener(_retireProbe);
  }

  void _retireProbe() {
    _generation++;
    if (!mounted) return;
    setState(() {
      _loading = false;
      _rows = null;
    });
  }

  void _restartProbe() {
    _retireProbe();
    if (mounted) _probe();
  }

  @override
  void dispose() {
    _unfollowOwner();
    _generation++;
    super.dispose();
  }

  Future<void> _probe() async {
    if (_loading) return;
    final generation = ++_generation;
    setState(() => _loading = true);
    final conn = widget.connection;

    final dashboardFuture = _reachable(
      '${conn.effectiveDashboardUrl}/api/status',
    );
    final notificationFuture = widget.notifications?.permissionGranted();

    final dashboard = await dashboardFuture;
    if (!_current(generation)) return;
    // A public /api/status only proves the Dashboard is up; chat and Bot Mode
    // need the saved login too, so check it before calling the row healthy.
    final auth = dashboard == true
        ? await _dashboardAuth(conn)
        : DashboardAuthCheck.unknown;
    final notifications = await notificationFuture;
    if (!_current(generation)) return;

    final rows = <_RawRow>[];
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
      (true, DashboardAuthCheck.ok) => const _RawRow(
        _LabelKind.dashboard,
        _Health.ok,
        _DetailKind.connected,
      ),
      (true, DashboardAuthCheck.unknown) => const _RawRow(
        _LabelKind.dashboard,
        _Health.unknown,
        _DetailKind.unavailable,
      ),
    });
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

  Future<DashboardAuthCheck> _dashboardAuth(SavedConnection conn) async {
    final injected = widget.dashboardAuth;
    if (injected != null) return injected(conn);
    final manager = widget.connManager;
    if (manager == null) return DashboardAuthCheck.unknown;
    return checkSavedDashboardLogin(manager, conn);
  }

  Future<bool> _reachable(String url) async {
    final injected = widget.reachable;
    if (injected != null) return injected(url);
    final client = OriginBoundHttpClient();
    try {
      final safeUrl = TransportPrivacy.requireAllowed(url);
      final response = await client
          .get(Uri.parse(safeUrl))
          .timeout(const Duration(seconds: 6));
      return response.statusCode >= 200 && response.statusCode < 300;
    } catch (_) {
      return false;
    } finally {
      client.close();
    }
  }

  /// Closes the sheet and opens the same sign-in the chat uses.
  void _signIn() {
    final navigator = Navigator.of(context);
    final manager = widget.connManager!;
    if (navigator.canPop()) navigator.pop();
    unawaited(signInToDashboard(navigator, manager, widget.connection));
  }

  String _label(_LabelKind kind, Strings s) => switch (kind) {
    _LabelKind.dashboard => 'Dashboard',
    _LabelKind.notifications => s.statusNotifications,
  };

  String _detail(_DetailKind kind, Strings s) => switch (kind) {
    _DetailKind.connected => s.statusConnected,
    _DetailKind.offline => s.statusOffline,
    _DetailKind.wrongPassword => s.statusWrongPassword,
    _DetailKind.loginRequired => s.statusLoginRequired,
    _DetailKind.unavailable => s.setStatusUnavailable,
    _DetailKind.enabled => s.statusEnabled,
    _DetailKind.disabled => s.statusDisabled,
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
                    onPressed: _probe,
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
                if (row.detail == _DetailKind.loginRequired &&
                    widget.connManager != null)
                  TextButton(
                    key: const ValueKey('instance-status-sign-in'),
                    onPressed: _signIn,
                    child: Text(s.s2SessionExpiredSignIn),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
