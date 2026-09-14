import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../main.dart';
import '../models/desktop_control_center.dart';
import '../services/desktop_control_gateway.dart';
import '../theme/app_theme.dart';
import '../widgets/hermes_premium_ui.dart';
import '../widgets/hermes_ui.dart';
import 'lock_screen.dart';

/// Readable mobile view of native background work and saved spawn trees.
///
/// The surface intentionally omits raw prompts, host snapshot paths and output
/// tails. Those values may contain private code or secrets and are not needed
/// to identify or cancel the exact task.
class AgentCenterScreen extends StatefulWidget {
  final HermesDesktopControlGateway gateway;
  final String runtimeSessionId;
  final bool readOnly;
  final Future<void> Function()? disposeGateway;

  const AgentCenterScreen({
    required this.gateway,
    this.runtimeSessionId = '',
    this.readOnly = false,
    this.disposeGateway,
    super.key,
  });

  @override
  State<AgentCenterScreen> createState() => _AgentCenterScreenState();
}

class _AgentCenterScreenState extends State<AgentCenterScreen> {
  AgentCenterSnapshot? _snapshot;
  Object? _failure;
  bool _loading = true;
  final Set<String> _stopping = {};

  bool get _hasRuntime => widget.runtimeSessionId.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    final close = widget.disposeGateway;
    if (close != null) unawaited(close());
    super.dispose();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _failure = null;
      });
    }
    try {
      final snapshot = await widget.gateway.agentCenterSnapshot(
        runtimeSessionId: widget.runtimeSessionId,
      );
      if (!mounted) return;
      setState(() => _snapshot = snapshot);
    } catch (error) {
      if (!mounted) return;
      setState(() => _failure = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _failureText(Object failure, Strings strings) {
    if (failure is DesktopControlFailure) {
      return switch (failure.kind) {
        DesktopControlFailureKind.unsupported =>
          strings.agentCenterFailureUnsupported,
        DesktopControlFailureKind.forbidden =>
          strings.agentCenterFailureForbidden,
        DesktopControlFailureKind.invalidResponse =>
          strings.agentCenterFailureInvalidResponse,
        DesktopControlFailureKind.unavailable =>
          strings.agentCenterFailureUnavailable,
        DesktopControlFailureKind.rejected =>
          strings.agentCenterFailureRejected,
      };
    }
    return strings.agentCenterFailureUnknown;
  }

  Future<void> _showSpawnTree(SpawnTreeEntry entry, int ordinal) async {
    showHermesFloatingSurface<void>(
      context: context,
      surfaceKey: const ValueKey('agent-spawn-tree-surface'),
      maxWidth: 620,
      maxHeightFactor: 0.75,
      builder: (sheetContext) => SizedBox(
        height: MediaQuery.sizeOf(sheetContext).height * 0.6,
        child: FutureBuilder<SpawnTreeDetail>(
          future: widget.gateway.loadSpawnTree(entry.opaquePath),
          builder: (context, snapshot) {
            final strings = Strings.of(context);
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError || !snapshot.hasData) {
              return _AgentSheetMessage(
                icon: Icons.error_outline_rounded,
                text: strings.agentCenterHistoryOpenFailed,
              );
            }
            final detail = snapshot.data!;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 12, 10),
                  child: Row(
                    children: [
                      const Icon(Icons.account_tree_outlined),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          '${strings.agentCenterWorkFallback} $ordinal',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      IconButton(
                        tooltip: strings.commonClose,
                        onPressed: () => Navigator.pop(sheetContext),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: detail.subagents.isEmpty
                      ? _AgentSheetMessage(
                          icon: Icons.check_circle_outline_rounded,
                          text: strings.agentCenterHistoryEmpty,
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.all(16),
                          itemCount: detail.subagents.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 8),
                          itemBuilder: (context, index) {
                            final node = detail.subagents[index];
                            return HermesCard(
                              key: ValueKey(
                                'agent-center-history-$ordinal-subagent-${index + 1}',
                              ),
                              child: Row(
                                children: [
                                  const Icon(
                                    Icons.smart_toy_outlined,
                                    size: 20,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      strings.subagentActivityItem(index + 1),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  HermesBadge(
                                    _agentStatusLabel(node.status, strings),
                                    color: Theme.of(
                                      context,
                                    ).hermes.textSecondary,
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _stopProcess(BackgroundProcessEntry process, int ordinal) async {
    if (!_hasRuntime ||
        widget.readOnly ||
        _stopping.contains(process.opaqueId)) {
      return;
    }
    final strings = Strings.of(context);
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(strings.agentCenterStopProcessTitle),
        content: Text(
          strings.agentCenterStopProcessBody(
            strings.agentCenterProcessFallback('$ordinal'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(strings.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(strings.agentCenterStop),
          ),
        ],
      ),
    );
    if (approved != true || !mounted || widget.readOnly) return;
    final lock = context.findAncestorStateOfType<HermesAppState>()?.appLock;
    if (lock != null) {
      final verified = await LockScreen.verify(
        context,
        lock,
        reason: strings.agentCenterStopProcessTitle,
      );
      if (!verified || !mounted || widget.readOnly) return;
    }
    setState(() => _stopping.add(process.opaqueId));
    try {
      await widget.gateway.killBackgroundProcess(
        widget.runtimeSessionId,
        process.opaqueId,
      );
      await _load();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(Strings.of(context).agentCenterStopFailed)),
      );
    } finally {
      if (mounted) setState(() => _stopping.remove(process.opaqueId));
    }
  }

  Future<void> _startBackgroundTask() async {
    if (!_hasRuntime || widget.readOnly) return;
    final strings = Strings.of(context);
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(strings.agentCenterNewTaskTitle),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: 2,
          maxLines: 5,
          maxLength: 2000,
          decoration: InputDecoration(hintText: strings.agentCenterNewTaskHint),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(strings.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: Text(strings.agentCenterStart),
          ),
        ],
      ),
    );
    controller.dispose();
    if (text == null || text.isEmpty || !mounted || widget.readOnly) return;
    try {
      await widget.gateway.startBackgroundTask(widget.runtimeSessionId, text);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(Strings.of(context).agentCenterTaskAccepted)),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(Strings.of(context).agentCenterTaskStartFailed)),
      );
    }
  }

  String _historySubtitle(SpawnTreeEntry entry, Strings strings) {
    final epoch = entry.finishedAt > 0 ? entry.finishedAt : entry.startedAt;
    if (epoch <= 0) return strings.agentCenterSubagentCount(entry.count);
    try {
      final milliseconds = epoch >= 1000000000000
          ? epoch.round()
          : (epoch * 1000).round();
      final date = DateTime.fromMillisecondsSinceEpoch(
        milliseconds,
        isUtc: true,
      ).toLocal();
      return strings.agentCenterSubagentCountWithDate(
        entry.count,
        MaterialLocalizations.of(context).formatShortDate(date),
      );
    } catch (_) {
      return strings.agentCenterSubagentCount(entry.count);
    }
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(strings.agentCenterTitle),
        actions: [
          IconButton(
            tooltip: strings.agentCenterRefreshTooltip,
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: _loading && snapshot == null
            ? const Center(child: CircularProgressIndicator())
            : _failure != null && snapshot == null
            ? _AgentFailure(
                message: _failureText(_failure!, strings),
                onRetry: _load,
              )
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
                  children: [
                    Text(
                      _hasRuntime
                          ? strings.agentCenterIntroRuntime
                          : strings.agentCenterIntroInstance,
                      style: TextStyle(
                        color: colors.textSecondary,
                        fontSize: 12.5,
                        height: 1.35,
                      ),
                    ),
                    if (_hasRuntime && !widget.readOnly) ...[
                      const SizedBox(height: 12),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: FilledButton.tonalIcon(
                          key: const ValueKey('agent-center-new-task'),
                          onPressed: _startBackgroundTask,
                          icon: const Icon(Icons.add_task_rounded, size: 19),
                          label: Text(strings.agentCenterNewTask),
                        ),
                      ),
                    ],
                    if (_hasRuntime) ...[
                      HermesSectionHeader(strings.agentCenterRunningSection),
                      if (snapshot == null || snapshot.processes.isEmpty)
                        _AgentEmpty(
                          icon: Icons.hourglass_empty_rounded,
                          text: strings.agentCenterNoProcesses,
                        )
                      else
                        HermesGroup(
                          children: [
                            for (final (index, process)
                                in snapshot.processes.indexed)
                              Material(
                                type: MaterialType.transparency,
                                child: ListTile(
                                  key: ValueKey(
                                    'agent-center-process-${index + 1}',
                                  ),
                                  minTileHeight: 58,
                                  leading: Icon(
                                    process.status == AgentCenterStatus.running
                                        ? Icons.play_circle_outline_rounded
                                        : Icons.timelapse_rounded,
                                  ),
                                  title: Text(
                                    strings.agentCenterProcessFallback(
                                      '${index + 1}',
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: Text(
                                    strings.agentCenterProcessStatus(
                                      _agentStatusLabel(
                                        process.status,
                                        strings,
                                      ),
                                      process.uptimeSeconds,
                                    ),
                                  ),
                                  trailing: _hasRuntime && !widget.readOnly
                                      ? IconButton(
                                          key: ValueKey(
                                            'agent-center-process-stop-${index + 1}',
                                          ),
                                          tooltip:
                                              strings.agentCenterStopTooltip,
                                          onPressed:
                                              _stopping.contains(
                                                process.opaqueId,
                                              )
                                              ? null
                                              : () => _stopProcess(
                                                  process,
                                                  index + 1,
                                                ),
                                          icon:
                                              _stopping.contains(
                                                process.opaqueId,
                                              )
                                              ? const SizedBox.square(
                                                  dimension: 20,
                                                  child:
                                                      CircularProgressIndicator(
                                                        strokeWidth: 2,
                                                      ),
                                                )
                                              : const Icon(
                                                  Icons.stop_circle_outlined,
                                                ),
                                        )
                                      : null,
                                ),
                              ),
                          ],
                        ),
                    ],
                    HermesSectionHeader(strings.agentCenterHistorySection),
                    if (snapshot == null || snapshot.snapshots.isEmpty)
                      _AgentEmpty(
                        icon: Icons.account_tree_outlined,
                        text: strings.agentCenterNoHistory,
                      )
                    else
                      HermesGroup(
                        children: [
                          for (final (index, entry)
                              in snapshot.snapshots.indexed)
                            Material(
                              type: MaterialType.transparency,
                              child: ListTile(
                                key: ValueKey(
                                  'agent-center-history-${index + 1}',
                                ),
                                minTileHeight: 58,
                                leading: const Icon(Icons.hub_outlined),
                                title: Text(
                                  '${strings.agentCenterWorkFallback} ${index + 1}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  _historySubtitle(entry, strings),
                                ),
                                trailing: const Icon(
                                  Icons.chevron_right_rounded,
                                ),
                                onTap: () => _showSpawnTree(entry, index + 1),
                              ),
                            ),
                        ],
                      ),
                    if (_failure != null && snapshot != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          strings.agentCenterStaleView(
                            _failureText(_failure!, strings),
                          ),
                          style: TextStyle(color: colors.warning, fontSize: 12),
                        ),
                      ),
                  ],
                ),
              ),
      ),
    );
  }
}

class _AgentFailure extends StatelessWidget {
  final String message;
  final Future<void> Function() onRetry;

  const _AgentFailure({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off_outlined, size: 36),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: Text(Strings.of(context).commonRetry),
          ),
        ],
      ),
    ),
  );
}

class _AgentEmpty extends StatelessWidget {
  final IconData icon;
  final String text;

  const _AgentEmpty({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return HermesPanel(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Icon(icon, color: colors.textSecondary, size: 30),
            const SizedBox(height: 8),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.textSecondary, fontSize: 12.5),
            ),
          ],
        ),
      ),
    );
  }
}

class _AgentSheetMessage extends StatelessWidget {
  final IconData icon;
  final String text;

  const _AgentSheetMessage({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 34),
          const SizedBox(height: 12),
          Text(text),
        ],
      ),
    ),
  );
}

String _agentStatusLabel(AgentCenterStatus value, Strings strings) {
  return switch (value) {
    AgentCenterStatus.requested => strings.subagentActivityRequested,
    AgentCenterStatus.running => strings.statusRunning,
    AgentCenterStatus.thinking => strings.subagentActivityThinking,
    AgentCenterStatus.tool => strings.subagentActivityTool,
    AgentCenterStatus.completed => strings.subagentActivityCompleted,
    AgentCenterStatus.failed => strings.subagentActivityFailed,
    AgentCenterStatus.cancelled => strings.subagentActivityCancelled,
    AgentCenterStatus.stopped => strings.statusStopped,
    AgentCenterStatus.unknown => strings.subagentActivityUnknown,
  };
}
