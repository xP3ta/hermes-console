import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/connection.dart';
import 'package:hermes_android/core/screen/screen_controller.dart';
import 'package:hermes_android/core/screen/screen_server.dart';
import 'package:hermes_android/core/screen/takeover_view.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:webview_flutter/webview_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('peek status treats a missing installed flag as present', () {
    final state = DisplayState.fromJson({
      'running': false,
      'status': 'running',
      'lease_holder': 'human',
    });
    expect(state.running, isTrue);
    expect(state.installed, isTrue);
    expect(state.leaseHolder, 'human');
  });

  test('runtime status requires explicit booleans and a lease object', () {
    final runtime = DisplayRuntime.fromJson({
      'supported': true,
      'running': true,
      'blocker': 'memory',
      'geometry': '1280x800',
      'lease': {'holder': 'agent', 'epoch': 4, 'since': 1, 'reason': 'boot'},
    });
    expect(runtime.supported, isTrue);
    expect(runtime.installed, isFalse);
    expect(runtime.running, isTrue);
    expect(runtime.blocker, 'memory');
    expect(runtime.lease.holder, 'agent');
    expect(runtime.lease.epoch, 4);
    expect(runtime.lease.heldByHuman, isFalse);
  });

  test('thumbnail reads a data url and the human suppression flag', () async {
    final controller = _controller((method, params) async {
      expect(method, 'display.thumbnail');
      expect(params, {'profile': 'default'});
      return {
        'data_url': 'data:image/jpeg;base64,YQ==',
        'suppressed': 'human_has_control',
      };
    });
    final frame = await controller.thumbnail(profile: 'default');
    expect(frame.dataUrl, contains('base64'));
    expect(frame.suppressedByHuman, isTrue);
  });

  test('observe requires a ticket and viewer id', () async {
    final controller = _controller(
      (method, params) async => {'path': '/api/display/ws'},
    );
    await expectLater(
      controller.observe(),
      throwsA(
        isA<ScreenControllerException>().having(
          (error) => error.kind,
          'kind',
          ScreenFailureKind.invalidResponse,
        ),
      ),
    );
  });

  test('observe keeps the gateway path and runtime', () async {
    final calls = <String>[];
    final controller = _controller((method, params) async {
      calls.add(method);
      return {
        'ticket': 'ticket-1',
        'viewer_id': 'viewer-1',
        'path': '/api/display/ws',
        'supported': true,
        'installed': true,
        'running': true,
        'lease': {'holder': 'agent', 'epoch': 1, 'since': 1},
      };
    });
    final session = await controller.observe(profile: 'work');
    expect(calls, ['display.observe']);
    expect(session.ticket, 'ticket-1');
    expect(session.viewerId, 'viewer-1');
    expect(session.path, '/api/display/ws');
    expect(session.runtime.running, isTrue);
  });

  test('acquire and release send the viewer id and profile', () async {
    final seen = <Map<String, dynamic>>[];
    final controller = _controller((method, params) async {
      seen.add({'method': method, ...params});
      return {
        'lease': {
          'holder': 'human',
          'viewer_hash': 'hash-us',
          'epoch': 2,
          'since': 9,
        },
      };
    });
    final acquired = await controller.acquire('viewer-1', profile: 'work');
    final released = await controller.release('viewer-1', profile: 'work');
    expect(acquired.heldByHuman, isTrue);
    expect(acquired.viewerHash, 'hash-us');
    expect(released.epoch, 2);
    expect(seen, [
      {
        'method': 'display.lease.acquire',
        'profile': 'work',
        'viewer_id': 'viewer-1',
        'reason': 'hermes-console',
      },
      {
        'method': 'display.lease.release',
        'profile': 'work',
        'viewer_id': 'viewer-1',
      },
    ]);
  });

  test('display websocket uses the dashboard host and only the ticket', () {
    final controller = _controller(
      (method, params) async => {},
      base: Uri.parse('https://hermes.example/prefix'),
    );
    final uri = controller.displayWsUri('/api/display/ws', 'ticket-1');
    expect(uri.scheme, 'wss');
    expect(uri.host, 'hermes.example');
    expect(uri.path, '/prefix/api/display/ws');
    expect(uri.queryParameters, {'display_ticket': 'ticket-1'});
  });

  test('display websocket drops credentials in the Dashboard address', () {
    final controller = _controller(
      (method, params) async => {},
      base: Uri.parse('https://user:secret@hermes.example'),
    );
    final uri = controller.displayWsUri('/api/display/ws', 'ticket-1');
    expect(uri.userInfo, isEmpty);
    expect(uri.toString(), isNot(contains('secret')));
    expect(uri.toString(), startsWith('wss://hermes.example/'));
  });

  test('display websocket does not double a prefixed path', () {
    final controller = _controller(
      (method, params) async => {},
      base: Uri.parse('http://127.0.0.1:9119/hermes'),
    );
    final uri = controller.displayWsUri('/hermes/api/display/ws', 'ticket-1');
    expect(uri.scheme, 'ws');
    expect(uri.path, '/hermes/api/display/ws');
  });

  test('display websocket rejects an empty ticket and a non-http base', () {
    final controller = _controller((method, params) async => {});
    expect(
      () => controller.displayWsUri('/api/display/ws', ''),
      throwsA(isA<ScreenControllerException>()),
    );
    final odd = _controller(
      (method, params) async => {},
      base: Uri.parse('ftp://127.0.0.1/hermes'),
    );
    expect(
      () => odd.displayWsUri('/api/display/ws', 'ticket-1'),
      throwsA(
        isA<ScreenControllerException>().having(
          (error) => error.kind,
          'kind',
          ScreenFailureKind.unavailable,
        ),
      ),
    );
  });

  test('lease events and takeover detection follow the holder hash', () async {
    final payloads = Stream<Map<String, dynamic>>.fromIterable([
      {
        'profile_key': 'default',
        'lease': {
          'holder': 'human',
          'viewer_hash': 'other',
          'epoch': 3,
          'since': 1,
        },
      },
    ]);
    final controller = ScreenController(
      rpc: (method, params) async => {},
      leasePayloads: payloads,
      dashboardBase: () => Uri.parse('http://127.0.0.1:9119'),
    );
    final lease = await controller.watchLease().first;
    expect(lease.viewerHash, 'other');
    expect(
      displayLeaseTakenOver(lease, ourViewerHash: 'hash-us', ourEpoch: 2),
      isTrue,
    );
    expect(
      displayLeaseTakenOver(lease, ourViewerHash: 'other', ourEpoch: 3),
      isFalse,
    );
    expect(
      displayLeaseTakenOver(
        const DisplayLeaseInfo(
          holder: 'agent',
          viewerHash: '',
          epoch: 1,
          reason: '',
        ),
        ourViewerHash: 'hash-us',
        ourEpoch: 0,
      ),
      isTrue,
    );
    expect(
      displayLeaseTakenOver(
        const DisplayLeaseInfo(
          holder: 'agent',
          viewerHash: '',
          epoch: 1,
          reason: '',
        ),
        ourViewerHash: 'hash-us',
        ourEpoch: 2,
      ),
      isFalse,
    );
    expect(
      displayLeaseTakenOver(
        const DisplayLeaseInfo(
          holder: 'human',
          viewerHash: '',
          epoch: 1,
          reason: '',
        ),
        ourViewerHash: 'hash-us',
        ourEpoch: 0,
      ),
      isFalse,
    );
  });

  test('the viewer hash is the gateway\'s: sha256(viewer_id)[:12]', () {
    // Python: hashlib.sha256(b'viewer-1').hexdigest()[:12]
    expect(displayViewerHash('viewer-1'), '63a9e8a8c2d8');
    expect(displayViewerHash(''), 'e3b0c44298fc');
  });

  test('a lease is ours only when a human holds it with our hash', () {
    DisplayLeaseInfo lease(String holder, String hash) => DisplayLeaseInfo(
      holder: holder,
      viewerHash: hash,
      epoch: 1,
      reason: '',
    );
    final ours = displayViewerHash('viewer-1');
    expect(displayLeaseHeldBy(lease('human', ours), 'viewer-1'), isTrue);
    expect(displayLeaseHeldBy(lease('human', ours), 'viewer-2'), isFalse);
    expect(displayLeaseHeldBy(lease('agent', ours), 'viewer-1'), isFalse);
    expect(displayLeaseHeldBy(lease('human', ''), 'viewer-1'), isFalse);
    expect(displayLeaseHeldBy(lease('human', ours), ''), isFalse);
  });

  test('display RPC allowlist keeps control off read-only connections', () {
    for (final method in ['display.status', 'display.thumbnail']) {
      expect(
        TuiGatewayClient.displayRpcAllowed(method, readOnly: true),
        isTrue,
      );
      expect(
        TuiGatewayClient.displayRpcAllowed(method, readOnly: false),
        isTrue,
      );
    }
    for (final method in [
      'display.start',
      'display.observe',
      'display.lease.acquire',
      'display.lease.release',
    ]) {
      expect(
        TuiGatewayClient.displayRpcAllowed(method, readOnly: true),
        isFalse,
      );
      expect(
        TuiGatewayClient.displayRpcAllowed(method, readOnly: false),
        isTrue,
      );
    }
    expect(
      TuiGatewayClient.displayRpcAllowed('session.list', readOnly: false),
      isFalse,
    );
  });

  test('rejected display calls do not dial the gateway', () async {
    final client = TuiGatewayClient(
      SavedConnection(
        id: 'screen-ro',
        label: 'Read only',
        host: '127.0.0.1',
        port: 8642,
        apiKey: 'test-only',
        readOnly: true,
        dashboardUrl: 'http://127.0.0.1:9',
      ),
    );
    addTearDown(client.close);
    await expectLater(
      client.displayRequest('display.observe', const {}),
      throwsA(isA<TuiGatewayRpcError>()),
    );
    await expectLater(
      client.displayRequest('display.status', const {'profile': 'Not A Name'}),
      throwsA(isA<TuiGatewayRpcError>()),
    );
    expect(client.isConnected, isFalse);
  });

  test(
    'the bridge asks Flutter to reconnect instead of reusing the ticket',
    () async {
      final html = await rootBundle.loadString('assets/novnc/bridge.html');
      expect(html, contains("post('reconnect')"));
      expect(html, isNot(contains('location.reload')));
      // P4: the socket arrives through connect(), never from the page URL.
      expect(html, isNot(contains("params.get('ws')")));
      expect(html, contains("post('ready')"));
      expect(html, contains('window.hermesScreen.connect = connect'));
      // P7: shared stated, the agent keeps its own session.
      expect(html, contains('{ shared: true }'));
    },
  );

  test(
    'the bridge page loads only itself and the screen socket (CSP)',
    () async {
      final html = await rootBundle.loadString('assets/novnc/bridge.html');
      final csp = RegExp(
        r'<meta http-equiv="Content-Security-Policy" content="([^"]+)">',
      ).firstMatch(html)?[1];
      expect(csp, isNotNull);
      // Mixed content is allowed for a ws:// Dashboard (REVIEW-PR210 P2):
      // the policy is what keeps that to the socket alone.
      expect(csp, startsWith("default-src 'none';"));
      expect(csp, contains('connect-src ws: wss:;'));
      expect(csp, contains("img-src 'self' data:;"));
      expect(csp, isNot(contains('unsafe-inline')));
      expect(csp, isNot(contains('unsafe-eval')));
      // The inline script and style run only while their hashes match.
      String hashOf(String text) =>
          "'sha256-${base64Encode(sha256.convert(utf8.encode(text)).bytes)}'";
      final script = RegExp(
        r'<script type="module">(.*?)</script>',
        dotAll: true,
      ).firstMatch(html)![1]!;
      final style = RegExp(
        r'<style>(.*?)</style>',
        dotAll: true,
      ).firstMatch(html)![1]!;
      expect(RegExp('<script').allMatches(html), hasLength(1));
      expect(csp, contains("script-src 'self' ${hashOf(script)};"));
      expect(csp, contains('style-src ${hashOf(style)};'));
    },
  );

  test(
    'the socket opens from a sandboxed relay: Origin null (REVIEW-R5-B #4)',
    () async {
      final bridge = await rootBundle.loadString('assets/novnc/bridge.html');
      expect(bridge, contains('new NullOriginSocket(wsUrl)'));
      final socket = await rootBundle.loadString(
        'assets/novnc/null-origin-socket.js',
      );
      expect(socket, contains("setAttribute('sandbox', 'allow-scripts')"));
      final relay = await rootBundle.loadString('assets/novnc/ws-relay.html');
      final csp = RegExp(
        r'<meta http-equiv="Content-Security-Policy" content="([^"]+)">',
      ).firstMatch(relay)![1]!;
      final script = RegExp(
        r'<script>(.*?)</script>',
        dotAll: true,
      ).firstMatch(relay)![1]!;
      final hash =
          "'sha256-${base64Encode(sha256.convert(utf8.encode(script)).bytes)}'";
      expect(csp, startsWith("default-src 'none';"));
      expect(csp, contains('script-src $hash;'));
      expect(csp, contains('connect-src ws: wss:;'));
    },
  );

  test('the noVNC page is https on the asset host and cannot leave it', () {
    final page = screenAssetPageUri(copy: {'connecting': 'Conectando…'});
    expect(page.queryParameters, {'connecting': 'Conectando…'});
    expect(page.toString(), isNot(contains('ticket')));
    expect(page.scheme, 'https');
    expect(page.host, screenAssetHost);
    expect(page.path, '/assets/novnc/bridge.html');
    expect(
      screenNavigationDecision(page, page.replace(query: '').toString()),
      NavigationDecision.navigate,
    );
    expect(
      screenNavigationDecision(page, 'http://${page.host}${page.path}'),
      NavigationDecision.prevent,
    );
    expect(
      screenNavigationDecision(page, 'https://evil.test/bridge.html'),
      NavigationDecision.prevent,
    );
    expect(
      screenNavigationDecision(page, 'javascript:alert(1)'),
      NavigationDecision.prevent,
    );
    expect(
      screenNavigationDecision(
        page,
        'https://user:pass@${page.host}${page.path}',
      ),
      NavigationDecision.prevent,
    );
  });

  test('the socket goes to the page as a JSON string, never spliced raw', () {
    const ws = r'wss://dash.example/api/display/ws?display_ticket=t"); x(';
    final script = screenConnectScript(ws);
    expect(
      script,
      startsWith('window.hermesScreen && window.hermesScreen.connect("'),
    );
    expect(script, contains(r't\"); x('));
    expect(script, endsWith('")'));
    expect(screenSocketUnencrypted('ws://10.0.0.2/api/display/ws'), isTrue);
    expect(
      screenSocketUnencrypted('wss://dash.example/api/display/ws'),
      isFalse,
    );
  });
}

ScreenController _controller(DisplayRpc rpc, {Uri? base}) => ScreenController(
  rpc: rpc,
  leasePayloads: const Stream.empty(),
  dashboardBase: () => base ?? Uri.parse('http://127.0.0.1:9119'),
);
