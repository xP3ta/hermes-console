import 'dart:async';

import 'package:flutter/material.dart';

import '../models/activity_snapshot.dart';
import 'activity_panel.dart';

class ActivityTaskLingerHost extends StatefulWidget {
  const ActivityTaskLingerHost({
    required this.snapshot,
    this.actions = ActivityPanelActions.none,
    this.clock,
    this.revealAfter = const Duration(seconds: 2),
    this.suspended = false,
    @visibleForTesting
    this.lingerAfterFinished = const Duration(seconds: 4),
    super.key,
  });

  final ActivitySnapshot snapshot;
  final ActivityPanelActions actions;
  final DateTime Function()? clock;
  final Duration revealAfter;
  final bool suspended;
  final Duration lingerAfterFinished;

  @override
  State<ActivityTaskLingerHost> createState() => _ActivityTaskLingerHostState();
}

class _ActivityTaskLingerHostState extends State<ActivityTaskLingerHost> {
  Timer? _lingerTimer;
  bool _lingering = false;

  @override
  void didUpdateWidget(ActivityTaskLingerHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    final tasks = widget.snapshot.tasks;
    if (tasks == null || tasks.isEmpty || tasks.hasOpen) {
      _cancelLinger();
      return;
    }

    final oldTasks = oldWidget.snapshot.tasks;
    if (tasks.isFinished &&
        oldTasks != null &&
        oldTasks.hasOpen &&
        oldWidget.snapshot.showTasks) {
      _lingerTimer?.cancel();
      _lingering = true;
      _lingerTimer = Timer(widget.lingerAfterFinished, () {
        _lingerTimer = null;
        if (mounted) setState(() => _lingering = false);
      });
    }
  }

  void _cancelLinger() {
    _lingerTimer?.cancel();
    _lingerTimer = null;
    _lingering = false;
  }

  @override
  void dispose() {
    _lingerTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _lingering && !widget.snapshot.showTasks
        ? widget.snapshot.withTasksActive(true)
        : widget.snapshot;
    return ActivityPillHost(
      snapshot: snapshot,
      actions: widget.actions,
      clock: widget.clock,
      revealAfter: widget.revealAfter,
      suspended: widget.suspended,
    );
  }
}
