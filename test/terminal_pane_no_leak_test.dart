// Nothing a terminal run produces leaves memory: a marker in the output, in a
// refusal and in a process chunk is absent from the error log, a diagnostic
// bundle, debugPrint output, SharedPreferences and secure storage.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/agent_terminal_stream.dart';
import 'package:hermes_android/core/services/app_error_log.dart';
import 'package:hermes_android/core/services/diagnostic_bundle_service.dart';
import 'package:hermes_android/core/services/terminal_pane_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

final class _Dashboard extends DashboardClient {
  _Dashboard() : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(queryName: 'ticket', credential: 't');
}

final class _Channel implements WebSocketChannel {
  _Channel(this.requests, this.respond) {
    _incoming.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'method': 'event',
        'params': {'type': 'gateway.ready', 'payload': <String, dynamic>{}},
      }),
    );
  }

  final List<Map<String, dynamic>> requests;
  final Object Function(Map<String, dynamic> frame) respond;
  final StreamController<dynamic> _incoming = StreamController<dynamic>();

  @override
  Future<void> get ready async {}

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  late final WebSocketSink sink = _Sink((data) {
    final frame = Map<String, dynamic>.from(jsonDecode(data as String) as Map);
    requests.add(frame);
    final answer = respond(frame);
    _incoming.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': frame['id'],
        if (answer is Map && answer.containsKey('__error'))
          'error': {'code': answer['__error'], 'message': answer['message']}
        else if (answer is int)
          'error': {'code': answer, 'message': 'x'}
        else
          'result': answer,
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

({TuiGatewayClient client, List<Map<String, dynamic>> requests}) _client(
  Object Function(Map<String, dynamic> frame) respond, {
  bool readOnly = false,
}) {
  final requests = <Map<String, dynamic>>[];
  final client = TuiGatewayClient(
    SavedConnection(
      id: 'term-wire',
      label: 'wire',
      host: 'hermes.local',
      port: 8642,
      apiKey: 'k',
      readOnly: readOnly,
    ),
    dashboard: _Dashboard(),
    channelFactory: (_, _) => _Channel(requests, (frame) {
      return switch (frame['method']) {
        'gateway.capabilities' => {'per_session_exclusive_submit': true},
        'client.capabilities' => {'server_requests': <String>[]},
        _ => respond(frame),
      };
    }),
  );
  addTearDown(client.close);
  return (client: client, requests: requests);
}

const _marker = 'LEAK-MARKER-7f3a9';

void main() {
  late List<String> printed;
  late DebugPrintCallback originalDebugPrint;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppErrorLog.resetForTesting();
    printed = [];
    originalDebugPrint = debugPrint;
    debugPrint = (message, {wrapWidth}) => printed.add(message ?? '');
  });

  tearDown(() => debugPrint = originalDebugPrint);

  test('outputs, refusals and chunks stay in memory only', () async {
    var step = 0;
    final h = _client((frame) {
      if (frame['method'] != 'shell.exec') return {'processes': <Object>[]};
      final command = (frame['params'] as Map)['command'] as String;
      if (command.isEmpty) return {'__error': 4004, 'message': 'empty command'};
      step += 1;
      return switch (step) {
        1 => {'stdout': 'out $_marker', 'stderr': 'err $_marker', 'code': 0},
        2 => {'__error': 4005, 'message': 'blocked: $_marker'},
        _ => {'__error': -32000, 'message': 'boom $_marker'},
      };
    });
    final controller = TerminalPaneController(
      gateway: h.client,
      profile: 'p',
      appLockEnabled: () => true,
      verify: () async => true,
    );
    addTearDown(controller.dispose);
    await controller.open();
    await controller.run('echo $_marker');
    expect(controller.lastResult?.stdout, contains(_marker));
    await controller.run('rm $_marker');
    expect(controller.refusal?.message, contains(_marker));
    await controller.run('boom $_marker');
    expect(controller.failed, isTrue);

    final stream = AgentTerminalStream()..onChunk('p1', 'chunk $_marker');
    expect(stream.backlog('p1'), contains(_marker));

    // The page is still alive and holds the marker in memory; nothing else may.
    AppErrorLog.record('terminal', StateError(_marker));
    final bundle = DiagnosticBundleService().build(
      DiagnosticBundleInput(
        appVersion: '1.2.15',
        buildNumber: 1,
        flavor: DiagnosticFlavor.full,
        androidApi: 34,
        formFactor: DiagnosticFormFactor.phone,
        recentErrors: [
          for (final r in AppErrorLog.recent)
            DiagnosticErrorEvent.fromAppError(r),
        ],
      ),
    );
    final prefs = await SharedPreferences.getInstance();
    final prefDump = [
      for (final k in prefs.getKeys()) '$k=${prefs.get(k)}',
    ].join('\n');
    final secure = (await const FlutterSecureStorage().readAll()).toString();

    expect(AppErrorLog.recent.join('\n'), isNot(contains(_marker)));
    expect(bundle.preview, isNot(contains(_marker)));
    expect(printed.join('\n'), isNot(contains(_marker)));
    expect(prefDump, isNot(contains(_marker)));
    expect(secure, isNot(contains(_marker)));
    expect(
      controller.history.join('\n'),
      contains(_marker),
      reason: 'sanity: the marker really is in memory',
    );
    stream.dispose();
  });

  test('after dispose not even memory holds the marker', () async {
    final h = _client(
      (frame) => (frame['params'] as Map)['command'] == ''
          ? {'__error': 4004, 'message': 'empty command'}
          : {'stdout': _marker, 'stderr': '', 'code': 0},
    );
    final controller = TerminalPaneController(
      gateway: h.client,
      profile: 'p',
      appLockEnabled: () => true,
      verify: () async => true,
    );
    await controller.open();
    await controller.run('echo $_marker');
    controller.dispose();
    expect(controller.history, isEmpty);
    expect(controller.lastResult, isNull);
  });
}
