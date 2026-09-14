import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/voice/conversation/native_voice.dart';
import 'package:hermes_android/core/services/voice/conversation/native_voice_session_configurator.dart';
import 'package:hermes_android/core/services/voice/voice_service.dart';

class CountClient extends MockClient {
  CountClient(super.handler);
  int closes = 0;
  @override
  void close() {
    closes++;
    super.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final barrier in ['schema', 'config']) {
    for (final invalidation in [
      'consent',
      'mode',
      'profile',
      'connection',
      'owner',
      'supersession',
      'dispose',
      'none',
    ]) {
      test(
        'adversarial $barrier fence $invalidation exact resource owner',
        () async {
          SharedPreferences.setMockInitialValues({});
          final prefs = await SharedPreferences.getInstance();
          const identity = 'http://owner.test:9119';
          await NativeVoiceModeStore(
            prefs,
          ).write(identity, NativeVoiceMode.server);
          await NativeVoiceConsentStore(
            prefs,
          ).write(identity, NativeVoiceConsent.accepted);
          await NativeVoiceCapabilityStore(prefs).write(
            identity,
            NativeVoiceCapability(
              transcribe: true,
              speak: true,
              checkedAtMs: DateTime.now().millisecondsSinceEpoch,
              conclusive: true,
            ),
          );
          final voice = VoiceService(prefs, SecureStorage());
          var disposed = false;
          final held = Completer<void>(), release = Completer<void>();
          var callsA = 0, callsB = 0;
          final clientA = CountClient((r) async {
            if (r.url.path ==
                (barrier == 'schema' ? '/api/config/schema' : '/api/config')) {
              if (!held.isCompleted) held.complete();
              await release.future;
            }
            if (r.url.path == '/api/audio/transcribe') {
              callsA++;
              return http.Response('{"ok":true,"transcript":"A"}', 200);
            }
            return http.Response('{}', 200);
          });
          final clientB = CountClient((r) async {
            if (r.url.path == '/api/audio/transcribe') {
              callsB++;
              return http.Response('{"ok":true,"transcript":"B"}', 200);
            }
            return http.Response('{}', 200);
          });
          final connection = SavedConnection(
            id: 'owner',
            label: 'owner',
            host: 'owner.test',
            port: 8642,
            apiKey: String.fromCharCodes([107]),
          );
          DashboardClient dash(CountClient client) => DashboardClient(
            host: 'owner.test',
            port: 9119,
            manualToken: String.fromCharCodes([116]),
            httpClientOverride: client,
          );
          final owner = Object();
          final reservation = voice.beginNativeVoicePreparation(owner: owner)!;
          var currentProfile = '', currentConnection = connection;
          final a = configureAcceptedNativeVoiceSession(
            voice: voice,
            connection: connection,
            preferences: prefs,
            profile: '',
            owner: owner,
            preparation: reservation,
            isStillCurrent: () =>
                currentProfile == '' &&
                identical(currentConnection, connection),
            dashboardClient: dash(clientA),
          );
          try {
            await held.future;
            switch (invalidation) {
              case 'consent':
                await NativeVoiceConsentStore(
                  prefs,
                ).write(identity, NativeVoiceConsent.rejected);
              case 'mode':
                await NativeVoiceModeStore(
                  prefs,
                ).write(identity, NativeVoiceMode.phone);
              case 'profile':
                currentProfile = 'different';
              case 'connection':
                currentConnection = SavedConnection(
                  id: 'B',
                  label: 'B',
                  host: 'b.test',
                  port: 8642,
                  apiKey: String.fromCharCodes([107]),
                );
              case 'owner':
                expect(
                  voice.cancelNativeVoicePreparationOwnedBy(owner),
                  isTrue,
                );
              case 'supersession':
                expect(
                  await configureAcceptedNativeVoiceSession(
                    voice: voice,
                    connection: connection,
                    preferences: prefs,
                    profile: '',
                    dashboardClient: dash(clientB),
                  ),
                  isTrue,
                );
              case 'dispose':
                await voice.dispose();
                disposed = true;
              case 'none':
                break;
            }
            release.complete();
            expect(await a, invalidation == 'none');
            expect(clientA.closes, invalidation == 'none' ? 0 : 1);
            if (invalidation == 'supersession') {
              expect(clientB.closes, 0);
              expect(
                await voice.transcribeNativeWav(Uint8List.fromList([1])),
                'B',
              );
              expect(callsA, 0);
              expect(callsB, 1);
            } else if (invalidation == 'none') {
              expect(
                await voice.transcribeNativeWav(Uint8List.fromList([1])),
                'A',
              );
              expect(callsA, 1);
            } else {
              expect(voice.nativeVoiceActive, isFalse);
            }
            if (!disposed) {
              await voice.dispose();
              disposed = true;
            }
            expect(clientA.closes, 1);
            if (invalidation == 'supersession') expect(clientB.closes, 1);
          } finally {
            if (!release.isCompleted) release.complete();
            if (!disposed) await voice.dispose();
            clientB.close();
          }
        },
      );
    }
  }
}
