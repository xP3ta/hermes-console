// The notch at the bottom of a full-screen tool opened from a chat (the
// in-app browser, Files): a tap, or a drag up like the chat notch's own
// gesture, goes back to the conversation, whose notch opens the sheet
// again. Same grabber as the chat's. Extracted from the browser (F3) so
// every tool returns to the chat the same way.
import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import 'chat_notch.dart'
    show
        kChatNotchGrabberHeight,
        kChatNotchGrabberWidth,
        kChatNotchSlotHeight,
        kChatNotchTargetWidth;

class BackToChatNotch extends StatelessWidget {
  const BackToChatNotch({
    required this.label,
    required this.onTap,
    this.notchKey = const ValueKey('back-to-chat-notch'),
    super.key,
  });

  /// Spoken label, e.g. «Volver al chat».
  final String label;
  final VoidCallback onTap;

  /// Key of the touch target (the browser keeps 'in-app-browser-notch').
  final Key notchKey;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Center(
      child: Semantics(
        container: true,
        button: true,
        label: label,
        onTap: onTap,
        child: GestureDetector(
          key: notchKey,
          behavior: HitTestBehavior.opaque,
          excludeFromSemantics: true,
          onTap: onTap,
          onVerticalDragEnd: (details) {
            if ((details.primaryVelocity ?? 0) < 0) onTap();
          },
          child: SizedBox(
            width: kChatNotchTargetWidth,
            height: kChatNotchSlotHeight,
            child: Center(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.textSecondary.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(kChatNotchGrabberHeight),
                ),
                child: const SizedBox(
                  width: kChatNotchGrabberWidth,
                  height: kChatNotchGrabberHeight,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
