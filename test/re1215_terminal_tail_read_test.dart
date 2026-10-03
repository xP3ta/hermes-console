// re1215: a turn that ends on a long chat must not re-download the whole
// session.
//
// Field log (server, 15:50:25–27): after every terminal Console fetched the
// complete transcript in 500-row pages, once from the blocking terminal
// reconcile and up to three more times from the late recovery. On a
// 2500-row chat that is 5 × 500 rows per read. The terminal only needs the
// newest page when that page proves the turn (its prompt and its reply).
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/in_memory_compression_restore_storage.dart';

class _Gateway
    implements HermesDesktopGateway, HermesDesktopSessionLifecycleGateway {
  final StreamController<TuiGatewayEvent> _events =
      StreamController<TuiGatewayEvent>.broadcast();
  late DesktopSessionSnapshot snapshot;

  @override
  Stream<TuiGatewayEvent> get events => _events.stream;

  @override
  bool get isConnected => true;

  @override
  Future<void> connect() async {}

  @override
  Future<DesktopSessionSnapshot> resumeExisting(
    String storedSessionId, {
    String profile = '',
    bool omitMessages = false,
    bool deferHistory = false,
  }) async => snapshot;

  @override
  Future<DesktopSessionSnapshot> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => throw StateError('must not create');

  @override
  Future<DesktopSessionBinding> resumeSession(
    String storedSessionId, {
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => throw StateError('legacy resume must not run');

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

  void emit(String type, {Map<String, dynamic> payload = const {}}) =>
      _events.add(
        TuiGatewayEvent(
          type: type,
          sessionId: snapshot.runtimeSessionId,
          payload: payload,
        ),
      );

  @override
  Future<void> close() async => _events.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// `/api/sessions/{id}/messages` with `order=latest` offsets counted back
/// from the newest row, integer row ids and ~1.7 KB per row.
class _Server {
  _Server(int rows) {
    for (var i = 1; i <= rows; i++) {
      append(i.isOdd ? 'user' : 'assistant');
    }
  }

  final rows = <Map<String, dynamic>>[];
  final requests = <Uri>[];
  var bytes = 0;

  void append(String role, {String? content, String? displayKind}) {
    final id = rows.length + 1;
    rows.add({
      'id': id,
      'role': role,
      'content': content ?? '$role $id ${'x' * 1700}',
      'display_kind': ?displayKind,
    });
  }

  /// `tui_gateway/server.py` `_append_model_switch_marker`: a `role=user`
  /// row persisted when the model changes, before the next prompt. Hermes
  /// 0.19 REST omitted `display_kind`; the text prefix still identifies it.
  void appendModelSwitch({bool withDisplayKind = true}) => append(
    'user',
    content:
        '[System: The active model for this chat has changed to gpt-5 via '
        'provider openai. From this point forward, use this runtime metadata '
        'when answering questions about what model/provider is active.]',
    displayKind: withDisplayKind ? 'model_switch' : null,
  );

  /// `tui_gateway/agent_callbacks.py`: the personality marker goes into the
  /// history and is flushed with the next turn, right before its prompt.
  void appendPersonalitySwitch() => append(
    'user',
    content:
        "[System: The user has changed the assistant's personality. From "
        'this point forward, adopt the following persona and respond '
        'accordingly: pirate]',
    displayKind: 'personality_switch',
  );

  http.Client client() => MockClient((request) async {
    requests.add(request.url);
    final limit = int.parse(request.url.queryParameters['limit'] ?? '500');
    final offset = int.parse(request.url.queryParameters['offset'] ?? '0');
    final end = math.max(0, rows.length - offset);
    final start = math.max(0, end - limit);
    final page = rows.sublist(start, end);
    final body = jsonEncode({
      'object': 'list',
      'session_id': 'stored-long',
      'data': page,
      'pagination': {
        'limit': limit,
        'offset': offset,
        'order': 'latest',
        'returned': page.length,
      },
    });
    bytes += utf8.encode(body).length;
    return http.Response(body, 200);
  });
}

ActiveChat _chat(_Server server, _Gateway gateway) => ActiveChat(
  compressionRestoreStore: testCompressionRestoreStore(),
  connection: SavedConnection(
    id: 'long-chat',
    label: 'long',
    host: '127.0.0.1',
    port: 8642,
    apiKey: 'k',
    kind: InstanceKind.vps,
  ),
  sessionId: 'stored-long',
  sessionTitle: 'Long chat',
  notifications: null,
  onTerminal: () {},
  api: ApiClient(
    baseUrl: 'http://127.0.0.1:8642',
    apiKey: 'k',
    httpClient: server.client(),
  ),
  desktopGateway: gateway,
  allowUnownedDesktopSnapshotForTesting: true,
);

Future<void> _settle() async {
  for (var i = 0; i < 40; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final commitBeforeTerminal in [true, false]) {
    final label = commitBeforeTerminal
        ? 'transcript committed before the terminal'
        : 'transcript committed 300 ms after the terminal';
    test(
      '2500-row chat: a turn end reads only the newest page ($label)',
      () async {
        final server = _Server(2500);
        final gateway = _Gateway()
          ..snapshot = const DesktopSessionSnapshot(
            runtimeSessionId: 'runtime-long',
            storedSessionId: 'stored-long',
            created: false,
            messagesProvided: false,
            messageCount: 2500,
          );
        final chat = _chat(server, gateway);
        addTearDown(chat.dispose);
        addTearDown(gateway.close);

        await chat.loadMessages(expectedMessageCount: 2500);
        await _settle();
        final openingIds = chat.messages.map((m) => m['id']).toList();

        await chat.send(
          fullText: 'Vale hazlo',
          model: 'hermes-agent',
          history: chat.buildHistory(),
        );
        final readsBefore = server.requests.length;
        final bytesBefore = server.bytes;

        void commit() {
          server.append('user', content: 'Vale hazlo');
          server.append('assistant', content: 'Respuesta final');
        }

        if (commitBeforeTerminal) commit();
        gateway.emit(
          'message.delta',
          payload: const {'text': 'Respuesta final'},
        );
        gateway.emit(
          'message.complete',
          payload: const {'text': 'Respuesta final'},
        );
        if (!commitBeforeTerminal) {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          commit();
        }
        await _settle();

        final terminalReads = server.requests.skip(readsBefore).toList();
        final terminalBytes = server.bytes - bytesBefore;
        // ignore: avoid_print
        print(
          '[re1215] terminal on 2500 rows ($label): '
          'reads=${terminalReads.length} '
          'limits=${terminalReads.map((u) => u.queryParameters['limit']).toList()} '
          'bytes=$terminalBytes',
        );

        expect(chat.isStreaming, isFalse);
        // The turn end must confirm against the durable store: at least one
        // REST read, and the shown prompt/reply are the stored rows, not the
        // optimistic projection.
        expect(
          terminalReads,
          isNotEmpty,
          reason: 'a terminal must read the durable tail at least once',
        );
        expect(chat.messages[0]['id'], server.rows.last['id']);
        expect(
          chat.messages[1]['id'],
          server.rows[server.rows.length - 2]['id'],
        );
        final contents = chat.messages.map((m) => m['content']).toList();
        expect(contents.first, 'Respuesta final');
        expect(contents[1], 'Vale hazlo');
        expect(contents.where((c) => c == 'Respuesta final'), hasLength(1));
        expect(contents.where((c) => c == 'Vale hazlo'), hasLength(1));
        // Every row the chat showed before the turn is still there, in order.
        final ids = chat.messages.map((m) => m['id']).whereType<int>().toList();
        expect(ids.toSet(), hasLength(ids.length));
        final retained = ids.where(openingIds.contains).toList();
        expect(retained, openingIds.whereType<int>().toList());
        for (var i = 1; i < ids.length; i++) {
          expect(ids[i], lessThan(ids[i - 1]));
        }
        expect(
          terminalReads.where((u) => u.queryParameters['limit'] == '500'),
          isEmpty,
          reason: 'a terminal must not page through the whole session',
        );
        expect(terminalBytes, lessThan(3 * 220 * 1024));
      },
    );
  }

  // Editorial `role=user` rows (model/personality switch) right before a
  // prompt: they must stay single, in place, and never count as the turn's
  // prompt, neither on this device's terminal nor on a passive read of a turn
  // sent from Desktop.
  for (final (label, marker) in <(String, void Function(_Server))>[
    ('model_switch', (s) => s.appendModelSwitch()),
    ('legacy model switch', (s) => s.appendModelSwitch(withDisplayKind: false)),
    ('personality_switch', (s) => s.appendPersonalitySwitch()),
  ]) {
    for (final fromDesktop in [false, true]) {
      test('$label before a ${fromDesktop ? 'Desktop' : 'Console'} prompt '
          'keeps every row once and in order', () async {
        final server = _Server(2500);
        final gateway = _Gateway()
          ..snapshot = const DesktopSessionSnapshot(
            runtimeSessionId: 'runtime-long',
            storedSessionId: 'stored-long',
            created: false,
            messagesProvided: false,
            messageCount: 2500,
          );
        final chat = _chat(server, gateway);
        addTearDown(chat.dispose);
        addTearDown(gateway.close);
        await chat.loadMessages(expectedMessageCount: 2500);
        await _settle();
        expect(
          await chat.loadEarlierMessages(continuePastInvisible: true),
          isTrue,
        );
        final before = chat.messages.map((m) => m['id']).toList();

        marker(server);
        final markerId = server.rows.last['id'];
        if (fromDesktop) {
          server.append('user', content: 'Vale hazlo');
          server.append('assistant', content: 'Respuesta final');
          await chat.loadMessages(passiveOnly: true);
          await _settle();
        } else {
          await chat.send(
            fullText: 'Vale hazlo',
            model: 'hermes-agent',
            history: chat.buildHistory(),
          );
          server.append('user', content: 'Vale hazlo');
          server.append('assistant', content: 'Respuesta final');
          gateway.emit(
            'message.delta',
            payload: const {'text': 'Respuesta final'},
          );
          gateway.emit(
            'message.complete',
            payload: const {'text': 'Respuesta final'},
          );
          await _settle();
          // Desktop-style passive refreshes after the turn change nothing.
          await chat.loadMessages(passiveOnly: true);
          await _settle();
        }

        final messages = chat.messages;
        final contents = messages.map((m) => m['content']).toList();
        expect(contents[0], 'Respuesta final');
        expect(contents[1], 'Vale hazlo');
        expect(messages[2]['id'], markerId);
        expect(contents.where((c) => c == 'Respuesta final'), hasLength(1));
        expect(contents.where((c) => c == 'Vale hazlo'), hasLength(1));
        expect(
          messages.where((m) => m['id'] == markerId),
          hasLength(1),
          reason: 'the editorial row is shown once',
        );
        final ids = messages.map((m) => m['id']).toList();
        expect(ids.whereType<int>().toSet(), hasLength(ids.length));
        for (var i = 1; i < ids.length; i++) {
          expect(ids[i] as int, lessThan(ids[i - 1] as int));
        }
        expect(ids.where(before.contains).toList(), before);
        expect(chat.isStreaming, isFalse);
      });
    }
  }
}
