import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/models/bot_visual_identity.dart';

class _Auth extends DashboardClient {
  _Auth() : super(host: 'hermes.local', manualToken: 'test');
  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(queryName: 'ticket', credential: 'test');
}

class _Socket implements WebSocketChannel {
  final incoming = StreamController<dynamic>();
  final Map<String, dynamic> Function(String, Map<String, dynamic>) handle;
  _Socket(this.handle) {
    incoming.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'method': 'event',
        'params': {'type': 'gateway.ready', 'payload': {}},
      }),
    );
  }
  @override
  Future<void> get ready async {}
  @override
  Stream<dynamic> get stream => incoming.stream;
  @override
  late final WebSocketSink sink = _Sink((data) {
    final frame = jsonDecode(data as String) as Map;
    incoming.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': frame['id'],
        'result': handle(
          frame['method'] as String,
          Map<String, dynamic>.from(frame['params'] as Map),
        ),
      }),
    );
  });
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Sink implements WebSocketSink {
  final void Function(dynamic) send;
  final doneGate = Completer<void>();
  _Sink(this.send);
  @override
  void add(dynamic data) => send(data);
  @override
  Future<void> get done => doneGate.future;
  @override
  Future<void> close([int? code, String? reason]) async {
    if (!doneGate.isCompleted) doneGate.complete();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'empty creation and credential choice use current native wire fields',
    () async {
      Map<String, dynamic>? sent;
      final client = TuiGatewayClient(
        SavedConnection(
          id: 'test',
          label: 'Test',
          host: 'hermes.local',
          port: 8642,
          apiKey: '',
        ),
        dashboard: _Auth(),
        channelFactory: (_, _) => _Socket((method, params) {
          expect(method, 'profiles.create');
          sent = params;
          return {'ok': true};
        }),
      );
      addTearDown(client.close);
      await client.createProfileNative(
        name: 'empty',
        noSkills: true,
        shareAuth: false,
      );
      expect(sent!['clone_from'], isNull);
      expect(sent!['no_skills'], true);
      expect(sent!['mirror_credentials'], false);
    },
  );

  for (final cas in [false, true]) {
    test(
      'native metadata transport preserves unknown fields and title/identity/pin semantics CAS=$cas',
      () async {
        var meta = <String, dynamic>{
          'future': {'opaque': 1},
          'chat': 'canonical',
          'title': 'Old',
        };
        var revision = 0;
        final client = TuiGatewayClient(
          SavedConnection(
            id: 'test',
            label: 'Test',
            host: 'hermes.local',
            port: 8642,
            apiKey: '',
          ),
          dashboard: _Auth(),
          channelFactory: (_, _) => _Socket((method, params) {
            if (method == 'profiles.list') {
              return {
                'profiles': [
                  {
                    'name': 'bot',
                    'ui_meta': {'hermes-bots': meta},
                    if (cas) 'ui_meta_revisions': {'hermes-bots': revision},
                  },
                ],
              };
            }
            expect(method, 'profiles.configure');
            expect(
              params['ui_meta_expected_revisions'],
              cas ? {'hermes-bots': revision} : null,
            );
            meta = Map<String, dynamic>.from(
              (params['ui_meta'] as Map)['hermes-bots'] as Map,
            );
            revision++;
            return {
              'ok': true,
              'applied': {'ui_meta': true},
            };
          }),
        );
        addTearDown(client.close);
        await client.saveProfileBotMeta(
          profile: 'bot',
          title: '  New  ',
          pinned: true,
          hidden: false,
        );
        expect(meta, {
          'future': {'opaque': 1},
          'chat': 'canonical',
          'title': 'New',
          'pinned': true,
          'hidden': false,
        });
        await client.saveProfileBotMeta(
          profile: 'bot',
          title: '',
          pinned: false,
          identity: ClassicFaceIdentity(shape: 'cloud', colorHex: '#38bdf8'),
        );
        expect(meta.containsKey('title'), false);
        expect(meta['shape'], 'cloud');
        expect(meta['color'], '#38bdf8');
        expect(meta['pinned'], false);
        expect(meta['chat'], 'canonical');
        expect(meta['future'], {'opaque': 1});
      },
    );
  }
  test(
    'read-only mutations and unlisted RoomLink methods never open a socket',
    () async {
      var opened = false;
      final client = TuiGatewayClient(
        SavedConnection(
          id: 'readonly',
          label: 'Test',
          host: 'hermes.local',
          port: 8642,
          apiKey: '',
          readOnly: true,
        ),
        dashboard: _Auth(),
        channelFactory: (_, _) {
          opened = true;
          throw StateError('unexpected');
        },
      );
      addTearDown(client.close);
      await expectLater(
        client.patchBotMetadata('bot', {'pinned': true}),
        throwsA(isA<TuiGatewayRpcError>()),
      );
      await expectLater(
        client.roomLinkRequest('groups.peer.invite', {}),
        throwsA(isA<TuiGatewayRpcError>()),
      );
      await expectLater(
        client.roomLinkRequest('groups.send', {}),
        throwsA(isA<TuiGatewayRpcError>()),
      );
      expect(opened, false);
    },
  );
}
