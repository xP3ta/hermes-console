// Settings › Advanced › Tools: the server's toolsets, their switches and the
// detail of one (provider, model, credentials). Every write is read back.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/server_toolset.dart';
import 'package:hermes_android/core/screens/server_toolsets_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/server_toolsets_repository.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_toolsets_server.dart';

SavedConnection _connection({bool readOnly = false}) => SavedConnection(
  id: 'conn-tools1215',
  label: 'Tools QA',
  host: 'hermes.example.test',
  port: 8642,
  apiKey: '',
  dashboardUrl: 'http://hermes.example.test:9119',
  readOnly: readOnly,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ConnectionManager manager;
  late FakeToolsetsServer server;
  late List<String> profiles;

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
    profiles = [];
  });

  tearDown(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          null,
        );
  });

  ServerToolsetsRepository repoFor(String profile, {required bool writable}) {
    profiles.add(profile);
    return ServerToolsetsRepository(
      server.dashboard,
      profile: profile,
      writable: writable,
    );
  }

  Future<void> pump(WidgetTester tester, Widget screen) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: screen,
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Future<void> pumpList(WidgetTester tester, {bool readOnly = false}) => pump(
    tester,
    ServerToolsetsScreen(
      connection: _connection(readOnly: readOnly),
      connManager: manager,
      toolsetsFor: repoFor,
    ),
  );

  Future<void> pumpDetail(
    WidgetTester tester, {
    String name = 'web',
    bool readOnly = false,
  }) => pump(
    tester,
    ToolsetDetailScreen(
      connection: _connection(readOnly: readOnly),
      connManager: manager,
      toolset: ServerToolset(name: name, label: 'Label $name'),
      toolsetsFor: repoFor,
    ),
  );

  Strings strings(WidgetTester tester) =>
      Strings.of(tester.element(find.byType(Scaffold).first));

  Finder switchOf(String name) => find.descendant(
    of: find.byKey(ValueKey('adv1215-toolset-$name')),
    matching: find.byType(Switch),
  );

  group('list', () {
    testWidgets('one row per toolset, switch on what is enabled', (
      tester,
    ) async {
      await pumpList(tester);

      expect(find.text('Label web'), findsOneWidget);
      expect(find.text('Label files'), findsOneWidget);
      expect(tester.widget<Switch>(switchOf('web')).value, isTrue);
      expect(tester.widget<Switch>(switchOf('files')).value, isFalse);
      expect(server.requests.map((r) => r.method), ['GET']);
    });

    testWidgets('a wrapped list reads the same', (tester) async {
      server.wrapList = true;
      await pumpList(tester);
      expect(find.text('Label web'), findsOneWidget);
    });

    testWidgets('a server with none says so', (tester) async {
      server.toolsets = [];
      await pumpList(tester);
      expect(find.text(strings(tester).adv1215ToolsNone), findsOneWidget);
    });

    testWidgets('a toolset the server cannot use says so', (tester) async {
      server.toolsets = [
        {...fakeToolset('files'), 'available': false},
      ];
      await pumpList(tester);
      expect(find.text(strings(tester).adv1215ToolUnavailable), findsOneWidget);
    });

    testWidgets('reads nothing more while it stays open', (tester) async {
      await pumpList(tester);
      await tester.pump(const Duration(minutes: 10));
      expect(server.requests, hasLength(1));
    });
  });

  group('switch', () {
    testWidgets('one PUT, one re-read, and the row follows the server', (
      tester,
    ) async {
      await pumpList(tester);
      server.requests.clear();

      await tester.tap(switchOf('files'));
      await tester.pump();
      await tester.pump();

      expect(server.requests.map((r) => r.method), ['PUT', 'GET']);
      expect(server.puts.single.url.path, '/api/tools/toolsets/files');
      expect(jsonDecode(server.puts.single.body), {'enabled': true});
      expect(tester.widget<Switch>(switchOf('files')).value, isTrue);
    });

    testWidgets('a flag the server did not keep goes back and says so', (
      tester,
    ) async {
      await pumpList(tester);
      server.ignoreWrites = true;

      await tester.tap(switchOf('files'));
      await tester.pump();
      await tester.pump();

      expect(tester.widget<Switch>(switchOf('files')).value, isFalse);
      expect(find.text(strings(tester).adv1215SaveFailed), findsWidgets);
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('an install the server started is only announced', (
      tester,
    ) async {
      server.enableResponse = {
        'ok': true,
        'name': 'files',
        'platform': 'cli',
        'enabled': true,
        'post_setup_started': 'install_x',
      };
      await pumpList(tester);
      server.requests.clear();

      await tester.tap(switchOf('files'));
      await tester.pump();
      await tester.pump();
      expect(
        find.text(strings(tester).voiceServerSetupRunning),
        findsOneWidget,
      );

      await tester.pump(const Duration(minutes: 10));
      expect(server.requests.map((r) => r.method), ['PUT', 'GET']);
    });

    testWidgets('turning off the last enabled one asks first', (tester) async {
      await pumpList(tester);
      server.requests.clear();

      await tester.tap(switchOf('web'));
      await tester.pumpAndSettle();
      expect(find.text(strings(tester).adv1215ToolsLastTitle), findsOneWidget);
      expect(server.puts, isEmpty);

      await tester.tap(find.text(strings(tester).commonCancel));
      await tester.pumpAndSettle();
      expect(server.puts, isEmpty);
      expect(tester.widget<Switch>(switchOf('web')).value, isTrue);

      await tester.tap(switchOf('web'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(strings(tester).adv1215ToolsLastConfirm));
      await tester.pumpAndSettle();
      expect(jsonDecode(server.puts.single.body), {'enabled': false});
      expect(tester.widget<Switch>(switchOf('web')).value, isFalse);
    });

    testWidgets('turning one off with another still on does not ask', (
      tester,
    ) async {
      server.toolsets = [
        fakeToolset('web', enabled: true),
        fakeToolset('files', enabled: true),
      ];
      await pumpList(tester);

      await tester.tap(switchOf('web'));
      await tester.pump();
      await tester.pump();

      expect(find.text(strings(tester).adv1215ToolsLastTitle), findsNothing);
      expect(server.puts, hasLength(1));
    });

    testWidgets('read only: the switches are disabled', (tester) async {
      await pumpList(tester, readOnly: true);
      expect(tester.widget<Switch>(switchOf('files')).onChanged, isNull);
      await tester.tap(switchOf('files'));
      await tester.pump();
      expect(server.puts, isEmpty);
    });

    testWidgets('leaving mid-write leaves no error behind', (tester) async {
      await pumpList(tester);
      await tester.tap(switchOf('files'));
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('a profile switch reads the list again for that profile', (
      tester,
    ) async {
      await pumpList(tester);
      await manager.setActiveProfile('conn-tools1215', 'work');
      await tester.pump();
      await tester.pump();

      expect(profiles, ['', 'work']);
      expect(server.requests.last.url.queryParameters, {'profile': 'work'});
    });
  });

  group('detail', () {
    testWidgets('opens with one read of the config and one of the models', (
      tester,
    ) async {
      await pumpDetail(tester);

      expect(server.requests.map((r) => r.url.path), [
        '/api/tools/toolsets/web/config',
        '/api/tools/toolsets/web/models',
      ]);
      expect(find.text('alpha'), findsWidgets);
      expect(find.text('beta'), findsOneWidget);
    });

    testWidgets('choosing a provider: one PUT, then the config again', (
      tester,
    ) async {
      server.config['providers'][1]['requires_nous_auth'] = false;
      await pumpDetail(tester);
      server.requests.clear();

      await tester.tap(find.text('beta'));
      await tester.pumpAndSettle();

      expect(server.requests.map((r) => r.method), ['PUT', 'GET']);
      expect(jsonDecode(server.puts.single.body), {'provider': 'beta'});
      expect(server.config['active_provider'], 'beta');
    });

    testWidgets('a provider that needs a Nous account says so', (tester) async {
      await pumpDetail(tester);
      expect(find.text(strings(tester).adv1215ToolNeedsNous), findsOneWidget);
    });

    testWidgets('choosing a model: one PUT, then the models again', (
      tester,
    ) async {
      await pumpDetail(tester);
      server.requests.clear();

      await tester.tap(find.text('Model 1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Model 2'));
      await tester.pumpAndSettle();

      expect(server.requests.map((r) => r.method), ['PUT', 'GET']);
      expect(jsonDecode(server.puts.single.body), {'model': 'm2'});
      expect(find.text('Model 2'), findsOneWidget);
    });

    testWidgets('a key is typed masked, sent once and never shown again', (
      tester,
    ) async {
      await pumpDetail(tester);
      expect(find.text(strings(tester).adv1215ToolKeyUnset), findsOneWidget);
      server.requests.clear();

      await tester.tap(find.text('ALPHA_KEY'));
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.obscureText, isTrue);
      await tester.enterText(find.byType(TextField), 'synthetic-secret-value');
      expect(server.puts, isEmpty);
      await tester.tap(find.text(strings(tester).commonSave));
      await tester.pumpAndSettle();

      expect(server.puts.single.url.path, '/api/tools/toolsets/web/env');
      expect(jsonDecode(server.puts.single.body), {
        'env': {'ALPHA_KEY': 'synthetic-secret-value'},
      });
      expect(find.textContaining('synthetic-secret-value'), findsNothing);
      expect(find.text(strings(tester).adv1215ToolKeySet), findsOneWidget);
    });

    testWidgets('a toolset with nothing to configure says so', (tester) async {
      server.config['has_category'] = false;
      await pumpDetail(tester);
      expect(find.text(strings(tester).adv1215ToolNothing), findsOneWidget);
      expect(server.requests.map((r) => r.url.path), [
        '/api/tools/toolsets/web/config',
      ], reason: 'no models read without a category');
    });

    testWidgets('read only: nothing can be picked or typed', (tester) async {
      await pumpDetail(tester, readOnly: true);
      server.requests.clear();

      await tester.tap(find.text('beta'));
      await tester.tap(find.text('ALPHA_KEY'));
      await tester.pumpAndSettle();

      expect(find.byType(TextField), findsNothing);
      expect(server.requests, isEmpty);
    });
  });
}
