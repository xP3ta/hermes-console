// 3b (ORDEN-T2-C): the voice v2 capsule of maqueta 135 v2. The header's
// pill becomes the capsule in place (no window of its own), with the pill
// morph's motion; minimizing gives the pill back saying the voice is on;
// only ✕ ends the conversation.
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/floating_chat_header.dart';
import 'package:hermes_android/core/widgets/hermes_notice.dart';
import 'package:hermes_android/core/widgets/island.dart';
import 'package:hermes_android/core/widgets/mascot/mascot_state.dart';
import 'package:hermes_android/core/widgets/pill_morph.dart';
import 'package:hermes_android/core/widgets/voice_capsule.dart';
import 'package:hermes_android/core/widgets/voice_wave.dart';
import 'package:hermes_android/core/widgets/voice_strip.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

const _labels = VoiceStripLabels(
  finishListening: 'Terminar de hablar',
  pause: 'Pausar',
  resume: 'Reanudar',
  stopAndTalk: 'Parar y hablar',
  cancel: 'Cancelar tarea',
  stop: 'Detener',
  retry: 'Reintentar',
  review: 'Ver aprobación',
  close: 'Terminar modo voz',
  end: 'Terminar',
);

const _capsuleLabels = VoiceCapsuleLabels(
  title: 'Modo voz',
  settings: 'Configurar voz',
  minimize: 'Minimizar',
  open: 'Expandir',
  openRunning: 'Abrir lo que está en marcha',
);

Widget _app(
  Widget child, {
  bool reduceMotion = false,
  double width = 412,
  double textScale = 1,
  Locale locale = const Locale('es'),
  ThemeData? theme,
}) => MaterialApp(
  locale: locale,
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: theme ?? AppTheme.hermesRedDark,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      disableAnimations: reduceMotion,
      textScaler: TextScaler.linear(textScale),
    ),
    child: child!,
  ),
  home: Scaffold(
    body: Align(
      alignment: Alignment.topCenter,
      child: SizedBox(width: width, child: child),
    ),
  ),
);

class _Calls {
  int minimized = 0;
  int closed = 0;
  int paused = 0;
  int resumed = 0;
  int settings = 0;
  int opened = 0;
}

VoiceCapsule _capsule(
  _Calls calls, {
  VoiceStripState state = VoiceStripState.listening,
  String? mark,
}) => VoiceCapsule(
  state: state,
  statusLabel: 'Escuchando…',
  labels: _labels,
  capsuleLabels: _capsuleLabels,
  onMinimize: () => calls.minimized++,
  onClose: () => calls.closed++,
  onPause: () => calls.paused++,
  onResume: () => calls.resumed++,
  onSettings: () => calls.settings++,
  mark: mark,
  onOpenMark: () => calls.opened++,
);

Finder _key(String key) => find.byKey(ValueKey(key));

/// A voice state's pose, meter and frame.
typedef _Look = (MascotState, VoiceWaveMode, IslandTone?);

void main() {
  group('the capsule', () {
    testWidgets('three rows; four 48 dp buttons that TalkBack names', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final calls = _Calls();
      await tester.pumpWidget(_app(_capsule(calls)));
      await tester.pump(kPillMorphOpen);

      expect(_key('voice-capsule-mascot'), findsOneWidget);
      expect(_key('voice-capsule-meter'), findsOneWidget);
      // The same status line, embedded: the capsule is its surface.
      final line = tester.widget<DecoratedBox>(_key('voice-strip'));
      expect((line.decoration as BoxDecoration).color, isNull);
      expect(find.text('Escuchando…'), findsOneWidget);

      for (final (key, label) in const [
        ('voice-capsule-settings', 'Configurar voz'),
        ('voice-capsule-minimize', 'Minimizar'),
        ('voice-strip-pause', 'Pausar'),
        ('voice-strip-close', 'Terminar modo voz'),
      ]) {
        final size = tester.getSize(_key(key));
        expect(size.width, greaterThanOrEqualTo(48), reason: key);
        expect(size.height, greaterThanOrEqualTo(48), reason: key);
        expect(find.bySemanticsLabel(label), findsOneWidget, reason: key);
      }
      expect(
        tester.getSize(_key('voice-capsule')).width,
        lessThanOrEqualTo(VoiceCapsule.maxWidth),
      );
      // QA 9709: the minimize button says what it does, ⌃ folds it up.
      expect(
        find.descendant(
          of: _key('voice-capsule-minimize'),
          matching: find.byIcon(Icons.keyboard_arrow_up_rounded),
        ),
        findsOneWidget,
      );

      await tester.tap(_key('voice-capsule-settings'));
      await tester.tap(_key('voice-capsule-minimize'));
      await tester.tap(_key('voice-strip-pause'));
      await tester.tap(_key('voice-strip-close'));
      expect(calls.settings, 1);
      expect(calls.minimized, 1);
      expect(calls.paused, 1);
      expect(calls.closed, 1);
      semantics.dispose();
    });

    testWidgets('a 320 dp phone (≈196 dp between the header buttons): no '
        'overflow, four 48 dp targets inside the capsule', (tester) async {
      final calls = _Calls();
      await tester.pumpWidget(_app(_capsule(calls), width: 196));
      await tester.pump(kPillMorphOpen);
      expect(tester.takeException(), isNull);
      final capsule = tester.getRect(_key('voice-capsule'));
      for (final key in const [
        'voice-capsule-settings',
        'voice-capsule-minimize',
        'voice-strip-pause',
        'voice-strip-close',
      ]) {
        final rect = tester.getRect(_key(key));
        expect(rect.width, greaterThanOrEqualTo(48), reason: key);
        expect(rect.height, greaterThanOrEqualTo(48), reason: key);
        expect(rect.left, greaterThanOrEqualTo(capsule.left), reason: key);
        expect(rect.right, lessThanOrEqualTo(capsule.right), reason: key);
      }
    });

    testWidgets('paused: 🎙 resumes, and the line does not offer it twice', (
      tester,
    ) async {
      final calls = _Calls();
      await tester.pumpWidget(
        _app(_capsule(calls, state: VoiceStripState.paused)),
      );
      await tester.pump(kPillMorphOpen);
      expect(_key('voice-strip-pause'), findsNothing);
      expect(_key('voice-strip-resume'), findsOneWidget);
      expect(find.bySemanticsLabel('Reanudar'), findsOneWidget);
      await tester.tap(_key('voice-strip-resume'));
      expect(calls.resumed, 1);
    });

    testWidgets('«1 ⌄» opens what is running, at 48 dp', (tester) async {
      final calls = _Calls();
      await tester.pumpWidget(_app(_capsule(calls, mark: '1')));
      await tester.pump(kPillMorphOpen);
      final mark = _key('voice-capsule-mark');
      expect(tester.getSize(mark).height, greaterThanOrEqualTo(48));
      await tester.tap(mark);
      await tester.tap(_key('voice-capsule-top'));
      expect(calls.opened, 2);
    });

    testWidgets('🎙 pauses only what the clock times (review P2)', (
      tester,
    ) async {
      for (final state in VoiceStripState.values) {
        if (state == VoiceStripState.paused) continue;
        final calls = _Calls();
        await tester.pumpWidget(_app(_capsule(calls, state: state)));
        await tester.pump(kPillMorphOpen);
        await tester.tap(_key('voice-strip-pause'), warnIfMissed: false);
        expect(calls.paused, state.timed ? 1 : 0, reason: state.name);
      }
      expect(VoiceStripState.loading.timed, isFalse);
      expect(VoiceStripState.waiting.timed, isFalse);
      expect(VoiceStripState.error.timed, isFalse);
    });

    testWidgets('«N ⌄» at 196 dp, in Portuguese at 134 %: the count, never '
        'the words, and TalkBack reads them all (review P2)', (tester) async {
      final semantics = tester.ensureSemantics();
      final calls = _Calls();
      await tester.pumpWidget(
        _app(
          _capsule(calls, mark: '12 em execução'),
          width: 196,
          textScale: 1.34,
          locale: const Locale('pt'),
        ),
      );
      await tester.pump(kPillMorphOpen);
      expect(tester.takeException(), isNull);
      expect(find.text('12'), findsOneWidget);
      expect(find.text('12 em execução'), findsNothing);
      expect(find.bySemanticsLabel('12 em execução'), findsOneWidget);
      final capsule = tester.getRect(_key('voice-capsule'));
      final mark = tester.getRect(_key('voice-capsule-mark'));
      expect(mark.right, lessThanOrEqualTo(capsule.right));
      expect(mark.height, greaterThanOrEqualTo(48));
      expect(
        tester.getRect(_key('voice-capsule-meter')).right,
        lessThanOrEqualTo(mark.left),
      );
      semantics.dispose();
    });

    testWidgets('Esc minimizes: the capsule takes the focus when it opens', (
      tester,
    ) async {
      final calls = _Calls();
      await tester.pumpWidget(_app(_capsule(calls)));
      await tester.pump(kPillMorphOpen);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(calls.minimized, 1);
    });

    testWidgets('without anything running the top row opens nothing', (
      tester,
    ) async {
      final calls = _Calls();
      await tester.pumpWidget(_app(_capsule(calls)));
      await tester.pump(kPillMorphOpen);
      expect(_key('voice-capsule-mark'), findsNothing);
      await tester.tap(_key('voice-capsule-top'));
      expect(calls.opened, 0);
    });

    testWidgets('swiping up past the morph threshold minimizes; a short '
        'swipe does not', (tester) async {
      final calls = _Calls();
      await tester.pumpWidget(_app(_capsule(calls)));
      await tester.pump(kPillMorphOpen);
      await tester.timedDrag(
        _key('voice-capsule-top'),
        const Offset(0, -20),
        const Duration(milliseconds: 400),
      );
      expect(calls.minimized, 0);
      await tester.drag(
        _key('voice-capsule-top'),
        const Offset(0, -(kPillMorphDismissDistance + 20)),
      );
      await tester.pump();
      expect(calls.minimized, 1);
      expect(calls.closed, 0);
    });

    testWidgets('Back minimizes and never ends the voice', (tester) async {
      final calls = _Calls();
      await tester.pumpWidget(_app(_capsule(calls)));
      await tester.pump(kPillMorphOpen);
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(calls.minimized, 1);
      expect(calls.closed, 0);
      expect(find.byType(VoiceCapsule), findsOneWidget);
    });

    testWidgets('TalkBack can minimize it from the capsule itself', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final calls = _Calls();
      await tester.pumpWidget(_app(_capsule(calls)));
      await tester.pump(kPillMorphOpen);
      final node = tester.getSemantics(
        find.bySemanticsLabel('Modo voz').first,
      );
      final action = CustomSemanticsAction.getIdentifier(
        const CustomSemanticsAction(label: 'Minimizar'),
      );
      node.owner!.performAction(
        node.id,
        SemanticsAction.customAction,
        action,
      );
      await tester.pump();
      expect(calls.minimized, 1);
      semantics.dispose();
    });

    testWidgets('a long failure stays readable: three lines, the capsule '
        'grows down', (tester) async {
      final calls = _Calls();
      await tester.pumpWidget(
        _app(
          VoiceCapsule(
            state: VoiceStripState.error,
            statusLabel: List.filled(20, 'no se pudo conectar').join(' '),
            labels: _labels,
            capsuleLabels: _capsuleLabels,
            onMinimize: () => calls.minimized++,
            onClose: () => calls.closed++,
            onRetry: () {},
          ),
          width: 360,
        ),
      );
      await tester.pump(kPillMorphOpen);
      expect(tester.takeException(), isNull);
      final long = tester.getSize(_key('voice-strip-status')).height;
      final grown = tester.getSize(_key('voice-capsule')).height;
      expect(find.bySemanticsLabel('Reintentar'), findsOneWidget);

      // A failure short enough for one line beside «Reintentar» (13 dp
      // glyphs in the test font: «no se pudo conectar» would already wrap).
      await tester.pumpWidget(
        _app(
          VoiceCapsule(
            state: VoiceStripState.error,
            statusLabel: 'sin red',
            labels: _labels,
            capsuleLabels: _capsuleLabels,
            onMinimize: () => calls.minimized++,
            onClose: () => calls.closed++,
            onRetry: () {},
          ),
          width: 360,
        ),
      );
      await tester.pump(kPillMorphOpen);
      final line = tester.getSize(_key('voice-strip-status')).height;
      expect(long, closeTo(3 * line, 0.5), reason: 'exactly three lines');
      expect(
        grown,
        greaterThan(tester.getSize(_key('voice-capsule')).height + line),
        reason: 'the capsule grows down with them',
      );
    });

    testWidgets('an engine that needs it: «Terminar de hablar» is the '
        'listening state\'s action', (tester) async {
      var finished = 0;
      await tester.pumpWidget(
        _app(
          VoiceCapsule(
            state: VoiceStripState.listening,
            statusLabel: 'Escuchando…',
            labels: _labels,
            capsuleLabels: _capsuleLabels,
            onMinimize: () {},
            onClose: () {},
            onFinishListening: () => finished++,
          ),
        ),
      );
      await tester.pump(kPillMorphOpen);
      final action = _key('voice-strip-finish-listening');
      expect(action, findsOneWidget);
      expect(find.bySemanticsLabel('Terminar de hablar'), findsOneWidget);
      await tester.tap(action);
      expect(finished, 1);
    });

    testWidgets('reduced motion: everything shows at once', (tester) async {
      final calls = _Calls();
      await tester.pumpWidget(_app(_capsule(calls), reduceMotion: true));
      await tester.pump();
      for (final fade in tester.widgetList<FadeTransition>(
        find.descendant(
          of: find.byType(VoiceCapsule),
          matching: find.byType(FadeTransition),
        ),
      )) {
        expect(fade.opacity.value, 1);
      }
    });
  });

  // QA 9709 (the owner): the wave fills the row, like Grok's, at every width the
  // capsule takes (a 320 dp phone leaves 196, the Fold with its pane 224-236,
  // a Pixel 288, at most 360), with large text, in both themes.
  group('the wave across the capsule and the pill', () {
    for (final (name, theme) in [
      ('dark', AppTheme.hermesRedDark),
      ('light', AppTheme.hermesRedLight),
    ]) {
      for (final width in const [196.0, 236.0, 288.0, 360.0]) {
        testWidgets('$name, $width dp, text at 134 %', (tester) async {
          final calls = _Calls();
          final mic = ValueNotifier<double>(0);
          addTearDown(mic.dispose);
          await tester.pumpWidget(
            _app(
              VoiceCapsule(
                state: VoiceStripState.listening,
                statusLabel: 'Escuchando…',
                labels: _labels,
                capsuleLabels: _capsuleLabels,
                onMinimize: () => calls.minimized++,
                onClose: () => calls.closed++,
                onPause: () {},
                micLevel: mic,
                mark: '1',
                onOpenMark: () {},
              ),
              width: width,
              textScale: 1.34,
              theme: theme,
            ),
          );
          await tester.pump(kPillMorphOpen);
          expect(tester.takeException(), isNull);
          final face = tester.getRect(_key('voice-capsule-mascot'));
          final wave = tester.getRect(_key('voice-capsule-meter'));
          final mark = tester.getRect(_key('voice-capsule-mark'));
          // From the face to «1 ⌄»: all the room the row has.
          expect(wave.left, closeTo(face.right + 12, 0.5));
          expect(wave.right, closeTo(mark.left, 0.5));
          expect(wave.width, greaterThan(40));
          // It moves with the microphone.
          final state = tester.state<VoiceWaveState>(find.byType(VoiceWave));
          for (var i = 0; i < 6; i++) {
            await tester.pump(const Duration(milliseconds: 60));
          }
          mic.value = 0.3;
          for (var i = 0; i < 3; i++) {
            await tester.pump(const Duration(milliseconds: 60));
          }
          expect(state.samples.last, greaterThan(0.5));
          // ⌃ «Minimizar», 48 dp.
          final minimize = tester.getSize(_key('voice-capsule-minimize'));
          expect(minimize.width, greaterThanOrEqualTo(48));
          expect(minimize.height, greaterThanOrEqualTo(48));

          await tester.pumpWidget(
            _app(
              VoiceCapsulePill(
                name: 'Hermes',
                state: VoiceStripState.speaking,
                statusLabel: 'Hablando…',
                openLabel: 'Expandir',
                onOpen: () {},
              ),
              width: width,
              textScale: 1.34,
              theme: theme,
            ),
          );
          expect(tester.takeException(), isNull);
          final pill = tester.getRect(_key('voice-capsule-pill'));
          final pillWave = tester.getRect(_key('voice-capsule-pill-wave'));
          final expand = tester.getRect(_key('voice-capsule-pill-expand'));
          expect(pill.width, closeTo(width, 0.5));
          expect(pillWave.width, greaterThan(40));
          expect(pillWave.right, closeTo(expand.left, 0.5));
        });
      }
    }

    testWidgets('speaking follows the reply, not the microphone; reduced '
        'motion keeps it still', (tester) async {
      final calls = _Calls();
      final mic = ValueNotifier<double>(0);
      final speech = ValueNotifier<double>(0);
      addTearDown(mic.dispose);
      addTearDown(speech.dispose);
      Widget capsule({bool reduce = false}) => _app(
        VoiceCapsule(
          state: VoiceStripState.speaking,
          statusLabel: 'Hablando…',
          labels: _labels,
          capsuleLabels: _capsuleLabels,
          onMinimize: () => calls.minimized++,
          onClose: () => calls.closed++,
          micLevel: mic,
          speechLevel: speech,
        ),
        reduceMotion: reduce,
      );
      await tester.pumpWidget(capsule());
      await tester.pump(kPillMorphOpen);
      final state = tester.state<VoiceWaveState>(find.byType(VoiceWave));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
      mic.value = 0.4;
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
      expect(state.samples.last, 0, reason: 'the microphone is not the reply');
      speech.value = 0.3;
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
      expect(state.samples.last, greaterThan(0.5));

      await tester.pumpWidget(capsule(reduce: true));
      await tester.pump(kPillMorphOpen);
      expect(
        tester.state<VoiceWaveState>(find.byType(VoiceWave)).ticking,
        isFalse,
      );
    });
  });

  group('the minimized pill', () {
    // QA 9709: its name, the wave across the rest and ⌄; TalkBack hears the
    // state and «Expandir».
    testWidgets('says the voice is on and opens the capsule', (tester) async {
      final semantics = tester.ensureSemantics();
      var opened = 0;
      await tester.pumpWidget(
        _app(
          VoiceCapsulePill(
            name: 'Hermes',
            state: VoiceStripState.listening,
            statusLabel: 'Escuchando…',
            openLabel: 'Expandir',
            onOpen: () => opened++,
          ),
        ),
      );
      expect(find.text('Hermes'), findsOneWidget);
      final pill = tester.getRect(_key('voice-capsule-pill'));
      final name = tester.getRect(_key('voice-capsule-pill-name'));
      final wave = tester.getRect(_key('voice-capsule-pill-wave'));
      final expand = tester.getRect(_key('voice-capsule-pill-expand'));
      expect(wave.left, greaterThan(name.right));
      expect(wave.right, closeTo(expand.left, 0.5));
      expect(expand.right, lessThanOrEqualTo(pill.right));
      expect(
        tester.getSemantics(_key('voice-capsule-pill')),
        isSemantics(
          label: 'Hermes, Escuchando…',
          hint: 'Expandir',
          isButton: true,
          hasTapAction: true,
        ),
      );
      await tester.tap(_key('voice-capsule-pill'));
      expect(opened, 1);
      semantics.dispose();
    });
  });

  group('the island takes the voice', () {
    Widget island({IslandVoice? voice}) => _app(
      ChatIsland(name: 'Hermes', status: IslandStatus.working, voice: voice),
    );
    // The shell's own, the outermost one.
    final shell = find
        .descendant(
          of: find.byKey(const ValueKey('island')),
          matching: find.byType(AnimatedSize),
        )
        .first;

    RoundedRectangleBorder shape(WidgetTester tester) =>
        tester
                .widget<Material>(
                  find
                      .descendant(
                        of: find.byKey(const ValueKey('island')),
                        matching: find.byType(Material),
                      )
                      .first,
                )
                .shape!
            as RoundedRectangleBorder;

    testWidgets('one shape: the capsule inside the island, radius 28, with '
        'the pill morph', (tester) async {
      final calls = _Calls();
      await tester.pumpWidget(
        island(voice: IslandVoice(expanded: true, child: _capsule(calls))),
      );
      await tester.pump(kPillMorphOpen);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('island')),
          matching: find.byType(VoiceCapsule),
        ),
        findsOneWidget,
      );
      expect(
        shape(tester).borderRadius,
        BorderRadius.circular(IslandMetrics.voiceRadius),
      );
      final size = tester.widget<AnimatedSize>(shell);
      expect(size.duration, kPillMorphOpen);
      expect(size.reverseDuration, kPillMorphClose);
      expect(size.curve, kPillMorphCurve);
    });

    testWidgets('waiting frames it amber, like the island\'s own events', (
      tester,
    ) async {
      final calls = _Calls();
      await tester.pumpWidget(
        island(
          voice: IslandVoice(
            expanded: true,
            tone: voiceCapsuleTone(VoiceStripState.waiting),
            child: _capsule(calls, state: VoiceStripState.waiting),
          ),
        ),
      );
      await tester.pump(kPillMorphOpen);
      final colors = AppTheme.hermesRedDark.hermes;
      expect(shape(tester).side.color, colors.warning.withValues(alpha: 0.7));
    });

    testWidgets('minimized, the island is the voice pill again; gone, the '
        'pill at rest', (tester) async {
      await tester.pumpWidget(
        island(
          voice: IslandVoice(
            expanded: false,
            child: VoiceCapsulePill(
              name: 'Hermes',
              state: VoiceStripState.listening,
              statusLabel: 'Escuchando…',
              openLabel: 'Abrir modo voz',
              onOpen: () {},
            ),
          ),
        ),
      );
      await tester.pump(kPillMorphOpen);
      expect(_key('voice-capsule-pill'), findsOneWidget);
      expect(
        shape(tester).borderRadius,
        BorderRadius.circular(IslandMetrics.radius),
      );

      await tester.pumpWidget(island());
      await tester.pump(kPillMorphClose);
      expect(_key('voice-capsule-pill'), findsNothing);
      expect(find.text('Hermes'), findsOneWidget);
    });
  });

  group('one animation, one surface (review P1)', () {
    Widget island({IslandVoice? voice}) => _app(
      ChatIsland(name: 'Hermes', status: IslandStatus.working, voice: voice),
    );
    final surface = find.byKey(const ValueKey('island'));
    final shell = find
        .descendant(of: surface, matching: find.byType(AnimatedSize))
        .first;

    testWidgets('rest → capsule → rest: the same shell grows and shrinks, '
        'it is never built again', (tester) async {
      final calls = _Calls();
      await tester.pumpWidget(island());
      await tester.pump();
      final element = tester.element(surface);
      final size = tester.state(shell);
      final rest = tester.getSize(surface).height;

      await tester.pumpWidget(
        island(voice: IslandVoice(expanded: true, child: _capsule(calls))),
      );
      expect(tester.element(surface), same(element));
      expect(tester.state(shell), same(size));
      await tester.pump(kPillMorphOpen ~/ 2);
      final opening = tester.getSize(surface).height;
      await tester.pump(kPillMorphOpen);
      final open = tester.getSize(surface).height;
      expect(open, greaterThan(rest));
      expect(opening, greaterThan(rest), reason: 'it grows, it does not cut');
      expect(opening, lessThan(open));

      await tester.pumpWidget(island());
      expect(tester.element(surface), same(element));
      expect(tester.state(shell), same(size));
      await tester.pump(kPillMorphClose ~/ 2);
      final closing = tester.getSize(surface).height;
      expect(closing, lessThan(open), reason: 'it shrinks, it does not cut');
      expect(closing, greaterThan(rest));
      await tester.pump(kPillMorphOpen);
      expect(tester.getSize(surface).height, rest);
    });

    testWidgets('capsule ↔ its minimized pill: the same shell too', (
      tester,
    ) async {
      final calls = _Calls();
      final pill = VoiceCapsulePill(
        name: 'Hermes',
        state: VoiceStripState.listening,
        statusLabel: 'Escuchando…',
        openLabel: 'Abrir modo voz',
        onOpen: () {},
      );
      await tester.pumpWidget(
        island(voice: IslandVoice(expanded: false, child: pill)),
      );
      await tester.pump(kPillMorphOpen);
      final size = tester.state(shell);
      final minimized = tester.getSize(surface).height;
      await tester.pumpWidget(
        island(voice: IslandVoice(expanded: true, child: _capsule(calls))),
      );
      expect(tester.state(shell), same(size));
      await tester.pump(kPillMorphOpen ~/ 2);
      expect(tester.getSize(surface).height, greaterThan(minimized));
      await tester.pumpWidget(
        island(voice: IslandVoice(expanded: false, child: pill)),
      );
      expect(tester.state(shell), same(size));
      await tester.pump(kPillMorphOpen);
    });
  });

  group('the island\'s voice, its notices and its face (review P2)', () {
    Widget island({IslandVoice? voice, double? headroom}) => _app(
      Builder(
        builder: (context) => ChatIsland(
          name: 'Hermes',
          status: IslandStatus.working,
          voice: voice,
          headroom: headroom,
          notices: HermesNotice.feedOf(context),
        ),
      ),
    );
    final surface = find.byKey(const ValueKey('island'));

    testWidgets('a notice with the capsule open is its first row: in the '
        'island, nothing over it', (tester) async {
      final calls = _Calls();
      await tester.pumpWidget(
        island(voice: IslandVoice(expanded: true, child: _capsule(calls))),
      );
      await tester.pump(kPillMorphOpen);
      final capsule = tester.state(find.byType(VoiceCapsule));
      HermesNotice.of(tester.element(find.byType(VoiceCapsule))).show(
        title: 'Fable terminó',
        message: 'Diseño de píldora',
      );
      await tester.pump();
      await tester.pump(kPillMorphOpen);
      final card = find.byType(HermesNoticeCard);
      expect(find.descendant(of: surface, matching: card), findsOneWidget);
      expect(_key('hermes-notice-lane'), findsNothing);
      expect(tester.state(find.byType(VoiceCapsule)), same(capsule));
      expect(
        tester.getRect(card).bottom,
        lessThanOrEqualTo(tester.getRect(_key('voice-capsule')).top),
      );
      // Its own time runs out; the capsule stays.
      await tester.pump(const Duration(seconds: 30));
      await tester.pump(kPillMorphOpen);
      expect(card, findsNothing);
      expect(tester.state(find.byType(VoiceCapsule)), same(capsule));
    });

    testWidgets('minimized, a notice takes the island for its turn and '
        'gives the voice pill back', (tester) async {
      final pill = VoiceCapsulePill(
        name: 'Hermes',
        state: VoiceStripState.listening,
        statusLabel: 'Escuchando…',
        openLabel: 'Abrir modo voz',
        onOpen: () {},
      );
      await tester.pumpWidget(
        island(voice: IslandVoice(expanded: false, child: pill)),
      );
      await tester.pump(kPillMorphOpen);
      HermesNotice.of(tester.element(surface)).show(message: 'Copiado');
      await tester.pump();
      await tester.pump(kPillMorphOpen);
      expect(
        find.descendant(of: surface, matching: find.byType(HermesNoticeCard)),
        findsOneWidget,
      );
      expect(_key('voice-capsule-pill'), findsNothing);
      await tester.pump(const Duration(seconds: 30));
      await tester.pump(kPillMorphOpen);
      expect(_key('voice-capsule-pill'), findsOneWidget);
    });

    testWidgets('minimized: the pill and the face above it open the capsule, '
        '36 + 48 = 84 dp to aim at', (tester) async {
      var opened = 0;
      await tester.pumpWidget(
        island(
          headroom: FloatingChatHeader.faceSize,
          voice: IslandVoice(
            expanded: false,
            onTap: () => opened++,
            child: VoiceCapsulePill(
              name: 'Hermes',
              state: VoiceStripState.listening,
              statusLabel: 'Escuchando…',
              openLabel: 'Abrir modo voz',
              onOpen: () => opened++,
            ),
          ),
        ),
      );
      await tester.pump(kPillMorphOpen);
      final face = tester.getRect(_key('island-headroom'));
      expect(face.height, greaterThanOrEqualTo(48));
      expect(
        tester.getRect(surface).bottom - face.top,
        greaterThanOrEqualTo(84),
      );
      await tester.tap(_key('island-headroom'));
      await tester.tap(_key('voice-capsule-pill'));
      expect(opened, 2);
    });
  });

  testWidgets('the face goes into the capsule: the header\'s fades out and '
      'keeps its room', (tester) async {
    Widget header({required bool hidden}) => _app(
      FloatingChatHeader(
        faces: const SizedBox.square(
          key: ValueKey('default-face'),
          dimension: FloatingChatHeader.faceSize,
        ),
        faceHidden: hidden,
        pill: const ChatIsland(name: 'Hermes', status: IslandStatus.idle),
      ),
    );
    await tester.pumpWidget(header(hidden: false));
    final room = tester.getRect(_key('floating-header-faces'));
    AnimatedOpacity face() =>
        tester.widget(_key('floating-header-faces-visibility'));
    expect(face().opacity, 1);

    await tester.pumpWidget(header(hidden: true));
    await tester.pumpAndSettle();
    expect(face().opacity, 0);
    expect(tester.getRect(_key('floating-header-faces')), room);
  });

  // QA 9709 (the owner): the voice is silent while Hermes works (nothing loops);
  // that the work started is felt: one light tick when what was said turns
  // into work, in the capsule and in its pill.
  testWidgets('one tick when the work starts, none per tool or interim', (
    tester,
  ) async {
    final ticks = <Object?>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') ticks.add(call.arguments);
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    final calls = _Calls();
    Future<void> capsule(VoiceStripState state) async {
      await tester.pumpWidget(_app(_capsule(calls, state: state)));
      await tester.pump(kPillMorphOpen);
    }

    await capsule(VoiceStripState.listening);
    expect(ticks, isEmpty, reason: 'opening the capsule does not tick');
    await capsule(VoiceStripState.thinking);
    expect(ticks, ['HapticFeedbackType.selectionClick']);
    // The same turn: a tool, a spoken interim, the tool going on.
    await capsule(VoiceStripState.toolCall);
    await capsule(VoiceStripState.speaking);
    await capsule(VoiceStripState.toolCall);
    expect(ticks, hasLength(1));
    // The next turn.
    await capsule(VoiceStripState.listening);
    await capsule(VoiceStripState.transcribing);
    await capsule(VoiceStripState.toolCall);
    expect(ticks, hasLength(2));
    // Paused, then working again: nothing was said, no tick.
    await capsule(VoiceStripState.paused);
    await capsule(VoiceStripState.thinking);
    expect(ticks, hasLength(2));

    Widget pill(VoiceStripState state) => _app(
      VoiceCapsulePill(
        name: 'Hermes',
        state: state,
        statusLabel: 'Escuchando…',
        openLabel: 'Abrir modo voz',
        onOpen: () {},
      ),
    );
    await tester.pumpWidget(pill(VoiceStripState.listening));
    expect(ticks, hasLength(2), reason: 'a new pill does not tick');
    await tester.pumpWidget(pill(VoiceStripState.thinking));
    expect(ticks, hasLength(3));
  });

  test('each voice state: its pose, its meter and its frame', () {
    // Every state's look, in the enum's order.
    const expected = <VoiceStripState, _Look>{
      VoiceStripState.loading: (MascotState.idle, VoiceWaveMode.rest, null),
      VoiceStripState.listening: (
        MascotState.idle,
        VoiceWaveMode.listening,
        null,
      ),
      VoiceStripState.transcribing: (
        MascotState.thinking,
        VoiceWaveMode.thinking,
        null,
      ),
      VoiceStripState.thinking: (
        MascotState.thinking,
        VoiceWaveMode.thinking,
        null,
      ),
      VoiceStripState.toolCall: (
        MascotState.tool,
        VoiceWaveMode.thinking,
        null,
      ),
      VoiceStripState.speaking: (
        MascotState.thinking,
        VoiceWaveMode.speaking,
        null,
      ),
      VoiceStripState.waiting: (
        MascotState.needsYou,
        VoiceWaveMode.rest,
        IslandTone.needsYou,
      ),
      VoiceStripState.paused: (MascotState.idle, VoiceWaveMode.rest, null),
      VoiceStripState.error: (
        MascotState.error,
        VoiceWaveMode.rest,
        IslandTone.error,
      ),
    };
    expect(expected.keys, unorderedEquals(VoiceStripState.values));
    for (final MapEntry(key: state, :value) in expected.entries) {
      final (pose, meter, tone) = value;
      expect(voiceCapsuleMascotState(state), pose, reason: state.name);
      expect(voiceCapsuleWaveMode(state), meter, reason: state.name);
      expect(voiceCapsuleTone(state), tone, reason: state.name);
    }
  });
}
