// Ola 7 (AUDITORIA-PULIDO §4.2): the skeletons of the chat and the list
// are static (no shimmer, no frames), take the theme and are read as
// «Cargando…».
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/loading_skeleton.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

Widget _app(Widget child, ThemeData theme) => MaterialApp(
  theme: theme,
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  home: Scaffold(body: child),
);

void main() {
  for (final (name, theme) in [
    ('dark', AppTheme.hermesRedDark),
    ('light', AppTheme.hermesRedLight),
  ]) {
    testWidgets('$name: the chat skeleton is still, themed and «Cargando…»', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      tester.view
        ..devicePixelRatio = 1
        ..physicalSize = const Size(360, 800);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_app(const ChatLoadingSkeleton(), theme));
      // Nothing moves: no ticker runs.
      expect(tester.binding.transientCallbackCount, 0);

      const skeleton = ValueKey('chat-loading-skeleton');
      expect(
        tester.getSemantics(find.byKey(skeleton)),
        isSemantics(label: 'Cargando…', isLiveRegion: true),
      );
      // Resting on the bottom, as the transcript does.
      expect(tester.getRect(find.byKey(skeleton)).bottom, 800);
      final bars = tester.widgetList<DecoratedBox>(
        find.descendant(
          of: find.byKey(skeleton),
          matching: find.byType(DecoratedBox),
        ),
      );
      expect(bars, isNotEmpty);
      for (final bar in bars) {
        expect(
          (bar.decoration as ShapeDecoration).color,
          theme.hermes.surfaceVariant,
        );
      }
      expect(tester.takeException(), isNull);
      semantics.dispose();
    });
  }

  testWidgets('a skeleton bar takes its share of the width', (tester) async {
    await tester.pumpWidget(
      _app(
        const SizedBox(width: 200, child: SkeletonBar(widthFactor: 0.5)),
        AppTheme.hermesRedDark,
      ),
    );
    final bar = find.descendant(
      of: find.byType(SkeletonBar),
      matching: find.byType(DecoratedBox),
    );
    expect(tester.getSize(bar).width, 100);
  });

  // Flicker audit P3: a skeleton shows only if the load outlasts its grace.
  testWidgets('a delayed skeleton shows after its grace, not before', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const DelayedSkeleton(child: SizedBox(key: ValueKey('late'))),
        AppTheme.fromId('dark'),
      ),
    );
    expect(find.byKey(const ValueKey('late')), findsNothing);
    await tester.pump(const Duration(milliseconds: 170));
    expect(find.byKey(const ValueKey('late')), findsNothing);
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.byKey(const ValueKey('late')), findsOneWidget);
  });

  testWidgets('a load that ends within the grace never shows the skeleton', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const DelayedSkeleton(child: SizedBox(key: ValueKey('late'))),
        AppTheme.fromId('dark'),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('late')), findsNothing);
    // The content lands: the skeleton is gone with no frame of it.
    await tester.pumpWidget(
      _app(const Text('contenido'), AppTheme.fromId('dark')),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('late')), findsNothing);
    expect(find.text('contenido'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
