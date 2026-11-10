import 'package:flutter/material.dart';

import '../../main.dart' show HermesAppState;
import '../capabilities/capabilities_screen.dart'
    show CapabilitiesHub, ExtensionsTab;
import '../capabilities/las_chat.dart' show lasChatFor;
import '../services/desktop_control_gateway.dart';
import '../services/tui_gateway_client.dart' show TuiGatewayClient;
import 'extensions_tools_screen.dart';

/// Redirect kept for every caller of the old «Extensions centre».
///
/// That screen (Plugins · Tools · MCP, with two loose cards for the server
/// integrations and the MCP catalog) is now the Extensions screen with three
/// tabs, Skills · Plugins · MCP; its tool groups moved to the ⋯ menu and the
/// server integrations to «Webhooks and server status» in the same menu. A
/// gateway that is not a real connection (nothing to build the screen from)
/// lands on the tool groups, the only part that needs nothing else.
class ExtensionsCenterScreen extends StatelessWidget {
  final HermesDesktopControlGateway gateway;
  final String runtimeSessionId;
  final bool readOnly;

  const ExtensionsCenterScreen({
    required this.gateway,
    this.runtimeSessionId = '',
    this.readOnly = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final live = gateway;
    if (live is TuiGatewayClient) {
      // The profile in use, like every other way in without a profile of its
      // own (the old centre was not profile-aware at all).
      final connection = live.connection;
      final profile =
          context
              .findAncestorStateOfType<HermesAppState>()
              ?.connManager
              .activeProfileFor(connection.id) ??
          '';
      return CapabilitiesHub(
        connection: connection,
        profile: profile,
        initialTab: ExtensionsTab.plugins,
        learnLauncher: lasChatFor(connection, profile),
        runtimeSessionId: runtimeSessionId,
      );
    }
    return ExtensionsToolsScreen(
      gateway: gateway,
      runtimeSessionId: runtimeSessionId,
      readOnly: readOnly,
    );
  }
}
