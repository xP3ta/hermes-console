import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/connection.dart';
import 'package:hermes_android/core/services/json_rpc_wire.dart';
import 'package:hermes_android/core/services/transcript_rehydrate_cost.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

import 'support/qrc_fake_gateway_socket.dart';

/// A WebSocket frame above the off-main threshold (a long session's
/// transcript) is parsed in a short-lived isolate, like the HTTP reads of
/// the same size, with the same duplicate-aware parser; the frames after it
/// on the socket keep their wire order.

SavedConnection _conn() => SavedConnection(
  id: 'qrc-frames',
  label: 'qrc-frames',
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'unused',
  dashboardUrl: 'http://127.0.0.1:1',
  kind: InstanceKind.vps,
);

String _event(String type, {int blobLength = 0}) => jsonEncode({
  'jsonrpc': '2.0',
  'method': 'event',
  'params': {
    'type': type,
    'payload': {'blob': 'x' * blobLength},
  },
});

Future<void> _until(bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  test('the off-main decoder refuses a duplicated key like the inline one', () {
    final blob = 'x' * (kJsonDecodeOffMainBytes + 1024);
    final duplicated =
        '{"jsonrpc":"2.0","method":"event","method":"event",'
        '"params":{"type":"qrc","payload":{"blob":"$blob"}}}';
    expect(
      () => JsonRpcWireDecoder.decodeTransportFrame(
        duplicated,
        replayCapable: false,
      ),
      throwsA(isA<JsonRpcWireFormatException>()),
    );
    expect(
      JsonRpcWireDecoder.decodeTransportFrameOffMain(
        duplicated,
        replayCapable: false,
      ),
      throwsA(isA<JsonRpcWireFormatException>()),
    );
  });

  test(
    'the off-main decoder yields the same frame as the inline one',
    () async {
      final frame = _event('qrc.big', blobLength: kJsonDecodeOffMainBytes);
      final inline =
          JsonRpcWireDecoder.decodeTransportFrame(frame, replayCapable: false)
              as JsonRpcEventFrame;
      final offMain =
          await JsonRpcWireDecoder.decodeTransportFrameOffMain(
                frame,
                replayCapable: false,
              )
              as JsonRpcEventFrame;
      expect(offMain.event.type, inline.event.type);
      expect(offMain.event.payload, inline.event.payload);
    },
  );

  test('a big frame decodes off the main isolate and the frames after it '
      'keep wire order', () async {
    final channels = <QrcFakeChannel>[];
    final client = TuiGatewayClient(
      _conn(),
      dashboard: QrcTickets(),
      heartbeatInterval: Duration.zero,
      channelFactory: (_, _) {
        final channel = QrcFakeChannel();
        channels.add(channel);
        return channel;
      },
    );
    addTearDown(client.close);
    await client.connect();
    final types = <String>[];
    final subscription = client.events.listen((event) => types.add(event.type));
    addTearDown(subscription.cancel);

    final big = _event('qrc.big', blobLength: kJsonDecodeOffMainBytes + 1024);
    expect(big.length, greaterThan(kJsonDecodeOffMainBytes));
    channels.single.push(big);
    channels.single.push(_event('qrc.after'));
    channels.single.push(_event('qrc.last'));
    await _until(() => types.length >= 3);
    expect(types, ['qrc.big', 'qrc.after', 'qrc.last']);
    expect(client.isConnected, isTrue);

    // Small frames after the queue drained go straight through again.
    channels.single.push(_event('qrc.inline'));
    await _until(() => types.length >= 4);
    expect(types.last, 'qrc.inline');
  });

  test(
    'a big frame with a duplicated key drops the socket as before',
    () async {
      final channels = <QrcFakeChannel>[];
      final client = TuiGatewayClient(
        _conn(),
        dashboard: QrcTickets(),
        heartbeatInterval: Duration.zero,
        channelFactory: (_, _) {
          final channel = QrcFakeChannel();
          channels.add(channel);
          return channel;
        },
      );
      addTearDown(client.close);
      await client.connect();
      final blob = 'x' * (kJsonDecodeOffMainBytes + 1024);
      channels.single.push(
        '{"jsonrpc":"2.0","method":"event","method":"event",'
        '"params":{"type":"qrc","payload":{"blob":"$blob"}}}',
      );
      await _until(() => !client.isConnected);
      expect(client.isConnected, isFalse);
    },
  );
}
