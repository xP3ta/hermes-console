import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../design/modal.dart' show releaseTextFocusIfKeyboardHidden;
import '../../design/tokens.dart';
import '../../models/message_reaction.dart';
import '../../theme/app_theme.dart';
import '../../theme/motion.dart' show CoveredRouteMediaQueryFreeze, RouteCurves;

/// Hands the long-press message surface (quick reactions on top of the
/// message actions) to every [ChatMessageSelectionArea] of one message.
/// Chats with a durable row id get the reactions row; rooms get the same
/// panel without it (Copy, Reply, Select text). Absent, a long-press keeps
/// the plain selection toolbar.
class MessageQuickReactScope extends InheritedWidget {
  const MessageQuickReactScope({
    super.key,
    this.onReact,
    this.selected,
    this.copyText,
    this.onReply,
    this.replyLabel,
    required super.child,
  });

  /// Called with the picked emoji; the owner's current emoji again
  /// retracts it (Tapback), which the server resolves. Null: the panel has
  /// no reactions row (rooms).
  final ValueChanged<String>? onReact;

  /// The owner's current reaction on this message, shown as picked.
  final String? selected;

  /// Plain text of the whole message for «Copy message»; evaluated only
  /// when chosen. Null hides the action.
  final String Function()? copyText;

  /// «Reply» on the surface; null hides it.
  final VoidCallback? onReply;

  /// Label of the reply action (e.g. «Reply to @builder»).
  final String? replyLabel;

  static MessageQuickReactScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MessageQuickReactScope>();

  @override
  bool updateShouldNotify(MessageQuickReactScope oldWidget) =>
      oldWidget.selected != selected ||
      oldWidget.onReact != onReact ||
      oldWidget.copyText != copyText ||
      oldWidget.onReply != onReply ||
      oldWidget.replyLabel != replyLabel;
}

/// The six quick reactions in one soft pill.
class QuickReactionBar extends StatelessWidget {
  const QuickReactionBar({super.key, required this.onPick, this.selected});

  final ValueChanged<String> onPick;
  final String? selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      key: const ValueKey('quick-reaction-bar'),
      color: scheme.surfaceContainerHigh,
      shape: StadiumBorder(
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final emoji in kQuickReactions)
              Semantics(
                button: true,
                selected: emoji == selected,
                label: emoji,
                child: InkWell(
                  key: ValueKey('quick-reaction-$emoji'),
                  customBorder: const CircleBorder(),
                  onTap: () => onPick(emoji),
                  child: Container(
                    width: 40,
                    height: 40,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: emoji == selected
                          ? scheme.primaryContainer.withValues(alpha: 0.7)
                          : null,
                    ),
                    child: Text(emoji, style: const TextStyle(fontSize: 22)),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// What the owner chose on the long-press surface.
sealed class MessageActionChoice {
  const MessageActionChoice();
}

/// A quick reaction.
final class MessageReactChoice extends MessageActionChoice {
  const MessageReactChoice(this.emoji);
  final String emoji;
}

/// «Copy message», «Reply» or «Select text».
enum MessageActionKind { copy, reply, select }

final class MessageActionKindChoice extends MessageActionChoice {
  const MessageActionKindChoice(this.kind);
  final MessageActionKind kind;
}

/// Long-press surface of one message: the six quick reactions on top of the
/// message actions, as one floating card group (iMessage/Telegram). It sits
/// above the pressed message, or below it when there is no room on top, so
/// the message stays readable; the rest of the screen is dimmed around it.
/// Resolves to the choice, or null when dismissed.
Future<MessageActionChoice?> showMessageActions({
  required BuildContext context,
  required Rect message,
  required Offset press,
  required MessageQuickReactScope scope,
}) {
  final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
  releaseTextFocusIfKeyboardHidden(context);
  final s = Strings.of(context);
  return Navigator.of(context).push<MessageActionChoice>(
    PageRouteBuilder<MessageActionChoice>(
      opaque: false,
      barrierDismissible: true,
      barrierColor: Colors.transparent,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      transitionDuration: reduceMotion
          ? Duration.zero
          : const Duration(milliseconds: 160),
      reverseTransitionDuration: reduceMotion
          ? Duration.zero
          : const Duration(milliseconds: 120),
      pageBuilder: (context, animation, secondaryAnimation) =>
          CoveredRouteMediaQueryFreeze(
            child: Stack(
              children: [
                // Dim everything but the pressed message; taps on the dim
                // area reach the route barrier and close the surface.
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(painter: _ScrimWithHole(message)),
                  ),
                ),
                Positioned.fill(
                  child: CustomSingleChildLayout(
                    delegate: MessageActionsLayout(
                      message: message,
                      press: press,
                      padding: MediaQuery.paddingOf(context),
                      keyboard: MediaQuery.viewInsetsOf(context).bottom,
                    ),
                    child: _MessageActionsSurface(
                      scope: scope,
                      alignEnd:
                          message.center.dx >
                          MediaQuery.sizeOf(context).width / 2,
                      strings: s,
                    ),
                  ),
                ),
              ],
            ),
          ),
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        if (reduceMotion) return child;
        return RouteCurves(
          animation: animation,
          builder: (context, curved, child) =>
              FadeTransition(opacity: curved, child: child),
          child: child,
        );
      },
    ),
  );
}

class _MessageActionsSurface extends StatelessWidget {
  const _MessageActionsSurface({
    required this.scope,
    required this.alignEnd,
    required this.strings,
  });

  final MessageQuickReactScope scope;
  final bool alignEnd;
  final Strings strings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = theme.hermes;
    void choose(MessageActionChoice choice) =>
        Navigator.of(context).pop(choice);
    Widget action(MessageActionKind kind, IconData icon, String label) =>
        InkWell(
          key: ValueKey('message-action-${kind.name}'),
          onTap: () => choose(MessageActionKindChoice(kind)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 46),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Icon(icon, size: 19, color: colors.textSecondary),
                  const SizedBox(width: 12),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HermesType.body.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
    final reply = scope.onReply;
    return Column(
      key: const ValueKey('message-actions-surface'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: alignEnd
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        if (scope.onReact != null) ...[
          QuickReactionBar(
            selected: scope.selected,
            onPick: (emoji) => choose(MessageReactChoice(emoji)),
          ),
          const SizedBox(height: 8),
        ],
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 200, maxWidth: 260),
          child: Material(
            color: scheme.surfaceContainerHigh,
            surfaceTintColor: Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(HermesRadius.group + 2),
              side: BorderSide(
                color: scheme.outlineVariant.withValues(alpha: 0.6),
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: IntrinsicWidth(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (scope.copyText != null)
                      action(
                        MessageActionKind.copy,
                        Icons.copy_rounded,
                        strings.chaCopyMessage,
                      ),
                    if (reply != null)
                      action(
                        MessageActionKind.reply,
                        Icons.reply_rounded,
                        scope.replyLabel ?? strings.roomReplyInThread,
                      ),
                    action(
                      MessageActionKind.select,
                      Icons.text_fields_rounded,
                      strings.chaSelectText,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Places the surface above the pressed [message], else below it, else (a
/// message taller than the screen) next to the [press] point; always inside
/// the safe area and above the keyboard, aligned with the message's side.
@visibleForTesting
class MessageActionsLayout extends SingleChildLayoutDelegate {
  MessageActionsLayout({
    required this.message,
    required this.press,
    required this.padding,
    this.keyboard = 0,
  });

  final Rect message;
  final Offset press;
  final EdgeInsets padding;
  final double keyboard;

  static const double gap = 8;
  static const double margin = 8;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final maxX = math.max(margin, size.width - childSize.width - margin);
    final alignEnd = message.center.dx > size.width / 2;
    final x = (alignEnd ? message.right - childSize.width : message.left).clamp(
      margin,
      maxX,
    );
    final top = padding.top + margin;
    final bottom = size.height - math.max(padding.bottom, keyboard) - margin;
    final maxY = math.max(top, bottom - childSize.height);
    final above = message.top - gap - childSize.height;
    final below = message.bottom + gap;
    double y;
    if (above >= top) {
      y = above;
    } else if (below + childSize.height <= bottom) {
      y = below;
    } else {
      // Taller than the free space on either side: stay by the finger.
      final overPress = press.dy - gap - childSize.height;
      y = overPress >= top ? overPress : press.dy + gap;
    }
    return Offset(x, y.clamp(top, maxY));
  }

  @override
  bool shouldRelayout(MessageActionsLayout old) =>
      old.message != message ||
      old.press != press ||
      old.padding != padding ||
      old.keyboard != keyboard;
}

/// Soft scrim around the pressed message; the message itself stays clear.
class _ScrimWithHole extends CustomPainter {
  _ScrimWithHole(this.hole);

  final Rect hole;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRRect(
        RRect.fromRectAndRadius(
          hole.inflate(2),
          const Radius.circular(HermesRadius.group),
        ),
      );
    canvas.drawPath(
      path,
      Paint()..color = Colors.black.withValues(alpha: 0.32),
    );
  }

  @override
  bool shouldRepaint(_ScrimWithHole old) => old.hole != hole;
}
