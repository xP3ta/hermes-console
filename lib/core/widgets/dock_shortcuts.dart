import 'package:flutter/material.dart';

import '../screens/cron_screen.dart';
import '../screens/session_list_screen.dart';
import '../screens/tasks_screen.dart';
import '../screens/tools_hub_screen.dart';
import '../services/connection_manager.dart';
import 'hermes_drawer.dart' show buildHermesToolDestinations;

/// Navegación de los accesos directos opcionales del catálogo del dock
/// (Cron, Tareas, Sesiones, Herramientas): están en el catálogo de ambos
/// perfiles pero ocultos por defecto (ver `DockProfileConfig.defaultBots` /
/// `.defaultGeneral`); el usuario los activa desde Ajustes › Dock si los
/// quiere en la barra.
///
/// Reutilizan EXACTAMENTE las mismas pantallas y criterios de capacidades
/// que ya usa [HermesDrawer] para las mismas secciones, para no duplicar
/// navegación (ver [buildHermesToolDestinations]).
void openDockCron(BuildContext context, SavedConnection connection) {
  Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => CronScreen(connection: connection)),
  );
}

void openDockTasks(BuildContext context, SavedConnection connection) {
  Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => TasksScreen(connection: connection)),
  );
}

void openDockSessions(
  BuildContext context,
  SavedConnection connection,
  ConnectionManager connManager,
) {
  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) =>
          SessionListScreen(connection: connection, connManager: connManager),
    ),
  );
}

void openDockTools(
  BuildContext context,
  SavedConnection? connection,
  ConnectionManager connManager,
) {
  final capabilities = connection == null
      ? const CapabilityMatrix()
      : connManager.loadCapabilities(connection.id);
  final destinations = buildHermesToolDestinations(
    context: context,
    connection: connection,
    connManager: connManager,
    capabilities: capabilities,
  );
  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => ToolsHubScreen(destinations: destinations),
    ),
  );
}
