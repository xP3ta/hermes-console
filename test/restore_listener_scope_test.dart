// The opt-in listening of 1.3.1 is back (push is off in 1.4.0). These pin the
// boundaries it comes back with: it only exists behind the user's switch, the
// manifest and the release policy declare exactly what 1.3.1 declared, and the
// pieces added since (turn keep-alive, retired widgets, App Lock) stay intact.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/notifications/background_listener.dart';
import 'package:hermes_android/core/services/notifications/cron_notice_policy.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _kotlin = 'android/app/src/main/kotlin/com/hermesagent/hermes_android/';

void main() {
  String read(String path) => File(path).readAsStringSync();

  group('manifest and policy', () {
    final manifest = read('android/app/src/main/AndroidManifest.xml');
    final policy =
        jsonDecode(read('tool/release/full_release_policy.json'))
            as Map<String, dynamic>;

    test('the shared service declares the 1.3.1 type set', () {
      expect(
        manifest,
        contains(
          'android:foregroundServiceType="dataSync|remoteMessaging|microphone|mediaPlayback"',
        ),
      );
      expect(
        manifest,
        contains('android.permission.FOREGROUND_SERVICE_REMOTE_MESSAGING'),
      );
    });

    test('only the app\'s own receiver restores, and only the opt-in', () {
      expect(manifest, contains('.HermesAutomationRebootReceiver'));
      expect(
        manifest,
        contains(
          '<uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED" />',
        ),
      );
      expect(manifest, contains('service.RebootReceiver"\n'));
      final receiver = read('${_kotlin}HermesAutomationRebootReceiver.kt');
      expect(receiver, contains('flutter.notif_background_listen'));
      expect(receiver, contains('hardStopRuntimeService'));
    });

    test('the turn keep-alive service is still a separate dataSync one', () {
      expect(manifest, contains('.HermesTurnKeepAliveService'));
      final services = {
        for (final e in policy['foregroundServices'] as List)
          (e as Map)['name'] as String: List<String>.from(e['types'] as List),
      };
      expect(
        services['com.hermesagent.hermes_android.HermesTurnKeepAliveService'],
        ['dataSync'],
      );
      expect(
        services['com.pravera.flutter_foreground_task.service.ForegroundService'],
        ['dataSync', 'mediaPlayback', 'microphone', 'remoteMessaging'],
      );
    });

    test('the policy allows the two permissions and no longer forbids boot', () {
      final allowed = [
        for (final p in policy['permissions'] as List) (p as Map)['name'],
      ];
      expect(
        allowed,
        containsAll([
          'android.permission.FOREGROUND_SERVICE_REMOTE_MESSAGING',
          'android.permission.RECEIVE_BOOT_COMPLETED',
        ]),
      );
      expect(
        policy['forbiddenPermissions'],
        isNot(contains('android.permission.RECEIVE_BOOT_COMPLETED')),
      );
    });
  });

  group('behind the switch', () {
    final screen = read('lib/core/screens/notification_settings_screen.dart');
    final listener = read(
      'lib/core/services/notifications/background_listener.dart',
    );

    test('Settings offers the 1.3.1 switch with the same preference key', () {
      expect(screen, contains("ValueKey('notif-background-listener')"));
      expect(screen, contains('BackgroundListener.prefKey'));
      expect(screen, contains('BackgroundListener.startForAutomation()'));
      expect(listener, contains('NotificationService.backgroundListenPreferenceKey'));
      expect(
        read('lib/core/services/notifications/notification_service.dart'),
        contains("backgroundListenPreferenceKey = 'notif_background_listen'"),
      );
    });

    test('the poll does nothing without the opt-in', () {
      final poll = listener.substring(listener.indexOf('Future<void> _poll()'));
      final gate = poll.indexOf('if (!automationOptIn)');
      final discover = poll.indexOf('discoverCronRuns(');
      expect(gate, greaterThan(0));
      expect(discover, greaterThan(gate));
    });

    test('App Lock hides the content of notices posted with the app closed', () {
      expect(listener, contains("prefs.getBool('app_lock_enabled')"));
      expect(listener, contains('forceHideSensitiveContent'));
      expect(
        read('lib/core/services/notifications/notification_service.dart'),
        contains('forceHideSensitiveContent ||'),
      );
    });

    test('rooms are watched but the retired Bots/Salas widgets get nothing', () {
      final bots = read('lib/core/services/notifications/bot_mode_background.dart');
      expect(bots, contains('publish ?? _discardBotModeWidgetSnapshot'));
    });

    test('the listener never touches the turn ledger or the turn service', () {
      expect(listener, isNot(contains('LiveTurnEndLedger')));
      expect(listener, isNot(contains('HermesTurnKeepAliveService')));
    });
  });

  group('ending the listening', () {
    test('an install that never opted in is left untouched', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await BackgroundListener.recordOptOut(prefs);
      expect(prefs.containsKey(BackgroundListener.prefKey), isFalse);
      expect(CronNoticePolicy.read(prefs), CronNoticeMode.automatic);
    });

    test('opting out keeps the Cron mode of the open app', () async {
      SharedPreferences.setMockInitialValues({BackgroundListener.prefKey: true});
      final prefs = await SharedPreferences.getInstance();
      await BackgroundListener.recordOptOut(prefs);
      expect(prefs.getBool(BackgroundListener.prefKey), isFalse);
      expect(CronNoticePolicy.read(prefs), CronNoticeMode.automatic);
    });
  });
}
