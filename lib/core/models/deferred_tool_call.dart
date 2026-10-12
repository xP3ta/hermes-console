import 'dart:convert';

/// Name of Hermes' deferred-tool bridge (`tools/tool_search.py
/// TOOL_CALL_NAME`). When tool search is active the model invokes every
/// deferred tool as `tool_call({calls: [{name, arguments}]})`; the transcript
/// keeps the bridge name while the work is the wrapped tool.
const deferredToolBridgeName = 'tool_call';

/// One tool wrapped by a bridge invocation.
typedef DeferredToolCall = ({String name, Object? arguments});

final _unsafeToolNamePattern = RegExp(
  '[\\x00-\\x1f\\x7f'
  '${String.fromCharCode(0x2028)}${String.fromCharCode(0x2029)}'
  '${String.fromCharCode(0x202a)}-${String.fromCharCode(0x202e)}'
  '${String.fromCharCode(0x2066)}-${String.fromCharCode(0x2069)}]',
);

/// Bounded upper limit of wrapped calls considered per bridge invocation.
const maxDeferredToolCalls = 32;

Object? decodeToolArguments(Object? raw) {
  if (raw is! String) return raw;
  final text = raw.trim();
  if (text.isEmpty || text.length > 512000) return null;
  try {
    return jsonDecode(text);
  } on FormatException {
    return null;
  }
}

bool isDeferredToolBridge(String name) =>
    name.trim().toLowerCase() == deferredToolBridgeName;

/// The tools a bridge invocation wraps, in order, or `null` when [name] is not
/// the bridge or its arguments cannot be read (the caller then keeps the
/// original call). Accepts both `{calls: [...]}` and the single-call form
/// `{name, arguments}`, like `normalize_tool_call_entries` upstream.
List<DeferredToolCall>? unwrapDeferredToolCall(
  String name,
  Object? rawArguments,
) {
  if (!isDeferredToolBridge(name)) return null;
  final arguments = decodeToolArguments(rawArguments);
  if (arguments is! Map) return null;
  final calls = arguments['calls'];
  final candidates = calls is List ? calls : [arguments];
  final entries = <DeferredToolCall>[];
  for (final candidate in candidates.take(maxDeferredToolCalls)) {
    if (candidate is! Map) continue;
    final inner = candidate['name']?.toString().trim() ?? '';
    if (inner.isEmpty ||
        inner.length > 180 ||
        inner.contains(_unsafeToolNamePattern) ||
        isDeferredToolBridge(inner)) {
      continue;
    }
    entries.add((
      name: inner,
      arguments: decodeToolArguments(candidate['arguments']),
    ));
  }
  return entries.isEmpty ? null : List.unmodifiable(entries);
}
