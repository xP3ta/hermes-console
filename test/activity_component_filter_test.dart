// Logs: the component and profile filters go to the server; what is copied
// stays what the server sent.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/screens/activity_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _Read {
  const _Read({this.file, this.level, this.component, this.profile});

  final String? file;
  final String? level;
  final String? component;
  final String? profile;
}

class _FakeLogs extends DashboardClient {
  _FakeLogs({this.profiles = const ['default', 'work']})
    : super(
        host: 'logs.example.test',
        manualToken: 'token',
        httpClientOverride: MockClient((_) async => http.Response('{}', 500)),
      );

  final List<String> profiles;
  final reads = <_Read>[];
  Object? error;

  @override
  Future<List<String>> getLogs({
    String file = 'agent',
    int lines = 200,
    String? level,
    String? search,
    String? component,
    String? profile,
  }) async {
    reads.add(
      _Read(file: file, level: level, component: component, profile: profile),
    );
    final failure = error;
    if (failure != null) throw failure;
    if (component == 'tools') return const [];
    if (component == 'cron') {
      return ['2026-06-11 03:31:41,093 INFO cron.jobs: tick'];
    }
    return [
      '2026-06-11 03:31:40,000 INFO gateway.run: first',
      '2026-06-11 03:31:41,093 ERROR agent.loop: second',
    ];
  }

  @override
  Future<List<AgentProfile>> getProfiles() async => [
    for (final name in profiles)
      AgentProfile.fromJson({'name': name, 'is_default': name == 'default'}),
  ];
}

Future<void> _pump(WidgetTester tester, _FakeLogs client) async {
  // Wide enough for the file selector row, which the test font overflows.
  tester.view.physicalSize = const Size(520, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.fromId('dark'),
      home: ActivityScreen(
        connection: SavedConnection(
          id: 'logs',
          label: 'QA',
          host: 'logs.example.test',
          port: 8642,
          apiKey: '',
          useHttps: true,
        ),
        clientOverride: client,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tapKey(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('with no filter nothing extra is asked of the server', (
    tester,
  ) async {
    final client = _FakeLogs();
    await _pump(tester, client);
    expect(client.reads.single.component, isNull);
    expect(client.reads.single.profile, isNull);
    expect(find.text('first'), findsOneWidget);
  });

  testWidgets('choosing a component reads the log with it, "all" clears it', (
    tester,
  ) async {
    final client = _FakeLogs();
    await _pump(tester, client);

    await _tapKey(tester, 'logs-component-cron');
    expect(client.reads.last.component, 'cron');
    expect(find.text('tick'), findsOneWidget);
    expect(find.text('first'), findsNothing);

    await _tapKey(tester, 'logs-component-all');
    expect(client.reads.last.component, isNull);
    expect(find.text('first'), findsOneWidget);
  });

  testWidgets('only the ids the server knows are offered', (tester) async {
    await _pump(tester, _FakeLogs());
    for (final id in ['gateway', 'agent', 'tools', 'cli', 'cron', 'gui']) {
      expect(find.byKey(ValueKey('logs-component-$id')), findsOneWidget);
    }
  });

  testWidgets('a component with no lines says which one is empty', (
    tester,
  ) async {
    final client = _FakeLogs();
    await _pump(tester, client);
    final s = await Strings.delegate.load(const Locale('es'));
    client.reads.clear();
    await _tapKey(tester, 'logs-component-tools');
    expect(client.reads.single.component, 'tools');
    expect(find.text('first'), findsNothing);
    expect(find.textContaining(s.kluLogForComponent('tools')), findsOneWidget);
  });

  testWidgets('with several profiles a profile can be chosen', (tester) async {
    final client = _FakeLogs();
    await _pump(tester, client);
    await _tapKey(tester, 'logs-profile-work');
    expect(client.reads.last.profile, 'work');
    await _tapKey(tester, 'logs-profile-all');
    expect(client.reads.last.profile, isNull);
  });

  testWidgets('with one profile there is nothing to choose', (tester) async {
    await _pump(tester, _FakeLogs(profiles: const ['default']));
    expect(find.byKey(const ValueKey('logs-profile-all')), findsNothing);
    expect(find.byKey(const ValueKey('logs-component-all')), findsOneWidget);
  });

  testWidgets('the filter buttons are 48 dp targets', (tester) async {
    await _pump(tester, _FakeLogs());
    for (final key in ['logs-component-all', 'logs-profile-work']) {
      expect(
        tester.getSize(find.byKey(ValueKey(key))).height,
        greaterThanOrEqualTo(48),
        reason: key,
      );
    }
  });

  testWidgets('copying a line copies the line the server sent and no more', (
    tester,
  ) async {
    final copied = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    final client = _FakeLogs();
    await _pump(tester, client);
    await _tapKey(tester, 'logs-component-gateway');
    await _tapKey(tester, 'logs-profile-work');

    await tester.longPress(find.text('first'));
    await tester.pump();
    expect(copied, ['2026-06-11 03:31:40,000 INFO gateway.run: first']);
    expect(copied.single, isNot(contains('work')));
    expect(copied.single, isNot(contains('logs.example.test')));
  });

  testWidgets('a failed read with a filter shows the error and can retry', (
    tester,
  ) async {
    final client = _FakeLogs();
    await _pump(tester, client);
    client.error = const DashboardHttpException(400);
    await _tapKey(tester, 'logs-component-cron');
    final s = await Strings.delegate.load(const Locale('es'));
    expect(find.text(s.actLogsReadError), findsOneWidget);
    client.error = null;
    await tester.tap(find.text(s.commonRetry));
    await tester.pumpAndSettle();
    expect(find.text('tick'), findsOneWidget);
  });

  test('over the wire the query carries component and profile', () async {
    final seen = <Uri>[];
    final client = DashboardClient(
      host: 'logs.example.test',
      manualToken: 'token',
      httpClientOverride: MockClient((request) async {
        seen.add(request.url);
        return http.Response('{"file":"agent","lines":["x"]}', 200);
      }),
    );
    await client.getLogs();
    await client.getLogs(component: 'cron', profile: 'work');
    await client.getLogs(component: '', profile: 'default');
    client.close();
    final logs = seen.where((u) => u.path == '/api/logs').toList();
    expect(logs[0].queryParameters.containsKey('component'), isFalse);
    expect(logs[0].queryParameters.containsKey('profile'), isFalse);
    expect(logs[1].queryParameters['component'], 'cron');
    expect(logs[1].queryParameters['profile'], 'work');
    expect(logs[2].queryParameters.containsKey('component'), isFalse);
    expect(logs[2].queryParameters.containsKey('profile'), isFalse);
  });
}
