import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/glass_strip.dart';
import 'package:hermes_android/core/design/modal.dart';
import 'package:hermes_android/core/design/tokens.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/theme_contrast.dart';
import 'package:hermes_android/core/widgets/frosted_backdrop.dart';
import 'package:hermes_android/core/widgets/hermes_app_bar.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

/// The three dots of a row or of a header: one button, one menu, the same
/// everywhere.
void main() {
  const menu = ValueKey('hermes-menu');

  int filtersIn(Layer? layer) {
    var count = layer is BackdropFilterLayer ? 1 : 0;
    if (layer is ContainerLayer) {
      for (
        var child = layer.firstChild;
        child != null;
        child = child.nextSibling
      ) {
        count += filtersIn(child);
      }
    }
    return count;
  }

  int menuFilters(WidgetTester tester) {
    final strips = find.descendant(
      of: find.byKey(menu),
      matching: find.byType(HermesGlassStrip),
    );
    if (strips.evaluate().isEmpty) return 0;
    return filtersIn(tester.renderObject(strips).debugLayer);
  }

  void resetPolicy() {
    FrostedBackdropPolicy.blurAllowed.value = true;
    FrostedBackdropPolicy.reducedPerformance.value = false;
    FrostedBackdropPolicy.knownHighEnd.value = false;
    FrostedBackdropPolicy.liquidGpuValidated.value = false;
    FrostedBackdropPolicy.effectCeiling.value = HermesGlassTier.liquid;
  }

  setUp(resetPolicy);
  tearDown(resetPolicy);

  Widget app({
    required ValueChanged<String> onSelected,
    bool inHeader = false,
    String themeId = 'classic-dark',
    bool reduceMotion = false,
    bool highContrast = false,
  }) {
    final button = HermesMenuButton<String>(
      key: const ValueKey('dots'),
      tooltip: 'Más',
      onSelected: onSelected,
      actions: (_) => const [
        HermesAction(
          value: 'refresh',
          label: 'Actualizar',
          icon: Icons.refresh,
        ),
        HermesAction(
          value: 'sort:recent',
          label: 'Recientes',
          selected: true,
          section: 'Ordenar por',
        ),
        HermesAction(value: 'sort:cost', label: 'Coste', selected: false),
        HermesAction(value: 'import', label: 'Importar', divided: true),
        HermesAction(value: 'delete', label: 'Borrar', destructive: true),
      ],
    );
    return MaterialApp(
      theme: AppTheme.fromId(themeId),
      locale: const Locale('es'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(disableAnimations: reduceMotion, highContrast: highContrast),
        child: child!,
      ),
      home: Scaffold(
        appBar: HermesAppBar(
          title: const Text('Conversaciones'),
          actions: [
            if (inHeader) ...[
              IconButton(
                tooltip: 'Nueva',
                icon: const Icon(Icons.add),
                onPressed: () {},
              ),
              button,
            ],
          ],
        ),
        body: inHeader
            ? null
            : Align(alignment: Alignment.centerRight, child: button),
      ),
    );
  }

  testWidgets('opens the shared menu from itself and reports the choice', (
    tester,
  ) async {
    final chosen = <String>[];
    await tester.pumpWidget(app(onSelected: chosen.add));
    expect(find.byKey(menu), findsNothing);
    await tester.tap(find.byKey(const ValueKey('dots')));
    await tester.pumpAndSettle();

    expect(find.byKey(menu), findsOneWidget);
    // The light scrim of a menu.
    final barrier = tester.widgetList<ModalBarrier>(find.byType(ModalBarrier));
    expect(
      barrier.map((b) => b.color?.a).whereType<double>(),
      contains(closeTo(HermesChrome.scrimMenu, 0.005)),
    );
    // A menu is opaque: the theme's tone, no veil, no filter. Nothing under
    // it can be read through it.
    final colors = AppTheme.fromId('classic-dark').hermes;
    final surface = tester.widget<Material>(
      find
          .descendant(of: find.byKey(menu), matching: find.byType(Material))
          .first,
    );
    expect(surface.color, HermesChrome.of(colors).opaque);
    expect(surface.color!.a, 1);
    expect(menuFilters(tester), 0);
    expect(
      find.descendant(
        of: find.byKey(menu),
        matching: find.byType(HermesGlassStrip),
      ),
      findsNothing,
    );
    for (final behind in [Colors.white, Colors.black]) {
      expect(
        ThemeContrast.ratio(
          colors.textPrimary,
          ThemeContrast.composite(surface.color!, behind),
        ),
        greaterThanOrEqualTo(4.5),
      );
    }

    // The group heading, the choice in force with its check, the rest.
    final rect = tester.getRect;
    expect(find.text('Ordenar por'), findsOneWidget);
    expect(
      rect(find.text('Ordenar por')).bottom,
      lessThanOrEqualTo(rect(find.text('Recientes')).top),
    );
    final check = find.descendant(
      of: find.byKey(menu),
      matching: find.byIcon(Icons.check_rounded),
    );
    expect(check, findsOneWidget);
    expect(
      rect(check).center.dy,
      closeTo(rect(find.text('Recientes')).center.dy, 2),
    );
    // What deletes goes last.
    expect(
      rect(find.text('Borrar')).top,
      greaterThan(rect(find.text('Importar')).bottom),
    );

    await tester.tap(find.text('Coste'));
    await tester.pumpAndSettle();
    expect(chosen, ['sort:cost']);
    expect(find.byKey(menu), findsNothing);
  });

  for (final id in ['classic-dark', 'classic', 'console']) {
    testWidgets('$id: the menu body is opaque, with its border and shadow', (
      tester,
    ) async {
      await tester.pumpWidget(app(onSelected: (_) {}, themeId: id));
      await tester.tap(find.byKey(const ValueKey('dots')));
      await tester.pumpAndSettle();
      final colors = AppTheme.fromId(id).hermes;
      final chrome = HermesChrome.of(colors);
      final material = tester.widget<Material>(
        find
            .descendant(of: find.byKey(menu), matching: find.byType(Material))
            .first,
      );
      expect(material.color, chrome.opaque);
      expect(material.color!.a, 1);
      expect(material.shape, isA<RoundedRectangleBorder>());
      expect(
        (material.shape! as RoundedRectangleBorder).side.color,
        chrome.line,
      );
      final shadow = tester.widget<DecoratedBox>(
        find
            .descendant(
              of: find.byKey(menu),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      expect((shadow.decoration as ShapeDecoration).shadows, chrome.shadow);
      expect(menuFilters(tester), 0);
    });
  }

  for (final reason in [
    'reduced motion',
    'high contrast',
    'low RAM',
    'blur off',
  ]) {
    testWidgets(
      'short-menu $reason fallback stays opaque and reports its choice',
      (tester) async {
        if (reason == 'low RAM') {
          FrostedBackdropPolicy.reducedPerformance.value = true;
        }
        if (reason == 'blur off') {
          FrostedBackdropPolicy.blurAllowed.value = false;
        }
        final chosen = <String>[];
        await tester.pumpWidget(
          app(
            onSelected: chosen.add,
            reduceMotion: reason == 'reduced motion',
            highContrast: reason == 'high contrast',
          ),
        );
        await tester.tap(find.byKey(const ValueKey('dots')));
        await tester.pumpAndSettle();
        final material = tester.widget<Material>(
          find
              .descendant(of: find.byKey(menu), matching: find.byType(Material))
              .first,
        );
        expect(
          material.color,
          HermesChrome.of(AppTheme.fromId('classic-dark').hermes).opaque,
        );
        expect(menuFilters(tester), 0);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Coste'));
        await tester.pumpAndSettle();
        expect(chosen, ['sort:cost']);
        expect(find.byKey(menu), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('closed without choosing, nothing is reported; a drag takes it '
      'away', (tester) async {
    final chosen = <String>[];
    await tester.pumpWidget(app(onSelected: chosen.add));
    await tester.tap(find.byKey(const ValueKey('dots')));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(20, 500));
    await tester.pumpAndSettle();
    expect(find.byKey(menu), findsNothing);
    expect(chosen, isEmpty);

    await tester.tap(find.byKey(const ValueKey('dots')));
    await tester.pumpAndSettle();
    await tester.fling(find.text('Actualizar'), const Offset(0, 260), 1400);
    await tester.pumpAndSettle();
    expect(find.byKey(menu), findsNothing);
    expect(chosen, isEmpty);
  });

  testWidgets('in a header it sits in the actions pill like any icon', (
    tester,
  ) async {
    await tester.pumpWidget(app(onSelected: (_) {}, inHeader: true));
    // The pill is drawn behind the icons it holds.
    final pill = tester.getRect(
      find.byKey(const ValueKey('hermes-app-bar-actions')),
    );
    final dots = tester.getRect(find.byKey(const ValueKey('dots')));
    expect(pill.contains(dots.center), isTrue);
    expect(pill.contains(tester.getCenter(find.byTooltip('Nueva'))), isTrue);
    await tester.tap(find.byKey(const ValueKey('dots')));
    await tester.pumpAndSettle();
    expect(find.byKey(menu), findsOneWidget);
    // Hanging from the header, it opens below it.
    expect(
      tester.getRect(find.byKey(menu)).top,
      greaterThanOrEqualTo(
        tester.getRect(find.byKey(const ValueKey('dots'))).top,
      ),
    );
  });
}
