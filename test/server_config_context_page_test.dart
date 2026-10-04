// The Context page reuses the compression card (now confirmed by a re-read)
// and the Conversation page links to the existing voice settings.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/server_config_page_screen.dart';
import 'package:hermes_android/core/services/compression_config_repository.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/server_config_repository.dart';
import 'package:hermes_android/core/settings/server_config_pages.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/compression_config_card.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

final class _Store implements ServerConfigStore {
  _Store({required this.writable});

  final bool writable;

  @override
  bool get isWritable => writable;

  @override
  Future<Map<String, dynamic>> readConfig() async => {
    'context': {'engine': 'compressor'},
    'voice': {'voice_chat_mode': 'push'},
  };

  @override
  Future<Map<String, dynamic>> readSchema() async => {'fields': {}};

  @override
  Future<Object?> save(String path, Object? value) async => value;
}

Map<String, dynamic> _clone(Object value) =>
    jsonDecode(jsonEncode(value)) as Map<String, dynamic>;

final _contextSchema = <String, dynamic>{
  'fields': {
    'compression.enabled': {'type': 'boolean'},
    'compression.threshold': {'type': 'number'},
    'compression.target_ratio': {'type': 'number'},
    'compression.protect_last_n': {'type': 'number'},
    'context.engine': {'type': 'string', 'description': 'Context engine'},
  },
};

final _conversationSchema = <String, dynamic>{
  'fields': {
    'voice.voice_chat_mode': {'type': 'string'},
  },
};

SavedConnection _connection({bool readOnly = false}) => SavedConnection(
  id: 'conn-ctx1215',
  label: 'Ctx QA',
  host: 'hermes.example.test',
  port: 8642,
  apiKey: '',
  dashboardUrl: 'http://hermes.example.test:9119',
  readOnly: readOnly,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ConnectionManager manager;
  late List<http.Request> requests;
  late Map<String, dynamic> serverConfig;
  late Map<String, dynamic> fixture;

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
    fixture =
        jsonDecode(
              File(
                'test/fixtures/spec047/compression_config.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    serverConfig = _clone(fixture['config']!);
    requests = [];
  });

  tearDown(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          null,
        );
  });

  DashboardClient dashboard() => DashboardClient(
    host: 'hermes.example.test',
    port: 9119,
    manualToken: 'synthetic-token',
    httpClientOverride: MockClient((request) async {
      requests.add(request);
      if (request.method == 'PUT') {
        final sent =
            (jsonDecode(request.body) as Map<String, dynamic>)['config']
                as Map<String, dynamic>;
        (serverConfig['compression'] as Map<String, dynamic>).addAll(
          sent['compression'] as Map<String, dynamic>,
        );
        return http.Response('{"ok":true}', 200);
      }
      return http.Response(
        jsonEncode(
          request.url.path == '/api/config/schema'
              ? fixture['schema']
              : serverConfig,
        ),
        200,
      );
    }),
  );

  Future<void> pumpPage(
    WidgetTester tester,
    ServerConfigPage page,
    Map<String, dynamic> schema, {
    bool readOnly = false,
  }) async {
    final client = dashboard();
    addTearDown(client.close);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: ServerConfigPageScreen(
          connection: _connection(readOnly: readOnly),
          connManager: manager,
          page: page,
          schema: schema,
          storeFor: (profile, {required writable}) =>
              _Store(writable: writable),
          compressionFor: (profile, {required writable}) =>
              CompressionConfigRepository(
                client,
                profile: profile,
                writable: writable,
              ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('Context', () {
    testWidgets('mounts the compression card and the other context rows', (
      tester,
    ) async {
      await pumpPage(tester, ServerConfigPage.context, _contextSchema);

      expect(find.byType(CompressionConfigCard), findsOneWidget);
      expect(find.text('Comprimir automáticamente'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('adv1215-field-context.engine')),
        findsOneWidget,
      );
      for (final path in const [
        'compression.enabled',
        'compression.threshold',
        'compression.target_ratio',
        'compression.protect_last_n',
      ]) {
        expect(find.byKey(ValueKey('adv1215-field-$path')), findsNothing);
      }
    });

    testWidgets('a save through the card is read back', (tester) async {
      await pumpPage(tester, ServerConfigPage.context, _contextSchema);
      requests.clear();

      tester
          .widget<SwitchListTile>(
            find.byKey(const ValueKey('compression-config-enabled')),
          )
          .onChanged!(false);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();

      expect(requests.map((r) => r.method), ['PUT', 'GET']);
      expect(requests.last.url.path, '/api/config');
    });

    testWidgets('without compression fields there is no card', (tester) async {
      await pumpPage(tester, ServerConfigPage.context, {
        'fields': {
          'context.engine': {'type': 'string'},
        },
      });
      expect(find.byType(CompressionConfigCard), findsNothing);
      expect(
        find.byKey(const ValueKey('adv1215-field-context.engine')),
        findsOneWidget,
      );
    });

    testWidgets('read only: the card cannot change anything', (tester) async {
      await pumpPage(
        tester,
        ServerConfigPage.context,
        _contextSchema,
        readOnly: true,
      );
      requests.clear();

      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const ValueKey('compression-config-enabled')),
            )
            .onChanged,
        isNull,
      );
      expect(requests.where((r) => r.method == 'PUT'), isEmpty);
    });
  });

  group('Conversation', () {
    testWidgets('links to the voice settings and lists its own fields', (
      tester,
    ) async {
      await pumpPage(
        tester,
        ServerConfigPage.conversation,
        _conversationSchema,
      );

      expect(find.byKey(const ValueKey('adv1215-voice-link')), findsOneWidget);
      expect(find.text('Voz'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('adv1215-field-voice.voice_chat_mode')),
        findsOneWidget,
      );
    });

    testWidgets('other pages have no voice link', (tester) async {
      await pumpPage(tester, ServerConfigPage.context, _contextSchema);
      expect(find.byKey(const ValueKey('adv1215-voice-link')), findsNothing);
    });
  });
}
