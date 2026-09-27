import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/tokens.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/scroll_behavior.dart';

void main() {
  group('spec 080 tokens', () {
    test('reference values of the Bot profile screen', () {
      expect(HermesSpace.pageH, 18);
      expect(HermesSpace.rowMin, 52);
      expect(HermesSpace.tap, 48);
      expect(HermesRadius.group, 16);
      expect(HermesRadius.floating, 22);
      expect(HermesType.display.fontSize, 22);
      expect(HermesType.title.fontSize, 17);
      expect(HermesType.body.fontSize, 14.5);
      expect(HermesType.support.fontSize, 12.5);
      expect(HermesType.caption.fontSize, 11.5);
    });
  });

  group('theme titles', () {
    for (final id in const ['amber', 'mocha', 'crimson']) {
      test('$id: titleLarge/titleMedium use textPrimary, not accent', () {
        final theme = AppTheme.fromId(id);
        final colors = theme.hermes;
        expect(theme.textTheme.titleLarge?.color, colors.textPrimary);
        expect(theme.textTheme.titleMedium?.color, colors.textPrimary);
        expect(theme.textTheme.titleLarge?.color, isNot(colors.accent));
      });
    }
  });

  group('scroll physics', () {
    Future<List<ScrollPhysics>> physicsOf(
      WidgetTester tester,
      Widget child,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          scrollBehavior: const MomentumScrollBehavior(),
          home: Scaffold(body: child),
        ),
      );
      return [
        for (final state in tester.stateList<ScrollableState>(
          find.byType(Scrollable),
        ))
          state.position.physics,
      ];
    }

    bool always(ScrollPhysics p) {
      ScrollPhysics? cursor = p;
      while (cursor != null) {
        if (cursor is AlwaysScrollableScrollPhysics) return true;
        cursor = cursor.parent;
      }
      return false;
    }

    testWidgets('page-level list is always scrollable (pull to refresh)', (
      tester,
    ) async {
      final physics = await physicsOf(
        tester,
        ListView(children: const [Text('short')]),
      );
      expect(physics, hasLength(1));
      expect(always(physics.single), isTrue);
    });

    testWidgets('inner vertical block never bounces when content fits', (
      tester,
    ) async {
      await physicsOf(
        tester,
        ListView(
          children: [
            SizedBox(
              height: 200,
              child: SingleChildScrollView(
                key: const ValueKey('inner'),
                child: const Text('fits'),
              ),
            ),
          ],
        ),
      );
      final inner = tester.state<ScrollableState>(
        find.descendant(
          of: find.byKey(const ValueKey('inner')),
          matching: find.byType(Scrollable),
        ),
      );
      expect(always(inner.position.physics), isFalse);
      expect(inner.position.maxScrollExtent, 0);
      await tester.drag(find.text('fits'), const Offset(0, 120));
      await tester.pump();
      expect(inner.position.pixels, 0);
    });

    testWidgets('horizontal strip is not always-scrollable', (tester) async {
      final physics = await physicsOf(
        tester,
        const SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Text('strip'),
        ),
      );
      expect(always(physics.single), isFalse);
    });

    testWidgets('scrollables in a modal scope clamp', (tester) async {
      final physics = await physicsOf(
        tester,
        HermesModalScrollScope(
          child: ListView(children: const [Text('picker')]),
        ),
      );
      // A primary ListView adds AlwaysScrollable itself; the base must clamp.
      ScrollPhysics? cursor = physics.single;
      var clamps = false;
      var bounces = false;
      while (cursor != null) {
        clamps |= cursor is ClampingScrollPhysics;
        bounces |= cursor is BouncingScrollPhysics;
        cursor = cursor.parent;
      }
      expect(clamps, isTrue);
      expect(bounces, isFalse);
    });
  });
}
