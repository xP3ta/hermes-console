import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/home_dashboard_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/session_archive.dart';
import 'package:hermes_android/core/services/session_deletion.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RecentHomeClient extends ApiClient {
  _RecentHomeClient(this.session)
    : super(
        baseUrl: 'http://127.0.0.1:8642',
        apiKey: 'test-key',
        httpClient: MockClient((_) async => http.Response('{}', 404)),
      );

  final Session session;

  @override
  Future<bool> healthCheck() async => true;

  @override
  Future<List<Session>> getSessions({
    bool includeChildren = false,
    String? profile,
  }) async => [session];

  @override
  void close() {}
}

class _ProfileRowsHomeClient extends ApiClient {
  _ProfileRowsHomeClient(this.sessions)
    : super(
        baseUrl: 'http://127.0.0.1:8642',
        apiKey: 'test-key',
        httpClient: MockClient((_) async => http.Response('{}', 404)),
      );

  final List<Session> sessions;
  String? requestedProfile;

  @override
  Future<bool> healthCheck() async => true;

  @override
  Future<List<Session>> getSessions({
    bool includeChildren = false,
    String? profile,
  }) async {
    requestedProfile = profile;
    return List<Session>.of(sessions);
  }

  @override
  void close() {}
}

class _MutableRecentHomeClient extends ApiClient {
  _MutableRecentHomeClient(this.sessions)
    : super(
        baseUrl: 'http://127.0.0.1:8642',
        apiKey: 'test-key',
        httpClient: MockClient((_) async => http.Response('{}', 404)),
      );

  List<Session> sessions;
  int sessionReads = 0;

  @override
  Future<bool> healthCheck() async => true;

  @override
  Future<List<Session>> getSessions({
    bool includeChildren = false,
    String? profile,
  }) async {
    sessionReads++;
    return List<Session>.of(sessions);
  }

  @override
  void close() {}
}

class _DeferredRecentHomeClient extends ApiClient {
  _DeferredRecentHomeClient()
    : super(
        baseUrl: 'http://127.0.0.1:8642',
        apiKey: 'test-key',
        httpClient: MockClient((_) async => http.Response('{}', 404)),
      );

  final List<Completer<List<Session>>> sessionLoads = [];

  @override
  Future<bool> healthCheck() async => true;

  @override
  Future<List<Session>> getSessions({
    bool includeChildren = false,
    String? profile,
  }) {
    final load = Completer<List<Session>>();
    sessionLoads.add(load);
    return load.future;
  }

  @override
  void close() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final secureValues = <String, String>{};
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, (call) async {
          final args = call.arguments is Map
              ? Map<Object?, Object?>.from(call.arguments as Map)
              : const <Object?, Object?>{};
          switch (call.method) {
            case 'write':
              secureValues[args['key'] as String] = args['value'] as String;
              return null;
            case 'read':
              return secureValues[args['key']];
            case 'readAll':
              return Map<String, String>.of(secureValues);
            case 'delete':
              secureValues.remove(args['key']);
              return null;
          }
          return null;
        });
  });

  tearDown(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, null);
  });

  testWidgets(
    'Home stamps profileless scoped rows and rejects contradictory owners',
    (tester) async {
      final manager = await ConnectionManager.create(
        await SharedPreferences.getInstance(),
      );
      await manager.saveConnection(
        'QA',
        '127.0.0.2',
        8642,
        'test-key',
        kind: InstanceKind.vps,
      );
      final connection = manager.getConnections().single;
      await manager.setActiveConnection(connection.id);
      await manager.setActiveProfile(connection.id, 'canonical-owner');
      final client = _ProfileRowsHomeClient(const [
        Session(
          id: 'legacy-profileless-row',
          title: 'Visible legacy row',
          model: 'hermes-agent',
          source: 'mobile',
          messageCount: 1,
          isActive: false,
          preview: 'Content',
          startedAt: 2,
        ),
        Session(
          id: 'contradictory-row',
          title: 'Hidden contradictory row',
          model: 'hermes-agent',
          source: 'mobile',
          messageCount: 1,
          isActive: false,
          preview: 'Content',
          startedAt: 1,
          profile: 'other-owner',
        ),
      ]);

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('es'),
          theme: AppTheme.fromId('dark'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          home: HomeDashboardScreen(
            connManager: manager,
            clientFactory: (_) => client,
          ),
        ),
      );
      for (var attempt = 0; attempt < 40; attempt++) {
        await tester.pump(const Duration(milliseconds: 50));
        if (find.text('Visible legacy row').evaluate().isNotEmpty) break;
      }

      expect(client.requestedProfile, 'canonical-owner');
      expect(find.text('Visible legacy row'), findsOneWidget);
      expect(find.text('Hidden contradictory row'), findsNothing);
      final recentTile = tester.widget(
        find.byWidgetPredicate(
          (widget) => widget.runtimeType.toString() == '_RecentSessionTile',
        ),
      );
      expect((recentTile as dynamic).session.profile, 'canonical-owner');

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('swipe gestiona y renombra por identidad lógica', (tester) async {
    final manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    await manager.saveConnection(
      'QA',
      '127.0.0.2',
      8642,
      'test-key',
      kind: InstanceKind.vps,
    );
    final connection = manager.getConnections().single;
    await manager.setActiveConnection(connection.id);
    final session = Session(
      id: 'physical-session',
      lineageRootId: 'logical-session',
      title: 'Título del servidor',
      model: 'hermes-agent',
      source: 'mobile',
      messageCount: 1,
      isActive: false,
      preview: 'Contenido',
      startedAt: DateTime.now().millisecondsSinceEpoch / 1000,
    );
    final client = _RecentHomeClient(session);

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: HomeDashboardScreen(
          connManager: manager,
          clientFactory: (_) => client,
        ),
      ),
    );
    for (var attempt = 0; attempt < 30; attempt++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (find.text('Título del servidor').evaluate().isNotEmpty) break;
    }

    await tester.drag(find.text('Título del servidor'), const Offset(-500, 0));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('home-recent-actions')), findsOneWidget);
    expect(find.text('Título del servidor'), findsWidgets);
    expect(
      find.byKey(const ValueKey('home-recent-action-rename')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('home-recent-action-delete')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('home-recent-action-rename')));
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('session-title-editor-field'));
    expect(field, findsOneWidget);

    await tester.enterText(field, 'Título local');
    await tester.tap(find.text('Guardar'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('Título local'), findsOneWidget);
    expect(find.text('Título del servidor'), findsNothing);
    final archive = await SessionArchive.load(manager.prefs, connection.id);
    expect(archive.titleForSession(session), 'Título local');
    final persistedRows = manager.prefs.getStringList(
      'session_titles_${connection.id}',
    );
    expect(
      persistedRows?.map((row) => row.split('\t').first),
      contains('logical-session'),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'una limpieza confirmada refresca recientes sin salir de Inicio',
    (tester) async {
      final manager = await ConnectionManager.create(
        await SharedPreferences.getInstance(),
      );
      await manager.saveConnection(
        'QA',
        '127.0.0.2',
        8642,
        'test-key',
        kind: InstanceKind.vps,
      );
      final connection = manager.getConnections().single;
      await manager.setActiveConnection(connection.id);
      final client = _MutableRecentHomeClient([
        Session(
          id: 'to-clean',
          title: 'Conversación eliminada',
          model: 'hermes-agent',
          source: 'mobile',
          messageCount: 1,
          isActive: false,
          preview: 'Contenido',
          startedAt: DateTime.now().millisecondsSinceEpoch / 1000,
        ),
      ]);

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('es'),
          theme: AppTheme.fromId('dark'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          home: HomeDashboardScreen(
            connManager: manager,
            clientFactory: (_) => client,
          ),
        ),
      );
      for (var attempt = 0; attempt < 30; attempt++) {
        await tester.pump(const Duration(milliseconds: 50));
        if (find.text('Conversación eliminada').evaluate().isNotEmpty) break;
      }
      expect(find.text('Conversación eliminada'), findsOneWidget);
      final readsBefore = client.sessionReads;

      historyCleanupInvalidations.publish(
        connectionId: 'otra-instancia',
        scope: HistoryCleanupScope.normalConversations,
      );
      await tester.pump();
      expect(
        client.sessionReads,
        readsBefore,
        reason: 'Inicio ignora invalidaciones de otra conexión',
      );

      client.sessions = [];
      historyCleanupInvalidations.publish(
        connectionId: connection.id,
        scope: HistoryCleanupScope.normalConversations,
      );
      for (var attempt = 0; attempt < 30; attempt++) {
        await tester.pump(const Duration(milliseconds: 50));
        if (find.text('Conversación eliminada').evaluate().isEmpty) break;
      }

      expect(client.sessionReads, greaterThan(readsBefore));
      expect(find.text('Conversación eliminada'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      final readsAfterDispose = client.sessionReads;
      historyCleanupInvalidations.publish(
        connectionId: connection.id,
        scope: HistoryCleanupScope.normalConversations,
      );
      await tester.pump();
      expect(client.sessionReads, readsAfterDispose);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('el refresh más antiguo no pisa un resultado nuevo', (
    tester,
  ) async {
    final manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    await manager.saveConnection(
      'QA',
      '127.0.0.2',
      8642,
      'test-key',
      kind: InstanceKind.vps,
    );
    final connection = manager.getConnections().single;
    await manager.setActiveConnection(connection.id);
    final client = _DeferredRecentHomeClient();

    Session session(String id, String title) => Session(
      id: id,
      title: title,
      model: 'hermes-agent',
      source: 'mobile',
      messageCount: 1,
      isActive: false,
      preview: title,
      startedAt: DateTime.now().millisecondsSinceEpoch / 1000,
    );

    Future<void> pumpUntilLoads(int count) async {
      for (var attempt = 0; attempt < 40; attempt++) {
        await tester.pump(const Duration(milliseconds: 10));
        if (client.sessionLoads.length >= count) return;
      }
      fail('Se esperaban $count lecturas; hubo ${client.sessionLoads.length}.');
    }

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: HomeDashboardScreen(
          connManager: manager,
          clientFactory: (_) => client,
        ),
      ),
    );
    await pumpUntilLoads(1);
    client.sessionLoads[0].complete([session('initial', 'Inicial')]);
    await tester.pump();
    expect(find.text('Inicial'), findsOneWidget);

    historyCleanupInvalidations.publish(
      connectionId: connection.id,
      scope: HistoryCleanupScope.normalConversations,
    );
    await pumpUntilLoads(2);
    historyCleanupInvalidations.publish(
      connectionId: connection.id,
      scope: HistoryCleanupScope.normalConversations,
    );
    await pumpUntilLoads(3);

    client.sessionLoads[2].complete([session('new', 'Resultado nuevo')]);
    for (var attempt = 0; attempt < 20; attempt++) {
      await tester.pump(const Duration(milliseconds: 10));
      if (find.text('Resultado nuevo').evaluate().isNotEmpty) break;
    }
    expect(find.text('Resultado nuevo'), findsOneWidget);

    client.sessionLoads[1].complete([session('old', 'Resultado viejo')]);
    await tester.pump();
    await tester.pump();

    expect(find.text('Resultado nuevo'), findsOneWidget);
    expect(find.text('Resultado viejo'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
