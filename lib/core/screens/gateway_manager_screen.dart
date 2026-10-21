// The saved Hermes connections, each one opens its connection screen.
//
// Backed by the existing ConnectionManager (SharedPreferences metadata +
// API keys in Android Keystore). The "active" gateway is the
// `last_connection_id` preference that HomeScreen uses to auto-connect on
// launch — selecting a card here changes which gateway the app opens next.
import 'dart:async';

import 'package:flutter/material.dart';
import '../services/origin_bound_http_client.dart';

import '../../l10n/app_localizations.dart';
import '../services/connection_manager.dart';
import '../utils/transport_privacy.dart';
import '../theme/app_theme.dart';
import '../widgets/general_dock_shell.dart';
import '../widgets/hermes_ui.dart' show HermesIconTile, HermesPrimaryButton;
import '../widgets/instance_kind_picker.dart';
import '../widgets/instance_status_panel.dart'
    show DashboardAuthCheck, checkSavedDashboardLogin;
import '../widgets/status_pill.dart';
import 'instance_edit_screen.dart';
import 'onboarding_screen.dart';
import '../design/hermes_design.dart'
    show
        HermesAction,
        HermesPage,
        HermesListGroup,
        HermesListRow,
        HermesSpace,
        HermesDialogAction,
        HermesDialogActionStyle,
        HermesMenuButton,
        showHermesDialog;
import '../feedback/feedback_policy.dart';

class GatewayManagerScreen extends StatefulWidget {
  final ConnectionManager connManager;
  const GatewayManagerScreen({required this.connManager, super.key});

  @override
  State<GatewayManagerScreen> createState() => _GatewayManagerScreenState();
}

class _GatewayManagerScreenState extends State<GatewayManagerScreen> {
  static const _activeKey = ConnectionManager.lastConnKey;

  List<SavedConnection> _connections = [];
  String? _activeId;
  String? _defaultId;

  /// Per-connection health status. Keyed by connection id.
  final Map<String, InstanceStatus> _statuses = {};

  /// Ids whose Dashboard answered but wants a login.
  final Set<String> _loginRequired = {};

  @override
  void initState() {
    super.initState();
    _init();
  }

  List<SavedConnection> _visibleConnections() =>
      widget.connManager.getConnections();

  void _init() {
    setState(() {
      _connections = _visibleConnections();
      _activeId = widget.connManager.prefs.getString(_activeKey);
      _defaultId = widget.connManager.defaultConnectionId;
      for (final c in _connections) {
        _statuses[c.id] = InstanceStatus.checking;
      }
    });
    _checkAllHealth();
  }

  void _refresh() {
    setState(() {
      _connections = _visibleConnections();
      _defaultId = widget.connManager.defaultConnectionId;
      _activeId = widget.connManager.activeConnectionId.value;
      for (final c in _connections) {
        if (!_statuses.containsKey(c.id)) {
          _statuses[c.id] = InstanceStatus.unknown;
        }
      }
    });
  }

  Future<void> _checkAllHealth() async {
    final connections = List<SavedConnection>.from(_connections);
    await Future.wait(connections.map(_checkSingle));
  }

  Future<void> _checkSingle(SavedConnection conn) async {
    if (!mounted) return;
    setState(() => _statuses[conn.id] = InstanceStatus.checking);
    final (status, loginRequired) = await _fetchStatus(conn);
    if (!mounted) return;
    setState(() {
      _statuses[conn.id] = status;
      if (loginRequired) {
        _loginRequired.add(conn.id);
      } else {
        _loginRequired.remove(conn.id);
      }
    });
  }

  /// Reads the state of the Dashboard, the only origin Desktop talks to:
  /// `/api/status` says it is up and the authenticated `/api/sessions` read
  /// (the same login check as the status panel) says the login is accepted.
  /// A 401/403 is a login problem, never an offline server.
  Future<(InstanceStatus, bool)> _fetchStatus(SavedConnection conn) async {
    try {
      final base = TransportPrivacy.requireAllowed(conn.effectiveDashboardUrl);
      final client = OriginBoundHttpClient();
      try {
        final res = await client
            .get(Uri.parse('$base/api/status'))
            .timeout(const Duration(seconds: 8));
        if (res.statusCode < 200 || res.statusCode >= 300) {
          return (InstanceStatus.offline, false);
        }
      } finally {
        client.close();
      }
      return switch (await checkSavedDashboardLogin(widget.connManager, conn)) {
        DashboardAuthCheck.ok => (InstanceStatus.online, false),
        DashboardAuthCheck.loginRequired ||
        DashboardAuthCheck.invalidCredentials => (InstanceStatus.error, true),
        DashboardAuthCheck.unknown => (InstanceStatus.offline, false),
      };
    } on TimeoutException {
      return (InstanceStatus.offline, false);
    } catch (e) {
      debugPrint(
        '[gateway-manager] status check unavailable (${e.runtimeType})',
      );
      return (InstanceStatus.offline, false);
    }
  }

  Future<void> _setActive(SavedConnection conn) async {
    final changed = conn.id != _activeId;
    await widget.connManager.setActiveConnection(conn.id);
    if (!mounted) return;
    setState(() => _activeId = conn.id);
    final notice = AppFeedback.of(context);
    // Screens below this one (Tools hub, dock) were built for the previous
    // instance; return to the root like the drawer selector does.
    if (changed) Navigator.of(context).popUntil((route) => route.isFirst);
    notice.notify(
      FeedbackKind.routine,
      Strings.of(context).gwActiveInstance(conn.label),
    );
  }

  /// Fija [conn] como predeterminada (la app abrirá siempre con ella), o la
  /// quita si ya lo era. Al fijarla, también la deja activa para reflejarlo ya.
  Future<void> _toggleDefault(SavedConnection conn) async {
    final makeDefault = conn.id != _defaultId;
    await widget.connManager.setDefaultConnection(makeDefault ? conn.id : null);
    if (makeDefault) {
      await widget.connManager.setActiveConnection(conn.id);
    }
    if (!mounted) return;
    setState(() {
      _defaultId = makeDefault ? conn.id : null;
      if (makeDefault) _activeId = conn.id;
    });
    AppFeedback.of(context).notify(
      FeedbackKind.routine,
      makeDefault
          ? Strings.of(context).gwDefaultInstance(conn.label)
          : Strings.of(context).gwNoDefault,
    );
  }

  Future<void> _deleteConnection(SavedConnection conn) async {
    if (conn.id == _activeId) {
      AppFeedback.of(context).notify(
        FeedbackKind.error,
        Strings.of(context).gwCantDeleteActive,
        warning: true,
      );
      return;
    }

    final s = Strings.of(context);
    final confirm = await showHermesDialog<bool>(
      context: context,
      title: s.sRemoveTitle,
      message: s.sRemoveBody(conn.label),
      actions: [
        HermesDialogAction(
          label: s.commonCancel,
          value: false,
          style: HermesDialogActionStyle.cancel,
        ),
        HermesDialogAction(
          label: s.sRemove,
          value: true,
          style: HermesDialogActionStyle.destructive,
        ),
      ],
    );
    if (confirm != true) return;
    await widget.connManager.deleteConnection(conn.id);
    if (!mounted) return;
    setState(() {
      _statuses.remove(conn.id);
    });
    _refresh();
  }

  Future<void> _showEditDialog(SavedConnection conn) async {
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            InstanceEditScreen(connManager: widget.connManager, initial: conn),
      ),
    );
    if (saved == true && mounted) {
      _refresh();
      final updated = widget.connManager
          .getConnections()
          .where((c) => c.id == conn.id)
          .firstOrNull;
      if (updated != null) unawaited(_checkSingle(updated));
    }
  }

  Future<void> _showAddDialog() async {
    // Add an explicit connection to an existing server.
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => OnboardingScreen(
          connManager: widget.connManager,
          // A finished connection becomes the active one: land on Home, not
          // back on this list. Backing out never fires onDone.
          onDone: () => Navigator.of(context).popUntil((r) => r.isFirst),
        ),
      ),
    );
    if (mounted) {
      _refresh();
      final added = widget.connManager.getConnections().firstOrNull;
      if (added != null) unawaited(_checkSingle(added));
    }
  }

  // Esta pantalla lista TODAS las instancias y no tiene una "conexión
  // actual" propia como el resto de pantallas del perfil General — usamos la
  // instancia activa (la que HomeScreen usaría para reconectar) como ancla
  // del dock; sin ninguna activa (lista vacía o recién arrancada) el dock
  // simplemente no se pinta, igual que en Voz cuando falta connManager.
  SavedConnection? get _activeConnectionObj {
    final id = _activeId;
    if (id == null) return null;
    for (final c in _connections) {
      if (c.id == id) return c;
    }
    return null;
  }

  Widget _wrapWithDock(Widget body) {
    final conn = _activeConnectionObj;
    if (conn == null) return body;
    return GeneralDockShell(
      connection: conn,
      connManager: widget.connManager,
      pet: false,
      onCreate: _showAddDialog,
      body: body,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    return HermesPage(
      wrapBody: _wrapWithDock,
      title: s.gwTitle,
      listKey: const ValueKey('hermes-connections-scroll'),
      bottomInset: 96,
      actions: [
        IconButton(
          key: const ValueKey('hermes-add'),
          tooltip: _connections.isEmpty ? s.homeAddInstance : s.gwAddInstance,
          icon: Icon(Icons.add, color: colors.accent),
          onPressed: _showAddDialog,
        ),
      ],
      onRefresh: () async {
        _refresh();
        await _checkAllHealth();
      },
      children: [
        if (_connections.isEmpty) ...[
          Text(s.homeNoInstances),
          const SizedBox(height: HermesSpace.x6),
          HermesPrimaryButton(
            key: const ValueKey('hermes-add-empty'),
            label: s.homeAddInstance,
            icon: Icons.qr_code_scanner,
            onTap: _showAddDialog,
          ),
        ] else ...[
          HermesListGroup(
            children: [
              for (final conn in _connections) _connectionRow(conn, s),
            ],
          ),
          const SizedBox(height: HermesSpace.x6),
          HermesListRow(
            key: const ValueKey('hermes-add-another'),
            title: s.gwAddInstance,
            icon: Icons.add,
            onTap: _showAddDialog,
          ),
        ],
      ],
    );
  }

  Widget _connectionRow(SavedConnection conn, Strings s) {
    final active = conn.id == _activeId;
    final isDefault = conn.id == _defaultId;
    final status = _statuses[conn.id] ?? InstanceStatus.unknown;
    final statusLabel = _loginRequired.contains(conn.id)
        ? s.statusLoginRequired
        : status == InstanceStatus.online
        ? s.sChatConnected
        : status.labelFor(context);
    return HermesListRow(
      key: ValueKey('hermes-connection-${conn.id}'),
      title: conn.label,
      subtitle: [
        conn.host,
        statusLabel,
        if (active) s.gwActiveBadge,
        if (isDefault) s.gwDefaultBadge,
        if (conn.readOnly) s.gwReadOnly,
      ].join(' · '),
      subtitleMaxLines: 3,
      leading: HermesIconTile(
        instanceKindIcon(conn.kind),
        size: 40,
        active: active,
      ),
      onTap: () => _showEditDialog(conn),
      trailing: _CardMenu(
        key: ValueKey('hermes-menu-${conn.id}'),
        onSelect: () => _setActive(conn),
        onToggleDefault: () => _toggleDefault(conn),
        onTest: () => _checkSingle(conn),
        onDelete: () => _deleteConnection(conn),
        isActive: active,
        isDefault: isDefault,
        label: conn.label,
      ),
    );
  }
}

class _CardMenu extends StatelessWidget {
  final VoidCallback onSelect;
  final VoidCallback onToggleDefault;
  final VoidCallback onTest;
  final VoidCallback onDelete;
  final bool isActive;
  final bool isDefault;
  final String label;

  const _CardMenu({
    super.key,
    required this.label,
    required this.onSelect,
    required this.onToggleDefault,
    required this.onTest,
    required this.onDelete,
    required this.isActive,
    required this.isDefault,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return HermesMenuButton<_MenuAction>(
      tooltip: Strings.of(context).sConnectionOptions(label),
      icon: Icon(Icons.more_vert, size: 20, color: colors.textSecondary),
      onSelected: (action) {
        switch (action) {
          case _MenuAction.select:
            onSelect();
          case _MenuAction.toggleDefault:
            onToggleDefault();
          case _MenuAction.test:
            onTest();
          case _MenuAction.delete:
            onDelete();
        }
      },
      actions: (context) => [
        if (!isActive)
          HermesAction(
            value: _MenuAction.select,
            label: Strings.of(context).gwSetActive,
            icon: Icons.check_circle_outline,
          ),
        HermesAction(
          value: _MenuAction.toggleDefault,
          label: isDefault
              ? Strings.of(context).gwUnsetDefault
              : Strings.of(context).gwSetDefault,
          icon: isDefault ? Icons.star : Icons.star_outline,
        ),
        HermesAction(
          value: _MenuAction.test,
          label: Strings.of(context).gwTestConnection,
          icon: Icons.wifi_tethering,
        ),
        HermesAction(
          value: _MenuAction.delete,
          label: Strings.of(context).gwDelete,
          icon: Icons.delete_outline,
          destructive: true,
        ),
      ],
    );
  }
}

enum _MenuAction { select, toggleDefault, test, delete }
