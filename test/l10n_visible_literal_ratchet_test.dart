import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/l10n_visible_literals.dart';

void main() {
  test('new visible literals use Strings.of(context)', () {
    final raw = jsonDecode(File('tool/l10n/visible_literal_allowlist.json').readAsStringSync()) as List;
    final allowed = <String>{};
    for (final value in raw) {
      final entry = value as Map<String, dynamic>;
      final path = entry['file'] as String;
      final literal = entry['literal'] as String;
      expect(path, startsWith('lib/'));
      expect(path, isNot(contains('*')));
      expect((entry['reason'] as String).trim(), isNotEmpty);
      expect(allowed.add('$path: $literal'), isTrue, reason: 'Duplicate exception');
    }
    final actual = <String>{};
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final path = entity.path.replaceAll(r'\', '/');
      if (RegExp(r'^lib/l10n/app_localizations(?:_(?:es|en|pt|de|fr|it|ja|ko|zh))?\.dart$').hasMatch(path)) {
        continue;
      }
      for (final literal in visibleDartLiterals(entity.readAsStringSync())) {
        actual.add('$path: $literal');
      }
    }
    expect(
      actual.difference(allowed),
      isEmpty,
      reason: 'Use Strings.of(context) for visible copy. Exceptions require an exact file, literal and reason.',
    );
    expect(allowed.difference(actual), isEmpty, reason: 'Remove stale visible-copy exceptions.');
  });

  test('visible arguments, dialogs and app notices reject unlisted copy', () {
    final surfaces = [
      "Text('New copy')", "SelectableText('New copy')", "TextSpan(text: 'New copy')",
      for (final property in ['label', 'title', 'subtitle', 'hint', 'hintText', 'labelText', 'helperText', 'tooltip', 'semanticLabel', 'semanticsLabel', 'content', 'errorText'])
        "CustomWidget($property: 'New copy')",
      "SnackBar(content: Text('New copy'))",
      "showDialog(builder: (_) => AlertDialog(title: Text('New copy')))",
      "showHermesDialog(title: 'New copy')",
      "showHermesReviewPage(text: 'New copy')",
      "HermesNoticeCard(message: 'New copy')",
      "IslandEvent(line: 'New copy')",
      "AppFeedback.of(context).notify(FeedbackKind.error, 'New copy')",
      for (final helper in ['_snack', '_toast', '_message', '_showMessage'])
        "$helper('New copy')",
      "Text(flag ? 'New copy' : strings.title)",
      r'''Text('${flag ? 'New copy' : name}')''',
      r'''Text('\u0048ello')''',
    ];
    for (final source in surfaces) {
      expect(visibleDartLiterals(source), isNotEmpty, reason: source);
    }
    // These words were translated in phase 6; uppercase does not make them IDs.
    for (final word in ['CODE', 'AUDIO', 'VIDEO', 'FILE']) {
      expect(visibleDartLiterals("Text('$word')"), isNotEmpty);
    }
  });

  test('keys, callbacks, source data, brands and localized composition stay out', () {
    final sources = [
      "final data = {'title': 'transport value'};",
      "return 'internal diagnostic';",
      "Text(strings.title, key: ValueKey('widget-id'), style: TextStyle(fontFamily: 'Inter'))",
      "CustomWidget(label: settings.getString('key'))",
      "CustomWidget(label: state == 'running' ? strings.running : strings.idle)",
      "CustomWidget(label: switch (state) {'running' => strings.running, _ => strings.idle})",
      "CustomWidget(content: [IconButton(onPressed: () => send('protocol-id'))])",
      "_SoulTemplate(content: 'Document written to SOUL.md')",
      "Text('Bot Chat')", "Text('SOUL')", "Text('Console')",
      "Text('https://example.invalid')", "Text('/tmp/example.md')",
      r'''Text('${strings.title} · $size MB')''',
      r'''Text('\n${strings.title}')''',
      "// Text('comment')\n/* Text('another comment') */",
    ];
    for (final source in sources) {
      expect(visibleDartLiterals(source), isEmpty, reason: source);
    }
  });
}
