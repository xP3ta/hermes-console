// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hermes Console contributors
//
// The Models page: the "ACTIVE MODEL" card, the fallback chain, "Models by
// function", one group per connected provider with its models, then what is
// connected and what is still to set up. Every value on it is the server's.
// It paints the last answer at once and never trades what is on screen for a
// loader while the server is asked again.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/active_profile_scope.dart';
import 'package:hermes_android/core/services/models_snapshot.dart';
import 'package:hermes_android/core/widgets/console_loader.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/models_server.dart';

void main() {
  late ActiveProfileScope scope;
  setUp(() async => scope = await modelsScope());

  Finder inRow(String rowKey, String value) =>
      find.descendant(of: modelsKey(rowKey), matching: find.text(value));
  Finder option(String provider, String model) =>
      modelsKey('models-picker-$provider-$model');
  String? shown(WidgetTester tester, String key) {
    final finder = modelsKey(key);
    return finder.evaluate().isEmpty ? null : tester.widget<Text>(finder).data;
  }

  String? mainModel(WidgetTester tester) =>
      shown(tester, 'lm1215-active-model');
  String? mainProvider(WidgetTester tester) =>
      shown(tester, 'lm1215-active-provider');

  testWidgets('the blocks of the page, top to bottom', (tester) async {
    final server = ModelsServer()
      ..contextLength = 204800
      ..accounts = [
        {
          'id': 'nous',
          'name': 'Nous',
          'flow': 'device_code',
          'status': {'logged_in': true},
        },
      ];
    await pumpModels(tester, server, scope);
    await tester.pumpAndSettle();
    // The card of the main model says how much context it has.
    expect(find.text('200k tokens'), findsOneWidget);
    final order = [
      for (final label in [
        'ACTIVE MODEL',
        'FALLBACK MODELS',
        'Models by function',
        'MAIN MODEL · PROVIDERS',
        'ACCOUNTS',
        'API KEYS',
        'Unconfigured providers',
        'Custom endpoints',
      ])
        tester.getTopLeft(find.text(label)).dy,
    ];
    expect(order, [...order]..sort(), reason: 'top to bottom');
    expect(mainModel(tester), 'acme-large');
    expect(mainProvider(tester), 'Acme');
    // One group per connected provider; its models show once it is opened.
    expect(modelRow('acme', 'acme-small'), findsNothing);
    await openProvider(tester, 'acme');
    expect(modelRow('acme', 'acme-large'), findsOneWidget);
    expect(modelRow('acme', 'acme-small'), findsOneWidget);
    await openAux(tester);
    expect(inRow('models-aux-vision', 'Automatic'), findsOneWidget);
    expect(inRow('models-aux-compression', 'next · other'), findsOneWidget);
  });

  testWidgets('a model of another provider becomes the main model', (
    tester,
  ) async {
    final server = ModelsServer();
    await pumpModels(tester, server, scope);
    await tester.pumpAndSettle();
    await openProvider(tester, 'other');
    await tapOn(tester, modelRow('other', 'next'));

    final set = server.of('POST', '/api/model/set').single;
    expect(set.profile, 'ana');
    expect(set.body, {'provider': 'other', 'model': 'next', 'scope': 'main'});
    expect(mainProvider(tester), 'Other');
    expect(mainModel(tester), 'next');
  });

  testWidgets('a model of a user endpoint is set with its address', (
    tester,
  ) async {
    final server = ModelsServer()
      ..catalog.add({
        'slug': 'box',
        'name': 'Box',
        'authenticated': true,
        'is_user_defined': true,
        'api_url': 'http://box.example.test:8080/v1',
        'models': ['box-model'],
      });
    await pumpModels(tester, server, scope);
    await tester.pumpAndSettle();
    await openProvider(tester, 'box');
    await tapOn(tester, modelRow('box', 'box-model'));
    expect(server.of('POST', '/api/model/set').single.body, {
      'provider': 'box',
      'model': 'box-model',
      'scope': 'main',
      'base_url': 'http://box.example.test:8080/v1',
    });
  });

  testWidgets('a model the server wants acknowledged is asked once and '
      'resent', (tester) async {
    final server = ModelsServer()
      ..confirmFirst = {
        'ok': false,
        'confirm_required': true,
        'confirm_message': 'This model is billed at a premium rate.',
      };
    await pumpModels(tester, server, scope);
    await tester.pumpAndSettle();
    await openProvider(tester, 'acme');
    await tapOn(tester, modelRow('acme', 'acme-small'));

    expect(server.mainModel, 'acme-large', reason: 'not applied unasked');
    expect(
      find.text('This model is billed at a premium rate.'),
      findsOneWidget,
    );
    await tapOn(tester, inDialog('Use'));
    final sets = server.of('POST', '/api/model/set');
    expect(sets, hasLength(2));
    expect(sets.last.body!['confirm_expensive_model'], isTrue);
    expect(mainModel(tester), 'acme-small');
  });

  testWidgets('a refused model is not shown as the main model', (tester) async {
    final server = ModelsServer()
      ..confirmFirst = {'ok': false, 'confirm_required': false};
    await pumpModels(tester, server, scope);
    await tester.pumpAndSettle();
    await openProvider(tester, 'acme');
    await tapOn(tester, modelRow('acme', 'acme-small'));
    expect(mainModel(tester), 'acme-large');
    expect(find.byKey(const ValueKey('hermes-dialog')), findsNothing);
  });

  testWidgets('the reasoning default is written as a sparse patch and shows '
      'what the server kept', (tester) async {
    final server = ModelsServer();
    await pumpModels(tester, server, scope);
    await tester.pumpAndSettle();
    expect(inRow('models-main-reasoning', 'Medium'), findsOneWidget);
    await tapOn(tester, modelsKey('models-main-reasoning'));
    await tapOn(tester, modelsKey('models-reasoning-high'));

    final put = server.of('PUT', '/api/config').single;
    expect(put.profile, 'ana');
    expect(put.body, {
      'config': {
        'agent': {'reasoning_effort': 'high'},
      },
    });
    expect(inRow('models-main-reasoning', 'High'), findsOneWidget);
  });

  testWidgets('speed is offered only for a model that has it', (tester) async {
    final server = ModelsServer();
    server.catalog.first['capabilities'] = {
      'acme-large': {'reasoning': false, 'fast': true},
    };
    await pumpModels(tester, server, scope);
    await tester.pumpAndSettle();
    expect(modelsKey('models-main-reasoning'), findsNothing);
    expect(modelsKey('models-main-speed'), findsNothing);
    await tapOn(tester, modelsKey('models-main-fast'));
    expect(server.of('PUT', '/api/config').single.body, {
      'config': {
        'agent': {'service_tier': 'fast'},
      },
    });
  });

  testWidgets('an auxiliary task goes back to automatic from its picker', (
    tester,
  ) async {
    final server = ModelsServer();
    await pumpModels(tester, server, scope);
    await tester.pumpAndSettle();
    await openAux(tester);
    await tapOn(tester, modelsKey('models-aux-compression'));
    await tapOn(tester, modelsKey('models-picker-default'));

    final set = server.of('POST', '/api/model/set').single;
    expect(set.profile, 'ana');
    expect(set.body, {
      'provider': 'auto',
      'model': '',
      'scope': 'auxiliary',
      'task': 'compression',
    });
    expect(inRow('models-aux-compression', 'Automatic'), findsOneWidget);
  });

  testWidgets('"Reset all to main" asks once', (tester) async {
    final server = ModelsServer();
    await pumpModels(tester, server, scope);
    await tester.pumpAndSettle();
    await openAux(tester);
    await tapOn(tester, modelsKey('models-aux-reset'));
    expect(server.writes, isEmpty);
    await tapOn(tester, inDialog('Cancel'));
    expect(server.writes, isEmpty);

    await tapOn(tester, modelsKey('models-aux-reset'));
    await tapOn(tester, inDialog('Reset all to main'));
    expect(server.of('POST', '/api/model/set').single.body, {
      'provider': 'auto',
      'model': '',
      'scope': 'auxiliary',
      'task': '__reset__',
    });
    expect(inRow('models-aux-compression', 'Automatic'), findsOneWidget);
  });

  testWidgets('a task pinned to another provider than the main one is said', (
    tester,
  ) async {
    final server = ModelsServer();
    await pumpModels(tester, server, scope);
    await tester.pumpAndSettle();
    // Said above the closed block, so it is seen without opening it.
    expect(modelsKey('models-aux-stale'), findsOneWidget);
    await openAux(tester);
    await tapOn(tester, modelsKey('models-aux-reset'));
    await tapOn(tester, inDialog('Reset all to main'));
    expect(modelsKey('models-aux-stale'), findsNothing);
  });

  testWidgets('"Edit models" takes a model out of the page and the pickers', (
    tester,
  ) async {
    final server = ModelsServer();
    await pumpModels(tester, server, scope);
    await tester.pumpAndSettle();
    await tapOn(tester, modelsKey('models-edit-models'));
    await tapOn(tester, modelsKey('model-visibility-provider-acme'));
    await tapOn(tester, modelsKey('model-visibility-acme-acme-small'));
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('hidden_models'), ['acme/acme-small']);
    await openProvider(tester, 'acme');
    expect(modelRow('acme', 'acme-large'), findsOneWidget);
    expect(modelRow('acme', 'acme-small'), findsNothing);
    await tapOn(tester, modelsKey('models-fallback-add'));
    expect(option('acme', 'acme-large'), findsOneWidget);
    expect(option('acme', 'acme-small'), findsNothing);
  });

  testWidgets('a connected provider\'s group offers what can be done to it', (
    tester,
  ) async {
    final server = ModelsServer.acmeIdle();
    await pumpModels(tester, server, scope);
    await tester.pumpAndSettle();
    // Other has no key the server lists: only "Remove provider".
    await openProvider(tester, 'other');
    expect(modelsKey('models-provider-key-other'), findsNothing);
    expect(modelsKey('models-provider-remove-other'), findsOneWidget);

    await openProvider(tester, 'acme');
    expect(modelsKey('models-provider-key-acme'), findsOneWidget);
    await tapOn(tester, modelsKey('models-provider-remove-acme'));
    expect(server.writes, isEmpty, reason: 'nothing is removed unasked');
    await tapOn(tester, inDialog('Remove'));
    expect(server.of('DELETE', '/api/env').single.body, {
      'key': 'ACME_API_KEY',
      'profile': 'ana',
    });
  });

  testWidgets('a read-only connection changes nothing', (tester) async {
    final server = ModelsServer();
    await pumpModels(tester, server, scope, readOnly: true);
    await tester.pumpAndSettle();
    await openProvider(tester, 'acme');
    await tapOn(tester, modelRow('acme', 'acme-small'));
    await openAux(tester);
    await tapOn(tester, modelsKey('models-aux-reset'));
    expect(find.byKey(const ValueKey('hermes-dialog')), findsNothing);
    expect(server.writes, isEmpty);
    expect(mainModel(tester), 'acme-large');
  });

  testWidgets('reopening paints every block at once, before the server '
      'answers', (tester) async {
    final server = ModelsServer()
      ..accounts = [
        {
          'id': 'nous',
          'name': 'Nous',
          'flow': 'device_code',
          'status': {'logged_in': true},
        },
      ];
    final cache = ModelsSnapshotCache();
    await pumpModels(tester, server, scope, cache: cache);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());

    server.optionsGate = Completer<void>();
    await pumpModels(tester, server, scope, cache: cache);
    await tester.pump();
    await tester.pump();
    expect(find.byType(ConsoleLoader), findsNothing);
    expect(mainModel(tester), 'acme-large');
    expect(find.text('Models by function'), findsOneWidget);
    expect(modelsKey('models-provider-acme'), findsOneWidget);
    expect(modelsKey('models-account-nous'), findsOneWidget);
    expect(modelsKey('configured-key-ACME_API_KEY'), findsOneWidget);
    expect(modelsKey('models-unconfigured'), findsOneWidget);
    expect(modelsKey('models-fallback-add'), findsOneWidget);
    expect(modelsKey('mdl-revalidating'), findsOneWidget);

    server.optionsGate!.complete();
    await tester.pumpAndSettle();
    expect(modelsKey('mdl-revalidating'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('after a change the page stays on screen while the server is '
      'read again', (tester) async {
    final server = ModelsServer();
    await pumpModels(tester, server, scope);
    await tester.pumpAndSettle();
    await openAux(tester);
    await tapOn(tester, modelsKey('models-aux-compression'));
    server.optionsGate = Completer<void>();
    await tester.tap(modelsKey('models-picker-default'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // The write landed; its re-read is still being built by the server.
    expect(server.of('POST', '/api/model/set'), hasLength(1));
    expect(find.byType(ConsoleLoader), findsNothing);
    expect(mainModel(tester), 'acme-large');
    expect(modelsKey('models-aux-compression'), findsOneWidget);

    server.optionsGate!.complete();
    await tester.pumpAndSettle();
    expect(inRow('models-aux-compression', 'Automatic'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a failed refresh keeps the page and says so in one sentence', (
    tester,
  ) async {
    final server = ModelsServer();
    final cache = ModelsSnapshotCache();
    await pumpModels(tester, server, scope, cache: cache);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());

    server.optionsStatus = 503;
    await pumpModels(tester, server, scope, cache: cache);
    await tester.pumpAndSettle();
    expect(mainModel(tester), 'acme-large');
    expect(modelsKey('models-load-failed'), findsOneWidget);
    expect(find.text('Could not load models'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
