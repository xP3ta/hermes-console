import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// rp1215: "… is replying" under the assistant's name while a turn runs and
/// no answer text has arrived yet: three dots and one short line. It names
/// WHO is answering and nothing else; what the turn is doing (tool, timer,
/// tasks) stays in the activity pill above the composer.
///
/// The dots pulse through a wave; with reduced motion they hold still. A
/// finite wave deliberately lets a transcript settle after the indicator has
/// appeared (important for a live row that can stay visible while a tool
/// runs). Only the dots repaint (own [RepaintBoundary]), so the transcript
/// does not.
class ChatReplyingIndicator extends StatefulWidget {
  const ChatReplyingIndicator({
    super.key,
    required this.label,
    required this.semanticsLabel,
    this.labelKey,
  });

  /// Visible line, e.g. «está respondiendo…».
  final String label;

  /// Full sentence for screen readers, e.g. «Hermes está respondiendo».
  final String semanticsLabel;

  /// Key of the label [Text] (kept stable for callers that find it).
  final Key? labelKey;

  static const double dotSize = 5;

  @override
  State<ChatReplyingIndicator> createState() => _ChatReplyingIndicatorState();
}

class _ChatReplyingIndicatorState extends State<ChatReplyingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _wave = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  bool _still = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (_still) {
      _wave.stop();
    } else if (!_wave.isAnimating && _wave.value == 0) {
      _wave.forward();
    }
  }

  @override
  void dispose() {
    _wave.dispose();
    super.dispose();
  }

  /// Opacity of dot [index] at wave phase [t] (0..1): each dot peaks a
  /// third of a cycle after the previous one.
  static double _opacity(int index, double t) {
    final phase = (t - index / 3) % 1.0;
    final peak = phase < 0.5 ? phase * 2 : (1 - phase) * 2;
    return 0.3 + 0.7 * peak;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    Widget dot(int index, double t) => Padding(
      padding: const EdgeInsets.only(right: 3),
      child: Opacity(
        opacity: _still ? 0.7 : _opacity(index, t),
        child: SizedBox.square(
          dimension: ChatReplyingIndicator.dotSize,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.accent,
              shape: BoxShape.circle,
            ),
          ),
        ),
      ),
    );
    return Semantics(
      liveRegion: true,
      label: widget.semanticsLabel,
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          RepaintBoundary(
            child: AnimatedBuilder(
              animation: _wave,
              builder: (context, _) => Row(
                mainAxisSize: MainAxisSize.min,
                children: [for (var i = 0; i < 3; i++) dot(i, _wave.value)],
              ),
            ),
          ),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              widget.label,
              key: widget.labelKey,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: colors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

/// rp1215: the accent edge on the left of the user bubble being answered
/// while other messages wait behind it. Painted over the bubble (clipped to
/// its rounded shape), so marking or unmarking never changes the layout.
class UserBubbleAccentEdgePainter extends CustomPainter {
  const UserBubbleAccentEdgePainter(this.color, {this.radius = 20});

  final Color color;
  final double radius;

  static const double width = 3;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final shape = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );
    canvas
      ..save()
      ..clipRRect(shape)
      ..drawRect(
        Rect.fromLTWH(0, 0, width, size.height),
        Paint()..color = color,
      )
      ..restore();
  }

  @override
  bool shouldRepaint(UserBubbleAccentEdgePainter old) =>
      old.color != color || old.radius != radius;
}
