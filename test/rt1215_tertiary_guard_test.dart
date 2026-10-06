// rt1215: `textDisabled` is the ink of a control that cannot be used right
// now (WCAG 1.4.3 exempts inactive components). Read-only text such as
// timestamps, counters, captions or hunk headers uses `textTertiary`, which
// reaches AA in every theme. This guard finds every text style that paints
// `textDisabled` and only lets through the listed disabled-control labels.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Text styles that may paint `textDisabled`: each one is the label of a
/// control while it is disabled (`onTap == null`, `enabled: false`,
/// `onChanged: null`). File → number of such styles.
const Map<String, int> _disabledControlLabels = {
  // Model row the active source cannot use (InkWell onTap: null), in the
  // session model sheet since the picker moved out of the chat screen.
  'lib/core/widgets/session_model_sheet.dart': 1,
  // Loop switch label under reduce motion, Stop button while idle.
  'lib/core/screens/companion/mascotas_screen.dart': 2,
  // Stop-agent action while the local agent is not running.
  'lib/core/screens/local_instance_control_screen.dart': 1,
  // Maintenance row subtitle while the action is unavailable.
  'lib/core/screens/settings_screen.dart': 1,
  // Voice engine tile while the engine is not installed.
  'lib/core/screens/voice_settings_screen.dart': 1,
  // Profile quick action without a handler.
  'lib/core/bots/ui/profile/bot_profile_screen.dart': 1,
  // Disabled option in the shared option sheet.
  'lib/core/design/modal.dart': 1,
  // Dock destination while it is unavailable.
  'lib/core/widgets/dock.dart': 1,
  // New-chat drawer entry while there is no connection.
  'lib/core/widgets/hermes_drawer.dart': 1,
  // Switch tile title/subtitle and the action button while disabled.
  'lib/core/widgets/hermes_ui.dart': 3,
  // Project action while it is not allowed.
  'lib/core/widgets/projects/project_actions.dart': 1,
};

/// Calls whose `color`/`foregroundColor` paints text.
bool _isTextStyleCall(String callee) =>
    callee == 'TextStyle' ||
    callee == 'TextSpan' ||
    callee.endsWith('copyWith') ||
    callee.endsWith('styleFrom');

/// Name of the innermost call around [offset] (`TextStyle`, `x.copyWith`).
String? _enclosingCall(String src, int offset) {
  var depth = 0;
  for (var i = offset - 1; i >= 0; i--) {
    final ch = src[i];
    if (ch == ')' || ch == ']' || ch == '}') {
      depth++;
    } else if (ch == '(' || ch == '[' || ch == '{') {
      if (depth > 0) {
        depth--;
        continue;
      }
      if (ch != '(') return null;
      final m = RegExp(
        r'([A-Za-z_][A-Za-z0-9_.]*)\s*$',
      ).firstMatch(src.substring(0, i));
      return m?.group(1);
    }
  }
  return null;
}

/// The named argument that holds [offset] (`color`, `disabledForegroundColor`).
String? _namedArgument(String src, int offset) {
  final before = src.substring(0, offset);
  final m = RegExp(r'([A-Za-z_]+)\s*:[^:,()]*$').firstMatch(before);
  return m?.group(1);
}

Map<String, int> textDisabledTextStyles(Directory lib) {
  final hits = <String, int>{};
  final files =
      lib
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  for (final file in files) {
    final root = lib.path.replaceAll('\\', '/');
    final path = file.path.replaceAll('\\', '/');
    final rel = 'lib${path.substring(root.length)}';
    if (rel.startsWith('lib/core/theme/') || rel.startsWith('lib/l10n/')) {
      continue;
    }
    final src = file.readAsStringSync();
    for (final m in RegExp(r'\btextDisabled\b').allMatches(src)) {
      final lineStart = src.lastIndexOf('\n', m.start) + 1;
      if (src.substring(lineStart, m.start).trimLeft().startsWith('//')) {
        continue;
      }
      final callee = _enclosingCall(src, m.start);
      if (callee == null || !_isTextStyleCall(callee)) continue;
      final arg = _namedArgument(src, m.start);
      if (arg != null && arg.startsWith('disabled')) continue;
      hits[rel] = (hits[rel] ?? 0) + 1;
    }
  }
  return hits;
}

void main() {
  test('read-only text never paints textDisabled', () {
    final hits = textDisabledTextStyles(Directory('lib'));
    final unexpected = <String>[];
    hits.forEach((file, count) {
      final allowed = _disabledControlLabels[file] ?? 0;
      if (count > allowed) {
        unexpected.add(
          '$file: $count text styles use textDisabled '
          '(allowed $allowed for disabled controls); use textTertiary',
        );
      }
    });
    expect(unexpected, isEmpty, reason: unexpected.join('\n'));
  });

  test('the disabled-control allowlist has no stale entries', () {
    final hits = textDisabledTextStyles(Directory('lib'));
    final stale = <String>[
      for (final e in _disabledControlLabels.entries)
        if ((hits[e.key] ?? 0) != e.value)
          '${e.key}: listed ${e.value}, found ${hits[e.key] ?? 0}',
    ];
    expect(stale, isEmpty, reason: stale.join('\n'));
  });

  test('the scanner sees text styles and skips icons and disabled slots', () {
    final dir = Directory.systemTemp.createTempSync('rt1215_guard');
    addTearDown(() => dir.deleteSync(recursive: true));
    final lib = Directory('${dir.path}/lib/x')..createSync(recursive: true);
    File('${lib.path}/a.dart').writeAsStringSync('''
final a = Text('10:00', style: TextStyle(color: c.textDisabled));
final b = Text('x', style: base.copyWith(color: c.textDisabled));
final i = Icon(Icons.close, color: c.textDisabled);
final t = TextButton.styleFrom(disabledForegroundColor: c.textDisabled);
// TextStyle(color: c.textDisabled) in a comment
''');
    expect(textDisabledTextStyles(Directory('${dir.path}/lib')), {
      'lib/x/a.dart': 2,
    });
  });
}
