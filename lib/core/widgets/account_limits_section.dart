import 'package:hermes_android/core/design/hicons.dart';
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../models/account_usage_limits.dart';
import '../design/tokens.dart'
    show HermesSpace, HermesType, HermesChrome, HermesRadius;
import '../theme/app_theme.dart';
import '../usage/plan_limits_view.dart';

/// «Límites de tu plan» in the model sheet: the `usage.bars` dollar bars
/// when Hermes has them, then [planLimitsView]'s localized rows for the
/// `session.usage` lines (a thin bar only under a stated percentage). The
/// server's free text never renders as is (QA 9494 privacy): unknown lines,
/// scrubbed of URLs and ids, sit in a collapsed «Detalles del proveedor».
/// Paints nothing when the provider publishes no limits.
class AccountLimitsSection extends StatelessWidget {
  const AccountLimitsSection({
    required this.limits,
    this.preferredProvider,
    super.key,
  });

  final AccountUsageLimits limits;
  final String? preferredProvider;

  @override
  Widget build(BuildContext context) {
    if (limits.isEmpty) return const SizedBox.shrink();
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final preferred = preferredProvider?.trim().toLowerCase();
    final creditsFirst = AccountCreditBars.leads(limits, preferred);
    final body = <Widget>[];
    final creditRows = AccountCreditBars.rows(context, limits);
    if (creditsFirst) {
      body.addAll(creditRows);
    }
    final view = planLimitsView(
      limits,
      strings,
      languageCode: Localizations.localeOf(context).languageCode,
      preferredProvider: preferred,
    );
    for (var i = 0; i < view.rows.length; i++) {
      final row = view.rows[i];
      if (row.heading &&
          i + 1 < view.rows.length &&
          view.rows[i + 1].label == strings.msvProviderNoUsage) {
        body.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: HermesSpace.x2),
            child: Wrap(
              spacing: HermesSpace.x2,
              runSpacing: HermesSpace.x1,
              children: [
                Text(
                  row.label,
                  style: TextStyle(
                    fontSize: HermesType.supportSize,
                    fontWeight: FontWeight.w600,
                    color: colors.textSecondary,
                  ),
                ),
                Text(
                  strings.msvProviderNoUsage,
                  style: TextStyle(
                    fontSize: HermesType.captionSize,
                    color: colors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        );
        i++;
      } else if (row.heading) {
        body.add(
          Padding(
            padding: EdgeInsets.only(top: body.isEmpty ? 0 : 6, bottom: 4),
            child: Text(
              row.label,
              style: TextStyle(
                fontSize: HermesType.supportSize,
                fontWeight: FontWeight.w700,
                color: colors.textPrimary,
              ),
            ),
          ),
        );
      } else {
        body.add(_LineRow(row: row, index: i));
      }
    }
    if (!creditsFirst) {
      body.addAll(creditRows);
    }
    for (final note in view.notes) {
      body.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            note,
            style: TextStyle(
              fontSize: HermesType.supportSize,
              color: colors.warning,
            ),
          ),
        ),
      );
    }
    if (view.providerDetails.isNotEmpty) {
      body.add(_ProviderDetails(lines: view.providerDetails));
    }
    if (body.isEmpty) return const SizedBox.shrink();
    return Container(
      key: const ValueKey('account-limits-section'),
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
      decoration: BoxDecoration(
        color: colors.surfaceVariant.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(HermesRadius.row),
        border: Border.all(color: colors.divider.withValues(alpha: 0.7)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(
              strings.acl1215Title,
              style: TextStyle(
                fontSize: HermesType.textSize,
                fontWeight: FontWeight.w700,
                color: colors.textPrimary,
              ),
            ),
          ),
          const SizedBox(height: 8),
          ...body,
        ],
      ),
    );
  }
}

/// The `usage.bars` credit bars (plan and top-up, what is left of each) and
/// the renewal date: the part of [AccountLimitsSection] that is not a
/// `session.usage` line, so the Usage screen's limits show it the same way.
/// Paints nothing when Hermes sent none.
class AccountCreditBars extends StatelessWidget {
  const AccountCreditBars({required this.limits, super.key});

  final AccountUsageLimits limits;

  /// Whether the credits go before the provider-account windows: unless the
  /// session runs on another provider than the one the credits are from.
  static bool leads(AccountUsageLimits limits, String? preferredProvider) {
    final preferred = preferredProvider?.trim().toLowerCase();
    final creditsProvider = limits.creditsIdentity?.provider
        .trim()
        .toLowerCase();
    return preferred == null ||
        preferred.isEmpty ||
        preferred == creditsProvider;
  }

  /// One row per bar, then when the plan renews.
  static List<Widget> rows(BuildContext context, AccountUsageLimits limits) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    return [
      for (final bar in limits.bars)
        _UsageBarRow(
          bar: bar,
          label: switch (bar.kind) {
            AccountUsageBarKind.plan =>
              limits.planName ?? strings.acl1215PlanBar,
            AccountUsageBarKind.topup => strings.acl1215TopupBar,
          },
        ),
      if (limits.renews case final renews?)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            strings.acl1215Renews(renews),
            style: TextStyle(
              fontSize: HermesType.captionSize,
              color: colors.textSecondary,
            ),
          ),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final children = rows(context, limits);
    if (children.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }
}

Color _barColor(double usedPercent, HermesThemeColors colors) {
  if (usedPercent >= 100) return colors.error;
  if (usedPercent >= 80) return colors.warning;
  return colors.success;
}

Widget _thinBar(
  Key key,
  double usedPercent,
  HermesThemeColors colors, {
  required String label,
  required String? value,
}) => ClipRRect(
  borderRadius: BorderRadius.circular(HermesSpace.x1),
  child: LinearProgressIndicator(
    key: key,
    value: (usedPercent / 100).clamp(0.0, 1.0),
    minHeight: HermesSpace.x2,
    color: _barColor(usedPercent, colors),
    backgroundColor: HermesChrome.of(colors).opaque,
    semanticsLabel: [label, ?value].join('. '),
    borderRadius: BorderRadius.circular(HermesSpace.x1),
  ),
);

class _LineRow extends StatelessWidget {
  const _LineRow({required this.row, required this.index});

  final PlanLimitRow row;
  final int index;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final used = row.usedPercent;
    final detail = row.detail;
    const tabular = [FontFeature.tabularFigures()];
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: HermesSpace.x2,
            runSpacing: HermesSpace.x1,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                row.label,
                style: TextStyle(
                  fontSize: HermesType.supportSize,
                  height: 1.3,
                  color: colors.textPrimary,
                ),
              ),
              if (row.value case final value?) ...[
                Text(
                  value,
                  style: TextStyle(
                    fontSize: HermesType.supportSize,
                    color: colors.textSecondary,
                    fontFeatures: tabular,
                  ),
                ),
              ],
            ],
          ),
          if (used != null) ...[
            const SizedBox(height: 4),
            _thinBar(
              ValueKey('account-limit-bar-$index'),
              used,
              colors,
              label: row.label,
              value: row.value,
            ),
            const SizedBox(height: HermesSpace.x1),
            _UsageState(usedPercent: used),
          ],
          if (detail != null) ...[
            const SizedBox(height: 3),
            Text(
              detail,
              style: TextStyle(
                fontSize: HermesType.captionSize,
                color: colors.textSecondary,
                fontFeatures: tabular,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Unknown provider lines, scrubbed, collapsed under a neutral title.
class _ProviderDetails extends StatefulWidget {
  const _ProviderDetails({required this.lines});

  final List<String> lines;

  @override
  State<_ProviderDetails> createState() => _ProviderDetailsState();
}

class _ProviderDetailsState extends State<_ProviderDetails> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          button: true,
          expanded: _open,
          child: GestureDetector(
            key: const ValueKey('plan-limits-details'),
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _open = !_open),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: HermesSpace.tap),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      strings.plv1215Details,
                      style: TextStyle(
                        fontSize: HermesType.supportSize,
                        color: colors.textSecondary,
                      ),
                    ),
                  ),
                  Icon(
                    _open
                        ? HIcons.expand_less_rounded
                        : HIcons.expand_more_rounded,
                    size: 18,
                    color: colors.textSecondary,
                  ),
                ],
              ),
            ),
          ),
        ),
        if (_open)
          for (final line in widget.lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                line,
                style: TextStyle(
                  fontSize: HermesType.captionSize,
                  color: colors.textSecondary,
                ),
              ),
            ),
      ],
    );
  }
}

class _UsageBarRow extends StatelessWidget {
  const _UsageBarRow({required this.bar, required this.label});

  final AccountUsageBar bar;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: HermesType.valueSize,
                    color: colors.textPrimary,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                flex: 2,
                child: Text(
                  strings.acl1215BarLeft(bar.remaining, bar.total),
                  textAlign: TextAlign.end,
                  style: TextStyle(
                    fontSize: HermesType.supportSize,
                    color: colors.textSecondary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          _thinBar(
            ValueKey('account-usage-bar-${bar.kind.name}'),
            bar.usedFraction * 100,
            colors,
            label: label,
            value: strings.acl1215BarLeft(bar.remaining, bar.total),
          ),
          const SizedBox(height: HermesSpace.x1),
          _UsageState(usedPercent: bar.usedFraction * 100),
        ],
      ),
    );
  }
}

class _UsageState extends StatelessWidget {
  const _UsageState({required this.usedPercent});

  final double usedPercent;

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return Text(
      usedPercent >= 100
          ? strings.hwLimReached
          : usedPercent >= 80
          ? strings.msvUsageNearLimit
          : strings.msvUsageAvailable,
      style: TextStyle(
        fontSize: HermesType.captionSize,
        color: _barColor(usedPercent, colors),
      ),
    );
  }
}
