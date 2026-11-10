import 'dart:async';
import 'dart:ui' show Locale;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/voice/session/voice_app_settings.dart';
import 'package:hermes_android/core/services/voice/session/voice_care.dart';
import 'package:hermes_android/core/services/voice/session/voice_care_text.dart';
import 'package:hermes_android/core/services/voice/session/voice_entry_guard.dart';
import 'package:hermes_android/core/services/voice/stt_engine.dart';
import 'package:hermes_android/core/services/voice/voice_service.dart'
    show SttCheck, SttStatus;
import 'package:hermes_android/core/services/voice/voice_settings.dart'
    show SttEngineKind;
import 'package:hermes_android/l10n/app_localizations.dart';

/// A system recognizer whose error callback the test can call, as the
/// platform does while it listens.
class _Recognizer implements SystemSttRuntime {
  _Recognizer({this.locales_ = const ['es_ES'], this.system = 'es_ES'});

  final List<String> locales_;
  final String? system;
  void Function(String message)? error;

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<bool> initialize({
    required void Function(String message) onError,
  }) async {
    error = onError;
    return true;
  }

  @override
  Future<List<String>> locales() async => locales_;

  @override
  Future<String?> systemLocale() async => system;

  @override
  Future<void> listen({
    required void Function(String text, bool isFinal) onResult,
    required String? localeId,
    required bool continuous,
  }) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> cancel() async {}

  @override
  Future<void> dispose() async {}
}

Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('classifySttCaptureFailure', () {
    test('names the failures the user can act on', () {
      expect(
        classifySttCaptureFailure('error_busy'),
        SttCaptureFailureKind.micBusy,
      );
      expect(
        classifySttCaptureFailure('NotReadableError: Could not start audio'),
        SttCaptureFailureKind.micBusy,
      );
      expect(
        classifySttCaptureFailure('error_audio_error'),
        SttCaptureFailureKind.micUnavailable,
      );
      for (final code in [
        'error_network',
        'error_network_timeout',
        'error_server_disconnected',
      ]) {
        expect(
          classifySttCaptureFailure(code),
          SttCaptureFailureKind.needsNetwork,
          reason: code,
        );
      }
      expect(
        classifySttCaptureFailure('error_language_unavailable'),
        SttCaptureFailureKind.languageUnavailable,
      );
    });

    test('leaves silence and unknown messages alone', () {
      expect(classifySttCaptureFailure('error_no_match'), isNull);
      expect(classifySttCaptureFailure('error_speech_timeout'), isNull);
      expect(classifySttCaptureFailure('something else'), isNull);
    });
  });

  group('system recognizer', () {
    test('a busy microphone ends the capture with its own failure', () async {
      final runtime = _Recognizer();
      final engine = SystemSttEngine(lang: 'es', runtime: runtime);
      final errors = <Object>[];
      final done = Completer<void>();
      engine.listen().listen(
        (_) {},
        onError: errors.add,
        onDone: done.complete,
      );
      await _settle();

      runtime.error!('error_busy');
      await done.future.timeout(const Duration(seconds: 2));

      expect(errors, hasLength(1));
      expect(errors.single, isA<SttCaptureFailure>());
      expect(
        (errors.single as SttCaptureFailure).kind,
        SttCaptureFailureKind.micBusy,
      );
      await engine.dispose();
    });

    test('a plain no-match is not a failure', () async {
      final runtime = _Recognizer();
      final engine = SystemSttEngine(lang: 'es', runtime: runtime);
      final errors = <Object>[];
      engine.listen().listen((_) {}, onError: errors.add);
      await _settle();

      runtime.error!('error_no_match');
      await _settle();

      expect(errors, isEmpty);
      await engine.dispose();
    });

    test(
      'says when the language has no pack and the system one is used',
      () async {
        final english = SystemSttEngine(
          lang: 'es',
          runtime: _Recognizer(locales_: const ['en_US'], system: 'en_US'),
        );
        expect(await english.available(), isTrue);
        expect(english.localeFellBack, isTrue);
        await english.dispose();

        final spanish = SystemSttEngine(
          lang: 'es',
          runtime: _Recognizer(locales_: const ['es_MX'], system: 'en_US'),
        );
        expect(await spanish.available(), isTrue);
        expect(spanish.localeFellBack, isFalse);
        await spanish.dispose();
      },
    );
  });

  group('voiceEntryBlock', () {
    VoiceEntryBlock? block({
      bool attachments = false,
      bool editing = false,
      bool approval = false,
      int queued = 0,
    }) => voiceEntryBlock(
      hasAttachments: attachments,
      editingMessage: editing,
      pendingApproval: approval,
      queuedMessages: queued,
    );

    test('lets voice start when nothing is pending', () {
      expect(block(), isNull);
    });

    test('names each thing that stands in the way', () {
      expect(block(attachments: true), VoiceEntryBlock.attachments);
      expect(block(editing: true), VoiceEntryBlock.editingMessage);
      expect(block(approval: true), VoiceEntryBlock.pendingApproval);
      expect(block(queued: 2), VoiceEntryBlock.queued);
    });

    test(
      'reports editing first, then attachments, approvals and the queue',
      () {
        expect(
          block(attachments: true, editing: true, approval: true, queued: 1),
          VoiceEntryBlock.editingMessage,
        );
        expect(
          block(attachments: true, approval: true, queued: 1),
          VoiceEntryBlock.attachments,
        );
        expect(
          block(approval: true, queued: 1),
          VoiceEntryBlock.pendingApproval,
        );
      },
    );
  });

  group('voiceEntryPrecheck', () {
    test('GPT-Live is not blocked by a missing local model', () async {
      var localCalls = 0;
      final check = await voiceEntryPrecheck(
        startsLive: true,
        localCheck: () async {
          localCalls++;
          return const SttCheck(
            SttStatus.needsWhisperModel,
            SttEngineKind.whisper,
          );
        },
        microphoneGranted: () async => true,
      );
      expect(check.ready, isTrue);
      expect(localCalls, 0);
    });

    test('GPT-Live still needs the microphone permission', () async {
      final check = await voiceEntryPrecheck(
        startsLive: true,
        localCheck: () async =>
            const SttCheck(SttStatus.ready, SttEngineKind.system),
        microphoneGranted: () async => false,
      );
      expect(check.status, SttStatus.needsMicPermission);
    });

    test('the chained conversation checks its own engine', () async {
      final check = await voiceEntryPrecheck(
        startsLive: false,
        localCheck: () async => const SttCheck(
          SttStatus.needsSherpaModel,
          SttEngineKind.sherpaLive,
        ),
        microphoneGranted: () async => true,
      );
      expect(check.status, SttStatus.needsSherpaModel);
    });
  });

  group('openAppSettingsForVoice', () {
    const channel = MethodChannel('voice-care-test/android_apps');

    tearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    test('asks the platform for the app settings page', () async {
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            return true;
          });

      expect(await openAppSettingsForVoice(channel: channel), isTrue);
      expect(calls, ['openAppSettings']);
    });

    test('is false when the platform cannot open it', () async {
      expect(await openAppSettingsForVoice(channel: channel), isFalse);
    });
  });

  group('care wording', () {
    test('every care has text in every language', () async {
      for (final code in [
        'es',
        'en',
        'pt',
        'de',
        'fr',
        'it',
        'ja',
        'ko',
        'zh',
      ]) {
        final strings = await Strings.delegate.load(Locale(code));
        for (final care in VoiceCare.values) {
          expect(
            voiceCareText(strings, care).trim(),
            isNotEmpty,
            reason: '$code ${care.name}',
          );
        }
        expect(strings.vcrRetryMessage, isNotEmpty);
        expect(strings.vcrUseThisPhone, isNotEmpty);
        expect(strings.vcrContinue, isNotEmpty);
        expect(strings.vcrOpenSettings, isNotEmpty);
      }
    });

    test('only situations that stop the conversation are blocking', () {
      expect(VoiceCare.sendFailed.blocking, isTrue);
      expect(VoiceCare.serverUnavailable.blocking, isTrue);
      expect(VoiceCare.pausedByBackground.blocking, isFalse);
      expect(VoiceCare.languageFallback.blocking, isFalse);
      expect(VoiceCare.routeRestarted.blocking, isFalse);
    });
  });
}
