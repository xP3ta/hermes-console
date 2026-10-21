import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_active_session.dart';
import 'package:hermes_android/core/screens/home_dashboard_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/global_activity_aggregate.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/instance_status_panel.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _QuietClient extends ApiClient {
  _QuietClient()
    : super(
        baseUrl: 'http://127.0.0.1:8642',
        apiKey: 'test-key',
        httpClient: MockClient((_) async => http.Response('{}', 404)),
      );

  @override
  Future<bool> healthCheck() async => true;

  @override
  Future<bool> healthReachable() => healthCheck();

  @override
  Future<List<Session>> getSessions({
    bool includeChildren = false,
    String? profile,
    int pageSize = 200,
    bool Function(List<Session> sessions)? enough,
    int? maxPages,
  }) async => <Session>[];

  @override
  void close() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final secureValues = <String, String>{};
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, (call) async {
          final args = call.arguments is Map
              ? Map<Object?, Object?>.from(call.arguments as Map)
              : const <Object?, Object?>{};
          switch (call.method) {
            case 'write':
              secureValues[args['key'] as String] = args['value'] as String;
              return null;
            case 'read':
              return secureValues[args['key']];
            case 'readAll':
              return Map<String, String>.of(secureValues);
            case 'delete':
              secureValues.remove(args['key']);
              return null;
          }
          return null;
        });
  });

  tearDown(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, null);
  });

  testWidgets('a roster read that fails after Home is disposed arms no timer '
      'and does not mark the shared activity stale', (tester) async {
    final manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    await manager.saveConnection(
      'QA',
      '127.0.0.2',
      8642,
      'test-key',
      kind: InstanceKind.vps,
    );
    final connection = manager.getConnections().single;
    await manager.setActiveConnection(connection.id);
    final profile = Session.profileOwner(
      manager.activeProfileFor(connection.id),
    );

    // One live session already known for this connection: a late stale mark
    // would flip it, so the aggregate can tell whether Home touched it.
    final aggregate = GlobalActivityAggregate.inMemory();
    addTearDown(aggregate.dispose);
    aggregate.applyRoster(
      connectionId: connection.id,
      profile: profile,
      replayEpoch: 'epoch',
      requestGeneration: aggregate.beginRosterRequest(connection.id, profile),
      roster: const DesktopActiveSessionList(
        sessions: [
          DesktopActiveSession(
            runtimeSessionId: 'runtime-1',
            storedSessionId: 'stored-1',
            status: 'working',
          ),
        ],
      ),
    );
    expect(aggregate.activities.where((a) => a.stale), isEmpty);
    expect(aggregate.activities, hasLength(1));

    final rosterRead = Completer<DesktopActiveSessionList>();
    var rosterReads = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: HomeDashboardScreen(
          connManager: manager,
          clientFactory: (_) => _QuietClient(),
          dashboardAuthProbe: (_) async => DashboardAuthCheck.ok,
          globalActivityOverride: aggregate,
          activeSessionListLoader: () {
            rosterReads++;
            return rosterRead.future;
          },
        ),
      ),
    );
    for (var attempt = 0; attempt < 40 && rosterReads == 0; attempt++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(
      rosterReads,
      greaterThan(0),
      reason: 'Home must have asked the roster',
    );

    // Leave Home with the roster read still in flight, then let it fail.
    await tester.pumpWidget(const SizedBox.shrink());
    rosterRead.completeError(StateError('roster read cut by the dispose'));
    await tester.pump();

    expect(
      aggregate.activities.where((a) => a.stale),
      isEmpty,
      reason: 'a disposed Home must not mark the shared activity stale',
    );
    // The binding fails the test at its end if the 60 s stale-expiry Timer
    // (or any other) is still pending after the tree was disposed.
  });
}
