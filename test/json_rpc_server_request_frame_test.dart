import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/json_rpc_wire.dart';

void main() {
  JsonRpcWireFrame decode(String text) =>
      JsonRpcWireDecoder.decodeText(text, replayCapable: true);

  test('a string id plus method decodes as a server→client request', () {
    final frame = decode(
      '{"jsonrpc":"2.0","id":"srq-0123456789ab","method":"approval",'
      '"params":{"session_id":"runtime-1","request_id":"apr-1"}}',
    );
    expect(frame, isA<JsonRpcServerRequestFrame>());
    final request = frame as JsonRpcServerRequestFrame;
    expect(request.id, 'srq-0123456789ab');
    expect(request.method, 'approval');
    expect(request.params, {'session_id': 'runtime-1', 'request_id': 'apr-1'});
    expect(() => request.params['x'] = 1, throwsUnsupportedError);
  });

  test('a server request without params decodes with an empty map', () {
    final frame =
        decode('{"jsonrpc":"2.0","id":"srq-1","method":"sudo"}')
            as JsonRpcServerRequestFrame;
    expect(frame.params, isEmpty);
  });

  test('server requests still fail closed on structural violations', () {
    for (final text in const [
      // extra member
      '{"jsonrpc":"2.0","id":"srq-1","method":"clarify","params":{},"x":1}',
      // params must be an object
      '{"jsonrpc":"2.0","id":"srq-1","method":"clarify","params":[]}',
      // empty / untrimmed method
      '{"jsonrpc":"2.0","id":"srq-1","method":""}',
      '{"jsonrpc":"2.0","id":"srq-1","method":" clarify"}',
      // empty / untrimmed id
      '{"jsonrpc":"2.0","id":"","method":"clarify"}',
      '{"jsonrpc":"2.0","id":"srq-1 ","method":"clarify"}',
      // a string id on a response is still not ours
      '{"jsonrpc":"2.0","id":"srq-1","result":{}}',
    ]) {
      expect(
        () => decode(text),
        throwsA(isA<JsonRpcWireFormatException>()),
        reason: text,
      );
    }
  });

  test('integer-id responses and notifications keep their existing shapes', () {
    expect(
      decode('{"jsonrpc":"2.0","id":7,"result":{"ok":true}}'),
      isA<JsonRpcResponseFrame>(),
    );
    expect(
      decode('{"jsonrpc":"2.0","method":"request.cancel","params":{}}'),
      isA<JsonRpcNotificationFrame>(),
    );
  });
}
