import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/models/subagent_activity.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _ReconnectGateway
    implements HermesDesktopGateway, HermesDesktopSessionLifecycleGateway {
  final StreamController<TuiGatewayEvent> _events =
      StreamController<TuiGatewayEvent>.broadcast();

  bool _connected = false;
  int connectCalls = 0;
  int resumeExistingCalls = 0;
  int createCalls = 0;

  String get runtimeSessionId => 'runtime-parent-$resumeExistingCalls';

  @override
  Stream<TuiGatewayEvent> get events => _events.stream;

  @override
  bool get isConnected => _connected;

  @override
  Future<void> connect() async {
    connectCalls++;
    _connected = true;
  }

  void disconnectTransport() {
    _connected = false;
  }

  @override
  Future<DesktopSessionSnapshot> resumeExisting(
    String storedSessionId, {
    String profile = '',
    bool omitMessages = false,
    bool deferHistory = false,
  }) async {
    resumeExistingCalls++;
    return DesktopSessionSnapshot.fromJson(
      {
        'session_id': runtimeSessionId,
        'session_key': storedSessionId,
        'messages': const [
          {'role': 'user', 'content': 'parent turn'},
          {'role': 'assistant', 'content': 'working'},
        ],
        'running': true,
        'status': 'working',
      },
      requestedStoredSessionId: storedSessionId,
      created: false,
      method: 'session.resume',
    );
  }

  @override
  Future<DesktopSessionSnapshot> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async {
    createCalls++;
    throw StateError('reconnect must never create a session');
  }

  @override
  Future<DesktopSessionBinding> resumeSession(
    String storedSessionId, {
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => throw StateError('legacy resume is outside this contract');

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

  void emit(String type, Map<String, dynamic> payload, {String? sessionId}) {
    _events.add(
      TuiGatewayEvent(
        type: type,
        sessionId: sessionId ?? runtimeSessionId,
        payload: payload,
      ),
    );
  }

  @override
  Future<void> close() async {
    _connected = false;
    if (!_events.isClosed) await _events.close();
  }
}

Future<void> _waitFor(
  bool Function() condition, {
  required String reason,
}) async {
  for (var attempt = 0; attempt < 100 && !condition(); attempt++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue, reason: reason);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'resume + replay tras reconexión reconstruye hijos sin duplicarlos',
    () async {
      final gateway = _ReconnectGateway();
      var restCalls = 0;
      final chat = ActiveChat(
        connection: SavedConnection(
          id: 't102-subagents',
          label: 'T102 subagents',
          host: 'example.invalid',
          port: 443,
          apiKey: 'test-only',
          useHttps: true,
          kind: InstanceKind.vps,
        ),
        sessionId: 'stored-parent',
        sessionTitle: 'T102 subagents',
        notifications: null,
        onTerminal: () {},
        api: ApiClient(
          baseUrl: 'https://example.invalid',
          apiKey: 'test-only',
          httpClient: MockClient((_) async {
            restCalls++;
            return http.Response('unexpected REST', 500);
          }),
        ),
        desktopGateway: gateway,
      );
      addTearDown(() async {
        chat.dispose();
        await gateway.close();
      });

      await chat.loadMessages();
      expect(chat.state, ChatPipelineState.executing);
      expect(gateway.resumeExistingCalls, 1);
      expect(gateway.createCalls, 0);
      // Paridad con Desktop: transcript REST y resume arrancan en paralelo.
      expect(restCalls, 1);

      gateway.emit('subagent.start', const {
        'subagent_id': 'child-before-disconnect',
        'child_session_id': 'child-session-a',
        'goal': 'goal preserved across runtime aliases',
        'event_id': 'child-a-start',
        'event_revision': 1,
        'status': 'running',
      });
      await _waitFor(
        () => chat.subagentActivities.length == 1,
        reason: 'el hijo vivo debe aparecer antes de perder el transporte',
      );

      gateway.disconnectTransport();
      expect(await chat.ensureDesktopRuntime(), isTrue);
      expect(gateway.resumeExistingCalls, 2);
      expect(gateway.createCalls, 0);
      expect(restCalls, 1);

      gateway.emit('subagent.complete', const {
        'subagent_id': 'child-before-disconnect',
        'child_session_id': 'child-session-a',
        'event_id': 'child-a-complete',
        'event_revision': 2,
        'status': 'completed',
        'summary': 'completed after reconnect',
      });
      // El start se perdió, pero un terminal autoritativo reconstruye la fila.
      gateway.emit('subagent.complete', const {
        'subagent_id': 'child-terminal-only',
        'event_id': 'child-b-complete',
        'event_revision': 4,
        'status': 'failed',
      });
      // Replays y eventos vivos tardíos no duplican ni reabren terminales.
      gateway.emit('subagent.complete', const {
        'subagent_id': 'child-terminal-only',
        'event_id': 'child-b-complete',
        'event_revision': 4,
        'status': 'failed',
      });
      gateway.emit('subagent.progress', const {
        'subagent_id': 'child-before-disconnect',
        'event_id': 'child-a-late-progress',
        'event_revision': 3,
        'task_index': 1,
        'task_count': 2,
      });
      gateway.emit('subagent.complete', const {
        'subagent_id': 'foreign-child',
        'status': 'completed',
      }, sessionId: 'runtime-other-parent');

      await _waitFor(
        () => chat.subagentActivities.length == 2,
        reason: 'deben quedar exactamente los dos hijos del runtime reanudado',
      );
      final byId = {
        for (final activity in chat.subagentActivities)
          activity.key.stableId: activity,
      };

      expect(byId.keys, {'child-before-disconnect', 'child-terminal-only'});
      expect(
        byId['child-before-disconnect']?.phase,
        SubagentActivityPhase.completed,
      );
      expect(
        byId['child-before-disconnect']?.goalPreview,
        'goal preserved across runtime aliases',
      );
      expect(byId['child-terminal-only']?.phase, SubagentActivityPhase.failed);
      expect(restCalls, 1);
      expect(gateway.createCalls, 0);
    },
  );
}
