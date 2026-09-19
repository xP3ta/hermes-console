import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_drawer.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ConnectionManager> manager() async {
    SharedPreferences.setMockInitialValues({});
    return ConnectionManager.create(await SharedPreferences.getInstance());
  }

  Future<void> pumpDrawer(
    WidgetTester tester, {
    required ConnectionManager connManager,
  }) async {
    final scaffoldKey = GlobalKey<ScaffoldState>();
    final connection = SavedConnection(
      id: 'drawer-premium-qa',
      label: 'Server',
      host: '127.0.0.1',
      port: 8642,
      apiKey: 'test-only',
    );

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: Scaffold(
          key: scaffoldKey,
          drawer: HermesDrawer(
            connection: connection,
            connManager: connManager,
            current: DrawerSection.home,
            recentSessionsClientFactory: (saved) => ApiClient(
              baseUrl: saved.baseUrl,
              apiKey: saved.apiKey,
              httpClient: MockClient((request) async {
                expect(request.url.path, '/api/sessions');
                return http.Response(
                  jsonEncode({
                    'object': 'list',
                    'data': [
                      {
                        'id': 'older',
                        'title': 'Diseño anterior',
                        'last_active': '2026-07-28T08:00:00Z',
                        'message_count': 2,
                      },
                      {
                        'id': 'newest',
                        'title': 'Rediseño premium',
                        'last_active': '2026-07-29T08:00:00Z',
                        'message_count': 4,
                      },
                      {
                        'id': 'third',
                        'title': 'Composer flotante',
                        'last_active': '2026-07-29T07:00:00Z',
                        'message_count': 3,
                      },
                      {
                        'id': 'fourth',
                        'title': 'Ajustes de voz',
                        'last_active': '2026-07-29T06:00:00Z',
                        'message_count': 3,
                      },
                      {
                        'id': 'fifth',
                        'title': 'No debe aparecer',
                        'last_active': '2026-07-27T06:00:00Z',
                        'message_count': 3,
                      },
                      {
                        'id': 'child',
                        'title': 'Subagente oculto',
                        'last_active': '2026-07-29T09:00:00Z',
                        'parent_session_id': 'newest',
                      },
                    ],
                  }),
                  200,
                );
              }),
            ),
          ),
        ),
      ),
    );
    scaffoldKey.currentState!.openDrawer();
    await tester.pumpAndSettle();
  }

  testWidgets(
    'Nuevo chat es la primera fila de la lista y se desplaza con ella',
    (tester) async {
      // La maqueta aprobada del rediseño del drawer mueve "Nuevo chat" del
      // dock fijo al fondo a la primera fila bajo la cabecera: ya no hay
      // una franja separada, así que debe desplazarse con el resto de la
      // lista en vez de quedarse fijo.
      await pumpDrawer(tester, connManager: await manager());

      final newChat = find.text('Nuevo chat');
      expect(newChat, findsOneWidget);
      final initialY = tester.getCenter(newChat).dy;

      // Un desplazamiento pequeño: lo bastante para mover la fila si ya no
      // está fija, sin sacarla del viewport (ahora es la primera fila, así
      // que un scroll grande directamente la saca de la pantalla).
      await tester.drag(
        find.byKey(const ValueKey('drawer-scroll')),
        const Offset(0, -80),
      );
      await tester.pump();

      expect(tester.getCenter(newChat).dy, isNot(initialY));
    },
  );

  testWidgets('el drawer carga recientes reales y omite sesiones hijas', (
    tester,
  ) async {
    await pumpDrawer(tester, connManager: await manager());

    // Mission Control añadió una entrada real al drawer; en una pantalla de
    // teléfono la sección Recientes queda ahora fuera del viewport inicial.
    await tester.drag(
      find.byKey(const ValueKey('drawer-scroll')),
      const Offset(0, -520),
    );
    await tester.pumpAndSettle();

    expect(find.text('Rediseño premium'), findsOneWidget);
    expect(find.text('Diseño anterior'), findsOneWidget);
    expect(find.text('Composer flotante'), findsOneWidget);
    expect(find.text('Ajustes de voz'), findsOneWidget);
    expect(find.text('No debe aparecer'), findsNothing);
    expect(find.text('Subagente oculto'), findsNothing);
  });
}
