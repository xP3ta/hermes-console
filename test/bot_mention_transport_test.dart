import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/attachment_draft.dart';
import 'package:hermes_android/core/models/bot_mention.dart';
import 'package:hermes_android/core/models/prepared_turn.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/bot_mention_roster.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'support/in_memory_compression_fence_storage.dart';

class _Store implements TurnOutboxPersistence {
  PreparedTurn? saved;
  @override
  Future<void> save(PreparedTurn turn) async {
    saved = PreparedTurn.fromJson(turn.toJson());
  }

  @override
  Future<void> delete(PreparedTurn turn) async {}
}

class _Gateway
    implements
        HermesDesktopGateway,
        HermesDesktopAttachmentGateway,
        HermesDesktopIdempotentGateway {
  final controller = StreamController<TuiGatewayEvent>.broadcast();
  final payloads = <String>[];
  final ids = <String>[];
  int uploads = 0;
  @override
  bool get isConnected => true;
  @override
  Stream<TuiGatewayEvent> get events => controller.stream;
  @override
  Future<void> connect() async {}
  @override
  Future<DesktopSessionBinding> resumeSession(
    String storedSessionId, {
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => DesktopSessionBinding(
    runtimeSessionId: 'runtime',
    storedSessionId: storedSessionId,
    created: false,
  );
  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async {
    payloads.add(text);
  }

  @override
  Future<DesktopTurnAck> submitPromptIdempotent(
    String runtimeSessionId,
    String text,
    String clientTurnId,
  ) async {
    payloads.add(text);
    ids.add(clientTurnId);
    return DesktopTurnAck(
      accepted: true,
      clientTurnId: clientTurnId,
      serverTurnId: 'server',
      state: DesktopTurnState.accepted,
      duplicate: ids.length > 1,
    );
  }

  @override
  Future<DesktopTurnStatus> getTurnStatus(
    String sessionId,
    String clientTurnId,
  ) async => DesktopTurnStatus(clientTurnId: clientTurnId, known: false);
  @override
  Future<DesktopAttachmentResult> attachFileBytes(
    String runtimeSessionId, {
    required String filename,
    required String mimeType,
    required String contentBase64,
  }) async {
    uploads++;
    return const DesktopAttachmentResult(
      path: '/remote/file.pdf',
      refText: '@file:.hermes/file.pdf',
    );
  }

  @override
  Future<DesktopAttachmentResult> attachImageBytes(
    String runtimeSessionId, {
    required String filename,
    required String contentBase64,
  }) async => const DesktopAttachmentResult(path: '/remote/image.png');
  @override
  Future<void> detachImage(String runtimeSessionId, String path) async {}
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
  Future<void> close() => controller.close();
}

void main() {
  setUp(BotMentionRoster.shared.clear);
  tearDown(BotMentionRoster.shared.clear);
  final connection = SavedConnection(
    id: 'local',
    label: 'Local',
    host: 'example.invalid',
    port: 443,
    apiKey: 'fixture',
    useHttps: true,
  );
  ActiveChat chat({HermesDesktopGateway? gateway, ApiClient? api}) =>
      ActiveChat(
        connection: connection,
        sessionId: 'session',
        sessionTitle: 'Normal chat',
        sessionProfile: 'default',
        notifications: null,
        onTerminal: () {},
        desktopGateway: gateway,
        api: api,
        compressionFenceStore: testCompressionFenceStore(),
        turnIdempotencyCapability: () async => true,
        storedMessageLoader: (_, _) async => const [],
        terminalReconcileBudget: Duration.zero,
      );
  final bots = const [
    BotMention(connectionId: 'local', profile: 'ops', handle: 'ops'),
  ];
  PreparedTurn turn({
    List<AttachmentDraft> attachments = const [],
    String text = '@ops',
    String? fullText,
    String? desktopText,
  }) => PreparedTurn(
    connectionId: 'local',
    sessionId: 'session',
    clientTurnId: 'turn',
    createdAtMs: 1,
    updatedAtMs: 1,
    text: text,
    fullText: fullText,
    desktopText: desktopText,
    attachments: attachments,
    model: 'hermes-agent',
    profile: 'default',
    mentions: bots,
    mentionAnnotation: buildBotMentionAnnotation(bots),
  );

  test(
    'native file references precede the trailing note and retry preserves exact payload/id',
    () async {
      final dir = Directory.systemTemp.createTempSync('mention-attachment-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/file.pdf')..writeAsStringSync('fixture');
      final gateway = _Gateway();
      final subject = chat(gateway: gateway);
      addTearDown(subject.dispose);
      addTearDown(gateway.close);
      final store = _Store();
      final prepared = turn(
        fullText: '[📎 file.pdf]\n@ops\n⟦adjunto⟧\ntext payload',
        desktopText: '[📎 file.pdf]\n@ops',
        attachments: [
          AttachmentDraft(
            localId: 'file',
            type: AttachmentType.document,
            name: 'file.pdf',
            mimeType: 'application/pdf',
            sizeBytes: 7,
            localPath: file.path,
          ),
        ],
      );
      final delivery = ActiveTurnDelivery(prepared: prepared, store: store);
      expect(
        await subject.send(
          fullText: 'ignored',
          model: 'hermes-agent',
          history: [],
          delivery: delivery,
        ),
        isTrue,
      );
      final expected =
          '[📎 file.pdf]\n@ops\n\n@file:.hermes/file.pdf${prepared.mentionAnnotation}';
      expect(gateway.payloads, [expected]);
      expect(
        subject.messages
            .where((row) => row['role'] == 'user')
            .single['content'],
        prepared.fullText,
      );
      final restored = PreparedTurn.fromJson(delivery.current.toJson());
      subject.state = ChatPipelineState.idle;
      BotMentionRoster.shared.replace('local', 'Local', const [
        AgentProfile(name: 'different'),
      ]);
      expect(
        await subject.send(
          fullText: 'changed caller',
          model: 'hermes-agent',
          history: [],
          delivery: ActiveTurnDelivery(prepared: restored, store: store),
        ),
        isTrue,
      );
      expect(gateway.payloads, [expected, expected]);
      expect(gateway.ids, ['turn', 'turn']);
      expect(gateway.uploads, 1);
    },
  );

  for (final text in [
    'ordinary',
    'user@ops.com',
    '`@ops`',
    '```\n@ops\n```',
    '@unknown',
  ]) {
    test('native ordinary send is byte identical: $text', () async {
      BotMentionRoster.shared.replace('local', 'Local', const [
        AgentProfile(name: 'ops'),
      ]);
      final gateway = _Gateway();
      final subject = chat(gateway: gateway);
      addTearDown(subject.dispose);
      addTearDown(gateway.close);
      expect(
        await subject.send(fullText: text, model: 'hermes-agent', history: []),
        isTrue,
      );
      expect(gateway.payloads, [text]);
    });
  }

  test(
    'REST fallback uses full attachment text and exactly one frozen note',
    () async {
      final inputs = <String>[];
      final api = ApiClient(
        baseUrl: 'https://example.invalid',
        apiKey: 'fixture',
        httpClient: MockClient((request) async {
          if (request.method == 'POST' && request.url.path == '/v1/runs') {
            inputs.add((jsonDecode(request.body) as Map)['input'] as String);
            return http.Response('{"run_id":"run"}', 200);
          }
          return http.Response('{}', 404);
        }),
      );
      final subject = chat(api: api);
      addTearDown(subject.dispose);
      final prepared = turn(
        fullText: '@ops\n⟦adjunto⟧\n```txt\nbody\n```',
        desktopText: '@ops',
      );
      expect(
        await subject.send(
          fullText: 'ignored',
          model: 'hermes-agent',
          history: [],
          delivery: ActiveTurnDelivery(prepared: prepared, store: _Store()),
        ),
        isTrue,
      );
      expect(inputs, ['${prepared.fullText}${prepared.mentionAnnotation}']);
      expect('@mentions resolved'.allMatches(inputs.single).length, 1);
    },
  );
}
