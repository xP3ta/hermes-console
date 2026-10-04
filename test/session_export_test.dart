// Export of a conversation as JSON, shaped like Hermes Desktop's
// `session-export.ts`: `{exported_at, session_id, title, session,
// message_count, messages}` written to a temporary file, shared once and
// deleted. The transcript read is capped so a huge chat cannot exhaust the
// phone.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/core_read.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/session_export_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Session _session({
  String id = 'stored-0123456789',
  String title = 'Plan de viaje',
  String? profile,
}) => Session(
  id: id,
  title: title,
  model: 'model-a',
  source: 'mobile',
  messageCount: 3,
  isActive: false,
  preview: 'private preview text',
  startedAt: 1790000000,
  updatedAt: 1790000500,
  cwd: '/srv/work/repo',
  gitRepoRoot: '/srv/work/repo',
  gitBranch: 'main',
  profile: profile,
  inputTokens: 120,
  outputTokens: 80,
  estimatedCostUsd: 0.5,
);

List<Map<String, dynamic>> _messages(int count, {int pad = 0}) => [
  for (var i = 0; i < count; i++)
    {
      'message_id': 'm$i',
      'role': i.isEven ? 'user' : 'assistant',
      'content': 'message $i${'x' * pad}',
    },
];

/// A fake `/api/sessions/{id}/messages` with `order=latest` pagination.
ApiClient _api(
  List<Map<String, dynamic>> all, {
  List<Uri>? requests,
  int status = 200,
}) => ApiClient(
  baseUrl: 'https://hermes.example.test',
  apiKey: 'k',
  httpClient: MockClient((request) async {
    requests?.add(request.url);
    if (status != 200) return http.Response('x', status);
    final limit = int.parse(request.url.queryParameters['limit'] ?? '120');
    final offset = int.parse(request.url.queryParameters['offset'] ?? '0');
    final end = math.max(0, all.length - offset);
    final start = math.max(0, end - limit);
    final page = all.sublist(start, end);
    return http.Response(
      jsonEncode({
        'session_id': 'stored-0123456789',
        'messages': page,
        'pagination': {
          'limit': limit,
          'offset': offset,
          'order': 'latest',
          'returned': page.length,
        },
      }),
      200,
    );
  }),
);

void main() {
  group('ApiClient.getMessages cap', () {
    test('without a cap it reads every page in chronological order', () async {
      final all = _messages(1040);
      final requests = <Uri>[];
      final rows = await _api(all, requests: requests).getMessages('s1');
      expect(rows, hasLength(1040));
      expect(rows.first['message_id'], 'm0');
      expect(rows.last['message_id'], 'm1039');
      expect(requests, hasLength(3));
    });

    test('a transcript under the cap is returned whole', () async {
      final rows = await _api(
        _messages(30),
      ).getMessages('s1', maxJsonChars: 1000000);
      expect(rows, hasLength(30));
    });

    test('over the cap it stops with a typed error', () async {
      final requests = <Uri>[];
      await expectLater(
        _api(
          _messages(1040, pad: 200),
          requests: requests,
        ).getMessages('s1', maxJsonChars: 50000),
        throwsA(isA<SessionTranscriptTooLargeException>()),
      );
      // It does not keep paging once the cap is passed.
      expect(requests.length, lessThan(3));
    });
  });

  group('ApiClient.getMessages bounded read', () {
    // The cap must hold while the body arrives, not after it was decoded: a
    // first page with one huge message is abandoned part way through.
    ApiClient streamingApi({
      required int totalBytes,
      required void Function(int) onChunk,
      int? declaredLength,
    }) => ApiClient(
      baseUrl: 'https://hermes.example.test',
      apiKey: 'k',
      httpClient: MockClient.streaming((request, _) async {
        Stream<List<int>> body() async* {
          var sent = 0;
          while (sent < totalBytes) {
            const chunk = 64 * 1024;
            sent += chunk;
            onChunk(sent);
            yield List<int>.filled(chunk, 0x61);
          }
        }

        return http.StreamedResponse(
          body(),
          200,
          contentLength: declaredLength,
        );
      }),
    );

    test('stops reading the body once it passes the cap', () async {
      var delivered = 0;
      await expectLater(
        streamingApi(
          totalBytes: 40 * 1024 * 1024,
          onChunk: (n) => delivered = n,
        ).getMessages('s1', maxJsonChars: 100000),
        throwsA(isA<SessionTranscriptTooLargeException>()),
      );
      // 100 000 chars allow at most 400 000 bytes (+ one chunk in flight).
      expect(delivered, lessThanOrEqualTo(512 * 1024));
    });

    test('a declared length over the cap is refused without reading', () async {
      var delivered = 0;
      await expectLater(
        streamingApi(
          totalBytes: 40 * 1024 * 1024,
          declaredLength: 20 * 1024 * 1024,
          onChunk: (n) => delivered = n,
        ).getMessages('s1', maxJsonChars: 100000),
        throwsA(isA<SessionTranscriptTooLargeException>()),
      );
      expect(delivered, lessThanOrEqualTo(64 * 1024));
    });
  });

  group('sessionExportFileName', () {
    test('slugs the title and the first 8 characters of the id', () {
      expect(
        sessionExportFileName('Plan de viaje', 'stored-0123456789'),
        'plan-de-viaje-stored-0.json',
      );
    });

    test('lowercases, keeps dots, dashes and underscores, trims dashes', () {
      expect(
        sessionExportFileName('  --Hello, World_v1.2!!  ', 'ABCDEF12-34'),
        'hello-world_v1.2-abcdef12.json',
      );
    });

    test('falls back to "session" for an empty title or id', () {
      expect(sessionExportFileName('¡¿?!', '***'), 'session-session.json');
      expect(sessionExportFileName(null, ''), 'session-session.json');
    });

    test('caps the title slug at 48 characters', () {
      final name = sessionExportFileName('a' * 100, 'id-1234567');
      expect(name, '${'a' * 48}-id-12345.json');
    });

    test('never ends the title slug with a dash after the cut', () {
      final title = '${'a' * 47} bbbb';
      expect(
        sessionExportFileName(title, 'id-1234567'),
        '${'a' * 47}-id-12345.json',
      );
    });
  });

  group('SessionExportService', () {
    late Directory temp;
    final shared = <(String, String)>[];
    final now = DateTime.utc(2026, 10, 4, 12, 30, 5);

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('session-export-test');
      shared.clear();
    });

    tearDown(() async {
      if (temp.existsSync()) await temp.delete(recursive: true);
    });

    SessionExportService service(
      ApiClient api, {
      int cap = sessionExportMaxJsonChars,
    }) => SessionExportService(
      readMessages: (id, {profile, maxJsonChars}) =>
          api.getMessages(id, profile: profile, maxJsonChars: maxJsonChars),
      tempDir: () async => temp,
      shareFile: (file) async =>
          shared.add((file.uri.pathSegments.last, file.readAsStringSync())),
      clock: () => now,
      maxJsonChars: cap,
    );

    test('shares one JSON file shaped like the Desktop export', () async {
      final result = await service(
        _api(_messages(1040)),
      ).export(_session(), title: 'Plan de viaje');

      expect(result, SessionExportResult.shared);
      expect(shared, hasLength(1));
      expect(shared.single.$1, 'plan-de-viaje-stored-0.json');
      final json = jsonDecode(shared.single.$2) as Map<String, dynamic>;
      expect(json.keys.toList(), [
        'exported_at',
        'session_id',
        'title',
        'session',
        'message_count',
        'messages',
      ]);
      expect(json['exported_at'], '2026-10-04T12:30:05.000Z');
      expect(json['session_id'], 'stored-0123456789');
      expect(json['title'], 'Plan de viaje');
      expect(json['message_count'], 1040);
      final messages = (json['messages'] as List).cast<Map<String, dynamic>>();
      expect(messages, hasLength(1040));
      expect(messages.first['message_id'], 'm0');
      expect(messages.last['message_id'], 'm1039');
    });

    test('the session block holds the public fields of the row', () async {
      await service(_api(_messages(3))).export(_session(profile: 'work'));
      final session =
          (jsonDecode(shared.single.$2) as Map)['session']
              as Map<String, dynamic>;
      expect(session['id'], 'stored-0123456789');
      expect(session['title'], 'Plan de viaje');
      expect(session['model'], 'model-a');
      expect(session['profile'], 'work');
      expect(session['cwd'], '/srv/work/repo');
      expect(session['git_branch'], 'main');
      expect(session['input_tokens'], 120);
      expect(session['estimated_cost_usd'], 0.5);
      // No free text of the conversation outside `messages`.
      expect(shared.single.$2.contains('private preview text'), isFalse);
    });

    test('a null title stays null', () async {
      await service(_api(_messages(2))).export(_session());
      expect((jsonDecode(shared.single.$2) as Map)['title'], isNull);
    });

    test('reads with the stored id and the session profile', () async {
      final requests = <Uri>[];
      await service(
        _api(_messages(2), requests: requests),
      ).export(_session(profile: 'work'));
      expect(
        requests.single.path,
        '/p/work/api/sessions/stored-0123456789/messages',
      );
    });

    test('the temporary file is deleted after sharing', () async {
      await service(_api(_messages(2))).export(_session());
      expect(temp.listSync(), isEmpty);
    });

    test('the temporary file is deleted when sharing fails', () async {
      final failing = SessionExportService(
        readMessages: (id, {profile, maxJsonChars}) =>
            _api(_messages(2)).getMessages(id),
        tempDir: () async => temp,
        shareFile: (_) async => throw StateError('share sheet failed'),
        clock: () => now,
      );
      expect(await failing.export(_session()), SessionExportResult.failed);
      expect(temp.listSync(), isEmpty);
    });

    test('over the cap there is no file and nothing is shared', () async {
      final result = await service(
        _api(_messages(1040, pad: 200)),
        cap: 50000,
      ).export(_session());
      expect(result, SessionExportResult.tooLarge);
      expect(shared, isEmpty);
      expect(temp.listSync(), isEmpty);
    });

    test('the cap handed to the read is the exporter cap', () async {
      int? seen;
      final svc = SessionExportService(
        readMessages: (id, {profile, maxJsonChars}) async {
          seen = maxJsonChars;
          return _messages(1);
        },
        tempDir: () async => temp,
        shareFile: (_) async {},
        clock: () => now,
      );
      await svc.export(_session());
      expect(seen, 8000000);
    });

    test('404 and 503 are reported, not thrown', () async {
      expect(
        await service(_api(const [], status: 404)).export(_session()),
        SessionExportResult.notFound,
      );
      expect(
        await service(_api(const [], status: 503)).export(_session()),
        SessionExportResult.unavailable,
      );
      expect(shared, isEmpty);
    });

    test('leaving the screen before the read ends shares nothing', () async {
      var cancelled = false;
      final svc = SessionExportService(
        readMessages: (id, {profile, maxJsonChars}) async {
          cancelled = true;
          return _messages(2);
        },
        tempDir: () async => temp,
        shareFile: (file) async => shared.add(('x', 'x')),
        clock: () => now,
      );
      final result = await svc.export(_session(), isCancelled: () => cancelled);
      expect(result, SessionExportResult.cancelled);
      expect(shared, isEmpty);
      expect(temp.listSync(), isEmpty);
    });

    test('a failed read is a plain failure', () async {
      final svc = SessionExportService(
        readMessages: (id, {profile, maxJsonChars}) async =>
            throw const CoreReadException(CoreReadErrorKind.malformed),
        tempDir: () async => temp,
        shareFile: (_) async {},
        clock: () => now,
      );
      expect(await svc.export(_session()), SessionExportResult.failed);
    });
  });
}
