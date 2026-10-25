// SPDX-License-Identifier: GPL-3.0-only
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// i18n-approval (emulator QA H5): the Chats launcher widget names an
/// untitled chat with the [Strings] it is offered; without them it falls
/// back to the Spanish source title. Every screen that feeds it says the
/// app language.
void main() {
  test('every offer to the Chats launcher widget carries the app strings', () {
    const call = 'LauncherWidgetChatsPublisher.instance.offer(';
    final offers = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final source = entity.readAsStringSync();
      for (var at = source.indexOf(call); at >= 0;) {
        // The call's arguments, up to its closing parenthesis.
        var depth = 0;
        var end = at + call.length - 1;
        for (; end < source.length; end++) {
          if (source[end] == '(') depth++;
          if (source[end] == ')' && --depth == 0) break;
        }
        final path = entity.path.replaceAll(r'\', '/');
        offers.add(path);
        expect(
          source.substring(at, end),
          contains('strings: '),
          reason: '$path offers chats without the app strings',
        );
        at = source.indexOf(call, end);
      }
    }
    expect(offers, isNotEmpty, reason: 'the scan found the call sites');
  });
}
