import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import 'chat_live_icon.dart';

/// The state a delegated-work piece draws its icon for.
enum DelegatedIconState { running, done, failed, unknown }

/// One place, one function per icon: the capsule above the composer and the
/// subagent cards in the chat draw their icons through these. Running icons
/// animate only while the work is confirmed running; an unknown state keeps
/// the quiet Material glyph, and every icon falls back to Material until its
/// strip is loaded.
Widget delegatedCapsuleIcon(
  BuildContext context,
  DelegatedIconState state, {
  required Color color,
  double size = 16,
}) => _live(
  state,
  ChatLiveGlyph.agentTeam,
  Icons.help_outline_rounded,
  color,
  size,
);

/// The leading icon of a subagent's card in the chat (and in the sheet rows).
Widget delegatedChildIcon(
  BuildContext context,
  DelegatedIconState state, {
  required Color color,
  double size = 16,
}) => _live(
  state,
  ChatLiveGlyph.delegateTask,
  Icons.help_outline_rounded,
  color,
  size,
);

/// The icon in the sheet header: the team glyph.
Widget delegatedSheetIcon(
  BuildContext context,
  DelegatedIconState state, {
  required Color color,
  double size = 18,
}) => _live(
  state,
  ChatLiveGlyph.parallelTools,
  Icons.help_outline_rounded,
  color,
  size,
);

Widget _live(
  DelegatedIconState state,
  ChatLiveGlyph running,
  IconData unknown,
  Color color,
  double size,
) {
  if (state == DelegatedIconState.unknown) {
    return Icon(unknown, size: size, color: color);
  }
  return ChatLiveIcon(
    switch (state) {
      DelegatedIconState.running => running,
      DelegatedIconState.done => ChatLiveGlyph.check,
      _ => ChatLiveGlyph.error,
    },
    live: state == DelegatedIconState.running,
    size: size,
    color: color,
  );
}

/// The ink of a delegated icon in a list: the chat's one quiet ink, the
/// error ink for a failure, the faint ink when its state is unknown. Never a
/// state colour for work that runs or ended well.
Color delegatedIconInk(HermesThemeColors colors, DelegatedIconState state) =>
    switch (state) {
      DelegatedIconState.failed => colors.error,
      DelegatedIconState.unknown => colors.textTertiary,
      _ => colors.textSecondary,
    };

/// The chevron that says the capsule opens a sheet.
Widget delegatedCapsuleChevron(
  BuildContext context, {
  required Color color,
  double size = 18,
}) => Icon(Icons.chevron_right_rounded, size: size, color: color);
