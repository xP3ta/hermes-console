import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'voice_meter.dart';

/// What the voice surface shows. A projection of the voice controller's phase;
/// it is not a second conversation state machine.
enum VoiceStripState {
  loading,
  listening,
  transcribing,
  thinking,
  toolCall,
  speaking,
  waiting,
  paused,
  error,
}

/// Which controls a state offers. The status line and the composer's controls
/// read the same rules, so an action is never offered twice or lost.
extension VoiceStripStateRules on VoiceStripState {
  /// States the clock times, like Desktop's dictation timer. They are also
  /// the ones that can be paused.
  bool get timed => switch (this) {
    VoiceStripState.listening ||
    VoiceStripState.transcribing ||
    VoiceStripState.thinking ||
    VoiceStripState.toolCall ||
    VoiceStripState.speaking => true,
    _ => false,
  };

  bool get canStopAndTalk => switch (this) {
    VoiceStripState.thinking ||
    VoiceStripState.toolCall ||
    VoiceStripState.speaking => true,
    _ => false,
  };

  /// A turn can only be cancelled from a state that belongs to one.
  bool get canCancelTurn => switch (this) {
    VoiceStripState.transcribing ||
    VoiceStripState.thinking ||
    VoiceStripState.toolCall ||
    VoiceStripState.speaking => true,
    _ => false,
  };
}

@immutable
class VoiceStripLabels {
  final String finishListening;
  final String pause;
  final String resume;
  final String stopAndTalk;
  final String cancel;

  /// The composer's own stop, when the conversation's controls carry it.
  final String stop;
  final String retry;
  final String review;

  /// Name of the end control for assistive technology ("End voice mode").
  final String close;

  /// The word written on the end pill ("End").
  final String end;

  const VoiceStripLabels({
    required this.finishListening,
    required this.pause,
    required this.resume,
    required this.stopAndTalk,
    required this.cancel,
    required this.stop,
    required this.retry,
    required this.review,
    required this.close,
    required this.end,
  });
}

/// Smallest touch target of a voice control.
const double _kTarget = 48;

TextPainter _painter(
  BuildContext context,
  String text,
  TextStyle style,
  int maxLines,
) => TextPainter(
  text: TextSpan(
    text: text,
    style: DefaultTextStyle.of(context).style.merge(style),
  ),
  textDirection: Directionality.of(context),
  textScaler: MediaQuery.textScalerOf(context),
  maxLines: maxLines,
);

/// Width of [text] on one line, as [context] draws it.
double _textWidth(BuildContext context, String text, TextStyle style) {
  final painter = _painter(context, text, style, 1)..layout();
  final width = painter.width;
  painter.dispose();
  return width.ceilToDouble();
}

/// Whether [text] fits [width] in at most [maxLines] lines.
bool _textFits(
  BuildContext context,
  String text,
  TextStyle style,
  double width,
  int maxLines,
) {
  if (width <= 0) return false;
  final painter = _painter(context, text, style, maxLines)
    ..layout(maxWidth: width);
  final fits = !painter.didExceedMaxLines;
  painter.dispose();
  return fits;
}

/// Voice conversation inside the chat, as Hermes Desktop does it: the
/// transcript stays on screen and one thin line above the composer carries
/// the live state, with at most one action that belongs to that state. The
/// conversation controls live in the composer ([VoiceComposerControls]).
///
/// Only a projection of the voice controller: it owns no capture, playback,
/// transcript or conversation state.
class VoiceStatusLine extends StatefulWidget {
  final VoiceStripState state;

  /// The state in plain words. Assistive technology hears this line.
  final String statusLabel;

  /// What the engine is hearing right now, read while listening; empty or
  /// null keeps [statusLabel] on screen.
  final ValueGetter<String>? heard;
  final VoiceStripLabels labels;
  final VoidCallback? onResume;
  final VoidCallback? onStopAndTalk;
  final VoidCallback? onRetry;
  final VoidCallback? onReview;

  const VoiceStatusLine({
    required this.state,
    required this.statusLabel,
    required this.labels,
    this.heard,
    this.onResume,
    this.onStopAndTalk,
    this.onRetry,
    this.onReview,
    super.key,
  });

  @override
  State<VoiceStatusLine> createState() => _VoiceStatusLineState();
}

class _VoiceStatusLineState extends State<VoiceStatusLine> {
  /// An engine may publish what it hears without notifying its listeners, so
  /// the line reads it on its own while it listens.
  static const _heardPoll = Duration(milliseconds: 250);

  /// Room a status too long for the line keeps before the action shrinks.
  static const double _minStatusWidth = 72;
  static const double _leadingWidth = 8 + 24 + 9;

  Timer? _clockTicker;
  Timer? _heardTicker;
  int _elapsedSeconds = 0;
  String _heard = '';

  @override
  void initState() {
    super.initState();
    _restartClock();
    _syncHeard();
  }

  @override
  void didUpdateWidget(VoiceStatusLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The clock times the current state, like Desktop's dictation timer.
    if (oldWidget.state != widget.state) _restartClock();
    _syncHeard();
  }

  @override
  void dispose() {
    _clockTicker?.cancel();
    _heardTicker?.cancel();
    super.dispose();
  }

  void _restartClock() {
    _clockTicker?.cancel();
    _clockTicker = null;
    _elapsedSeconds = 0;
    if (!widget.state.timed) return;
    _clockTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _elapsedSeconds += 1);
    });
  }

  String _readHeard() =>
      (widget.heard?.call() ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();

  void _syncHeard() {
    if (widget.state != VoiceStripState.listening || widget.heard == null) {
      _heardTicker?.cancel();
      _heardTicker = null;
      _heard = '';
      return;
    }
    _heard = _readHeard();
    _heardTicker ??= Timer.periodic(_heardPoll, (_) {
      final heard = _readHeard();
      if (mounted && heard != _heard) setState(() => _heard = heard);
    });
  }

  String get _clock {
    final minutes = _elapsedSeconds ~/ 60;
    final seconds = (_elapsedSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  /// The one action the current state is really about, or none.
  _LineAction? _action(Color tone) {
    final w = widget;
    final state = w.state;
    if (state == VoiceStripState.error && w.onRetry != null) {
      return _LineAction(
        actionKey: 'voice-strip-retry',
        icon: Icons.refresh_rounded,
        label: w.labels.retry,
        onPressed: w.onRetry!,
        tint: tone,
      );
    }
    if (state == VoiceStripState.waiting && w.onReview != null) {
      return _LineAction(
        actionKey: 'voice-strip-review',
        icon: Icons.shield_outlined,
        label: w.labels.review,
        onPressed: w.onReview!,
        tint: tone,
      );
    }
    if ((state == VoiceStripState.paused || state == VoiceStripState.waiting) &&
        w.onResume != null) {
      return _LineAction(
        actionKey: 'voice-strip-resume',
        icon: Icons.play_arrow_rounded,
        label: w.labels.resume,
        onPressed: w.onResume!,
      );
    }
    if (state.canStopAndTalk && w.onStopAndTalk != null) {
      return _LineAction(
        actionKey: 'voice-strip-stop-and-talk',
        icon: Icons.mic_rounded,
        label: w.labels.stopAndTalk,
        onPressed: w.onStopAndTalk!,
        tint: tone,
      );
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final w = widget;
    final state = w.state;
    final listening = state == VoiceStripState.listening;
    final tone = switch (state) {
      VoiceStripState.error => colors.error,
      VoiceStripState.paused => colors.textSecondary,
      VoiceStripState.waiting => colors.warning,
      _ => colors.accent,
    };
    final surface = state == VoiceStripState.speaking
        ? Color.alphaBlend(
            colors.accent.withValues(alpha: 0.08),
            colors.surfaceVariant,
          )
        : colors.surfaceVariant;
    final border = switch (state) {
      VoiceStripState.speaking => colors.accent.withValues(alpha: 0.34),
      VoiceStripState.error => colors.error.withValues(alpha: 0.5),
      _ => colors.divider,
    };
    final clockStyle = TextStyle(
      color: colors.textSecondary,
      fontSize: 11.5,
      fontFamily: 'monospace',
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final statusStyle = TextStyle(
      color: state == VoiceStripState.paused
          ? colors.textSecondary
          : colors.textPrimary,
      fontSize: 13.5,
      height: 1.2,
      fontWeight: FontWeight.w500,
    );
    // A failure has to be readable in full; a phase is one short line.
    final statusLines = state == VoiceStripState.error ? 3 : 1;
    final action = _action(tone);
    final clock = state.timed ? _clock : null;
    final text = listening && _heard.isNotEmpty ? _heard : w.statusLabel;
    return Stack(
      children: [
        // The line is 40 dp thin; its row is 48 dp so the action keeps a
        // full touch target.
        Positioned.fill(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: DecoratedBox(
              key: const ValueKey('voice-strip'),
              decoration: BoxDecoration(
                color: surface.withValues(alpha: 0.92),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: border),
              ),
            ),
          ),
        ),
        // The action's ink and text style come from this Material, so what
        // is measured under it is what gets drawn.
        Material(
          type: MaterialType.transparency,
          child: LayoutBuilder(
            builder: (context, constraints) {
              // The status comes first. The action gives up its glyph to
              // let it be read whole; for a failure, which has to be read in
              // full, its name too. Assistive technology always has the name.
              var form = _LineActionForm.full;
              if (action != null && constraints.maxWidth.isFinite) {
                final label = _textWidth(
                  context,
                  action.label,
                  _LineAction.labelStyle,
                );
                final taken =
                    _leadingWidth +
                    (clock == null
                        ? 0
                        : 8 + _textWidth(context, clock, clockStyle));
                double room(_LineActionForm form) =>
                    constraints.maxWidth -
                    taken -
                    _LineAction.widthFor(form, label);
                final failure = state == VoiceStripState.error;
                form = _LineActionForm.values
                    .where((form) => failure || form != _LineActionForm.glyph)
                    .firstWhere(
                      (form) => _textFits(
                        context,
                        text,
                        statusStyle,
                        room(form),
                        statusLines,
                      ),
                      // Too long for the line whatever the action does: a
                      // failure gets all the room there is, any other
                      // status a readable start beside the named action.
                      orElse: () => failure
                          ? _LineActionForm.glyph
                          : _LineActionForm.values.firstWhere(
                              (form) => room(form) >= _minStatusWidth,
                              orElse: () => _LineActionForm.glyph,
                            ),
                    );
              }
              return ConstrainedBox(
                constraints: const BoxConstraints(minHeight: _kTarget),
                child: Row(
                  children: [
                    Expanded(
                      child: Semantics(
                        container: true,
                        liveRegion: true,
                        label: w.statusLabel,
                        child: ExcludeSemantics(
                          child: Row(
                            children: [
                              const SizedBox(width: 8),
                              _StateBadge(state: state, tone: tone),
                              const SizedBox(width: 9),
                              Expanded(
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 10,
                                  ),
                                  child: Text(
                                    text,
                                    key: const ValueKey('voice-strip-status'),
                                    maxLines: statusLines,
                                    overflow: TextOverflow.ellipsis,
                                    style: statusStyle,
                                  ),
                                ),
                              ),
                              if (clock != null) ...[
                                const SizedBox(width: 8),
                                Text(
                                  clock,
                                  key: const ValueKey('voice-strip-clock'),
                                  style: clockStyle,
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (action != null)
                      action.build(colors, form)
                    else
                      const SizedBox(width: 12),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// The round mark that says which state the conversation is in.
class _StateBadge extends StatelessWidget {
  final VoiceStripState state;
  final Color tone;

  const _StateBadge({required this.state, required this.tone});

  @override
  Widget build(BuildContext context) {
    final icon = switch (state) {
      VoiceStripState.listening => Icons.mic_rounded,
      VoiceStripState.speaking => Icons.volume_up_rounded,
      VoiceStripState.paused => Icons.pause_rounded,
      VoiceStripState.error => Icons.warning_amber_rounded,
      VoiceStripState.waiting => Icons.shield_outlined,
      VoiceStripState.loading ||
      VoiceStripState.transcribing ||
      VoiceStripState.thinking ||
      VoiceStripState.toolCall => null,
    };
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return Container(
      key: const ValueKey('voice-strip-badge'),
      width: 24,
      height: 24,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.16),
        shape: BoxShape.circle,
      ),
      child: icon != null
          ? Icon(icon, size: 14, color: tone)
          // Hermes is at work: the only state that moves on its own.
          : RepaintBoundary(
              child: SizedBox.square(
                dimension: 12,
                child: CircularProgressIndicator(
                  value: still ? 0.72 : null,
                  strokeWidth: 1.8,
                  color: tone,
                ),
              ),
            ),
    );
  }
}

/// How much of itself the status line's action shows: glyph and name, the
/// name alone, or the glyph alone.
enum _LineActionForm { full, word, glyph }

/// The single action of the status line: a small chip inside a full touch
/// target. Built under the line's Material.
class _LineAction {
  final String actionKey;
  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  /// Colour of a tinted chip; a neutral chip has none.
  final Color? tint;

  const _LineAction({
    required this.actionKey,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.tint,
  });

  static const labelStyle = TextStyle(
    fontSize: 12.5,
    height: 1.2,
    fontWeight: FontWeight.w600,
  );

  static const double _outer = 6;
  static const double _chipStart = 8;
  static const double _chipEnd = 11;
  static const double _iconSize = 14;
  static const double _iconGap = 6;

  /// Width of the action in [form] for a label [labelWidth] wide.
  static double widthFor(_LineActionForm form, double labelWidth) =>
      switch (form) {
        _LineActionForm.full =>
          2 * _outer +
              _chipStart +
              _iconSize +
              _iconGap +
              labelWidth +
              _chipEnd,
        _LineActionForm.word => 2 * _outer + 2 * _chipEnd + labelWidth,
        _LineActionForm.glyph => _kTarget,
      };

  Widget build(HermesThemeColors colors, _LineActionForm form) {
    final foreground = tint ?? colors.textPrimary;
    final background = (tint ?? colors.textPrimary).withValues(
      alpha: tint == null ? 0.08 : 0.2,
    );
    return Semantics(
      button: true,
      label: label,
      onTap: onPressed,
      excludeSemantics: true,
      child: Tooltip(
        message: label,
        child: InkWell(
          key: ValueKey(actionKey),
          onTap: onPressed,
          customBorder: const StadiumBorder(),
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minWidth: _kTarget,
              minHeight: _kTarget,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: _outer,
                vertical: 10,
              ),
              child: Center(
                widthFactor: 1,
                heightFactor: 1,
                child: Ink(
                  decoration: ShapeDecoration(
                    color: background,
                    shape: const StadiumBorder(),
                  ),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      minWidth: 28,
                      minHeight: 28,
                    ),
                    child: Padding(
                      padding: switch (form) {
                        _LineActionForm.full => const EdgeInsets.only(
                          left: _chipStart,
                          right: _chipEnd,
                        ),
                        _LineActionForm.word => const EdgeInsets.symmetric(
                          horizontal: _chipEnd,
                        ),
                        _LineActionForm.glyph => EdgeInsets.zero,
                      },
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (form != _LineActionForm.word)
                            Icon(icon, size: _iconSize, color: foreground),
                          if (form == _LineActionForm.full)
                            const SizedBox(width: _iconGap),
                          if (form != _LineActionForm.glyph)
                            Text(
                              label,
                              maxLines: 1,
                              softWrap: false,
                              style: labelStyle.copyWith(color: foreground),
                            ),
                        ],
                      ),
                    ),
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

/// The voice conversation's controls at the composer's trailing end, where
/// the start-voice button stands outside a conversation: pause, the one round
/// button the current state calls for (finish speaking, cancel the turn, or
/// the composer's own stop) and the pill that ends the conversation.
///
/// Like [VoiceStatusLine], only a projection of the voice controller.
class VoiceComposerControls extends StatelessWidget {
  final VoiceStripState state;
  final VoiceStripLabels labels;

  /// Width the controls may take: the end pill gives up its word before the
  /// composer's field runs out of room.
  final double maxWidth;

  /// Width that leaves the composer's field its hint whole: the pill keeps
  /// its bars only within it. Defaults to [maxWidth].
  final double? comfortWidth;
  final ValueListenable<double>? micLevel;
  final VoidCallback? onPause;
  final VoidCallback? onFinishListening;
  final VoidCallback? onCancel;

  /// The composer's own stop. It takes the round button's place while the
  /// conversation has neither to finish speaking nor a turn of its own to
  /// cancel, so the row never holds two stops.
  final VoidCallback? onStop;
  final VoidCallback? onClose;

  const VoiceComposerControls({
    required this.state,
    required this.labels,
    required this.maxWidth,
    this.comfortWidth,
    this.micLevel,
    this.onPause,
    this.onFinishListening,
    this.onCancel,
    this.onStop,
    this.onClose,
    super.key,
  });

  /// The least the controls take: pause, the round button and the end pill
  /// as a glyph.
  static const double minWidth = 3 * _kTarget;

  static const _endStyle = TextStyle(
    fontSize: 13,
    height: 1.2,
    fontWeight: FontWeight.w700,
  );

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final pause = state.timed && onPause != null;
    final finish =
        state == VoiceStripState.listening && onFinishListening != null;
    final cancel = state.canCancelTurn && onCancel != null;
    // The controls' ink and text style come from this Material, so what is
    // measured under it is what gets drawn.
    return Material(
      type: MaterialType.transparency,
      child: Builder(
        builder: (context) {
          // A live conversation moves between states with and without the
          // round button: the pill keeps one shape through them all.
          final reserved = state.timed ? 2 * _kTarget : 0.0;
          final word = _textWidth(context, labels.end, _endStyle);
          bool fits(_EndPillForm form, double width) =>
              _EndPill.widthFor(form, word) <= width - reserved;
          final form = fits(_EndPillForm.full, comfortWidth ?? maxWidth)
              ? _EndPillForm.full
              : fits(_EndPillForm.word, maxWidth)
              ? _EndPillForm.word
              : _EndPillForm.bars;
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (pause)
                _RoundControl(
                  actionKey: 'voice-strip-pause',
                  icon: Icons.pause_rounded,
                  label: labels.pause,
                  onPressed: onPause!,
                  foreground: colors.textPrimary,
                  iconSize: 20,
                ),
              if (finish)
                _RoundControl(
                  actionKey: 'voice-strip-finish-listening',
                  icon: Icons.arrow_upward_rounded,
                  label: labels.finishListening,
                  onPressed: onFinishListening!,
                  foreground: colors.accent,
                  background: colors.accent.withValues(alpha: 0.2),
                )
              else if (cancel)
                _RoundControl(
                  actionKey: 'voice-strip-cancel',
                  icon: Icons.stop_rounded,
                  label: labels.cancel,
                  onPressed: onCancel!,
                  foreground: colors.accent,
                  background: colors.accent.withValues(alpha: 0.2),
                )
              else if (onStop != null)
                _RoundControl(
                  actionKey: 'voice-strip-stop',
                  icon: Icons.stop_rounded,
                  label: labels.stop,
                  onPressed: onStop!,
                  foreground: colors.accent,
                  background: colors.accent.withValues(alpha: 0.2),
                ),
              if (onClose != null)
                _EndPill(
                  form: form,
                  word: labels.end,
                  label: labels.close,
                  style: _endStyle,
                  meter: switch (state) {
                    // The microphone is open in both: while the voice is
                    // prepared what it captures is kept for the recogniser,
                    // and the level is real.
                    VoiceStripState.listening ||
                    VoiceStripState.loading => VoiceMeterMode.level,
                    VoiceStripState.speaking => VoiceMeterMode.speaking,
                    _ => VoiceMeterMode.still,
                  },
                  level: micLevel,
                  onPressed: onClose!,
                ),
            ],
          );
        },
      ),
    );
  }
}

/// A round glyph control with a full touch target; named for assistive
/// technology and on long press. Built under the controls' Material.
class _RoundControl extends StatelessWidget {
  final String actionKey;
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final Color foreground;
  final Color? background;
  final double iconSize;

  const _RoundControl({
    required this.actionKey,
    required this.icon,
    required this.label,
    required this.onPressed,
    required this.foreground,
    this.background,
    this.iconSize = 18,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
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
            dimension: _kTarget,
            child: Center(
              child: Ink(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: background,
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: iconSize, color: foreground),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// How much of itself the end pill shows: bars and word, the word alone, or
/// the bars alone in a round button.
enum _EndPillForm { full, word, bars }

/// Ends the conversation. It stands where the start-voice button was and
/// carries the conversation's meter, the only one on screen: the status line
/// keeps the words and the clock, as in Hermes Desktop. Built under the
/// controls' Material.
class _EndPill extends StatelessWidget {
  final _EndPillForm form;
  final VoiceMeterMode meter;
  final String word;
  final String label;
  final TextStyle style;
  final ValueListenable<double>? level;
  final VoidCallback onPressed;

  const _EndPill({
    required this.form,
    required this.word,
    required this.label,
    required this.style,
    required this.meter,
    required this.level,
    required this.onPressed,
  });

  static const double _outerStart = 1;
  static const double _outerEnd = 3;
  static const double _fullStart = 11;
  static const double _fullEnd = 12;
  static const double _barsGap = 6;
  static const double _wordSide = 12;
  static const double _height = 38;

  /// Width of the pill in [form] for a word [wordWidth] wide.
  static double widthFor(_EndPillForm form, double wordWidth) =>
      _outerStart +
      _outerEnd +
      switch (form) {
        _EndPillForm.full =>
          _fullStart + VoiceMeter.width + _barsGap + wordWidth + _fullEnd,
        _EndPillForm.word => 2 * _wordSide + wordWidth,
        _EndPillForm.bars => _height,
      };

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Semantics(
      button: true,
      label: label,
      onTap: onPressed,
      excludeSemantics: true,
      child: Tooltip(
        message: label,
        child: InkWell(
          key: const ValueKey('voice-strip-close'),
          onTap: onPressed,
          customBorder: const StadiumBorder(),
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minWidth: _kTarget,
              minHeight: _kTarget,
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(_outerStart, 5, _outerEnd, 5),
              child: Center(
                widthFactor: 1,
                heightFactor: 1,
                child: Ink(
                  decoration: ShapeDecoration(
                    color: colors.accent,
                    shape: const StadiumBorder(),
                  ),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      minWidth: _height,
                      minHeight: _height,
                    ),
                    child: Padding(
                      padding: switch (form) {
                        _EndPillForm.full => const EdgeInsets.only(
                          left: _fullStart,
                          right: _fullEnd,
                        ),
                        _EndPillForm.word => const EdgeInsets.symmetric(
                          horizontal: _wordSide,
                        ),
                        _EndPillForm.bars => EdgeInsets.zero,
                      },
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (form != _EndPillForm.word)
                            VoiceMeter(
                              key: const ValueKey('voice-strip-end-level'),
                              mode: meter,
                              level: level,
                              color: colors.onAccent.withValues(alpha: 0.9),
                            ),
                          if (form == _EndPillForm.full)
                            const SizedBox(width: _barsGap),
                          if (form != _EndPillForm.bars)
                            Text(
                              word,
                              maxLines: 1,
                              softWrap: false,
                              style: style.copyWith(color: colors.onAccent),
                            ),
                        ],
                      ),
                    ),
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
