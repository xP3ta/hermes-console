import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../main.dart' show HermesAppState;
import '../models/dock_config.dart' show DockItemId;
import '../screens/herdr_agents_screen.dart' show AgentsHomeScreen;
import '../services/connection_manager.dart';
import '../shell/gesture_dock_state.dart' show GestureDockTab;
import '../widgets/general_dock_shell.dart';
import '../widgets/hermes_premium_ui.dart' show HermesEmptyState;

/// The screen of the dock's «Agentes» item and of the profile hub's
/// Trabajo › Agentes: the terminal's agents, as a section of its own that
/// needs no open chat.
///
/// The body is [AgentsHomeScreen] (list and detail in two panes on wide
/// windows), under this screen's own app bar. The dock, the drawer and the
/// profile hub call only this function.
///
/// [connection] defaults to the app's active one; [connManager] to the
/// app's. Agents are of the machine
/// the SSH profile points at, not of a bot profile, so nothing here depends
/// on the active profile.
Widget buildAgentsDestination(
  BuildContext context, {
  SavedConnection? connection,
  ConnectionManager? connManager,
}) {
  final strings = Strings.of(context);
  final manager =
      connManager ??
      context.findAncestorStateOfType<HermesAppState>()?.connManager;
  final conn = connection ?? _active(manager);
  return Scaffold(
    // No bar of its own: the section's header (server, «+», menu) is the
    // only one, and the dock is the way out.
    body: conn == null || manager == null
        ? SafeArea(
            child: Center(
              child: HermesEmptyState(
                icon: Icons.terminal_rounded,
                title: strings.navAgents,
                body: strings.drawerNeedInstance,
              ),
            ),
          )
        : GeneralDockShell(
            connection: conn,
            connManager: manager,
            pet: false,
            currentDestination: DockItemId.agents,
            gestureTab: GestureDockTab.agents,
            body: AgentsHomeScreen(
              initialConnectionId: conn.id,
              showAppBar: false,
            ),
          ),
  );
}

SavedConnection? _active(ConnectionManager? manager) {
  return manager?.resolveActiveConnection();
}
