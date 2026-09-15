import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../main.dart';
import '../screens/chat_screen.dart';
import '../screens/mission_control_screen.dart';
import '../screens/settings_screen.dart';
import '../services/connection_manager.dart';
import 'dock_shortcuts.dart';
import 'general_mode_dock.dart';

/// Envuelve el `body` de una pantalla de navegación del perfil "General"
/// (fuera de una conversación abierta) con el mismo dock flotante que ya usa
/// `HomeDashboardScreen`: mismo patrón Stack + Positioned + callbacks
/// (onCreate/onOpenBots/onOpenSettings/...), gestionando por su cuenta el
/// "Atrás" contextual (RouteAware) para no duplicar esa lógica ni la lista
/// de callbacks en cada pantalla que se sume (Ajustes, lista de sesiones).
///
/// Deliberadamente NO se usa dentro de una conversación (`ChatScreen`): ahí
/// ya viven el composer y el pill flotante de subagentes; superponer el
/// dock los taparía/competiría con ellos.
class GeneralDockShell extends StatefulWidget {
  final Widget body;
  final SavedConnection connection;
  final ConnectionManager connManager;

  /// Acción de "Crear". Si es null, crea una conversación nueva genérica
  /// (mismo comportamiento que Inicio); algunas pantallas (p.ej. la lista de
  /// sesiones) ya tienen su propia creación con refresco de estado y la
  /// pasan aquí en vez de usar el fallback.
  final VoidCallback? onCreate;

  /// False cuando esta pantalla YA ES Ajustes: evita apilar Ajustes sobre
  /// Ajustes al tocar el item "Ajustes" del dock.
  final bool includeSettingsAction;

  /// False cuando esta pantalla YA ES la lista de sesiones (solo aplica si
  /// el usuario activó el acceso opcional "Sesiones" del catálogo).
  final bool includeSessionsAction;

  const GeneralDockShell({
    required this.body,
    required this.connection,
    required this.connManager,
    this.onCreate,
    this.includeSettingsAction = true,
    this.includeSessionsAction = true,
    super.key,
  });

  @override
  State<GeneralDockShell> createState() => _GeneralDockShellState();
}

class _GeneralDockShellState extends State<GeneralDockShell> with RouteAware {
  bool _hasSubscreenAbove = false;
  PageRoute<dynamic>? _route;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute<dynamic> && !identical(route, _route)) {
      hermesRouteObserver.unsubscribe(this);
      _route = route;
      hermesRouteObserver.subscribe(this, route);
    }
  }

  @override
  void dispose() {
    hermesRouteObserver.unsubscribe(this);
    super.dispose();
  }

  @override
  void didPopNext() {
    if (mounted) setState(() => _hasSubscreenAbove = false);
  }

  @override
  void didPushNext() {
    if (mounted) setState(() => _hasSubscreenAbove = true);
  }

  void _defaultCreate() {
    final session = Session(
      id: GatewayChatClient.generateSessionId(),
      title: Strings.of(context).drawerNewChat,
      model: 'hermes-agent',
      source: 'mobile',
      messageCount: 0,
      isActive: true,
      preview: '',
      startedAt: DateTime.now().millisecondsSinceEpoch.toDouble() / 1000,
    );
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            ChatScreen(connection: widget.connection, session: session),
      ),
    );
  }

  void _openBots() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MissionControlScreen(
          connection: widget.connection,
          connManager: widget.connManager,
        ),
      ),
    );
  }

  void _openSettings() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SettingsScreen(
          connection: widget.connection,
          connManager: widget.connManager,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.body,
        GeneralModeDock(
          onCreate: widget.onCreate ?? _defaultCreate,
          onOpenBots: _openBots,
          onOpenSettings: widget.includeSettingsAction ? _openSettings : null,
          onOpenHome: () => Navigator.of(context).popUntil((r) => r.isFirst),
          onOpenCron: () => openDockCron(context, widget.connection),
          onOpenTasks: () => openDockTasks(context, widget.connection),
          onOpenSessions: widget.includeSessionsAction
              ? () => openDockSessions(
                  context,
                  widget.connection,
                  widget.connManager,
                )
              : null,
          onOpenTools: () =>
              openDockTools(context, widget.connection, widget.connManager),
          showBackContext: _hasSubscreenAbove,
          onBack: () => Navigator.of(context).maybePop(),
        ),
      ],
    );
  }
}
