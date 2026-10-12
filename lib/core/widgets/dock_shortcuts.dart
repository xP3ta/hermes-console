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
WidgetBuilder dockCronBuilder(
  SavedConnection connection,
  ConnectionManager connManager,
) =>
    (_) => CronScreen(connection: connection, connManager: connManager);

WidgetBuilder dockTasksBuilder(
  SavedConnection connection,
  ConnectionManager connManager,
) =>
    (_) => TasksScreen(connection: connection, connManager: connManager);

WidgetBuilder dockSessionsBuilder(
  SavedConnection connection,
  ConnectionManager connManager,
) =>
    (_) => SessionListScreen(connection: connection, connManager: connManager);

/// The hub lists what the server can do now, read when the screen opens.
WidgetBuilder dockToolsBuilder(
  SavedConnection? connection,
  ConnectionManager connManager,
) => (context) {
  final capabilities = connection == null
      ? const CapabilityMatrix()
      : connManager.loadCapabilities(connection.id);
  return ToolsHubScreen(
    destinations: buildHermesToolDestinations(
      context: context,
      connection: connection,
      connManager: connManager,
      capabilities: capabilities,
    ),
    connection: connection,
    connManager: connManager,
  );
};

void openDockCron(
  BuildContext context,
  SavedConnection connection,
  ConnectionManager connManager,
) {
  Navigator.push(
    context,
    MaterialPageRoute(builder: dockCronBuilder(connection, connManager)),
  );
}

void openDockTasks(
  BuildContext context,
  SavedConnection connection,
  ConnectionManager connManager,
) {
  Navigator.push(
    context,
    MaterialPageRoute(builder: dockTasksBuilder(connection, connManager)),
  );
}

void openDockSessions(
  BuildContext context,
  SavedConnection connection,
  ConnectionManager connManager,
) {
  Navigator.push(
    context,
    MaterialPageRoute(builder: dockSessionsBuilder(connection, connManager)),
  );
}

void openDockTools(
  BuildContext context,
  SavedConnection? connection,
  ConnectionManager connManager,
) {
  Navigator.push(
    context,
    MaterialPageRoute(builder: dockToolsBuilder(connection, connManager)),
  );
}
