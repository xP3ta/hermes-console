// Confirmed writes of one server config field: the minimal patch, the
// re-read that decides success, and what never reaches the network.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/server_config_repository.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A server whose `/api/config` deep-merges what it is sent, like Hermes.
final class _Server {
  final Map<String, dynamic> config;
  final Map<String, dynamic> schema;
  final List<http.Request> requests = [];

  /// `true`: a PUT is answered ok but changes nothing.
  bool ignoreWrites = false;
  int? putStatus;
  Object? putBody;
  int? getStatusAfterPut;
  bool dropAfterPut = false;
  Completer<void>? holdPut;
  int puts = 0;

  _Server({Map<String, dynamic>? config, Map<String, dynamic>? schema})
    : config =
          config ??
          {
            'terminal': {'persistent_shell': false, 'cwd': '/srv/a'},
            'model_context_length': 0,
            'agent': {'max_turns': 90},
            'terminal_list': <Object?>['A'],
          },
      schema = schema ?? {'fields': <String, dynamic>{}};

  late final DashboardClient dashboard = DashboardClient(
    host: 'hermes.example.test',
    port: 9119,
    manualToken: 'synthetic-token',
    httpClientOverride: MockClient(_handle),
  );

  List<http.Request> get puts_ =>
      requests.where((r) => r.method == 'PUT').toList();
  List<http.Request> get gets =>
      requests.where((r) => r.method == 'GET').toList();

  Future<http.Response> _handle(http.Request request) async {
    requests.add(request);
    if (request.method == 'PUT' && request.url.path == '/api/config') {
      puts++;
      final hold = holdPut;
      if (hold != null) await hold.future;
      final status = putStatus;
      if (status != null) return http.Response('{}', status);
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      if (!ignoreWrites) _merge(config, body['config'] as Map<String, dynamic>);
      return http.Response(jsonEncode(putBody ?? {'ok': true}), 200);
    }
    if (request.method == 'GET' && request.url.path == '/api/config') {
      if (puts > 0 && dropAfterPut) throw const SocketException('gone');
      final status = getStatusAfterPut;
      if (puts > 0 && status != null) return http.Response('{}', status);
      return http.Response(jsonEncode(config), 200);
    }
    if (request.method == 'GET' && request.url.path == '/api/config/schema') {
      return http.Response(jsonEncode(schema), 200);
    }
    return http.Response('{}', 404);
  }

  static void _merge(Map<String, dynamic> into, Map<String, dynamic> from) {
    from.forEach((key, value) {
      final current = into[key];
      if (value is Map<String, dynamic> && current is Map<String, dynamic>) {
        _merge(current, value);
      } else {
        into[key] = value;
      }
    });
  }
}

ServerConfigRepository _repo(
  _Server server, {
  String? profile,
  bool writable = true,
}) => ServerConfigRepository(
  server.dashboard,
  profile: profile,
  writable: writable,
);

Future<ServerConfigException> _failure(Future<Object?> future) async {
  try {
    await future;
  } on ServerConfigException catch (error) {
    return error;
  }
  throw TestFailure('Expected ServerConfigException');
}

void main() {
  group('save', () {
    test('sends only the branch of the path, then re-reads it', () async {
      final server = _Server();
      final result = await _repo(
        server,
      ).save('terminal.persistent_shell', true);

      expect(result, true);
      expect(server.puts_, hasLength(1));
      expect(jsonDecode(server.puts_.single.body), {
        'config': {
          'terminal': {'persistent_shell': true},
        },
      });
      expect(server.gets.map((r) => r.url.path), ['/api/config']);
      expect(server.requests.map((r) => r.method), ['PUT', 'GET']);
    });

    test('carries the profile on the write and on the re-read', () async {
      final server = _Server();
      await _repo(server, profile: 'work').save('agent.max_turns', 50);

      for (final request in server.requests) {
        expect(request.url.queryParameters, {'profile': 'work'});
      }
    });

    test('the default profile adds no query', () async {
      final server = _Server();
      await _repo(server, profile: 'default').save('agent.max_turns', 50);
      expect(server.requests.every((r) => r.url.query.isEmpty), isTrue);
    });

    test('a bad profile name is refused before any request', () async {
      final server = _Server();
      expect(
        () => _repo(server, profile: '../x'),
        throwsA(
          isA<ServerConfigException>().having(
            (e) => e.kind,
            'kind',
            ServerConfigFailureKind.invalidProfile,
          ),
        ),
      );
      expect(server.requests, isEmpty);
    });

    test('model_context_length is sent without the model', () async {
      final server = _Server();
      await _repo(server).save('model_context_length', 128000);

      expect(jsonDecode(server.puts_.single.body), {
        'config': {'model_context_length': 128000},
      });
    });

    test('a list is compared by content after the re-read', () async {
      final server = _Server(
        config: {
          'terminal': {
            'env_passthrough': <Object?>['A'],
          },
        },
      );
      final result = await _repo(
        server,
      ).save('terminal.env_passthrough', ['A', 'B']);
      expect(result, ['A', 'B']);
    });

    test('a number the server stores as a float still matches', () async {
      final server = _Server();
      expect(await _repo(server).save('agent.max_turns', 50.0), 50);
    });

    test('a value the server did not keep is an error with the server '
        'value', () async {
      final server = _Server()..ignoreWrites = true;
      final failure = await _failure(
        _repo(server).save('terminal.persistent_shell', true),
      );

      expect(failure.kind, ServerConfigFailureKind.notSaved);
      expect(failure.serverValue, false);
    });

    test('a path missing after the re-read is an error', () async {
      final server = _Server(config: {'other': 1})..ignoreWrites = true;
      final failure = await _failure(
        _repo(server).save('terminal.persistent_shell', true),
      );
      expect(failure.kind, ServerConfigFailureKind.notSaved);
      expect(failure.serverValue, isNull);
    });

    test('ok false is a rejection and nothing is re-read', () async {
      final server = _Server()..putBody = {'ok': false};
      final failure = await _failure(_repo(server).save('agent.max_turns', 50));
      expect(failure.kind, ServerConfigFailureKind.rejected);
      expect(server.gets, isEmpty);
    });

    test('a body without ok is not a success', () async {
      final server = _Server()..putBody = <String, dynamic>{};
      final failure = await _failure(_repo(server).save('agent.max_turns', 50));
      expect(failure.kind, ServerConfigFailureKind.rejected);
    });

    for (final entry in {
      400: ServerConfigFailureKind.rejected,
      401: ServerConfigFailureKind.authentication,
      403: ServerConfigFailureKind.permissionDenied,
      404: ServerConfigFailureKind.unsupported,
      500: ServerConfigFailureKind.remote,
    }.entries) {
      test('HTTP ${entry.key} on the write is ${entry.value.name}', () async {
        final server = _Server()..putStatus = entry.key;
        final failure = await _failure(
          _repo(server).save('agent.max_turns', 50),
        );
        expect(failure.kind, entry.value);
        expect(server.gets, isEmpty, reason: 'no re-read after a failed write');
      });
    }

    test('a write that went through but cannot be re-read is not a '
        'success', () async {
      for (final configure in <void Function(_Server)>[
        (s) => s.getStatusAfterPut = 500,
        (s) => s.getStatusAfterPut = 401,
        (s) => s.dropAfterPut = true,
      ]) {
        final server = _Server();
        configure(server);
        final failure = await _failure(
          _repo(server).save('agent.max_turns', 50),
        );
        expect(failure.kind, ServerConfigFailureKind.unconfirmed);
      }
    });

    test('a read-only repository never reaches the network', () async {
      final server = _Server();
      final failure = await _failure(
        _repo(server, writable: false).save('agent.max_turns', 50),
      );
      expect(failure.kind, ServerConfigFailureKind.readOnly);
      expect(server.requests, isEmpty);
    });

    test('the model and secrets are never written from here', () async {
      final server = _Server();
      for (final path in const [
        'model',
        'model.api_key',
        'logging.level',
        'terminal.backend',
        '',
      ]) {
        final failure = await _failure(_repo(server).save(path, 'x'));
        expect(failure.kind, ServerConfigFailureKind.rejected, reason: path);
      }
      expect(server.requests, isEmpty);
    });

    test('a second save of the same field waits for the first', () async {
      final server = _Server()..holdPut = Completer<void>();
      final repo = _repo(server);

      final first = repo.save('agent.max_turns', 10);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      final second = repo.save('agent.max_turns', 20);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(server.puts, 1, reason: 'the second write is not sent yet');

      final held = server.holdPut!;
      server.holdPut = null;
      held.complete();
      expect(await first, 10);
      expect(await second, 20);
      expect(server.puts, 2);
      expect(server.requests.map((r) => r.method), [
        'PUT',
        'GET',
        'PUT',
        'GET',
      ]);
    });

    test('different fields do not wait for each other', () async {
      final server = _Server()..holdPut = Completer<void>();
      final repo = _repo(server);

      final first = repo.save('agent.max_turns', 10);
      final second = repo.save('terminal.cwd', '/srv/b');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(server.puts, 2);

      server.holdPut!.complete();
      await Future.wait([first, second]);
    });

    test('a failed save does not block the next one', () async {
      final server = _Server()..putStatus = 500;
      final repo = _repo(server);
      await _failure(repo.save('agent.max_turns', 10));
      server.putStatus = null;
      expect(await repo.save('agent.max_turns', 10), 10);
    });

    test('closing refuses new work', () async {
      final server = _Server();
      final repo = _repo(server)..close();
      final failure = await _failure(repo.save('agent.max_turns', 10));
      expect(failure.kind, ServerConfigFailureKind.closed);
      expect(server.requests, isEmpty);
    });
  });

  group('load', () {
    test('reads config and schema in the same profile', () async {
      final server = _Server(
        schema: {
          'fields': {
            'agent.max_turns': {'type': 'number'},
          },
        },
      );
      final snapshot = await _repo(server, profile: 'work').load();

      expect(snapshot.profile, 'work');
      expect(snapshot.valueAt('agent.max_turns'), 90);
      expect(snapshot.valueAt('terminal.cwd'), '/srv/a');
      expect(snapshot.valueAt('terminal.missing'), isNull);
      expect(snapshot.valueAt('agent.max_turns.deeper'), isNull);
      expect(snapshot.schema['fields'], isA<Map>());
      for (final request in server.requests) {
        expect(request.method, 'GET');
        expect(request.url.queryParameters, {'profile': 'work'});
      }
    });

    test('a server without the schema route is unsupported', () async {
      final repo = ServerConfigRepository(
        DashboardClient(
          host: 'hermes.example.test',
          port: 9119,
          manualToken: 'synthetic-token',
          httpClientOverride: MockClient(
            (request) async => http.Response('nope', 404),
          ),
        ),
      );
      final failure = await _failure(repo.load());
      expect(failure.kind, ServerConfigFailureKind.unsupported);
    });

    test('a body that is not an object is an invalid response', () async {
      final repo = ServerConfigRepository(
        DashboardClient(
          host: 'hermes.example.test',
          port: 9119,
          manualToken: 'synthetic-token',
          httpClientOverride: MockClient(
            (request) async => http.Response('[1,2]', 200),
          ),
        ),
      );
      final failure = await _failure(repo.load());
      expect(failure.kind, ServerConfigFailureKind.invalidResponse);
    });
  });
}
