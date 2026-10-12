import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/ui/roster/living_bot_face.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_bot_face.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

Widget _app(Widget child, {bool reduceMotion = false}) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.hermesRedDark,
  home: MediaQuery(
    data: MediaQueryData(
      size: const Size(400, 800),
      disableAnimations: reduceMotion,
    ),
    child: Scaffold(body: child),
  ),
);

/// 20 working faces in a list that only builds on-screen rows.
Widget _roster({bool reduceMotion = false}) => _app(
  ListView.builder(
    // ignore: deprecated_member_use
    cacheExtent: 0,
    itemCount: 20,
    itemExtent: 100,
    itemBuilder: (context, index) => Center(
      child: LivingBotFace(
        key: ValueKey('face-$index'),
        profileName: 'bot_$index',
        signal: BotFaceSignal.working,
        size: 48,
      ),
    ),
  ),
  reduceMotion: reduceMotion,
);

void main() {
  setUp(() => debugLivingBotFacesStill = false);
  tearDown(() => debugLivingBotFacesStill = true);

  group('LivingBotFace motion mapping (spec 070 § Motion)', () {
    test('each state maps to a HermesBotFace pose', () {
      expect(BotFaceSignal.idle.motionState, HermesBotFaceMotionState.idle);
      expect(
        BotFaceSignal.thinking.motionState,
        HermesBotFaceMotionState.thinking,
      );
      expect(
        BotFaceSignal.speaking.motionState,
        HermesBotFaceMotionState.speaking,
      );
      expect(
        BotFaceSignal.working.motionState,
        HermesBotFaceMotionState.working,
      );
      expect(
        BotFaceSignal.attention.motionState,
        HermesBotFaceMotionState.listening,
      );
      expect(BotFaceSignal.working.hasRing, isTrue);
      expect(BotFaceSignal.attention.hasRing, isTrue);
      expect(BotFaceSignal.idle.hasRing, isFalse);
    });

    testWidgets('one shared clock drives the Blobatar (no inner ticker)', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          const LivingBotFace(
            profileName: 'astra',
            signal: BotFaceSignal.thinking,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      final face = tester.widget<HermesBotFace>(find.byType(HermesBotFace));
      expect(face.clock, isNotNull);
      expect(face.animate, isTrue);
      expect(face.motionState, HermesBotFaceMotionState.thinking);
      expect(livingBotFaceActiveTickers, 1);
      await tester.pumpWidget(const SizedBox());
      expect(livingBotFaceActiveTickers, 0);
    });

    testWidgets('entrance scales in, then idle breathes, blinks and glances '
        'on the shared idle clock', (tester) async {
      await tester.pumpWidget(
        _app(
          const LivingBotFace(profileName: 'idle', signal: BotFaceSignal.idle),
        ),
      );
      await tester.pump(const Duration(milliseconds: 16));
      Opacity opacity() => tester.widget<Opacity>(
        find.descendant(
          of: find.byType(LivingBotFace),
          matching: find.byType(Opacity),
        ),
      );
      expect(opacity().opacity, lessThan(1));
      await tester.pump(const Duration(milliseconds: 500));
      expect(opacity().opacity, 1);
      final face = tester.widget<HermesBotFace>(find.byType(HermesBotFace));
      expect(face.animate, isTrue, reason: 'an idle visible face is alive');
      expect(face.motionState, HermesBotFaceMotionState.idle);
      expect(identical(face.clock, livingBotFaceIdleClock), isTrue);
      expect(livingBotFaceIdleFaces, 1);
      expect(livingBotFaceActiveTickers, 0, reason: 'no busy clock idle');
      expect(livingBotFaceClockTimers, 1);
      var ticks = 0;
      void count() => ticks++;
      livingBotFaceIdleClock.addListener(count);
      addTearDown(() => livingBotFaceIdleClock.removeListener(count));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      // 12.5 fps, never the display rate; and never a vsync ticker.
      expect(ticks, inInclusiveRange(11, 14));
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(const SizedBox());
      expect(livingBotFaceIdleFaces, 0);
      expect(livingBotFaceClockTimers, 0);
    });

    testWidgets('busy motion is capped and stops when the work ends', (
      tester,
    ) async {
      final signal = ValueNotifier(BotFaceSignal.working);
      addTearDown(signal.dispose);
      await tester.pumpWidget(
        _app(
          ValueListenableBuilder<BotFaceSignal>(
            valueListenable: signal,
            builder: (context, value, _) => LivingBotFace(
              profileName: 'forja',
              signal: value,
              entrance: false,
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 16));
      final face = tester.widget<HermesBotFace>(find.byType(HermesBotFace));
      expect(face.animate, isTrue);
      expect(livingBotFaceActiveTickers, 1);
      final clock = face.clock!;
      var ticks = 0;
      void count() => ticks++;
      clock.addListener(count);
      addTearDown(() => clock.removeListener(count));
      // One second sampled at the Pixel's 120 Hz vsync.
      for (var i = 0; i < 120; i++) {
        await tester.pump(const Duration(microseconds: 8333));
      }
      expect(ticks, inInclusiveRange(25, 32), reason: '~30 fps, not 120');
      signal.value = BotFaceSignal.idle;
      await tester.pump();
      expect(livingBotFaceActiveTickers, 0);
      final frozen = clock.value;
      ticks = 0;
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(ticks, 0, reason: 'the busy clock stopped with the work');
      expect(clock.value, frozen);
      final idle = tester.widget<HermesBotFace>(find.byType(HermesBotFace));
      expect(idle.animate, isTrue, reason: 'idle stays alive');
      expect(identical(idle.clock, livingBotFaceIdleClock), isTrue);
      expect(livingBotFaceClockTimers, 1);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('pinned-size faces are more expressive than row faces', (
      tester,
    ) async {
      expect(
        LivingBotFace.expressivenessFor(60),
        greaterThan(LivingBotFace.expressivenessFor(48)),
      );
    });

    test('idle breath, blink and glance are all visible within 6 s', () {
      final frames = [
        for (var ms = 0; ms <= 6000; ms += 16)
          hermesBlobatarMotionSnapshot(
            'astra',
            Duration(milliseconds: ms),
          ).scaled(
            LivingBotFace.expressivenessFor(48),
            eyeGain: LivingBotFace.eyeGainFor(
              LivingBotFace.expressivenessFor(48),
            ),
          ),
      ];
      final breath = frames.map((f) => f.breatheScaleX);
      expect(
        breath.reduce((a, b) => a > b ? a : b) -
            breath.reduce((a, b) => a < b ? a : b),
        allOf(greaterThan(.02), lessThan(.035)),
      );
      expect(frames.any((f) => f.blinkScaleY < .3), isTrue);
      expect(frames.any((f) => f.eyeOffsetX.abs() > 2), isTrue);
    });

    test('working eyes scan a line; thinking eyes wander', () {
      List<double> xs(HermesBotFaceMotionState state) => [
        for (var ms = 0; ms <= 2700; ms += 30)
          hermesBlobatarMotionSnapshot(
            'forja',
            Duration(milliseconds: ms),
            state: state,
          ).eyeOffsetX,
      ];
      double span(List<double> v) =>
          v.reduce((a, b) => a > b ? a : b) - v.reduce((a, b) => a < b ? a : b);
      expect(span(xs(HermesBotFaceMotionState.working)), greaterThan(1.5));
      expect(span(xs(HermesBotFaceMotionState.thinking)), greaterThan(.8));
      expect(
        BotFaceSignal.working.motionState,
        HermesBotFaceMotionState.working,
      );
    });
  });

  group('T405 perf: 20 animated faces', () {
    testWidgets('only on-screen faces tick', (tester) async {
      await tester.pumpWidget(_roster());
      await tester.pump(const Duration(milliseconds: 100));
      final built = find.byType(LivingBotFace).evaluate().length;
      expect(built, lessThan(20));
      expect(livingBotFaceActiveTickers, built);
      // Scroll: off-screen faces are disposed, new ones take their place;
      // the count of ticking clocks tracks the visible faces only.
      await tester.drag(find.byType(ListView), const Offset(0, -900));
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        livingBotFaceActiveTickers,
        find.byType(LivingBotFace).evaluate().length,
      );
      expect(livingBotFaceActiveTickers, lessThan(20));
      await tester.pumpWidget(const SizedBox());
      expect(livingBotFaceActiveTickers, 0);
    });

    testWidgets('twelve faces, idle and busy, run at most two timers and '
        'a tick repaints without rebuilding', (tester) async {
      await tester.pumpWidget(
        _app(
          Wrap(
            children: [
              for (var i = 0; i < 12; i++)
                LivingBotFace(
                  key: ValueKey('grid-face-$i'),
                  profileName: 'grid_$i',
                  signal: i < 4 ? BotFaceSignal.working : BotFaceSignal.idle,
                  size: 52,
                  entrance: false,
                  style: LivingBotFaceStyle.calm,
                ),
            ],
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(livingBotFaceIdleFaces, 8);
      expect(livingBotFaceActiveTickers, 4);
      expect(livingBotFaceClockTimers, 2, reason: 'one idle, one busy');
      expect(tester.binding.transientCallbackCount, 0, reason: 'no vsync');

      var rebuilds = 0;
      var paints = 0;
      debugOnRebuildDirtyWidget = (element, builtOnce) => rebuilds++;
      debugProfilePaintsEnabled = true;
      debugOnProfilePaint = (object) {
        if (object is RenderCustomPaint) paints++;
      };
      addTearDown(() {
        debugOnRebuildDirtyWidget = null;
        debugProfilePaintsEnabled = false;
        debugOnProfilePaint = null;
      });
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(paints, greaterThan(12 * 5), reason: 'every face kept moving');
      expect(rebuilds, 0, reason: 'clock ticks only repaint the faces');
      debugOnRebuildDirtyWidget = null;
      debugProfilePaintsEnabled = false;
      debugOnProfilePaint = null;
      await tester.pumpWidget(const SizedBox());
      expect(livingBotFaceClockTimers, 0);
    });

    testWidgets('a backgrounded app stops every face clock and resumes', (
      tester,
    ) async {
      await tester.pumpWidget(_roster());
      await tester.pump(const Duration(milliseconds: 100));
      expect(livingBotFaceClockTimers, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(livingBotFaceClockTimers, 0, reason: 'no timer in background');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(livingBotFaceClockTimers, 1);
      await tester.pumpWidget(const SizedBox());
      expect(livingBotFaceClockTimers, 0);
    });

    testWidgets('idle faces in a covered route never tick', (tester) async {
      final visible = ValueNotifier(false);
      addTearDown(visible.dispose);
      await tester.pumpWidget(
        _app(
          ValueListenableBuilder<bool>(
            valueListenable: visible,
            builder: (context, on, _) => TickerMode(
              enabled: on,
              child: const LivingBotFace(
                profileName: 'argos',
                signal: BotFaceSignal.idle,
                entrance: false,
              ),
            ),
          ),
        ),
      );
      for (var i = 0; i < 50; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.binding.hasScheduledFrame, isFalse);
        expect(livingBotFaceClockTimers, 0, reason: 'no wake-ups covered');
      }
      expect(
        tester.widget<HermesBotFace>(find.byType(HermesBotFace)).animate,
        isFalse,
      );
      // Uncovered again: the face comes back to life on the idle clock.
      visible.value = true;
      await tester.pump();
      expect(livingBotFaceIdleFaces, 1);
      expect(livingBotFaceClockTimers, 1);
      expect(
        tester.widget<HermesBotFace>(find.byType(HermesBotFace)).animate,
        isTrue,
      );
      await tester.pumpWidget(const SizedBox());
      expect(livingBotFaceClockTimers, 0);
    });

    testWidgets('reduced motion stops every ticker but keeps the state', (
      tester,
    ) async {
      await tester.pumpWidget(_roster(reduceMotion: true));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(LivingBotFace), findsWidgets);
      expect(livingBotFaceActiveTickers, 0);
      expect(tester.binding.hasScheduledFrame, isFalse);
      // The working state is still readable from the static ring.
      expect(
        find.byKey(const ValueKey('living-face-ring-working')),
        findsWidgets,
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('reduced motion keeps an idle face fully static', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          const LivingBotFace(profileName: 'argos', signal: BotFaceSignal.idle),
          reduceMotion: true,
        ),
      );
      for (var i = 0; i < 100; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.binding.hasScheduledFrame, isFalse);
      }
      final face = tester.widget<HermesBotFace>(find.byType(HermesBotFace));
      expect(face.animate, isFalse);
      expect(livingBotFaceClockTimers, 0);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('background routes pause faces (TickerMode)', (tester) async {
      await tester.pumpWidget(
        _app(
          TickerMode(
            enabled: false,
            child: ListView(
              children: [
                for (var i = 0; i < 4; i++)
                  LivingBotFace(
                    profileName: 'b$i',
                    signal: BotFaceSignal.working,
                  ),
              ],
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(livingBotFaceActiveTickers, 0);
      expect(livingBotFaceClockTimers, 0);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('animate: false and a host-drawn state mark', (tester) async {
      await tester.pumpWidget(
        _app(
          const Column(
            children: [
              LivingBotFace(
                key: ValueKey('still'),
                profileName: 'history',
                signal: BotFaceSignal.idle,
                animate: false,
              ),
              LivingBotFace(
                key: ValueKey('unmarked'),
                profileName: 'home',
                signal: BotFaceSignal.working,
                stateMark: false,
                style: LivingBotFaceStyle.dots,
              ),
            ],
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      HermesBotFace faceOf(String key) => tester.widget<HermesBotFace>(
        find.descendant(
          of: find.byKey(ValueKey(key)),
          matching: find.byType(HermesBotFace),
        ),
      );
      expect(faceOf('still').animate, isFalse);
      expect(livingBotFaceIdleFaces, 0, reason: 'a still face rides nothing');
      // No ring/orbit, but the face still moves with its state.
      expect(
        find.byKey(const ValueKey('living-face-ring-working')),
        findsNothing,
      );
      expect(faceOf('unmarked').animate, isTrue);
      expect(faceOf('unmarked').motionState, HermesBotFaceMotionState.working);
      expect(livingBotFaceActiveTickers, 1);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('Desktop face metadata', () {
    test('a bare Blobatar silhouette renders as that living silhouette', () {
      const astra = AgentProfile(
        name: 'console-lead',
        hasAvatar: true,
        botModeUiMeta: {'shape': 'sun', 'color': '#d4a72c'},
      );
      expect(astra.botFaceShape, 'blobatar::sun');
      // The PNG next to shape metadata is Desktop's backfill, not a photo.
      expect(astra.botPaintsPhoto, isFalse);
      const hermes = AgentProfile(
        name: 'default',
        hasAvatar: true,
        botModeUiMeta: {'shape': 'circle', 'imageKind': 'photo'},
      );
      expect(hermes.botPaintsPhoto, isTrue);
      const plain = AgentProfile(name: 'x', hasAvatar: true);
      expect(plain.botPaintsPhoto, isTrue);
      expect(
        const AgentProfile(
          name: 'y',
          botModeUiMeta: {'shape': 'blobatar:abc:cloud'},
        ).botFaceShape,
        'blobatar:abc:cloud',
      );
    });

    testWidgets('a Desktop-backfilled bot gets the living face, not the PNG', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          const LivingBotFace(
            profileName: 'console-lead',
            profile: AgentProfile(
              name: 'console-lead',
              hasAvatar: true,
              botModeUiMeta: {'shape': 'sun'},
            ),
            signal: BotFaceSignal.idle,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
      final face = tester.widget<HermesBotFace>(find.byType(HermesBotFace));
      expect((face.visual as HermesBlobatarFaceVisual).resolvedKind, 'sun');
      await tester.pumpWidget(const SizedBox());
    });
  });
}
