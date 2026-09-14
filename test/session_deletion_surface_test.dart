import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/session_list_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _host(Widget child, {Locale locale = const Locale('es')}) => MaterialApp(
  locale: locale,
  theme: AppTheme.fromId('dark'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  home: child,
);

class _OfflineLineageApiClient extends ApiClient {
  _OfflineLineageApiClient()
    : super(
        baseUrl: 'https://hermes.test',
        apiKey: 'test-key',
        connectionId: 'conn-offline-delete',
        httpClient: MockClient((_) async => throw UnimplementedError()),
      );

  int lineageRequests = 0;

  @override
  Future<bool> healthCheck() async => true;

  @override
  Future<List<Session>> getSessions({
    bool includeChildren = false,
    String? profile,
  }) async {
    if (includeChildren) {
      lineageRequests++;
      throw StateError('offline');
    }
    return [
      Session.fromJson({
        'id': 'cron_report_20260717_090000',
        'title': 'Informe QA',
        'source': 'cron',
        'started_at': 1,
        'ended_at': 2,
      }),
    ];
  }
}

Future<void> pumpOfflineCronList(
  WidgetTester tester,
  ApiClient client, {
  Locale locale = const Locale('es'),
}) async {
  tester.view.physicalSize = const Size(800, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final manager = await ConnectionManager.create(prefs);
  final connection = SavedConnection(
    id: 'conn-offline-delete',
    label: 'QA',
    host: 'hermes.test',
    port: 443,
    apiKey: 'test-key',
    useHttps: true,
    kind: InstanceKind.vps,
  );
  await tester.pumpWidget(
    _host(
      SessionListScreen(
        connection: connection,
        connManager: manager,
        clientOverride: client,
      ),
      locale: locale,
    ),
  );
  for (var attempt = 0; attempt < 20; attempt++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (find
        .byKey(const ValueKey('session-filter-automation'))
        .evaluate()
        .isNotEmpty) {
      break;
    }
  }
  // Los informes cron no contaminan la lista general, pero siguen disponibles
  // en su apartado específico con todas sus acciones de gestión.
  expect(find.text('Informe QA'), findsNothing);
  await tester.tap(find.byKey(const ValueKey('session-filter-automation')));
  await tester.pump();
  expect(find.text('Informe QA'), findsOneWidget);
}

Future<void> deleteConversationOnly(WidgetTester tester) async {
  final action = find.byKey(const ValueKey('cron_delete_conversation_only'));
  expect(action, findsOneWidget);
  await tester.tap(action);
  await tester.pumpAndSettle();
}

void expectOfflineFeedback(WidgetTester tester, String message) {
  expect(find.text('Informe QA'), findsOneWidget);
  expect(find.text(message), findsOneWidget);
  expect(find.textContaining('Bad state:'), findsNothing);
  expect(tester.takeException(), isNull);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => call.method == 'readAll' ? <String, String>{} : null,
        );
  });

  testWidgets('swipe cron sin red conserva la fila y muestra un solo error', (
    tester,
  ) async {
    final client = _OfflineLineageApiClient();
    await pumpOfflineCronList(tester, client);

    await tester.drag(find.text('Informe QA'), const Offset(-700, 0));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('session-actions-surface')),
      findsOneWidget,
    );
    expect(find.byType(BottomSheet), findsNothing);
    final deleteAction = find.text('Borrar sesión');
    await tester.ensureVisible(deleteAction);
    await tester.tap(deleteAction);
    await tester.pumpAndSettle();
    await deleteConversationOnly(tester);

    expectOfflineFeedback(
      tester,
      'No se pudo comprobar la conversación completa. '
      'Revisa la conexión e inténtalo de nuevo.',
    );
    expect(client.lineageRequests, 1);
  });

  testWidgets('sheet cron sin red conserva la fila y muestra un solo error', (
    tester,
  ) async {
    final client = _OfflineLineageApiClient();
    await pumpOfflineCronList(tester, client);

    await tester.longPress(find.text('Informe QA'));
    await tester.pumpAndSettle();
    final deleteAction = find.text('Borrar sesión');
    await tester.ensureVisible(deleteAction);
    await tester.tap(deleteAction);
    await tester.pumpAndSettle();
    await deleteConversationOnly(tester);

    expectOfflineFeedback(
      tester,
      'No se pudo comprobar la conversación completa. '
      'Revisa la conexión e inténtalo de nuevo.',
    );
    expect(client.lineageRequests, 1);
  });

  testWidgets('el error offline se localiza en inglés sin prefijo técnico', (
    tester,
  ) async {
    final client = _OfflineLineageApiClient();
    await pumpOfflineCronList(tester, client, locale: const Locale('en'));

    await tester.drag(find.text('Informe QA'), const Offset(-700, 0));
    await tester.pumpAndSettle();
    final deleteAction = find.text('Delete session');
    await tester.ensureVisible(deleteAction);
    await tester.tap(deleteAction);
    await tester.pumpAndSettle();
    await deleteConversationOnly(tester);

    expectOfflineFeedback(
      tester,
      'The full conversation could not be checked. '
      'Check the connection and try again.',
    );
    expect(find.textContaining('No se pudo'), findsNothing);
    expect(client.lineageRequests, 1);
  });
}
