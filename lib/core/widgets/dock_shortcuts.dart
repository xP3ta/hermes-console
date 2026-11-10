import 'package:flutter/material.dart';

import '../navigation/agents_destination.dart';
import '../screens/app_settings_screen.dart';
import '../screens/cron_screen.dart';
import '../screens/session_list_screen.dart';
import '../screens/tasks_screen.dart';
import '../services/connection_manager.dart';

/// Navegación de los accesos directos opcionales del catálogo del dock
/// (Cron, Tareas, Sesiones, Agentes): están en el catálogo de ambos
/// perfiles pero ocultos por defecto (ver `DockProfileConfig.defaultBots` /
/// `.defaultGeneral`); el usuario los activa desde Ajustes › Dock si los
/// quiere en la barra.
///
/// Reutilizan EXACTAMENTE las mismas pantallas y criterios de capacidades
/// que ya usa [HermesDrawer] para las mismas secciones, para no duplicar
/// navegación.
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

/// «Herramientas» ya no existe (1.4.0): lo de la app y el servidor está en
/// Ajustes de la app y lo de cada bot en su perfil. Esta función conserva el
/// nombre para los llamadores antiguos y los lleva a Ajustes de la app.
WidgetBuilder dockToolsBuilder(
  SavedConnection? connection,
  ConnectionManager connManager,
) =>
    (context) =>
        AppSettingsScreen(connection: connection, connManager: connManager);

/// Agentes: la sección propia de los agentes del terminal.
WidgetBuilder dockAgentsBuilder(
  SavedConnection connection, [
  ConnectionManager? connManager,
]) =>
    (context) => buildAgentsDestination(
      context,
      connection: connection,
      connManager: connManager,
    );

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

/// Redirección de «Herramientas»: abre Ajustes de la app (ver [dockToolsBuilder]).
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

void openDockAgents(
  BuildContext context,
  SavedConnection connection, [
  ConnectionManager? connManager,
]) {
  Navigator.push(
    context,
    MaterialPageRoute(builder: dockAgentsBuilder(connection, connManager)),
  );
}
