// The turn keep-alive stays what it was approved as: a short dataSync
// service bounded to a running turn (Desktop «while working»), never the
// permanent listener removed on 3 Nov. These pin the manifest, the native
// service, the setting and the two hooks.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/notifications/notification_strings.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _kotlin = 'android/app/src/main/kotlin/com/hermesagent/hermes_android/';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  String read(String path) => File(path).readAsStringSync();

  /// The body of the Kotlin function declared at [signature]: up to the
  /// closing brace at the declaration's own indentation (a block body), or
  /// up to the next blank line (an expression body).
  String bodyOf(String source, String signature) {
    final at = source.indexOf(signature);
    expect(at, greaterThanOrEqualTo(0), reason: signature);
    final lineStart = source.lastIndexOf('\n', at) + 1;
    final indent = source.substring(lineStart, at).replaceAll(
      RegExp(r'[^ ]'),
      '',
    );
    // The parameter list may span lines: what follows its `)` on that line
    // says block (`{`) or expression (`=`).
    var depth = 0;
    var close = source.indexOf('(', at);
    for (; close < source.length; close++) {
      final c = source[close];
      if (c == '(') depth++;
      if (c == ')' && --depth == 0) break;
    }
    final headerEnd = source.indexOf('\n', close);
    final header = source.substring(close, headerEnd).trimRight();
    final end = header.endsWith('{')
        ? source.indexOf('\n$indent}', headerEnd)
        : source.indexOf('\n\n', headerEnd);
    expect(end, greaterThan(at), reason: signature);
    return source.substring(at, end);
  }

  group('manifest and release policy', () {
    test('one more dataSync service, removed with the task, not exported', () {
      final manifest = read('android/app/src/main/AndroidManifest.xml');
      final service = RegExp(
        r'<service\s+android:name="\.HermesTurnKeepAliveService"([^>]*)/>',
      ).firstMatch(manifest);
      expect(service, isNotNull);
      final attributes = service!.group(1)!;
      expect(attributes, contains('android:foregroundServiceType="dataSync"'));
      expect(attributes, contains('android:exported="false"'));
      expect(attributes, contains('android:stopWithTask="true"'));
      // No new permission: dataSync was already declared for SSH/SFTP.
      expect(manifest, isNot(contains('FOREGROUND_SERVICE_SPECIAL_USE')));
      expect(manifest, isNot(contains('REQUEST_IGNORE_BATTERY_OPTIMIZATIONS')));
    });

    test('the release policy lists it with dataSync only', () {
      final policy =
          jsonDecode(read('tool/release/full_release_policy.json'))
              as Map<String, dynamic>;
      final services = {
        for (final entry in policy['foregroundServices'] as List)
          (entry as Map)['name'] as String: List<String>.from(
            entry['types'] as List,
          ),
      };
      expect(
        services['com.hermesagent.hermes_android.HermesTurnKeepAliveService'],
        ['dataSync'],
      );
    });
  });

  group('native service', () {
    final service = read('${_kotlin}HermesTurnKeepAliveService.kt');
    final activity = read('${_kotlin}MainActivity.kt');

    test('never sticky, ends on the system timeout, backstop cap', () {
      expect(service, contains('START_NOT_STICKY'));
      expect(service, isNot(contains('return START_STICKY')));
      expect(service, contains('FOREGROUND_SERVICE_TYPE_DATA_SYNC'));
      expect(service, contains('override fun onTimeout(startId: Int)'));
      expect(
        service,
        contains('override fun onTimeout(startId: Int, fgsType: Int)'),
      );
      expect(service, contains('handler.postDelayed(backstop'));
    });

    test('no boot, no wakelock, no poll, no secrets in its logs', () {
      for (final forbidden in [
        'BOOT_COMPLETED',
        'WakeLock',
        'newWakeLock',
        'WorkManager',
        'AlarmManager',
        'http',
      ]) {
        expect(service, isNot(contains(forbidden)), reason: forbidden);
      }
      final logs = RegExp(r'Log\.[a-z]\(TAG, "([^"]*)"').allMatches(service);
      expect(logs, isNotEmpty);
      for (final line in logs) {
        final text = line.group(1)!;
        for (final secret in [r'$title', r'$text', 'session', 'token']) {
          expect(text, isNot(contains(secret)), reason: text);
        }
      }
    });

    test('the service card is the live row, never a second card '
        '(Pixel 9980, SC5off single_live_card)', () {
      // A group summary with one child was shown as a card of its own on
      // Android 16 (id 258 next to the row): no group, no summary.
      expect(service, isNot(contains('setGroupSummary')));
      expect(service, isNot(contains('setGroup(')));
      expect(service, isNot(contains('groupLiveRows')));
      expect(service, contains('HermesRichNotifications.CH_LIVE'));
      expect(service, contains('.setSilent(true)'));
      // A stop before the promotion is deferred, never a crash.
      expect(service, contains('stopRequested = true'));
      // The promotion shows the chat row already in the tray, at once (no
      // 10 s deferral with the row gone and the card not yet drawn).
      expect(service, contains('adoptableRow('));
      expect(service, contains('FOREGROUND_SERVICE_IMMEDIATE'));
      expect(service, contains('Build.VERSION.SDK_INT >= Build.VERSION_CODES.S'));
      final rich = read('${_kotlin}HermesRichNotifications.kt');
      expect(rich, isNot(contains('HermesTurnKeepAliveService.GROUP')));
      expect(rich, isNot(contains('setGroup(HermesTurnKeepAliveService')));
    });

    test('every post of a chat live row passes through the service card', () {
      final rich = read('${_kotlin}HermesRichNotifications.kt');
      // Both notify helpers: the plain row, the ProgressStyle row and the
      // confirmations a tap puts in its place («Enviando…» after Parar).
      for (final helper in [
        'private fun notify(',
        'private fun notifyBuilt(',
      ]) {
        final body = bodyOf(rich, helper);
        expect(
          body,
          contains('HermesTurnKeepAliveService.carry(context, tag, id,'),
          reason: helper,
        );
        // Permission first: nothing is carried that could not be posted.
        expect(
          body.indexOf('POST_NOTIFICATIONS'),
          lessThan(body.indexOf('HermesTurnKeepAliveService.carry(')),
          reason: helper,
        );
      }
    });

    test('a cancelled row leaves the service card (every cancel path)', () {
      final rich = read('${_kotlin}HermesRichNotifications.kt');
      final body = bodyOf(rich, 'private fun noteCancelled(');
      expect(body, contains('HermesTurnKeepAliveService.rowCancelled(tag, id)'));
      expect(service, contains('fun rowCancelled('));
      // The background worker cancels off the main thread.
      expect(service, contains('Looper.myLooper() != Looper.getMainLooper()'));
      expect(service, contains('@Volatile\n        var carriedTag'));
    });

    test('tray readers see the service card as the row it carries', () {
      final rich = read('${_kotlin}HermesRichNotifications.kt');
      expect(rich, contains('private fun trayAddress('));
      for (final reader in [
        'fun liveTurnRows(',
        'private fun cancelOrphanedLiveRows(',
      ]) {
        expect(bodyOf(rich, reader), contains('trayAddress('), reason: reader);
      }
      expect(
        bodyOf(rich, 'private fun isActive('),
        contains('HermesTurnKeepAliveService.carries(tag, id)'),
      );
    });

    test('the activity exposes the channel and releases it with the engine', () {
      expect(activity, contains('"hermes/turn_keepalive"'));
      expect(activity, contains('HermesTurnKeepAliveService.start('));
      expect(activity, contains('HermesTurnKeepAliveService.stop('));
      expect(activity, contains('HermesTurnKeepAliveService.onEnded = null'));
    });
  });

  group('hooks', () {
    test('ActiveChat re-arms its park while the hold is on (one place)', () {
      final chat = read('lib/core/services/active_chat_service.dart');
      expect('TurnKeepAliveHold.held'.allMatches(chat), hasLength(1));
      expect(chat, contains('Timer(chatTransportBackgroundGrace, parkAfterGrace)'));
    });

    test('the app idle timer re-arms while the hold is on', () {
      final main = read('lib/main.dart');
      expect(main, contains('if (TurnKeepAliveHold.held) {'));
      expect(main, contains('_turnKeepAlive?.lifecycleChanged(state)'));
      expect(main, contains('liveTurnAppLocked(prefs)'));
    });
  });

  group('stop order', () {
    test('the stop does not re-file a row Dart just cancelled', () {
      final service = read('${_kotlin}HermesTurnKeepAliveService.kt');
      final rich = read('${_kotlin}HermesRichNotifications.kt');
      expect(
        service,
        contains('HermesRichNotifications.cancelledRecently(tag, LIVE_ROW_ID)'),
      );
      expect(rich, contains('fun cancelledRecently('));
      // The cancel handler notes the row; a fresh post clears the mark.
      final cancel = rich.indexOf('"cancel" -> {');
      expect(rich.indexOf('noteCancelled(', cancel), greaterThan(cancel));
      expect(rich, contains('recentCancels.remove(rowKey)'));
    });

    test('the carried row goes back under its tag BEFORE the card goes, '
        'and the card goes at once (no 500 ms overlap)', () {
      final service = read('${_kotlin}HermesTurnKeepAliveService.kt');
      expect(service, isNot(contains('UNGROUP_SETTLE_MS')));
      for (final path in [
        'fun stop(context: Context)',
        'private fun endFromNative(',
        'override fun onDestroy()',
        'private fun stopNow()',
      ]) {
        final body = bodyOf(service, path);
        final back = body.indexOf('putBackCarriedRow(');
        expect(back, greaterThan(0), reason: path);
        final gone = [
          'stopService(',
          'stopForeground(',
          'stopForegroundCompat(',
        ].map(body.indexOf).where((i) => i >= 0);
        expect(gone, isNotEmpty, reason: path);
        for (final i in gone) {
          expect(back, lessThan(i), reason: path);
        }
      }
    });

    test('the controller sends a stop at once when nothing is queued', () {
      final dart = read(
        'lib/core/services/turn_keepalive_controller.dart',
      );
      expect(dart, contains('if (_queued == 0)'));
    });
  });

  group('setting', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('on by default and never written until the user moves it', () async {
      final prefs = await SharedPreferences.getInstance();
      final service = NotificationService(prefs);
      expect(service.keepAliveWhileWorking, isTrue);
      expect(prefs.getKeys(), isEmpty);
      var changed = 0;
      service.onKeepAliveChanged = () => changed++;
      await service.setKeepAliveWhileWorking(false);
      expect(service.keepAliveWhileWorking, isFalse);
      expect(changed, 1);
      expect(prefs.getKeys(), {'notif_keepalive_while_working'});
    });

    test('the service card names no chat, in every language', () async {
      final prefs = await SharedPreferences.getInstance();
      final copy = NotificationService(prefs).keepAliveNoticeCopy();
      expect(copy.title, isNotEmpty);
      expect(copy.text, isNotEmpty);
      for (final entry in notificationCatalogs.entries) {
        expect(entry.value['keepAliveTitle'], isNotEmpty, reason: entry.key);
        expect(entry.value['keepAliveText'], isNotEmpty, reason: entry.key);
      }
    });

    test('the switch has its copy in the nine catalogs and on the screen', () {
      for (final arb in Directory('lib/l10n')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.arb'))) {
        final keys = (jsonDecode(arb.readAsStringSync()) as Map).keys.toSet();
        expect(keys, containsAll(['notifKeepAliveTitle', 'notifKeepAliveSub']),
            reason: arb.path);
      }
      final screen = read('lib/core/screens/notification_settings_screen.dart');
      expect(screen, contains('notif-keepalive-while-working'));
      expect(screen, contains('notif.setKeepAliveWhileWorking(v)'));
    });
  });
}
