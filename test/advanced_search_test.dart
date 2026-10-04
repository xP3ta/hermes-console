// Settings search inside Advanced: an in-memory filter over what is already
// loaded, never a request.
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/settings/advanced_search.dart';
import 'package:hermes_android/core/settings/server_config_pages.dart';

AdvancedSearchEntry _entry(
  String title, {
  String? group,
  List<String>? extra,
}) => AdvancedSearchEntry(
  title: title,
  group: group,
  extra: extra ?? const [],
  target: const AdvancedPageTarget(ServerConfigPage.mainModel),
);

void main() {
  final entries = [
    _entry(
      'Reasoning effort',
      group: 'Main model',
      extra: ['agent.reasoning_effort'],
    ),
    _entry(
      'Show reasoning',
      group: 'Behavior',
      extra: ['display.show_reasoning'],
    ),
    _entry('Persistent shell', group: 'Shell'),
    _entry('Esfuerzo de razonamiento', group: 'Modelo principal'),
  ];

  test('an empty or blank query matches nothing', () {
    expect(searchAdvanced(entries, ''), isEmpty);
    expect(searchAdvanced(entries, '   '), isEmpty);
  });

  test('matches case-insensitively on the title', () {
    expect(searchAdvanced(entries, 'REASONING').map((e) => e.title), [
      'Reasoning effort',
      'Show reasoning',
    ]);
  });

  test('matches the Spanish text too', () {
    expect(searchAdvanced(entries, 'razonamiento').map((e) => e.title), [
      'Esfuerzo de razonamiento',
    ]);
  });

  test('every word has to match, in any order', () {
    expect(searchAdvanced(entries, 'effort reasoning'), hasLength(1));
    expect(searchAdvanced(entries, 'effort shell'), isEmpty);
  });

  test('also matches the page title and the dotted path', () {
    expect(searchAdvanced(entries, 'behavior').single.title, 'Show reasoning');
    expect(
      searchAdvanced(entries, 'display.show').single.title,
      'Show reasoning',
    );
  });

  test('a search that matches nothing is empty', () {
    expect(searchAdvanced(entries, 'zzz'), isEmpty);
  });
}
