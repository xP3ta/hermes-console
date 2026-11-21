// A file sent to a room goes through the room's own attachment store, as
// Hermes Desktop sends it
// (apps/desktop/src/plugins/hermes-bots/canonical-group-attachments.tsx
// `upload`: `room_id`, `upload_id`, `kind`, `name`, `mime`, `data_base64`;
// canonical-group-workspace.tsx `sendIntent`: the `groups.send` payload
// lists the receipts as its `attachments` manifest).
//
// Answers use the real shapes of both servers: the stored row
// (gateway/hosted_room_attachments.py `HostedRoomAttachmentStore._metadata`,
// tui_gateway/contracts/canonical.py `RoomAttachment`) and the `message.user`
// event with its manifest (gateway/hosted_room_discussion.py
// `validate_user_payload`).
//
// These run against a real loopback WebSocket.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/mission_control_repository.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

import 'bots/room/room_fixtures.dart';
import 'support/rpc_frame_helpers.dart';

const _attId = 'att_0123456789abcdef0123456789abcdef';
const _uploadId = '5d0c6f6e-2f7a-4d55-9a43-1f0a8b1c2d3e';
const _clientEvent = 'c0ffee00-1111-4222-8333-444455556666';
final Uint8List _pdf = Uint8List.fromList(
  utf8.encode('%PDF-1.4\n% a room file\n%%EOF\n'),
);

Map<String, Object?> _manifest({int? size}) => {
  'attachment_id': _attId,
  'kind': 'pdf',
  'name': 'plan.pdf',
  'size': size ?? _pdf.length,
  'mime': 'application/pdf',
};

/// `groups.attachment.upload`'s result: the stored row.
Map<String, Object?> _receipt({int? size, bool idempotent = false}) => {
  ..._manifest(size: size),
  'sha256': sha256.convert(_pdf).toString(),
  'state': 'uploaded',
  'created_at': 1790000100.5,
  'idempotent': idempotent,
};

/// The `message.user` event the server appends for a send of [text] that
/// lists the stored file.
Map<String, Object?> _userEvent(String text) => {
  'room_id': roomId,
  'seq': 4,
  'event_id': TuiGatewayClient.durableGroupEventId(_clientEvent),
  'kind': 'message.user',
  'actor': {'kind': 'user', 'id': 'desktop'},
  'authority_epoch': 2,
  'payload': {
    'text': text,
    'thread_id': 'thread-1',
    'attachments': [_manifest()],
  },
  'created_at': 1790000200.0,
  'idempotent': false,
};

const _allMethods = [
  'groups.capabilities',
  'groups.list',
  'groups.state',
  'groups.log',
  'groups.send',
  'groups.attachment.upload',
  'groups.attachment.download',
];

final class _Dashboard extends DashboardClient {
  _Dashboard() : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(queryName: 'ticket', credential: 'test');
}

/// A loopback gateway: `groups.capabilities` lists [methods]; every other
/// group frame is answered by [answer] (a JSON-RPC `result` or `error`).
final class _Gateway {
  final HttpServer server;
  final TuiGatewayClient client;
  final List<Map<String, dynamic>> frames;

  _Gateway._(this.server, this.client, this.frames);

  static Future<_Gateway> start({
    List<String> methods = _allMethods,
    required FutureOr<Map<String, Object?>> Function(
      String method,
      Map<String, dynamic> params,
    )
    answer,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final frames = <Map<String, dynamic>>[];
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'event',
          'params': {
            'type': 'gateway.ready',
            'payload': {'replay_epoch': 'room-uploads'},
          },
        }),
      );
      socket.listen((raw) async {
        final rpc = Map<String, dynamic>.from(jsonDecode(raw as String) as Map);
        if (rpc['method'] == 'gateway.ping') return;
        if (isClientCapabilitiesFrame(rpc)) {
          socket.add(jsonEncode(clientCapabilitiesResponse(rpc)));
          return;
        }
        frames.add(rpc);
        var reply = <String, Object?>{
          'result': {
            'protocol_version': 2,
            'driver': true,
            'methods': methods,
            'max_log_limit': 500,
          },
        };
        if (rpc['method'] != 'groups.capabilities') {
          reply = await answer(
            rpc['method'] as String,
            Map<String, dynamic>.from(rpc['params'] as Map),
          );
        }
        socket.add(jsonEncode({'jsonrpc': '2.0', 'id': rpc['id'], ...reply}));
      });
    });
    final client = TuiGatewayClient(
      SavedConnection(
        id: 'room-uploads',
        label: 'Room uploads',
        host: '127.0.0.1',
        port: 8642,
        dashboardUrl: 'http://127.0.0.1:${server.port}',
        apiKey: String.fromCharCodes(const [113, 97]),
      ),
      dashboard: _Dashboard(),
      heartbeatInterval: const Duration(hours: 1),
      heartbeatDeadline: const Duration(hours: 2),
    );
    return _Gateway._(server, client, frames);
  }

  List<Map<String, dynamic>> sent(String method) =>
      frames.where((frame) => frame['method'] == method).toList();

  Future<HostedGroupAttachment> upload() => client.uploadGroupAttachment(
    roomId: roomId,
    uploadId: _uploadId,
    kind: 'pdf',
    name: 'plan.pdf',
    mime: 'application/pdf',
    bytes: _pdf,
  );

  Future<void> close() async {
    await client.close();
    await server.close(force: true);
  }
}

/// Answers `groups.send` with the appended event and `groups.log` with it.
Map<String, Object?> _sendAndLog(
  String method,
  Map<String, dynamic> params, {
  required String text,
}) => switch (method) {
  'groups.send' => {
    'result': {
      'event': _userEvent(text),
      'client_event_id': params['event_id'],
      'accepted': true,
      'driver_started': true,
    },
  },
  'groups.log' => {
    'result': {
      'events': [_userEvent(text)],
      'cursor': 4,
      'latest_seq': 4,
      'has_more': false,
      'authority': {'gateway_id': gatewayId, 'epoch': 2},
    },
  },
  _ => {
    'error': {'code': -32601, 'message': 'unexpected $method'},
  },
};

/// [answer] with its event's payload cut to [text]: a server event that
/// lists no files.
Map<String, Object?> _withoutFiles(
  String method,
  Map<String, Object?> answer,
  String text,
) {
  final result = answer['result'];
  if (result is! Map) return answer;
  Map<String, Object?> bare(Object? event) => {
    ...(event! as Map<String, Object?>),
    'payload': {'text': text, 'thread_id': 'thread-1'},
  };
  return {
    'result': method == 'groups.send'
        ? {...result, 'event': bare(result['event'])}
        : {
            ...result,
            'events': [bare((result['events'] as List).single)],
          },
  };
}

/// A gateway that lists the room's capabilities and records the store
/// calls of the repository.
final class _StoreGateway
    implements MissionHostedGroupsGateway, MissionHostedGroupsUploadGateway {
  _StoreGateway(this.methods, {this.driver = true});

  final List<GroupMethod> methods;
  final bool driver;
  final List<String> calls = [];

  @override
  Future<GroupsCapabilities> capabilities() async {
    return GroupsCapabilities.tryParse(
      {
        'protocol_version': 2,
        'driver': driver,
        'methods': [for (final method in methods) method.wire],
        'max_log_limit': 500,
      },
      connectionId: 'room-uploads',
      generation: 7,
    )!;
  }

  @override
  Future<HostedGroupAttachment> uploadAttachment(
    String roomId, {
    required String uploadId,
    required String kind,
    required String name,
    required String mime,
    required Uint8List bytes,
    required int generation,
  }) async {
    calls.add(
      'upload:$roomId:$uploadId:$kind:$name:$mime:'
      '${bytes.length}:$generation',
    );
    return HostedGroupAttachment.fromJson(_manifest());
  }

  @override
  Future<HostedGroupLogPage> sendWithAttachments(
    String roomId, {
    required String text,
    required List<HostedGroupAttachment> attachments,
    required HostedGroupSendAttempt attempt,
    required int generation,
  }) async {
    final ids = attachments.map((a) => a.attachmentId).join(',');
    calls.add('send:$roomId:$text:$ids:$generation');
    throw StateError('stop after the call');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

MissionControlRepository _repository(MissionHostedGroupsGateway gateway) =>
    MissionControlRepository(
      profilesLoader: () async => const [],
      sessionsLoader: () async => const [],
      boardLoader: () async => throw UnimplementedError(),
      hostedGroupsGateway: gateway,
    );

void main() {
  group('groups.attachment.upload on the wire', () {
    test('[RED] sends the six fields Desktop sends and returns the manifest '
        'entry of the stored row', () async {
      final gateway = await _Gateway.start(
        answer: (_, _) => {'result': _receipt()},
      );
      addTearDown(gateway.close);

      final receipt = await gateway.upload();

      expect(gateway.sent('groups.attachment.upload').single['params'], {
        'room_id': roomId,
        'upload_id': _uploadId,
        'kind': 'pdf',
        'name': 'plan.pdf',
        'mime': 'application/pdf',
        'data_base64': base64.encode(_pdf),
      });
      expect(receipt.toManifest(), _manifest());
    });

    test('[RED] a receipt of another size than the bytes sent is refused',
        () async {
      final gateway = await _Gateway.start(
        answer: (_, _) => {'result': _receipt(size: _pdf.length + 1)},
      );
      addTearDown(gateway.close);

      await expectLater(
        gateway.upload(),
        throwsA(isA<GroupInvalidResponseError>()),
      );
    });

    test('[CONTROL] a server without the method answers -32601 and is '
        'never asked', () async {
      final gateway = await _Gateway.start(
        methods: _allMethods
            .where((method) => method != 'groups.attachment.upload')
            .toList(),
        answer: (_, _) => {'result': _receipt()},
      );
      addTearDown(gateway.close);

      await expectLater(
        gateway.upload(),
        throwsA(
          isA<TuiGatewayRpcError>().having(
            (error) => error.code,
            'code',
            -32601,
          ),
        ),
      );
      expect(gateway.sent('groups.attachment.upload'), isEmpty);
    });
  });

  group('groups.send lists the stored files', () {
    test('[RED] the payload carries the manifest and the acknowledged event '
        'must list the same files', () async {
      final gateway = await _Gateway.start(
        answer: (method, params) => _sendAndLog(method, params, text: 'plan'),
      );
      addTearDown(gateway.close);
      final caps = await gateway.client.groupCapabilities();

      final page = await gateway.client.sendGroupText(
        roomId: roomId,
        text: 'plan',
        eventId: _clientEvent,
        threadId: 'thread-1',
        generation: caps.generation,
        attachments: [HostedGroupAttachment.fromJson(_manifest())],
      );

      expect(gateway.sent('groups.send').single['params'], {
        'room_id': roomId,
        'event_id': _clientEvent,
        'payload': {
          'text': 'plan',
          'thread_id': 'thread-1',
          'attachments': [_manifest()],
        },
      });
      expect(page.events.single.attachments.single.attachmentId, _attId);
    });

    test('[RED] a message of files alone is sent with empty text', () async {
      final gateway = await _Gateway.start(
        answer: (method, params) => _sendAndLog(method, params, text: ''),
      );
      addTearDown(gateway.close);
      final caps = await gateway.client.groupCapabilities();

      await gateway.client.sendGroupText(
        roomId: roomId,
        text: '',
        eventId: _clientEvent,
        threadId: 'thread-1',
        generation: caps.generation,
        attachments: [HostedGroupAttachment.fromJson(_manifest())],
      );

      final payload =
          gateway.sent('groups.send').single['params']['payload'] as Map;
      expect(payload['text'], '');
      expect(payload['attachments'], [_manifest()]);
    });

    test('[RED] an acknowledgement without the files is not a delivery',
        () async {
      final gateway = await _Gateway.start(
        // The room logs the message without them, too.
        answer: (method, params) => _withoutFiles(
          method,
          _sendAndLog(method, params, text: 'plan'),
          'plan',
        ),
      );
      addTearDown(gateway.close);
      final caps = await gateway.client.groupCapabilities();

      await expectLater(
        gateway.client.sendGroupText(
          roomId: roomId,
          text: 'plan',
          eventId: _clientEvent,
          threadId: 'thread-1',
          generation: caps.generation,
          attachments: [HostedGroupAttachment.fromJson(_manifest())],
        ),
        throwsA(isA<TuiGatewayRpcError>()),
      );
    });

    test('[CONTROL] a text message keeps its payload without a manifest',
        () async {
      final gateway = await _Gateway.start(
        answer: (method, params) => _withoutFiles(
          method,
          _sendAndLog(method, params, text: 'hello'),
          'hello',
        ),
      );
      addTearDown(gateway.close);
      final caps = await gateway.client.groupCapabilities();

      await gateway.client.sendGroupText(
        roomId: roomId,
        text: 'hello',
        eventId: _clientEvent,
        threadId: 'thread-1',
        generation: caps.generation,
      );

      expect(gateway.sent('groups.send').single['params']['payload'], {
        'text': 'hello',
        'thread_id': 'thread-1',
      });
    });
  });

  group('the repository keeps a room file under the live capabilities', () {
    test('[RED] the upload goes to the gateway with the live generation, '
        'the send lists its receipt', () async {
      final gateway = _StoreGateway([
        GroupMethod.capabilities,
        GroupMethod.list,
        GroupMethod.state,
        GroupMethod.log,
        GroupMethod.send,
        GroupMethod.attachmentUpload,
      ]);
      final repository = _repository(gateway);

      final receipt = await repository.uploadHostedGroupAttachment(
        buildRoom(),
        uploadId: _uploadId,
        kind: 'pdf',
        name: 'plan.pdf',
        mime: 'application/pdf',
        bytes: _pdf,
      );
      await expectLater(
        repository.sendHostedGroupMessage(
          buildRoom(),
          text: 'plan',
          attachments: [receipt],
          attempt: HostedGroupSendAttempt.forClientEvent(
            _clientEvent,
            threadId: 'thread-1',
          ),
          generation: 7,
        ),
        throwsStateError,
      );

      expect(gateway.calls, [
        'upload:$roomId:$_uploadId:pdf:plan.pdf:application/pdf:'
            '${_pdf.length}:7',
        'send:$roomId:plan:$_attId:7',
      ]);
    });

    test('[RED] a listed method whose room driver is down is not missing: '
        'no -32601, nothing uploaded', () async {
      final gateway = _StoreGateway(
        [
          GroupMethod.capabilities,
          GroupMethod.list,
          GroupMethod.state,
          GroupMethod.log,
          GroupMethod.send,
          GroupMethod.attachmentUpload,
        ],
        driver: false,
      );
      final repository = _repository(gateway);

      Object? failure;
      try {
        await repository.uploadHostedGroupAttachment(
          buildRoom(),
          uploadId: _uploadId,
          kind: 'pdf',
          name: 'plan.pdf',
          mime: 'application/pdf',
          bytes: _pdf,
        );
      } catch (error) {
        failure = error;
      }

      // The room keeps its store path and the message stays retryable.
      expect(failure, isNotNull);
      expect(
        failure is TuiGatewayRpcError && failure.code == -32601,
        isFalse,
      );
      expect(gateway.calls, isEmpty);
    });

    test('[CONTROL] capabilities without the method: -32601, nothing is '
        'uploaded', () async {
      final gateway = _StoreGateway([
        GroupMethod.capabilities,
        GroupMethod.list,
        GroupMethod.state,
        GroupMethod.log,
        GroupMethod.send,
      ]);
      final repository = _repository(gateway);

      await expectLater(
        repository.uploadHostedGroupAttachment(
          buildRoom(),
          uploadId: _uploadId,
          kind: 'pdf',
          name: 'plan.pdf',
          mime: 'application/pdf',
          bytes: _pdf,
        ),
        throwsA(
          isA<TuiGatewayRpcError>().having(
            (error) => error.code,
            'code',
            -32601,
          ),
        ),
      );
      expect(gateway.calls, isEmpty);
    });
  });
}
