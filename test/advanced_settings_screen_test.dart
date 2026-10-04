// Settings › Advanced: the pages the server's schema brings, the Tools row
// when the server has toolsets, and a search that runs in memory.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/advanced_settings_screen.dart';
import 'package:hermes_android/core/screens/server_config_page_screen.dart';
import 'package:hermes_android/core/screens/server_toolsets_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/server_config_repository.dart';
import 'package:hermes_android/core/services/server_toolsets_repository.dart';
import 'package:hermes_android/core/settings/settings_deep_link.dart';
import 'package:hermes_android/core/settings/settings_search.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_toolsets_server.dart';

final class _Store implements ServerConfigStore {
  _Store(this.schema, {this.error});

  final Map<String, dynamic> schema;
  final ServerConfigException? error;
  int schemaReads = 0;
  int configReads = 0;

  @override
  bool get isWritable => true;

  @override
  Future<Map<String, dynamic>> readConfig() async {
    configReads++;
    return {
      'agent': {'reasoning_effort': 'low'},
      'timezone': 'UTC',
    };
  }

  @override
  Future<Map<String, dynamic>> readSchema() async {
    schemaReads++;
    final failure = error;
    if (failure != null) throw failure;
    return schema;
  }

  @override
  Future<Object?> save(String path, Object? value) async => value;
}

Map<String, dynamic> _schema() => {
  'fields': {
    'agent.reasoning_effort': {
      'type': 'select',
      'description': 'Reasoning effort for the main model',
      'options': ['low', 'high'],
    },
    'timezone': {'type': 'string', 'description': 'IANA time zone'},
    'agent.max_turns': {'type': 'number'},
    'logging.level': {'type': 'string'},
  },
};

SavedConnection _connection() => SavedConnection(
  id: 'conn-adv1215',
  label: 'Adv QA',
  host: 'hermes.example.test',
  port: 8642,
  apiKey: '',
  dashboardUrl: 'http://hermes.example.test:9119',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ConnectionManager manager;
  late FakeToolsetsServer server;
  late _Store store;

  setUp(() async {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => call.method == 'readAll' ? <String, String>{} : null,
        );
    SharedPreferences.setMockInitialValues({});
    manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    server = FakeToolsetsServer();
    store = _Store(_schema());
  });

  tearDown(() {
    SettingsDeepLink.pending.value = null;
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          null,
        );
  });

  Future<void> pump(
    WidgetTester tester, {
    Map<String, dynamic>? initialSchema,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: const Scaffold(body: Text('Settings')),
      ),
    );
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => AdvancedSettingsScreen(
          connection: _connection(),
          connManager: manager,
          initialSchema: initialSchema,
          storeFor: (profile, {required writable}) => store,
          toolsetsFor: (profile, {required writable}) =>
              ServerToolsetsRepository(
                server.dashboard,
                profile: profile,
                writable: writable,
              ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Strings strings(WidgetTester tester) =>
      Strings.of(tester.element(find.byType(Scaffold).last));

  group('what it shows', () {
    testWidgets('reads the schema and the toolsets once when it opens', (
      tester,
    ) async {
      await pump(tester);

      expect(store.schemaReads, 1);
      expect(server.requests.map((r) => r.url.path), ['/api/tools/toolsets']);
      await tester.pump(const Duration(minutes: 5));
      expect(store.schemaReads, 1);
      expect(server.requests, hasLength(1));
    });

    testWidgets('a schema already read is not read again', (tester) async {
      await pump(tester, initialSchema: _schema());
      expect(store.schemaReads, 0);
    });

    testWidgets('only the pages that have a field, then Tools', (tester) async {
      await pump(tester);
      final s = strings(tester);

      expect(find.text(s.adv1215PageMain), findsOneWidget);
      expect(find.text(s.adv1215PageBehavior), findsOneWidget);
      expect(find.text(s.adv1215PageRuntime), findsOneWidget);
      expect(find.text(s.adv1215PageShell), findsNothing);
      expect(find.text(s.adv1215PageNetwork), findsNothing);
      expect(find.text(s.drawerTools), findsOneWidget);
    });

    testWidgets('a server without toolsets shows no Tools row', (tester) async {
      server.toolsets = [];
      await pump(tester);
      expect(find.text(strings(tester).drawerTools), findsNothing);
      expect(find.text(strings(tester).adv1215PageMain), findsOneWidget);
    });

    testWidgets('a server that offers nothing says so', (tester) async {
      store = _Store({'fields': <String, dynamic>{}});
      server.toolsets = [];
      await pump(tester);
      expect(find.text(strings(tester).adv1215Unreadable), findsOneWidget);
    });

    testWidgets('a schema that cannot be read says so', (tester) async {
      store = _Store(
        _schema(),
        error: const ServerConfigException(
          ServerConfigFailureKind.permissionDenied,
        ),
      );
      await pump(tester);
      expect(find.text(strings(tester).adv1215LoadDenied), findsOneWidget);
    });

    testWidgets('a row opens its page', (tester) async {
      await pump(tester);
      await tester.tap(find.text(strings(tester).adv1215PageBehavior));
      await tester.pumpAndSettle();
      expect(find.byType(ServerConfigPageScreen), findsOneWidget);
    });

    testWidgets('Tools opens the toolsets', (tester) async {
      await pump(tester);
      await tester.tap(find.text(strings(tester).drawerTools));
      await tester.pumpAndSettle();
      expect(find.byType(ServerToolsetsScreen), findsOneWidget);
    });

    testWidgets('a profile switch reads both again', (tester) async {
      await pump(tester);
      await manager.setActiveProfile('conn-adv1215', 'work');
      await tester.pumpAndSettle();

      expect(store.schemaReads, 2);
      expect(server.requests.last.url.queryParameters, {'profile': 'work'});
    });
  });

  group('search', () {
    testWidgets('typing reads nothing', (tester) async {
      await pump(tester);
      final before = (
        store.schemaReads,
        store.configReads,
        server.requests.length,
      );

      for (final text in ['r', 're', 'rea', 'reas', 'reasoning']) {
        await tester.enterText(find.byType(TextField), text);
        await tester.pump();
      }

      expect((
        store.schemaReads,
        store.configReads,
        server.requests.length,
      ), before);
    });

    testWidgets('reasoning leads to the Main model page, by its row', (
      tester,
    ) async {
      await pump(tester);
      await tester.enterText(find.byType(TextField), 'reasoning');
      await tester.pump();

      expect(
        find.byKey(const ValueKey('adv1215-hit-agent.reasoning_effort')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('adv1215-hit-agent.reasoning_effort')),
      );
      await tester.pumpAndSettle();

      final page = tester.widget<ServerConfigPageScreen>(
        find.byType(ServerConfigPageScreen),
      );
      expect(page.highlightPath, 'agent.reasoning_effort');
      expect(
        find.byKey(const ValueKey('adv1215-highlight-agent.reasoning_effort')),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('its Spanish text leads there too', (tester) async {
      await pump(tester);
      await tester.enterText(find.byType(TextField), 'razonamiento');
      await tester.pump();
      expect(
        find.byKey(const ValueKey('adv1215-hit-agent.reasoning_effort')),
        findsOneWidget,
      );
    });

    testWidgets('no match says so, and clearing brings the pages back', (
      tester,
    ) async {
      await pump(tester);
      await tester.enterText(find.byType(TextField), 'zzzz');
      await tester.pump();
      expect(find.text(strings(tester).adv1215SearchEmpty), findsOneWidget);
      expect(find.text(strings(tester).adv1215PageMain), findsNothing);

      await tester.tap(find.byTooltip(strings(tester).adv1215SearchClear));
      await tester.pump();
      expect(find.text(strings(tester).adv1215PageMain), findsOneWidget);
    });

    testWidgets('a Settings section goes back and asks for it', (tester) async {
      await pump(tester);
      await tester.enterText(find.byType(TextField), 'seguridad');
      await tester.pump();

      await tester.tap(
        find.byKey(const ValueKey('adv1215-hit-section-security')),
      );
      await tester.pumpAndSettle();

      expect(find.byType(AdvancedSettingsScreen), findsNothing);
      expect(find.text('Settings'), findsOneWidget);
      expect(SettingsDeepLink.pending.value, SettingsSection.security);
    });
  });
}
