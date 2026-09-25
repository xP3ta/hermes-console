/// Typed, bounded projections for the optional Hermes Desktop control centres.
///
/// These models deliberately expose only fields rendered by the Android UI.
/// Unknown payload keys (including configuration values and secrets) are never
/// retained, logged, or copied into diagnostics.
library;

const int _maxCenterRows = 200;
const int _maxPreviewText = 500;

String _cleanText(Object? raw, {int max = _maxPreviewText}) {
  if (raw is! String) return '';
  final value = raw
      .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'), ' ')
      .trim();
  return value.length <= max ? value : value.substring(0, max);
}

String _safeProcessCommand(Object? raw) {
  final command = _cleanText(raw, max: 240);
  if (command.isEmpty) return '';
  final parts = command.split(RegExp(r'\s+'));
  String safePart(String value) {
    if (value.isEmpty || value.startsWith('-') || value.contains('=')) return '';
    return value.split(RegExp(r'[/\\]')).last;
  }

  final executable = safePart(parts.first);
  if (executable.isEmpty) return '';
  final lower = executable.toLowerCase();
  final display = <String>[executable];
  if (lower == 'dart' && parts.length > 1 && parts[1] == 'run') {
    display.add('run');
    if (parts.length > 2) {
      final script = safePart(parts[2]);
      if (script.isNotEmpty) display.add(script);
    }
  } else if (const {'python', 'python3', 'node', 'bash', 'sh'}.contains(lower) &&
      parts.length > 1) {
    final script = safePart(parts[1]);
    if (script.isNotEmpty) display.add(script);
  } else if (const {
    'npm',
    'pnpm',
    'yarn',
    'flutter',
    'cargo',
    'gradle',
  }.contains(lower)) {
    for (final part in parts.skip(1).take(2)) {
      final projection = safePart(part);
      if (projection.isNotEmpty) display.add(projection);
    }
  }
  return _cleanText(display.join(' '), max: 80);
}

/// Proyección de solo lectura de un comando para mostrarlo en pantalla: el
/// ejecutable (y, en las herramientas conocidas, el guion o subcomando), nunca
/// flags, argumentos, variables ni rutas completas.
String safeCommandProjection(Object? raw) => _safeProcessCommand(raw);

int _safeInt(Object? raw, {int fallback = 0}) {
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  return int.tryParse(raw?.toString() ?? '') ?? fallback;
}

double _safeDouble(Object? raw) {
  if (raw is num) return raw.toDouble();
  return double.tryParse(raw?.toString() ?? '') ?? 0;
}

List<Map<String, dynamic>> _objectRows(Object? raw) {
  if (raw is! List) return const [];
  return raw
      .take(_maxCenterRows)
      .whereType<Map>()
      .map((row) => Map<String, dynamic>.from(row))
      .toList(growable: false);
}

final class RecoveryCheckpoint {
  final String hash;
  final String timestamp;
  final String message;

  const RecoveryCheckpoint({
    required this.hash,
    required this.timestamp,
    required this.message,
  });

  static RecoveryCheckpoint? tryParse(Map<String, dynamic> json) {
    final hash = _cleanText(json['hash'], max: 128);
    if (hash.isEmpty) return null;
    return RecoveryCheckpoint(
      hash: hash,
      timestamp: _cleanText(json['timestamp'], max: 80),
      message: _cleanText(json['message']),
    );
  }
}

final class RecoveryTimeline {
  final bool enabled;
  final List<RecoveryCheckpoint> checkpoints;

  const RecoveryTimeline({required this.enabled, required this.checkpoints});

  factory RecoveryTimeline.fromJson(Map<String, dynamic> json) {
    final checkpoints = _objectRows(json['checkpoints'])
        .map(RecoveryCheckpoint.tryParse)
        .whereType<RecoveryCheckpoint>()
        .toList(growable: false);
    return RecoveryTimeline(
      enabled: json['enabled'] == true,
      checkpoints: checkpoints,
    );
  }
}

final class RecoveryDiff {
  final String stat;
  final String diff;

  const RecoveryDiff({required this.stat, required this.diff});

  factory RecoveryDiff.fromJson(Map<String, dynamic> json) => RecoveryDiff(
    stat: _cleanText(json['stat'], max: 1000),
    // Hermes itself caps this response to 4,000 characters. Keep a client cap
    // as well so a non-conforming server cannot create an oversized widget.
    diff: _cleanText(json['diff'], max: 4000),
  );
}

final class RecoveryRestoreResult {
  final bool success;
  final int historyRemoved;

  const RecoveryRestoreResult({
    required this.success,
    required this.historyRemoved,
  });

  factory RecoveryRestoreResult.fromJson(Map<String, dynamic> json) =>
      RecoveryRestoreResult(
        success: json['success'] == true,
        historyRemoved: _safeInt(json['history_removed']).clamp(0, 100000),
      );
}

final class DesktopPluginEntry {
  final String name;
  final String version;
  final String description;
  final String source;
  final String status;

  const DesktopPluginEntry({
    required this.name,
    required this.version,
    required this.description,
    required this.source,
    required this.status,
  });

  bool get enabled => const {'enabled', 'active', 'on'}.contains(status);

  static DesktopPluginEntry? tryParse(Map<String, dynamic> json) {
    final name = _cleanText(json['name'], max: 160);
    if (name.isEmpty) return null;
    final legacyEnabled = json['enabled'];
    return DesktopPluginEntry(
      name: name,
      version: _cleanText(json['version'], max: 80),
      description: _cleanText(json['description']),
      source: _cleanText(json['source'], max: 80),
      status: _cleanText(
        json['status'] ??
            (legacyEnabled is bool
                ? (legacyEnabled ? 'enabled' : 'disabled')
                : ''),
        max: 80,
      ).toLowerCase(),
    );
  }
}

final class DesktopToolsetEntry {
  final String name;
  final String description;
  final int toolCount;
  final bool enabled;
  final List<String> tools;

  const DesktopToolsetEntry({
    required this.name,
    required this.description,
    required this.toolCount,
    required this.enabled,
    required this.tools,
  });

  static DesktopToolsetEntry? tryParse(Map<String, dynamic> json) {
    final name = _cleanText(json['name'], max: 160);
    if (name.isEmpty) return null;
    final rawTools = json['tools'];
    final tools = rawTools is List
        ? rawTools
              .take(200)
              .map((value) => _cleanText(value, max: 160))
              .where((value) => value.isNotEmpty)
              .toList(growable: false)
        : const <String>[];
    return DesktopToolsetEntry(
      name: name,
      description: _cleanText(json['description']),
      toolCount: _safeInt(
        json['tool_count'],
        fallback: tools.length,
      ).clamp(0, 10000),
      enabled: json['enabled'] != false,
      tools: tools,
    );
  }
}

final class ExtensionsInventory {
  final List<DesktopPluginEntry> plugins;
  final List<DesktopToolsetEntry> toolsets;

  const ExtensionsInventory({required this.plugins, required this.toolsets});

  factory ExtensionsInventory.fromJson({
    required Map<String, dynamic> plugins,
    required Map<String, dynamic> toolsets,
  }) => ExtensionsInventory(
    plugins: _objectRows(plugins['plugins'])
        .map(DesktopPluginEntry.tryParse)
        .whereType<DesktopPluginEntry>()
        .toList(growable: false),
    toolsets: _objectRows(toolsets['toolsets'])
        .map(DesktopToolsetEntry.tryParse)
        .whereType<DesktopToolsetEntry>()
        .toList(growable: false),
  );
}

final class DesktopPluginManagementEntry {
  final String name;
  final String source;
  final String runtimeStatus;
  final bool canUpdate;
  final bool canRemove;
  final bool authRequired;

  const DesktopPluginManagementEntry({
    required this.name,
    required this.source,
    required this.runtimeStatus,
    required this.canUpdate,
    required this.canRemove,
    required this.authRequired,
  });

  static DesktopPluginManagementEntry? tryParse(Map<String, dynamic> json) {
    final name = _cleanText(json['name'], max: 160);
    if (name.isEmpty) return null;
    return DesktopPluginManagementEntry(
      name: name,
      source: _cleanText(json['source'], max: 80),
      runtimeStatus: _cleanText(json['runtime_status'], max: 80).toLowerCase(),
      canUpdate: json['can_update_git'] == true,
      canRemove: json['can_remove'] == true,
      authRequired: json['auth_required'] == true,
    );
  }
}

final class DesktopMcpServerEntry {
  final String name;
  final String transport;
  final String endpointLabel;
  final String auth;
  final bool enabled;
  final int? toolCount;

  const DesktopMcpServerEntry({
    required this.name,
    required this.transport,
    required this.endpointLabel,
    required this.auth,
    required this.enabled,
    required this.toolCount,
  });

  static DesktopMcpServerEntry? tryParse(Map<String, dynamic> json) {
    final name = _cleanText(json['name'], max: 160);
    if (name.isEmpty) return null;
    final command = _cleanText(json['command'], max: 800);
    final url = _cleanText(json['url'], max: 800);
    final tools = json['tools'];
    return DesktopMcpServerEntry(
      name: name,
      transport: _cleanText(json['transport'], max: 32).toLowerCase(),
      endpointLabel: url.isNotEmpty ? url : command,
      auth: _cleanText(json['auth'], max: 80).toLowerCase(),
      enabled: json['enabled'] != false,
      toolCount: tools is List ? tools.take(500).length : null,
    );
  }
}

final class DesktopMcpEnvRequirement {
  final String name;
  final String prompt;
  final bool required;

  const DesktopMcpEnvRequirement({
    required this.name,
    required this.prompt,
    required this.required,
  });

  static DesktopMcpEnvRequirement? tryParse(Map<String, dynamic> json) {
    final name = _cleanText(json['name'], max: 160);
    if (name.isEmpty) return null;
    return DesktopMcpEnvRequirement(
      name: name,
      prompt: _cleanText(json['prompt'], max: 240),
      required: json['required'] == true,
    );
  }
}

final class DesktopMcpCatalogEntry {
  final String name;
  final String description;
  final String source;
  final String transport;
  final String authType;
  final String command;
  final List<String> args;
  final String url;
  final String installUrl;
  final String installRef;
  final List<String> bootstrap;
  final String postInstall;
  final List<DesktopMcpEnvRequirement> requiredEnv;
  final bool needsInstall;
  final bool installed;
  final bool enabled;

  const DesktopMcpCatalogEntry({
    required this.name,
    required this.description,
    required this.source,
    required this.transport,
    required this.authType,
    required this.command,
    required this.args,
    required this.url,
    required this.installUrl,
    required this.installRef,
    required this.bootstrap,
    required this.postInstall,
    required this.requiredEnv,
    required this.needsInstall,
    required this.installed,
    required this.enabled,
  });

  static DesktopMcpCatalogEntry? tryParse(Map<String, dynamic> json) {
    final name = _cleanText(json['name'], max: 160);
    if (name.isEmpty) return null;

    List<String> strings(Object? value, {int maxRows = 80, int max = 800}) {
      if (value is! List) return const <String>[];
      return value
          .take(maxRows)
          .map((item) => _cleanText(item, max: max))
          .where((item) => item.isNotEmpty)
          .toList(growable: false);
    }

    return DesktopMcpCatalogEntry(
      name: name,
      description: _cleanText(json['description'], max: 600),
      source: _cleanText(json['source'], max: 160),
      transport: _cleanText(json['transport'], max: 32).toLowerCase(),
      authType: _cleanText(json['auth_type'], max: 80).toLowerCase(),
      command: _cleanText(json['command'], max: 800),
      args: strings(json['args']),
      url: _cleanText(json['url'], max: 800),
      installUrl: _cleanText(json['install_url'], max: 800),
      installRef: _cleanText(json['install_ref'], max: 160),
      bootstrap: strings(json['bootstrap']),
      postInstall: _cleanText(json['post_install'], max: 1000),
      requiredEnv: _objectRows(json['required_env'])
          .take(40)
          .map(DesktopMcpEnvRequirement.tryParse)
          .whereType<DesktopMcpEnvRequirement>()
          .toList(growable: false),
      needsInstall: json['needs_install'] == true,
      installed: json['installed'] == true,
      enabled: json['enabled'] == true,
    );
  }
}

final class DesktopExtensionInstallResult {
  final bool accepted;
  final bool background;
  final String installedName;
  final String actionId;
  final List<String> notices;

  const DesktopExtensionInstallResult({
    required this.accepted,
    this.background = false,
    this.installedName = '',
    this.actionId = '',
    this.notices = const [],
  });

  factory DesktopExtensionInstallResult.fromPluginJson(
    Map<String, dynamic> json,
  ) {
    return DesktopExtensionInstallResult(
      accepted: json['ok'] == true,
      installedName: _cleanText(json['plugin_name'], max: 160),
      notices: [
        ..._stringNotices(json['warnings']),
        ..._stringNotices(json['missing_env']),
      ],
    );
  }

  factory DesktopExtensionInstallResult.fromMcpJson(Map<String, dynamic> json) {
    return DesktopExtensionInstallResult(
      accepted: json['ok'] == true,
      background: json['background'] == true,
      installedName: _cleanText(json['name'], max: 160),
      actionId: _cleanText(json['action'], max: 160),
    );
  }

  static List<String> _stringNotices(Object? raw) {
    if (raw is! List) return const [];
    return raw
        .take(20)
        .map((value) => _cleanText(value, max: 240))
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
  }
}

final class DesktopMcpProbeResult {
  final bool ok;
  final int toolCount;
  final bool authorizationRequired;

  const DesktopMcpProbeResult({
    required this.ok,
    required this.toolCount,
    required this.authorizationRequired,
  });

  factory DesktopMcpProbeResult.fromJson(Map<String, dynamic> json) {
    final tools = json['tools'];
    final error = _cleanText(json['error'], max: 240).toLowerCase();
    return DesktopMcpProbeResult(
      ok: json['ok'] == true,
      toolCount: tools is List ? tools.take(500).length : 0,
      authorizationRequired:
          error.contains('401') ||
          error.contains('unauthorized') ||
          error.contains('authentication'),
    );
  }
}

enum AgentCenterStatus {
  requested,
  running,
  thinking,
  tool,
  completed,
  failed,
  cancelled,
  stopped,
  unknown,
}

AgentCenterStatus _parseAgentCenterStatus(Object? raw) {
  final value = _cleanText(raw, max: 80).toLowerCase();
  return switch (value) {
    'requested' || 'pending' => AgentCenterStatus.requested,
    'running' || 'active' => AgentCenterStatus.running,
    'thinking' => AgentCenterStatus.thinking,
    'tool' || 'using_tool' || 'using tool' => AgentCenterStatus.tool,
    // `process.list` del gateway conserva ~30 min las entradas terminadas con
    // `status: "exited"`; Desktop las trata como terminadas (done/failed).
    'completed' || 'finished' || 'exited' => AgentCenterStatus.completed,
    'failed' || 'error' => AgentCenterStatus.failed,
    'cancelled' || 'canceled' => AgentCenterStatus.cancelled,
    'stopped' => AgentCenterStatus.stopped,
    _ => AgentCenterStatus.unknown,
  };
}

final class SpawnTreeEntry {
  /// Opaque backend identity used only for `spawn_tree.load`.
  final String opaquePath;
  final int count;
  final double startedAt;
  final double finishedAt;

  const SpawnTreeEntry({
    required this.opaquePath,
    required this.count,
    required this.startedAt,
    required this.finishedAt,
  });

  static SpawnTreeEntry? tryParse(Map<String, dynamic> json) {
    final path = _cleanText(json['path'], max: 2048);
    if (path.isEmpty) return null;
    return SpawnTreeEntry(
      opaquePath: path,
      count: _safeInt(json['count']).clamp(0, 10000),
      startedAt: _safeDouble(json['started_at']),
      finishedAt: _safeDouble(json['finished_at']),
    );
  }
}

final class BackgroundProcessEntry {
  /// Opaque backend identity used only for the exact `process.kill` call.
  final String opaqueId;
  final AgentCenterStatus status;
  final int uptimeSeconds;
  final String command;
  final bool notifyOnComplete;
  final List<String> watchPatterns;
  final bool watchHit;
  final DateTime? startedAt;

  const BackgroundProcessEntry({
    required this.opaqueId,
    required this.status,
    required this.uptimeSeconds,
    this.command = '',
    this.notifyOnComplete = false,
    this.watchPatterns = const [],
    this.watchHit = false,
    this.startedAt,
  });

  static BackgroundProcessEntry? tryParse(Map<String, dynamic> json) {
    final id = _cleanText(
      json['session_id'] ?? json['process_id'] ?? json['id'],
      max: 512,
    );
    if (id.isEmpty) return null;
    final startedAtSeconds = _safeDouble(json['started_at']);
    return BackgroundProcessEntry(
      opaqueId: id,
      status: _parseAgentCenterStatus(json['status'] ?? json['phase']),
      uptimeSeconds: _safeInt(
        json['uptime_seconds'] ?? json['uptime'],
      ).clamp(0, 315360000),
      command: _safeProcessCommand(json['command']),
      notifyOnComplete: json['notify_on_complete'] == true,
      watchPatterns: json['watch_patterns'] is List
          ? (json['watch_patterns'] as List)
                .map((value) => _cleanText(value, max: 120))
                .where((value) => value.isNotEmpty)
                .take(8)
                .toList(growable: false)
          : const [],
      watchHit: json['watch_hit'] == true,
      startedAt: startedAtSeconds > 0
          ? DateTime.fromMillisecondsSinceEpoch(
              (startedAtSeconds * 1000).round(),
              isUtc: true,
            )
          : null,
    );
  }
}

final class AgentCenterSnapshot {
  final List<SpawnTreeEntry> snapshots;
  final List<BackgroundProcessEntry> processes;
  final bool processesFullyParsed;

  const AgentCenterSnapshot({
    required this.snapshots,
    required this.processes,
    this.processesFullyParsed = true,
  });

  factory AgentCenterSnapshot.fromJson({
    required Map<String, dynamic> snapshots,
    Map<String, dynamic>? processes,
  }) {
    final rawProcesses = processes?['processes'];
    final parsedProcesses = _objectRows(rawProcesses)
        .map(BackgroundProcessEntry.tryParse)
        .whereType<BackgroundProcessEntry>()
        .toList(growable: false);
    return AgentCenterSnapshot(
      snapshots: _objectRows(snapshots['entries'])
          .map(SpawnTreeEntry.tryParse)
          .whereType<SpawnTreeEntry>()
          .toList(growable: false),
      processes: parsedProcesses,
      processesFullyParsed:
          rawProcesses is List && parsedProcesses.length == rawProcesses.length,
    );
  }
}

final class SpawnTreeSubagentEntry {
  final AgentCenterStatus status;

  const SpawnTreeSubagentEntry({required this.status});

  factory SpawnTreeSubagentEntry.fromJson(Map<String, dynamic> json) =>
      SpawnTreeSubagentEntry(
        status: _parseAgentCenterStatus(json['status'] ?? json['phase']),
      );
}

final class SpawnTreeDetail {
  final double startedAt;
  final double finishedAt;
  final List<SpawnTreeSubagentEntry> subagents;

  const SpawnTreeDetail({
    required this.startedAt,
    required this.finishedAt,
    required this.subagents,
  });

  factory SpawnTreeDetail.fromJson(Map<String, dynamic> json) =>
      SpawnTreeDetail(
        startedAt: _safeDouble(json['started_at']),
        finishedAt: _safeDouble(json['finished_at']),
        subagents: _objectRows(
          json['subagents'],
        ).map(SpawnTreeSubagentEntry.fromJson).toList(growable: false),
      );
}

final class ProjectSessionPreview {
  final String id;
  final String title;
  final String preview;
  final double lastActive;

  const ProjectSessionPreview({
    required this.id,
    required this.title,
    required this.preview,
    required this.lastActive,
  });

  static ProjectSessionPreview? tryParse(Map<String, dynamic> json) {
    final id = _cleanText(json['id'], max: 512);
    if (id.isEmpty) return null;
    return ProjectSessionPreview(
      id: id,
      title: _cleanText(json['title']),
      preview: _cleanText(json['preview']),
      lastActive: _safeDouble(json['last_active'] ?? json['started_at']),
    );
  }
}

final class ProjectLane {
  final String id;
  final String label;
  final String path;
  final int totalCount;
  final List<ProjectSessionPreview> sessions;

  const ProjectLane({
    required this.id,
    required this.label,
    required this.path,
    required this.totalCount,
    required this.sessions,
  });

  static ProjectLane? tryParse(Map<String, dynamic> json) {
    final id = _cleanText(json['id'], max: 2048);
    if (id.isEmpty) return null;
    final sessions = _objectRows(json['sessions'])
        .map(ProjectSessionPreview.tryParse)
        .whereType<ProjectSessionPreview>()
        .toList(growable: false);
    return ProjectLane(
      id: id,
      label: _cleanText(json['label']),
      path: _cleanText(json['path'], max: 2048),
      totalCount: _safeInt(
        json['totalCount'] ?? json['total_count'],
        fallback: sessions.length,
      ).clamp(0, 100000),
      sessions: sessions,
    );
  }
}

final class ProjectRepositoryNode {
  final String id;
  final String label;
  final String path;
  final int sessionCount;
  final List<ProjectLane> lanes;

  const ProjectRepositoryNode({
    required this.id,
    required this.label,
    required this.path,
    required this.sessionCount,
    required this.lanes,
  });

  static ProjectRepositoryNode? tryParse(Map<String, dynamic> json) {
    final id = _cleanText(json['id'], max: 2048);
    if (id.isEmpty) return null;
    return ProjectRepositoryNode(
      id: id,
      label: _cleanText(json['label']),
      path: _cleanText(json['path'], max: 2048),
      sessionCount: _safeInt(
        json['sessionCount'] ?? json['session_count'],
      ).clamp(0, 100000),
      lanes: _objectRows(json['groups'])
          .map(ProjectLane.tryParse)
          .whereType<ProjectLane>()
          .toList(growable: false),
    );
  }
}

final class ProjectNode {
  final String id;
  final String label;
  final String path;
  final String color;
  final String icon;
  final bool archived;
  final bool automatic;
  final bool noProject;
  final int sessionCount;
  final double lastActive;
  final List<ProjectSessionPreview> previewSessions;
  final List<ProjectRepositoryNode> repositories;

  const ProjectNode({
    required this.id,
    required this.label,
    required this.path,
    required this.color,
    required this.icon,
    required this.archived,
    required this.automatic,
    required this.noProject,
    required this.sessionCount,
    required this.lastActive,
    required this.previewSessions,
    required this.repositories,
  });

  static ProjectNode? tryParse(Map<String, dynamic> json) {
    final id = _cleanText(json['id'], max: 2048);
    if (id.isEmpty) return null;
    return ProjectNode(
      id: id,
      label: _cleanText(json['label'] ?? json['name']),
      path: _cleanText(json['path'] ?? json['primary_path'], max: 2048),
      color: _cleanText(json['color'], max: 32),
      icon: _cleanText(json['icon'], max: 32),
      archived: json['archived'] == true,
      automatic: json['isAuto'] == true || json['is_auto'] == true,
      noProject: json['isNoProject'] == true || json['is_no_project'] == true,
      sessionCount: _safeInt(
        json['sessionCount'] ?? json['session_count'],
      ).clamp(0, 100000),
      lastActive: _safeDouble(json['lastActive'] ?? json['last_active']),
      previewSessions:
          _objectRows(json['previewSessions'] ?? json['preview_sessions'])
              .map(ProjectSessionPreview.tryParse)
              .whereType<ProjectSessionPreview>()
              .toList(growable: false),
      repositories: _objectRows(json['repos'])
          .map(ProjectRepositoryNode.tryParse)
          .whereType<ProjectRepositoryNode>()
          .toList(growable: false),
    );
  }

  ProjectNode withHydrated(ProjectNode detail) => ProjectNode(
    id: id,
    label: detail.label.isEmpty ? label : detail.label,
    path: detail.path.isEmpty ? path : detail.path,
    color: detail.color.isEmpty ? color : detail.color,
    icon: detail.icon.isEmpty ? icon : detail.icon,
    archived: detail.archived,
    automatic: detail.automatic,
    noProject: detail.noProject,
    sessionCount: detail.sessionCount,
    lastActive: detail.lastActive == 0 ? lastActive : detail.lastActive,
    previewSessions: detail.previewSessions.isEmpty
        ? previewSessions
        : detail.previewSessions,
    repositories: detail.repositories,
  );
}

final class ProjectTreeSnapshot {
  final List<ProjectNode> projects;
  final String? activeId;

  const ProjectTreeSnapshot({required this.projects, this.activeId});

  factory ProjectTreeSnapshot.fromJson(Map<String, dynamic> json) =>
      ProjectTreeSnapshot(
        projects: _objectRows(json['projects'])
            .map(ProjectNode.tryParse)
            .whereType<ProjectNode>()
            .toList(growable: false),
        activeId: switch (_cleanText(json['active_id'], max: 2048)) {
          '' => null,
          final value => value,
        },
      );
}

/// One quality gate attached to a standing goal (`/goal gate add ...`).
final class SessionGoalGate {
  final String command;
  final int timeoutSeconds;
  final int maxRetries;
  final int attempts;
  final int? lastExitCode;

  const SessionGoalGate({
    required this.command,
    required this.timeoutSeconds,
    required this.maxRetries,
    required this.attempts,
    this.lastExitCode,
  });

  static SessionGoalGate? tryParse(Map<String, dynamic> json) {
    final command = _cleanText(json['command'], max: 400);
    if (command.isEmpty) return null;
    return SessionGoalGate(
      command: command,
      timeoutSeconds: _safeInt(json['timeout_seconds']),
      maxRetries: _safeInt(json['max_retries']),
      attempts: _safeInt(json['attempts']),
      lastExitCode: json['last_exit_code'] == null
          ? null
          : _safeInt(json['last_exit_code']),
    );
  }
}

/// A goal parked waiting on a time, another session, or a process to exit.
final class SessionGoalWaitBarrier {
  final String type;
  final String untilAt;
  final String target;
  final String reason;

  const SessionGoalWaitBarrier({
    required this.type,
    required this.untilAt,
    required this.target,
    required this.reason,
  });

  static SessionGoalWaitBarrier? tryParse(Map<String, dynamic> json) {
    final type = _cleanText(json['type'], max: 40);
    if (type.isEmpty) return null;
    return SessionGoalWaitBarrier(
      type: type,
      untilAt: _cleanText(json['until_at'], max: 80),
      target: _cleanText(json['target'], max: 200),
      reason: _cleanText(json['reason']),
    );
  }
}

DateTime? _epochDateTime(Object? raw) {
  final seconds = _safeDouble(raw);
  if (seconds <= 0) return null;
  return DateTime.fromMillisecondsSinceEpoch(
    (seconds * 1000).round(),
    isUtc: true,
  );
}

final class SessionLoopSnapshot {
  const SessionLoopSnapshot({
    required this.status,
    required this.interval,
    required this.lastRunAt,
    required this.nextDueAt,
    required this.ticksFired,
    required this.awaitingResponse,
    this.deferredByGoal = false,
  });

  final String status;
  final Duration interval;
  final DateTime? lastRunAt;
  final DateTime? nextDueAt;
  final int ticksFired;
  final bool awaitingResponse;
  final bool deferredByGoal;

  static SessionLoopSnapshot? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final json = Map<String, dynamic>.from(raw);
    final status = _cleanText(json['status'], max: 40);
    if (status.isEmpty || status == 'cleared') return null;
    return SessionLoopSnapshot(
      status: status,
      interval: Duration(
        milliseconds: (_safeDouble(json['interval_seconds']) * 1000)
            .round()
            .clamp(0, 315360000000),
      ),
      lastRunAt: _epochDateTime(json['last_fired_at']),
      nextDueAt: _epochDateTime(json['next_due_at']),
      ticksFired: _safeInt(json['ticks_fired']).clamp(0, 1000000000),
      awaitingResponse: json['awaiting_response'] == true,
      deferredByGoal: json['deferred_by_goal'] == true,
    );
  }
}

final class SessionHeartbeatSnapshot {
  const SessionHeartbeatSnapshot({
    required this.status,
    required this.interval,
    required this.lastRunAt,
    required this.nextDueAt,
    required this.fireCount,
  });

  final String status;
  final Duration interval;
  final DateTime? lastRunAt;
  final DateTime? nextDueAt;
  final int fireCount;

  static SessionHeartbeatSnapshot? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final json = Map<String, dynamic>.from(raw);
    final status = _cleanText(json['status'], max: 40);
    if (status.isEmpty || status == 'cleared') return null;
    final interval = Duration(
      seconds: _safeInt(json['interval_seconds']).clamp(0, 315360000),
    );
    final lastRunAt = _epochDateTime(json['last_fired_at']);
    return SessionHeartbeatSnapshot(
      status: status,
      interval: interval,
      lastRunAt: lastRunAt,
      nextDueAt: status == 'active' && lastRunAt != null
          ? lastRunAt.add(interval)
          : null,
      fireCount: _safeInt(json['fire_count']).clamp(0, 1000000000),
    );
  }
}

final class SessionControlSnapshot {
  const SessionControlSnapshot({
    required this.goal,
    required this.loop,
    required this.heartbeat,
    required this.revision,
    required this.updatedAt,
  });

  final SessionGoalSnapshot? goal;
  final SessionLoopSnapshot? loop;
  final SessionHeartbeatSnapshot? heartbeat;
  final String revision;
  final DateTime? updatedAt;

  factory SessionControlSnapshot.fromJson(Object? raw) {
    final json = raw is Map
        ? Map<String, dynamic>.from(raw)
        : const <String, dynamic>{};
    return SessionControlSnapshot(
      goal: SessionGoalSnapshot.tryParse(json['goal']),
      loop: SessionLoopSnapshot.tryParse(json['loop']),
      heartbeat: SessionHeartbeatSnapshot.tryParse(json['heartbeat']),
      revision: _cleanText(json['revision'], max: 128),
      updatedAt: _epochDateTime(json['updated_at']),
    );
  }
}

/// Live standing-goal state for one session, from `session.control.read` /
/// `session.control.update` (`session.control.goal` in the gateway contract).
/// A `null` snapshot (from a "cleared" status) means no active goal.
final class SessionGoalSnapshot {
  final String title;
  final String status;
  final int turnsUsed;
  final int maxTurns;
  final String outcome;
  final String verification;
  final String constraints;
  final String boundaries;
  final String stopWhen;
  final List<String> subgoals;
  final List<SessionGoalGate> gates;
  final String pausedReason;
  final String lastVerdict;
  final String lastReason;
  final SessionGoalWaitBarrier? waitBarrier;

  const SessionGoalSnapshot({
    required this.title,
    required this.status,
    required this.turnsUsed,
    required this.maxTurns,
    this.outcome = '',
    this.verification = '',
    this.constraints = '',
    this.boundaries = '',
    this.stopWhen = '',
    this.subgoals = const [],
    this.gates = const [],
    this.pausedReason = '',
    this.lastVerdict = '',
    this.lastReason = '',
    this.waitBarrier,
  });

  bool get isActive => status == 'active';
  bool get isPaused => status == 'paused';
  bool get isDone => status == 'done';
  bool get isWaiting => status == 'waiting';
  bool get isBlocked => lastVerdict == 'blocked';

  /// wait_barrier.reason > paused_reason > last_reason, same priority Desktop
  /// uses in `session-control-goal.tsx`.
  String get displayReason {
    final barrierReason = waitBarrier?.reason ?? '';
    if (barrierReason.isNotEmpty) return barrierReason;
    if (pausedReason.isNotEmpty) return pausedReason;
    return lastReason;
  }

  /// Parses `control.goal` from `session.control.read` / `.update`. Returns
  /// null both for a missing field and for an explicit `status: "cleared"`.
  static SessionGoalSnapshot? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final json = Map<String, dynamic>.from(raw);
    final status = _cleanText(json['status'], max: 40);
    if (status.isEmpty || status == 'cleared') return null;
    final contract = json['contract'];
    final contractMap = contract is Map
        ? Map<String, dynamic>.from(contract)
        : const <String, dynamic>{};
    final waitBarrierRaw = json['wait_barrier'];
    return SessionGoalSnapshot(
      title: _cleanText(json['title'], max: 200),
      status: status,
      turnsUsed: _safeInt(json['turns_used']),
      maxTurns: _safeInt(json['max_turns']),
      outcome: _cleanText(contractMap['outcome']),
      verification: _cleanText(contractMap['verification']),
      constraints: _cleanText(contractMap['constraints']),
      boundaries: _cleanText(contractMap['boundaries']),
      stopWhen: _cleanText(contractMap['stop_when']),
      subgoals: (json['subgoals'] is List)
          ? (json['subgoals'] as List)
                .map((e) => _cleanText(e, max: 200))
                .where((e) => e.isNotEmpty)
                .toList(growable: false)
          : const [],
      gates: _objectRows(json['gates'])
          .map(SessionGoalGate.tryParse)
          .whereType<SessionGoalGate>()
          .toList(growable: false),
      pausedReason: _cleanText(json['paused_reason']),
      lastVerdict: _cleanText(json['last_verdict'], max: 40),
      lastReason: _cleanText(json['last_reason']),
      waitBarrier: waitBarrierRaw is Map
          ? SessionGoalWaitBarrier.tryParse(
              Map<String, dynamic>.from(waitBarrierRaw),
            )
          : null,
    );
  }
}
