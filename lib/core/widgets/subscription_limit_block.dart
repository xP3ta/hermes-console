import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import 'chat_status_pill.dart' show SubscriptionLimitLevel;

/// What the subscription-limit block can say about the active provider.
enum SubscriptionLimitKind {
  /// Hermes published usage windows for this account.
  windows,

  /// A local model: no usage limit and no cost.
  local,

  /// Hermes has no limit data for this provider.
  noData,
}

/// One usage window of a subscription (5 h session, week, …) as Hermes
/// computes it: percentage used and, when known, when it resets.
@immutable
class SubscriptionLimitWindow {
  const SubscriptionLimitWindow({
    required this.label,
    required this.usedPercent,
    this.resetAt,
  });

  final String label;
  final double usedPercent;
  final DateTime? resetAt;
}

/// Subscription limits of the account behind the active model. Only real
/// Hermes data may build one; nothing here is estimated by the client.
@immutable
class SubscriptionLimits {
  const SubscriptionLimits({
    required this.kind,
    this.plan,
    this.windows = const [],
    this.extraUsed,
    this.extraLimit,
    this.extraCurrency,
  });

  final SubscriptionLimitKind kind;
  final String? plan;
  final List<SubscriptionLimitWindow> windows;

  /// Extra usage beyond the plan, as Hermes formats it (`4.20` of `50.00`).
  final String? extraUsed;
  final String? extraLimit;
  final String? extraCurrency;

  /// The dot next to the model in the status pill: the fullest window.
  SubscriptionLimitLevel get level {
    if (kind != SubscriptionLimitKind.windows || windows.isEmpty) {
      return SubscriptionLimitLevel.none;
    }
    final fullest = windows
        .map((w) => w.usedPercent)
        .reduce((a, b) => a > b ? a : b);
    if (fullest >= 100) return SubscriptionLimitLevel.reached;
    if (fullest >= 80) return SubscriptionLimitLevel.near;
    return SubscriptionLimitLevel.none;
  }
}

/// `35 min`, `1 h 48 min`, `3 h`, `2 d 5 h`. Never below one minute.
String formatLimitDuration(Duration duration) {
  final minutes = duration.inMinutes < 1 ? 1 : duration.inMinutes;
  final days = minutes ~/ (60 * 24);
  final hours = (minutes ~/ 60) % 24;
  final mins = minutes % 60;
  if (days > 0) return hours > 0 ? '$days d $hours h' : '$days d';
  if (hours > 0) return mins > 0 ? '$hours h $mins min' : '$hours h';
  return '$mins min';
}

/// «Límite de tu suscripción»: plan chip, one bar per window (accent, amber
/// from 80 %, red and «Agotado» at 100 %), reset time, a banner when a
/// window is used up, and the extra-usage line.
class SubscriptionLimitBlock extends StatelessWidget {
  const SubscriptionLimitBlock({required this.limits, this.now, super.key});

  final SubscriptionLimits limits;

  /// Injectable clock for the reset countdown (tests).
  final DateTime Function()? now;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final clock = now?.call() ?? DateTime.now();
    final body = <Widget>[];
    switch (limits.kind) {
      case SubscriptionLimitKind.local:
        body.add(_Note(text: strings.sp1215LimitLocal));
      case SubscriptionLimitKind.noData:
        body.add(_Note(text: strings.sp1215LimitNoData));
      case SubscriptionLimitKind.windows:
        String? resetText(SubscriptionLimitWindow window) {
          final at = window.resetAt;
          if (at == null) return null;
          return strings.sp1215LimitResetsIn(
            formatLimitDuration(at.difference(clock)),
          );
        }

        final exhausted = limits.windows
            .where((w) => w.usedPercent >= 100)
            .toList();
        if (exhausted.isNotEmpty) {
          final reset = resetText(exhausted.first);
          body.add(
            Container(
              key: const ValueKey('limit-banner'),
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: colors.error.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: colors.error.withValues(alpha: 0.4)),
              ),
              child: Text(
                reset == null
                    ? strings.sp1215LimitBannerNoReset
                    : strings.sp1215LimitBanner(_capitalized(reset)),
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: colors.error,
                ),
              ),
            ),
          );
        }
        for (final window in limits.windows) {
          body.add(_WindowRow(window: window, resetText: resetText(window)));
        }
        final extraUsed = limits.extraUsed;
        final extraLimit = limits.extraLimit;
        if (extraUsed != null && extraLimit != null) {
          body.add(
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                strings.sp1215LimitExtra(
                  extraUsed,
                  extraLimit,
                  limits.extraCurrency ?? 'USD',
                ),
                style: TextStyle(fontSize: 11.5, color: colors.textSecondary),
              ),
            ),
          );
        }
    }
    return Container(
      key: const ValueKey('subscription-limit-block'),
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: colors.surfaceVariant.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.divider.withValues(alpha: 0.7)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Semantics(
                header: true,
                child: Text(
                  strings.sp1215LimitTitle,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: colors.textPrimary,
                  ),
                ),
              ),
              if (limits.plan != null && limits.plan!.trim().isNotEmpty)
                Container(
                  key: const ValueKey('subscription-plan-chip'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: colors.accent.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(99),
                  ),
                  child: Text(
                    limits.plan!.trim(),
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: colors.accentText,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          ...body,
        ],
      ),
    );
  }
}

String _capitalized(String text) =>
    text.isEmpty ? text : text[0].toUpperCase() + text.substring(1);

class _WindowRow extends StatelessWidget {
  const _WindowRow({required this.window, required this.resetText});

  final SubscriptionLimitWindow window;
  final String? resetText;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final used = window.usedPercent;
    final full = used >= 100;
    final barColor = full
        ? colors.error
        : used >= 80
        ? colors.warning
        : colors.accent;
    final usedText = full
        ? strings.sp1215LimitUsedUp
        : strings.sp1215LimitUsed(used.round().clamp(0, 100));
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            spacing: 8,
            children: [
              Text(
                window.label,
                style: TextStyle(fontSize: 13, color: colors.textPrimary),
              ),
              Text(
                usedText,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: full ? FontWeight.w700 : FontWeight.w500,
                  color: full ? colors.error : colors.textSecondary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(
              value: (used / 100).clamp(0.0, 1.0),
              minHeight: 5,
              color: barColor,
              backgroundColor: colors.divider.withValues(alpha: 0.6),
            ),
          ),
          if (resetText != null) ...[
            const SizedBox(height: 4),
            Text(
              resetText!,
              style: TextStyle(fontSize: 11, color: colors.textSecondary),
            ),
          ],
        ],
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: TextStyle(
      fontSize: 12.5,
      height: 1.35,
      color: Theme.of(context).hermes.textSecondary,
    ),
  );
}
