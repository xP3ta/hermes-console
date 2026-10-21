// Matriz de capacidades por instancia.
//
// Se rellena con pruebas reales contra el Gateway (8642) y el Dashboard
// (9119) via ConnectionDiagnostics. La UI la consulta para decidir qué
// mostrar, desactivar o marcar como solo lectura — nunca para inventar
// funciones que el backend no expone.

/// Estado de una capacidad: confirmada, descartada o sin probar todavía.
enum CapState {
  yes('yes'),
  no('no'),
  unknown('unknown');

  const CapState(this.storageKey);
  final String storageKey;

  static CapState fromStorage(String? v) => CapState.values.firstWhere(
    (s) => s.storageKey == v,
    orElse: () => CapState.unknown,
  );

  bool get isYes => this == CapState.yes;
  bool get isNo => this == CapState.no;
}

class CapabilityMatrix {
  final CapState gatewayOnline;
  final CapState dashboardOnline;
  final CapState gatewayAuthValid;
  final CapState dashboardAuthValid;
  final CapState chatSupported;
  final CapState sessionsRead;
  final CapState sessionsWrite;
  final CapState sessionsDelete;
  final CapState streamingSupported;
  final CapState turnIdempotency;
  final CapState kanbanTrackedCreate;
  final CapState skillsRead;
  final CapState skillsToggle;
  final CapState skillsInstall;
  final CapState toolsetsRead;
  final CapState cronRead;
  final CapState cronWrite;
  final CapState memoryRead;
  final CapState memoryWrite;
  final CapState modelsRead;
  final CapState modelsWrite;
  final CapState configRead;
  final CapState configWrite;
  final CapState logsRead;
  final CapState pluginsSupported;

  /// Versión de hermes-agent reportada por el Dashboard (su endpoint de salud, o el de estado si falta).
  final String? gatewayVersion;

  /// Modelo activo declarado por el servidor. Ninguna sonda actual lo rellena;
  /// el campo se conserva para no cambiar el JSON guardado.
  final String? serverModel;

  /// Nombres de campos de esta matriz cuyo valor vino declarado por el
  /// servidor. Ninguna sonda actual lo rellena (el resto se infiere con
  /// probes del Dashboard); se conserva para no cambiar el JSON guardado.
  final List<String> serverSourced;

  /// Cuándo se ejecutó la detección (ms epoch).
  final int? checkedAtMs;

  const CapabilityMatrix({
    this.gatewayOnline = CapState.unknown,
    this.dashboardOnline = CapState.unknown,
    this.gatewayAuthValid = CapState.unknown,
    this.dashboardAuthValid = CapState.unknown,
    this.chatSupported = CapState.unknown,
    this.sessionsRead = CapState.unknown,
    this.sessionsWrite = CapState.unknown,
    this.sessionsDelete = CapState.unknown,
    this.streamingSupported = CapState.unknown,
    this.turnIdempotency = CapState.unknown,
    this.kanbanTrackedCreate = CapState.unknown,
    this.skillsRead = CapState.unknown,
    this.skillsToggle = CapState.unknown,
    this.skillsInstall = CapState.unknown,
    this.toolsetsRead = CapState.unknown,
    this.cronRead = CapState.unknown,
    this.cronWrite = CapState.unknown,
    this.memoryRead = CapState.unknown,
    this.memoryWrite = CapState.unknown,
    this.modelsRead = CapState.unknown,
    this.modelsWrite = CapState.unknown,
    this.configRead = CapState.unknown,
    this.configWrite = CapState.unknown,
    this.logsRead = CapState.unknown,
    this.pluginsSupported = CapState.unknown,
    this.gatewayVersion,
    this.serverModel,
    this.serverSourced = const [],
    this.checkedAtMs,
  });

  bool isServerSourced(String field) => serverSourced.contains(field);

  Map<String, dynamic> toJson() => {
    'gateway_online': gatewayOnline.storageKey,
    'dashboard_online': dashboardOnline.storageKey,
    'gateway_auth_valid': gatewayAuthValid.storageKey,
    'dashboard_auth_valid': dashboardAuthValid.storageKey,
    'chat_supported': chatSupported.storageKey,
    'sessions_read': sessionsRead.storageKey,
    'sessions_write': sessionsWrite.storageKey,
    'sessions_delete': sessionsDelete.storageKey,
    'streaming_supported': streamingSupported.storageKey,
    'turn_idempotency': turnIdempotency.storageKey,
    'kanban_tracked_create': kanbanTrackedCreate.storageKey,
    'skills_read': skillsRead.storageKey,
    'skills_toggle': skillsToggle.storageKey,
    'skills_install': skillsInstall.storageKey,
    'toolsets_read': toolsetsRead.storageKey,
    'cron_read': cronRead.storageKey,
    'cron_write': cronWrite.storageKey,
    'memory_read': memoryRead.storageKey,
    'memory_write': memoryWrite.storageKey,
    'models_read': modelsRead.storageKey,
    'models_write': modelsWrite.storageKey,
    'config_read': configRead.storageKey,
    'config_write': configWrite.storageKey,
    'logs_read': logsRead.storageKey,
    'plugins_supported': pluginsSupported.storageKey,
    'gateway_version': gatewayVersion,
    'server_model': serverModel,
    'server_sourced': serverSourced,
    'checked_at_ms': checkedAtMs,
  };

  factory CapabilityMatrix.fromJson(Map<String, dynamic> json) {
    CapState s(String key) => CapState.fromStorage(json[key] as String?);
    return CapabilityMatrix(
      gatewayOnline: s('gateway_online'),
      dashboardOnline: s('dashboard_online'),
      gatewayAuthValid: s('gateway_auth_valid'),
      dashboardAuthValid: s('dashboard_auth_valid'),
      chatSupported: s('chat_supported'),
      sessionsRead: s('sessions_read'),
      sessionsWrite: s('sessions_write'),
      sessionsDelete: s('sessions_delete'),
      streamingSupported: s('streaming_supported'),
      turnIdempotency: s('turn_idempotency'),
      kanbanTrackedCreate: s('kanban_tracked_create'),
      skillsRead: s('skills_read'),
      skillsToggle: s('skills_toggle'),
      skillsInstall: s('skills_install'),
      toolsetsRead: s('toolsets_read'),
      cronRead: s('cron_read'),
      cronWrite: s('cron_write'),
      memoryRead: s('memory_read'),
      memoryWrite: s('memory_write'),
      modelsRead: s('models_read'),
      modelsWrite: s('models_write'),
      configRead: s('config_read'),
      configWrite: s('config_write'),
      logsRead: s('logs_read'),
      pluginsSupported: s('plugins_supported'),
      gatewayVersion: json['gateway_version'] as String?,
      serverModel: json['server_model'] as String?,
      serverSourced:
          (json['server_sourced'] as List?)?.whereType<String>().toList() ??
          const [],
      checkedAtMs: json['checked_at_ms'] as int?,
    );
  }
}
