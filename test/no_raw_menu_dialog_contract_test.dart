import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every menu, every select and every dialog of the app is shown by the
/// helpers of `lib/core/design/modal.dart`, so all of them get the same floating tone,
/// their scrim, the exit that recedes and — when they can be dismissed — the
/// drag away. A raw Material menu or dialog has none of that.
void main() {
  test('no raw popup menu, dropdown, menu or dialog outside the shared '
      'helpers', () {
    final lib = Directory('lib');
    expect(lib.existsSync(), isTrue, reason: 'lib must exist');

    final violations = <String>[];
    for (final entity in lib.listSync(recursive: true, followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final path = entity.path.replaceAll(r'\', '/');
      // The helpers themselves.
      if (path == 'lib/core/design/modal.dart') continue;
      final source = _withoutComments(entity.readAsStringSync());
      for (final match in _raw.allMatches(source)) {
        final line = '\n'.allMatches(source.substring(0, match.start)).length;
        violations.add('$path:${line + 1} ${match.group(1)}');
      }
    }

    expect(
      violations,
      isEmpty,
      reason:
          'Use HermesMenuButton / showHermesMenu for a menu, '
          'HermesSelectField / showHermesOptions for a select and '
          'showHermesDialog / showHermesDialogRoute / hermesDialogRoute / '
          'showHermesSurface for a dialog:\n${violations.join('\n')}',
    );
  });
}

final _raw = RegExp(
  r'\b(PopupMenuButton|showMenu|showButtonMenu|showDialog|showGeneralDialog|'
  r'showAdaptiveDialog|showCupertinoDialog|showCupertinoModalPopup|'
  r'showAboutDialog|showTimePicker|showDatePicker|showDateRangePicker|'
  r'DialogRoute|RawDialogRoute|CupertinoDialogRoute|'
  r'DropdownButton|DropdownButtonFormField|DropdownMenu)'
  r'\s*(?:<[^>{}()]*>)?\s*\(',
);

String _withoutComments(String source) {
  return source
      .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')
      .replaceAll(RegExp(r'//[^\r\n]*'), '');
}
