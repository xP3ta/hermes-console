import '../models/capability_matrix.dart';

/// A verified login replaces cached access refusals. Feature permissions
/// must be checked with the new session; a login proves no write capability.
/// Gateway facts remain valid for the unchanged connection.
CapabilityMatrix capabilitiesAfterDashboardLogin(CapabilityMatrix previous) {
  CapState declared(String name, CapState state) =>
      previous.isServerSourced(name) ? state : CapState.unknown;
  return CapabilityMatrix(
    gatewayOnline: previous.gatewayOnline,
    gatewayAuthValid: previous.gatewayAuthValid,
    chatSupported: previous.chatSupported,
    sessionsRead: previous.sessionsRead,
    sessionsWrite: previous.sessionsWrite,
    sessionsDelete: previous.sessionsDelete,
    streamingSupported: previous.streamingSupported,
    turnIdempotency: previous.turnIdempotency,
    kanbanTrackedCreate: declared(
      'kanbanTrackedCreate',
      previous.kanbanTrackedCreate,
    ),
    skillsRead: declared('skillsRead', previous.skillsRead),
    skillsToggle: declared('skillsToggle', previous.skillsToggle),
    toolsetsRead: declared('toolsetsRead', previous.toolsetsRead),
    cronWrite: declared('cronWrite', previous.cronWrite),
    memoryWrite: declared('memoryWrite', previous.memoryWrite),
    configWrite: declared('configWrite', previous.configWrite),
    pluginsSupported: previous.pluginsSupported,
    gatewayVersion: previous.gatewayVersion,
    serverModel: previous.serverModel,
    serverSourced: previous.serverSourced,
    dashboardOnline: CapState.yes,
    dashboardAuthValid: CapState.yes,
    checkedAtMs: DateTime.now().millisecondsSinceEpoch,
  );
}
