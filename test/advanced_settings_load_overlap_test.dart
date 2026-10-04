// Settings › Advanced loads the schema, the toolsets and the Diagnostics probe
// as one batch. A pull to refresh while a batch is pending joins that batch:
// no second set of reads, and no older answer published after a newer one.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/capabilities/capabilities_repository.dart';
import 'package:hermes_android/core/screens/advanced_settings_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/server_config_repository.dart';
import 'package:hermes_android/core/services/server_toolsets_repository.dart';
import 'package:hermes_android/core/settings/settings_deep_link.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'capabilities/capabilities_fakes.dart';
import 'support/fake_toolsets_server.dart';

/// Every schema read waits for the test to answer it, in any order.
final class _GatedStore implements ServerConfigStore {
  final List<Completer<Map<String, dynamic>>> reads = [];

  @override
  bool get isWritable => true;

  @override
  Future<Map<String, dynamic>> readConfig() async => {};

  @override
  Future<Map<String, dynamic>> readSchema() {
    final read = Completer<Map<String, dynamic>>();
    reads.add(read);
    return read.future;
  }

  @override
  Future<Object?> save(String path, Object? value) async => value;
}

Map<String, dynamic> _schema(String field) => {
  'fields': {
    field: {'type': 'string'},
  },
};

ScriptedRest _server({required bool doctor}) {
  final rest = ScriptedRest()
    ..gets['health'] = {'ok': true, 'version': '1'}
    ..gets['health/idle'] = {'ok': true, 'idle': true};
  if (doctor) {
    rest.gets['actions/doctor/status'] = {
      'name': 'doctor',
      'running': false,
      'exit_code': 0,
      'lines': <String>[],
    };
  }
  return rest;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const id = 'conn-adv-overlap';
  late ConnectionManager manager;
  late FakeToolsetsServer toolsets;
  late _GatedStore store;
  late Map<String, ScriptedRest> rests;

  setUp(() async {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => call.method == 'readAll' ? <String, String>{} : null,
        );
    SharedPreferences.setMockInitialValues({});
    manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    toolsets = FakeToolsetsServer()..toolsets = [];
    store = _GatedStore();
    rests = {'': _server(doctor: false), 'work': _server(doctor: true)};
  });

  tearDown(() {
    SettingsDeepLink.pending.value = null;
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          null,
        );
  });

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: const Scaffold(body: Text('Settings')),
      ),
    );
    tester
        .state<NavigatorState>(find.byType(Navigator))
        .push(
          MaterialPageRoute<void>(
            builder: (_) => AdvancedSettingsScreen(
              connection: SavedConnection(
                id: id,
                label: 'Adv QA',
                host: 'hermes.example.test',
                port: 8642,
                apiKey: '',
                dashboardUrl: 'http://hermes.example.test:9119',
              ),
              connManager: manager,
              storeFor: (profile, {required writable}) => store,
              toolsetsFor: (profile, {required writable}) =>
                  ServerToolsetsRepository(
                    toolsets.dashboard,
                    profile: profile,
                    writable: writable,
                  ),
              repositoryFor: (profile) => CapabilitiesRepository(
                rest: rests[profile]!,
                profile: profile,
                sleep: (_) async {},
                actionPollInterval: Duration.zero,
              ),
            ),
          ),
        );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> pullToRefresh(WidgetTester tester) async {
    unawaited(
      tester
          .state<RefreshIndicatorState>(find.byType(RefreshIndicator).first)
          .show(),
    );
    // `show()` animates the indicator in before it calls `onRefresh`.
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> answer(
    WidgetTester tester,
    int read,
    Map<String, dynamic> schema,
  ) async {
    store.reads[read].complete(schema);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
  }

  Strings strings(WidgetTester tester) =>
      Strings.of(tester.element(find.byType(Scaffold).last));

  int ownReads(ScriptedRest rest) => rest.calls.length;

  testWidgets('a refresh while the first load is pending joins it', (
    tester,
  ) async {
    await open(tester);
    final firstBatch = ownReads(rests['']!);
    expect(store.reads, hasLength(1));

    await pullToRefresh(tester);

    expect(store.reads, hasLength(1), reason: 'one schema read, not two');
    expect(
      ownReads(rests['']!),
      firstBatch,
      reason: 'no second set of Diagnostics reads',
    );

    await answer(tester, 0, _schema('timezone'));
    expect(find.text(strings(tester).adv1215PageBehavior), findsOneWidget);
  });

  testWidgets('a refresh after the load finished reads again', (tester) async {
    await open(tester);
    await answer(tester, 0, _schema('timezone'));
    final firstBatch = ownReads(rests['']!);

    await pullToRefresh(tester);
    expect(store.reads, hasLength(2));
    await answer(tester, 1, _schema('agent.max_turns'));

    expect(ownReads(rests['']!), firstBatch * 2);
    expect(find.text(strings(tester).adv1215PageBehavior), findsNothing);
    expect(find.text(strings(tester).adv1215PageRuntime), findsOneWidget);
  });

  testWidgets(
    'the answer of a profile left behind never lands on the new one',
    (tester) async {
      await open(tester);
      expect(store.reads, hasLength(1));

      await manager.setActiveProfile(id, 'work');
      await tester.pump();
      expect(
        store.reads,
        hasLength(2),
        reason: 'the new profile reads its own',
      );

      await answer(tester, 1, _schema('agent.max_turns'));
      // The slow answer of the previous profile arrives last.
      await answer(tester, 0, _schema('timezone'));

      final s = strings(tester);
      expect(find.text(s.adv1215PageRuntime), findsOneWidget);
      expect(find.text(s.adv1215PageBehavior), findsNothing);
      expect(find.text(s.sd1215Diagnostics), findsOneWidget);
    },
  );

  testWidgets('a refresh during a profile switch joins the new profile load', (
    tester,
  ) async {
    await open(tester);
    await manager.setActiveProfile(id, 'work');
    await tester.pump();
    expect(store.reads, hasLength(2));

    await pullToRefresh(tester);
    expect(store.reads, hasLength(2), reason: 'joined the work load');
  });
}
