// A failed `message.complete` and a resumed failed `inflight` keep the layer,
// code, retryable and usage-limit reset of the gateway's `error_surface` (and
// the `billing` block) on the `assistant_error` row, sanitized.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/models/turn_error_surface.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/session_reconciler.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/in_memory_compression_restore_storage.dart';

class _FakeDesktopGateway implements HermesDesktopGateway {
  final StreamController<TuiGatewayEvent> _events =
      StreamController<TuiGatewayEvent>.broadcast(sync: true);

  @override
  Stream<TuiGatewayEvent> get events => _events.stream;

  @override
  bool get isConnected => true;

  @override
  Future<void> connect() async {}

  @override
  Future<DesktopSessionBinding> resumeSession(
    String storedSessionId, {
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => DesktopSessionBinding(
    runtimeSessionId: 'runtime-surface',
    storedSessionId: storedSessionId,
    created: false,
  );

  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async {}

  @override
  Future<void> steer(String runtimeSessionId, String text) async {}

  @override
  Future<void> interrupt(String runtimeSessionId) async {}

  @override
  Future<void> resolveApproval(
    String runtimeSessionId,
    String choice, {
    bool resolveAll = false,
    String? requestId,
  }) async {}

  @override
  Future<void> close() async {}

  void emit(String type, Map<String, dynamic> payload) => _events.add(
    TuiGatewayEvent(
      type: type,
      sessionId: 'runtime-surface',
      payload: Map<String, dynamic>.unmodifiable(payload),
    ),
  );
}

Future<ActiveChat> _liveChat(_FakeDesktopGateway gateway) async {
  final chat = ActiveChat(
    compressionRestoreStore: testCompressionRestoreStore(),
    connection: SavedConnection(
      id: 'conn-surface',
      label: 'Surface',
      host: 'example.invalid',
      port: 443,
      apiKey: 'unused',
      useHttps: true,
      kind: InstanceKind.vps,
    ),
    sessionId: 'stored-surface',
    sessionTitle: 'Surface',
    notifications: null,
    onTerminal: () {},
    api: ApiClient(
      baseUrl: 'https://example.invalid',
      apiKey: 'unused',
      httpClient: MockClient((_) async => http.Response('unused', 500)),
    ),
    desktopGateway: gateway,
  );
  addTearDown(chat.dispose);
  expect(
    await chat.send(fullText: 'hola', model: 'hermes-agent', history: const []),
    isTrue,
  );
  return chat;
}

Map<String, dynamic> _errorRow(ActiveChat chat) =>
    chat.messages.firstWhere((row) => row['role'] == 'assistant_error');

Map<String, dynamic> _failure({
  Object? surface,
  Object? billing,
  String status = 'error',
}) => {
  'text': '',
  'status': status,
  'error': 'Rate limited by the provider',
  'message': 'Rate limited by the provider',
  'recoverable': true,
  'error_surface': surface,
  'billing': billing,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('message.complete', () {
    test('a failed turn keeps the sanitized error surface', () async {
      final gateway = _FakeDesktopGateway();
      final chat = await _liveChat(gateway);
      gateway.emit(
        'message.complete',
        _failure(
          surface: {
            'layer': 'provider',
            'code': 'rate_limit',
            'retryable': true,
            'provider': 'anthropic',
            'provider_label': 'Anthropic',
            'model': 'claude-example',
            'resets_at': 1790000000.5,
            'message': '  Try again later  ',
            'raw_provider_body': 'must not be kept',
          },
        ),
      );
      await Future<void>.delayed(Duration.zero);

      final stored = _errorRow(chat)[turnErrorSurfaceKey];
      expect(stored, {
        'layer': 'provider',
        'code': 'rate_limit',
        'retryable': true,
        'provider': 'anthropic',
        'provider_label': 'Anthropic',
        'model': 'claude-example',
        'message': 'Try again later',
        'resets_at': 1790000000.5,
      });
      expect(_errorRow(chat).containsKey(turnBillingBlockKey), isFalse);
    });

    test('error_surface null leaves no key', () async {
      final gateway = _FakeDesktopGateway();
      final chat = await _liveChat(gateway);
      gateway.emit('message.complete', _failure());
      await Future<void>.delayed(Duration.zero);

      expect(_errorRow(chat).containsKey(turnErrorSurfaceKey), isFalse);
      expect(_errorRow(chat).containsKey(turnBillingBlockKey), isFalse);
    });

    test('an unknown layer leaves no key', () async {
      final gateway = _FakeDesktopGateway();
      final chat = await _liveChat(gateway);
      gateway.emit(
        'message.complete',
        _failure(surface: {'layer': 'mystery', 'code': 'rate_limit'}),
      );
      await Future<void>.delayed(Duration.zero);

      expect(_errorRow(chat).containsKey(turnErrorSurfaceKey), isFalse);
    });

    test('a billing block keeps the label, Nous flag, https URL and '
        'first line', () async {
      final gateway = _FakeDesktopGateway();
      final chat = await _liveChat(gateway);
      gateway.emit(
        'message.complete',
        _failure(
          surface: {'layer': 'billing', 'code': 'billing', 'retryable': false},
          billing: {
            'provider': 'example',
            'provider_label': 'Example AI',
            'model': 'm',
            'billing_url': 'https://billing.example.test/top-up',
            'is_nous': false,
            'message': 'Out of credits.\nAdd funds to continue.',
          },
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(_errorRow(chat)[turnBillingBlockKey], {
        'provider_label': 'Example AI',
        'is_nous': false,
        'billing_url': 'https://billing.example.test/top-up',
        'message': 'Out of credits.',
      });
    });

    test('a billing block with a plain http URL drops the URL', () async {
      final gateway = _FakeDesktopGateway();
      final chat = await _liveChat(gateway);
      gateway.emit(
        'message.complete',
        _failure(
          billing: {
            'provider_label': 'Example AI',
            'billing_url': 'http://billing.example.test/top-up',
            'is_nous': false,
            'message': 'Out of credits.',
          },
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(
        (_errorRow(chat)[turnBillingBlockKey] as Map).containsKey(
          'billing_url',
        ),
        isFalse,
      );
    });

    test('the standalone error event carries no surface', () async {
      final gateway = _FakeDesktopGateway();
      final chat = await _liveChat(gateway);
      gateway.emit('error', {'message': 'Boom'});
      await Future<void>.delayed(Duration.zero);

      expect(_errorRow(chat).containsKey(turnErrorSurfaceKey), isFalse);
      expect(_errorRow(chat).containsKey(turnBillingBlockKey), isFalse);
    });
  });

  group('resumed inflight', () {
    DesktopSessionSnapshot snapshotWith(Map<String, Object?> surface) =>
        DesktopSessionSnapshot.fromJson(
          {
            'session_id': 'runtime-surface',
            'session_key': 'stored-1',
            'info': {'provider': 'anthropic'},
            'inflight': {
              'user': 'resume',
              'assistant': '',
              'streaming': false,
              'error': 'Rate limited by the provider',
              'status': 'error',
              'recoverable': true,
              'error_surface': surface,
            },
            'running': false,
            'status': 'idle',
          },
          requestedStoredSessionId: 'stored-1',
          created: false,
          method: 'session.resume',
        );

    test('resets_at and message survive the snapshot scalars', () {
      final snapshot = snapshotWith({
        'layer': 'provider',
        'code': 'rate_limit',
        'retryable': true,
        'resets_at': 1790000000.5,
        'message': 'Try again later',
      });
      expect(snapshot.inflight!.errorSurface['resets_at'], 1790000000.5);
      expect(snapshot.inflight!.errorSurface['message'], 'Try again later');
    });

    test('a non-positive resets_at and a blank message are not kept', () {
      final snapshot = snapshotWith({
        'layer': 'provider',
        'code': 'rate_limit',
        'resets_at': 0,
        'message': '   ',
      });
      expect(snapshot.inflight!.errorSurface.containsKey('resets_at'), isFalse);
      expect(snapshot.inflight!.errorSurface.containsKey('message'), isFalse);
    });

    test('the reconciled error row carries the surface with its reset', () {
      final projected = const DesktopSessionReconciler().project(
        snapshotWith({
          'layer': 'provider',
          'code': 'rate_limit',
          'retryable': true,
          'provider': 'anthropic',
          'resets_at': 1790000000.5,
        }),
      );
      final error = projected.messagesNewestFirst.first;
      expect(error['role'], 'assistant_error');
      expect(
        TurnErrorSurface.parse(error[turnErrorSurfaceKey])!.resetsAt,
        1790000000.5,
      );
    });

    test('an inflight without a surface keeps no key', () {
      final projected = const DesktopSessionReconciler().project(
        DesktopSessionSnapshot.fromJson(
          {
            'session_id': 'runtime-surface',
            'session_key': 'stored-1',
            'inflight': {
              'user': 'resume',
              'assistant': '',
              'streaming': false,
              'error': 'Boom',
              'status': 'error',
            },
            'running': false,
            'status': 'idle',
          },
          requestedStoredSessionId: 'stored-1',
          created: false,
          method: 'session.resume',
        ),
      );
      expect(
        projected.messagesNewestFirst.first.containsKey(turnErrorSurfaceKey),
        isFalse,
      );
    });
  });

  group('provider wait notices', () {
    const wait = '⏳ waiting on provider…';

    Future<(_FakeDesktopGateway, ActiveChat)> live() async {
      final gateway = _FakeDesktopGateway();
      return (gateway, await _liveChat(gateway));
    }

    String reasoningOf(ActiveChat chat) => chat.messages
        .where((row) => row['role'] == 'assistant')
        .map(
          (row) => [row['reasoning'], row[assistantActivityTraceKey]].join(' '),
        )
        .join(' ');

    test('a wait notice becomes the turn status, never reasoning', () async {
      final (gateway, chat) = await live();
      gateway.emit('thinking.delta', {'text': wait});
      await Future<void>.delayed(Duration.zero);

      expect(reasoningOf(chat), isNot(contains('waiting on provider')));
      expect(chat.providerWaitText, wait);
    });

    test('a decorative spinner phrase is not reasoning (as Desktop)', () async {
      final (gateway, chat) = await live();
      gateway.emit('thinking.delta', {'text': 'pondering…'});
      await Future<void>.delayed(Duration.zero);

      expect(chat.providerWaitText, isNull);
      expect(reasoningOf(chat), isNot(contains('pondering…')));
    });

    for (final event in const {
      'message.delta': {'text': 'Hola'},
      'message.interim': {'text': 'Hola'},
      'message.complete': {'text': 'Hola'},
      'error': {'message': 'Boom'},
      'tool.start': {'tool_id': 'call-1', 'name': 'read_file'},
      'reasoning.delta': {'text': 'real reasoning'},
    }.entries) {
      test('${event.key} clears the wait notice', () async {
        final (gateway, chat) = await live();
        gateway.emit('thinking.delta', {'text': wait});
        await Future<void>.delayed(Duration.zero);
        expect(chat.providerWaitText, wait);

        gateway.emit(event.key, event.value);
        await Future<void>.delayed(const Duration(milliseconds: 100));

        expect(chat.providerWaitText, isNull);
      });
    }

    test(
      'a decorative phrase after a wait notice clears the stale status',
      () async {
        final (gateway, chat) = await live();
        gateway.emit('reasoning.delta', {'text': 'checking the files'});
        gateway.emit('thinking.delta', {'text': wait});
        await Future<void>.delayed(Duration.zero);
        expect(chat.providerWaitText, wait);

        gateway.emit('thinking.delta', {'text': 'pondering…'});
        await Future<void>.delayed(Duration.zero);

        expect(chat.providerWaitText, isNull);
        expect(reasoningOf(chat), contains('checking the files'));
        expect(reasoningOf(chat), isNot(contains('pondering…')));
        expect(reasoningOf(chat), isNot(contains('waiting on provider')));
      },
    );

    test('a new notice replaces the previous one', () async {
      final (gateway, chat) = await live();
      gateway.emit('thinking.delta', {'text': wait});
      gateway.emit('thinking.delta', {'text': '⚠ no output for 30s'});
      await Future<void>.delayed(Duration.zero);

      expect(chat.providerWaitText, '⚠ no output for 30s');
    });

    test('a wait notice is announced to the screen', () async {
      final (gateway, chat) = await live();
      final emitted = <ActiveChatEvent>[];
      final subscription = chat.changes.listen(emitted.add);
      addTearDown(subscription.cancel);
      gateway.emit('thinking.delta', {'text': wait});
      await Future<void>.delayed(Duration.zero);

      expect(emitted, contains(ActiveChatEvent.toolProgress));
    });
  });
}
