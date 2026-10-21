// Tests de resiliencia de red: el cliente debe degradar con gracia (sin crashes
// ni estados inconsistentes) cuando el gateway o el bridge fallan. Cubren:
//   • Gateway: error del servidor en el turno y respuesta que llega después
//     del cierre del turno (el chat solo habla por el socket del Dashboard,
//     como Desktop) y respuesta 5xx al lanzar un run (cliente REST).
//   • Bridge: 404 (endpoint inexistente), body 200 malformado y conexión
//     rechazada (SocketException).

import 'dart:async';
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

import 'support/desktop_chat_socket.dart';
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
    ActiveChat chatOn(
      DesktopChatSocket socket, {
      StoredSessionMessageLoader? loader,
      Duration budget = Duration.zero,
    }) {
      final chat = ActiveChat(
        compressionRestoreStore: testCompressionRestoreStore(),
        connection: _conn(),
        sessionId: 'sess-1',
        sessionTitle: 'X',
        notifications: null,
        onTerminal: () {},
        // The REST run API is gone from chat: any request fails the test.
        api: ApiClient(
          baseUrl: 'http://hermes.local:8642',
          apiKey: 'fixture',
          httpClient: HostCounter(),
        ),
        desktopGateway: socket,
        storedMessageLoader: loader ?? (_, _) async => const [],
        terminalReconcileBudget: budget,
      );
      addTearDown(chat.dispose);
      addTearDown(socket.close);
      return chat;
    }

    Future<void> until(bool Function() done, Duration limit) async {
      final deadline = DateTime.now().add(limit);
      while (!done() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    test(
      '1a. error del servidor en el turno: error seguro, sin detalle privado',
      () async {
        // El servidor termina el turno con un error cuyo texto lleva detalle
        // interno: el chat muestra el aviso seguro de siempre.
        final socket = DesktopChatSocket();
        final chat = chatOn(socket);
        final errored = chat.changes.firstWhere(
          (e) => e == ActiveChatEvent.error,
        );
        await chat.send(fullText: 'hola', model: 'm', history: const []);
        socket.fail(1, 'TimeoutException: sin respuesta del gateway\n#0 main');
        await errored.timeout(const Duration(seconds: 5));

        expect(chat.state, ChatPipelineState.failed);
        final top = chat.messages.first;
        expect(top['role'], 'assistant_error');
        final msg = (top['content'] as String?) ?? '';
        expect(msg, 'No se pudo completar la respuesta. Inténtalo de nuevo.');
        expect(msg, isNot(contains('Timeout')));
        expect(msg, isNot(contains('sin respuesta del gateway')));
        expect(msg, isNot(contains('#0')));
        expect(msg.trim(), isNotEmpty);
      },
    );

    test('1a-bis. turno cerrado con la respuesta ya en el servidor: reconcilia '
        'el transcript y la muestra, no falla', () async {
      // El turno termina sin texto, pero el servidor SÍ produjo la
      // respuesta: releer la conversación debe recuperarla.
      final socket = DesktopChatSocket();
      final chat = chatOn(
        socket,
        loader: (_, _) async => const [
          {'role': 'user', 'content': 'hola'},
          {'role': 'assistant', 'content': 'Aquí está la respuesta.'},
        ],
        budget: const Duration(seconds: 2),
      );
      await chat.send(fullText: 'hola', model: 'm', history: const []);
      socket.complete(1, '');
      await until(
        () => chat.state == ChatPipelineState.completed,
        const Duration(seconds: 5),
      );

      expect(chat.state, ChatPipelineState.completed);
      final answers = chat.messages.where((m) => m['role'] == 'assistant');
      expect(answers.last['content'], 'Aquí está la respuesta.');
    });

    test('1a-ter. el turno termina con la respuesta VACÍA (continuación '
        'post-aprobación tardía); aparece luego en el transcript y se rellena '
        'la burbuja sin recargar (bug S3)', () async {
      // El turno termina SIN entregar la respuesta final (como tras una
      // aprobación). El servidor tarda más que el presupuesto de reconciliación
      // en persistirla: al principio devuelve una burbuja VACÍA y solo después
      // el texto real.
      final clock = Stopwatch();
      final socket = DesktopChatSocket();
      final chat = chatOn(
        socket,
        loader: (_, _) async {
          final answered =
              clock.isRunning &&
              clock.elapsed > const Duration(milliseconds: 600);
          return [
            {'role': 'user', 'content': 'hola'},
            {
              'role': 'assistant',
              'content': answered ? 'La respuesta final.' : '',
            },
          ];
        },
        budget: const Duration(milliseconds: 300),
      );
      await chat.send(fullText: 'hola', model: 'm', history: const []);
      clock.start();
      socket.complete(1, '');
      String? last() {
        final rows = chat.messages.where((m) => m['role'] == 'assistant');
        return rows.isEmpty ? null : rows.last['content'] as String?;
      }

      await until(
        () => last() == 'La respuesta final.',
        const Duration(seconds: 8),
      );

      expect(last(), 'La respuesta final.');
    });
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
