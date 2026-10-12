// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hermes Console contributors
//
// Accounts and API keys of the Models screen, as Desktop's Settings →
// Providers offers them. Their rows and their state are the server's own
// lists (`/api/providers/oauth`, `/api/env`), never guessed from the model
// catalog: whatever is set can be removed, and nothing is shown as connected,
// saved or removed unless the server says so.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/active_profile_scope.dart';

import 'support/models_server.dart';

void main() {
  late ActiveProfileScope scope;
  setUp(() async => scope = await modelsScope());

  final keyRow = modelsKey('configured-key-ACME_API_KEY');
  final field = modelsKey('provider-key-field');
  final save = modelsKey('provider-key-save');
  final reason = modelsKey('provider-key-reason');

  Future<void> removeAcmeKey(WidgetTester tester) async {
    await tapOn(tester, keyRow);
    await tapOn(tester, modelsKey('models-key-remove-ACME_API_KEY'));
  }

  Future<void> enterZetaKey(WidgetTester tester, String key) async {
    await openUnconfigured(tester);
    await tapOn(tester, modelsKey('models-key-option-ZETA_API_KEY'));
    await tester.enterText(field, key);
    await tester.pumpAndSettle();
    await tapOn(tester, save);
  }

  group('API keys', () {
    testWidgets('a set key is listed and removable although the catalog row '
        'of its provider names no key', (tester) async {
      // The official catalog sends `auth_type`/`key_env` only for providers
      // that are NOT set up, so a connected provider's row cannot say which
      // key to remove. The key list can.
      final server = ModelsServer.acmeIdle();
      await pumpModels(tester, server, scope);
      await tester.pumpAndSettle();
      expect(keyRow, findsOneWidget);
      expect(
        find.descendant(of: keyRow, matching: find.text('Connected')),
        findsOneWidget,
      );

      await removeAcmeKey(tester);
      expect(server.writes, isEmpty, reason: 'nothing is removed unasked');
      await tapOn(tester, inDialog('Remove'));

      final delete = server.of('DELETE', '/api/env').single;
      expect(delete.profile, 'ana');
      expect(delete.body, {'key': 'ACME_API_KEY', 'profile': 'ana'});
      expect(keyRow, findsNothing, reason: 'the server lists it as unset');
    });

    testWidgets('cancelling the question removes nothing', (tester) async {
      final server = ModelsServer.acmeIdle();
      await pumpModels(tester, server, scope);
      await tester.pumpAndSettle();
      await removeAcmeKey(tester);
      await tapOn(tester, inDialog('Cancel'));
      expect(server.writes, isEmpty);
      expect(keyRow, findsOneWidget);
    });

    testWidgets('a key the server still holds is not shown as removed', (
      tester,
    ) async {
      final server = ModelsServer.acmeIdle()..ignoreKeyDelete = true;
      await pumpModels(tester, server, scope);
      await tester.pumpAndSettle();
      await removeAcmeKey(tester);
      await tapOn(tester, inDialog('Remove'));
      expect(server.of('DELETE', '/api/env'), hasLength(1));
      expect(keyRow, findsOneWidget);
    });

    testWidgets('a key is removable while the catalog cannot be read', (
      tester,
    ) async {
      final server = ModelsServer()..optionsStatus = 503;
      await pumpModels(tester, server, scope);
      await tester.pumpAndSettle();
      await removeAcmeKey(tester);
      await tapOn(tester, inDialog('Remove'));
      expect(server.of('DELETE', '/api/env').single.profile, 'ana');
      expect(keyRow, findsNothing);
    });

    testWidgets('a read-only connection cannot remove a key', (tester) async {
      final server = ModelsServer();
      await pumpModels(tester, server, scope, readOnly: true);
      await tester.pumpAndSettle();
      await removeAcmeKey(tester);
      expect(find.byKey(const ValueKey('hermes-dialog')), findsNothing);
      expect(server.writes, isEmpty);
      expect(keyRow, findsOneWidget);
    });

    testWidgets('a saved key is listed as connected once the server holds it', (
      tester,
    ) async {
      final server = ModelsServer();
      await pumpModels(tester, server, scope);
      await tester.pumpAndSettle();
      final zeta = modelsKey('configured-key-ZETA_API_KEY');
      expect(zeta, findsNothing);

      await enterZetaKey(tester, 'synthetic-zeta-key');

      // The server's own check first, then the store, then the list again.
      final check = server.of('POST', '/api/providers/validate').single;
      expect(check.body, {
        'key': 'ZETA_API_KEY',
        'value': 'synthetic-zeta-key',
      });
      expect(check.profile, 'ana');
      final put = server.of('PUT', '/api/env').single;
      expect(put.body, {
        'key': 'ZETA_API_KEY',
        'value': 'synthetic-zeta-key',
        'profile': 'ana',
      });
      expect(field, findsNothing, reason: 'the key page closed');
      expect(zeta, findsOneWidget);
      expect(
        find.descendant(of: zeta, matching: find.text('Connected')),
        findsOneWidget,
      );
    });

    testWidgets('a key the provider rejects is not stored', (tester) async {
      final server = ModelsServer()
        ..verdicts['ZETA_API_KEY'] = {
          'ok': false,
          'reachable': true,
          'message': 'That API key was rejected.',
        };
      await pumpModels(tester, server, scope);
      await tester.pumpAndSettle();
      await enterZetaKey(tester, 'synthetic-bad-key');

      expect(server.of('PUT', '/api/env'), isEmpty);
      expect(server.keys['ZETA_API_KEY'], isFalse);
      expect(reason, findsOneWidget);
      expect(field, findsOneWidget, reason: 'the page stays to fix the key');
    });

    testWidgets('a key the server did not store is never shown as saved', (
      tester,
    ) async {
      final server = ModelsServer()..ignoreKeySave = true;
      await pumpModels(tester, server, scope);
      await tester.pumpAndSettle();
      await enterZetaKey(tester, 'synthetic-zeta-key');

      expect(server.of('PUT', '/api/env'), hasLength(1));
      expect(reason, findsOneWidget);
      expect(field, findsOneWidget);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(modelsKey('configured-key-ZETA_API_KEY'), findsNothing);
    });

    testWidgets('a provider the server cannot check still gets its key', (
      tester,
    ) async {
      // `reachable: false` is "no verdict", not a rejection.
      final server = ModelsServer()
        ..verdicts['ZETA_API_KEY'] = {'ok': false, 'reachable': false};
      await pumpModels(tester, server, scope);
      await tester.pumpAndSettle();
      await enterZetaKey(tester, 'synthetic-zeta-key');
      expect(server.keys['ZETA_API_KEY'], isTrue);
      expect(modelsKey('configured-key-ZETA_API_KEY'), findsOneWidget);
    });

    testWidgets('a profile switch while the key page is open voids the save', (
      tester,
    ) async {
      final server = ModelsServer();
      await pumpModels(tester, server, scope);
      await tester.pumpAndSettle();
      await openUnconfigured(tester);
      await tapOn(tester, modelsKey('models-key-option-ZETA_API_KEY'));
      await tester.enterText(field, 'synthetic-zeta-key');
      await scope.switchTo('bert');
      await tester.pumpAndSettle();
      await tapOn(tester, save);

      expect(server.of('PUT', '/api/env'), isEmpty);
      expect(server.of('POST', '/api/providers/validate'), isEmpty);
      expect(field, findsNothing, reason: 'the page of another profile closes');
    });
  });

  group('Accounts', () {
    ModelsServer withAccounts() => ModelsServer()
      ..accounts = [
        {
          'id': 'anthropic',
          'name': 'Anthropic',
          // Signed in elsewhere, but its credential is Hermes' to clear.
          'flow': 'external',
          'disconnectable': true,
          'status': {'logged_in': true},
        },
        {
          'id': 'openai-codex',
          'name': 'OpenAI Codex',
          'flow': 'device_code',
          'disconnectable': true,
          'status': {'logged_in': true},
        },
        {
          'id': 'nous',
          'name': 'Nous',
          'flow': 'device_code',
          'disconnectable': true,
          'status': {'logged_in': false},
        },
        {
          'id': 'qwen-oauth',
          'name': 'Qwen',
          'flow': 'external',
          'disconnectable': false,
          'status': {'logged_in': false},
        },
      ];

    final anthropic = modelsKey('models-account-anthropic');

    testWidgets('connected accounts are the server\'s and can be '
        'disconnected', (tester) async {
      final server = withAccounts();
      await pumpModels(tester, server, scope);
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: anthropic, matching: find.text('Connected')),
        findsOneWidget,
      );
      expect(modelsKey('models-account-openai-codex'), findsOneWidget);
      expect(modelsKey('models-account-nous'), findsNothing);

      await tapOn(tester, anthropic);
      await tapOn(tester, modelsKey('models-account-disconnect-anthropic'));
      expect(server.writes, isEmpty, reason: 'nothing is removed unasked');
      await tapOn(tester, inDialog('Remove'));

      final delete = server.of('DELETE', '/api/providers/oauth/anthropic');
      expect(delete.single.profile, 'ana');
      expect(anthropic, findsNothing, reason: 'the server lists it signed out');
      expect(modelsKey('models-account-openai-codex'), findsOneWidget);
    });

    testWidgets('an account the server still reports is not shown as '
        'disconnected', (tester) async {
      final server = withAccounts()..ignoreDisconnect = true;
      await pumpModels(tester, server, scope);
      await tester.pumpAndSettle();
      await tapOn(tester, anthropic);
      await tapOn(tester, modelsKey('models-account-disconnect-anthropic'));
      await tapOn(tester, inDialog('Remove'));
      expect(
        server.of('DELETE', '/api/providers/oauth/anthropic'),
        hasLength(1),
      );
      expect(anthropic, findsOneWidget);
    });

    testWidgets('only accounts that can sign in from the phone are offered', (
      tester,
    ) async {
      final server = withAccounts();
      await pumpModels(tester, server, scope);
      await tester.pumpAndSettle();
      await openUnconfigured(tester);
      expect(modelsKey('models-account-option-nous'), findsOneWidget);
      // Needs the provider's own CLI on the server.
      expect(modelsKey('models-account-option-qwen-oauth'), findsNothing);
    });

    testWidgets('a read-only connection cannot disconnect', (tester) async {
      final server = withAccounts();
      await pumpModels(tester, server, scope, readOnly: true);
      await tester.pumpAndSettle();
      await tapOn(tester, anthropic);
      await tapOn(tester, modelsKey('models-account-disconnect-anthropic'));
      expect(find.byKey(const ValueKey('hermes-dialog')), findsNothing);
      expect(server.writes, isEmpty);
    });

    testWidgets('the account list is read for the profile on screen', (
      tester,
    ) async {
      final server = withAccounts();
      await pumpModels(tester, server, scope);
      await tester.pumpAndSettle();
      expect(
        server.of('GET', '/api/providers/oauth').map((r) => r.profile),
        everyElement('ana'),
      );
      expect(
        server.of('GET', '/api/env').map((r) => r.profile),
        everyElement('ana'),
      );
    });
  });
}
