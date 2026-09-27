import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('shortcut and widget use collision-free secret-free native actions', () {
    const action = 'dev.xpetalab.hermesconsole.action.NEW_SESSION';
    final shortcut = File(
      'android/app/src/main/res/xml/shortcuts.xml',
    ).readAsStringSync();
    final contract = File(
      'android/app/src/main/kotlin/com/hermesagent/hermes_android/'
      'NewSessionLaunchContract.kt',
    ).readAsStringSync();
    final provider = File(
      'android/app/src/main/kotlin/com/hermesagent/hermes_android/'
      'NewSessionWidgetProvider.kt',
    ).readAsStringSync();
    final glance = File(
      'android/app/src/main/kotlin/com/hermesagent/hermes_android/'
      'HermesBotModeWidgets.kt',
    ).readAsStringSync();

    expect(shortcut, contains(action));
    expect(contract, contains(action));
    expect(provider, contains('HomeWidgetGlanceWidgetReceiver'));
    expect(glance, contains('NewSessionLaunchContract.newIntent'));
    expect(glance, contains('SOURCE_WIDGET'));
    expect(contract, contains('EXTRA_TARGET'));
    for (final actionName in [
      'ACTION_NEW_SESSION',
      'ACTION_NEW_SESSION_CAMERA',
      'ACTION_NEW_SESSION_GALLERY',
      'ACTION_NEW_SESSION_VOICE',
      'ACTION_OPEN_APP',
      'ACTION_OPEN_SESSION',
      'ACTION_OPEN_SETUP',
    ]) {
      expect(contract, contains('const val $actionName'));
    }
    final nativeActions = RegExp(
      r'const val ACTION_[A-Z_]+ = "([^"]+)"',
    ).allMatches(contract).map((match) => match.group(1)).whereType<String>();
    expect(nativeActions.toSet(), hasLength(nativeActions.length));
    expect(contract, contains('action = actionFor(kind, target)'));
    expect(contract, contains('.appendPath(kind.wireValue)'));
    expect(contract, contains('appendPath(target.wireValue)'));
    expect(contract, contains('matchesLaunchUri('));
    expect(contract, contains('.scheme("hermes-console-widget")'));
    expect(contract, contains('intent.data = null'));
    for (final target in ['COMPOSER', 'CAMERA', 'GALLERY', 'VOICE']) {
      expect(contract, contains(target));
    }
    expect(glance, contains('NewSessionLaunchTarget.COMPOSER'));
    expect(glance, contains('NewSessionLaunchTarget.VOICE'));
    expect(glance, contains('openActivityIntent'));

    final nativeSurface = '$shortcut\n$contract\n$provider\n$glance'
        .toLowerCase();
    expect(nativeSurface, isNot(contains('api_key')));
    expect(nativeSurface, isNot(contains('bearer')));
    expect(nativeSurface, isNot(contains('gateway_url')));
    expect(nativeSurface, isNot(contains('prompt_text')));
  });

  test('widget routes are neutralized before Flutter sees the intent', () {
    final activity = File(
      'android/app/src/main/kotlin/com/hermesagent/hermes_android/'
      'MainActivity.kt',
    ).readAsStringSync();
    final onCreate = activity.substring(
      activity.indexOf('override fun onCreate'),
      activity.indexOf('override fun onNewIntent'),
    );
    final onNewIntent = activity.substring(
      activity.indexOf('override fun onNewIntent'),
      activity.indexOf('override fun configureFlutterEngine'),
    );

    void expectConsumedBeforeSuper(String body, String superCall) {
      final parse = body.indexOf('NewSessionLaunchContract.parse(intent)');
      final neutralize = body.indexOf(
        'NewSessionLaunchContract.neutralize(intent)',
      );
      final delegate = body.indexOf(superCall);

      expect(parse, greaterThanOrEqualTo(0));
      expect(neutralize, greaterThan(parse));
      expect(delegate, greaterThan(neutralize));
    }

    expectConsumedBeforeSuper(onCreate, 'super.onCreate(savedInstanceState)');
    expectConsumedBeforeSuper(onNewIntent, 'super.onNewIntent(intent)');
  });

  test('Bot Mode widget family replaces the old variants in place', () {
    String read(String path) => File(path).readAsStringSync();
    const kt = 'android/app/src/main/kotlin/com/hermesagent/hermes_android/';
    final provider = read('${kt}NewSessionWidgetProvider.kt');
    final glance = read('${kt}HermesBotModeWidgets.kt');
    final state = read('${kt}BotModeWidgetState.kt');
    final expiryWorker = read('${kt}HermesWidgetExpiryWorker.kt');
    final manifest = read('android/app/src/main/AndroidManifest.xml');
    final publisher = read('lib/core/services/home_widget_publisher.dart');
    final background = read(
      'lib/core/services/notifications/bot_mode_background.dart',
    );

    // Legacy receiver names survive so placed widgets migrate, not vanish.
    expect(provider, contains('class NewSessionWidgetProvider'));
    expect(provider, contains('class HermesCompactWidgetProvider'));
    expect(provider, contains('class HermesControlWidgetProvider'));
    expect(provider, contains('BotModeWidgetKind.BOTS'));
    expect(provider, contains('BotModeWidgetKind.STATUS'));
    expect(provider, contains('BotModeWidgetKind.QUICK_ASK'));
    expect(glance, contains('class HermesNeedsYouWidgetProvider'));
    expect(glance, contains('class HermesRoomWidgetProvider'));
    for (final receiver in [
      '.NewSessionWidgetProvider',
      '.HermesCompactWidgetProvider',
      '.HermesControlWidgetProvider',
      '.HermesNeedsYouWidgetProvider',
      '.HermesRoomWidgetProvider',
      '.HermesNotificationActionReceiver',
    ]) {
      expect(manifest, contains(receiver));
    }
    for (final name in [
      'HermesNeedsYouWidgetProvider',
      'HermesRoomWidgetProvider',
      'HermesCompactWidgetProvider',
    ]) {
      expect(publisher, contains(name));
      expect(background, contains(name));
    }

    expect(glance, contains('SizeMode.Responsive'));
    expect(glance, contains('system_app_widget_background_radius'));
    expect(glance, contains('appWidgetBackground()'));
    expect(glance, isNot(contains('RemoteViews')));
    expect(
      glance,
      isNot(contains('WorkManager.getInstance(context).enqueue(\n')),
    );
    // Widget actions go through the same inbox as notification actions.
    expect(glance, contains('actionSendBroadcast'));
    expect(glance, contains('"widget"'));
    expect(state, contains('fun trusted(nowMs: Long)'));
    expect(state, contains('BOT_MODE_STALE_AFTER_MS'));
    expect(expiryWorker, contains('botModeWidgetReceivers()'));
    expect(expiryWorker, isNot(contains('PeriodicWorkRequest')));

    for (final info in [
      'new_session_widget_info',
      'hermes_widget_compact_info',
      'hermes_widget_control_info',
      'botw_needs_you_info',
      'botw_room_info',
    ]) {
      final xml = read('android/app/src/main/res/xml/$info.xml');
      expect(xml, contains('android:updatePeriodMillis="0"'));
      // Informational widgets may live on the lock screen; widgets with
      // Approve / Deny / Stop or conversation text are home-screen only.
      const informational = {
        'hermes_widget_compact_info',
        'hermes_widget_control_info',
      };
      expect(
        xml,
        contains(
          informational.contains(info)
              ? 'android:widgetCategory="home_screen|keyguard"'
              : 'android:widgetCategory="home_screen"',
        ),
      );
      expect(xml, contains('android:previewLayout="@layout/botw_preview_'));
      expect(
        xml,
        contains('android:previewImage="@drawable/botw_preview_image"'),
      );
    }
    // Picker previews mirror the dark, face-based Glance widgets and only use
    // RemoteViews-safe views.
    const allowedViews = {
      'LinearLayout',
      'FrameLayout',
      'ImageView',
      'TextView',
    };
    for (final name in ['bots', 'needs_you', 'room', 'quick_ask', 'status']) {
      final layout = read(
        'android/app/src/main/res/layout/botw_preview_$name.xml',
      );
      expect(
        layout,
        contains('@drawable/botw_preview_background'),
        reason: name,
      );
      expect(layout, contains('@color/botw_preview_'), reason: name);
      expect(layout, isNot(contains('new_session_widget_')), reason: name);
      final tags = RegExp(r'<([A-Za-z.]+)[\s>]')
          .allMatches(layout)
          .map((m) => m.group(1)!)
          .where((t) => t != '?xml')
          .toSet();
      expect(
        allowedViews.containsAll(tags),
        isTrue,
        reason: '$name uses $tags',
      );
      if (name != 'status') {
        expect(layout, contains('@drawable/botw_preview_face_'), reason: name);
      }
    }
    expect(
      read('android/app/src/main/res/layout/botw_preview_needs_you.xml'),
      allOf(contains('@string/botw_approve'), contains('@string/botw_deny')),
    );
    expect(
      read('android/app/src/main/res/values-v31/bot_mode_widget_preview.xml'),
      contains('@android:dimen/system_app_widget_background_radius'),
    );
    expect(
      read('android/app/src/main/res/values/bot_mode_widget_preview.xml'),
      contains('<color name="botw_preview_surface">#FF1A191D</color>'),
    );
    for (final locale in ['values', 'values-es']) {
      final strings = read(
        'android/app/src/main/res/$locale/bot_mode_widgets.xml',
      );
      for (final key in [
        'botw_preview_working',
        'botw_preview_working_count',
        'botw_preview_approval',
        'botw_preview_room_name',
        'botw_preview_room_line',
        'botw_preview_ask',
        'botw_preview_status',
        'botw_preview_status_line',
      ]) {
        expect(strings, contains('name="$key"'), reason: '$locale/$key');
      }
    }
    expect(
      read('android/app/src/main/res/xml/new_session_widget_info.xml'),
      contains('android:minResizeHeight="110dp"'),
    );
  });

  test('widget has localized Material You and OLED-safe resources', () {
    final strings = File(
      'android/app/src/main/res/values/new_session_widget.xml',
    ).readAsStringSync();
    final spanish = File(
      'android/app/src/main/res/values-es/new_session_widget.xml',
    ).readAsStringSync();
    final dynamic = File(
      'android/app/src/main/res/values-v31/new_session_widget.xml',
    ).readAsStringSync();
    final dynamicNight = File(
      'android/app/src/main/res/values-night-v31/new_session_widget.xml',
    ).readAsStringSync();
    final background = File(
      'android/app/src/main/res/drawable/new_session_widget_background.xml',
    ).readAsStringSync();

    expect(strings, contains('name="new_session_widget_action"'));
    expect(spanish, contains('Nueva conversación'));
    expect(strings, contains('name="hermes_widget_session"'));
    expect(spanish, contains('name="hermes_widget_session"'));
    expect(strings, contains('name="hermes_widget_instance"'));
    expect(spanish, contains('name="hermes_widget_instance"'));
    expect(spanish, contains('>Instancia</string>'));
    expect(strings, contains('name="hermes_widget_agent"'));
    expect(spanish, contains('name="hermes_widget_agent"'));
    expect(strings, contains('name="hermes_widget_compact_name"'));
    expect(strings, contains('name="hermes_widget_control_name"'));
    expect(strings, contains('name="hermes_widget_dashboard_name"'));
    expect(spanish, contains('Hermes · Compacto'));
    expect(spanish, contains('Hermes · Controles'));
    expect(spanish, contains('Hermes · Panel'));
    expect(strings, contains('name="new_session_widget_composer_hint"'));
    expect(spanish, contains('Escribe a Hermes'));
    expect(dynamic, contains('@android:color/system_neutral1_50'));
    expect(dynamic, contains('@android:color/system_accent1_700'));
    expect(dynamicNight, contains('@android:color/black'));
    expect(dynamicNight, contains('@android:color/system_accent1_200'));
    expect(
      dynamic,
      contains('@android:dimen/system_app_widget_background_radius'),
    );
    expect(background, contains('@dimen/new_session_widget_corner_radius'));
  });
}
