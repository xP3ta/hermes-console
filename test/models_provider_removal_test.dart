// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hermes Console contributors
//
// "Remove" of a connected provider. One action takes it out of every model
// list: its key, its account or the endpoint the user wrote is cleared, and a
// provider that is still connected because its credential belongs to another
// program on the server is left out of the profile's catalog
// (`model_catalog.excluded_providers`, which Desktop, the TUI and the CLI
// honour too). Nobody has to hide a provider to finish the job, and what was
// taken out is offered back with the providers that are not connected.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_model_catalog.dart';
import 'package:hermes_android/core/models/model_active_info.dart';
import 'package:hermes_android/core/models/model_provider.dart';
import 'package:hermes_android/core/models/oauth_account.dart';
import 'package:hermes_android/core/services/active_profile_scope.dart';
import 'package:hermes_android/core/services/model_catalog_cache.dart';
import 'package:hermes_android/core/services/model_picker_loader.dart';
import 'package:hermes_android/core/services/models_snapshot.dart';
import 'package:hermes_android/core/widgets/console_loader.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/models_server.dart';

Map<String, dynamic> _row(
  String slug,
  String name,
  List<String> models, [
  Map<String, dynamic> more = const {},
]) => {
  'slug': slug,
  'name': name,
  'authenticated': true,
  'is_user_defined': false,
  'source': 'built-in',
  'models': models,
  ...more,
};

/// Acme runs the profile; Kimi is connected by its key and unused.
ModelsServer _server() => ModelsServer()
  ..catalog = [
    _row('acme', 'Acme', ['acme-large', 'acme-small']),
    _row('kimi', 'Kimi', ['kimi-k2', 'kimi-k1']),
  ]
  ..aux = [
    {'task': 'vision', 'provider': 'auto', 'model': ''},
  ]
  ..keys = {'ACME_API_KEY': true, 'KIMI_API_KEY': true, 'ZETA_API_KEY': false}
  ..keyAliases = {'KIMI_CODING_API_KEY': 'KIMI_API_KEY'}
  ..credentials = {
    'kimi': ['KIMI_API_KEY', 'KIMI_CODING_API_KEY'],
  };

/// GitHub Copilot is connected by the GitHub login of the server, Anthropic
/// by the Claude Code login: nothing of theirs is Hermes' to clear.
ModelsServer _external() => _server()
  ..catalog.addAll([
    _row('copilot', 'GitHub Copilot', ['gpt-x']),
    _row('anthropic', 'Anthropic', ['claude-next']),
  ])
  ..accounts = [
    {
      'id': 'claude-code',
      'name': 'Claude Code',
      'flow': 'external',
      'disconnectable': false,
      'disconnect_command': 'rm -f ~/.claude/.credentials.json',
      'status': {'logged_in': true},
    },
    {
      'id': 'copilot-acp',
      'name': 'GitHub Copilot ACP',
      'flow': 'external',
      'disconnectable': false,
      'status': {'logged_in': false},
    },
  ]
  ..config = {
    'fallback_providers': <Object>[],
    'agent': {'reasoning_effort': 'medium', 'service_tier': 'normal'},
    'model_catalog': {
      'enabled': true,
      'excluded_providers': ['Legacy'],
    },
  };

void main() {
  late ActiveProfileScope scope;
  setUp(() async => scope = await modelsScope());

  Finder tile(String slug) => modelsKey('models-provider-$slug');
  Finder remove(String slug) => modelsKey('models-provider-remove-$slug');
  Finder restore(String slug) => modelsKey('models-restore-$slug');
  Finder option(String provider, String model) =>
      modelsKey('models-picker-$provider-$model');

  Future<void> back(WidgetTester tester) async {
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
  }

  Future<void> removeProvider(WidgetTester tester, String slug) async {
    await openProvider(tester, slug);
    await tapOn(tester, remove(slug));
    await tapOn(tester, inDialog('Remove'));
  }

  List<Object?> deletedKeys(ModelsServer server) => [
    for (final request in server.of('DELETE', '/api/env')) request.body!['key'],
  ];

  group('a provider connected by its key', () {
    testWidgets('Remove takes it out of every list at once, and it stays out '
        'on reopen', (tester) async {
      final server = _server();
      final cache = ModelsSnapshotCache();
      // The chat model picker keeps its own copy of the catalog.
      final chat = (picker: ModelPickerCache(), catalog: ModelCatalogCache());
      final chatKey = ModelPickerCache.key(modelsConnectionId, 'ana');
      chat.picker.write(
        chatKey,
        ModelPickerResult(
          info: const ModelActiveInfo(
            model: 'acme-large',
            provider: 'acme',
            effectiveContextLength: 0,
          ),
          providers: [
            for (final row in server.catalog) ModelProvider.fromJson(row),
          ],
          source: ModelPickerSource.socket,
        ),
      );
      chat.catalog.write(
        modelsConnectionId,
        'ana',
        const DesktopModelCatalog(),
      );
      await pumpModels(tester, server, scope, cache: cache, chatCatalogs: chat);
      await tester.pumpAndSettle();
      expect(tile('kimi'), findsOneWidget);

      await openProvider(tester, 'kimi');
      await tapOn(tester, remove('kimi'));
      expect(server.writes, isEmpty, reason: 'nothing is removed unasked');
      await tapOn(tester, inDialog('Remove'));

      final delete = server.of('DELETE', '/api/env').single;
      expect(delete.profile, 'ana');
      expect(delete.body, {'key': 'KIMI_API_KEY', 'profile': 'ana'});
      expect(
        server.of('PUT', '/api/config'),
        isEmpty,
        reason: 'gone with its key: nothing to exclude',
      );

      // The page.
      expect(tile('kimi'), findsNothing);
      expect(tile('acme'), findsOneWidget);
      expect(modelsKey('configured-key-KIMI_API_KEY'), findsNothing);
      // The fallback picker and the pickers of "Models by function".
      await tapOn(tester, modelsKey('models-fallback-add'));
      expect(option('acme', 'acme-large'), findsOneWidget);
      expect(option('kimi', 'kimi-k2'), findsNothing);
      await back(tester);
      await openAux(tester);
      await tapOn(tester, modelsKey('models-aux-vision'));
      expect(option('acme', 'acme-large'), findsOneWidget);
      expect(option('kimi', 'kimi-k2'), findsNothing);
      await back(tester);
      // "Edit models".
      await tapOn(tester, modelsKey('models-edit-models'));
      expect(modelsKey('model-visibility-provider-acme'), findsOneWidget);
      expect(modelsKey('model-visibility-provider-kimi'), findsNothing);
      await back(tester);
      // The chat picker's copy: what it paints, and that it asks again.
      final kept = chat.picker.peek(chatKey)!;
      expect([for (final row in kept.result.providers) row.slug], ['acme']);
      expect(kept.fresh, isFalse);
      expect(chat.catalog.read(modelsConnectionId, 'ana'), isNull);
      // It is not connected now: it can be set up again like any other.
      await openUnconfigured(tester);
      expect(modelsKey('models-key-option-KIMI_API_KEY'), findsOneWidget);
      expect(restore('kimi'), findsNothing);

      // Reopening paints the kept answer before the server says anything.
      await tester.pumpWidget(const SizedBox());
      server.optionsGate = Completer<void>();
      await pumpModels(tester, server, scope, cache: cache, chatCatalogs: chat);
      await tester.pump();
      await tester.pump();
      expect(find.byType(ConsoleLoader), findsNothing);
      expect(tile('acme'), findsOneWidget);
      expect(tile('kimi'), findsNothing);
      server.optionsGate!.complete();
      await tester.pumpAndSettle();
      expect(tile('kimi'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a key kept under the second variable of its card is a key '
        'that is set, and Remove clears it', (tester) async {
      // Kimi's card has `KIMI_API_KEY` and `KIMI_CODING_API_KEY`; either
      // connects it.
      final server = _server()
        ..keys = {
          'ACME_API_KEY': true,
          'KIMI_API_KEY': false,
          'KIMI_CODING_API_KEY': true,
          'ZETA_API_KEY': false,
        };
      await pumpModels(tester, server, scope);
      await tester.pumpAndSettle();
      expect(modelsKey('configured-key-KIMI_API_KEY'), findsOneWidget);
      // Not one of the providers still to set up.
      await openUnconfigured(tester);
      expect(modelsKey('models-key-option-ZETA_API_KEY'), findsOneWidget);
      expect(modelsKey('models-key-option-KIMI_API_KEY'), findsNothing);

      await removeProvider(tester, 'kimi');
      expect(deletedKeys(server), ['KIMI_CODING_API_KEY']);
      expect(tile('kimi'), findsNothing);
      expect(modelsKey('configured-key-KIMI_API_KEY'), findsNothing);
    });

    testWidgets('with both variables set, both are cleared', (tester) async {
      final server = _server()..keys['KIMI_CODING_API_KEY'] = true;
      await pumpModels(tester, server, scope);
      await tester.pumpAndSettle();
      await removeProvider(tester, 'kimi');
      expect(deletedKeys(server), ['KIMI_API_KEY', 'KIMI_CODING_API_KEY']);
      expect(tile('kimi'), findsNothing);
      expect(server.of('PUT', '/api/config'), isEmpty);
    });

    testWidgets('removing the key from the key list clears both too', (
      tester,
    ) async {
      final server = _server()..keys['KIMI_CODING_API_KEY'] = true;
      await pumpModels(tester, server, scope);
      await tester.pumpAndSettle();
      await tapOn(tester, modelsKey('configured-key-KIMI_API_KEY'));
      await tapOn(tester, modelsKey('models-key-remove-KIMI_API_KEY'));
      await tapOn(tester, inDialog('Remove'));
      expect(deletedKeys(server), ['KIMI_API_KEY', 'KIMI_CODING_API_KEY']);
      expect(tile('kimi'), findsNothing);
    });

    testWidgets('still connected once its key is gone: it is left out of the '
        'catalog, in the same action', (tester) async {
      // Something that is not Hermes' to clear keeps it connected.
      final server = _server()..ambient = {'kimi'};
      await pumpModels(tester, server, scope);
      await tester.pumpAndSettle();
      await removeProvider(tester, 'kimi');

      expect(deletedKeys(server), ['KIMI_API_KEY']);
      expect(server.of('PUT', '/api/config').single.body, {
        'config': {
          'model_catalog': {
            'excluded_providers': ['kimi'],
          },
        },
      });
      expect(tile('kimi'), findsNothing);
      await openUnconfigured(tester);
      expect(restore('kimi'), findsOneWidget);
      // One row for it: what puts it back, not its key again.
      expect(modelsKey('models-key-option-KIMI_API_KEY'), findsNothing);
    });

    testWidgets('a provider the server still lists is not said to be removed', (
      tester,
    ) async {
      final server = _server()
        ..ambient = {'kimi'}
        ..ignoreConfigSave = true;
      await pumpModels(tester, server, scope);
      await tester.pumpAndSettle();
      await removeProvider(tester, 'kimi');
      expect(server.of('PUT', '/api/config'), hasLength(1));
      expect(tile('kimi'), findsOneWidget);
      await openUnconfigured(tester);
      expect(restore('kimi'), findsNothing);
    });

    testWidgets('a read-only connection removes nothing', (tester) async {
      final server = _server();
      await pumpModels(tester, server, scope, readOnly: true);
      await tester.pumpAndSettle();
      await openProvider(tester, 'kimi');
      await tapOn(tester, remove('kimi'));
      expect(find.byKey(const ValueKey('hermes-dialog')), findsNothing);
      expect(server.writes, isEmpty);
      expect(tile('kimi'), findsOneWidget);
    });
  });

  group('a provider another program on the server signs in', () {
    testWidgets('Remove leaves it out of the profile\'s catalog and changes '
        'nothing else', (tester) async {
      final server = _external();
      await pumpModels(tester, server, scope);
      await tester.pumpAndSettle();
      await openProvider(tester, 'copilot');
      await tapOn(tester, remove('copilot'));
      expect(server.writes, isEmpty, reason: 'nothing is removed unasked');
      await tapOn(tester, inDialog('Remove'));

      // One write: the list, with what was already on it and this provider.
      final write = server.writes.single;
      expect(write.method, 'PUT');
      expect(write.path, '/api/config');
      expect(write.profile, 'ana');
      expect(write.body, {
        'config': {
          'model_catalog': {
            'excluded_providers': ['Legacy', 'copilot'],
          },
        },
      });
      expect((server.config['model_catalog'] as Map)['enabled'], isTrue);
      expect(server.config['agent'], {
        'reasoning_effort': 'medium',
        'service_tier': 'normal',
      });
      // The list was read first, and the catalog after.
      final paths = [for (final request in server.requests) request.path];
      final put = paths.lastIndexOf('/api/config');
      expect(paths.sublist(0, put), contains('/api/config'));
      expect(paths.sublist(put), contains('/api/model/options'));

      expect(tile('copilot'), findsNothing);
      expect(tile('anthropic'), findsOneWidget);
      await tapOn(tester, modelsKey('models-fallback-add'));
      expect(option('copilot', 'gpt-x'), findsNothing);
      await back(tester);
    });

    testWidgets('it is offered back with the providers that are not '
        'connected, and one tap puts it back', (tester) async {
      final server = _external();
      final cache = ModelsSnapshotCache();
      await pumpModels(tester, server, scope, cache: cache);
      await tester.pumpAndSettle();
      await removeProvider(tester, 'copilot');
      await openUnconfigured(tester);
      expect(
        find.descendant(
          of: modelsKey('models-unconfigured'),
          matching: find.text('GitHub Copilot'),
        ),
        findsOneWidget,
      );
      // An id someone wrote on the server by hand is offered back too.
      expect(restore('Legacy'), findsOneWidget);

      // Reopening paints it there at once, from the kept answer.
      await tester.pumpWidget(const SizedBox());
      server.optionsGate = Completer<void>();
      await pumpModels(tester, server, scope, cache: cache);
      await tester.pump();
      await tester.pump();
      expect(tile('copilot'), findsNothing);
      await tester.tap(modelsKey('models-unconfigured'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(restore('copilot'), findsOneWidget);
      server.optionsGate!.complete();
      await tester.pumpAndSettle();

      server.requests.clear();
      await tapOn(tester, restore('copilot'));
      expect(server.writes.single.body, {
        'config': {
          'model_catalog': {
            'excluded_providers': ['Legacy'],
          },
        },
      });
      expect(tile('copilot'), findsOneWidget);
      expect(restore('copilot'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the server\'s disconnect command is never shown, offered or '
        'sent', (tester) async {
      final server = _external();
      await pumpModels(tester, server, scope);
      await tester.pumpAndSettle();
      // A login Hermes can neither renew nor clear is not a row of its own.
      expect(modelsKey('models-account-claude-code'), findsNothing);
      await openProvider(tester, 'anthropic');
      await openUnconfigured(tester);
      for (final leak in ['rm -f', '.credentials', 'terminal']) {
        expect(find.textContaining(leak), findsNothing, reason: leak);
      }
      // Removing the provider that login connects only leaves it out.
      await removeProvider(tester, 'anthropic');
      expect(server.writes.single.path, '/api/config');
      expect(tile('anthropic'), findsNothing);
      for (final request in server.requests) {
        expect('${request.path} ${request.body}', isNot(contains('rm -f')));
      }
      // The command is not even kept in memory.
      expect(
        OAuthAccount.fromJson(server.accounts.first).toJson().toString(),
        isNot(contains('rm -f')),
      );
    });
  });

  group('an endpoint the user wrote', () {
    ModelsServer withLab() => _server()
      ..catalog.addAll([
        _row(
          'lab',
          'Lab',
          ['lab-1'],
          {
            'is_user_defined': true,
            'source': 'user-config',
            'api_url': 'http://lab.test/v1',
          },
        ),
        _row(
          'custom',
          'Custom endpoint',
          ['raw-1'],
          {
            'is_user_defined': true,
            'source': 'model-config',
            'api_url': 'http://raw.test/v1',
          },
        ),
        _row('llamacpp', 'Local', ['local-1'], {'source': 'local-runtime'}),
        _row('moa', 'Mixture of Agents', ['default'], {'source': 'virtual'}),
      ])
      ..endpoints = [
        {
          'id': 'lab',
          'name': 'Lab',
          'base_url': 'http://lab.test/v1',
          'model': 'lab-1',
          'models': ['lab-1'],
          'source': 'providers',
          'is_current': false,
        },
        {
          'id': 'custom',
          'name': 'Custom',
          'base_url': 'http://raw.test/v1',
          'model': 'raw-1',
          'models': ['raw-1'],
          'source': 'direct-config',
          'is_current': false,
        },
      ];

    testWidgets('Remove deletes the saved endpoint, like Desktop', (
      tester,
    ) async {
      final server = withLab();
      await pumpModels(tester, server, scope);
      await tester.pumpAndSettle();
      expect(modelsKey('saved-endpoint-lab'), findsOneWidget);
      await removeProvider(tester, 'lab');

      final write = server.writes.single;
      expect(write.method, 'DELETE');
      expect(write.path, '/api/providers/custom-endpoints/lab');
      expect(write.profile, 'ana');
      expect(tile('lab'), findsNothing);
      expect(modelsKey('saved-endpoint-lab'), findsNothing);
      // Hermes' exclusion list does not reach an endpoint: it is not used.
      await openUnconfigured(tester);
      expect(restore('lab'), findsNothing);
    });

    testWidgets('the confirmation says an endpoint is gone for good', (
      tester,
    ) async {
      final server = withLab();
      await pumpModels(tester, server, scope);
      await tester.pumpAndSettle();
      await openProvider(tester, 'lab');
      await tapOn(tester, remove('lab'));

      // The one removal the phone cannot undo: a hand-written entry.
      expect(
        find.text('It is deleted from the server and cannot be undone.'),
        findsOneWidget,
      );
      await tapOn(tester, inDialog('Cancel'));
      expect(server.writes, isEmpty);
      expect(modelsKey('saved-endpoint-lab'), findsOneWidget);
    });

    testWidgets('what is not a connected provider has no Remove', (
      tester,
    ) async {
      final server = withLab();
      await pumpModels(tester, server, scope);
      await tester.pumpAndSettle();
      // An address written straight into the config (Desktop offers no
      // delete for it either), the local runtime and Mixture of Agents.
      for (final slug in ['custom', 'llamacpp', 'moa']) {
        await openProvider(tester, slug);
        expect(remove(slug), findsNothing, reason: slug);
      }
      await openProvider(tester, 'lab');
      expect(remove('lab'), findsOneWidget);
    });
  });

  group('a provider the profile is using', () {
    const sentence = 'Choose another model before removing';

    Future<void> expectRefused(
      WidgetTester tester,
      ModelsServer server,
      String slug,
      String name,
    ) async {
      await pumpModels(tester, server, scope);
      await tester.pumpAndSettle();
      await openProvider(tester, slug);
      await tapOn(tester, remove(slug));
      expect(find.byKey(const ValueKey('hermes-dialog')), findsNothing);
      expect(find.text('$sentence $name.'), findsOneWidget);
      expect(server.writes, isEmpty);
      expect(tile(slug), findsOneWidget);
    }

    testWidgets('is not removed while the main model runs on it', (
      tester,
    ) async {
      await expectRefused(tester, _server(), 'acme', 'Acme');
    });

    testWidgets('is not removed while a fallback runs on it', (tester) async {
      final server = _server()
        ..config['fallback_providers'] = [
          {'provider': 'kimi', 'model': 'kimi-k2'},
        ];
      await expectRefused(tester, server, 'kimi', 'Kimi');
    });

    testWidgets('is not removed while a task of "Models by function" runs on '
        'it', (tester) async {
      final server = _server()
        ..aux = [
          {'task': 'vision', 'provider': 'kimi', 'model': 'kimi-k1'},
        ];
      await expectRefused(tester, server, 'kimi', 'Kimi');
    });

    testWidgets('and neither is its key, from the key list', (tester) async {
      final server = _server();
      await pumpModels(tester, server, scope);
      await tester.pumpAndSettle();
      await tapOn(tester, modelsKey('configured-key-ACME_API_KEY'));
      await tapOn(tester, modelsKey('models-key-remove-ACME_API_KEY'));
      expect(find.byKey(const ValueKey('hermes-dialog')), findsNothing);
      expect(find.text('$sentence Acme.'), findsOneWidget);
      expect(server.writes, isEmpty);
    });

    testWidgets('and neither is the endpoint it runs on, from the endpoints '
        'list', (tester) async {
      final server = _server()
        ..catalog.add(
          _row(
            'lab',
            'Lab',
            ['lab-1'],
            {
              'is_user_defined': true,
              'source': 'user-config',
              'api_url': 'http://lab.test/v1',
            },
          ),
        )
        ..endpoints = [
          {
            'id': 'lab',
            'name': 'Lab',
            'base_url': 'http://lab.test/v1',
            'model': 'lab-1',
            'models': ['lab-1'],
            'source': 'providers',
            'is_current': true,
          },
        ]
        ..mainProvider = 'lab'
        ..mainModel = 'lab-1';
      await pumpModels(tester, server, scope);
      await tester.pumpAndSettle();
      await tapOn(
        tester,
        find.descendant(
          of: modelsKey('saved-endpoint-lab'),
          matching: find.byIcon(Icons.more_vert),
        ),
      );
      await tapOn(tester, find.text('Delete'));
      expect(find.byKey(const ValueKey('hermes-dialog')), findsNothing);
      expect(find.text('$sentence Lab.'), findsOneWidget);
      expect(server.writes, isEmpty);
    });

    testWidgets('once another model is the main one it can be removed', (
      tester,
    ) async {
      final server = _server();
      await pumpModels(tester, server, scope);
      await tester.pumpAndSettle();
      await openProvider(tester, 'kimi');
      await tapOn(tester, modelRow('kimi', 'kimi-k2'));
      server.requests.clear();
      await removeProvider(tester, 'acme');
      expect(deletedKeys(server), ['ACME_API_KEY']);
      expect(tile('acme'), findsNothing);
    });
  });

  group('a provider an older version of the app hid on this device', () {
    testWidgets('is offered back with the providers that are not connected, '
        'and nothing is written to the server', (tester) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('hidden_providers', ['kimi']);
      final server = _server();
      await pumpModels(tester, server, scope);
      await tester.pumpAndSettle();
      expect(tile('kimi'), findsNothing);
      await tapOn(tester, modelsKey('models-fallback-add'));
      expect(option('kimi', 'kimi-k2'), findsNothing);
      await back(tester);

      await openUnconfigured(tester);
      expect(
        find.descendant(
          of: modelsKey('models-unconfigured'),
          matching: find.text('Kimi'),
        ),
        findsOneWidget,
      );
      await tapOn(tester, restore('kimi'));
      expect(server.writes, isEmpty);
      expect(prefs.getStringList('hidden_providers'), isEmpty);
      expect(tile('kimi'), findsOneWidget);
      expect(restore('kimi'), findsNothing);
    });
  });

  group('"Edit models"', () {
    ModelsServer seven() => _server()
      ..catalog = [
        for (final name in const [
          'Acme',
          'Bravo',
          'Carbon',
          'Delta',
          'Echo',
          'Foxtrot',
          'Golf',
        ])
          _row(name.toLowerCase(), name, [
            for (var model = 1; model <= 12; model++)
              '${name.toLowerCase()}-$model',
          ]),
        // Not connected: never listed.
        {
          'slug': 'hotel',
          'name': 'Hotel',
          'authenticated': false,
          'models': ['hotel-1'],
        },
      ]
      ..mainModel = 'acme-1';

    testWidgets('opens with every provider closed and fits one screen with '
        'seven of them', (tester) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('hidden_models', ['bravo/bravo-3']);
      await prefs.setStringList('hidden_providers', ['golf']);
      final server = seven();
      await pumpModels(tester, server, scope);
      await tester.pumpAndSettle();
      await tester.ensureVisible(modelsKey('models-edit-models'));
      // A phone screen from here on.
      tester.view.physicalSize = const Size(412, 800);
      await tester.pumpAndSettle();
      await tapOn(tester, modelsKey('models-edit-models'));

      Finder header(String slug) =>
          modelsKey('model-visibility-provider-$slug');
      final shown = ['acme', 'bravo', 'carbon', 'delta', 'echo', 'foxtrot'];
      for (final slug in shown) {
        expect(header(slug), findsOneWidget, reason: slug);
        expect(
          tester.getRect(header(slug)).bottom,
          lessThanOrEqualTo(800),
          reason: '$slug is on the first screen',
        );
        // A provider is not switched off here: it is removed on the page.
        expect(
          find.descendant(of: header(slug), matching: find.byType(Switch)),
          findsNothing,
        );
      }
      // Only the providers of the page: connected and not taken out.
      expect(header('golf'), findsNothing);
      expect(header('hotel'), findsNothing);
      expect(find.byType(Switch), findsNothing, reason: 'every one is closed');
      expect(
        find.descendant(
          of: header('acme'),
          matching: find.text('12 of 12 visible'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: header('bravo'),
          matching: find.text('11 of 12 visible'),
        ),
        findsOneWidget,
      );

      // Opening one shows its models; the others stay closed.
      await tapOn(tester, header('acme'));
      expect(modelsKey('model-visibility-acme-acme-1'), findsOneWidget);
      expect(modelsKey('model-visibility-bravo-bravo-1'), findsNothing);
      await tapOn(tester, modelsKey('model-visibility-acme-acme-2'));
      expect(
        find.descendant(
          of: header('acme'),
          matching: find.text('11 of 12 visible'),
        ),
        findsOneWidget,
      );
      expect(prefs.getStringList('hidden_models'), [
        'bravo/bravo-3',
        'acme/acme-2',
      ]);
      expect(prefs.getStringList('hidden_providers'), ['golf']);
      await tapOn(tester, header('acme'));
      expect(modelsKey('model-visibility-acme-acme-1'), findsNothing);
    });
  });
}
