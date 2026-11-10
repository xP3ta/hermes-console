import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../design/modal.dart' show showHermesSurface;
import '../../models/activity_snapshot.dart';
import '../../theme/app_theme.dart';
import '../../theme/hermes_tokens.dart';
import '../../theme/readable_ink.dart';
import '../chat_event_cards.dart' show ChatTraceEvent, memoryWriteLabel;
import 'turn_step_motion.dart';

typedef ConfirmedMemoryWrite = ({String id, MemoryWrite write});

/// A receipt requires a completed memory tool and its successful result.
/// Replayed IDs retain only the latest status, without changing the trace.
List<ConfirmedMemoryWrite> confirmedTurnMemory(
  Iterable<ChatTraceEvent> events,
) {
  final latest = <String, ChatTraceEvent>{};
  for (final event in events) {
    latest[event.id] = event;
  }
  return [
    for (final event in latest.values)
      if (event.memoryLanded) (id: event.id, write: event.memory!),
  ];
}

String confirmedMemoryLabel(Strings s, List<ConfirmedMemoryWrite> writes) {
  assert(writes.isNotEmpty);
  final first = writes.first.write;
  if (writes.every(
    (entry) =>
        entry.write.action == first.action &&
        entry.write.userTarget == first.userTarget,
  )) {
    return memoryWriteLabel(s, first);
  }
  return writes.every((entry) => entry.write.userTarget)
      ? s.mp1215ProfileUpdated
      : s.mp1215MemoryUpdated;
}

/// One actionable receipt at the answer's foot, live and in history.
/// Announcements belong to the screen's turn event, never to widget mounts
/// or live regions: rebuilding, scrolling or settling cannot repeat them.
class TurnMemoryPill extends StatelessWidget {
  const TurnMemoryPill({required this.events, this.active = false, super.key});

  final List<ChatTraceEvent> events;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final writes = confirmedTurnMemory(events);
    if (writes.isEmpty) return const SizedBox.shrink();
    final label = confirmedMemoryLabel(Strings.of(context), writes);
    final colors = Theme.of(context).hermes;
    final ink = readableInkOnTint(colors.textSecondary, colors.surface, colors);
    void open() => showHermesSurface<void>(
      context: context,
      surfaceKey: const ValueKey('turn-memory-preview'),
      maxWidth: 560,
      builder: (context) => _MemoryReceipt(writes: writes),
    );
    return TurnStepMotion(
      animateInitial: active,
      entries: [
        (
          id: 'confirmed-memory',
          child: Padding(
            padding: const EdgeInsets.only(top: HermesSpace.x2),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: IntrinsicWidth(
                child: Semantics(
                  button: true,
                  label: label,
                  onTap: open,
                  excludeSemantics: true,
                  child: Material(
                    color: colors.surface,
                    shape: StadiumBorder(
                      side: BorderSide(color: colors.divider),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      key: const ValueKey('turn-memory-pill'),
                      onTap: open,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          minHeight: HermesSize.tap,
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: HermesSpace.x3,
                            vertical: HermesSpace.x2,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.psychology_outlined,
                                size: HermesIcon.md,
                                color: ink,
                              ),
                              const SizedBox(width: HermesSpace.x2),
                              Flexible(
                                child: Text(
                                  label,
                                  style: HermesType.support.copyWith(
                                    color: ink,
                                  ),
                                ),
                              ),
                              const SizedBox(width: HermesSpace.x1),
                              Icon(
                                Icons.chevron_right_rounded,
                                size: HermesIcon.sm,
                                color: ink,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _MemoryReceipt extends StatelessWidget {
  const _MemoryReceipt({required this.writes});
  final List<ConfirmedMemoryWrite> writes;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(HermesSpace.x4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      confirmedMemoryLabel(s, writes),
                      style: HermesType.title.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded, size: HermesIcon.lg),
                ),
              ],
            ),
            for (final entry in writes)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: HermesSpace.x3),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      memoryWriteLabel(s, entry.write),
                      style: HermesType.support.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                    if (entry.write.preview case final preview?) ...[
                      const SizedBox(height: HermesSpace.x1),
                      Text(
                        preview,
                        key: ValueKey(('memory-preview', entry.id)),
                        style: HermesType.text.copyWith(
                          color: colors.textPrimary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
