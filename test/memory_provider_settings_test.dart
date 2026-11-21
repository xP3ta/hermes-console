// The memory provider of a profile, as Hermes Desktop offers it: active and
// selected shown apart, the provider chosen from the server's own list and
// saved by itself, a form made of the fields the provider's plugin
// declares, the full configuration, credentials that are write-only, and
// OAuth connect where the provider has one. Fixtures are synthetic; no real
// server is involved.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/memory_provider_config.dart';
import 'package:hermes_android/core/screens/memory_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/memory_settings_api.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/memory_provider_settings.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_local_models_server.dart' show fakeConnection;

Map<String, Object?> _field(
  String key,
  String kind, {
  String? label,
  bool inline = true,
  Object? value = '',
  bool isSet = false,
  String group = '',
  List<String> options = const [],
  String info = '',
}) => {
  'key': key,
  'label': label ?? key,
  'kind': kind,
  'description': 'About $key',
  'info': info,
  'placeholder': '',
  'inline': inline,
  'group': group,
  'options': [
    for (final option in options)
      {'value': option, 'label': option.toUpperCase(), 'description': ''},
  ],
  'value': value,
  'is_set': isSet,
};

class _Server {
  final requests = <http.Request>[];
  String active = 'honcho';
  String configProvider = 'honcho';
  bool configRoute = true;
  bool schemaOptions = true;
  bool legacyProviderPayload = false;
  int providerConfigStatus = 200;
  int providerSaveStatus = 200;
  bool oauth = false;
  String oauthState = 'idle';
  bool oauthConnected = false;
  String? oauthAuth;
  bool builtinUser = true;

  List<Map<String, Object?>> fields = [
    _field('mode', 'select', options: ['cloud', 'local_external'], value: 'cloud'),
    _field('api_key', 'secret', label: 'API key'),
    _field('api_url', 'text', value: 'https://api.example.test'),
    _field('mirror_to_own_bank', 'bool', value: false),
    _field('recall_budget', 'select', options: ['low', 'mid', 'high'], value: 'mid'),
  ];

  List<http.Request> where(String method, String path) => requests
      .where((r) => r.method == method && r.url.path == path)
      .toList();

  Map<String, Object?> get _status => {
    'active': active,
    'providers': [
      {
        'name': 'honcho',
        'description': 'Hosted memory',
        'available': true,
        'configured': true,
        'status': 'ready',
      },
      {
        'name': 'hindsight',
        'description': 'Long-term memory',
        'available': true,
        'configured': false,
        'status': 'needs_config',
      },
    ],
    'builtin_files': {'memory': 2048, 'user': 0},
  };

  DashboardClient get client => DashboardClient(
    host: 'hermes.local',
    port: 9119,
    manualToken: 'dashboard-token',
    httpClientOverride: MockClient((request) async {
      requests.add(
        http.Request(request.method, request.url)..body = request.body,
      );
      final path = request.url.path;
      http.Response json(Object body, [int status = 200]) =>
          http.Response(jsonEncode(body), status);
      if (path == '/api/memory') return json(_status);
      if (path == '/api/config/schema') {
        return json({
          'fields': {
            'memory.provider': {
              'type': 'select',
              if (schemaOptions) 'options': ['honcho', 'hindsight'],
            },
          },
        });
      }
      if (path == '/api/config') {
        if (!configRoute) return json({'detail': 'Not Found'}, 404);
        if (request.method == 'PUT') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final memory = (body['config'] as Map)['memory'] as Map;
          configProvider = memory['provider'] as String;
          active = configProvider;
          return json({'ok': true});
        }
        return json({
          'memory': {
            'provider': configProvider,
            'memory_enabled': true,
            'user_profile_enabled': builtinUser,
          },
          'model': {'default': 'not read by this screen'},
        });
      }
      final provider = RegExp(
        r'^/api/memory/providers/([^/]+)/(config|oauth/status|oauth/start)$',
      ).firstMatch(path);
      if (provider != null) {
        final name = provider.group(1)!;
        switch (provider.group(2)) {
          case 'config' when request.method == 'GET':
            if (providerConfigStatus != 200) {
              return json({'detail': 'nope'}, providerConfigStatus);
            }
            if (legacyProviderPayload) {
              return json({
                'name': name,
                'label': name,
                'fields': [
                  {'key': 'api_key', 'label': 'API key', 'secret': true},
                ],
                'setup': {'commands': <String>[]},
              });
            }
            return json({
              'name': name,
              'label': name == 'hindsight' ? 'Hindsight' : name,
              'docs_url': 'https://docs.example.test/$name',
              'fields': name == 'hindsight' ? fields : <Object>[],
            });
          case 'config':
            if (providerSaveStatus != 200) {
              return json({
                'detail': "Invalid value for 'recall_budget'",
              }, providerSaveStatus);
            }
            return json({'ok': true});
          case 'oauth/status':
            if (!oauth) return json({'detail': 'no oauth'}, 404);
            return json({
              'state': oauthState,
              'detail': '',
              'connected': oauthConnected,
              'auth': oauthAuth,
            });
          case 'oauth/start':
            oauthState = 'pending';
            return json({'state': 'pending', 'connected': false});
        }
      }
      return json({}, 404);
    }),
  );
}

Future<void> _pump(
  WidgetTester tester,
  _Server server, {
  bool readOnly = false,
  String? profile,
}) async {
  tester.view.physicalSize = const Size(412, 3200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.hermesRedDark,
      home: MemoryScreen(
        connection: fakeConnection(readOnly: readOnly),
        profileOverride: profile,
        dashboardClientForTesting: server.client,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _in(Key key, Finder what) =>
    find.descendant(of: find.byKey(key), matching: what);

Future<void> _choose(WidgetTester tester, String provider) async {
  await tester.tap(find.byKey(const ValueKey('memory-provider-select')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey('memory-provider-option-$provider')));
  // The menu closes; the save is still waiting for its delay.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _blur(WidgetTester tester) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('the declared settings of a provider', () {
    test('are read as the plugin wrote them; a secret never has a value', () {
      final config = MemoryProviderConfig.tryParse({
        'name': 'hindsight',
        'label': 'Hindsight',
        'docs_url': '',
        'fields': [
          _field('api_key', 'secret', value: 'never-sent-but-if-it-were'),
          _field('mirror', 'bool', value: true),
          _field('budget', 'number', value: 3),
          _field('tags', 'json', value: ['a', 'b'], inline: false, group: 'Recall'),
          _field('extra', 'something new', inline: false),
        ],
      })!;
      expect(config.fields.map((f) => f.kind), [
        MemoryProviderFieldKind.secret,
        MemoryProviderFieldKind.bool,
        MemoryProviderFieldKind.number,
        MemoryProviderFieldKind.json,
        MemoryProviderFieldKind.text,
      ]);
      expect(config.fields.map((f) => f.value), ['', 'true', '3', '["a","b"]', '']);
      expect(config.inlineFields, hasLength(3));
      expect(config.hasFullConfig, isTrue);
      expect(config.grouped('Other').map((g) => g.$1), ['Other', 'Recall']);
    });

    test('an older payload is not taken for them', () {
      expect(
        MemoryProviderConfig.tryParse({
          'name': 'hindsight',
          'label': 'hindsight',
          'fields': <Object>[],
          'setup': <String, Object>{},
        }),
        isNull,
        reason: 'it carries `setup` and no `docs_url`',
      );
      expect(
        MemoryProviderConfig.tryParse({
          'name': 'x',
          'label': 'x',
          'docs_url': '',
          'fields': [
            {'key': 'api_key', 'label': 'API key', 'secret': true},
          ],
        }),
        isNull,
        reason: 'a field without `inline`',
      );
    });

    test('built-in names are not an external provider', () {
      for (final name in ['', 'default', 'builtin', 'Built-In', ' none ']) {
        expect(isExternalMemoryProvider(name), isFalse, reason: name);
      }
      expect(isExternalMemoryProvider('hindsight'), isTrue);
      expect(isExternalMemoryProvider(null), isFalse);
    });
  });

  testWidgets('the active provider, its readiness and the built-in layer; '
      'no selected row while the choice is the saved one', (tester) async {
    final server = _Server()..builtinUser = false;
    await _pump(tester, server);
    final strings = Strings.of(tester.element(find.byType(MemoryScreen)));

    const active = ValueKey('memory-active-provider');
    expect(_in(active, find.text('honcho')), findsOneWidget);
    expect(_in(active, find.text(strings.mempStatusReady)), findsOneWidget);
    expect(
      _in(active, find.text(strings.mempProviderDesc('honcho'))),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('memory-selected-provider')), findsNothing);
    expect(
      _in(
        const ValueKey('memory-builtin-layer'),
        find.text(strings.mempOnlyFile('MEMORY.md')),
      ),
      findsOneWidget,
    );
    // Only `memory.*` was asked of the config, unnamed: no profile picked.
    expect(server.where('GET', '/api/config').single.url.query, isEmpty);
  });

  testWidgets('choosing another provider shows it as selected, not active, '
      'and saves it by itself after the delay', (tester) async {
    final server = _Server();
    await _pump(tester, server);
    final strings = Strings.of(tester.element(find.byType(MemoryScreen)));

    await _choose(tester, 'hindsight');
    const selected = ValueKey('memory-selected-provider');
    expect(_in(selected, find.text('hindsight')), findsOneWidget);
    expect(
      _in(selected, find.text(strings.mempStatusNeedsSetup)),
      findsOneWidget,
    );
    expect(
      _in(selected, find.text(strings.mempSelectedDesc('honcho'))),
      findsOneWidget,
      reason: 'sessions keep using the saved one until this is saved',
    );
    expect(
      _in(const ValueKey('memory-active-provider'), find.text('honcho')),
      findsOneWidget,
    );
    expect(server.where('PUT', '/api/config'), isEmpty, reason: 'not yet');

    await tester.pump(kMemoryProviderSaveDelay);
    await tester.pumpAndSettle();
    final put = server.where('PUT', '/api/config').single;
    expect(jsonDecode(put.body), {
      'config': {
        'memory': {'provider': 'hindsight'},
      },
    });
    // The status was read again: the choice is now the active one.
    expect(find.byKey(selected), findsNothing);
    expect(
      _in(const ValueKey('memory-active-provider'), find.text('hindsight')),
      findsOneWidget,
    );
    expect(
      _in(
        const ValueKey('memory-active-provider'),
        find.text(strings.mempProviderNotReadyDesc('hindsight')),
      ),
      findsOneWidget,
    );
  });

  testWidgets('«Built-in only» is a choice; leaving before the delay saves '
      'nothing', (tester) async {
    final server = _Server();
    await _pump(tester, server);
    final strings = Strings.of(tester.element(find.byType(MemoryScreen)));
    await _choose(tester, '');
    const selected = ValueKey('memory-selected-provider');
    expect(_in(selected, find.text(strings.mempNoProvider)), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
    expect(server.where('PUT', '/api/config'), isEmpty);
  });

  testWidgets('the form is the fields the provider declares, each saved '
      'alone when committed', (tester) async {
    final server = _Server()
      ..active = 'hindsight'
      ..configProvider = 'hindsight';
    await _pump(tester, server);
    final strings = Strings.of(tester.element(find.byType(MemoryScreen)));

    final read = server
        .where('GET', '/api/memory/providers/hindsight/config')
        .single;
    expect(read.url.queryParameters, {'surface': 'declared'});
    expect(find.text(strings.mempSettingsTitle('Hindsight')), findsOneWidget);
    for (final key in [
      'mode',
      'api_key',
      'api_url',
      'mirror_to_own_bank',
      'recall_budget',
    ]) {
      expect(find.byKey(ValueKey('memory-field-$key')), findsOneWidget);
    }
    expect(find.text(strings.mempSecretNotSet('API key')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('memory-full-config')),
      findsNothing,
      reason: 'every declared field is inline',
    );
    const save = '/api/memory/providers/hindsight/config';

    // A switch commits when it changes.
    await tester.tap(
      find.byKey(const ValueKey('memory-field-mirror_to_own_bank-switch')),
    );
    await tester.pumpAndSettle();
    expect(jsonDecode(server.where('PUT', save).last.body), {
      'values': {'mirror_to_own_bank': 'true'},
    });

    // A choice commits when it changes.
    await tester.tap(
      find.byKey(const ValueKey('memory-field-recall_budget-select')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('memory-field-recall_budget-option-high')),
    );
    await tester.pumpAndSettle();
    expect(jsonDecode(server.where('PUT', save).last.body), {
      'values': {'recall_budget': 'high'},
    });

    // Text commits when it loses the focus, and only if it changed.
    final url = find.byKey(const ValueKey('memory-field-api_url-input'));
    await tester.tap(url);
    await tester.pump();
    await _blur(tester);
    expect(server.where('PUT', save), hasLength(2), reason: 'unchanged');
    await tester.enterText(url, 'https://hs.example.test');
    await _blur(tester);
    expect(jsonDecode(server.where('PUT', save).last.body), {
      'values': {'api_url': 'https://hs.example.test'},
    });
    expect(server.where('PUT', save).last.url.queryParameters, {
      'surface': 'declared',
    });
  });

  testWidgets('a credential is write-only: hidden while typed, blank keeps '
      'the stored one, and the field empties once saved', (tester) async {
    final server = _Server()
      ..active = 'hindsight'
      ..configProvider = 'hindsight';
    await _pump(tester, server);
    final strings = Strings.of(tester.element(find.byType(MemoryScreen)));
    const save = '/api/memory/providers/hindsight/config';
    final key = find.byKey(const ValueKey('memory-field-api_key-input'));

    final input = tester.widget<TextField>(key);
    expect(input.obscureText, isTrue);
    expect(input.enableSuggestions, isFalse);
    expect(input.autocorrect, isFalse);
    expect(input.enableIMEPersonalizedLearning, isFalse);

    await tester.tap(key);
    await tester.pump();
    await _blur(tester);
    expect(server.where('PUT', save), isEmpty, reason: 'blank is not sent');

    await tester.enterText(key, 'hs-secret-value');
    await _blur(tester);
    expect(jsonDecode(server.where('PUT', save).single.body), {
      'values': {'api_key': 'hs-secret-value'},
    });
    expect(tester.widget<TextField>(key).controller!.text, isEmpty);
    expect(find.text(strings.mempSecretSet('API key')), findsOneWidget);
    expect(find.text(strings.mempSecretKeep), findsOneWidget);
    expect(find.text('hs-secret-value'), findsNothing);
  });

  testWidgets('a refused save says which field, with the server’s reason '
      'but never for a credential', (tester) async {
    final server = _Server()
      ..active = 'hindsight'
      ..configProvider = 'hindsight'
      ..providerSaveStatus = 400;
    await _pump(tester, server);
    final strings = Strings.of(tester.element(find.byType(MemoryScreen)));

    await tester.enterText(
      find.byKey(const ValueKey('memory-field-api_url-input')),
      'not a url',
    );
    await _blur(tester);
    expect(
      find.textContaining(strings.mempSaveFieldFailed('api_url')),
      findsOneWidget,
    );
    expect(find.textContaining("Invalid value for 'recall_budget'"), findsOneWidget);

    await tester.pump(const Duration(seconds: 8));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('memory-field-api_key-input')),
      'hs-secret-value',
    );
    await _blur(tester);
    expect(
      find.text(strings.mempSaveFieldFailed('API key')),
      findsOneWidget,
      reason: 'the bare message',
    );
    // Only the field the user typed in holds it: no notice repeats it.
    expect(
      find.byWidgetPredicate(
        (w) => w is Text && (w.data ?? '').contains('hs-secret-value'),
      ),
      findsNothing,
    );
  });

  testWidgets('«Full config…» exists only with a field that is not inline, '
      'groups them, and sends only what was edited', (tester) async {
    final server = _Server()
      ..active = 'hindsight'
      ..configProvider = 'hindsight'
      ..fields = [
        _field('api_url', 'text', value: 'https://api.example.test', group: 'Connection'),
        _field('api_key', 'secret', label: 'API key', isSet: true, group: 'Connection'),
        _field('bank_id_template', 'text', inline: false, group: 'Banks'),
        _field('retain_tags', 'json', inline: false, value: ['x']),
      ];
    await _pump(tester, server, profile: 'ana');
    final strings = Strings.of(tester.element(find.byType(MemoryScreen)));

    expect(
      find.byKey(const ValueKey('memory-field-bank_id_template')),
      findsNothing,
      reason: 'not inline: only in the full configuration',
    );
    await tester.tap(find.byKey(const ValueKey('memory-full-config')));
    await tester.pumpAndSettle();
    expect(find.text(strings.mempFullTitle('Hindsight')), findsOneWidget);
    expect(find.text(strings.mempFullDesc('Hindsight', 'ana')), findsOneWidget);
    expect(find.text(strings.mempDocsLink('Hindsight')), findsOneWidget);
    for (final group in ['CONNECTION', 'BANKS', strings.mempGroupOther.toUpperCase()]) {
      expect(find.text(group), findsOneWidget);
    }
    expect(find.text('["x"]'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('memory-field-bank_id_template-input')),
      'user-{profile}',
    );
    await _blur(tester);
    const save = '/api/memory/providers/hindsight/config';
    expect(server.where('PUT', save), isEmpty, reason: 'waits for Save');

    await tester.tap(find.byKey(const ValueKey('memory-full-save')));
    await tester.pumpAndSettle();
    final put = server.where('PUT', save).single;
    expect(jsonDecode(put.body), {
      'values': {'bank_id_template': 'user-{profile}'},
    });
    expect(put.url.queryParameters, {'surface': 'declared', 'profile': 'ana'});
    expect(find.text(strings.mempFullTitle('Hindsight')), findsNothing);
    // The form was read again after the save.
    expect(server.where('GET', save), hasLength(2));
  });

  testWidgets('a named profile is named on every call', (tester) async {
    final server = _Server()
      ..active = 'hindsight'
      ..configProvider = 'hindsight'
      ..oauth = true;
    await _pump(tester, server, profile: 'ana');
    final scoped = server.requests.where(
      (r) =>
          r.url.path == '/api/config' ||
          r.url.path == '/api/config/schema' ||
          r.url.path.startsWith('/api/memory/providers/'),
    );
    expect(scoped, isNotEmpty);
    for (final request in scoped) {
      expect(
        request.url.queryParameters['profile'],
        'ana',
        reason: '${request.method} ${request.url.path}',
      );
    }
  });

  testWidgets('OAuth connect shows only for a provider that has it, polls '
      'until the server says, and says where the consent page opens', (
    tester,
  ) async {
    final without = _Server()
      ..active = 'hindsight'
      ..configProvider = 'hindsight';
    await _pump(tester, without);
    expect(find.byKey(const ValueKey('memory-connect')), findsNothing);

    final server = _Server()
      ..active = 'hindsight'
      ..configProvider = 'hindsight'
      ..oauth = true
      ..oauthConnected = true
      ..oauthAuth = 'apikey';
    await tester.pumpWidget(const SizedBox.shrink());
    await _pump(tester, server);
    final strings = Strings.of(tester.element(find.byType(MemoryScreen)));
    expect(find.text(strings.mempApiKeySet), findsOneWidget);
    expect(find.text(strings.mempConnectOAuth), findsOneWidget);

    const status = '/api/memory/providers/hindsight/oauth/status';
    final before = server.where('GET', status).length;
    await tester.tap(find.byKey(const ValueKey('memory-connect-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      server.where('POST', '/api/memory/providers/hindsight/oauth/start'),
      hasLength(1),
    );
    expect(find.text(strings.mempWaitingConsent), findsOneWidget);
    expect(find.text(strings.mempConsentWhere), findsOneWidget);

    await tester.pump(kMemoryOAuthPoll);
    await tester.pump(const Duration(milliseconds: 50));
    expect(server.where('GET', status).length, before + 1);
    expect(find.text(strings.mempWaitingConsent), findsOneWidget);

    server
      ..oauthState = 'connected'
      ..oauthAuth = 'oauth';
    final reads = server.where('GET', '/api/memory').length;
    await tester.pump(kMemoryOAuthPoll);
    await tester.pumpAndSettle();
    expect(find.text(strings.mempWaitingConsent), findsNothing);
    expect(find.text(strings.mempOAuthSet), findsOneWidget);
    expect(find.text(strings.mempReconnect), findsOneWidget);
    expect(
      server.where('GET', '/api/memory').length,
      reads + 1,
      reason: 'the status is read again once connected',
    );
    // No poll is left running.
    final settled = server.where('GET', status).length;
    await tester.pump(kMemoryOAuthPoll * 3);
    expect(server.where('GET', status).length, settled);
  });

  testWidgets('Cancel stops waiting; a wait that never ends times out', (
    tester,
  ) async {
    final server = _Server()
      ..active = 'hindsight'
      ..configProvider = 'hindsight'
      ..oauth = true;
    await _pump(tester, server);
    final strings = Strings.of(tester.element(find.byType(MemoryScreen)));
    const status = '/api/memory/providers/hindsight/oauth/status';

    await tester.tap(find.byKey(const ValueKey('memory-connect-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const ValueKey('memory-connect-cancel')));
    await tester.pump();
    final polls = server.where('GET', status).length;
    await tester.pump(kMemoryOAuthPoll * 3);
    expect(server.where('GET', status).length, polls);
    expect(find.text(strings.mempConnect), findsOneWidget);
  });

  group('an older Hermes', () {
    testWidgets('without the config route: the status still shows and the '
        'choice is said to be unavailable', (tester) async {
      final server = _Server()..configRoute = false;
      await _pump(tester, server);
      final strings = Strings.of(tester.element(find.byType(MemoryScreen)));
      expect(
        _in(const ValueKey('memory-active-provider'), find.text('honcho')),
        findsOneWidget,
      );
      expect(find.text(strings.mempSelectUnsupported), findsOneWidget);
      expect(find.byKey(const ValueKey('memory-provider-select')), findsNothing);
      expect(
        _in(
          const ValueKey('memory-builtin-layer'),
          find.text(strings.mempOnByDefault),
        ),
        findsOneWidget,
      );
    });

    testWidgets('that answers the older provider payload: no form, a clear '
        'message, and nothing is ever written', (tester) async {
      final server = _Server()
        ..active = 'hindsight'
        ..configProvider = 'hindsight'
        ..legacyProviderPayload = true;
      await _pump(tester, server);
      final strings = Strings.of(tester.element(find.byType(MemoryScreen)));
      expect(find.text(strings.mempUnsupported), findsOneWidget);
      expect(find.byKey(const ValueKey('memory-config-panel')), findsNothing);
      expect(server.requests.where((r) => r.method == 'PUT'), isEmpty);
    });

    testWidgets('without the provider config route: the same message', (
      tester,
    ) async {
      final server = _Server()
        ..active = 'hindsight'
        ..configProvider = 'hindsight'
        ..providerConfigStatus = 404;
      await _pump(tester, server);
      final strings = Strings.of(tester.element(find.byType(MemoryScreen)));
      expect(find.text(strings.mempUnsupported), findsOneWidget);
    });

    testWidgets('whose schema lists no providers: the ones the status names '
        'are offered', (tester) async {
      final server = _Server()..schemaOptions = false;
      await _pump(tester, server);
      await tester.tap(find.byKey(const ValueKey('memory-provider-select')));
      await tester.pumpAndSettle();
      for (final option in ['', 'honcho', 'hindsight']) {
        expect(
          find.byKey(ValueKey('memory-provider-option-$option')),
          findsOneWidget,
        );
      }
    });
  });

  testWidgets('a provider that fails to load its settings can be retried', (
    tester,
  ) async {
    final server = _Server()
      ..active = 'hindsight'
      ..configProvider = 'hindsight'
      ..providerConfigStatus = 503;
    await _pump(tester, server);
    expect(find.byKey(const ValueKey('memory-config-failed')), findsOneWidget);
    server.providerConfigStatus = 200;
    final strings = Strings.of(tester.element(find.byType(MemoryScreen)));
    await tester.tap(find.text(strings.commonRetry));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('memory-config-panel')), findsOneWidget);
  });

  testWidgets('a read-only connection can look, not change', (tester) async {
    final server = _Server()
      ..active = 'hindsight'
      ..configProvider = 'hindsight';
    await _pump(tester, server, readOnly: true);
    await tester.tap(find.byKey(const ValueKey('memory-provider-select')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('memory-provider-option-honcho')),
      findsNothing,
    );
    final key = tester.widget<TextField>(
      find.byKey(const ValueKey('memory-field-api_key-input')),
    );
    expect(key.enabled, isFalse);
    expect(server.requests.where((r) => r.method == 'PUT'), isEmpty);
  });

  test('the server’s reason is read from its answer, bounded', () {
    expect(
      memoryServerDetail(
        const DashboardHttpException(400, body: '{"detail":"Invalid value"}'),
      ),
      'Invalid value',
    );
    expect(memoryServerDetail(const DashboardHttpException(500)), isNull);
    expect(memoryServerDetail(StateError('x')), isNull);
    expect(memoryRouteMissing(const DashboardHttpException(405)), isTrue);
    expect(memoryRouteMissing(const DashboardHttpException(500)), isFalse);
  });
}
