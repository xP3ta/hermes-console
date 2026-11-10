import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/hermes_tokens.dart';
import 'voice_capsule.dart'
    show voiceCapsuleWaveColor, voiceCapsuleWaveLevel, voiceCapsuleWaveMode;
import 'voice_strip.dart';
import 'voice_wave.dart';

/// The composer as the voice dock (voz inline): in the composer field's own
/// footprint and material, left to right, the microphone's mute (pause ↔
/// resume), a live wave and ✕ that ends the conversation.
///
/// When the state has an action of its own, a short chip stands in the
/// middle of the wave: «Enviar ya» while an engine waits to be told the
/// user is done, «Interrumpir» while Hermes speaks, «Reintentar» after a
/// failure, «Revisar» while an approval waits. Which state offers which
/// action is [VoiceStripStateRules]'s, as for the voice line. Otherwise,
/// while the chat has work to stop, the chip is the conversation's one
/// Stop ([onStop]): the composer's own Stop is under the dock.
///
/// Nothing in it moves between states: the three slots keep their place and
/// only their contents change (a 250 ms cross-fade, cut with reduce motion).
/// The wave repaints its own layer; a level tick rebuilds nothing. A tap on
/// the wave ([onType]) brings the keyboard back for typing.
/// The dock's words, localized by the host.
@immutable
class VoiceDockLabels {
  const VoiceDockLabels({
    required this.pause,
    required this.resume,
    required this.close,
    required this.sendNow,
    required this.interrupt,
    required this.retry,
    required this.review,
    required this.type,
    this.stop = '',
  });

  final String pause;
  final String resume;
  final String close;

  /// «Enviar ya».
  final String sendNow;

  /// «Interrumpir».
  final String interrupt;
  final String retry;

  /// «Revisar».
  final String review;

  /// What a tap on the wave does, for TalkBack.
  final String type;

  /// The Stop chip's word («Detener»), whatever it stops.
  final String stop;
}

class VoiceDock extends StatelessWidget {
  const VoiceDock({
    required this.state,
    required this.labels,
    required this.onClose,
    this.micLevel,
    this.speechLevel,
    this.onPause,
    this.onResume,
    this.onFinishListening,
    this.onStopAndTalk,
    this.onRetry,
    this.onReview,
    this.onStop,
    this.onType,
    this.reduceMotion = false,
    super.key,
  });

  final VoiceStripState state;
  final VoiceDockLabels labels;
  final VoidCallback onClose;
  final ValueListenable<double>? micLevel;
  final ValueListenable<double>? speechLevel;
  final VoidCallback? onPause;
  final VoidCallback? onResume;
  final VoidCallback? onFinishListening;
  final VoidCallback? onStopAndTalk;
  final VoidCallback? onRetry;
  final VoidCallback? onReview;

  /// Stops the chat's work (or cancels the voice turn); null when there is
  /// nothing to stop.
  final VoidCallback? onStop;
  final VoidCallback? onType;
  final bool reduceMotion;

  /// Smallest touch target of a dock control.
  static const double target = 48;

  /// The swap between two states' contents.
  static const Duration swap = HermesMotion.voiceSwap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final duration = reduceMotion ? Duration.zero : swap;
    final chip = _chip(colors);
    final wave = voiceCapsuleWaveMode(state);
    final resume = state == VoiceStripState.paused ? onResume : null;
    final pause = resume == null && state.timed ? onPause : null;
    return Material(
      key: const ValueKey('voice-dock'),
      type: MaterialType.transparency,
      child: Row(
        children: [
          _DockRound(
            actionKey: resume != null
                ? 'voice-strip-resume'
                : pause != null
                ? 'voice-strip-pause'
                : 'voice-dock-mute',
            icon: resume != null || state == VoiceStripState.paused
                ? Icons.mic_off_rounded
                : Icons.mic_rounded,
            label: resume != null ? labels.resume : labels.pause,
            onPressed: resume ?? pause,
            foreground: colors.textPrimary,
            background: colors.textPrimary.withValues(alpha: 0.08),
            duration: duration,
          ),
          Expanded(
            child: Stack(
              alignment: Alignment.center,
              children: [
                Semantics(
                  container: true,
                  button: onType != null,
                  label: labels.type,
                  onTap: onType,
                  excludeSemantics: true,
                  child: GestureDetector(
                    key: const ValueKey('voice-dock-wave'),
                    behavior: HitTestBehavior.opaque,
                    onTap: onType,
                    child: SizedBox(
                      height: target,
                      child: AnimatedOpacity(
                        opacity: chip == null ? 1 : 0.25,
                        duration: duration,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: HermesSpace.x2,
                          ),
                          child: VoiceWave(
                            mode: reduceMotion ? VoiceWaveMode.rest : wave,
                            level: voiceCapsuleWaveLevel(
                              wave,
                              micLevel: micLevel,
                              speechLevel: speechLevel,
                            ),
                            color: voiceCapsuleWaveColor(colors, state),
                            height: 28,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                AnimatedSwitcher(
                  duration: duration,
                  child:
                      chip ??
                      const SizedBox.shrink(
                        key: ValueKey('voice-dock-no-chip'),
                      ),
                ),
              ],
            ),
          ),
          _DockRound(
            actionKey: 'voice-strip-close',
            icon: Icons.close_rounded,
            label: labels.close,
            onPressed: onClose,
            foreground: colors.textPrimary,
            background: colors.error.withValues(alpha: 0.14),
            duration: duration,
          ),
        ],
      ),
    );
  }

  /// The one action the current state is about, as a chip, or none.
  Widget? _chip(HermesThemeColors colors) {
    if (state.canFinishListening && onFinishListening != null) {
      return _DockChip(
        key: const ValueKey('voice-strip-finish-listening'),
        icon: Icons.arrow_upward_rounded,
        label: labels.sendNow,
        onPressed: onFinishListening!,
        tint: colors.accent,
      );
    }
    if (state.offersRetry && onRetry != null) {
      return _DockChip(
        key: const ValueKey('voice-strip-retry'),
        icon: Icons.refresh_rounded,
        label: labels.retry,
        onPressed: onRetry!,
        tint: colors.error,
      );
    }
    if (state.offersReview && onReview != null) {
      return _DockChip(
        key: const ValueKey('voice-strip-review'),
        icon: Icons.shield_outlined,
        label: labels.review,
        onPressed: onReview!,
        tint: colors.warning,
      );
    }
    if (state.dockInterrupts && onStopAndTalk != null) {
      return _DockChip(
        key: const ValueKey('voice-strip-stop-and-talk'),
        icon: Icons.mic_rounded,
        label: labels.interrupt,
        onPressed: onStopAndTalk!,
        tint: colors.accent,
      );
    }
    if (onStop != null) {
      return _DockChip(
        key: const ValueKey('voice-dock-stop'),
        icon: Icons.stop_rounded,
        label: labels.stop,
        onPressed: onStop!,
        tint: colors.error,
      );
    }
    return null;
  }
}

/// A round control of the dock with a full touch target. Disabled (no
/// [onPressed]) it keeps its place, dimmed.
class _DockRound extends StatelessWidget {
  const _DockRound({
    required this.actionKey,
    required this.icon,
    required this.label,
    required this.onPressed,
    required this.foreground,
    required this.background,
    required this.duration,
  });

  final String actionKey;
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final Color foreground;
  final Color background;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      onTap: onPressed,
      excludeSemantics: true,
      child: Tooltip(
        message: label,
        child: InkWell(
          key: ValueKey(actionKey),
          onTap: onPressed,
          customBorder: const CircleBorder(),
          child: SizedBox.square(
            dimension: VoiceDock.target,
            child: Center(
              child: Ink(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: background,
                  shape: BoxShape.circle,
                ),
                child: AnimatedSwitcher(
                  duration: duration,
                  child: Icon(
                    icon,
                    key: ValueKey(icon),
                    size: 20,
                    color: enabled
                        ? foreground
                        : foreground.withValues(alpha: 0.38),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The state's action in the middle of the wave: a short pill, 48 dp tall
/// to the touch, its word cut with «…» rather than pushing the round
/// buttons.
class _DockChip extends StatelessWidget {
  const _DockChip({
    required this.icon,
    required this.label,
    required this.onPressed,
    required this.tint,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Semantics(
      button: true,
      label: label,
      onTap: onPressed,
      excludeSemantics: true,
      child: InkWell(
        onTap: onPressed,
        customBorder: const StadiumBorder(),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: VoiceDock.target),
          child: Center(
            widthFactor: 1,
            child: Ink(
              padding: const EdgeInsets.symmetric(
                horizontal: HermesSpace.x3,
                vertical: HermesSpace.x1,
              ),
              decoration: ShapeDecoration(
                color: tint.withValues(alpha: 0.16),
                shape: const StadiumBorder(),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 18, color: tint),
                  const SizedBox(width: HermesSpace.x1),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HermesType.value.copyWith(
                        color: colors.textPrimary,
                        fontWeight: FontWeight.w600,
                        height: 1.2,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
