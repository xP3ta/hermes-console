import 'package:flutter/foundation.dart';

import '../../l10n/app_localizations.dart';
import '../models/account_usage_limits.dart';
import 'provider_value_validation.dart';
export 'provider_value_validation.dart' show scrubProviderText;

/// One row of «Límites de tu plan», already localized.
@immutable
class PlanLimitRow {
  const PlanLimitRow({
    required this.label,
    this.value,
    this.detail,
    this.usedPercent,
    this.heading = false,
  });

  /// A localized label («Sesión actual», «Semana», «Créditos»…).
  final String label;

  /// Localized amount («Quedan 72 %», «No disponible», «$12.00»).
  final String? value;

  /// Localized secondary line (reset time, «$12.00 de $20.00»).
  final String? detail;

  /// Set only when the server stated it unambiguously: draws a thin bar.
  final double? usedPercent;

  /// A block title (the account's limits, the credits).
  final bool heading;
}

/// What the plan limits block shows, built ONLY from what Hermes structures
/// (QA 9494 privacy): the windows Hermes renders for `/usage`, their
/// percentages and reset times, the credit amounts and known statuses, each
/// under a localized label. The server's English free text never renders
/// as is: unknown lines go to [providerDetails] with every URL and id
/// removed, for a collapsed «Detalles del proveedor».
///
/// Shared by the model sheet and Home, so both say the same thing.
@immutable
class PlanLimitsView {
  const PlanLimitsView({
    this.rows = const [],
    this.notes = const [],
    this.providerDetails = const [],
  });

  final List<PlanLimitRow> rows;

  /// Localized statuses («Sin saldo: recarga para seguir»).
  final List<String> notes;

  /// Unknown provider lines, scrubbed of URLs and ids.
  final List<String> providerDetails;

  bool get isEmpty => rows.isEmpty && notes.isEmpty && providerDetails.isEmpty;
}

/// Builds the localized view of [limits]' text lines. The `usage.bars`
/// bars are already structured and render apart.
PlanLimitsView planLimitsView(
  AccountUsageLimits limits,
  Strings s, {
  required String languageCode,
}) {
  final rows = <PlanLimitRow>[];
  final notes = <String>[];
  final details = <String>[];
  AccountLimitSource? block;
  for (final line in limits.lines) {
    if (line.heading) continue;
    final row = _row(line, s, languageCode);
    if (row != null) {
      if (block != line.source) {
        block = line.source;
        rows.add(
          PlanLimitRow(
            label: line.source == AccountLimitSource.credits
                ? s.plv1215Credits
                : s.plv1215Account,
            heading: true,
          ),
        );
      }
      rows.add(row);
      continue;
    }
    final note = _note(line.text, s);
    if (note != null) {
      if (!notes.contains(note)) notes.add(note);
      continue;
    }
    if (_dropped(line.text)) continue;
    final clean = scrubProviderText(line.text);
    if (clean != null && !details.contains(clean)) details.add(clean);
  }
  return PlanLimitsView(
    rows: List.unmodifiable(rows),
    notes: List.unmodifiable(notes),
    providerDetails: List.unmodifiable(details),
  );
}

// `Session: 72% remaining (28% used) • resets in 2h 13m (2026-10-06 …)`
final _window = RegExp(
  r'^([A-Za-z][A-Za-z -]{0,39}): (\d{1,3})% remaining \((\d{1,3})% used\)'
  r'(?: • (.+))?$',
);
final _windowUnavailable = RegExp(r'^([A-Za-z][A-Za-z -]{0,39}): unavailable$');
final _resetsIn = RegExp(
  r'^resets in (?:(\d{1,5})d ?)?(?:(\d{1,5})h ?)?(?:(\d{1,5})m)?\s*(?:\(([^()]*)\))?$',
);
final _resetsNow = RegExp(r'^resets now(?: \(([^()]*)\))?$');
final _moneyLeft = RegExp(
  r'^(\$[\d,]+(?:\.\d+)?) of (\$[\d,]+(?:\.\d+)?) left$',
);
final _extraUsage = RegExp(
  r'^Extra usage: (\d{1,12}(?:\.\d{1,2})?) / (\d{1,12}(?:\.\d{1,2})?) (USD|EUR|GBP|CAD|AUD|JPY|CHF|CNY|INR|KRW|BRL|MXN|NZD|SEK|NOK|DKK|SGD|HKD|ZAR)$',
);
final _amount = RegExp(r'^([A-Za-z][A-Za-z -]{0,39}): (\$[\d,]+(?:\.\d+)?)$');
final _renews = RegExp(r'^Renews: (.+)$');
final _banked = RegExp(r'^You have (\d{1,5}) resets? banked\b');

String? _windowLabel(String raw, Strings s) => switch (raw.trim()) {
  'Session' || 'Current session' => s.plv1215Session,
  'Weekly' || 'Current week' => s.plv1215Week,
  'Opus week' => s.plv1215WeekOpus,
  'Sonnet week' => s.plv1215WeekSonnet,
  'Subscription' => s.plv1215Subscription,
  'API key quota' => s.plv1215ApiKeyQuota,
  _ => null,
};

String? _amountLabel(String raw, Strings s) => switch (raw.trim()) {
  'Subscription credits' => s.plv1215CreditsPlan,
  'Top-up credits' => s.plv1215CreditsTopup,
  'Total usable' => s.plv1215CreditsTotal,
  'Credits balance' => s.plv1215CreditsBalance,
  'Rollover' => s.plv1215Rollover,
  _ => null,
};

PlanLimitRow? _row(AccountLimitLine line, Strings s, String languageCode) {
  final text = line.text.trim();
  final window = _window.firstMatch(text);
  if (window != null) {
    final remaining = int.parse(window.group(2)!);
    final used = int.parse(window.group(3)!);
    if (remaining > 100 || used > 100 || (remaining + used - 100).abs() > 1) {
      return null;
    }
    final tail = window.group(4)?.trim();
    String? detail;
    if (tail != null) {
      final money = _moneyLeft.firstMatch(tail);
      final now = _resetsNow.firstMatch(tail);
      if (money != null &&
          validatedMoney(money.group(1)) != null &&
          validatedMoney(money.group(2)) != null) {
        detail = s.plv1215Of(money.group(1)!, money.group(2)!);
      } else if (now != null && validResetTimestamp(now.group(1))) {
        detail = s.plv1215ResetsNow;
      } else if (_resetsIn.firstMatch(tail) case final reset?) {
        if (validResetTimestamp(reset.group(4))) {
          final span = _span(
            days: int.tryParse(reset.group(1) ?? ''),
            hours: int.tryParse(reset.group(2) ?? ''),
            minutes: int.tryParse(reset.group(3) ?? ''),
            languageCode: languageCode,
          );
          if (span != null) detail = s.plv1215ResetsIn(span);
        }
      }
    }
    return PlanLimitRow(
      label: _windowLabel(window.group(1)!, s) ?? s.plv1215Limit,
      value: s.plv1215Left(remaining),
      detail: detail,
      usedPercent: used.toDouble().clamp(0, 100).toDouble(),
    );
  }
  final unavailable = _windowUnavailable.firstMatch(text);
  if (unavailable != null) {
    final label = _windowLabel(unavailable.group(1)!, s);
    if (label == null) return null;
    return PlanLimitRow(label: label, value: s.plv1215Unavailable);
  }
  final extra = _extraUsage.firstMatch(text);
  if (extra != null) {
    return PlanLimitRow(
      label: s.plv1215ExtraUsage,
      value: s.plv1215Of(
        extra.group(1)!,
        '${extra.group(2)!} ${extra.group(3)!}',
      ),
      usedPercent: line.usedPercent,
    );
  }
  final amount = _amount.firstMatch(text);
  if (amount != null) {
    final label = _amountLabel(amount.group(1)!, s);
    final money = validatedMoney(amount.group(2));
    if (label == null || money == null) return null;
    return PlanLimitRow(label: label, value: money);
  }
  final renews = _renews.firstMatch(text);
  if (renews != null) {
    final date = validatedRenewalDate(renews.group(1));
    if (date == null) return null;
    return PlanLimitRow(label: s.plv1215RenewsLabel, value: date);
  }
  return null;
}

String? _note(String text, Strings s) {
  final t = text.trim();
  if (t.startsWith('Status: access depleted')) return s.plv1215Depleted;
  final banked = _banked.firstMatch(t);
  if (banked != null) return s.plv1215BankedResets(int.parse(banked.group(1)!));
  return null;
}

/// Lines that only repeat what the section already says, or point at a
/// command or page: never shown, not even as details.
bool _dropped(String text) {
  final t = text.trim();
  const recognized = [
    'Session',
    'Current session',
    'Weekly',
    'Current week',
    'Opus week',
    'Sonnet week',
    'Subscription',
    'API key quota',
    'Subscription credits',
    'Top-up credits',
    'Total usable',
    'Credits balance',
    'Rollover',
    'Extra usage',
  ];
  return recognized.any((label) => t.startsWith('$label:')) ||
      t.startsWith('Provider:') ||
      t.startsWith('Renews:') ||
      t.startsWith('You have ') ||
      t.startsWith('Top up:') ||
      t.startsWith('(or run ') ||
      t.isEmpty;
}

String? _span({
  required int? days,
  required int? hours,
  required int? minutes,
  required String languageCode,
}) {
  final es = languageCode == 'es';
  final parts = <String>[
    if (days != null && days > 0) es ? '$days d' : '${days}d',
    if (hours != null && hours > 0) es ? '$hours h' : '${hours}h',
    if (minutes != null && minutes > 0) es ? '$minutes min' : '${minutes}m',
  ];
  if (parts.isEmpty) return null;
  return parts.join(' ');
}
