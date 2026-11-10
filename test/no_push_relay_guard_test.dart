import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Console has no push relay and no Firebase: alerts with the app closed come
/// from the opt-in background listening. Nothing may bring them back unnoticed.
void main() {
  String read(String path) => File(path).readAsStringSync();

  test('Gradle builds no Firebase, Google services or Play Integrity', () {
    for (final path in [
      'android/settings.gradle.kts',
      'android/build.gradle.kts',
      'android/app/build.gradle.kts',
    ]) {
      final text = read(path).toLowerCase();
      expect(text, isNot(contains('firebase')), reason: path);
      expect(text, isNot(contains('google-services')), reason: path);
      expect(text, isNot(contains('com.google.gms')), reason: path);
      expect(text, isNot(contains('play:integrity')), reason: path);
    }
  });

  test('the manifest declares no messaging service or receiver', () {
    final manifest = read('android/app/src/main/AndroidManifest.xml');
    expect(manifest, isNot(contains('MESSAGING_EVENT')));
    expect(manifest, isNot(contains('firebase')));
    expect(manifest, isNot(contains('c2dm')));
  });

  test('no google-services.json in the tree', () {
    for (final path in [
      'android/app/google-services.json',
      'android/google-services.json',
      'google-services.json',
    ]) {
      expect(File(path).existsSync(), isFalse, reason: path);
    }
  });

  test('no push code in lib/ or the native sources', () {
    expect(Directory('lib/core/services/push').existsSync(), isFalse);
    final offenders = <String>[];
    for (final root in ['lib', 'android/app/src/main/kotlin']) {
      for (final entity in Directory(root).listSync(recursive: true)) {
        if (entity is! File) continue;
        final text = entity.readAsStringSync();
        if (text.contains('com.google.firebase') ||
            text.contains('FirebaseMessaging') ||
            text.contains('HERMES_' 'PUSH_')) {
          offenders.add(entity.path);
        }
      }
    }
    expect(offenders, isEmpty);
  });
}
