import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

class _TicketDashboardClient extends DashboardClient {
  _TicketDashboardClient()
    : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(
        queryName: 'ticket',
        credential: 'ticket-bot-mode',
      );
}

TuiGatewayClient _clientFor(HttpServer server) => TuiGatewayClient(
  SavedConnection(
    id: 'conn-bot-mode',
    label: 'Bot Mode',
    host: '127.0.0.1',
    port: 8642,
    apiKey: 'gateway-key',
    dashboardUrl: 'http://127.0.0.1:${server.port}',
  ),
  dashboard: _TicketDashboardClient(),
);

void main() {
  test(
    'roster solicita señales Desktop cargadas y pins preferidos sin polling',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final requests = <Map<String, dynamic>>[];
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        await for (final raw in socket) {
          final frame = jsonDecode(raw as String) as Map<String, dynamic>;
          requests.add(frame);
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': frame['id'],
              'result': {
                'profiles': [
                  {
                    'name': 'research',
                    'preferred_session': {
                      'id': 'stored-bot-chat',
                      'resolved_id': 'stored-bot-chat--compact-1',
                      'title': 'Bot Chat',
                      'last_active': 120,
                    },
                    'worker_session': {
                      'id': 'worker-opaque',
                      'source': 'kanban',
                      'title': 'work kanban T-3',
                      'last_active': 125,
                    },
                  },
                ],
              },
            }),
          );
        }
      });

      final client = _clientFor(server);
      addTearDown(client.close);
      final profiles = await client.listProfiles(
        includeSessions: true,
        preferredSessionIds: const {
          'research': 'stored-bot-chat',
          '../invalid-profile': 'must-not-leave-device',
          'qa': 'bad\nsession',
          'mobile': 'mob-local-provisional',
        },
      );

      expect(requests, hasLength(1));
      expect(requests.single['method'], 'profiles.list');
      expect(requests.single['params'], {
        'include_sessions': true,
        'preferred_session_ids': {'research': 'stored-bot-chat'},
      });
      expect(
        profiles.single.preferredSession?.resolvedId,
        'stored-bot-chat--compact-1',
      );
      expect(profiles.single.workerSession?.source, 'kanban');
    },
  );

  test('roster moderno degrada con respuesta de Gateway antiguo', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final requests = <Map<String, dynamic>>[];
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      await for (final raw in socket) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        requests.add(frame);
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': frame['id'],
            'result': {
              'profiles': [
                {'name': 'legacy'},
              ],
            },
          }),
        );
      }
    });

    final client = _clientFor(server);
    addTearDown(client.close);
    final profiles = await client.listProfiles(includeSessions: true);

    expect(requests, hasLength(1));
    expect(requests.single['params'], {'include_sessions': true});
    expect(profiles.single.lastSession, isNull);
    expect(profiles.single.preferredSession, isNull);
    expect(profiles.single.workerSession, isNull);
  });

  test(
    'findCanonicalBotChat uses hidden session.list for the profile',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final requests = <Map<String, dynamic>>[];
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        await for (final raw in socket) {
          final frame = jsonDecode(raw as String) as Map<String, dynamic>;
          requests.add(frame);
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': frame['id'],
              'result': {
                'sessions': [
                  {
                    'id': 'scratch',
                    'title': 'Scratch work',
                    'message_count': 9,
                    'started_at': 40,
                  },
                  {
                    'id': 'older-bot-chat',
                    'title': 'Bot Chat',
                    'message_count': 2,
                    'started_at': 10,
                  },
                  {
                    'id': 'canonical-bot-chat',
                    'title': 'Bot Chat',
                    'message_count': 163,
                    'started_at': 20,
                  },
                  {
                    'id': 'mob-bot-infra',
                    'title': 'Bot Chat',
                    'message_count': 400,
                    'started_at': 50,
                  },
                ],
              },
            }),
          );
        }
      });

      final client = _clientFor(server);
      addTearDown(client.close);
      final id = await client.findCanonicalBotChat(profile: 'infra');

      expect(requests, hasLength(1));
      expect(requests.single['method'], 'session.list');
      expect(requests.single['params'], {
        'limit': 50,
        'include_hidden': true,
        'profile': 'infra',
      });
      expect(id, 'canonical-bot-chat');
    },
  );

  test(
    'profile creation uses the native Desktop contract in one write',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final requests = <Map<String, dynamic>>[];
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        await for (final raw in socket) {
          final frame = jsonDecode(raw as String) as Map<String, dynamic>;
          requests.add(frame);
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': frame['id'],
              'result': {'ok': true},
            }),
          );
        }
      });

      final client = _clientFor(server);
      addTearDown(client.close);
      await client.createProfileNative(
        name: 'release-qa',
        cloneFrom: 'default',
        description: 'Release quality',
        soul: '# QA\nVerify the build.',
        model: 'gpt-5.6-codex',
        provider: 'openai-codex',
      );

      expect(requests, hasLength(1));
      expect(requests.single['method'], 'profiles.create');
      expect(requests.single['params'], {
        'name': 'release-qa',
        'description': 'Release quality',
        'clone_from': 'default',
        'no_skills': false,
        'share_auth': true,
        'soul': '# QA\nVerify the build.',
        'model': 'gpt-5.6-codex',
        'provider': 'openai-codex',
      });
    },
  );

  test(
    'profile creation rejects a half-configured model before transport',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      var requests = 0;
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        await for (final _ in socket) {
          requests++;
        }
      });
      final client = _clientFor(server);
      addTearDown(client.close);

      await expectLater(
        client.createProfileNative(name: 'qa', model: 'model-only'),
        throwsA(
          isA<TuiGatewayRpcError>().having(
            (error) => error.method,
            'method',
            'profiles.create',
          ),
        ),
      );
      expect(requests, 0);
    },
  );

  test('AgentProfile conserva el namespace oficial y rechaza pins móviles', () {
    final profile = AgentProfile.fromJson({
      'name': 'infra',
      'ui_meta': {
        'hermes-bots': {
          'chat': 'stored-infra',
          'title': 'Infra',
          'shape': 'cloud',
        },
      },
    });
    final provisional = AgentProfile.fromJson({
      'name': 'infra',
      'ui_meta': {
        'hermes-bots': {'chat': 'mob-bot-infra'},
      },
    });

    expect(profile.botChatSessionId, 'stored-infra');
    expect(profile.botModeUiMeta, {
      'chat': 'stored-infra',
      'title': 'Infra',
      'shape': 'cloud',
    });
    expect(
      () => profile.botModeUiMeta['title'] = 'overwrite',
      throwsUnsupportedError,
    );
    expect(provisional.botChatSessionId, isNull);
  });

  test(
    'materializa, oculta y fija stored id preservando metadata Desktop',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final requests = <Map<String, dynamic>>[];
      var botMeta = <String, dynamic>{
        'title': 'Infra',
        'shape': 'cloud',
        'group': 'Research',
        'color': '#38bdf8',
        'image': 'data:image/png;base64,legacy',
        'pet': {'id': 'legacy-pet'},
      };

      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        await for (final raw in socket) {
          final frame = jsonDecode(raw as String) as Map<String, dynamic>;
          requests.add(frame);
          final method = frame['method'] as String;
          final params = Map<String, dynamic>.from(frame['params'] as Map);
          final Map<String, dynamic> result;
          switch (method) {
            case 'profiles.list':
              result = {
                'profiles': [
                  {
                    'name': 'infra',
                    'ui_meta': {
                      'hermes-bots': Map<String, dynamic>.from(botMeta),
                      'foreign-plugin': {'keep': true},
                    },
                  },
                ],
              };
              break;
            case 'session.title':
              result = {'pending': false, 'title': 'Bot Chat'};
              break;
            case 'session.set_hidden':
              result = {'hidden': true, 'session_key': 'stored-infra'};
              break;
            case 'profiles.configure':
              final uiMeta = Map<String, dynamic>.from(
                params['ui_meta'] as Map,
              );
              botMeta = Map<String, dynamic>.from(uiMeta['hermes-bots'] as Map);
              result = {
                'ok': true,
                'applied': {'ui_meta': true},
              };
              break;
            default:
              throw StateError('Unexpected method $method');
          }
          socket.add(
            jsonEncode({'jsonrpc': '2.0', 'id': frame['id'], 'result': result}),
          );
        }
      });

      final client = _clientFor(server);
      addTearDown(client.close);
      await client.persistCanonicalBotChat(
        profile: 'infra',
        runtimeSessionId: 'runtime-infra',
        storedSessionId: 'stored-infra',
      );

      expect(requests.map((request) => request['method']), [
        'profiles.list',
        'session.title',
        'session.set_hidden',
        'profiles.list',
        'profiles.configure',
        'profiles.list',
      ]);
      expect(requests[1]['params'], {
        'session_id': 'runtime-infra',
        'title': 'Bot Chat',
      });
      expect(requests[2]['params'], {
        'session_id': 'runtime-infra',
        'hidden': true,
      });
      expect(requests[4]['params'], {
        'name': 'infra',
        'ui_meta': {
          'hermes-bots': {
            'title': 'Infra',
            'shape': 'cloud',
            'group': 'Research',
            'color': '#38bdf8',
            'image': 'data:image/png;base64,legacy',
            'pet': {'id': 'legacy-pet'},
            'chat': 'stored-infra',
          },
        },
      });
      expect(
        requests.where((request) => request['method'] == 'session.list'),
        isEmpty,
      );
    },
  );

  test('un pin concurrente bloquea antes de materializar otra fila', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final requests = <Map<String, dynamic>>[];

    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      await for (final raw in socket) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        requests.add(frame);
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': frame['id'],
            'result': {
              'profiles': [
                {
                  'name': 'infra',
                  'ui_meta': {
                    'hermes-bots': {'chat': 'stored-other'},
                  },
                },
              ],
            },
          }),
        );
      }
    });

    final client = _clientFor(server);
    addTearDown(client.close);
    await expectLater(
      client.persistCanonicalBotChat(
        profile: 'infra',
        runtimeSessionId: 'runtime-new',
        storedSessionId: 'stored-new',
      ),
      throwsA(
        isA<TuiGatewayRpcError>()
            .having((error) => error.method, 'method', 'profiles.configure')
            .having(
              (error) => error.message,
              'message',
              'Canonical Bot Chat pin changed concurrently',
            ),
      ),
    );

    expect(requests.map((request) => request['method']), ['profiles.list']);
  });

  test(
    'pins presentes pero malformados bloquean antes de session.title',
    () async {
      for (final invalidBotMeta in <Object?>[
        {'chat': 'mob-bot-infra'},
        {'chat': 42},
        {'chat': 'stored\ncontrol'},
        'corrupt-namespace',
      ]) {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final requests = <Map<String, dynamic>>[];
        server.listen((request) async {
          final socket = await WebSocketTransformer.upgrade(request);
          await for (final raw in socket) {
            final frame = jsonDecode(raw as String) as Map<String, dynamic>;
            requests.add(frame);
            socket.add(
              jsonEncode({
                'jsonrpc': '2.0',
                'id': frame['id'],
                'result': {
                  'profiles': [
                    {
                      'name': 'infra',
                      'ui_meta': {'hermes-bots': invalidBotMeta},
                    },
                  ],
                },
              }),
            );
          }
        });
        final client = _clientFor(server);
        try {
          await expectLater(
            client.persistCanonicalBotChat(
              profile: 'infra',
              runtimeSessionId: 'runtime-new',
              storedSessionId: 'stored-new',
            ),
            throwsA(
              isA<TuiGatewayRpcError>().having(
                (error) => error.message,
                'message',
                'Canonical Bot Chat pin is malformed',
              ),
            ),
          );
          expect(requests.map((request) => request['method']), [
            'profiles.list',
          ]);
        } finally {
          await client.close();
          await server.close(force: true);
        }
      }
    },
  );

  test('revalidar pin oficial bloquea un repin antes del prompt', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final requests = <Map<String, dynamic>>[];
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      await for (final raw in socket) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        requests.add(frame);
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': frame['id'],
            'result': {
              'profiles': [
                {
                  'name': 'infra',
                  'ui_meta': {
                    'hermes-bots': {'chat': 'stored-new'},
                  },
                },
              ],
            },
          }),
        );
      }
    });

    final client = _clientFor(server);
    addTearDown(client.close);
    await expectLater(
      client.assertCanonicalBotChat(
        profile: 'infra',
        storedSessionId: 'stored-old',
      ),
      throwsA(
        isA<TuiGatewayRpcError>().having(
          (error) => error.message,
          'message',
          'Canonical Bot Chat pin changed or was removed',
        ),
      ),
    );
    expect(requests.map((request) => request['method']), ['profiles.list']);
  });

  test('un gateway sin set_hidden aún puede fijar el pin canónico', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final requests = <Map<String, dynamic>>[];
    String? pinned;

    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      await for (final raw in socket) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        requests.add(frame);
        final method = frame['method'] as String;
        if (method == 'session.set_hidden') {
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': frame['id'],
              'error': {'code': -32601, 'message': 'method not found'},
            }),
          );
          continue;
        }
        final Map<String, dynamic> result;
        if (method == 'session.title') {
          result = {'pending': false, 'title': 'Bot Chat'};
        } else if (method == 'profiles.configure') {
          final params = Map<String, dynamic>.from(frame['params'] as Map);
          final uiMeta = Map<String, dynamic>.from(params['ui_meta'] as Map);
          final bots = Map<String, dynamic>.from(uiMeta['hermes-bots'] as Map);
          pinned = bots['chat'] as String?;
          result = {
            'ok': true,
            'applied': {'ui_meta': true},
          };
        } else if (method == 'profiles.list') {
          result = {
            'profiles': [
              {
                'name': 'infra',
                'ui_meta': {
                  'hermes-bots': {'chat': ?pinned},
                },
              },
            ],
          };
        } else {
          throw StateError('Unexpected method $method');
        }
        socket.add(
          jsonEncode({'jsonrpc': '2.0', 'id': frame['id'], 'result': result}),
        );
      }
    });

    final client = _clientFor(server);
    addTearDown(client.close);
    await client.persistCanonicalBotChat(
      profile: 'infra',
      runtimeSessionId: 'runtime-infra',
      storedSessionId: 'stored-infra',
    );

    expect(pinned, 'stored-infra');
    expect(
      requests.where((request) => request['method'] == 'session.set_hidden'),
      hasLength(1),
    );
  });

  test('revalidar pin oficial acepta el pin canónico vigente', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final requests = <Map<String, dynamic>>[];
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      await for (final raw in socket) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        requests.add(frame);
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': frame['id'],
            'result': {
              'profiles': [
                {
                  'name': 'infra',
                  'ui_meta': {
                    'hermes-bots': {'chat': 'stored-infra'},
                  },
                },
              ],
            },
          }),
        );
      }
    });

    final client = _clientFor(server);
    addTearDown(client.close);
    await client.assertCanonicalBotChat(
      profile: 'infra',
      storedSessionId: 'stored-infra',
    );

    expect(requests.map((request) => request['method']), ['profiles.list']);
  });

  test('un pin oficial reseteado a null se materializa de nuevo, incluso sin '
      'set_hidden (-32601)', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final requests = <Map<String, dynamic>>[];
    String? pinned;

    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      await for (final raw in socket) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        requests.add(frame);
        final method = frame['method'] as String;
        if (method == 'session.set_hidden') {
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': frame['id'],
              'error': {'code': -32601, 'message': 'method not found'},
            }),
          );
          continue;
        }
        final Map<String, dynamic> result;
        if (method == 'session.title') {
          result = {'pending': false, 'title': 'Bot Chat'};
        } else if (method == 'profiles.configure') {
          final params = Map<String, dynamic>.from(frame['params'] as Map);
          final uiMeta = Map<String, dynamic>.from(params['ui_meta'] as Map);
          final bots = Map<String, dynamic>.from(uiMeta['hermes-bots'] as Map);
          pinned = bots['chat'] as String?;
          result = {
            'ok': true,
            'applied': {'ui_meta': true},
          };
        } else if (method == 'profiles.list') {
          // Desktop's `chat: null` reset survives the round-trip verbatim
          // until this client publishes the replacement pin.
          result = {
            'profiles': [
              {
                'name': 'codex-qa',
                'ui_meta': {
                  'hermes-bots': {'chat': pinned, 'title': 'QA'},
                },
              },
            ],
          };
        } else {
          throw StateError('Unexpected method $method');
        }
        socket.add(
          jsonEncode({'jsonrpc': '2.0', 'id': frame['id'], 'result': result}),
        );
      }
    });

    final client = _clientFor(server);
    addTearDown(client.close);
    await client.persistCanonicalBotChat(
      profile: 'codex-qa',
      runtimeSessionId: 'runtime-codex-qa',
      storedSessionId: 'stored-codex-qa',
    );

    expect(pinned, 'stored-codex-qa');
    expect(requests.map((request) => request['method']), [
      'profiles.list',
      'session.title',
      'session.set_hidden',
      'profiles.list',
      'profiles.configure',
      'profiles.list',
    ]);
  });
}
