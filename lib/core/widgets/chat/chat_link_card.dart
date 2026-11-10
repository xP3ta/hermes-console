import 'package:flutter/material.dart';

import '../../design/tokens.dart';
import '../../theme/app_theme.dart';
import 'embeds/embed_detector.dart';

/// A finished reply's Markdown cut where a paragraph is only a link.
sealed class ChatLinkSplitPart {
  const ChatLinkSplitPart();
}

/// Markdown between link paragraphs, rendered as before.
final class ChatLinkTextPart extends ChatLinkSplitPart {
  const ChatLinkTextPart(this.markdown);
  final String markdown;
}

/// A paragraph that is only a link: its card.
final class ChatLinkCardPart extends ChatLinkSplitPart {
  const ChatLinkCardPart({required this.title, required this.url});
  final String title;
  final Uri url;
}

// Flush left only: an indented link is a list item's continuation or code
// (REVIEW-R5-B #7).
final RegExp _markdownLink = RegExp(
  r'^\[([^\]\n]+)\]\((https?://[^\s)]+)\)\s*$',
);
final RegExp _bareLink = RegExp(r'^<?(https?://[^\s<>]+)>?\s*$');
final RegExp _fence = RegExp(r'^ {0,3}(```|~~~)');

/// A link reference definition (`[1]: https://…`): its uses would no longer
/// resolve once the reply is cut into parts.
final RegExp _referenceDefinition = RegExp(
  r'^ {0,3}\[[^\]\n]+\]:\s*\S',
  multiLine: true,
);

/// Splits [markdown] at every paragraph that is only an `http(s)` link
/// (`[title](https://…)` or a bare URL, alone between blank lines), outside
/// fenced code and never indented (a list item's continuation, indented
/// code). Links a player card already shows (YouTube…) stay text, and a reply
/// with link reference definitions is never cut. Null when there is no such
/// paragraph: the caller renders as before.
List<ChatLinkSplitPart>? splitStandaloneLinks(String markdown) {
  if (!markdown.contains('http')) return null;
  if (_referenceDefinition.hasMatch(markdown)) return null;
  final lines = markdown.split('\n');
  final parts = <ChatLinkSplitPart>[];
  final text = <String>[];
  var fenced = false;
  var found = false;

  void flushText() {
    // Only the blank lines at the edges go: an indented code block that
    // starts a part keeps its indentation.
    while (text.isNotEmpty && text.first.trim().isEmpty) {
      text.removeAt(0);
    }
    while (text.isNotEmpty && text.last.trim().isEmpty) {
      text.removeLast();
    }
    if (text.isNotEmpty) parts.add(ChatLinkTextPart(text.join('\n')));
    text.clear();
  }

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (_fence.hasMatch(line)) fenced = !fenced;
    final alone =
        !fenced &&
        (i == 0 || lines[i - 1].trim().isEmpty) &&
        (i == lines.length - 1 || lines[i + 1].trim().isEmpty);
    final card = alone ? _linkOf(line) : null;
    if (card == null) {
      text.add(line);
      continue;
    }
    found = true;
    flushText();
    parts.add(card);
  }
  if (!found) return null;
  flushText();
  return parts;
}

ChatLinkCardPart? _linkOf(String line) {
  final markdown = _markdownLink.firstMatch(line);
  final href = markdown?.group(2) ?? _bareLink.firstMatch(line)?.group(1);
  if (href == null) return null;
  final url = Uri.tryParse(href);
  if (url == null || url.host.isEmpty) return null;
  if (url.scheme != 'http' && url.scheme != 'https') return null;
  // A provider with its own player card keeps its link as text.
  if (detectStandaloneEmbeds(href).isNotEmpty) return null;
  final title = plainLinkTitle(markdown?.group(1) ?? '');
  return ChatLinkCardPart(title: title.isEmpty ? href : title, url: url);
}

/// A link title as the reader sees it: no `**`, `_`, `~~` or backticks, and
/// escapes resolved (`[**Docs**](…)` reads «Docs», also for TalkBack;
/// REVIEW-R5-B #20).
@visibleForTesting
String plainLinkTitle(String markdown) => markdown
    // Escaped characters are kept aside so the markers below leave them.
    .replaceAllMapped(
      RegExp(r'\\(.)'),
      (m) => '\u0000${m[1]!.codeUnitAt(0)}\u0000',
    )
    .replaceAll(RegExp(r'\*\*|__|~~|`'), '')
    .replaceAllMapped(
      RegExp(r'(^|[^\w*])[*_](\S(?:.*?\S)?)[*_](?![\w*])'),
      (m) => '${m[1]}${m[2]}',
    )
    .replaceAllMapped(
      RegExp('\u0000(\\d+)\u0000'),
      (m) => String.fromCharCode(int.parse(m[1]!)),
    )
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// The L2 chat design's link card (`v2-cadu-console.html` `.card.link`): a
/// tile, the link's title and its domain in mono. Only what the message
/// already says: no page fetch, so no preview image or reading time.
class ChatLinkCard extends StatelessWidget {
  const ChatLinkCard({
    super.key,
    required this.title,
    required this.url,
    required this.onTap,
  });

  final String title;
  final Uri url;
  final VoidCallback onTap;

  String get _domain {
    final host = url.host.toLowerCase();
    return host.startsWith('www.') ? host.substring(4) : host;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    // Its own node: a link card is read and opened on its own, not merged
    // into the reply around it.
    return Semantics(
      container: true,
      link: true,
      label: title,
      value: _domain,
      onTap: onTap,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          key: const ValueKey('chat-link-card'),
          constraints: const BoxConstraints(maxWidth: 360),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: colors.surfaceVariant,
            borderRadius: BorderRadius.circular(HermesRadius.floating),
            border: Border.all(color: colors.divider.withValues(alpha: 0.5)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: colors.accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(HermesRadius.group),
                ),
                child: Icon(
                  Icons.language_rounded,
                  size: 28,
                  color: colors.accent,
                ),
              ),
              const SizedBox(width: 12),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.textPrimary,
                        fontWeight: FontWeight.w600,
                        fontSize: 14.5,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _domain,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.textSecondary,
                        fontFamily: 'monospace',
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
