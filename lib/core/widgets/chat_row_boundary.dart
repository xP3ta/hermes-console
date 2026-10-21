import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../services/app_error_log.dart';
import '../theme/app_theme.dart';

/// Test seams, null in production: a fault in the plan phase, or a row child
/// that replaces the real one (and may throw while building).
abstract final class ChatRowFaults {
  static void Function(Map<String, dynamic> message)? debugPlanFault;
  static Widget? Function(Object unit)? debugRowChild;
}

/// Wraps one transcript row so a build error below it stays inside the row.
/// Carries the log id and the raw text offered by "Copy plain text".
final class ChatRowScope extends InheritedWidget {
  const ChatRowScope({
    required this.rowId,
    required this.raw,
    required super.child,
    super.key,
  });
  final String rowId;
  final String? raw;

  @override
  bool updateShouldNotify(ChatRowScope old) => false;
}

ErrorWidgetBuilder? _installed;

/// Inside a [ChatRowScope] a failed descendant becomes a bounded card; anywhere
/// else the previous builder answers exactly as before.
void installChatRowErrorWidget() {
  if (identical(ErrorWidget.builder, _installed)) return;
  final outside = ErrorWidget.builder;
  ErrorWidget.builder = _installed = (details) =>
      _ScopedErrorFallback(details, outside);
}

class _ScopedErrorFallback extends StatefulWidget {
  const _ScopedErrorFallback(this.details, this.outside);
  final FlutterErrorDetails details;
  final ErrorWidgetBuilder outside;

  @override
  State<_ScopedErrorFallback> createState() => _ScopedErrorFallbackState();
}

class _ScopedErrorFallbackState extends State<_ScopedErrorFallback> {
  ChatRowScope? _scope;

  @override
  void initState() {
    super.initState();
    // A card that itself fails to build must not recurse into another card.
    if (context.findAncestorWidgetOfExactType<ChatRowFailureCard>() == null) {
      _scope = context.getInheritedWidgetOfExactType<ChatRowScope>();
    }
    final scope = _scope;
    if (scope == null) return;
    AppErrorLog.record(
      'chat-row',
      widget.details.exception,
      rowId: scope.rowId,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scope = _scope;
    if (scope == null) return widget.outside(widget.details);
    return ChatRowFailureCard(raw: scope.raw);
  }
}

class ChatRowFailureCard extends StatefulWidget {
  const ChatRowFailureCard({required this.raw, super.key});
  final String? raw;

  @override
  State<ChatRowFailureCard> createState() => _ChatRowFailureCardState();
}

class _ChatRowFailureCardState extends State<ChatRowFailureCard> {
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final tone = Theme.of(context).hermes.warning;
    final raw = widget.raw;
    return Container(
      key: const ValueKey('chat-row-failure'),
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 6),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.07),
        border: Border.all(color: tone.withValues(alpha: 0.30)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(strings.chatRowFailedTitle),
          if (raw != null)
            TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: raw));
                if (mounted) setState(() => _copied = true);
              },
              child: Text(
                _copied ? strings.chatRowCopied : strings.chatRowCopyPlain,
              ),
            ),
        ],
      ),
    );
  }
}
