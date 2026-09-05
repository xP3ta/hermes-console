import 'dart:async';
import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/notifications/background_listener.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  sqflite.databaseFactory = databaseFactoryFfi;

  test('automation demand remains active until the user disables it', () async {
    SharedPreferences.setMockInitialValues({BackgroundListener.prefKey: true});
    var prefs = await SharedPreferences.getInstance();
    expect(BackgroundListener.automationMessagingDemandForTest(prefs), isTrue);

    SharedPreferences.setMockInitialValues({BackgroundListener.prefKey: false});
    prefs = await SharedPreferences.getInstance();
    expect(BackgroundListener.automationMessagingDemandForTest(prefs), isFalse);
  });

  group('live-turn foreground lease', () {
    tearDown(() => BackgroundListener.setActiveTurnDemandForTest(false));

    test('a live turn holds the service without the permanent opt-in', () async {
      SharedPreferences.setMockInitialValues({
        BackgroundListener.prefKey: false,
      });
      final prefs = await SharedPreferences.getInstance();
      expect(
        BackgroundListener.automationForegroundDemandForTest(prefs),
        isFalse,
      );

      // Sin esta lease Android congela el isolate al minimizar y la respuesta
      // del agente se pierde a mitad de turno.
      BackgroundListener.setActiveTurnDemandForTest(true);
      expect(
        BackgroundListener.automationForegroundDemandForTest(prefs),
        isTrue,
      );

      BackgroundListener.setActiveTurnDemandForTest(false);
      expect(
        BackgroundListener.automationForegroundDemandForTest(prefs),
        isFalse,
      );
    });

    test('a live turn never grants the permanent opt-in', () async {
      SharedPreferences.setMockInitialValues({
        BackgroundListener.prefKey: false,
      });
      final prefs = await SharedPreferences.getInstance();
      BackgroundListener.setActiveTurnDemandForTest(true);

      // El re-arranque tras boot y la escucha continua siguen dependiendo solo
      // del consentimiento explícito.
      expect(
        BackgroundListener.automationMessagingDemandForTest(prefs),
        isFalse,
      );
      expect(await BackgroundListener.isEnabled(), isFalse);
    });

    test('the permanent opt-in outlives the lease being released', () async {
      SharedPreferences.setMockInitialValues({
        BackgroundListener.prefKey: true,
      });
      final prefs = await SharedPreferences.getInstance();
      BackgroundListener.setActiveTurnDemandForTest(true);
      BackgroundListener.setActiveTurnDemandForTest(false);
      expect(
        BackgroundListener.automationForegroundDemandForTest(prefs),
        isTrue,
      );
    });
  });

  test('Android 15+ automation uses remoteMessaging, not dataSync', () {
    expect(
      BackgroundListener.automationServiceTypeForTest(
        androidSdkInt: 34,
      ).rawValue,
      ForegroundServiceTypes.dataSync.rawValue,
    );
    expect(
      BackgroundListener.automationServiceTypeForTest(
        androidSdkInt: 35,
      ).rawValue,
      ForegroundServiceTypes.remoteMessaging.rawValue,
    );
    expect(
      BackgroundListener.automationServiceTypeForTest(
        androidSdkInt: 36,
      ).rawValue,
      ForegroundServiceTypes.remoteMessaging.rawValue,
    );

    List<int> types({
      required bool automation,
      required bool external,
      required int sdk,
    }) => BackgroundListener.networkServiceTypesForTest(
      automation: automation,
      externalDataSync: external,
      androidSdkInt: sdk,
    ).map((type) => type.rawValue).toList();

    expect(types(automation: true, external: false, sdk: 36), [
      ForegroundServiceTypes.remoteMessaging.rawValue,
    ]);
    expect(types(automation: false, external: true, sdk: 36), isEmpty);
    expect(types(automation: true, external: true, sdk: 36), [
      ForegroundServiceTypes.remoteMessaging.rawValue,
    ]);
    expect(types(automation: true, external: true, sdk: 34), [
      ForegroundServiceTypes.dataSync.rawValue,
    ]);

    List<int> voice({
      required bool automation,
      required bool external,
      required int sdk,
    }) => BackgroundListener.voiceServiceTypesForTest(
      automation: automation,
      externalDataSync: external,
      androidSdkInt: sdk,
    ).map((type) => type.rawValue).toList();
    List<int> readAloud({
      required bool automation,
      required bool external,
      required int sdk,
    }) => BackgroundListener.readAloudServiceTypesForTest(
      automation: automation,
      externalDataSync: external,
      androidSdkInt: sdk,
    ).map((type) => type.rawValue).toList();

    expect(voice(automation: true, external: false, sdk: 36), [
      ForegroundServiceTypes.microphone.rawValue,
      ForegroundServiceTypes.mediaPlayback.rawValue,
      ForegroundServiceTypes.remoteMessaging.rawValue,
    ]);
    expect(readAloud(automation: true, external: false, sdk: 36), [
      ForegroundServiceTypes.mediaPlayback.rawValue,
      ForegroundServiceTypes.remoteMessaging.rawValue,
    ]);
    expect(voice(automation: true, external: true, sdk: 36), [
      ForegroundServiceTypes.microphone.rawValue,
      ForegroundServiceTypes.mediaPlayback.rawValue,
      ForegroundServiceTypes.remoteMessaging.rawValue,
    ]);
    expect(
      voice(automation: true, external: false, sdk: 36),
      isNot(contains(ForegroundServiceTypes.dataSync.rawValue)),
    );
  });

  test('system restarts restore only an authorized automation listener', () {
    expect(
      resolveBackgroundTaskStartDisposition(
        starter: TaskStarter.developer,
        automationEnabled: false,
      ),
      BackgroundTaskStartDisposition.runtimeOwner,
    );
    expect(
      resolveBackgroundTaskStartDisposition(
        starter: TaskStarter.system,
        automationEnabled: true,
      ),
      BackgroundTaskStartDisposition.restoreAutomation,
    );
    expect(
      resolveBackgroundTaskStartDisposition(
        starter: TaskStarter.system,
        automationEnabled: false,
      ),
      BackgroundTaskStartDisposition.stop,
    );
  });

  test('foreground UI never mistakes an audio-only service for automation', () {
    expect(
      backgroundAutomationRunningForUi(
        serviceRunning: true,
        automationOptIn: false,
      ),
      isFalse,
    );
    expect(
      backgroundAutomationRunningForUi(
        serviceRunning: true,
        automationOptIn: true,
      ),
      isTrue,
    );
    expect(
      backgroundAutomationRunningForUi(
        serviceRunning: false,
        automationOptIn: true,
      ),
      isFalse,
    );
  });

  test(
    'two overlapping SFTP transfers acquire and release one demand',
    () async {
      final transitions = <bool>[];
      final gate = ExternalDataSyncDemandGate((required) async {
        transitions.add(required);
        return true;
      });

      await gate.reconcile(sftpActive: true, sshActive: false);
      await gate.reconcile(sftpActive: true, sshActive: false);
      await gate.reconcile(sftpActive: true, sshActive: false);
      await gate.reconcile(sftpActive: false, sshActive: false);

      expect(transitions, <bool>[true, false]);
    },
  );

  test(
    'SSH failure or duplicate close cannot release another active owner',
    () async {
      final transitions = <bool>[];
      final gate = ExternalDataSyncDemandGate((required) async {
        transitions.add(required);
        return true;
      });

      await gate.reconcile(sftpActive: false, sshActive: true);
      await gate.reconcile(sftpActive: true, sshActive: true);
      // Una segunda sesión falla/cierra mientras SFTP y la primera SSH siguen.
      await gate.reconcile(sftpActive: true, sshActive: true);
      await gate.reconcile(sftpActive: true, sshActive: false);
      await gate.reconcile(sftpActive: true, sshActive: false);
      await gate.reconcile(sftpActive: false, sshActive: false);

      expect(transitions, <bool>[true, false]);
    },
  );

  test(
    'failed dataSync acquisition is retried while owner stays active',
    () async {
      var attempts = 0;
      final gate = ExternalDataSyncDemandGate((required) async {
        attempts++;
        return attempts > 1;
      });

      expect(await gate.reconcile(sftpActive: true, sshActive: false), isFalse);
      expect(await gate.reconcile(sftpActive: true, sshActive: false), isTrue);

      expect(attempts, 2);
      expect(gate.required, isTrue);
    },
  );

  test(
    'dataSync Stop waits for confirmed release and retries before ACK',
    () async {
      final releases = <Completer<bool>>[];
      final gate = ExternalDataSyncDemandGate((required) {
        if (required) return true;
        final release = Completer<bool>();
        releases.add(release);
        return release.future;
      });

      expect(await gate.reconcile(sftpActive: true, sshActive: false), isTrue);

      var acknowledged = false;
      Future<void> handleStop() async {
        final released = await gate.confirmReleased();
        if (released) acknowledged = true;
      }

      final failedStop = handleStop();
      await Future<void>.delayed(Duration.zero);
      expect(releases, hasLength(1));
      expect(acknowledged, isFalse);

      releases.single.complete(false);
      await failedStop;
      expect(acknowledged, isFalse);
      expect(gate.required, isTrue);

      final successfulRetry = handleStop();
      await Future<void>.delayed(Duration.zero);
      expect(releases, hasLength(2));
      expect(acknowledged, isFalse);

      releases.last.complete(true);
      await successfulRetry;
      expect(acknowledged, isTrue);
      expect(gate.required, isFalse);
    },
  );

  test('chat idle release never clears a live external owner', () {
    // ActiveChatService lives in the `active_chat_registry.dart` part of the
    // active_chat_service library.
    final activeChat = File(
      'lib/core/services/active_chat_registry.dart',
    ).readAsStringSync();
    final start = activeChat.indexOf('Future<void> _maybeStopForeground()');
    final end = activeChat.indexOf('void _rememberSteerProjections', start);

    expect(start, isNonNegative);
    expect(end, greaterThan(start));
    final block = activeChat.substring(start, end);
    expect(block, contains('BackgroundListener.releaseIdleRuntime()'));
    expect(block, isNot(contains('BackgroundListener.stop()')));
  });

  test(
    'audio and external FGS mutations are serialized deterministically',
    () async {
      final serializer = ForegroundMutationSerializer();
      final audioEntered = Completer<void>();
      final releaseAudio = Completer<void>();
      final order = <String>[];

      final audio = serializer.run(() async {
        order.add('audio-enter');
        audioEntered.complete();
        await releaseAudio.future;
        order.add('audio-exit');
      });
      await audioEntered.future;
      final external = serializer.run(() async {
        order.add('external');
      });
      await Future<void>.delayed(Duration.zero);
      expect(order, <String>['audio-enter']);

      releaseAudio.complete();
      await Future.wait<void>(<Future<void>>[audio, external]);
      expect(order, <String>['audio-enter', 'audio-exit', 'external']);
    },
  );

  test('Stop and downgrade share the same FGS mutation serializer', () async {
    final serializer = ForegroundMutationSerializer();
    final stopEntered = Completer<void>();
    final releaseStop = Completer<void>();
    final order = <String>[];

    final stop = serializer.run(() async {
      order.add('stop-enter');
      stopEntered.complete();
      await releaseStop.future;
      order.add('stop-exit');
    });
    await stopEntered.future;
    final voice = serializer.run(() async {
      order.add('voice');
    });
    await Future<void>.delayed(Duration.zero);
    expect(order, <String>['stop-enter']);

    releaseStop.complete();
    await Future.wait<void>(<Future<void>>[stop, voice]);
    expect(order, <String>['stop-enter', 'stop-exit', 'voice']);

    final listener = File(
      'lib/core/services/notifications/background_listener.dart',
    ).readAsStringSync();
    for (final method in <String>[
      'static Future<bool> start()',
      'static Future<bool> startForVoice()',
      'static Future<bool> startForReadAloud({required bool paused})',
      'static Future<void> downgradeFromVoice()',
      'static Future<void> downgradeFromReadAloud()',
      'static Future<bool> stop()',
      'static Future<void> restoreIfEnabled(SharedPreferences prefs)',
    ]) {
      final start = listener.indexOf(method);
      expect(start, isNonNegative, reason: method);
      final block = listener.substring(
        start,
        (start + 220).clamp(0, listener.length),
      );
      expect(block, contains('_foregroundMutations.run'), reason: method);
    }
  });

  test('task-isolate Stop fences every later notification update', () {
    final fence = ForegroundTaskStopFence();
    expect(fence.allowsUpdate, isTrue);
    fence.requestStop();
    expect(fence.allowsUpdate, isFalse);

    final listener = File(
      'lib/core/services/notifications/background_listener.dart',
    ).readAsStringSync();
    final handlerStart = listener.indexOf('class _HermesTaskHandler');
    final handlerEnd = listener.indexOf(
      '/// API sencilla para arrancar/parar',
      handlerStart,
    );
    final handler = listener.substring(handlerStart, handlerEnd);
    expect(handler, contains('_stopFence.requestStop()'));
    expect(handler, contains('if (!_stopFence.allowsUpdate) return'));
  });

  test('task isolate hydrates automation opt-in before every poll gate', () {
    final listener = File(
      'lib/core/services/notifications/background_listener.dart',
    ).readAsStringSync();
    final handlerStart = listener.indexOf('class _HermesTaskHandler');
    final onStart = listener.indexOf('Future<void> onStart(', handlerStart);
    final repeat = listener.indexOf('void onRepeatEvent(', onStart);
    final poll = listener.indexOf('Future<void> _poll()', repeat);
    final nextMethod = listener.indexOf('Future<void> _maybeAutoStop', poll);
    expect(onStart, isNonNegative);
    expect(repeat, greaterThan(onStart));
    expect(poll, greaterThan(repeat));
    expect(nextMethod, greaterThan(poll));

    final startBlock = listener.substring(onStart, repeat);
    final startReload = startBlock.indexOf('prefs.reload()');
    final startHydrate = startBlock.indexOf(
      'NotificationService.setAutomationNotificationsOptedIn(',
    );
    expect(startReload, isNonNegative);
    expect(startHydrate, greaterThan(startReload));

    final pollBlock = listener.substring(poll, nextMethod);
    final pollReload = pollBlock.indexOf('prefs.reload()');
    final pollHydrate = pollBlock.indexOf(
      'NotificationService.setAutomationNotificationsOptedIn(',
    );
    final pollGate = pollBlock.indexOf(
      'NotificationService.automationNotificationsEnabled',
    );
    expect(pollReload, isNonNegative);
    expect(pollHydrate, greaterThan(pollReload));
    expect(pollGate, greaterThan(pollHydrate));
  });

  test('task isolate reaches orphan cleanup without automation opt-in', () {
    final listener = File(
      'lib/core/services/notifications/background_listener.dart',
    ).readAsStringSync();
    final pollStart = listener.indexOf('Future<void> _poll()');
    final pollEnd = listener.indexOf('Future<void> _maybeAutoStop', pollStart);
    expect(pollStart, isNonNegative);
    expect(pollEnd, greaterThan(pollStart));
    final poll = listener.substring(pollStart, pollEnd);

    final optOutBranch = poll.indexOf('if (!automationOptIn)');
    final voiceGuard = poll.indexOf('if (audioCardActive)', optOutBranch);
    final cleanup = poll.indexOf('await _maybeAutoStop(prefs)', optOutBranch);
    final optOutReturn = poll.indexOf('return;', cleanup);
    expect(optOutBranch, isNonNegative);
    expect(voiceGuard, greaterThan(optOutBranch));
    expect(cleanup, greaterThan(voiceGuard));
    expect(optOutReturn, greaterThan(cleanup));

    final discovery = poll.indexOf('BackgroundWatch.snapshot()');
    expect(discovery, greaterThan(optOutReturn));
  });

  test('auto-stop protects a durable external owner until its release', () {
    bool evaluate({required int externalDemand}) =>
        backgroundRuntimeMayAutoStopForTest(
          automationOptIn: false,
          audioCardActive: false,
          externalDataSyncDemand: externalDemand,
          emptyPolls: 2,
          uiHeartbeatStaleMs: const Duration(minutes: 4).inMilliseconds,
        );

    expect(evaluate(externalDemand: 1), isFalse);
    expect(evaluate(externalDemand: 0), isTrue);
    expect(
      backgroundRuntimeMayAutoStopForTest(
        automationOptIn: false,
        audioCardActive: true,
        externalDataSyncDemand: 0,
        emptyPolls: 2,
        uiHeartbeatStaleMs: const Duration(minutes: 4).inMilliseconds,
      ),
      isFalse,
    );
  });

  test('manifest and UI expose a persistent user-controlled listener', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final listener = File(
      'lib/core/services/notifications/background_listener.dart',
    ).readAsStringSync();
    final es = File('lib/l10n/app_es.arb').readAsStringSync();
    final en = File('lib/l10n/app_en.arb').readAsStringSync();

    expect(
      manifest,
      contains('android.permission.FOREGROUND_SERVICE_REMOTE_MESSAGING'),
    );
    expect(
      manifest,
      contains(
        'android:foregroundServiceType="dataSync|remoteMessaging|microphone|mediaPlayback"',
      ),
    );
    expect(
      manifest,
      isNot(
        contains(
          'android:name="android.permission.RECEIVE_BOOT_COMPLETED"\n        tools:node="remove"',
        ),
      ),
    );
    expect(listener, contains('ForegroundServiceTypes.remoteMessaging'));
    expect(listener, contains('autoRunOnBoot: autoRunOnBoot'));
    expect(listener, contains('await prefs.setBool(prefKey, false);'));
    expect(listener, isNot(contains('automationSessionDuration')));
    expect(listener, isNot(contains('automationSessionDeadlineKey')));
    expect(es, contains('hasta que la desactives'));
    expect(en, contains('until you turn it off'));
    expect(es, isNot(contains('5 h 50 min')));
    expect(en, isNot(contains('5 h 50 min')));
    expect(
      manifest,
      contains('android:name=".HermesAutomationRebootReceiver"'),
    );
    expect(
      manifest,
      contains(
        'android:name="com.pravera.flutter_foreground_task.service.RebootReceiver"\n'
        '            tools:node="remove"',
      ),
    );
    expect(
      manifest,
      contains(
        'android:name="com.pravera.flutter_foreground_task.service.RestartReceiver"\n            tools:node="remove"',
      ),
    );
  });

  test(
    'clean opt-in and connection edits always refresh cron/kanban targets',
    () {
      final settings = File(
        'lib/core/screens/notification_settings_screen.dart',
      ).readAsStringSync();
      final manager = File(
        'lib/core/services/connection_manager.dart',
      ).readAsStringSync();
      final main = File('lib/main.dart').readAsStringSync();

      String methodBlock(String start, String end) {
        final from = settings.indexOf(start);
        final to = settings.indexOf(end, from + start.length);
        expect(from, isNonNegative);
        expect(to, greaterThan(from));
        return settings.substring(from, to);
      }

      for (final block in <String>[
        methodBlock(
          'Future<void> _toggleBackground(bool v)',
          'Future<void> _toggleCronResults',
        ),
        methodBlock(
          'Future<void> _toggleKanbanResults(',
          'Future<bool> _requestPermission',
        ),
      ]) {
        final sync = block.indexOf('BackgroundCronWatch.syncConnections');
        final start = block.indexOf('BackgroundListener.startForAutomation');
        expect(sync, isNonNegative);
        expect(start, greaterThan(sync));
      }

      expect(manager, contains('connectionsRevision'));
      expect(
        main,
        contains(
          'widget.connManager.connectionsRevision.addListener(\n'
          '      _syncBackgroundCronConnections,\n'
          '    );',
        ),
      );
      expect(
        main,
        contains(
          'widget.connManager.connectionsRevision.removeListener(\n'
          '      _syncBackgroundCronConnections,\n'
          '    );',
        ),
      );
    },
  );

  test('master off stops the durable automation listener', () {
    final settings = File(
      'lib/core/screens/notification_settings_screen.dart',
    ).readAsStringSync();
    final start = settings.indexOf('Widget _masterSwitch(');
    final end = settings.indexOf('List<Widget> _eventSwitches(', start);
    expect(start, isNonNegative);
    expect(end, greaterThan(start));
    final block = settings.substring(start, end);

    expect(block, contains('BackgroundListener.stopAutomation()'));
  });

  test('boot receiver restores automation-only despite transient owners', () {
    final receiver = File(
      'android/app/src/main/kotlin/com/hermesagent/hermes_android/'
      'HermesAutomationRebootReceiver.kt',
    ).readAsStringSync();
    final listener = File(
      'lib/core/services/notifications/background_listener.dart',
    ).readAsStringSync();
    final activity = File(
      'android/app/src/main/kotlin/com/hermesagent/hermes_android/'
      'MainActivity.kt',
    ).readAsStringSync();

    expect(receiver, contains('flutter.notif_background_listen'));
    expect(receiver, contains('ForegroundServiceTypes.setData'));
    expect(receiver, contains('listOf(9)'));
    expect(receiver, contains('listOf(2)'));
    expect(receiver, contains('ForegroundServiceAction.REBOOT'));
    expect(receiver, contains('ForegroundServiceAction.API_STOP'));
    expect(receiver, contains('ForegroundServiceAction.API_START'));
    expect(receiver, contains('ContextCompat.startForegroundService'));
    expect(receiver, isNot(contains('MICROPHONE')));
    expect(receiver, isNot(contains('MEDIA_PLAYBACK')));
    expect(receiver, contains('fun persist(context: Context)'));
    final persistStart = receiver.indexOf('fun persist(context: Context)');
    final persistEnd = receiver.indexOf('\n    }\n}', persistStart);
    expect(persistStart, isNonNegative);
    expect(persistEnd, greaterThan(persistStart));
    expect(
      receiver.substring(persistStart, persistEnd),
      contains('automationEnabled(context)'),
    );
    final receiveStart = receiver.indexOf('override fun onReceive');
    final sanitize = receiver.indexOf(
      'HermesForegroundRestartContract.persist(context)',
      receiveStart,
    );
    final disabledBranch = receiver.indexOf('if (!enabled) {', receiveStart);
    final disabledHardStop = receiver.indexOf(
      'HermesForegroundServiceGate.hardStopRuntimeService(context)',
      disabledBranch,
    );
    final disabledReturn = receiver.indexOf('return', disabledHardStop);
    expect(sanitize, greaterThan(receiveStart));
    expect(disabledBranch, greaterThan(sanitize));
    expect(disabledHardStop, greaterThan(disabledBranch));
    expect(disabledReturn, greaterThan(disabledHardStop));
    final restartChannelStart = activity.indexOf(
      'foregroundRestartContractChannelName,',
    );
    final externalChannelStart = activity.indexOf(
      'foregroundExternalDataSyncChannelName,',
      restartChannelStart,
    );
    expect(restartChannelStart, isNonNegative);
    expect(externalChannelStart, greaterThan(restartChannelStart));
    expect(
      activity.substring(restartChannelStart, externalChannelStart),
      isNot(contains('call.argument<Boolean>("enabled")')),
    );

    expect(listener, contains('_voiceServiceTypes(prefs)'));
    expect(listener, contains('_readAloudServiceTypes(prefs)'));
    expect(listener, contains('_persistDurableRestartContract(prefs)'));
  });

  test('Android 15+ isolates external dataSync from permanent messaging', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final service = File(
      'android/app/src/main/kotlin/com/hermesagent/hermes_android/'
      'HermesExternalDataSyncService.kt',
    ).readAsStringSync();
    final activity = File(
      'android/app/src/main/kotlin/com/hermesagent/hermes_android/'
      'MainActivity.kt',
    ).readAsStringSync();
    final listener = File(
      'lib/core/services/notifications/background_listener.dart',
    ).readAsStringSync();

    expect(manifest, contains('android:name=".HermesExternalDataSyncService"'));
    expect(service, contains('FOREGROUND_SERVICE_TYPE_DATA_SYNC'));
    expect(service, contains('START_NOT_STICKY'));
    expect(service, contains('external_data_sync_stop'));
    expect(service, contains('.addAction('));
    expect(activity, contains('foregroundExternalDataSyncChannelName'));
    expect(activity, contains('stopRequested'));
    expect(activity, contains('hardStopRuntimeService'));
    expect(listener, contains("'hermes/foreground_external_data_sync'"));
    final main = File('lib/main.dart').readAsStringSync();
    expect(main, contains('widget.sftpTransfers.cancelAll()'));
    expect(main, contains('widget.sshSessions.closeAll()'));
  });

  test('dataSync timeout durably cancels SSH and SFTP owners', () {
    final service = File(
      'android/app/src/main/kotlin/com/hermesagent/hermes_android/'
      'HermesExternalDataSyncService.kt',
    ).readAsStringSync();
    final activity = File(
      'android/app/src/main/kotlin/com/hermesagent/hermes_android/'
      'MainActivity.kt',
    ).readAsStringSync();
    final main = File('lib/main.dart').readAsStringSync();

    for (final signature in const [
      'override fun onTimeout(startId: Int)',
      'override fun onTimeout(startId: Int, fgsType: Int)',
    ]) {
      final start = service.indexOf(signature);
      final end = service.indexOf('\n    }', start);
      expect(start, isNonNegative);
      expect(end, greaterThan(start));
      final block = service.substring(start, end);
      final request = block.indexOf('requestOwnerStop(this)');
      final stop = block.indexOf('stopNow()');
      expect(request, isNonNegative, reason: signature);
      expect(stop, greaterThan(request), reason: signature);
    }
    expect(service, contains('.commit()'));
    expect(service, contains('sendBroadcast('));
    expect(activity, contains('ACTION_OWNER_STOP_REQUIRED'));
    expect(activity, contains('acknowledgeStopRequested'));
    expect(main, contains("'acknowledgeStopRequested'"));
  });

  test('delivered dataSync Stop is acknowledged only after Dart succeeds', () {
    final activity = File(
      'android/app/src/main/kotlin/com/hermesagent/hermes_android/'
      'MainActivity.kt',
    ).readAsStringSync();
    final deliveryStart = activity.indexOf(
      'private fun deliverExternalDataSyncStop()',
    );
    final nextMethod = activity.indexOf(
      'override fun onTrimMemory',
      deliveryStart,
    );
    expect(deliveryStart, isNonNegative);
    expect(nextMethod, greaterThan(deliveryStart));
    final delivery = activity.substring(deliveryStart, nextMethod);

    expect(delivery, contains('object : MethodChannel.Result'));
    final success = delivery.indexOf('override fun success(');
    final clearPending = delivery.indexOf(
      'pendingExternalDataSyncStop = false',
      success,
    );
    final acknowledge = delivery.indexOf(
      'HermesExternalDataSyncService.acknowledgeOwnerStop(',
      success,
    );
    expect(success, isNonNegative);
    expect(clearPending, greaterThan(success));
    expect(acknowledge, greaterThan(clearPending));

    final error = delivery.indexOf('override fun error(');
    final notImplemented = delivery.indexOf('override fun notImplemented()');
    expect(error, greaterThan(acknowledge));
    expect(notImplemented, greaterThan(error));
    expect(delivery.substring(error), isNot(contains('acknowledgeOwnerStop(')));

    final main = File('lib/main.dart').readAsStringSync();
    expect(
      main,
      contains('await _externalDataSyncDemandGate.confirmReleased()'),
    );
    expect(
      main,
      contains('final released = await _stopExternalDataSyncOwners()'),
    );
  });

  test('network Stop uses a native hard gate, not plugin action state', () {
    final receiver = File(
      'android/app/src/main/kotlin/com/hermesagent/hermes_android/'
      'HermesAutomationRebootReceiver.kt',
    ).readAsStringSync();
    final listener = File(
      'lib/core/services/notifications/background_listener.dart',
    ).readAsStringSync();

    expect(receiver, contains('COMPONENT_ENABLED_STATE_DISABLED'));
    expect(receiver, contains('context.stopService'));
    expect(listener, contains("'hardStopRuntimeService'"));
    expect(listener, contains("'prepareRuntimeService'"));
  });

  test('generic dataSync Stop cancels owners through the main isolate', () {
    final listener = File(
      'lib/core/services/notifications/background_listener.dart',
    ).readAsStringSync();
    final main = File('lib/main.dart').readAsStringSync();

    expect(listener, contains('foregroundStopActionEnvelope'));
    expect(listener, contains('foregroundStopRequestedFromData'));
    expect(main, contains('foregroundStopRequestedFromData(data)'));
    expect(main, contains('_stopExternalDataSyncOwners()'));
    expect(main, contains('BackgroundListener.stopAutomation()'));
  });

  test('delayed network Stop revalidates every newer foreground owner', () {
    final listener = File(
      'lib/core/services/notifications/background_listener.dart',
    ).readAsStringSync();
    final buttonStart = listener.indexOf(
      'void onNotificationButtonPressed(String id)',
    );
    final buttonEnd = listener.indexOf(
      'void onNotificationPressed()',
      buttonStart,
    );
    expect(buttonStart, isNonNegative);
    expect(buttonEnd, greaterThan(buttonStart));
    final block = listener.substring(buttonStart, buttonEnd);
    final delay = block.indexOf('terminalActionDeliveryGrace');
    final fallbackStop = block.indexOf(
      'FlutterForegroundTask.stopService()',
      delay,
    );
    expect(delay, isNonNegative);
    expect(fallbackStop, greaterThan(delay));
    final revalidation = block.substring(delay, fallbackStop);
    expect(revalidation, contains('prefs.reload()'));
    expect(revalidation, contains('voiceCardActiveKey'));
    expect(revalidation, contains('externalDataSyncDemandKey'));
    expect(revalidation, contains('prefKey'));
  });

  test(
    'Ollama progress never mutates or stops the shared foreground service',
    () {
      final screen = File(
        'lib/core/screens/onboarding/local_install_screen.dart',
      ).readAsStringSync();
      final start = screen.indexOf('class _OllamaInstallNotif');
      expect(start, isNonNegative);
      final block = screen.substring(start);

      expect(block, contains('operationProgress('));
      expect(block, contains('cancelOperation('));
      expect(block, isNot(contains('FlutterForegroundTask.')));
      expect(block, isNot(contains('BackgroundListener.stop()')));
    },
  );

  test('notification updates re-sanitize the durable restart contract', () {
    final listener = File(
      'lib/core/services/notifications/background_listener.dart',
    ).readAsStringSync();

    for (final boundaries in const <(String, String)>[
      (
        'static Future<void> _updateTextSerialized(',
        'static Future<bool> isEnabled()',
      ),
      (
        'static Future<void> _updateReadAloudNotificationSerialized({',
        '/// Proyecta Voz',
      ),
      (
        'static Future<void> _updateVoiceNotificationSerialized({',
        '/// Vuelve al tipo de red exacto',
      ),
    ]) {
      final start = listener.indexOf(boundaries.$1);
      final end = listener.indexOf(boundaries.$2, start + boundaries.$1.length);
      expect(start, isNonNegative, reason: boundaries.$1);
      expect(end, greaterThan(start), reason: boundaries.$1);
      final block = listener.substring(start, end);
      final update = block.indexOf('FlutterForegroundTask.updateService(');
      final sanitize = block.indexOf('_persistDurableRestartContract(prefs)');
      expect(update, isNonNegative, reason: boundaries.$1);
      expect(sanitize, greaterThan(update), reason: boundaries.$1);
    }
  });

  test('disabling automation is one serialized foreground mutation', () {
    final listener = File(
      'lib/core/services/notifications/background_listener.dart',
    ).readAsStringSync();
    final start = listener.indexOf('static Future<void> stopAutomation()');
    final end = listener.indexOf(
      '/// Reconciliación idempotente de la demanda agregada',
      start,
    );
    expect(start, isNonNegative);
    expect(end, greaterThan(start));
    expect(
      listener.substring(start, end),
      contains('_foregroundMutations.run'),
    );
  });

  test(
    'API 35 Stop removes Flutter messaging while native dataSync remains',
    () {
      final flutterTypes = BackgroundListener.networkServiceTypesForTest(
        automation: false,
        externalDataSync: true,
        androidSdkInt: 35,
      );
      expect(flutterTypes, isEmpty);
      expect(
        resolveForegroundNetworkReconcileAction(
          audioOwner: false,
          flutterNetworkDemand: flutterTypes.isNotEmpty,
          serviceRunning: true,
        ),
        ForegroundNetworkReconcileAction.stop,
      );
    },
  );

  test('automation adapter does not refactor voice read aloud SSH or SFTP', () {
    final listener = File(
      'lib/core/services/notifications/background_listener.dart',
    ).readAsStringSync();
    final main = File('lib/main.dart').readAsStringSync();
    final ssh = File(
      'lib/core/services/ssh_session_service.dart',
    ).readAsStringSync();
    final sftp = File(
      'lib/core/services/sftp_transfer_service.dart',
    ).readAsStringSync();

    expect(listener, isNot(contains("import 'foreground_service_lease.dart'")));
    expect(listener, isNot(contains('ForegroundOwnerLease')));
    expect(listener, isNot(contains('_foregroundLeases')));
    expect(listener, contains('serviceTypes: await _voiceServiceTypes(prefs)'));
    expect(
      listener,
      contains('serviceTypes: await _readAloudServiceTypes(prefs)'),
    );

    for (final source in <String>[ssh, sftp]) {
      expect(source, isNot(contains('ForegroundOwnerLease')));
      expect(source, contains('VoidCallback? onNeedForeground'));
      expect(source, contains('VoidCallback? onMaybeRelease'));
    }
    expect(main, contains('widget.sftpTransfers.onNeedForeground'));
    expect(main, contains('widget.sshSessions.onNeedForeground'));
  });

  test(
    'audio release restores persistent network even if Android killed FGS',
    () {
      final listener = File(
        'lib/core/services/notifications/background_listener.dart',
      ).readAsStringSync();

      for (final boundaries in const <(String, String)>[
        (
          'static Future<void> downgradeFromVoice()',
          'static Future<void> downgradeFromReadAloud()',
        ),
        (
          'static Future<void> downgradeFromReadAloud()',
          'static Future<bool> stop()',
        ),
      ]) {
        final start = listener.indexOf(boundaries.$1);
        final end = listener.indexOf(
          boundaries.$2,
          start + boundaries.$1.length,
        );
        expect(start, isNonNegative);
        expect(end, greaterThan(start));
        final block = listener.substring(start, end);

        expect(block, contains('if (_networkDemand(prefs))'));
        expect(block, contains('await start();'));
        expect(
          block,
          isNot(
            contains(
              'if (!await FlutterForegroundTask.isRunningService) return;',
            ),
          ),
          reason:
              'si Android ya eliminó el FGS de audio, el opt-in de escucha '
              'todavía debe reconstruir remoteMessaging',
        );
      }

      final releaseStart = listener.indexOf(
        'static Future<void> _reconcileAfterDataSyncRelease(',
      );
      final releaseEnd = listener.indexOf(
        'static Future<int> _androidSdkInt()',
        releaseStart,
      );
      expect(releaseStart, isNonNegative);
      expect(releaseEnd, greaterThan(releaseStart));
      final releaseBlock = listener.substring(releaseStart, releaseEnd);
      expect(releaseBlock, contains('await start();'));
      expect(
        releaseBlock,
        isNot(contains('if (_voiceTypeSaved || _readAloudTypeSaved) return;')),
      );
    },
  );

  test(
    'audio prepare failure clears the durable card and restores network',
    () {
      final listener = File(
        'lib/core/services/notifications/background_listener.dart',
      ).readAsStringSync();
      final helperStart = listener.indexOf(
        'Future<void> _recoverNetworkAfterAudioStartFailure(',
      );
      final voiceStart = listener.indexOf(
        'Future<bool> _startForVoiceSerialized()',
      );
      final readAloudStart = listener.indexOf(
        'Future<bool> _startForReadAloudSerialized(',
      );
      final nextReadAloudMethod = listener.indexOf(
        'Future<void> _updateReadAloudNotificationSerialized(',
        readAloudStart,
      );
      expect(helperStart, isNonNegative);
      expect(voiceStart, isNonNegative);
      expect(readAloudStart, greaterThan(voiceStart));
      expect(nextReadAloudMethod, greaterThan(readAloudStart));

      final helper = listener.substring(
        helperStart,
        listener.indexOf('\n  static ', helperStart + 1),
      );
      expect(helper, contains('setBool(voiceCardActiveKey, false)'));
      expect(helper, contains('_voiceTypeSaved = false'));
      expect(helper, contains('_readAloudTypeSaved = false'));
      expect(helper, contains('if (_networkDemand(prefs))'));
      expect(helper, contains('await start()'));

      for (final block in <String>[
        listener.substring(voiceStart, readAloudStart),
        listener.substring(readAloudStart, nextReadAloudMethod),
      ]) {
        final prepare = block.indexOf('await _prepareFlutterRuntimeService()');
        final recover = block.indexOf(
          'await _recoverNetworkAfterAudioStartFailure(',
        );
        expect(prepare, isNonNegative);
        expect(recover, greaterThan(prepare));
      }
    },
  );

  test('background polling logs never expose run IDs, URLs, or raw errors', () {
    final listener = File(
      'lib/core/services/notifications/background_listener.dart',
    ).readAsStringSync();

    expect(
      listener,
      isNot(contains("debugPrint('[hermes-notif] poll run \${r.runId}")),
    );
    expect(
      listener,
      isNot(contains("debugPrint('[hermes-notif] run \${r.runId}")),
    );
    expect(listener, isNot(contains("se continúa sin propagar): \$e")));
  });

  test(
    'cron polling versions one cursor per job and suppresses no-op polls',
    () {
      final listener = File(
        'lib/core/services/notifications/background_listener.dart',
      ).readAsStringSync();
      final start = listener.indexOf('Future<bool> _discoverCronRuns(');
      final end = listener.indexOf(
        'Future<bool> _discoverKanbanTransitions(',
        start,
      );
      expect(start, isNonNegative);
      expect(end, greaterThan(start));
      final block = listener.substring(start, end);

      expect(block, contains('discoveryCursorForExecution'));
      expect(block, contains('suppressEventsWhenVersionUnchanged: true'));
      expect(block, isNot(contains('final grouped =')));
    },
  );
}
