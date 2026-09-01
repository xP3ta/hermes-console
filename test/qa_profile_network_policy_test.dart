import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

String _withoutCommentsOrWhitespace(String xml) => xml
    .replaceAll(RegExp(r'<!--[\s\S]*?-->'), '')
    .replaceAll(RegExp(r'\s+'), '');

void main() {
  const profileManifestPath = String.fromEnvironment(
    'HERMES_QA_PROFILE_MANIFEST_OVERRIDE',
    defaultValue: 'android/app/src/profile/AndroidManifest.xml',
  );

  group('qaProfile network policy', () {
    test('enlaza la misma politica de red que release', () {
      final profileManifest = _read(profileManifestPath);
      final releaseManifest = _read(
        'android/app/src/release/AndroidManifest.xml',
      );

      for (final manifest in [profileManifest, releaseManifest]) {
        expect(
          manifest,
          contains(
            'android:networkSecurityConfig="@xml/network_security_config"',
          ),
        );
        expect(
          manifest,
          contains('tools:replace="android:networkSecurityConfig"'),
        );
      }
    });

    test('el resource profile es semanticamente igual al de release', () {
      final profilePolicy = _withoutCommentsOrWhitespace(
        _read('android/app/src/profile/res/xml/network_security_config.xml'),
      );
      final releasePolicy = _withoutCommentsOrWhitespace(
        _read('android/app/src/release/res/xml/network_security_config.xml'),
      );

      expect(profilePolicy, releasePolicy);
      expect(profilePolicy, contains('cleartextTrafficPermitted="true"'));
      expect(profilePolicy, contains('<certificatessrc="system"/>'));
    });

    test('main conserva el default de plataforma cerrado', () {
      final mainManifest = _read('android/app/src/main/AndroidManifest.xml');
      expect(mainManifest, contains('android:usesCleartextTraffic="false"'));
    });

    test('main elimina permisos implicitos del runtime LiteRT antiguo', () {
      final mainManifest = _withoutCommentsOrWhitespace(
        _read('android/app/src/main/AndroidManifest.xml'),
      );

      expect(
        mainManifest,
        contains('xmlns:tools="http://schemas.android.com/tools"'),
      );
      for (final permission in [
        'android.permission.READ_PHONE_STATE',
        'android.permission.READ_EXTERNAL_STORAGE',
      ]) {
        expect(
          mainManifest,
          contains(
            '<uses-permissionandroid:name="$permission"'
            'tools:node="remove"/>',
          ),
        );
      }
    });

    test('verificadores rechazan permisos implicitos en QA y Play', () {
      final qaVerifier = _read('tool/qa/verify_qa_profile_network_policy.sh');
      final releaseVerifier = _read('tool/qa/release_rehearsal.sh');

      for (final permission in [
        'android.permission.READ_PHONE_STATE',
        'android.permission.READ_EXTERNAL_STORAGE',
      ]) {
        expect(qaVerifier, contains(permission));
        expect(releaseVerifier, contains(permission));
      }
      expect(
        releaseVerifier,
        contains('android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK'),
      );
      expect(
        releaseVerifier,
        contains('android.permission.FOREGROUND_SERVICE_REMOTE_MESSAGING'),
      );
      expect(
        releaseVerifier,
        contains('dataSync|remoteMessaging|microphone|mediaPlayback'),
      );
    });

    test('el verificador resuelve la referencia compilada del resource', () {
      final verifier = _read('tool/qa/verify_qa_profile_network_policy.sh');

      expect(verifier, contains('dump xmltree --file AndroidManifest.xml'));
      expect(verifier, contains('network_config_id'));
      expect(verifier, contains('dump resources'));
      expect(verifier, contains('xml/network_security_config'));
    });

    test('el inventario ZIP no provoca SIGPIPE con grep temprano', () {
      final verifier = _read('tool/qa/verify_qa_profile_network_policy.sh');

      expect(verifier, contains('archive_entries='));
      expect(verifier, contains(r'unzip -Z1 "$apk" >"$archive_entries"'));
      expect(verifier, isNot(contains(r'unzip -Z1 "$apk" | grep')));
    });

    test('la limpieza normal cancela el trap antes de perder el scope', () {
      final verifier = _read('tool/qa/verify_qa_profile_network_policy.sh');

      expect(verifier, contains(r'rm -rf -- "$scratch"'));
      expect(verifier, contains('trap - EXIT'));
    });
  });
}
