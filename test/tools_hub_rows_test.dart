// Tools hub: a subtitle with the group count, the search in a panel, and the
// groups as rows with an icon tile, an optional value and a chevron.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/tools_hub_screen.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_ui.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

HermesToolDestination _dest(String id, String group, {String? value}) =>
    HermesToolDestination(
      id: id,
      group: group,
      icon: Icons.folder_outlined,
      label: 'Destino $id',
      value: value,
      builder: (_) => const SizedBox.shrink(),
    );

Future<void> _pump(WidgetTester tester, {double scale = 1}) async {
  tester.view.physicalSize = const Size(390, 1200);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(() {
    tester.view.reset();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  });
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('es'),
      theme: AppTheme.fromId('dark'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      home: ToolsHubScreen(
        destinations: [
          _dest('a', 'trabajo', value: '12 activos'),
          _dest('b', 'trabajo'),
          _dest('c', 'perfil', value: '3'),
        ],
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('subtitle counts the groups and follows the search', (
    tester,
  ) async {
    await _pump(tester);
    expect(find.text('2 grupos'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('tools-search')), 'zzz');
    await tester.pump();
    expect(find.byKey(const ValueKey('tools-groups-count')), findsNothing);
    await tester.enterText(
      find.byKey(const ValueKey('tools-search')),
      'Destino c',
    );
    await tester.pump();
    expect(find.text('1 grupo'), findsOneWidget);
  });

  testWidgets('rows sit in HermesGroup, the value shows only when known', (
    tester,
  ) async {
    await _pump(tester);
    expect(find.byType(HermesGroup), findsNWidgets(2));
    expect(find.byType(HermesPanel), findsOneWidget);
    expect(find.text('12 activos'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    final plain = find.byKey(const ValueKey('tool-b'));
    expect(
      find.descendant(
        of: plain,
        matching: find.byIcon(Icons.chevron_right_rounded),
      ),
      findsOneWidget,
    );
  });

  testWidgets('large text does not overflow', (tester) async {
    await _pump(tester, scale: 2);
    expect(tester.takeException(), isNull);
  });
}
