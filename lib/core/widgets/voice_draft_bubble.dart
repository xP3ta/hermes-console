// Voz inline (§5): what the user is saying, as a draft of their message at
// the bottom of the transcript.
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../services/voice/session/voice_ui_surface.dart';
import '../services/voice/voice_phase.dart';
import '../theme/app_theme.dart';
import '../theme/hermes_tokens.dart';

/// When the draft shows and with which words.
abstract final class VoiceDraft {
  /// The draft's words for [phase] and [partial]: null hides the draft, an
  /// empty string shows it with the listening tag only (a capture being
  /// transcribed by a host that streams no partials).
  ///
  /// Only while the user's turn is being captured: once it is sent (or
  /// Hermes answers, or the conversation pauses) the draft is gone, so the
  /// sent message never shows next to it.
  static String? textFor({
    required VoicePhase phase,
    required String partial,
    bool userPaused = false,
  }) {
    if (userPaused) return null;
    final text = partial.trim();
    return switch (phase) {
      VoicePhase.listening => text.isEmpty ? null : text,
      VoicePhase.transcribing => text,
      _ => null,
    };
  }
}

/// The draft itself: the user's bubble, translucent, with a thin border and
/// a small microphone tag, «Hablando…» over the words heard so far, or
/// «Escuchando…» alone before any.
///
/// Laid out as a user's message row (end side, the same insets and corner),
/// so the sent message lands where the draft was.
class VoiceDraftBubble extends StatelessWidget {
  const VoiceDraftBubble({
    required this.text,
    required this.speakingLabel,
    required this.listeningLabel,
    super.key,
  });

  final String text;
  final String speakingLabel;
  final String listeningLabel;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final tag = text.isEmpty ? listeningLabel : speakingLabel;
    // The insets of the user's message row (chat_screen `_UserMessage`),
    // as they are, also right to left: the message lands where this was.
    return Padding(
      padding: const EdgeInsets.only(
        left: 56,
        right: HermesSpace.x3,
        top: 11,
        bottom: 3,
      ),
      child: Align(
        alignment: AlignmentDirectional.centerEnd,
        child: Semantics(
          container: true,
          label: text.isEmpty ? tag : '$tag $text',
          excludeSemantics: true,
          child: Container(
            key: const ValueKey('voice-draft-bubble'),
            padding: const EdgeInsets.symmetric(
              horizontal: HermesSpace.x4,
              vertical: 11,
            ),
            decoration: BoxDecoration(
              color: colors.surfaceVariant.withValues(alpha: 0.3),
              border: Border.all(color: colors.accent.withValues(alpha: 0.45)),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.mic_rounded, size: 14, color: colors.accent),
                    const SizedBox(width: HermesSpace.x1),
                    Flexible(
                      child: Text(
                        tag,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: colors.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
                if (text.isNotEmpty) ...[
                  const SizedBox(height: HermesSpace.x1),
                  Text(
                    text,
                    style: TextStyle(
                      fontSize: HermesType.valueSize,
                      height: 1.35,
                      color: colors.textPrimary.withValues(alpha: 0.85),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The draft's place under the newest row of a chat in a voice
/// conversation. It listens to [voice] (and to its partials, which do not
/// rebuild the chat) and rebuilds only itself.
///
/// When the draft goes because the turn was sent, it is cut in the same
/// frame the message appears; when it goes because nothing was said, it
/// fades out.
class VoiceDraftSlot extends StatefulWidget {
  const VoiceDraftSlot({
    required this.voice,
    required this.speakingLabel,
    required this.listeningLabel,
    this.reduceMotion = false,
    super.key,
  });

  final VoiceUiSurface voice;
  final String speakingLabel;
  final String listeningLabel;
  final bool reduceMotion;

  static const Duration fade = HermesMotion.voiceFade;

  @override
  State<VoiceDraftSlot> createState() => _VoiceDraftSlotState();
}

class _VoiceDraftSlotState extends State<VoiceDraftSlot> {
  Listenable? _partials;
  String? _text;
  String? _fading;
  bool _syncScheduled = false;

  @override
  void initState() {
    super.initState();
    widget.voice.addListener(_onVoice);
    _listenToPartials();
    _text = _current();
  }

  @override
  void didUpdateWidget(VoiceDraftSlot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.voice, widget.voice)) {
      oldWidget.voice.removeListener(_onVoice);
      _partials?.removeListener(_onVoice);
      _partials = null;
      widget.voice.addListener(_onVoice);
      _listenToPartials();
      _text = _current();
      _fading = null;
    }
  }

  @override
  void dispose() {
    widget.voice.removeListener(_onVoice);
    _partials?.removeListener(_onVoice);
    super.dispose();
  }

  void _listenToPartials() {
    final next = widget.voice.partialTranscriptChanges;
    if (identical(next, _partials)) return;
    _partials?.removeListener(_onVoice);
    _partials = null;
    // The surface itself is already listened to.
    if (identical(next, widget.voice)) return;
    _partials = next..addListener(_onVoice);
  }

  String? _current() {
    final voice = widget.voice;
    if (!voice.active) return null;
    return VoiceDraft.textFor(
      phase: voice.phase,
      partial: voice.partialTranscript,
      userPaused: voice.userPaused,
    );
  }

  void _onVoice() {
    if (!mounted) return;
    _listenToPartials();
    // Never a rebuild inside the chat's own build or layout.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (_syncScheduled) return;
      _syncScheduled = true;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _syncScheduled = false;
        _sync();
      });
      return;
    }
    _sync();
  }

  void _sync() {
    if (!mounted) return;
    final next = _current();
    final voice = widget.voice;
    // Privacy hid the voice: its phase is idle, but that is not «nothing
    // was said». No words stay on screen, not even fading.
    final hidden = voice.privacyHidden;
    if (next == _text && !(hidden && _fading != null)) return;
    // Gone with no words kept: nothing was said, the draft fades. A sent
    // turn keeps its words (the message takes the draft's place at once).
    final fades =
        !hidden &&
        next == null &&
        _text != null &&
        voice.active &&
        voice.partialTranscript.trim().isEmpty &&
        !widget.reduceMotion;
    setState(() {
      _fading = fades ? _text : null;
      _text = next;
    });
  }

  @override
  Widget build(BuildContext context) {
    final text = _text;
    if (text != null) {
      return VoiceDraftBubble(
        text: text,
        speakingLabel: widget.speakingLabel,
        listeningLabel: widget.listeningLabel,
      );
    }
    final fading = _fading;
    if (fading == null) return const SizedBox.shrink();
    return TweenAnimationBuilder<double>(
      key: ValueKey(('voice-draft-fade', fading)),
      tween: Tween(begin: 1, end: 0),
      duration: VoiceDraftSlot.fade,
      onEnd: () {
        if (mounted) setState(() => _fading = null);
      },
      builder: (context, opacity, child) =>
          Opacity(opacity: opacity, child: child),
      child: ExcludeSemantics(
        child: VoiceDraftBubble(
          text: fading,
          speakingLabel: widget.speakingLabel,
          listeningLabel: widget.listeningLabel,
        ),
      ),
    );
  }
}
