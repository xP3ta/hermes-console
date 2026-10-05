// Per-file reset of the built-in memory files (MEMORY.md / USER.md) and the
// provider status. Fixtures are synthetic; no real server is involved.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/memory_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_local_models_server.dart' show fakeConnection;

const _status = {
  'active': 'honcho',
  'providers': [
    {
      'name': 'honcho',
      'description': 'Hosted memory',
      'available': true,
      'configured': true,
      'status': 'ready',
    },
    {
      'name': 'mem0',
      'description': 'Vector memory',
      'available': true,
      'configured': false,
      'status': 'needs_config',
    },
    {'name': 'legacy', 'description': 'Old provider', 'configured': false},
  ],
  'builtin_files': {'memory': 2048, 'user': 0},
};

class _Server {
  final requests = <http.Request>[];
  int resetStatus = 200;
  Map<String, Object?> resetBody = {
    'ok': true,
    'deleted': ['MEMORY.md'],
  };

  List<http.Request> get resets =>
      requests.where((r) => r.url.path == '/api/memory/reset').toList();
  List<http.Request> get reads => requests
      .where((r) => r.method == 'GET' && r.url.path == '/api/memory')
      .toList();

  DashboardClient get client => DashboardClient(
    host: 'hermes.local',
    port: 9119,
    manualToken: 'dashboard-token',
    httpClientOverride: MockClient((request) async {
      requests.add(
        http.Request(request.method, request.url)..body = request.body,
      );
      if (request.url.path == '/api/memory/reset') {
        return http.Response(jsonEncode(resetBody), resetStatus);
      }
      if (request.url.path == '/api/memory') {
        return http.Response(jsonEncode(_status), 200);
      }
      return http.Response('{}', 404);
    }),
  );
}

Future<void> _pump(
  WidgetTester tester,
  _Server server, {
  bool readOnly = false,
  String? profile,
}) async {
  tester.view.physicalSize = const Size(412, 2000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('es'),
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

Future<void> _openReset(WidgetTester tester, String file) async {
  await tester.tap(find.byKey(ValueKey('mem-file-more-$file')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('mem-file-reset')));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('MemoryInfo', () {
    test('parses provider status and availability', () {
      final info = MemoryInfo.fromJson(Map<String, dynamic>.from(_status));
      expect(info.providers[0].status, MemoryProviderStatus.ready);
      expect(info.providers[0].available, isTrue);
      expect(info.providers[1].status, MemoryProviderStatus.needsConfig);
    });

    test('tolerates absent, null and unknown values', () {
      final info = MemoryInfo.fromJson({
        'providers': [
          {'name': 'a', 'configured': true},
          {'name': 'b', 'status': null, 'available': null},
          {'name': 'c', 'status': 'from-the-future'},
        ],
      });
      for (final provider in info.providers) {
        expect(provider.status, MemoryProviderStatus.unknown);
        expect(provider.available, isNull);
      }
      expect(info.providers.first.configured, isTrue);
    });
  });

  testWidgets('provider tiles show the status when the server sends it', (
    tester,
  ) async {
    await _pump(tester, _Server());
    expect(find.text('Falta configurar'), findsOneWidget);
    // Unknown status keeps today's «configured» wording.
    expect(find.text('No configurado'), findsOneWidget);
  });

  testWidgets('reset asks first, sends an explicit default profile, re-reads', (
    tester,
  ) async {
    final server = _Server();
    await _pump(tester, server);
    expect(server.reads, hasLength(1));

    await _openReset(tester, 'memory');
    expect(server.resets, isEmpty);
    expect(find.textContaining('MEMORY.md'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('mem-reset-confirm')));
    await tester.pumpAndSettle();

    expect(server.resets, hasLength(1));
    final reset = server.resets.single;
    expect(reset.method, 'POST');
    expect(reset.url.queryParameters, {'profile': 'default'});
    expect(jsonDecode(reset.body), {'target': 'memory'});
    expect(server.reads, hasLength(2));
    expect(find.textContaining('MEMORY.md'), findsWidgets);
  });

  testWidgets('a named profile is passed as is', (tester) async {
    final server = _Server();
    await _pump(tester, server, profile: 'ana');
    await _openReset(tester, 'user');
    await tester.tap(find.byKey(const ValueKey('mem-reset-confirm')));
    await tester.pumpAndSettle();

    expect(server.resets.single.url.queryParameters, {'profile': 'ana'});
    expect(jsonDecode(server.resets.single.body), {'target': 'user'});
  });

  testWidgets('cancelling the confirmation sends nothing', (tester) async {
    final server = _Server();
    await _pump(tester, server);
    await _openReset(tester, 'memory');
    await tester.tap(find.byKey(const ValueKey('mem-reset-cancel')));
    await tester.pumpAndSettle();

    expect(server.resets, isEmpty);
    expect(server.reads, hasLength(1));
  });

  testWidgets('a server without the route hides the action afterwards', (
    tester,
  ) async {
    final server = _Server()..resetStatus = 404;
    await _pump(tester, server);
    await _openReset(tester, 'memory');
    await tester.tap(find.byKey(const ValueKey('mem-reset-confirm')));
    await tester.pumpAndSettle();

    expect(server.resets, hasLength(1));
    expect(find.byKey(const ValueKey('mem-file-more-memory')), findsNothing);
    expect(find.byKey(const ValueKey('mem-file-more-user')), findsNothing);
  });

  testWidgets('a read-only connection has no reset action', (tester) async {
    await _pump(tester, _Server(), readOnly: true);
    expect(find.byKey(const ValueKey('mem-file-more-memory')), findsNothing);
  });
}
