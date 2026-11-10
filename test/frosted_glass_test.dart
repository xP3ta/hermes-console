// Q9-CHAT5 v2 (the owner): the glass of what floats, and the rules on its cost,
// as requirements. (1) a moderate blur, the light veil does the effect;
// (2) ONE blurring layer per zone; (3) every frosted surface in its own
// repaint boundary; (4) without blur (low end, battery saver, the system's
// blur switch, reduced motion, high contrast standing for reduced
// transparency) the veil, a hairline and a shadow; (6) a mid or low range
// device has no blur by default until the measured cost says otherwise.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/glass_strip.dart';
import 'package:hermes_android/core/design/tokens.dart' show HermesChrome;
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/frosted_backdrop.dart';

final _theme = AppTheme.hermesRedDark;
final _colors = _theme.hermes;

Widget _host(
  Widget child, {
  bool disableAnimations = false,
  bool highContrast = false,
}) => MaterialApp(
  theme: _theme,
  builder: (context, app) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      disableAnimations: disableAnimations,
      highContrast: highContrast,
    ),
    child: app!,
  ),
  home: Scaffold(
    body: Stack(
      children: [
        // Something to frost: text behind the glass.
        ListView(
          children: [
            for (var i = 0; i < 30; i++) Text('Línea $i del transcript'),
          ],
        ),
        Align(alignment: Alignment.bottomCenter, child: child),
      ],
    ),
  ),
);

Widget _glass(
  String id, {
  FrostedZone zone = FrostedZone.none,
  int priority = 0,
  Widget? child,
}) => SizedBox(
  width: 200,
  height: 36,
  child: FrostedBackdrop.glass(
    key: ValueKey(id),
    zone: zone,
    zonePriority: priority,
    borderRadius: BorderRadius.circular(18),
    child: child ?? const SizedBox.expand(),
  ),
);

/// Backdrop layers actually pushed to the compositor (what costs raster).
int _backdropLayers(WidgetTester tester) =>
    tester.layers.whereType<BackdropFilterLayer>().length;

BoxDecoration _surface(WidgetTester tester, String id) =>
    tester
            .widget<DecoratedBox>(
              find.descendant(
                of: find.byKey(ValueKey(id)),
                matching: find.byKey(const ValueKey('frosted-glass')),
              ),
            )
            .decoration
        as BoxDecoration;

List<BoxShadow> _shadow(WidgetTester tester, String id) =>
    ((tester
                .widget<DecoratedBox>(
                  find.descendant(
                    of: find.byKey(ValueKey(id)),
                    matching: find.byKey(
                      const ValueKey('frosted-glass-shadow'),
                    ),
                  ),
                )
                .decoration
            as BoxDecoration)
        .boxShadow ??
    const []);

void main() {
  tearDown(() {
    FrostedBackdropPolicy.reducedPerformance.value = false;
    FrostedBackdropPolicy.blurAllowed.value = true;
  });

  for (final retainedStrip in [false, true]) {
    testWidgets(
      'zone lifecycle: reparented ${retainedStrip ? 'strip' : 'legacy'} '
      'retains draft and releases its zone',
      (tester) async {
        final ownerKey = GlobalKey();
        final fieldKey = GlobalKey();
        final controller = TextEditingController(text: 'borrador conservado')
          ..selection = const TextSelection(baseOffset: 2, extentOffset: 8);
        addTearDown(controller.dispose);
        Widget strip({Key? key, int priority = 0, required Widget child}) =>
            HermesGlassStrip(
              key: key,
              zone: FrostedZone.bottom,
              priority: priority,
              child: Builder(
                builder: (context) => HermesGlassPiece(
                  shape: const StadiumBorder(),
                  child: ColoredBox(
                    color:
                        HermesGlassStrip.of(context)?.veil ??
                        HermesChrome.of(_colors).opaque,
                    child: SizedBox(width: 200, height: 36, child: child),
                  ),
                ),
              ),
            );
        final field = Material(
          type: MaterialType.transparency,
          child: TextField(
            key: fieldKey,
            controller: controller,
            decoration: const InputDecoration.collapsed(hintText: ''),
          ),
        );
        final retained = retainedStrip
            ? strip(key: ownerKey, child: field)
            : SizedBox(
                width: 200,
                height: 36,
                child: FrostedBackdrop.glass(
                  key: ownerKey,
                  zone: FrostedZone.bottom,
                  borderRadius: BorderRadius.circular(18),
                  child: field,
                ),
              );
        await tester.pumpWidget(
          _host(
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _glass('old-low', zone: FrostedZone.bottom),
                _glass('old-high', zone: FrostedZone.bottom, priority: 1),
                KeyedSubtree(
                  key: const ValueKey('left-parent'),
                  child: retained,
                ),
              ],
            ),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(_backdropLayers(tester), 1);
        final beforeOwner = ownerKey.currentState;
        final beforeField = tester.state(find.byKey(fieldKey));
        final selection = controller.selection;

        final competitor = retainedStrip
            ? _glass('new-high', zone: FrostedZone.bottom, priority: 2)
            : strip(priority: 2, child: const SizedBox());
        await tester.pumpWidget(
          _host(
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                KeyedSubtree(
                  key: const ValueKey('right-parent'),
                  child: retained,
                ),
                competitor,
              ],
            ),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(_backdropLayers(tester), 1);
        expect(ownerKey.currentState, same(beforeOwner));
        expect(tester.state(find.byKey(fieldKey)), same(beforeField));
        expect(controller.text, 'borrador conservado');
        expect(controller.selection, selection);

        // Remove the winner: the retained surface must be eligible again.
        await tester.pumpWidget(
          _host(
            KeyedSubtree(key: const ValueKey('right-parent'), child: retained),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(_backdropLayers(tester), 1);
        expect(ownerKey.currentState, same(beforeOwner));
        expect(tester.state(find.byKey(fieldKey)), same(beforeField));
        expect(controller.selection, selection);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(_backdropLayers(tester), 0);
        await tester.pumpWidget(
          _host(_glass('fresh', zone: FrostedZone.bottom)),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(_backdropLayers(tester), 1, reason: 'no inactive ghost owner');
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );
  }

  testWidgets('(1) a moderate blur under the chrome\'s light veil, with '
      'its hairline', (tester) async {
    expect(FrostedBackdrop.glassSigma, inInclusiveRange(16, 20));
    await tester.pumpWidget(_host(_glass('g')));
    expect(_backdropLayers(tester), 1);
    final filter = tester.widget<BackdropFilter>(find.byType(BackdropFilter));
    expect(filter.enabled, isTrue);
    final surface = _surface(tester, 'g');
    expect(surface.color, FrostedBackdrop.glassVeil(_colors));
    expect(surface.color!.a, lessThan(1), reason: 'a veil, not a wall');
    expect(
      (surface.border! as Border).top.color,
      HermesChrome.of(_colors).line,
    );
    // Blurred, it needs no shadow to float.
    expect(_shadow(tester, 'g'), isEmpty);
  });

  testWidgets('(2) one blurring layer per zone: the highest priority blurs, '
      'the others keep the translucent veil', (tester) async {
    await tester.pumpWidget(
      _host(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _glass('step', zone: FrostedZone.bottom),
            _glass('status', zone: FrostedZone.bottom, priority: 1),
            _glass('dock', zone: FrostedZone.bottom),
          ],
        ),
      ),
    );
    await tester.pump();
    expect(_backdropLayers(tester), 1, reason: 'one blur at the foot');
    BackdropFilter filterOf(String id) => tester.widget<BackdropFilter>(
      find.descendant(
        of: find.byKey(ValueKey(id)),
        matching: find.byType(BackdropFilter),
      ),
    );
    expect(filterOf('status').enabled, isTrue);
    expect(filterOf('step').enabled, isFalse);
    expect(filterOf('dock').enabled, isFalse);
    expect(_surface(tester, 'step').color, HermesChrome.of(_colors).fill);
    expect(_surface(tester, 'step').color!.a, lessThan(1));

    // The one that blurred goes: another of the zone takes the blur.
    await tester.pumpWidget(
      _host(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _glass('step', zone: FrostedZone.bottom),
            _glass('dock', zone: FrostedZone.bottom),
          ],
        ),
      ),
    );
    await tester.pump();
    expect(_backdropLayers(tester), 1);
    expect(filterOf('step').enabled, isTrue);
    expect(filterOf('dock').enabled, isFalse);
  });

  testWidgets('(2) surfaces of no zone, or of different zones, each blur', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _glass('a'),
            _glass('b', zone: FrostedZone.bottom),
          ],
        ),
      ),
    );
    await tester.pump();
    expect(_backdropLayers(tester), 2);
  });

  testWidgets('(2) a surface on a route covered by another never keeps the '
      'blur from the one on screen (two chats, REVIEW-Q9-CHAT5)', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        theme: _theme,
        navigatorKey: navigator,
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: _glass('first', zone: FrostedZone.bottom, priority: 1),
          ),
        ),
      ),
    );
    await tester.pump();
    unawaited(
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: _glass('second', zone: FrostedZone.bottom, priority: 1),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump();
    final second = tester.widget<BackdropFilter>(
      find.descendant(
        of: find.byKey(const ValueKey('second')),
        matching: find.byType(BackdropFilter),
      ),
    );
    expect(second.enabled, isTrue, reason: 'the chat on screen blurs');
    expect(_backdropLayers(tester), 1);
    // Back on the first chat, it blurs again.
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    await tester.pump();
    final first = tester.widget<BackdropFilter>(
      find.descendant(
        of: find.byKey(const ValueKey('first')),
        matching: find.byType(BackdropFilter),
      ),
    );
    expect(first.enabled, isTrue);
  });

  testWidgets('(3) without blur (sigma 0) a surface is in a boundary too', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        SizedBox(
          width: 200,
          height: 36,
          child: FrostedBackdrop(
            key: const ValueKey('solid'),
            sigma: 0,
            tint: _colors.surface,
            borderRadius: BorderRadius.circular(18),
            builder: (context, fill) => ColoredBox(color: fill),
          ),
        ),
      ),
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('solid')),
        matching: find.byKey(const ValueKey('frosted-backdrop-boundary')),
      ),
      findsOneWidget,
    );
    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('(3) every frosted surface in its own repaint boundary', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _glass('a', zone: FrostedZone.bottom, priority: 1),
            _glass('b', zone: FrostedZone.bottom),
          ],
        ),
      ),
    );
    await tester.pump();
    for (final id in ['a', 'b']) {
      final boundary = find.descendant(
        of: find.byKey(ValueKey(id)),
        matching: find.byKey(const ValueKey('frosted-backdrop-boundary')),
      );
      expect(boundary, findsOneWidget);
      expect(
        find.descendant(of: boundary, matching: find.byType(BackdropFilter)),
        findsOneWidget,
      );
      expect(tester.widget(boundary), isA<RepaintBoundary>());
    }
  });

  for (final (name, motion, contrast, arrange)
      in <(String, bool, bool, void Function())>[
        ('reduced motion', true, false, () {}),
        ('high contrast (reduced transparency)', false, true, () {}),
        (
          'a low-RAM device or battery saver',
          false,
          false,
          () => FrostedBackdropPolicy.reducedPerformance.value = true,
        ),
        (
          'the system turned blur off, or a mid-range device',
          false,
          false,
          () => FrostedBackdropPolicy.blurAllowed.value = false,
        ),
      ]) {
    testWidgets('(4) $name: no blur; the veil laid on the page, the '
        'hairline and the chrome\'s shadow', (tester) async {
      arrange();
      await tester.pumpWidget(
        _host(
          _glass('g', zone: FrostedZone.bottom, priority: 1),
          disableAnimations: motion,
          highContrast: contrast,
        ),
      );
      await tester.pump();
      expect(_backdropLayers(tester), 0);
      final surface = _surface(tester, 'g');
      expect(
        surface.color,
        Color.alphaBlend(
          FrostedBackdrop.glassVeil(_colors),
          _colors.background,
        ),
      );
      expect(surface.color!.a, 1, reason: 'nothing reads through');
      expect(surface.border, isNotNull);
      expect(_shadow(tester, 'g'), HermesChrome.of(_colors).shadow);
      expect(_shadow(tester, 'g'), isNotEmpty);
    });
  }

  testWidgets('(4) a policy change keeps what sits on the glass', (
    tester,
  ) async {
    final field = GlobalKey<EditableTextState>();
    final controller = TextEditingController(text: 'a medio escribir');
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _host(
        _glass(
          'g',
          child: Material(
            type: MaterialType.transparency,
            child: TextField(
              key: field,
              controller: controller,
              decoration: const InputDecoration.collapsed(hintText: ''),
            ),
          ),
        ),
      ),
    );
    final before = tester.state(find.byType(EditableText));
    FrostedBackdropPolicy.blurAllowed.value = false;
    await tester.pump();
    expect(_backdropLayers(tester), 0);
    expect(identical(tester.state(find.byType(EditableText)), before), isTrue);
    FrostedBackdropPolicy.blurAllowed.value = true;
    await tester.pump();
    expect(_backdropLayers(tester), 1);
    expect(identical(tester.state(find.byType(EditableText)), before), isTrue);
  });

  group('(4, 6) the platform\'s signals', () {
    test('an older Android side (two keys only) keeps the blur', () {
      FrostedBackdropPolicy.apply({
        'lowRamDevice': false,
        'powerSaveMode': false,
      });
      expect(FrostedBackdropPolicy.blurAllowed.value, isTrue);
      expect(FrostedBackdropPolicy.reducedPerformance.value, isFalse);
    });

    test('low RAM or battery saver: no blur, and reducedPerformance keeps '
        'its meaning', () {
      FrostedBackdropPolicy.apply({
        'lowRamDevice': false,
        'powerSaveMode': true,
        'crossWindowBlurEnabled': true,
        'mediaPerformanceClass': 34,
        'totalMemoryBytes': 16 << 30,
      });
      expect(FrostedBackdropPolicy.blurAllowed.value, isFalse);
      expect(FrostedBackdropPolicy.reducedPerformance.value, isTrue);
    });

    // The person's switches: «Allow window-level blurs» off in the
    // developer options, or One UI's «Reduce transparency and blur».
    for (final key in const ['windowBlursDisabled', 'reduceTransparency']) {
      test('the system\'s blur switch off ($key): no blur', () {
        FrostedBackdropPolicy.apply({
          'lowRamDevice': false,
          'powerSaveMode': false,
          'crossWindowBlurEnabled': true,
          key: true,
          'mediaPerformanceClass': 34,
          'totalMemoryBytes': 16 << 30,
        });
        expect(FrostedBackdropPolicy.blurAllowed.value, isFalse);
        expect(FrostedBackdropPolicy.reducedPerformance.value, isFalse);
        expect(
          FrostedBackdropPolicy.lastDecision,
          startsWith('[glass] blur=off'),
        );
      });
    }

    // Q9-CRISTAL-DETRAS: the owner's Fold showed the chrome of before. A device
    // without blurs between windows (Samsung reports
    // isCrossWindowBlurEnabled false) still frosts its own pieces.
    test('no blur between windows, but nothing switched off: the app still '
        'frosts, and the log says why it would not', () {
      FrostedBackdropPolicy.apply({
        'lowRamDevice': false,
        'powerSaveMode': false,
        'crossWindowBlurEnabled': false,
        'windowBlursDisabled': false,
        'reduceTransparency': false,
        'mediaPerformanceClass': 0,
        'totalMemoryBytes': 12 << 30,
      });
      expect(FrostedBackdropPolicy.blurAllowed.value, isTrue);
      expect(FrostedBackdropPolicy.lastDecision, startsWith('[glass] blur=on'));
      expect(FrostedBackdropPolicy.lastDecision, contains('crossWindowBlur'));
      final off = FrostedBackdropPolicy.describe({
        'lowRamDevice': false,
        'powerSaveMode': true,
        'mediaPerformanceClass': 0,
        'totalMemoryBytes': 6 << 30,
      });
      expect(off, startsWith('[glass] blur=off'));
      expect(off, contains('battery saver'));
      expect(off, contains('mid or low range'));
    });

    test('(6) a mid or low range device has no blur by default; a high-end '
        'one (media class or memory) has', () {
      expect(FrostedBackdropPolicy.blurNeedsHighEnd, isTrue);
      FrostedBackdropPolicy.apply({
        'lowRamDevice': false,
        'powerSaveMode': false,
        'crossWindowBlurEnabled': true,
        'mediaPerformanceClass': 0,
        'totalMemoryBytes': 6 << 30,
      });
      expect(FrostedBackdropPolicy.blurAllowed.value, isFalse);
      FrostedBackdropPolicy.apply({
        'lowRamDevice': false,
        'powerSaveMode': false,
        'crossWindowBlurEnabled': true,
        'mediaPerformanceClass': 0,
        'totalMemoryBytes': 12 << 30,
      });
      expect(FrostedBackdropPolicy.blurAllowed.value, isTrue);
      FrostedBackdropPolicy.apply({
        'lowRamDevice': false,
        'powerSaveMode': false,
        'crossWindowBlurEnabled': true,
        'mediaPerformanceClass': 33,
        'totalMemoryBytes': 6 << 30,
      });
      expect(FrostedBackdropPolicy.blurAllowed.value, isTrue);
    });
  });
}
