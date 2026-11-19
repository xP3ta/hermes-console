import 'package:hermes_android/core/design/hicons.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../services/voice/read_aloud_session.dart';
import '../services/voice/voice_settings.dart';
import '../theme/app_theme.dart';

enum ReadAloudButtonAction { read, pause, resume, stop }

class ReadAloudButton extends StatelessWidget {
  final String messageKey;
  final ValueListenable<ReadAloudSnapshot>? state;
  final ReadAloudStopBehavior stopBehavior;
  final VoidCallback? onPressed;

  const ReadAloudButton({
    super.key,
    required this.messageKey,
    required this.state,
    required this.stopBehavior,
    required this.onPressed,
  });

  static ReadAloudButtonAction actionFor(
    ReadAloudSnapshot snapshot,
    String messageKey,
    ReadAloudStopBehavior stopBehavior,
  ) {
    if (!snapshot.owns(messageKey)) return ReadAloudButtonAction.read;
    if (snapshot.isResumable) return ReadAloudButtonAction.resume;
    if (snapshot.isActive) {
      return stopBehavior == ReadAloudStopBehavior.pauseAndResume
          ? ReadAloudButtonAction.pause
          : ReadAloudButtonAction.stop;
    }
    return ReadAloudButtonAction.read;
  }

  @override
  Widget build(BuildContext context) {
    final listenable = state;
    if (listenable == null) {
      return _buildButton(context, const ReadAloudSnapshot.idle());
    }
    return ValueListenableBuilder<ReadAloudSnapshot>(
      valueListenable: listenable,
      builder: (context, snapshot, _) => _buildButton(context, snapshot),
    );
  }

  Widget _buildButton(BuildContext context, ReadAloudSnapshot snapshot) {
    final action = actionFor(snapshot, messageKey, stopBehavior);
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final (label, icon) = switch (action) {
      ReadAloudButtonAction.read => (
        strings.chaReadAloud,
        HIcons.volume_up_outlined,
      ),
      ReadAloudButtonAction.pause => (
        strings.chaPauseReading,
        HIcons.pause_circle_outline_rounded,
      ),
      ReadAloudButtonAction.resume => (
        strings.chaContinueReading,
        HIcons.play_circle_outline_rounded,
      ),
      ReadAloudButtonAction.stop => (
        strings.chaStopReading,
        HIcons.stop_circle_outlined,
      ),
    };
    final emphasized = action != ReadAloudButtonAction.read;
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: Tooltip(
        message: label,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(24),
          child: SizedBox(
            width: 48,
            height: 48,
            child: Center(
              child: Icon(
                icon,
                size: 17,
                color: emphasized ? colors.accent : colors.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
