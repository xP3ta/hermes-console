import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;

import '../../models/composer_reference.dart';
import '../../models/reference_directive.dart';
import '../../theme/app_theme.dart';

const String _referenceTag = 'hermes-ref';

/// A user message body: light Markdown with `@file:`/`@folder:`/`@url:`
/// references shown as chips (Desktop `user-message-text.tsx`: directives win
/// over inline code, so a backtick-quoted value never renders as a code span).
/// Plain links stay ordinary tappable links.
class UserMessageText extends StatelessWidget {
  final String data;
  final MarkdownStyleSheet? styleSheet;

  /// Tapped links and `@url:` chips. The caller applies the safe external-open
  /// rule.
  final void Function(String? href)? onTapLink;

  const UserMessageText({
    required this.data,
    this.styleSheet,
    this.onTapLink,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return MarkdownBody(
      data: data,
      selectable: false,
      // Respeta los saltos de línea simples (CommonMark los colapsaría).
      softLineBreak: true,
      onTapLink: (text, href, title) => onTapLink?.call(href),
      styleSheet: styleSheet,
      inlineSyntaxes: [_ReferenceSyntax()],
      builders: {_referenceTag: _ReferenceChipBuilder(onTapLink)},
    );
  }
}

/// Claims a whole directive at its `@`, before the inline-code syntax can
/// split a quoted value into a bare prefix plus a code span.
class _ReferenceSyntax extends md.InlineSyntax {
  _ReferenceSyntax()
    : super(
        r'''(?<![\w/])@(?:file|folder|url):(?:(?:`[^`\n]+`|"[^"\n]+"|'[^'\n]+')(?::\d+(?:-\d+)?)?|\S+)''',
        startCharacter: 0x40,
      );

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final ref = findReferenceDirectives(match.group(0)!).firstOrNull;
    if (ref == null || ref.start != 0) return false;
    final element = md.Element.text(_referenceTag, ref.label)
      ..attributes['kind'] = ref.kind.name
      ..attributes['value'] = ref.value;
    parser.addNode(element);
    // Trailing prose punctuation the directive does not own stays as text.
    final rest = match.group(0)!.substring(ref.raw.length);
    if (rest.isNotEmpty) parser.addNode(md.Text(rest));
    return true;
  }
}

class _ReferenceChipBuilder extends MarkdownElementBuilder {
  final void Function(String? href)? onTapLink;

  _ReferenceChipBuilder(this.onTapLink);

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final kind = composerReferenceKindFromWire(
      element.attributes['kind'] ?? '',
    );
    if (kind == null) return null;
    final chip = ReferenceChip(
      kind: kind,
      label: element.textContent,
      value: element.attributes['value'] ?? '',
      textStyle: parentStyle,
      onTapLink: onTapLink,
    );
    return Text.rich(
      WidgetSpan(alignment: PlaceholderAlignment.middle, child: chip),
    );
  }
}

/// Rounded reference chip: kind icon plus a short label. A link chip opens
/// its link through [onTapLink].
class ReferenceChip extends StatelessWidget {
  final ComposerReferenceKind kind;
  final String label;
  final String value;
  final TextStyle? textStyle;
  final void Function(String? href)? onTapLink;

  const ReferenceChip({
    required this.kind,
    required this.label,
    required this.value,
    this.textStyle,
    this.onTapLink,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final icon = switch (kind) {
      ComposerReferenceKind.url => Icons.link_rounded,
      ComposerReferenceKind.folder => Icons.folder_outlined,
      ComposerReferenceKind.file => Icons.description_outlined,
    };
    final fontSize = (textStyle?.fontSize ?? 14) * 0.92;
    final body = Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: colors.accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: colors.accent.withValues(alpha: 0.28)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: fontSize + 1, color: colors.accent),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: fontSize,
                height: 1.25,
                fontWeight: FontWeight.w600,
                color: colors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
    final tappable = kind == ComposerReferenceKind.url && onTapLink != null;
    return Semantics(
      key: ValueKey('user-reference-chip-${kind.name}'),
      link: kind == ComposerReferenceKind.url,
      label: label,
      excludeSemantics: true,
      onTap: tappable ? () => onTapLink!(value) : null,
      child: tappable
          ? GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onTapLink!(value),
              child: body,
            )
          : body,
    );
  }
}
