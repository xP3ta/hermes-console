// Tests de resiliencia de red: el cliente debe degradar con gracia (sin crashes
// ni estados inconsistentes) cuando el gateway o el bridge fallan. Cubren:
//   • Gateway: timeout durante el stream del run y respuesta 5xx al lanzarlo.
//   • Bridge: 404 (endpoint inexistente), body 200 malformado y conexión
//     rechazada (SocketException).
//
// Nota: el gateway NO se sondea con un `pollRun`; consume el run por SSE
// (`ApiClient.streamRunEvents`). El "timeout en el poll" se ejerce, por tanto,
// sobre ese stream real a través de `ActiveChat` (la capa que ve el usuario).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/main.dart'
    show NetworkAvailabilityRecoveryListener;

import 'support/in_memory_compression_restore_storage.dart';

SavedConnection _conn() => SavedConnection(
  id: 'conn-1',
  label: 'Test',
  host: 'hermes.local',
  port: 8642,
  apiKey: 'test-key',
);

void main() {
  group('Gateway — resiliencia de red', () {
    test(
      '1a. timeout en el stream del run: error seguro, sin detalle privado',
      () async {
        // startRun responde (con ~200ms de latencia), pero el SSE de eventos se
        // cuelga y lanza TimeoutException en el primer (y único) intento.
        final client = MockClient((request) async {
          final path = request.url.path;
          if (request.method == 'POST' && path == '/v1/runs') {
            await Future<void>.delayed(const Duration(milliseconds: 200));
            return http.Response(jsonEncode({'run_id': 'run_1'}), 200);
          }
          if (request.method == 'GET' && path == '/v1/runs/run_1/events') {
            throw TimeoutException('sin respuesta del gateway');
          }
          return http.Response('not found', 404);
        });
        final api = ApiClient(
          baseUrl: 'http://hermes.local:8642',
          apiKey: 'k',
          httpClient: client,
        );
        final chat = ActiveChat(
          compressionRestoreStore: testCompressionRestoreStore(),
          connection: _conn(),
          sessionId: 'sess-1',
          sessionTitle: 'X',
          notifications: null,
          onTerminal: () {},
          api: api,
        );

        final errored = chat.changes.firstWhere(
          (e) => e == ActiveChatEvent.error,
        );
        chat.send(fullText: 'hola', model: 'm', history: const []);
        await errored.timeout(const Duration(seconds: 5));

        expect(chat.state, ChatPipelineState.failed);
        final top = chat.messages.first;
        expect(top['role'], 'assistant_error');
        final msg = (top['content'] as String?) ?? '';
        expect(msg, 'No se pudo recuperar el turno. Inténtalo de nuevo.');
        expect(msg, isNot(contains('Timeout')));
        expect(msg, isNot(contains('sin respuesta del gateway')));
        expect(msg, isNot(contains('#0')));
        expect(msg.trim(), isNotEmpty);

        chat.dispose();
      },
    );

    test(
      '1a-bis. corte del stream con la respuesta ya en el servidor: reconcilia '
      'el transcript y la muestra, no falla',
      () async {
        // startRun responde, pero el SSE se cae a mitad. La diferencia con 1a: el
        // servidor SÍ produjo la respuesta del turno, así que releer la
        // conversación (getMessages) debe recuperarla en vez de dejar un error.
        final client = MockClient((request) async {
          final path = request.url.path;
          if (request.method == 'POST' && path == '/v1/runs') {
            await Future<void>.delayed(const Duration(milliseconds: 30));
            return http.Response(jsonEncode({'run_id': 'run_1'}), 200);
          }
          if (request.method == 'GET' && path == '/v1/runs/run_1/events') {
            throw const SocketException('stream caído a mitad');
          }
          if (request.method == 'GET' &&
              path == '/api/sessions/sess-1/messages') {
            return http.Response(
              jsonEncode({
                'data': [
                  {'role': 'user', 'content': 'hola'},
                  {'role': 'assistant', 'content': 'Aquí está la respuesta.'},
                ],
              }),
              200,
            );
          }
          return http.Response('not found', 404);
        });
        final api = ApiClient(
          baseUrl: 'http://hermes.local:8642',
          apiKey: 'k',
          httpClient: client,
        );
        final chat = ActiveChat(
          compressionRestoreStore: testCompressionRestoreStore(),
          connection: _conn(),
          sessionId: 'sess-1',
          sessionTitle: 'X',
          notifications: null,
          onTerminal: () {},
          api: api,
        );

        chat.send(fullText: 'hola', model: 'm', history: const []);
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (chat.state != ChatPipelineState.completed &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }

        expect(chat.state, ChatPipelineState.completed);
        expect(chat.messages.first['role'], 'assistant');
        expect(chat.messages.first['content'], 'Aquí está la respuesta.');

        chat.dispose();
      },
    );

    test('1a-ter. el turno termina con la respuesta VACÍA (continuación '
        'post-aprobación tardía); aparece luego en el transcript y se rellena '
        'la burbuja sin recargar (bug S3)', () async {
      // startRun responde y el SSE del run termina SIN entregar la respuesta
      // final (como tras una aprobación: la continuación no llega por ese SSE).
      // El servidor tarda un poco más que el presupuesto de reconciliación de
      // _completeRun en persistir la respuesta: al principio getMessages
      // devuelve una burbuja de asistente VACÍA y solo después el texto real.
      final clock = Stopwatch();
      final client = MockClient((request) async {
        final path = request.url.path;
        if (request.method == 'POST' && path == '/v1/runs') {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return http.Response(jsonEncode({'run_id': 'run_1'}), 200);
        }
        if (request.method == 'GET' && path == '/v1/runs/run_1/events') {
          if (!clock.isRunning) clock.start();
          // Stream vacío que cierra limpio → onDone sin texto final.
          return http.Response('', 200);
        }
        if (request.method == 'GET' &&
            path == '/api/sessions/sess-1/messages') {
          final answered =
              clock.isRunning &&
              clock.elapsed > const Duration(milliseconds: 600);
          return http.Response(
            jsonEncode({
              'data': [
                {'role': 'user', 'content': 'hola'},
                {
                  'role': 'assistant',
                  'content': answered ? 'La respuesta final.' : '',
                },
              ],
            }),
            200,
          );
        }
        return http.Response('not found', 404);
      });
      final api = ApiClient(
        baseUrl: 'http://hermes.local:8642',
        apiKey: 'k',
        httpClient: client,
      );
      final chat = ActiveChat(
        compressionRestoreStore: testCompressionRestoreStore(),
        connection: _conn(),
        sessionId: 'sess-1',
        sessionTitle: 'X',
        notifications: null,
        onTerminal: () {},
        api: api,
        // Presupuesto corto: el reconcile de _completeRun se rinde vacío y debe
        // ser la recuperación de fondo la que rellene la respuesta tardía.
        terminalReconcileBudget: const Duration(milliseconds: 300),
      );

      chat.send(fullText: 'hola', model: 'm', history: const []);
      final deadline = DateTime.now().add(const Duration(seconds: 8));
      while ((chat.messages.isEmpty ||
              chat.messages.first['content'] != 'La respuesta final.') &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }

      expect(chat.messages.first['role'], 'assistant');
      expect(chat.messages.first['content'], 'La respuesta final.');

      chat.dispose();
    });

    test(
      '1b. respuesta 503 al lanzar el run incluye el código en el mensaje',
      () async {
        final api = ApiClient(
          baseUrl: 'http://hermes.local:8642',
          apiKey: 'k',
          httpClient: MockClient(
            (request) async => http.Response('service overloaded', 503),
          ),
        );

        await expectLater(
          () => api.startRun(input: 'hola', sessionId: 'sess-1', model: 'm'),
          throwsA(
            predicate(
              (e) => e.toString().contains('503'),
              'mensaje contiene el código 503',
            ),
          ),
        );
        api.close();
      },
    );
  });

  test('online events wake recovery and stop after listener disposal', () {
    fakeAsync((async) {
      final events = StreamController<dynamic>.broadcast();
      var wakeCalls = 0;
      final listener = NetworkAvailabilityRecoveryListener(
        events: events.stream,
        onAvailable: () => wakeCalls += 1,
      );

      events.add(null);
      async.elapse(NetworkAvailabilityRecoveryListener.debounce);
      expect(wakeCalls, 1);

      unawaited(listener.dispose());
      events.add(null);
      async.elapse(NetworkAvailabilityRecoveryListener.debounce);
      expect(wakeCalls, 1);
      unawaited(events.close());
    });
  });

  test('an onAvailable burst is debounced into one probe; onLost only '
      'marks sockets stale', () {
    fakeAsync((async) {
      final events = StreamController<dynamic>.broadcast();
      var wakeCalls = 0;
      var lostCalls = 0;
      final listener = NetworkAvailabilityRecoveryListener(
        events: events.stream,
        onAvailable: () => wakeCalls += 1,
        onLost: () => lostCalls += 1,
      );
      // Logcat showed several "network available" per second on Wi-Fi
      // re-association: one probe per owner, not one per event.
      for (var i = 0; i < 5; i++) {
        events.add('available');
        async.elapse(const Duration(milliseconds: 300));
      }
      expect(wakeCalls, 0);
      async.elapse(NetworkAvailabilityRecoveryListener.debounce);
      expect(wakeCalls, 1);

      events.add('lost');
      async.elapse(const Duration(seconds: 5));
      expect(lostCalls, 1);
      expect(wakeCalls, 1, reason: 'loss never triggers a reconnect storm');
      unawaited(listener.dispose());
      unawaited(events.close());
    });
  });

  group('official Dashboard network resilience', () {
    DashboardClient client(MockClient transport) => DashboardClient(
      host: 'fixture.invalid',
      useHttps: true,
      manualToken: 'synthetic-canary',
      httpClientOverride: transport,
    );
    test('404 HTML is a typed HTTP cause, not a JSON parse failure', () async {
      final c = client(
        MockClient((_) async => http.Response('<html>not found</html>', 404)),
      );
      addTearDown(c.close);
      await expectLater(
        c.apiGet('model/info'),
        throwsA(
          isA<DashboardHttpException>().having(
            (e) => e.statusCode,
            'status',
            404,
          ),
        ),
      );
    });
    test(
      'malformed success is rejected rather than accepted as a catalog',
      () async {
        final c = client(
          MockClient((_) async => http.Response('<html>invalid</html>', 200)),
        );
        addTearDown(c.close);
        await expectLater(c.getModelInfo(), throwsA(isA<FormatException>()));
      },
    );
    test('connection refusal remains an honest unavailable failure', () async {
      final c = client(
        MockClient(
          (_) async => throw const SocketException('synthetic refusal'),
        ),
      );
      addTearDown(c.close);
      await expectLater(c.getModelInfo(), throwsA(isA<SocketException>()));
    });
  });
}
