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
      'LauncherWidgets.kt',
    ).readAsStringSync();

    expect(shortcut, contains(action));
    expect(contract, contains(action));
    expect(provider, contains('LauncherWidgetProvider('));
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

  test(
    'the three receivers shipped since 1.2.13 are kept, with new content',
    () {
      String read(String path) => File(path).readAsStringSync();
      const kt = 'android/app/src/main/kotlin/com/hermesagent/hermes_android/';
      final provider = read('${kt}NewSessionWidgetProvider.kt');
      final renderer = read('${kt}LauncherWidgets.kt');
      final expiryWorker = read('${kt}HermesWidgetExpiryWorker.kt');
      final manifest = read('android/app/src/main/AndroidManifest.xml');
      final publisher = read('lib/core/services/home_widget_publisher.dart');
      final background = read(
        'lib/core/services/notifications/bot_mode_background.dart',
      );

      // A launcher binds a placed widget to its receiver's class name: the
      // names stay, so a "Hermes · Panel" on somebody's home screen becomes
      // Ahora in place, and the two others become Chat rápido.
      expect(
        provider,
        contains(
          'class NewSessionWidgetProvider : '
          'LauncherWidgetProvider(LauncherWidgetSubject.AHORA)',
        ),
      );
      for (final name in [
        'HermesCompactWidgetProvider',
        'HermesControlWidgetProvider',
      ]) {
        expect(
          provider,
          contains(
            'class $name : LauncherWidgetProvider(LauncherWidgetSubject.QUICK)',
          ),
        );
      }
      expect(
        File('${kt}HermesConsoleGlanceWidget.kt').existsSync(),
        isFalse,
        reason: 'the three near-duplicate session widgets are gone',
      );

      String receiverBlock(String name) {
        final start = manifest.indexOf('android:name="$name"');
        expect(start, greaterThanOrEqualTo(0), reason: name);
        return manifest.substring(
          start,
          manifest.indexOf('</receiver>', start),
        );
      }

      const kept = {
        '.NewSessionWidgetProvider': [
          'lw_ahora_name',
          'new_session_widget_info',
        ],
        '.HermesCompactWidgetProvider': [
          'lw_quick_name',
          'hermes_widget_compact_info',
        ],
        '.HermesControlWidgetProvider': [
          'lw_quick_wide_name',
          'hermes_widget_control_info',
        ],
      };
      kept.forEach((receiver, res) {
        final block = receiverBlock(receiver);
        expect(block, contains('android:label="@string/${res[0]}"'));
        expect(block, contains('android:resource="@xml/${res[1]}"'));
        expect(block, isNot(contains('android:enabled="false"')));
      });
      final ahora = read(
        'android/app/src/main/res/xml/new_session_widget_info.xml',
      );
      final quick = read(
        'android/app/src/main/res/xml/hermes_widget_compact_info.xml',
      );
      final quickWide = read(
        'android/app/src/main/res/xml/hermes_widget_control_info.xml',
      );
      // Ahora: one row by default, narrower and taller on demand.
      expect(ahora, contains('android:targetCellWidth="4"'));
      expect(ahora, contains('android:targetCellHeight="1"'));
      expect(ahora, contains('android:resizeMode="horizontal|vertical"'));
      expect(ahora, contains('android:minResizeWidth="110dp"'));
      expect(ahora, contains('android:minResizeHeight="40dp"'));
      expect(
        ahora,
        contains('android:previewLayout="@layout/lw_preview_ahora"'),
      );
      // Until its first drawing a placed widget is the empty card, never
      // sample content that could pass for real.
      expect(ahora, contains('android:initialLayout="@layout/lw_initial"'));
      // Chat rápido: one row; the picker offers it once.
      expect(quick, contains('android:targetCellWidth="2"'));
      expect(quick, contains('android:targetCellHeight="1"'));
      expect(quick, contains('android:resizeMode="horizontal"'));
      expect(quick, contains('android:previewLayout="@layout/lw_quick_small"'));
      expect(quick, isNot(contains('hide_from_picker')));
      expect(quickWide, contains('android:targetCellWidth="4"'));
      expect(quickWide, contains('android:resizeMode="horizontal"'));
      expect(quickWide, contains('android:widgetFeatures="hide_from_picker"'));
      expect(
        quickWide,
        contains('android:previewLayout="@layout/lw_quick_wide"'),
      );
      for (final info in [ahora, quick, quickWide]) {
        expect(info, contains('android:updatePeriodMillis="0"'));
        expect(info, contains('android:description="@string/lw_'));
        expect(info, isNot(contains('botw_')));
      }
      // The app's publisher keeps refreshing these receivers; the Bot Mode
      // listener only drives the Bot Mode receivers, so Ahora (which shows the
      // same approvals) follows that snapshot from the native side.
      for (final name in [
        'NewSessionWidgetProvider',
        'HermesCompactWidgetProvider',
        'HermesControlWidgetProvider',
      ]) {
        expect(publisher, contains("hermes_android.$name'"));
        expect(background, isNot(contains("hermes_android.$name'")));
        expect(renderer, contains('$name::class.java'));
      }
      expect(renderer, contains('if (key == BOT_MODE_SNAPSHOT_KEY)'));
      expect(
        read('${kt}HermesApplication.kt'),
        contains('LauncherWidgetRefresh.watch(this)'),
      );
      // One redraw-only worker for the family; nothing periodic, no network.
      expect(expiryWorker, contains('launcherWidgetReceivers()'));
      expect(expiryWorker, contains('OneTimeWorkRequestBuilder'));
      expect(expiryWorker, contains('ExistingWorkPolicy.REPLACE'));
      for (final source in [expiryWorker, renderer, provider]) {
        expect(source, isNot(contains('PeriodicWorkRequest')));
        expect(source, isNot(contains('NetworkType')));
        expect(source, isNot(contains('AlarmManager')));
        expect(source, isNot(contains('HttpURLConnection')));
        expect(source, isNot(contains('androidx.glance')));
      }
    },
  );

  test('Cron: the next job in one row, all by next run when larger', () {
    String read(String path) => File(path).readAsStringSync();
    const kt = 'android/app/src/main/kotlin/com/hermesagent/hermes_android/';
    final provider = read('${kt}NewSessionWidgetProvider.kt');
    final renderer = read('${kt}LauncherWidgets.kt');
    final state = read('${kt}LauncherWidgetCron.kt');
    final manifest = read('android/app/src/main/AndroidManifest.xml');
    final info = read(
      'android/app/src/main/res/xml/hermes_widget_cron_info.xml',
    );
    expect(
      provider,
      contains(
        'class HermesCronWidgetProvider : '
        'LauncherWidgetProvider(LauncherWidgetSubject.CRON)',
      ),
    );
    final start = manifest.indexOf('android:name=".HermesCronWidgetProvider"');
    expect(start, greaterThanOrEqualTo(0));
    final block = manifest.substring(
      start,
      manifest.indexOf('</receiver>', start),
    );
    expect(block, contains('android:label="@string/lw_cron_name"'));
    expect(block, contains('android:resource="@xml/hermes_widget_cron_info"'));
    expect(block, contains('android:exported="false"'));
    expect(info, contains('android:targetCellWidth="2"'));
    expect(info, contains('android:targetCellHeight="1"'));
    expect(info, contains('android:resizeMode="horizontal|vertical"'));
    expect(info, contains('android:updatePeriodMillis="0"'));
    expect(info, contains('android:description="@string/lw_cron_description"'));
    // Its picker preview is the very layout the one-row widget uses.
    expect(info, contains('android:previewLayout="@layout/lw_strip"'));
    expect(renderer, contains('RemoteViews(pkg, R.layout.lw_strip)'));
    expect(info, contains('android:initialLayout="@layout/lw_initial"'));
    // It reads the section Dart publishes, of this schema only.
    expect(state, contains('CRON_SNAPSHOT_KEY = "hermes_widget_cron_v1"'));
    expect(
      state,
      contains(
        'if (json.optInt("schema_version") != CRON_SCHEMA) '
        'return CronWidgetState()',
      ),
    );
    // By next run; a job whose time has passed with no news comes after the
    // ones still to run; a failed job is never the one left out.
    expect(state, contains('ahead.sortedBy { it.nextMs }'));
    expect(
      state,
      contains('all.drop(count).filter { it.last == CronWidgetResult.FAILED }'),
    );
    expect(renderer, contains('cron.rows(data.nowMs, fit)'));
    expect(renderer, contains('R.plurals.lw_cron_failed'));
    // Old data keeps the schedule and says since when it has had no news.
    expect(state, contains('CRON_STALE_AFTER_MS = 15 * 60 * 1000L'));
    expect(renderer, contains('stale -> since(cron.updatedAtMs)'));
    expect(renderer, contains('R.drawable.lw_ic_cloud_off, R.color.lw_amber'));
    // A job opens in the app's Cron screen through the link Dart built.
    expect(
      renderer,
      contains('job?.openPayload?.let { LauncherWidgetOpen.Payload(it) }'),
    );
    // Its clock (a job's time coming, midnight) only wakes a redraw while a
    // Cron widget is placed.
    expect(
      renderer,
      contains(
        'withCron = placed(context, manager, HermesCronWidgetProvider::class.java)',
      ),
    );
    expect(
      renderer,
      contains('cron.nextChangeAtMs(nowMs).takeIf { withCron }'),
    );
  });

  test('Ahora answers through the notification action path, never locked', () {
    String read(String path) => File(path).readAsStringSync();
    const kt = 'android/app/src/main/kotlin/com/hermesagent/hermes_android/';
    final renderer = read('${kt}LauncherWidgets.kt');
    final notif = read('${kt}HermesRichNotifications.kt');
    // Permitir / Rechazar are the same broadcast as a notification's buttons,
    // marked as coming from a widget…
    expect(
      renderer,
      contains(
        'HermesRichNotifications.actionBroadcast('
        'context, actionId, payload, 0, null, "widget")',
      ),
    );
    expect(renderer, contains('answer("approve", payload)'));
    expect(renderer, contains('answer("deny", payload)'));
    expect(renderer, contains('PendingIntent.FLAG_IMMUTABLE'));
    // …which the receiver refuses while the keyguard shows.
    expect(
      notif,
      contains(
        'if (source == "widget" && '
        '(keyguard == null || keyguard.isKeyguardLocked)) return',
      ),
    );
    // On a lock-screen host it only counts: no names, no text, no buttons.
    final locked = renderer.substring(
      renderer.indexOf('private fun ahoraLocked('),
      renderer.indexOf('private fun ahoraStrip('),
    );
    expect(locked, contains('R.plurals.lw_needs_you'));
    expect(locked, contains('R.plurals.lw_running'));
    expect(locked, isNot(contains('answer(')));
    expect(locked, isNot(contains('need.')));
    expect(locked, isNot(contains('.what')));
    expect(locked, isNot(contains('.who')));
    // Every other tap is a deep link the app already had.
    for (final route in [
      'NewSessionLaunchContract.openAppIntent(context)',
      'NewSessionLaunchContract.openSetupIntent(context)',
      'NewSessionLaunchContract.openSessionIntent(',
      'NewSessionLaunchContract.newIntent(',
      'HermesRichNotifications.openActivityIntent(context, open.payload)',
    ]) {
      expect(renderer, contains(route));
    }
    // Timers are the launcher's own Chronometer: no redraw per second.
    expect(renderer, contains('views.setChronometer('));
    // Schema 2 of the app's snapshot lists every chat that runs or waits;
    // one written by 1.2.14 (schema 1) still draws.
    final state = read('${kt}HermesWidgetState.kt');
    expect(state, contains('READABLE_SCHEMAS = setOf(1L, 2L)'));
    expect(state, contains('values["active"] as? JSONArray'));
    expect(
      state,
      contains('val listsActivity: Boolean get() = schemaVersion >= 2'),
    );
    expect(renderer, contains('if (data.chatOnline && chat.listsActivity)'));
    // A request the app did not describe is not called a permission.
    expect(renderer, contains('need == null -> AhoraNeedKind.UNKNOWN'));
    expect(
      renderer,
      contains('AhoraNeedKind.UNKNOWN -> R.string.lw_needs_you_who'),
    );
    // An ordinary chat's request is answered with its own payload…
    expect(renderer, contains('answerPayload = need?.actionPayload'));
    // …its timer counts from the turn's start, and its phase is the plain
    // word Dart chose for the running tool.
    expect(renderer, contains('sinceMs = activity.startedAtMs'));
    expect(
      renderer,
      contains(
        'else -> activity.phase ?: context.getString(R.string.lw_working)',
      ),
    );
    // The same agent is not listed twice (as a chat and as a working bot).
    expect(renderer, contains('if (bot.profile !in shown) runs +='));
    // Old data never looks alive.
    expect(state, contains('active = emptyList(),'));
    expect(renderer, contains('if (!data.chatOnline && !data.botsOnline)'));
    expect(renderer, contains('mode = AhoraMode.OFFLINE'));
    expect(renderer, contains('R.string.lw_since'));
    // …and a moment that is not from today is named by its day: a bare
    // "18:32" on a card left since yesterday would read as today's.
    expect(renderer, contains('R.string.lw_since_yesterday'));
    expect(renderer, contains('R.string.lw_since_day'));
    expect(renderer, contains('moment(model.sinceMs)'));
    expect(renderer, contains('moment(cron.updatedAtMs)'));
    expect(renderer, isNot(contains('clock(model.sinceMs)')));
  });

  test('Bots and Salas ship in the family; the three drafts are gone', () {
    String read(String path) => File(path).readAsStringSync();
    const kt = 'android/app/src/main/kotlin/com/hermesagent/hermes_android/';
    const res = 'android/app/src/main/res';
    final provider = read('${kt}NewSessionWidgetProvider.kt');
    final renderer = read('${kt}LauncherWidgets.kt');
    final manifest = read('android/app/src/main/AndroidManifest.xml');
    final background = read(
      'lib/core/services/notifications/bot_mode_background.dart',
    );
    const family = {
      'HermesBotsWidgetProvider': [
        'BOTS',
        'lw_bots_name',
        'hermes_widget_bots_info',
        'lw_preview_bots',
      ],
      'HermesRoomWidgetProvider': [
        'ROOMS',
        'lw_rooms_name',
        'hermes_widget_rooms_info',
        'lw_preview_rooms',
      ],
    };
    family.forEach((name, parts) {
      expect(
        provider,
        contains(
          'class $name : LauncherWidgetProvider(LauncherWidgetSubject.${parts[0]})',
        ),
      );
      final start = manifest.indexOf('android:name=".$name"');
      expect(start, greaterThanOrEqualTo(0), reason: name);
      final block = manifest.substring(
        start,
        manifest.indexOf('</receiver>', start),
      );
      expect(block, contains('android:label="@string/${parts[1]}"'));
      expect(block, contains('android:resource="@xml/${parts[2]}"'));
      expect(block, isNot(contains('android:enabled="false"')), reason: name);
      final info = read('$res/xml/${parts[2]}.xml');
      expect(info, contains('android:previewLayout="@layout/${parts[3]}"'));
      expect(info, contains('android:initialLayout="@layout/lw_initial"'));
      expect(info, contains('android:resizeMode="horizontal|vertical"'));
      expect(info, contains('android:targetCellWidth="2"'));
      expect(info, contains('android:targetCellHeight="1"'));
      expect(info, contains('android:updatePeriodMillis="0"'));
      expect(info, contains('android:widgetCategory="home_screen"'));
      // The background listener already redraws these two receivers when it
      // publishes the snapshot they read.
      expect(background, contains("hermes_android.$name'"));
      expect(renderer, contains('$name::class.java'));
    });
    // They read the listener's snapshot and never show old data as live.
    expect(renderer, contains('data.bots.trusted(data.nowMs).bots'));
    expect(renderer, contains('data.bots.trusted(data.nowMs).rooms'));
    expect(renderer, contains('val offline = !data.botsOnline'));
    // Who waits for you comes first; a row opens that bot or that room.
    expect(renderer, contains('it.state.priority'));
    expect(
      renderer,
      contains('pending(LauncherWidgetOpen.Payload(bot.openPayload))'),
    );
    expect(
      renderer,
      contains('pending(LauncherWidgetOpen.Payload(room.openPayload))'),
    );
    // Te necesitan, Pregunta rápida and Estado were never enabled in a
    // released manifest (1.2.13 did not have them, 1.2.14 shipped them
    // disabled): Ahora and Chat rápido cover them, so they are removed.
    for (final gone in [
      'HermesNeedsYouWidgetProvider',
      'HermesQuickAskWidgetProvider',
      'HermesStatusWidgetProvider',
    ]) {
      expect(manifest, isNot(contains(gone)), reason: gone);
      expect(provider, isNot(contains(gone)), reason: gone);
      expect(renderer, isNot(contains(gone)), reason: gone);
    }
    expect(File('${kt}HermesBotModeWidgets.kt').existsSync(), isFalse);
    for (final dir in ['layout', 'drawable', 'drawable-nodpi', 'xml']) {
      final left = Directory('$res/$dir')
          .listSync()
          .map((f) => f.uri.pathSegments.last)
          .where((name) => name.startsWith('botw_'));
      expect(left, isEmpty, reason: dir);
    }
    // No widget of the family is drawn with Glance any more.
    final sources = Directory(kt)
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.kt'))
        .map((f) => f.readAsStringSync())
        .join('\n');
    expect(sources, isNot(contains('androidx.glance')));
    expect(sources, isNot(contains('GlanceAppWidget')));
  });

  test('Tareas: the card in progress, then the pending ones', () {
    String read(String path) => File(path).readAsStringSync();
    const kt = 'android/app/src/main/kotlin/com/hermesagent/hermes_android/';
    final provider = read('${kt}NewSessionWidgetProvider.kt');
    final renderer = read('${kt}LauncherWidgets.kt');
    final state = read('${kt}LauncherWidgetTasks.kt');
    final manifest = read('android/app/src/main/AndroidManifest.xml');
    final info = read(
      'android/app/src/main/res/xml/hermes_widget_tasks_info.xml',
    );
    expect(
      provider,
      contains(
        'class HermesTasksWidgetProvider : '
        'LauncherWidgetProvider(LauncherWidgetSubject.TASKS)',
      ),
    );
    final start = manifest.indexOf('android:name=".HermesTasksWidgetProvider"');
    expect(start, greaterThanOrEqualTo(0));
    final block = manifest.substring(
      start,
      manifest.indexOf('</receiver>', start),
    );
    expect(block, contains('android:label="@string/lw_tasks_name"'));
    expect(block, contains('android:resource="@xml/hermes_widget_tasks_info"'));
    expect(info, contains('android:previewLayout="@layout/lw_preview_tasks"'));
    expect(info, contains('android:initialLayout="@layout/lw_initial"'));
    expect(info, contains('android:resizeMode="horizontal|vertical"'));
    expect(info, contains('android:targetCellWidth="2"'));
    expect(info, contains('android:targetCellHeight="1"'));
    expect(info, contains('android:updatePeriodMillis="0"'));
    // It reads the section Dart publishes, of this schema only.
    expect(state, contains('TASKS_SNAPSHOT_KEY = "hermes_widget_tasks_v1"'));
    expect(
      state,
      contains(
        'if (json.optInt("schema_version") != TASKS_SCHEMA) '
        'return TasksWidgetState()',
      ),
    );
    // The counts of its head are the whole board's.
    expect(
      renderer,
      contains('plural(R.plurals.lw_tasks_running, kanban.running)'),
    );
    expect(
      renderer,
      contains('plural(R.plurals.lw_tasks_pending, kanban.pending)'),
    );
    // A card opens in the app's Tareas screen through the link Dart built.
    expect(
      renderer,
      contains('task?.openPayload?.let { LauncherWidgetOpen.Payload(it) }'),
    );
    // Old data: nothing is shown as in progress, and it says since when.
    expect(state, contains('TASKS_STALE_AFTER_MS = 15 * 60 * 1000L'));
    expect(renderer, contains('subColor = tone.takeIf { !stale }'));
    expect(
      renderer,
      contains('val live = !stale && task.state != TaskWidgetState.PENDING'),
    );
    expect(
      renderer,
      contains('tasks.nextChangeAtMs(nowMs).takeIf { withTasks }'),
    );
  });

  test('Chats: the conversation that moves, then the recent ones', () {
    String read(String path) => File(path).readAsStringSync();
    const kt = 'android/app/src/main/kotlin/com/hermesagent/hermes_android/';
    final provider = read('${kt}NewSessionWidgetProvider.kt');
    final renderer = read('${kt}LauncherWidgets.kt');
    final state = read('${kt}LauncherWidgetChats.kt');
    final manifest = read('android/app/src/main/AndroidManifest.xml');
    final info = read(
      'android/app/src/main/res/xml/hermes_widget_chats_info.xml',
    );
    expect(
      provider,
      contains(
        'class HermesChatsWidgetProvider : '
        'LauncherWidgetProvider(LauncherWidgetSubject.CHATS)',
      ),
    );
    final start = manifest.indexOf('android:name=".HermesChatsWidgetProvider"');
    expect(start, greaterThanOrEqualTo(0));
    final block = manifest.substring(
      start,
      manifest.indexOf('</receiver>', start),
    );
    expect(block, contains('android:label="@string/lw_chats_name"'));
    expect(block, contains('android:resource="@xml/hermes_widget_chats_info"'));
    expect(info, contains('android:previewLayout="@layout/lw_preview_chats"'));
    expect(info, contains('android:initialLayout="@layout/lw_initial"'));
    expect(info, contains('android:resizeMode="horizontal|vertical"'));
    expect(info, contains('android:updatePeriodMillis="0"'));
    expect(state, contains('CHATS_SNAPSHOT_KEY = "hermes_widget_chats_v1"'));
    expect(
      state,
      contains(
        'if (json.optInt("schema_version") != CHATS_SCHEMA) '
        'return ChatsWidgetState()',
      ),
    );
    // Who waits for you first, then who runs, then by last activity; a chat
    // just started that the list does not have yet is added.
    expect(state, contains('it.needsYou -> 0'));
    expect(state, contains('it.running -> 1'));
    expect(state, contains('it.sessionId !in known'));
    // What runs or waits is only taken from a fresh snapshot of the app.
    expect(
      renderer,
      contains(
        'val active = if (data.chatOnline && data.chat.listsActivity) '
        'data.chat.active else emptyList()',
      ),
    );
    // A row opens its conversation; "Ver" is the row's label, not a second
    // tap target.
    expect(
      renderer,
      contains(
        'LauncherWidgetOpen.Session(data.chats.connectionId, it.chat.id)',
      ),
    );
    final row = read('android/app/src/main/res/layout/lw_row_chat.xml');
    expect(row, contains('android:id="@+id/lw_row_view"'));
    expect(
      renderer,
      isNot(contains('setOnClickPendingIntent(R.id.lw_row_view')),
    );
    expect(state, contains('CHATS_STALE_AFTER_MS = 15 * 60 * 1000L'));
  });

  test('the picker offers the same seven widgets in every build', () {
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
    final names = [
      for (final block in blocks)
        RegExp(r'android:name="\.(\w+)"').firstMatch(block)!.group(1)!,
    ];
    expect(names, [
      'NewSessionWidgetProvider',
      'HermesCompactWidgetProvider',
      'HermesControlWidgetProvider',
      'HermesCronWidgetProvider',
      'HermesBotsWidgetProvider',
      'HermesRoomWidgetProvider',
      'HermesTasksWidgetProvider',
      'HermesChatsWidgetProvider',
    ]);
    for (final block in blocks) {
      expect(block, isNot(contains('android:enabled="false"')));
      expect(block, contains('android:exported="false"'));
    }
    // One of the eight receivers is hidden from the picker (the wide Chat
    // rápido kept for widgets already placed): the seven names of the
    // design are offered.
    final hidden = [
      for (final block in blocks)
        if (read(
          'android/app/src/main/res/xml/'
          '${RegExp(r'@xml/(\w+)').firstMatch(block)!.group(1)!}.xml',
        ).contains('hide_from_picker'))
          block,
    ];
    expect(hidden, hasLength(1));
    // No flavor adds or removes a widget.
    for (final flavor in ['full', 'release', 'profile', 'debug', 'qa']) {
      final path = 'android/app/src/$flavor/AndroidManifest.xml';
      if (!File(path).existsSync()) continue;
      expect(read(path), isNot(contains('WidgetProvider')), reason: flavor);
    }
    expect(
      File('android/app/src/play/AndroidManifest.xml').existsSync(),
      isFalse,
    );
    // The widget gallery is QA-only.
    expect(manifest, isNot(contains('WidgetGalleryActivity')));
    expect(qa, contains('WidgetGalleryActivity'));
    // A failed redraw of one receiver never blocks the others.
    final publisher = read('lib/core/services/home_widget_publisher.dart');
    final update = publisher.substring(
      publisher.indexOf('requestUpdate() async'),
    );
    expect(update, contains('try {'));
    for (final name in names.take(3)) {
      expect(publisher, contains("hermes_android.$name'"));
    }
  });

  test('Bot Mode snapshot and notifications keep their contract', () {
    String read(String path) => File(path).readAsStringSync();
    const dir = 'android/app/src/main/kotlin/com/hermesagent/hermes_android';
    final state = read('$dir/BotModeWidgetState.kt');
    final notif = read('$dir/HermesRichNotifications.kt');
    // Outcomes expire on the widget side too (never stale "done").
    expect(state, contains('BOT_MODE_OUTCOME_MS = 10 * 60 * 1000L'));
    expect(state, contains('BOT_MODE_STALE_AFTER_MS'));
    expect(state, contains('fun trusted(nowMs: Long)'));
    expect(state, contains('json.optJSONArray("rooms")'));
    expect(state, contains('"done" -> DONE'));
    expect(state, contains('"failed" -> FAILED'));
    // Notifications: state accent (never colorized), group summary per
    // Bot/room and a non-promoted multi-room summary.
    expect(notif, contains('.setColor(accent)'));
    expect(notif, contains('setColorized(false)'));
    expect(notif, contains('fun syncGroupSummary('));
    // A bot-only shortcut Person demotes the card out of Conversations.
    expect(notif, isNot(contains('.setBot(true)')));
    expect(notif, contains('builder.setShortcutId(it)'));
    expect(notif, contains('args["promote"] != false'));
  });
}
