// The launcher widgets drawn by the app keep their contract with Android:
// the picture is shown only while true, the tap zones come from the
// drawing, nothing polls or wakes anything, the lock screen keeps the
// redacted native drawing, and the retired widgets left no orphan.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/home/launcher/launcher_widget_geometry.dart';
import 'package:hermes_android/core/home/launcher/launcher_widget_images.dart';
import 'package:hermes_android/core/home/launcher/launcher_widget_scene.dart';

const _kt = 'android/app/src/main/kotlin/com/hermesagent/hermes_android';
const _res = 'android/app/src/main/res';
const _dart = 'lib/core/home/launcher';

String _read(String path) => File(path).readAsStringSync();

void main() {
  test('the provider shows a picture only while it is true, else draws natively', () {
    final widgets = _read('$_kt/LauncherWidgets.kt');
    final images = _read('$_kt/LauncherWidgetImages.kt');
    // The sizes are recorded before the manifest is read; the lock screen
    // never gets a picture (it may carry titles and requests).
    expect(widgets, contains('LauncherWidgetSizes.record(context, manager)'));
    expect(widgets, contains('if (!onLockScreen) {'));
    expect(
      widgets,
      contains(
        'LauncherWidgetImages.views(context, images, data, subject, size, renderer, budget)?.let { return it }',
      ),
    );
    expect(widgets, contains('return renderer.build(subject)'));
    // Freshness: drawn from the stored snapshots (not older), before it
    // expires, at this density and font scale.
    expect(
      images,
      contains('if (manifest.sourcesMs < latestSourceMs) return false'),
    );
    expect(
      images,
      contains('image.validUntilMs?.let { if (nowMs >= it) return false }'),
    );
    expect(
      images,
      contains(
        'near(manifest.density, density) && near(manifest.fontScale, fontScale)',
      ),
    );
    expect(
      images,
      contains(
        'matches(manifest, image, data.latestSourceMs, data.nowMs, density, config.fontScale)',
      ),
    );
    expect(widgets, contains('val latestSourceMs: Long'));
    // The four snapshots Dart counts in sources_ms are the four Kotlin
    // compares with (a fifth on one side only would hide every picture).
    expect(
      widgets,
      contains(
        'maxOf(chat.updatedAtMs, maxOf(cron.updatedAtMs, maxOf(tasks.updatedAtMs, chats.updatedAtMs)))',
      ),
    );
    // Memory: one budget for every size of one update (Android 12 sends a
    // drawing per orientation in the same RemoteViews), under the system's
    // 1.5 screens; a lower scale first, then the native drawing.
    expect(
      images,
      contains(
        'LauncherWidgetImageBudget((1.5f * widthPx * heightPx * 4 * SHARE).toLong())',
      ),
    );
    expect(images, contains('const val SHARE = 0.8f'));
    expect(
      widgets,
      contains('val budget = LauncherWidgetImageBudget.of(context)'),
    );
    expect(
      images,
      contains('budget.remainingBytes -= bitmap.allocationByteCount.toLong()'),
    );
    expect(images, contains('inSampleSize = sample'));
    expect(
      images,
      contains(
        'return sample.takeIf { bytesOf(width, height, it) <= budgetBytes }',
      ),
    );
    expect(images, contains('const val MAX_ZONES = 16'));
    // A picture's own end feeds the one-shot redraw that already existed.
    expect(
      widgets,
      contains(
        'listOfNotNull(nativeDue, images?.nextExpiryMs(now)).minOrNull()',
      ),
    );
  });

  test('the memory budget, worked through: a sample size, then nothing', () {
    // Mirrors LauncherWidgetImages.sampleFor / LauncherWidgetImageBudget for
    // a phone screen (1080 x 2400 px): one update may carry 0.8 x 1.5
    // screens of bitmaps.
    int? sampleFor(int w, int h, int budget) {
      var sample = 1;
      int bytes(int s) => (w ~/ s) * (h ~/ s) * 4;
      while (bytes(sample) > budget && sample < 8) {
        sample *= 2;
      }
      return bytes(sample) <= budget ? sample : null;
    }

    final budget = (1.5 * 1080 * 2400 * 4 * 0.8).toInt();
    // The largest picture the app draws (lwMaxPixels) fits whole...
    expect(sampleFor(1536, 1024, budget), 1);
    // ...and a second one in the same update (portrait and landscape) only
    // at half its sides.
    final left = budget - 1536 * 1024 * 4;
    expect(sampleFor(1536, 1024, left), 2);
    // Nothing left: the native drawing.
    expect(sampleFor(1536, 1024, 1000), isNull);
  });

  test(
    'tap zones: the rects the drawing emitted, laid as padding, every kind understood',
    () {
      final images = _read('$_kt/LauncherWidgetImages.kt');
      final widgets = _read('$_kt/LauncherWidgets.kt');
      expect(images, contains('hit.setViewPadding('));
      expect(images, contains('Math.round(zone.left * density)'));
      expect(images, contains('(widthPx - Math.round(zone.right * density))'));
      expect(
        images,
        contains('hit.setContentDescription(R.id.lw_zone_hit, zone.label)'),
      );
      expect(
        images,
        contains('hit.setOnClickPendingIntent(R.id.lw_zone_hit, intent)'),
      );
      expect(
        images,
        contains(
          'views.setContentDescription(R.id.lw_picture, image.description)',
        ),
      );
      // Every action a drawing may name has an intent on the other side.
      final intents = widgets.substring(
        widgets.indexOf('fun intentFor(zone: LauncherWidgetZone)'),
      );
      for (final kind in LwActionKind.values) {
        expect(intents, contains('"${kind.name}" ->'), reason: kind.name);
      }
      // Approve / Deny go through the notification action path (refused while locked).
      expect(
        intents,
        contains('"approve" -> zone.payload?.let { answer("approve", it) }'),
      );
      expect(
        intents,
        contains('"deny" -> zone.payload?.let { answer("deny", it) }'),
      );
      // The keys Android writes are the ones Dart reads.
      expect(images, contains('"$lwSizesKey"'));
      expect(images, contains('"$lwImagesKey"'));
      for (final subject in LwSubject.values) {
        expect(widgets, contains('("${subject.key}")'), reason: subject.key);
      }
    },
  );

  test('the picture layouts hold only what a RemoteViews may inflate', () {
    final image = _read('$_res/layout/lw_image.xml');
    final zone = _read('$_res/layout/lw_zone.xml');
    final tags = RegExp(
      r'<([A-Za-z.]+)[\s>]',
    ).allMatches(image + zone).map((m) => m.group(1)).toSet();
    expect(tags, everyElement(isIn(['FrameLayout', 'ImageView'])));
    expect(image, contains('android:id="@android:id/background"'));
    expect(image, contains('android:scaleType="fitXY"'));
    expect(zone, contains('android:clickable="true"'));
    expect(zone, contains('android:focusable="true"'));
    expect(zone, contains('android:id="@+id/lw_zone_hit"'));
  });

  test(
    'no polling, no service, no periodic work, no new receiver, no network',
    () {
      final manifest = _read('android/app/src/main/AndroidManifest.xml');
      for (final info in Directory('$_res/xml').listSync().whereType<File>()) {
        if (!info.path.contains('widget')) continue;
        expect(
          _read(info.path),
          contains('android:updatePeriodMillis="0"'),
          reason: info.path,
        );
      }
      expect(manifest, isNot(contains('CONFIGURATION_CHANGED')));
      expect(manifest, isNot(contains('LauncherWidget')));
      for (final file in [
        '$_kt/LauncherWidgetImages.kt',
        '$_kt/LauncherWidgets.kt',
      ]) {
        final text = _read(file);
        for (final forbidden in [
          'WorkManager',
          'PeriodicWork',
          'Timer',
          'postDelayed',
          'registerReceiver',
          'startService',
          'startForegroundService',
          'HttpURLConnection',
          'okhttp',
        ]) {
          expect(text, isNot(contains(forbidden)), reason: '$file: $forbidden');
        }
      }
      // The one-shot expiry worker that already existed is the only one.
      expect(
        _read('$_kt/HermesWidgetExpiryWorker.kt'),
        contains('OneTimeWorkRequestBuilder'),
      );
      expect(
        _read('$_kt/HermesWidgetExpiryWorker.kt'),
        isNot(contains('PeriodicWorkRequest')),
      );
      for (final file in Directory(_dart).listSync().whereType<File>()) {
        final text = _read(file.path);
        for (final forbidden in [
          'Timer(',
          'Timer.periodic',
          'Stream.periodic',
          'Isolate.',
          'dart:io\' show HttpClient',
          'HttpClient(',
          'http.get',
          'WorkManager',
        ]) {
          expect(
            text,
            isNot(contains(forbidden)),
            reason: '${file.path}: $forbidden',
          );
        }
      }
      // Redraws come from events the app already had.
      final app = _read('$_kt/HermesApplication.kt');
      expect(
        app,
        contains(
          'override fun onConfigurationChanged(newConfig: Configuration)',
        ),
      );
      expect(
        app,
        contains(
          'LauncherWidgets.requestUpdate(this, launcherWidgetReceivers())',
        ),
      );
      final activity = _read('$_kt/MainActivity.kt');
      expect(activity, contains('LauncherWidgetSizes.onChanged = {'));
      expect(activity, contains('LauncherWidgetSizes.onChanged = null'));
      expect(activity, contains('"hermes/launcher_widgets"'));
    },
  );

  test('the app publishes on its own events only', () {
    final main = _read('lib/main.dart');
    expect(main, contains('_configureLauncherWidgetImages();'));
    expect(
      main,
      contains('LauncherWidgetImagePublisher.instance.configure(null)'),
    );
    final hooks = RegExp(
      r'_redrawLauncherWidgets\(\);',
    ).allMatches(main).length;
    // Resume, look & feel, brightness, theme list, font, text scale, locales, app language.
    expect(hooks, greaterThanOrEqualTo(8));
    expect(main, contains('void didChangeTextScaleFactor()'));
    expect(main, contains('void didChangeLocales(List<Locale>? locales)'));
    for (final file in [
      'lib/core/services/home_widget_publisher.dart',
      'lib/core/services/launcher_widget_cron.dart',
    ]) {
      expect(
        _read(file),
        contains(
          'if (LauncherWidgetImagePublisher.instance.request()) return;',
        ),
        reason: file,
      );
    }
    final images = _read('$_dart/launcher_widget_images.dart');
    expect(images, contains("if (call.method == 'sizesChanged') request();"));
  });

  test(
    'Bots and Salas are retired without an orphan, in resources and tools',
    () {
      final manifest = _read('android/app/src/main/AndroidManifest.xml');
      final receivers = RegExp(
        r'android:name="\.(\w+WidgetProvider)"',
      ).allMatches(manifest).map((m) => m.group(1)).toList();
      expect(receivers, [
        'NewSessionWidgetProvider',
        'HermesCompactWidgetProvider',
        'HermesControlWidgetProvider',
        'HermesCronWidgetProvider',
        'HermesTasksWidgetProvider',
        'HermesChatsWidgetProvider',
      ]);
      for (final name in receivers) {
        expect(
          _read('$_kt/NewSessionWidgetProvider.kt'),
          contains('class $name'),
        );
      }
      expect(_read('tool/qa/widget_shots.py'), isNot(contains('preview_bots')));
      expect(_read('tool/qa/widget_scenes.py'), isNot(contains('bots_shots')));
      // Every publisher the Dart side names is a receiver of the manifest.
      for (final providers in lwProviders.values) {
        for (final provider in providers) {
          expect(
            receivers,
            contains(provider.split('.').last),
            reason: provider,
          );
        }
      }
    },
  );

  test(
    'every lwp word is in the nine languages with the same placeholders',
    () {
      final es =
          jsonDecode(_read('lib/l10n/app_es.arb')) as Map<String, dynamic>;
      final keys = es.keys.where((k) => k.startsWith('lwp')).toList();
      expect(keys.length, greaterThanOrEqualTo(70));
      for (final locale in ['en', 'de', 'fr', 'it', 'pt', 'ja', 'ko', 'zh']) {
        final other =
            jsonDecode(_read('lib/l10n/app_$locale.arb'))
                as Map<String, dynamic>;
        for (final key in keys) {
          expect(other[key], isA<String>(), reason: '$locale lacks $key');
          expect(
            other['@$key'],
            es['@$key'],
            reason: '$locale: metadata of $key',
          );
          // The placeholders declared in the metadata: every language uses
          // only those (a plural's case words are not placeholders).
          final meta = es['@$key'] as Map<String, dynamic>?;
          final declared =
              ((meta?['placeholders'] as Map<String, dynamic>?) ?? const {})
                  .keys
                  .toSet();
          final words = RegExp(
            r'\{(\w+)\}',
          ).allMatches(other[key] as String).map((m) => m.group(1)!).toSet();
          final plural = RegExp(
            r'^\{(\w+),\s*plural',
          ).firstMatch(other[key] as String)?.group(1);
          final used = {...words.where(declared.contains), ?plural};
          expect(
            used,
            declared,
            reason: '$locale: $key uses other placeholders than es',
          );
        }
      }
    },
  );
}
