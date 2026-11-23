import 'dart:convert';

/// Whether a finished tool call failed, read from its result.
///
/// The gateway's `tool.complete` carries no error flag: a failure lives inside
/// `result` (`tui_gateway/tool_progress.py`). This is Hermes Desktop's
/// `toolCallFailed` (`apps/desktop/src/components/assistant-ui/tool/
/// fallback-model/format.ts`) with its `extractToolErrorMessage`
/// (`apps/desktop/src/lib/tool-result-summary.ts`), plus the terminal rule both
/// Desktop (`failedCallNeedsUser`) and the agent (`agent/display.py::
/// _detect_tool_failure`) apply: a non-zero exit code is a failure.
///
/// [isError] is an explicit flag from the envelope, when there is one.
bool toolCallFailed({
  required String? toolName,
  required Object? result,
  bool isError = false,
}) {
  final record = _record(result);
  if (toolName == 'terminal') {
    final exit = record['exit_code'];
    if (exit is num && exit != 0) return true;
  }
  if (_isNeutralFailure(toolName, result, record)) return false;
  if (record['success'] == true || record['ok'] == true) return false;
  return isError ||
      record['success'] == false ||
      record['ok'] == false ||
      _nestedError(result, 0, <Object>{}, false);
}

const _errorKeys = ['error', 'errors', 'failure', 'exception'];
const _errorMessageKeys = ['message', 'reason', 'detail'];
const _wrapperKeys = ['data', 'result', 'output', 'response', 'payload'];
const _nonErrorText = {
  '',
  '0',
  'false',
  'none',
  'null',
  'nil',
  'ok',
  'success',
  'n/a',
  'na',
};
final _failedStatus = RegExp(
  r'^(error|failed|failure|fatal|exception)$',
  caseSensitive: false,
);
final _jsonStart = RegExp(r'^[{\["]');

/// A refused `skill_manage` call is the agent's own retry loop, unless its
/// rollback failed (Desktop's `isNeutralFailure`).
bool _isNeutralFailure(
  String? toolName,
  Object? result,
  Map<String, Object?> record,
) {
  if (toolName != 'skill_manage') return false;
  final error = record['error'] ?? (result is String ? result : '');
  return !error.toString().contains('ROLLBACK FAILED');
}

Map<String, Object?> _record(Object? value) {
  if (value is Map) return value.cast<String, Object?>();
  if (value is! String || value.trim().isEmpty) return const {};
  try {
    final parsed = jsonDecode(value);
    return parsed is Map ? parsed.cast<String, Object?>() : const {};
  } catch (_) {
    return const {};
  }
}

Object? _norm(Object? value) {
  if (value is! String) return value;
  final text = value.trim();
  if (text.isEmpty) return '';
  if (!_jsonStart.hasMatch(text)) return value;
  try {
    return jsonDecode(text);
  } catch (_) {
    return value;
  }
}

bool _meaningful(Object? value) {
  final v = _norm(value);
  return switch (v) {
    null => false,
    final String s => !_nonErrorText.contains(s.trim().toLowerCase()),
    final bool b => b,
    final num n => n != 0,
    final List<Object?> l => l.any(_meaningful),
    final Map<Object?, Object?> m => m.isNotEmpty,
    _ => true,
  };
}

bool _hasErrorSignal(Map<Object?, Object?> record) {
  final status = record['status'];
  return record['success'] == false ||
      record['ok'] == false ||
      (status is String && _failedStatus.hasMatch(status.trim())) ||
      _errorKeys.any((key) => _meaningful(record[key]));
}

bool _firstString(Map<Object?, Object?> record, List<String> keys) => keys.any(
  (key) => record[key] is String && (record[key]! as String).trim().isNotEmpty,
);

/// Whether an error value has text to show (Desktop's `valueErrorText`).
bool _errorText(Object? value) {
  final v = _norm(value);
  return switch (v) {
    final String s => _meaningful(s) && s.trim().isNotEmpty,
    final List<Object?> l => l.any(_errorText),
    final Map<Object?, Object?> m => _firstString(m, _errorMessageKeys),
    _ => false,
  };
}

bool _nestedError(Object? value, int depth, Set<Object> seen, bool failed) {
  if (depth > 5) return false;
  final v = _norm(value);
  if (v is! Map && v is! List) return false;
  if (!seen.add(v!)) return false;
  if (v is List) {
    return v.any((item) => _nestedError(item, depth + 1, seen, failed));
  }
  final record = v as Map<Object?, Object?>;
  if (record['success'] == true || record['ok'] == true) return false;
  for (final key in _errorKeys) {
    if (_meaningful(record[key]) && _errorText(record[key])) return true;
  }
  final signal = _hasErrorSignal(record);
  if (signal && _firstString(record, _errorMessageKeys)) return true;
  // Returned data and stdout can describe failures without the tool failing:
  // they are unwrapped only to explain a failure the envelope declared.
  final declared = failed || signal;
  final nested = declared
      ? [..._errorKeys, ..._wrapperKeys, 'details']
      : _errorKeys;
  return nested.any(
    (key) => _nestedError(record[key], depth + 1, seen, declared),
  );
}
