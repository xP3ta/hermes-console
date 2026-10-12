import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/utils/chat_ask_about.dart';

void main() {
  group('ask about this quote', () {
    test('quotes every line with "> " and trims the selection', () {
      expect(
        buildAskAboutQuote('  \n first line \nsecond line\n\n third  \n '),
        '> first line\n> second line\n>\n> third',
      );
    });

    test('a blank selection yields no quote', () {
      expect(buildAskAboutQuote('  \n\t '), isEmpty);
    });

    test('caps long selections with an ellipsis', () {
      final quote = buildAskAboutQuote('a' * 5000);
      expect(quote, '> ${'a' * askAboutQuoteMaxChars}…');
      final short = buildAskAboutQuote('abcdef', maxChars: 3);
      expect(short, '> abc…');
    });

    test('an empty composer gets the quote, a blank line and the cursor', () {
      final value = insertQuoteIntoComposer(TextEditingValue.empty, '> hi');
      expect(value.text, '> hi\n\n');
      expect(value.selection, const TextSelection.collapsed(offset: 6));
    });

    test('existing composer text is kept and the quote follows it', () {
      final value = insertQuoteIntoComposer(
        const TextEditingValue(
          text: 'my draft  \n',
          selection: TextSelection.collapsed(offset: 2),
        ),
        '> hi',
      );
      expect(value.text, 'my draft\n\n> hi\n\n');
      expect(
        value.selection,
        TextSelection.collapsed(offset: value.text.length),
      );
    });
  });
}
