import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('only the transport adapter imports flutter_webrtc', () {
    final importers = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.readAsStringSync().contains('package:flutter_webrtc')) {
        importers.add(entity.path);
      }
    }
    expect(importers, [
      'lib/core/services/voice/live/flutter_webrtc_transport.dart',
    ]);
  });
}
