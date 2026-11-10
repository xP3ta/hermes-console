// Fold 9851 (chat c16d42): a turn redirected from the phone (`session.redirect`)
// is stored by Hermes as a hidden interrupt placeholder plus a PLAIN user row
// (no `display_kind=steer`). The durable read therefore lists the correction
// as a newer prompt, while locally it is a `_steer` row inside the same turn.
// Before the fix, after the app came back from the background:
// - a failed recovery kept «Error»: the newest durable prompt (the correction)
//   never matched the local open prompt, so durable success was never adopted;
// - a terminal fence on the redirected turn could never be covered, so every
//   refresh kept the truncated local turn and dropped the rows after it while
//   the durable tail was recorded as seen («tail-unchanged»);
// - once durable rows were adopted, the remembered correction was re-inserted
//   next to its plain durable echo (duplicate bubble).
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/in_memory_compression_restore_storage.dart';
import 'support/test_api_client.dart';

const _prompt = 'audita el repositorio';
const _correction = 'aclaración: la app será pública';
const _finalText = 'informe final: todo revisado';

Map<String, dynamic> _call(String id) => {
  'id': id,
  'type': 'function',
  'function': {'name': 'terminal', 'arguments': '{}'},
};

/// REST rows (`/api/sessions/:id/messages`) of the real case's shape: an
/// older closed turn, the redirected turn cut on a tool batch, the hidden
/// interrupt placeholder, the correction as a plain user row and the work
/// that followed up to the final.
List<Map<String, dynamic>> _durableRows({
  bool withFinal = true,
  String correction = _correction,
}) => [
  {'id': 10, 'role': 'user', 'content': 'hola'},
  {
    'id': 11,
    'role': 'assistant',
    'content': 'hola, ¿qué hacemos?',
    'finish_reason': 'stop',
  },
  {'id': 12, 'role': 'user', 'content': _prompt},
  {
    'id': 13,
    'role': 'assistant',
    'content': '',
    'tool_calls': [_call('c1')],
    'finish_reason': 'tool_calls',
  },
  {'id': 14, 'role': 'tool', 'tool_call_id': 'c1', 'content': 'ok'},
  {'id': 15, 'role': 'assistant', 'content': '', 'display_kind': 'hidden'},
  {'id': 16, 'role': 'user', 'content': correction},
  {
    'id': 17,
    'role': 'assistant',
    'content': '',
    'tool_calls': [_call('c2')],
    'finish_reason': 'tool_calls',
  },
  {'id': 18, 'role': 'tool', 'tool_call_id': 'c2', 'content': 'hecho'},
  if (withFinal)
    {
      'id': 19,
      'role': 'assistant',
      'content': _finalText,
      'finish_reason': 'stop',
    },
];

class _Server {
  _Server(this.rows);

  final List<Map<String, dynamic>> rows;
  int reads = 0;

  http.Client client() => MockClient((request) async {
    reads++;
    final limit = int.parse(request.url.queryParameters['limit'] ?? '500');
    final offset = int.parse(request.url.queryParameters['offset'] ?? '0');
    final end = math.max(0, rows.length - offset);
    final start = math.max(0, end - limit);
    final page = rows.sublist(start, end);
    return http.Response(
      jsonEncode({
        'object': 'list',
        'session_id': 'stored-chat',
        'data': page,
        'pagination': {
          'limit': limit,
          'offset': offset,
          'order': 'latest',
          'returned': page.length,
        },
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  });
}

/// The Fold had a socket: a gateway that connects and resumes as a no-op.
class _QuietGateway implements HermesDesktopGateway {
  final _events = StreamController<TuiGatewayEvent>.broadcast();
  bool _connected = false;

  @override
  Stream<TuiGatewayEvent> get events => _events.stream;
  @override
  bool get isConnected => _connected;
  @override
  Future<void> connect() async {
    _connected = true;
  }
  @override
  Future<DesktopSessionBinding> resumeSession(
    String storedSessionId, {
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => DesktopSessionBinding(
    runtimeSessionId: 'runtime-quiet',
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
  Future<void> close() async {
    _connected = false;
    await _events.close();
  }
}

ActiveChat _chat(
  _Server server, {
  int pageSize = 120,
  HermesDesktopGateway? gateway,
  bool redirected = true,
}) => ActiveChat(
  compressionRestoreStore: testCompressionRestoreStore(),
  desktopGateway: gateway,
  allowUnownedDesktopSnapshotForTesting: true,
  transcriptPageSizeForTesting: pageSize,
  connection: SavedConnection(
    id: 'stale-resume',
    label: 'stale-resume',
    host: '127.0.0.1',
    port: 8642,
    apiKey: 'test-key',
    kind: InstanceKind.vps,
  ),
  sessionId: 'stored-chat',
  sessionTitle: 'stale-resume',
  notifications: null,
  onTerminal: () {},
  api: testApiClient(
    baseUrl: 'http://127.0.0.1:8642',
    httpClient: server.client(),
  ),
  // The phone redirected the second turn (user ordinal 1) with this text.
  initialSteerProjections: redirected
      ? const [
          (
            anchorUserOrdinal: 1,
            content: _correction,
            anchorUserContent: _prompt,
          ),
        ]
      : const [],
);

/// What the phone showed: the older turn, its own prompt, the correction it
/// sent mid-turn, the partial reply cut when the socket went away and the
/// recovery error that left the header in «Error».
List<Map<String, dynamic>> _failedLocalProjection() => [
  {
    'role': 'assistant_error',
    'content': activeChatDesktopRecoveryUiMessage(''),
    '_prompt': _prompt,
  },
  {'role': 'assistant', 'content': 'revisando', '_cancelled': true},
  {
    'role': 'user',
    'content': _correction,
    '_steer': true,
    '_optimistic': true,
  },
  {'role': 'user', 'content': _prompt},
  {
    'id': 11,
    'role': 'assistant',
    'content': 'hola, ¿qué hacemos?',
  },
  {'id': 10, 'role': 'user', 'content': 'hola'},
];

int _count(ActiveChat chat, String text) => chat.messages
    .where((message) => message['content'] == text)
    .length;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('redirected turn finished while the app was away', () {
    for (final withGateway in [false, true]) {
    test('resume adopts the durable turn once and clears the recovery error '
        '(gateway: $withGateway)', () async {
      final server = _Server(_durableRows());
      final chat = _chat(
        server,
        gateway: withGateway ? _QuietGateway() : null,
      );
      addTearDown(chat.dispose);
      chat.internalMessagesForTesting = _failedLocalProjection();
      chat.state = ChatPipelineState.failed;
      chat.messagesLoaded = true;

      expect(await chat.reconcileAfterResume(), isTrue);

      expect(chat.state, ChatPipelineState.completed);
      expect(
        chat.messages.where((m) => m['role'] == 'assistant_error'),
        isEmpty,
      );
      expect(_count(chat, _finalText), 1);
      expect(_count(chat, _prompt), 1);
      expect(_count(chat, _correction), 1);

      // The next passive reads must not re-insert the remembered correction
      // beside its plain durable echo, nor change the projection again.
      await chat.loadMessages(passiveOnly: true);
      final settled = chat.messages
          .map((m) => '${m['role']}:${m['content']}')
          .toList(growable: false);
      expect(_count(chat, _correction), 1);
      expect(_count(chat, _finalText), 1);
      expect(chat.messages.where((m) => m['_steer'] == true), isEmpty);
      await chat.loadMessages(passiveOnly: true);
      expect(
        chat.messages.map((m) => '${m['role']}:${m['content']}').toList(),
        settled,
      );
      expect(chat.state, ChatPipelineState.completed);
    });
    }

    test('a turn still without its final keeps the error', () async {
      final server = _Server(_durableRows(withFinal: false));
      final chat = _chat(server);
      addTearDown(chat.dispose);
      chat.internalMessagesForTesting = _failedLocalProjection();
      chat.state = ChatPipelineState.failed;
      chat.messagesLoaded = true;

      expect(await chat.reconcileAfterResume(), isFalse);

      expect(chat.state, ChatPipelineState.failed);
      expect(chat.messages.first['role'], 'assistant_error');
      expect(_count(chat, _finalText), 0);
    });

    test('a newer prompt that is not this turn\'s correction keeps the error',
        () async {
      final server = _Server(_durableRows(correction: 'otra petición'));
      final chat = _chat(server);
      addTearDown(chat.dispose);
      chat.internalMessagesForTesting = _failedLocalProjection();
      chat.state = ChatPipelineState.failed;
      chat.messagesLoaded = true;

      expect(await chat.reconcileAfterResume(), isFalse);

      expect(chat.state, ChatPipelineState.failed);
      expect(chat.messages.first['role'], 'assistant_error');
    });
  });

  group('terminal fence on a redirected turn', () {
    /// The phone saw the turn end live (fenced, awaiting its durable copy)
    /// but missed the work after the correction.
    List<Map<String, dynamic>> fencedLocalProjection() => [
      {
        'role': 'assistant',
        'content': 'revisando',
        '_localTerminalProjectionId': 'terminal-7',
      },
      {
        'role': 'user',
        'content': _correction,
        '_steer': true,
        '_optimistic': true,
        '_localTerminalProjectionId': 'terminal-7',
      },
      {
        'role': 'user',
        'content': _prompt,
        '_localTerminalProjectionId': 'terminal-7',
        '_localTerminalAnchorRowId': 11,
        '_localTerminalOrdinalAfterAnchor': 1,
      },
      {
        'id': 11,
        'role': 'assistant',
        'content': 'hola, ¿qué hacemos?',
      },
      {'id': 10, 'role': 'user', 'content': 'hola'},
    ];

    test('a partial page paints the rows after the correction once', () async {
      final server = _Server(_durableRows());
      // Newest 9 of 10 rows: the page holds the fenced prompt, not row 10.
      final chat = _chat(server, pageSize: 9);
      addTearDown(chat.dispose);
      chat.internalMessagesForTesting = fencedLocalProjection();
      chat.state = ChatPipelineState.completed;
      chat.messagesLoaded = true;

      await chat.loadMessages(passiveOnly: true);

      expect(_count(chat, _finalText), 1);
      expect(_count(chat, _prompt), 1);
      expect(_count(chat, _correction), 1);
      expect(_count(chat, 'revisando'), 0);
      expect(_count(chat, 'hola'), 1);
      expect(
        chat.messages.where((m) => m['_localTerminalProjectionId'] != null),
        isEmpty,
      );
      // The newest durable row is now on screen: the tail probe may say so.
      final probe = await chat.probePassiveDurableTail();
      expect(probe?.unchanged, isTrue);
      final settled = chat.messages
          .map((m) => '${m['role']}:${m['content']}')
          .toList(growable: false);
      await chat.loadMessages(passiveOnly: true);
      expect(
        chat.messages.map((m) => '${m['role']}:${m['content']}').toList(),
        settled,
      );
    });

    // Decision: Desktop parity (the server leads). Another surface's newer
    // stored turn closes the fence, so the phone's own stopped final that
    // Hermes never stored is dropped, exactly as Desktop paints the REST tail
    // and keeps no never-saved local final: apps/desktop/src/app/session/
    // hooks/use-session-actions/index.ts:2115-2139 and utils.ts:1181-1270.
    // Guarding the rule with "only a redirected turn" would keep that final
    // but hide the other surface's STORED turn on every refresh (the bug
    // stale-resume fixed), so no guard is shipped.
    test('another surface\'s newer turn replaces an own stopped turn that '
        'was never stored (server leads, Desktop parity)', () async {
      const ownPartial = 'mi respuesta parcial, detenida';
      final server = _Server([
        {'id': 10, 'role': 'user', 'content': 'hola'},
        {
          'id': 11,
          'role': 'assistant',
          'content': 'hola, ¿qué hacemos?',
          'finish_reason': 'stop',
        },
        // The phone's own prompt reached the server; its stopped final not.
        {'id': 12, 'role': 'user', 'content': _prompt},
        // Then the desktop asked and finished a turn of its own.
        {'id': 20, 'role': 'user', 'content': 'pregunta del escritorio'},
        {
          'id': 21,
          'role': 'assistant',
          'content': 'respuesta del escritorio',
          'finish_reason': 'stop',
        },
      ]);
      // No redirect anywhere: no remembered correction either.
      final chat = _chat(server, redirected: false);
      addTearDown(chat.dispose);
      chat.internalMessagesForTesting = [
        {
          'role': 'assistant',
          'content': ownPartial,
          '_localTerminalProjectionId': 'terminal-9',
        },
        {
          'role': 'user',
          'content': _prompt,
          '_localTerminalProjectionId': 'terminal-9',
          '_localTerminalAnchorRowId': 11,
          '_localTerminalOrdinalAfterAnchor': 1,
        },
        {
          'id': 11,
          'role': 'assistant',
          'content': 'hola, ¿qué hacemos?',
        },
        {'id': 10, 'role': 'user', 'content': 'hola'},
      ];
      chat.state = ChatPipelineState.completed;
      chat.messagesLoaded = true;

      await chat.loadMessages(passiveOnly: true);

      // The never-stored local final is gone: the server's tail is painted.
      expect(
        _count(chat, ownPartial),
        0,
        reason: 'unsaved local final dropped',
      );
      // The own prompt is stored, so it shows once (not duplicated by the
      // local projection).
      expect(_count(chat, _prompt), 1);
      expect(_count(chat, _correction), 0);
      // The other surface's stored turn is shown once, not hidden.
      expect(_count(chat, 'pregunta del escritorio'), 1);
      expect(_count(chat, 'respuesta del escritorio'), 1);
      final settled = chat.messages
          .map((m) => '${m['role']}:${m['content']}')
          .toList(growable: false);
      await chat.loadMessages(passiveOnly: true);
      expect(
        chat.messages.map((m) => '${m['role']}:${m['content']}').toList(),
        settled,
      );
      expect(_count(chat, 'respuesta del escritorio'), 1);
    });

    test('a newer turn without its final keeps the fenced local turn',
        () async {
      final server = _Server(_durableRows(withFinal: false));
      final chat = _chat(server, pageSize: 8);
      addTearDown(chat.dispose);
      chat.internalMessagesForTesting = fencedLocalProjection();
      chat.state = ChatPipelineState.completed;
      chat.messagesLoaded = true;

      await chat.loadMessages(passiveOnly: true);

      expect(_count(chat, 'revisando'), 1);
      expect(_count(chat, _prompt), 1);
    });
  });
}
