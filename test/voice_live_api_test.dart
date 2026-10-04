import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/voice/live/voice_live_api.dart';
import 'package:hermes_android/core/services/voice/live/voice_live_protocol.dart';

class _RecordingDashboard extends DashboardClient {
  _RecordingDashboard()
    : super(host: 'hermes.local', port: 1, manualToken: 'x');

  final List<String> gets = [];
  final List<({String endpoint, Map<String, dynamic>? body, Duration timeout})>
  posts = [];
  Object? getResult;
  Object? postResult;

  @override
  Future<Map<String, dynamic>> apiGet(
    String endpoint, {
    bool retried = false,
  }) async {
    gets.add(endpoint);
    final result = getResult;
    if (result is Exception) throw result;
    return result as Map<String, dynamic>;
  }

  @override
  Future<Map<String, dynamic>> apiPost(
    String endpoint, {
    Map<String, dynamic>? body,
    bool retried = false,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    posts.add((endpoint: endpoint, body: body, timeout: timeout));
    final result = postResult;
    if (result is Exception) throw result;
    return result as Map<String, dynamic>;
  }
}

void main() {
  late _RecordingDashboard dashboard;
  late DashboardVoiceLiveApi api;

  setUp(() {
    dashboard = _RecordingDashboard();
    api = DashboardVoiceLiveApi(dashboard);
  });

  group('fetchStatus', () {
    test('GETs the status route with an encoded profile', () async {
      dashboard.getResult = {'ok': true, 'mode': 'gpt-live', 'available': true};
      final status = await api.fetchStatus(profile: 'my profile/é');
      expect(dashboard.gets, [
        'audio/voice-live/status?profile=my+profile%2F%C3%A9',
      ]);
      expect(status!.mode, VoiceLiveMode.gptLive);
      expect(status.available, isTrue);
    });

    test('omits the query for the default profile', () async {
      dashboard.getResult = {'ok': true, 'available': false};
      await api.fetchStatus();
      await api.fetchStatus(profile: 'default');
      expect(dashboard.gets, [
        'audio/voice-live/status',
        'audio/voice-live/status',
      ]);
    });

    test('404, 405 and any error resolve to null', () async {
      for (final error in <Exception>[
        const DashboardHttpException(404),
        const DashboardHttpException(405),
        const DashboardHttpException(500),
        Exception('offline'),
      ]) {
        dashboard.getResult = error;
        expect(await api.fetchStatus(), isNull, reason: '$error');
      }
    });

    test('ok:false resolves to null', () async {
      dashboard.getResult = {'ok': false};
      expect(await api.fetchStatus(), isNull);
    });
  });

  group('createSession', () {
    test('POSTs sdp byte-exact and history with a 45 s timeout', () async {
      dashboard.postResult = {
        'ok': true,
        'session': {'id': 'sess_9'},
        'transport': {'type': 'webrtc', 'sdp': 'v=0\r\nanswer\r\n'},
      };
      const sdp = 'v=0\r\no=- 1 2\r\n';
      final history = [
        {
          'type': 'message',
          'role': 'user',
          'content': [
            {'type': 'input_text', 'text': 'hola'},
          ],
        },
      ];
      final answer = await api.createSession(
        sdp: sdp,
        history: history,
        profile: 'ops',
      );
      expect(dashboard.posts, hasLength(1));
      final post = dashboard.posts.single;
      expect(post.endpoint, 'audio/voice-live/session?profile=ops');
      expect(post.body, {'sdp': sdp, 'history': history});
      expect(post.timeout, const Duration(seconds: 45));
      expect(answer.sdp, 'v=0\r\nanswer\r\n');
      expect(answer.sessionId, 'sess_9');
    });

    test('omits an empty history', () async {
      dashboard.postResult = {
        'ok': true,
        'transport': {'sdp': 'answer'},
      };
      await api.createSession(sdp: 'offer');
      expect(dashboard.posts.single.body, {'sdp': 'offer'});
    });

    test('503 and 502 surface the server detail', () async {
      dashboard.postResult = const DashboardHttpException(
        503,
        body: '{"detail":"no OpenAI API key"}',
      );
      await expectLater(
        api.createSession(sdp: 'offer'),
        throwsA(
          isA<VoiceLiveSessionException>()
              .having((e) => e.statusCode, 'statusCode', 503)
              .having((e) => e.detail, 'detail', 'no OpenAI API key'),
        ),
      );
      dashboard.postResult = const DashboardHttpException(
        502,
        body: '{"detail":"GPT-Live session creation failed (400): bad"}',
      );
      await expectLater(
        api.createSession(sdp: 'offer'),
        throwsA(
          isA<VoiceLiveSessionException>().having(
            (e) => e.detail,
            'detail',
            'GPT-Live session creation failed (400): bad',
          ),
        ),
      );
    });

    test('a non-JSON error body still yields a typed error', () async {
      dashboard.postResult = const DashboardHttpException(502, body: '<html>');
      await expectLater(
        api.createSession(sdp: 'offer'),
        throwsA(
          isA<VoiceLiveSessionException>().having(
            (e) => e.statusCode,
            'statusCode',
            502,
          ),
        ),
      );
    });

    test('a response without ok or transport.sdp is rejected', () async {
      for (final body in <Map<String, dynamic>>[
        {'ok': false},
        {'ok': true},
        {
          'ok': true,
          'transport': {'sdp': ''},
        },
      ]) {
        dashboard.postResult = body;
        await expectLater(
          api.createSession(sdp: 'offer'),
          throwsA(isA<VoiceLiveSessionException>()),
          reason: '$body',
        );
      }
    });
  });
}
