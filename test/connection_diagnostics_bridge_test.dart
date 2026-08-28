import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:hermes_android/core/services/connection_diagnostics.dart';
import 'package:hermes_android/core/services/connection_manager.dart';

SavedConnection _conn({String apiKey = 'tok-123'}) => SavedConnection(
  id: 'i1',
  label: 'demo',
  host: '192.168.1.20',
  port: 8642,
  apiKey: apiKey,
);

SavedConnection _publicConn({String? dashboardUrl}) => SavedConnection(
  id: 'public',
  label: 'public cleartext',
  host: 'gateway.example.com',
  port: 8642,
  apiKey: 'must-not-leave-the-device',
  dashboardUrl: dashboardUrl,
);

void main() {
  group('ConnectionDiagnostics transport boundary', () {
    test('bloquea gateway HTTP público antes de tocar la red', () async {
      var hits = 0;
      final diag = ConnectionDiagnostics(
        httpClient: MockClient((_) async {
          hits++;
          return http.Response('{}', 200);
        }),
      );

      await expectLater(diag.probeGateway(_publicConn()), throwsArgumentError);
      expect(hits, 0);
    });

    test('bloquea dashboard HTTP público antes de tocar la red', () async {
      var hits = 0;
      final diag = ConnectionDiagnostics(
        httpClient: MockClient((_) async {
          hits++;
          return http.Response('{}', 200);
        }),
      );

      await expectLater(
        diag.probeDashboard(
          _publicConn(dashboardUrl: 'http://dashboard.example.com:9119'),
          const DashboardSecrets(),
        ),
        throwsArgumentError,
      );
      expect(hits, 0);
    });

    test('bloquea bridge HTTP público antes de tocar la red', () async {
      var hits = 0;
      final diag = ConnectionDiagnostics(
        httpClient: MockClient((_) async {
          hits++;
          return http.Response('{}', 200);
        }),
      );

      await expectLater(diag.probeBridge(_publicConn()), throwsArgumentError);
      expect(hits, 0);
    });
  });

  group('ConnectionDiagnostics.probeBridge', () {
    test('con API key y sin bridge token solo comprueba health', () async {
      final hits = <String>[];
      final client = MockClient((req) async {
        hits.add('${req.method} ${req.url.path}');
        if (req.url.path == '/bridge/health') {
          return http.Response('{"status":"ok","version":"1.10.0"}', 200);
        }
        return http.Response('not found', 404);
      });
      final diag = ConnectionDiagnostics(httpClient: client);

      final results = await diag.probeBridge(_conn());

      // Se sondea el puerto derivado del bridge (9131), no el del gateway.
      expect(hits, ['GET /bridge/health']);
      expect(results.map((r) => r.name), ['health']);
      expect(results.every((r) => r.status == ProbeStatus.ok), isTrue);
    });

    test('si /bridge/health no responde, no intenta provision', () async {
      final hits = <String>[];
      final client = MockClient((req) async {
        hits.add(req.url.path);
        return http.Response('nope', 404);
      });
      final diag = ConnectionDiagnostics(httpClient: client);

      final results = await diag.probeBridge(_conn());

      expect(hits, ['/bridge/health']);
      expect(results, hasLength(1));
      expect(results.single.name, 'health');
      expect(results.single.status, ProbeStatus.notFound);
    });

    test('usa URL y token manuales sin depender de provision', () async {
      final hits = <String>[];
      final client = MockClient((req) async {
        hits.add('${req.method} ${req.url}');
        expect(req.url.host, '100.90.80.70');
        expect(req.url.port, 19131);
        if (req.url.path == '/bridge/health') {
          return http.Response('{"status":"ok","version":"1.10.0"}', 200);
        }
        if (req.url.path == '/bridge/capabilities') {
          expect(req.headers['Authorization'], 'Bearer manual-bridge-token');
          return http.Response('{"operations":{}}', 200);
        }
        fail('No debía llamar ${req.url.path}');
      });
      final diag = ConnectionDiagnostics(httpClient: client);

      final results = await diag.probeBridge(
        _conn(),
        bridgeUrl: 'http://100.90.80.70:19131',
        bridgeToken: 'manual-bridge-token',
      );

      expect(results.map((r) => r.name), ['health', 'auth']);
      expect(results.every((r) => r.status == ProbeStatus.ok), isTrue);
      expect(hits.every((hit) => hit.startsWith('GET ')), isTrue);
      expect(hits.where((hit) => hit.contains('/bridge/provision')), isEmpty);
    });

    test(
      'sin API key solo comprueba health (no hay nada que provisionar)',
      () async {
        final client = MockClient((req) async {
          if (req.url.path == '/bridge/health') {
            return http.Response('{"status":"ok","version":"1.10.0"}', 200);
          }
          return http.Response('not found', 404);
        });
        final diag = ConnectionDiagnostics(httpClient: client);

        final results = await diag.probeBridge(_conn(apiKey: ''));

        expect(results.map((r) => r.name), ['health']);
        expect(results.single.status, ProbeStatus.ok);
      },
    );
  });
}
