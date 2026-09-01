import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/config/flavor.dart';
import 'package:hermes_android/core/services/notifications/background_listener.dart';
import 'package:hermes_android/core/services/notifications/notification_strings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('voice foreground product gate', () {
    test('voice is enabled in an ordinary build', () {
      expect(kVoiceModeEnabled, isTrue);
      expect(kVoiceQaHarnessEnabled, isFalse);
      expect(kVoiceRuntimeEnabled, isTrue);
    });

    test('requires both the QA flavor and the explicit request', () {
      expect(voiceQaHarnessAllowed(flavor: 'qa', requested: true), isTrue);
      expect(voiceQaHarnessAllowed(flavor: 'qa', requested: false), isFalse);
      expect(voiceQaHarnessAllowed(flavor: 'full', requested: true), isFalse);
      expect(voiceQaHarnessAllowed(flavor: 'play', requested: true), isFalse);
    });

    test('keeps foreground only for opted-in active voice sessions', () {
      expect(
        voiceRuntimeNeedsForeground(active: true, continueWhenLocked: true),
        isTrue,
      );
      expect(
        voiceRuntimeNeedsForeground(active: true, continueWhenLocked: false),
        isFalse,
      );
      expect(
        voiceRuntimeNeedsForeground(active: false, continueWhenLocked: true),
        isFalse,
      );
    });

    test('Pause libera lease de audio sin terminar la conversación lógica', () {
      final main = File('lib/main.dart').readAsStringSync();
      final runtimeChanged = main.indexOf('void _onVoiceRuntimeChanged()');
      final consentChanged = main.indexOf(
        'void _onVoiceConsentChanged()',
        runtimeChanged,
      );

      expect(runtimeChanged, isNonNegative);
      expect(consentChanged, greaterThan(runtimeChanged));
      final handler = main.substring(runtimeChanged, consentChanged);
      expect(
        handler,
        contains('voice.setVoiceConversationActive(voiceConvo.active)'),
      );
      expect(
        handler,
        contains(
          'voice.setVoiceConversationAudioLeaseActive('
          'voiceConvo.audioLeaseRequired)',
        ),
      );
      expect(
        handler.indexOf('setVoiceConversationAudioLeaseActive'),
        lessThan(handler.indexOf('_queueVoiceForegroundSync()')),
        reason: 'la residencia se actualiza antes de reconciliar el FGS',
      );
      expect(main, isNot(contains('_armVoicePauseTimeout')));
    });
  });

  group('voice notification action envelope', () {
    test('accepts only typed product actions', () {
      expect(
        BackgroundListener.voiceSessionActionFromData(const {
          'type': 'voice_session',
          'action': 'open',
        }),
        VoiceSessionAction.open,
      );
      expect(
        BackgroundListener.voiceSessionActionFromData(const {
          'type': 'voice_session',
          'action': 'pause',
        }),
        VoiceSessionAction.pause,
      );
      expect(
        BackgroundListener.voiceSessionActionFromData(const {
          'type': 'voice_session',
          'action': 'continue',
        }),
        VoiceSessionAction.continueSession,
      );
      expect(
        BackgroundListener.voiceSessionActionFromData(const {
          'type': 'voice_session',
          'action': 'end',
        }),
        VoiceSessionAction.end,
      );
    });

    test('rejects malformed, stale and unrelated data', () {
      expect(BackgroundListener.voiceSessionActionFromData(null), isNull);
      expect(
        BackgroundListener.voiceSessionActionFromData(const {
          'type': 'approval',
          'action': 'end',
        }),
        isNull,
      );
      expect(
        BackgroundListener.voiceSessionActionFromData(const {
          'type': 'voice_session',
          'action': 'unknown',
        }),
        isNull,
      );
    });

    test('entrega end antes de detener el foreground task', () async {
      final events = <String>[];
      final completion = BackgroundListener.sendTerminalActionThenStop(
        BackgroundListener.voiceSessionActionEnvelope(VoiceSessionAction.end),
        grace: Duration.zero,
        sendToMain: (data) {
          events.add(
            'send:${BackgroundListener.voiceSessionActionFromData(data)?.name}',
          );
        },
        shouldStop: () async {
          events.add('check');
          return true;
        },
        stopService: () async => events.add('stop'),
      );

      expect(events, ['send:end']);
      await completion;
      expect(events, ['send:end', 'check', 'stop']);
    });

    test('no apaga el dataSync que ya restauró el isolate principal', () async {
      SharedPreferences.setMockInitialValues({
        BackgroundListener.voiceCardActiveKey: false,
      });
      final events = <String>[];
      await BackgroundListener.sendTerminalActionThenStop(
        BackgroundListener.voiceSessionActionEnvelope(VoiceSessionAction.end),
        grace: Duration.zero,
        sendToMain: (_) => events.add('send'),
        stopService: () async => events.add('stop'),
      );

      expect(events, ['send']);
    });
  });

  group('read aloud foreground arbitration', () {
    test('prioriza conversación, después lectura y finalmente dataSync', () {
      expect(
        resolveForegroundAudioOwner(
          voiceConversationNeedsForeground: true,
          readAloudNeedsForeground: true,
        ),
        ForegroundAudioOwner.voiceConversation,
      );
      expect(
        resolveForegroundAudioOwner(
          voiceConversationNeedsForeground: false,
          readAloudNeedsForeground: true,
        ),
        ForegroundAudioOwner.readAloud,
      );
      expect(
        resolveForegroundAudioOwner(
          voiceConversationNeedsForeground: false,
          readAloudNeedsForeground: false,
        ),
        ForegroundAudioOwner.dataSync,
      );
    });

    test('pause, resume y end usan envelope separado de micrófono', () {
      for (final action in ReadAloudNotificationAction.values) {
        final envelope = BackgroundListener.readAloudActionEnvelope(action);
        expect(BackgroundListener.readAloudActionFromData(envelope), action);
        expect(BackgroundListener.voiceSessionActionFromData(envelope), isNull);
      }
      expect(
        BackgroundListener.readAloudActionFromData(const {
          'type': 'voice_session',
          'action': 'pause',
        }),
        isNull,
      );
    });
  });

  test('la aprobación usa un estado propio y nunca un botón Continuar', () {
    const es = NotifL10n(true);
    expect(
      es.voiceWaitingApproval,
      'Hermes necesita aprobación · pulsa Revisar',
    );
    expect(es.voiceCardWaitingApproval, 'Necesita aprobación');
    expect(es.voiceReviewApproval, 'Revisar');
    expect(
      BackgroundListener.voiceReviewApprovalButtonId,
      'voice_review_approval',
    );

    final source = File(
      'lib/core/services/notifications/background_listener.dart',
    ).readAsStringSync();
    final waitingProjection = source.substring(
      source.indexOf('VoiceNotificationState.waitingPermission =>'),
      source.indexOf(
        '};',
        source.indexOf('VoiceNotificationState.waitingPermission =>'),
      ),
    );
    expect(waitingProjection, contains('voiceReviewApprovalButtonId'));
    expect(waitingProjection, isNot(contains('voiceContinueButtonId')));
  });

  test('native voice card waits for the matching plugin action', () {
    final native = File(
      'android/app/src/main/kotlin/com/hermesagent/hermes_android/'
      'VoiceNotificationCardAdapter.kt',
    ).readAsStringSync();
    final dart = File(
      'lib/core/services/notifications/voice_notification_card_adapter.dart',
    ).readAsStringSync();

    // updateService() only enqueues an Android service intent. The custom card
    // must not recover and repost the previous notification while its primary
    // action still belongs to the old voice state.
    expect(native, contains('primaryAction != expectedPrimaryAction'));
    expect(native, contains('scheduleRetry('));
    expect(native, contains('generation == requestGeneration'));
    expect(dart, contains("'expectedPrimaryAction': expectedPrimaryAction"));
    expect(dart, contains("'openHintLabel': openHintLabel"));
    expect(dart, contains("'stateLabel': stateLabel"));
    expect(dart, contains("'microphoneLabel': microphoneLabel"));
    expect(native, contains('stateLabel.ifEmpty'));
    expect(native, contains('microphoneLabel.ifEmpty'));

    final listener = File(
      'lib/core/services/notifications/background_listener.dart',
    ).readAsStringSync();
    final startForVoice = listener.indexOf(
      'static Future<bool> startForVoice()',
    );
    final idempotentBranchStart = listener.indexOf(
      'if (running && _voiceTypeSaved)',
      startForVoice,
    );
    final idempotentBranch = listener.substring(
      idempotentBranchStart,
      listener.indexOf(
        'if (running) await _hardStopFlutterRuntime()',
        idempotentBranchStart,
      ),
    );
    expect(idempotentBranch, isNot(contains('updateService(')));
  });

  test('la tarjeta de voz conserva controles visibles y pulsables', () {
    final layout = File(
      'android/app/src/main/res/layout/notification_voice_expanded.xml',
    ).readAsStringSync();
    final native = File(
      'android/app/src/main/kotlin/com/hermesagent/hermes_android/'
      'VoiceNotificationCardAdapter.kt',
    ).readAsStringSync();

    expect(layout, contains('@+id/voice_notification_primary_action'));
    expect(layout, contains('@+id/voice_notification_end_action'));
    expect('android:layout_height="48dp"'.allMatches(layout), hasLength(2));
    expect(native, contains('R.id.voice_notification_primary_action'));
    expect(native, contains('R.id.voice_notification_end_action'));
    expect(native, contains('R.id.voice_notification_open_hint'));
    expect(native, contains('setOnClickPendingIntent'));
    expect(
      native,
      contains('.setActions()'),
      reason: 'la fila nativa rota no debe duplicar los controles propios',
    );
  });

  test('el arbitraje serial no reinicia el FGS al actualizar estado', () {
    final source = File('lib/main.dart').readAsStringSync();
    final syncBlock = source.substring(
      source.indexOf('Future<void> _queueVoiceForegroundSync()'),
      source.indexOf('void _onVoiceRuntimeChanged()'),
    );
    expect(syncBlock, contains('resolveForegroundAudioOwner('));
    expect(
      'BackgroundListener.startForVoice()'.allMatches(syncBlock),
      hasLength(1),
      reason: 'tokens y parciales no deben reiniciar ni republicar el FGS',
    );
    expect(
      'BackgroundListener.startForReadAloud('.allMatches(syncBlock),
      hasLength(1),
    );
    expect(
      'widget.activeChats.maybeReleaseForeground()'.allMatches(syncBlock),
      hasLength(1),
      reason:
          'al terminar el ultimo propietario de audio debe liberar dataSync '
          'si no quedan chats, SSH/SFTP ni un opt-in persistente',
    );
    expect(
      syncBlock.indexOf('widget.activeChats.maybeReleaseForeground()'),
      greaterThan(syncBlock.indexOf('BackgroundListener.downgradeFromVoice()')),
    );
    expect(
      syncBlock.indexOf('completeVoiceLeaseTrace('),
      greaterThan(
        syncBlock.indexOf('widget.activeChats.maybeReleaseForeground()'),
      ),
      reason: 'la lease se registra solo tras reconciliar downgrade y owner',
    );
    expect(syncBlock, contains('releaseConfirmed: false'));
    expect(syncBlock, isNot(contains('releaseConfirmed: true')));
  });

  test('una adquisición FGS de Voz tardía se compensa tras Exit', () {
    final source = File('lib/main.dart').readAsStringSync();
    final syncBlock = source.substring(
      source.indexOf('Future<void> _queueVoiceForegroundSync()'),
      source.indexOf('void _onVoiceRuntimeChanged()'),
    );
    final helperBlock = source.substring(
      source.indexOf(
        'Future<void> _compensateStaleVoiceForegroundAcquisition()',
      ),
      source.indexOf('Future<void> _queueVoiceForegroundSync()'),
    );

    final acquisition = syncBlock.substring(
      syncBlock.indexOf(
        'final started = await BackgroundListener.startForVoice()',
      ),
      syncBlock.indexOf('_foregroundAudioOwner = desired;'),
    );
    expect(acquisition, contains('if (!started) return;'));
    expect(
      acquisition,
      contains('await _compensateStaleVoiceForegroundAcquisition();'),
      reason:
          'si Exit gana mientras startForVoice espera, el FGS físico debe '
          'degradarse aunque el owner lógico nunca llegara a Voz',
    );
    expect(helperBlock, contains('BackgroundListener.downgradeFromVoice()'));
    expect(
      helperBlock,
      contains('widget.activeChats.maybeReleaseForeground()'),
    );
  });

  test('manifest declara mediaPlayback sin crear otro servicio', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    expect(
      manifest,
      contains('android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK'),
    );
    expect(
      manifest,
      contains(
        'android:foregroundServiceType="dataSync|remoteMessaging|microphone|mediaPlayback"',
      ),
    );
    expect(
      'com.pravera.flutter_foreground_task.service.ForegroundService'
          .allMatches(manifest),
      hasLength(1),
    );
  });

  test('full-duplex conserva AEC diagnóstico y falla cerrado en altavoz', () {
    final native = File(
      'android/app/src/main/kotlin/com/hermesagent/hermes_android/'
      'HermesFullDuplexCaptureHandler.kt',
    ).readAsStringSync();

    expect(
      native,
      contains('.setAudioSource(MediaRecorder.AudioSource.VOICE_RECOGNITION)'),
      reason:
          'VOICE_RECOGNITION conserva primary-capture en el Pixel y permite '
          'ligar AEC sin el eco de MIC ni la deformacion de voip-capture',
    );
    expect(
      native,
      isNot(contains('MediaRecorder.AudioSource.VOICE_COMMUNICATION')),
    );
    expect(native, isNot(contains('MediaRecorder.AudioSource.MIC')));
    expect(
      native,
      contains('AcousticEchoCanceler.create(recorder.audioSessionId)'),
    );
    expect(
      native,
      contains('aec != null && aec.hasControl() && aec.enabled'),
      reason: 'AEC se conserva como señal diagnóstica de la sesión real',
    );
    expect(
      native,
      contains('"playbackSafe" to privateOutput'),
      reason:
          'AEC es diagnóstico: solo la ruta privada del AudioTrack puede '
          'autorizar barge-in durante playback antes de que el eco corte TTS',
    );
    expect(
      native,
      isNot(contains('"playbackSafe" to (aecLive || privateOutput)')),
    );
    expect(
      native,
      contains('NoiseSuppressor.create(recorder.audioSessionId)'),
      reason: 'Desktop solicita noiseSuppression en la misma captura',
    );
    expect(
      native,
      contains(
        'noiseSuppressor != null && noiseSuppressor.hasControl() && '
        'noiseSuppressor.enabled',
      ),
    );
    expect(native, contains('owner.noiseSuppressor?.release()'));
  });

  test('los propietarios de audio no consumen la cuota dataSync', () {
    final source = File(
      'lib/core/services/notifications/background_listener.dart',
    ).readAsStringSync();
    for (final method in const [
      'static Future<bool> startForVoice()',
      'static Future<bool> startForReadAloud',
    ]) {
      final start = source.indexOf(method);
      final end = source.indexOf('\n  static ', start + method.length);
      final block = source.substring(start, end);
      expect(
        block,
        isNot(contains('ForegroundServiceTypes.dataSync')),
        reason: '$method no debe heredar el timeout de seis horas',
      );
    }
  });

  test('el foreground service no retiene CPU ni Wi-Fi mientras espera', () {
    final source = File(
      'lib/core/services/notifications/background_listener.dart',
    ).readAsStringSync();

    expect(source, isNot(contains('allowWakeLock: true')));
    expect(source, isNot(contains('allowWifiLock: true')));
    expect(RegExp(r'allowWakeLock:\s*false').allMatches(source), hasLength(2));
    expect(RegExp(r'allowWifiLock:\s*false').allMatches(source), hasLength(2));
  });

  test('las notificaciones solo se inicializan si hay runs o cron', () {
    final source = File(
      'lib/core/services/notifications/background_listener.dart',
    ).readAsStringSync();
    final onStart = source.substring(
      source.indexOf('Future<void> onStart('),
      source.indexOf('@override', source.indexOf('Future<void> onStart(') + 1),
    );
    final pollStart = source.indexOf('Future<void> _poll()');
    final poll = source.substring(
      pollStart,
      source.indexOf('Future<void> _maybeAutoStop(', pollStart),
    );

    expect(onStart, contains('_notif = NotificationService(prefs)'));
    expect(onStart, isNot(contains('.init()')));
    final emptyGuard = poll.indexOf('if (runs.isEmpty && cronTargets.isEmpty)');
    expect(emptyGuard, greaterThanOrEqualTo(0));
    expect(poll.indexOf('await notif.init()'), greaterThan(emptyGuard));
  });
}
