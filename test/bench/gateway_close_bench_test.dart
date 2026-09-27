@Tags(['bench'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

/// Manual bench against a real Hermes `tui_gateway.ws.handle_ws`
/// (local harness, not in the repo). Skipped unless
/// `HERMES_WS_BENCH_PORTS` is set. Each run connects, lets the fire-and-forget
/// `client.capabilities` (slowed server-side) stay in flight, and disposes.
final class _Ticket extends DashboardClient {
  _Ticket() : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(queryName: 'ticket', credential: 'bench');
}

void main() {
  final ports = Platform.environment['HERMES_WS_BENCH_PORTS'];
  final runs =
      int.tryParse(Platform.environment['HERMES_WS_BENCH_RUNS'] ?? '') ?? 6;
  test(
    'dispose with a reply in flight against real handle_ws',
    () async {
      for (final port in ports!.split(',')) {
        for (var i = 0; i < runs; i++) {
          final client = TuiGatewayClient(
            SavedConnection(
              id: 'bench-$port-$i',
              label: 'Bench',
              host: '127.0.0.1',
              port: 8642,
              apiKey: 'k',
              dashboardUrl: 'http://127.0.0.1:$port',
            ),
            dashboard: _Ticket(),
            heartbeatInterval: Duration.zero,
          );
          await client.connect();
          await Future<void>.delayed(const Duration(milliseconds: 50));
          await client.close();
          await Future<void>.delayed(const Duration(milliseconds: 800));
        }
      }
    },
    skip: ports == null ? 'set HERMES_WS_BENCH_PORTS to run' : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
