import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/kanban_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  SavedConnection connection({bool readOnly = false}) => SavedConnection(
    id: 'kanban-020',
    label: 'QA',
    host: 'hermes.local',
    port: 8642,
    apiKey: 'gateway-key',
    useHttps: true,
    readOnly: readOnly,
  );

  test('detalle, comentario y log usan rutas oficiales 0.20', () async {
    final requests = <http.Request>[];
    final dashboard = DashboardClient(
      host: 'hermes.local',
      manualToken: 'session-token',
      httpClientOverride: MockClient((request) async {
        requests.add(request);
        switch ((request.method, request.url.path)) {
          case ('GET', '/api/plugins/kanban/tasks/t%2F020'):
            return http.Response(
              jsonEncode({
                'task': {
                  'id': 't/020',
                  'title': 'Detalle',
                  'status': 'running',
                },
                'comments': [
                  {'id': 1, 'body': 'Hola'},
                ],
                'runs': [
                  {'id': 41, 'task_id': 't/020', 'status': 'running'},
                ],
              }),
              200,
            );
          case ('POST', '/api/plugins/kanban/tasks/t%2F020/comments'):
            return http.Response('{"ok":true}', 200);
          case ('GET', '/api/plugins/kanban/tasks/t%2F020/log'):
            return http.Response(
              jsonEncode({
                'task_id': 't/020',
                'exists': true,
                'size_bytes': 12,
                'content': 'hello',
                'truncated': false,
              }),
              200,
            );
          default:
            return http.Response('{}', 404);
        }
      }),
    );
    final client = KanbanClient(connection(), dashboardClient: dashboard);
    addTearDown(client.close);

    final detail = await client.getTaskDetail('t/020', board: 'project');
    await client.addComment('t/020', '  Nueva pista  ', board: 'project');
    final log = await client.getTaskLog(
      't/020',
      tailBytes: 65536,
      board: 'project',
    );

    expect(detail.comments.single.body, 'Hola');
    expect(detail.runs.single.id, 41);
    expect(log.content, 'hello');

    final detailRequest = requests[0];
    expect(detailRequest.url.queryParameters, {'board': 'project'});
    final commentRequest = requests[1];
    expect(jsonDecode(commentRequest.body), {'body': 'Nueva pista'});
    expect(commentRequest.url.queryParameters, {'board': 'project'});
    final logRequest = requests[2];
    expect(logRequest.url.queryParameters, {
      'tail': '65536',
      'board': 'project',
    });
  });

  test('recovery y runs no reintentan ni disfrazan mutaciones', () async {
    final requests = <http.Request>[];
    final dashboard = DashboardClient(
      host: 'hermes.local',
      manualToken: 'session-token',
      httpClientOverride: MockClient((request) async {
        requests.add(request);
        switch ((request.method, request.url.path)) {
          case ('GET', '/api/plugins/kanban/runs/41'):
            return http.Response(
              '{"run":{"id":41,"task_id":"t1","status":"running"}}',
              200,
            );
          case ('GET', '/api/plugins/kanban/runs/41/inspect'):
            return http.Response('{"run_id":41,"alive":true,"pid":999}', 200);
          case ('POST', '/api/plugins/kanban/runs/41/terminate'):
          case ('POST', '/api/plugins/kanban/tasks/t1/reclaim'):
          case ('POST', '/api/plugins/kanban/tasks/t1/reassign'):
          case ('POST', '/api/plugins/kanban/tasks/t1/specify'):
            return http.Response('{"ok":true}', 200);
          default:
            return http.Response('{}', 404);
        }
      }),
    );
    final client = KanbanClient(connection(), dashboardClient: dashboard);
    addTearDown(client.close);

    expect((await client.getRun(41, board: 'project')).id, 41);
    expect((await client.inspectRun(41, board: 'project')).alive, isTrue);
    await client.terminateRun(41, reason: 'Atascado', board: 'project');
    await client.reclaimTask('t1', reason: 'Recuperación', board: 'project');
    await client.reassignTask(
      't1',
      profile: 'nous',
      reclaimFirst: true,
      reason: 'Reintentar',
      board: 'project',
    );
    final specified = await client.specifyTask(
      't1',
      author: 'mobile',
      board: 'project',
    );
    expect(specified.ok, isTrue);

    expect(jsonDecode(requests[2].body), {'reason': 'Atascado'});
    expect(jsonDecode(requests[3].body), {'reason': 'Recuperación'});
    expect(jsonDecode(requests[4].body), {
      'profile': 'nous',
      'reclaim_first': true,
      'reason': 'Reintentar',
    });
    expect(jsonDecode(requests[5].body), {'author': 'mobile'});
    expect(
      requests.every(
        (request) => request.url.queryParameters['board'] == 'project',
      ),
      isTrue,
    );
  });

  test('comentario vacío falla antes de tocar la red', () async {
    var calls = 0;
    final dashboard = DashboardClient(
      host: 'hermes.local',
      manualToken: 'session-token',
      httpClientOverride: MockClient((request) async {
        calls++;
        return http.Response('{}', 200);
      }),
    );
    final client = KanbanClient(connection(), dashboardClient: dashboard);
    addTearDown(client.close);

    await expectLater(
      client.addComment('t1', '   '),
      throwsA(isA<ArgumentError>()),
    );
    expect(calls, 0);
  });

  test('adjuntos usan multipart oficial y descarga autenticada', () async {
    final temp = await Directory.systemTemp.createTemp('kanban-attachment-');
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/trace.txt');
    await file.writeAsString('trace-body');
    final requests = <http.Request>[];
    final dashboard = DashboardClient(
      host: 'hermes.local',
      manualToken: 'session-token',
      httpClientOverride: MockClient((request) async {
        requests.add(request);
        switch ((request.method, request.url.path)) {
          case ('POST', '/api/plugins/kanban/tasks/t1/attachments'):
            expect(request.headers['content-type'], startsWith('multipart/'));
            expect(request.body, contains('name="file"'));
            expect(request.body, contains('filename="trace.txt"'));
            expect(request.body, isNot(contains('/private/')));
            expect(request.body, contains('name="uploaded_by"'));
            expect(request.body, contains('mobile'));
            return http.Response(
              jsonEncode({
                'attachment': {
                  'id': 11,
                  'task_id': 't1',
                  'filename': 'trace.txt',
                  'size': 10,
                },
              }),
              200,
            );
          case ('GET', '/api/plugins/kanban/tasks/t1/attachments'):
            return http.Response(
              jsonEncode({
                'attachments': [
                  {'id': 11, 'filename': 'trace.txt', 'size': 10},
                ],
              }),
              200,
            );
          case ('GET', '/api/plugins/kanban/attachments/11'):
            return http.Response.bytes(
              utf8.encode('trace-body'),
              200,
              headers: {'content-type': 'text/plain'},
            );
          case ('DELETE', '/api/plugins/kanban/attachments/11'):
            return http.Response('{"ok":true}', 200);
          default:
            return http.Response('{}', 404);
        }
      }),
    );
    final client = KanbanClient(connection(), dashboardClient: dashboard);
    addTearDown(client.close);

    final uploaded = await client.uploadAttachment(
      't1',
      filePath: file.path,
      filename: '/private/trace.txt',
      uploadedBy: 'mobile',
      board: 'project',
    );
    final listed = await client.listAttachments('t1', board: 'project');
    final downloaded = await client.downloadAttachment('11', board: 'project');
    await client.deleteAttachment('11', board: 'project');

    expect(uploaded.id, '11');
    expect(listed.single.filename, 'trace.txt');
    expect(utf8.decode(downloaded.bytes), 'trace-body');
    expect(downloaded.contentType, 'text/plain');
    expect(
      requests.every(
        (request) => request.url.queryParameters['board'] == 'project',
      ),
      isTrue,
    );
  });

  test('adjunto mayor de 25 MiB falla antes de tocar la red', () async {
    final temp = await Directory.systemTemp.createTemp('kanban-oversize-');
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/large.bin');
    final handle = await file.open(mode: FileMode.write);
    await handle.truncate(kKanbanAttachmentMaxBytes + 1);
    await handle.close();
    var calls = 0;
    final dashboard = DashboardClient(
      host: 'hermes.local',
      manualToken: 'session-token',
      httpClientOverride: MockClient((request) async {
        calls++;
        return http.Response('{}', 200);
      }),
    );
    final client = KanbanClient(connection(), dashboardClient: dashboard);
    addTearDown(client.close);

    await expectLater(
      client.uploadAttachment('t1', filePath: file.path, filename: 'large.bin'),
      throwsA(isA<StateError>()),
    );
    expect(calls, 0);
  });

  test(
    'model-options, overrides, decompose y bulk respetan payload 0.20',
    () async {
      final requests = <http.Request>[];
      final dashboard = DashboardClient(
        host: 'hermes.local',
        manualToken: 'session-token',
        httpClientOverride: MockClient((request) async {
          requests.add(request);
          switch ((request.method, request.url.path)) {
            case ('GET', '/api/plugins/kanban/model-options'):
              return http.Response(
                '{"providers":[{"slug":"openai","label":"OpenAI","models":["gpt-5.6"]}]}',
                200,
              );
            case ('PATCH', '/api/plugins/kanban/tasks/t1'):
              return http.Response('{"task":{"id":"t1"}}', 200);
            case ('POST', '/api/plugins/kanban/tasks/t1/decompose'):
              return http.Response(
                '{"ok":true,"task_id":"t1","fanout":true,"child_ids":["c1"]}',
                200,
              );
            case ('POST', '/api/plugins/kanban/tasks/bulk'):
              return http.Response(
                '{"results":[{"id":"t1","ok":true},{"id":"missing","ok":false,"error":"not found"}]}',
                200,
              );
            default:
              return http.Response('{}', 404);
          }
        }),
      );
      final client = KanbanClient(connection(), dashboardClient: dashboard);
      addTearDown(client.close);

      final options = await client.getModelOptions();
      await client.updateTaskOverrides(
        't1',
        model: 'gpt-5.6',
        provider: 'openai',
        reasoningEffort: 'high',
        board: 'project',
      );
      final decomposed = await client.decomposeTask(
        't1',
        author: 'mobile',
        board: 'project',
      );
      final bulk = await client.bulkUpdate(
        ['t1', 'missing', 't1'],
        archive: true,
        board: 'project',
      );

      expect(options.providers.single.models, ['gpt-5.6']);
      expect(decomposed.childIds, ['c1']);
      expect(bulk.succeeded.single.id, 't1');
      expect(bulk.failed.single.id, 'missing');
      expect(requests[0].url.query, isEmpty);
      expect(jsonDecode(requests[1].body), {
        'model_override': 'gpt-5.6',
        'provider_override': 'openai',
        'reasoning_effort': 'high',
      });
      expect(jsonDecode(requests[2].body), {'author': 'mobile'});
      expect(jsonDecode(requests[3].body), {
        'ids': ['t1', 'missing'],
        'archive': true,
      });
    },
  );

  test(
    'orchestration reads typed state and writes one field per request',
    () async {
      final requests = <http.Request>[];
      final dashboard = DashboardClient(
        host: 'hermes.local',
        manualToken: 'session-token',
        httpClientOverride: MockClient((request) async {
          requests.add(request);
          switch ((request.method, request.url.path)) {
            case ('GET', '/api/plugins/kanban/orchestration'):
            case ('PUT', '/api/plugins/kanban/orchestration'):
              return http.Response(
                jsonEncode({
                  'orchestrator_profile': 'lead',
                  'default_assignee': null,
                  'auto_decompose': true,
                  'resolved_orchestrator_profile': 'lead',
                  'resolved_default_assignee': 'builder',
                  'active_profile': 'default',
                }),
                200,
              );
            case ('PATCH', '/api/plugins/kanban/profiles/builder'):
              return http.Response(
                '{"ok":true,"profile":"builder","description":"Builds"}',
                200,
              );
            case ('POST', '/api/plugins/kanban/profiles/builder/describe-auto'):
              return http.Response(
                '{"ok":false,"profile":"builder","reason":"No model","description":""}',
                200,
              );
            default:
              return http.Response('{}', 404);
          }
        }),
      );
      final client = KanbanClient(connection(), dashboardClient: dashboard);
      addTearDown(client.close);

      final state = await client.getOrchestration();
      final updated = await client.setOrchestration(
        orchestratorProfile: 'lead',
      );
      final cleared = await client.setOrchestration(defaultAssignee: '');
      final description = await client.setProfileDescription(
        'builder',
        '  Builds  ',
      );
      final automatic = await client.autoDescribeProfile('builder');

      expect(state!.orchestratorProfile, 'lead');
      expect(state.defaultAssignee, isNull);
      expect(state.autoDecompose, isTrue);
      expect(updated.resolvedOrchestratorProfile, 'lead');
      expect(cleared.resolvedDefaultAssignee, 'builder');
      expect(description.description, 'Builds');
      expect(automatic.ok, isFalse);
      expect(automatic.reason, 'No model');
      expect(jsonDecode(requests[1].body), {'orchestrator_profile': 'lead'});
      expect(jsonDecode(requests[2].body), {'default_assignee': ''});
      expect(jsonDecode(requests[3].body), {'description': 'Builds'});
      expect(jsonDecode(requests[4].body), {'overwrite': false});
    },
  );

  test('create override fields follow the Desktop omit rule', () async {
    final bodies = <Map<String, dynamic>>[];
    final dashboard = DashboardClient(
      host: 'hermes.local',
      manualToken: 'session-token',
      httpClientOverride: MockClient((request) async {
        bodies.add(Map<String, dynamic>.from(jsonDecode(request.body) as Map));
        return http.Response('{}', 200);
      }),
    );
    final client = KanbanClient(connection(), dashboardClient: dashboard);
    addTearDown(client.close);

    await client.createTask(title: 'Profile defaults');
    await client.createTask(
      title: 'Override',
      modelOverride: 'gpt-5.6',
      providerOverride: 'openai',
      reasoningEffort: 'high',
    );

    expect(bodies.first, {'title': 'Profile defaults'});
    expect(bodies.first.keys.where((key) => key.startsWith('clear_')), isEmpty);
    expect(bodies.last, {
      'title': 'Override',
      'model_override': 'gpt-5.6',
      'provider_override': 'openai',
      'reasoning_effort': 'high',
    });
  });

  test(
    'modo solo lectura bloquea todas las mutaciones antes de la red',
    () async {
      var calls = 0;
      final dashboard = DashboardClient(
        host: 'hermes.local',
        manualToken: 'session-token',
        httpClientOverride: MockClient((request) async {
          calls++;
          return http.Response('{"ok":true}', 200);
        }),
      );
      final client = KanbanClient(
        connection(readOnly: true),
        dashboardClient: dashboard,
      );
      addTearDown(client.close);

      final mutations = <Future<void>>[
        client.addComment('t1', 'nota'),
        client.createTask(title: 'nueva'),
        client.setOrchestration(autoDecompose: true).then((_) {}),
        client.setProfileDescription('builder', 'Builds').then((_) {}),
        client.autoDescribeProfile('builder').then((_) {}),
        client.moveTask('t1', 'done'),
        client.updateTask('t1', title: 'cambio'),
        client.deleteTask('t1'),
        client.terminateRun(7).then((_) {}),
        client.reclaimTask('t1').then((_) {}),
        client.reassignTask('t1', profile: 'default').then((_) {}),
        client.specifyTask('t1').then((_) {}),
        client.decomposeTask('t1').then((_) {}),
        client.updateTaskOverrides('t1', clearModel: true),
        client.bulkUpdate(['t1'], archive: true).then((_) {}),
        client
            .uploadAttachment(
              't1',
              filePath: '/does/not/exist',
              filename: 'blocked.txt',
            )
            .then((_) {}),
        client.deleteAttachment('1'),
      ];

      for (final mutation in mutations) {
        await expectLater(mutation, throwsA(isA<StateError>()));
      }
      expect(calls, 0);
    },
  );
}
