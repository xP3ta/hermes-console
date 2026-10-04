// The confirmed write behind Settings › Advanced: one minimal PUT of the edited
// path, then a re-read that has to show the value before the row calls it saved.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/active_profile_scope.dart';
import 'package:hermes_android/core/services/server_config_repository.dart';
import 'package:hermes_android/core/settings/server_config_pages.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

typedef _Handler = FutureOr<http.Response> Function(http.Request request);

Map<String, dynamic> _deepMerge(
  Map<String, dynamic> base,
  Map<String, dynamic> patch,
) {
  final out = Map<String, dynamic>.from(base);
  patch.forEach((key, value) {
    final current = out[key];
    out[key] = value is Map<String, dynamic> && current is Map<String, dynamic>
        ? _deepMerge(current, value)
        : value;
  });
  return out;
}

final class _Server {
  _Server({Map<String, dynamic>? config, Map<String, dynamic>? schema})
    : config =
          config ??
          {
            'model': 'gpt-example',
            'model_context_length': 0,
            'timezone': 'UTC',
            'terminal': {'persistent_shell': false, 'cwd': '/srv/work'},
            'display': {'show_reasoning': false, 'skin': 'dark'},
            'agent': {'max_turns': 90, 'reasoning_effort': 'medium'},
            'plugins': {'secret_value': 'must-not-leak'},
          },
      schema =
          schema ??
          {
            'fields': {
              'model': {'type': 'string', 'description': 'Model'},
              'model_context_length': {
                'type': 'number',
                'description': 'Context length',
              },
              'timezone': {'type': 'string', 'description': 'Timezone'},
              'terminal.persistent_shell': {
                'type': 'boolean',
                'description': 'Persistent shell',
              },
              'terminal.cwd': {'type': 'string', 'description': 'Folder'},
              'terminal.backend': {'type': 'string', 'description': 'Backend'},
              'display.show_reasoning': {
                'type': 'boolean',
                'description': 'Show reasoning',
              },
              'display.skin': {'type': 'string', 'description': 'Skin'},
              'agent.max_turns': {'type': 'number', 'description': 'Turns'},
              'agent.reasoning_effort': {
                'type': 'select',
                'description': 'Effort',
                'options': ['low', 'medium', 'high'],
              },
              'terminal.env_passthrough': {
                'type': 'list',
                'description': 'Env',
              },
              'voice.gpt_live.api_key': {
                'type': 'string',
                'description': 'Key',
              },
              'terminal.env': {'type': 'object', 'description': 'Env map'},
            },
            'category_order': ['general'],
          };

  Map<String, dynamic> config;
  Map<String, dynamic> schema;
  final requests = <http.Request>[];

  /// Status for the PUT (200 applies the patch).
  int putStatus = 200;
  int getConfigStatus = 200;
  int schemaStatus = 200;

  /// Whether the PUT is accepted but silently not applied.
  bool dropWrites = false;
  Completer<void>? holdPut;

  List<http.Request> get puts => [
    for (final r in requests)
      if (r.method == 'PUT') r,
  ];
  List<http.Request> get configGets => [
    for (final r in requests)
      if (r.method == 'GET' && r.url.path == '/api/config') r,
  ];

  DashboardClient client() => DashboardClient(
    host: '127.0.0.1',
    port: 9119,
    manualToken: 'synthetic-dashboard-token',
    httpClientOverride: MockClient((request) async {
      requests.add(request);
      final path = request.url.path;
      if (path == '/api/config/schema') {
        return schemaStatus == 200
            ? http.Response(jsonEncode(schema), 200)
            : http.Response('{}', schemaStatus);
      }
      if (path == '/api/config' && request.method == 'GET') {
        return getConfigStatus == 200
            ? http.Response(jsonEncode(config), 200)
            : http.Response('{}', getConfigStatus);
      }
      if (path == '/api/config' && request.method == 'PUT') {
        await holdPut?.future;
        if (putStatus != 200) return http.Response('{}', putStatus);
        if (!dropWrites) {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          config = _deepMerge(config, body['config'] as Map<String, dynamic>);
        }
        return http.Response(jsonEncode({'ok': true}), 200);
      }
      return http.Response('{}', 404);
    }),
  );
}

ServerConfigRepository _repo(
  _Server server, {
  String? profile,
  bool writable = true,
}) => ServerConfigRepository(
  server.client(),
  profile: profile,
  writable: writable,
);

void main() {
  group('load', () {
    test('keeps only editable fields, grouped by page', () async {
      final snapshot = await _repo(_Server()).load();
      expect(snapshot, isNotNull);
      final byPage = snapshot!.byPage;

      expect(
        [for (final f in byPage[ServerConfigPage.mainModel]!) f.path],
        ['model_context_length', 'agent.reasoning_effort'],
      );
      expect(
        [for (final f in byPage[ServerConfigPage.shell]!) f.path],
        ['terminal.env_passthrough'],
      );
      final allPaths = [for (final f in snapshot.fields) f.path];
      expect(allPaths, isNot(contains('model')));
      expect(allPaths, isNot(contains('voice.gpt_live.api_key')));
      expect(allPaths, isNot(contains('terminal.env')));
      expect(allPaths, isNot(contains('display.skin')));
      expect(allPaths, isNot(contains('terminal.backend')));
    });

    test('carries type, description, options and the current value', () async {
      final snapshot = (await _repo(_Server()).load())!;
      final effort = snapshot.field('agent.reasoning_effort')!;
      expect(effort.type, 'select');
      expect(effort.options, ['low', 'medium', 'high']);
      expect(effort.value, 'medium');
      expect(effort.description, 'Effort');
      expect(snapshot.field('terminal.persistent_shell')!.value, false);
      expect(snapshot.field('model_context_length')!.value, 0);
    });

    test(
      'a page appears only if the schema brings one of its fields',
      () async {
        final server = _Server(
          schema: {
            'fields': {
              'timezone': {'type': 'string', 'description': 'Timezone'},
            },
          },
        );
        final snapshot = (await _repo(server).load())!;
        expect(snapshot.byPage.keys, [ServerConfigPage.behavior]);
      },
    );

    test('no value from outside the table ever reaches the snapshot', () async {
      final snapshot = (await _repo(_Server()).load())!;
      expect(
        jsonEncode(snapshot.fields.map((f) => f.value).toList()),
        isNot(contains('must-not-leak')),
      );
    });

    test('a 404 schema is unsupported, not empty', () async {
      final server = _Server()..schemaStatus = 404;
      await expectLater(
        _repo(server).load(),
        throwsA(
          isA<ServerConfigException>().having(
            (e) => e.kind,
            'kind',
            ServerConfigFailure.unsupported,
          ),
        ),
      );
    });

    test('the profile travels in the query of both reads', () async {
      final server = _Server();
      await _repo(server, profile: 'work').load();
      expect(
        server.requests.map((r) => r.url.queryParameters['profile']),
        everyElement('work'),
      );
    });

    test('a read answered after a profile change is discarded', () async {
      final server = _Server();
      var current = true;
      final snapshot = await _repo(server).load(isCurrent: () => current);
      expect(snapshot, isNotNull);

      final slow = Completer<void>();
      final repo = ServerConfigRepository(
        DashboardClient(
          host: '127.0.0.1',
          port: 9119,
          manualToken: 't',
          httpClientOverride: MockClient((request) async {
            await slow.future;
            return http.Response(
              jsonEncode(
                request.url.path.endsWith('schema')
                    ? server.schema
                    : server.config,
              ),
              200,
            );
          }),
        ),
      );
      final pending = repo.load(isCurrent: () => current);
      current = false;
      slow.complete();
      expect(await pending, isNull);
    });
  });

  group('save', () {
    test('one minimal PUT and one re-read confirm a switch', () async {
      final server = _Server();
      final result = await _repo(
        server,
      ).save('terminal.persistent_shell', true);

      expect(result.outcome, ServerConfigSaveOutcome.confirmed);
      expect(server.puts, hasLength(1));
      expect(jsonDecode(server.puts.single.body), {
        'config': {
          'terminal': {'persistent_shell': true},
        },
      });
      // One read after the write; load() is a separate call.
      expect(server.configGets, hasLength(1));
      expect(server.requests.map((r) => r.method).toList(), ['PUT', 'GET']);
    });

    test('the profile travels with the write', () async {
      final server = _Server();
      await _repo(server, profile: 'work').save('timezone', 'Europe/Madrid');
      expect(server.puts.single.url.queryParameters['profile'], 'work');
      expect(server.configGets.single.url.queryParameters['profile'], 'work');
    });

    test('model_context_length is sent without model', () async {
      final server = _Server();
      final result = await _repo(server).save('model_context_length', 32768);
      expect(result.outcome, ServerConfigSaveOutcome.confirmed);
      expect(jsonDecode(server.puts.single.body), {
        'config': {'model_context_length': 32768},
      });
    });

    test('a re-read that disagrees returns the server value', () async {
      final server = _Server()..dropWrites = true;
      final result = await _repo(
        server,
      ).save('terminal.persistent_shell', true);
      expect(result.outcome, ServerConfigSaveOutcome.mismatch);
      expect(result.serverValue, false);
    });

    test('a value missing from the re-read is a mismatch', () async {
      final server = _Server()..dropWrites = true;
      final result = await _repo(server).save('desktop.repo_scan_depth', 3);
      expect(result.outcome, ServerConfigSaveOutcome.mismatch);
      expect(result.serverValue, isNull);
    });

    test('numbers compare by value and lists element by element', () async {
      final server = _Server();
      final repo = _repo(server);
      expect(
        (await repo.save('agent.max_turns', 120.0)).outcome,
        ServerConfigSaveOutcome.confirmed,
      );
      expect(
        (await repo.save('terminal.env_passthrough', ['A', 'B'])).outcome,
        ServerConfigSaveOutcome.confirmed,
      );
    });

    test(
      'a path outside the editable table never reaches the network',
      () async {
        final server = _Server();
        for (final path in const [
          'model',
          'voice.gpt_live.api_key',
          'display.skin',
        ]) {
          await expectLater(
            _repo(server).save(path, 'x'),
            throwsA(isA<ServerConfigException>()),
            reason: path,
          );
        }
        expect(server.requests, isEmpty);
      },
    );

    test('a read-only repository never reaches the network', () async {
      final server = _Server();
      await expectLater(
        _repo(server, writable: false).save('timezone', 'UTC'),
        throwsA(
          isA<ServerConfigException>().having(
            (e) => e.kind,
            'kind',
            ServerConfigFailure.readOnly,
          ),
        ),
      );
      expect(server.requests, isEmpty);
    });

    for (final (status, kind) in const [
      (401, ServerConfigFailure.auth),
      (403, ServerConfigFailure.auth),
      (404, ServerConfigFailure.unsupported),
      (405, ServerConfigFailure.unsupported),
      (500, ServerConfigFailure.unavailable),
    ]) {
      test('PUT $status is $kind and is never marked saved', () async {
        final server = _Server()..putStatus = status;
        await expectLater(
          _repo(server).save('timezone', 'UTC'),
          throwsA(
            isA<ServerConfigException>().having((e) => e.kind, 'kind', kind),
          ),
        );
        expect(
          server.configGets,
          isEmpty,
          reason: 'no re-read after a failure',
        );
      });
    }

    test('a 401 on the re-read is not a success', () async {
      final server = _Server()..getConfigStatus = 401;
      await expectLater(
        _repo(server).save('timezone', 'UTC'),
        throwsA(
          isA<ServerConfigException>().having(
            (e) => e.kind,
            'kind',
            ServerConfigFailure.auth,
          ),
        ),
      );
    });

    test('a second save of one path waits for the first', () async {
      final server = _Server()..holdPut = Completer<void>();
      final repo = _repo(server);
      final first = repo.save('timezone', 'Europe/Madrid');
      final second = repo.save('timezone', 'UTC');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(server.puts, hasLength(1), reason: 'only the first is in flight');

      server.holdPut!.complete();
      await first;
      await second;
      expect(server.puts, hasLength(2));
      expect(server.requests.map((r) => r.method).toList(), [
        'PUT',
        'GET',
        'PUT',
        'GET',
      ]);
    });

    test(
      'an answer after the profile changed is stale, not confirmed',
      () async {
        final server = _Server();
        var current = true;
        server.holdPut = Completer<void>();
        final pending = _repo(
          server,
        ).save('timezone', 'UTC', isCurrent: () => current);
        current = false;
        server.holdPut!.complete();
        expect((await pending).outcome, ServerConfigSaveOutcome.stale);
      },
    );
  });

  test('ProfileReadTicket plugs into isCurrent', () {
    final ticket = ProfileReadTicket.fixed('work');
    expect(ticket.isCurrent, isTrue);
  });
}
