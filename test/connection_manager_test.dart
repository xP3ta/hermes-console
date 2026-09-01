import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_android/core/services/bridge_client.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/session_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('SavedConnection', () {
    test('normalizes bare HTTP gateway hosts with fallback port', () {
      final normalized = SavedConnection.normalizeHostAndPort(
        '192.168.1.50',
        8642,
      );

      expect(normalized.host, '192.168.1.50');
      expect(normalized.port, 8642);
      expect(normalized.useHttps, isFalse);
    });

    test('onDeviceLoopback survives toMap/fromMap roundtrip', () {
      final conn = SavedConnection(
        id: 'a',
        label: 'Hermes local',
        host: '127.0.0.1',
        port: 9119,
        apiKey: 'tok',
        kind: InstanceKind.localhost,
        onDeviceLoopback: true,
      );
      expect(SavedConnection.fromMap(conn.toMap()).onDeviceLoopback, isTrue);
    });

    test(
      'migrates legacy localhost loopback (no flag) to onDeviceLoopback',
      () {
        final map = {
          'id': 'b',
          'label': 'Hermes local',
          'host': '127.0.0.1',
          'port': 9119,
          'kind': 'localhost',
          // sin 'on_device_loopback' (dato anterior al campo)
        };
        expect(SavedConnection.fromMap(map).onDeviceLoopback, isTrue);
      },
    );

    test('does NOT infer onDeviceLoopback for non-loopback instances', () {
      final map = {
        'id': 'c',
        'label': 'remoto',
        'host': '192.168.1.40',
        'port': 8642,
        'kind': 'homelab',
      };
      expect(SavedConnection.fromMap(map).onDeviceLoopback, isFalse);
    });

    test(
      'copyWith preserves onDeviceLoopback and does not rewrite loopback',
      () {
        final conn = SavedConnection(
          id: 'd',
          label: 'local',
          host: '127.0.0.1',
          port: 9119,
          apiKey: 'tok',
          onDeviceLoopback: true,
        );
        expect(conn.copyWith(label: 'otro').onDeviceLoopback, isTrue);
        // El loopback on-device NO se reescribe a 10.0.2.2.
        expect(conn.baseUrl, 'http://127.0.0.1:9119');
        expect(conn.derivedBridgeUrl, 'http://127.0.0.1:9131');
      },
    );

    test('normalizes HTTPS URLs without an explicit port to 443', () {
      final normalized = SavedConnection.normalizeHostAndPort(
        'https://hermes.example.com',
        8642,
      );

      expect(normalized.host, 'hermes.example.com');
      expect(normalized.port, 443);
      expect(normalized.useHttps, isTrue);
    });

    test('normalizes HTTPS URLs with a custom fallback port', () {
      final normalized = SavedConnection.normalizeHostAndPort(
        'https://hermes.example.com',
        8443,
      );

      expect(normalized.host, 'hermes.example.com');
      expect(normalized.port, 8443);
      expect(normalized.useHttps, isTrue);
    });

    test('serializes HTTPS flag and remains backward compatible', () {
      final conn = SavedConnection(
        id: '1',
        label: 'Remote',
        host: 'hermes.example.com',
        port: 443,
        apiKey: 'key',
        useHttps: true,
      );

      expect(SavedConnection.fromMap(conn.toMap()).useHttps, isTrue);
      expect(
        SavedConnection.fromMap({
          'id': '2',
          'label': 'Old',
          'host': '192.168.1.50',
          'port': 8642,
          'api_key': 'key',
        }).useHttps,
        isFalse,
      );
    });

    test('uses dashboard port 9119 for local gateway connections', () {
      final conn = SavedConnection(
        id: '1',
        label: 'Home',
        host: '192.168.1.50',
        port: 8642,
        apiKey: 'key',
      );

      expect(conn.dashboardPort, 9119);
      expect(
        DashboardClient(host: conn.host, port: conn.dashboardPort).baseUrl,
        'http://192.168.1.50:9119',
      );
    });

    test('uses the HTTPS proxy port for dashboard calls over HTTPS', () {
      final conn = SavedConnection(
        id: '1',
        label: 'Remote',
        host: 'hermes.example.com',
        port: 443,
        apiKey: 'key',
        useHttps: true,
      );

      expect(conn.dashboardPort, 443);
      expect(
        DashboardClient(
          host: conn.host,
          port: conn.dashboardPort,
          useHttps: conn.useHttps,
        ).baseUrl,
        'https://hermes.example.com:443',
      );
    });
  });

  group('Session', () {
    test('fromJson captures all standard fields', () {
      final s = Session.fromJson({
        'id': 'mob-123',
        'title': 'Test session',
        'model': 'kimi-k2.6',
        'source': 'mobile',
        'message_count': 5,
        'preview': 'Hello',
        'started_at': 1749476527.848,
        'ended_at': null,
      });

      expect(s.id, 'mob-123');
      expect(s.model, 'kimi-k2.6');
      expect(s.messageCount, 5);
      expect(s.isActive, isTrue);
      expect(s.updatedAt, isNull);
    });

    test('fromJson captures optional updated_at field', () {
      final s = Session.fromJson({
        'id': 'mob-456',
        'title': 'With update ts',
        'model': 'hermes-agent',
        'source': 'mobile',
        'message_count': 2,
        'preview': '',
        'started_at': 1749476000.0,
        'ended_at': null,
        'updated_at': 1749479999.0,
      });

      expect(s.updatedAt, 1749479999.0);
      expect(s.lastActivityAt, 1749479999.0);
    });

    test('lastActivityAt falls back to startedAt when no other timestamps', () {
      final s = Session.fromJson({
        'id': 'mob-789',
        'title': 'Fallback test',
        'model': 'hermes-agent',
        'source': 'mobile',
        'message_count': 0,
        'preview': '',
        'started_at': 1749476000.0,
      });

      expect(s.updatedAt, isNull);
      expect(s.endedAt, isNull);
      expect(s.lastActivityAt, 1749476000.0);
    });

    test('lastActivityAt uses endedAt when it is newer than updatedAt', () {
      final s = Session.fromJson({
        'id': 'mob-ended',
        'title': 'Ended test',
        'model': 'hermes-agent',
        'source': 'mobile',
        'message_count': 3,
        'preview': '',
        'started_at': 1749476000.0,
        'updated_at': 1749477000.0,
        'ended_at': 1749478000.0,
      });

      expect(s.lastActivityAt, 1749478000.0);
    });
  });

  group('ModelInfo', () {
    test('fromJson parses standard OpenAI model object', () {
      final m = ModelInfo.fromJson({
        'id': 'kimi-k2.6',
        'object': 'model',
        'created': 1749400000,
        'owned_by': 'hermes',
      });

      expect(m.id, 'kimi-k2.6');
      expect(m.object, 'model');
      expect(m.created, 1749400000);
      expect(m.ownedBy, 'hermes');
    });

    test('fromJson uses hermes-agent fallback for missing id', () {
      final m = ModelInfo.fromJson({});

      expect(m.id, 'hermes-agent');
    });

    test('fromJson tolerates malformed optional fields', () {
      final m = ModelInfo.fromJson({
        'id': 123,
        'object': 456,
        'created': 'not-a-timestamp',
        'owned_by': {'name': 'hermes'},
      });

      expect(m.id, 'hermes-agent');
      expect(m.object, 'model');
      expect(m.created, isNull);
      expect(m.ownedBy, isNull);
    });

    test('toString returns model id', () {
      const m = ModelInfo(id: 'kimi-k2.6');
      expect(m.toString(), 'kimi-k2.6');
    });
  });

  group('ModelProvider', () {
    test('fromJson parses OAuth provider models returned as objects', () {
      final provider = ModelProvider.fromJson({
        'slug': 'copilot',
        'name': 'GitHub Copilot',
        'authenticated': true,
        'auth_type': 'oauth_device_code',
        'oauth_provider_id': 'copilot',
        'models': [
          {'id': 'gpt-5.4', 'context_length': 128000},
          {'model': 'claude-sonnet-4-6'},
          {'name': 'gemini-3-pro'},
          {'value': 'gpt-5.4'},
          {'id': ''},
        ],
      });

      expect(provider.slug, 'copilot');
      expect(provider.authenticated, isTrue);
      expect(provider.authType, 'oauth_device_code');
      expect(provider.oauthProviderId, 'copilot');
      expect(provider.models, ['gpt-5.4', 'claude-sonnet-4-6', 'gemini-3-pro']);
    });

    test('fromJson accepts alternative model catalog fields', () {
      final provider = ModelProvider.fromJson({
        'id': 'qwen-oauth',
        'label': 'Qwen OAuth',
        'configured': 'true',
        'available_models': [
          'qwen3.5-coder',
          {'slug': 'qwen3.5-plus'},
        ],
      });

      expect(provider.slug, 'qwen-oauth');
      expect(provider.name, 'Qwen OAuth');
      expect(provider.authenticated, isTrue);
      expect(provider.models, ['qwen3.5-coder', 'qwen3.5-plus']);
    });

    test('fromJson parses model maps keyed by id', () {
      final provider = ModelProvider.fromJson({
        'provider': 'google-gemini-cli',
        'title': 'Google Gemini OAuth',
        'available': 1,
        'models': {
          'gemini-3-pro': {'context': 1000000},
          'gemini-3-flash': {'id': 'gemini-3-flash'},
        },
      });

      expect(provider.slug, 'google-gemini-cli');
      expect(provider.name, 'Google Gemini OAuth');
      expect(provider.authenticated, isTrue);
      expect(provider.models, ['gemini-3-pro', 'gemini-3-flash']);
    });
  });

  group('ApiClient', () {
    test('getMessages rechaza un transcript one-shot truncado', () async {
      final client = ApiClient(
        baseUrl: 'http://hermes.local:8642',
        apiKey: 'gateway-key',
        httpClient: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'data': [
                {'id': 'valid-row', 'role': 'user', 'content': 'hola'},
                'invalid-row',
              ],
            }),
            200,
          ),
        ),
      );
      addTearDown(client.close);

      await expectLater(
        client.getMessages('stored-chat'),
        throwsA(isA<FormatException>()),
      );
    });

    test(
      'includeChildren serializa include_children=true solo en Gateway API',
      () async {
        final requests = <http.Request>[];
        final client = ApiClient(
          baseUrl: 'http://hermes.local:8642',
          apiKey: 'gateway-key',
          httpClient: MockClient((request) async {
            requests.add(request);
            return http.Response(
              jsonEncode({
                'data': [
                  {
                    'id': 'root-session',
                    'title': 'Root',
                    'source': 'mobile',
                    'message_count': 1,
                  },
                  {
                    'id': 'child-session',
                    'title': 'Child',
                    'source': 'mobile',
                    'message_count': 1,
                    'parent_session_id': 'root-session',
                  },
                ],
              }),
              200,
            );
          }),
        );
        addTearDown(client.close);

        final sessions = await client.getSessions(includeChildren: true);

        expect(requests, hasLength(1));
        expect(requests.single.url.path, '/api/sessions');
        expect(requests.single.url.queryParameters, {
          'limit': '200',
          'include_children': 'true',
        });
        expect(sessions.map((session) => session.id), [
          'root-session',
          'child-session',
        ]);
      },
    );

    test('getModelInfoList returns fallback on non-200', () async {
      final client = ApiClient(
        baseUrl: 'http://hermes.local:8642',
        apiKey: 'test-key',
        httpClient: MockClient((request) async {
          if (request.url.path == '/v1/models') {
            return http.Response(
              '{"error":{"message":"Invalid API key"}}',
              401,
            );
          }
          return http.Response('not found', 404);
        }),
      );

      final models = await client.getModelInfoList();
      expect(models, hasLength(1));
      expect(models.first.id, 'hermes-agent');
      client.close();
    });

    test('getModelInfoList parses model list from backend', () async {
      final client = ApiClient(
        baseUrl: 'http://hermes.local:8642',
        apiKey: 'valid-key',
        httpClient: MockClient((request) async {
          if (request.url.path == '/v1/models') {
            return http.Response(
              jsonEncode({
                'object': 'list',
                'data': [
                  {'id': 'kimi-k2.6', 'object': 'model', 'owned_by': 'hermes'},
                  {'id': 'gpt-4o', 'object': 'model', 'owned_by': 'openai'},
                ],
              }),
              200,
            );
          }
          return http.Response('not found', 404);
        }),
      );

      final models = await client.getModelInfoList();
      expect(models, hasLength(2));
      expect(models[0].id, 'kimi-k2.6');
      expect(models[1].id, 'gpt-4o');
      client.close();
    });

    test('getModelInfoList returns fallback for empty model list', () async {
      final client = ApiClient(
        baseUrl: 'http://hermes.local:8642',
        apiKey: 'valid-key',
        httpClient: MockClient((request) async {
          return http.Response('{"object":"list","data":[]}', 200);
        }),
      );

      final models = await client.getModelInfoList();
      expect(models, hasLength(1));
      expect(models.first.id, 'hermes-agent');
      client.close();
    });

    test('startRun envía el historial en conversation_history', () async {
      Map<String, dynamic>? body;
      final client = ApiClient(
        baseUrl: 'http://hermes.local:8642',
        apiKey: 'k',
        httpClient: MockClient((request) async {
          body = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(jsonEncode({'run_id': 'run_1'}), 200);
        }),
      );

      final runId = await client.startRun(
        input: '¿cómo me llamo?',
        sessionId: 'sess-1',
        model: 'hermes-agent',
        history: const [
          {'role': 'user', 'content': 'me llamo Zorglub'},
          {'role': 'assistant', 'content': 'Hola Zorglub'},
        ],
      );

      expect(runId, 'run_1');
      // El gateway lee el contexto de `conversation_history` (NO de `messages`).
      expect(body!['conversation_history'], const [
        {'role': 'user', 'content': 'me llamo Zorglub'},
        {'role': 'assistant', 'content': 'Hola Zorglub'},
      ]);
      expect(body!['input'], '¿cómo me llamo?');
      client.close();
    });

    test(
      'startRun inyecta el contexto en input si el gateway rechaza (422)',
      () async {
        final bodies = <Map<String, dynamic>>[];
        final client = ApiClient(
          baseUrl: 'http://hermes.local:8642',
          apiKey: 'k',
          httpClient: MockClient((request) async {
            final b = jsonDecode(request.body) as Map<String, dynamic>;
            bodies.add(b);
            // Gateway estricto: rechaza cualquier cuerpo con campos de historial.
            if (b.containsKey('conversation_history') ||
                b.containsKey('messages')) {
              return http.Response('{"error":"unexpected field"}', 422);
            }
            return http.Response(jsonEncode({'run_id': 'run_2'}), 200);
          }),
        );

        final runId = await client.startRun(
          input: '¿cómo me llamo?',
          sessionId: 'sess-1',
          history: const [
            {'role': 'user', 'content': 'me llamo Zorglub'},
            {'role': 'assistant', 'content': 'Hola Zorglub'},
          ],
        );

        expect(runId, 'run_2');
        // El reintento NO debe perder el contexto: va inyectado en `input`.
        final retry = bodies.last;
        expect(retry.containsKey('conversation_history'), isFalse);
        expect(retry.containsKey('messages'), isFalse);
        expect(retry['input'], contains('me llamo Zorglub'));
        expect(retry['input'], contains('Hola Zorglub'));
        expect(retry['input'], contains('¿cómo me llamo?'));
        client.close();
      },
    );

    test('getModelInfoList returns fallback for malformed JSON', () async {
      final client = ApiClient(
        baseUrl: 'http://hermes.local:8642',
        apiKey: 'valid-key',
        httpClient: MockClient((request) async {
          return http.Response('not json', 200);
        }),
      );

      final models = await client.getModelInfoList();
      expect(models, hasLength(1));
      expect(models.first.id, 'hermes-agent');
      client.close();
    });

    test('getModelInfoList returns fallback on timeout', () async {
      final client = ApiClient(
        baseUrl: 'http://hermes.local:8642',
        apiKey: 'valid-key',
        httpClient: MockClient((request) {
          throw TimeoutException('simulated timeout');
        }),
      );

      final models = await client.getModelInfoList();
      expect(models, hasLength(1));
      expect(models.first.id, 'hermes-agent');
      client.close();
    });

    test('getModels wraps getModelInfoList returning id list', () async {
      final client = ApiClient(
        baseUrl: 'http://hermes.local:8642',
        apiKey: 'valid-key',
        httpClient: MockClient((request) async {
          if (request.url.path == '/v1/models') {
            return http.Response(
              jsonEncode({
                'object': 'list',
                'data': [
                  {'id': 'kimi-k2.6'},
                  {'id': 'gpt-4o'},
                ],
              }),
              200,
            );
          }
          return http.Response('not found', 404);
        }),
      );

      final ids = await client.getModels();
      expect(ids, ['kimi-k2.6', 'gpt-4o']);
      client.close();
    });

    test('healthCheck verifies an authenticated endpoint', () async {
      final client = ApiClient(
        baseUrl: 'http://hermes.local:8642',
        apiKey: 'valid-key',
        httpClient: MockClient((request) async {
          expect(request.headers['authorization'], 'Bearer valid-key');
          if (request.url.path == '/health') {
            return http.Response('{}', 200);
          }
          if (request.url.path == '/api/sessions') {
            return http.Response('{"object":"list","data":[]}', 200);
          }
          return http.Response('not found', 404);
        }),
      );

      expect(await client.healthCheck(), isTrue);
      client.close();
    });

    test('healthCheck rejects invalid API keys', () async {
      final client = ApiClient(
        baseUrl: 'http://hermes.local:8642',
        apiKey: 'bad-key',
        httpClient: MockClient((request) async {
          if (request.url.path == '/health') {
            return http.Response('{}', 200);
          }
          if (request.url.path == '/api/sessions') {
            return http.Response('unauthorized', 401);
          }
          return http.Response('not found', 404);
        }),
      );

      expect(await client.healthCheck(), isFalse);
      client.close();
    });
  });

  group('T039B — capacidades de sesiones separadas por superficie', () {
    test(
      'Dashboard omite include_children y no inventa un árbol ausente',
      () async {
        final dashboardRequests = <http.Request>[];
        final gatewayRequests = <http.Request>[];
        final dashboard = DashboardClient(
          host: '127.0.0.1',
          port: 9119,
          manualToken: 'dashboard-token',
          httpClientOverride: MockClient((request) async {
            dashboardRequests.add(request);
            return http.Response(
              jsonEncode({
                'sessions': [
                  {
                    'id': 'root-only',
                    '_lineage_root_id': 'root-only',
                    'title': 'Root only',
                    'preview': '',
                    'model': 'hermes-agent',
                    'source': 'mobile',
                    'message_count': 1,
                    'started_at': 1000,
                    'last_active': 1001,
                    'archived': false,
                  },
                ],
                'total': 1,
                'limit': 20,
                'offset': 0,
              }),
              200,
            );
          }),
        );
        final gateway = ApiClient(
          baseUrl: 'http://127.0.0.1:8642',
          apiKey: 'gateway-key',
          httpClient: MockClient((request) async {
            gatewayRequests.add(request);
            return http.Response('{}', 500);
          }),
        );
        final repository = SessionRepository(dashboard, gateway);
        addTearDown(() {
          repository.close();
          dashboard.close();
          gateway.close();
        });

        final snapshot = await repository.refresh(
          const SessionLibraryQuery(includeChildren: true, minMessages: 0),
        );

        expect(snapshot.source, SessionLibrarySource.dashboard);
        expect(snapshot.sessions.map((session) => session.id), ['root-only']);
        expect(dashboardRequests, hasLength(1));
        expect(dashboardRequests.single.url.path, '/api/sessions');
        expect(
          dashboardRequests.single.url.queryParameters,
          isNot(contains('include_children')),
        );
        expect(gatewayRequests, isEmpty);
      },
    );
  });

  group('GatewayChatClient', () {
    test('appends latest user message to existing history exactly once', () {
      final messages = GatewayChatClient.buildChatCompletionMessages(
        message: 'new question',
        history: [
          {'role': 'user', 'content': 'old question'},
          {'role': 'assistant', 'content': 'old answer'},
        ],
      );

      expect(messages, [
        {'role': 'user', 'content': 'old question'},
        {'role': 'assistant', 'content': 'old answer'},
        {'role': 'user', 'content': 'new question'},
      ]);
    });

    test(
      'does not duplicate latest user message already present in history',
      () {
        final messages = GatewayChatClient.buildChatCompletionMessages(
          message: 'new question',
          history: [
            {'role': 'user', 'content': 'old question'},
            {'role': 'assistant', 'content': 'old answer'},
            {'role': 'user', 'content': 'new question'},
          ],
        );

        expect(
          messages.where((m) => m['content'] == 'new question'),
          hasLength(1),
        );
        expect(messages.last, {'role': 'user', 'content': 'new question'});
      },
    );

    test('parses normal chat completion SSE token frames', () {
      final token = GatewayChatClient.parseSseFrame(
        'data: {"choices":[{"delta":{"content":"hello"}}]}',
      );

      expect(token, 'hello');
    });

    test('parses Hermes tool progress SSE frames via callback', () {
      Map<String, dynamic>? progress;
      final token = GatewayChatClient.parseSseFrame(
        'event: hermes.tool.progress\n'
        'data: {"tool":"read_file","toolCallId":"call_1","status":"running"}',
        onToolProgress: (p) => progress = p,
      );

      expect(token, isNull);
      expect(progress, isNotNull);
      expect(progress!['tool'], 'read_file');
      expect(progress!['toolCallId'], 'call_1');
      expect(progress!['status'], 'running');
    });
  });

  group('DashboardClient', () {
    test(
      'getSessionMessages rechaza un transcript one-shot truncado',
      () async {
        final client = DashboardClient(
          host: 'hermes.local',
          manualToken: 'test-token',
          httpClientOverride: MockClient(
            (_) async => http.Response(
              jsonEncode({
                'messages': [
                  {'id': 'valid-row', 'role': 'user', 'content': 'hola'},
                  42,
                ],
              }),
              200,
            ),
          ),
        );
        addTearDown(client.close);

        await expectLater(
          client.getSessionMessages('stored-chat'),
          throwsA(isA<FormatException>()),
        );
      },
    );

    test('el refresco manual fuerza una comprobación sin caché', () async {
      final calls = <http.Request>[];
      final client = DashboardClient(
        host: 'hermes.local',
        manualToken: 'test-token',
        httpClientOverride: MockClient((request) async {
          calls.add(request);
          return http.Response(
            jsonEncode({
              'current_version': '0.18.2',
              'behind': 1,
              'update_available': true,
              'can_apply': true,
            }),
            200,
          );
        }),
      );

      await client.checkUpdate();
      await client.checkUpdate(force: true);

      expect(calls, hasLength(2));
      expect(calls.first.url.queryParameters, isEmpty);
      expect(calls.last.url.queryParameters['force'], 'true');
      client.close();
    });

    test('wraps cron job updates for dashboard endpoint', () {
      final updates = {'name': 'Daily', 'no_agent': true};

      expect(DashboardClient.buildCronUpdateBody(updates), {
        'updates': updates,
      });
    });

    test('replica el contrato Desktop para proveedor externo', () async {
      final calls = <http.Request>[];
      final client = DashboardClient(
        host: 'hermes.local',
        manualToken: 'test-token',
        httpClientOverride: MockClient((request) async {
          calls.add(request);
          if (request.url.path == '/api/providers/validate') {
            return http.Response(
              jsonEncode({
                'ok': true,
                'reachable': true,
                'message': '',
                'models': ['edge-model'],
              }),
              200,
            );
          }
          if (request.url.path == '/api/model/set') {
            return http.Response(jsonEncode({'ok': true}), 200);
          }
          return http.Response('not found', 404);
        }),
      );
      addTearDown(client.close);

      final probe = await client.validateExternalProvider(
        baseUrl: 'https://edge.example/v1',
        apiKey: 'provider-secret',
      );
      final applied = await client.setActiveModel(
        providerSlug: 'custom',
        modelId: 'edge-model',
        baseUrl: 'https://edge.example/v1',
        apiKey: 'provider-secret',
      );

      expect(probe['models'], ['edge-model']);
      expect(applied, isTrue);
      expect(calls, hasLength(2));
      expect(calls.first.url.path, '/api/providers/validate');
      expect(jsonDecode(calls.first.body), {
        'key': 'OPENAI_BASE_URL',
        'value': 'https://edge.example/v1',
        'api_key': 'provider-secret',
      });
      expect(calls.last.url.path, '/api/model/set');
      expect(jsonDecode(calls.last.body), {
        'provider': 'custom',
        'model': 'edge-model',
        'scope': 'main',
        'base_url': 'https://edge.example/v1',
        'api_key': 'provider-secret',
      });
      expect(calls.last.body, isNot(contains('"name"')));
      expect(calls.last.body, isNot(contains('"models"')));
    });

    test('usa los endpoints oficiales del TTS de Hermes', () async {
      final calls = <http.Request>[];
      final client = DashboardClient(
        host: 'hermes.local',
        manualToken: 'test-token',
        httpClientOverride: MockClient((request) async {
          calls.add(request);
          if (request.method == 'GET' && request.url.path == '/api/config') {
            return http.Response(
              jsonEncode({
                'config': {
                  'tts': {'provider': 'edge'},
                },
              }),
              200,
            );
          }
          if (request.method == 'POST' &&
              request.url.path == '/api/audio/speak') {
            return http.Response(
              jsonEncode({
                'ok': true,
                'provider': 'edge',
                'data_url': 'data:audio/wav;base64,UklGRg==',
              }),
              200,
            );
          }
          return http.Response('not found', 404);
        }),
      );

      final config = await client.getServerConfig();
      final audio = await client.synthesizeSpeech('Hola');

      expect(
        DashboardClient.audioSpeakRequestTimeout('Hola'),
        const Duration(seconds: 180),
      );
      expect((config['config'] as Map)['tts'], {'provider': 'edge'});
      expect(audio['provider'], 'edge');
      expect(calls, hasLength(2));
      expect(calls.last.headers['x-hermes-session-token'], 'test-token');
      expect(jsonDecode(calls.last.body), {'text': 'Hola'});
      client.close();
    });

    test('propaga el perfil efectivo a todas las rutas de audio', () async {
      final calls = <http.Request>[];
      final client = DashboardClient(
        host: 'hermes.local',
        manualToken: 'test-token',
        httpClientOverride: MockClient((request) async {
          calls.add(request);
          return http.Response('{}', 200);
        }),
      );

      await client.synthesizeSpeech('Hola', profile: 'voice_work');
      await client.transcribeAudio(
        'data:audio/wav;base64,UklGRg==',
        profile: 'voice_work',
      );
      expect(
        await client.probeAudioEndpoint('speak', profile: 'voice_work'),
        200,
      );
      await client.synthesizeSpeech('Default', profile: 'default');

      expect(calls, hasLength(4));
      for (final call in calls.take(3)) {
        expect(call.url.queryParameters['profile'], 'voice_work');
      }
      expect(calls[0].url.path, '/api/audio/speak');
      expect(calls[1].url.path, '/api/audio/transcribe');
      expect(calls[2].url.path, '/api/audio/speak');
      expect(calls.last.url.queryParameters, isEmpty);
      client.close();
    });

    test('escala y limita los timeouts de audio como Hermes Desktop', () {
      expect(
        DashboardClient.audioSpeakRequestTimeout('mensaje corto'),
        const Duration(seconds: 180),
      );
      expect(
        DashboardClient.audioSpeakRequestTimeout('x' * 8000),
        const Duration(seconds: 280),
      );
      expect(
        DashboardClient.audioSpeakRequestTimeout('x' * 100000),
        const Duration(seconds: 600),
      );

      expect(
        DashboardClient.audioTranscribeRequestTimeout(
          'data:audio/webm;base64,AA==',
        ),
        const Duration(seconds: 180),
      );
      expect(
        DashboardClient.audioTranscribeRequestTimeout('x' * 3000000),
        const Duration(seconds: 300),
      );
      expect(
        DashboardClient.audioTranscribeRequestTimeout('x' * 9000000),
        const Duration(seconds: 600),
      );
    });
  });

  group('ConnectionManager._loadApiKeys', () {
    test(
      'preserves explicit homelab adb-reverse gateway on loopback',
      () async {
        const prefsKey = 'saved_connections';
        SharedPreferences.setMockInitialValues({
          prefsKey: [
            jsonEncode({
              'id': 'adb-reverse',
              'label': 'Hermes Mission QA',
              'host': '127.0.0.1',
              'port': 8642,
              'kind': 'homelab',
              'on_device_loopback': true,
              'dashboard_url': 'http://127.0.0.1:9119',
            }),
          ],
        });

        final prefs = await SharedPreferences.getInstance();
        final manager = await ConnectionManager.create(prefs);

        final connection = manager.getConnections().single;
        expect(connection.kind, InstanceKind.homelab);
        expect(connection.port, 8642);
        expect(connection.onDeviceLoopback, isTrue);
        expect(connection.dashboardUrl, 'http://127.0.0.1:9119');
      },
    );

    test('still migrates legacy localhost gateway metadata', () async {
      const prefsKey = 'saved_connections';
      SharedPreferences.setMockInitialValues({
        prefsKey: [
          jsonEncode({
            'id': 'legacy-local',
            'label': 'Hermes local',
            'host': '127.0.0.1',
            'port': 8642,
            'kind': 'localhost',
          }),
        ],
      });

      final prefs = await SharedPreferences.getInstance();
      final manager = await ConnectionManager.create(prefs);

      final connection = manager.getConnections().single;
      expect(connection.kind, InstanceKind.localhost);
      expect(connection.port, 9119);
      expect(connection.dashboardUrl, 'http://127.0.0.1:9119');
    });

    test(
      'mixed legacy+corrupt entries: does not throw, re-saves only the clean valid entry',
      () async {
        const prefsKey = 'saved_connections';

        SharedPreferences.setMockInitialValues({
          prefsKey: [
            jsonEncode({
              'id': 'conn-1',
              'label': 'Home',
              'host': '192.168.1.50',
              'port': 8642,
              'api_key': 'secret',
            }),
            '{NOT_VALID_JSON',
          ],
        });

        final prefs = await SharedPreferences.getInstance();

        // Must not throw despite the corrupt entry
        await ConnectionManager.create(prefs);

        final saved = prefs.getStringList(prefsKey)!;

        // Corrupt entry excluded, valid entry preserved
        expect(saved, hasLength(1));

        final entry = jsonDecode(saved.first) as Map<String, dynamic>;
        expect(entry['id'], 'conn-1');

        // api_key must not appear in the re-saved JSON
        expect(entry.containsKey('api_key'), isFalse);
      },
    );

    test(
      'pruneOrphanData quita restos de instancias borradas y conserva el resto',
      () async {
        SharedPreferences.setMockInitialValues({
          'saved_connections': [
            jsonEncode({
              'id': 'keep',
              'label': 'Viva',
              'host': '192.168.1.50',
              'port': 8642,
            }),
          ],
          // Datos de la conexión viva: deben conservarse.
          'capabilities_keep': '{}',
          'active_profile_keep': 'qa',
          'archived_sessions_keep': <String>['s1'],
          'mission_control.organizations.v1.keep': '[]',
          'mission_control.rooms.v1.keep': '[]',
          'mission_control.bot_chat_pins.v1.keep': '{}',
          'memory_draft::keep::nota': 'texto',
          // Huérfanos de una instancia borrada: deben eliminarse.
          'capabilities_gone': '{}',
          'runs_gone': '[]',
          'approval_rules_gone': '[]',
          'hidden_sessions_gone': <String>['x'],
          'mission_control.organizations.v1.gone': '[]',
          'mission_control.rooms.v1.gone': '[]',
          'mission_control.bot_chat_pins.v1.gone': '{}',
          'memory_draft::gone::vieja': 'basura',
          'memory_draft_ts::gone::vieja': 0,
          // Ajustes globales: nunca se tocan.
          'theme_mode': 'oled',
          'header_title': 'XPetaLab',
        });
        final prefs = await SharedPreferences.getInstance();
        // create() ya ejecuta la poda; comprobamos el efecto.
        final mgr = await ConnectionManager.create(prefs);

        // Huérfanos fuera.
        expect(prefs.containsKey('capabilities_gone'), isFalse);
        expect(prefs.containsKey('runs_gone'), isFalse);
        expect(prefs.containsKey('approval_rules_gone'), isFalse);
        expect(prefs.containsKey('hidden_sessions_gone'), isFalse);
        expect(
          prefs.containsKey('mission_control.organizations.v1.gone'),
          isFalse,
        );
        expect(prefs.containsKey('mission_control.rooms.v1.gone'), isFalse);
        expect(
          prefs.containsKey('mission_control.bot_chat_pins.v1.gone'),
          isFalse,
        );
        expect(prefs.containsKey('memory_draft::gone::vieja'), isFalse);
        expect(prefs.containsKey('memory_draft_ts::gone::vieja'), isFalse);
        // Vivos y globales intactos.
        expect(prefs.containsKey('capabilities_keep'), isTrue);
        expect(prefs.containsKey('active_profile_keep'), isTrue);
        expect(prefs.containsKey('memory_draft::keep::nota'), isTrue);
        expect(
          prefs.containsKey('mission_control.organizations.v1.keep'),
          isTrue,
        );
        expect(prefs.containsKey('mission_control.rooms.v1.keep'), isTrue);
        expect(
          prefs.containsKey('mission_control.bot_chat_pins.v1.keep'),
          isTrue,
        );
        expect(prefs.getString('theme_mode'), 'oled');
        expect(prefs.getString('header_title'), 'XPetaLab');

        // Idempotente: una segunda pasada no quita nada.
        expect(await mgr.pruneOrphanData(), 0);
      },
    );

    test(
      'pruneOrphanData poda las preferencias de mascota con scope connId.profile',
      () async {
        SharedPreferences.setMockInitialValues({
          'saved_connections': [
            jsonEncode({
              'id': 'keep',
              'label': 'Viva',
              'host': '192.168.1.50',
              'port': 8642,
            }),
          ],
          // Scoped a la conexión viva: se conservan.
          'companion.selected_slug.keep.alpha': 'nimbus',
          'companion.enabled.keep.alpha': false,
          // Huérfanas de una instancia borrada: se eliminan.
          'companion.selected_slug.gone.alpha': 'jinx',
          'companion.scale.gone.beta': 'large',
          'companion.size_multiplier.gone.beta': 1.25,
          // Globales (legado y ajustes de app): nunca se tocan.
          'companion.selected_slug': 'boba',
          'companion.enabled': true,
          'companion.presence_level': 'minimal',
          'companion.animation_speed.nimbus': 0.8,
        });
        final prefs = await SharedPreferences.getInstance();
        await ConnectionManager.create(prefs);

        expect(
          prefs.containsKey('companion.selected_slug.gone.alpha'),
          isFalse,
        );
        expect(prefs.containsKey('companion.scale.gone.beta'), isFalse);
        expect(
          prefs.containsKey('companion.size_multiplier.gone.beta'),
          isFalse,
        );
        expect(prefs.containsKey('companion.selected_slug.keep.alpha'), isTrue);
        expect(prefs.getString('companion.selected_slug'), 'boba');
        expect(prefs.getBool('companion.enabled'), isTrue);
        expect(prefs.getString('companion.presence_level'), 'minimal');
        expect(prefs.getDouble('companion.animation_speed.nimbus'), 0.8);
      },
    );
  });

  group('ConnectionManager.findConnectionByEndpoint', () {
    Future<ConnectionManager> manager() async {
      SharedPreferences.setMockInitialValues({
        'saved_connections': [
          jsonEncode({
            'id': 'demo-node',
            'label': 'Server',
            'host': 'Hermes.Example.Test.',
            'port': 443,
            'use_https': true,
          }),
        ],
      });
      final prefs = await SharedPreferences.getInstance();
      return ConnectionManager.create(prefs);
    }

    test('detecta el mismo host normalizado, puerto y transporte', () async {
      final mgr = await manager();

      final match = mgr.findConnectionByEndpoint(
        host: 'hermes.example.test',
        port: 443,
        useHttps: true,
      );

      expect(match?.id, 'demo-node');
    });

    test(
      'no confunde otro puerto o transporte con la misma instancia',
      () async {
        final mgr = await manager();

        expect(
          mgr.findConnectionByEndpoint(
            host: 'hermes.example.test',
            port: 8642,
            useHttps: true,
          ),
          isNull,
        );
        expect(
          mgr.findConnectionByEndpoint(
            host: 'hermes.example.test',
            port: 443,
            useHttps: false,
          ),
          isNull,
        );
      },
    );

    test(
      'permite excluir la propia instancia durante una actualización',
      () async {
        final mgr = await manager();

        expect(
          mgr.findConnectionByEndpoint(
            host: 'hermes.example.test',
            port: 443,
            useHttps: true,
            excludingId: 'demo-node',
          ),
          isNull,
        );
      },
    );
  });

  group('ConnectionManager capability endpoint binding', () {
    const id = 'demo-node';

    Future<({ConnectionManager manager, SharedPreferences prefs})>
    managerWithCapabilities() async {
      SharedPreferences.setMockInitialValues({
        'saved_connections': [
          jsonEncode({
            'id': id,
            'label': 'Server',
            'host': 'hermes.example.test',
            'port': 443,
            'use_https': true,
          }),
        ],
        'capabilities_$id': jsonEncode({
          'turn_idempotency': 'yes',
          'server_sourced': ['turnIdempotency'],
          'checked_at_ms': DateTime.now().millisecondsSinceEpoch,
        }),
      });
      FlutterSecureStorage.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      return (manager: await ConnectionManager.create(prefs), prefs: prefs);
    }

    test('updateConnection invalida capacidades al cambiar el host', () async {
      final fixture = await managerWithCapabilities();

      await fixture.manager.updateConnection(
        id,
        label: 'Server',
        host: 'nuevo.example.test',
        port: 443,
        useHttps: true,
        kind: InstanceKind.vps,
      );

      expect(fixture.prefs.containsKey('capabilities_$id'), isFalse);
    });

    test(
      'upsertConnection invalida ante cualquier cambio de Gateway',
      () async {
        final replacements = <SavedConnection>[
          SavedConnection(
            id: id,
            label: 'Server',
            host: 'nuevo.example.test',
            port: 443,
            apiKey: '',
            useHttps: true,
          ),
          SavedConnection(
            id: id,
            label: 'Server',
            host: 'hermes.example.test',
            port: 8642,
            apiKey: '',
            useHttps: true,
          ),
          SavedConnection(
            id: id,
            label: 'Server',
            host: 'hermes.example.test',
            port: 443,
            apiKey: '',
            useHttps: false,
          ),
        ];

        for (final replacement in replacements) {
          final fixture = await managerWithCapabilities();
          await fixture.manager.upsertConnection(replacement);
          expect(
            fixture.prefs.containsKey('capabilities_$id'),
            isFalse,
            reason:
                '${replacement.host}:${replacement.port} '
                'https=${replacement.useHttps}',
          );
        }
      },
    );

    test('editar solo metadatos conserva capacidades verificadas', () async {
      final fixture = await managerWithCapabilities();

      await fixture.manager.upsertConnection(
        SavedConnection(
          id: id,
          label: 'Server renombrado',
          host: 'hermes.example.test',
          port: 443,
          apiKey: '',
          useHttps: true,
        ),
      );

      expect(fixture.prefs.containsKey('capabilities_$id'), isTrue);
    });

    test(
      'metadata and dashboard secret rotation publish distinct revisions',
      () async {
        final fixture = await managerWithCapabilities();
        final revisions = <int>[];
        fixture.manager.connectionsRevision.addListener(
          () => revisions.add(fixture.manager.connectionsRevision.value),
        );

        await fixture.manager.upsertConnection(
          SavedConnection(
            id: id,
            label: 'Server editado',
            host: 'hermes.example.test',
            port: 443,
            apiKey: '',
            useHttps: true,
          ),
        );
        await fixture.manager.setDashboardSecrets(
          id,
          sessionToken: 'rotated-token',
        );

        expect(revisions, hasLength(2));
        expect(revisions[1], greaterThan(revisions[0]));
      },
    );
  });

  group('ConnectionManager instancia predeterminada', () {
    Future<ConnectionManager> managerWith(List<String> ids) async {
      SharedPreferences.setMockInitialValues({
        'saved_connections': [
          for (final id in ids)
            jsonEncode({
              'id': id,
              'label': id,
              'host': '192.168.1.50',
              'port': 8642,
            }),
        ],
      });
      final prefs = await SharedPreferences.getInstance();
      return ConnectionManager.create(prefs);
    }

    test('setDefaultConnection fija y limpia la predeterminada', () async {
      final mgr = await managerWith(['a', 'b']);
      expect(mgr.defaultConnectionId, isNull);

      await mgr.setDefaultConnection('b');
      expect(mgr.defaultConnectionId, 'b');

      await mgr.setDefaultConnection(null);
      expect(mgr.defaultConnectionId, isNull);
    });

    test('defaultConnectionId ignora un id que ya no existe', () async {
      final mgr = await managerWith(['a']);
      // Predeterminada apuntando a una instancia inexistente (p.ej. borrada):
      // el getter no debe devolver un id muerto.
      await mgr.prefs.setString(ConnectionManager.defaultConnKey, 'ghost');
      expect(mgr.defaultConnectionId, isNull);
    });

    test(
      'applyDefaultOnLaunch siembra la activa con la predeterminada',
      () async {
        final mgr = await managerWith(['a', 'b']);
        // Activa actual = "a" (última usada).
        await mgr.prefs.setString(ConnectionManager.lastConnKey, 'a');
        await mgr.setDefaultConnection('b');

        await mgr.applyDefaultOnLaunch();

        expect(mgr.prefs.getString(ConnectionManager.lastConnKey), 'b');
      },
    );

    test(
      'applyDefaultOnLaunch no toca la activa si no hay predeterminada',
      () async {
        final mgr = await managerWith(['a', 'b']);
        await mgr.prefs.setString(ConnectionManager.lastConnKey, 'a');

        await mgr.applyDefaultOnLaunch();

        expect(mgr.prefs.getString(ConnectionManager.lastConnKey), 'a');
      },
    );
  });

  group('MemoryInfo', () {
    test('fromJson parses active provider and providers list', () {
      final info = MemoryInfo.fromJson({
        'active': 'agentmemory',
        'providers': [
          {
            'name': 'agentmemory',
            'description': 'Persistent cross-session memory.',
            'configured': true,
          },
          {
            'name': 'mem0',
            'description': 'Mem0 server-side memory.',
            'configured': false,
          },
        ],
        'builtin_files': {'memory': 2227, 'user': 1323},
      });

      expect(info.active, 'agentmemory');
      expect(info.providers, hasLength(2));
      expect(info.providers[0].name, 'agentmemory');
      expect(info.providers[0].configured, isTrue);
      expect(info.providers[1].configured, isFalse);
      expect(info.builtinFiles['memory'], 2227);
      expect(info.builtinFiles['user'], 1323);
      expect(info.configuredCount, 1);
    });

    test('activeProvider returns the matching provider', () {
      final info = MemoryInfo.fromJson({
        'active': 'holographic',
        'providers': [
          {
            'name': 'holographic',
            'description': 'Local SQLite.',
            'configured': true,
          },
          {'name': 'mem0', 'description': 'Cloud memory.', 'configured': false},
        ],
        'builtin_files': {},
      });

      expect(info.activeProvider?.name, 'holographic');
    });

    test('fromJson handles missing fields gracefully', () {
      final info = MemoryInfo.fromJson({});

      expect(info.active, '');
      expect(info.providers, isEmpty);
      expect(info.builtinFiles, isEmpty);
      expect(info.activeProvider, isNull);
      expect(info.configuredCount, 0);
    });

    test(
      'fromJson handles null active, empty providers, and missing builtin files',
      () {
        final info = MemoryInfo.fromJson({'active': null, 'providers': []});

        expect(info.active, '');
        expect(info.providers, isEmpty);
        expect(info.builtinFiles, isEmpty);
        expect(info.activeProvider, isNull);
      },
    );

    test('MemoryProvider.fromJson captures all fields', () {
      final p = MemoryProvider.fromJson({
        'name': 'byterover',
        'description': 'ByteRover knowledge tree.',
        'configured': false,
      });

      expect(p.name, 'byterover');
      expect(p.description, 'ByteRover knowledge tree.');
      expect(p.configured, isFalse);
    });
  });

  group('DashboardClient.getModelOptions', () {
    test('parses providers returned as a map keyed by slug', () async {
      final client = DashboardClient(
        host: 'hermes.local',
        port: 9119,
        httpClientOverride: MockClient((request) async {
          if (request.url.path == '/') {
            return http.Response(
              '<script>window.__HERMES_SESSION_TOKEN__="test-token";</script>',
              200,
            );
          }
          if (request.url.path == '/api/model/options') {
            expect(request.headers['x-hermes-session-token'], 'test-token');
            return http.Response(
              jsonEncode({
                'providers': {
                  'copilot': {
                    'name': 'GitHub Copilot',
                    'authenticated': true,
                    'models': [
                      {'id': 'gpt-5.4'},
                    ],
                  },
                },
              }),
              200,
            );
          }
          return http.Response('not found', 404);
        }),
      );

      final providers = await client.getModelOptions();
      expect(providers, hasLength(1));
      expect(providers.first.slug, 'copilot');
      expect(providers.first.models, ['gpt-5.4']);
      client.close();
    });
  });

  group('DashboardClient.deleteCronJob', () {
    test(
      'confirma global aunque el perfil responda éxito idempotente',
      () async {
        final calls = <Uri>[];
        final client = DashboardClient(
          host: 'hermes.local',
          port: 9119,
          manualToken: 'test-token',
          httpClientOverride: MockClient((request) async {
            calls.add(request.url);
            expect(request.method, 'DELETE');
            if (request.url.queryParameters['profile'] == 'wrong-profile') {
              return http.Response('', 204);
            }
            return http.Response('', 204);
          }),
        );

        await client.deleteCronJob('job-qa', profile: 'wrong-profile');

        expect(calls, hasLength(2));
        expect(calls.first.path, '/api/cron/jobs/job-qa');
        expect(calls.first.queryParameters['profile'], 'wrong-profile');
        expect(calls.last.path, '/api/cron/jobs/job-qa');
        expect(calls.last.queryParameters, isEmpty);
        client.close();
      },
    );

    test('404 también global es éxito idempotente', () async {
      var calls = 0;
      final client = DashboardClient(
        host: 'hermes.local',
        port: 9119,
        manualToken: 'test-token',
        httpClientOverride: MockClient((_) async {
          calls++;
          return http.Response('already gone', 404);
        }),
      );

      await client.deleteCronJob('job-gone', profile: 'old-profile');

      expect(calls, 2);
      client.close();
    });

    test('deleted=false se expone como rechazo tipado', () async {
      var calls = 0;
      final client = DashboardClient(
        host: 'hermes.local',
        port: 9119,
        manualToken: 'test-token',
        httpClientOverride: MockClient((request) async {
          calls++;
          expect(request.method, 'DELETE');
          return http.Response(jsonEncode({'deleted': false}), 200);
        }),
      );

      await expectLater(
        client.deleteCronJob('demo-daily-summary'),
        throwsA(isA<CronDeleteRejectedException>()),
      );

      expect(calls, 1);
      client.close();
    });

    test('rechaza todos los IDs hostiles antes de hacer red', () async {
      var calls = 0;
      final client = DashboardClient(
        host: 'hermes.local',
        port: 9119,
        manualToken: 'test-token',
        httpClientOverride: MockClient((_) async {
          calls++;
          return http.Response('', 204);
        }),
      );

      for (final id in [
        '',
        '../job',
        'job/name',
        'job?profile=x',
        'job#fragment',
        'a' * 129,
      ]) {
        await expectLater(client.deleteCronJob(id), throwsArgumentError);
      }

      expect(calls, 0);
      client.close();
    });

    test('la ruta usa la normalización central y Uri.encodeComponent', () {
      final source = File(
        'lib/core/services/connection_manager.dart',
      ).readAsStringSync();

      expect(source, contains('validateCronJobId(jobId)'));
      expect(source, contains('Uri.encodeComponent(id)'));
    });
  });

  group('ConnectionManager.deleteLinkedCronJob', () {
    final connection = SavedConnection(
      id: 'cron-conn',
      label: 'Cron test',
      host: '127.0.0.1',
      port: 8642,
      apiKey: 'gateway-key',
      onDeviceLoopback: true,
    );

    Future<ConnectionManager> createManager({
      Map<String, String> secureValues = const {},
      required BridgeClientFactory bridgeClientFactory,
      required BridgeProvisioner bridgeProvisioner,
      required DashboardClientFactory dashboardClientFactory,
    }) async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues(secureValues);
      final prefs = await SharedPreferences.getInstance();
      return ConnectionManager.create(
        prefs,
        bridgeClientFactory: bridgeClientFactory,
        bridgeProvisioner: bridgeProvisioner,
        dashboardClientFactory: dashboardClientFactory,
      );
    }

    test('ID hostil no alcanza provisión, Bridge ni Dashboard', () async {
      var bridgeClients = 0;
      var provisions = 0;
      var dashboards = 0;
      final manager = await createManager(
        bridgeClientFactory: ({required baseUrl, required token}) {
          bridgeClients++;
          return BridgeClient(baseUrl: baseUrl, token: token);
        },
        bridgeProvisioner: (baseUrl, gatewayKey) async {
          provisions++;
          return 'unexpected';
        },
        dashboardClientFactory: (connection) {
          dashboards++;
          return DashboardClient.lazy(connection);
        },
      );

      await expectLater(
        manager.deleteLinkedCronJob(connection, '../job'),
        throwsArgumentError,
      );

      expect(bridgeClients, 0);
      expect(provisions, 0);
      expect(dashboards, 0);
    });

    test('sin token usa Dashboard sin intentar provisionar Bridge', () async {
      var bridgeClients = 0;
      var provisions = 0;
      var dashboardCalls = 0;
      final manager = await createManager(
        bridgeClientFactory: ({required baseUrl, required token}) {
          bridgeClients++;
          return BridgeClient(baseUrl: baseUrl, token: token);
        },
        bridgeProvisioner: (baseUrl, gatewayKey) async {
          provisions++;
          return 'unexpected-token';
        },
        dashboardClientFactory: (connection) => DashboardClient(
          host: 'hermes.local',
          port: 9119,
          manualToken: 'dashboard-token',
          httpClientOverride: MockClient((request) async {
            dashboardCalls++;
            return http.Response('', 204);
          }),
        ),
      );

      await manager.deleteLinkedCronJob(connection, 'job-dashboard');

      expect(dashboardCalls, 1);
      expect(provisions, 0);
      expect(bridgeClients, 0);
    });

    test(
      'deleted=false del Dashboard no intenta provisionar ni fingir éxito',
      () async {
        var bridgeClients = 0;
        var provisions = 0;
        final manager = await createManager(
          bridgeClientFactory: ({required baseUrl, required token}) {
            bridgeClients++;
            return BridgeClient(baseUrl: baseUrl, token: token);
          },
          bridgeProvisioner: (baseUrl, gatewayKey) async {
            provisions++;
            return 'unexpected-token';
          },
          dashboardClientFactory: (connection) => DashboardClient(
            host: 'hermes.local',
            port: 9119,
            manualToken: 'dashboard-token',
            httpClientOverride: MockClient(
              (_) async => http.Response(jsonEncode({'deleted': false}), 200),
            ),
          ),
        );

        await expectLater(
          manager.deleteLinkedCronJob(connection, 'demo-daily-summary'),
          throwsA(isA<CronDeleteRejectedException>()),
        );

        expect(provisions, 0);
        expect(bridgeClients, 0);
      },
    );

    test(
      'sin token provisiona una sola vez solo después de fallar Dashboard',
      () async {
        final order = <String>[];
        final manager = await createManager(
          bridgeClientFactory: ({required baseUrl, required token}) =>
              BridgeClient(
                baseUrl: baseUrl,
                token: token,
                httpClient: MockClient((request) async {
                  if (request.url.path == '/bridge/health') {
                    return http.Response(jsonEncode({'status': 'ok'}), 200);
                  }
                  if (request.url.path == '/bridge/capabilities') {
                    return http.Response(
                      jsonEncode({
                        'operations': {'cron_delete': true},
                      }),
                      200,
                    );
                  }
                  if (request.method == 'DELETE') {
                    order.add('bridge_delete');
                  }
                  return http.Response(jsonEncode({'ok': true}), 200);
                }),
              ),
          bridgeProvisioner: (baseUrl, gatewayKey) async {
            order.add('provision');
            return 'fresh-token';
          },
          dashboardClientFactory: (connection) => DashboardClient(
            host: 'hermes.local',
            port: 9119,
            manualToken: 'dashboard-token',
            httpClientOverride: MockClient((_) async {
              order.add('dashboard');
              throw const SocketException('dashboard offline');
            }),
          ),
        );

        await manager.deleteLinkedCronJob(connection, 'job-fallback');

        expect(order, ['dashboard', 'provision', 'bridge_delete']);
      },
    );

    test(
      'cron_delete=false evita DELETE y reprovisión antes del fallback',
      () async {
        var bridgeDeletes = 0;
        var provisions = 0;
        final dashboardCalls = <Uri>[];
        final manager = await createManager(
          secureValues: {'bridge_token_cron-conn': 'stored-token'},
          bridgeClientFactory: ({required baseUrl, required token}) =>
              BridgeClient(
                baseUrl: baseUrl,
                token: token,
                httpClient: MockClient((request) async {
                  if (request.url.path == '/bridge/health') {
                    return http.Response(jsonEncode({'status': 'ok'}), 200);
                  }
                  if (request.url.path == '/bridge/capabilities') {
                    return http.Response(
                      jsonEncode({
                        'operations': {'cron_delete': false},
                      }),
                      200,
                    );
                  }
                  if (request.method == 'DELETE') bridgeDeletes++;
                  return http.Response(jsonEncode({'ok': true}), 200);
                }),
              ),
          bridgeProvisioner: (baseUrl, gatewayKey) async {
            provisions++;
            return null;
          },
          dashboardClientFactory: (connection) => DashboardClient(
            host: 'hermes.local',
            port: 9119,
            manualToken: 'dashboard-token',
            httpClientOverride: MockClient((request) async {
              dashboardCalls.add(request.url);
              return http.Response('', 204);
            }),
          ),
        );

        await manager.deleteLinkedCronJob(
          connection,
          'job-1',
          profile: 'work_bot',
        );

        expect(bridgeDeletes, 0);
        expect(provisions, 0);
        expect(dashboardCalls, hasLength(2));
      },
    );

    test(
      'cron_delete=true propaga perfil al Bridge y no usa Dashboard',
      () async {
        final bridgeCalls = <http.Request>[];
        var dashboards = 0;
        final manager = await createManager(
          secureValues: {'bridge_token_cron-conn': 'stored-token'},
          bridgeClientFactory: ({required baseUrl, required token}) =>
              BridgeClient(
                baseUrl: baseUrl,
                token: token,
                httpClient: MockClient((request) async {
                  bridgeCalls.add(request);
                  if (request.url.path == '/bridge/health') {
                    return http.Response(jsonEncode({'status': 'ok'}), 200);
                  }
                  if (request.url.path == '/bridge/capabilities') {
                    return http.Response(
                      jsonEncode({
                        'operations': {'cron_delete': true},
                      }),
                      200,
                    );
                  }
                  return http.Response(jsonEncode({'ok': true}), 200);
                }),
              ),
          bridgeProvisioner: (baseUrl, gatewayKey) async => null,
          dashboardClientFactory: (connection) {
            dashboards++;
            return DashboardClient.lazy(connection);
          },
        );

        await manager.deleteLinkedCronJob(
          connection,
          'job-1',
          profile: 'work_bot',
        );

        final deletion = bridgeCalls.singleWhere(
          (request) => request.method == 'DELETE',
        );
        expect(deletion.url.queryParameters, {'profile': 'work_bot'});
        expect(dashboards, 0);
      },
    );
  });

  group('DashboardClient.applyUpdate', () {
    test('confirma una respuesta HTTP exitosa', () async {
      final client = DashboardClient(
        host: 'hermes.local',
        port: 9119,
        manualToken: 'test-token',
        httpClientOverride: MockClient((request) async {
          expect(request.method, 'POST');
          expect(request.url.path, '/api/hermes/update');
          return http.Response('{"ok":true}', 200);
        }),
      );

      final result = await client.applyUpdate();

      expect(result.responseConfirmed, isTrue);
      client.close();
    });

    test(
      'un timeout tras el POST queda pendiente de confirmar por status',
      () async {
        final client = DashboardClient(
          host: 'hermes.local',
          port: 9119,
          manualToken: 'test-token',
          httpClientOverride: MockClient((_) async {
            await Future<void>.delayed(const Duration(milliseconds: 50));
            return http.Response('{"ok":true}', 200);
          }),
        );

        final result = await client.applyUpdate(
          timeout: const Duration(milliseconds: 1),
        );

        expect(result.responseConfirmed, isFalse);
        client.close();
      },
    );

    test(
      'un cierre de socket tras el POST tampoco se trata como rechazo',
      () async {
        final client = DashboardClient(
          host: 'hermes.local',
          port: 9119,
          manualToken: 'test-token',
          httpClientOverride: MockClient((_) async {
            throw const SocketException('dashboard restarting');
          }),
        );

        final result = await client.applyUpdate();

        expect(result.responseConfirmed, isFalse);
        client.close();
      },
    );
  });

  group('DashboardClient password-login (cookie session)', () {
    test(
      'logs in via /auth/password-login and uses the session cookie',
      () async {
        var loginCalls = 0;
        final client = DashboardClient(
          host: 'hermes.local',
          port: 9119,
          basicUser: 'admin',
          basicPass: 's3cret',
          httpClientOverride: MockClient((request) async {
            if (request.url.path == '/auth/password-login') {
              loginCalls++;
              final body = jsonDecode(request.body) as Map<String, dynamic>;
              expect(body['provider'], 'basic');
              expect(body['username'], 'admin');
              expect(body['password'], 's3cret');
              return http.Response(
                jsonEncode({'ok': true, 'next': '/'}),
                200,
                headers: {
                  'set-cookie':
                      'hermes_session_at=AT1; Path=/; HttpOnly; SameSite=Lax, '
                      'hermes_session_rt=RT1; Path=/; HttpOnly; SameSite=Lax, '
                      'hermes_session_provider=basic; Path=/; HttpOnly; SameSite=Lax',
                },
              );
            }
            if (request.url.path == '/api/model/options') {
              // Sin la cookie de sesión, el Dashboard rechaza la ruta /api/.
              final cookie = request.headers['cookie'] ?? '';
              if (!cookie.contains('hermes_session_at=AT1') ||
                  !cookie.contains('hermes_session_rt=RT1') ||
                  !cookie.contains('hermes_session_provider=basic')) {
                return http.Response(
                  jsonEncode({
                    'error': 'unauthenticated',
                    'reason': 'no_cookie',
                  }),
                  401,
                );
              }
              return http.Response(
                jsonEncode({
                  'providers': {
                    'openai-codex': {
                      'name': 'OpenAI Codex',
                      'authenticated': true,
                      'models': [
                        {'id': 'gpt-5.5'},
                      ],
                    },
                  },
                }),
                200,
              );
            }
            return http.Response('not found', 404);
          }),
        );

        final providers = await client.getModelOptions();
        expect(loginCalls, 1, reason: 'debe autenticarse una sola vez');
        expect(providers.single.slug, 'openai-codex');
        expect(providers.single.models, ['gpt-5.5']);
        client.close();
      },
    );

    test('shares one password login between concurrent consumers', () async {
      var loginCalls = 0;
      final loginStarted = Completer<void>();
      final releaseLogin = Completer<void>();
      final client = DashboardClient(
        host: 'hermes.local',
        port: 9119,
        basicUser: 'admin',
        basicPass: 's3cret',
        httpClientOverride: MockClient((request) async {
          if (request.url.path == '/auth/password-login') {
            loginCalls++;
            if (!loginStarted.isCompleted) loginStarted.complete();
            await releaseLogin.future;
            return http.Response(
              '{"ok":true}',
              200,
              headers: {'set-cookie': 'hermes_session_at=AT_SHARED'},
            );
          }
          expect(request.headers['cookie'], contains('AT_SHARED'));
          if (request.url.path == '/api/model/info') {
            return http.Response('{"model":"gpt","provider":"test"}', 200);
          }
          if (request.url.path == '/api/model/options') {
            return http.Response('{"providers":{}}', 200);
          }
          return http.Response('not found', 404);
        }),
      );

      final infoFuture = client.getModelInfo();
      final optionsFuture = client.getModelOptions();
      await loginStarted.future;
      expect(loginCalls, 1);
      releaseLogin.complete();

      await Future.wait([infoFuture, optionsFuture]);
      expect(loginCalls, 1);
      client.close();
    });

    test(
      'shares a simultaneous login across DashboardClient instances',
      () async {
        var loginCalls = 0;
        final loginStarted = Completer<void>();
        final releaseLogin = Completer<void>();
        MockClient backend() => MockClient((request) async {
          if (request.url.path == '/auth/password-login') {
            loginCalls++;
            if (!loginStarted.isCompleted) loginStarted.complete();
            await releaseLogin.future;
            return http.Response(
              '{"ok":true}',
              200,
              headers: {'set-cookie': 'hermes_session_at=AT_CROSS_CLIENT'},
            );
          }
          expect(request.headers['cookie'], contains('AT_CROSS_CLIENT'));
          return http.Response('{"model":"gpt","provider":"test"}', 200);
        });

        final first = DashboardClient(
          host: 'shared-login.local',
          basicUser: 'admin',
          basicPass: 'secret',
          httpClientOverride: backend(),
        );
        final second = DashboardClient(
          host: 'shared-login.local',
          basicUser: 'admin',
          basicPass: 'secret',
          httpClientOverride: backend(),
        );

        final firstRequest = first.getModelInfo();
        final secondRequest = second.getModelInfo();
        await loginStarted.future;
        expect(loginCalls, 1);
        releaseLogin.complete();
        await Future.wait([firstRequest, secondRequest]);
        expect(loginCalls, 1);
        first.close();
        second.close();
      },
    );

    test('reauthenticates on 401 and ingests rotated cookies', () async {
      var loginCalls = 0;
      final client = DashboardClient(
        host: 'hermes.local',
        port: 9119,
        basicUser: 'admin',
        basicPass: 's3cret',
        httpClientOverride: MockClient((request) async {
          if (request.url.path == '/auth/password-login') {
            loginCalls++;
            // 1er login emite AT1 (que "caduca"); el re-login emite AT2.
            final at = loginCalls == 1 ? 'AT1' : 'AT2';
            return http.Response(
              jsonEncode({'ok': true}),
              200,
              headers: {'set-cookie': 'hermes_session_at=$at'},
            );
          }
          if (request.url.path == '/api/model/info') {
            final cookie = request.headers['cookie'] ?? '';
            // La primera cookie (AT1) caducó → 401 una vez, luego re-login → AT2.
            if (!cookie.contains('hermes_session_at=AT2')) {
              return http.Response(
                jsonEncode({'error': 'unauthenticated'}),
                401,
              );
            }
            return http.Response(
              jsonEncode({'model': 'gpt-5.5', 'provider': 'openai-codex'}),
              200,
            );
          }
          return http.Response('not found', 404);
        }),
      );

      final info = await client.getModelInfo();
      expect(info.model, 'gpt-5.5');
      expect(
        loginCalls,
        2,
        reason: 'login inicial + re-login tras 401 con cookie caducada',
      );
      client.close();
    });

    test(
      'falls back to legacy token scrape when login endpoint is 404',
      () async {
        final client = DashboardClient(
          host: 'hermes.local',
          port: 9119,
          basicUser: 'admin',
          basicPass: 's3cret',
          httpClientOverride: MockClient((request) async {
            if (request.url.path == '/auth/password-login') {
              return http.Response('not found', 404);
            }
            if (request.url.path == '/') {
              return http.Response(
                '<script>window.__HERMES_SESSION_TOKEN__="legacy-tok";</script>',
                200,
              );
            }
            if (request.url.path == '/api/model/options') {
              expect(request.headers['x-hermes-session-token'], 'legacy-tok');
              return http.Response(jsonEncode({'providers': {}}), 200);
            }
            return http.Response('not found', 404);
          }),
        );

        final providers = await client.getModelOptions();
        expect(providers, isEmpty);
        client.close();
      },
    );
  });

  group('DashboardClient.getMemoryInfo', () {
    test('parses memory info from dashboard endpoint', () async {
      final client = DashboardClient(
        host: 'hermes.local',
        port: 9119,
        httpClientOverride: MockClient((request) async {
          if (request.url.path == '/') {
            return http.Response(
              '<script>window.__HERMES_SESSION_TOKEN__="test-token";</script>',
              200,
            );
          }
          if (request.url.path == '/api/memory') {
            expect(request.headers['x-hermes-session-token'], 'test-token');
            return http.Response(
              jsonEncode({
                'active': 'agentmemory',
                'providers': [
                  {
                    'name': 'agentmemory',
                    'description': 'Desc.',
                    'configured': true,
                  },
                ],
                'builtin_files': {'memory': 1000},
              }),
              200,
            );
          }
          return http.Response('not found', 404);
        }),
      );

      final info = await client.getMemoryInfo();
      expect(info.active, 'agentmemory');
      expect(info.providers, hasLength(1));
      expect(info.builtinFiles['memory'], 1000);
      client.close();
    });

    test('retries once on 401 by refreshing the session token', () async {
      var rootFetchCount = 0;
      final client = DashboardClient(
        host: 'hermes.local',
        port: 9119,
        httpClientOverride: MockClient((request) async {
          if (request.url.path == '/') {
            rootFetchCount++;
            final token = rootFetchCount == 1 ? 'stale-token' : 'fresh-token';
            return http.Response(
              '<script>window.__HERMES_SESSION_TOKEN__="$token";</script>',
              200,
            );
          }
          if (request.url.path == '/api/memory') {
            if (request.headers['x-hermes-session-token'] != 'fresh-token') {
              return http.Response('{"detail":"Unauthorized"}', 401);
            }
            return http.Response(
              jsonEncode({
                'active': 'holographic',
                'providers': [],
                'builtin_files': {},
              }),
              200,
            );
          }
          return http.Response('not found', 404);
        }),
      );

      final info = await client.getMemoryInfo();
      expect(info.active, 'holographic');
      expect(rootFetchCount, 2);
      client.close();
    });

    test('times out when the memory endpoint does not answer', () async {
      final client = DashboardClient(
        host: 'hermes.local',
        port: 9119,
        httpClientOverride: MockClient((request) async {
          if (request.url.path == '/') {
            return http.Response(
              '<script>window.__HERMES_SESSION_TOKEN__="test-token";</script>',
              200,
            );
          }
          if (request.url.path == '/api/memory') {
            await Future<void>.delayed(const Duration(seconds: 11));
            return http.Response('{}', 200);
          }
          return http.Response('not found', 404);
        }),
      );

      await expectLater(
        client.getMemoryInfo(),
        throwsA(isA<TimeoutException>()),
      );
      client.close();
    });
  });

  // =========================================================================
  // TASK-019b: LocalChatMode
  // =========================================================================
  group('LocalChatMode (TASK-019b)', () {
    SavedConnection baseConn({LocalChatMode mode = LocalChatMode.auto}) =>
        SavedConnection(
          id: 'test-local',
          label: 'Local',
          host: '127.0.0.1',
          port: 8642,
          apiKey: 'tok',
          onDeviceLoopback: true,
          kind: InstanceKind.localhost,
          localChatMode: mode,
        );

    test('default es auto', () {
      final conn = SavedConnection(
        id: 'x',
        label: 'x',
        host: '127.0.0.1',
        port: 8642,
        apiKey: 'k',
      );
      expect(conn.localChatMode, LocalChatMode.auto);
    });

    test('localChatMode survives toMap/fromMap roundtrip (auto)', () {
      final conn = baseConn(mode: LocalChatMode.auto);
      final roundtrip = SavedConnection.fromMap(conn.toMap());
      expect(roundtrip.localChatMode, LocalChatMode.auto);
    });

    test('localChatMode survives toMap/fromMap roundtrip (simple)', () {
      final conn = baseConn(mode: LocalChatMode.simple);
      final roundtrip = SavedConnection.fromMap(conn.toMap());
      expect(roundtrip.localChatMode, LocalChatMode.simple);
    });

    test('localChatMode survives toMap/fromMap roundtrip (agent)', () {
      final conn = baseConn(mode: LocalChatMode.agent);
      final roundtrip = SavedConnection.fromMap(conn.toMap());
      expect(roundtrip.localChatMode, LocalChatMode.agent);
    });

    test('fromMap sin clave local_chat_mode migra a auto', () {
      final map = baseConn().toMap()..remove('local_chat_mode');
      expect(SavedConnection.fromMap(map).localChatMode, LocalChatMode.auto);
    });

    test('copyWith conserva localChatMode si no se pasa', () {
      final conn = baseConn(mode: LocalChatMode.simple);
      expect(conn.copyWith(label: 'Otro').localChatMode, LocalChatMode.simple);
    });

    test('copyWith puede cambiar localChatMode', () {
      final conn = baseConn(mode: LocalChatMode.simple);
      expect(
        conn.copyWith(localChatMode: LocalChatMode.agent).localChatMode,
        LocalChatMode.agent,
      );
    });

    test('storageKey de cada modo', () {
      expect(LocalChatMode.auto.storageKey, 'auto');
      expect(LocalChatMode.simple.storageKey, 'simple');
      expect(LocalChatMode.agent.storageKey, 'agent');
    });

    test('fromStorage con valor desconocido cae a auto', () {
      expect(LocalChatMode.fromStorage('desconocido'), LocalChatMode.auto);
    });

    test('fromStorage null cae a auto', () {
      expect(LocalChatMode.fromStorage(null), LocalChatMode.auto);
    });
  });
}
