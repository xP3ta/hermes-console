// Toolsets of the server: the list, enabling, the provider, the model and the
// credentials of one toolset. Every write is confirmed by reading back.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/server_toolset.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/server_config_repository.dart'
    show ServerConfigException, ServerConfigFailureKind;
import 'package:hermes_android/core/services/server_toolsets_repository.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/fake_toolsets_server.dart';

ServerToolsetsRepository _repo(
  FakeToolsetsServer server, {
  String? profile,
  bool writable = true,
  bool Function()? isCurrent,
}) => ServerToolsetsRepository(
  server.dashboard,
  profile: profile,
  writable: writable,
  isCurrent: isCurrent,
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
  group('list', () {
    test('parses a bare list, with null optional fields', () async {
      final server = FakeToolsetsServer()
        ..toolsets = [
          fakeToolset('web', enabled: true, description: null),
          {'name': 'bare'},
        ];
      final rows = await _repo(server).list();

      expect(rows.map((t) => t.name), ['web', 'bare']);
      expect(rows.first.enabled, isTrue);
      expect(rows.first.description, isNull);
      expect(rows.first.label, 'Label web');
      expect(rows.last.label, 'bare');
      expect(rows.last.enabled, isFalse);
      expect(rows.last.tools, isEmpty);
    });

    test('parses the wrapped list', () async {
      final server = FakeToolsetsServer()..wrapList = true;
      expect((await _repo(server).list()).map((t) => t.name), ['web', 'files']);
    });

    test('rows without a usable name are dropped', () async {
      final server = FakeToolsetsServer()
        ..toolsets = [
          {'name': ''},
          {'label': 'x'},
          fakeToolset('ok'),
        ];
      expect((await _repo(server).list()).map((t) => t.name), ['ok']);
    });

    test('carries the profile', () async {
      final server = FakeToolsetsServer();
      await _repo(server, profile: 'work').list();
      expect(server.requests.single.url.queryParameters, {'profile': 'work'});
    });
  });

  group('enable', () {
    test('one PUT with the flag, one re-read of the list', () async {
      final server = FakeToolsetsServer();
      final result = await _repo(server).setEnabled('files', true);

      expect(server.puts, hasLength(1));
      expect(server.puts.single.url.path, '/api/tools/toolsets/files');
      expect(jsonDecode(server.puts.single.body), {'enabled': true});
      expect(server.requests.map((r) => r.method), ['PUT', 'GET']);
      expect(
        result.toolsets.firstWhere((t) => t.name == 'files').enabled,
        true,
      );
      expect(result.postSetupStarted, isFalse);
    });

    test('post_setup_started is reported, never followed', () async {
      final server = FakeToolsetsServer()
        ..enableResponse = {
          'ok': true,
          'name': 'files',
          'platform': 'cli',
          'enabled': true,
          'post_setup_started': 'install_x',
        };
      final result = await _repo(server).setEnabled('files', true);
      expect(result.postSetupStarted, isTrue);
      expect(server.requests.map((r) => r.method), ['PUT', 'GET']);
    });

    test('a flag the re-read does not show is notSaved', () async {
      final server = FakeToolsetsServer()..ignoreWrites = true;
      final failure = await _failure(_repo(server).setEnabled('files', true));
      expect(failure.kind, ServerConfigFailureKind.notSaved);
    });

    test('an unknown toolset (400) is rejected', () async {
      final server = FakeToolsetsServer()..putStatus = 400;
      final failure = await _failure(_repo(server).setEnabled('nope', true));
      expect(failure.kind, ServerConfigFailureKind.rejected);
      expect(server.requests.map((r) => r.method), ['PUT']);
    });

    test('a read-only repository never reaches the network', () async {
      final server = FakeToolsetsServer();
      final failure = await _failure(
        _repo(server, writable: false).setEnabled('files', true),
      );
      expect(failure.kind, ServerConfigFailureKind.readOnly);
      expect(server.requests, isEmpty);
    });

    test('a name that is not a plain toolset name is refused', () async {
      final server = FakeToolsetsServer();
      for (final name in const ['', '../config', 'a/b', 'a b', 'x?y=1']) {
        final failure = await _failure(_repo(server).setEnabled(name, true));
        expect(failure.kind, ServerConfigFailureKind.rejected, reason: name);
      }
      expect(server.requests, isEmpty);
    });
  });

  group('detail', () {
    test('config parses providers, env vars with is_set only', () async {
      final server = FakeToolsetsServer();
      final config = await _repo(server).config('web');

      expect(config.hasCategory, isTrue);
      expect(config.activeProvider, 'alpha');
      expect(config.providers.map((p) => p.name), ['alpha', 'beta']);
      expect(config.providers.first.isActive, isTrue);
      expect(config.providers.first.envVars.single.key, 'ALPHA_KEY');
      expect(config.providers.first.envVars.single.isSet, isFalse);
      expect(config.providers.last.requiresNousAuth, isTrue);
      expect(server.requests.single.url.path, '/api/tools/toolsets/web/config');
    });

    test('models parses the list and the current one', () async {
      final server = FakeToolsetsServer();
      final models = await _repo(server).models('web');

      expect(models.hasModels, isTrue);
      expect(models.current, 'm1');
      expect(models.models.map((m) => m.id), ['m1', 'm2']);
      expect(models.models.last.display, 'Model 2');
    });

    test('choosing a provider: one PUT, then the config again', () async {
      final server = FakeToolsetsServer();
      final config = await _repo(server).setProvider('web', 'beta');

      expect(jsonDecode(server.puts.single.body), {'provider': 'beta'});
      expect(server.puts.single.url.path, '/api/tools/toolsets/web/provider');
      expect(server.requests.map((r) => r.method), ['PUT', 'GET']);
      expect(config.activeProvider, 'beta');
    });

    test('a provider the re-read does not show is notSaved', () async {
      final server = FakeToolsetsServer()..ignoreWrites = true;
      final failure = await _failure(_repo(server).setProvider('web', 'beta'));
      expect(failure.kind, ServerConfigFailureKind.notSaved);
    });

    test('choosing a model: one PUT, then the models again', () async {
      final server = FakeToolsetsServer();
      final models = await _repo(server).setModel('web', 'm2');

      expect(jsonDecode(server.puts.single.body), {'model': 'm2'});
      expect(server.puts.single.url.path, '/api/tools/toolsets/web/model');
      expect(server.requests.map((r) => r.method), ['PUT', 'GET']);
      expect(models.current, 'm2');
    });

    test('a model the re-read does not show is notSaved', () async {
      final server = FakeToolsetsServer()..ignoreWrites = true;
      final failure = await _failure(_repo(server).setModel('web', 'm2'));
      expect(failure.kind, ServerConfigFailureKind.notSaved);
    });

    test('credentials go in one PUT and only is_set comes back', () async {
      final server = FakeToolsetsServer();
      final config = await _repo(
        server,
      ).saveCredentials('web', {'ALPHA_KEY': 'synthetic-secret-value'});

      expect(server.puts.single.url.path, '/api/tools/toolsets/web/env');
      expect(jsonDecode(server.puts.single.body), {
        'env': {'ALPHA_KEY': 'synthetic-secret-value'},
      });
      expect(config.providers.first.envVars.single.isSet, isTrue);
      expect(config.toString(), isNot(contains('synthetic-secret-value')));
    });

    test('a credential the re-read still shows unset is notSaved', () async {
      final server = FakeToolsetsServer()..ignoreWrites = true;
      final failure = await _failure(
        _repo(server).saveCredentials('web', {'ALPHA_KEY': 'v'}),
      );
      expect(failure.kind, ServerConfigFailureKind.notSaved);
    });

    test('empty and blank credentials are not sent', () async {
      final server = FakeToolsetsServer();
      final failure = await _failure(
        _repo(server).saveCredentials('web', {'ALPHA_KEY': '  '}),
      );
      expect(failure.kind, ServerConfigFailureKind.rejected);
      expect(server.requests, isEmpty);
    });

    test('profile on every request', () async {
      final server = FakeToolsetsServer();
      final repo = _repo(server, profile: 'work');
      await repo.setProvider('web', 'beta');
      await repo.setModel('web', 'm2');
      for (final request in server.requests) {
        expect(request.url.queryParameters, {'profile': 'work'});
      }
    });
  });

  group('overlapping writes', () {
    Future<void> settle() async {
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    test(
      'two provider choices run in order: the last intent is final',
      () async {
        final server = FakeToolsetsServer()..holdNextPut = Completer<void>();
        final hold = server.holdNextPut!;
        final repo = _repo(server);

        final first = repo.setProvider('web', 'beta');
        await settle();
        final second = repo.setProvider('web', 'alpha');
        await settle();
        expect(server.puts, hasLength(1), reason: 'the second waits its turn');

        hold.complete();
        expect((await first).activeProvider, 'beta');
        expect((await second).activeProvider, 'alpha');
        expect(server.puts.map((r) => jsonDecode(r.body)['provider']), [
          'beta',
          'alpha',
        ]);
        expect(server.config['active_provider'], 'alpha');
      },
    );

    test('two model choices run in order: the last intent is final', () async {
      final server = FakeToolsetsServer()..holdNextPut = Completer<void>();
      final hold = server.holdNextPut!;
      final repo = _repo(server);

      final first = repo.setModel('web', 'm2');
      await settle();
      final second = repo.setModel('web', 'm1');
      await settle();
      hold.complete();
      await first;
      expect((await second).current, 'm1');
      expect(server.puts.map((r) => jsonDecode(r.body)['model']), ['m2', 'm1']);
      expect(server.models['current'], 'm1');
    });

    test('a write for another toolset does not wait', () async {
      final server = FakeToolsetsServer()..holdNextPut = Completer<void>();
      final hold = server.holdNextPut!;
      final repo = _repo(server);

      final first = repo.setProvider('web', 'beta');
      await settle();
      final other = repo.setEnabled('files', true);
      await settle();
      expect(server.puts, hasLength(2));
      hold.complete();
      await Future.wait([first, other]);
    });

    test('closing sends only the write already in flight', () async {
      final server = FakeToolsetsServer()..holdNextPut = Completer<void>();
      final hold = server.holdNextPut!;
      final repo = _repo(server);

      final first = repo.setProvider('web', 'beta');
      await settle();
      final second = _failure(repo.setModel('web', 'm2'));
      await settle();
      repo.close();
      hold.complete();

      expect((await first).activeProvider, 'beta');
      expect((await second).kind, ServerConfigFailureKind.closed);
      expect(server.puts, hasLength(1));
    });

    test('a queued write whose profile went stale sends no PUT', () async {
      final server = FakeToolsetsServer()..holdNextPut = Completer<void>();
      final hold = server.holdNextPut!;
      var current = true;
      final repo = _repo(server, isCurrent: () => current);

      final first = repo.setProvider('web', 'beta');
      await settle();
      final second = _failure(
        repo.saveCredentials('web', {'ALPHA_KEY': 'synthetic'}),
      );
      await settle();
      current = false;
      hold.complete();

      await first;
      expect((await second).kind, ServerConfigFailureKind.closed);
      expect(server.puts, hasLength(1));
    });
  });

  group('failures', () {
    for (final entry in {
      401: ServerConfigFailureKind.authentication,
      403: ServerConfigFailureKind.permissionDenied,
      404: ServerConfigFailureKind.unsupported,
      500: ServerConfigFailureKind.remote,
    }.entries) {
      test('HTTP ${entry.key} on a write is ${entry.value.name}', () async {
        final server = FakeToolsetsServer()..putStatus = entry.key;
        final failure = await _failure(_repo(server).setEnabled('files', true));
        expect(failure.kind, entry.value);
      });
    }

    test('a write that went through but cannot be re-read is '
        'unconfirmed', () async {
      final repo = ServerToolsetsRepository(
        DashboardClient(
          host: 'hermes.example.test',
          port: 9119,
          manualToken: 'synthetic-token',
          httpClientOverride: MockClient(
            (request) async => request.method == 'PUT'
                ? http.Response(jsonEncode({'ok': true}), 200)
                : http.Response('{}', 500),
          ),
        ),
      );
      final failure = await _failure(repo.setEnabled('files', true));
      expect(failure.kind, ServerConfigFailureKind.unconfirmed);
    });
  });

  test('the model parses defensively', () {
    final row = ServerToolset.tryParse({
      'name': 'x',
      'label': null,
      'tools': ['a', 3, null, 'b'],
      'enabled': 'yes',
    });
    expect(row, isNotNull);
    expect(row!.label, 'x');
    expect(row.tools, ['a', 'b']);
    expect(row.enabled, isFalse);
    expect(ServerToolset.tryParse('nope'), isNull);
  });
}
