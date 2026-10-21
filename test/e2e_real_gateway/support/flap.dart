// Harness for net1_flap_test.dart: Console's real chat service and shared
// gateway pool dialled through tool/e2e/flap_proxy.py (E2E_FLAP=1), the
// proxy's control socket and the `[QA-NET]` lines. Only seams that exist
// before and after NET-1, so the same file runs on either side.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:hermes_android/core/bots/data/gateway_socket_meter.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/shared_gateway_pool.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/main.dart'
    show NetworkAvailabilityRecoveryListener;

import '../../support/in_memory_compression_restore_storage.dart';
import 'real_gateway.dart';

export 'flap_verdict.dart';

/// Control socket of flap_proxy.py (`pass`, `blackhole`, `rst`, `refuse`,
/// `flap N DOWN UP`, `stats`, `reset`); every reply is the proxy's stats.
Future<Map<String, dynamic>> flapControl(String path, String command) async {
  final socket = await Socket.connect(
    InternetAddress(path, type: InternetAddressType.unix),
    0,
  );
  socket.write('$command\n');
  final line = await utf8.decoder
      .bind(socket)
      .transform(const LineSplitter())
      .first;
  socket.destroy();
  return jsonDecode(line) as Map<String, dynamic>;
}

extension FlapStats on Map<String, dynamic> {
  Map<String, dynamic> get _paths => this['by_path'] as Map<String, dynamic>;

  /// WebSocket upgrades that reached the proxy (forwarded or swallowed).
  int get wsOpens => (_paths['GET /api/ws'] as int?) ?? 0;

  int get historyReads => _paths.entries
      .where((e) => e.key.startsWith('GET ') && e.key.endsWith('/messages'))
      .fold(0, (sum, e) => sum + (e.value as int));

  /// Longest wait for an answer of any request but the WebSocket upgrade.
  int get restWaitMs => (this['wait_ms'] as Map<String, dynamic>).entries
      .where((e) => e.key != 'GET /api/ws')
      .fold(0, (max, e) => (e.value as int) > max ? e.value as int : max);

  /// Live WebSockets the cuts tore down (0: the cuts measured nothing).
  int get severedWs => (this['severed_ws'] as int?) ?? 0;

  /// Upgrades per cut window (the cuts made before each arrived).
  Map<String, int> get opensByWindow =>
      ((this['ws_opens_by_window'] as Map?) ?? const {}).map(
        (k, v) => MapEntry('$k', v as int),
      );

  String get brief =>
      'cuts=${this['cuts']} wsOpens=$wsOpens rejected=${this['rejected']} '
      'wsLiveMax=${this['ws_live_max']} historyReads=$historyReads '
      'restWaitMs=$restWaitMs severedWs=$severedWs '
      'opensByWindow=$opensByWindow';
}

/// One phone whose Dashboard and API server sit behind the proxy.
final class FlapConsole {
  FlapConsole(this.env) {
    final dash = Uri.parse(env.vars['HERMES_E2E_PROXY_URL']!);
    final api = Uri.parse(env.vars['HERMES_E2E_PROXY_API_URL']!);
    connection = SavedConnection(
      id: 'e2e-flap',
      label: 'Real gateway E2E (flap)',
      host: api.host,
      port: api.port,
      apiKey: env.apiKey,
      dashboardUrl: dash.toString(),
      dashboardAuthMode: AuthMode.basicAuth,
    );
    pool = SharedGatewayPool.forTesting(linger: Duration.zero);
    service = ActiveChatService(
      compressionRestoreStore: testCompressionRestoreStore(),
      chatGatewayPool: pool,
      sharedChatGatewayFactory: (connection) => TuiGatewayClient(
        connection,
        dashboard: dashboard(),
        channelFactory: meter.connect,
      ),
    );
    // The app's own listener (main.dart), with its onAvailable/onLost bodies
    // pointed at this phone's service and pool. The status registry (display
    // state, absent before N4) is not driven.
    _listener = NetworkAvailabilityRecoveryListener(
      events: _signals.stream,
      onAvailable: () {
        GatewaySocketMeter.instance.recordNetworkAvailable();
        service.requestImmediateTransportRecovery();
        unawaited(pool.probeAll());
      },
      onLost: GatewaySocketMeter.instance.recordNetworkLost,
    );
    GatewaySocketMeter.instance.debugUseLog(NetMeterLog(qaNet.add));
  }

  final E2eEnv env;
  late final SavedConnection connection;
  final meter = TrafficMeter();
  late final http = MeteredHttpClient(meter);
  late final SharedGatewayPool pool;
  late final ActiveChatService service;
  final _signals = StreamController<dynamic>.broadcast();
  late final NetworkAvailabilityRecoveryListener _listener;

  /// Every `[QA-NET]` line Console produced (the QA meter, forced on here).
  final qaNet = <String>[];

  int qaCount(String text) => qaNet.where((l) => l.contains(text)).length;

  Future<Map<String, dynamic>> proxy(String command) =>
      flapControl(env.vars['HERMES_E2E_PROXY_CONTROL']!, command);

  /// A platform network event: `available` (validated) or `lost`.
  void signal(String event) => _signals.add(event);

  DashboardClient dashboard() {
    final dash = Uri.parse(connection.dashboardUrl!);
    return DashboardClient(
      host: dash.host,
      port: dash.port,
      basicUser: env.user,
      basicPass: env.password,
      httpClientOverride: http,
    );
  }

  /// Opens [sessionId] through the service, on the pool's shared chat socket.
  ActiveChat open(String sessionId) => service.attach(
    connection: connection,
    sessionId: sessionId,
    sessionTitle: 'E2E $sessionId',
    initialStoredSessionId: sessionId,
    api: ApiClient(
      baseUrl: connection.baseUrl,
      apiKey: connection.apiKey,
      connectionId: connection.id,
      httpClient: http,
      profileDashboard: dashboard(),
    ),
    transcriptDashboard: dashboard(),
    attachDesktopRuntimeOnLoad: true,
    disableForegroundKeepAlive: true,
  );

  Future<void> close() async {
    await proxy('pass');
    await _listener.dispose();
    service.dispose();
    await pool.closeAll();
    http.close();
    GatewaySocketMeter.instance.debugUseLog(null);
  }
}
