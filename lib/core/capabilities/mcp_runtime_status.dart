// Live state of each configured MCP server, from the gateway's
// `mcp.servers.status` (cached runtime view: it never connects or probes).

enum McpRuntimeStatus {
  connected,
  disabled,
  connecting,
  failed,
  lazy,
  configured;

  /// Unknown wire values read as [configured]: nothing is claimed about them.
  static McpRuntimeStatus parse(Object? value) {
    for (final status in values) {
      if (status.name == value) return status;
    }
    return configured;
  }
}

final class McpRuntimeRow {
  final String name;
  final McpRuntimeStatus status;
  final int tools;

  const McpRuntimeRow({
    required this.name,
    required this.status,
    this.tools = 0,
  });

  static McpRuntimeRow? tryParse(Object? json) {
    if (json is! Map) return null;
    final name = json['name'];
    if (name is! String || name.trim().isEmpty) return null;
    final tools = json['tools'];
    return McpRuntimeRow(
      name: name.trim(),
      status: McpRuntimeStatus.parse(json['status']),
      tools: tools is int && tools > 0 ? tools : 0,
    );
  }
}
