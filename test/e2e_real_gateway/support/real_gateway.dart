// End-to-end harness: Console's real gateway client and chat service against
// a REAL `hermes serve` (Dashboard REST + /api/ws) and `gateway.run` API
// server, both driven by Hermes' own scripted loopback model provider.
//
// Nothing here is a fake of Hermes: every frame and every page comes from the
// backend `tool/e2e/run_local.sh` (or the CI job) starts. The suite is
// skipped unless HERMES_E2E_URL and HERMES_E2E_TOKEN are set.
//
// Every HTTP request and WebSocket frame Console sends or receives is metered
// here, so scenarios can assert performance budgets (requests and bytes per
// chat open, reads per terminal, sockets per chat) and fail on regressions.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

// ignore: depend_on_referenced_packages
import 'package:async/async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:http/http.dart' as http;
// ignore: depend_on_referenced_packages
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../support/in_memory_compression_restore_storage.dart';

/// Backend coordinates published by `tool/e2e/backend.py` (`backend.env`).
final class E2eEnv {
  E2eEnv._(this.vars);

  final Map<String, String> vars;

  static final E2eEnv current = E2eEnv._(Platform.environment);

  /// The skip reason, or null when the backend is configured.
  String? get skipReason =>
      (vars['HERMES_E2E_URL'] ?? '').isEmpty ||
          (vars['HERMES_E2E_TOKEN'] ?? '').isEmpty
      ? 'real-gateway E2E: set HERMES_E2E_URL/HERMES_E2E_TOKEN '
            '(tool/e2e/run_local.sh does)'
      : null;

  Uri get dashboard => Uri.parse(vars['HERMES_E2E_URL']!);
  String get user => vars['HERMES_E2E_USER'] ?? 'e2e';
  String get password => vars['HERMES_E2E_TOKEN']!;
  Uri get api => Uri.parse(vars['HERMES_E2E_API_URL'] ?? '');
  String get apiKey => vars['HERMES_E2E_API_KEY'] ?? '';
  Uri get control => Uri.parse(vars['HERMES_E2E_CONTROL_URL'] ?? '');
  String get seededSession =>
      vars['HERMES_E2E_SEEDED_SESSION'] ?? 'e2e-seeded-300';
  int get seededRows => int.parse(vars['HERMES_E2E_SEEDED_ROWS'] ?? '300');

  /// How many main-turn provider requests started from a user prompt
  /// carrying [tag]. A prompt reaching the model twice shows here as 2.
  Future<int> modelTurnsFor(String tag) =>
      _controlCount('/main-requests', {'tag': tag});

  /// Rows a committed compaction archived in [sessionId]'s lineage.
  Future<int> compactedRows(String sessionId) =>
      _controlCount('/compacted-rows', {'session': sessionId});

  Future<int> _controlCount(String path, Map<String, String> query) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(
        control.replace(path: path, queryParameters: query),
      );
      final response = await request.close();
      final body = await utf8.decodeStream(response);
      return (jsonDecode(body) as Map<String, dynamic>)['count'] as int;
    } finally {
      client.close(force: true);
    }
  }
}

/// One metered HTTP request.
final class MeteredRequest {
  MeteredRequest(this.method, this.url, this.status, this.bytes);

  final String method;
  final Uri url;
  final int status;
  final int bytes;

  bool get isTranscriptPage =>
      method == 'GET' &&
      RegExp(r'/sessions/[^/]+/messages$').hasMatch(url.path);

  @override
  String toString() => '$method ${url.path}?${url.query} -> $status ($bytes B)';
}

/// HTTP client that records every request and its response size.
final class MeteredHttpClient extends http.BaseClient {
  MeteredHttpClient(this.meter);

  final TrafficMeter meter;
  final http.Client _inner = http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await _inner.send(request);
    final bytes = await response.stream.toBytes();
    meter.http.add(
      MeteredRequest(
        request.method,
        request.url,
        response.statusCode,
        bytes.length,
      ),
    );
    return http.StreamedResponse(
      Stream.value(bytes),
      response.statusCode,
      contentLength: bytes.length,
      request: response.request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  @override
  void close() => _inner.close();
}

/// One WebSocket the client opened, with every frame in both directions.
final class MeteredSocket {
  MeteredSocket(this.index);

  final int index;
  final sent = <Map<String, dynamic>>[];
  final received = <Map<String, dynamic>>[];
  var receivedBytes = 0;
  bool closed = false;

  Iterable<String> sentMethods() =>
      sent.map((frame) => frame['method']).whereType<String>();

  int count(String method) => sentMethods().where((m) => m == method).length;
}

/// TCP forwarder in front of the Dashboard. [severAll] destroys every
/// connection at once without a close frame: what a wifi/cellular switch
/// does to a phone's sockets.
final class SeverableProxy {
  SeverableProxy._(this._server, this._target) {
    _server.listen((client) async {
      try {
        final upstream = await Socket.connect(_target.host, _target.port);
        _pairs.add((client, upstream));
        client.listen(
          upstream.add,
          onError: (Object _) => upstream.destroy(),
          onDone: upstream.destroy,
          cancelOnError: true,
        );
        upstream.listen(
          client.add,
          onError: (Object _) => client.destroy(),
          onDone: client.destroy,
          cancelOnError: true,
        );
      } on Object {
        client.destroy();
      }
    });
  }

  final ServerSocket _server;
  final Uri _target;
  final _pairs = <(Socket, Socket)>[];

  int get port => _server.port;

  /// Binds on the backend's own host: Hermes rejects a Host header that
  /// does not name the interface it bound (DNS-rebinding guard).
  static Future<SeverableProxy> start(Uri target) async =>
      SeverableProxy._(await ServerSocket.bind(target.host, 0), target);

  void severAll() {
    for (final (a, b) in _pairs) {
      a.destroy();
      b.destroy();
    }
    _pairs.clear();
  }

  Future<void> close() async {
    severAll();
    await _server.close();
  }
}

/// Records Console's traffic against the real backend.
final class TrafficMeter {
  final http = <MeteredRequest>[];
  final sockets = <MeteredSocket>[];

  /// When set, WebSockets are dialled through this proxy.
  SeverableProxy? proxy;

  int _httpMark = 0;
  final _frameMarks = <int, int>{};

  /// Starts a measurement window.
  void mark() {
    _httpMark = http.length;
    _frameMarks
      ..clear()
      ..addEntries(sockets.map((s) => MapEntry(s.index, s.sent.length)));
  }

  List<MeteredRequest> get httpSinceMark => http.sublist(_httpMark);

  List<MeteredRequest> get transcriptPagesSinceMark =>
      httpSinceMark.where((r) => r.isTranscriptPage).toList();

  int get bytesSinceMark =>
      httpSinceMark.fold(0, (sum, request) => sum + request.bytes);

  /// RPC methods sent on every socket since [mark].
  List<String> rpcSinceMark() => [
    for (final socket in sockets)
      ...socket.sent
          .skip(_frameMarks[socket.index] ?? 0)
          .map((f) => f['method'])
          .whereType<String>(),
  ];

  int get openSockets => sockets.where((s) => !s.closed).length;

  WebSocketChannel connect(Uri uri, Map<String, dynamic> headers) {
    final via = proxy;
    final target = via == null ? uri : uri.replace(port: via.port);
    final channel = IOWebSocketChannel.connect(
      target,
      headers: headers,
      pingInterval: const Duration(seconds: 20),
      connectTimeout: const Duration(seconds: 10),
    );
    final socket = MeteredSocket(sockets.length);
    sockets.add(socket);
    return _MeteredChannel(channel, socket);
  }

  /// Per-socket trace of what went over the wire (methods out, event types
  /// and reply keys in), for diagnosing a failed scenario from the log.
  String wireTrace() {
    final lines = <String>[];
    for (final socket in sockets) {
      final out = socket.sentMethods().join(',');
      final inbound = socket.received.map((f) {
        final params = f['params'];
        if (f['method'] == 'event' && params is Map) return '${params['type']}';
        if (f['method'] is String) return 'req:${f['method']}';
        final result = f['result'];
        if (result is Map) {
          final open = result['open_requests'];
          return 'reply${open is List ? '(open=${open.length})' : ''}';
        }
        return f.containsKey('error') ? 'error' : 'reply';
      });
      // Run-length encode: message.delta x22 instead of 22 entries.
      final collapsed = <String>[];
      String? previous;
      var run = 0;
      void flush() {
        if (previous != null) {
          collapsed.add(run > 1 ? '$previous x$run' : previous);
        }
      }

      for (final item in inbound) {
        if (item == previous) {
          run++;
          continue;
        }
        flush();
        previous = item;
        run = 1;
      }
      flush();
      lines.add('  #${socket.index} out[$out] in[${collapsed.join(',')}]');
    }
    return lines.join('\n');
  }

  String report() {
    final pages = http.where((r) => r.isTranscriptPage).length;
    final bytes = http.fold(0, (sum, r) => sum + r.bytes);
    return 'http=${http.length} pages=$pages bytes=$bytes '
        'sockets=${sockets.length} open=$openSockets';
  }
}

void _record(List<Map<String, dynamic>> into, Object? raw) {
  final text = raw is String
      ? raw
      : raw is List<int>
      ? utf8.decode(raw)
      : '';
  for (final line in const LineSplitter().convert(text)) {
    if (line.trim().isEmpty) continue;
    try {
      final decoded = jsonDecode(line);
      if (decoded is Map<String, dynamic>) into.add(decoded);
    } on FormatException {
      // Not JSON: not ours to meter.
    }
  }
}

final class _MeteredChannel extends StreamChannelMixin<dynamic>
    implements WebSocketChannel {
  _MeteredChannel(this._inner, this._socket)
    : stream = _inner.stream.transform(
        StreamTransformer<dynamic, dynamic>.fromHandlers(
          handleData: (raw, sink) {
            _socket.receivedBytes += raw is String
                ? raw.length
                : (raw as List<int>).length;
            _record(_socket.received, raw);
            sink.add(raw);
          },
          handleDone: (sink) {
            _socket.closed = true;
            sink.close();
          },
        ),
      );

  final IOWebSocketChannel _inner;
  final MeteredSocket _socket;

  @override
  final Stream<dynamic> stream;

  @override
  late final WebSocketSink sink = _MeteredSink(_inner.sink, _socket);

  @override
  int? get closeCode => _inner.closeCode;

  @override
  String? get closeReason => _inner.closeReason;

  @override
  String? get protocol => _inner.protocol;

  @override
  Future<void> get ready => _inner.ready;
}

final class _MeteredSink extends DelegatingStreamSink<dynamic>
    implements WebSocketSink {
  _MeteredSink(this._inner, this._socket) : super(_inner);

  final WebSocketSink _inner;
  final MeteredSocket _socket;

  @override
  void add(dynamic data) {
    _record(_socket.sent, data);
    _inner.add(data);
  }

  @override
  Future<void> close([int? closeCode, String? closeReason]) {
    _socket.closed = true;
    return _inner.close(closeCode, closeReason);
  }
}

/// One Console "phone" talking to the real backend.
final class E2eConsole {
  E2eConsole(this.env, {String id = 'e2e-phone'})
    : connection = SavedConnection(
        id: id,
        label: 'Real gateway E2E',
        host: env.api.host,
        port: env.api.port,
        apiKey: env.apiKey,
        dashboardUrl: env.dashboard.toString(),
        dashboardAuthMode: AuthMode.basicAuth,
      ) {
    http = MeteredHttpClient(meter);
  }

  final E2eEnv env;
  final SavedConnection connection;
  final meter = TrafficMeter();
  late final MeteredHttpClient http;
  final _clients = <TuiGatewayClient>[];
  final _chats = <ActiveChat>[];

  DashboardClient dashboard() => DashboardClient(
    host: env.dashboard.host,
    port: env.dashboard.port,
    basicUser: env.user,
    basicPass: env.password,
    httpClientOverride: http,
  );

  TuiGatewayClient gateway() {
    final client = TuiGatewayClient(
      connection,
      dashboard: dashboard(),
      channelFactory: meter.connect,
    );
    _clients.add(client);
    return client;
  }

  ApiClient api() => ApiClient(
    baseUrl: connection.baseUrl,
    apiKey: env.apiKey,
    connectionId: connection.id,
    httpClient: http,
  );

  /// Opens [sessionId] the way the chat screen does: the real chat service
  /// with its own socket, attached to the live runtime on load.
  ActiveChat open(
    String sessionId, {
    TuiGatewayClient? gateway,
    int expectedMessageCount = 0,
  }) {
    final chat = ActiveChat(
      compressionRestoreStore: testCompressionRestoreStore(),
      connection: connection,
      sessionId: sessionId,
      initialStoredSessionId: sessionId,
      sessionTitle: 'E2E $sessionId',
      notifications: null,
      onTerminal: () {},
      api: api(),
      transcriptDashboard: dashboard(),
      desktopGateway: gateway ?? this.gateway(),
      attachDesktopRuntimeOnLoad: true,
      // Production recovery cadence (no test override): a reconnect must
      // converge with the timings phones really use.
    );
    chat.smoothStreaming = false;
    _chats.add(chat);
    return chat;
  }

  Future<void> close() async {
    for (final chat in _chats) {
      chat.dispose();
    }
    for (final client in _clients) {
      await client.close();
    }
    http.close();
    await meter.proxy?.close();
  }
}

/// Initialises the test binding (platform-channel mocks for preferences and
/// secure storage) but gives the suite back real sockets: the binding
/// replaces `HttpClient` with one that answers 400 to everything.
void useRealNetwork() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
}

/// One-line chat state for failure messages.
String describeChat(ActiveChat chat) {
  // `messages` is newest-first.
  final rows = chat.messages
      .take(6)
      .map((m) {
        final text = '${m['content']}';
        final id = m['id'] ?? m['client_id'] ?? m['_local_id'] ?? '-';
        return '$id/${m['role']}:${text.length > 40 ? text.substring(0, 40) : text}';
      })
      .join(' | ');
  return 'state=${chat.state.name} streaming=${chat.isStreaming} '
      'runtime=${chat.desktopRuntimeSessionId} rows=${chat.messages.length} '
      'assistantContent=${chat.assistantContent.length}ch tail=[$rows]';
}

/// Polls [condition] in real time.
Future<void> waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 30),
  String what = 'condition',
  ActiveChat? chat,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail(
        'timed out after ${timeout.inSeconds}s waiting for $what'
        '${chat == null ? '' : '\n  ${describeChat(chat)}'}',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// Prints one budget line that run_local.sh / CI keep in the log.
void reportBudget(String name, Map<String, Object> values) {
  // ignore: avoid_print
  print(
    '[e2e-budget] $name ${values.entries.map((e) => '${e.key}=${e.value}').join(' ')}',
  );
}
