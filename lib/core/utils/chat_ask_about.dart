import 'package:flutter/widgets.dart';

/// Longest selection "Ask about this" quotes before cutting with an ellipsis.
const int askAboutQuoteMaxChars = 2000;

/// Markdown quote of a transcript selection: trimmed, capped at [maxChars]
/// (with `…`) and with `> ` before every line. Blank selections yield ''.
String buildAskAboutQuote(
  String selected, {
  int maxChars = askAboutQuoteMaxChars,
}) {
  var text = selected.replaceAll('\r\n', '\n').trim();
  if (text.isEmpty) return '';
  if (text.length > maxChars) {
    text = '${text.substring(0, maxChars).trimRight()}…';
  }
  return text
      .split('\n')
      .map((line) {
        final trimmed = line.trimRight().trimLeft();
        return trimmed.isEmpty ? '>' : '> $trimmed';
      })
      .join('\n');
}

/// Puts [quote] into the composer without sending: an empty composer gets the
/// quote alone, otherwise it follows the existing text after a blank line.
/// Either way a blank line follows it and the cursor lands after it.
TextEditingValue insertQuoteIntoComposer(
  TextEditingValue current,
  String quote,
) {
  if (quote.isEmpty) return current;
  final existing = current.text.trimRight();
  final text = existing.isEmpty ? '$quote\n\n' : '$existing\n\n$quote\n\n';
  return TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: text.length),
  );
}
