import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/mission_bot_routine_sheet.dart';

void main() {
  test('routine copy resolves all languages, regions and unknown locales', () {
    const titles = {
      'es': 'Nueva rutina',
      'en': 'New routine',
      'pt': 'Nova rotina',
      'de': 'New routine',
      'fr': 'New routine',
      'it': 'New routine',
      'ja': 'New routine',
      'ko': 'New routine',
      'zh': 'New routine',
      'xx': 'New routine',
    };
    for (final entry in titles.entries) {
      final copy = MissionBotRoutineSheetCopy.forLocale(Locale(entry.key));
      expect(copy.title, entry.value, reason: entry.key);
      expect(copy.whatRequired, isNotEmpty, reason: entry.key);
    }
    expect(
      MissionBotRoutineSheetCopy.forLocale(const Locale('pt', 'PT')).title,
      'Nova rotina',
    );
    expect(MissionBotRoutineSheetCopy.es.title, 'Nueva rutina');
    expect(MissionBotRoutineSheetCopy.en.title, 'New routine');
    expect(MissionBotRoutineSheetCopy.pt.title, 'Nova rotina');
  });
}
