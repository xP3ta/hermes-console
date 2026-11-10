import 'dart:convert';

import 'package:flutter/foundation.dart' show listEquals;

import 'agent_task_list.dart';
import 'desktop_control_center.dart' show safeCommandProjection;
import 'session_activity.dart';
import 'subagent_activity.dart';
import 'tool_name.dart' show canonicalToolName;

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

/// Activity traces use seconds in history and milliseconds on the live wire.
/// Reject epoch/sentinel instants before subtracting or converting to DateTime.
DateTime? activityInstant(Object? raw) {
  if (raw is! num || !raw.isFinite || raw <= 0) return null;
  final ms = raw < 1e11 ? raw * 1000 : raw;
  if (ms < 1e12 || ms > 8640000000000000) return null;
  return DateTime.fromMillisecondsSinceEpoch(ms.round());
}

/// A missing/implausible measurement is unknown, never a clamped duration.
Duration? measuredActivityDuration(Duration? value) =>
    value == null || value.isNegative || value.inHours >= 24 ? null : value;

enum ActivityStepKind { reasoning, tool, skill }

enum ActivityStepStatus { running, done, failed }

/// Un paso (herramienta, skill o razonamiento) del turno.
final class ActivityStep {
  const ActivityStep({
    required this.id,
    required this.kind,
    required this.label,
    required this.status,
    // Preserve the public argument and const snapshots while projecting on read.
    String? detail,
    this.startedAt,
    this.duration,
    this.text,
    this.title,
    // ignore: prefer_initializing_formals
  }) : _detail = detail;

  final String id;
  final ActivityStepKind kind;
  final String label;
  final ActivityStepStatus status;

  /// The gateway's own label of an MCP or connector call («GitHub · create
  /// issue»), when its event carried one; the screen prefers it to [label].
  final String? title;

  final String? _detail;

  /// Client-projected detail, including snapshots that arrived unfiltered.
  String? get detail => kind == ActivityStepKind.reasoning
      ? null
      : sanitizeActivityDetail(
          kind == ActivityStepKind.skill ? 'skill_view' : label,
          _detail,
        );

  /// The command in full for the live row («uname -a»), masked; null for a
  /// step that is not a command or whose command is not safe to show.
  String? get commandLine => kind == ActivityStepKind.tool &&
          _commandDetailTool(_detailTool(label)) &&
          _detail != null
      ? maskedCommandLine(_detail)
      : null;

  final DateTime? startedAt;

  /// Duración medida, solo en pasos terminados.
  final Duration? duration;

  /// Texto libre del paso (razonamiento). Mientras el paso sigue abierto, el
  /// panel lo enseña en vivo bajo «Ahora» ([ActivitySnapshot.liveReasoning]).
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
    final started = activityInstant(step['timestamp']);
    final ended = activityInstant(step['completed_at']);
    Duration? duration;
    if (status != ActivityStepStatus.running &&
        started != null &&
        ended != null &&
        ended.isAfter(started)) {
      duration = measuredActivityDuration(ended.difference(started));
    }
    final detail = step['detail'] is String
        ? (step['detail'] as String).trim()
        : null;
    final text = kind == ActivityStepKind.reasoning
        ? step['text']?.toString().trim()
        : null;
    final title = step['title']?.toString().trim();
    return ActivityStep(
      id: step['id']?.toString() ?? 'step-$index',
      kind: kind,
      label: label,
      status: status,
      detail: detail == null || detail.isEmpty ? null : detail,
      startedAt: started,
      duration: duration,
      text: text == null || text.isEmpty ? null : text,
      title: title == null || title.isEmpty ? null : title,
    );
  }
}

/// Pasos de un trace: el vivo, los terminados y el razonamiento abierto.
typedef ActivitySteps = ({
  ActivityStep? current,
  List<ActivityStep> done,
  String? liveReasoning,
});

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

final _detailControls = RegExp(r'[\x00-\x1f\x7f\u202a-\u202e\u2066-\u2069]');
final _detailIdentifier = RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_.+-]*$');
final _detailShellSyntax = RegExp(r'(^|\s)-{1,2}\S|[;|`$<>]');

String _detailTool(String tool) =>
    canonicalToolName(tool.trim().toLowerCase().replaceAll('-', '_'));

bool _commandDetailTool(String name) => const {
  'terminal',
  'bash',
  'shell',
  'exec_command',
  'execute_code',
}.any((tool) => name == tool || name.startsWith('${tool}_'));

bool _fileDetailTool(String name) => const {
  'read_file',
  'open_file',
  'edit_file',
  'write_file',
  'patch',
  'apply_patch',
}.any((tool) => name == tool || name.startsWith('${tool}_'));

String? _detailHost(String value) {
  final uri = Uri.tryParse(value);
  final host = uri?.host ?? '';
  return host.isEmpty || _secretLike.hasMatch(host) ? null : _cap(host);
}

String? _detailFile(String value) {
  // Never turn a signed URL into a filename containing its query string.
  if (value.contains('://') || value.contains('?') || value.contains('&')) {
    return _detailHost(value);
  }
  final name = _basename(value);
  if (name.isEmpty ||
      _secretLike.hasMatch(name) ||
      _detailShellSyntax.hasMatch(name) ||
      name.contains('=') ||
      name.startsWith('-')) {
    return null;
  }
  return _cap(name);
}

/// Catalogue IDs may be category/name; each segment is still an identifier,
/// never an absolute path, traversal, free text or a secret.
bool _detailSkillId(String value) {
  final segments = value.split('/');
  return segments.length <= 2 &&
      segments.every(_detailIdentifier.hasMatch) &&
      !_secretLike.hasMatch(value);
}

String? _detailExecutable(String value) {
  final projection = safeCommandProjection(value);
  final executable = projection.split(RegExp(r'\s+')).first;
  if (!_detailIdentifier.hasMatch(executable) ||
      _secretLike.hasMatch(executable)) {
    return null;
  }
  return _cap(executable);
}

/// Strings that look like a credential even without a telling name: provider
/// key prefixes, JWTs and long unbroken key-like runs.
final RegExp _credentialShape = RegExp(
  r'(sk-[A-Za-z0-9_\-]{8,}|gh[pousr]_[A-Za-z0-9]{8,}|xox[abprs]-|AKIA[0-9A-Z]{8,}|'
  r'eyJ[A-Za-z0-9_\-]{8,}\.|(?<![A-Za-z0-9/._\-])[A-Za-z0-9_\-]{32,}={0,2}'
  r'(?![A-Za-z0-9/._\-]))',
);

/// One display token of a command or a goal, with what must not be shown
/// masked: userinfo and query strings of URLs and `NAME=value` assignments.
String? _maskDisplayToken(String token) {
  if (token.contains('://')) {
    final uri = Uri.tryParse(token);
    if (uri == null || uri.userInfo.isNotEmpty) return null;
    if (uri.hasQuery || uri.hasFragment) {
      final bare = uri.replace(query: '', fragment: '').toString();
      final cut = bare.indexOf('?');
      return '${cut < 0 ? bare : bare.substring(0, cut)}?…';
    }
    return token;
  }
  final assignment = RegExp(r'^([A-Za-z_][A-Za-z0-9_]*)=(.*)$').firstMatch(token);
  if (assignment != null && assignment.group(2)!.isNotEmpty) {
    return '${assignment.group(1)}=•••';
  }
  return token;
}

String? _maskDisplayLine(String line) {
  final out = <String>[];
  for (final token in line.split(RegExp(r'\s+'))) {
    if (token.isEmpty) continue;
    final masked = _maskDisplayToken(token);
    if (masked == null) return null;
    out.add(masked);
  }
  return out.join(' ');
}

/// The command the user can read in the live row, «uname -a» or «ls /tmp».
///
/// Complete (the approved v4 video) but never a secret: the first line only;
/// a command that names a secret anywhere (`token`, `password`, `Bearer`,
/// `API_KEY=…`) or carries a credential-shaped string, a URL with userinfo or
/// anything unreadable shows nothing here and the caller falls back to the
/// executable alone. URL queries and `NAME=value` values are masked. The
/// executable is shown by name, never by absolute path.
String? maskedCommandLine(String raw, {int max = 64}) {
  if (raw.length > 4096) return null;
  final first = raw.split(RegExp(r'[\r\n]')).first.trim();
  if (first.isEmpty || _detailControls.hasMatch(first)) return null;
  if (_secretLike.hasMatch(first) || _credentialShape.hasMatch(first)) {
    return null;
  }
  final tokens = first.split(RegExp(r'\s+'));
  final executable = tokens.first.split(RegExp(r'[/\\]')).last;
  if (!_detailIdentifier.hasMatch(executable) ||
      _secretLike.hasMatch(executable)) {
    return null;
  }
  final rest = _maskDisplayLine(tokens.skip(1).join(' '));
  if (rest == null) return null;
  return _cap(rest.isEmpty ? executable : '$executable $rest', max);
}

/// The one-line description of a delegated task under its name: the public
/// goal's first line, with the same masking; null when it is not safe to show.
String? maskedGoalLine(String? raw, {int max = 72}) {
  if (raw == null || raw.length > 4096) return null;
  final first = raw.split(RegExp(r'[\r\n]')).first.trim();
  if (first.isEmpty || _detailControls.hasMatch(first)) return null;
  if (_secretLike.hasMatch(first) || _credentialShape.hasMatch(first)) {
    return null;
  }
  final masked = _maskDisplayLine(first);
  return masked == null || masked.isEmpty ? null : _cap(masked, max);
}

/// Revalidate even an allegedly projected snapshot detail at the client
/// boundary. Only executables, filenames, hosts and catalogue skill IDs survive.
/// Queries/patterns are not display-safe targets, including old stored traces.
String? sanitizeActivityDetail(String tool, Object? raw) {
  if (raw is! String || raw.length > 4096 || _detailControls.hasMatch(raw)) {
    return null;
  }
  final value = raw.trim();
  if (value.isEmpty) return null;
  final name = _detailTool(tool);
  if (_commandDetailTool(name)) return _detailExecutable(value);
  if (value.contains('://') || value.contains('?') || value.contains('&')) {
    return _detailHost(value);
  }
  if (isSkillLoadTool(name)) {
    final parts = value.split(' → ');
    if (parts.length > 2 || !_detailSkillId(parts.first)) {
      return null;
    }
    final file = parts.length == 2 ? _detailFile(parts.last) : null;
    return _cap(file == null ? parts.first : '${parts.first} → $file');
  }
  if (_fileDetailTool(name)) return _detailFile(value);
  if (name.contains('search') || name == 'grep' || name == 'glob') return null;
  if (const {
        'web_extract',
        'web_fetch',
        'web_read',
        'browser_navigate',
      }.contains(name) &&
      _detailIdentifier.hasMatch(value) &&
      !_secretLike.hasMatch(value)) {
    return _cap(value);
  }
  // Unknown tools may carry a path or a host, never arbitrary free text.
  if (value.contains('/') || value.contains(r'\')) return _detailFile(value);
  if (_detailIdentifier.hasMatch(value) &&
      value.contains('.') &&
      !_secretLike.hasMatch(value)) {
    return _cap(value);
  }
  return null;
}

/// Project arguments to an executable, filename or host. Never return queries,
/// patterns, command flags, URL paths, userinfo or signed query strings.
String? activityToolDetail(String tool, Object? args) {
  if (args is! Map) return null;
  String? text(String key) {
    final value = args[key];
    if (value is! String ||
        value.length > 4096 ||
        _detailControls.hasMatch(value)) {
      return null;
    }
    return value.trim().isEmpty ? null : value.trim();
  }

  if (isSkillLoadTool(_detailTool(tool))) {
    final name = text('name');
    if (name != null && _detailSkillId(name)) {
      final file = text('file_path');
      final projected = file == null ? null : _detailFile(file);
      return _cap(projected == null ? name : '$name → $projected');
    }
  }
  for (final key in const ['command', 'cmd', 'script']) {
    final command = text(key);
    if (command != null) {
      return maskedCommandLine(command) ?? _detailExecutable(command);
    }
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
    if (path != null) return _detailFile(path);
  }
  final url = text('url');
  return url == null ? null : _detailHost(url);
}

// ─────────────────────────────────────────────────────────────────────────────
// mp1215 · Escrituras de memoria que aterrizaron
// ─────────────────────────────────────────────────────────────────────────────

/// The tools that write the agent's persistent memory (or user profile), by
/// canonical name (lowercase, words joined by `_`). The ONE place to extend
/// when another memory tool shows up: `memory` is Hermes' own; `omh_remember`
/// is the OMH plugin's save/recall tool (shown as «Omh Remember»).
const Set<String> memoryToolNames = {'memory', 'omh_remember'};

/// The OMH plugin's save/recall tool, which answers with `status` rather
/// than `success`.
const String omhRememberTool = 'omh_remember';

final RegExp _toolNameBreaks = RegExp(r'[\s\-.]+');

/// `Omh Remember`, `omh-remember` and `omh_remember` are the same tool.
String canonicalMemoryToolName(String label) =>
    label.trim().toLowerCase().replaceAll(_toolNameBreaks, '_');

bool isMemoryTool(String label) =>
    memoryToolNames.contains(canonicalMemoryToolName(label));

bool _isOmhRemember(String tool) =>
    canonicalMemoryToolName(tool) == omhRememberTool;

/// OMH `status` values that mean the record is now stored. `pending_review`
/// (queued), `refused` and `error` are NOT stored.
const Set<String> _omhLandedStatuses = {
  'remembered',
  'corrected',
  'already_remembered',
};

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
    this.rejected = false,
  });

  final MemoryWriteAction action;

  /// `target: user` — el perfil del usuario, no las notas del agente.
  final bool userTarget;
  final bool landed;

  /// The result said, in so many words, that nothing was stored (`success:
  /// false`, an OMH `refused`/`error`). Not set while a write is merely
  /// queued for approval, nor when there was no parsable result.
  final bool rejected;

  /// Lo guardado (add/replace) o lo quitado (remove), si viene en los args.
  final String? preview;

  Map<String, dynamic> toStep() => Map<String, dynamic>.unmodifiable({
    'action': action.name,
    'target': userTarget ? 'user' : 'memory',
    'landed': landed,
    if (rejected) 'rejected': true,
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
      rejected: raw['rejected'] == true && raw['landed'] != true,
      preview: _memoryPreview(raw['preview']),
    );
  }

  /// Proyecta los argumentos de una llamada `memory` (op única o lote
  /// `operations`). `null` si no es la herramienta o los args no la describen.
  static MemoryWrite? fromArgs(String tool, Object? args) {
    if (!isMemoryTool(tool)) return null;
    final record = _memoryRecord(args);
    if (record == null) return null;
    if (_isOmhRemember(tool)) {
      // `recall` only reads; a save with `replaces` updates a record.
      final act = (record['action'] ?? 'save').toString().trim().toLowerCase();
      if (act != 'save') return null;
      final replaces = record['replaces'];
      return MemoryWrite(
        action: replaces is String && replaces.trim().isNotEmpty
            ? MemoryWriteAction.replace
            : MemoryWriteAction.add,
        userTarget: false,
        landed: false,
        preview: _memoryPreview(record['summary']),
      );
    }
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
    if (_isOmhResult(record)) {
      // A recall reads; it never earns a write.
      if (record['action'] == 'recall') return call;
      final replaced =
          record['status'] == 'corrected' ||
          (record['replaces'] is String &&
              (record['replaces'] as String).isNotEmpty);
      return MemoryWrite(
        action:
            call?.action ??
            (replaced ? MemoryWriteAction.replace : MemoryWriteAction.add),
        userTarget: false,
        landed: memoryResultLanded(record),
        rejected: _memoryRejected(record),
        preview: call?.preview,
      );
    }
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
      rejected: _memoryRejected(record),
      preview: call?.preview,
    );
  }
}

/// The result is a clear «not stored»: not landed and not just queued.
bool _memoryRejected(Map record) {
  if (memoryResultLanded(record)) return false;
  return !(record['staged'] == true ||
      record['proposal_staged'] == true ||
      record['status'] == 'pending_review');
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

/// An `omh_remember` answer: it carries `status` (and its plugin/schema
/// marks) instead of `success`.
bool _isOmhResult(Map record) =>
    record['plugin_tool'] == omhRememberTool ||
    (record['schema_version'] is String &&
        (record['schema_version'] as String).startsWith('omh_memory_') &&
        !record.containsKey('success'));

/// El resultado de `memory` confirma que la escritura quedó guardada: el
/// gateway devuelve `success: true` y no la dejó en espera de aprobación.
bool memoryResultLanded(Object? result) {
  final record = _memoryRecord(result);
  if (record == null) return false;
  if (_isOmhResult(record)) {
    return record['action'] != 'recall' &&
        _omhLandedStatuses.contains(record['status']);
  }
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
    this.liveReasoning,
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

  /// lr1215: el razonamiento que el modelo está escribiendo AHORA (el paso de
  /// razonamiento abierto del turno), como el desplegable vivo de Desktop.
  final String? liveReasoning;

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

  /// Finished / total subagents of this snapshot, for whoever paints
  /// «n/N agentes». «Finished» includes the ones that failed or were
  /// stopped; the total is [subagentCount] (a number-only roster counts as
  /// 0/N).
  SubagentGroupCount get subagentGroupCount =>
      SubagentGroupCount.of(subagents, genericTotal: subagentGenericCount);

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
          passiveRemote == other.passiveRemote &&
          liveReasoning == other.liveReasoning;

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
    liveReasoning,
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
    liveReasoning: liveReasoning,
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
    liveReasoning: liveReasoning,
  );

  static const ActivitySteps noSteps = (
    current: null,
    done: <ActivityStep>[],
    liveReasoning: null,
  );

  /// Pasos de un trace normalizado: `(current, done)` sin razonamientos ni la
  /// herramienta de tareas (que ya tiene su propia sección), y el texto del
  /// razonamiento abierto en [ActivitySteps.liveReasoning].
  static ActivitySteps splitSteps(Iterable<Map<String, dynamic>> trace) {
    final steps = <ActivityStep>[];
    String? liveReasoning;
    var index = 0;
    for (final raw in trace) {
      final step = ActivityStep.fromTrace(raw, index: index++);
      if (step == null) continue;
      if (step.kind == ActivityStepKind.reasoning) {
        if (step.isRunning && step.text != null) liveReasoning = step.text;
        continue;
      }
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
    return (current: current, done: done, liveReasoning: liveReasoning);
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
        left.text == right.text &&
        left.title == right.title;

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
        step.title,
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
