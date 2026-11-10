import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/hermes_design.dart';
import 'package:hermes_android/core/design/glass_strip.dart';
import 'package:hermes_android/core/design/liquid_glass.dart';
import 'package:hermes_android/core/models/dock_config.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/dock_style.dart';
import 'package:hermes_android/core/widgets/frosted_backdrop.dart';
import 'package:hermes_android/core/widgets/hermes_app_bar.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

const _menu = ValueKey('open-menu');
const _options = ValueKey('open-options');
const _list = ValueKey('production-groups');
const _sizes = [
  Size(360, 800),
  Size(412, 915),
  Size(773, 1000),
  Size(884, 1000),
  Size(1000, 773),
];

Widget _page() => Builder(
  builder: (context) => Scaffold(
    extendBodyBehindAppBar: true,
    appBar: HermesAppBar(
      title: const Text('Ajustes'),
      leading: IconButton(
        tooltip: 'Volver',
        onPressed: () {},
        icon: const Icon(Icons.arrow_back),
      ),
      actions: [
        IconButton(
          key: _menu,
          tooltip: 'Acciones',
          icon: const Icon(Icons.more_horiz),
          onPressed: () => unawaited(
            showHermesMenu<int>(
              context: context,
              actions: const [
                HermesAction(
                  value: 1,
                  label: 'Actualizar',
                  icon: Icons.refresh,
                ),
                HermesAction(value: 2, label: 'Ordenar', icon: Icons.sort),
              ],
            ),
          ),
        ),
      ],
    ),
    body: ListView(
      key: _list,
      clipBehavior: hermesUnderHeader,
      padding: const EdgeInsets.fromLTRB(16, 100, 16, 100),
      children: [
        TextButton(
          key: _options,
          onPressed: () => unawaited(
            showHermesOptions<int>(
              context: context,
              options: [
                for (var i = 0; i < 40; i++)
                  HermesOption(value: i, label: 'Opción $i'),
              ],
            ),
          ),
          child: const Text('Opciones'),
        ),
        for (var group = 0; group < 12; group++) ...[
          HermesListGroup(
            children: [
              HermesListRow(title: 'Grupo $group', onTap: () {}),
              const HermesListRow(
                title: 'Estado',
                subtitle: 'Contenido de la página',
              ),
            ],
          ),
          const SizedBox(height: 16),
        ],
      ],
    ),
    bottomNavigationBar: DockBar(
      style: const DockStyle(transparency: .6),
      children: [
        for (final icon in [Icons.home, Icons.forum, Icons.settings])
          Expanded(
            child: IconButton(
              icon: Icon(icon),
              tooltip: 'Destino',
              onPressed: () {},
            ),
          ),
      ],
    ),
  ),
);

Future<void> _pump(
  WidgetTester tester, {
  required Size size,
  required String theme,
  double scale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.fromId(theme),
      locale: const Locale('es'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: _page(),
    ),
  );
  await tester.pumpAndSettle();
}

int _layers(WidgetTester tester) =>
    tester.layers.whereType<BackdropFilterLayer>().length;

void main() {
  setUp(() {
    FrostedBackdropPolicy.effectCeiling.value = HermesGlassTier.liquid;
    FrostedBackdropPolicy.liquidGpuValidated.value = false;
    FrostedBackdropPolicy.knownHighEnd.value = true;
  });
  tearDown(() {
    FrostedBackdropPolicy.effectCeiling.value = HermesGlassTier.liquid;
    FrostedBackdropPolicy.liquidGpuValidated.value = false;
    FrostedBackdropPolicy.knownHighEnd.value = false;
  });

  for (final size in _sizes) {
    for (final theme in ['classic-dark', 'classic']) {
      testWidgets(
        '$theme $size: actual shared components, stable fallback geometry',
        (tester) async {
          await _pump(tester, size: size, theme: theme, scale: 2);
          expect(tester.takeException(), isNull);
          expect(_layers(tester), 2, reason: 'top and bottom, no row filters');
          final header = tester.getRect(find.byType(HermesAppBar));
          final dock = tester.getRect(find.byType(DockBar));
          final rows = tester.getRect(find.byKey(_list));
          expect(
            find.descendant(
              of: find.byKey(_list),
              matching: find.byType(HermesGlassStrip),
            ),
            findsNothing,
          );
          expect(
            find.descendant(
              of: find.byKey(_list),
              matching: find.byType(FrostedBackdrop),
            ),
            findsNothing,
          );
          expect(
            tester
                .widget<HermesGlassStrip>(
                  find.descendant(
                    of: find.byType(HermesAppBar),
                    matching: find.byType(HermesGlassStrip),
                  ),
                )
                .liquid,
            HermesLiquid.header,
          );
          FrostedBackdropPolicy.effectCeiling.value = HermesGlassTier.chrome;
          await tester.pump();
          expect(_layers(tester), 0);
          expect(tester.getRect(find.byType(HermesAppBar)), header);
          expect(tester.getRect(find.byType(DockBar)), dock);
          expect(tester.getRect(find.byKey(_list)), rows);
          expect(
            tester.getSize(find.byKey(_menu)).height,
            greaterThanOrEqualTo(48),
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'short menu is opaque: no overlay band, no extra filter through route and '
    'drag frames',
    (tester) async {
      await _pump(tester, size: const Size(412, 915), theme: 'classic-dark');
      await tester.tap(find.byKey(_menu));
      for (final ms in [0, 50, 80, 100]) {
        await tester.pump(Duration(milliseconds: ms));
        // Only the header's and the dock's filters, never the menu's.
        expect(_layers(tester), lessThanOrEqualTo(2));
        expect(tester.takeException(), isNull);
      }
      await tester.pumpAndSettle();
      final surface = find.byKey(const ValueKey('hermes-menu'));
      expect(
        find.descendant(
          of: surface,
          matching: find.byType(HermesLiquidSurface),
        ),
        findsNothing,
      );
      expect(
        find.descendant(of: surface, matching: find.byType(HermesGlassStrip)),
        findsNothing,
      );
      final material = tester.widget<Material>(
        find.descendant(of: surface, matching: find.byType(Material)).first,
      );
      expect(material.color!.a, 1);
      final rest = tester.getRect(surface);
      final gesture = await tester.startGesture(rest.center);
      await gesture.moveBy(const Offset(0, 30));
      await tester.pump();
      expect(_layers(tester), lessThanOrEqualTo(2));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'long searchable options keep opaque material and zero row filters',
    (tester) async {
      await _pump(tester, size: const Size(360, 800), theme: 'classic');
      await tester.tap(find.byKey(_options));
      await tester.pumpAndSettle();
      final surface = find.byKey(const ValueKey('hermes-option-surface'));
      final material = tester.widget<Material>(
        find.descendant(of: surface, matching: find.byType(Material)).first,
      );
      expect(material.color!.a, 1);
      expect(
        find.descendant(of: surface, matching: find.byType(HermesGlassStrip)),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('hermes-option-search')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
