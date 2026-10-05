import 'dart:typed_data';

import '../models/desktop_control_center.dart';
import '../models/admin_integrations.dart';
import '../models/project_files.dart';

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
abstract class HermesDesktopProcessStopGateway {
  Future<void> stopBackgroundProcesses(String runtimeSessionId);
}

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

/// Reply ideas for the chat composer through Hermes' stateless
/// `llm.oneshot`, asked only when the user taps for them. A gateway without
/// it, a read-only connection or a server that lacks the method hides the
/// action.
abstract class HermesQuickReplySuggestionGateway {
  /// False on read-only connections and once `llm.oneshot` is unsupported.
  bool get quickReplySuggestionsAvailable;

  /// Up to three short replies; empty when the call fails or is not allowed.
  Future<List<String>> suggestQuickReplies({
    required String lastAssistant,
    required String lastUser,
    String profile = '',
  });
}

/// Project writes and git worktree helpers, exactly as Hermes Desktop issues
/// them: `projects.update` / `projects.create` / `projects.delete` /
/// `projects.set_active` over JSON-RPC and the Dashboard `/api/git/*` mirror
/// Desktop uses on a remote gateway. Kept separate from
/// [HermesDesktopControlGateway] so legacy fakes and servers keep compiling;
/// a screen treats a gateway without it as read-only.
abstract class HermesProjectManagementGateway {
  /// True when this connection may write (not a read-only instance).
  bool get projectWritesAllowed;

  /// `projects.update {id, name?, color?, icon?}`. An empty string clears
  /// color/icon on the server, like Desktop's "No color".
  Future<void> updateProject(
    String id, {
    String? name,
    String? color,
    String? icon,
  });

  /// `projects.create`, used (like Desktop) to adopt an auto-discovered repo
  /// the first time its appearance changes.
  Future<void> createProject({
    required String name,
    required String primaryPath,
    String? color,
    String? icon,
  });

  /// `projects.delete {id}` — drops the saved project only; files, repos and
  /// worktrees stay on disk.
  Future<void> deleteProject(String id);

  /// `projects.set_active {id}`.
  Future<void> setActiveProject(String id);

  /// `GET /api/git/base-branches?path=` (new-worktree base picker).
  Future<List<ProjectGitBaseBranch>> listBaseBranches(String repoPath);

  /// `GET /api/git/branches?path=` ("convert an existing branch").
  Future<List<ProjectGitBranch>> listBranches(String repoPath);

  /// `POST /api/git/worktree/add {path, name?, branch?, base?, existingBranch?}`.
  Future<ProjectWorktreeResult> addWorktree(
    String repoPath, {
    String? branch,
    String? base,
    String? existingBranch,
  });

  /// `POST /api/git/branch/switch {path, branch}`.
  Future<void> switchBranch(String repoPath, String branch);
}

/// The saved project `projects.create` returned: its id and the folder that
/// became primary (where Desktop writes IDEA.md).
final class ProjectCreated {
  final String id;
  final String primaryPath;

  const ProjectCreated({required this.id, required this.primaryPath});
}

/// Creating projects from scratch, exactly as Hermes Desktop's project
/// dialog and "Open folder…" do (`apps/desktop/src/store/projects.ts`):
/// `projects.create`, `projects.add_folder`, `llm.oneshot` for the idea,
/// `GET /api/fs/default-cwd` to seed the remote folder picker and
/// `projects.discover_repos {scan: true}` on refresh. Separate from
/// [HermesProjectManagementGateway] so older fakes and servers keep
/// compiling; a screen hides creation when the gateway lacks it.
abstract class HermesProjectCreationGateway {
  /// True when this connection may write (not a read-only instance).
  bool get projectWritesAllowed;

  /// True once `projects.*` writes answered "method not found".
  bool get projectCreationKnownUnsupported;

  /// `projects.create {name, folders, primary_path?, use}`.
  Future<ProjectCreated> createProjectFromFolders({
    required String name,
    required List<String> folders,
    String? primaryPath,
    bool use = true,
  });

  /// `projects.add_folder {id, path, is_primary: false}`.
  Future<void> addProjectFolder(String id, String path);

  /// `llm.oneshot` with Desktop's project-idea prompt; '' when it fails.
  Future<String> generateProjectIdea(String name);

  /// `GET /api/fs/default-cwd` → the server's default folder, or null.
  Future<String?> projectDefaultFolder();

  /// `projects.discover_repos {scan: true}`: the host scans its discovery
  /// roots so repositories without chats show up. Best effort.
  Future<void> scanProjectRepos();
}

/// Read-only browsing of a project folder through the Dashboard file routes
/// Hermes Desktop's remote file tree uses (`apps/desktop/src/lib/
/// desktop-fs.ts`): `GET /api/fs/list?path=`, `GET /api/fs/read-text?path=`
/// and `GET /api/fs/read-data-url?path=`. No write route is exposed here.
abstract class HermesProjectFilesGateway {
  /// True once `/api/fs/list` answered 404/405 on this connection (an older
  /// Hermes); cleared on reconnect or when the capability TTL expires.
  bool get projectFilesKnownUnsupported;

  Future<ProjectDirectoryListing> listProjectDirectory(String path);

  Future<ProjectFilePreview> readProjectFileText(String path);

  /// Raw bytes for previews the text route cannot carry (images).
  Future<Uint8List> readProjectFileBytes(String path);
}

/// One write route of the project file browser, gated on its own: an older
/// Hermes may serve some of them and not others.
enum ProjectFileWriteAction { createFolder, writeText, upload, delete }

/// Optional writes for the project file browser, kept apart from
/// [HermesProjectFilesGateway] so read-only fakes and servers stay read-only.
/// Exactly the Dashboard routes Hermes Desktop/Web use:
/// `POST /api/files/mkdir {path}`, `POST /api/fs/write-text {path, content}`,
/// `POST /api/files/upload-stream` (multipart `file`, `path`, `overwrite`)
/// and `DELETE /api/files {path, recursive}`.
abstract class HermesProjectFileWritesGateway {
  /// False on a read-only connection: no write is ever sent.
  bool get projectFileWritesAllowed;

  /// True once [action]'s route answered 404/405 (405 only for delete).
  bool projectFileWriteKnownUnsupported(ProjectFileWriteAction action);

  /// Creates [path] and returns the folder the server reports.
  Future<String> createProjectFolder(String path);

  /// Creates or overwrites the UTF-8 text file at [path].
  Future<void> writeProjectFileText(String path, String content);

  /// Uploads the local file at [localPath] to [path]; never overwrites.
  Future<String> uploadProjectFile(
    String path, {
    required String localPath,
    required String filename,
  });

  /// Deletes a file or an empty folder (never recursive).
  Future<void> deleteProjectEntry(String path);
}

/// The child chat `session.branch` / `session.branch_whole` created. Only the
/// identity travels: the child chat loads its own transcript when opened.
final class DesktopBranchResult {
  final String runtimeSessionId;
  final String storedSessionId;
  final String title;
  final int messageCount;

  const DesktopBranchResult({
    required this.runtimeSessionId,
    required this.storedSessionId,
    required this.title,
    required this.messageCount,
  });
}

/// Side agents and live branching, as Hermes Desktop issues them:
/// `prompt.btw`, `prompt.background`, `session.branch` and
/// `session.branch_whole`. Optional, so legacy fakes and servers keep working;
/// a method-not-found answer turns the matching `*KnownUnsupported` flag on
/// and the entries that need it disappear.
abstract class HermesDesktopTurnSideGateway {
  /// `prompt.btw` / `prompt.background` answered `-32601` on this connection.
  bool get turnSideKnownUnsupported;

  /// `session.branch` answered `-32601` on this connection.
  bool get turnBranchKnownUnsupported;

  /// `prompt.btw {session_id, text}`: a side question over a snapshot of the
  /// live conversation. Safe while a turn runs; the answer arrives later as
  /// `btw.complete`. Returns the task id.
  Future<String> askSideQuestion(String runtimeSessionId, String text);

  /// `prompt.background {session_id, text}`: a detached task on a fresh agent;
  /// the answer arrives as `background.complete`. Returns the task id.
  Future<String> startBackgroundPrompt(String runtimeSessionId, String text);

  /// `session.branch`: forks the live session into a new stored child keeping
  /// the first [count] user/assistant rows (all of them when null). The same
  /// [idempotencyKey] returns the same child.
  Future<DesktopBranchResult> branchSession(
    String runtimeSessionId, {
    int? count,
    String? name,
    required String idempotencyKey,
  });

  /// `session.branch_whole`: [branchSession] of the whole history.
  Future<DesktopBranchResult> branchWholeSession(
    String runtimeSessionId, {
    String? name,
    required String idempotencyKey,
  });
}

abstract class HermesDesktopSessionControlGateway {
  Future<SessionControlSnapshot> readSessionControl(String runtimeSessionId);

  Future<void> sendSessionControlAction(
    String runtimeSessionId,
    String action,
  );
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
