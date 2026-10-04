/// Large-paste-to-attachment policy, ported from Hermes Desktop
/// (`apps/desktop/src/app/chat/composer/large-paste.ts`): a plain-text paste
/// longer than [largePasteAttachmentThreshold] characters becomes a `.txt`
/// attachment named like Desktop's (`pasted_content_<stamp>_<hex>.txt`)
/// instead of flooding the composer, and reaches Hermes through the same
/// `@file:` attachment pipeline as any text file.
library;

import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart';

/// Characters beyond which a plain-text paste becomes a `.txt` attachment.
const int largePasteAttachmentThreshold = 3000;

/// True when a pasted chunk should become an attachment.
bool shouldConvertPasteToAttachment(
  String text, {
  int threshold = largePasteAttachmentThreshold,
}) => threshold > 0 && text.length > threshold;

final _pastedContentName = RegExp(r'(?:^|[\\/])pasted_content_[\w-]+\.txt$');

/// True for a large-paste file, whose chip reads "Pasted content".
bool isPastedContentName(String name) => _pastedContentName.hasMatch(name);

/// Desktop `electron/composer-paste.ts` file name.
String pastedContentFileName({DateTime? now, Random? random}) {
  final stamp = (now ?? DateTime.now())
      .toUtc()
      .toIso8601String()
      .replaceAll(RegExp(r'[:.]'), '-')
      .replaceFirst('T', '_')
      .replaceFirst('Z', '');
  final rng = random ?? Random.secure();
  final hex = List.generate(
    3,
    (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  return 'pasted_content_${stamp}_$hex.txt';
}

/// Human-readable size of a paste's UTF-8 bytes (Desktop `pasteSizeLabel`).
String pasteSizeLabel(String text) {
  final bytes = utf8.encode(text).length;
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// The contiguous chunk a single edit inserted, or null when the edit was not
/// a pure insertion/replacement of one run.
String? insertedChunk(TextEditingValue oldValue, TextEditingValue newValue) {
  final before = oldValue.text;
  final after = newValue.text;
  if (after.length <= before.length) return null;
  var prefix = 0;
  final maxPrefix = min(before.length, after.length);
  while (prefix < maxPrefix &&
      before.codeUnitAt(prefix) == after.codeUnitAt(prefix)) {
    prefix++;
  }
  var suffix = 0;
  while (suffix < before.length - prefix &&
      suffix < after.length - prefix &&
      before.codeUnitAt(before.length - 1 - suffix) ==
          after.codeUnitAt(after.length - 1 - suffix)) {
    suffix++;
  }
  return after.substring(prefix, after.length - suffix);
}

/// Start of the occurrence of [run] in [text] closest to [near], or -1 when
/// the field no longer holds it verbatim (the user edited the pasted run).
int pastedRunOffset(String text, String run, {required int near}) {
  if (run.isEmpty) return -1;
  var best = -1;
  for (var at = text.indexOf(run); at >= 0; at = text.indexOf(run, at + 1)) {
    if (best < 0 || (at - near).abs() < (best - near).abs()) best = at;
  }
  return best;
}

/// [value] without the [length] characters at [start], keeping the caret on
/// the text it was next to.
TextEditingValue removePastedRun(
  TextEditingValue value,
  int start,
  int length,
) {
  final end = start + length;
  int shift(int offset) => offset <= start
      ? offset
      : offset >= end
      ? offset - length
      : start;
  final selection = value.selection;
  return TextEditingValue(
    text: value.text.replaceRange(start, end, ''),
    selection: selection.isValid
        ? selection.copyWith(
            baseOffset: shift(selection.baseOffset),
            extentOffset: shift(selection.extentOffset),
          )
        : TextSelection.collapsed(offset: value.text.length - length),
  );
}

/// Spots a large paste as it lands in the field: the field keeps it (its only
/// durable copy until a chip exists) and [onLargePaste] receives the text and
/// where it starts. Only user edits pass through formatters, so programmatic
/// restores never trigger it.
final class LargePasteFormatter extends TextInputFormatter {
  final bool Function() enabled;
  final void Function(String text, int offset) onLargePaste;
  final int threshold;

  LargePasteFormatter({
    required this.enabled,
    required this.onLargePaste,
    this.threshold = largePasteAttachmentThreshold,
  });

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (newValue.text.length - oldValue.text.length <= threshold ||
        !enabled()) {
      return newValue;
    }
    final chunk = insertedChunk(oldValue, newValue);
    if (chunk == null ||
        !shouldConvertPasteToAttachment(chunk, threshold: threshold)) {
      return newValue;
    }
    onLargePaste(chunk, _commonPrefix(oldValue.text, newValue.text));
    return newValue;
  }
}

int _commonPrefix(String a, String b) {
  final limit = min(a.length, b.length);
  var index = 0;
  while (index < limit && a.codeUnitAt(index) == b.codeUnitAt(index)) {
    index++;
  }
  return index;
}
