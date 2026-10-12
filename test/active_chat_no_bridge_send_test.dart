// SPDX-License-Identifier: MIT
// A saved legacy on-device localhost connection must send
// chat turns, with and without a non-default profile, through the official
// Hermes transport only. Zero `/bridge/*` and zero provisioning, including
// when the official gateway fails. Explicit official port9131 is valid.
// Synthetic data only; no real servers.
//
// Uses only the default transports of ActiveChat (no Bridge injection), and
// records every HttpClient request with its origin stack.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:hermes_android/core/models/connection.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Req {
  final String method;
  final Uri uri;
  final String origin;
  _Req(this.method, this.uri, this.origin);
  bool get bridge =>
      uri.path.contains('/bridge/') || uri.path.endsWith('/bridge');
  @override
  String toString() => '$method $uri <- $origin';
}

final _requests = <_Req>[];
int Function(Uri) _status = (_) => 404;

String _origin() {
  final frames = StackTrace.current.toString().split('\n');
  return frames
      .where((f) => f.contains('package:hermes_android/'))
      .map(
        (f) => f
            .replaceAll(RegExp(r'.*package:hermes_android/'), '')
            .replaceAll(')', ''),
      )
      .take(3)
      .join(' < ');
}

class _FakeClient implements HttpClient {
  @override
  dynamic noSuchMethod(Invocation i) {
    final name = i.memberName.toString();
    if (name.contains('openUrl')) {
      return Future.value(
        _FakeRequest(
          i.positionalArguments[0] as String,
          i.positionalArguments[1] as Uri,
        ),
      );
    }
    for (final verb in ['get', 'post', 'put', 'delete', 'head', 'patch']) {
      if (name == 'Symbol("${verb}Url")') {
        return Future.value(
          _FakeRequest(verb.toUpperCase(), i.positionalArguments[0] as Uri),
        );
      }
    }
    return null;
  }
}

class _FakeRequest implements HttpClientRequest {
  _FakeRequest(this.method, this.uri) {
    _requests.add(_Req(method, uri, _origin()));
  }
  @override
  final String method;
  @override
  final Uri uri;
  @override
  final HttpHeaders headers = _FakeHeaders();
  @override
  Encoding encoding = utf8;
  @override
  bool followRedirects = true;
  @override
  int maxRedirects = 5;
  @override
  bool persistentConnection = true;
  @override
  int contentLength = -1;
  @override
  bool bufferOutput = true;
  @override
  void add(List<int> data) {}
  @override
  void write(Object? object) {}
  @override
  Future addStream(Stream<List<int>> stream) => stream.drain();
  @override
  Future<HttpClientResponse> close() async {
    final status = _status(uri);
    if (status == 0) throw TimeoutException('Synthetic official timeout');
    if (status == -1) throw const SocketException('Synthetic official offline');
    return _FakeResponse(status);
  }

  @override
  Future<HttpClientResponse> get done => close();
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

class _FakeHeaders implements HttpHeaders {
  final _m = <String, List<String>>{};
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      _m[name.toLowerCase()] = ['$value'];
  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) =>
      (_m[name.toLowerCase()] ??= []).add('$value');
  @override
  String? value(String name) => _m[name.toLowerCase()]?.first;
  @override
  List<String>? operator [](String name) => _m[name.toLowerCase()];
  @override
  void forEach(void Function(String, List<String>) f) => _m.forEach(f);
  @override
  ContentType? contentType;
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

class _FakeResponse extends Stream<List<int>> implements HttpClientResponse {
  _FakeResponse(this.statusCode);
  @override
  final int statusCode;
  @override
  String get reasonPhrase => 'synthetic';
  @override
  bool get isRedirect => false;
  @override
  List<RedirectInfo> get redirects => const [];
  @override
  bool get persistentConnection => false;
  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;
  @override
  int get contentLength => 2;
  @override
  HttpHeaders get headers =>
      _FakeHeaders()..set('content-type', 'application/json');
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.fromIterable([utf8.encode('{}')]).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

final _legacyLocal = SavedConnection(
  id: 'nb-legacy-local',
  label: 'Hermes local',
  host: '127.0.0.1',
  port: 9119,
  apiKey: 'synthetic-local-token',
  dashboardUrl: 'http://127.0.0.1:9119',
  kind: InstanceKind.localhost,
  onDeviceLoopback: true,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (_) async => null,
        );
    _requests.clear();
    _status = (_) => 404;
    SharedPreferences.setMockInitialValues({});
  });

  for (final status in [404, 401, 500, 403, 0, -1]) {
    for (final profile in ['', 'nb-work']) {
      test('legacy localhost send (official=$status, profile="$profile"): '
          'zero Bridge', () async {
        _status = (_) => status;
        Object? outcome;
        await HttpOverrides.runZoned(() async {
          final chat = ActiveChat(
            connection: _legacyLocal,
            sessionId: 'nb-session',
            sessionTitle: 'Synthetic',
            notifications: null,
            onTerminal: () {},
          );

          try {
            outcome = await chat
                .send(
                  fullText: 'synthetic prompt',
                  model: 'hermes-agent',
                  history: const [],
                  profile: profile,
                )
                .timeout(const Duration(seconds: 20));
          } catch (e) {
            outcome = 'error:${e.runtimeType}';
          }
          await Future<void>.delayed(const Duration(milliseconds: 300));
          chat.dispose();
          for (final r in _requests) {
            debugPrint('NBSEND $status "$profile" request $r');
          }
          debugPrint(
            'NBSEND $status "$profile" outcome=$outcome requests=${_requests.length}',
          );
        }, createHttpClient: (c) => _FakeClient());
        final bridge = _requests.where((r) => r.bridge).toList();
        expect(bridge, isEmpty, reason: bridge.join('\n'));
        expect(outcome, isFalse);
        expect(_requests, isNotEmpty);
        expect(
          _requests.every(
            (r) =>
                r.uri.host == _legacyLocal.host &&
                r.uri.port == _legacyLocal.dashboardPort,
          ),
          isTrue,
        );
        expect(_requests.any((r) => r.uri.path == '/'), isTrue);
        expect(
          _requests.where((r) => r.uri.path.endsWith('/v1/runs')),
          isEmpty,
        );
      });
    }
  }

  test('positive control: the recorder sees a Bridge request', () async {
    await HttpOverrides.runZoned(() async {
      final c = HttpClient();
      final req = await c.getUrl(
        Uri.parse('http://127.0.0.1:9131/bridge/health'),
      );
      await req.close();
    }, createHttpClient: (c) => _FakeClient());
    expect(_requests.where((r) => r.bridge), hasLength(1));
  });
}
