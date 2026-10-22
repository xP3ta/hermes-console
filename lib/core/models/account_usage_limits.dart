import 'package:flutter/foundation.dart';

import '../widgets/chat_status_pill.dart' show SubscriptionLimitLevel;
import '../usage/provider_value_validation.dart';
import 'model_provider.dart';
import 'provider_usage.dart';

/// Where a rendered limit line came from in `session.usage`.
enum AccountLimitSource {
  /// `account_lines`: provider account limits (Codex / Claude quota windows).
  account,

  /// `credits_lines`: Nous credits.
  credits,
}

/// A pooled account Hermes gives no numbers for (or a limited one): its
/// row states the situation and draws no gauge.
enum AccountLimitStatus { limited, unknown, unavailable }

/// One line Hermes rendered for `/usage` (agent/account_usage.py), shown as
/// is. [usedPercent] is set only when the line states it unambiguously.
@immutable
class AccountLimitLine {
  const AccountLimitLine({
    required this.text,
    required this.source,
    this.heading = false,
    this.usedPercent,
    this.groupHeading = false,
    this.inUse = true,
    this.modelScoped = false,
    this.status,
    this.accountNumber,
  });

  /// The line as Hermes sent it (heading lines lose the 📈 and `**`).
  final String text;
  final AccountLimitSource source;
  final bool heading;
  final double? usedPercent;

  /// A heading that names whose the lines below are (a provider, or one
  /// account of its pool). Unlike the `account_lines` title it is rendered.
  final bool groupHeading;

  /// False for the lines of a provider other than the one the session runs
  /// on: shown under their own heading, never counted for the status pill.
  final bool inUse;

  /// The window caps one model family, not the account: it never makes the
  /// account "reached".
  final bool modelScoped;

  /// Set on a state row: [text] then holds only the reset phrase, if any.
  final AccountLimitStatus? status;

  /// With [groupHeading]: the 1-based position of a pooled account that
  /// Hermes gave no usable label, shown as «Account N».
  final int? accountNumber;

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

  /// Builds the block from the `usage` of the `/api/model/options` rows
  /// (Hermes >= 0.22.3, whose `session.usage` has no `account_lines`) in the
  /// same shape `account_lines` had. The row of [sessionProvider] (the
  /// provider the session runs on) goes first and is the only one that
  /// feeds [level] and [accountIdentity]; every other provider with usage
  /// follows under its own heading. When the route is not in the catalog
  /// all of them are listed that way and none feeds the pill. A pool gets
  /// one heading per account, never a provider-wide figure. [skipProvider]
  /// leaves out a provider whose limits are already shown (Nous credits).
  factory AccountUsageLimits.fromProviderUsage(
    List<ModelProvider> providers, {
    String? sessionProvider,
    String? skipProvider,
    DateTime? now,
  }) {
    final clock = (now ?? DateTime.now()).toUtc();
    final wanted = sessionProvider?.trim().toLowerCase() ?? '';
    final skip = skipProvider?.trim().toLowerCase();
    bool isRoute(ModelProvider p) =>
        wanted.isNotEmpty &&
        (p.slug.trim().toLowerCase() == wanted || p.aliases.contains(wanted));
    final rows = [
      for (final p in providers)
        if (p.usage != null &&
            p.slug.trim().isNotEmpty &&
            p.slug.trim().toLowerCase() != skip)
          p,
    ];
    // Exactly one match decides the route; two rows claiming it decide nothing.
    final routes = rows.where(isRoute).toList();
    final route = routes.length == 1 ? routes.single : null;
    final ordered = [?route, ...rows.where((p) => !identical(p, route))];
    final lines = <AccountLimitLine>[];
    for (final p in ordered) {
      lines.addAll(_providerLines(p, inUse: identical(p, route), now: clock));
    }
    return AccountUsageLimits(
      lines: List.unmodifiable(lines),
      accountIdentity: route == null
          ? null
          : AccountLimitIdentity(provider: route.slug.trim().toLowerCase()),
    );
  }

  /// Puts [other]'s lines after these and fills what this block lacks.
  AccountUsageLimits withProviderLines(AccountUsageLimits other) =>
      AccountUsageLimits(
        lines: List.unmodifiable([...other.lines, ...lines]),
        bars: bars,
        planName: planName,
        renews: renews,
        accountIdentity: accountIdentity ?? other.accountIdentity,
        creditsIdentity: creditsIdentity,
      );

  /// Hint for the status pill: the fullest unambiguous number among the
  /// parsed lines and the plan bar's `pct_used`.
  SubscriptionLimitLevel get level {
    double? fullest;
    void consider(double? value) {
      if (value == null) return;
      if (fullest == null || value > fullest!) fullest = value;
    }

    for (final line in lines) {
      if (line.inUse && !line.modelScoped) consider(line.usedPercent);
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

List<AccountLimitLine> _providerLines(
  ModelProvider provider, {
  required bool inUse,
  required DateTime now,
}) {
  final usage = provider.usage!;
  final slug = provider.slug.trim();
  final name = scrubProviderText(provider.name) ?? slug;
  final out = <AccountLimitLine>[];
  void group(String text, {int? number}) => out.add(
    AccountLimitLine(
      text: text.length > 60 ? text.substring(0, 60).trim() : text,
      source: AccountLimitSource.account,
      heading: true,
      groupHeading: true,
      inUse: inUse,
      accountNumber: number,
    ),
  );
  void windows(List<ProviderUsageWindow> list) {
    for (final w in list) {
      final line = _windowLine(w, inUse: inUse, now: now);
      if (line != null) out.add(line);
    }
  }

  if (usage.accounts.isEmpty) {
    if (usage.windows.isEmpty) return const [];
    group(name);
    windows(usage.windows);
    return out;
  }
  for (final (i, account) in usage.accounts.indexed) {
    final label = account.label.isEmpty
        ? null
        : scrubProviderText(account.label);
    group(
      label == null ? name : '$name · $label',
      number: label == null ? i + 1 : null,
    );
    final numeric =
        account.state == ProviderUsageState.ready ||
        account.state == ProviderUsageState.limited;
    if (numeric) windows(account.windows);
    final status = switch (account.state) {
      ProviderUsageState.ready => null,
      ProviderUsageState.limited => AccountLimitStatus.limited,
      ProviderUsageState.unknown => AccountLimitStatus.unknown,
      ProviderUsageState.unavailable => AccountLimitStatus.unavailable,
    };
    if (status != null) {
      final at = status == AccountLimitStatus.limited ? account.resetsAt : null;
      out.add(
        AccountLimitLine(
          text: at == null ? status.name : _resetPhrase(at, now),
          source: AccountLimitSource.account,
          inUse: inUse,
          status: status,
        ),
      );
    } else if (account.windows.isEmpty) {
      // "ready" without numbers is not a state Hermes sends: say so.
      out.add(
        AccountLimitLine(
          text: AccountLimitStatus.unknown.name,
          source: AccountLimitSource.account,
          inUse: inUse,
          status: AccountLimitStatus.unknown,
        ),
      );
    }
  }
  return out;
}

/// `Session: 72% remaining (28% used) • resets in 2h 13m (2026-10-06 18:00)`,
/// what Hermes' `render_account_usage_lines` writes for a window.
AccountLimitLine? _windowLine(
  ProviderUsageWindow w, {
  required bool inUse,
  required DateTime now,
}) {
  // The label rides in a `Label: N% remaining` line (and is mapped to a
  // localized name there): only plain words qualify, anything else is dropped.
  final label = w.label.trim();
  if (!RegExp(r'^[A-Za-z][A-Za-z -]{0,39}$').hasMatch(label)) return null;
  final used = w.usedPercent.round();
  var text = '$label: ${100 - used}% remaining ($used% used)';
  if (w.resetsAt case final at?) text += ' • ${_resetPhrase(at, now)}';
  return AccountLimitLine(
    text: text,
    source: AccountLimitSource.account,
    usedPercent: AccountUsageLimits.parseUsedPercent(text),
    inUse: inUse,
    modelScoped: w.scope == ProviderUsageScope.model,
  );
}

String _resetPhrase(DateTime at, DateTime now) {
  String two(int v) => v.toString().padLeft(2, '0');
  final local = at.toLocal();
  final stamp =
      '${local.year.toString().padLeft(4, '0')}-${two(local.month)}-'
      '${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
  final seconds = at.difference(now).inSeconds;
  if (seconds <= 0) return 'resets now ($stamp)';
  final hours = seconds ~/ 3600;
  final minutes = seconds % 3600 ~/ 60;
  if (hours >= 24) return 'resets in ${hours ~/ 24}d ${hours % 24}h ($stamp)';
  return hours > 0
      ? 'resets in ${hours}h ${minutes}m ($stamp)'
      : 'resets in ${minutes}m ($stamp)';
}
