import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../screens/subagent_detail_screen.dart' show SubagentLiveTail;
import '../services/subagent_finished_record.dart';
import '../services/subagent_live_watch.dart';
import 'activity_pill.dart' show formatTurnElapsed;
import 'console_loader.dart';
import 'subagent_stream_view.dart';

/// What a finished subagent did: its goal, the steps it ran and its result,
/// read once (when the page opens) from the best source there is. Rendered
/// through the same rows as the live log; it only adds the headings.
class SubagentFinishedView extends StatefulWidget {
  const SubagentFinishedView({
    super.key,
    required this.load,
    this.showGoal = true,
    this.showTargets = false,
  });

  /// Called once per view; the key decides when a new read is due.
  final Future<SubagentFinishedRecord> Function() load;

  /// The goal is withheld from openers that are not the owner.
  final bool showGoal;

  /// One-line targets (paths) of the steps: owner only.
  final bool showTargets;

  @override
  State<SubagentFinishedView> createState() => _SubagentFinishedViewState();
}

class _SubagentFinishedViewState extends State<SubagentFinishedView> {
  late final Future<SubagentFinishedRecord> _record = _read();
  final ValueNotifier<SubagentLiveTail> _tail = ValueNotifier(
    const SubagentLiveTail(),
  );
  final ValueNotifier<SubagentLiveWatchView> _view = ValueNotifier(
    const SubagentLiveWatchView(),
  );

  Future<SubagentFinishedRecord> _read() async {
    SubagentFinishedRecord record;
    try {
      record = await widget.load();
    } catch (_) {
      record = SubagentFinishedRecord.empty;
    }
    if (mounted) {
      _view.value = SubagentLiveWatchView(
        status: SubagentLiveWatchStatus.finished,
        blocks: record.blocks,
      );
    }
    return record;
  }

  @override
  void dispose() {
    _tail.dispose();
    _view.dispose();
    super.dispose();
  }

  String? _meta(Strings s, SubagentFinishedRecord record) {
    final parts = <String>[
      if (record.durationSeconds case final seconds?
          when seconds.isFinite &&
              seconds >= 0 &&
              seconds < const Duration(days: 1).inSeconds)
        '${s.subagentUiTechDuration}: ${formatTurnElapsed(Duration(milliseconds: (seconds * 1000).round()))}',
      if (record.model case final model?) '${s.subagentUiTechModel}: $model',
      if (record.apiCalls case final calls?) '${s.subagentUiTechCalls}: $calls',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    return FutureBuilder<SubagentFinishedRecord>(
      future: _record,
      builder: (context, snapshot) {
        final record = snapshot.data;
        if (record == null) {
          return const Center(
            key: ValueKey('subagent-record-loading'),
            child: ConsoleLoader.medium(),
          );
        }
        final goal = widget.showGoal ? record.goal : '';
        final nothing =
            goal.isEmpty && record.blocks.isEmpty && record.result.isEmpty;
        return SubagentStreamView(
          key: const ValueKey('subagent-record'),
          tail: _tail,
          live: _view,
          prompt: goal,
          working: false,
          result: record.result,
          showTargets: widget.showTargets,
          active: false,
          recap: SubagentStreamRecap(
            task: s.sv2TaskSection,
            steps: s.subagentUiSectionDid,
            result: s.subagentUiSectionResult,
            empty: s.subagentRecordUnavailable,
            note: nothing || record.source == SubagentRecordSource.child
                ? null
                : s.subagentRecordParentOnly,
            meta: _meta(s, record),
          ),
        );
      },
    );
  }
}
