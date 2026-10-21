// C3a: the published app is Dashboard-only, so no text of it may send a
// person to the retired setup script or to the Gateway key. Only the
// "remove the old bridge" help (D-C3-2) still names the old assistant.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _forbidden = [
  'hermes-mobile-setup',
  'hermes-pair',
  'API_SERVER_KEY',
  'openssl rand',
];

const _allowedFile = 'lib/core/widgets/legacy_bridge_removal_help.dart';

bool _generated(String path) => path.split('/').last.startsWith('app_local');

void main() {
  test('no lib file but the bridge-removal help names the old script', () {
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File) continue;
      final path = entity.path.replaceAll(r'\', '/');
      if (_generated(path) || path == _allowedFile) continue;
      if (!path.endsWith('.dart') && !path.endsWith('.arb')) continue;
      // Comments are not shown to anyone; code and message text are.
      final text = entity
          .readAsLinesSync()
          .where((line) => !line.trimLeft().startsWith('//'))
          .join('\n');
      for (final word in _forbidden) {
        if (text.contains(word)) offenders.add('$path: $word');
      }
    }
    expect(offenders, isEmpty);
  });

  test('the old script is still named, once, where the bridge is removed', () {
    final text = File(_allowedFile).readAsStringSync();
    expect(text, contains('hermes-mobile-setup'));
    expect(text, contains('--retire-bridge'));
  });

  test('EN and ES have exactly the same message keys', () {
    Map<String, dynamic> read(String name) =>
        jsonDecode(File('lib/l10n/$name').readAsStringSync())
            as Map<String, dynamic>;
    // `@key` entries are metadata, which each file keeps only where needed.
    Set<String> keys(String name) =>
        read(name).keys.where((k) => !k.startsWith('@')).toSet();
    final en = keys('app_en.arb');
    final es = keys('app_es.arb');
    expect(en.difference(es), isEmpty, reason: 'only in EN');
    expect(es.difference(en), isEmpty, reason: 'only in ES');
  });
}
