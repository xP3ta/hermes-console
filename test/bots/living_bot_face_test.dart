import 'package:flutter/material.dart';
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

    testWidgets('entrance scales in, then idle holds still and only blinks', (
      tester,
    ) async {
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
      expect(face.animate, isFalse, reason: 'no continuous idle motion');
      final clock = face.clock!;
      final blink = face.blink!;
      final rest = clock.value;
      // Idle must stop producing frames: over 20 s the face wakes up only
      // for short one-shot blinks.
      var busy = 0;
      var blinkFrames = 0;
      const steps = 200;
      for (var i = 0; i < steps; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (tester.binding.transientCallbackCount > 0) busy++;
        if (blink.value > 0) blinkFrames++;
      }
      expect(clock.value, rest, reason: 'the motion clock never runs idle');
      expect(livingBotFaceActiveTickers, 0);
      expect(livingBotFacePendingBlinks, lessThanOrEqualTo(1));
      expect(busy, lessThan(steps ~/ 10), reason: 'busy in $busy samples');
      expect(blinkFrames, greaterThan(0), reason: 'idle still blinks');
      await tester.pumpWidget(const SizedBox());
      expect(livingBotFaceActiveTickers, 0);
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
      expect(ticks, 0);
      expect(clock.value, frozen);
      expect(
        tester.widget<HermesBotFace>(find.byType(HermesBotFace)).animate,
        isFalse,
      );
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

    testWidgets('a roster of idle faces settles (no running clock)', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          ListView.builder(
            // ignore: deprecated_member_use
            cacheExtent: 0,
            itemCount: 20,
            itemExtent: 100,
            itemBuilder: (context, index) => Center(
              child: LivingBotFace(
                profileName: 'idle_$index',
                signal: BotFaceSignal.idle,
                size: 48,
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(LivingBotFace), findsWidgets);
      expect(livingBotFaceActiveTickers, 0);
      // Blinks are one-shot and staggered: most of the time nothing ticks.
      var busy = 0;
      const steps = 100;
      for (var i = 0; i < steps; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (tester.binding.transientCallbackCount > 0) busy++;
      }
      expect(busy, lessThan(steps ~/ 2), reason: 'busy in $busy samples');
      await tester.pumpWidget(const SizedBox());
      expect(livingBotFaceActiveTickers, 0);
    });

    testWidgets('idle faces in a covered route never blink or tick', (
      tester,
    ) async {
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
      for (var i = 0; i < 200; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.binding.transientCallbackCount, 0);
        expect(tester.binding.hasScheduledFrame, isFalse);
        expect(livingBotFacePendingBlinks, 0, reason: 'no wake-ups covered');
      }
      expect(
        tester.widget<HermesBotFace>(find.byType(HermesBotFace)).blink,
        isNull,
      );
      // Uncovered again: the face comes back to life with its blinks.
      visible.value = true;
      await tester.pump();
      final blink = tester
          .widget<HermesBotFace>(find.byType(HermesBotFace))
          .blink!;
      var blinked = false;
      for (var i = 0; i < 100 && !blinked; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        blinked = blink.value > 0;
      }
      expect(blinked, isTrue);
      await tester.pumpWidget(const SizedBox());
      expect(livingBotFacePendingBlinks, 0);
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
      expect(face.blink, isNull);
      expect(livingBotFacePendingBlinks, 0);
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
