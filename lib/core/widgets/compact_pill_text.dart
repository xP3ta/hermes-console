import 'package:flutter/material.dart';

/// Keeps the full description accessible when an aggregate needs shorter copy.
class CompactPillText extends StatelessWidget {
  const CompactPillText({
    required this.label,
    required this.compactLabel,
    required this.style,
    super.key,
  });

  final String label;
  final String compactLabel;
  final TextStyle style;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final painter = TextPainter(
        text: TextSpan(
          text: label,
          style: DefaultTextStyle.of(context).style.merge(style),
        ),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout(maxWidth: constraints.maxWidth);
      final fits = !painter.didExceedMaxLines;
      painter.dispose();
      return Text(
        fits ? label : compactLabel,
        semanticsLabel: label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style,
      );
    },
  );
}
