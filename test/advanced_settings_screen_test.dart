// Settings › Advanced: one entry in Settings, pages built from the schema,
// confirmed writes (one PUT and one re-read), nothing sent while typing, and
// a search that goes straight to the row.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/advanced_settings_screen.dart';
import 'package:hermes_android/core/screens/settings_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _deepMerge(
  Map<String, dynamic> base,
  Map<String, dynamic> patch,
) {
  final out = Map<String, dynamic>.from(base);
  patch.forEach((key, value) {
    final current = out[key];
    out[key] = value is Map<String, dynamic> && current is Map<String, dynamic>
        ? _deepMerge(current, value)
        : value;
  });
  return out;
}

final class _Server {
  Map<String, dynamic> config = {
    'model': 'gpt-example',
    'timezone': 'UTC',
    'terminal': {'persistent_shell': false, 'cwd': '/srv/work'},
    'agent': {'reasoning_effort': 'medium', 'max_turns': 90},
  };
  Map<String, dynamic> schema = {
    'fields': {
      'timezone': {'type': 'string', 'description': 'Timezone'},
      'terminal.persistent_shell': {
        'type': 'boolean',
        'description': 'Persistent shell',
      },
      'terminal.cwd': {'type': 'string', 'description': 'Working folder'},
      'agent.reasoning_effort': {
        'type': 'select',
        'description': 'Reasoning effort',
        'options': ['low', 'medium', 'high'],
      },
      'agent.max_turns': {'type': 'number', 'description': 'Maximum turns'},
    },
  };
  List<Map<String, dynamic>> toolsets = [
    {
      'name': 'web',
      'label': 'Web',
      'description': 'Search',
      'enabled': true,
      'available': true,
      'configured': true,
    },
  ];
  final requests = <http.Request>[];
  bool applyWrites = true;
  int toolsetsStatus = 200;
  int schemaStatus = 200;
  Completer<void>? holdPut;
  Completer<void>? holdSchema;

  List<http.Request> get puts => [
    for (final r in requests)
      if (r.method == 'PUT') r,
  ];
  int get configGets => requests
      .where((r) => r.method == 'GET' && r.url.path == '/api/config')
      .length;

  DashboardClient client(SavedConnection _) => DashboardClient(
    host: '127.0.0.1',
    port: 9119,
    manualToken: 'synthetic-dashboard-token',
    httpClientOverride: MockClient((request) async {
      requests.add(request);
      final path = request.url.path;
      if (path == '/api/config/schema') {
        await holdSchema?.future;
        return http.Response(jsonEncode(schema), schemaStatus);
      }
      if (path == '/api/config' && request.method == 'GET') {
        return http.Response(jsonEncode(config), 200);
      }
      if (path == '/api/config' && request.method == 'PUT') {
        await holdPut?.future;
        if (applyWrites) {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          config = _deepMerge(config, body['config'] as Map<String, dynamic>);
        }
        return http.Response('{"ok":true}', 200);
      }
      if (path == '/api/tools/toolsets' && request.method == 'GET') {
        return http.Response(jsonEncode(toolsets), toolsetsStatus);
      }
      if (path.startsWith('/api/tools/toolsets/') && path.endsWith('/config')) {
        return http.Response(
          jsonEncode({'name': 'web', 'has_category': false, 'providers': []}),
          200,
        );
      }
      if (path.startsWith('/api/tools/toolsets/') && request.method == 'PUT') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        for (final t in toolsets) {
          if (path.endsWith('/${t['name']}')) t['enabled'] = body['enabled'];
        }
        return http.Response('{"ok":true,"post_setup_started":null}', 200);
      }
      return http.Response('{}', 404);
    }),
  );
}

SavedConnection _connection({bool readOnly = false}) => SavedConnection(
  id: 'qa-advanced',
  label: 'QA',
  host: 'hermes.example.test',
  port: 8642,
  apiKey: '',
  dashboardUrl: 'http://hermes.example.test:9119',
  readOnly: readOnly,
);

Future<ConnectionManager> _manager() async {
  SharedPreferences.setMockInitialValues({});
  return ConnectionManager.create(await SharedPreferences.getInstance());
}

Future<void> _pumpAdvanced(
  WidgetTester tester,
  _Server server, {
  ConnectionManager? manager,
  bool readOnly = false,
}) async {
  final connManager = manager ?? await _manager();
  tester.view.physicalSize = const Size(1080, 2000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('es'),
      theme: AppTheme.fromId('dark'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      home: AdvancedSettingsScreen(
        connection: _connection(readOnly: readOnly),
        connManager: connManager,
        dashboardFactory: server.client,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openPage(WidgetTester tester, String name) async {
  await tester.tap(find.byKey(ValueKey('adv-page-$name')));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // Building the "Data" block of Settings trips a framework assertion about
    // a `ListTile` inside a `DecoratedBox`; it happens on the base too and has
    // nothing to do with the Advanced row. Only that message is let through.
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exceptionAsString().contains(
        'ListTile background color or ink splashes may be invisible',
      )) {
        return;
      }
      previous?.call(details);
    };
    addTearDown(() => FlutterError.onError = previous);
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => call.method == 'readAll' ? <String, String>{} : null,
        );
  });

  tearDown(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          null,
        );
  });

  group('Settings entry', () {
    testWidgets('shows one Advanced row and reads nothing', (tester) async {
      final manager = await _manager();
      tester.view.physicalSize = const Size(1080, 3000);
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
      await tester.pump();
      tester.takeException();

      expect(find.text('Avanzado'), findsOneWidget);
      expect(find.text('Modelo principal'), findsNothing);
    });
  });

  group('pages', () {
    testWidgets('only pages the schema brought are listed, with Tools', (
      tester,
    ) async {
      final server = _Server();
      await _pumpAdvanced(tester, server);

      expect(find.byKey(const ValueKey('adv-page-mainModel')), findsOneWidget);
      expect(find.byKey(const ValueKey('adv-page-behavior')), findsOneWidget);
      expect(find.byKey(const ValueKey('adv-page-shell')), findsOneWidget);
      expect(find.byKey(const ValueKey('adv-page-projects')), findsOneWidget);
      expect(find.byKey(const ValueKey('adv-page-runtime')), findsOneWidget);
      expect(find.byKey(const ValueKey('adv-page-network')), findsNothing);
      expect(find.byKey(const ValueKey('adv-page-context')), findsNothing);
      expect(find.byKey(const ValueKey('adv-page-tools')), findsOneWidget);
    });

    testWidgets('no Tools row when the server has no toolsets', (tester) async {
      final server = _Server()..toolsetsStatus = 404;
      await _pumpAdvanced(tester, server);
      expect(find.byKey(const ValueKey('adv-page-tools')), findsNothing);
      expect(find.byKey(const ValueKey('adv-page-shell')), findsOneWidget);
    });

    testWidgets('a server without the schema shows no pages at all', (
      tester,
    ) async {
      final server = _Server()..schemaStatus = 404;
      await _pumpAdvanced(tester, server);
      expect(find.byKey(const ValueKey('adv-page-shell')), findsNothing);
      expect(find.byKey(const ValueKey('adv-page-tools')), findsNothing);
    });

    testWidgets('model, objects and secrets never appear on any page', (
      tester,
    ) async {
      final server = _Server();
      server.schema['fields'] = {
        ...(server.schema['fields'] as Map<String, dynamic>),
        'model': {'type': 'string', 'description': 'The model'},
        'terminal.env': {'type': 'object', 'description': 'Env map'},
        'model.api_key': {'type': 'string', 'description': 'Model key'},
      };
      await _pumpAdvanced(tester, server);
      await _openPage(tester, 'mainModel');
      expect(find.text('Reasoning effort'), findsOneWidget);
      expect(find.text('The model'), findsNothing);
      expect(find.text('Model key'), findsNothing);
    });
  });

  group('confirmed writes', () {
    testWidgets('a switch makes one PUT and one re-read', (tester) async {
      final server = _Server();
      await _pumpAdvanced(tester, server);
      await _openPage(tester, 'shell');
      final readsBefore = server.configGets;

      await tester.tap(
        find.byKey(const ValueKey('adv-toggle-terminal.persistent_shell')),
      );
      await tester.pumpAndSettle();

      expect(server.puts, hasLength(1));
      expect(jsonDecode(server.puts.single.body), {
        'config': {
          'terminal': {'persistent_shell': true},
        },
      });
      expect(server.configGets - readsBefore, 1);
      final toggle = tester.widget<Switch>(find.byType(Switch));
      expect(toggle.value, isTrue);
    });

    testWidgets('the PUT carries the active profile', (tester) async {
      final server = _Server();
      final manager = await _manager();
      await manager.setActiveProfile('qa-advanced', 'work');
      await _pumpAdvanced(tester, server, manager: manager);
      await _openPage(tester, 'shell');
      await tester.tap(
        find.byKey(const ValueKey('adv-toggle-terminal.persistent_shell')),
      );
      await tester.pumpAndSettle();
      expect(server.puts.single.url.queryParameters['profile'], 'work');
    });

    testWidgets('a re-read that disagrees puts the server value back', (
      tester,
    ) async {
      final server = _Server()..applyWrites = false;
      await _pumpAdvanced(tester, server);
      await _openPage(tester, 'shell');

      await tester.tap(
        find.byKey(const ValueKey('adv-toggle-terminal.persistent_shell')),
      );
      await tester.pumpAndSettle();

      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
      expect(find.text('No se pudo guardar'), findsOneWidget);
    });

    testWidgets('typing sends nothing; confirming sends one PUT and one GET', (
      tester,
    ) async {
      final server = _Server();
      await _pumpAdvanced(tester, server);
      await _openPage(tester, 'runtime');
      await tester.tap(find.byKey(const ValueKey('adv-edit-agent.max_turns')));
      await tester.pumpAndSettle();
      final requestsBefore = server.requests.length;

      for (final text in ['1', '12', '120', '1200']) {
        await tester.enterText(
          find.byKey(const ValueKey('server-config-editor')),
          text,
        );
        await tester.pump();
      }
      expect(server.requests.length, requestsBefore, reason: 'nothing per key');

      await tester.tap(find.text('Guardar'));
      await tester.pumpAndSettle();

      expect(server.puts, hasLength(1));
      expect(jsonDecode(server.puts.single.body), {
        'config': {
          'agent': {'max_turns': 1200},
        },
      });
      expect(server.requests.length - requestsBefore, 2);
      expect(find.text('1200'), findsOneWidget);
    });

    testWidgets('a select writes the picked option on selection', (
      tester,
    ) async {
      final server = _Server();
      await _pumpAdvanced(tester, server);
      await _openPage(tester, 'mainModel');
      await tester.tap(
        find.byKey(const ValueKey('adv-select-agent.reasoning_effort')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('high'));
      await tester.pumpAndSettle();
      expect(jsonDecode(server.puts.single.body), {
        'config': {
          'agent': {'reasoning_effort': 'high'},
        },
      });
    });

    testWidgets('a save answered after leaving the page throws nothing', (
      tester,
    ) async {
      final server = _Server()..holdPut = Completer<void>();
      await _pumpAdvanced(tester, server);
      await _openPage(tester, 'shell');
      await tester.tap(
        find.byKey(const ValueKey('adv-toggle-terminal.persistent_shell')),
      );
      await tester.pump();

      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await tester.pumpAndSettle();
      server.holdPut!.complete();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });

  group('read-only', () {
    testWidgets('controls do nothing and the network is untouched', (
      tester,
    ) async {
      final server = _Server();
      await _pumpAdvanced(tester, server, readOnly: true);
      await _openPage(tester, 'shell');
      final before = server.requests.length;
      await tester.tap(
        find.byKey(const ValueKey('adv-toggle-terminal.persistent_shell')),
      );
      await tester.pumpAndSettle();
      expect(server.requests.length, before);
      expect(
        find.text('Instancia en solo lectura — acción desactivada'),
        findsOneWidget,
      );
    });
  });

  group('profile', () {
    testWidgets('a read answered after a profile change is discarded', (
      tester,
    ) async {
      final server = _Server()..holdSchema = Completer<void>();
      final manager = await _manager();
      await _pumpAdvanced(tester, server, manager: manager);
      // The first read is still in flight when the profile changes.
      final late = server.holdSchema!;
      server.holdSchema = null;
      server.schema = {
        'fields': {
          'display.personality': {
            'type': 'string',
            'description': 'Personality',
          },
        },
      };
      await manager.setActiveProfile('qa-advanced', 'work');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('adv-page-behavior')), findsOneWidget);

      late.complete();
      await tester.pumpAndSettle();
      // The old profile's schema (shell, runtime...) never shows up.
      expect(find.byKey(const ValueKey('adv-page-shell')), findsNothing);
      expect(find.byKey(const ValueKey('adv-page-behavior')), findsOneWidget);
    });
  });

  group('search', () {
    testWidgets('finds a field, opens its page and tints the row once', (
      tester,
    ) async {
      final server = _Server();
      await _pumpAdvanced(tester, server);
      final before = server.requests.length;

      await tester.enterText(find.byType(TextField), 'reasoning');
      await tester.pumpAndSettle();
      expect(server.requests.length, before, reason: 'search is local');
      expect(find.text('Reasoning effort'), findsOneWidget);

      await tester.tap(find.text('Reasoning effort'));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));

      final row = find.byKey(
        const ValueKey('adv-field-agent.reasoning_effort'),
      );
      expect(row, findsOneWidget);
      Color? tint() =>
          (tester.widget<AnimatedContainer>(row).decoration as BoxDecoration?)
              ?.color;
      expect(tint(), isNot(Colors.transparent));

      await tester.pump(const Duration(seconds: 3));
      expect(tint(), Colors.transparent, reason: 'tinted once, then clear');
    });

    testWidgets('a search with no match says so', (tester) async {
      await _pumpAdvanced(tester, _Server());
      await tester.enterText(find.byType(TextField), 'zzzzzz');
      await tester.pumpAndSettle();
      expect(find.text('Sin resultados'), findsOneWidget);
    });
  });

  group('tools', () {
    testWidgets('disabling the last active toolset asks first', (tester) async {
      final server = _Server();
      await _pumpAdvanced(tester, server);
      await _openPage(tester, 'tools');

      await tester.tap(find.byKey(const ValueKey('toolset-switch-web')));
      await tester.pumpAndSettle();
      expect(find.text('¿Desactivar la última herramienta?'), findsOneWidget);
      expect(server.puts, isEmpty);

      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(server.puts, isEmpty);

      await tester.tap(find.byKey(const ValueKey('toolset-switch-web')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Desactivar'));
      await tester.pumpAndSettle();
      expect(server.puts, hasLength(1));
      expect(jsonDecode(server.puts.single.body), {'enabled': false});
    });
  });
}
