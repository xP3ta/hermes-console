import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/modal.dart';
import 'package:hermes_android/core/design/tokens.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_app_bar.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

/// The three dots of a row or of a header: one button, one menu, the same
/// everywhere.
void main() {
  const menu = ValueKey('hermes-menu');

  Widget app({
    required ValueChanged<String> onSelected,
    bool inHeader = false,
    String themeId = 'classic-dark',
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
    // The floating tone, opaque.
    final colors = AppTheme.fromId('classic-dark').hermes;
    final surface = tester.widget<Material>(
      find
          .descendant(of: find.byKey(menu), matching: find.byType(Material))
          .first,
    );
    expect(surface.color, HermesChrome.of(colors).opaque);

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
