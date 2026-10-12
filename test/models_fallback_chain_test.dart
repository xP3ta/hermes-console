// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hermes Console contributors
//
// The fallback chain of a profile (`fallback_providers`) is edited like
// Desktop's `fallback-models-field.tsx`: one row per entry, each added,
// changed or removed on its own, written as `{provider, model}` while every
// other key of an entry rides along. Whatever is on screen after a change is
// what the server returned, never what was picked.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/models_screen.dart';
import 'package:hermes_android/core/services/active_profile_scope.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/models_snapshot.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/console_loader.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _connectionId = 'fallback-fixture';

/// A hand-written local-gateway entry: the editor owns provider/model only.
const _routed = <String, dynamic>{
  'provider': 'fixture',
  'model': 'backup',
  'base_url': 'https://gateway.example.test/v1',
  'api_key': 'synthetic-gateway-key',
  'api_mode': 'chat_completions',
};
const _survivor = <String, dynamic>{
  'provider': 'survivor',
  'model': 'keep',
  'base_url': 'https://survivor.example.test/v1',
  'key_env': 'SYNTHETIC_SURVIVOR_KEY',
  'routing': {
    'nested': {
      'weights': [1, 2],
    },
  },
};

class _Server {
  _Server(List<Object?> chain) : config = {'fallback_providers': chain};

  /// One config file per profile, like Hermes.
  final Map<String, dynamic> config;
  final Map<String, Map<String, dynamic>> others = {};
  final puts = <({String? profile, Map<String, dynamic> body})>[];
  final configProfiles = <String?>[];

  /// Answers `ok` without storing anything (a managed install does this).
  bool ignoreWrites = false;

  /// What a PUT answers; anything but 200 + `ok` stores nothing.
  int putStatus = 200;
  bool putOk = true;

  /// Raw body of every config read, when it is not the config itself.
  String? configBody;
  Completer<void>? configGate;
  Completer<void>? optionsGate;

  Map<String, dynamic> _configOf(String? profile) =>
      profile == 'ana' ? config : others.putIfAbsent(profile ?? '', () => {});

  DashboardClient client() => DashboardClient(
    host: '127.0.0.1',
    manualToken: 'synthetic-fixture-token',
    httpClientOverride: MockClient((request) async {
      final profile = request.url.queryParameters['profile'];
      switch (request.url.path) {
        case '/api/model/info':
          return http.Response('{"model":"main","provider":"fixture"}', 200);
        case '/api/model/options':
          await optionsGate?.future;
          return http.Response(
            jsonEncode({
              'providers': [
                {
                  'slug': 'fixture',
                  'name': 'Fixture',
                  'authenticated': true,
                  // Nothing of a catalog row is a route of a fallback entry.
                  'key_env': 'SYNTHETIC_FIXTURE_KEY',
                  'api_url': 'https://fixture.example.test/v1',
                  'has_api_key': true,
                  'models': ['main', 'backup', 'next'],
                },
                {
                  'slug': 'other',
                  'name': 'Other',
                  'authenticated': true,
                  'models': ['next'],
                },
              ],
            }),
            200,
          );
        case '/api/model/auxiliary':
          return http.Response('{"tasks":[]}', 200);
        case '/api/providers/oauth':
          return http.Response('{"providers":[]}', 200);
        case '/api/providers/custom-endpoints':
          return http.Response('{"endpoints":[]}', 200);
        case '/api/env':
          return http.Response('{}', 200);
        case '/api/config':
          configProfiles.add(profile);
          if (request.method == 'GET') {
            await configGate?.future;
            return http.Response(
              configBody ?? jsonEncode(_configOf(profile)),
              200,
            );
          }
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          puts.add((profile: profile, body: body));
          if (putStatus != 200) return http.Response('{}', putStatus);
          if (!putOk) return http.Response('{"ok":false}', 200);
          if (!ignoreWrites) {
            _configOf(
              profile,
            ).addAll((body['config'] as Map).cast<String, dynamic>());
          }
          return http.Response('{"ok":true}', 200);
      }
      return http.Response('{}', 404);
    }),
  );
}

void main() {
  late ConnectionManager manager;
  late ActiveProfileScope scope;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => call.method == 'readAll' ? <String, String>{} : null,
        );
    manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    await manager.setActiveProfile(_connectionId, 'ana');
    scope = ActiveProfileScope.of(manager, _connectionId);
  });

  Future<void> open(
    WidgetTester tester,
    _Server server, {
    bool readOnly = false,
    ModelsSnapshotCache? cache,
  }) async {
    tester.view.physicalSize = const Size(412, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        theme: AppTheme.hermesRedDark,
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: ModelsScreen(
          key: UniqueKey(),
          connection: SavedConnection(
            id: _connectionId,
            label: 'Fixture',
            host: '127.0.0.1',
            port: 8642,
            apiKey: 'synthetic-connection-token',
            readOnly: readOnly,
          ),
          dashboardClientForTesting: server.client(),
          profileScope: scope,
          gatewayCatalogForTesting: () => null,
          snapshotCache: cache,
        ),
      ),
    );
  }

  Finder row(int index) => find.byKey(ValueKey('models-fallback-row-$index'));
  Finder inRow(int index, String text) =>
      find.descendant(of: row(index), matching: find.text(text));
  Finder remove(int index) =>
      find.byKey(ValueKey('models-fallback-remove-$index'));
  final add = find.byKey(const ValueKey('models-fallback-add'));
  final problem = find.byKey(const ValueKey('models-fallback-error'));
  Finder option(String provider, String model) =>
      find.byKey(ValueKey('models-picker-$provider-$model'));
  Finder dialogAction(String label) => find.descendant(
    of: find.byKey(const ValueKey('hermes-dialog')),
    matching: find.text(label),
  );

  Future<void> tap(WidgetTester tester, Finder target) async {
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  List<dynamic> written(_Server server) =>
      (server.puts.single.body['config'] as Map)['fallback_providers'] as List;

  testWidgets('every entry of the chain is a row, in order', (tester) async {
    final server = _Server([_routed, _survivor]);
    await open(tester, server);
    await tester.pumpAndSettle();
    expect(inRow(0, 'backup'), findsOneWidget);
    expect(inRow(0, 'Fixture'), findsOneWidget);
    expect(inRow(1, 'keep'), findsOneWidget);
    expect(row(2), findsNothing);
    expect(add, findsOneWidget);
    expect(server.puts, isEmpty);
  });

  testWidgets('a row pointed at another provider is written as '
      '{provider, model}; the other rows keep their routing', (tester) async {
    final server = _Server([_routed, _survivor]);
    await open(tester, server);
    await tester.pumpAndSettle();
    await tap(tester, row(0));
    await tap(tester, option('other', 'next'));

    // Desktop's shape: only the list, and nothing of the catalog row or of
    // the previous provider's route in the new entry.
    expect(server.puts.single.body, {
      'config': {
        'fallback_providers': [
          {'provider': 'other', 'model': 'next'},
          _survivor,
        ],
      },
    });
    expect(inRow(0, 'next'), findsOneWidget);
    expect(inRow(0, 'Other'), findsOneWidget);
    expect(inRow(1, 'keep'), findsOneWidget);
    expect(problem, findsNothing);
  });

  testWidgets('another model of the same provider keeps the hand-written '
      'route of the row', (tester) async {
    final server = _Server([_routed, _survivor]);
    await open(tester, server);
    await tester.pumpAndSettle();
    await tap(tester, row(0));
    await tap(tester, option('fixture', 'next'));
    expect(written(server), [
      {..._routed, 'model': 'next'},
      _survivor,
    ]);
  });

  testWidgets('Add fallback appends a last resort', (tester) async {
    final server = _Server([_routed]);
    await open(tester, server);
    await tester.pumpAndSettle();
    await tap(tester, add);
    await tap(tester, option('other', 'next'));
    expect(written(server), [
      _routed,
      {'provider': 'other', 'model': 'next'},
    ]);
    expect(inRow(1, 'next'), findsOneWidget);
  });

  testWidgets('removing a row asks once and keeps the others', (tester) async {
    final server = _Server([_routed, _survivor]);
    await open(tester, server);
    await tester.pumpAndSettle();

    await tap(tester, remove(0));
    expect(server.puts, isEmpty, reason: 'nothing is removed unasked');
    await tap(tester, dialogAction('Cancel'));
    expect(server.puts, isEmpty);
    expect(inRow(0, 'backup'), findsOneWidget);

    await tap(tester, remove(0));
    await tap(tester, dialogAction('Remove'));
    expect(written(server), [_survivor]);
    expect(inRow(0, 'keep'), findsOneWidget);
    expect(row(1), findsNothing);
  });

  testWidgets('removing the only row leaves an empty list on the server', (
    tester,
  ) async {
    final server = _Server([_routed]);
    await open(tester, server);
    await tester.pumpAndSettle();
    await tap(tester, remove(0));
    await tap(tester, dialogAction('Remove'));
    expect(written(server), isEmpty);
    expect(row(0), findsNothing);
    expect(add, findsOneWidget);
  });

  testWidgets('a change the server did not keep is shown as not saved, with '
      'the list the server holds', (tester) async {
    final server = _Server([_routed])..ignoreWrites = true;
    await open(tester, server);
    await tester.pumpAndSettle();
    await tap(tester, add);
    await tap(tester, option('other', 'next'));

    expect(server.puts, hasLength(1));
    expect(row(1), findsNothing, reason: 'the server holds one entry');
    expect(inRow(0, 'backup'), findsOneWidget);
    expect(problem, findsOneWidget);
  });

  for (final failure in ['ok false', '401', '404', '500']) {
    testWidgets('a write the server refused ($failure) is never shown as '
        'saved', (tester) async {
      final server = _Server([_routed]);
      if (failure == 'ok false') {
        server.putOk = false;
      } else {
        server.putStatus = int.parse(failure);
      }
      await open(tester, server);
      await tester.pumpAndSettle();
      await tap(tester, add);
      await tap(tester, option('other', 'next'));

      // A 401 is resent once after signing in again; nothing else repeats.
      expect(server.puts, hasLength(failure == '401' ? 2 : 1));
      expect(server.config['fallback_providers'], [_routed]);
      expect(inRow(0, 'backup'), findsOneWidget);
      expect(row(1), findsNothing);
      expect(problem, findsOneWidget);
    });
  }

  testWidgets('a legacy fallback_model is neither listed nor rewritten', (
    tester,
  ) async {
    // Desktop edits `fallback_providers` only. Sending `fallback_model: null`
    // never cleared a legacy entry on the server (its merge ignores a null
    // over a section) and made every later save look unconfirmed.
    final server = _Server([_routed]);
    server.config['fallback_model'] = {'provider': 'legacy', 'model': 'old'};
    await open(tester, server);
    await tester.pumpAndSettle();
    expect(find.text('old'), findsNothing);
    await tap(tester, add);
    await tap(tester, option('other', 'next'));
    expect((server.puts.single.body['config'] as Map).keys, [
      'fallback_providers',
    ]);
    expect(server.config['fallback_model'], {
      'provider': 'legacy',
      'model': 'old',
    });
    expect(inRow(1, 'next'), findsOneWidget);
    expect(problem, findsNothing);
  });

  testWidgets('an answer that is not a configuration is a failed read, not '
      '"no fallbacks"', (tester) async {
    final server = _Server([_routed])..configBody = '[]';
    await open(tester, server);
    await tester.pumpAndSettle();
    expect(add, findsNothing);
    expect(problem, findsOneWidget);
  });

  testWidgets('a list changed on the server meanwhile is shown, not '
      'overwritten', (tester) async {
    final server = _Server([_routed]);
    await open(tester, server);
    await tester.pumpAndSettle();
    // Another client edits the chain while this screen is open.
    server.config['fallback_providers'] = [_survivor, _routed];
    await tap(tester, add);
    await tap(tester, option('other', 'next'));

    expect(server.puts, isEmpty);
    expect(inRow(0, 'keep'), findsOneWidget);
    expect(inRow(1, 'backup'), findsOneWidget);
    expect(problem, findsOneWidget);
  });

  testWidgets('a read-only connection changes nothing', (tester) async {
    final server = _Server([_routed, _survivor]);
    await open(tester, server, readOnly: true);
    await tester.pumpAndSettle();
    await tap(tester, add);
    expect(find.byKey(const ValueKey('models-picker-surface')), findsNothing);
    await tap(tester, remove(0));
    expect(find.byKey(const ValueKey('hermes-dialog')), findsNothing);
    expect(server.puts, isEmpty);
    expect(inRow(1, 'keep'), findsOneWidget);
  });

  testWidgets('reads and the write stay on the profile on screen', (
    tester,
  ) async {
    final server = _Server([_routed]);
    await open(tester, server);
    await tester.pumpAndSettle();
    await tap(tester, add);
    await tap(tester, option('other', 'next'));
    expect(server.puts.single.profile, 'ana');
    expect(server.configProfiles, everyElement('ana'));
    expect(server.others, isEmpty);
  });

  testWidgets('a profile switch while the picker is open voids the change', (
    tester,
  ) async {
    final server = _Server([_routed]);
    await open(tester, server);
    await tester.pumpAndSettle();
    await tap(tester, add);
    await scope.switchTo('bert');
    await tester.pumpAndSettle();
    await tap(tester, option('other', 'next'));
    await scope.switchTo('ana');
    await tester.pumpAndSettle();

    expect(server.puts, isEmpty);
    expect(server.config['fallback_providers'], [_routed]);
    expect(inRow(0, 'backup'), findsOneWidget);
    expect(row(1), findsNothing);
  });

  testWidgets('a legacy "provider/model" entry is a row, not a hidden '
      'section', (tester) async {
    final server = _Server(['fixture/backup', _survivor]);
    await open(tester, server);
    await tester.pumpAndSettle();
    expect(inRow(0, 'backup'), findsOneWidget);
    expect(inRow(1, 'keep'), findsOneWidget);
    expect(problem, findsNothing);
  });

  testWidgets('reopening paints the chain at once, before the server '
      'answers', (tester) async {
    final server = _Server([_routed, _survivor]);
    final cache = ModelsSnapshotCache();
    await open(tester, server, cache: cache);
    await tester.pumpAndSettle();
    expect(inRow(1, 'keep'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());

    server
      ..configGate = Completer<void>()
      ..optionsGate = Completer<void>();
    await open(tester, server, cache: cache);
    await tester.pump();
    await tester.pump();
    expect(find.byType(ConsoleLoader), findsNothing);
    expect(inRow(0, 'backup'), findsOneWidget);
    expect(inRow(1, 'keep'), findsOneWidget);

    server.configGate!.complete();
    server.optionsGate!.complete();
    await tester.pumpAndSettle();
    expect(inRow(1, 'keep'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
