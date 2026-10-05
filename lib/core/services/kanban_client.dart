// Cliente del Kanban nativo de Hermes (plugin del dashboard).
//
// Todo tira del agente: el board, las tarjetas y los eventos en vivo vienen del
// dashboard de la conexión activa (local en :9119 vía Termux, o remoto), nunca
// de almacenamiento local. Reutiliza DashboardClient para el auth (token de
// sesión / basic), de modo que funciona idéntico en local y remoto. El tiempo
// real llega por WebSocket sobre el mismo origen del dashboard.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/agent_profile.dart';
import '../models/kanban.dart';
import '../models/kanban_orchestration.dart';
import 'connection_manager.dart';

const int kKanbanAttachmentMaxBytes = 25 * 1024 * 1024;
const List<String> kKanbanReasoningEfforts = <String>[
  'none',
  'minimal',
  'low',
  'medium',
  'high',
  'xhigh',
  'max',
  'ultra',
];

class KanbanAttachmentDownload {
  final Uint8List bytes;
  final String? contentType;

  const KanbanAttachmentDownload({required this.bytes, this.contentType});
}

class KanbanTaskTarget {
  final String boardId;
  final String? boardQuery;
  final String displayName;

  const KanbanTaskTarget({
    required this.boardId,
    required this.boardQuery,
    required this.displayName,
  });
}

class KanbanClient {
  final SavedConnection _conn;
  final DashboardClient _dash;

  KanbanClient(SavedConnection conn, {DashboardClient? dashboardClient})
    : _conn = conn,
      _dash = dashboardClient ?? DashboardClient.lazy(conn);

  static const String _base = 'plugins/kanban';

  /// Positive, read-only compatibility gate for tracked task creation.
  ///
  /// Evidence comes from the last authenticated diagnostics snapshot: a
  /// direct server declaration when present, otherwise the audited Hermes
  /// version floor. This method never probes the task POST endpoint.
  Future<bool> supportsIdempotentTrackedCreate() =>
      ConnectionManager.isKanbanTrackedCreateSupported(_conn.id);

  /// Resolves the exact board used for a Room write. Multi-board servers
  /// return a stable slug. Legacy single-board servers are labelled honestly
  /// with a non-server sentinel and omit the `board` query parameter.
  Future<KanbanTaskTarget> resolveCurrentTaskTarget() async {
    final catalog = await getBoardsIfSupported();
    if (catalog == null) {
      return const KanbanTaskTarget(
        boardId: 'legacy-current',
        boardQuery: null,
        displayName: 'Hermes (legacy current board)',
      );
    }
    final slug =
        catalog.current ??
        catalog.boards.where((board) => board.isCurrent).firstOrNull?.slug ??
        catalog.boards.first.slug;
    final selected = catalog.boards.where((board) => board.slug == slug);
    if (selected.isEmpty) {
      throw StateError('Kanban current board is absent from its catalog');
    }
    return KanbanTaskTarget(
      boardId: slug,
      boardQuery: slug,
      displayName: selected.first.name,
    );
  }

  /// Board completo (columnas + tarjetas) del agente.
  Future<KanbanBoard> getBoard({
    bool includeArchived = false,
    String? board,
  }) async {
    final json = await _dash.apiGet(
      _endpoint(
        'board',
        board: board,
        query: {if (includeArchived) 'include_archived': 'true'},
      ),
    );
    return KanbanBoard.fromJson(json, boardId: board);
  }

  /// Lee el board actual y su locator en una sola operación coherente.
  ///
  /// En Hermes multi-board fija primero el slug y consulta después ese board
  /// explícito; así un cambio concurrente de board no mezcla payload e ID.
  Future<KanbanBoard> getCurrentBoard() async {
    final target = await resolveCurrentTaskTarget();
    final board = await getBoard(board: target.boardQuery);
    return board.withBoardId(target.boardId);
  }

  /// Detalle de una tarjeta (la respuesta envuelve el task en `task`).
  Future<KanbanTask> getTask(String id, {String? board}) async {
    return (await getTaskDetail(id, board: board)).task;
  }

  /// Detalle rico publicado por Hermes Agent 0.20. Conserva compatibilidad
  /// con respuestas legacy que contienen solo la tarjeta.
  Future<KanbanTaskDetail> getTaskDetail(String id, {String? board}) async {
    final json = await _dash.apiGet(
      _endpoint('tasks/${Uri.encodeComponent(id)}', board: board),
    );
    return KanbanTaskDetail.fromJson(json);
  }

  Future<void> addComment(String taskId, String body, {String? board}) async {
    _requireWritable();
    final text = body.trim();
    if (text.isEmpty) throw ArgumentError.value(body, 'body', 'is empty');
    await _dash.apiPost(
      _endpoint('tasks/${Uri.encodeComponent(taskId)}/comments', board: board),
      body: {'body': text},
    );
  }

  Future<List<KanbanAttachment>> listAttachments(
    String taskId, {
    String? board,
  }) async {
    final json = await _dash.apiGet(
      _endpoint(
        'tasks/${Uri.encodeComponent(taskId)}/attachments',
        board: board,
      ),
    );
    final raw = json['attachments'];
    if (raw is! List) return const [];
    return List<KanbanAttachment>.unmodifiable(
      raw.whereType<Map<String, dynamic>>().map(KanbanAttachment.fromJson),
    );
  }

  Future<KanbanAttachment> uploadAttachment(
    String taskId, {
    required String filePath,
    required String filename,
    String? uploadedBy,
    String? board,
  }) async {
    _requireWritable();
    final rawName = filename.trim();
    if (rawName.isEmpty) {
      throw ArgumentError.value(filename, 'filename', 'is empty');
    }
    final basename = rawName.split(RegExp(r'[/\\]')).last;
    final name = KanbanAttachment(
      id: 'upload',
      filename: basename,
    ).safeFilename;
    final file = File(filePath);
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file) {
      throw ArgumentError.value(filePath, 'filePath', 'is not a file');
    }
    if (stat.size > kKanbanAttachmentMaxBytes) {
      throw StateError('Attachment exceeds 25 MiB');
    }
    final json = await _dash.apiPostMultipartFile(
      _endpoint(
        'tasks/${Uri.encodeComponent(taskId)}/attachments',
        board: board,
      ),
      fieldName: 'file',
      filePath: filePath,
      filename: name,
      fields: {'uploaded_by': ?_nonEmpty(uploadedBy)},
    );
    final raw = json['attachment'];
    if (raw is! Map<String, dynamic>) {
      throw const FormatException('Missing attachment response');
    }
    return KanbanAttachment.fromJson(raw);
  }

  Future<KanbanAttachmentDownload> downloadAttachment(
    String attachmentId, {
    String? board,
  }) async {
    final response = await _dash.apiDownload(
      _endpoint(
        'attachments/${Uri.encodeComponent(attachmentId)}',
        board: board,
      ),
      maxBytes: kKanbanAttachmentMaxBytes,
    );
    return KanbanAttachmentDownload(
      bytes: response.bytes,
      contentType: response.contentType,
    );
  }

  Future<void> deleteAttachment(String attachmentId, {String? board}) async {
    _requireWritable();
    await _dash.apiDelete(
      _endpoint(
        'attachments/${Uri.encodeComponent(attachmentId)}',
        board: board,
      ),
    );
  }

  Future<KanbanTaskLog> getTaskLog(
    String taskId, {
    int tailBytes = 65536,
    String? board,
  }) async {
    if (tailBytes < 1 || tailBytes > 2000000) {
      throw RangeError.range(tailBytes, 1, 2000000, 'tailBytes');
    }
    final json = await _dash.apiGet(
      _endpoint(
        'tasks/${Uri.encodeComponent(taskId)}/log',
        board: board,
        query: {'tail': '$tailBytes'},
      ),
    );
    return KanbanTaskLog.fromJson(json);
  }

  Future<KanbanRun> getRun(int runId, {String? board}) async {
    final json = await _dash.apiGet(_endpoint('runs/$runId', board: board));
    final raw = json['run'];
    if (raw is Map<String, dynamic>) return KanbanRun.fromJson(raw);
    return KanbanRun.fromJson(json);
  }

  Future<KanbanRunInspection> inspectRun(int runId, {String? board}) async {
    final json = await _dash.apiGet(
      _endpoint('runs/$runId/inspect', board: board),
    );
    return KanbanRunInspection.fromJson(json);
  }

  Future<KanbanActionResult> terminateRun(
    int runId, {
    String? reason,
    String? board,
  }) async {
    _requireWritable();
    final json = await _dash.apiPost(
      _endpoint('runs/$runId/terminate', board: board),
      body: {'reason': ?_nonEmpty(reason)},
    );
    return KanbanActionResult.fromJson(json);
  }

  Future<KanbanActionResult> reclaimTask(
    String taskId, {
    String? reason,
    String? board,
  }) async {
    _requireWritable();
    final json = await _dash.apiPost(
      _endpoint('tasks/${Uri.encodeComponent(taskId)}/reclaim', board: board),
      body: {'reason': ?_nonEmpty(reason)},
    );
    return KanbanActionResult.fromJson(json);
  }

  Future<KanbanActionResult> reassignTask(
    String taskId, {
    String? profile,
    bool reclaimFirst = false,
    String? reason,
    String? board,
  }) async {
    _requireWritable();
    final json = await _dash.apiPost(
      _endpoint('tasks/${Uri.encodeComponent(taskId)}/reassign', board: board),
      body: {
        'profile': profile,
        'reclaim_first': reclaimFirst,
        'reason': ?_nonEmpty(reason),
      },
    );
    return KanbanActionResult.fromJson(json);
  }

  Future<KanbanActionResult> specifyTask(
    String taskId, {
    String? author,
    String? board,
  }) async {
    _requireWritable();
    final json = await _dash.apiPost(
      _endpoint('tasks/${Uri.encodeComponent(taskId)}/specify', board: board),
      body: {'author': ?_nonEmpty(author)},
      timeout: const Duration(minutes: 5),
    );
    return KanbanActionResult.fromJson(json);
  }

  Future<KanbanDecomposeResult> decomposeTask(
    String taskId, {
    String? author,
    String? board,
  }) async {
    _requireWritable();
    final json = await _dash.apiPost(
      _endpoint('tasks/${Uri.encodeComponent(taskId)}/decompose', board: board),
      body: {'author': ?_nonEmpty(author)},
      timeout: const Duration(minutes: 5),
    );
    return KanbanDecomposeResult.fromJson(json);
  }

  Future<KanbanModelOptions> getModelOptions() async {
    final json = await _dash.apiGet(_endpoint('model-options'));
    return KanbanModelOptions.fromJson(json);
  }

  Future<void> updateTaskOverrides(
    String taskId, {
    String? model,
    String? provider,
    String? reasoningEffort,
    bool clearModel = false,
    bool clearReasoningEffort = false,
    String? board,
  }) async {
    _requireWritable();
    final normalizedModel = _nonEmpty(model);
    final normalizedProvider = _nonEmpty(provider);
    final normalizedEffort = _nonEmpty(reasoningEffort);
    if (!clearModel && normalizedModel == null) {
      throw ArgumentError.value(model, 'model', 'is empty');
    }
    if (normalizedEffort != null &&
        !kKanbanReasoningEfforts.contains(normalizedEffort)) {
      throw ArgumentError.value(
        reasoningEffort,
        'reasoningEffort',
        'is not supported',
      );
    }
    await _dash.apiPatch(
      _endpoint('tasks/${Uri.encodeComponent(taskId)}', board: board),
      body: {
        if (clearModel)
          'clear_model_override': true
        else ...{
          'model_override': normalizedModel,
          'provider_override': ?normalizedProvider,
        },
        if (clearReasoningEffort)
          'clear_reasoning_effort': true
        else
          'reasoning_effort': ?normalizedEffort,
      },
    );
  }

  Future<KanbanBulkResult> bulkUpdate(
    Iterable<String> taskIds, {
    String? status,
    String? assignee,
    String? priority,
    bool archive = false,
    bool reclaimFirst = false,
    String? model,
    String? provider,
    String? reasoningEffort,
    bool clearModel = false,
    bool clearReasoningEffort = false,
    String? board,
  }) async {
    _requireWritable();
    final ids = taskIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (ids.isEmpty) {
      throw ArgumentError.value(taskIds, 'taskIds', 'is empty');
    }
    final normalizedEffort = _nonEmpty(reasoningEffort);
    if (normalizedEffort != null &&
        !kKanbanReasoningEfforts.contains(normalizedEffort)) {
      throw ArgumentError.value(
        reasoningEffort,
        'reasoningEffort',
        'is not supported',
      );
    }
    final json = await _dash.apiPost(
      _endpoint('tasks/bulk', board: board),
      body: {
        'ids': ids,
        'status': ?_nonEmpty(status),
        if (assignee != null) 'assignee': assignee.trim(),
        if (priority != null) 'priority': kanbanPriorityToInt(priority),
        if (archive) 'archive': true,
        if (reclaimFirst) 'reclaim_first': true,
        if (clearModel)
          'clear_model_override': true
        else ...{
          'model_override': ?_nonEmpty(model),
          'provider_override': ?_nonEmpty(provider),
        },
        if (clearReasoningEffort)
          'clear_reasoning_effort': true
        else
          'reasoning_effort': ?normalizedEffort,
      },
    );
    return KanbanBulkResult.fromJson(json);
  }

  /// Descubrimiento positivo del endpoint multi-board. Un Dashboard legacy
  /// responde 404/405: en ese caso devolvemos null y la UI conserva el board
  /// activo sin añadir `board=` a ningún REST/WS.
  Future<KanbanBoardCatalog?> getBoardsIfSupported() async {
    try {
      final json = await _dash.apiGet('$_base/boards');
      final catalog = KanbanBoardCatalog.fromJson(json);
      // A successful multi-board response is authoritative even when it is
      // empty or malformed. Treating an empty 200 response as a legacy 404
      // would silently redirect a tracked Room write to an unspecified board.
      // Let the write resolver fail closed instead.
      return catalog;
    } on DashboardHttpException catch (e) {
      if (e.statusCode == 404 || e.statusCode == 405) return null;
      rethrow;
    }
  }

  /// Roster autoritativo de perfiles asignables. A diferencia de [getProfiles]
  /// no degrada un fallo de red/schema a una lista vacía: los callers que van a
  /// escribir deben distinguir "cero perfiles" de "no se pudo verificar".
  Future<List<AgentProfile>> getProfilesAuthoritative() async {
    final data = await _dash.apiGet('$_base/profiles');
    final raw = data['profiles'];
    if (raw is! List) {
      throw StateError('Kanban profiles response did not include a roster');
    }
    return List<AgentProfile>.unmodifiable(
      raw.whereType<Map<String, dynamic>>().map(AgentProfile.fromJson),
    );
  }

  /// Desktop-parity Kanban orchestration settings. Legacy plugins omit the
  /// route; callers hide the entry when this returns null.
  Future<KanbanOrchestration?> getOrchestration() async {
    try {
      return KanbanOrchestration.fromJson(
        await _dash.apiGet('$_base/orchestration'),
      );
    } on DashboardHttpException catch (error) {
      if (error.statusCode == 404 || error.statusCode == 405) return null;
      rethrow;
    }
  }

  Future<KanbanOrchestration> setOrchestration({
    String? orchestratorProfile,
    String? defaultAssignee,
    bool? autoDecompose,
  }) async {
    _requireWritable();
    final body = <String, dynamic>{
      'orchestrator_profile': ?orchestratorProfile?.trim(),
      'default_assignee': ?defaultAssignee?.trim(),
      'auto_decompose': ?autoDecompose,
    };
    if (body.isEmpty) {
      throw ArgumentError('one orchestration field is required');
    }
    return KanbanOrchestration.fromJson(
      await _dash.apiPut('$_base/orchestration', body: body),
    );
  }

  Future<KanbanProfileDescriptionResult> setProfileDescription(
    String name,
    String text,
  ) async {
    _requireWritable();
    final json = await _dash.apiPatch(
      '$_base/profiles/${Uri.encodeComponent(name)}',
      body: {'description': text.trim()},
    );
    return KanbanProfileDescriptionResult.fromJson(json);
  }

  Future<KanbanAutoDescriptionResult> autoDescribeProfile(String name) async {
    _requireWritable();
    final json = await _dash.apiPost(
      '$_base/profiles/${Uri.encodeComponent(name)}/describe-auto',
      body: const {'overwrite': false},
    );
    return KanbanAutoDescriptionResult.fromJson(json);
  }

  /// Perfiles asignables (GET /api/profiles). El `assignee` de una tarjeta es
  /// el perfil que la EJECUTA: el dispatcher del gateway sólo coge tareas
  /// `ready` con un perfil asignado real. Una tarjeta sin assignee se queda
  /// en `ready` para siempre (sólo es una anotación). Por eso el formulario
  /// ofrece elegir perfil. Devuelve lista vacía si el endpoint falla (la UI
  /// degrada a "sin asignar").
  Future<List<AgentProfile>> getProfiles() async {
    try {
      // El roster de perfiles asignables lo sirve el propio plugin Kanban
      // (/api/plugins/kanban/profiles), NO /api/profiles (que no existe en el
      // dashboard → 404 → lista vacía → todo quedaba "sin asignar").
      return await getProfilesAuthoritative();
    } catch (e) {
      debugPrint('[kanban] excepción silenciada (se devuelve lista vacía): $e');
      return const [];
    }
  }

  /// Crea una tarjeta. Sólo `title` es obligatorio. `assignee` es el perfil
  /// que ejecutará la tarea (vacío/null = sin asignar, sólo anotación).
  Future<void> createTask({
    required String title,
    String? body,
    String? status,
    String? priority,
    String? assignee,
    String? parent,
    String? board,
    String? modelOverride,
    String? providerOverride,
    String? reasoningEffort,
  }) async {
    _requireWritable();
    await _dash.apiPost(
      _endpoint('tasks', board: board),
      body: _createTaskPayload(
        title: title,
        body: body,
        status: status,
        priority: priority,
        assignee: assignee,
        parent: parent,
        modelOverride: modelOverride,
        providerOverride: providerOverride,
        reasoningEffort: reasoningEffort,
      ),
    );
  }

  /// Crea una task con identidad idempotente y devuelve la entidad autoritativa
  /// publicada por Hermes. Se usa cuando una superficie local necesita enlazar
  /// metadata al task id real sin mantener una base de tareas paralela.
  Future<KanbanTask> createTaskTracked({
    required String title,
    required String idempotencyKey,
    String? body,
    String? status,
    String? priority,
    String? assignee,
    String? parent,
    String? board,
    String? modelOverride,
    String? providerOverride,
    String? reasoningEffort,
  }) async {
    _requireWritable();
    final key = idempotencyKey.trim();
    if (key.isEmpty || key.length > 256) {
      throw ArgumentError.value(
        idempotencyKey,
        'idempotencyKey',
        'must contain 1 to 256 characters',
      );
    }
    final existing = await reconcileTrackedTask(
      title: title,
      idempotencyKey: key,
      body: body,
      assignee: assignee,
      board: board,
    );
    if (existing != null) return existing;
    final payload = _createTaskPayload(
      title: title,
      body: body,
      status: status,
      priority: priority,
      assignee: assignee,
      parent: parent,
      modelOverride: modelOverride,
      providerOverride: providerOverride,
      reasoningEffort: reasoningEffort,
    )..['idempotency_key'] = key;
    final response = await _dash.apiPost(
      _endpoint('tasks', board: board),
      body: payload,
    );
    final rawTask = response['task'];
    if (rawTask is! Map<String, dynamic>) {
      throw StateError('Kanban create response did not include a task');
    }
    final task = KanbanTask.fromJson(rawTask);
    if (task.id.trim().isEmpty) {
      throw StateError('Kanban create response did not include a task id');
    }
    if (task.idempotencyKey != key) {
      throw StateError(
        'Kanban create response did not confirm the idempotency key',
      );
    }
    return task;
  }

  /// Read-only reconciliation for a create whose response was ambiguous.
  ///
  /// This method never writes. A matching key with a different payload fails
  /// closed so a recovered Room operation cannot adopt somebody else's task.
  Future<KanbanTask?> reconcileTrackedTask({
    required String title,
    required String idempotencyKey,
    String? body,
    String? assignee,
    String? board,
  }) async {
    final key = idempotencyKey.trim();
    if (key.isEmpty || key.length > 256) {
      throw ArgumentError.value(
        idempotencyKey,
        'idempotencyKey',
        'must contain 1 to 256 characters',
      );
    }
    final snapshot = await getBoard(includeArchived: true, board: board);
    for (final column in snapshot.columns) {
      for (final task in column.tasks) {
        if (task.idempotencyKey != key) continue;
        final normalizedBody = body?.trim() ?? '';
        final normalizedAssignee = assignee?.trim() ?? '';
        if (task.title.trim() != title.trim() ||
            task.body.trim() != normalizedBody ||
            (task.assignee?.trim() ?? '') != normalizedAssignee) {
          throw StateError('Kanban idempotency key belongs to another payload');
        }
        return task;
      }
    }
    return null;
  }

  Map<String, dynamic> _createTaskPayload({
    required String title,
    String? body,
    String? status,
    String? priority,
    String? assignee,
    String? parent,
    String? modelOverride,
    String? providerOverride,
    String? reasoningEffort,
  }) {
    final model = _nonEmpty(modelOverride);
    final effort = _nonEmpty(reasoningEffort);
    if (effort != null && !kKanbanReasoningEfforts.contains(effort)) {
      throw ArgumentError.value(
        reasoningEffort,
        'reasoningEffort',
        'is not supported',
      );
    }
    final payload = <String, dynamic>{'title': title};
    if (body != null && body.isNotEmpty) payload['body'] = body;
    if (status != null) payload['status'] = status;
    // El servidor exige priority ENTERO (no la etiqueta) → si no, HTTP 422.
    if (priority != null) payload['priority'] = kanbanPriorityToInt(priority);
    // Sin assignee la tarea jamás se ejecuta; sólo se manda si hay perfil.
    if (assignee != null && assignee.isNotEmpty) payload['assignee'] = assignee;
    if (parent != null) payload['parent'] = parent;
    if (model != null) {
      payload['model_override'] = model;
      final provider = _nonEmpty(providerOverride);
      if (provider != null) payload['provider_override'] = provider;
    }
    if (effort != null) payload['reasoning_effort'] = effort;
    return payload;
  }

  /// Mueve una tarjeta a otra columna (PATCH status). El backend rechaza
  /// `running` (lo gestiona el dispatcher) y devuelve 409 si el padre bloquea.
  Future<void> moveTask(String id, String status, {String? board}) async {
    _requireWritable();
    await _dash.apiPatch(
      _endpoint('tasks/${Uri.encodeComponent(id)}', board: board),
      body: {'status': status},
    );
  }

  /// Actualiza campos editables de una tarjeta.
  Future<void> updateTask(
    String id, {
    String? title,
    String? body,
    String? priority,
    String? status,
    String? assignee,
    String? board,
  }) async {
    _requireWritable();
    final payload = <String, dynamic>{};
    if (title != null) payload['title'] = title;
    if (body != null) payload['body'] = body;
    // Priority como ENTERO (el servidor rechaza la etiqueta string → 422).
    if (priority != null) payload['priority'] = kanbanPriorityToInt(priority);
    if (status != null) payload['status'] = status;
    // assignee == '' desasigna (el servidor lo interpreta como sin perfil);
    // null = no tocar. Cambiar el perfil es lo que pone la tarea a ejecutar.
    if (assignee != null) payload['assignee'] = assignee;
    if (payload.isEmpty) return;
    await _dash.apiPatch(
      _endpoint('tasks/${Uri.encodeComponent(id)}', board: board),
      body: payload,
    );
  }

  Future<void> archiveTask(String id, {String? board}) =>
      updateTask(id, status: 'archived', board: board);

  Future<void> deleteTask(String id, {String? board}) async {
    _requireWritable();
    await _dash.apiDelete(
      _endpoint('tasks/${Uri.encodeComponent(id)}', board: board),
    );
  }

  /// Suscripción en vivo a los eventos del board (WebSocket). Emite un
  /// [KanbanEvent] por cada cambio; la pantalla refresca el board al recibirlo.
  /// Si el socket falla o se cierra, el stream termina (la UI puede reconectar).
  Stream<KanbanEvent> events({int since = 0, String? board}) async* {
    // Dashboards con login por cookie: el WS se autentica con un ticket de un
    // solo uso (?ticket=), no con la cookie (los sockets no pueden mandarla en
    // el upgrade). Si no hay ticket (modo token/loopback), se cae a ?token=.
    // Sin esto el board NO se actualizaba solo (había que refrescar a mano).
    final ticket = await _dash.mintWsTicket();
    final token = ticket == null ? await _resolveToken() : '';
    final wsUri = _eventsUri(
      since: since,
      ticket: ticket,
      token: token,
      board: board,
    );
    final ws = await WebSocket.connect(
      wsUri.toString(),
    ).timeout(const Duration(seconds: 10));
    // Sin ping, un socket muerto (cambio wifi→datos, NAT caducado) queda
    // zombi: el board deja de actualizarse SIN error y la reconexión de la
    // pantalla nunca se entera. Con ping, el onDone llega y se reconecta solo.
    ws.pingInterval = const Duration(seconds: 30);
    try {
      await for (final msg in ws) {
        if (msg is! String) continue;
        final decoded = jsonDecode(msg);
        if (decoded is! Map<String, dynamic>) continue;
        final events = decoded['events'];
        if (events is List) {
          for (final e in events) {
            if (e is Map<String, dynamic>) yield KanbanEvent.fromJson(e);
          }
        }
      }
    } finally {
      // Code + reason: a close frame without a code is logged as 1005.
      await ws.close(1000, 'client_dispose');
    }
  }

  Future<String> _resolveToken() async {
    final headers = await _dash.authHeadersForDiagnostics();
    return headers['X-Hermes-Session-Token'] ?? '';
  }

  Uri _eventsUri({
    required int since,
    String? ticket,
    String token = '',
    String? board,
  }) {
    final base = Uri.parse(_conn.effectiveDashboardUrl);
    final scheme = base.scheme == 'https' ? 'wss' : 'ws';
    return base.replace(
      scheme: scheme,
      path: '/api/$_base/events',
      queryParameters: <String, String>{
        if (since > 0) 'since': '$since',
        if (board != null && board.isNotEmpty) 'board': board,
        if (ticket != null && ticket.isNotEmpty) 'ticket': ticket,
        if (token.isNotEmpty) 'token': token,
      },
    );
  }

  String _endpoint(
    String suffix, {
    String? board,
    Map<String, String> query = const {},
  }) {
    final params = <String, String>{
      ...query,
      if (board != null && board.isNotEmpty) 'board': board,
    };
    final path = '$_base/$suffix';
    if (params.isEmpty) return path;
    return '$path?${Uri(queryParameters: params).query}';
  }

  String? _nonEmpty(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  void _requireWritable() {
    if (_conn.readOnly) {
      throw StateError('Read-only instance');
    }
  }

  void close() => _dash.close();
}
