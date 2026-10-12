import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/activity_snapshot.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/mascot/mascot_atlas.dart';
import 'package:hermes_android/core/widgets/mascot/mascot_cluster.dart';
import 'package:hermes_android/core/widgets/mascot/mascot_demo_page.dart';
import 'package:hermes_android/core/widgets/mascot/mascot_identity.dart';
import 'package:hermes_android/core/widgets/mascot/mascot_sprite.dart';
import 'package:hermes_android/core/widgets/mascot/mascot_state.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

final _reduce = ValueNotifier<bool>(false);

// One theme instance: a fresh ThemeData per pump would start a theme
// animation, and its colour lerp legitimately repaints the tinted sprite.
final _theme = AppTheme.hermesRedDark;

Widget _app(Widget child, {Locale locale = const Locale('es')}) => MaterialApp(
  locale: locale,
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: _theme,
  builder: (context, inner) => ValueListenableBuilder<bool>(
    valueListenable: _reduce,
    builder: (context, reduce, _) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduce),
      child: inner!,
    ),
  ),
  home: Scaffold(body: Center(child: child)),
);

Future<void> _loadAtlases(WidgetTester tester) async {
  await tester.runAsync(() async {
    for (final kind in MascotSpriteKind.values) {
      await MascotAtlas.load(kind);
    }
  });
}

MascotSpriteDebugView _view(WidgetTester tester, [Finder? finder]) =>
    tester.state(finder ?? find.byType(MascotSprite)) as MascotSpriteDebugView;

/// Pumps [total] in [step] slices of fake time and returns the times (ms)
/// at which at least one mascot repainted.
Future<List<int>> _paintTimes(
  WidgetTester tester,
  Duration total, {
  Duration step = const Duration(milliseconds: 10),
}) async {
  final times = <int>[];
  var t = 0;
  while (t < total.inMilliseconds) {
    final before = debugMascotPaintCount;
    await tester.pump(step);
    t += step.inMilliseconds;
    if (debugMascotPaintCount > before) times.add(t);
  }
  return times;
}

/// Most repaints inside any one-second window.
int _maxPerSecond(List<int> times) {
  var best = 0;
  for (var i = 0; i < times.length; i++) {
    var n = 0;
    for (var j = i; j < times.length && times[j] < times[i] + 1000; j++) {
      n++;
    }
    if (n > best) best = n;
  }
  return best;
}

Future<ui.Image> _capture(WidgetTester tester, Key key) async {
  final boundary =
      tester.renderObject(find.byKey(key)) as RenderRepaintBoundary;
  return (await tester.runAsync(() => boundary.toImage(pixelRatio: 3)))!;
}

Future<List<List<int>>> _opaquePixels(
  WidgetTester tester,
  ui.Image image,
) async {
  final data = (await tester.runAsync(
    () => image.toByteData(format: ui.ImageByteFormat.rawStraightRgba),
  ))!;
  final out = <List<int>>[];
  for (var i = 0; i < data.lengthInBytes; i += 4) {
    out.add([
      data.getUint8(i),
      data.getUint8(i + 1),
      data.getUint8(i + 2),
      data.getUint8(i + 3),
    ]);
  }
  return out;
}

void main() {
  setUp(() {
    debugMascotSpritesStill = false;
    _reduce.value = false;
    MascotSprite.appLocked = null;
  });
  tearDown(() {
    debugMascotSpritesStill = true;
    _reduce.value = false;
    MascotSprite.appLocked = null;
  });

  group('state mapping', () {
    const tool = ActivityStep(
      id: 't',
      kind: ActivityStepKind.tool,
      label: 'terminal',
      status: ActivityStepStatus.running,
    );
    const reasoning = ActivityStep(
      id: 'r',
      kind: ActivityStepKind.reasoning,
      label: '',
      status: ActivityStepStatus.running,
    );
    const finished = ActivityStep(
      id: 'd',
      kind: ActivityStepKind.tool,
      label: 'terminal',
      status: ActivityStepStatus.done,
    );
    final table =
        <
          (
            String,
            ActivitySnapshot,
            ({bool offline, bool error, bool done}),
            MascotState,
          )
        >[
          (
            'nothing alive',
            ActivitySnapshot.idle,
            (offline: false, error: false, done: false),
            MascotState.idle,
          ),
          (
            'turn without a step',
            const ActivitySnapshot(turnActive: true),
            (offline: false, error: false, done: false),
            MascotState.thinking,
          ),
          (
            'open reasoning',
            const ActivitySnapshot(turnActive: true, current: reasoning),
            (offline: false, error: false, done: false),
            MascotState.thinking,
          ),
          (
            'running tool',
            const ActivitySnapshot(turnActive: true, current: tool),
            (offline: false, error: false, done: false),
            MascotState.tool,
          ),
          (
            'finished step only',
            const ActivitySnapshot(turnActive: true, current: finished),
            (offline: false, error: false, done: false),
            MascotState.thinking,
          ),
          (
            'permission while a tool runs',
            const ActivitySnapshot(
              turnActive: true,
              current: tool,
              waitingForUser: true,
            ),
            (offline: false, error: false, done: false),
            MascotState.needsYou,
          ),
          (
            'just finished',
            ActivitySnapshot.idle,
            (offline: false, error: false, done: true),
            MascotState.done,
          ),
          (
            'live work beats done',
            const ActivitySnapshot(turnActive: true),
            (offline: false, error: false, done: true),
            MascotState.thinking,
          ),
          (
            'error beats needs you',
            const ActivitySnapshot(waitingForUser: true),
            (offline: false, error: true, done: false),
            MascotState.error,
          ),
          (
            'offline beats everything',
            const ActivitySnapshot(turnActive: true, waitingForUser: true),
            (offline: true, error: true, done: true),
            MascotState.offline,
          ),
        ];
    for (final (name, snapshot, flags, expected) in table) {
      test(name, () {
        expect(
          mascotStateFor(
            snapshot,
            offline: flags.offline,
            error: flags.error,
            justFinished: flags.done,
          ),
          expected,
        );
      });
    }
  });

  group('identity', () {
    test('is deterministic per profile id and overridable', () {
      final a = MascotIdentity.forProfile('profile-forja');
      expect(MascotIdentity.forProfile('profile-forja'), a);
      expect(MascotIdentity.palette, contains(a.color));
      final ids = List<String>.generate(60, (i) => 'bot-$i');
      final sprites = ids.map((id) => MascotIdentity.forProfile(id).sprite);
      final colors = ids.map((id) => MascotIdentity.forProfile(id).color);
      expect(sprites.toSet(), MascotSpriteKind.values.toSet());
      expect(colors.toSet().length, greaterThanOrEqualTo(5));
      final custom = MascotIdentity.forProfile(
        'profile-forja',
        sprite: MascotSpriteKind.violet,
        color: const Color(0xFF123456),
      );
      expect(custom.sprite, MascotSpriteKind.violet);
      expect(custom.color, const Color(0xFF123456));
    });
  });

  group('frame budget', () {
    Future<List<int>> measure(
      WidgetTester tester,
      MascotState state,
      Duration total,
    ) async {
      await _loadAtlases(tester);
      // A fresh mascot per state (a key), so no crossfade is measured.
      await tester.pumpWidget(
        _app(MascotSprite(key: ValueKey(state), state: state)),
      );
      await tester.pump();
      return _paintTimes(tester, total);
    }

    testWidgets('idle only blinks: at most 6 repaints per second', (
      tester,
    ) async {
      final times = await measure(
        tester,
        MascotState.idle,
        const Duration(seconds: 20),
      );
      expect(_maxPerSecond(times), lessThanOrEqualTo(6));
      // It does blink (two repaints per blink, 4.2-8 s apart)...
      expect(times.length, inInclusiveRange(4, 12));
      expect(_view(tester).debugMoving, isTrue);
    });

    for (final state in [
      MascotState.thinking,
      MascotState.tool,
      MascotState.needsYou,
    ]) {
      testWidgets('${state.name} animates at most 30 repaints per second', (
        tester,
      ) async {
        final times = await measure(tester, state, const Duration(seconds: 8));
        expect(_maxPerSecond(times), lessThanOrEqualTo(30));
        expect(times.length, greaterThanOrEqualTo(30));
      });
    }

    testWidgets('a state change crossfades within the 30 fps cap', (
      tester,
    ) async {
      await _loadAtlases(tester);
      await tester.pumpWidget(
        _app(const MascotSprite(state: MascotState.idle)),
      );
      await tester.pump();
      await tester.pumpWidget(
        _app(const MascotSprite(state: MascotState.tool)),
      );
      final times = await _paintTimes(
        tester,
        const Duration(seconds: 2),
        step: const Duration(milliseconds: 4),
      );
      expect(_maxPerSecond(times), lessThanOrEqualTo(30));
      // The crossfade itself repaints (~6 times in its 200 ms), never
      // faster than one frame per 33 ms.
      final fade = times.where((t) => t <= 220).toList();
      expect(fade.length, greaterThanOrEqualTo(5));
      for (var i = 1; i < fade.length; i++) {
        expect(fade[i] - fade[i - 1], greaterThanOrEqualTo(32));
      }
    });

    testWidgets('offline and error hold a pose without a timer', (
      tester,
    ) async {
      for (final state in [MascotState.offline, MascotState.error]) {
        final times = await measure(tester, state, const Duration(seconds: 3));
        expect(times.length, lessThanOrEqualTo(1), reason: state.name);
        expect(debugMascotActiveTimers, 0, reason: state.name);
      }
    });

    testWidgets('done waves once and goes back to idle', (tester) async {
      await _loadAtlases(tester);
      await tester.pumpWidget(
        _app(const MascotSprite(state: MascotState.done)),
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(_view(tester).debugPlaying, MascotState.done);
      expect(
        _view(tester).debugCell,
        inInclusiveRange(MascotCell.wave, MascotCell.wave + 7),
      );
      for (var i = 0; i < 120; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(_view(tester).debugPlaying, MascotState.idle);
      expect(_view(tester).debugCell, MascotCell.bob);
      // And idle keeps its own cheap budget afterwards.
      final times = await _paintTimes(tester, const Duration(seconds: 3));
      expect(_maxPerSecond(times), lessThanOrEqualTo(6));
    });
  });

  group('pauses (0 fps, no timer)', () {
    Future<void> expectFrozen(WidgetTester tester, [String? reason]) async {
      final times = await _paintTimes(tester, const Duration(seconds: 5));
      expect(times, isEmpty, reason: reason);
      expect(debugMascotActiveTimers, 0, reason: reason);
    }

    Future<void> expectMoving(WidgetTester tester) async {
      final times = await _paintTimes(tester, const Duration(seconds: 2));
      expect(times, isNotEmpty);
    }

    testWidgets('while the route is covered', (tester) async {
      await _loadAtlases(tester);
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          locale: const Locale('es'),
          home: const Scaffold(body: MascotSprite(state: MascotState.tool)),
        ),
      );
      await expectMoving(tester);
      navigator.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const Scaffold()),
      );
      await tester.pumpAndSettle();
      expect(
        _view(
          tester,
          find.byType(MascotSprite, skipOffstage: false),
        ).debugMoving,
        isFalse,
      );
      await expectFrozen(tester);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      await expectMoving(tester);
    });

    testWidgets('while the app is in the background', (tester) async {
      await _loadAtlases(tester);
      await tester.pumpWidget(
        _app(const MascotSprite(state: MascotState.tool)),
      );
      await expectMoving(tester);
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pump();
      await expectFrozen(tester);
      for (final state in [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pump();
      await expectMoving(tester);
    });

    testWidgets('while the App Lock is locked', (tester) async {
      await _loadAtlases(tester);
      final locked = ValueNotifier<bool>(false);
      addTearDown(locked.dispose);
      MascotSprite.appLocked = locked;
      await tester.pumpWidget(
        _app(const MascotSprite(state: MascotState.thinking)),
      );
      await expectMoving(tester);
      locked.value = true;
      await tester.pump();
      await expectFrozen(tester);
      locked.value = false;
      await tester.pump();
      await expectMoving(tester);
    });

    testWidgets('with reduced motion: the still pose of each state', (
      tester,
    ) async {
      await _loadAtlases(tester);
      _reduce.value = true;
      for (final state in MascotState.values) {
        await tester.pumpWidget(_app(MascotSprite(state: state)));
        await tester.pump();
        expect(
          _view(tester).debugCell,
          MascotProgram.staticCell(state),
          reason: state.name,
        );
        await expectFrozen(tester, state.name);
      }
      _reduce.value = false;
      await tester.pump();
      await expectMoving(tester);
    });
  });

  group('header presence', () {
    testWidgets('counts header mascots on the visible route only', (
      tester,
    ) async {
      debugMascotSpritesStill = true;
      final navigator = GlobalKey<NavigatorState>();
      Widget app({required bool header}) => MaterialApp(
        navigatorKey: navigator,
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        locale: const Locale('es'),
        home: Scaffold(
          body: MascotSprite(state: MascotState.idle, header: header),
        ),
      );
      await tester.pumpWidget(app(header: false));
      await tester.pump();
      expect(MascotSprite.visibleHeaders.value, 0);
      await tester.pumpWidget(app(header: true));
      await tester.pump();
      expect(MascotSprite.visibleHeaders.value, 1);
      navigator.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const Scaffold()),
      );
      await tester.pumpAndSettle();
      expect(MascotSprite.visibleHeaders.value, 0);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(MascotSprite.visibleHeaders.value, 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(MascotSprite.visibleHeaders.value, 0);
    });
  });

  group('pixels', () {
    const key = Key('mascot-boundary');

    Future<List<List<int>>> render(
      WidgetTester tester,
      MascotState state, {
      MascotIdentity identity = MascotIdentity.hermes,
      double size = MascotSprite.large,
    }) async {
      await _loadAtlases(tester);
      _reduce.value = true;
      await tester.pumpWidget(
        _app(
          RepaintBoundary(
            key: key,
            child: MascotSprite(state: state, identity: identity, size: size),
          ),
        ),
      );
      await tester.pump();
      final image = await _capture(tester, key);
      return _opaquePixels(tester, image);
    }

    /// Body pixels: opaque and bright (eyes are dark).
    void expectTint(List<List<int>> px, Color color) {
      final want = [
        (color.r * 255).round(),
        (color.g * 255).round(),
        (color.b * 255).round(),
      ];
      final peak = want.reduce((a, b) => a > b ? a : b);
      // Body pixels: opaque and nearly as bright as the tint (the eyes and
      // their anti-aliased rims are darker).
      final b = px
          .where(
            (p) =>
                p[3] >= 250 &&
                p.take(3).reduce((a, b) => a > b ? a : b) >= peak * 0.9,
          )
          .toList();
      expect(b.length, greaterThan(2000));
      final off = b.where(
        (p) =>
            (p[0] - want[0]).abs() > 4 ||
            (p[1] - want[1]).abs() > 4 ||
            (p[2] - want[2]).abs() > 4,
      );
      expect(off.length, lessThan(b.length * 0.02));
    }

    testWidgets('idle wears the identity colour', (tester) async {
      final identity = MascotIdentity.forProfile('lira');
      expectTint(
        await render(tester, MascotState.idle, identity: identity),
        identity.color,
      );
    });

    testWidgets('needs you is amber (the theme warning colour)', (
      tester,
    ) async {
      final px = await render(tester, MascotState.needsYou);
      expectTint(px, _theme.hermes.warning);
    });

    testWidgets('error is red with X eyes', (tester) async {
      expectTint(
        await render(tester, MascotState.error),
        MascotSprite.errorColor,
      );
    });

    testWidgets('crisp at 3x: sharp edges and the expected body size', (
      tester,
    ) async {
      final px = await render(tester, MascotState.idle);
      // 40 dp at 3x = 120 px; the Pixel body is 110/140 of the cell.
      var minX = 1 << 30, maxX = -1;
      for (var i = 0; i < px.length; i++) {
        if (px[i][3] < 128) continue;
        final x = i % 120;
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
      }
      expect(maxX - minX + 1, inInclusiveRange(90, 98));
      final opaque = px.where((p) => p[3] >= 250).length;
      final soft = px.where((p) => p[3] > 0 && p[3] < 250).length;
      expect(soft, lessThan(opaque * 0.12));
    });

    testWidgets('a blink closes the eyes', (tester) async {
      await _loadAtlases(tester);
      await tester.pumpWidget(
        _app(
          const RepaintBoundary(
            key: key,
            child: MascotSprite(
              state: MascotState.idle,
              size: MascotSprite.large,
            ),
          ),
        ),
      );
      await tester.pump();
      int dark(List<List<int>> px) =>
          px.where((p) => p[3] >= 250 && p[0] < 80 && p[1] < 80).length;
      final open = dark(
        await _opaquePixels(tester, await _capture(tester, key)),
      );
      var guard = 0;
      while (_view(tester).debugCell != MascotCell.eyesClosed &&
          guard++ < 1000) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(_view(tester).debugCell, MascotCell.eyesClosed);
      final closed = dark(
        await _opaquePixels(tester, await _capture(tester, key)),
      );
      expect(open, greaterThan(150));
      expect(closed, lessThan(open * 0.4));
    });
  });

  group('labels', () {
    testWidgets('one label per state, in Spanish and English', (tester) async {
      debugMascotSpritesStill = true;
      const es = {
        MascotState.idle: 'Hermes está en reposo',
        MascotState.thinking: 'Hermes está pensando',
        MascotState.tool: 'Hermes está usando una herramienta',
        MascotState.needsYou: 'Hermes te necesita',
        MascotState.done: 'Hermes ha terminado',
        MascotState.offline: 'Hermes está sin conexión',
        MascotState.error: 'Hermes ha tenido un error',
      };
      const en = {
        MascotState.idle: 'Hermes is idle',
        MascotState.thinking: 'Hermes is thinking',
        MascotState.tool: 'Hermes is using a tool',
        MascotState.needsYou: 'Hermes needs you',
        MascotState.done: 'Hermes is done',
        MascotState.offline: 'Hermes is offline',
        MascotState.error: 'Hermes hit an error',
      };
      for (final (locale, labels) in [
        (const Locale('es'), es),
        (const Locale('en'), en),
      ]) {
        for (final state in MascotState.values) {
          await tester.pumpWidget(
            _app(MascotSprite(state: state), locale: locale),
          );
          expect(find.bySemanticsLabel(labels[state]!), findsOneWidget);
        }
      }
    });
  });

  group('cluster', () {
    MascotClusterMember member(String name) => MascotClusterMember(
      name: name,
      identity: MascotIdentity.forProfile(name),
    );

    testWidgets('shows up to three faces and +N', (tester) async {
      debugMascotSpritesStill = true;
      await tester.pumpWidget(
        _app(
          MascotCluster(
            members: [
              for (final n in ['Forja', 'Radar', 'Lira', 'Nube', 'Eco'])
                member(n),
            ],
          ),
        ),
      );
      expect(find.byType(MascotSprite), findsNWidgets(3));
      expect(find.text('+2'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Forja, Radar, Lira y 2 más'),
        findsOneWidget,
      );
      // The first member is in front, the faces overlap.
      final first = tester.getRect(
        find.byKey(const ValueKey('mascot-cluster-0')),
      );
      final second = tester.getRect(
        find.byKey(const ValueKey('mascot-cluster-1')),
      );
      expect(second.left, lessThan(first.right));
      expect(second.left, greaterThan(first.left));
    });

    testWidgets('no +N chip with three or fewer', (tester) async {
      debugMascotSpritesStill = true;
      await tester.pumpWidget(
        _app(MascotCluster(members: [member('Forja'), member('Radar')])),
      );
      expect(find.byType(MascotSprite), findsNWidgets(2));
      expect(find.byKey(const ValueKey('mascot-cluster-more')), findsNothing);
    });
  });

  testWidgets('the demo page builds every state', (tester) async {
    debugMascotSpritesStill = true;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        locale: const Locale('en'),
        home: const MascotDemoPage(),
      ),
    );
    for (final state in MascotState.values) {
      await tester.tap(find.text(state.name).first);
      await tester.pump();
    }
    expect(tester.takeException(), isNull);
  });
}
