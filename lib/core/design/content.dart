import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/hermes_notice.dart';
import 'list.dart';
import 'tokens.dart';

/// 6 px dot + support label in the status colour + optional "· meta". No box.
class HermesStatusText extends StatelessWidget {
  final String label;
  final HermesStatusTone tone;
  final String? meta;
  final int maxLines;

  const HermesStatusText({
    super.key,
    required this.label,
    this.tone = HermesStatusTone.neutral,
    this.meta,
    this.maxLines = 2,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final color = tone.colorIn(colors);
    final scale = MediaQuery.textScalerOf(context).scale(12.5) / 12.5;
    return Semantics(
      label: meta == null ? label : '$label, $meta',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            // Centre the dot on the first text line.
            padding: EdgeInsets.only(top: 6 * scale),
            child: Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: label,
                    style: TextStyle(
                      color: tone == HermesStatusTone.neutral
                          ? colors.textSecondary
                          : color,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (meta != null && meta!.isNotEmpty)
                    TextSpan(
                      text: ' · $meta',
                      style: TextStyle(color: colors.textSecondary),
                    ),
                ],
              ),
              maxLines: maxLines,
              overflow: TextOverflow.ellipsis,
              style: HermesType.support.copyWith(height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

/// Tag for decision-changing states only (Read-only, Failed, Needs you):
/// tinted fill, fully rounded, no border, sentence case. Max one per row.
class HermesTag extends StatelessWidget {
  final String label;
  final HermesStatusTone tone;
  final IconData? icon;

  const HermesTag({
    super.key,
    required this.label,
    this.tone = HermesStatusTone.warn,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final color = tone.colorIn(colors);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(HermesRadius.tag),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ).copyWith(color: color),
          ),
        ],
      ),
    );
  }
}

/// [HermesListRow] + [Switch]; the whole row toggles.
class HermesToggleRow extends StatelessWidget {
  final String title;
  final String? subtitle;
  final IconData? icon;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final Key? switchKey;

  const HermesToggleRow({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.icon,
    this.switchKey,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onChanged != null;
    return MergeSemantics(
      child: Opacity(
        opacity: enabled ? 1 : .5,
        child: HermesListRow(
          icon: icon,
          title: title,
          subtitle: subtitle,
          subtitleMaxLines: 2,
          onTap: enabled ? () => onChanged!(!value) : null,
          trailing: Padding(
            padding: const EdgeInsets.only(left: 10),
            child: Switch(key: switchKey, value: value, onChanged: onChanged),
          ),
        ),
      ),
    );
  }
}

/// Row + current value + chevron; [onTap] opens a floating option surface.
class HermesSelectRow extends StatelessWidget {
  final String title;
  final String value;
  final IconData? icon;
  final String? subtitle;
  final VoidCallback? onTap;

  const HermesSelectRow({
    super.key,
    required this.title,
    required this.value,
    required this.onTap,
    this.icon,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) => HermesListRow(
    icon: icon,
    title: title,
    subtitle: subtitle,
    value: value,
    onTap: onTap,
    semanticLabel: '$title: $value',
  );
}

/// Read-only text with NO scroll of its own. Long text collapses to
/// [collapsedLines] with an inline "Show all"; huge text offers "Open" which
/// pushes a [HermesLogPage].
class HermesTextBlock extends StatefulWidget {
  final String text;
  final int collapsedLines;
  final bool mono;
  final bool copyable;

  /// Page title for the full-screen view of huge text.
  final String? openTitle;

  /// Beyond this many lines the block offers "Open" instead of expanding.
  final int hugeLineThreshold;

  /// Wrap in a [HermesListGroup] surface (the detail-page default).
  final bool grouped;

  const HermesTextBlock({
    super.key,
    required this.text,
    this.collapsedLines = 6,
    this.mono = false,
    this.copyable = false,
    this.openTitle,
    this.hugeLineThreshold = 200,
    this.grouped = true,
  });

  @override
  State<HermesTextBlock> createState() => _HermesTextBlockState();
}

class _HermesTextBlockState extends State<HermesTextBlock> {
  bool _expanded = false;

  bool get _huge =>
      '\n'.allMatches(widget.text).length + 1 > widget.hugeLineThreshold;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final style = widget.mono
        ? TextStyle(
            fontFamily: 'monospace',
            fontSize: 12.5,
            height: 1.45,
            color: colors.textPrimary,
          )
        : HermesType.text.copyWith(color: colors.textPrimary);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = (constraints.maxWidth - 2 * HermesSpace.rowH).clamp(
          0.0,
          double.infinity,
        );
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: style),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          maxLines: widget.collapsedLines,
        )..layout(maxWidth: width);
        final overflows = painter.didExceedMaxLines;
        painter.dispose();
        final collapsed = overflows && !_expanded;
        final actions = <Widget>[
          if (overflows && _huge && widget.openTitle != null)
            _BlockAction(
              key: const ValueKey('hermes-text-block-open'),
              label: s.commonOpen,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => HermesLogPage(
                    title: widget.openTitle!,
                    text: widget.text,
                  ),
                ),
              ),
            )
          else if (overflows)
            _BlockAction(
              key: const ValueKey('hermes-text-block-toggle'),
              label: _expanded ? s.designShowLess : s.designShowAll,
              onTap: () => setState(() => _expanded = !_expanded),
            ),
          const Spacer(),
          if (widget.copyable)
            IconButton(
              key: const ValueKey('hermes-text-block-copy'),
              tooltip: s.commonCopy,
              iconSize: 18,
              color: colors.textSecondary,
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: widget.text));
                if (context.mounted) {
                  HermesNotice.show(
                    context,
                    message: s.designCopied,
                    kind: HermesNoticeKind.success,
                  );
                }
              },
              icon: const Icon(Icons.copy_rounded),
            ),
        ];
        final body = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                HermesSpace.rowH,
                HermesSpace.x3,
                HermesSpace.rowH,
                actions.length > 1 ? 0 : HermesSpace.x3,
              ),
              child: Text(
                widget.text,
                key: const ValueKey('hermes-text-block-text'),
                style: style,
                maxLines: collapsed ? widget.collapsedLines : null,
                overflow: collapsed ? TextOverflow.fade : null,
              ),
            ),
            if (actions.length > 1)
              Padding(
                padding: const EdgeInsets.only(left: 2, right: 4),
                child: Row(children: actions),
              ),
          ],
        );
        if (!widget.grouped) return body;
        return HermesListGroup(children: [body]);
      },
    );
  }
}

class _BlockAction extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _BlockAction({super.key, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: onTap,
    style: TextButton.styleFrom(
      minimumSize: const Size(48, 44),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      foregroundColor: Theme.of(context).hermes.accentText,
      textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
    ),
    child: Text(label),
  );
}

/// Full page for long read-only text (logs, outputs): mono, ONE scroll, Copy.
class HermesLogPage extends StatelessWidget {
  final String title;
  final String text;
  final bool mono;

  /// Optional one-line note above the text (for example "truncated").
  final String? notice;

  const HermesLogPage({
    super.key,
    required this.title,
    required this.text,
    this.mono = true,
    this.notice,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    return Scaffold(
      appBar: HermesAppBar(
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            key: const ValueKey('hermes-log-copy'),
            tooltip: s.commonCopy,
            icon: const Icon(Icons.copy_rounded),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: text));
              if (context.mounted) {
                HermesNotice.show(
                  context,
                  message: s.designCopied,
                  kind: HermesNoticeKind.success,
                );
              }
            },
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: SelectionArea(
          child: ListView(
            key: const ValueKey('hermes-log-page'),
            padding: const EdgeInsets.fromLTRB(
              HermesSpace.pageH,
              HermesSpace.pageTop,
              HermesSpace.pageH,
              HermesSpace.pageBottom,
            ),
            children: [
              if (notice != null && notice!.isNotEmpty) ...[
                HermesInlineNotice(message: notice!),
                const SizedBox(height: HermesSpace.x3),
              ],
              Text(
                text,
                style: mono
                    ? TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12.5,
                        height: 1.5,
                        color: colors.textPrimary,
                      )
                    : HermesType.text.copyWith(color: colors.textPrimary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Unified empty state: quiet icon, title, text, one CTA.
class HermesEmptyStateView extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? body;
  final String? actionLabel;
  final VoidCallback? onAction;

  const HermesEmptyStateView({
    super.key,
    required this.icon,
    required this.title,
    this.body,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 32, color: colors.textSecondary),
          const SizedBox(height: 14),
          Semantics(
            header: true,
            child: Text(
              title,
              textAlign: TextAlign.center,
              style: HermesType.title.copyWith(color: colors.textPrimary),
            ),
          ),
          if (body != null && body!.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              body!,
              textAlign: TextAlign.center,
              style: HermesType.text.copyWith(color: colors.textSecondary),
            ),
          ],
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: onAction,
              icon: const Icon(Icons.add_rounded, size: 18),
              label: Text(actionLabel!),
            ),
          ],
        ],
      ),
    );
  }
}

/// One-line page notice: icon + support text + optional action + 48 dp close.
/// No box (a faint tint at most).
class HermesInlineNotice extends StatelessWidget {
  final String message;
  final IconData icon;
  final HermesStatusTone tone;
  final String? actionLabel;
  final VoidCallback? onAction;
  final VoidCallback? onDismiss;

  const HermesInlineNotice({
    super.key,
    required this.message,
    this.icon = Icons.info_outline_rounded,
    this.tone = HermesStatusTone.neutral,
    this.actionLabel,
    this.onAction,
    this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final color = tone.colorIn(colors);
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: HermesType.support.copyWith(
                color: tone == HermesStatusTone.neutral
                    ? colors.textSecondary
                    : color,
              ),
            ),
          ),
          if (actionLabel != null && onAction != null)
            TextButton(
              onPressed: onAction,
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              child: Text(actionLabel!),
            ),
          if (onDismiss != null)
            IconButton(
              tooltip: Strings.of(context).designDismiss,
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              iconSize: 18,
              color: colors.textSecondary,
              onPressed: onDismiss,
              icon: const Icon(Icons.close_rounded),
            ),
        ],
      ),
    );
  }
}
