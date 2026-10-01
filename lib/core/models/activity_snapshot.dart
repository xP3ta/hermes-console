import 'dart:convert';

import 'package:flutter/foundation.dart' show listEquals;

import 'agent_task_list.dart';
import 'desktop_control_center.dart' show safeCommandProjection;
import 'session_activity.dart';
import 'subagent_activity.dart';

/// Herramientas puente de Hermes (búsqueda diferida de herramientas): el
/// modelo las llama para encontrar/describir/invocar la herramienta real. No
/// son trabajo del usuario: nunca se pintan como pasos.
bool isInternalActivityLabel(String label) {
  final normalized = label.trim().toLowerCase();
  return normalized == 'tool_call' ||
      normalized == 'tool_describe' ||
      normalized == 'tool_search';
}

/// tp1216: the tool Hermes uses to load a skill's instructions (or one of
/// its resources). Its `name` argument identifies the skill.
bool isSkillLoadTool(String label) =>
    label.trim().toLowerCase() == 'skill_view';

enum ActivityStepKind { reasoning, tool, skill }

enum ActivityStepStatus { running, done, failed }

/// Un paso (herramienta, skill o razonamiento) del turno.
final class ActivityStep {
  const ActivityStep({
    required this.id,
    required this.kind,
    required this.label,
    required this.status,
    this.detail,
    this.startedAt,
    this.duration,
    this.text,
  });

  final String id;
  final ActivityStepKind kind;
  final String label;
  final ActivityStepStatus status;

  /// Detalle ya proyectado y seguro (ver [activityToolDetail]); nunca crudo.
  final String? detail;
  final DateTime? startedAt;

  /// Duración medida, solo en pasos terminados.
  final Duration? duration;

  /// Texto libre del paso (razonamiento): solo se pinta en el historial, bajo
  /// la fila, y plegado.
  final String? text;

  bool get isRunning => status == ActivityStepStatus.running;

  /// Convierte un paso normalizado de `_activity_trace`.
  static ActivityStep? fromTrace(Map<String, dynamic> step, {int index = 0}) {
    final kind = switch (step['kind']) {
      'reasoning' => ActivityStepKind.reasoning,
      'skill' => ActivityStepKind.skill,
      'tool' => ActivityStepKind.tool,
      _ => null,
    };
    if (kind == null) return null;
    final label = kind == ActivityStepKind.reasoning
        ? ''
        : step['label']?.toString().trim() ?? '';
    if (kind != ActivityStepKind.reasoning && label.isEmpty) return null;
    final status = switch (step['status']) {
      'running' => ActivityStepStatus.running,
      'failed' || 'error' => ActivityStepStatus.failed,
      _ => ActivityStepStatus.done,
    };
    // Los pasos vivos guardan milisegundos; los reconstruidos del historial de
    // Desktop, segundos. Nada real llega a 1e11 s (año 5138).
    DateTime? instant(Object? raw) {
      if (raw is! num || !raw.isFinite || raw <= 0) return null;
      return DateTime.fromMillisecondsSinceEpoch(
        (raw < 1e11 ? raw * 1000 : raw).round(),
      );
    }

    final started = instant(step['timestamp']);
    final ended = instant(step['completed_at']);
    Duration? duration;
    if (status != ActivityStepStatus.running &&
        started != null &&
        ended != null &&
        ended.isAfter(started)) {
      duration = ended.difference(started);
    }
    final detail = step['detail']?.toString().trim();
    return ActivityStep(
      id: step['id']?.toString() ?? 'step-$index',
      kind: kind,
      label: label,
      status: status,
      detail: detail == null || detail.isEmpty ? null : detail,
      startedAt: started,
      duration: duration,
    );
  }
}

const int _maxDetailChars = 48;

final RegExp _secretLike = RegExp(
  r'(sk-[A-Za-z0-9]|ghp_|gho_|xox[abp]-|AKIA[0-9A-Z]|Bearer\s|'
  r'api[_-]?key|token|secret|passw|authorization|credential)',
  caseSensitive: false,
);

String _cap(String value, [int max = _maxDetailChars]) {
  final clean = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (clean.length <= max) return clean;
  return '${clean.substring(0, max - 1).trimRight()}…';
}

String _basename(String value) {
  final parts = value.split(RegExp(r'[/\\]'))
    ..removeWhere((part) => part.isEmpty);
  return parts.isEmpty ? '' : parts.last;
}

/// Detalle corto y SEGURO de una herramienta para la pastilla/el panel.
///
/// Reglas (privacidad primero, nunca el argumento crudo):
///  * comandos: solo la proyección del ejecutable de `safeCommandProjection`
///    (la misma de la pastilla «En segundo plano»), sin flags ni argumentos;
///  * rutas: solo el nombre del archivo, nunca el directorio;
///  * URLs: solo el host;
///  * consultas/patrones de búsqueda: texto corto, y se descartan si parecen
///    contener un secreto (claves, tokens, `Bearer …`, contraseñas).
/// Devuelve `null` cuando no hay nada presentable.
String? activityToolDetail(String tool, Object? args) {
  if (args is! Map) return null;
  String? text(String key) {
    final value = args[key];
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  // tp1216: a skill load names its skill (`skill_view {name, file_path?}`),
  // as Hermes Desktop titles it («github-pr-workflow → api.md»). Skill
  // names are catalogue identifiers, still capped and secret-screened.
  if (isSkillLoadTool(tool)) {
    final name = text('name');
    if (name != null && !_secretLike.hasMatch(name)) {
      final file = text('file_path');
      final fileName = file == null ? '' : _basename(file);
      return _cap(
        fileName.isEmpty || _secretLike.hasMatch(fileName)
            ? name
            : '$name → $fileName',
      );
    }
  }

  for (final key in const ['command', 'cmd', 'script']) {
    final command = text(key);
    if (command == null) continue;
    final projection = safeCommandProjection(command);
    return projection.isEmpty ? null : _cap(projection);
  }
  for (final key in const [
    'path',
    'file_path',
    'filepath',
    'file',
    'filename',
    'target',
  ]) {
    final path = text(key);
    if (path == null) continue;
    final name = _basename(path);
    if (name.isEmpty || _secretLike.hasMatch(name)) return null;
    return _cap(name);
  }
  final url = text('url');
  if (url != null) {
    final host = Uri.tryParse(url)?.host ?? '';
    return host.isEmpty ? null : _cap(host);
  }
  for (final key in const ['query', 'q', 'pattern']) {
    final value = text(key);
    if (value == null) continue;
    if (_secretLike.hasMatch(value)) return null;
    return _cap(value);
  }
  return null;
}

// ─────────────────────────────────────────────────────────────────────────────
// mp1215 · Escrituras de memoria que aterrizaron
// ─────────────────────────────────────────────────────────────────────────────

/// The Hermes tool that writes the agent's persistent memory/user profile.
bool isMemoryTool(String label) => label.trim().toLowerCase() == 'memory';

enum MemoryWriteAction { add, replace, remove }

/// Clave del paso de `_activity_trace` que describe una llamada `memory`.
const memoryWriteStepKey = 'memory';

const int _maxMemoryPreviewChars = 280;

final RegExp _memoryUnsafeChars = RegExp(
  '[\\x00-\\x08\\x0b-\\x1f\\x7f'
  '${String.fromCharCode(0x202a)}-${String.fromCharCode(0x202e)}'
  '${String.fromCharCode(0x2066)}-${String.fromCharCode(0x2069)}]',
);

/// Texto de vista previa seguro: espacios colapsados, sin controles ni
/// marcas bidi, acotado y descartado si parece un secreto.
String? _memoryPreview(Object? raw) {
  if (raw is! String) return null;
  final clean = raw
      .replaceAll(_memoryUnsafeChars, ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (clean.isEmpty || _secretLike.hasMatch(clean)) return null;
  return _cap(clean, _maxMemoryPreviewChars);
}

/// Una escritura de memoria tal como la describe el propio gateway: la
/// acción y el destino de los argumentos de la llamada (o, sin ellos, de la
/// forma del resultado) y [landed] solo cuando el resultado confirma
/// `success: true` sin quedar pendiente de aprobación. Sin resultado no hay
/// marca: nada se infiere.
final class MemoryWrite {
  const MemoryWrite({
    required this.action,
    required this.userTarget,
    required this.landed,
    this.preview,
  });

  final MemoryWriteAction action;

  /// `target: user` — el perfil del usuario, no las notas del agente.
  final bool userTarget;
  final bool landed;

  /// Lo guardado (add/replace) o lo quitado (remove), si viene en los args.
  final String? preview;

  Map<String, dynamic> toStep() => Map<String, dynamic>.unmodifiable({
    'action': action.name,
    'target': userTarget ? 'user' : 'memory',
    'landed': landed,
    'preview': ?preview,
  });

  static MemoryWriteAction? _action(Object? value) => switch (value) {
    'add' => MemoryWriteAction.add,
    'replace' => MemoryWriteAction.replace,
    'remove' => MemoryWriteAction.remove,
    _ => null,
  };

  /// Lee el campo [memoryWriteStepKey] de un paso ya normalizado.
  static MemoryWrite? fromStep(Object? raw) {
    if (raw is! Map) return null;
    final action = _action(raw['action']);
    if (action == null) return null;
    return MemoryWrite(
      action: action,
      userTarget: raw['target'] == 'user',
      landed: raw['landed'] == true,
      preview: _memoryPreview(raw['preview']),
    );
  }

  /// Proyecta los argumentos de una llamada `memory` (op única o lote
  /// `operations`). `null` si no es la herramienta o los args no la describen.
  static MemoryWrite? fromArgs(String tool, Object? args) {
    if (!isMemoryTool(tool)) return null;
    final record = _memoryRecord(args);
    if (record == null) return null;
    String? previewOf(Map op, MemoryWriteAction action) => _memoryPreview(
      action == MemoryWriteAction.remove
          ? op['old_text']
          : (op['content'] ?? op['new_text']),
    );

    MemoryWriteAction action;
    String? preview;
    final operations = record['operations'];
    if (operations is List && operations.isNotEmpty) {
      final ops = operations.whereType<Map>().toList(growable: false);
      final actions = ops.map((op) => _action(op['action'])).toSet();
      if (ops.length != operations.length || actions.contains(null)) {
        return null;
      }
      // Un lote homogéneo conserva su acción; uno mixto «actualiza».
      action = actions.length == 1
          ? actions.single!
          : MemoryWriteAction.replace;
      for (final op in ops) {
        preview = previewOf(op, _action(op['action'])!);
        if (preview != null) break;
      }
    } else {
      final single = _action(record['action']);
      if (single == null) return null;
      action = single;
      preview = previewOf(record, action);
    }
    return MemoryWrite(
      action: action,
      userTarget: record['target'] == 'user',
      landed: false,
      preview: preview,
    );
  }

  /// Asienta [call] (si se conocían sus args) con el resultado de la
  /// herramienta. Sin args, la acción sale de la forma del resultado que
  /// Hermes devuelve (`replaced_entry`/`removed_entry`); el texto nunca.
  static MemoryWrite? settle(MemoryWrite? call, Object? result) {
    final record = _memoryRecord(result);
    if (record == null) return call;
    final landed = memoryResultLanded(record);
    final target = record['target'];
    final replaced =
        record.containsKey('replaced_entry') ||
        record.containsKey('replaced_entries');
    final removed =
        record.containsKey('removed_entry') ||
        record.containsKey('removed_entries');
    final action =
        call?.action ??
        (replaced
            ? MemoryWriteAction.replace
            : removed
            ? MemoryWriteAction.remove
            : MemoryWriteAction.add);
    return MemoryWrite(
      action: action,
      userTarget: target is String
          ? target == 'user'
          : call?.userTarget == true,
      landed: landed,
      preview: call?.preview,
    );
  }
}

Map? _memoryRecord(Object? raw) {
  if (raw is Map) return raw;
  if (raw is! String) return null;
  final text = raw.trim();
  if (!text.startsWith('{') || text.length > 65536) return null;
  try {
    final decoded = jsonDecode(text);
    if (decoded is Map) return decoded;
  } catch (_) {
    // Hermes may append a loop warning after the JSON object.
    final end = text.lastIndexOf('}');
    if (end > 0) {
      try {
        final decoded = jsonDecode(text.substring(0, end + 1));
        if (decoded is Map) return decoded;
      } catch (_) {}
    }
  }
  return null;
}

/// El resultado de `memory` confirma que la escritura quedó guardada: el
/// gateway devuelve `success: true` y no la dejó en espera de aprobación.
bool memoryResultLanded(Object? result) {
  final record = _memoryRecord(result);
  if (record == null) return false;
  return record['success'] == true &&
      record['staged'] != true &&
      record['proposal_staged'] != true;
}

/// Todo lo que el chat sabe estar vivo AHORA, en un solo valor inmutable.
///
/// La pastilla y el panel se pintan exclusivamente desde aquí: no leen el
/// servicio. Así hay una sola fuente de la verdad para «qué está pasando» y
/// las pruebas construyen estados sin montar un chat.
final class ActivitySnapshot {
  const ActivitySnapshot({
    this.turnActive = false,
    this.tasksActive,
    this.turnStartedAt,
    this.headline,
    this.waitingForUser = false,
    this.noActivityHint = false,
    this.current,
    this.done = const [],
    this.tasks,
    this.processes = const [],
    this.schedules = const [],
    this.goal,
    this.processesStale = false,
    this.subagentsStale = false,
    this.backgroundStartedAt,
    this.subagents = const [],
    this.subagentGenericCount = 0,
    this.passiveRemote = false,
  });

  static const ActivitySnapshot idle = ActivitySnapshot();

  final bool turnActive;

  /// Las tareas se enseñan mientras hay un turno vivo, también de otra
  /// superficie; por defecto, el mismo [turnActive].
  final bool? tasksActive;
  final DateTime? turnStartedAt;

  /// Titular del pipeline (conectando / pensando / respondiendo…) cuando no hay
  /// un paso concreto en curso.
  final String? headline;
  final bool waitingForUser;

  /// Cinco minutos sin actividad del runtime: la acción cede su sitio a
  /// «Sigo trabajando».
  final bool noActivityHint;

  /// Paso en curso, con su detalle.
  final ActivityStep? current;

  /// Pasos terminados de ESTE turno, el más reciente primero.
  final List<ActivityStep> done;
  final AgentTaskList? tasks;
  final List<SessionActivityProcess> processes;
  final List<SessionActivitySchedule> schedules;
  final SessionActivityGoal? goal;
  final bool processesStale;

  /// El recuento de subagentes es el último conocido de un runtime perdido
  /// (corte, rotación): se enseña como desfasado, nunca como en vivo.
  final bool subagentsStale;
  final DateTime? backgroundStartedAt;
  final List<SubagentActivity> subagents;

  /// Subagentes conocidos solo por contador (sin detalle individual).
  final int subagentGenericCount;

  /// Otra superficie (Desktop, otro cliente) tiene trabajo vivo en esta sesión
  /// del que solo se sabe que existe: sin conteo ni detalle.
  final bool passiveRemote;

  bool get hasTasks => tasks != null && tasks!.isNotEmpty;

  /// Las tareas se enseñan mientras hay un turno vivo (con elementos abiertos
  /// o recién completadas); al terminar el turno viven en el historial.
  bool get showTasks => hasTasks && (tasksActive ?? turnActive);

  int get backgroundCount =>
      processes.length + schedules.length + (goal == null ? 0 : 1);

  int get subagentLive => subagents
      .where((a) => !a.isTerminal && a.phase != SubagentActivityPhase.unknown)
      .length;

  int get subagentEnded => subagents.where((a) => a.isTerminal).length;

  int get subagentCount => subagents.length > subagentGenericCount
      ? subagents.length
      : subagentGenericCount;

  bool get hasSubagents => subagentCount > 0 || passiveRemote;

  /// Hay subagentes vivos (o solo conocidos por contador).
  bool get subagentsRunning =>
      subagentLive > 0 ||
      (subagents.isEmpty && (subagentCount > 0 || passiveRemote));

  /// Algo distinto del turno mantiene la pastilla viva por sí solo.
  bool get hasNonTurnActivity => backgroundCount > 0 || hasSubagents;

  bool get isLive => turnActive || showTasks || hasNonTurnActivity;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ActivitySnapshot &&
          turnActive == other.turnActive &&
          tasksActive == other.tasksActive &&
          turnStartedAt == other.turnStartedAt &&
          headline == other.headline &&
          waitingForUser == other.waitingForUser &&
          noActivityHint == other.noActivityHint &&
          _stepEquals(current, other.current) &&
          _listEqualsBy(done, other.done, _stepEquals) &&
          _taskListEquals(tasks, other.tasks) &&
          _listEqualsBy(processes, other.processes, _processEquals) &&
          _listEqualsBy(schedules, other.schedules, _scheduleEquals) &&
          _goalEquals(goal, other.goal) &&
          processesStale == other.processesStale &&
          subagentsStale == other.subagentsStale &&
          backgroundStartedAt == other.backgroundStartedAt &&
          _listEqualsBy(subagents, other.subagents, _subagentEquals) &&
          subagentGenericCount == other.subagentGenericCount &&
          passiveRemote == other.passiveRemote;

  @override
  int get hashCode => Object.hashAll([
    turnActive,
    tasksActive,
    turnStartedAt,
    headline,
    waitingForUser,
    noActivityHint,
    _stepHash(current),
    _listHashBy(done, _stepHash),
    _taskListHash(tasks),
    _listHashBy(processes, _processHash),
    _listHashBy(schedules, _scheduleHash),
    _goalHash(goal),
    processesStale,
    subagentsStale,
    backgroundStartedAt,
    _listHashBy(subagents, _subagentHash),
    subagentGenericCount,
    passiveRemote,
  ]);

  ActivitySnapshot withTasksActive(bool value) => ActivitySnapshot(
    turnActive: turnActive,
    tasksActive: value,
    turnStartedAt: turnStartedAt,
    headline: headline,
    waitingForUser: waitingForUser,
    noActivityHint: noActivityHint,
    current: current,
    done: done,
    tasks: tasks,
    processes: processes,
    schedules: schedules,
    goal: goal,
    processesStale: processesStale,
    subagentsStale: subagentsStale,
    backgroundStartedAt: backgroundStartedAt,
    subagents: subagents,
    subagentGenericCount: subagentGenericCount,
    passiveRemote: passiveRemote,
  );

  ActivitySnapshot copyWith({
    bool? turnActive,
    DateTime? turnStartedAt,
    String? headline,
    bool? waitingForUser,
    bool? noActivityHint,
    ActivityStep? current,
    List<ActivityStep>? done,
    AgentTaskList? tasks,
  }) => ActivitySnapshot(
    turnActive: turnActive ?? this.turnActive,
    tasksActive: tasksActive,
    turnStartedAt: turnStartedAt ?? this.turnStartedAt,
    headline: headline ?? this.headline,
    waitingForUser: waitingForUser ?? this.waitingForUser,
    noActivityHint: noActivityHint ?? this.noActivityHint,
    current: current ?? this.current,
    done: done ?? this.done,
    tasks: tasks ?? this.tasks,
    processes: processes,
    schedules: schedules,
    goal: goal,
    processesStale: processesStale,
    subagentsStale: subagentsStale,
    backgroundStartedAt: backgroundStartedAt,
    subagents: subagents,
    subagentGenericCount: subagentGenericCount,
    passiveRemote: passiveRemote,
  );

  /// Pasos de un trace normalizado: `(current, done)` sin razonamientos ni la
  /// herramienta de tareas (que ya tiene su propia sección).
  static ({ActivityStep? current, List<ActivityStep> done}) splitSteps(
    Iterable<Map<String, dynamic>> trace,
  ) {
    final steps = <ActivityStep>[];
    var index = 0;
    for (final raw in trace) {
      final step = ActivityStep.fromTrace(raw, index: index++);
      if (step == null || step.kind == ActivityStepKind.reasoning) continue;
      final normalized = step.label.trim().toLowerCase();
      if (normalized == 'todo_list' || normalized == 'todo') continue;
      if (isInternalActivityLabel(step.label)) continue;
      steps.add(step);
    }
    ActivityStep? current;
    for (var i = steps.length - 1; i >= 0; i--) {
      if (steps[i].isRunning) {
        current = steps[i];
        break;
      }
    }
    final done = steps
        .where((step) => !step.isRunning)
        .toList(growable: false)
        .reversed
        .toList(growable: false);
    return (current: current, done: done);
  }
}

bool _listEqualsBy<T>(
  List<T> left,
  List<T> right,
  bool Function(T left, T right) equals,
) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (!equals(left[index], right[index])) return false;
  }
  return true;
}

int _listHashBy<T>(List<T> values, int Function(T value) hash) =>
    Object.hashAll(values.map(hash));

bool _stepEquals(ActivityStep? left, ActivityStep? right) =>
    identical(left, right) ||
    left != null &&
        right != null &&
        left.id == right.id &&
        left.kind == right.kind &&
        left.label == right.label &&
        left.status == right.status &&
        left.detail == right.detail &&
        left.startedAt == right.startedAt &&
        left.duration == right.duration &&
        left.text == right.text;

int _stepHash(ActivityStep? step) => step == null
    ? 0
    : Object.hash(
        step.id,
        step.kind,
        step.label,
        step.status,
        step.detail,
        step.startedAt,
        step.duration,
        step.text,
      );

bool _taskListEquals(AgentTaskList? left, AgentTaskList? right) =>
    identical(left, right) ||
    left != null &&
        right != null &&
        left.revision == right.revision &&
        left.omitted == right.omitted &&
        listEquals(left.items, right.items);

int _taskListHash(AgentTaskList? tasks) => tasks == null
    ? 0
    : Object.hash(tasks.revision, tasks.omitted, Object.hashAll(tasks.items));

bool _processEquals(
  SessionActivityProcess left,
  SessionActivityProcess right,
) =>
    identical(left, right) ||
    left.id == right.id &&
        left.command == right.command &&
        left.notifyOnComplete == right.notifyOnComplete &&
        left.startedAt == right.startedAt &&
        left.watchHit == right.watchHit &&
        listEquals(left.watchPatterns, right.watchPatterns);

int _processHash(SessionActivityProcess process) => Object.hash(
  process.id,
  process.command,
  process.notifyOnComplete,
  process.startedAt,
  process.watchHit,
  Object.hashAll(process.watchPatterns),
);

bool _scheduleEquals(
  SessionActivitySchedule left,
  SessionActivitySchedule right,
) =>
    identical(left, right) ||
    left.kind == right.kind &&
        left.status == right.status &&
        left.interval == right.interval &&
        left.lastRunAt == right.lastRunAt &&
        left.nextDueAt == right.nextDueAt &&
        left.runCount == right.runCount &&
        left.awaitingResponse == right.awaitingResponse &&
        left.deferredByGoal == right.deferredByGoal;

int _scheduleHash(SessionActivitySchedule schedule) => Object.hash(
  schedule.kind,
  schedule.status,
  schedule.interval,
  schedule.lastRunAt,
  schedule.nextDueAt,
  schedule.runCount,
  schedule.awaitingResponse,
  schedule.deferredByGoal,
);

bool _goalEquals(SessionActivityGoal? left, SessionActivityGoal? right) =>
    identical(left, right) ||
    left != null &&
        right != null &&
        left.title == right.title &&
        left.status == right.status;

int _goalHash(SessionActivityGoal? goal) =>
    goal == null ? 0 : Object.hash(goal.title, goal.status);

bool _subagentEquals(SubagentActivity left, SubagentActivity right) =>
    identical(left, right) ||
    left.key == right.key &&
        left.source == right.source &&
        left.phase == right.phase &&
        left.subagentId == right.subagentId &&
        left.delegationId == right.delegationId &&
        left.childSessionId == right.childSessionId &&
        left.legacyToolCallId == right.legacyToolCallId &&
        left.eventRevision == right.eventRevision &&
        listEquals(left.seenEventIds, right.seenEventIds) &&
        _subagentDetailsEquals(left.details, right.details);

int _subagentHash(SubagentActivity activity) => Object.hash(
  activity.key,
  activity.source,
  activity.phase,
  activity.subagentId,
  activity.delegationId,
  activity.childSessionId,
  activity.legacyToolCallId,
  activity.eventRevision,
  Object.hashAll(activity.seenEventIds),
  _subagentDetailsHash(activity.details),
);

bool _subagentDetailsEquals(
  SubagentActivityDetails left,
  SubagentActivityDetails right,
) =>
    identical(left, right) ||
    left.goalPreview == right.goalPreview &&
        left.detailPreview == right.detailPreview &&
        left.summaryPreview == right.summaryPreview &&
        left.outputTailPreview == right.outputTailPreview &&
        left.parentId == right.parentId &&
        left.depth == right.depth &&
        left.model == right.model &&
        left.progress == right.progress &&
        left.toolCount == right.toolCount &&
        listEquals(left.toolsets, right.toolsets) &&
        left.filesReadCount == right.filesReadCount &&
        left.filesWrittenCount == right.filesWrittenCount &&
        left.activeToolName == right.activeToolName &&
        left.activeToolPreview == right.activeToolPreview &&
        left.acceptingSteer == right.acceptingSteer &&
        left.usage == right.usage &&
        left.durationSeconds == right.durationSeconds &&
        left.startedAt == right.startedAt &&
        left.completedAt == right.completedAt;

int _subagentDetailsHash(SubagentActivityDetails details) => Object.hashAll([
  details.goalPreview,
  details.detailPreview,
  details.summaryPreview,
  details.outputTailPreview,
  details.parentId,
  details.depth,
  details.model,
  details.progress,
  details.toolCount,
  Object.hashAll(details.toolsets),
  details.filesReadCount,
  details.filesWrittenCount,
  details.activeToolName,
  details.activeToolPreview,
  details.acceptingSteer,
  details.usage,
  details.durationSeconds,
  details.startedAt,
  details.completedAt,
]);
