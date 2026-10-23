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

// These consequences must survive locale merges, not just the verb "interrupt".
const _requiredConsequences = <String, List<String>>{
  'es': ['turnos en curso', 'este chat', 'volver a enviar'],
  'en': ['running turns', 'this chat', 'resend'],
  'de': ['Laufende Antworten', 'diesem Chat', 'erneut senden'],
  'fr': ['tours en cours', 'ce chat', 'renvoyer'],
  'it': ['turni in corso', 'questa chat', 'reinviar'],
  'pt': ['turnos em andamento', 'deste chat', 'reenvi'],
  'ja': ['実行中のターン', 'このチャット', '再送'],
  'ko': ['진행 중인 턴', '이 채팅', '다시 보낼'],
  'zh': ['正在进行的回合', '当前聊天', '重新发送'],
};

bool _hasRequiredConsequences(String code, String body) =>
    _requiredConsequences[code]!.every(body.contains);

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
    expect(_requiredConsequences.keys.toSet(), _interruptWord.keys.toSet());
  });

  for (final code in _interruptWord.keys) {
    test('$code: restart body says running turns are interrupted', () async {
      final strings = await Strings.delegate.load(Locale(code));
      final body = strings.setRestartGatewayBody;
      expect(body, contains(_interruptWord[code]!), reason: code);
      expect(body, isNot(contains(_oldWording[code]!)), reason: code);
      expect(_hasRequiredConsequences(code, body), isTrue, reason: code);
      // Plain text: no ICU placeholders or leftover braces, intro kept.
      expect(body, isNot(contains('{')), reason: code);
      expect(body, isNot(contains('}')), reason: code);
      expect(body, contains('\n\n'), reason: code);
    });
  }

  test('the semantic guard rejects session-only and incomplete warnings', () async {
    const oldPortuguese = 'Interrompe brevemente as sessões ativas. Continuar?';
    expect(_hasRequiredConsequences('pt', oldPortuguese), isFalse);
    for (final code in _requiredConsequences.keys) {
      final body = (await Strings.delegate.load(Locale(code))).setRestartGatewayBody;
      for (final consequence in _requiredConsequences[code]!) {
        final mutant = body.replaceAll(consequence, '');
        expect(_hasRequiredConsequences(code, mutant), isFalse,
            reason: '$code must retain $consequence');
      }
    }
  });
}
