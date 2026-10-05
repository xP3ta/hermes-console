import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/utils/chat_quick_replies.dart';
import 'package:hermes_android/l10n/app_localizations_en.dart';
import 'package:hermes_android/l10n/app_localizations_es.dart';

void main() {
  final es = StringsEs();
  final en = StringsEn();

  group('heuristic quick replies', () {
    test('a closing question offers yes / no / explain more', () {
      expect(
        heuristicQuickReplies(
          'Lo he revisado.\n\n¿Quieres que lo aplique?',
          es,
        ),
        ['Sí', 'No', 'Explícamelo más'],
      );
      expect(heuristicQuickReplies('Done. Should I apply it?  ', en), [
        'Yes',
        'No',
        'Explain it in more detail',
      ]);
    });

    test('a proposed plan offers go ahead / step by step', () {
      const plan =
          'Plan:\n\n1. Crear la tabla\n2. Migrar datos\n3. Borrar la vieja';
      expect(heuristicQuickReplies(plan, es), [
        'Adelante',
        'Hazlo paso a paso',
      ]);
      expect(heuristicQuickReplies(plan, en), [
        'Go ahead',
        'Do it step by step',
      ]);
    });

    test('code or a diff offers run tests / review changes', () {
      const code = 'Cambiado:\n\n```dart\nvoid main() {}\n```\nListo.';
      expect(heuristicQuickReplies(code, es), [
        'Ejecuta los tests',
        'Revisa los cambios',
      ]);
      const diff = 'Applied:\n--- a/x.dart\n+++ b/x.dart\n@@ -1 +1 @@\n-a\n+b';
      expect(heuristicQuickReplies(diff, en), [
        'Run the tests',
        'Review the changes',
      ]);
    });

    test('anything else offers continue / summarize', () {
      expect(heuristicQuickReplies('Here is the overview of X.', en), [
        'Continue',
        'Summarize it',
      ]);
      expect(heuristicQuickReplies('Este es el resumen.', es), [
        'Continúa',
        'Resúmelo',
      ]);
    });

    test('an empty answer offers nothing', () {
      expect(heuristicQuickReplies('   ', es), isEmpty);
    });
  });

  group('smart quick replies parsing', () {
    test('keeps up to three short clean lines', () {
      expect(
        parseSmartQuickReplies(
          '1. "Sí, hazlo"\n- Muéstrame el diff\n\n* ¿Y los tests?\nOtra más',
        ),
        ['Sí, hazlo', 'Muéstrame el diff', '¿Y los tests?'],
      );
    });

    test('drops overlong lines, duplicates and blanks', () {
      expect(parseSmartQuickReplies('ok\nOK\n${'x' * 200}\n  \nvale'), [
        'ok',
        'vale',
      ]);
    });

    test('the prompt input carries only truncated last messages', () {
      final input = smartQuickReplyInput(
        lastAssistant: 'A' * 5000,
        lastUser: 'U' * 5000,
      );
      expect(input.length, lessThan(2600));
      expect(input, contains('A' * 100));
      expect(input, contains('U' * 100));
    });
  });
}
