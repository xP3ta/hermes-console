// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/onboarding_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/dashboard_address.dart';
import 'package:hermes_android/core/services/simple_connect/hermes_server_status.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:http/testing.dart';

import '../onb2q/hermes_shaped_server.dart';
import '../support/connection_editor_actions.dart';
import '../support/onboarding_fakes.dart';

/// One HTTP client of the fake Dashboard. It remembers whether it read the
/// model state and whether it was closed.
class DashClient extends http.BaseClient {
  DashClient(this._owner);
  final Dash _owner;
  bool servedModel = false;
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request.url.path.startsWith('/api/model/')) servedModel = true;
    return _owner._inner.send(request);
  }

  @override
  void close() {
    closed = true;
    super.close();
  }
}

/// A Dashboard whose login and model answers the test steers.
class Dash {
  Dash({this.ready = true});

  /// The Dashboard being driven by the test in progress ([withDash]).
  static Dash? current;

  /// The sign-in routes of a real Hermes-shaped server; the fake forwards
  /// `/auth/*` and `/api/auth/me` to it over a socket made outside the fake
  /// client's zone.
  HermesShapedServer? auth;
  late final http.Client _real = IOClient(
    HttpClient()..idleTimeout = Duration.zero,
  );

  bool ready;
  int modelStatus = 200;
  Completer<void>? hang;
  final List<Uri> modelCalls = [];
  final List<DashClient> clients = [];

  late final MockClient _inner = MockClient((r) async {
    if (auth != null &&
        (r.url.path.startsWith('/auth/') || r.url.path == '/api/auth/me')) {
      final out =
          http.Request(
              r.method,
              Uri.parse(auth!.url).replace(
                path: r.url.path,
                query: r.url.hasQuery ? r.url.query : null,
              ),
            )
            ..followRedirects = false
            ..headers.addAll(r.headers);
      out.body = r.body;
      return http.Response.fromStream(await _real.send(out));
    }
    switch (r.url.path) {
      case '/api/status':
        return http.Response('{"auth_required":true}', 200);
      case '/api/auth/providers':
        return http.Response(
          '{"providers":[{"name":"basic","supports_password":true}]}',
          200,
        );
      case '/auth/password-login':
        return http.Response(
          '{}',
          200,
          headers: {'set-cookie': 'hermes_session_at=synthetic; Path=/'},
        );
    }
    if (!r.url.path.startsWith('/api/model/')) {
      return http.Response('{"user_id":"synthetic-owner"}', 200);
    }
    modelCalls.add(r.url);
    if (hang != null) await hang!.future;
    if (modelStatus != 200) return http.Response('{}', modelStatus);
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

  http.Client newClient() {
    final c = DashClient(this);
    clients.add(c);
    return c;
  }

  Iterable<DashClient> get modelClients => clients.where((c) => c.servedModel);
  int get modelReads => modelCalls.length;
}

HermesServerStatus fixtureStatus() => HermesServerStatus.tryParse(
  jsonDecode(
    File(
      'test/fixtures/simple_connect/status_dashboard_basic.json',
    ).readAsStringSync(),
  ),
)!;

/// The address check of Connect by hand: the fake Dashboard always answers.
Future<HostProbeResult> fakeProbe(DiscoveryTarget _) async =>
    HostProbeResult(HostVerdict.hermes, fixtureStatus());

class Taps {
  Taps(this.tester);
  final WidgetTester tester;
  int count = 0;
  final List<String> trail = [];

  Future<void> key(String key) async {
    final finder = find.byKey(ValueKey(key));
    await revealEditorControl(tester, finder);
    await tester.tap(finder);
    count++;
    trail.add(key);
    await tester.pumpAndSettle();
  }

  Future<void> raw(String name, Finder finder) async {
    await tester.tap(finder);
    count++;
    trail.add(name);
    await tester.pumpAndSettle();
  }

  /// Types the address and the credentials of Connect by hand (typing is
  /// not a touch).
  Future<void> typeManual(String address) async {
    await tester.enterText(
      find.byKey(const ValueKey('manual-address')),
      address,
    );
    await tester.enterText(
      find.byKey(const ValueKey('manual-user')),
      HermesShapedServer.user,
    );
    await tester.enterText(
      find.byKey(const ValueKey('manual-password')),
      HermesShapedServer.pass,
    );
    await tester.pump();
  }
}

class Rig {
  Rig(this.manager, this.done, this.screen);
  final ConnectionManager manager;
  final List<int> done;
  final OnboardingScreen screen;
}

/// Pumps the onboarding on the welcome. [saved] is a connection that exists
/// before (for the https route).
Future<Rig> pumpWelcome(
  WidgetTester tester, {
  bool flag = true,
  OnboardingDiagnostics? diagnostics,
  bool savedHttps = false,
}) async {
  tester.view.physicalSize = const Size(800, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final manager = await onboardingManager();
  if (savedHttps) {
    await manager.upsertConnection(
      fakeFullPairing.toDraftConnection().copyWith(id: 'conn-a'),
    );
  }
  final done = <int>[];
  final screen = OnboardingScreen(
    connManager: manager,
    onDone: () => done.add(1),
    diagnostics: diagnostics ?? OnboardingDiagnostics(),
    playOpening: false,
    simpleConnectEnabled: flag,
    probe: fakeProbe,
    scanCode: (_) async => fakeFullPairing,
  );
  await tester.pumpWidget(onboardingHost(screen));
  await tester.pumpAndSettle();
  return Rig(manager, done, screen);
}

/// The fake Dashboard serves every HTTP client created inside [body].
Future<T> withDash<T>(Dash dash, Future<T> Function() body) {
  Dash.current = dash;
  return http.runWithClient(body, dash.newClient);
}

/// The whole Connect by hand route up to the saved connection: the address
/// of a Hermes-shaped server on this phone's loopback (no consent needed),
/// its credentials, and the form's own Connect. [saved] adds a connection
/// that exists before. Real sockets need real time, so it waits for the save.
Future<(Rig, Taps)> connectByHand(
  WidgetTester tester, {
  bool saved = false,
  bool flag = true,
  OnboardingDiagnostics? diagnostics,
  Future<void> Function(ConnectionManager)? before,
}) async {
  HttpOverrides.global = null;
  final server = (await tester.runAsync(HermesShapedServer.start))!;
  addTearDown(server.close);
  Dash.current!.auth = server;
  final rig = await pumpWelcome(
    tester,
    flag: flag,
    diagnostics: diagnostics,
    savedHttps: saved,
  );
  await before?.call(rig.manager);
  final taps = Taps(tester);
  await taps.key('onboarding-manual');
  await taps.typeManual(server.url);
  await taps.key('manual-connect');
  final before0 = saved ? 2 : 1;
  for (var i = 0; i < 200; i++) {
    if (rig.manager.getConnections().length >= before0) break;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump(const Duration(milliseconds: 25));
  }
  // The short pauses of the arrival run on the fake clock.
  // and a refresh of the session may need a real round trip.
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pumpAndSettle();
  return (rig, taps);
}
