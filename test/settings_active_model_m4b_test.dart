// M4b — Ajustes › Chat › «Modelo activo» per profile, exercised through an existing boundary:
// the real SettingsScreen + _ActiveModelTile + DashboardClient over real loopback HTTP to a synthetic
// /api/model/info served in-test (no Hermes, no real data). Records what the tile shows for:
// Configuration reads only: these fixtures do not prove effective turn execution.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_android/core/screens/settings_screen.dart';

import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

// Prevent ModelsScreen from provisioning a bridge in the synthetic navigation.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global =
      null; // real loopback only; the fixture binds 127.0.0.1:0

  late HttpServer server;
  late ConnectionManager manager;
  late SavedConnection connection;
  final auxiliary = <String, (int, Map<String, dynamic>)>{};
  final gates = <String, Completer<void>>{};
  final requests = <String>[];
  // profile -> (status, body)
  final responses = <String, (int, Map<String, dynamic>)>{};

  setUp(() async {
    SharedPreferences.setMockInitialValues(const {});
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => call.method == 'readAll' ? <String, String>{} : null,
        );
    requests.clear();
    responses.clear();
    auxiliary.clear();
    gates.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final profile = req.uri.queryParameters['profile'] ?? 'default';
      requests.add('${req.uri.path}?profile=$profile');
      if (req.uri.path == '/') {
        // Synthetic dashboard shell: the token Console scrapes (cookieSession mode).
        req.response.headers.contentType = ContentType.html;
        req.response.write(
          '<script>window.__HERMES_SESSION_TOKEN__="synthetic-token";</script>',
        );
        await req.response.close();
        return;
      }
      final r = req.uri.path == '/api/model/info'
          ? (responses[profile] ?? (404, {'detail': 'unknown'}))
          : req.uri.path == '/api/model/auxiliary'
          ? (auxiliary[profile] ??
                (
                  200,
                  {
                    'main': {'model': 'aux-$profile', 'provider': 'prov'},
                  },
                ))
          : (404, {'detail': 'not served'});
      // Snapshot the bytes and gate when the request arrives (not at release).
      final gate = gates['${req.uri.path}:$profile'];
      if (gate != null) await gate.future;
      req.response.statusCode = r.$1;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(r.$2));
      await req.response.close();
    });
  });
  tearDown(() async => server.close(force: true));

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 30; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
  }

  String? subtitle() {
    final title = find.text('Modelo activo');
    expect(title, findsOneWidget, reason: 'tile visible');
    final row = find.ancestor(of: title, matching: find.byType(InkWell)).first;
    final texts = find
        .descendant(of: row, matching: find.byType(Text))
        .evaluate()
        .map((e) => (e.widget as Text).data ?? '')
        .where((t) => t.isNotEmpty && t != 'Modelo activo')
        .toList();
    return texts.isEmpty ? null : texts.join(' | ');
  }

  Future<String?> subtitleFor(WidgetTester tester, String profile) async {
    final prefs = await SharedPreferences.getInstance();
    manager = await ConnectionManager.create(prefs);
    connection = SavedConnection(
      id: 'm4b-$profile',
      label: 'Hermes',
      host: '127.0.0.1',
      port: 8642,
      apiKey: 'qa',
      dashboardUrl: 'http://127.0.0.1:${server.port}',
    );
    await manager.upsertConnection(connection);
    if (profile != 'default') {
      await manager.setActiveProfile(connection.id, profile);
    }
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: SettingsScreen(connection: connection, connManager: manager),
      ),
    );
    await tester.pump();
    final chat = find.byKey(const ValueKey('settings-category-chat'));
    expect(chat, findsOneWidget, reason: 'chat category');
    await tester.tap(chat);
    await settle(tester);
    return subtitle();
  }

  for (final area in ['info', 'auxiliary']) {
    for (final oldStatus in [200, 503]) {
      for (final latest in [
        'info',
        'empty',
        'auxiliary',
        'failed',
        'pending',
      ]) {
        testWidgets(
          'M4b reload ignores old $area $oldStatus with latest $latest',
          (tester) async {
            final oldInfo = Completer<void>();
            final oldAuxiliary = Completer<void>();
            gates['/api/model/info:bot-a'] = oldInfo;
            gates['/api/model/auxiliary:bot-a'] = oldAuxiliary;
            responses['bot-a'] = (
              area == 'info' ? oldStatus : 503,
              {'model': 'obsolete-info', 'provider': 'prov'},
            );
            auxiliary['bot-a'] = (
              area == 'auxiliary' ? oldStatus : 503,
              {
                'main': {'model': 'obsolete-auxiliary', 'provider': 'prov'},
              },
            );
            expect(await subtitleFor(tester, 'bot-a'), isNull);
            expect(requests, contains('/api/model/info?profile=bot-a'));
            expect(requests, contains('/api/model/auxiliary?profile=bot-a'));
            final nav = Navigator.of(
              tester.element(find.text('Modelo activo')),
            );
            await tester.tap(find.text('Modelo activo'));
            gates.clear();
            final newInfo = Completer<void>();
            final newAuxiliary = Completer<void>();
            if (latest == 'pending') {
              gates['/api/model/info:bot-a'] = newInfo;
              gates['/api/model/auxiliary:bot-a'] = newAuxiliary;
            }
            responses['bot-a'] = (
              latest == 'auxiliary' || latest == 'failed' ? 503 : 200,
              {
                'model': latest == 'empty' ? '' : 'fresh-info',
                'provider': 'prov',
              },
            );
            auxiliary['bot-a'] = (
              latest == 'failed' ? 503 : 200,
              {
                'main': {'model': 'fresh-auxiliary', 'provider': 'prov'},
              },
            );
            nav.pop();
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 500));
            await settle(tester);
            final expected = switch (latest) {
              'empty' => 'Sin modelo configurado',
              'auxiliary' => 'fresh-auxiliary',
              'failed' => 'No se pudieron cargar los modelos',
              'pending' => null,
              _ => 'fresh-info',
            };
            expect(subtitle(), expected);
            // Both generations crossed the HTTP boundary with the same profile.
            for (final source in ['info', 'auxiliary']) {
              expect(
                requests
                    .where((r) => r == '/api/model/$source?profile=bot-a')
                    .length,
                greaterThanOrEqualTo(2),
              );
            }
            // Each obsolete settlement is checked separately, including failure.
            final first = area == 'info' ? oldInfo : oldAuxiliary;
            final second = area == 'info' ? oldAuxiliary : oldInfo;
            first.complete();
            await settle(tester);
            expect(subtitle(), expected, reason: 'old $area cannot publish');
            second.complete();
            await settle(tester);
            expect(
              subtitle(),
              expected,
              reason: 'obsolete load cannot settle status',
            );
            if (latest == 'pending') {
              newAuxiliary.complete();
              await settle(tester);
              expect(subtitle(), 'fresh-auxiliary');
              newInfo.complete();
              await settle(tester);
              expect(subtitle(), 'fresh-info');
            }
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }

  testWidgets(
    'M4b present: profile model shown (and requested with its own profile)',
    (tester) async {
      responses['bot-a'] = (
        200,
        {'model': 'model-of-bot-a', 'provider': 'prov'},
      );
      final s = await subtitleFor(tester, 'bot-a');
      debugPrint('M4B_RESULT present subtitle=$s requests=$requests');
      expect(requests, contains('/api/model/info?profile=bot-a'));
      expect(s, contains('model-of-bot-a'));
    },
  );

  testWidgets(
    'M4b 200 empty: «sin modelo configurado» must be distinguishable',
    (tester) async {
      responses['bot-b'] = (200, {'model': '', 'provider': ''});
      final s = await subtitleFor(tester, 'bot-b');
      debugPrint('M4B_RESULT empty subtitle=$s requests=$requests');
      expect(s, 'Sin modelo configurado');
      expect(s, isNot(contains('aux-')));
    },
  );

  testWidgets('M4b parallel auxiliary resolves while info is held', (
    tester,
  ) async {
    final gate = Completer<void>();
    gates['/api/model/info:bot-a'] = gate;
    responses['bot-a'] = (200, {'model': '', 'provider': ''});
    expect(await subtitleFor(tester, 'bot-a'), 'aux-bot-a');
    expect(requests, contains('/api/model/auxiliary?profile=bot-a'));
    gate.complete();
    await settle(tester);
    // A successful empty info overrides the provisional config fallback.
    expect(subtitle(), 'Sin modelo configurado');
  });

  for (final infoStatus in [200, 500]) {
    for (final auxiliaryStatus in [200, 503]) {
      testWidgets('M4b held info $infoStatus with auxiliary $auxiliaryStatus', (
        tester,
      ) async {
        final gate = Completer<void>();
        gates['/api/model/info:bot-a'] = gate;
        responses['bot-a'] = (
          infoStatus,
          {'model': 'info-a', 'provider': 'prov'},
        );
        auxiliary['bot-a'] = auxiliaryStatus == 200
            ? (
                200,
                {
                  'main': {'model': 'aux-a', 'provider': 'prov'},
                },
              )
            : (503, {'detail': 'unavailable'});
        expect(
          await subtitleFor(tester, 'bot-a'),
          auxiliaryStatus == 200 ? 'aux-a' : isNull,
        );
        expect(requests, contains('/api/model/auxiliary?profile=bot-a'));
        gate.complete();
        await settle(tester);
        expect(
          subtitle(),
          infoStatus == 200
              ? 'info-a'
              : auxiliaryStatus == 200
              ? 'aux-a'
              : 'No se pudieron cargar los modelos',
        );
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final infoModel in ['', 'info-a']) {
    for (final auxiliaryStatus in [200, 503]) {
      testWidgets(
        'M4b info "$infoModel" independent of held auxiliary $auxiliaryStatus',
        (tester) async {
          final gate = Completer<void>();
          gates['/api/model/auxiliary:bot-a'] = gate;
          responses['bot-a'] = (200, {'model': infoModel, 'provider': 'prov'});
          auxiliary['bot-a'] = auxiliaryStatus == 200
              ? (
                  200,
                  {
                    'main': {'model': 'aux-a', 'provider': 'prov'},
                  },
                )
              : (503, {'detail': 'unavailable'});
          final expected = infoModel.isEmpty
              ? 'Sin modelo configurado'
              : infoModel;
          expect(await subtitleFor(tester, 'bot-a'), expected);
          expect(requests, contains('/api/model/auxiliary?profile=bot-a'));
          gate.complete();
          await settle(tester);
          expect(subtitle(), expected);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'M4b invalid auxiliary cannot confirm absence while info pending',
    (tester) async {
      final gate = Completer<void>();
      gates['/api/model/info:bot-a'] = gate;
      responses['bot-a'] = (200, {'model': '', 'provider': ''});
      auxiliary['bot-a'] = (200, {'tasks': []});
      expect(await subtitleFor(tester, 'bot-a'), isNull);
      gate.complete();
      await settle(tester);
      expect(subtitle(), 'Sin modelo configurado');
    },
  );

  testWidgets('M4b HTTP error uses auxiliary main of the same profile', (
    tester,
  ) async {
    responses['bot-c'] = (500, {'detail': 'boom'});
    final s = await subtitleFor(tester, 'bot-c');
    debugPrint('M4B_RESULT error subtitle=$s requests=$requests');
    expect(s, 'aux-bot-c');
    expect(requests, contains('/api/model/auxiliary?profile=bot-c'));
    expect(
      requests
          .where((r) => r.startsWith('/api/model/'))
          .any((r) => r.endsWith('profile=default')),
      isFalse,
    );
  });

  testWidgets('M4b failed info without auxiliary main shows lookup failure', (
    tester,
  ) async {
    responses['bot-c'] = (500, {'detail': 'boom'});
    auxiliary['bot-c'] = (200, {'tasks': []});
    expect(
      await subtitleFor(tester, 'bot-c'),
      'No se pudieron cargar los modelos',
    );
  });

  testWidgets('M4b both reads fail without inventing configured absence', (
    tester,
  ) async {
    responses['bot-c'] = (500, {'detail': 'boom'});
    auxiliary['bot-c'] = (503, {'detail': 'unavailable'});
    expect(
      await subtitleFor(tester, 'bot-c'),
      'No se pudieron cargar los modelos',
    );
  });

  testWidgets('M4b empty auxiliary main confirms configured absence', (
    tester,
  ) async {
    responses['bot-c'] = (500, {'detail': 'boom'});
    auxiliary['bot-c'] = (
      200,
      {
        'main': {'model': '', 'provider': ''},
      },
    );
    expect(await subtitleFor(tester, 'bot-c'), 'Sin modelo configurado');
  });

  for (final lateStatus in [200, 500]) {
    testWidgets('M4b ignores late info $lateStatus after A to B', (
      tester,
    ) async {
      final gate = Completer<void>();
      gates['/api/model/info:bot-a'] = gate;
      responses['bot-a'] = (
        lateStatus,
        {'model': 'obsolete-a', 'provider': 'prov'},
      );
      responses['bot-b'] = (200, {'model': 'current-b', 'provider': 'prov'});
      expect(await subtitleFor(tester, 'bot-a'), 'aux-bot-a');
      expect(requests, contains('/api/model/info?profile=bot-a'));
      await manager.setActiveProfile(connection.id, 'bot-b');
      await settle(tester);
      expect(subtitle(), 'current-b');
      gate.complete();
      await settle(tester);
      expect(subtitle(), 'current-b');
      expect(requests, contains('/api/model/auxiliary?profile=bot-a'));
    });
  }

  for (final area in ['info', 'auxiliary']) {
    testWidgets('M4b drops stale $area on A B A and does not reuse model cache', (
      tester,
    ) async {
      final gate = Completer<void>();
      gates['/api/model/$area:bot-a'] = gate;
      responses['bot-a'] = (
        area == 'info' ? 200 : 500,
        {'model': 'obsolete-a', 'provider': 'prov'},
      );
      auxiliary['bot-a'] = (
        200,
        {
          'main': {'model': 'obsolete-aux-a', 'provider': 'prov'},
        },
      );
      responses['bot-b'] = (200, {'model': 'current-b', 'provider': 'prov'});
      expect(
        await subtitleFor(tester, 'bot-a'),
        area == 'info' ? 'obsolete-aux-a' : isNull,
      );
      expect(requests, contains('/api/model/$area?profile=bot-a'));
      await manager.setActiveProfile(connection.id, 'bot-b');
      await settle(tester);
      expect(subtitle(), 'current-b');
      gates.remove('/api/model/$area:bot-a');
      responses['bot-a'] = (200, {'model': 'fresh-a', 'provider': 'prov'});
      await manager.setActiveProfile(connection.id, 'bot-a');
      // The previous profile must clear synchronously before a new read settles.
      await tester.pump();
      expect(subtitle(), isNot('current-b'));
      await settle(tester);
      expect(subtitle(), 'fresh-a');
      gate.complete();
      await settle(tester);
      expect(subtitle(), 'fresh-a');
      expect(
        requests.where((r) => r == '/api/model/info?profile=bot-a').length,
        2,
      );
      expect(
        requests
            .where((r) => r.startsWith('/api/model/'))
            .any((r) => r.endsWith('profile=default')),
        isFalse,
      );
    });
  }
}
