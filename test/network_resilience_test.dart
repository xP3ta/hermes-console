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

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/bridge_client.dart';
import 'package:hermes_android/core/services/connection_manager.dart';

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
        expect(msg, 'Could not recover the turn. Please try again.');
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

  group('Bridge — resiliencia de red', () {
    BridgeClient bridge(MockClient client) => BridgeClient(
      baseUrl: 'http://hermes.local:9131',
      token: 'bridge-token',
      httpClient: client,
    );

    test(
      '1c. 404 en /bridge/chat → BridgeException con hint, no FormatException',
      () async {
        // Un endpoint inexistente suele devolver HTML (no JSON). El fix de _decode
        // (57d20de) debe convertirlo en un BridgeException legible en vez de
        // reventar al hacer jsonDecode del HTML.
        final client = bridge(
          MockClient(
            (request) async => http.Response(
              '<html><body>404 Not Found</body></html>',
              404,
              headers: {'content-type': 'text/html'},
            ),
          ),
        );

        await expectLater(
          client.chat('hola'),
          throwsA(
            allOf(
              isA<BridgeException>(),
              isNot(isA<FormatException>()),
              predicate(
                (e) => e.toString().contains('endpoint no disponible'),
                'incluye el hint "endpoint no disponible"',
              ),
            ),
          ),
        );
        client.close();
      },
    );

    test(
      '1d. body 200 malformado lanza una excepción manejable (no crash)',
      () async {
        // El cuerpo 2xx se decodifica sin try/catch en BridgeClient._decode, así
        // que un body no-JSON propaga un FormatException. Es CATCHABLE (no peta el
        // isolate) y el llamador lo maneja como cualquier error del turno.
        // TODO: requires refactor of BridgeClient._decode to wrap 2xx JSON parse
        // errors in a BridgeException with a human-readable message.
        final client = bridge(
          MockClient(
            (request) async => http.Response('<html>not json at all', 200),
          ),
        );

        await expectLater(client.chat('hola'), throwsA(isA<Exception>()));
        client.close();
      },
    );

    test(
      '1e. conexión rechazada (SocketException) en health → false, no lanza',
      () async {
        final client = bridge(
          MockClient(
            (request) async =>
                throw const SocketException('connection refused'),
          ),
        );

        // health() captura cualquier fallo de red y degrada a false sin propagar.
        expect(await client.health(), isFalse);
        client.close();
      },
    );
  });
}
