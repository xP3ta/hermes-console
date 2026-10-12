/// Prefix Hermes puts on every tool name it sends to Anthropic over OAuth
/// (`agent/anthropic_adapter.py _MCP_TOOL_PREFIX`). The gateway turns it back
/// into the registered name before a tool runs, so `tool.start`,
/// `tool.complete` and the transcript carry `terminal`; `tool.generating`,
/// emitted while the model is still writing the call, carries the wire name
/// `mcp__terminal`.
const _oauthWirePrefix = 'mcp__';

/// Tools Hermes renames on that wire (`_OAUTH_TOOL_NAME_ALIASES`), wire name
/// to registered name.
const _oauthWireAliases = <String, String>{
  'chat_history_lookup': 'session_search',
  'context_notes': 'memory',
};

const _connectorPrefix = 'connectors__';

/// The registered name of a tool, whichever way the gateway announced it.
///
/// Every surface that names a running tool reads the result, so the tool is
/// called the same while its call is being written, while it runs and once
/// it is done. A native MCP tool is registered as `mcp__<server>__<tool>` and
/// keeps its name; `mcp__<tool>` is a built-in tool on the OAuth wire
/// (`tools/tool_labels.py label_for_tool_name` draws the same line).
String canonicalToolName(String raw) {
  final name = raw.trim();
  if (!name.startsWith(_oauthWirePrefix)) return name;
  final bare = name.substring(_oauthWirePrefix.length);
  if (bare.isEmpty) return name;
  if (bare.startsWith(_connectorPrefix)) return bare;
  final separator = bare.indexOf('__');
  if (separator > 0 && separator + 2 < bare.length) return name;
  return _oauthWireAliases[bare] ?? bare;
}
