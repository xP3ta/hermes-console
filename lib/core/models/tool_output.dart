/// Displayable output of a finished tool call — a file edit's diff or a
/// terminal's captured output — keyed by the gateway's stable tool id.
///
/// Sources (Desktop parity, `lib/chat-messages/tool-parts.ts`):
/// - live `tool.complete` (`inline_diff`, parsed `result`), recorded by the
///   chat's [ToolOutputLedger];
/// - durable tool rows (`tool_call_id`, raw `content`), where `patch`
///   results still carry their own `diff`.
/// Nothing is fetched: a record only exists when the server sent the data.
library;

import 'dart:collection';
import 'dart:convert';

import '../utils/ansi_text.dart';
import '../utils/unified_diff.dart';

/// Desktop `tool-render-class.ts` `FILE_EDIT_TOOL_NAMES`.
const Set<String> fileEditToolNames = {'edit_file', 'patch', 'write_file'};

/// Desktop `fallback-model` `rendersAnsi`.
const Set<String> terminalOutputToolNames = {'terminal', 'execute_code'};

bool isFileEditToolName(String name) => fileEditToolNames.contains(name);

const int _maxDiffChars = 200 * 1024;
const int _maxOutputChars = 64 * 1024;

final class ToolOutputRecord {
  final String toolId;
  final String name;

  /// Per-file diffs of a landed edit (empty when the server sent none).
  final List<FileDiff> files;

  /// Terminal/execute_code output, ANSI SGR kept for colouring.
  final String? output;
  final int? exitCode;

  const ToolOutputRecord({
    required this.toolId,
    required this.name,
    this.files = const [],
    this.output,
    this.exitCode,
  });

  bool get hasDiff => files.isNotEmpty;
  bool get hasOutput => output != null && output!.trim().isNotEmpty;

  /// Live `tool.complete` payload.
  static ToolOutputRecord? fromCompletePayload(Map<String, dynamic> payload) {
    final id = _string(payload['tool_id']);
    final name = _string(payload['name']);
    if (id == null || name == null) return null;
    if (payload['error'] != null || payload['status'] == 'error') {
      return null;
    }
    final args = _map(payload['args']);
    final result = _decode(payload['result']);
    return _build(
      id: id,
      name: name,
      args: args,
      result: result,
      inlineDiff: _string(payload['inline_diff']),
    );
  }

  /// Durable tool row (`role: tool`) coalesced under an assistant turn.
  static ToolOutputRecord? fromToolRow(Map<String, dynamic> row) {
    final id = _string(row['tool_call_id']);
    final name = _string(row['tool_name']) ?? _string(row['name']);
    if (id == null || name == null) return null;
    return _build(
      id: id,
      name: name,
      args: const {},
      result: _decode(row['content']),
      inlineDiff: _storedInlineDiff(row['display_metadata']),
    );
  }

  static ToolOutputRecord? _build({
    required String id,
    required String name,
    required Map<String, dynamic> args,
    required Object? result,
    String? inlineDiff,
  }) {
    final record = result is Map<String, dynamic> ? result : const {};
    if (isFileEditToolName(name)) {
      if (record['success'] == false || record['error'] is String) return null;
      final raw =
          inlineDiff ??
          _string(record['inline_diff']) ??
          _string(record['diff']);
      if (raw == null || raw.length > _maxDiffChars) return null;
      final cleaned = cleanInlineDiff(raw);
      if (cleaned.isEmpty) return null;
      final path =
          _string(args['path']) ??
          _string(args['file']) ??
          _string(args['filepath']) ??
          _string(record['path']) ??
          _string(record['resolved_path']) ??
          '';
      final files = splitFileDiffs(cleaned, fallbackPath: path)
          .where((f) => !f.stats.isEmpty || f.diff.trim().isNotEmpty)
          .toList(growable: false);
      if (files.isEmpty) return null;
      return ToolOutputRecord(toolId: id, name: name, files: files);
    }
    if (terminalOutputToolNames.contains(name)) {
      String? output;
      int? exit;
      if (record.isNotEmpty) {
        final parts = [
          _string(record['output']) ?? _string(record['stdout']),
          _string(record['stderr']),
        ].whereType<String>().where((p) => p.trim().isNotEmpty);
        output = parts.isEmpty ? null : parts.join('\n');
        final code = record['exit_code'] ?? record['returncode'];
        exit = code is int ? code : (code is num ? code.toInt() : null);
      } else if (result is String && result.trim().isNotEmpty) {
        output = result;
      }
      if (output == null || output.trim().isEmpty) return null;
      if (output.length > _maxOutputChars) {
        output = output.substring(output.length - _maxOutputChars);
      }
      return ToolOutputRecord(
        toolId: id,
        name: name,
        output: sanitizeAnsiForRender(output).trimRight(),
        exitCode: exit,
      );
    }
    return null;
  }
}

/// Bounded per-chat store of live tool outputs (newest wins, oldest evicted).
final class ToolOutputLedger {
  ToolOutputLedger({this.capacity = 256});

  final int capacity;
  final LinkedHashMap<String, ToolOutputRecord> _records = LinkedHashMap();
  int _revision = 0;

  int get revision => _revision;

  ToolOutputRecord? operator [](String id) => _records[id];

  void recordComplete(Map<String, dynamic> payload) {
    final record = ToolOutputRecord.fromCompletePayload(payload);
    if (record == null) return;
    put(record);
  }

  void put(ToolOutputRecord record) {
    _records.remove(record.toolId);
    _records[record.toolId] = record;
    while (_records.length > capacity) {
      _records.remove(_records.keys.first);
    }
    _revision++;
  }

  void clear() {
    if (_records.isEmpty) return;
    _records.clear();
    _revision++;
  }
}

/// Index of durable tool outputs from internal transcript rows (assistant
/// rows carry their coalesced results under [toolResultsKey]).
Map<String, ToolOutputRecord> indexDurableToolOutputs(
  Iterable<Map<String, dynamic>> rows, {
  required String toolResultsKey,
}) {
  final index = <String, ToolOutputRecord>{};
  void absorb(Object? raw) {
    if (raw is! Map) return;
    final row = Map<String, dynamic>.from(raw);
    final name = _string(row['tool_name']) ?? _string(row['name']) ?? '';
    if (!isFileEditToolName(name) && !terminalOutputToolNames.contains(name)) {
      return;
    }
    final record = ToolOutputRecord.fromToolRow(row);
    if (record != null) index[record.toolId] = record;
  }

  for (final row in rows) {
    final role = row['role'];
    if (role == 'tool') {
      absorb(row);
    } else if (role == 'assistant') {
      final results = row[toolResultsKey];
      if (results is List) results.forEach(absorb);
    }
  }
  return index;
}

String? _string(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : value;
}

Map<String, dynamic> _map(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  if (value is String && value.trimLeft().startsWith('{')) {
    final decoded = _decode(value);
    if (decoded is Map<String, dynamic>) return decoded;
  }
  return const {};
}

Object? _decode(Object? value) {
  if (value is Map) return Map<String, dynamic>.from(value);
  if (value is! String) return value;
  final trimmed = value.trimLeft();
  if (!trimmed.startsWith('{')) return value;
  try {
    final decoded = jsonDecode(trimmed);
    return decoded is Map ? Map<String, dynamic>.from(decoded) : value;
  } catch (_) {
    // A result with trailing text (`{…}\n\n[Tool loop warning…]`) or
    // truncated JSON is still plain output.
    return value;
  }
}

String? _storedInlineDiff(Object? displayMetadata) {
  final display = _map(displayMetadata);
  final metadata = _map(display['tool_result_metadata']);
  return _string(metadata['inline_diff']);
}
