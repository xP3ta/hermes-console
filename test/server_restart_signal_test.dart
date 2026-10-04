// "Restart required" is never read from the server on purpose: a model call
// Console already makes (REST `/api/model/options` and `/api/model/set`, RPC
// `model.options`) fails with 503 `Restart required: …` or error 5098 when the
// process runs older code than the checkout. Console only remembers that.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/server_restart_signal.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

const _host = 'hermes.example.test';

const _restartDetail =
    'Restart required: This process is running code from abc1234 but the '
    'checkout on disk is now def5678 (see /srv/hermes/.git/HEAD). '
    'Restart the dashboard to continue.';

void main() {
  setUp(ServerRestartSignals.resetForTesting);

  group('the store', () {
    test('a 503 with the restart detail is remembered, without paths', () {
      ServerRestartSignals.noteHttp(
        _host,
        503,
        jsonEncode({'detail': _restartDetail}),
      );
      final text = ServerRestartSignals.textFor([_host])!;
      expect(text, startsWith('Restart required:'));
      expect(text, contains('abc1234'));
      expect(text, isNot(contains('/srv')));
      expect(text, isNot(contains('.git')));
    });

    test('any other 503 or status is nothing', () {
      ServerRestartSignals.noteHttp(
        _host,
        503,
        jsonEncode({'detail': 'database is corrupt'}),
      );
      ServerRestartSignals.noteHttp(
        _host,
        500,
        jsonEncode({'detail': _restartDetail}),
      );
      ServerRestartSignals.noteHttp(_host, 503, 'not json');
      ServerRestartSignals.noteHttp(_host, 503, jsonEncode({'detail': 5}));
      expect(ServerRestartSignals.textFor([_host]), isNull);
    });

    test('RPC 5098 is remembered, other codes are not', () {
      ServerRestartSignals.noteRpc(_host, 5000, 'x');
      expect(ServerRestartSignals.textFor([_host]), isNull);
      ServerRestartSignals.noteRpc(_host, 5098, 'process is older than disk');
      expect(
        ServerRestartSignals.textFor([_host]),
        'process is older than disk',
      );
    });

    test('RPC 5098 without text still says restart', () {
      ServerRestartSignals.noteRpc(_host, 5098, '  ');
      expect(ServerRestartSignals.textFor([_host]), isNotEmpty);
    });

    test('it is per host', () {
      ServerRestartSignals.noteRpc(_host, 5098, 'old code');
      expect(ServerRestartSignals.textFor(['other.example.test']), isNull);
      expect(
        ServerRestartSignals.textFor(['other.example.test', _host]),
        'old code',
      );
    });

    test('the text is one bounded line', () {
      ServerRestartSignals.noteRpc(_host, 5098, 'a\nb ${'x' * 400}');
      final text = ServerRestartSignals.textFor([_host])!;
      expect(text.contains('\n'), isFalse);
      expect(text.length, lessThanOrEqualTo(240));
    });

    test('a newer note replaces the older one', () {
      ServerRestartSignals.noteRpc(_host, 5098, 'first');
      ServerRestartSignals.noteRpc(_host, 5098, 'second');
      expect(ServerRestartSignals.textFor([_host]), 'second');
    });
  });

  group('the REST seams only observe', () {
    DashboardClient dashboard(http.Response Function(http.Request) answer) =>
        DashboardClient(
          host: _host,
          port: 9119,
          manualToken: 'dashboard-token',
          httpClientOverride: MockClient((request) async => answer(request)),
        );

    test('getModelOptions notes the 503 and still throws it', () async {
      final client = dashboard(
        (_) => http.Response(jsonEncode({'detail': _restartDetail}), 503),
      );
      await expectLater(
        client.getModelOptions(),
        throwsA(
          isA<DashboardHttpException>().having(
            (e) => e.statusCode,
            'status',
            503,
          ),
        ),
      );
      expect(ServerRestartSignals.textFor([_host]), isNotNull);
    });

    test('setActiveModel notes the 503 and still throws it', () async {
      final client = dashboard(
        (_) => http.Response(jsonEncode({'detail': _restartDetail}), 503),
      );
      await expectLater(
        client.setActiveModel(providerSlug: 'p', modelId: 'm'),
        throwsA(isA<DashboardHttpException>()),
      );
      expect(ServerRestartSignals.textFor([_host]), isNotNull);
    });

    test('another failure leaves no signal', () async {
      final client = dashboard(
        (_) => http.Response(jsonEncode({'detail': 'nope'}), 500),
      );
      await expectLater(
        client.getModelOptions(),
        throwsA(isA<DashboardHttpException>()),
      );
      expect(ServerRestartSignals.textFor([_host]), isNull);
    });

    test('a healthy answer leaves no signal and makes no extra call', () async {
      var calls = 0;
      final client = dashboard((_) {
        calls++;
        return http.Response(jsonEncode({'providers': <Object>[]}), 200);
      });
      await client.getModelOptions();
      expect(calls, 1);
      expect(ServerRestartSignals.textFor([_host]), isNull);
    });
  });

  group('the RPC seams only observe', () {
    test('model.options 5098 is noted and still thrown', () async {
      final requests = <String>[];
      final client = TuiGatewayClient(
        SavedConnection(
          id: 'rs-1',
          label: 'rs',
          host: _host,
          port: 8642,
          apiKey: 'k',
        ),
        dashboard: _Dashboard(),
        channelFactory: (_, _) => _Channel(requests),
      );
      addTearDown(client.close);

      await expectLater(
        client.globalModelOptions(),
        throwsA(isA<TuiGatewayRpcError>().having((e) => e.code, 'code', 5098)),
      );
      expect(ServerRestartSignals.textFor([_host]), isNotNull);
      expect(requests.where((r) => r == 'model.options'), hasLength(1));
    });
  });
}

final class _Dashboard extends DashboardClient {
  _Dashboard() : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(queryName: 'ticket', credential: 't');
}

final class _Channel implements WebSocketChannel {
  _Channel(this.requests) {
    _incoming.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'method': 'event',
        'params': {'type': 'gateway.ready', 'payload': <String, dynamic>{}},
      }),
    );
  }

  final List<String> requests;
  final StreamController<dynamic> _incoming = StreamController<dynamic>();

  @override
  Future<void> get ready async {}

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  late final WebSocketSink sink = _Sink((data) {
    final frame = Map<String, dynamic>.from(jsonDecode(data as String) as Map);
    final method = '${frame['method']}';
    requests.add(method);
    _incoming.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': frame['id'],
        if (method == 'model.options')
          'error': {'code': 5098, 'message': 'Restart required: old code'}
        else
          'result': method == 'gateway.capabilities'
              ? {'per_session_exclusive_submit': true}
              : <String, dynamic>{},
      }),
    );
  });

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Sink implements WebSocketSink {
  _Sink(this.onAdd);
  final void Function(dynamic) onAdd;
  final Completer<void> _done = Completer<void>();

  @override
  void add(dynamic data) => onAdd(data);

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    if (!_done.isCompleted) _done.complete();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
