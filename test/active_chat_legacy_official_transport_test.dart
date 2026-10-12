// SPDX-License-Identifier: MIT
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

import 'support/in_memory_compression_restore_storage.dart';

/// Controlled official HTTP/auth + real JSON-RPC WebSocket, not a fake gateway.
class _OfficialServer {
  _OfficialServer(
    this.server, {
    this.httpStatus = 200,
    this.rejectPrompt = false,
  }) {
    server.listen((request) async {
      paths.add(request.uri.path);
      if (httpStatus != 200) {
        request.response.statusCode = httpStatus;
        await request.response.close();
        return;
      }
      if (request.uri.path == '/') {
        request.response.write(
          'window.__HERMES_SESSION_TOKEN__="fixture-token";',
        );
      } else if (request.uri.path == '/api/auth/ws-ticket') {
        authHeaders.add(request.headers.value('x-hermes-session-token'));
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'ticket': 'fixture-ticket'}));
      } else if (request.uri.path == '/api/ws') {
        expect(request.uri.queryParameters, {'ticket': 'fixture-ticket'});
        final socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'event',
            'params': {
              'type': 'gateway.ready',
              'payload': {'heartbeat': false},
            },
          }),
        );
        await for (final raw in socket) {
          final frame = jsonDecode(raw as String) as Map<String, dynamic>;
          frames.add(frame);
          final result = switch (frame['method']) {
            'session.resume' || 'session.create' => {
              'session_id': 'runtime-fixture',
              'stored_session_id': 'stored-fixture',
              'status': 'idle',
              'running': false,
            },
            'session.active_list' => {'sessions': <Object>[]},
            'gateway.capabilities' => {'per_session_exclusive_submit': true},
            'client.capabilities' => {'server_requests': <Object>[]},
            'prompt.submit' => {'status': 'accepted'},
            'profiles.list' => {
              'profiles': [
                {'name': 'nb-work', 'active': true},
              ],
            },
            'profiles.create' => {'ok': true},
            _ => <String, dynamic>{},
          };
          if (rejectPrompt && frame['method'] == 'prompt.submit') {
            socket.add(
              jsonEncode({
                'jsonrpc': '2.0',
                'id': frame['id'],
                'error': {'code': -32601, 'message': 'Not supported'},
              }),
            );
          } else {
            socket.add(
              jsonEncode({
                'jsonrpc': '2.0',
                'id': frame['id'],
                'result': result,
              }),
            );
            if (frame['method'] == 'prompt.submit') acceptedReplies++;
          }
        }
        return;
      } else {
        request.response.statusCode = 404;
      }
      await request.response.close();
    });
  }
  final HttpServer server;
  final int httpStatus;
  final bool rejectPrompt;
  int acceptedReplies = 0;
  final paths = <String>[];
  final authHeaders = <String?>[];
  final sockets = <WebSocket>[];
  final frames = <Map<String, dynamic>>[];
  static Future<_OfficialServer> start({
    int port = 0,
    int httpStatus = 200,
    bool rejectPrompt = false,
  }) async => _OfficialServer(
    await HttpServer.bind(InternetAddress.loopbackIPv4, port),
    httpStatus: httpStatus,
    rejectPrompt: rejectPrompt,
  );
  Future<void> close() async {
    for (final socket in sockets) {
      await socket.close();
    }
    await server.close(force: true);
  }
}

class _RealHttp extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (_) async => null,
        );
  });
  for (final topology in [
    (InstanceKind.localhost, 0, true),
    (InstanceKind.localhost, 9131, true),
    (InstanceKind.localhost, 8643, true),
    (InstanceKind.vps, 0, false),
    (InstanceKind.homelab, 0, false),
  ]) {
    final (kind, port, onDevice) = topology;
    for (final profile in ['', 'nb-work']) {
      test(
        'real official send kind=$kind port=$port profile=$profile',
        () => HttpOverrides.runZoned(() async {
          final server = await _OfficialServer.start(port: port);
          addTearDown(server.close);
          final connection = SavedConnection(
            id: 'legacy-fixture',
            label: 'Saved client',
            host: '127.0.0.1',
            port: server.server.port,
            apiKey: 'synthetic-key',
            dashboardUrl: 'http://127.0.0.1:${server.server.port}',
            kind: kind,
            onDeviceLoopback: onDevice,
          );
          final chat = ActiveChat(
            connection: connection,
            sessionId: 'stored-fixture',
            sessionTitle: 'Fixture',
            sessionProfile: profile,
            notifications: null,
            onTerminal: () {},
            compressionRestoreStore: testCompressionRestoreStore(),
          );
          addTearDown(chat.dispose);
          final accepted = await chat
              .send(
                fullText: 'official fixture message',
                model: 'hermes-agent',
                history: const [],
              )
              .timeout(const Duration(seconds: 15));
          expect(accepted, isTrue);
          expect(server.acceptedReplies, 1);
          expect(chat.hasDesktopTransport, isTrue);
          final resume = server.frames.singleWhere(
            (f) => f['method'] == 'session.resume',
          );
          expect(
            resume.keys,
            unorderedEquals(['jsonrpc', 'id', 'method', 'params']),
          );
          expect(resume['jsonrpc'], '2.0');
          expect(resume['id'], isNotNull);
          expect(
            resume['params'],
            containsPair('session_id', 'stored-fixture'),
          );
          if (profile.isNotEmpty) {
            expect(resume['params'], containsPair('profile', profile));
          }
          final submit = server.frames.singleWhere(
            (f) => f['method'] == 'prompt.submit',
          );
          expect(
            submit['params'],
            containsPair('session_id', 'runtime-fixture'),
          );
          expect(
            submit['params'],
            containsPair('text', 'official fixture message'),
          );
          expect(server.authHeaders, ['fixture-token']);
          expect(server.paths.where((p) => p.contains('bridge')), isEmpty);
          expect(connection.port, server.server.port);
          expect(connection.onDeviceLoopback, onDevice);
          expect(chat.sessionProfile, profile.isEmpty ? 'default' : profile);
        }, createHttpClient: _RealHttp().createHttpClient),
      );
    }
  }
  for (final status in [401, 403, 404, 500]) {
    for (final profile in ['', 'nb-work']) {
      test(
        'default factory official HTTP $status profile=$profile fails honestly',
        () => HttpOverrides.runZoned(() async {
          final server = await _OfficialServer.start(httpStatus: status);
          addTearDown(server.close);
          final connection = SavedConnection(
            id: 'error-fixture',
            label: 'Fixture',
            host: '127.0.0.1',
            port: server.server.port,
            apiKey: 'synthetic-key',
            dashboardUrl: 'http://127.0.0.1:${server.server.port}',
            kind: InstanceKind.localhost,
            onDeviceLoopback: true,
          );
          final chat = ActiveChat(
            connection: connection,
            sessionId: 'stored-fixture',
            sessionTitle: 'Fixture',
            sessionProfile: profile,
            notifications: null,
            onTerminal: () {},
            compressionRestoreStore: testCompressionRestoreStore(),
          );
          addTearDown(chat.dispose);
          expect(
            await chat.send(
              fullText: 'synthetic',
              model: 'hermes-agent',
              history: const [],
            ),
            isFalse,
          );
          await Future<void>.delayed(const Duration(milliseconds: 300));
          expect(chat.state, ChatPipelineState.failed);
          expect(chat.sessionProfile, profile.isEmpty ? 'default' : profile);
          expect(server.paths, ['/']);
          expect(server.frames, isEmpty);
        }, createHttpClient: _RealHttp().createHttpClient),
      );
    }
  }
  for (final profile in ['', 'nb-work']) {
    for (final reject in [false, true]) {
      test(
        'default factory session create profile=$profile rejected=$reject owns result',
        () => HttpOverrides.runZoned(() async {
          final server = await _OfficialServer.start(rejectPrompt: reject);
          addTearDown(server.close);
          final connection = SavedConnection(
            id: 'create-fixture',
            label: 'Fixture',
            host: '127.0.0.1',
            port: server.server.port,
            apiKey: 'synthetic-key',
            dashboardUrl: 'http://127.0.0.1:${server.server.port}',
            kind: InstanceKind.localhost,
            onDeviceLoopback: true,
          );
          final chat = ActiveChat(
            connection: connection,
            sessionId: 'mob-fixture',
            sessionTitle: 'Fixture',
            sessionProfile: profile,
            notifications: null,
            onTerminal: () {},
            compressionRestoreStore: testCompressionRestoreStore(),
          );
          addTearDown(chat.dispose);
          final accepted = await chat.send(
            fullText: 'create fixture',
            model: 'hermes-agent',
            history: const [],
          );
          expect(accepted, !reject);
          expect(server.acceptedReplies, reject ? 0 : 1);
          expect(chat.sessionProfile, profile.isEmpty ? 'default' : profile);
          final create = server.frames.singleWhere(
            (f) => f['method'] == 'session.create',
          );
          expect(
            create['params'],
            containsPair('profile', profile.isEmpty ? 'default' : profile),
          );
          expect(
            server.frames.where((f) => f['method'] == 'session.resume'),
            isEmpty,
          );
          expect(
            server.paths.where(
              (p) => p.contains('bridge') || p.endsWith('/v1/runs'),
            ),
            isEmpty,
          );
          if (reject) expect(chat.state, ChatPipelineState.failed);
        }, createHttpClient: _RealHttp().createHttpClient),
      );
    }
  }
  test(
    'official profile list/create on explicit port9131 has real scoped results',
    () => HttpOverrides.runZoned(() async {
      final server = await _OfficialServer.start(port: 9131);
      addTearDown(server.close);
      final connection = SavedConnection(
        id: 'profile-fixture',
        label: 'Fixture',
        host: '127.0.0.1',
        port: 9131,
        apiKey: 'synthetic-key',
        dashboardUrl: 'http://127.0.0.1:9131',
        kind: InstanceKind.localhost,
        onDeviceLoopback: true,
      );
      final client = TuiGatewayClient(connection);
      addTearDown(client.close);
      final profiles = await client.listProfiles();
      expect(profiles.single.name, 'nb-work');
      await client.createProfileNative(
        name: 'new-work',
        cloneFrom: 'nb-work',
        shareAuth: false,
      );
      final frame = server.frames.singleWhere(
        (f) => f['method'] == 'profiles.create',
      );
      expect(frame['params'], {
        'name': 'new-work',
        'description': '',
        'clone_from': 'nb-work',
        'no_skills': false,
        'share_auth': false,
        'mirror_credentials': false,
      });
      expect(server.paths.where((p) => p.contains('bridge')), isEmpty);
      expect(connection.port, 9131);
    }, createHttpClient: _RealHttp().createHttpClient),
  );
}
