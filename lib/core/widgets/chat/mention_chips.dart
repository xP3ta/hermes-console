import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;

import '../../../l10n/app_localizations.dart';
import '../../theme/app_theme.dart';

/// Markdown element for a recognized `@mention`.
const String mentionChipTag = 'hermes-mention';

/// What a recognized mention points at (Desktop `group-mention-text.tsx`
/// kinds: a bot, the human, or the whole room).
enum MentionChipKind { agent, human, broadcast }

/// One recognized mention: how its chip looks and what a tap does.
@immutable
class MentionChipTarget {
  const MentionChipTarget({
    required this.kind,
    required this.name,
    this.color,
    this.avatar,
    this.onTap,
  });

  final MentionChipKind kind;

  /// Who it is, for screen readers («Mención a Builder»).
  final String name;

  /// The bot's stable identity colour (agents only).
  final Color? color;

  /// The bot's face at [size] (agents only).
  final Widget Function(double size)? avatar;

  /// Only where Console already acted on a mention (the room opens the
  /// member's chat); Desktop's mentions do nothing on tap.
  final VoidCallback? onTap;
}

/// Decides which `@tokens` of a message are mentions, with the same rule the
/// routing uses, so a token is a chip exactly when routing would honour it.
/// Lookups are cached per token for the life of the resolver; a new roster
/// means a new resolver (and a re-parse of the messages showing it).
///
/// A resolver may also claim an inline code span that is exactly an agent's
/// id (`` `pi` ``): the server lists teammates to the model that way, so a
/// reply names them that way too. See [lookupName].
abstract class MentionChipResolver {
  final Map<String, MentionChipTarget?> _cache = {};
  final Map<String, MentionChipTarget?> _nameCache = {};

  /// Matches one mention at its `@`; group 1 is the token. Must reject
  /// e-mail addresses, paths and handles glued to a word (a lookbehind).
  RegExp get pattern;

  /// Trailing characters the token may include but prose usually owns
  /// («@builder.» at the end of a sentence).
  String get trailingPunctuation => '';

  /// The target of [token] (without `@`), or null to leave it as text.
  @protected
  MentionChipTarget? lookup(String token);

  /// The agent an inline code span reading exactly [code] names, or null to
  /// leave it as code. Nothing by default: only a resolver whose names are
  /// ids the model is told about (not words of a sentence) opts in.
  @protected
  MentionChipTarget? lookupName(String code) => null;

  /// Number of uncached lookups so far (tests: parsing is not redone).
  @visibleForTesting
  int lookups = 0;

  MentionChipTarget? resolve(String token) {
    final key = token.toLowerCase();
    if (_cache.containsKey(key)) return _cache[key];
    lookups += 1;
    return _cache[key] = lookup(token);
  }

  /// [lookupName], cached. Case matters: an id is written as it is.
  MentionChipTarget? resolveName(String code) {
    if (_nameCache.containsKey(code)) return _nameCache[code];
    lookups += 1;
    return _nameCache[code] = lookupName(code);
  }
}

/// The mention resolver for the messages below it. [ChatMarkdownBlock] and
/// [UserMessageText] read it; without one, nothing changes.
class MentionChipScope extends InheritedWidget {
  const MentionChipScope({
    super.key,
    required this.resolver,
    required super.child,
  });

  final MentionChipResolver? resolver;

  static MentionChipResolver? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<MentionChipScope>()
      ?.resolver;

  @override
  bool updateShouldNotify(MentionChipScope oldWidget) =>
      !identical(resolver, oldWidget.resolver);
}

/// Inline syntaxes and builders that turn [resolver]'s mentions into chips,
/// or empty ones when there is nothing to do (`builders` is empty exactly
/// then). `@token` mentions are claimed by a syntax; code spans and fenced
/// code never reach it, the Markdown parser hands them over whole.
///
/// With [names], an inline code span that is exactly an agent's id becomes
/// a chip too, through the `code` builder; [inlineCode] is the builder the
/// body uses for every other code span (it keeps its say). Fenced code is
/// never one: its text spans lines.
({List<md.InlineSyntax> syntaxes, Map<String, MarkdownElementBuilder> builders})
mentionChipMarkdown(
  MentionChipResolver? resolver,
  String data, {
  bool names = false,
  MarkdownElementBuilder? inlineCode,
}) {
  if (resolver == null) return (syntaxes: const [], builders: const {});
  final mentions = data.contains('@');
  final codeNames = names && data.contains('`');
  if (!mentions && !codeNames) return (syntaxes: const [], builders: const {});
  return (
    syntaxes: [if (mentions) MentionChipSyntax(resolver)],
    builders: {
      if (mentions) mentionChipTag: MentionChipBuilder(resolver),
      if (codeNames) 'code': MentionNameCodeBuilder(resolver, inlineCode),
    },
  );
}

/// A style with the underline of a link: chips never nest inside one (the
/// link keeps its text and its tap).
bool mentionInsideLink(TextStyle? style) =>
    style?.decoration == TextDecoration.underline;

/// Claims a recognized `@token` at its `@`. An unknown token stays text.
class MentionChipSyntax extends md.InlineSyntax {
  MentionChipSyntax(this.resolver)
    : super(
        resolver.pattern.pattern,
        startCharacter: 0x40,
        caseSensitive: resolver.pattern.isCaseSensitive,
      );

  final MentionChipResolver resolver;

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    var token = match.group(1)!;
    var trailing = '';
    final strip = resolver.trailingPunctuation;
    while (token.isNotEmpty && strip.contains(token[token.length - 1])) {
      trailing = token[token.length - 1] + trailing;
      token = token.substring(0, token.length - 1);
    }
    if (token.isEmpty || resolver.resolve(token) == null) {
      // Not a mention: the `@` is plain text. Step past it ourselves, since
      // returning false alone would leave the parser where it is.
      parser.advanceBy(1);
      return false;
    }
    parser.addNode(
      md.Element.text(mentionChipTag, '@$token')
        ..attributes['token'] = token,
    );
    if (trailing.isNotEmpty) parser.addNode(md.Text(trailing));
    return true;
  }
}

class MentionChipBuilder extends MarkdownElementBuilder {
  MentionChipBuilder(this.resolver);

  final MentionChipResolver resolver;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final token = element.attributes['token'] ?? '';
    final target = resolver.resolve(token);
    // Inside a link's text the mention stays text (the link's own).
    if (target == null || mentionInsideLink(parentStyle)) return null;
    return Text.rich(
      WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: MentionChip(
          text: element.textContent,
          target: target,
          textStyle: parentStyle,
        ),
      ),
    );
  }
}

/// The `code` builder of a body whose resolver names agents: an inline code
/// span that is exactly an agent's id is that agent's chip; every other code
/// span goes to [fallback] (the body's own code builder), or stays code.
class MentionNameCodeBuilder extends MarkdownElementBuilder {
  MentionNameCodeBuilder(this.resolver, this.fallback);

  final MentionChipResolver resolver;
  final MarkdownElementBuilder? fallback;

  @override
  bool isBlockElement() => fallback?.isBlockElement() ?? false;

  @override
  void visitElementBefore(md.Element element) =>
      fallback?.visitElementBefore(element);

  @override
  Widget? visitText(md.Text text, TextStyle? preferredStyle) =>
      fallback?.visitText(text, preferredStyle);

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final code = element.textContent;
    // A fenced or indented block spans lines (its text ends in one); inside
    // a link's text the code is the link's.
    if (!code.contains('\n') && !mentionInsideLink(parentStyle)) {
      final target = resolver.resolveName(code);
      if (target != null) {
        return Text.rich(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: MentionChip(
              text: code,
              target: target,
              textStyle: parentStyle,
              byName: true,
            ),
          ),
        );
      }
    }
    return fallback?.visitElementAfterWithContext(
      context,
      element,
      preferredStyle,
      parentStyle,
    );
  }
}

/// A mention as a rounded pill: the bot's face (or a person / group mark)
/// and the `@token` exactly as written, so selecting and copying the message
/// still gives `@token`. Not colour alone: the face, the mark and the label
/// say who it is.
///
/// The pill never grows the line it sits on: its face is about the text's
/// size and its label keeps the text's size, so a chip arriving mid-stream
/// (the token completing) changes what the line shows, not its height.
class MentionChip extends StatefulWidget {
  const MentionChip({
    super.key,
    required this.text,
    required this.target,
    this.textStyle,
    this.byName = false,
  });

  /// `@token` as written in the message, or the bare id of a [byName] chip.
  final String text;
  final MentionChipTarget target;

  /// The surrounding text's style (size).
  final TextStyle? textStyle;

  /// The agent was named by its id (an inline code span), not `@mentioned`:
  /// screen readers hear «Agent pi» rather than «Mention of pi».
  final bool byName;

  @override
  State<MentionChip> createState() => _MentionChipState();
}

class _MentionChipState extends State<MentionChip> {
  TapGestureRecognizer? _tap;

  @override
  void initState() {
    super.initState();
    _syncTap();
  }

  @override
  void didUpdateWidget(MentionChip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.target.onTap != widget.target.onTap) _syncTap();
  }

  void _syncTap() {
    final onTap = widget.target.onTap;
    if (onTap == null) {
      _tap?.dispose();
      _tap = null;
      return;
    }
    (_tap ??= TapGestureRecognizer()).onTap = onTap;
  }

  @override
  void dispose() {
    _tap?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final target = widget.target;
    final fontSize = widget.textStyle?.fontSize ?? 14;
    final mark = fontSize * 1.1;
    // The user reads in a neutral tone, the room in the accent, a bot in its
    // own colour.
    final tone = switch (target.kind) {
      MentionChipKind.agent => target.color ?? colors.accent,
      MentionChipKind.broadcast => colors.accent,
      MentionChipKind.human => colors.textSecondary,
    };
    final leading = switch (target.kind) {
      MentionChipKind.agent when target.avatar != null => target.avatar!(mark),
      MentionChipKind.agent => Icon(
        Icons.smart_toy_outlined,
        size: mark,
        color: tone,
      ),
      MentionChipKind.broadcast => Icon(
        Icons.groups_rounded,
        size: mark,
        color: tone,
      ),
      MentionChipKind.human => Icon(
        Icons.person_rounded,
        size: mark,
        color: tone,
      ),
    };
    final label = switch (target.kind) {
      MentionChipKind.human => strings.chaMentionChipYou,
      MentionChipKind.broadcast => strings.chaMentionChipEveryone,
      MentionChipKind.agent when widget.byName => strings.amcAgentChipLabel(
        target.name,
      ),
      MentionChipKind.agent => strings.chaMentionChipLabel(target.name),
    };
    final body = Container(
      padding: EdgeInsetsDirectional.fromSTEB(2, 1, fontSize * 0.5, 1),
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          tone.withValues(alpha: 0.16),
          colors.surfaceVariant,
        ),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: tone.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipOval(child: SizedBox.square(dimension: mark, child: leading)),
          SizedBox(width: fontSize * 0.25),
          Flexible(
            child: Text.rich(
              TextSpan(text: widget.text, recognizer: _tap),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: (widget.textStyle ?? const TextStyle()).copyWith(
                fontSize: fontSize,
                height: 1.2,
                fontWeight: FontWeight.w600,
                color: colors.textPrimary,
                decoration: TextDecoration.none,
              ),
            ),
          ),
        ],
      ),
    );
    final onTap = target.onTap;
    // One reading: «Mención a <nombre>», never the @token as well. A chip
    // with nothing to do joins its sentence (the paragraph merges inline
    // widgets into its own label, in order); one that opens something is a
    // node of its own, or its tap would become the whole sentence's.
    // The WidgetSpan already scales the chip with the paragraph's text
    // scale; scaling its label again made it twice as big (REVIEW-R5-B #6).
    final unscaled = MediaQuery.withClampedTextScaling(
      minScaleFactor: 1,
      maxScaleFactor: 1,
      child: body,
    );
    return Semantics(
      container: onTap != null,
      label: label,
      link: onTap != null,
      excludeSemantics: true,
      onTap: onTap,
      child: onTap == null
          ? unscaled
          : GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onTap,
              child: unscaled,
            ),
    );
  }
}
