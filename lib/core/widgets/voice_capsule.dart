import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/services.dart';

import '../feedback/haptics.dart';
import '../theme/app_theme.dart';
import '../theme/hermes_tokens.dart';
import 'island.dart' show IslandMetrics, IslandTone;
import 'mascot/mascot_identity.dart';
import 'mascot/mascot_sprite.dart';
import 'mascot/mascot_state.dart';
import 'pill_morph.dart'
    show kPillMorphDismissDistance, kPillMorphDismissVelocity;
import 'voice_meter.dart';
import 'voice_wave.dart';
import 'voice_strip.dart';

/// Words the capsule adds to the voice line's ([VoiceStripLabels]).
@immutable
class VoiceCapsuleLabels {
  const VoiceCapsuleLabels({
    required this.title,
    required this.settings,
    required this.minimize,
    required this.open,
    required this.openRunning,
  });

  /// «Modo voz»: what TalkBack calls the capsule.
  final String title;

  /// ⚙ «Configurar voz».
  final String settings;

  /// «Minimizar»: the ⌃ button and the capsule's own accessibility action
  /// (QA 9709).
  final String minimize;

  /// The minimized pill's ⌄ and hint: «Expandir».
  final String open;

  /// The top row's hint, with something running: «Abrir lo que está en
  /// marcha».
  final String openRunning;
}

/// The face's pose for a voice state. The atlas has no listening or speaking
/// eyes yet (v1 decision still open): the nearest resting or working pose.
MascotState voiceCapsuleMascotState(VoiceStripState state) => switch (state) {
  VoiceStripState.loading ||
  VoiceStripState.listening ||
  VoiceStripState.paused => MascotState.idle,
  VoiceStripState.transcribing ||
  VoiceStripState.thinking ||
  VoiceStripState.speaking => MascotState.thinking,
  VoiceStripState.toolCall => MascotState.tool,
  VoiceStripState.waiting => MascotState.needsYou,
  VoiceStripState.error => MascotState.error,
};

/// What the wave draws for a voice state (QA 9709): the microphone while it
/// listens, the reply while it plays, a slow pulse while Hermes works, a
/// still line otherwise.
VoiceWaveMode voiceCapsuleWaveMode(VoiceStripState state) => switch (state) {
  VoiceStripState.listening => VoiceWaveMode.listening,
  VoiceStripState.speaking => VoiceWaveMode.speaking,
  VoiceStripState.transcribing ||
  VoiceStripState.thinking ||
  VoiceStripState.toolCall => VoiceWaveMode.thinking,
  VoiceStripState.loading ||
  VoiceStripState.waiting ||
  VoiceStripState.paused ||
  VoiceStripState.error => VoiceWaveMode.rest,
};

/// The level the wave follows in [mode]: the microphone's or the reply's.
ValueListenable<double>? voiceCapsuleWaveLevel(
  VoiceWaveMode mode, {
  required ValueListenable<double>? micLevel,
  required ValueListenable<double>? speechLevel,
}) => switch (mode) {
  VoiceWaveMode.listening => micLevel,
  VoiceWaveMode.speaking => speechLevel,
  VoiceWaveMode.rest || VoiceWaveMode.thinking => null,
};

/// The wave's colour: the accent while it listens, the reply's own while
/// Hermes speaks, amber or red when it waits or fails, quiet otherwise.
Color voiceCapsuleWaveColor(HermesThemeColors colors, VoiceStripState state) =>
    switch (state) {
      VoiceStripState.listening => colors.accent,
      VoiceStripState.speaking => colors.success,
      VoiceStripState.waiting => colors.warning,
      VoiceStripState.error => colors.error,
      _ => colors.textSecondary,
    };

/// How the island is framed for a voice state: amber while an approval
/// waits, red on a failure (135 v2 §3), like the island's own events.
IslandTone? voiceCapsuleTone(VoiceStripState state) => switch (state) {
  VoiceStripState.waiting => IslandTone.needsYou,
  VoiceStripState.error => IslandTone.error,
  _ => null,
};

/// The voice conversation when it has the header's island (maqueta 135 v2):
/// the pill grows into this capsule, downwards only, between the header's
/// side buttons and never wider than [maxWidth].
///
/// Three rows: the face, the wave and «1 ⌄» (what the pill had running);
/// the state in words with its one action ([VoiceStatusLine], the same nine
/// states, texts and rules as the line it replaces); and four 48 dp buttons:
/// ⚙ settings, ⌃ minimize, 🎙 pause or resume, ✕ end.
///
/// Swiping it up (past the pill morph's thresholds), the system Back, Esc or
/// ⌃ minimize it; only ✕ ends the conversation. Like the line, it is only a
/// projection of the voice controller.
class VoiceCapsule extends StatefulWidget {
  const VoiceCapsule({
    required this.state,
    required this.statusLabel,
    required this.labels,
    required this.capsuleLabels,
    required this.onMinimize,
    required this.onClose,
    this.name = 'Hermes',
    this.heard,
    this.micLevel,
    this.speechLevel,
    this.mark,
    this.onOpenMark,
    this.onSettings,
    this.onPause,
    this.onResume,
    this.onStopAndTalk,
    this.onRetry,
    this.onReview,
    this.onFinishListening,
    super.key,
  });

  final VoiceStripState state;
  final String statusLabel;
  final VoiceStripLabels labels;
  final VoiceCapsuleLabels capsuleLabels;

  /// Whose face it is, for the sprite's own label.
  final String name;
  final ValueGetter<String>? heard;
  final ValueListenable<double>? micLevel;

  /// How loud the reply is while it plays (`VoiceService.playbackLevel`).
  final ValueListenable<double>? speechLevel;

  /// What the island had running («1»), opened by [onOpenMark]: the same
  /// card the pill opens (v2 decision 5: kept in the capsule).
  final String? mark;
  final VoidCallback? onOpenMark;

  final VoidCallback onMinimize;
  final VoidCallback onClose;
  final VoidCallback? onSettings;
  final VoidCallback? onPause;
  final VoidCallback? onResume;
  final VoidCallback? onStopAndTalk;
  final VoidCallback? onRetry;
  final VoidCallback? onReview;
  final VoidCallback? onFinishListening;

  /// Never wider than this (135 v2 §1).
  static const double maxWidth = IslandMetrics.voiceMaxWidth;

  /// The top row: face, meter and «1 ⌄» (135 v2 §8).
  static const double topRowHeight = 58;

  @override
  State<VoiceCapsule> createState() => _VoiceCapsuleState();
}

class _VoiceCapsuleState extends State<VoiceCapsule>
    with SingleTickerProviderStateMixin {
  /// The rows come in after the surface starts to grow: the state and the
  /// face from 30 %, the buttons from 50 % of the morph (135 v2 §2).
  late final AnimationController _entrance = AnimationController(
    vsync: this,
    duration: HermesMotion.sheetOpen,
  );
  late final CurvedAnimation _rowsIn = CurvedAnimation(
    parent: _entrance,
    curve: const Interval(0.3, 1, curve: HermesMotion.standard),
  );
  late final CurvedAnimation _buttonsIn = CurvedAnimation(
    parent: _entrance,
    curve: const Interval(0.5, 1, curve: HermesMotion.standard),
  );
  double _drag = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_entrance.isAnimating || _entrance.isCompleted) return;
    if (HermesMotion.reduced(context)) {
      _entrance.value = 1;
    } else {
      _entrance.forward();
    }
  }

  @override
  void dispose() {
    _rowsIn.dispose();
    _buttonsIn.dispose();
    _entrance.dispose();
    super.dispose();
  }

  void _onDragUpdate(DragUpdateDetails details) {
    _drag += details.primaryDelta ?? 0;
  }

  void _onDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    final up =
        -_drag > kPillMorphDismissDistance ||
        -velocity > kPillMorphDismissVelocity;
    _drag = 0;
    if (up) widget.onMinimize();
  }

  Widget _staggered(Animation<double> opacity, Widget child) =>
      FadeTransition(opacity: opacity, child: child);

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final w = widget;
    final paused = w.state == VoiceStripState.paused;
    // 🎙 pauses only what the clock times (listening to speaking); in
    // loading, waiting or error there is nothing to pause.
    final mic = paused ? w.onResume : (w.state.timed ? w.onPause : null);
    final top = _TopRow(
      state: w.state,
      name: w.name,
      micLevel: w.micLevel,
      speechLevel: w.speechLevel,
      mark: w.mark,
      onOpenMark: w.onOpenMark,
      labels: w.capsuleLabels,
    );
    final capsule = LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? math.min(constraints.maxWidth, VoiceCapsule.maxWidth)
            : VoiceCapsule.maxWidth;
        return SizedBox(
          key: const ValueKey('voice-capsule'),
          width: width,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              HermesSpace.x1,
              0,
              HermesSpace.x1,
              HermesSpace.x1,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _staggered(_rowsIn, top),
                _staggered(
                  _rowsIn,
                  VoiceStatusLine(
                    state: w.state,
                    statusLabel: w.statusLabel,
                    labels: w.labels,
                    heard: w.heard,
                    // Resuming is the 🎙 button here; the line never offers
                    // the same thing twice.
                    onStopAndTalk: w.onStopAndTalk,
                    onRetry: w.onRetry,
                    onReview: w.onReview,
                    onFinishListening: w.onFinishListening,
                    embedded: true,
                  ),
                ),
                _staggered(
                  _buttonsIn,
                  // Four 48 dp targets that close up in a narrow column
                  // (135 v2 §7) and take a second row before they would
                  // overflow (a 320 dp phone leaves the island ~196 dp).
                  Wrap(
                    key: const ValueKey('voice-capsule-buttons'),
                    alignment: WrapAlignment.spaceEvenly,
                    children: [
                      _CapsuleButton(
                        actionKey: 'voice-capsule-settings',
                        icon: Icons.tune_rounded,
                        label: w.capsuleLabels.settings,
                        onPressed: w.onSettings,
                        foreground: colors.textPrimary,
                      ),
                      // QA 9709: it folds the capsule up into the island,
                      // what swiping it up does too.
                      _CapsuleButton(
                        actionKey: 'voice-capsule-minimize',
                        icon: Icons.keyboard_arrow_up_rounded,
                        label: w.capsuleLabels.minimize,
                        onPressed: w.onMinimize,
                        foreground: colors.textPrimary,
                      ),
                      // The keys of the composer's old pause and resume, so
                      // the conversation keeps one of each.
                      _CapsuleButton(
                        actionKey: paused
                            ? 'voice-strip-resume'
                            : 'voice-strip-pause',
                        icon: paused
                            ? Icons.play_arrow_rounded
                            : Icons.pause_rounded,
                        label: paused ? w.labels.resume : w.labels.pause,
                        onPressed: mic,
                        foreground: paused
                            ? colors.accent
                            : colors.textPrimary,
                        background: paused
                            ? colors.accent.withValues(alpha: 0.2)
                            : null,
                      ),
                      _CapsuleButton(
                        actionKey: 'voice-strip-close',
                        icon: Icons.close_rounded,
                        label: w.labels.close,
                        onPressed: w.onClose,
                        foreground: colors.error,
                        background: colors.error.withValues(alpha: 0.14),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    // Never wider than [maxWidth] (135 v2 §8), even in a parent that hands
    // it a tight width: that would stretch the capsule's own box.
    final bounded = Align(
      alignment: Alignment.topCenter,
      widthFactor: 1,
      heightFactor: 1,
      child: capsule,
    );
    // Back minimizes and never ends the voice (only ✕ does); Esc too.
    return _WorkTick(
      state: w.state,
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) widget.onMinimize();
        },
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): widget.onMinimize,
          },
          // Esc needs the focus inside: the capsule takes it when it opens,
          // without adding a stop to the traversal.
          child: Focus(
            autofocus: true,
            skipTraversal: true,
            child: Semantics(
              container: true,
              explicitChildNodes: true,
              label: w.capsuleLabels.title,
              customSemanticsActions: {
                CustomSemanticsAction(label: w.capsuleLabels.minimize):
                    widget.onMinimize,
              },
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                excludeFromSemantics: true,
                onVerticalDragUpdate: _onDragUpdate,
                onVerticalDragEnd: _onDragEnd,
                child: Material(
                  type: MaterialType.transparency,
                  child: bounded,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The capsule's first row: the face that came down from the island, the
/// wave across the rest of it, and «1 ⌄». A tap on the face or the wave
/// opens what is running, like the pill did.
class _TopRow extends StatelessWidget {
  const _TopRow({
    required this.state,
    required this.name,
    required this.micLevel,
    required this.speechLevel,
    required this.mark,
    required this.onOpenMark,
    required this.labels,
  });

  final VoiceStripState state;
  final String name;
  final ValueListenable<double>? micLevel;
  final ValueListenable<double>? speechLevel;
  final String? mark;
  final VoidCallback? onOpenMark;
  final VoiceCapsuleLabels labels;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final mark = this.mark;
    final open = mark != null ? onOpenMark : null;
    // The row shows the count, «1 ⌄» (135 v2 §2), so no language's words
    // overflow a narrow capsule; TalkBack reads the whole mark. Every
    // catalog's mark carries its number.
    final count =
        mark == null ? null : RegExp(r'\d+').firstMatch(mark)?.group(0) ?? mark;
    final wave = voiceCapsuleWaveMode(state);
    return SizedBox(
      height: VoiceCapsule.topRowHeight,
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              button: open != null,
              hint: open != null ? labels.openRunning : null,
              onTap: open,
              excludeSemantics: true,
              child: GestureDetector(
                key: const ValueKey('voice-capsule-top'),
                behavior: HitTestBehavior.opaque,
                onTap: open,
                child: Row(
                  children: [
                    MascotSprite(
                      key: const ValueKey('voice-capsule-mascot'),
                      state: voiceCapsuleMascotState(state),
                      still: state == VoiceStripState.paused,
                      identity: MascotIdentity.hermes,
                      size: MascotSprite.large,
                      name: name,
                      excludeSemantics: true,
                    ),
                    const SizedBox(width: HermesSpace.x3),
                    // QA 9709: the wave fills the row, like Grok's.
                    Expanded(
                      child: VoiceWave(
                        key: const ValueKey('voice-capsule-meter'),
                        mode: wave,
                        level: voiceCapsuleWaveLevel(
                          wave,
                          micLevel: micLevel,
                          speechLevel: speechLevel,
                        ),
                        color: voiceCapsuleWaveColor(colors, state),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (mark != null && count != null)
            Semantics(
              button: true,
              label: mark,
              hint: labels.openRunning,
              onTap: open,
              excludeSemantics: true,
              child: InkWell(
                key: const ValueKey('voice-capsule-mark'),
                onTap: open,
                customBorder: const StadiumBorder(),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    minWidth: HermesSize.tap,
                    minHeight: HermesSize.tap,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: HermesSpace.x2,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          count,
                          maxLines: 1,
                          style: HermesType.support.copyWith(
                            color: colors.textPrimary,
                            fontWeight: FontWeight.w600,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                        Icon(
                          Icons.expand_more_rounded,
                          size: HermesIcon.md,
                          color: colors.textSecondary,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// One of the capsule's four buttons: a 48 dp target around a 40 dp disc,
/// named for TalkBack and on long press.
class _CapsuleButton extends StatelessWidget {
  const _CapsuleButton({
    required this.actionKey,
    required this.icon,
    required this.label,
    required this.onPressed,
    required this.foreground,
    this.background,
  });

  final String actionKey;
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final Color foreground;
  final Color? background;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
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
            dimension: HermesSize.tap,
            child: Center(
              child: Ink(
                width: HermesSize.segment,
                height: HermesSize.segment,
                decoration: BoxDecoration(
                  color: background ?? colors.surfaceVariant,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  icon,
                  size: HermesIcon.lg,
                  color: enabled ? foreground : colors.textDisabled,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The capsule minimized (135 v2 §6): the pill again, saying the voice is
/// still on, its name, the wave and ⌄ (QA 9709), while the face goes back
/// up. A tap opens the capsule again; the voice never ended. TalkBack hears
/// the name and the state, and «Expandir».
class VoiceCapsulePill extends StatelessWidget {
  const VoiceCapsulePill({
    required this.name,
    required this.state,
    required this.statusLabel,
    required this.openLabel,
    required this.onOpen,
    this.micLevel,
    this.speechLevel,
    super.key,
  });

  final String name;
  final VoiceStripState state;
  final String statusLabel;

  /// «Expandir».
  final String openLabel;
  final VoidCallback onOpen;
  final ValueListenable<double>? micLevel;
  final ValueListenable<double>? speechLevel;

  /// The pill's wave is lower than the capsule's.
  static const double waveHeight = 22;

  /// A long name is cut before it can take the wave's room.
  static const double nameMaxWidth = 120;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final wave = voiceCapsuleWaveMode(state);
    // Joined like the island's own label.
    final spoken = [name, statusLabel].join(', ');
    return _WorkTick(
      state: state,
      child: Semantics(
        container: true,
        button: true,
        liveRegion: true,
        label: spoken,
        hint: openLabel,
        onTap: onOpen,
        excludeSemantics: true,
        child: GestureDetector(
          key: const ValueKey('voice-capsule-pill'),
          behavior: HitTestBehavior.opaque,
          onTap: onOpen,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: IslandMetrics.restHeight,
              maxWidth: VoiceCapsule.maxWidth,
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                HermesSpace.x3,
                0,
                HermesSpace.x1,
                0,
              ),
              child: Row(
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: VoiceCapsulePill.nameMaxWidth,
                    ),
                    child: Text(
                      name,
                      key: const ValueKey('voice-capsule-pill-name'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HermesType.value.copyWith(
                        color: colors.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: HermesSpace.x2),
                  Expanded(
                    child: VoiceWave(
                      key: const ValueKey('voice-capsule-pill-wave'),
                      mode: wave,
                      level: voiceCapsuleWaveLevel(
                        wave,
                        micLevel: micLevel,
                        speechLevel: speechLevel,
                      ),
                      color: voiceCapsuleWaveColor(colors, state),
                      height: waveHeight,
                    ),
                  ),
                  Icon(
                    Icons.keyboard_arrow_down_rounded,
                    key: const ValueKey('voice-capsule-pill-expand'),
                    size: HermesIcon.lg,
                    color: colors.textSecondary,
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

/// The voice conversation as the header's island says it (voz inline): five
/// small level bars, the state in one word and, while it listens, its clock
/// («Escuchando 0:03», «Pensando», «Hablando», «En pausa»).
///
/// It is exactly the island's resting height and never wider than
/// [maxWidth]; a long state ends in «…». Only its contents change between
/// states (a 180 ms cross-fade, cut with reduce motion): it never moves the
/// header's sprite or buttons. The bars repaint their own layer; the clock
/// rebuilds this widget alone, once a second. A tap is the state's action,
/// pause or resume ([onTap], [actionLabel]); TalkBack hears the name and the
/// state once per change, never the clock.
class VoiceIslandStatus extends StatefulWidget {
  const VoiceIslandStatus({
    required this.name,
    required this.state,
    required this.statusLabel,
    this.actionLabel,
    this.onTap,
    this.micLevel,
    this.speechLevel,
    this.reduceMotion = false,
    super.key,
  });

  final String name;
  final VoiceStripState state;

  /// The state in plain words (the voice line's, «Escuchando…»).
  final String statusLabel;

  /// What a tap does, for TalkBack: «Pausar» or «Continuar».
  final String? actionLabel;
  final VoidCallback? onTap;
  final ValueListenable<double>? micLevel;
  final ValueListenable<double>? speechLevel;
  final bool reduceMotion;

  /// Never wider than the capsule's pill was.
  static const double maxWidth = VoiceCapsule.maxWidth;

  /// The content's cross-fade between two states.
  static const Duration swap = HermesMotion.voiceFade;

  /// The word on the island: the label without its trailing «…».
  static String word(String statusLabel) =>
      statusLabel.trim().replaceFirst(RegExp(r'(…|\.\.\.)$'), '');

  @override
  State<VoiceIslandStatus> createState() => _VoiceIslandStatusState();
}

class _VoiceIslandStatusState extends State<VoiceIslandStatus> {
  Timer? _clockTicker;
  int _elapsedSeconds = 0;

  bool get _clocked => widget.state == VoiceStripState.listening;

  @override
  void initState() {
    super.initState();
    _restartClock();
  }

  @override
  void didUpdateWidget(VoiceIslandStatus oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) _restartClock();
  }

  @override
  void dispose() {
    _clockTicker?.cancel();
    super.dispose();
  }

  void _restartClock() {
    _clockTicker?.cancel();
    _clockTicker = null;
    _elapsedSeconds = 0;
    if (!_clocked) return;
    _clockTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _elapsedSeconds += 1);
    });
  }

  String get _clock {
    final minutes = _elapsedSeconds ~/ 60;
    final seconds = (_elapsedSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final chrome = HermesChrome.of(colors);
    final state = widget.state;
    final meter = switch (state) {
      VoiceStripState.listening => VoiceMeterMode.level,
      VoiceStripState.speaking => VoiceMeterMode.speaking,
      _ => VoiceMeterMode.still,
    };
    final tone = switch (state) {
      VoiceStripState.listening => colors.accent,
      VoiceStripState.speaking => colors.success,
      VoiceStripState.waiting => colors.warning,
      VoiceStripState.error => colors.error,
      _ => colors.textSecondary,
    };
    final content = Row(
      key: ValueKey(state),
      mainAxisSize: MainAxisSize.min,
      children: [
        VoiceMeter(
          key: const ValueKey('voice-island-meter'),
          mode: widget.reduceMotion ? VoiceMeterMode.still : meter,
          level: state == VoiceStripState.speaking
              ? widget.speechLevel
              : widget.micLevel,
          color: tone,
        ),
        const SizedBox(width: HermesSpace.x2),
        Flexible(
          child: Text(
            VoiceIslandStatus.word(widget.statusLabel),
            key: const ValueKey('voice-island-word'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            // The rest pill's line height, whatever this word's style.
            strutStyle: const StrutStyle(
              fontSize: IslandMetrics.lineFontSize,
              height: 1.2,
              forceStrutHeight: true,
            ),
            style: HermesType.value.copyWith(
              color: state == VoiceStripState.paused
                  ? chrome.mutedInk
                  : colors.textPrimary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        if (_clocked) ...[
          const SizedBox(width: HermesSpace.x2),
          Text(
            _clock,
            key: const ValueKey('voice-island-clock'),
            maxLines: 1,
            strutStyle: const StrutStyle(
              fontSize: IslandMetrics.lineFontSize,
              height: 1.2,
              forceStrutHeight: true,
            ),
            style: HermesType.mono.copyWith(
              color: chrome.mutedInk,
              fontSize: HermesType.caption.fontSize,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ],
    );
    return _WorkTick(
      state: state,
      child: Semantics(
        container: true,
        button: widget.onTap != null,
        liveRegion: true,
        label: [widget.name, widget.statusLabel].join(', '),
        hint: widget.onTap != null ? widget.actionLabel : null,
        onTap: widget.onTap,
        excludeSemantics: true,
        child: GestureDetector(
          key: const ValueKey('voice-island-status'),
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: VoiceIslandStatus.maxWidth,
            ),
            // The rest pill's own frame: at least its height, its line's
            // room at every text size, so the island never changes height.
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: IslandMetrics.restHeight,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: HermesSpace.x3,
                  vertical: IslandMetrics.faceReach,
                ),
                child: AnimatedSwitcher(
                  duration: widget.reduceMotion
                      ? Duration.zero
                      : VoiceIslandStatus.swap,
                  layoutBuilder: (current, previous) => Stack(
                    alignment: Alignment.center,
                    children: [...previous, ?current],
                  ),
                  child: content,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Whether Hermes is working on the turn: thinking or running a tool.
bool voiceStateWorks(VoiceStripState state) =>
    state == VoiceStripState.thinking || state == VoiceStripState.toolCall;

/// QA 9709 (the owner): the voice is silent while Hermes works. That it started
/// is felt instead: one light tick when what was said turns into work (from
/// listening or transcribing). A tool after the thinking, or the work going
/// on after a spoken interim, does not tick again. The capsule and its pill
/// each have one; a new one (the capsule minimized or opened) never ticks.
class _WorkTick extends StatefulWidget {
  const _WorkTick({required this.state, required this.child});

  final VoiceStripState state;
  final Widget child;

  @override
  State<_WorkTick> createState() => _WorkTickState();
}

class _WorkTickState extends State<_WorkTick> {
  @override
  void didUpdateWidget(_WorkTick oldWidget) {
    super.didUpdateWidget(oldWidget);
    final heard = switch (oldWidget.state) {
      VoiceStripState.listening || VoiceStripState.transcribing => true,
      _ => false,
    };
    if (heard && voiceStateWorks(widget.state)) HermesHaptics.selection();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
