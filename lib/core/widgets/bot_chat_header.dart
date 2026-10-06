import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../models/activity_snapshot.dart';
import '../theme/app_theme.dart';
import 'activity_dots.dart' show activityStepTitle;

// dc1215: the canonical Bot Chat header in the Dots style. The bot's face
// rides centred on a pill with its name in bold and ONE line of live
// status under it. Normal chats keep their own header.

enum BotChatHeaderTone { idle, working, waiting }

/// The status line of the header: [text] is null when there is nothing
/// true to say (an idle bot whose last activity is unknown).
typedef BotChatHeaderStatus = ({String? text, BotChatHeaderTone tone});

/// What the header says, from the chat's own state:
///
///  * a pending approval → «Te espera: aprobación» (amber);
///  * a pending question, or a turn waiting for the user → «Te espera:
///    respuesta» (amber);
///  * a running turn → the current step as the working line names it, else
///    the latest finished step, else the pipeline headline or «Pensando…»;
///  * otherwise [idleText] (the last activity), never an invented one.
///
/// Background work alone (subagents, processes) does not make the bot
/// «think»: the activity view shows it.
BotChatHeaderStatus botChatHeaderStatus({
  required Strings strings,
  required bool approvalPending,
  required bool questionPending,
  required ActivitySnapshot snapshot,
  String? idleText,
}) {
  if (approvalPending) {
    return (
      text: strings.dc1215WaitingApproval,
      tone: BotChatHeaderTone.waiting,
    );
  }
  if (questionPending || (snapshot.turnActive && snapshot.waitingForUser)) {
    return (text: strings.dc1215WaitingAnswer, tone: BotChatHeaderTone.waiting);
  }
  if (snapshot.turnActive) {
    final current = snapshot.current;
    final String text;
    if (current != null && current.kind != ActivityStepKind.reasoning) {
      text = activityStepTitle(current);
    } else if (snapshot.done.isNotEmpty) {
      text = activityStepTitle(snapshot.done.first);
    } else {
      text = snapshot.headline ?? strings.chatActivityThinking;
    }
    return (text: text, tone: BotChatHeaderTone.working);
  }
  return (text: idleText, tone: BotChatHeaderTone.idle);
}

/// Face over a name pill with one status line. [compact] (the transcript is
/// scrolled away from the newest message) puts a smaller face beside the
/// pill in a standard-height bar.
class BotChatDotsHeader extends StatelessWidget {
  const BotChatDotsHeader({
    required this.faceBuilder,
    required this.name,
    required this.status,
    this.compact = false,
    super.key,
  });

  /// Builds the bot's face at the given size (the living face in the app).
  final Widget Function(double size) faceBuilder;
  final String name;
  final BotChatHeaderStatus status;
  final bool compact;

  static const double _face = 36;
  static const double _compactFace = 28;
  static const double _overlap = 8;
  static const double _nameSize = 15;
  static const double _nameHeight = 1.2;
  static const double _statusSize = 12.5;
  static const double _statusHeight = 1.25;

  static double _pillPadding(bool compact) => compact ? 5 : 7;

  static double _pillHeight(TextScaler scaler, {required bool compact}) =>
      _pillPadding(compact) * 2 +
      scaler.scale(_nameSize) * _nameHeight +
      scaler.scale(_statusSize) * _statusHeight +
      2;

  /// Material clamps an app bar title's text scale to this factor.
  static const double maxTitleTextScale = 1.34;

  /// The toolbar height the header needs at this text scale (clamped like
  /// every app bar title).
  static double heightFor(TextScaler textScaler, {required bool compact}) {
    final scaler = textScaler.clamp(maxScaleFactor: maxTitleTextScale);
    final pill = _pillHeight(scaler, compact: compact);
    final content = compact
        ? (pill > _compactFace ? pill : _compactFace)
        : _face - _overlap + pill;
    return (content + 8).ceilToDouble();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final text = status.text;
    final statusColor = status.tone == BotChatHeaderTone.waiting
        ? colors.warning
        : colors.textSecondary;
    final pill = DecoratedBox(
      key: const ValueKey('bot-chat-header-pill'),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: colors.divider, width: 0.8),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: 16,
          vertical: _pillPadding(compact),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: _nameSize,
                height: _nameHeight,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.1,
                color: colors.textPrimary,
              ),
            ),
            if (text != null)
              Text(
                text,
                key: const ValueKey('bot-chat-header-subtitle'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: _statusSize,
                  height: _statusHeight,
                  fontWeight: FontWeight.w500,
                  color: statusColor,
                ),
              ),
          ],
        ),
      ),
    );
    final Widget body;
    if (compact) {
      body = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox.square(
            dimension: _compactFace,
            child: faceBuilder(_compactFace),
          ),
          const SizedBox(width: 8),
          Flexible(child: pill),
        ],
      );
    } else {
      // The face paints over the pill's top edge, as in the mockup.
      body = Stack(
        alignment: Alignment.topCenter,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: _face - _overlap),
            child: pill,
          ),
          SizedBox.square(dimension: _face, child: faceBuilder(_face)),
        ],
      );
    }
    return Semantics(
      container: true,
      header: true,
      label: [name, ?text].join(', '),
      excludeSemantics: true,
      child: body,
    );
  }
}
