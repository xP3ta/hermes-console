import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/session_detail_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/shared_gateway_pool.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'hermes_fixture.dart';

class _RealHttp extends HttpOverrides {}

/// The child is read with `getSession` (Dashboard read); any
/// HTTP call here would be the removed Gateway `/fork` path.
class _Api extends ApiClient {
  _Api(this.log)
    : super(
        baseUrl: 'http://127.0.0.1:1',
        apiKey: 'fixture-key',
        httpClient: MockClient((r) async {
          log.add('HTTP ${r.method} ${r.url.path}');
          return http.Response('{}', 404);
        }),
      );
  final List<String> log;

  @override
  Future<Session> getSession(String id, {String? profile}) async {
    log.add('getSession $id $profile');
    return _session(id, 'Child copy', profile);
  }
}

Session _session(String id, String title, [String? profile]) => Session(
  id: id,
  title: title,
  model: 'm',
  source: 'mobile',
  messageCount: 3,
  isActive: false,
  preview: '',
  startedAt: 1,
  profile: profile,
);

void main() {
  late FakeHermes hermes;
  late List<String> log;

  Future<void> pump(
    WidgetTester tester, {
    String? profile,
    bool readOnly = false,
    bool sameHost = false,
  }) async {
    HttpOverrides.global = _RealHttp();
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (_) async => null,
        );
    if (!sameHost) {
      hermes = (await tester.runAsync(FakeHermes.start))!;
      hermes.results['session.branch_stored'] = {
        'session_id': 'runtime-child',
        'stored_session_id': 'child-stored',
        'message_count': 3,
      };
      log = [];
      addTearDown(hermes.close);
    }
    addTearDown(() => HttpOverrides.global = null);
    await tester.pumpWidget(const SizedBox()); // drop any route left open
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: SessionDetailScreen(
          connection: SavedConnection(
            id: 'branch-fixture-$profile',
            label: 'Fixture',
            host: '127.0.0.1',
            port: hermes.port,
            apiKey: 'fixture-key',
            dashboardUrl: 'http://127.0.0.1:${hermes.port}',
            kind: InstanceKind.vps,
            readOnly: readOnly,
          ),
          session: Session(
            id: 'parent-stored',
            title: 'Parent',
            model: 'm',
            source: 'mobile',
            messageCount: 3,
            isActive: false,
            preview: '',
            startedAt: 1,
            profile: profile,
          ),
          client: _Api(log),
          skipInitialSessionRefresh: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Real sockets and the fake-async zone take turns until [done] holds.
  Future<void> until(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 400 && !done(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
    }
    expect(done(), isTrue, reason: 'paths=${hermes.paths} log=$log');
    await tester.pumpAndSettle();
  }

  Future<void> duplicate(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('session-detail-duplicate')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('session-detail-duplicate-confirm')),
    );
    await tester.pump();
  }

  List<Map> branches() => [
    for (final f in hermes.rpc('session.branch_stored')) f['params'] as Map,
  ];
  final opened = find.byWidgetPredicate(
    (w) => w is SessionDetailScreen && w.session.id == 'child-stored',
  );

  void scenario(String name, Future<void> Function(WidgetTester) body) =>
      testWidgets(name, (tester) async {
        await body(tester);
        // The duplicate path never keeps its lease, whatever the outcome.
        expect(SharedGatewayPool.instance.leaseCount, 0);
        SharedGatewayPool.instance.disconnectIdle(); // its keep-alive timers
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump(const Duration(seconds: 30));
      });

  for (final profile in [null, 'work']) {
    scenario(
      'duplicate profile=$profile: one session.branch_stored, child opened',
      (tester) async {
        await pump(tester, profile: profile);
        await duplicate(tester);
        await until(tester, () => log.any((l) => l.startsWith('getSession')));
        final params = branches().single;
        expect(params, containsPair('parent_session_id', 'parent-stored'));
        expect(params['idempotency_key'], startsWith('branch-'));
        expect(params, containsPair('cols', 96));
        expect(params['profile'], profile);
        expect(params.containsKey('profile'), profile != null);
        expect(log, [
          'getSession child-stored $profile',
        ]); // no forkSession, no HTTP
        expect(hermes.restHits, isEmpty);
        expect(opened, findsOneWidget);
      },
    );
  }

  scenario('a lost response and a retry reuse the same key', (tester) async {
    await pump(tester);
    hermes.lostOnce.add('session.branch_stored');
    await duplicate(tester);
    await until(tester, () => branches().isNotEmpty);
    await tester.pump(const Duration(seconds: 61)); // the lost answer times out
    await tester.pumpAndSettle();
    await duplicate(tester);
    await until(tester, () => log.isNotEmpty);
    expect(branches().map((p) => p['idempotency_key']).toSet(), hasLength(1));
    expect(branches(), hasLength(2));
  });

  scenario('after a success the next duplicate uses a new key', (tester) async {
    await pump(tester);
    await duplicate(tester);
    await until(tester, () => log.length == 1);
    await pump(tester, sameHost: true); // the parent again, same server
    await duplicate(tester);
    await until(tester, () => log.length == 2);
    final keys = branches().map((p) => p['idempotency_key']).toList();
    expect(keys, hasLength(2));
    expect(keys.toSet(), hasLength(2));
  });

  for (final code in [-32601, 5000]) {
    scenario('error $code: sesDuplicateFailed, no navigation, no fallback', (
      tester,
    ) async {
      await pump(tester);
      hermes.errors['session.branch_stored'] = code;
      await duplicate(tester);
      await until(tester, () => branches().isNotEmpty);
      final s = await Strings.delegate.load(const Locale('es'));
      expect(
        find.textContaining(s.sesDuplicateFailed('').trim()),
        findsWidgets,
      );
      expect(log, isEmpty);
      expect(hermes.rpc('session.create'), isEmpty);
      expect(opened, findsNothing);
    });
  }

  scenario('read-only: no duplicate action, 0 RPC', (tester) async {
    await pump(tester, readOnly: true);
    expect(
      find.byKey(const ValueKey('session-detail-duplicate')),
      findsNothing,
    );
    expect(hermes.frames, isEmpty);
  });
}
