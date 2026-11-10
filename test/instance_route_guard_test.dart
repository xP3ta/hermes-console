import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/connection.dart';
import 'package:hermes_android/core/navigation/instance_route_guard.dart';
import 'package:hermes_android/core/screens/themes_screen.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

final _connection = SavedConnection(
  id: 'appearance-guard-test',
  label: 'Hermes QA',
  host: '192.168.1.20',
  port: 8642,
  apiKey: 'test-only',
);

Widget _host({
  required SavedConnection? connection,
  required VoidCallback built,
}) {
  return MaterialApp(
    locale: const Locale('es'),
    theme: AppTheme.fromId('dark'),
    localizationsDelegates: Strings.localizationsDelegates,
    supportedLocales: Strings.supportedLocales,
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: FilledButton(
            key: const ValueKey('open-gated-route'),
            onPressed: () {
              InstanceRouteGuard.push<void>(
                context,
                connection: connection,
                builder: (_) {
                  built();
                  return const ThemesScreen();
                },
              );
            },
            child: const Text('Abrir'),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('sin instancia explica el bloqueo y no añade una ruta', (
    tester,
  ) async {
    var builds = 0;
    await tester.pumpWidget(_host(connection: null, built: () => builds += 1));

    await tester.tap(find.byKey(const ValueKey('open-gated-route')));
    await tester.pump();

    expect(builds, 0);
    expect(find.byType(ThemesScreen), findsNothing);
    expect(find.text('Configura una instancia primero'), findsOneWidget);
  });

  testWidgets(
    'con instancia abre Temas directamente, sin pantalla Apariencia',
    (tester) async {
      var builds = 0;
      await tester.pumpWidget(
        _host(connection: _connection, built: () => builds += 1),
      );

      await tester.tap(find.byKey(const ValueKey('open-gated-route')));
      await tester.pumpAndSettle();

      expect(builds, 1);
      expect(find.byType(ThemesScreen), findsOneWidget);
      expect(
        find.byKey(const ValueKey('appearance-current-preview')),
        findsNothing,
      );
      expect(find.textContaining('Hermes QA'), findsNothing);
      // The Style and Glass selectors are gone from the screen.
      expect(find.text('Estilo'), findsNothing);
      expect(find.text('Cristal'), findsNothing);
    },
  );
}
