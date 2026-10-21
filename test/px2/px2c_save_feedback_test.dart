// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab

// PX2c: "Save" says it is checking, a refused Dashboard sign-in offers to
// sign in again, and the status line never claims the chat is connected
// without the Dashboard. Real loopback Dashboard (PX1 fake) and real
// ConnectionDiagnostics; flag off keeps today's texts.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/instance_edit_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/native_session_store.dart';
import 'package:hermes_android/core/widgets/hermes_ui.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import '../support/onboarding_fakes.dart';
import '../support/px1_fake_dashboard.dart';

class _Browser extends UrlLauncherPlatform {
  _Browser(this.open);
  final Future<bool> Function(Uri) open;
  @override
  LinkDelegate? get linkDelegate => null;
  @override
  Future<bool> launchUrl(String url, LaunchOptions options) =>
      open(Uri.parse(url));
}

class _Store implements NativeEnvelopeStore {
  final raw = <String, String>{};
  @override
  Future<String?> read(String id) async => raw[id];
  @override
  Future<void> writeDurable(String id, String v) async => raw[id] = v;
  @override
  Future<void> delete(String id) async => raw.remove(id);
}

/// The PX1 fake refuses everything without its Bearer, /api/health included;
/// a real Dashboard answers health to anyone. This front adds that route and
/// forwards the rest to the fake untouched.
class _Front {
  _Front(this.fake);
  final Px1FakeDashboard fake;
  late final HttpServer _server;
  String get base => 'http://127.0.0.1:${_server.port}';
  int get port => _server.port;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => _server.close(force: true));
    _server.listen((r) async {
      if (r.uri.path == '/api/health') {
        r.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'status': 'ok', 'version': '0.22.0'}));
        return r.response.close();
      }
      final body = BytesBuilder();
      await r.forEach(body.add);
      final client = HttpClient();
      final out = await client.openUrl(
        r.method,
        Uri.parse('${fake.base}${r.uri.path}'),
      );
      r.headers.forEach((k, v) {
        if (k != 'host') out.headers.set(k, v);
      });
      out.add(body.takeBytes());
      final res = await out.close();
      r.response
        ..statusCode = res.statusCode
        ..headers.contentType = ContentType.json;
      await res.pipe(r.response);
      client.close();
    });
  }
}

const _signedOut =
    'No se pudo comprobar el acceso al Dashboard. Entra de nuevo para guardar.';
const _missingSimple =
    'Falta entrar en el Dashboard. Sin eso Console no puede abrir el chat ni tus conversaciones.';
const _missingToday =
    'Falta entrar en el Dashboard para usar el chat, las tareas, los perfiles y la memoria.';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Store nativeStore;
  setUp(() {
    HttpOverrides.global = null;
    nativeStore = _Store();
    NativeSessionCoordinator.replaceInstanceForTesting(
      NativeSessionCoordinator(store: nativeStore),
    );
  });
  tearDown(() => NativeSessionCoordinator.replaceInstanceForTesting(null));

  Future<void> until(WidgetTester t, bool Function() done) async {
    for (var i = 0; i < 200 && !done(); i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await t.pump(const Duration(milliseconds: 50));
    }
  }

  // The editor sits on a launcher route so pop(true) is observable.
  Future<(ConnectionManager, Px1FakeDashboard, List<bool?>)> open(
    WidgetTester t, {
    required bool flag,
    String theme = 'dark',
    double scale = 1,
  }) async {
    final server = Px1FakeDashboard();
    final front = _Front(server);
    await t.runAsync(() async {
      await server.start();
      await front.start();
    });
    UrlLauncherPlatform.instance = _Browser(server.browse);
    final manager = await onboardingManager();
    final results = <bool?>[];
    await t.pumpWidget(
      onboardingHost(
        theme: theme,
        scale: scale,
        Builder(
          builder: (context) => TextButton(
            key: const ValueKey('open-editor'),
            onPressed: () async => results.add(
              await Navigator.of(context).push<bool>(
                MaterialPageRoute(
                  builder: (_) => InstanceEditScreen(
                    connManager: manager,
                    prefill: SavedConnection(
                      id: 'px2c',
                      label: 'Px2c',
                      host: '127.0.0.1',
                      port: front.port,
                      apiKey: '',
                      dashboardUrl: front.base,
                      dashboardAuthMode: AuthMode.sessionToken,
                    ),
                    verifyChatBeforeSave: true,
                    simpleConnect: flag,
                  ),
                ),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await t.tap(find.byKey(const ValueKey('open-editor')));
    await t.pumpAndSettle();
    return (manager, server, results);
  }

  Finder text(String s) => find.text(s);
  Finder save() => find.byKey(const ValueKey('instance-save'));
  Finder again() => find.byKey(const ValueKey('instance-sign-in-again'));
  bool saveEnabled(WidgetTester t) =>
      t.widget<HermesPrimaryButton>(save()).onTap != null;

  testWidgets('(1) a refused sign-in: Checking…, then banner + sign in again', (
    t,
  ) async {
    final (manager, _, _) = await open(t, flag: true);
    expect(saveEnabled(t), isTrue);
    await t.tap(save());
    await t.pump();
    expect(text('Comprobando…'), findsOneWidget);
    expect(saveEnabled(t), isFalse);
    await until(t, () => again().evaluate().isNotEmpty);
    expect(text(_signedOut), findsOneWidget);
    expect(again(), findsOneWidget);
    expect(text('Guardar'), findsOneWidget);
    expect(saveEnabled(t), isTrue);
    expect(manager.getConnections(), isEmpty);
    expect(nativeStore.raw, isEmpty);
  });

  testWidgets('(2) sign in again ends saved and popped', (t) async {
    final (manager, server, results) = await open(t, flag: true);
    await t.tap(save());
    await until(t, () => again().evaluate().isNotEmpty);
    await t.tap(again());
    final browser = find.byKey(const ValueKey('dashboard-oauth-browser'));
    await until(t, () => browser.evaluate().isNotEmpty);
    await t.tap(browser);
    await until(t, () => results.isNotEmpty);
    expect(results, [true]);
    expect(manager.getConnections(), hasLength(1));
    expect(server.sessionsWithBearer, greaterThan(0));
  });

  testWidgets('(3) status line never says the chat is connected', (t) async {
    await open(t, flag: true);
    await t.tap(find.byKey(const ValueKey('instance-test')));
    final status = find.byKey(const ValueKey('instance-connection-status'));
    await until(t, () => (t.widget<Text>(status).data ?? '') == _missingSimple);
    final shown = t.widget<Text>(status).data!;
    expect(shown, _missingSimple);
    expect(shown.toLowerCase(), isNot(contains('chat está conectado')));
  });

  testWidgets('(4) flag off: today\'s texts and no sign-in action', (t) async {
    await open(t, flag: false);
    await t.tap(save());
    await t.pump();
    expect(text('Comprobando…'), findsNothing);
    expect(text('Guardar'), findsOneWidget);
    await until(t, () => text(_missingToday).evaluate().isNotEmpty);
    expect(text(_missingToday), findsWidgets);
    expect(text(_signedOut), findsNothing);
    expect(again(), findsNothing);
  });

  testWidgets('(5) banner is a live region, the action is labelled', (t) async {
    final handle = t.ensureSemantics();
    await open(t, flag: true);
    await t.tap(save());
    await until(t, () => again().evaluate().isNotEmpty);
    final banner = t.getSemantics(text(_signedOut));
    expect(banner.getSemanticsData().flagsCollection.isLiveRegion, isTrue);
    expect(t.getSemantics(again()).label, contains('Entrar de nuevo'));
    handle.dispose();
  });

  for (final theme in ['light', 'dark']) {
    testWidgets('(6) $theme at text scale 2.0 does not overflow', (t) async {
      t.view.physicalSize = const Size(800, 1800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await open(t, flag: true, theme: theme, scale: 2);
      await t.tap(save());
      await until(t, () => again().evaluate().isNotEmpty);
      expect(again(), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  }
}
