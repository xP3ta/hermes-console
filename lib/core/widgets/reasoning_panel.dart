import 'package:flutter/material.dart';

import 'chat_turn_activity.dart';

/// The model's thinking in the activity view and wherever a reasoning block
/// stands on its own: the same thin line as the chat's trace (mock 137 A,
/// [ThinkingLine]), «Pensando… · 12 s» while [live] and «Pensamiento · 12 s»
/// once finished, which opens to six lines and then the whole thought.
///
/// Before 1.4.0 this was a header over a six-line box with «Ver todo», open
/// as soon as the model thought: the owner asked for the thinking not to load the
/// screen (mock 137, «Hoy» column).
class ReasoningPanel extends StatelessWidget {
  const ReasoningPanel({
    required this.text,
    this.live = false,
    this.meta,
    this.duration,
    this.bodyKey,
    super.key,
  });

  final String text;

  /// Still streaming: «Pensando…», the live dot and the last sentence.
  final bool live;

  /// The time, already worded (`12 s`).
  final String? meta;

  /// How long it thought, worded like the chat's trace (`12 s`).
  final Duration? duration;

  /// Key of the opened body (the activity view keeps
  /// `activity-now-reasoning` for its scroll contract).
  final Key? bodyKey;

  @override
  Widget build(BuildContext context) => KeyedSubtree(
    key: const ValueKey('reasoning-panel'),
    child: ThinkingLine(
      text: text,
      live: live,
      timeLabel: meta,
      duration: duration,
      bodyKey: bodyKey,
    ),
  );
}
