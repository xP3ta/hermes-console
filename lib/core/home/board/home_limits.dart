/// «Límites del plan» rows for Home: the same `session.usage` /
/// `usage.bars` data the model sheet reads ([AccountUsageLimits]). The text
/// lines go through the model sheet's own builder ([planLimitsView]), so
/// both surfaces name the windows the same way, in the user's language.
/// Home keeps only the rows with an unambiguous percentage (a bar to draw);
/// account headings, provider lines, top-up links, banked resets and
/// provider details never reach it. Privacy: provider lines can carry URLs
/// and account or organization ids, so nothing free-form passes through —
/// labels and details are Console's own, a plan name must be a plain word,
/// and bar amounts must look like amounts.
library;

import 'package:flutter/foundation.dart';

import '../../../l10n/app_localizations.dart';
import '../../models/account_usage_limits.dart';
import '../../models/home_widget_snapshot.dart';
import '../../usage/plan_limits_view.dart';

/// Whose limits a row is: the provider Hermes reports for them and, when it
/// reports one, the plan. Never a guess: without a plan only the provider's
/// name shows, and without a provider no identity at all.
@immutable
final class HomeLimitIdentity {
  const HomeLimitIdentity({
    required this.provider,
    required this.name,
    this.plan,
  });

  /// Hermes' slug for the provider (`openai-codex`): what the logo is
  /// resolved from.
  final String provider;

  /// The provider's name («OpenAI Codex», «Anthropic»).
  final String name;

  /// The plan as the provider reports it («Plus», «Max 5x»).
  final String? plan;

  @override
  bool operator ==(Object other) =>
      other is HomeLimitIdentity &&
      other.provider == provider &&
      other.plan == plan;

  @override
  int get hashCode => Object.hash(provider, plan);
}

/// Hermes' own names for the providers that report limits
/// (`hermes_cli/auth.py`, the model providers). Any other slug is written
/// out word by word.
const _providerNames = {
  'openai-codex': 'OpenAI Codex',
  'anthropic': 'Anthropic',
  'openrouter': 'OpenRouter',
  'nous': 'Nous',
  'opencode-zen': 'OpenCode Zen',
};

/// The name of the provider behind [slug].
String homeLimitProviderName(String slug) {
  final key = slug.toLowerCase();
  final known = _providerNames[key];
  if (known != null) return known;
  return key
      .split(RegExp(r'[-_.]+'))
      .where((word) => word.isNotEmpty)
      .map((word) => word[0].toUpperCase() + word.substring(1))
      .join(' ');
}

HomeLimitIdentity? _identity(AccountLimitIdentity? who, {String? plan}) {
  if (who == null) return null;
  return HomeLimitIdentity(
    provider: who.provider,
    name: homeLimitProviderName(who.provider),
    plan: _safePlanName(plan ?? who.plan),
  );
}

enum HomeLimitWindow {
  /// A window read from Hermes' text lines (session, week, extra usage,
  /// subscription…), labelled by [planLimitsView].
  line,

  /// The plan bar of `usage.bars`.
  planBar,

  /// The top-up bar of `usage.bars`.
  topupBar,
}

@immutable
final class HomeLimitRow {
  final HomeLimitWindow window;

  /// Percentage used, 0..100 (more when over).
  final double used;

  /// Localized label of a [HomeLimitWindow.line] row («Sesión actual»).
  final String? label;

  /// Localized secondary line of a [HomeLimitWindow.line] row («Se
  /// reinicia en 2 h 13 min», «$12.00 de $20.00»).
  final String? detail;

  /// Plan name of a [HomeLimitWindow.planBar] row.
  final String? name;

  /// Amount left and total of a bar (`$3.00`, `$20.00`), as Hermes
  /// formatted them.
  final String? left;
  final String? total;

  /// Whose limits this row is; null when Hermes did not say.
  final HomeLimitIdentity? who;

  const HomeLimitRow({
    required this.window,
    required this.used,
    this.who,
    this.label,
    this.detail,
    this.name,
    this.left,
    this.total,
  });

  /// 80 % used or more: calm warning; 100 %: reached.
  bool get near => used >= 80;
  bool get reached => used >= 100;
}

/// A display amount (`$12.00`, `4,20 €`, `50 USD`): digits, separators
/// and a short currency mark only — never a URL or an id.
final _amount = RegExp(r'^[$€£¥]?\d[\d.,]*\s?(?:[$€£¥]|[A-Z]{3})?$');

String? _safeAmount(String? raw) {
  final text = raw?.trim();
  if (text == null || text.isEmpty || text.length > 16) return null;
  return _amount.hasMatch(text) ? text : null;
}

/// The rows Home shows for [limits], each with whose it is. The provider
/// account the session runs on comes first (it is the one in use), then the
/// credits (the `usage.bars` bars, else Nous' credit lines).
List<HomeLimitRow> homeLimitRows(
  AccountUsageLimits limits,
  Strings s, {
  required String languageCode,
}) {
  final account = _identity(limits.accountIdentity);
  final credits = _identity(limits.creditsIdentity, plan: limits.planName);
  final accountRows = <HomeLimitRow>[];
  final creditRows = <HomeLimitRow>[];
  var inCredits = false;
  for (final row in planLimitsView(
    limits,
    s,
    languageCode: languageCode,
  ).rows) {
    if (row.heading) {
      inCredits = row.label == s.plv1215Credits;
      continue;
    }
    if (row.usedPercent == null) continue;
    (inCredits ? creditRows : accountRows).add(
      HomeLimitRow(
        window: HomeLimitWindow.line,
        who: inCredits ? credits : account,
        label: row.label,
        detail: row.detail,
        used: row.usedPercent!,
      ),
    );
  }
  return [
    ...accountRows,
    for (final bar in limits.bars)
      HomeLimitRow(
        window: switch (bar.kind) {
          AccountUsageBarKind.plan => HomeLimitWindow.planBar,
          AccountUsageBarKind.topup => HomeLimitWindow.topupBar,
        },
        who: credits,
        used: bar.usedFraction * 100,
        name: bar.kind == AccountUsageBarKind.plan
            ? _safePlanName(limits.planName)
            : null,
        left: _safeAmount(bar.remaining),
        total: _safeAmount(bar.total),
      ),
    ...creditRows,
  ];
}

/// Rows that belong to the same account, in the order they are shown.
@immutable
final class HomeLimitGroup {
  const HomeLimitGroup(this.who, this.rows);
  final HomeLimitIdentity? who;
  final List<HomeLimitRow> rows;
}

/// [rows] split by whose they are. The first group is the one in use.
List<HomeLimitGroup> homeLimitGroups(List<HomeLimitRow> rows) {
  final groups = <HomeLimitGroup>[];
  for (final row in rows) {
    if (groups.isNotEmpty && groups.last.who == row.who) {
      groups.last.rows.add(row);
    } else {
      groups.add(HomeLimitGroup(row.who, [row]));
    }
  }
  return groups;
}

/// A plan name from `usage.bars` («Pro», «Max 5x»): short words only.
String? _safePlanName(String? raw) {
  final text = raw?.trim();
  if (text == null || text.isEmpty || text.length > 24) return null;
  return RegExp(r'^[A-Za-z][A-Za-z0-9 +.\-]*$').hasMatch(text) &&
          !RegExp(r'://|www\.|org[_-]|\d{5,}').hasMatch(text)
      ? text
      : null;
}

String homeLimitLabel(Strings s, HomeLimitRow row) => switch (row.window) {
  HomeLimitWindow.line => row.label ?? s.plv1215Limit,
  HomeLimitWindow.planBar => row.name ?? s.acl1215PlanBar,
  HomeLimitWindow.topupBar => s.acl1215TopupBar,
};

/// What goes under a limit bar: when it resets, or what is left (the model
/// sheet's own localized detail for a text window).
String? homeLimitNote(Strings s, HomeLimitRow row) {
  if (row.reached) return s.hwLimReached;
  if (row.detail case final detail?) return detail;
  if (row.left case final left?) {
    if (row.total case final total?) return s.acl1215BarLeft(left, total);
  }
  return null;
}

/// The limits as the launcher widgets get them: one group per subscription
/// (provider id, name and plan as the server reports them), the account in
/// use first, each window already in the app's language.
List<HomeWidgetLimitGroup> homeWidgetLimits(
  AccountUsageLimits limits,
  Strings s, {
  required String languageCode,
}) {
  final groups = homeLimitGroups(
    homeLimitRows(limits, s, languageCode: languageCode),
  );
  return [
    for (final (i, group) in groups.indexed)
      if (group.who case final who?)
        HomeWidgetLimitGroup(
          provider: who.provider,
          providerName: who.name,
          plan: who.plan,
          inUse: i == 0,
          windows: [
            for (final row in group.rows)
              HomeWidgetLimitWindow(
                label: homeLimitLabel(s, row),
                usedPercent: row.used.round(),
                detail: homeLimitNote(s, row),
              ),
          ],
        ),
  ];
}
