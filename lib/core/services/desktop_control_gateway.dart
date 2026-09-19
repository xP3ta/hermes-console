import '../models/desktop_control_center.dart';
import '../models/admin_integrations.dart';

export '../models/desktop_control_center.dart'
    show SessionGoalSnapshot, SessionGoalGate, SessionGoalWaitBarrier;

enum DesktopControlFailureKind {
  unsupported,
  unavailable,
  forbidden,
  invalidResponse,
  rejected,
}

/// Sanitised error exposed to control-centre UI.
///
/// It intentionally carries no server message, paths, command text or payload.
final class DesktopControlFailure implements Exception {
  final DesktopControlFailureKind kind;
  final int? code;

  const DesktopControlFailure(this.kind, {this.code});
}

/// Optional JSON-RPC surface used by the long-form control centres.
///
/// Keeping this separate from the chat gateway lets legacy fakes and legacy
/// Hermes servers continue to work. Screens must treat method-not-found as an
/// unsupported capability, never as an empty successful inventory.
abstract class HermesDesktopControlGateway {
  Future<RecoveryTimeline> listRecovery(String runtimeSessionId);

  Future<RecoveryDiff> diffRecovery(
    String runtimeSessionId,
    String checkpointHash,
  );

  Future<RecoveryRestoreResult> restoreRecovery(
    String runtimeSessionId,
    String checkpointHash,
  );

  Future<ExtensionsInventory> extensionsInventory({
    String runtimeSessionId = '',
  });

  Future<void> setPluginEnabled(String name, bool enabled);

  Future<void> setToolsetEnabled(
    String name,
    bool enabled, {
    String runtimeSessionId = '',
  });

  Future<void> reloadMcp({
    String runtimeSessionId = '',
    required bool confirmed,
  });

  Future<AgentCenterSnapshot> agentCenterSnapshot({
    String runtimeSessionId = '',
  });

  Future<SpawnTreeDetail> loadSpawnTree(String opaquePath);

  Future<String> startBackgroundTask(String runtimeSessionId, String text);

  Future<void> killBackgroundProcess(String runtimeSessionId, String processId);

  Future<ProjectTreeSnapshot> projectTree();

  Future<ProjectNode?> projectSessions(String projectId);

  Future<void> setSessionWorkingDirectory(String runtimeSessionId, String path);

  /// Reads the live standing-goal snapshot for a session (`session.control.read`,
  /// `control.goal` in the response). Null when there is no active goal.
  Future<SessionGoalSnapshot?> readSessionGoal(String runtimeSessionId);

  /// Sends a `session.control` action (`goal.pause`, `goal.resume`,
  /// `goal.unwait` or `goal.clear`). `goal.gate*` and subgoal editing are
  /// intentionally not exposed here — use the `/goal` text command for those.
  Future<void> sendGoalAction(String runtimeSessionId, String action);
}

/// Optional authenticated Dashboard seam for installing and administering
/// extensions. Keeping it separate preserves legacy JSON-RPC fakes/servers.
abstract class HermesExtensionManagementGateway {
  Future<List<DesktopPluginManagementEntry>> managedPlugins();

  Future<DesktopExtensionInstallResult> installPlugin(
    String identifier, {
    required bool enable,
  });

  Future<void> updatePlugin(String name);

  Future<void> removePlugin(String name);

  Future<List<DesktopMcpServerEntry>> mcpServers();

  Future<List<DesktopMcpCatalogEntry>> mcpCatalog();

  Future<DesktopExtensionInstallResult> installMcpCatalogEntry(
    String name, {
    Map<String, String> environment = const {},
  });

  Future<void> setMcpServerEnabled(String name, bool enabled);

  Future<void> removeMcpServer(String name);

  Future<DesktopMcpProbeResult> testMcpServer(String name);
}

/// Operaciones MCP individuales que Agent 0.20 puede realizar sin reemplazar
/// el mapa completo ni rehidratar secretos redactados.
abstract class HermesMcpProvisioningGateway {
  Future<DesktopMcpServerEntry> addMcpServer(McpServerDraft draft);

  Future<McpOAuthFlow> startMcpOAuth(String name);

  Future<McpOAuthFlow> mcpOAuthFlow(String flowId);
}

abstract class HermesWebhookManagementGateway {
  Future<WebhookSnapshot> webhookSnapshot();

  Future<WebhookEnableResult> enableWebhooks();

  Future<WebhookCreateReceipt> createWebhook(WebhookDraft draft);

  Future<void> setWebhookEnabled(String name, bool enabled);

  Future<void> removeWebhook(String name);
}

/// Lectura del catálogo oficial de plataformas del servidor.
///
/// Android no implementa ni encapsula el protocolo A2A: únicamente muestra
/// el estado que Hermes Agent publica para la plataforma `a2a`.
abstract class HermesServerPlatformCapabilitiesGateway {
  Future<A2aServerCapability?> a2aServerCapability();
}

/// Mobile-side allowlist before an identifier reaches Hermes' own installer.
///
/// Accepted inputs are `owner/repo` or credential-free HTTPS Git URLs. Paths,
/// control characters and URLs carrying credentials/query/fragment are
/// rejected before any network mutation.
bool isSafePluginInstallIdentifier(String raw) {
  final value = raw.trim();
  if (value.isEmpty || value.length > 512) return false;
  if (RegExp(r'[\x00-\x20\x7F]').hasMatch(value)) return false;

  final ownerRepo = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,99}/'
    r'[A-Za-z0-9][A-Za-z0-9_.-]{0,159}$',
  );
  if (ownerRepo.hasMatch(value)) {
    return !value
        .split('/')
        .any((segment) => segment == '.' || segment == '..');
  }

  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme.toLowerCase() != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    return false;
  }
  final meaningfulSegments = uri.pathSegments
      .where((segment) {
        return segment.isNotEmpty;
      })
      .toList(growable: false);
  return meaningfulSegments.isNotEmpty &&
      !meaningfulSegments.any((segment) => segment == '.' || segment == '..');
}
