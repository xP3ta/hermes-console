import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;

import '../../../l10n/app_localizations.dart';
import '../../design/tokens.dart';
import '../../theme/app_theme.dart';
import '../../theme/theme_contrast.dart';
import '../../utils/chat_inline_refs.dart';
import 'chat_file_opener.dart';

/// Markdown element of a file reference found in running text.
const String chatFileChipTag = 'hermes-file';

/// Markdown element of a citation number.
const String chatCitationTag = 'hermes-cite';

/// Markdown element of a web address written bare in running text.
const String chatUrlTag = 'hermes-url';

/// «M↓», the mark of a Markdown file.
const String _markdownGlyph = 'M↓';

/// Sizes as a share of the text around the chip, so large fonts scale it.
const double _iconEm = 1.1;
const double _gapEm = 0.3;
const double _padEm = 0.12;
const double _citeEm = 0.7;
const double _citePadEm = 0.45;
const double _citeRiseEm = 0.2;
const double _urlMaxEm = 20;
const double _urlPadEm = 0.45;
const double _urlSizeEm = 0.9;

/// The accent as ink for chips: the theme's accent text lifted, only when
/// needed, to AA on every surface a reply sits on.
Color chatChipInk(HermesThemeColors colors) => ThemeContrast.adjustForContrast(
  colors.accentText,
  [colors.background, colors.surface, colors.surfaceVariant],
  minimum: 4.5,
);

/// A style with the underline of a link: chips never nest inside one.
bool _insideLink(TextStyle? style) =>
    style?.decoration == TextDecoration.underline;

/// The chip for an inline code span that is a file or folder, or null when
/// the code is not one (it then stays code). A fenced block never gets here:
/// its text spans lines.
Widget? chatInlineCodeChip(String code, TextStyle? parentStyle) {
  if (code.contains('\n') || _insideLink(parentStyle)) return null;
  final ref = chatFileRefFor(code);
  if (ref == null) return null;
  return _chipSpan(ref, parentStyle);
}

Widget _chipSpan(ChatFileRef ref, TextStyle? style) => Text.rich(
  WidgetSpan(
    alignment: PlaceholderAlignment.middle,
    child: ChatFileChip(ref: ref, textStyle: style),
  ),
);

/// Claims a file reference written as plain text. Anything that is not one
/// (an unknown extension, a library name, text inside a link's brackets)
/// stays text.
class ChatFileSyntax extends md.InlineSyntax {
  ChatFileSyntax() : super(chatFilePattern, caseSensitive: false);

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final token = match[0]!;
    final ref = chatInsideBrackets(match.input, match.start)
        ? null
        : chatFileRefFor(token, plain: true);
    if (ref == null) {
      // Step over the token ourselves: returning false alone would leave the
      // parser where it is.
      parser.advanceBy(token.length);
      return false;
    }
    parser.addNode(md.Element.text(chatFileChipTag, token));
    return true;
  }
}

/// Claims a citation number. The pattern itself refuses what is not one, so
/// a Markdown link or reference keeps its own handling.
class ChatCitationSyntax extends md.InlineSyntax {
  ChatCitationSyntax() : super(chatCitationPattern, startCharacter: 0x5B);

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(
      md.Element.text(chatCitationTag, match[0]!)..attributes['n'] = match[1]!,
    );
    return true;
  }
}

/// Claims a web address written bare in running text. One alone on its line,
/// and one that is the text of a link (`[https://a](https://a)`) keeps the link's own look.
class ChatUrlSyntax extends md.InlineSyntax {
  ChatUrlSyntax() : super(chatBareUrlPattern, startCharacter: 0x68);

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final token = match[0]!;
    final input = match.input;
    // An address alone on its line is a paragraph of its own: it keeps the
    // link (or the card of a finished reply) it always had.
    final alone =
        (match.start == 0 || input.codeUnitAt(match.start - 1) == 0x0A) &&
        (match.end == input.length || input.codeUnitAt(match.end) == 0x0A);
    if (alone || chatInsideBrackets(input, match.start)) {
      parser.advanceBy(token.length);
      return false;
    }
    parser.addNode(md.Element.text(chatUrlTag, token));
    return true;
  }
}

class ChatUrlChipBuilder extends MarkdownElementBuilder {
  ChatUrlChipBuilder(this.onOpen);

  /// Opens the address, like a link of the reply.
  final void Function(String href) onOpen;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    if (_insideLink(parentStyle)) return null;
    final url = element.textContent;
    return Text.rich(
      WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: ChatUrlChip(url: url, textStyle: parentStyle, onOpen: onOpen),
      ),
    );
  }
}

class ChatFileChipBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    if (_insideLink(parentStyle)) return null;
    final ref = chatFileRefFor(element.textContent, plain: true);
    return ref == null ? null : _chipSpan(ref, parentStyle);
  }
}

class ChatCitationBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final number = int.tryParse(element.attributes['n'] ?? '');
    if (number == null || _insideLink(parentStyle)) return null;
    return Text.rich(
      WidgetSpan(
        alignment: PlaceholderAlignment.aboveBaseline,
        baseline: TextBaseline.alphabetic,
        child: ChatCitationPill(number: number, textStyle: parentStyle),
      ),
    );
  }
}

/// Syntaxes and builders for the file references, citation numbers and (with
/// [onOpenUrl]) bare web addresses of one block of [source], or empty ones when it holds none (then nothing changes
/// and Markdown keeps its fast path). What a citation opens is not decided
/// here but by the [ChatCitationScope] above the pill, so a list of sources
/// that arrives later still reaches a block that is already parsed.
({List<md.InlineSyntax> syntaxes, Map<String, MarkdownElementBuilder> builders})
chatInlineChipMarkdown(String source, {void Function(String href)? onOpenUrl}) {
  final syntaxes = <md.InlineSyntax>[];
  final builders = <String, MarkdownElementBuilder>{};
  if (onOpenUrl != null && chatMayHaveBareUrls(source)) {
    syntaxes.add(ChatUrlSyntax());
    builders[chatUrlTag] = ChatUrlChipBuilder(onOpenUrl);
  }
  if (chatMayHaveFilePaths(source)) {
    syntaxes.add(ChatFileSyntax());
    builders[chatFileChipTag] = ChatFileChipBuilder();
  }
  if (chatMayHaveCitations(source)) {
    syntaxes.add(ChatCitationSyntax());
    builders[chatCitationTag] = ChatCitationBuilder();
  }
  return (syntaxes: syntaxes, builders: builders);
}

/// The sources of the reply and how to open one, for the citation pills
/// below it. Pills read it when they build, so they follow the list as it
/// grows without the block's Markdown being parsed again.
class ChatCitationScope extends InheritedWidget {
  const ChatCitationScope({
    super.key,
    required this.sources,
    required this.onOpen,
    required super.child,
  });

  final ChatCitationSources sources;

  /// Opens a source link, from the pill's own context.
  final void Function(BuildContext context, String href) onOpen;

  static ChatCitationScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ChatCitationScope>();

  @override
  bool updateShouldNotify(ChatCitationScope oldWidget) =>
      !mapEquals(sources.urls, oldWidget.sources.urls);
}

/// [child] under a [ChatCitationScope] when [source] holds citation numbers,
/// and as it is when it holds none (so such a block is built as before).
/// [data] is the whole reply: the list of sources may sit in another block
/// (or be drawn as rows, which are no longer Markdown).
Widget chatCitationScoped({
  required String source,
  required String data,
  required void Function(BuildContext context, String href) onOpen,
  required Widget child,
}) {
  if (!chatMayHaveCitations(source)) return child;
  return ChatCitationScope(
    sources: chatCitationSources(data),
    onOpen: onOpen,
    child: child,
  );
}

IconData _iconFor(ChatFileKind kind) => switch (kind) {
  ChatFileKind.folder => Icons.folder_rounded,
  ChatFileKind.archive => Icons.folder_zip_rounded,
  ChatFileKind.image => Icons.image_rounded,
  ChatFileKind.pdf => Icons.picture_as_pdf_rounded,
  ChatFileKind.code => Icons.code_rounded,
  ChatFileKind.data => Icons.data_object_rounded,
  ChatFileKind.file || ChatFileKind.markdown => Icons.insert_drive_file_rounded,
};

/// A file or folder of a reply: a type icon and the short name in the accent,
/// no fill. It wraps with the text and never grows past the column (the name
/// takes an ellipsis). A tap opens the file with Console's viewer when the
/// conversation can read it, and copies the path otherwise.
class ChatFileChip extends StatelessWidget {
  const ChatFileChip({super.key, required this.ref, this.textStyle});

  final ChatFileRef ref;

  /// The surrounding text's style (size, font).
  final TextStyle? textStyle;

  void _activate(BuildContext context) {
    final opener = ChatFileChipScope.maybeOf(context);
    if (opener != null && opener.canOpen(ref)) {
      unawaited(opener.open(context, ref));
    } else {
      unawaited(copyChatFilePath(context, ref.path));
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Localizations.of<Strings>(context, Strings);
    final base = textStyle ?? const TextStyle();
    final fontSize = base.fontSize ?? HermesType.readingSize;
    final ink = chatChipInk(colors);
    final mark = fontSize * _iconEm;
    final gap = fontSize * _gapEm;
    final pad = fontSize * _padEm;
    final Widget icon = ref.kind == ChatFileKind.markdown
        ? SizedBox(
            height: mark,
            child: Center(
              widthFactor: 1,
              child: Text(
                _markdownGlyph,
                textScaler: TextScaler.noScaling,
                maxLines: 1,
                style: base.copyWith(
                  fontSize: fontSize * 0.78,
                  height: 1,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0,
                  color: ink,
                  decoration: TextDecoration.none,
                ),
              ),
            ),
          )
        : Icon(_iconFor(ref.kind), size: mark, color: colors.textSecondary);
    final body = Padding(
      padding: EdgeInsets.symmetric(horizontal: pad),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          icon,
          SizedBox(width: gap),
          Flexible(
            child: Text(
              ref.name,
              textScaler: TextScaler.noScaling,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
              style: base.copyWith(
                fontSize: fontSize,
                height: 1.2,
                fontWeight: FontWeight.w500,
                color: ink,
                decoration: TextDecoration.none,
              ),
            ),
          ),
        ],
      ),
    );
    final label = ref.isFolder
        ? strings?.chcFolderLabel(ref.name)
        : strings?.chcFileLabel(ref.name);
    final opener = ChatFileChipScope.maybeOf(context);
    final opens = opener != null && opener.canOpen(ref);
    // The WidgetSpan already scales the chip with the paragraph's text
    // scale; scaling its label again would make it twice as big. Each Text
    // says so itself (`TextScaler.noScaling`) instead of wrapping the chip in
    // MediaQuery.withClampedTextScaling: that reads the whole MediaQuery, so
    // every chip of the transcript rebuilt on each keyboard frame.
    return ChatTapTarget(
      child: Semantics(
        container: true,
        button: true,
        label: label ?? ref.name,
        tooltip: ref.path,
        hint: opens ? strings?.chcFileOpenHint : strings?.chcFileCopyHint,
        excludeSemantics: true,
        onTap: () => _activate(context),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _activate(context),
          child: body,
        ),
      ),
    );
  }
}

/// Makes a small inline chip answer touches within [minSize] around it (48 dp
/// by default) without changing its size, its layout or how it looks. It
/// widens only the hit test: a touch in the margin reaches the chip as if it
/// had landed on its edge. Nothing here reads the MediaQuery or builds.
class ChatTapTarget extends SingleChildRenderObjectWidget {
  const ChatTapTarget({
    super.key,
    this.minSize = const Size.square(kMinInteractiveDimension),
    super.child,
  });

  final Size minSize;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderChatTapTarget(minSize);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderChatTapTarget).minSize = minSize;
  }
}

class _RenderChatTapTarget extends RenderProxyBox {
  _RenderChatTapTarget(this._minSize);

  Size _minSize;
  set minSize(Size value) => _minSize = value;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    final growX = math.max(0.0, (_minSize.width - size.width) / 2);
    final growY = math.max(0.0, (_minSize.height - size.height) / 2);
    if (position.dx < -growX ||
        position.dy < -growY ||
        position.dx >= size.width + growX ||
        position.dy >= size.height + growY) {
      return false;
    }
    return super.hitTest(
      result,
      position: Offset(
        position.dx.clamp(0.0, math.max(0.0, size.width - 0.001)),
        position.dy.clamp(0.0, math.max(0.0, size.height - 0.001)),
      ),
    );
  }
}

/// A citation number as a small raised pill: about 0.7 of the text, in the
/// accent at low strength. With a [url] a tap opens the source like any link;
/// without one the pill is only visual.
class ChatCitationPill extends StatelessWidget {
  const ChatCitationPill({super.key, required this.number, this.textStyle});

  final int number;
  final TextStyle? textStyle;

  /// Through the scope's opener at tap time, which is the current one.
  void _open(BuildContext context, String href) => context
      .getInheritedWidgetOfExactType<ChatCitationScope>()
      ?.onOpen(context, href);

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Localizations.of<Strings>(context, Strings);
    final base = textStyle ?? const TextStyle();
    final parentSize = base.fontSize ?? HermesType.readingSize;
    final fontSize = parentSize * _citeEm;
    final ink = chatChipInk(colors);
    final padH = fontSize * _citePadEm;
    final padV = fontSize * _padEm;
    final rise = parentSize * _citeRiseEm;
    final pill = DecoratedBox(
      decoration: BoxDecoration(
        color: ink.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(HermesRadius.tag),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: padH, vertical: padV),
        child: Text(
          number.toString(),
          textScaler: TextScaler.noScaling,
          maxLines: 1,
          style: base.copyWith(
            fontSize: fontSize,
            height: 1.1,
            fontWeight: FontWeight.w600,
            letterSpacing: 0,
            color: ink,
            decoration: TextDecoration.none,
          ),
        ),
      ),
    );
    final raised = Padding(
      padding: EdgeInsets.only(bottom: rise, left: padV, right: padV),
      child: pill,
    );
    // Unscaled by its own Text (see ChatFileChip): no whole-MediaQuery read.
    final href = ChatCitationScope.maybeOf(context)?.sources[number];
    if (href == null) {
      return Semantics(
        label: strings?.chcCitationLabel(number) ?? number.toString(),
        excludeSemantics: true,
        child: raised,
      );
    }
    return Semantics(
      container: true,
      link: true,
      label: strings?.chcCitationSourceLabel(number) ?? number.toString(),
      hint: strings?.chcCitationOpenHint,
      excludeSemantics: true,
      onTap: () => _open(context, href),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _open(context, href),
        child: raised,
      ),
    );
  }
}

/// A web address written in the text, as a quiet chip: the domain and the
/// start of the path in the accent, cut with an ellipsis at about twenty
/// letters wide, never the whole address breaking the paragraph. A tap opens
/// it like any link, a long press copies the whole address; a selection that
/// takes the chip copies its text, which is the address without the scheme.
class ChatUrlChip extends StatelessWidget {
  const ChatUrlChip({
    super.key,
    required this.url,
    this.textStyle,
    required this.onOpen,
  });

  final String url;
  final TextStyle? textStyle;
  final void Function(String href) onOpen;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Localizations.of<Strings>(context, Strings);
    final base = textStyle ?? const TextStyle();
    final parentSize = base.fontSize ?? HermesType.readingSize;
    final fontSize = parentSize * _urlSizeEm;
    final ink = chatChipInk(colors);
    final body = DecoratedBox(
      decoration: BoxDecoration(
        color: ink.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(HermesRadius.tag),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: fontSize * _urlPadEm,
          vertical: fontSize * _padEm,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: parentSize * _urlMaxEm),
          child: Text(
            chatUrlChipLabel(url),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            softWrap: false,
            style: base.copyWith(
              fontSize: fontSize,
              height: 1.25,
              fontWeight: FontWeight.w500,
              color: ink,
              decoration: TextDecoration.none,
            ),
          ),
        ),
      ),
    );
    final unscaled = MediaQuery.withClampedTextScaling(
      minScaleFactor: 1,
      maxScaleFactor: 1,
      child: body,
    );
    void copy() => unawaited(
      copyChatFilePath(context, url, message: strings?.mdpLinkCopied),
    );
    return Semantics(
      container: true,
      link: true,
      label: strings?.mdpLinkChipLabel(chatUrlDomain(url)) ?? url,
      hint: strings?.mdpOpenLinkHint,
      excludeSemantics: true,
      onTap: () => onOpen(url),
      onLongPress: copy,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onOpen(url),
        onLongPress: copy,
        child: unscaled,
      ),
    );
  }
}
