import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/bridge_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('BridgeCapabilities.fromJson', () {
    test('parsea scopes y operaciones', () {
      final caps = BridgeCapabilities.fromJson({
        'scopes': ['read', 'skills', 'memory'],
        'read_only': false,
        'version': '0.1.0',
        'operations': {
          'skills_install': true,
          'skills_remove': true,
          'memory_write': true,
          'soul_write': false,
          'logs_extended': true,
        },
      });
      expect(caps.online, isTrue);
      expect(caps.authValid, isTrue);
      expect(caps.scopes, containsAll(['read', 'skills', 'memory']));
      expect(caps.skillsInstall, isTrue);
      expect(caps.memoryWrite, isTrue);
      expect(caps.soulWrite, isFalse);
      expect(caps.cronDelete, isFalse);
      expect(caps.selfUpdate, isFalse);
      expect(caps.auditRead, isTrue); // logs_extended implica audit_read
      expect(caps.anyWrite, isTrue);
      expect(caps.version, '0.1.0');
    });

    test('offline = todo en false', () {
      const caps = BridgeCapabilities.offline;
      expect(caps.online, isFalse);
      expect(caps.anyWrite, isFalse);
      expect(caps.cronDelete, isFalse);
      expect(caps.selfUpdate, isFalse);
      expect(caps.scopes, isEmpty);
    });

    test('self update cuenta como capacidad de escritura', () {
      final caps = BridgeCapabilities.fromJson({
        'operations': {'self_update': true},
      });

      expect(caps.selfUpdate, isTrue);
      expect(caps.anyWrite, isTrue);
    });
  });

  group('selfUpdate', () {
    test(
      'envía el source verificado al endpoint autenticado y allowlisted',
      () async {
        late http.Request captured;
        const source = 'VERSION = "1.17.0"\nprint("new")\n';
        final client = BridgeClient(
          baseUrl: 'http://127.0.0.1:9131',
          token: 'bridge-secret',
          httpClient: MockClient((request) async {
            captured = request;
            return http.Response(
              jsonEncode({'ok': true, 'version': '1.17.0', 'restarting': true}),
              202,
            );
          }),
        );

        final response = await client.selfUpdate(
          source: source,
          version: '1.17.0',
          sha256: List.filled(64, 'a').join(),
        );

        expect(response['ok'], isTrue);
        expect(captured.method, 'POST');
        expect(captured.url.path, '/bridge/self-update');
        expect(captured.headers['authorization'], 'Bearer bridge-secret');
        final body = jsonDecode(captured.body) as Map<String, dynamic>;
        expect(body['version'], '1.17.0');
        expect(body['sha256'], List.filled(64, 'a').join());
        expect(
          utf8.decode(base64.decode(body['source_b64'] as String)),
          source,
        );
        client.close();
      },
    );
  });

  group('uploadAttachment', () {
    late Directory temp;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('bridge-upload-test-');
    });

    tearDown(() async {
      await temp.delete(recursive: true);
    });

    test('envía bytes y metadatos sin base64', () async {
      final file = File('${temp.path}/foto.png');
      final bytes = List<int>.generate(1024, (index) => index % 251);
      await file.writeAsBytes(bytes);
      late http.Request captured;
      final client = BridgeClient(
        baseUrl: 'http://127.0.0.1:9131',
        token: 'secret',
        httpClient: MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode({
              'ok': true,
              'path': '/home/u/.hermes/uploads/mobile/foto.png',
            }),
            200,
          );
        }),
      );

      final path = await client.uploadAttachment(
        file,
        filename: 'foto.png',
        mimeType: 'image/png',
      );

      expect(path, '/home/u/.hermes/uploads/mobile/foto.png');
      expect(captured.url.path, '/bridge/attachments');
      expect(captured.headers['x-hermes-filename'], 'foto.png');
      expect(captured.headers['content-type'], 'image/png');
      expect(captured.bodyBytes, bytes);
      expect(captured.bodyBytes.length, bytes.length);
    });

    test('rechaza localmente archivos vacíos o fuera de cota', () async {
      final empty = File('${temp.path}/empty.bin')..createSync();
      final client = BridgeClient(
        baseUrl: 'http://127.0.0.1:9131',
        token: 'secret',
        httpClient: MockClient((_) async => http.Response('{}', 200)),
      );

      await expectLater(
        client.uploadAttachment(empty, filename: 'empty.bin'),
        throwsA(isA<BridgeException>()),
      );
    });
  });

  group('deleteCronJob', () {
    test('usa el endpoint del bridge con DELETE y Bearer', () async {
      late http.Request captured;
      final client = BridgeClient(
        baseUrl: 'http://127.0.0.1:9131',
        token: 'bridge-secret',
        httpClient: MockClient((request) async {
          captured = request;
          return http.Response(jsonEncode({'ok': true}), 200);
        }),
      );

      await client.deleteCronJob('c5d077e6a181');

      expect(captured.method, 'DELETE');
      expect(captured.url.path, '/bridge/cron/jobs/c5d077e6a181');
      expect(captured.headers['authorization'], 'Bearer bridge-secret');
      client.close();
    });

    test('propaga un perfil validado y codificado al bridge', () async {
      late http.Request captured;
      final client = BridgeClient(
        baseUrl: 'http://127.0.0.1:9131',
        token: 'bridge-secret',
        httpClient: MockClient((request) async {
          captured = request;
          return http.Response(jsonEncode({'ok': true}), 200);
        }),
      );

      await client.deleteCronJob('job.profile-1', profile: 'work_bot');

      expect(captured.url.path, '/bridge/cron/jobs/job.profile-1');
      expect(captured.url.queryParameters, {'profile': 'work_bot'});
      client.close();
    });

    test('rechaza un ID manipulable antes de tocar la red', () async {
      var hits = 0;
      final client = BridgeClient(
        baseUrl: 'http://127.0.0.1:9131',
        token: 'bridge-secret',
        httpClient: MockClient((_) async {
          hits++;
          return http.Response(jsonEncode({'ok': true}), 200);
        }),
      );

      await expectLater(
        client.deleteCronJob('--help; rm'),
        throwsArgumentError,
      );
      expect(hits, 0);
      client.close();
    });

    test(
      'centraliza la allowlist de IDs y perfiles antes de tocar la red',
      () async {
        var hits = 0;
        final client = BridgeClient(
          baseUrl: 'http://127.0.0.1:9131',
          token: 'bridge-secret',
          httpClient: MockClient((_) async {
            hits++;
            return http.Response(jsonEncode({'ok': true}), 200);
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
        for (final profile in ['../work', 'Work', 'work/name', 'a' * 65]) {
          await expectLater(
            client.deleteCronJob('job-1', profile: profile),
            throwsArgumentError,
          );
        }

        expect(hits, 0);
        client.close();
      },
    );

    test('no acepta un 2xx sin confirmación ok', () async {
      final client = BridgeClient(
        baseUrl: 'http://127.0.0.1:9131',
        token: 'bridge-secret',
        httpClient: MockClient(
          (_) async => http.Response(jsonEncode({'ok': false}), 200),
        ),
      );

      await expectLater(
        client.deleteCronJob('c5d077e6a181'),
        throwsA(isA<BridgeException>()),
      );
      client.close();
    });
  });

  group('isValidSkillSource (anti-inyección)', () {
    test('acepta identificadores válidos (2–5 segmentos, @skill opcional)', () {
      for (final s in [
        'owner/repo',
        'Nous-Research/hermes.skill',
        'a_b-c/d.e_f-1',
        // Rutas multi-segmento del catálogo oficial de skills.sh (verificado en
        // vivo: el SKILL_RE del servidor las acepta y el botón instalar las usa).
        'official/email/agentmail',
        'official/autonomous-ai-agents/blackbox',
        'skills-sh/owner/repo/skill',
        'owner/repo@skill',
      ]) {
        expect(BridgeClient.isValidSkillSource(s), isTrue, reason: s);
      }
    });

    test('rechaza intentos de inyección y formatos inválidos', () {
      for (final s in [
        'owner/repo; rm -rf /',
        'owner/repo && curl x | bash',
        r'owner/$(whoami)',
        'owner/repo`id`',
        'owner repo',
        '/etc/passwd',
        'https://evil.com/x',
        'owner|repo',
        '',
        '   ',
      ]) {
        expect(BridgeClient.isValidSkillSource(s), isFalse, reason: s);
      }
    });
  });

  group('BridgeCapabilities.targets', () {
    test('parsea destinos escribibles y canWriteTarget', () {
      final caps = BridgeCapabilities.fromJson({
        'read_only': false,
        'scopes': ['read', 'memory', 'soul', 'cron'],
        'operations': {'file_read': true, 'cron_write': true},
        'targets': {
          'memory': {'mode': 'rw', 'writable': true},
          'config': {'mode': 'ro_redacted', 'writable': false},
          'cron': {'mode': 'rw', 'writable': true},
        },
      });
      expect(caps.canWriteTarget('memory'), isTrue);
      expect(caps.canWriteTarget('cron'), isTrue);
      expect(caps.canWriteTarget('config'), isFalse);
      expect(caps.canWriteTarget('inexistente'), isFalse);
      expect(caps.cronWrite, isTrue);
      expect(caps.cronDelete, isFalse);
    });

    test('consume cron_delete independientemente de cron_write', () {
      final caps = BridgeCapabilities.fromJson({
        'operations': {'cron_write': false, 'cron_delete': true},
      });

      expect(caps.cronWrite, isFalse);
      expect(caps.cronDelete, isTrue);
    });

    test('consume self_update independientemente de otras escrituras', () {
      final caps = BridgeCapabilities.fromJson({
        'operations': {'self_update': true},
      });

      expect(caps.selfUpdate, isTrue);
    });
  });

  group('isValidSkillName', () {
    test('acepta nombres simples y rechaza inyección', () {
      expect(BridgeClient.isValidSkillName('my-skill_1.2'), isTrue);
      for (final n in ['a b', 'a/b', 'a;b', r'a$b', '', '   ', 'a|b']) {
        expect(BridgeClient.isValidSkillName(n), isFalse, reason: n);
      }
    });
  });

  group('healthDiagnose clasifica la causa real', () {
    BridgeClient clientWith(MockClient mock) =>
        BridgeClient(baseUrl: 'http://h:9131', token: 't', httpClient: mock);

    test('200 status ok → reach ok', () async {
      final c = clientWith(
        MockClient(
          (_) async => http.Response(jsonEncode({'status': 'ok'}), 200),
        ),
      );
      final h = await c.healthDiagnose();
      expect(h.reach, BridgeReach.ok);
      expect(h.ok, isTrue);
    });

    test('HTTP no-200 → reach httpError con código', () async {
      final c = clientWith(MockClient((_) async => http.Response('nope', 503)));
      final h = await c.healthDiagnose();
      expect(h.reach, BridgeReach.httpError);
      expect(h.httpStatus, 503);
      expect(h.ok, isFalse);
    });

    test('200 sin status:ok → reach badResponse', () async {
      final c = clientWith(
        MockClient(
          (_) async => http.Response(jsonEncode({'status': 'starting'}), 200),
        ),
      );
      final h = await c.healthDiagnose();
      expect(h.reach, BridgeReach.badResponse);
    });

    test('conexión rechazada (errno 111) → reach refused', () async {
      final c = clientWith(
        MockClient((_) async {
          throw const SocketException(
            'refused',
            osError: OSError('Connection refused', 111),
          );
        }),
      );
      final h = await c.healthDiagnose();
      expect(h.reach, BridgeReach.refused);
      expect(h.detail, contains('refused'));
    });

    test('host no resoluble → reach dns', () async {
      final c = clientWith(
        MockClient((_) async {
          throw const SocketException('Failed host lookup');
        }),
      );
      final h = await c.healthDiagnose();
      expect(h.reach, BridgeReach.dns);
    });

    test('timeout → reach timeout', () async {
      final c = clientWith(
        MockClient((_) async {
          throw TimeoutException('slow');
        }),
      );
      final h = await c.healthDiagnose();
      expect(h.reach, BridgeReach.timeout);
    });

    test('health() sigue siendo un wrapper booleano', () async {
      final okC = clientWith(
        MockClient(
          (_) async => http.Response(jsonEncode({'status': 'ok'}), 200),
        ),
      );
      final badC = clientWith(MockClient((_) async => http.Response('x', 500)));
      expect(await okC.health(), isTrue);
      expect(await badC.health(), isFalse);
    });
  });

  group('static transport boundary', () {
    test('provision reutiliza la gateway key si provision esta cerrado pero '
        'capabilities la autentica', () async {
      final requests = <http.Request>[];
      final result = await BridgeClient.provision(
        'http://100.90.80.70:9131',
        'shared-verified-key',
        httpClient: MockClient((request) async {
          requests.add(request);
          expect(
            request.headers['authorization'],
            'Bearer shared-verified-key',
          );
          if (request.url.path == '/bridge/provision') {
            expect(request.method, 'POST');
            return http.Response(
              jsonEncode({'error': 'provision_disabled'}),
              403,
            );
          }
          expect(request.method, 'GET');
          expect(request.url.path, '/bridge/capabilities');
          return http.Response(
            jsonEncode({
              'object': 'hermes.bridge.capabilities',
              'version': '1.18.0',
              'scopes': ['read', 'config'],
              'operations': {'self_update': true},
            }),
            200,
          );
        }),
      );

      expect(result, 'shared-verified-key');
      expect(requests, hasLength(2));
    });

    test('provision no acepta un capabilities 200 de otro servicio', () async {
      final result = await BridgeClient.provision(
        'http://100.90.80.70:9131',
        'shared-verified-key',
        httpClient: MockClient((request) async {
          if (request.url.path == '/bridge/provision') {
            return http.Response('{}', 404);
          }
          return http.Response(
            jsonEncode({
              'object': 'not-hermes',
              'version': '1.18.0',
              'scopes': <String>[],
              'operations': <String, bool>{},
            }),
            200,
          );
        }),
      );

      expect(result, isNull);
    });

    test('provision no envía la API key por HTTP público', () async {
      var hits = 0;
      final result = await BridgeClient.provision(
        'http://bridge.example.com:9131',
        'must-stay-local',
        httpClient: MockClient((_) async {
          hits++;
          return http.Response('{}', 200);
        }),
      );

      expect(result, isNull);
      expect(hits, 0);
    });

    test('probeVersion tampoco toca HTTP público', () async {
      var hits = 0;
      final result = await BridgeClient.probeVersion(
        'http://bridge.example.com:9131',
        httpClient: MockClient((_) async {
          hits++;
          return http.Response('{}', 200);
        }),
      );

      expect(result, isNull);
      expect(hits, 0);
    });
  });

  group('diagnóstico de errores HTTP (TASK-016)', () {
    final logs = <String>[];
    setUp(() {
      logs.clear();
      BridgeClient.debugSink = logs.add;
    });
    tearDown(() => BridgeClient.debugSink = null);

    // Token reconocible para verificar que NUNCA aparece en logs/diagnóstico.
    BridgeClient clientWith(MockClient mock) => BridgeClient(
      baseUrl: 'http://h:9131',
      token: 'SUPERSECRET-TOKEN',
      httpClient: mock,
    );

    test(
      'HTTP 400 se clasifica como badRequest (no como offline genérico)',
      () async {
        final c = clientWith(
          MockClient(
            (_) async => http.Response(
              jsonEncode({'error': 'bad', 'message': 'campo X inválido'}),
              400,
            ),
          ),
        );
        await expectLater(
          c.rollback('b1'),
          throwsA(
            isA<BridgeException>()
                .having((e) => e.kind, 'kind', BridgeErrorKind.badRequest)
                .having((e) => e.status, 'status', 400),
          ),
        );
        expect(logs.single, contains('badRequest 400'));
      },
    );

    test('HTTP 401 y 403 se clasifican como auth', () async {
      for (final s in [401, 403]) {
        final c = clientWith(MockClient((_) async => http.Response('no', s)));
        await expectLater(
          c.rollback('b1'),
          throwsA(
            isA<BridgeException>()
                .having((e) => e.kind, 'kind', BridgeErrorKind.auth)
                .having((e) => e.status, 'status', s),
          ),
          reason: 'status $s',
        );
      }
    });

    test('HTTP 500 se clasifica como server', () async {
      final c = clientWith(MockClient((_) async => http.Response('boom', 500)));
      await expectLater(
        c.rollback('b1'),
        throwsA(
          isA<BridgeException>().having(
            (e) => e.kind,
            'kind',
            BridgeErrorKind.server,
          ),
        ),
      );
    });

    test('detect(): un no-200 deja la causa real en el log aunque devuelva '
        'offline (no se disfraza de bridge caído)', () async {
      final c = clientWith(
        MockClient((req) async {
          if (req.url.path.endsWith('/bridge/health')) {
            return http.Response(jsonEncode({'status': 'ok'}), 200);
          }
          return http.Response(jsonEncode({'error': 'bad'}), 400);
        }),
      );
      final caps = await c.detect();
      // Comportamiento de producto sin cambios: sigue degradando a offline.
      expect(caps.online, isFalse);
      // Pero el diagnóstico revela que fue un 400, no una caída de red.
      expect(logs.any((l) => l.contains('badRequest 400')), isTrue);
    });

    test('el body se trunca a un tamaño razonable', () {
      final out = BridgeClient.truncateForLog('x' * 2000);
      expect(out.length, lessThan(560));
      expect(out, contains('…(+1500)'));
    });

    test('el truncado colapsa espacios y saltos de línea', () {
      expect(BridgeClient.truncateForLog('a\n\n  b   c'), 'a b c');
    });

    test('redactUrlForLog enmascara token/key/password/auth y el userinfo', () {
      final r = BridgeClient.redactUrlForLog(
        'https://user:pass@h:9131/x?token=ABC&key=XYZ&q=ok&password=p',
      );
      expect(r, isNot(contains('ABC')));
      expect(r, isNot(contains('XYZ')));
      expect(r, isNot(contains('user:pass')));
      expect(r, contains('q=ok'));
      expect(r, contains('REDACTED'));
    });

    test('ni el diagnóstico ni el log filtran el token Bearer', () async {
      final c = clientWith(
        MockClient(
          (_) async => http.Response(jsonEncode({'error': 'bad'}), 400),
        ),
      );
      try {
        await c.rollback('b1');
        fail('debió lanzar BridgeException');
      } on BridgeException catch (e) {
        expect(e.diagnostic, isNotNull);
        expect(e.diagnostic, isNot(contains('SUPERSECRET-TOKEN')));
        expect(e.toString(), isNot(contains('SUPERSECRET-TOKEN')));
        expect(e.kind, BridgeErrorKind.badRequest);
      }
      expect(logs, isNotEmpty);
      expect(logs.every((l) => !l.contains('SUPERSECRET-TOKEN')), isTrue);
      expect(logs.every((l) => !l.toLowerCase().contains('bearer')), isTrue);
    });
  });
}
