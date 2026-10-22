// POST /api/gateway/restart now passes --interrupt (Hermes >= 0.22.4): the
// confirm dialog must say running turns are interrupted (this chat too) and
// can be resent, in every catalog.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

const _interruptWord = <String, String>{
  'es': 'Interrumpe',
  'en': 'Interrupts',
  'de': 'unterbrochen',
  'fr': 'Interrompt',
  'it': 'Interrompe',
  'pt': 'Interrompe',
  'ja': '中断',
  'ko': '중단',
  'zh': '中断',
};

// The old wording that understated the effect.
const _oldWording = <String, String>{
  'es': 'brevemente',
  'en': 'Briefly',
  'de': 'kurzzeitig',
  'fr': 'brièvement',
  'it': 'brevemente',
  'pt': 'brevemente',
  'ja': '一時的に切れ',
  'ko': '잠시 끊',
  'zh': '短暂',
};

void main() {
  test('covers every supported locale', () {
    expect(
      Strings.supportedLocales.map((l) => l.languageCode).toSet(),
      _interruptWord.keys.toSet(),
    );
  });

  for (final code in _interruptWord.keys) {
    test('$code: restart body says running turns are interrupted', () async {
      final strings = await Strings.delegate.load(Locale(code));
      final body = strings.setRestartGatewayBody;
      expect(body, contains(_interruptWord[code]!), reason: code);
      expect(body, isNot(contains(_oldWording[code]!)), reason: code);
      // Plain text: no ICU placeholders or leftover braces, intro kept.
      expect(body, isNot(contains('{')), reason: code);
      expect(body, isNot(contains('}')), reason: code);
      expect(body, contains('\n\n'), reason: code);
    });
  }
}
