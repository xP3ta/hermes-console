import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../services/quick_reply_prefs.dart';
import '../../theme/app_theme.dart';
import '../hermes_suggestions.dart';

/// Contextual reply chips closing the latest finished answer.
///
/// The rail sits inside the assistant bubble, in the slot of the answer's
/// own suggestions, with the same compact transparent chips. The [replies]
/// are local and free; without them nothing is shown, not even ✨. The ✨
/// chip ([loadSmart]) is the only path to a model call and runs solely on
/// tap, once per [turnKey]: its ideas are cached until the turn changes. A
/// tap on any chip only fills the composer through [onFill]; nothing is
/// sent. The rail listens to the composer and the setting itself, so hiding
/// or showing it never rebuilds the screen.
class ChatQuickReplyBar extends StatefulWidget {
  const ChatQuickReplyBar({
    super.key,
    required this.turnKey,
    required this.replies,
    required this.composer,
    required this.onFill,
    required this.smartLabel,
    this.loadSmart,
  });

  /// Identity of the finished assistant turn; null offers nothing.
  final Object? turnKey;
  final List<String> replies;
  final ValueListenable<TextEditingValue> composer;
  final ValueChanged<String> onFill;
  final String smartLabel;

  /// Null hides the ✨ chip (read-only, no capability).
  final Future<List<String>> Function()? loadSmart;

  @override
  State<ChatQuickReplyBar> createState() => _ChatQuickReplyBarState();
}

class _ChatQuickReplyBarState extends State<ChatQuickReplyBar> {
  Object? _smartTurn;
  List<String>? _smart;
  Object? _loadingTurn;

  /// Only emptiness matters: caret moves, selection on focus and further
  /// keystrokes must not rebuild the chips (they sit in a transcript row).
  late bool _composerEmpty = widget.composer.value.text.isEmpty;

  @override
  void initState() {
    super.initState();
    widget.composer.addListener(_onComposerChanged);
  }

  @override
  void dispose() {
    widget.composer.removeListener(_onComposerChanged);
    super.dispose();
  }

  void _onComposerChanged() {
    final empty = widget.composer.value.text.isEmpty;
    if (empty == _composerEmpty) return;
    setState(() => _composerEmpty = empty);
  }

  @override
  void didUpdateWidget(ChatQuickReplyBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.composer, widget.composer)) {
      oldWidget.composer.removeListener(_onComposerChanged);
      widget.composer.addListener(_onComposerChanged);
      _composerEmpty = widget.composer.value.text.isEmpty;
    }
    if (oldWidget.turnKey != widget.turnKey) {
      _smart = null;
      _smartTurn = null;
      _loadingTurn = null;
    }
  }

  Future<void> _askSmart() async {
    final load = widget.loadSmart;
    final turn = widget.turnKey;
    if (load == null || turn == null) return;
    if (_smartTurn == turn && _smart != null) return;
    if (_loadingTurn == turn) return;
    setState(() => _loadingTurn = turn);
    List<String> ideas;
    try {
      ideas = await load();
    } catch (_) {
      ideas = const [];
    }
    if (!mounted || widget.turnKey != turn || _loadingTurn != turn) return;
    setState(() {
      _loadingTurn = null;
      if (ideas.isNotEmpty) {
        _smartTurn = turn;
        _smart = List.unmodifiable(ideas.take(3));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final prefs = QuickReplyPrefs.shared;
    return ListenableBuilder(
      listenable: prefs,
      builder: (context, _) {
        final turn = widget.turnKey;
        if (!QuickReplyPrefs.shared.enabled ||
            turn == null ||
            widget.replies.isEmpty ||
            !_composerEmpty) {
          return const SizedBox.shrink();
        }
        final smart = _smartTurn == turn ? _smart : null;
        final chips = smart ?? widget.replies.take(3).toList(growable: false);
        return _rail(context, chips, smartShown: smart != null);
      },
    );
  }

  Widget _rail(
    BuildContext context,
    List<String> chips, {
    required bool smartShown,
  }) {
    final colors = Theme.of(context).hermes;
    final maxWidth = hermesSuggestionMaxWidth(context);
    final loading = _loadingTurn != null && _loadingTurn == widget.turnKey;
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 2),
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: SingleChildScrollView(
          key: const ValueKey('quick-reply-rail'),
          scrollDirection: Axis.horizontal,
          primary: false,
          padding: const EdgeInsets.only(right: 16),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var index = 0; index < chips.length; index++) ...[
                if (index > 0) const SizedBox(width: 8),
                Tooltip(
                  message: chips[index],
                  excludeFromSemantics: true,
                  child: OutlinedButton(
                    key: ValueKey('quick-reply-$index'),
                    onPressed: () => widget.onFill(chips[index]),
                    style: hermesSuggestionButtonStyle(
                      colors,
                      maxWidth: maxWidth,
                    ),
                    child: Text(
                      chips[index],
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
              if (widget.loadSmart != null) ...[
                const SizedBox(width: 8),
                Semantics(
                  button: true,
                  label: widget.smartLabel,
                  excludeSemantics: true,
                  child: Tooltip(
                    message: widget.smartLabel,
                    excludeFromSemantics: true,
                    child: OutlinedButton(
                      key: const ValueKey('quick-reply-smart'),
                      onPressed: loading ? null : () => unawaited(_askSmart()),
                      style: hermesSuggestionButtonStyle(
                        colors,
                        maxWidth: maxWidth,
                        highlighted: smartShown || loading,
                      ),
                      child: loading && reduceMotion
                          ? Icon(
                              Icons.hourglass_top_rounded,
                              size: 15,
                              color: colors.accent,
                            )
                          : loading
                          ? SizedBox.square(
                              dimension: 13,
                              child: CircularProgressIndicator(
                                strokeWidth: 1.7,
                                color: colors.accent,
                              ),
                            )
                          : Icon(
                              Icons.auto_awesome_outlined,
                              size: 16,
                              color: colors.accent,
                            ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
