import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../models/account_usage_limits.dart';
import '../theme/app_theme.dart';
import '../usage/plan_limits_view.dart';

/// «Límites de tu plan» in the model sheet: the `usage.bars` dollar bars
/// when Hermes has them, then [planLimitsView]'s localized rows for the
/// `session.usage` lines (a thin bar only under a stated percentage). The
/// server's free text never renders as is (QA 9494 privacy): unknown lines,
/// scrubbed of URLs and ids, sit in a collapsed «Detalles del proveedor».
/// Paints nothing when the provider publishes no limits.
class AccountLimitsSection extends StatelessWidget {
  const AccountLimitsSection({required this.limits, super.key});

  final AccountUsageLimits limits;

  @override
  Widget build(BuildContext context) {
    if (limits.isEmpty) return const SizedBox.shrink();
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final body = <Widget>[];
    for (final bar in limits.bars) {
      body.add(
        _UsageBarRow(
          bar: bar,
          label: switch (bar.kind) {
            AccountUsageBarKind.plan =>
              limits.planName ?? strings.acl1215PlanBar,
            AccountUsageBarKind.topup => strings.acl1215TopupBar,
          },
        ),
      );
    }
    if (limits.renews case final renews?) {
      body.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            strings.acl1215Renews(renews),
            style: TextStyle(fontSize: 11.5, color: colors.textSecondary),
          ),
        ),
      );
    }
    final view = planLimitsView(
      limits,
      strings,
      languageCode: Localizations.localeOf(context).languageCode,
    );
    for (var i = 0; i < view.rows.length; i++) {
      final row = view.rows[i];
      if (row.heading) {
        body.add(
          Padding(
            padding: EdgeInsets.only(top: body.isEmpty ? 0 : 6, bottom: 4),
            child: Text(
              row.label,
              style: TextStyle(
                fontSize: 12.5,
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
    for (final note in view.notes) {
      body.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            note,
            style: TextStyle(fontSize: 12.5, color: colors.warning),
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
        borderRadius: BorderRadius.circular(16),
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
                fontSize: 14,
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

Color _barColor(double usedPercent, HermesThemeColors colors) {
  if (usedPercent >= 100) return colors.error;
  if (usedPercent >= 80) return colors.warning;
  return colors.accent;
}

Widget _thinBar(Key key, double usedPercent, HermesThemeColors colors) =>
    ClipRRect(
      borderRadius: BorderRadius.circular(99),
      child: LinearProgressIndicator(
        key: key,
        value: (usedPercent / 100).clamp(0.0, 1.0),
        minHeight: 4,
        color: _barColor(usedPercent, colors),
        backgroundColor: colors.divider.withValues(alpha: 0.6),
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
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(
                child: Text(
                  row.label,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.3,
                    color: colors.textPrimary,
                  ),
                ),
              ),
              if (row.value case final value?) ...[
                const SizedBox(width: 8),
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: colors.textSecondary,
                    fontFeatures: tabular,
                  ),
                ),
              ],
            ],
          ),
          if (used != null) ...[
            const SizedBox(height: 4),
            _thinBar(ValueKey('account-limit-bar-$index'), used, colors),
          ],
          if (detail != null) ...[
            const SizedBox(height: 3),
            Text(
              detail,
              style: TextStyle(
                fontSize: 11,
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
              constraints: const BoxConstraints(minHeight: 40),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      strings.plv1215Details,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: colors.textSecondary,
                      ),
                    ),
                  ),
                  Icon(
                    _open
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
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
                style: TextStyle(fontSize: 11.5, color: colors.textSecondary),
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
                  style: TextStyle(fontSize: 13, color: colors.textPrimary),
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                flex: 2,
                child: Text(
                  strings.acl1215BarLeft(bar.remaining, bar.total),
                  textAlign: TextAlign.end,
                  style: TextStyle(
                    fontSize: 12.5,
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
          ),
        ],
      ),
    );
  }
}
