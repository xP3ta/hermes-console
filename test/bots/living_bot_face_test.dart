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

    testWidgets('entrance scales in, then idle keeps breathing continuously', (
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
      // Idle is alive while on screen: the clock keeps running (no bursts
      // with dead rests in between) and the face keeps its motion gain.
      final face = tester.widget<HermesBotFace>(find.byType(HermesBotFace));
      expect(face.motionGain, greaterThan(1));
      final clock = face.clock!;
      for (var i = 0; i < 4; i++) {
        final before = clock.value;
        await tester.pump(const Duration(seconds: 3));
        expect(clock.value, greaterThan(before));
        expect(livingBotFaceActiveTickers, 1);
        expect(tester.binding.hasScheduledFrame, isTrue);
      }
      await tester.pumpWidget(const SizedBox());
      expect(livingBotFaceActiveTickers, 0);
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

    testWidgets('idle faces tick only while on screen', (tester) async {
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
      await tester.pump(const Duration(milliseconds: 100));
      final built = find.byType(LivingBotFace).evaluate().length;
      expect(built, lessThan(20));
      expect(livingBotFaceActiveTickers, built);
      await tester.pumpWidget(const SizedBox());
      expect(livingBotFaceActiveTickers, 0);
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
