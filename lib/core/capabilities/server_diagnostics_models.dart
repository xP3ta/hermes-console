// Models of the read-only server diagnostics: the output of doctor and the
// security audit, the live MCP status, usage analytics and the health reads.
library;

/// The two long-running text commands the Dashboard spawns as background
/// actions (`POST /api/ops/<endpoint>`, tailed through
/// `GET /api/actions/<name>/status`). Neither mutates the server: doctor runs
/// without `--fix`.
enum OpsAction {
  doctor('doctor', 'ops/doctor'),
  securityAudit('security-audit', 'ops/security-audit');

  /// Action name (`name` of the status and of the log marker).
  final String actionName;
  final String endpoint;

  const OpsAction(this.actionName, this.endpoint);
}

/// The log is cumulative: each run begins with
/// `=== <name> started <time> ===`. Returns the lines after the last marker,
/// or all of them when the window holds none.
List<String> opsActionOutput(String actionName, List<String> lines) {
  final marker = '=== $actionName started';
  for (var i = lines.length - 1; i >= 0; i--) {
    if (lines[i].startsWith(marker)) return lines.sublist(i + 1);
  }
  return List<String>.of(lines);
}

enum McpServerState {
  connected,
  disabled,
  connecting,
  failed,
  lazy,
  configured,
  unknown,
}

enum McpServerSource { plugin, config }

/// One row of `mcp.servers.status`, read from the server's cached runtime
/// state (it never connects, probes or starts auth).
final class McpServerStatus {
  final String name;
  final String transport;

  /// Number of tools (an integer on the wire).
  final int tools;
  final McpServerState state;
  final McpServerSource? source;
  final String? plugin;

  const McpServerStatus({
    required this.name,
    required this.transport,
    required this.tools,
    required this.state,
    this.source,
    this.plugin,
  });

  static McpServerStatus? tryParse(Map<String, dynamic> json) {
    final name = _bounded(json['name'], 128);
    if (name.isEmpty) return null;
    final tools = json['tools'];
    final plugin = _bounded(json['plugin'], 128);
    return McpServerStatus(
      name: name,
      transport: _bounded(json['transport'], 32),
      tools: tools is int && tools >= 0 ? tools : 0,
      state: switch (json['status']) {
        'connected' => McpServerState.connected,
        'disabled' => McpServerState.disabled,
        'connecting' => McpServerState.connecting,
        'failed' => McpServerState.failed,
        'lazy' => McpServerState.lazy,
        'configured' => McpServerState.configured,
        _ => McpServerState.unknown,
      },
      source: switch (json['source']) {
        'plugin' => McpServerSource.plugin,
        'config' => McpServerSource.config,
        _ => null,
      },
      plugin: plugin.isEmpty ? null : plugin,
    );
  }
}

String _bounded(Object? value, int max) {
  if (value is! String) return '';
  final text = value.trim();
  return text.length <= max ? text : text.substring(0, max);
}

int _count(Object? value) =>
    value is num && value.isFinite && value >= 0 ? value.round() : 0;

double _money(Object? value) =>
    value is num && value.isFinite && value >= 0 ? value.toDouble() : 0;

/// Totals of a period. `SUM`s arrive as `null` on an empty period: zero.
final class UsageTotals {
  final int input;
  final int output;
  final int cacheRead;
  final int reasoning;
  final double estimatedCost;
  final double actualCost;
  final int sessions;
  final int apiCalls;

  const UsageTotals({
    this.input = 0,
    this.output = 0,
    this.cacheRead = 0,
    this.reasoning = 0,
    this.estimatedCost = 0,
    this.actualCost = 0,
    this.sessions = 0,
    this.apiCalls = 0,
  });

  factory UsageTotals.fromJson(Object? json) {
    final map = json is Map ? json : const {};
    return UsageTotals(
      input: _count(map['total_input']),
      output: _count(map['total_output']),
      cacheRead: _count(map['total_cache_read']),
      reasoning: _count(map['total_reasoning']),
      estimatedCost: _money(map['total_estimated_cost']),
      actualCost: _money(map['total_actual_cost']),
      sessions: _count(map['total_sessions']),
      apiCalls: _count(map['total_api_calls']),
    );
  }
}

final class UsageDay {
  final String day;
  final int input;
  final int output;
  final int cacheRead;
  final int reasoning;
  final double estimatedCost;
  final double actualCost;
  final int sessions;
  final int apiCalls;

  const UsageDay({
    required this.day,
    required this.input,
    required this.output,
    required this.cacheRead,
    required this.reasoning,
    required this.estimatedCost,
    required this.actualCost,
    required this.sessions,
    required this.apiCalls,
  });

  static UsageDay? tryParse(Map<dynamic, dynamic> json) {
    final day = json['day'];
    if (day is! String || day.trim().isEmpty) return null;
    return UsageDay(
      day: day.trim(),
      input: _count(json['input_tokens']),
      output: _count(json['output_tokens']),
      cacheRead: _count(json['cache_read_tokens']),
      reasoning: _count(json['reasoning_tokens']),
      estimatedCost: _money(json['estimated_cost']),
      actualCost: _money(json['actual_cost']),
      sessions: _count(json['sessions']),
      apiCalls: _count(json['api_calls']),
    );
  }
}

final class UsageModel {
  final String model;
  final int input;
  final int output;
  final double estimatedCost;
  final int sessions;
  final int apiCalls;

  const UsageModel({
    required this.model,
    required this.input,
    required this.output,
    required this.estimatedCost,
    required this.sessions,
    required this.apiCalls,
  });

  static UsageModel? tryParse(Map<dynamic, dynamic> json) {
    final model = json['model'];
    if (model is! String || model.trim().isEmpty) return null;
    return UsageModel(
      model: model.trim(),
      input: _count(json['input_tokens']),
      output: _count(json['output_tokens']),
      estimatedCost: _money(json['estimated_cost']),
      sessions: _count(json['sessions']),
      apiCalls: _count(json['api_calls']),
    );
  }
}

/// `GET /api/analytics/usage?days=`.
final class UsageAnalytics {
  /// The periods the UI offers.
  static const presets = [7, 30, 90];

  final int days;
  final UsageTotals totals;
  final List<UsageDay> daily;
  final List<UsageModel> byModel;

  const UsageAnalytics({
    required this.days,
    required this.totals,
    required this.daily,
    required this.byModel,
  });

  factory UsageAnalytics.fromJson(
    Map<String, dynamic> json, {
    required int days,
  }) {
    List<T> rows<T>(Object? value, T? Function(Map<dynamic, dynamic>) parse) =>
        value is List
        ? [
            for (final row in value)
              if (row is Map) ?parse(row),
          ]
        : <T>[];
    return UsageAnalytics(
      days: json['period_days'] is int ? json['period_days'] as int : days,
      totals: UsageTotals.fromJson(json['totals']),
      daily: rows(json['daily'], UsageDay.tryParse),
      byModel: rows(json['by_model'], UsageModel.tryParse),
    );
  }
}

/// `GET /api/health` (no token).
final class ServerHealth {
  final String version;
  final String displayVersion;

  const ServerHealth({required this.version, required this.displayVersion});

  factory ServerHealth.fromJson(Map<String, dynamic> json) {
    String text(Object? value) => value is String ? value.trim() : '';
    final version = text(json['version']);
    final display = text(json['displayVersion']);
    return ServerHealth(
      version: version,
      displayVersion: display.isEmpty ? version : display,
    );
  }
}

/// `GET /api/health/idle`: busy or free, never a retirement permit.
final class ServerIdle {
  /// True free, false busy, null unknown.
  final bool? idle;

  /// `turn_in_flight`, `awaiting_human_input`, `*_probe_unavailable`.
  final String? reason;

  const ServerIdle({this.idle, this.reason});

  factory ServerIdle.fromJson(Map<String, dynamic> json) {
    final reason = json['reason'];
    return ServerIdle(
      idle: json['idle'] is bool ? json['idle'] as bool : null,
      reason: reason is String && reason.trim().isNotEmpty
          ? reason.trim()
          : null,
    );
  }
}
