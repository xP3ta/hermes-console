// Multi-gateway management screen — "Instancias".
//
// Backed by the existing ConnectionManager (SharedPreferences metadata +
// API keys in Android Keystore). The "active" gateway is the
// `last_connection_id` preference that HomeScreen uses to auto-connect on
// launch — selecting a card here changes which gateway the app opens next.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../l10n/app_localizations.dart';
import '../config/flavor.dart';
import '../services/connection_manager.dart';
import '../utils/transport_privacy.dart';
import '../theme/app_theme.dart';
import '../widgets/accent_card.dart';
import '../widgets/general_dock_shell.dart';
import '../widgets/hermes_notice.dart';
import '../widgets/hermes_ui.dart';
import '../widgets/status_pill.dart';
import 'instance_edit_screen.dart';
import 'local_instance_control_screen.dart';
import 'onboarding/welcome_mode_screen.dart';
import '../widgets/hermes_app_bar.dart';

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

  @override
  void initState() {
    super.initState();
    _init();
  }

  /// U-13 (spec 028): con la instancia local retirada de la UI
  /// (kLocalAgentEnabled=false), las conexiones on-device guardadas se
  /// ocultan de la lista sin borrarlas (reversible); la activa se muestra
  /// siempre para no dejar la app conectada a algo invisible.
  List<SavedConnection> _visibleConnections() {
    final all = widget.connManager.getConnections();
    if (kLocalAgentEnabled) return all;
    final activeId = widget.connManager.prefs.getString(_activeKey);
    return all
        .where(
          (c) =>
              c.id == activeId ||
              (c.kind != InstanceKind.localhost && !c.onDeviceLoopback),
        )
        .toList();
  }

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
    final status = await _fetchStatus(conn);
    if (!mounted) return;
    setState(() => _statuses[conn.id] = status);
  }

  /// Fetches /health and maps the response to an [InstanceStatus].
  ///
  /// The current Hermes Gateway /health endpoint returns HTTP 200 when
  /// the server is up and the API key is valid (checked via /api/sessions).
  /// It does not currently expose a `mode` or `readOnly` field in its body,
  /// so [InstanceStatus.readOnly] and [InstanceStatus.syncing] are supported
  /// by the widget but are not sourced from live data. If a future version of
  /// the health endpoint adds e.g. `{"status":"read_only"}` or
  /// `{"status":"syncing"}`, extend the body-parsing block below.
  static Future<InstanceStatus> _fetchStatus(SavedConnection conn) async {
    try {
      final base = TransportPrivacy.requireAllowed(conn.baseUrl);
      final client = http.Client();
      try {
        final res = await client
            .get(
              Uri.parse('$base/health'),
              headers: {
                'Authorization': 'Bearer ${conn.apiKey}',
                'Content-Type': 'application/json',
              },
            )
            .timeout(const Duration(seconds: 8));

        if (res.statusCode == 401 || res.statusCode == 403) {
          return InstanceStatus.error;
        }
        if (res.statusCode != 200) return InstanceStatus.offline;

        // Future-proof: if /health body carries a status field, map it.
        // Currently this block never fires because Hermes /health
        // returns a plain `{"ok":true}` or similar without a `status` key.
        // Uncomment and extend when/if the backend adds it.
        // try {
        //   final body = jsonDecode(res.body) as Map<String, dynamic>?;
        //   final mode = body?['status'] as String?;
        //   if (mode == 'read_only') return InstanceStatus.readOnly;
        //   if (mode == 'syncing') return InstanceStatus.syncing;
        // } catch (_) {}

        // Confirm auth with sessions endpoint (same logic as ApiClient.healthCheck)
        final sessions = await client
            .get(
              Uri.parse('$base/api/sessions'),
              headers: {
                'Authorization': 'Bearer ${conn.apiKey}',
                'Content-Type': 'application/json',
              },
            )
            .timeout(const Duration(seconds: 8));

        if (sessions.statusCode == 200) return InstanceStatus.online;
        if (sessions.statusCode == 401 || sessions.statusCode == 403) {
          return InstanceStatus.error;
        }
        return InstanceStatus.offline;
      } finally {
        client.close();
      }
    } on TimeoutException {
      return InstanceStatus.offline;
    } catch (e) {
      debugPrint(
        '[gateway-manager] excepción silenciada (se continúa sin propagar): $e',
      );
      return InstanceStatus.offline;
    }
  }

  Future<void> _setActive(SavedConnection conn) async {
    await widget.connManager.setActiveConnection(conn.id);
    if (!mounted) return;
    setState(() => _activeId = conn.id);
    HermesNotice.of(context).showSnackBar(
      SnackBar(
        content: Text(
          Strings.of(context).gwActiveInstance(conn.label),
          style: const TextStyle(fontSize: 13),
        ),
        duration: const Duration(seconds: 2),
      ),
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
    HermesNotice.of(context).showSnackBar(
      SnackBar(
        content: Text(
          makeDefault
              ? Strings.of(context).gwDefaultInstance(conn.label)
              : Strings.of(context).gwNoDefault,
          style: const TextStyle(fontSize: 13),
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _deleteConnection(SavedConnection conn) async {
    if (conn.id == _activeId) {
      HermesNotice.of(context).showSnackBar(
        SnackBar(
          content: Text(
            Strings.of(context).gwCantDeleteActive,
            style: const TextStyle(fontSize: 13),
          ),
        ),
        kind: HermesNoticeKind.warning,
      );
      return;
    }

    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(s.gwDeleteInstanceTitle),
        content: Text(s.gwDeleteInstanceBody(conn.label)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(s.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(s.gwDelete, style: TextStyle(color: colors.error)),
          ),
        ],
      ),
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
    if (conn.kind == InstanceKind.localhost) {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => LocalInstanceControlScreen(
            connection: conn,
            connManager: widget.connManager,
          ),
        ),
      );
      if (mounted) _refresh();
      return;
    }
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
    // Ofrece ambos modos (cliente remoto / agente local en este móvil), no solo
    // remoto: así se puede añadir/instalar un Hermes local aunque ya existan
    // instancias remotas.
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => WelcomeModeScreen(
          connManager: widget.connManager,
          // U-32 también aquí: tras un alta con éxito la instancia nueva queda
          // activa (lo hace InstanceEditScreen), así que aterrizamos en la
          // pantalla principal en vez de volver a esta lista. Si el usuario
          // cancela, onDone no se dispara y se queda en el gestor.
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
      onCreate: _showAddDialog,
      body: body,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    return Scaffold(
      appBar: HermesAppBar(
        title: Text(s.gwTitle),
        actions: [
          IconButton(
            icon: Icon(Icons.add, color: colors.accent),
            onPressed: _showAddDialog,
            tooltip: s.gwAddInstance,
          ),
        ],
      ),
      body: _wrapWithDock(_buildBody(colors)),
    );
  }

  Widget _buildBody(HermesThemeColors colors) {
    if (_connections.isEmpty) {
      return _EmptyInstancesState(onAdd: _showAddDialog);
    }

    return RefreshIndicator(
      color: colors.accent,
      onRefresh: () async {
        _refresh();
        await _checkAllHealth();
      },
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        itemCount: _connections.length,
        itemBuilder: (context, index) {
          final conn = _connections[index];
          final isActive = conn.id == _activeId;
          final isDefault = conn.id == _defaultId;
          final status = _statuses[conn.id] ?? InstanceStatus.unknown;
          return _InstanceCard(
            connection: conn,
            isActive: isActive,
            isDefault: isDefault,
            status: status,
            onSelect: () => _setActive(conn),
            onToggleDefault: () => _toggleDefault(conn),
            onEdit: () => _showEditDialog(conn),
            onDelete: () => _deleteConnection(conn),
            onRecheck: () => _checkSingle(conn),
          );
        },
      ),
    );
  }
}

// ─── Instance Card ────────────────────────────────────────────────────────────

class _InstanceCard extends StatelessWidget {
  final SavedConnection connection;
  final bool isActive;
  final bool isDefault;
  final InstanceStatus status;
  final VoidCallback onSelect;
  final VoidCallback onToggleDefault;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onRecheck;

  const _InstanceCard({
    required this.connection,
    required this.isActive,
    required this.isDefault,
    required this.status,
    required this.onSelect,
    required this.onToggleDefault,
    required this.onEdit,
    required this.onDelete,
    required this.onRecheck,
  });

  static IconData _iconForKind(InstanceKind kind) => switch (kind) {
    InstanceKind.vps => Icons.dns_outlined,
    InstanceKind.homelab => Icons.storage_outlined,
    InstanceKind.pc => Icons.computer_outlined,
    InstanceKind.tailscale => Icons.vpn_lock_outlined,
    InstanceKind.localhost => Icons.terminal_outlined,
  };

  static Color _statusColor(HermesThemeColors c, InstanceStatus s) =>
      switch (s) {
        InstanceStatus.online => c.success,
        InstanceStatus.syncing => c.accent,
        InstanceStatus.readOnly => c.warning,
        InstanceStatus.error => c.error,
        InstanceStatus.offline => c.textDisabled,
        InstanceStatus.unknown => c.textSecondary,
        InstanceStatus.checking => c.accent,
      };

  // Antes cada hecho (activa / estado / solo lectura) era un fragmento de
  // texto suelto encadenado con "·" a mano; ahora es una sola etiqueta con
  // todo lo que aplica, coloreada por el hecho más importante.
  String _tagLabel(BuildContext context) {
    final parts = <String>[
      if (isActive) Strings.of(context).gwActiveBadge,
      status.labelFor(context),
      if (connection.readOnly) Strings.of(context).gwReadOnly,
    ];
    return parts.join(' · ');
  }

  Color _tagColor(HermesThemeColors colors) {
    if (status == InstanceStatus.error) return colors.error;
    if (connection.readOnly) return colors.warning;
    return _statusColor(colors, status);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final isOfflineOrError =
        status == InstanceStatus.offline || status == InstanceStatus.error;

    return AccentCard(
      margin: const EdgeInsets.only(bottom: 7),
      // La franja de acento en el lateral se veía como un tachón de color
      // pegado al borde — quitada. La etiqueta de estado ya dice "Activa"
      // en texto; un fondo un poco más marcado basta para distinguir la
      // tarjeta activa sin un borde duro de color.
      background: colors.surfaceVariant.withValues(alpha: isActive ? 0.7 : 0.4),
      borderRadius: const BorderRadius.all(Radius.circular(12)),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onSelect,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 11, 6, 11),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              HermesIconTile(
                _iconForKind(connection.kind),
                size: 36,
                active: isActive,
              ),
              const SizedBox(width: 12),
              // Label + URL + status
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Flexible(
                          child: Text(
                            connection.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                              color: colors.textPrimary,
                            ),
                          ),
                        ),
                        if (isDefault) ...[
                          const SizedBox(width: 6),
                          Tooltip(
                            message: Strings.of(context).gwDefaultBadge,
                            child: Icon(
                              Icons.star,
                              size: 14,
                              color: colors.accent,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 5),
                    // Una sola etiqueta con lo que importa (antes: punto +
                    // estado + " · Activa" + " · Solo lectura" como texto
                    // suelto encadenado, difícil de leer de un vistazo).
                    _StatusTag(
                      label: _tagLabel(context),
                      color: _tagColor(colors),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        if (connection.useHttps)
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: Icon(
                              Icons.lock_outline,
                              size: 11,
                              color: colors.success,
                            ),
                          ),
                        Flexible(
                          child: Text(
                            '${connection.host}:${connection.port}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: colors.textSecondary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              // Action buttons
              if (isOfflineOrError)
                IconButton(
                  icon: Icon(
                    Icons.refresh,
                    size: 18,
                    color: colors.textSecondary,
                  ),
                  onPressed: onRecheck,
                  tooltip: Strings.of(context).gwReconnect,
                  constraints: const BoxConstraints(
                    minWidth: 36,
                    minHeight: 36,
                  ),
                  padding: EdgeInsets.zero,
                ),
              // Editar ya no vive solo dentro del "⋮": era la acción más
              // usada y estaba escondida detrás de un paso extra.
              IconButton(
                icon: Icon(
                  Icons.edit_outlined,
                  size: 18,
                  color: colors.textPrimary,
                ),
                onPressed: onEdit,
                tooltip: Strings.of(context).commonEdit,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                padding: EdgeInsets.zero,
              ),
              _CardMenu(
                onSelect: onSelect,
                onToggleDefault: onToggleDefault,
                onTest: onRecheck,
                onDelete: onDelete,
                isActive: isActive,
                isDefault: isDefault,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One compact pill for everything worth flagging about an instance
/// (active / status / read-only), instead of a run of loose text fragments
/// chained with "·" that was hard to scan at a glance.
class _StatusTag extends StatelessWidget {
  final String label;
  final Color color;

  const _StatusTag({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ),
        ],
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

  const _CardMenu({
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
    return PopupMenuButton<_MenuAction>(
      icon: Icon(Icons.more_vert, size: 20, color: colors.textSecondary),
      color: colors.surface,
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
      itemBuilder: (_) => [
        if (!isActive)
          PopupMenuItem(
            value: _MenuAction.select,
            child: Row(
              children: [
                Icon(
                  Icons.check_circle_outline,
                  size: 18,
                  color: colors.accent,
                ),
                const SizedBox(width: 10),
                Text(Strings.of(context).gwSetActive),
              ],
            ),
          ),
        PopupMenuItem(
          value: _MenuAction.toggleDefault,
          child: Row(
            children: [
              Icon(
                isDefault ? Icons.star : Icons.star_outline,
                size: 18,
                color: colors.accent,
              ),
              const SizedBox(width: 10),
              Text(
                isDefault
                    ? Strings.of(context).gwUnsetDefault
                    : Strings.of(context).gwSetDefault,
              ),
            ],
          ),
        ),
        PopupMenuItem(
          value: _MenuAction.test,
          child: Row(
            children: [
              Icon(Icons.wifi_tethering, size: 18, color: colors.textSecondary),
              const SizedBox(width: 10),
              Text(Strings.of(context).gwTestConnection),
            ],
          ),
        ),
        PopupMenuItem(
          value: _MenuAction.delete,
          child: Row(
            children: [
              Icon(Icons.delete_outline, size: 18, color: colors.error),
              const SizedBox(width: 10),
              Text(
                Strings.of(context).gwDelete,
                style: TextStyle(color: colors.error),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

enum _MenuAction { select, toggleDefault, test, delete }

// ─── Empty state ──────────────────────────────────────────────────────────────

class _EmptyInstancesState extends StatelessWidget {
  final VoidCallback onAdd;

  const _EmptyInstancesState({required this.onAdd});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Center(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeOut,
        builder: (context, t, child) => Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, 8 * (1 - t)),
            child: child,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: colors.accent.withValues(alpha: 0.08),
                shape: BoxShape.circle,
                border: Border.all(
                  color: colors.accent.withValues(alpha: 0.35),
                ),
              ),
              child: Icon(Icons.dns_outlined, size: 26, color: colors.accent),
            ),
            const SizedBox(height: 18),
            Text(
              '▸ ${Strings.of(context).gwNoInstances}',
              style: TextStyle(
                fontSize: 13,
                color: colors.textSecondary,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 14),
            TextButton.icon(
              onPressed: onAdd,
              icon: Icon(Icons.add, size: 18, color: colors.accent),
              label: Text(
                Strings.of(context).gwAddInstanceLower,
                style: TextStyle(color: colors.accent),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
