/// `@` context references in the composer, in the exact text form Hermes
/// Desktop sends (`apps/desktop/src/app/chat/composer/hooks/use-at-completions.ts`,
/// `rich-editor.ts::quoteRefValue`, `path-refs.ts`): a picked row becomes
/// `@file:`path``/`@folder:`path/``, a starter row inserts the bare
/// `@file:`/`@folder:`/`@url:` prefix so the user keeps typing, and a hand-typed
/// bare path or link is promoted to that same quoted form when a space ends it.
library;

import 'package:flutter/services.dart';

/// Reference kinds Console offers from the `@` palette.
enum ComposerReferenceKind { file, folder, url }

ComposerReferenceKind? composerReferenceKindFromWire(String value) =>
    switch (value) {
      'file' => ComposerReferenceKind.file,
      'folder' => ComposerReferenceKind.folder,
      'url' => ComposerReferenceKind.url,
      _ => null,
    };

/// One `complete.path` row Console can render.
final class PathCompletionItem {
  final ComposerReferenceKind kind;

  /// Value after `@kind:`; empty for a starter row (`@file:`).
  final String value;
  final String display;
  final String meta;

  const PathCompletionItem({
    required this.kind,
    required this.value,
    required this.display,
    required this.meta,
  });

  bool get isStarter => value.isEmpty;

  /// The gateway's own `text`, e.g. `@file:lib/main.dart`.
  String get rawText => '@${kind.name}:$value';
}

/// Typed, bounded `complete.path` answer. Rows Console does not offer (agent
/// profile mentions — the mention palette owns them — `@diff`, `@git:`,
/// plugin prefixes) are dropped here, never rendered as dead rows.
final class PathCompletionBatch {
  static const int maxItems = 60;

  final List<PathCompletionItem> items;

  const PathCompletionBatch(this.items);

  factory PathCompletionBatch.fromJson(Object? value) {
    if (value is! Map) return const PathCompletionBatch([]);
    final raw = value['items'];
    if (raw is! List) return const PathCompletionBatch([]);
    final items = <PathCompletionItem>[];
    final seen = <String>{};
    for (final entry in raw.take(maxItems)) {
      if (entry is! Map) continue;
      final text = _bounded(entry['text'], 1024);
      if (text == null) continue;
      final match = RegExp(r'^@([a-z]+):(.*)$', dotAll: true).firstMatch(text);
      if (match == null) continue;
      final kind = composerReferenceKindFromWire(match.group(1)!);
      if (kind == null) continue;
      final rest = match.group(2)!;
      if (rest.contains('\n') || !seen.add(text)) continue;
      items.add(
        PathCompletionItem(
          kind: kind,
          value: rest,
          display:
              _bounded(entry['display'], 256) ??
              (rest.isEmpty ? '@${kind.name}:' : rest),
          meta: _bounded(entry['meta'], 240) ?? '',
        ),
      );
    }
    return PathCompletionBatch(List<PathCompletionItem>.unmodifiable(items));
  }
}

String? _bounded(Object? value, int max) {
  if (value is! String) return null;
  final cleaned = value
      .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'), '')
      .trim();
  if (cleaned.isEmpty) return null;
  return cleaned.length <= max ? cleaned : cleaned.substring(0, max);
}

/// Desktop `formatRefValue`: quote only when the bare `\S+` reading would
/// break the value.
String formatRefValue(String value) {
  if (!RegExp(r'''[\s`"'()\[\]{}<>,;]''').hasMatch(value)) return value;
  return quoteRefValue(value);
}

/// Desktop `quoteRefValue`: chips always carry a fence, backticks first.
String quoteRefValue(String value) {
  if (!value.contains('`')) return '`$value`';
  if (!value.contains('"')) return '"$value"';
  if (!value.contains("'")) return "'$value'";
  return value;
}

/// Serialized reference for a picked row (Desktop `hermesDirectiveFormatter`
/// + `refChipElement`): starters stay bare so the user keeps typing.
String serializeReference(PathCompletionItem item) => item.isStarter
    ? '@${item.kind.name}:'
    : '@${item.kind.name}:${quoteRefValue(item.value)}';

/// The `@…` token under a collapsed caret, if the `@` palette applies there.
final class ComposerReferenceQuery {
  final int start;
  final int end;

  /// Token text without the leading `@`.
  final String query;

  const ComposerReferenceQuery({
    required this.start,
    required this.end,
    required this.query,
  });

  /// `word` sent to `complete.path` (Desktop: a bare starter keyword asks for
  /// its listing, `@folder` → `@folder:`).
  String get word =>
      const {'file', 'folder', 'url'}.contains(query) ? '@$query:' : '@$query';

  /// The `kind:` the user scoped the browse to, if any.
  String? get scope {
    final match = RegExp(r'^(file|folder|url):').firstMatch(query);
    return match?.group(1);
  }
}

ComposerReferenceQuery? composerReferenceQuery(TextEditingValue value) {
  if (!value.selection.isValid ||
      !value.selection.isCollapsed ||
      (value.composing.isValid && !value.composing.isCollapsed)) {
    return null;
  }
  final end = value.selection.extentOffset;
  if (end < 0 || end > value.text.length) return null;
  final prefix = value.text.substring(0, end);
  final match = RegExp(r'''(^|\s)@([^\s@`"']*)$''').firstMatch(prefix);
  if (match == null) return null;
  // A caret inside a token must not splice a reference into its suffix.
  if (end < value.text.length && !RegExp(r'\s').hasMatch(value.text[end])) {
    return null;
  }
  final query = match.group(2)!;
  // `@url:<link>` has nothing to complete once the link starts.
  if (query.startsWith('url:') && query.length > 4) return null;
  final start = end - query.length - 1;
  final before = value.text.substring(0, start);
  if ('```'.allMatches(before).length.isOdd) return null;
  final line = before.substring(before.lastIndexOf('\n') + 1);
  if ('`'.allMatches(line).length.isOdd) return null;
  return ComposerReferenceQuery(start: start, end: end, query: query);
}

/// Replaces [query]'s token with [item]. A committed reference is followed by
/// one space unless whitespace already follows the caret.
TextEditingValue applyReferencePick(
  TextEditingValue value,
  ComposerReferenceQuery query,
  PathCompletionItem item,
) {
  final serialized = serializeReference(item);
  final followedBySpace =
      query.end < value.text.length &&
      RegExp(r'\s').hasMatch(value.text[query.end]);
  final insert = item.isStarter || followedBySpace
      ? serialized
      : '$serialized ';
  final text = value.text.replaceRange(query.start, query.end, insert);
  return TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: query.start + insert.length),
  );
}

/// Walks into a folder row: the token becomes the bare (scoped) path so the
/// next `complete.path` lists its children (Desktop Tab-descend).
TextEditingValue applyReferenceDescend(
  TextEditingValue value,
  ComposerReferenceQuery query,
  PathCompletionItem folder,
) {
  final path = folder.value.endsWith('/') ? folder.value : '${folder.value}/';
  final scope = query.scope == 'folder' ? 'folder:' : '';
  final insert = '@$scope$path';
  final text = value.text.replaceRange(query.start, query.end, insert);
  return TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: query.start + insert.length),
  );
}

final _typedBarePath = RegExp(
  r'''(?:^|\s)@((?!(?:file|folder|url|image|tool|line|terminal|session|git):)[^\s@:`"']*/[^\s@:`"']*)$''',
);
final _typedRef = RegExp(r'''(?:^|\s)@(file|folder|url):([^\s`"']+)$''');
final _typedUrl = RegExp(r'''(?:^|\s)(https?://[^\s<>\[\]{}"'`]+)$''');

/// Desktop commits a hand-typed `@path`, `@kind:value` or bare link as a
/// reference when a plain space ends it (`path-refs.ts::chipTypedPathOnSpace`,
/// `url-refs.ts`). Returns the promoted value, or null when nothing applies.
TextEditingValue? promoteTypedReferenceOnSpace(
  TextEditingValue oldValue,
  TextEditingValue newValue,
) {
  if (!newValue.selection.isCollapsed ||
      newValue.text.length != oldValue.text.length + 1) {
    return null;
  }
  final caret = newValue.selection.extentOffset;
  if (caret <= 0 || newValue.text[caret - 1] != ' ') return null;
  if (oldValue.text !=
      newValue.text.substring(0, caret - 1) + newValue.text.substring(caret)) {
    return null;
  }
  final before = newValue.text.substring(0, caret - 1);
  if (!before.contains('@') && !before.contains('http')) return null;
  if ('```'.allMatches(before).length.isOdd) return null;
  final line = before.substring(before.lastIndexOf('\n') + 1);
  if ('`'.allMatches(line).length.isOdd) return null;

  String? token;
  String? replacement;
  if (_typedRef.firstMatch(before) case final match?) {
    final value = match.group(2)!;
    token = '@${match.group(1)}:$value';
    replacement = '@${match.group(1)}:${quoteRefValue(value)}';
  } else if (_typedBarePath.firstMatch(before) case final match?) {
    final path = match.group(1)!;
    final trimmed = path.replaceFirst(RegExp(r'/+$'), '');
    if (trimmed.isEmpty) return null;
    token = '@$path';
    replacement =
        '@${path.endsWith('/') ? 'folder' : 'file'}:${quoteRefValue(trimmed)}';
  } else if (_typedUrl.firstMatch(before) case final match?) {
    final typed = match.group(1)!;
    // Prose punctuation after a link is not part of it; it stays after the
    // reference (Desktop `splitUrlTail`).
    final url = typed.replaceFirst(RegExp(r'[.,;:!?)]+$'), '');
    final trailing = typed.substring(url.length);
    final linkStart = before.length - typed.length;
    final inLinkDestination =
        linkStart >= 2 && before.substring(linkStart - 2, linkStart) == '](';
    if (inLinkDestination ||
        !RegExp(r'^https?://[^/?#\s]+').hasMatch(url) ||
        RegExp(r'^https?://$').hasMatch(url)) {
      return null;
    }
    token = typed;
    replacement = '@url:${quoteRefValue(url)}$trailing';
  }
  if (token == null || replacement == null) return null;
  final start = before.length - token.length;
  final text =
      newValue.text.substring(0, start) +
      replacement +
      newValue.text.substring(caret - 1);
  return TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: start + replacement.length + 1),
  );
}

/// Applies [promoteTypedReferenceOnSpace] while [enabled] (the chat's
/// gateway resolves context references).
final class ComposerReferenceFormatter extends TextInputFormatter {
  final bool Function() enabled;

  ComposerReferenceFormatter({required this.enabled});

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (!enabled()) return newValue;
    return promoteTypedReferenceOnSpace(oldValue, newValue) ?? newValue;
  }
}

/// Ranges of complete references (`@kind:value`) the composer accents.
Iterable<TextRange> composerReferenceRanges(String text) sync* {
  if (!text.contains('@')) return;
  for (final match in RegExp(
    r'''(?<![\w/])@(?:file|folder|url):(?:`[^`\n]+`|"[^"\n]+"|'[^'\n]+'|[^\s`"']+)''',
  ).allMatches(text)) {
    yield TextRange(start: match.start, end: match.end);
  }
}
