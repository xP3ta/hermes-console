import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/session_detail_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _host(Widget child) => MaterialApp(
  locale: const Locale('es'),
  theme: AppTheme.fromId('dark'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  home: child,
);

void main() {
  testWidgets(
    'SessionDetail no solicita ni representa transcript o artefactos derivados',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      var messageRequests = 0;
      const privateTranscript = <Map<String, dynamic>>[
        {'role': 'user', 'content': 'PRIVATE_USER_TRANSCRIPT'},
        {'role': 'assistant', 'content': 'PRIVATE_ASSISTANT_TRANSCRIPT'},
        {
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': 'PRIVATE_ARTIFACT_SOURCE'},
            {
              'type': 'document',
              'artifact_id': 'private-artifact',
              'name': 'PRIVATE_ARTIFACT_NAME.pdf',
            },
          ],
        },
      ];
      final api = ApiClient(
        baseUrl: 'http://127.0.0.1:8642',
        apiKey: 'test-key',
        httpClient: MockClient((request) async {
          if (request.url.path == '/api/sessions/session-tip/messages') {
            messageRequests++;
            return http.Response(jsonEncode({'data': privateTranscript}), 200);
          }
          return http.Response('{}', 404);
        }),
      );
      final connection = SavedConnection(
        id: 'connection-artifacts',
        label: 'Artifacts',
        host: '127.0.0.1',
        port: 8642,
        apiKey: 'test-key',
        kind: InstanceKind.vps,
      );
      const session = Session(
        id: 'session-tip',
        lineageRootId: 'session-root',
        title: 'Read-only overview',
        model: 'model-a',
        source: 'mobile',
        messageCount: 3,
        isActive: false,
        preview: '',
        startedAt: 1784500000,
      );

      await tester.pumpWidget(
        _host(
          SessionDetailScreen(
            connection: connection,
            session: session,
            client: api,
            skipInitialSessionRefresh: true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(messageRequests, 0);
      expect(find.byTooltip('Artefactos'), findsNothing);
      expect(find.byType(Tab), findsNothing);
      expect(find.textContaining('PRIVATE_'), findsNothing);

      // Ni los detalles técnicos ni la página de contexto piden el transcript.
      final context = find.byKey(const ValueKey('session-detail-context'));
      await tester.ensureVisible(context);
      await tester.pumpAndSettle();
      await tester.tap(context);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('session-context-page')),
        findsOneWidget,
      );
      expect(find.text('session-tip'), findsOneWidget);
      expect(messageRequests, 0);
      expect(find.textContaining('PRIVATE_'), findsNothing);
    },
  );

  testWidgets(
    'SessionDetail oculta (no deshabilita) las acciones de escritura en '
    'conexiones de solo lectura',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final api = ApiClient(
        baseUrl: 'http://127.0.0.1:8642',
        apiKey: 'k',
        httpClient: MockClient((_) async => http.Response('{}', 404)),
      );
      Future<void> pump({required bool readOnly}) async {
        await tester.pumpWidget(
          _host(
            SessionDetailScreen(
              key: ValueKey(readOnly),
              connection: SavedConnection(
                id: 'connection-ro-$readOnly',
                label: 'Instance',
                host: '127.0.0.1',
                port: 8642,
                apiKey: 'k',
                readOnly: readOnly,
              ),
              session: const Session(
                id: 'session-ro',
                title: 'Plan',
                model: 'model-a',
                source: 'mobile',
                messageCount: 1,
                isActive: false,
                preview: 'Último mensaje',
                startedAt: 1784500000,
              ),
              client: api,
              skipInitialSessionRefresh: true,
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await pump(readOnly: true);
      expect(find.byKey(const ValueKey('session-detail-resume')), findsOne);
      expect(
        find.byKey(const ValueKey('session-detail-duplicate')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('session-detail-delete')), findsNothing);
      expect(
        find.byKey(const ValueKey('session-detail-copy-summary')),
        findsOne,
      );
      expect(find.text('Solo lectura'), findsOneWidget);

      await pump(readOnly: false);
      expect(find.byKey(const ValueKey('session-detail-duplicate')), findsOne);
      final delete = find.byKey(const ValueKey('session-detail-delete'));
      await tester.ensureVisible(delete);
      await tester.pumpAndSettle();
      await tester.tap(delete);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('hermes-dialog')), findsOneWidget);
      expect(find.text('¿Eliminar esta conversación?'), findsOneWidget);
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('hermes-dialog')), findsNothing);
    },
  );
}
