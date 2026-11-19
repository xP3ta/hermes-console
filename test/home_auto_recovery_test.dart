// Regression tests for the Reddit report (home not recovering;
// acknowledged): with Tailscale set to connect when Console
// opens, the VPN comes up about a second after Home's first check. Home then
// stays «offline» with a Retry button until the user taps it.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_active_session.dart';
import 'package:hermes_android/core/models/home_widget_snapshot.dart';
import 'package:hermes_android/core/screens/home_dashboard_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/connection_status.dart';
import 'package:hermes_android/core/services/global_activity_aggregate.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/instance_status_panel.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_connection_link.dart';
import 'support/test_api_client.dart';

/// The network the probes see: unreachable until [reachable] flips.
final class _Network {
  bool reachable = false;

  /// H1: a probe answers with [reachable] as it was when it STARTED (a
  /// check already on the wire before a cut still answers fine).
  bool answerAtStart = false;
  int probes = 0;
  int inFlight = 0;
  int maxInFlight = 0;
  final List<Duration> probeTimes = [];

  /// The saved connection Home shows.
  String? connectionId;

  /// Client factory calls that throw before a client exists (review m6).
  int factoryThrows = 0;

  /// Connection states published to the launcher widget, in order.
  final List<HomeWidgetConnectionState> widgetStates = [];
  HermesHomeWidgetSnapshot widget = const HermesHomeWidgetSnapshot();
}

class _ProbeClient extends ApiClient {
  _ProbeClient(this.net, this.clock)
    : super(
        baseUrl: 'http://127.0.0.1:8642',
        apiKey: 'test-key',
        httpClient: MockClient((_) async => http.Response('{}', 404)),
        profileDashboard: testDashboardClient(
          baseUrl: 'http://127.0.0.1:8642',
          httpClient: MockClient((_) async => http.Response('{}', 404)),
        ),
      );

  final _Network net;
  final Stopwatch clock;

  @override
  Future<bool> healthCheck() => healthReachable();

  @override
  Future<bool> healthReachable() async {
    net.probes++;
    net.probeTimes.add(clock.elapsed);
    net.inFlight++;
    if (net.inFlight > net.maxInFlight) net.maxInFlight = net.inFlight;
    final atStart = net.reachable;
    try {
      // A refused dial on a VPN that is not up yet takes a moment.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      return net.answerAtStart ? atStart : net.reachable;
    } finally {
      net.inFlight--;
    }
  }

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

const _secureChannel = MethodChannel(
  'plugins.it_nomads.com/flutter_secure_storage',
);

/// Keystore reads (drafts) seen on the secure storage channel.
var _secureReads = 0;

Future<_Network> _pumpHome(WidgetTester tester, {int factoryThrows = 0}) async {
  final manager = await ConnectionManager.create(
    await SharedPreferences.getInstance(),
  );
  await manager.saveConnection(
    'Tailnet',
    '100.64.0.7',
    8642,
    'test-key',
    kind: InstanceKind.vps,
  );
  final connection = manager.getConnections().single;
  await manager.setActiveConnection(connection.id);
  final aggregate = GlobalActivityAggregate.inMemory();
  addTearDown(aggregate.dispose);
  final net = _Network()
    ..connectionId = connection.id
    ..factoryThrows = factoryThrows;
  // Fake-async time: the stopwatch only advances with tester.pump.
  final clock = _FakeClock(tester);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.fromId('dark'),
      locale: const Locale('en'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      home: HomeDashboardScreen(
        connManager: manager,
        clientFactory: (_) {
          if (net.factoryThrows > 0) {
            net.factoryThrows--;
            throw StateError('client factory failed');
          }
          return _ProbeClient(net, clock);
        },
        homeWidgetUpdateOverride: (transform) async {
          final next = transform(net.widget);
          if (next.connectionState != net.widget.connectionState ||
              !identical(next, net.widget)) {
            net.widgetStates.add(next.connectionState);
          }
          net.widget = next;
        },
        dashboardAuthProbe: (_) async => DashboardAuthCheck.ok,
        globalActivityOverride: aggregate,
        activeSessionListLoader: () async =>
            const DesktopActiveSessionList(sessions: []),
        eventStreamOverride: const Stream.empty(),
      ),
    ),
  );
  return net;
}

/// Elapsed fake time, read from the binding's clock.
final class _FakeClock implements Stopwatch {
  _FakeClock(this.tester) : _start = tester.binding.clock.now();
  final WidgetTester tester;
  final DateTime _start;

  @override
  Duration get elapsed => tester.binding.clock.now().difference(_start);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _advance(WidgetTester tester, Duration total) async {
  const step = Duration(milliseconds: 100);
  for (var t = Duration.zero; t < total; t += step) {
    await tester.pump(step);
  }
}

Finder _offlineRetry() => find.byKey(const ValueKey('home-offline-retry'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final secureValues = <String, String>{};
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_secureChannel, (call) async {
          final args = call.arguments is Map
              ? Map<Object?, Object?>.from(call.arguments as Map)
              : const <Object?, Object?>{};
          if (call.method == 'read' || call.method == 'readAll') {
            _secureReads++;
          }
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
        .setMockMethodCallHandler(_secureChannel, null);
  });

  testWidgets('[RED] the VPN comes up after the first check: Home recovers '
      'on its own, without tapping Retry', (tester) async {
    final net = await _pumpHome(tester);
    await _advance(tester, const Duration(seconds: 1));
    expect(net.probes, 1, reason: 'one check on open');
    expect(_offlineRetry(), findsOneWidget, reason: 'first check failed');

    // Tailscale finishes connecting ~1 s after the app opened.
    net.reachable = true;
    await _advance(tester, const Duration(seconds: 5));

    expect(net.probes, greaterThan(1), reason: 'Home must check again');
    expect(_offlineRetry(), findsNothing, reason: 'Home must be online');
    expect(
      net.widget.connectionState,
      HomeWidgetConnectionState.connected,
      reason: 'the launcher widget follows the recovery',
    );
    expect(net.maxInFlight, 1, reason: 'never two probes at once');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('[CONTROL] a server that stays down is probed with a growing '
      'delay, never a storm', (tester) async {
    final net = await _pumpHome(tester);
    await _advance(tester, const Duration(seconds: 120));

    // ≤ one probe every few seconds on average, and never overlapping.
    expect(net.probes, lessThanOrEqualTo(14), reason: '${net.probeTimes}');
    expect(net.maxInFlight, 1);
    final gaps = [
      for (var i = 1; i < net.probeTimes.length; i++)
        net.probeTimes[i] - net.probeTimes[i - 1],
    ];
    // Once backed off, gaps stay at the cap rather than shrinking back.
    if (gaps.length >= 4) {
      expect(
        gaps.last,
        greaterThanOrEqualTo(gaps[1]),
        reason: 'gaps $gaps',
      );
    }
    expect(_offlineRetry(), findsOneWidget, reason: 'still honest: offline');
    // The launcher widget says «offline» once and stays there: the retries
    // publish nothing while nothing changes (no connecting/offline flicker).
    expect(
      net.widgetStates.where((s) => s == HomeWidgetConnectionState.connecting),
      hasLength(lessThanOrEqualTo(1)),
      reason: '${net.widgetStates}',
    );
    expect(net.widgetStates.last, HomeWidgetConnectionState.disconnected);
    expect(
      net.widgetStates.length,
      lessThanOrEqualTo(3),
      reason: '${net.probes} probes, widget writes ${net.widgetStates}',
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('[CONTROL] no probes while the app is in the background; one '
      'check on resume', (tester) async {
    final net = await _pumpHome(tester);
    await _advance(tester, const Duration(seconds: 1));
    final before = net.probes;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await _advance(tester, const Duration(seconds: 60));
    expect(net.probes, before, reason: 'paused: no retries');

    net.reachable = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _advance(tester, const Duration(seconds: 2));
    expect(_offlineRetry(), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('[CONTROL] leaving Home cancels the pending retry (no timer '
      'outlives the screen)', (tester) async {
    final net = await _pumpHome(tester);
    await _advance(tester, const Duration(seconds: 1));
    final before = net.probes;
    await tester.pumpWidget(const SizedBox.shrink());
    await _advance(tester, const Duration(seconds: 60));
    expect(net.probes, before);
  });

  // Review m6 (console-reddit-independent-review.md) and §7.7 of the report.

  testWidgets('[RED] the chat socket coming up re-checks at once (no wait '
      'for the backoff) and the launcher widget gets one write', (
    tester,
  ) async {
    final net = await _pumpHome(tester);
    final link = FakeConnectionLink();
    ConnectionStatusRegistry.instance.bind(net.connectionId!, link);
    addTearDown(ConnectionStatusRegistry.instance.reset);
    // Failed checks at ~0, 1.2, 3.4, 7.6 and 15.8 s: the next is 15 s away.
    await _advance(tester, const Duration(seconds: 17));
    expect(_offlineRetry(), findsOneWidget);
    final probes = net.probes;
    final writes = net.widgetStates.length;

    // Tailscale finishes: the chat socket of this connection is up.
    net.reachable = true;
    link.change(() => link.isConnected = true);
    await _advance(tester, const Duration(milliseconds: 500));
    expect(net.probes, greaterThan(probes), reason: 'checked at once');
    await _advance(tester, const Duration(seconds: 1));
    expect(_offlineRetry(), findsNothing);
    expect(
      net.widgetStates.sublist(writes),
      [HomeWidgetConnectionState.connected],
      reason: 'no «connecting» flash on the way back',
    );
    expect(net.maxInFlight, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('[RED] a check that throws before probing (client factory) is '
      'not stuck «checking»: Retry shows and Home recovers by itself', (
    tester,
  ) async {
    final net = await _pumpHome(tester, factoryThrows: 2);
    await _advance(tester, const Duration(milliseconds: 500));
    expect(_offlineRetry(), findsOneWidget, reason: 'not stuck checking');
    net.reachable = true;
    await _advance(tester, const Duration(seconds: 8));
    expect(net.factoryThrows, 0, reason: 'retried past the failures');
    expect(_offlineRetry(), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('[RED] an automatic retry of a server still down only probes: '
      'no Keystore draft read every 15 s', (tester) async {
    await _pumpHome(tester);
    await _advance(tester, const Duration(seconds: 2));
    final reads = _secureReads;
    await _advance(tester, const Duration(seconds: 120));
    expect(_secureReads - reads, lessThanOrEqualTo(1));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  // E10 (emulator QA against the real instance): with the socket already up,
  // a 25 s route cut left Home saying «online» the whole time. Android's
  // network callback reaches ConnectionStatusRegistry.setNetworkLost; Home
  // must check at once on a loss and again at once when the network is back.

  testWidgets('[RED] E10 the network drops while Home is online: Home checks '
      'at once and says offline, then recovers at once when it is back', (
    tester,
  ) async {
    addTearDown(ConnectionStatusRegistry.instance.reset);
    final net = await _pumpHome(tester);
    await _advance(tester, const Duration(seconds: 1));
    net.reachable = true;
    // Retry once so Home is online.
    await tester.tap(_offlineRetry());
    await _advance(tester, const Duration(seconds: 2));
    expect(_offlineRetry(), findsNothing, reason: 'online before the cut');
    final writes = net.widgetStates.length;
    final probes = net.probes;

    net.reachable = false;
    ConnectionStatusRegistry.instance.setNetworkLost(true);
    await _advance(tester, const Duration(seconds: 1));
    expect(net.probes, greaterThan(probes), reason: 'checked at once');
    expect(_offlineRetry(), findsOneWidget, reason: 'says offline now');

    final probesOffline = net.probes;
    net.reachable = true;
    ConnectionStatusRegistry.instance.setNetworkLost(false);
    await _advance(tester, const Duration(seconds: 1));
    expect(net.probes, greaterThan(probesOffline), reason: 'no backoff wait');
    await _advance(tester, const Duration(seconds: 1));
    expect(_offlineRetry(), findsNothing, reason: 'online again');
    expect(
      net.widgetStates.sublist(writes),
      [HomeWidgetConnectionState.disconnected, HomeWidgetConnectionState.connected],
      reason: 'no «connecting» flash either way',
    );
    expect(net.maxInFlight, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('[CONTROL] E10 a network signal while Home is offline and a '
      'check is running never starts a second one', (tester) async {
    addTearDown(ConnectionStatusRegistry.instance.reset);
    final net = await _pumpHome(tester);
    for (var i = 0; i < 5; i++) {
      ConnectionStatusRegistry.instance.setNetworkLost(i.isEven);
      await tester.pump(const Duration(milliseconds: 50));
    }
    await _advance(tester, const Duration(seconds: 3));
    expect(net.maxInFlight, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  // Review H1: a loss that lands while a check is already on
  // the wire (it started before the cut and answers fine) must not leave Home
  // «online»: Home checks once more when that check ends.
  testWidgets('[RED] H1 the network drops while a check that will succeed is '
      'running: Home checks again when it ends and says offline', (
    tester,
  ) async {
    addTearDown(ConnectionStatusRegistry.instance.reset);
    final net = await _pumpHome(tester);
    await _advance(tester, const Duration(seconds: 1));
    net.reachable = true;
    await tester.tap(_offlineRetry());
    await _advance(tester, const Duration(seconds: 2));
    expect(_offlineRetry(), findsNothing, reason: 'online before the cut');

    net.answerAtStart = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 50));
    expect(net.inFlight, 1, reason: 'a check started before the cut');
    final probes = net.probes;

    net.reachable = false;
    ConnectionStatusRegistry.instance.setNetworkLost(true);
    await _advance(tester, const Duration(seconds: 2));
    expect(net.probes, greaterThan(probes), reason: 'checked once more');
    expect(_offlineRetry(), findsOneWidget, reason: 'offline after the loss');
    expect(net.maxInFlight, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('[CONTROL] H1 the network comes back before the running check '
      'ends: no extra check', (tester) async {
    addTearDown(ConnectionStatusRegistry.instance.reset);
    final net = await _pumpHome(tester);
    await _advance(tester, const Duration(seconds: 1));
    net.reachable = true;
    await tester.tap(_offlineRetry());
    await _advance(tester, const Duration(seconds: 2));
    net.answerAtStart = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 50));
    final probes = net.probes;
    ConnectionStatusRegistry.instance.setNetworkLost(true);
    await tester.pump(const Duration(milliseconds: 20));
    ConnectionStatusRegistry.instance.setNetworkLost(false);
    await _advance(tester, const Duration(seconds: 2));
    expect(net.probes, probes, reason: 'the running check stands');
    expect(_offlineRetry(), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
