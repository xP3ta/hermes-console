// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/models_screen.dart';
import 'package:hermes_android/core/screens/onboarding_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/onboarding_arrival.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../support/onboarding_fakes.dart';

/// A Dashboard whose model answers the test steers. `ready` flips it.
class _Model {
  _Model({this.ready = true});
  bool ready;
  bool fail = false;
  Completer<void>? hang;
  final List<Uri> calls = [];

  MockClient get client => MockClient((r) async {
    if (r.url.path == '/auth/password-login') {
      return http.Response(
        '{}',
        200,
        headers: {'set-cookie': 'hermes_session_at=synthetic-cookie; Path=/'},
      );
    }
    if (!r.url.path.startsWith('/api/model/')) {
      return http.Response('{}', 200);
    }
    calls.add(r.url);
    if (hang != null) await hang!.future;
    if (fail) return http.Response('{}', 500);
    if (r.url.path == '/api/model/info') {
      return http.Response(
        jsonEncode(
          ready
              ? {'model': 'gpt-x', 'provider': 'openai'}
              : {'model': '', 'provider': ''},
        ),
        200,
      );
    }
    return http.Response(
      jsonEncode({
        'providers': [
          {
            'slug': 'openai',
            'name': 'OpenAI',
            'authenticated': ready,
            'models': ['gpt-x'],
          },
        ],
      }),
      200,
    );
  });

  int get readCalls => calls.length;
}

const _openChat = ValueKey('onboarding-open-chat');

Future<(ConnectionManager, List<int>)> _toSuccess(
  WidgetTester tester,
  _Model model, {
  required bool flag,
  bool readOnly = false,
  Future<ConnectionManager> Function()? managerFactory,
}) async {
  tester.view.physicalSize = const Size(800, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final manager = await (managerFactory ?? onboardingManager)();
  final done = <int>[];
  {
    await tester.pumpWidget(
      onboardingHost(
        OnboardingScreen(
          connManager: manager,
          onDone: () => done.add(1),
          diagnostics: OnboardingDiagnostics(readOnly: readOnly),
          simpleConnectEnabled: flag,
          scanCode: (_) async => fakeFullPairing,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tapOnboarding(tester, 'onboarding-scan');
    await tapOnboarding(tester, 'onboarding-confirm');
  }
  return (manager, done);
}

/// The whole test runs inside the Dashboard fake's HTTP zone: frame
/// callbacks, which start the model read, run in the zone of the pump.
void _test(
  String name,
  _Model model,
  Future<void> Function(WidgetTester tester) body,
) => testWidgets(name, (tester) async {
  await http.runWithClient(() => body(tester), () => model.client);
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(OnboardingArrival.reset);

  final off = _Model();
  _test('RED 1: flag off keeps «Go to Home» alone and asks nothing', off, (
    tester,
  ) async {
    final (manager, done) = await _toSuccess(tester, off, flag: false);
    final s = onboardingStrings(tester);
    expect(find.text(s.o2SuccessTitle), findsOneWidget);
    expect(find.text(s.o2GoHome), findsOneWidget);
    expect(find.byKey(_openChat), findsNothing);
    expect(find.text(s.o2OpenChat), findsNothing);
    await tester.pump(const Duration(seconds: 5));
    expect(off.readCalls, 0);
    await tapOnboarding(tester, 'onboarding-done');
    expect(done, [1]);
    expect(OnboardingArrival.take(manager.getConnections().single.id), isFalse);
  });

  final readOnly = _Model();
  _test('read-only: no «Open chat», no model read', readOnly, (tester) async {
    await _toSuccess(tester, readOnly, flag: true, readOnly: true);
    final s = onboardingStrings(tester);
    expect(find.text(s.o2ReadOnly), findsOneWidget);
    expect(find.byKey(_openChat), findsNothing);
    expect(find.text(s.o2GoHome), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    expect(readOnly.readCalls, 0);
  });

  final ready = _Model();
  _test('RED 2: model ready → «Open chat» leaves one request', ready, (
    tester,
  ) async {
    final (manager, done) = await _toSuccess(tester, ready, flag: true);
    final s = onboardingStrings(tester);
    expect(find.text(s.o2OpenChat), findsOneWidget);
    expect(find.text(s.o2SuccessBody), findsOneWidget);
    expect(find.text(s.o2GoHome), findsOneWidget);
    expect(ready.readCalls, 2, reason: 'one info + one options, once');
    await tapOnboarding(tester, 'onboarding-open-chat');
    expect(done, [1]);
    expect(OnboardingArrival.take(manager.getConnections().single.id), isTrue);
  });

  final home = _Model();
  _test('«Go to Home» with the flag on leaves no request', home, (
    tester,
  ) async {
    final (manager, done) = await _toSuccess(tester, home, flag: true);
    await tapOnboarding(tester, 'onboarding-done');
    expect(done, [1]);
    expect(OnboardingArrival.take(manager.getConnections().single.id), isFalse);
  });

  final profile = _Model();
  _test(
    'RED 5: the model is read for the new connection\u2019s profile',
    profile,
    (tester) async {
      final manager = await onboardingManager();
      // Another connection works in profile `work`; it must stay there and the
      // new one must not inherit it.
      await manager.upsertConnection(
        fakeFullPairing.toDraftConnection().copyWith(
          id: 'conn-a',
          host: 'other.invalid',
        ),
      );
      await manager.setActiveProfile('conn-a', 'work');
      await _toSuccess(
        tester,
        profile,
        flag: true,
        managerFactory: () async => manager,
      );
      final created = manager.getConnections().firstWhere(
        (c) => c.id != 'conn-a',
      );
      expect(profile.readCalls, 2);
      expect(
        profile.calls.every((u) => !u.queryParameters.containsKey('profile')),
        isTrue,
      );
      expect(manager.activeProfileFor(created.id), '');
      expect(manager.activeProfileFor('conn-a'), 'work');
    },
  );

  final none = _Model(ready: false);
  _test('RED 3: no model → choose a model, never a chat that fails', none, (
    tester,
  ) async {
    final (manager, done) = await _toSuccess(tester, none, flag: true);
    final s = onboardingStrings(tester);
    expect(find.text(s.o2NeedsModelBody), findsOneWidget);
    expect(find.text(s.o2SuccessBody), findsNothing);
    expect(find.text(s.o2ChooseModel), findsOneWidget);
    expect(find.text(s.o2OpenChat), findsNothing);
    expect(find.text(s.o2GoHome), findsOneWidget);
    await tapOnboarding(tester, 'onboarding-open-chat');
    expect(find.byType(ModelsScreen), findsOneWidget);
    expect(done, isEmpty);
    expect(OnboardingArrival.take(manager.getConnections().single.id), isFalse);
    // Back with a model set: the check repeats once and «Open chat» appears.
    none.ready = true;
    final before = none.readCalls;
    Navigator.of(tester.element(find.byType(ModelsScreen))).pop();
    await tester.pumpAndSettle();
    expect(find.text(s.o2OpenChat), findsOneWidget);
    expect(find.text(s.o2ChooseModel), findsNothing);
    expect(none.readCalls, before + 2);
  });

  final broken = _Model()..fail = true;
  _test('RED 4: a failing read is «unknown» and opens the chat', broken, (
    tester,
  ) async {
    final (manager, done) = await _toSuccess(tester, broken, flag: true);
    final s = onboardingStrings(tester);
    expect(find.text(s.o2OpenChat), findsOneWidget);
    expect(find.text(s.o2NeedsModelBody), findsNothing);
    await tapOnboarding(tester, 'onboarding-open-chat');
    expect(done, [1]);
    expect(OnboardingArrival.take(manager.getConnections().single.id), isTrue);
  });

  final slow = _Model()..hang = Completer<void>();
  _test(
    'RED 4: «Open chat» shows from the first frame while the check runs',
    slow,
    (tester) async {
      final (manager, done) = await _toSuccess(tester, slow, flag: true);
      final s = onboardingStrings(tester);
      expect(find.text(s.o2OpenChat), findsOneWidget);
      await tester.tap(find.byKey(_openChat));
      await tester.pump(const Duration(milliseconds: 600));
      expect(done, [1]);
      expect(
        OnboardingArrival.take(manager.getConnections().single.id),
        isTrue,
      );
      slow.hang!.complete();
      await tester.pump(const Duration(seconds: 11));
    },
  );
}
