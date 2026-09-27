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
