import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/dock_config.dart';
import 'package:hermes_android/core/models/room_summary.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/dock_style.dart';
import 'package:hermes_android/core/widgets/frosted_backdrop.dart';
import 'package:hermes_android/core/widgets/room_summary_pill.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'room_member_status_test.dart' show statusEvent, statusRoom, statusNow;

final _theme = AppTheme.hermesRedDark;
final _colors = _theme.hermes;

Widget _host(
  Widget child, {
  bool disableAnimations = false,
  bool highContrast = false,
}) => MaterialApp(
  theme: _theme,
  locale: const Locale('en'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  builder: (context, app) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      disableAnimations: disableAnimations,
      highContrast: highContrast,
    ),
    child: app!,
  ),
  home: Scaffold(
    body: Align(alignment: Alignment.bottomCenter, child: child),
  ),
);

Widget _dock(double transparency) => SizedBox(
  width: 360,
  child: DockBar(
    style: DockStyle(transparency: transparency),
    children: const [
      Expanded(child: SizedBox()),
      Expanded(child: SizedBox()),
    ],
  ),
);

final _summary = deriveRoomSummary(
  events: [
    statusEvent(1, 'message.user', text: '@forja review the release'),
    statusEvent(2, 'turn.settled', payload: {'task_id': 't', 'passed': true}),
  ],
  members: statusRoom.members,
  localGatewayId: 'gateway',
  now: statusNow,
);

Widget _pill() => RoomSummaryPill(summary: _summary, localGatewayId: 'gateway');

/// Backdrop layers actually pushed to the compositor (what costs raster
/// time), not just widgets in the tree.
int _backdropLayers(WidgetTester tester) =>
    tester.layers.whereType<BackdropFilterLayer>().length;

Color _dockFill(WidgetTester tester) {
  final box = tester.widget<DecoratedBox>(
    find
        .descendant(
          of: find.byType(DockBar),
          matching: find.byType(DecoratedBox),
        )
        .first,
  );
  return (box.decoration as BoxDecoration).color!;
}

Color _pillFill(WidgetTester tester) => tester
    .widget<Material>(find.byKey(const ValueKey('room-summary-pill')))
    .color!;

/// A repaint boundary owned by [owner] that wraps its backdrop filter.
Finder _isolatedBackdrop(Finder owner) => find.ancestor(
  of: find.byType(BackdropFilter),
  matching: find.descendant(of: owner, matching: find.byType(RepaintBoundary)),
);

void main() {
  tearDown(() => FrostedBackdropPolicy.reducedPerformance.value = false);

  group('dock', () {
    testWidgets('a glass dock blurs at rest in its own repaint boundary', (
      tester,
    ) async {
      await tester.pumpWidget(_host(_dock(0.6)));
      final visual = resolveDockVisual(
        _colors,
        const DockStyle(transparency: .6),
      );
      expect(_backdropLayers(tester), 1);
      expect(_dockFill(tester), visual.background);
      // The blurred surface is isolated, so sibling repaints (a scrolling
      // list) never re-record the bar's picture.
      expect(_isolatedBackdrop(find.byType(DockBar)), findsOneWidget);
    });

    testWidgets('an opaque dock has no backdrop filter at all', (tester) async {
      await tester.pumpWidget(_host(_dock(0)));
      expect(find.byType(BackdropFilter), findsNothing);
      expect(_backdropLayers(tester), 0);
    });

    for (final (name, reduced, contrast, lowEnd) in [
      ('reduced motion', true, false, false),
      ('high contrast', false, true, false),
      ('a low-end device', false, false, true),
    ]) {
      testWidgets('$name drops the blur and settles on the at-rest tint', (
        tester,
      ) async {
        FrostedBackdropPolicy.reducedPerformance.value = lowEnd;
        await tester.pumpWidget(
          _host(_dock(0.6), disableAnimations: reduced, highContrast: contrast),
        );
        final visual = resolveDockVisual(
          _colors,
          const DockStyle(transparency: .6),
        );
        expect(_backdropLayers(tester), 0);
        // Without blur, a translucent bar would show sharp rows through it;
        // it takes the colour it has over the empty app background instead.
        expect(
          _dockFill(tester),
          Color.alphaBlend(visual.background, _colors.background),
        );
        expect(_dockFill(tester).a, 1);
      });
    }
  });

  group('room summary pill', () {
    testWidgets('blurs at rest in its own repaint boundary', (tester) async {
      await tester.pumpWidget(_host(_pill()));
      expect(_backdropLayers(tester), 1);
      expect(_pillFill(tester), _colors.surfaceVariant.withValues(alpha: .65));
      expect(_isolatedBackdrop(find.byType(RoomSummaryPill)), findsOneWidget);
    });

    testWidgets('reduced motion, high contrast and low-end drop the blur', (
      tester,
    ) async {
      final atRest = Color.alphaBlend(
        _colors.surfaceVariant.withValues(alpha: .65),
        _colors.background,
      );
      await tester.pumpWidget(_host(_pill(), disableAnimations: true));
      expect(_backdropLayers(tester), 0);
      expect(_pillFill(tester), atRest);

      await tester.pumpWidget(_host(_pill(), highContrast: true));
      expect(_backdropLayers(tester), 0);
      expect(_pillFill(tester), atRest);

      FrostedBackdropPolicy.reducedPerformance.value = true;
      await tester.pumpWidget(_host(_pill()));
      expect(_backdropLayers(tester), 0);
      expect(_pillFill(tester), atRest);
    });

    testWidgets('a policy change keeps the pill state', (tester) async {
      await tester.pumpWidget(_host(_pill()));
      await tester.tap(find.byKey(const ValueKey('room-summary-toggle')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('room-summary-expanded')),
        findsOneWidget,
      );

      FrostedBackdropPolicy.reducedPerformance.value = true;
      await tester.pumpAndSettle();
      expect(_backdropLayers(tester), 0);
      expect(
        find.byKey(const ValueKey('room-summary-expanded')),
        findsOneWidget,
      );
    });
  });

  group('FrostedBackdrop', () {
    Widget frosted(Color tint, {double sigma = 12}) => SizedBox(
      width: 200,
      height: 40,
      child: FrostedBackdrop(
        sigma: sigma,
        tint: tint,
        borderRadius: BorderRadius.circular(20),
        builder: (context, fill) =>
            ColoredBox(key: const ValueKey('fill'), color: fill),
      ),
    );

    Color fill(WidgetTester tester) =>
        tester.widget<ColoredBox>(find.byKey(const ValueKey('fill'))).color;

    testWidgets('an opaque tint never blurs and keeps its clip', (
      tester,
    ) async {
      await tester.pumpWidget(_host(frosted(const Color(0xFF223344))));
      expect(_backdropLayers(tester), 0);
      expect(fill(tester), const Color(0xFF223344));
      expect(find.byType(ClipRRect), findsOneWidget);
    });

    testWidgets('zero sigma paints the child untouched', (tester) async {
      await tester.pumpWidget(
        _host(frosted(const Color(0x80223344), sigma: 0)),
      );
      expect(find.byType(BackdropFilter), findsNothing);
      expect(find.byType(ClipRRect), findsNothing);
      expect(fill(tester), const Color(0x80223344));
    });
  });

  group('FrostedBackdropPolicy.refresh', () {
    const channel = MethodChannel('hermes/platform_info');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    Future<bool> read(Object? reply) async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'getPerformanceClass');
        return reply;
      });
      await FrostedBackdropPolicy.refresh();
      return FrostedBackdropPolicy.reducedPerformance.value;
    }

    test('low-RAM or battery saver reduce, a normal device restores', () async {
      expect(
        await read({'lowRamDevice': true, 'powerSaveMode': false}),
        isTrue,
      );
      expect(
        await read({'lowRamDevice': false, 'powerSaveMode': false}),
        isFalse,
      );
      expect(
        await read({'lowRamDevice': false, 'powerSaveMode': true}),
        isTrue,
      );
      expect(
        await read({'lowRamDevice': false, 'powerSaveMode': false}),
        isFalse,
      );
    });

    test('a missing handler keeps the current value', () async {
      FrostedBackdropPolicy.reducedPerformance.value = true;
      await FrostedBackdropPolicy.refresh();
      expect(FrostedBackdropPolicy.reducedPerformance.value, isTrue);
    });
  });
}
