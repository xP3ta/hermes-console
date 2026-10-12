import 'package:flutter/foundation.dart';

import '../widgets/chat_status_pill.dart' show SubscriptionLimitLevel;
import '../usage/provider_value_validation.dart';

/// Where a rendered limit line came from in `session.usage`.
enum AccountLimitSource {
  /// `account_lines`: provider account limits (Codex / Claude quota windows).
  account,

  /// `credits_lines`: Nous credits.
  credits,
}

/// One line Hermes rendered for `/usage` (agent/account_usage.py), shown as
/// is. [usedPercent] is set only when the line states it unambiguously.
@immutable
class AccountLimitLine {
  const AccountLimitLine({
    required this.text,
    required this.source,
    this.heading = false,
    this.usedPercent,
  });

  /// The line as Hermes sent it (heading lines lose the 📈 and `**`).
  final String text;
  final AccountLimitSource source;
  final bool heading;
  final double? usedPercent;

  /// Text before the first ` • ` (the window and its numbers).
  String get primary {
    final at = text.indexOf(_detailSeparator);
    return at < 0 ? text : text.substring(0, at);
  }

  /// Text after the first ` • ` (reset time or detail), if any.
  String? get secondary {
    final at = text.indexOf(_detailSeparator);
    if (at < 0) return null;
    final rest = text.substring(at + _detailSeparator.length).trim();
    return rest.isEmpty ? null : rest;
  }
}

const _detailSeparator = ' • ';

enum AccountUsageBarKind { plan, topup }

/// Whose limits a block of lines is: the `Provider: openai-codex (Plus)`
/// line Hermes renders under each block's title. [provider] is the slug
/// Hermes uses; [plan] is the plan name exactly as the provider reports it
/// (null when it reports none: nothing is guessed).
@immutable
class AccountLimitIdentity {
  const AccountLimitIdentity({required this.provider, this.plan});

  final String provider;
  final String? plan;

  static final _line = RegExp(
    r'^Provider:\s*([A-Za-z0-9][A-Za-z0-9._-]{0,39})(?:\s*\((.{1,60})\))?\s*$',
  );

  /// The identity a `Provider:` line states, or null for any other line
  /// (and for a provider that is not a plain slug).
  static AccountLimitIdentity? fromLine(String line) {
    final match = _line.firstMatch(line.trim());
    if (match == null) return null;
    return AccountLimitIdentity(
      provider: match.group(1)!.toLowerCase(),
      plan: match.group(2)?.trim(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AccountLimitIdentity &&
      other.provider == provider &&
      other.plan == plan;

  @override
  int get hashCode => Object.hash(provider, plan);
}

/// One bar of Hermes' `usage.bars` two-bar dollar view.
@immutable
class AccountUsageBar {
  const AccountUsageBar({
    required this.kind,
    required this.remaining,
    required this.total,
    required this.usedFraction,
    this.pctUsed,
  });

  final AccountUsageBarKind kind;

  /// Pre-formatted by Hermes (`$3.00`).
  final String remaining;
  final String total;

  /// `1 - fill_fraction` (Hermes fills the bar with what is left).
  final double usedFraction;

  /// Only the plan bar carries it.
  final int? pctUsed;
}

/// The limits block of the model sheet: what Hermes Desktop shows for
/// `session.usage` (`account_lines`, `credits_lines`) plus `usage.bars`
/// when Hermes reports it available. Nothing here is estimated.
@immutable
class AccountUsageLimits {
  const AccountUsageLimits({
    this.lines = const [],
    this.bars = const [],
    this.planName,
    this.renews,
    this.accountIdentity,
    this.creditsIdentity,
  });

  final List<AccountLimitLine> lines;
  final List<AccountUsageBar> bars;
  final String? planName;
  final String? renews;

  /// Whose the provider-account windows (`account_lines`) are: the route the
  /// session runs on. Null when Hermes did not say.
  final AccountLimitIdentity? accountIdentity;

  /// Whose the credits (`credits_lines`, or the `usage.bars` bars) are.
  final AccountLimitIdentity? creditsIdentity;

  bool get isEmpty => lines.isEmpty && bars.isEmpty;

  /// Builds the block from a `session.usage` result and, optionally, a
  /// `usage.bars` result. When the structured bars are available they stand
  /// in for the Nous credits lines (same account, same numbers).
  factory AccountUsageLimits.fromGateway(
    Map<String, dynamic> sessionUsage, {
    Map<String, dynamic>? usageBars,
  }) {
    final bars = <AccountUsageBar>[];
    String? planName;
    String? renews;
    if (usageBars != null && usageBars['available'] == true) {
      for (final key in const ['plan_bar', 'topup_bar']) {
        final bar = _bar(usageBars[key]);
        if (bar != null) bars.add(bar);
      }
      final rawName = _text(usageBars['plan_name']);
      planName = rawName == null ? null : scrubProviderText(rawName);
      renews = validatedRenewalDate(usageBars['renews_display']);
    }
    final accountLines = _lines(
      sessionUsage['account_lines'],
      AccountLimitSource.account,
    ).toList();
    final creditsLines = _lines(
      sessionUsage['credits_lines'],
      AccountLimitSource.credits,
    ).toList();
    var creditsIdentity = _identityOf(creditsLines);
    if (bars.isNotEmpty) {
      // The bars are Nous' billing view: the credits' owner is Nous even
      // when the text lines that would say so were left out for them.
      creditsIdentity = AccountLimitIdentity(
        provider: creditsIdentity?.provider ?? 'nous',
        plan: planName ?? creditsIdentity?.plan,
      );
    }
    final lines = <AccountLimitLine>[
      ...accountLines,
      if (bars.isEmpty) ...creditsLines,
    ];
    if (bars.isEmpty) {
      planName = null;
      renews = null;
    }
    return AccountUsageLimits(
      lines: List.unmodifiable(lines),
      bars: List.unmodifiable(bars),
      planName: planName,
      renews: renews,
      accountIdentity: _identityOf(accountLines),
      creditsIdentity: creditsIdentity,
    );
  }

  /// Hint for the status pill: the fullest unambiguous number among the
  /// parsed lines and the plan bar's `pct_used`.
  SubscriptionLimitLevel get level {
    double? fullest;
    void consider(double? value) {
      if (value == null) return;
      if (fullest == null || value > fullest!) fullest = value;
    }

    for (final line in lines) {
      consider(line.usedPercent);
    }
    for (final bar in bars) {
      consider(bar.pctUsed?.toDouble());
    }
    final value = fullest;
    if (value == null) return SubscriptionLimitLevel.none;
    if (value >= 100) return SubscriptionLimitLevel.reached;
    if (value >= 80) return SubscriptionLimitLevel.near;
    return SubscriptionLimitLevel.none;
  }

  static final _percent = RegExp(
    r'(\d+(?:\.\d+)?)\s*%(\s*(?:used|remaining))?',
    caseSensitive: false,
  );
  static final _ratio = RegExp(
    r'(?<![\d./])(\d+(?:\.\d+)?)\s*/\s*(\d+(?:\.\d+)?)(?![\d./])',
  );
  static final _usageWord = RegExp(
    r'\b(used|usage|spent|consumed)\b',
    caseSensitive: false,
  );

  /// Percentage used stated by [line], or null when the line does not say
  /// it unambiguously:
  /// * exactly one `N% used`, and any other percentage is the single
  ///   `M% remaining` with N + M = 100 (±1, Hermes rounds both);
  /// * or, with no percentage at all, exactly one `X / Y` on a line that
  ///   names usage (`Extra usage: 4.20 / 50.00 USD`), Y > 0.
  static double? parseUsedPercent(String line) {
    final percents = _percent.allMatches(line).toList();
    if (percents.isNotEmpty) {
      double? used;
      double? remaining;
      for (final m in percents) {
        final value = double.parse(m.group(1)!);
        final word = m.group(2)?.trim().toLowerCase();
        if (word == 'used' && used == null) {
          used = value;
        } else if (word == 'remaining' && remaining == null) {
          remaining = value;
        } else {
          return null;
        }
      }
      if (used == null) return null;
      if (remaining != null && (used + remaining - 100).abs() > 1) {
        return null;
      }
      return used;
    }
    if (!_usageWord.hasMatch(line)) return null;
    final ratios = _ratio.allMatches(line).toList();
    if (ratios.length != 1) return null;
    final x = double.parse(ratios.single.group(1)!);
    final y = double.parse(ratios.single.group(2)!);
    if (y <= 0) return null;
    return x / y * 100;
  }
}

AccountLimitIdentity? _identityOf(List<AccountLimitLine> lines) {
  for (final line in lines) {
    final identity = line.heading
        ? null
        : AccountLimitIdentity.fromLine(line.text);
    if (identity != null) return identity;
  }
  return null;
}

Iterable<AccountLimitLine> _lines(
  Object? raw,
  AccountLimitSource source,
) sync* {
  if (raw is! List) return;
  for (final item in raw) {
    if (item is! String) continue;
    var text = item.trim();
    if (text.isEmpty) continue;
    final heading = text.startsWith('📈');
    if (heading) {
      text = text.substring('📈'.length).replaceAll('**', '').trim();
      if (text.isEmpty) continue;
      yield AccountLimitLine(text: text, source: source, heading: true);
      continue;
    }
    yield AccountLimitLine(
      text: text,
      source: source,
      usedPercent: AccountUsageLimits.parseUsedPercent(text),
    );
  }
}

AccountUsageBar? _bar(Object? raw) {
  if (raw is! Map) return null;
  final kind = switch (raw['kind']) {
    'plan' => AccountUsageBarKind.plan,
    'topup' => AccountUsageBarKind.topup,
    _ => null,
  };
  final remaining = validatedMoney(raw['remaining_display']);
  final total = validatedMoney(raw['total_display']);
  final fill = raw['fill_fraction'];
  if (kind == null || remaining == null || total == null || fill is! num) {
    return null;
  }
  final fraction = fill.toDouble();
  if (!fraction.isFinite || fraction < 0 || fraction > 1) return null;
  final pct = raw['pct_used'];
  return AccountUsageBar(
    kind: kind,
    remaining: remaining,
    total: total,
    usedFraction: 1 - fraction,
    pctUsed: kind == AccountUsageBarKind.plan && pct is num && pct.isFinite
        ? pct.round()
        : null,
  );
}

String? _text(Object? raw) {
  if (raw is! String) return null;
  final text = raw.trim();
  return text.isEmpty ? null : text;
}
