import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hermes_android/core/design/hicons.dart';

import '../../../l10n/app_localizations.dart';
import '../../design/modal.dart' show showHermesSurface;
import '../../theme/app_theme.dart';
import '../../theme/hermes_tokens.dart';
import '../hermes_notice.dart';
import 'turn_receipt_pill.dart';

/// What the background self-improvement review reported, taken apart.
///
/// Hermes sends one line, `<heading>: <action> · <action> …`
/// (`agent/background_review.py` `_publish_review_summary`). It only drops
/// actions that are equal letter by letter, so a patched skill arrives twice:
/// once bare and once with the file it touched in brackets. The bare one says
/// nothing the other does not, and is dropped here.
final class ReviewSummary {
  const ReviewSummary._(this.heading, this.actions);

  factory ReviewSummary.parse(String text) {
    final trimmed = text.trim();
    var heading = '';
    var body = trimmed;
    final colon = trimmed.indexOf(': ');
    if (colon > 0 && !trimmed.substring(0, colon).contains(_separator)) {
      heading = trimmed.substring(0, colon).trim();
      body = trimmed.substring(colon + 2);
    }
    final parts = <String>[];
    for (final raw in body.split(_separator)) {
      final part = raw.trim();
      if (part.isNotEmpty && !parts.contains(part)) parts.add(part);
    }
    final actions = [
      for (final part in parts)
        if (!parts.any((other) => _saysMore(other, part))) part,
    ];
    return ReviewSummary._(heading, List.unmodifiable(actions));
  }

  static const _separator = ' · ';

  /// Whether [other] is [part] plus a bracketed detail.
  static bool _saysMore(String other, String part) =>
      other.length > part.length &&
      other.startsWith(part) &&
      other.substring(part.length).startsWith(' (');

  /// Hermes' own heading («Self-improvement review»), or empty.
  final String heading;

  /// Each thing the review did, once.
  final List<String> actions;

  /// The whole notice on one line, without repeats.
  String get line {
    final body = actions.join(_separator);
    if (heading.isEmpty) return body;
    return body.isEmpty ? heading : '$heading: $body';
  }
}

/// The review's notice in the transcript: the same quiet receipt as the
/// memory one, on a single line. A tap opens everything it says; a long
/// press copies the line as Hermes sent it.
class ReviewNoticeRow extends StatelessWidget {
  const ReviewNoticeRow({required this.text, super.key});

  /// The notice as Hermes sent it, without its leading glyph.
  final String text;

  @override
  Widget build(BuildContext context) {
    final summary = ReviewSummary.parse(text);
    void open() => showHermesSurface<void>(
      context: context,
      surfaceKey: const ValueKey('review-notice-detail'),
      maxWidth: 560,
      builder: (context) => _ReviewDetail(summary: summary),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: HermesSpace.x3,
        vertical: 2,
      ),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onLongPress: () {
          Clipboard.setData(ClipboardData(text: text));
          HermesNotice.of(context).showSnackBar(
            SnackBar(
              content: Text(Strings.of(context).chaCopied),
              duration: const Duration(seconds: 1),
            ),
            kind: HermesNoticeKind.success,
          );
        },
        child: TurnReceiptPill(
          inkKey: const ValueKey('review-notice-pill'),
          icon: HIcons.auto_awesome_rounded,
          label: summary.line,
          onTap: open,
          singleLine: true,
        ),
      ),
    );
  }
}

class _ReviewDetail extends StatelessWidget {
  const _ReviewDetail({required this.summary});
  final ReviewSummary summary;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(HermesSpace.x4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      summary.heading,
                      style: HermesType.title.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(HIcons.close_rounded, size: HermesIcon.lg),
                ),
              ],
            ),
            for (final (index, action) in summary.actions.indexed)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: HermesSpace.x2),
                child: SelectableText(
                  action,
                  key: ValueKey(('review-notice-action', index)),
                  style: HermesType.text.copyWith(color: colors.textPrimary),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
