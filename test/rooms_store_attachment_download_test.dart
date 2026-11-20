// A file sent through a room's own attachment store is read with
// `groups.attachment.download`, as Hermes Desktop reads it
// (apps/desktop/src/plugins/hermes-bots/canonical-group-attachments.tsx
// `fetchCanonicalGroupAttachment`: `room_id`, `event_id`, `attachment_id`).
//
// Answers use the real shapes of both servers: the stored row
// (gateway/hosted_room_attachments.py `HostedRoomAttachmentStore._metadata`)
// plus `data_base64` (gateway/session_hosted_attachments.py `read_download`,
// tui_gateway/contracts/canonical.py `RoomAttachmentBytes`), and the
// download's error envelope (tui_gateway/methods_groups.py, room_code 4126).
//
// No widget test lives here: the test binding replaces the HTTP client, and
// these run against a real loopback WebSocket.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/ui/room/room_gateway.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/mission_control_repository.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

import 'bots/room/room_fixtures.dart';
import 'support/rpc_frame_helpers.dart';

const _attId = 'att_0123456789abcdef0123456789abcdef';
const _eventId = 'user:7';
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

HostedGroupAttachment _attachment() =>
    HostedGroupAttachment.fromJson(_manifest());

/// `groups.attachment.download`'s result for [bytes]: the committed row and
/// its base64 bytes.
Map<String, Object?> _downloadResult(List<int> bytes, {int? size}) => {
  ..._manifest(size: size ?? bytes.length),
  'sha256': sha256.convert(bytes).toString(),
  'state': 'committed',
  'created_at': 1790000100.5,
  'idempotent': false,
  'event_id': _eventId,
  'data_base64': base64.encode(bytes),
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
            'payload': {'replay_epoch': 'room-files'},
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
          reply = await answer(Map<String, dynamic>.from(rpc['params'] as Map));
        }
        socket.add(jsonEncode({'jsonrpc': '2.0', 'id': rpc['id'], ...reply}));
      });
    });
    final client = TuiGatewayClient(
      SavedConnection(
        id: 'room-files',
        label: 'Room files',
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

  Future<Uint8List> download() => client.downloadGroupAttachment(
    roomId: roomId,
    eventId: _eventId,
    attachment: _attachment(),
  );

  Future<void> close() async {
    await client.close();
    await server.close(force: true);
  }
}

/// A gateway that lists the room's capabilities and records file reads.
final class _FilesGateway
    implements
        MissionHostedGroupsGateway,
        MissionHostedGroupsAttachmentGateway {
  _FilesGateway(this.methods);

  final List<GroupMethod> methods;
  final List<String> reads = [];

  @override
  Future<GroupsCapabilities> capabilities() async {
    return GroupsCapabilities.tryParse(
      {
        'protocol_version': 2,
        'driver': true,
        'methods': [for (final method in methods) method.wire],
        'max_log_limit': 500,
      },
      connectionId: 'room-files',
      generation: 7,
    )!;
  }

  @override
  Future<Uint8List> downloadAttachment(
    String roomId, {
    required String eventId,
    required HostedGroupAttachment attachment,
    required int generation,
  }) async {
    reads.add('$roomId:$eventId:${attachment.attachmentId}:$generation');
    return _pdf;
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
  group('groups.attachment.download on the wire', () {
    test('asks for the file by room, message and attachment id and returns '
        'its decoded bytes', () async {
      final gateway = await _Gateway.start(
        answer: (_) => {'result': _downloadResult(_pdf)},
      );
      addTearDown(gateway.close);

      final bytes = await gateway.download();

      expect(bytes, _pdf);
      expect(gateway.sent('groups.attachment.download').single['params'], {
        'room_id': roomId,
        'event_id': _eventId,
        'attachment_id': _attId,
      });
    });

    test('bytes that are not the size the manifest states are refused, '
        'shorter or longer', () async {
      for (final wrong in [
        _pdf.sublist(0, _pdf.length - 1),
        [..._pdf, 0x0a],
      ]) {
        final gateway = await _Gateway.start(
          // The row claims the manifest's size; the bytes disagree.
          answer: (_) => {
            'result': _downloadResult(wrong, size: _pdf.length),
          },
        );
        addTearDown(gateway.close);

        await expectLater(
          gateway.download(),
          throwsA(isA<GroupInvalidResponseError>()),
        );
      }
    });

    test('an answer for another attachment is refused', () async {
      final gateway = await _Gateway.start(
        answer: (_) => {
          'result': {
            ..._downloadResult(_pdf),
            'attachment_id': 'att_ffffffffffffffffffffffffffffffff',
          },
        },
      );
      addTearDown(gateway.close);

      await expectLater(
        gateway.download(),
        throwsA(isA<GroupInvalidResponseError>()),
      );
    });

    test("the server's refusal keeps its words, and the room shows "
        'them', () async {
      final gateway = await _Gateway.start(
        answer: (_) => {
          'error': {'code': 4126, 'message': 'attachment has expired'},
        },
      );
      addTearDown(gateway.close);

      Object? failure;
      try {
        await gateway.download();
      } catch (error) {
        failure = error;
      }

      expect(
        failure,
        isA<TuiGatewayRpcError>()
            .having((error) => error.code, 'code', 4126)
            .having(
              (error) => error.message,
              'message',
              'attachment has expired',
            ),
      );
      final actions = StoreRoomAttachmentActions(
        files: null,
        scope: 'room-files\u0000default',
        roomId: roomId,
        download: (_, _) async => _pdf,
      );
      expect(actions.failureMessage(failure!), 'attachment has expired');
      // Console's own verification is not the server's words.
      expect(
        actions.failureMessage(
          const GroupInvalidResponseError(
            'groups.attachment.download',
            'Hermes returned a file that does not match its manifest',
          ),
        ),
        isNull,
      );
    });

    test('[CONTROL] a server that does not list the method is never asked',
        () async {
      final gateway = await _Gateway.start(
        methods: _allMethods
            .where((method) => !method.startsWith('groups.attachment.'))
            .toList(),
        answer: (_) => {'result': _downloadResult(_pdf)},
      );
      addTearDown(gateway.close);

      await expectLater(
        gateway.download(),
        throwsA(
          isA<TuiGatewayRpcError>().having(
            (error) => error.code,
            'code',
            -32601,
          ),
        ),
      );
      expect(gateway.sent('groups.attachment.download'), isEmpty);
    });
  });

  group('the repository reads a room file under the live capabilities', () {
    test('the download goes to the gateway with the live generation',
        () async {
      final gateway = _FilesGateway([
        GroupMethod.capabilities,
        GroupMethod.list,
        GroupMethod.state,
        GroupMethod.log,
        GroupMethod.attachmentDownload,
      ]);
      final repository = _repository(gateway);

      final bytes = await repository.downloadHostedGroupAttachment(
        buildRoom(),
        eventId: _eventId,
        attachment: _attachment(),
      );

      expect(bytes, _pdf);
      expect(gateway.reads, ['$roomId:$_eventId:$_attId:7']);
    });

    test('[CONTROL] capabilities without the method: nothing is read',
        () async {
      final gateway = _FilesGateway([
        GroupMethod.capabilities,
        GroupMethod.list,
        GroupMethod.state,
        GroupMethod.log,
      ]);
      final repository = _repository(gateway);

      await expectLater(
        repository.downloadHostedGroupAttachment(
          buildRoom(),
          eventId: _eventId,
          attachment: _attachment(),
        ),
        throwsStateError,
      );
      expect(gateway.reads, isEmpty);
    });
  });
}
