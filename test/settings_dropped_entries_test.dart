import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_android/core/screens/settings_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/settings/settings_sections.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

// Owner decision (QA 9491): Settings no longer offers "Avanzado" (server
// settings, tools and search) nor "Terminal" (run a command on the server),
// on phones or in the tablet list-detail layout.

SavedConnection _connection() => SavedConnection(
  id: 'dropped-entries',
  label: 'Hermes',
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'k',
  dashboardUrl: 'http://127.0.0.1:9119',
);

Future<void> _pump(WidgetTester tester, Size size) async {
  SharedPreferences.setMockInitialValues(const {});
  TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        (call) async => call.method == 'readAll' ? <String, String>{} : null,
      );
  final manager = await ConnectionManager.create(
    await SharedPreferences.getInstance(),
  );
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('es'),
      theme: AppTheme.fromId('dark'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      home: SettingsScreen(connection: _connection(), connManager: manager),
    ),
  );
  await tester.pumpAndSettle();
}

/// Every row title seen while scrolling [scrollable] from top to bottom.
Future<Set<String>> _titlesWhileScrolling(
  WidgetTester tester,
  Finder scrollable,
) async {
  final seen = <String>{};
  void collect() {
    for (final element
        in find
            .descendant(of: scrollable, matching: find.byType(Text))
            .evaluate()) {
      final data = (element.widget as Text).data;
      if (data != null) seen.add(data);
    }
  }

  collect();
  for (var i = 0; i < 80; i++) {
    final position = tester
        .state<ScrollableState>(
          find
              .descendant(of: scrollable, matching: find.byType(Scrollable))
              .first,
        )
        .position;
    if (position.pixels >= position.maxScrollExtent) break;
    await tester.drag(scrollable, const Offset(0, -300));
    await tester.pumpAndSettle();
    collect();
  }
  return seen;
}

void main() {
  testWidgets('phone: the Settings list has neither Avanzado nor Terminal', (
    tester,
  ) async {
    await _pump(tester, const Size(411, 915));
    final titles = await _titlesWhileScrolling(
      tester,
      find.byType(ListView).first,
    );
    // The list was really walked to the end (control).
    expect(titles.map((t) => t.toLowerCase()), contains('acerca de'));
    expect(titles, isNot(contains('Avanzado')));
    expect(titles, isNot(contains('Terminal')));
    expect(find.byKey(const ValueKey('settings-terminal')), findsNothing);
    expect(find.byIcon(Icons.tune_rounded), findsNothing);
    expect(find.byIcon(Icons.terminal_rounded), findsNothing);
    // Walking the whole list trips a known debug-only diagnostic of an
    // unrelated row (a ListTile over a coloured box); anything else fails.
    final error = tester.takeException();
    expect(
      error == null || '$error'.contains('ListTile background color'),
      isTrue,
      reason: '$error',
    );
  });

  testWidgets('tablet: the System page has neither Avanzado nor Terminal', (
    tester,
  ) async {
    await _pump(tester, const Size(1280, 800));
    await tester.tap(
      find.byKey(ValueKey('settings-category-${SettingsSection.system.name}')),
    );
    await tester.pumpAndSettle();
    final pane = find.byKey(const ValueKey('settings-detail-pane'));
    expect(pane, findsOneWidget);
    final titles = await _titlesWhileScrolling(tester, pane);
    expect(titles, isNot(contains('Avanzado')));
    expect(titles, isNot(contains('Terminal')));
    expect(find.byIcon(Icons.tune_rounded), findsNothing);
    expect(find.byIcon(Icons.terminal_rounded), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
