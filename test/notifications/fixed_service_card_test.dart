// The fixed card Android demands while Console stays connected with the app
// closed: one calm line and the direct Stop the Play declaration describes,
// posted when it changes and never on a timer, a plain silent row (not a
// conversation), with a Settings row that opens its Android category so it
// can be minimised.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/notifications/background_listener.dart';
import 'package:hermes_android/core/services/notifications/notification_strings.dart';
import 'package:hermes_android/core/services/notifications/rich_notifications.dart';

const es = NotifL10n(true);
const en = NotifL10n(false);

String _between(String source, String from, String to) {
  final start = source.indexOf(from);
  expect(start, isNonNegative, reason: from);
  final end = source.indexOf(to, start + from.length);
  expect(end, greaterThan(start), reason: to);
  return source.substring(start, end);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final listener = File(
    'lib/core/services/notifications/background_listener.dart',
  ).readAsStringSync();

  group('what it says', () {
    test('connected: one line, and the direct Stop', () {
      final card = BackgroundListener.networkCard(es, connected: true);
      expect(card.title, 'Conectado a Hermes');
      expect(card.text, isEmpty);
      expect([for (final b in card.buttons) b.id], ['stop']);
      expect(card.buttons.single.text, 'Detener');
      final english = BackgroundListener.networkCard(en, connected: true);
      expect(english.title, 'Connected to Hermes');
      expect(english.buttons.single.text, 'Stop');
    });

    test('a transfer the user started keeps its Stop', () {
      final card = BackgroundListener.networkCard(es, connected: false);
      expect(card.title, 'Console');
      expect(card.text, 'Activo en segundo plano');
      expect([for (final b in card.buttons) b.id], ['stop']);
      expect(card.buttons.single.text, 'Detener');
    });

    test('start and restore post that card', () {
      final start = _between(
        listener,
        'final card = networkCard(t, connected: persistentAutomation);',
        'callback: hermesForegroundCallback,',
      );
      expect(start, contains('notificationTitle: card.title'));
      expect(start, contains('notificationText: card.text'));
      expect(start, contains('notificationButtons: card.buttons'));
      final restore = _between(
        listener,
        'if (disposition == BackgroundTaskStartDisposition.restoreAutomation) {',
        '// Only the Voice / Read Aloud card is restyled',
      );
      expect(restore, contains('connected: true'));
      // The card's own buttons replace whatever a previous build left.
      expect(restore, contains('notificationButtons: card.buttons'));
    });
  });

  group('when it is posted', () {
    test('a poll never rewrites it', () {
      final poll = _between(
        listener,
        'Future<void> _poll() async {',
        '/// A-302/U-11 (spec 028)',
      );
      expect(poll, isNot(contains('notificationTitle:')));
      expect(poll, isNot(contains('notificationText:')));
      // Changing the cadence is the only service update a poll makes.
      expect(poll, isNot(contains('FlutterForegroundTask.updateService(')));
      expect(listener, isNot(contains('bgWatching')));
    });

    test('start() re-posts it only when what holds the service changed', () {
      final sync = _between(
        listener,
        'static Future<void> _syncNetworkCard(SharedPreferences prefs) async {',
        '/// True si el FGS se arrancó',
      );
      expect(
        sync.indexOf('if (_networkCardConnected == connected) return;'),
        lessThan(sync.indexOf('FlutterForegroundTask.updateService(')),
      );
      expect(
        sync.indexOf('if (_networkCardConnected == connected) return;'),
        isNonNegative,
      );
    });
  });

  group('what it is', () {
    test('a plain row: only the Voice / Read Aloud card is restyled', () {
      final calls = RegExp(
        r'_decorateServiceCard\(\)',
      ).allMatches(listener).toList();
      // Its definition plus the two audio-only call sites.
      expect(calls, hasLength(3));
      expect(
        listener,
        contains(
          'if (prefs.getBool(BackgroundListener.voiceCardActiveKey) == true) {\n'
          '      unawaited(_decorateServiceCard());',
        ),
      );
      expect(
        listener,
        contains('if (audioCardActive) unawaited(_decorateServiceCard());'),
      );
      final cadence = _between(
        listener,
        'void _setPollInterval(int ms, {required bool persistentAutomation}) {',
        'Future<void> onStart(DateTime timestamp, TaskStarter starter) async {',
      );
      expect(cadence, isNot(contains('_decorateServiceCard')));
    });
  });

  group('Stop', () {
    String block() => _between(
      listener,
      'void onNotificationButtonPressed(String id) {',
      'void onNotificationPressed() {',
    );

    // docs/PLAY_FGS_DECLARATION.md: "a persistent notification describes the
    // work and provides a direct Stop action".
    test('turns background listening off, as the Play declaration says', () {
      final stop = block().substring(
        block().indexOf("if (id != 'stop') return;"),
      );
      final off = stop.indexOf(
        'prefs.setBool(BackgroundListener.prefKey, false)',
      );
      expect(off, isNonNegative);
      // The UI hears it first (it closes real transfers), then the opt-in
      // goes, then the service stops unless a new owner appeared meanwhile.
      expect(stop.indexOf('_stopFence.requestStop();'), lessThan(off));
      expect(stop.indexOf('foregroundStopActionEnvelope()'), lessThan(off));
      expect(
        stop.indexOf('FlutterForegroundTask.stopService()'),
        greaterThan(stop.indexOf('terminalActionDeliveryGrace')),
      );
    });

    test('the declaration still promises it', () {
      final doc = File('docs/PLAY_FGS_DECLARATION.md').readAsStringSync();
      expect(doc, contains('provides a direct Stop action'));
      expect(doc, contains('a persistent notification includes a'));
    });
  });

  group('Settings', () {
    test('the row opens the Android category of the card', () async {
      const native = MethodChannel(PlatformRichNotifications.channelName);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(native, (call) async {
        calls.add(call);
        return true;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(native, null));
      expect(
        await PlatformRichNotifications().openChannelSettings(
          BackgroundListener.serviceChannelId,
        ),
        isTrue,
      );
      expect(calls.single.method, 'openChannelSettings');
      expect(calls.single.arguments, {'channel': 'hermes_service_v2'});

      final screen = File(
        'lib/core/screens/notification_settings_screen.dart',
      ).readAsStringSync();
      final row = _between(
        screen,
        "key: const ValueKey('notif-fixed-card-settings'),",
        '],',
      );
      expect(row, contains('s.notifFixedCardTitle'));
      expect(row, contains('BackgroundListener.serviceChannelId'));
      // Only while there is a card.
      expect(screen, contains('if (Platform.isAndroid && _bgRunning && on)'));
    });

    test('native side: the category screen, else the app screen', () {
      final kt = File(
        'android/app/src/main/kotlin/com/hermesagent/hermes_android/HermesRichNotifications.kt',
      ).readAsStringSync();
      final open = _between(
        kt,
        'private fun openChannelSettings(context: Context, channelId: String?): Boolean {',
        'private fun openPromotionSettings(context: Context): Boolean {',
      );
      expect(open, contains('Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS'));
      expect(open, contains('Settings.EXTRA_CHANNEL_ID'));
      expect(open, contains('getNotificationChannel(channelId) != null'));
      expect(
        open.indexOf('Settings.ACTION_APP_NOTIFICATION_SETTINGS'),
        greaterThan(
          open.indexOf('Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS'),
        ),
      );
    });
  });
}
