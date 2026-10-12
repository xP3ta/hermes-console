import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/voice/live/voice_live_api.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('missing Dashboard login is access-required, not unsupported', () async {
    final client = DashboardClient(
      host: 'hermes.local',
      httpClientOverride: MockClient((_) async => http.Response('{}', 401)),
    );
    addTearDown(client.close);
    await expectLater(
      readVoiceLiveStatus(DashboardVoiceLiveApi(client)),
      throwsA(
        isA<VoiceLiveStatusException>().having(
          (e) => e.failure,
          'failure',
          VoiceLiveStatusFailure.accessRequired,
        ),
      ),
    );
  });
  for (final code in [401, 403, 500, 503]) {
    test('status $code retains typed access or transient evidence', () async {
      final client = DashboardClient(
        host: 'hermes.local',
        manualToken: 'fixture',
        httpClientOverride: MockClient((_) async => http.Response('{}', code)),
      );
      addTearDown(client.close);
      await expectLater(
        readVoiceLiveStatus(DashboardVoiceLiveApi(client)),
        throwsA(
          isA<VoiceLiveStatusException>().having(
            (e) => e.failure,
            'failure',
            code == 401 || code == 403
                ? VoiceLiveStatusFailure.accessRequired
                : VoiceLiveStatusFailure.transient,
          ),
        ),
      );
    });
  }
  for (final error in [
    const SocketException('offline'),
    TimeoutException('timeout'),
  ]) {
    test('status ${error.runtimeType} is not unsupported evidence', () async {
      final client = DashboardClient(
        host: 'hermes.local',
        manualToken: 'fixture',
        httpClientOverride: MockClient((_) async => throw error),
      );
      addTearDown(client.close);
      await expectLater(
        readVoiceLiveStatus(DashboardVoiceLiveApi(client)),
        throwsA(
          isA<VoiceLiveStatusException>().having(
            (e) => e.retryable,
            'retryable',
            isTrue,
          ),
        ),
      );
    });
  }
}
