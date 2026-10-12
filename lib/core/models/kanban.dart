// Modelos del Kanban nativo de Hermes (plugin servido por el dashboard en
// /api/plugins/kanban/). El board, las tarjetas y los eventos en vivo provienen
// del agente (local o remoto), nunca de almacenamiento local. El parseo es
// tolerante: el dataclass Task del backend puede añadir campos entre versiones,
// así que sólo leemos los conocidos con valores por defecto seguros.

/// Orden canónico de columnas del board de Hermes. Se usa sólo como respaldo
/// si el servidor no devolviera el orden; normalmente respetamos el orden que
/// envía el board.
const List<String> kKanbanColumnOrder = <String>[
  'triage',
  'todo',
  'scheduled',
  'ready',
  'running',
  'blocked',
  'review',
  'done',
];

/// Estados a los que el cliente puede mover una tarjeta directamente (PATCH
/// status). El backend rechaza 'running' (lo gestiona el dispatcher) con 400.
const Set<String> kKanbanMovableStatuses = <String>{
  'triage',
  'todo',
  'scheduled',
  'ready',
  'blocked',
  'review',
  'done',
};

/// La prioridad del Kanban de Hermes es un ENTERO (un "tiebreaker" de orden,
/// default 0); la app la presenta como low/normal/high. Estas funciones
/// convierten en ambos sentidos. Mandar la etiqueta como string provocaba
/// HTTP 422 ("priority debe ser entero") y fallaba TODA creación de tarea.
int kanbanPriorityToInt(String? label) {
  switch (label) {
    case 'high':
      return 3;
    case 'normal':
      return 2;
    case 'low':
      return 1;
  }
  return 0;
}

/// Entero del servidor → etiqueta. 0/ausente → null (sin chip: es el default,
/// no aporta nada mostrarlo).
String? kanbanPriorityLabel(dynamic raw) {
  final n = raw is num ? raw.toInt() : int.tryParse('${raw ?? ''}');
  if (n == null || n <= 0) return null;
  if (n >= 3) return 'high';
  if (n == 2) return 'normal';
  return 'low';
}

/// Una tarjeta del Kanban de Hermes.
class KanbanTask {
  final String id;
  final String title;
  final String body;
  final String status;
  final String? priority;
  final String? assignee;
  final String? parent;
  final String? blockReason;
  final String? latestSummary;
  final String? result;
  final int? createdAt;
  final int? startedAt;
  final int? completedAt;
  final int commentCount;
  final int progressDone;
  final int progressTotal;
  final int? workerPid;
  final int? lastHeartbeatAt;
  final String? modelOverride;
  final String? providerOverride;
  final String? reasoningEffort;
  final String? idempotencyKey;

  /// The server's failure streak (`consecutive_failures`): each crashed or
  /// timed-out worker run raises it, so a change means new failure events.
  final int consecutiveFailures;

  const KanbanTask({
    required this.id,
    required this.title,
    required this.body,
    required this.status,
    this.priority,
    this.assignee,
    this.parent,
    this.blockReason,
    this.latestSummary,
    this.result,
    this.createdAt,
    this.startedAt,
    this.completedAt,
    this.commentCount = 0,
    this.progressDone = 0,
    this.progressTotal = 0,
    this.workerPid,
    this.lastHeartbeatAt,
    this.modelOverride,
    this.providerOverride,
    this.reasoningEffort,
    this.idempotencyKey,
    this.consecutiveFailures = 0,
  });

  bool get isBlocked =>
      status == 'blocked' || (blockReason != null && blockReason!.isNotEmpty);

  bool get hasProgress => progressTotal > 0;

  factory KanbanTask.fromJson(Map<String, dynamic> json) {
    final progress = json['progress'];
    int done = 0;
    int total = 0;
    if (progress is Map) {
      done = _asInt(progress['done']);
      total = _asInt(progress['total']);
    }
    return KanbanTask(
      id: (json['id'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      body: (json['body'] ?? '').toString(),
      status: (json['status'] ?? 'todo').toString(),
      priority: kanbanPriorityLabel(json['priority']),
      assignee: _asNullableString(json['assignee']),
      parent: _asNullableString(json['parent']),
      blockReason: _asNullableString(json['block_reason']),
      latestSummary: _asNullableString(json['latest_summary']),
      result: _asNullableString(json['result']),
      createdAt: _asNullableInt(json['created_at']),
      startedAt: _asNullableInt(json['started_at']),
      completedAt: _asNullableInt(json['completed_at']),
      commentCount: _asInt(json['comment_count']),
      progressDone: done,
      progressTotal: total,
      workerPid: _asNullableInt(json['worker_pid']),
      lastHeartbeatAt: _asNullableInt(json['last_heartbeat_at']),
      modelOverride: _asNullableString(json['model_override']),
      providerOverride: _asNullableString(json['provider_override']),
      reasoningEffort: _asNullableString(json['reasoning_effort']),
      idempotencyKey: _asNullableString(json['idempotency_key']),
      consecutiveFailures: _asInt(json['consecutive_failures']),
    );
  }

  KanbanTask copyWith({String? status}) => KanbanTask(
    id: id,
    title: title,
    body: body,
    status: status ?? this.status,
    priority: priority,
    assignee: assignee,
    parent: parent,
    blockReason: blockReason,
    latestSummary: latestSummary,
    result: result,
    createdAt: createdAt,
    startedAt: startedAt,
    completedAt: completedAt,
    commentCount: commentCount,
    progressDone: progressDone,
    progressTotal: progressTotal,
    workerPid: workerPid,
    lastHeartbeatAt: lastHeartbeatAt,
    modelOverride: modelOverride,
    providerOverride: providerOverride,
    reasoningEffort: reasoningEffort,
    idempotencyKey: idempotencyKey,
    consecutiveFailures: consecutiveFailures,
  );
}

enum KanbanTaskDetailCapability {
  comments,
  events,
  attachments,
  links,
  childResults,
  runs,
  diagnostics,
}

/// Respuesta completa de `GET /tasks/:id` en Hermes Agent 0.20.
///
/// Los servidores anteriores pueden devolver únicamente la tarjeta. En ese
/// caso las colecciones quedan vacías, sin fabricar datos ni confundir una
/// capacidad ausente con contenido real.
class KanbanTaskDetail {
  final KanbanTask task;
  final List<KanbanComment> comments;
  final List<KanbanTaskEvent> events;
  final List<KanbanAttachment> attachments;
  final KanbanTaskLinks links;
  final List<KanbanChildResult> childResults;
  final List<KanbanRun> runs;
  final List<KanbanDiagnostic> diagnostics;
  final Set<KanbanTaskDetailCapability> capabilities;

  const KanbanTaskDetail({
    required this.task,
    this.comments = const [],
    this.events = const [],
    this.attachments = const [],
    this.links = const KanbanTaskLinks(),
    this.childResults = const [],
    this.runs = const [],
    this.diagnostics = const [],
    this.capabilities = const {},
  });

  factory KanbanTaskDetail.fromJson(Map<String, dynamic> json) {
    final taskJson = _asStringMap(json['task']) ?? json;
    final capabilities = <KanbanTaskDetailCapability>{
      if (json.containsKey('comments')) KanbanTaskDetailCapability.comments,
      if (json.containsKey('events')) KanbanTaskDetailCapability.events,
      if (json.containsKey('attachments'))
        KanbanTaskDetailCapability.attachments,
      if (json.containsKey('links')) KanbanTaskDetailCapability.links,
      if (json.containsKey('child_results'))
        KanbanTaskDetailCapability.childResults,
      if (json.containsKey('runs')) KanbanTaskDetailCapability.runs,
      if (taskJson.containsKey('diagnostics'))
        KanbanTaskDetailCapability.diagnostics,
    };
    return KanbanTaskDetail(
      task: KanbanTask.fromJson(taskJson),
      comments: _parseMapList(json['comments'], KanbanComment.fromJson),
      events: _parseMapList(json['events'], KanbanTaskEvent.fromJson),
      attachments: _parseMapList(
        json['attachments'],
        KanbanAttachment.fromJson,
      ),
      links: KanbanTaskLinks.fromJson(_asStringMap(json['links']) ?? const {}),
      childResults: _parseMapList(
        json['child_results'],
        KanbanChildResult.fromJson,
      ),
      runs: _parseMapList(json['runs'], KanbanRun.fromJson),
      diagnostics: _parseMapList(
        taskJson['diagnostics'],
        KanbanDiagnostic.fromJson,
      ),
      capabilities: Set<KanbanTaskDetailCapability>.unmodifiable(capabilities),
    );
  }

  bool supports(KanbanTaskDetailCapability capability) =>
      capabilities.contains(capability);
}

class KanbanComment {
  final String id;
  final String? taskId;
  final String author;
  final String body;
  final int? createdAt;

  const KanbanComment({
    required this.id,
    this.taskId,
    required this.author,
    required this.body,
    this.createdAt,
  });

  factory KanbanComment.fromJson(Map<String, dynamic> json) => KanbanComment(
    id: _asStringId(json['id']),
    taskId: _asNullableString(json['task_id']),
    author: (json['author'] ?? '').toString(),
    body: (json['body'] ?? '').toString(),
    createdAt: _asNullableInt(json['created_at']),
  );
}

class KanbanTaskEvent {
  final int id;
  final String? taskId;
  final String kind;
  final Map<String, dynamic> payload;
  final int? createdAt;
  final int? runId;

  const KanbanTaskEvent({
    required this.id,
    this.taskId,
    required this.kind,
    this.payload = const {},
    this.createdAt,
    this.runId,
  });

  factory KanbanTaskEvent.fromJson(Map<String, dynamic> json) =>
      KanbanTaskEvent(
        id: _asInt(json['id']),
        taskId: _asNullableString(json['task_id']),
        kind: (json['kind'] ?? '').toString(),
        payload: _immutableMap(json['payload']),
        createdAt: _asNullableInt(json['created_at']),
        runId: _asNullableInt(json['run_id']),
      );
}

/// Adjunto remoto. Deliberadamente no conserva `stored_path`: esa ruta
/// pertenece al servidor y nunca debe presentarse como un fichero Android.
class KanbanAttachment {
  final String id;
  final String? taskId;
  final String filename;
  final String? contentType;
  final int size;
  final String? uploadedBy;
  final int? createdAt;

  const KanbanAttachment({
    required this.id,
    this.taskId,
    required this.filename,
    this.contentType,
    this.size = 0,
    this.uploadedBy,
    this.createdAt,
  });

  factory KanbanAttachment.fromJson(Map<String, dynamic> json) =>
      KanbanAttachment(
        id: _asStringId(json['id']),
        taskId: _asNullableString(json['task_id']),
        filename: (json['filename'] ?? '').toString(),
        contentType: _asNullableString(json['content_type']),
        size: _asInt(json['size']),
        uploadedBy: _asNullableString(json['uploaded_by']),
        createdAt: _asNullableInt(json['created_at']),
      );

  @override
  String toString() => 'KanbanAttachment($id, $safeFilename, $size bytes)';

  String get safeFilename {
    // El Dashboard oficial ya sanea el nombre, pero un servidor legacy o
    // manipulado puede devolver una ruta absoluta. Android solo conserva el
    // basename: ni el texto visible, ni el diálogo de borrado, ni `toString`
    // deben filtrar directorios del host remoto.
    final basename = filename.replaceAll('\\', '/').split('/').last;
    var value = basename.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '_').trim();
    if (value == '.' || value == '..') value = '';
    if (value.isEmpty) value = 'attachment-$id';
    if (value.length > 120) value = value.substring(value.length - 120);
    return value;
  }
}

class KanbanTaskLinks {
  final List<String> parents;
  final List<String> children;
  final List<String> blockedBy;
  final List<String> blocks;

  const KanbanTaskLinks({
    this.parents = const [],
    this.children = const [],
    this.blockedBy = const [],
    this.blocks = const [],
  });

  factory KanbanTaskLinks.fromJson(Map<String, dynamic> json) =>
      KanbanTaskLinks(
        parents: _immutableStrings(json['parents']),
        children: _immutableStrings(json['children']),
        blockedBy: _immutableStrings(json['blocked_by']),
        blocks: _immutableStrings(json['blocks']),
      );
}

class KanbanChildResult {
  final String id;
  final String title;
  final String status;
  final String? latestSummary;
  final String? result;

  const KanbanChildResult({
    required this.id,
    required this.title,
    required this.status,
    this.latestSummary,
    this.result,
  });

  factory KanbanChildResult.fromJson(Map<String, dynamic> json) =>
      KanbanChildResult(
        id: _asStringId(json['id']),
        title: (json['title'] ?? '').toString(),
        status: (json['status'] ?? '').toString(),
        latestSummary: _asNullableString(json['latest_summary']),
        result: _asNullableString(json['result']),
      );
}

class KanbanRun {
  final int id;
  final String? taskId;
  final String? profile;
  final String? stepKey;
  final String status;
  final String? claimLock;
  final int? claimExpires;
  final int? workerPid;
  final int? maxRuntimeSeconds;
  final int? lastHeartbeatAt;
  final int? startedAt;
  final int? endedAt;
  final String? outcome;
  final String? summary;
  final Map<String, dynamic> metadata;
  final String? error;

  const KanbanRun({
    required this.id,
    this.taskId,
    this.profile,
    this.stepKey,
    this.status = '',
    this.claimLock,
    this.claimExpires,
    this.workerPid,
    this.maxRuntimeSeconds,
    this.lastHeartbeatAt,
    this.startedAt,
    this.endedAt,
    this.outcome,
    this.summary,
    this.metadata = const {},
    this.error,
  });

  factory KanbanRun.fromJson(Map<String, dynamic> json) => KanbanRun(
    id: _asInt(json['id']),
    taskId: _asNullableString(json['task_id']),
    profile: _asNullableString(json['profile']),
    stepKey: _asNullableString(json['step_key']),
    status: (json['status'] ?? '').toString(),
    claimLock: _asNullableString(json['claim_lock']),
    claimExpires: _asNullableInt(json['claim_expires']),
    workerPid: _asNullableInt(json['worker_pid']),
    maxRuntimeSeconds: _asNullableInt(json['max_runtime_seconds']),
    lastHeartbeatAt: _asNullableInt(json['last_heartbeat_at']),
    startedAt: _asNullableInt(json['started_at']),
    endedAt: _asNullableInt(json['ended_at']),
    outcome: _asNullableString(json['outcome']),
    summary: _asNullableString(json['summary']),
    metadata: _immutableMap(json['metadata']),
    error: _asNullableString(json['error']),
  );
}

enum KanbanDiagnosticSeverity { unknown, warning, error, critical }

class KanbanDiagnosticAction {
  final String kind;
  final String label;
  final Map<String, dynamic> payload;
  final bool suggested;

  const KanbanDiagnosticAction({
    required this.kind,
    required this.label,
    this.payload = const {},
    this.suggested = false,
  });

  factory KanbanDiagnosticAction.fromJson(Map<String, dynamic> json) =>
      KanbanDiagnosticAction(
        kind: (json['kind'] ?? '').toString(),
        label: (json['label'] ?? '').toString(),
        payload: _immutableMap(json['payload']),
        suggested: json['suggested'] == true,
      );
}

class KanbanDiagnostic {
  final String kind;
  final KanbanDiagnosticSeverity severity;
  final String title;
  final String detail;
  final List<KanbanDiagnosticAction> actions;
  final int? firstSeenAt;
  final int? lastSeenAt;
  final int count;
  final int? runId;
  final Map<String, dynamic> data;

  const KanbanDiagnostic({
    required this.kind,
    this.severity = KanbanDiagnosticSeverity.unknown,
    required this.title,
    required this.detail,
    this.actions = const [],
    this.firstSeenAt,
    this.lastSeenAt,
    this.count = 1,
    this.runId,
    this.data = const {},
  });

  factory KanbanDiagnostic.fromJson(Map<String, dynamic> json) =>
      KanbanDiagnostic(
        kind: (json['kind'] ?? '').toString(),
        severity: _diagnosticSeverity(json['severity']),
        title: (json['title'] ?? '').toString(),
        detail: (json['detail'] ?? '').toString(),
        actions: _parseMapList(
          json['actions'],
          KanbanDiagnosticAction.fromJson,
        ),
        firstSeenAt: _asNullableInt(json['first_seen_at']),
        lastSeenAt: _asNullableInt(json['last_seen_at']),
        count: _asInt(json['count']).clamp(1, 1 << 30),
        runId: _asNullableInt(json['run_id']),
        data: _immutableMap(json['data']),
      );
}

class KanbanTaskLog {
  final String taskId;
  final bool exists;
  final int sizeBytes;
  final String content;
  final bool truncated;

  const KanbanTaskLog({
    required this.taskId,
    required this.exists,
    this.sizeBytes = 0,
    this.content = '',
    this.truncated = false,
  });

  factory KanbanTaskLog.fromJson(Map<String, dynamic> json) => KanbanTaskLog(
    taskId: (json['task_id'] ?? '').toString(),
    exists: json['exists'] == true,
    sizeBytes: _asInt(json['size_bytes']),
    content: (json['content'] ?? '').toString(),
    truncated: json['truncated'] == true,
  );

  @override
  String toString() =>
      'KanbanTaskLog($taskId, $sizeBytes bytes, truncated: $truncated)';
}

class KanbanRunInspection {
  final int runId;
  final bool alive;
  final int? pid;
  final String? reason;
  final String? error;
  final double? cpuPercent;
  final int? memoryRssBytes;
  final int? memoryVmsBytes;
  final int? numThreads;
  final int? numFds;
  final String? status;
  final double? createTime;
  final List<String> command;

  const KanbanRunInspection({
    required this.runId,
    required this.alive,
    this.pid,
    this.reason,
    this.error,
    this.cpuPercent,
    this.memoryRssBytes,
    this.memoryVmsBytes,
    this.numThreads,
    this.numFds,
    this.status,
    this.createTime,
    this.command = const [],
  });

  factory KanbanRunInspection.fromJson(Map<String, dynamic> json) =>
      KanbanRunInspection(
        runId: _asInt(json['run_id']),
        alive: json['alive'] == true,
        pid: _asNullableInt(json['pid']),
        reason: _asNullableString(json['reason']),
        error: _asNullableString(json['error']),
        cpuPercent: _asNullableDouble(json['cpu_percent']),
        memoryRssBytes: _asNullableInt(json['memory_rss_bytes']),
        memoryVmsBytes: _asNullableInt(json['memory_vms_bytes']),
        numThreads: _asNullableInt(json['num_threads']),
        numFds: _asNullableInt(json['num_fds']),
        status: _asNullableString(json['status']),
        createTime: _asNullableDouble(json['create_time']),
        command: _immutableStrings(json['cmdline']),
      );
}

class KanbanActionResult {
  final bool ok;
  final String? taskId;
  final int? runId;
  final String? reason;
  final String? newTitle;
  final String? assignee;

  const KanbanActionResult({
    required this.ok,
    this.taskId,
    this.runId,
    this.reason,
    this.newTitle,
    this.assignee,
  });

  factory KanbanActionResult.fromJson(Map<String, dynamic> json) =>
      KanbanActionResult(
        ok: json['ok'] == true,
        taskId: _asNullableString(json['task_id']),
        runId: _asNullableInt(json['run_id']),
        reason: _asNullableString(json['reason']),
        newTitle: _asNullableString(json['new_title']),
        assignee: _asNullableString(json['assignee']),
      );
}

class KanbanModelProviderOption {
  final String slug;
  final String label;
  final List<String> models;

  const KanbanModelProviderOption({
    required this.slug,
    required this.label,
    this.models = const [],
  });

  factory KanbanModelProviderOption.fromJson(Map<String, dynamic> json) {
    final slug = (json['slug'] ?? '').toString().trim();
    final label = (json['label'] ?? '').toString().trim();
    return KanbanModelProviderOption(
      slug: slug,
      label: label.isEmpty ? slug : label,
      models: _immutableStrings(json['models'])
          .map((model) => model.trim())
          .where((model) => model.isNotEmpty)
          .toList(growable: false),
    );
  }
}

class KanbanModelOptions {
  final List<KanbanModelProviderOption> providers;

  const KanbanModelOptions({this.providers = const []});

  factory KanbanModelOptions.fromJson(Map<String, dynamic> json) =>
      KanbanModelOptions(
        providers:
            _parseMapList(json['providers'], KanbanModelProviderOption.fromJson)
                .where((provider) => provider.models.isNotEmpty)
                .toList(growable: false),
      );
}

class KanbanDecomposeResult {
  final bool ok;
  final String? taskId;
  final String? reason;
  final bool fanout;
  final List<String> childIds;
  final String? newTitle;

  const KanbanDecomposeResult({
    required this.ok,
    this.taskId,
    this.reason,
    this.fanout = false,
    this.childIds = const [],
    this.newTitle,
  });

  factory KanbanDecomposeResult.fromJson(Map<String, dynamic> json) =>
      KanbanDecomposeResult(
        ok: json['ok'] == true,
        taskId: _asNullableString(json['task_id']),
        reason: _asNullableString(json['reason']),
        fanout: json['fanout'] == true,
        childIds: _immutableStrings(json['child_ids']),
        newTitle: _asNullableString(json['new_title']),
      );
}

class KanbanBulkItemResult {
  final String id;
  final bool ok;
  final String? error;

  const KanbanBulkItemResult({required this.id, required this.ok, this.error});

  factory KanbanBulkItemResult.fromJson(Map<String, dynamic> json) =>
      KanbanBulkItemResult(
        id: _asStringId(json['id']),
        ok: json['ok'] == true,
        error: _asNullableString(json['error']),
      );
}

class KanbanBulkResult {
  final List<KanbanBulkItemResult> results;

  const KanbanBulkResult({this.results = const []});

  factory KanbanBulkResult.fromJson(Map<String, dynamic> json) =>
      KanbanBulkResult(
        results: _parseMapList(json['results'], KanbanBulkItemResult.fromJson),
      );

  List<KanbanBulkItemResult> get failed =>
      results.where((result) => !result.ok).toList(growable: false);

  List<KanbanBulkItemResult> get succeeded =>
      results.where((result) => result.ok).toList(growable: false);
}

/// Los cinco grupos humanos del tablero móvil más la vista de archivo.
///
/// [archived] no se añade como una sexta sección al tablero normal: se muestra
/// únicamente cuando el usuario abre el filtro de archivo. Así se conserva la
/// bandeja móvil de cinco grupos y el historial sigue siendo recuperable.
enum KanbanMobileGroup { attention, working, queued, notes, done, archived }

KanbanMobileGroup kanbanMobileGroupFor(KanbanTask task) {
  switch (task.status) {
    case 'blocked':
    case 'review':
      return KanbanMobileGroup.attention;
    case 'running':
      return KanbanMobileGroup.working;
    case 'done':
      return KanbanMobileGroup.done;
    case 'archived':
      return KanbanMobileGroup.archived;
    default:
      return (task.assignee ?? '').isEmpty
          ? KanbanMobileGroup.notes
          : KanbanMobileGroup.queued;
  }
}

/// Filtro puramente local para la bandeja móvil. La consulta cubre el resumen
/// visible y los campos que pueden explicar por qué una tarea requiere atención.
bool kanbanTaskMatchesFilter(
  KanbanTask task, {
  String query = '',
  KanbanMobileGroup? group,
}) {
  final mobileGroup = kanbanMobileGroupFor(task);
  if (group != null) {
    if (mobileGroup != group) return false;
  } else if (mobileGroup == KanbanMobileGroup.archived) {
    return false;
  }

  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return true;
  final haystack = <String?>[
    task.id,
    task.title,
    task.body,
    task.assignee,
    task.blockReason,
    task.latestSummary,
    task.result,
  ].whereType<String>().join('\n').toLowerCase();
  return haystack.contains(needle);
}

/// Una columna del board (estado + tarjetas).
class KanbanColumn {
  final String name;
  final List<KanbanTask> tasks;

  const KanbanColumn({required this.name, required this.tasks});

  factory KanbanColumn.fromJson(Map<String, dynamic> json) {
    final rawTasks = json['tasks'];
    final tasks = <KanbanTask>[];
    if (rawTasks is List) {
      for (final t in rawTasks) {
        if (t is Map<String, dynamic>) tasks.add(KanbanTask.fromJson(t));
      }
    }
    return KanbanColumn(name: (json['name'] ?? '').toString(), tasks: tasks);
  }
}

/// El board completo devuelto por GET /api/plugins/kanban/board.
class KanbanBoard {
  final List<KanbanColumn> columns;
  final int latestEventId;
  final String? boardId;

  const KanbanBoard({
    required this.columns,
    this.latestEventId = 0,
    this.boardId,
  });

  factory KanbanBoard.fromJson(Map<String, dynamic> json, {String? boardId}) {
    final rawCols = json['columns'];
    final columns = <KanbanColumn>[];
    if (rawCols is List) {
      for (final c in rawCols) {
        if (c is Map<String, dynamic>) columns.add(KanbanColumn.fromJson(c));
      }
    }
    return KanbanBoard(
      columns: columns,
      latestEventId: _asInt(json['latest_event_id']),
      boardId: boardId,
    );
  }

  int get taskCount => columns.fold(0, (sum, c) => sum + c.tasks.length);

  KanbanBoard withBoardId(String value) => KanbanBoard(
    columns: columns,
    latestEventId: latestEventId,
    boardId: value,
  );
}

/// Entrada del endpoint opcional `/boards`. Solo se usa después de que el
/// servidor haya demostrado que soporta el catálogo multi-board.
class KanbanBoardRef {
  final String slug;
  final String name;
  final bool isCurrent;

  const KanbanBoardRef({
    required this.slug,
    required this.name,
    this.isCurrent = false,
  });

  factory KanbanBoardRef.fromJson(Map<String, dynamic> json) {
    final slug = (json['slug'] ?? '').toString().trim();
    final name = (json['name'] ?? '').toString().trim();
    return KanbanBoardRef(
      slug: slug,
      name: name.isEmpty ? slug : name,
      isCurrent: json['is_current'] == true,
    );
  }
}

class KanbanBoardCatalog {
  final List<KanbanBoardRef> boards;
  final String? current;

  const KanbanBoardCatalog({required this.boards, this.current});

  factory KanbanBoardCatalog.fromJson(Map<String, dynamic> json) {
    final rawBoards = json['boards'];
    final boards = <KanbanBoardRef>[];
    if (rawBoards is List) {
      for (final raw in rawBoards) {
        if (raw is! Map<String, dynamic>) continue;
        final board = KanbanBoardRef.fromJson(raw);
        if (board.slug.isNotEmpty) boards.add(board);
      }
    }
    final explicitCurrent = _asNullableString(json['current']);
    final inferredCurrent = boards
        .where((board) => board.isCurrent)
        .map((board) => board.slug)
        .firstOrNull;
    return KanbanBoardCatalog(
      boards: boards,
      current: explicitCurrent ?? inferredCurrent,
    );
  }
}

/// Un evento en vivo del board (llega por WebSocket /api/plugins/kanban/events).
class KanbanEvent {
  final int id;
  final String? taskId;
  final String kind;

  /// Event payload (`reason`, `summary`, `error`…), when the server sends it.
  final Map<String, dynamic>? payload;

  const KanbanEvent({
    required this.id,
    this.taskId,
    this.kind = '',
    this.payload,
  });

  factory KanbanEvent.fromJson(Map<String, dynamic> json) => KanbanEvent(
    id: _asInt(json['id']),
    taskId: _asNullableString(json['task_id']),
    kind: (json['kind'] ?? '').toString(),
    payload: json['payload'] is Map
        ? Map<String, dynamic>.from(json['payload'] as Map)
        : null,
  );
}

/// Etiqueta legible de una columna/estado del board de Hermes. Son términos
/// técnicos del agente; se muestran en Title Case con respaldo genérico.
String kanbanColumnLabel(String name) {
  switch (name) {
    case 'triage':
      return 'Triage';
    case 'todo':
      return 'To Do';
    case 'scheduled':
      return 'Scheduled';
    case 'ready':
      return 'Ready';
    case 'running':
      return 'Running';
    case 'blocked':
      return 'Blocked';
    case 'review':
      return 'Review';
    case 'done':
      return 'Done';
  }
  if (name.isEmpty) return '—';
  return name[0].toUpperCase() + name.substring(1);
}

int _asInt(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}

int? _asNullableInt(Object? v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}

String? _asNullableString(Object? v) {
  if (v == null) return null;
  final s = v.toString();
  return s.isEmpty ? null : s;
}

String _asStringId(Object? value) => value == null ? '' : value.toString();

double? _asNullableDouble(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

Map<String, dynamic>? _asStringMap(Object? value) {
  if (value is! Map) return null;
  return <String, dynamic>{
    for (final entry in value.entries)
      if (entry.key is String) entry.key as String: entry.value,
  };
}

Map<String, dynamic> _immutableMap(Object? value) =>
    Map<String, dynamic>.unmodifiable(_asStringMap(value) ?? const {});

List<String> _immutableStrings(Object? value) {
  if (value is! List) return const [];
  return List<String>.unmodifiable(
    value.where((item) => item != null).map((item) => item.toString()),
  );
}

List<T> _parseMapList<T>(
  Object? value,
  T Function(Map<String, dynamic>) parse,
) {
  if (value is! List) return const [];
  final parsed = <T>[];
  for (final item in value) {
    final map = _asStringMap(item);
    if (map != null) parsed.add(parse(map));
  }
  return List<T>.unmodifiable(parsed);
}

KanbanDiagnosticSeverity _diagnosticSeverity(Object? value) {
  switch (value?.toString()) {
    case 'warning':
      return KanbanDiagnosticSeverity.warning;
    case 'error':
      return KanbanDiagnosticSeverity.error;
    case 'critical':
      return KanbanDiagnosticSeverity.critical;
    default:
      return KanbanDiagnosticSeverity.unknown;
  }
}
