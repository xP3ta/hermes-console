import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the Console launcher, splash and notification resources: one icon
/// for every flavor, an Android 13 themed layer, and a white status-bar icon.
void main() {
  const res = 'android/app/src/main/res';

  test('adaptive icons declare background, foreground and monochrome', () {
    for (final name in ['ic_launcher', 'ic_launcher_round']) {
      final xml = File('$res/mipmap-anydpi-v26/$name.xml').readAsStringSync();
      expect(xml, contains('@drawable/ic_launcher_background'), reason: name);
      expect(xml, contains('@drawable/ic_launcher_foreground'), reason: name);
      expect(xml, contains('<monochrome'), reason: name);
      expect(xml, contains('@drawable/ic_launcher_monochrome'), reason: name);
    }
    for (final layer in [
      'ic_launcher_background',
      'ic_launcher_foreground',
      'ic_launcher_monochrome',
    ]) {
      expect(File('$res/drawable/$layer.xml').existsSync(), isTrue);
    }
  });

  test('legacy launcher PNGs exist for every density', () {
    for (final density in ['mdpi', 'hdpi', 'xhdpi', 'xxhdpi', 'xxxhdpi']) {
      for (final name in ['ic_launcher', 'ic_launcher_round']) {
        expect(
          File('$res/mipmap-$density/$name.png').existsSync(),
          isTrue,
          reason: '$density/$name',
        );
      }
    }
  });

  test('no flavor or build type overrides the launcher icon', () {
    // Owner rule: the same icon on Play, full and QA builds.
    final overrides = Directory('android/app/src')
        .listSync()
        .whereType<Directory>()
        .where((dir) => !dir.path.endsWith('/main'))
        .expand((dir) => dir.listSync(recursive: true))
        .whereType<File>()
        .map((file) => file.path)
        .where(
          (path) =>
              path.contains('/ic_launcher') || path.contains('/splash_logo'),
        )
        .toList();
    expect(overrides, isEmpty);
  });

  test('status-bar icon is a white silhouette', () {
    final xml = File('$res/drawable/ic_stat_hermes.xml').readAsStringSync();
    final colors = RegExp(
      r'android:(?:fill|stroke)Color="(#[0-9A-Fa-f]+)"',
    ).allMatches(xml).map((m) => m.group(1)!.toUpperCase()).toSet();
    expect(colors, isNotEmpty);
    for (final color in colors) {
      final rgb = color.length == 9 ? color.substring(3) : color.substring(1);
      final alpha = color.length == 9 ? color.substring(1, 3) : 'FF';
      expect(
        rgb == 'FFFFFF' || alpha == '00',
        isTrue,
        reason: 'status-bar icons must be white or transparent, got $color',
      );
    }
  });

  test('splash uses the Console mark on graphite in light and dark', () {
    for (final dir in ['values-v31', 'values-night-v31']) {
      final styles = File('$res/$dir/styles.xml').readAsStringSync();
      expect(styles, contains('@drawable/splash_logo'), reason: dir);
      expect(styles, contains('@color/splash_background'), reason: dir);
    }
    for (final dir in ['values', 'values-night']) {
      final colors = File('$res/$dir/colors.xml').readAsStringSync();
      expect(
        colors,
        contains('<color name="splash_background">#26262A</color>'),
        reason: dir,
      );
    }
    expect(File('$res/drawable-nodpi/splash_logo.png').existsSync(), isTrue);
  });
}
