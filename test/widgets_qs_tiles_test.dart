import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _main = 'android/app/src/main';
const _locales = ['es', 'pt', 'de', 'fr', 'it', 'ja', 'ko', 'zh'];
const _tiles = {
  'HermesNewChatTileService': ('widgets_qs_new_chat_label', 'COMPOSER'),
  'HermesVoiceChatTileService': ('widgets_qs_voice_chat_label', 'VOICE'),
  'HermesCameraChatTileService': ('widgets_qs_camera_chat_label', 'CAMERA'),
};

String _read(String path) => File('$_main/$path').readAsStringSync();

String _tileBlock(String manifest, String service) {
  final start = manifest.indexOf('android:name=".$service"');
  expect(start, isNonNegative, reason: '$service is declared');
  final from = manifest.lastIndexOf('<service', start);
  return manifest.substring(from, manifest.indexOf('</service>', start));
}

void main() {
  test('each tile is a bound-by-system service with its own label', () {
    final manifest = _read('AndroidManifest.xml');
    for (final entry in _tiles.entries) {
      final block = _tileBlock(manifest, entry.key);
      expect(
        block,
        contains(
          'android:permission="android.permission.BIND_QUICK_SETTINGS_TILE"',
        ),
      );
      expect(block, contains('android.service.quicksettings.action.QS_TILE'));
      expect(block, contains('android:label="@string/${entry.value.$1}"'));
      expect(block, contains('android:exported="true"'));
      final icon = RegExp(r'@drawable/(\w+)').firstMatch(block)!.group(1);
      expect(File('$_main/res/drawable/$icon.xml').existsSync(), isTrue);
    }
  });

  test('tiles ask for no new permission', () {
    final manifest = _read('AndroidManifest.xml');
    // The bind permission is only an attribute of the service, never a
    // <uses-permission> the app requests.
    expect(
      manifest,
      isNot(
        contains(
          'uses-permission android:name="android.permission.BIND_QUICK_SETTINGS_TILE"',
        ),
      ),
    );
    expect(manifest, isNot(contains('STATUS_BAR')));
  });

  test('tiles launch through the secret-free launch contract', () {
    final kotlin = _read(
      'kotlin/com/hermesagent/hermes_android/HermesQuickTiles.kt',
    );
    expect(kotlin, contains('NewSessionLaunchContract.newIntent('));
    expect(kotlin, contains('NewSessionLaunchContract.SOURCE_WIDGET'));
    expect(kotlin, contains('unlockAndRun'));
    expect(kotlin, contains('Build.VERSION.SDK_INT >= 34'));
    expect(kotlin, contains('PendingIntent.FLAG_IMMUTABLE'));
    for (final entry in _tiles.entries) {
      expect(
        kotlin,
        contains(
          'class ${entry.key} : HermesQuickTileService('
          'NewSessionLaunchTarget.${entry.value.$2})',
        ),
      );
    }
    final lower = kotlin.toLowerCase();
    for (final word in ['api_key', 'bearer', 'gateway_url', 'prompt_text']) {
      expect(lower, isNot(contains(word)));
    }
  });

  test('tile labels exist in all nine languages and are real translations', () {
    final seen = <String, Set<String>>{};
    for (final dir in ['values', for (final l in _locales) 'values-$l']) {
      final xml = _read('res/$dir/launcher_widgets_strings.xml');
      for (final tile in _tiles.values) {
        final match = RegExp(
          '<string name="${tile.$1}">([^<]+)</string>',
        ).firstMatch(xml);
        expect(match, isNotNull, reason: '$dir ${tile.$1}');
        seen.putIfAbsent(tile.$1, () => {}).add(match!.group(1)!);
      }
    }
    for (final entry in seen.entries) {
      // Spanish and Portuguese may legitimately coincide.
      expect(entry.value.length, greaterThanOrEqualTo(8), reason: entry.key);
    }
  });
}
