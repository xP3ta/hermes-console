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

  test('original Hermes Console widgets are kept unchanged', () {
    String read(String path) => File(path).readAsStringSync();
    const kt = 'android/app/src/main/kotlin/com/hermesagent/hermes_android/';
    final provider = read('${kt}NewSessionWidgetProvider.kt');
    final original = read('${kt}HermesConsoleGlanceWidget.kt');
    final expiryWorker = read('${kt}HermesWidgetExpiryWorker.kt');
    final manifest = read('android/app/src/main/AndroidManifest.xml');
    final publisher = read('lib/core/services/home_widget_publisher.dart');
    final background = read(
      'lib/core/services/notifications/bot_mode_background.dart',
    );

    // Widgets placed from 1.2.13 keep the same receiver, look and behaviour.
    expect(
      provider,
      contains('HermesConsoleGlanceWidget(HermesWidgetVariant.DASHBOARD)'),
    );
    expect(
      provider,
      contains('HermesConsoleGlanceWidget(HermesWidgetVariant.COMPACT)'),
    );
    expect(
      provider,
      contains('HermesConsoleGlanceWidget(HermesWidgetVariant.CONTROL)'),
    );
    expect(provider, isNot(contains('BotModeWidgetKind')));
    expect(original, contains('enum class HermesWidgetVariant'));
    expect(original, contains('HermesWidgetExpiryScheduler.replace'));

    String receiverBlock(String name) {
      final start = manifest.indexOf('android:name="$name"');
      expect(start, greaterThanOrEqualTo(0), reason: name);
      return manifest.substring(start, manifest.indexOf('</receiver>', start));
    }

    const originals = {
      '.NewSessionWidgetProvider': [
        'hermes_widget_dashboard_name',
        'new_session_widget_info',
      ],
      '.HermesCompactWidgetProvider': [
        'hermes_widget_compact_name',
        'hermes_widget_compact_info',
      ],
      '.HermesControlWidgetProvider': [
        'hermes_widget_control_name',
        'hermes_widget_control_info',
      ],
    };
    originals.forEach((receiver, res) {
      final block = receiverBlock(receiver);
      expect(block, contains('android:label="@string/${res[0]}"'));
      expect(block, contains('android:resource="@xml/${res[1]}"'));
    });
    final dashboardInfo = read(
      'android/app/src/main/res/xml/new_session_widget_info.xml',
    );
    final compactInfo = read(
      'android/app/src/main/res/xml/hermes_widget_compact_info.xml',
    );
    final controlInfo = read(
      'android/app/src/main/res/xml/hermes_widget_control_info.xml',
    );
    expect(
      dashboardInfo,
      contains(
        'android:previewLayout="@layout/hermes_widget_dashboard_preview"',
      ),
    );
    expect(dashboardInfo, contains('android:targetCellWidth="4"'));
    expect(
      compactInfo,
      contains('android:previewLayout="@layout/hermes_widget_compact_preview"'),
    );
    expect(
      controlInfo,
      contains('android:previewLayout="@layout/new_session_widget_large"'),
    );
    for (final info in [dashboardInfo, compactInfo, controlInfo]) {
      expect(info, isNot(contains('botw_')));
      expect(info, contains('android:widgetCategory="home_screen"'));
    }
    for (final layout in [
      'hermes_widget_compact_preview',
      'hermes_widget_dashboard_preview',
      'new_session_widget',
      'new_session_widget_large',
      'new_session_widget_wide',
    ]) {
      expect(
        File('android/app/src/main/res/layout/$layout.xml').existsSync(),
        isTrue,
        reason: layout,
      );
    }
    // The original publisher keeps refreshing the original receivers; the
    // Bot Mode listener only drives the Bot Mode receivers.
    for (final name in [
      'NewSessionWidgetProvider',
      'HermesCompactWidgetProvider',
      'HermesControlWidgetProvider',
    ]) {
      expect(publisher, contains("hermes_android.$name'"));
      expect(background, isNot(contains("hermes_android.$name'")));
    }
    // The expiry worker redraws both families.
    expect(expiryWorker, contains('originalWidgetReceivers()'));
    expect(expiryWorker, contains('botModeWidgetReceivers()'));
    expect(expiryWorker, contains('NewSessionWidgetProvider::class.java'));
    expect(expiryWorker, contains('HermesCompactWidgetProvider::class.java'));
    expect(expiryWorker, contains('HermesControlWidgetProvider::class.java'));
  });

  test('Bot Mode widget family ships as new widgets', () {
    String read(String path) => File(path).readAsStringSync();
    const kt = 'android/app/src/main/kotlin/com/hermesagent/hermes_android/';
    final glance = read('${kt}HermesBotModeWidgets.kt');
    final state = read('${kt}BotModeWidgetState.kt');
    final expiryWorker = read('${kt}HermesWidgetExpiryWorker.kt');
    final manifest = read('android/app/src/main/AndroidManifest.xml');
    final publisher = read('lib/core/services/home_widget_publisher.dart');
    final background = read(
      'lib/core/services/notifications/bot_mode_background.dart',
    );

    const botMode = {
      'HermesBotsWidgetProvider': ['botw_bots_name', 'botw_bots_info', 'BOTS'],
      'HermesNeedsYouWidgetProvider': [
        'botw_needs_you_name',
        'botw_needs_you_info',
        'NEEDS_YOU',
      ],
      'HermesRoomWidgetProvider': ['botw_room_name', 'botw_room_info', 'ROOM'],
      'HermesQuickAskWidgetProvider': [
        'botw_quick_ask_name',
        'botw_quick_ask_info',
        'QUICK_ASK',
      ],
      'HermesStatusWidgetProvider': [
        'botw_status_name',
        'botw_status_info',
        'STATUS',
      ],
    };
    botMode.forEach((name, res) {
      expect(glance, contains('class $name'));
      expect(
        glance,
        contains('HermesBotModeWidget(BotModeWidgetKind.${res[2]})'),
        reason: name,
      );
      final start = manifest.indexOf('android:name=".$name"');
      expect(start, greaterThanOrEqualTo(0), reason: name);
      final block = manifest.substring(
        start,
        manifest.indexOf('</receiver>', start),
      );
      expect(block, contains('android:label="@string/${res[0]}"'));
      expect(block, contains('android:resource="@xml/${res[1]}"'));
      expect(background, contains("hermes_android.$name'"));
      expect(publisher, contains("hermes_android.$name'"));
    });
    expect(manifest, contains('.HermesNotificationActionReceiver'));
    // Eight widget receivers in total: 3 original + 5 Bot Mode.
    expect(
      RegExp('android.appwidget.provider').allMatches(manifest),
      hasLength(8),
    );

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
      'botw_bots_info',
      'botw_status_info',
      'botw_quick_ask_info',
      'botw_needs_you_info',
      'botw_room_info',
    ]) {
      final xml = read('android/app/src/main/res/xml/$info.xml');
      expect(xml, contains('android:updatePeriodMillis="0"'));
      // Informational widgets may live on the lock screen; widgets with
      // Approve / Deny / Stop or conversation text are home-screen only.
      const informational = {'botw_status_info', 'botw_quick_ask_info'};
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
      // Grok-style: every preview takes a state glow background.
      expect(layout, contains('@drawable/botw_glow_'), reason: name);
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
      contains('<color name="botw_preview_surface">#FF15171B</color>'),
    );
    // v2: near-black card; the state colour is ONLY a pre-blurred bottom
    // glow bitmap (Glance cannot blur); idle is pure black.
    for (final glow in ['idle', 'working', 'done', 'needs_you', 'failed']) {
      final xml = read('android/app/src/main/res/drawable/botw_glow_$glow.xml');
      expect(xml, contains('#FF07080A'), reason: glow);
      expect(xml, contains('@dimen/botw_preview_radius'), reason: glow);
      expect(xml, isNot(contains('android:type="linear"')), reason: glow);
      if (glow == 'idle') {
        expect(xml, isNot(contains('botw_glowimg_')));
      } else {
        expect(xml, contains('@drawable/botw_glowimg_$glow'), reason: glow);
        expect(
          File(
            'android/app/src/main/res/drawable-nodpi/botw_glowimg_$glow.png',
          ).existsSync(),
          isTrue,
          reason: glow,
        );
      }
    }
    for (final locale in ['values', 'values-es']) {
      final strings = read(
        'android/app/src/main/res/$locale/bot_mode_widgets.xml',
      );
      for (final key in [
        'botw_done',
        'botw_failed',
        'botw_needs_you_short',
        'botw_in_room',
        'botw_more',
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
      read('android/app/src/main/res/xml/botw_bots_info.xml'),
      contains('android:minResizeHeight="110dp"'),
    );
  });

  test('release builds expose only the 3 original widget providers', () {
    String read(String path) => File(path).readAsStringSync();
    final manifest = read('android/app/src/main/AndroidManifest.xml');
    final qa = read('android/app/src/qa/AndroidManifest.xml');
    final blocks = manifest
        .split('<receiver')
        .skip(1)
        .map((b) {
          final end = b.indexOf('</receiver>');
          return end < 0 ? b : b.substring(0, end);
        })
        .where((b) => b.contains('android.appwidget.provider'))
        .toList();
    expect(blocks, hasLength(8));
    final enabled = <String>[];
    for (final block in blocks) {
      final name = RegExp(
        r'android:name="\.(\w+)"',
      ).firstMatch(block)!.group(1)!;
      if (!block.contains('android:enabled="false"')) enabled.add(name);
    }
    // Bot Mode widgets are redesigned in 1.2.15: not in the 1.2.14 picker.
    expect(enabled, [
      'NewSessionWidgetProvider',
      'HermesCompactWidgetProvider',
      'HermesControlWidgetProvider',
    ]);
    // Release/full/play/profile/debug overlays never re-enable them.
    for (final flavor in ['full', 'release', 'profile', 'debug']) {
      final path = 'android/app/src/$flavor/AndroidManifest.xml';
      if (!File(path).existsSync()) continue;
      expect(read(path), isNot(contains('WidgetProvider')), reason: flavor);
    }
    expect(
      Directory('android/app/src/play').listSync().map((e) => e.path),
      isNot(contains('android/app/src/play/AndroidManifest.xml')),
    );
    // The qa flavor keeps the five Bot Mode widgets placeable.
    for (final name in [
      'HermesBotsWidgetProvider',
      'HermesNeedsYouWidgetProvider',
      'HermesRoomWidgetProvider',
      'HermesQuickAskWidgetProvider',
      'HermesStatusWidgetProvider',
    ]) {
      final start = qa.indexOf('hermes_android.$name"');
      expect(start, greaterThanOrEqualTo(0), reason: name);
      final block = qa.substring(start, qa.indexOf('/>', start));
      expect(block, contains('android:enabled="true"'), reason: name);
      expect(block, contains('tools:replace="android:enabled"'), reason: name);
    }
    expect(qa, isNot(contains('NewSessionWidgetProvider')));
    // Updating a disabled provider must not break the original widgets.
    final publisher = read('lib/core/services/home_widget_publisher.dart');
    final update = publisher.substring(
      publisher.indexOf('requestUpdate() async'),
    );
    expect(update, contains('try {'));
  });

  test('Grok-style Bot widgets: states, outcomes, multi-room and hero', () {
    String read(String path) => File(path).readAsStringSync();
    const dir = 'android/app/src/main/kotlin/com/hermesagent/hermes_android';
    final state = read('$dir/BotModeWidgetState.kt');
    final glance = read('$dir/HermesBotModeWidgets.kt');
    final notif = read('$dir/HermesRichNotifications.kt');
    // Outcomes expire on the widget side too (never stale "done").
    expect(state, contains('BOT_MODE_OUTCOME_MS = 10 * 60 * 1000L'));
    expect(state, contains('fun heroItem()'));
    expect(state, contains('json.optJSONArray("rooms")'));
    expect(state, contains('"done" -> DONE'));
    expect(state, contains('"failed" -> FAILED'));
    // Keyguard never shows steps or room names.
    expect(state, contains('steps = emptyList(), roomName = null'));
    // Bot Mode receivers redrawn by the expiry worker.
    for (final receiver in [
      'HermesBotsWidgetProvider::class.java',
      'HermesNeedsYouWidgetProvider::class.java',
      'HermesRoomWidgetProvider::class.java',
      'HermesStatusWidgetProvider::class.java',
      'HermesQuickAskWidgetProvider::class.java',
    ]) {
      expect(glance, contains(receiver));
    }
    expect(glance, contains('R.drawable.botw_glow_'));
    expect(glance, contains('MorePill('));
    // v2 layout: wide lists are plain rows with hairlines (no boxed rows),
    // the room Stop is a discreet control, the title is one line.
    expect(glance, contains('Hairline()'));
    expect(
      glance,
      isNot(
        contains(
          'botw_pill_glass)).clickable(openAction(context, item.openPayload))',
        ),
      ),
    );
    final listRow = glance.substring(
      glance.indexOf('private fun ListRow('),
      glance.indexOf('private fun Pill('),
    );
    expect(listRow, isNot(contains('.background(')));
    expect(glance, contains('R.drawable.botw_ic_stop'));
    expect(glance, isNot(contains('R.string.botw_in_room')));
    // Notifications: state accent (never colorized), group summary per
    // Bot/room and a non-promoted multi-room summary.
    expect(notif, contains('.setColor(accent)'));
    expect(notif, contains('setColorized(false)'));
    expect(notif, contains('fun syncGroupSummary('));
    // A bot-only shortcut Person demotes the card out of Conversations.
    expect(notif, isNot(contains('.setBot(true)')));
    expect(notif, contains('builder.setShortcutId(it)'));
    expect(notif, contains('args["promote"] != false'));
    // The widget gallery is QA-only.
    expect(
      read('android/app/src/main/AndroidManifest.xml'),
      isNot(contains('WidgetGalleryActivity')),
    );
  });

  test('Glance widgets expose three height-stable adaptive variants', () {
    final dashboardInfo = File(
      'android/app/src/main/res/xml/new_session_widget_info.xml',
    ).readAsStringSync();
    final compactInfo = File(
      'android/app/src/main/res/xml/hermes_widget_compact_info.xml',
    ).readAsStringSync();
    final controlInfo = File(
      'android/app/src/main/res/xml/hermes_widget_control_info.xml',
    ).readAsStringSync();
    final shortcut = File(
      'android/app/src/main/res/xml/shortcuts.xml',
    ).readAsStringSync();
    final controlPreview = File(
      'android/app/src/main/res/layout/new_session_widget_large.xml',
    ).readAsStringSync();
    final compactPreview = File(
      'android/app/src/main/res/layout/hermes_widget_compact_preview.xml',
    ).readAsStringSync();
    final dashboardPreview = File(
      'android/app/src/main/res/layout/hermes_widget_dashboard_preview.xml',
    ).readAsStringSync();
    final provider = File(
      'android/app/src/main/kotlin/com/hermesagent/hermes_android/'
      'NewSessionWidgetProvider.kt',
    ).readAsStringSync();
    final glance = File(
      'android/app/src/main/kotlin/com/hermesagent/hermes_android/'
      'HermesConsoleGlanceWidget.kt',
    ).readAsStringSync();
    final state = File(
      'android/app/src/main/kotlin/com/hermesagent/hermes_android/'
      'HermesWidgetState.kt',
    ).readAsStringSync();
    final expiryWorker = File(
      'android/app/src/main/kotlin/com/hermesagent/hermes_android/'
      'HermesWidgetExpiryWorker.kt',
    ).readAsStringSync();
    final appGradle = File('android/app/build.gradle.kts').readAsStringSync();
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final publisher = File(
      'lib/core/services/home_widget_publisher.dart',
    ).readAsStringSync();

    expect(shortcut, contains('android:icon="@mipmap/ic_launcher"'));
    expect(compactPreview, contains('192.168.1.20'));
    expect(compactPreview, contains('@string/hermes_widget_voice'));
    expect(controlPreview, contains('@string/hermes_widget_context'));
    expect(controlPreview, contains('<ProgressBar'));
    expect(dashboardPreview, contains('@string/hermes_widget_brand'));
    expect(dashboardPreview, contains('TTFT&#10;860ms'));
    for (final info in [dashboardInfo, compactInfo, controlInfo]) {
      expect(info, contains('android:updatePeriodMillis="0"'));
      expect(info, contains('android:resizeMode="horizontal"'));
      expect(info, contains('android:minResizeWidth'));
      expect(info, isNot(contains('android:minResizeHeight')));
    }
    expect(
      dashboardInfo,
      contains(
        'android:initialLayout="@layout/hermes_widget_dashboard_preview"',
      ),
    );
    expect(
      dashboardInfo,
      contains(
        'android:previewLayout="@layout/hermes_widget_dashboard_preview"',
      ),
    );
    expect(compactInfo, contains('android:targetCellWidth="2"'));
    expect(compactInfo, contains('android:targetCellHeight="1"'));
    expect(controlInfo, contains('android:targetCellWidth="4"'));
    expect(controlInfo, contains('android:targetCellHeight="1"'));
    expect(dashboardInfo, contains('android:targetCellWidth="4"'));
    expect(dashboardInfo, contains('android:targetCellHeight="2"'));
    expect(provider, contains('HomeWidgetGlanceWidgetReceiver'));
    expect(provider, contains('HermesConsoleGlanceWidget'));
    expect(provider, contains('HermesCompactWidgetProvider'));
    expect(provider, contains('HermesControlWidgetProvider'));
    expect(provider, contains('HermesWidgetVariant.COMPACT'));
    expect(provider, contains('HermesWidgetVariant.CONTROL'));
    expect(provider, contains('HermesWidgetVariant.DASHBOARD'));
    expect(glance, contains('SizeMode.Exact'));
    expect(glance, isNot(contains('SizeMode.Responsive')));
    expect(glance, contains('LocalSize.current'));
    expect(glance, contains('WidgetLayoutProfile'));
    expect(glance, contains('enum class WidgetContentTier'));
    expect(glance, contains('width < 100.dp || height < 54.dp'));
    expect(glance, contains('width < 190.dp || height < 100.dp'));
    expect(glance, contains('width < 270.dp || height < 190.dp'));
    expect(glance, contains('variantCeiling'));
    expect(glance, contains('enum class HermesWidgetVariant'));
    expect(glance, contains('CompactContent(context, state, colors, layout)'));
    expect(glance, contains('ControlContent(context, state, colors, layout)'));
    expect(glance, contains('ExpandedContent(context, state, colors, layout)'));
    expect(glance, contains('private fun ExpandedStatusPanel'));
    expect(glance, contains('.background(colors.surface)'));
    expect(glance, contains('ExpandedDetails(context, state, colors, roomy)'));
    expect(glance, contains('LinearProgressIndicator'));
    expect(glance, contains('firstTokenLatencyMs'));
    expect(state, contains('SCHEMA_VERSION'));
    expect(state, contains('cacheReadTokens'));
    expect(state, contains('firstTokenLatencyMs'));
    expect(state, contains('lastActivityAtMs'));
    expect(state, contains('fun staleAtMs()'));
    expect(state, contains('ATOMIC_SNAPSHOT'));
    expect(state, contains('JSONObject'));
    expect(state, contains('atomicSnapshotValues'));
    expect(glance, contains('HermesWidgetExpiryScheduler.replace'));
    expect(expiryWorker, contains('HomeWidgetPlugin.getData'));
    expect(expiryWorker, contains('OneTimeWorkRequestBuilder'));
    expect(expiryWorker, contains('ExistingWorkPolicy.REPLACE'));
    expect(expiryWorker, contains('originalWidgetReceivers()'));
    expect(expiryWorker, contains('NewSessionWidgetProvider::class.java'));
    expect(expiryWorker, contains('HermesCompactWidgetProvider::class.java'));
    expect(expiryWorker, contains('HermesControlWidgetProvider::class.java'));
    expect(expiryWorker, isNot(contains('PeriodicWorkRequest')));
    expect(expiryWorker, isNot(contains('NetworkType')));
    expect(appGradle, contains('androidx.work:work-runtime-ktx:2.11.2'));
    expect(glance, isNot(contains('RemoteViews')));
    expect(provider, isNot(contains('WorkManager')));
    expect(glance, isNot(contains('WorkManager')));
    expect(manifest, contains('android.app.shortcuts'));
    expect(manifest, contains('.NewSessionWidgetProvider'));
    expect(manifest, contains('.HermesCompactWidgetProvider'));
    expect(manifest, contains('.HermesControlWidgetProvider'));
    expect(manifest, contains('@xml/new_session_widget_info'));
    expect(manifest, contains('@xml/hermes_widget_compact_info'));
    expect(manifest, contains('@xml/hermes_widget_control_info'));
    expect(publisher, contains('HermesCompactWidgetProvider'));
    expect(publisher, contains('HermesControlWidgetProvider'));
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
