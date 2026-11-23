// How much the app talks to its server, counted on the phone for the
// diagnostic report (#226): what is kept is the shape of a route and
// sizes, never an address, an identifier, a query or content.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/diagnostic_bundle_service.dart';
import 'package:hermes_android/core/services/origin_bound_http_client.dart';
import 'package:hermes_android/core/services/traffic_counter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late DateTime now;
  final counter = TrafficCounter.instance;

  setUp(() {
    now = DateTime.utc(2026, 11, 21, 10, 15);
    counter.resetForTesting(now: () => now);
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(counter.resetForTesting);

  test('a route keeps its shape and nothing that names anything', () {
    expect(
      TrafficCounter.normalizePath(
        '/api/sessions/20260102_030405_a1b2c3/messages?limit=50&profile=ana',
      ),
      '/api/sessions/:id/messages',
    );
    expect(
      TrafficCounter.normalizePath('/api/profiles/ana-work/soul'),
      '/api/profiles/:id/soul',
    );
    expect(
      TrafficCounter.normalizePath('/api/files/download/home/ana/secret.pdf'),
      '/api/files/download/:id/:id/:id',
    );
    expect(TrafficCounter.normalizePath('/'), '/');
    // Deep paths are cut, not kept.
    expect(
      TrafficCounter.normalizePath('/a/b/c/d/e/f/g/h/i/j').split('/').length,
      9,
    );
  });

  test('every REST call through the origin-bound client is counted with '
      'the bytes of its bodies, on the side the app is on', () async {
    final client = OriginBoundHttpClient(
      MockClient((request) async {
        if (request.method == 'GET') {
          return http.Response('x' * 1000, 200);
        }
        return http.Response('ok', 200);
      }),
    );
    counter.foreground = true;
    await client.get(
      Uri.parse('http://10.0.0.5:9119/api/sessions/abc123/messages?limit=5'),
    );
    await client.get(
      Uri.parse('http://10.0.0.5:9119/api/sessions/zzz999/messages'),
    );
    counter.foreground = false;
    await client.post(
      Uri.parse('http://10.0.0.5:9119/api/sessions/abc123/messages'),
      body: 'y' * 40,
    );

    final report = await counter.report();
    final launch = report['sinceLaunch'] as Map<String, dynamic>;
    final fg = launch['foreground'] as Map<String, dynamic>;
    final bg = launch['background'] as Map<String, dynamic>;
    expect(fg['requests'], 2);
    expect(fg['responseBytes'], 2000);
    expect(fg['routes'], [
      {
        'route': 'GET /api/sessions/:id/messages',
        'requests': 2,
        'requestBytes': 0,
        'responseBytes': 2000,
      },
    ]);
    expect(bg['requests'], 1);
    expect(bg['requestBytes'], 40);
    expect(bg['responseBytes'], 2);

    final text = jsonEncode(report);
    for (final secret in ['abc123', 'zzz999', '10.0.0.5', 'limit', '9119']) {
      expect(text.contains(secret), isFalse, reason: secret);
    }
  });

  test('sockets, re-reads, totals per window and per hour; old hours are '
      'dropped', () async {
    counter.foreground = true;
    counter.socketOpened(again: false);
    counter.socketOpened(again: true);
    counter.socketSent('{"jsonrpc":"2.0"}');
    counter.socketReceived('x' * 300);
    counter.rehydration('in_place');
    counter.rehydration('something a caller made up');

    now = now.add(const Duration(hours: 30));
    counter.request('GET', '/api/status').received(10);

    var report = await counter.report();
    final day = (report['last24h'] as Map)['foreground'] as Map;
    expect(day['requests'], 1);
    expect(day['wsConnects'], 0, reason: 'thirty hours ago is not today');
    final window = (report['window'] as Map)['foreground'] as Map;
    expect(window['wsConnects'], 2);
    expect(window['wsReconnects'], 1);
    expect(window['wsMessagesIn'], 1);
    expect(window['wsBytesIn'], 300);
    expect(window['wsMessagesOut'], 1);
    expect(window['rehydrationsByReason'], {'in_place': 1, 'other': 1});
    expect(report['hourly'], hasLength(2));

    now = now.add(const Duration(hours: 30));
    counter.request('GET', '/api/status');
    report = await counter.report();
    expect(
      ((report['window'] as Map)['foreground'] as Map)['wsConnects'],
      0,
      reason: 'sixty hours ago has left the window',
    );
  });

  test('counts survive a restart, and the service isolate adds its own as '
      'background', () async {
    final prefs = await SharedPreferences.getInstance();
    counter.attach(prefs);
    counter.foreground = true;
    counter.request('GET', '/api/status').received(7);
    counter.save();

    // The notification service: its own isolate, its own key.
    counter.resetForTesting(now: () => now);
    counter.attach(prefs, service: true);
    counter.foreground = true; // has no screen: still background
    counter.request('GET', '/api/cron/jobs').received(90);
    counter.save();

    // The app again, later.
    counter.resetForTesting(now: () => now);
    counter.attach(prefs);
    final report = await counter.report();
    final window = report['window'] as Map;
    expect((window['foreground'] as Map)['responseBytes'], 7);
    expect((window['background'] as Map)['responseBytes'], 90);
    expect(
      ((report['sinceLaunch'] as Map)['foreground'] as Map)['requests'],
      0,
      reason: 'nothing yet in this run',
    );
  });

  test('a busy hour keeps a bounded number of routes', () {
    counter.foreground = true;
    // Shapes differ only by depth here; the cap is on distinct shapes.
    final side = TrafficSide();
    for (var i = 0; i < 100; i++) {
      side.route('GET /made-up/$i')[0]++;
    }
    expect(side.routes.length, TrafficCounter.maxRoutes + 1);
    expect(side.routes[TrafficCounter.other]![0], 100 - TrafficCounter.maxRoutes);
  });

  test('the diagnostic report carries the counts and stays under its limit', () {
    final service = DiagnosticBundleService(
      now: () => now,
      randomToken: () => 'token',
    );
    const base = (appVersion: '1.4.4', build: 14036);
    DiagnosticBundle build(Map<String, dynamic>? traffic) => service.build(
      DiagnosticBundleInput(
        appVersion: base.appVersion,
        buildNumber: base.build,
        flavor: DiagnosticFlavor.full,
        androidApi: 35,
        formFactor: DiagnosticFormFactor.phone,
        traffic: traffic,
      ),
    );
    expect(build(null).toJson().containsKey('traffic'), isFalse);
    final small = build({
      'windowHours': 48,
      'hourly': [1, 2],
    });
    expect((small.toJson()['traffic'] as Map)['hourly'], [1, 2]);
    // Too much: the per-hour lines go, the report is still whole.
    final big = build({
      'windowHours': 48,
      'hourly': List.filled(60000, 'x' * 8),
    });
    final traffic = big.toJson()['traffic'] as Map;
    expect(traffic.containsKey('hourly'), isFalse);
    expect(traffic['windowHours'], 48);
    expect(
      utf8.encode(big.preview).length,
      lessThanOrEqualTo(DiagnosticBundleService.maxBytes),
    );
  });
}
