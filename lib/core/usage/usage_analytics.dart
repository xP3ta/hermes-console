// Usage analytics of the server (read only): the answer of
// `GET /api/analytics/usage?days=N[&profile=P]`.
//
// One call is enough: besides the totals and the days it carries `by_model`
// (auxiliary models included), so `/api/analytics/models`, which only adds
// model capabilities, is not read. Every figure can be null on the wire (a
// SUM over no rows), so each one is read as an optional number.
import '../services/connection_manager.dart';

/// The periods the screen offers; the server accepts 1 to 365.
const List<int> kUsagePeriods = [7, 30, 90];

class UsageTotals {
  const UsageTotals({
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.sessions = 0,
    this.apiCalls = 0,
    this.estimatedCost = 0,
    this.actualCost = 0,
  });

  final int inputTokens;
  final int outputTokens;
  final int sessions;
  final int apiCalls;
  final double estimatedCost;
  final double actualCost;

  int get tokens => inputTokens + outputTokens;

  /// The server's cost when it knows it, else its estimate; zero when it
  /// gives none (the screen then shows no cost at all).
  double get cost => actualCost > 0 ? actualCost : estimatedCost;
  bool get costIsEstimate => actualCost <= 0 && estimatedCost > 0;
}

class UsageModelRow {
  const UsageModelRow({
    required this.model,
    required this.inputTokens,
    required this.outputTokens,
    required this.sessions,
    required this.estimatedCost,
  });

  final String model;
  final int inputTokens;
  final int outputTokens;
  final int sessions;
  final double estimatedCost;

  int get tokens => inputTokens + outputTokens;
}

class UsageDay {
  const UsageDay({required this.day, required this.tokens});

  /// `YYYY-MM-DD`, as the server groups them.
  final String day;
  final int tokens;
}

class UsageAnalytics {
  const UsageAnalytics({
    required this.periodDays,
    required this.totals,
    required this.models,
    required this.days,
  });

  final int periodDays;
  final UsageTotals totals;
  final List<UsageModelRow> models;
  final List<UsageDay> days;

  /// Nothing happened in the period: no tokens, no sessions.
  bool get isEmpty => totals.tokens == 0 && totals.sessions == 0;
}

int _int(Object? value) => value is num ? value.round() : 0;
double _double(Object? value) => value is num ? value.toDouble() : 0;

/// Reads the answer defensively: a missing or mistyped part is zero or empty,
/// never an exception.
UsageAnalytics parseUsageAnalytics(
  Map<String, dynamic> json, {
  int fallbackDays = 30,
}) {
  final rawTotals = json['totals'];
  final t = rawTotals is Map ? rawTotals : const <String, dynamic>{};
  final models = <UsageModelRow>[];
  final rawModels = json['by_model'];
  if (rawModels is List) {
    for (final row in rawModels) {
      if (row is! Map) continue;
      final name = row['model'];
      models.add(
        UsageModelRow(
          model: name is String && name.isNotEmpty ? name : 'unknown',
          inputTokens: _int(row['input_tokens']),
          outputTokens: _int(row['output_tokens']),
          sessions: _int(row['sessions']),
          estimatedCost: _double(row['estimated_cost']),
        ),
      );
    }
  }
  final days = <UsageDay>[];
  final rawDaily = json['daily'];
  if (rawDaily is List) {
    for (final row in rawDaily) {
      if (row is! Map) continue;
      final day = row['day'];
      if (day is! String) continue;
      days.add(
        UsageDay(
          day: day,
          tokens: _int(row['input_tokens']) + _int(row['output_tokens']),
        ),
      );
    }
  }
  final period = json['period_days'];
  return UsageAnalytics(
    periodDays: period is int && period > 0 ? period : fallbackDays,
    totals: UsageTotals(
      inputTokens: _int(t['total_input']),
      outputTokens: _int(t['total_output']),
      sessions: _int(t['total_sessions']),
      apiCalls: _int(t['total_api_calls']),
      estimatedCost: _double(t['total_estimated_cost']),
      actualCost: _double(t['total_actual_cost']),
    ),
    models: models,
    days: days,
  );
}

/// Reads the usage of [profile] over [days] days. Without a [profile] the
/// server answers for its own default.
Future<UsageAnalytics> fetchUsageAnalytics(
  DashboardClient client, {
  required int days,
  String? profile,
}) async {
  final scoped = profile?.trim() ?? '';
  final query = StringBuffer('days=$days');
  if (scoped.isNotEmpty && scoped != 'default') {
    query.write('&profile=${Uri.encodeQueryComponent(scoped)}');
  }
  final json = await client.apiGet('analytics/usage?$query');
  return parseUsageAnalytics(json, fallbackDays: days);
}

/// 1234 → "1.2k", 3 400 000 → "3.4M"; small numbers as they are.
String formatCompactCount(int value) {
  String scaled(double v, String suffix) {
    var text = v >= 100 ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
    if (text.endsWith('.0')) text = text.substring(0, text.length - 2);
    return '$text$suffix';
  }

  if (value >= 1000000000) return scaled(value / 1000000000, 'B');
  if (value >= 1000000) return scaled(value / 1000000, 'M');
  if (value >= 1000) return scaled(value / 1000, 'k');
  return '$value';
}

/// A cost in US dollars: cents for amounts of a cent or more, four decimals
/// below that so a small spend does not read as zero.
String formatUsageCost(double value) => value >= 0.01
    ? '\$${value.toStringAsFixed(2)}'
    : '\$${value.toStringAsFixed(4)}';
