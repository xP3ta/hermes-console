import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../main.dart';
import '../models/desktop_control_center.dart';
import '../services/desktop_control_gateway.dart';
import '../theme/app_theme.dart';
import '../widgets/hermes_notice.dart';
import '../widgets/hermes_premium_ui.dart';
import '../widgets/hermes_ui.dart';
import 'lock_screen.dart';

/// Mobile projection of Hermes Desktop's native rollback timeline.
///
/// Recovery is deliberately scoped to one live runtime session. The client
/// never accepts a device path and never suggests that restoring files also
/// rewinds the conversation transcript.
class RecoveryCenterScreen extends StatefulWidget {
  final HermesDesktopControlGateway gateway;
  final String runtimeSessionId;
  final bool readOnly;
  final Future<void> Function()? disposeGateway;

  const RecoveryCenterScreen({
    required this.gateway,
    required this.runtimeSessionId,
    this.readOnly = false,
    this.disposeGateway,
    super.key,
  });

  @override
  State<RecoveryCenterScreen> createState() => _RecoveryCenterScreenState();
}

class _RecoveryCenterScreenState extends State<RecoveryCenterScreen> {
  RecoveryTimeline? _timeline;
  Object? _failure;
  bool _loading = true;

  bool get _hasRuntime => widget.runtimeSessionId.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    if (_hasRuntime) {
      unawaited(_load());
    } else {
      _loading = false;
    }
  }

  @override
  void didUpdateWidget(covariant RecoveryCenterScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.runtimeSessionId != widget.runtimeSessionId ||
        oldWidget.gateway != widget.gateway) {
      _timeline = null;
      _failure = null;
      if (_hasRuntime) {
        unawaited(_load());
      } else {
        setState(() => _loading = false);
      }
    }
  }

  @override
  void dispose() {
    final close = widget.disposeGateway;
    if (close != null) unawaited(close());
    super.dispose();
  }

  Future<void> _load() async {
    if (!_hasRuntime) return;
    if (mounted) {
      setState(() {
        _loading = true;
        _failure = null;
      });
    }
    try {
      final timeline = await widget.gateway.listRecovery(
        widget.runtimeSessionId,
      );
      if (!mounted) return;
      setState(() => _timeline = timeline);
    } catch (error) {
      if (!mounted) return;
      setState(() => _failure = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openCheckpoint(RecoveryCheckpoint checkpoint) async {
    final restored = await showHermesFloatingSurface<bool>(
      context: context,
      surfaceKey: const ValueKey('recovery-checkpoint-surface'),
      maxWidth: 680,
      maxHeightFactor: 0.82,
      builder: (context) => SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.68,
        child: _RecoveryCheckpointSheet(
          gateway: widget.gateway,
          runtimeSessionId: widget.runtimeSessionId,
          checkpoint: checkpoint,
          readOnly: widget.readOnly,
        ),
      ),
    );
    if (restored != true || !mounted) return;
    await _load();
    if (!mounted) return;
    HermesNotice.of(context).showSnackBar(
      SnackBar(content: Text(Strings.of(context).recoveryCenterRestored)),
      kind: HermesNoticeKind.success,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final timeline = _timeline;
    return Scaffold(
      appBar: AppBar(
        title: Text(strings.recoveryCenterTitle),
        actions: [
          IconButton(
            tooltip: strings.recoveryCenterRefreshTooltip,
            onPressed: !_hasRuntime || _loading ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: !_hasRuntime
            ? _RecoveryMessage(
                icon: Icons.forum_outlined,
                title: strings.recoveryCenterNoActiveTitle,
                body: strings.recoveryCenterNoActiveBody,
              )
            : _loading && timeline == null
            ? const Center(child: CircularProgressIndicator())
            : _failure != null && timeline == null
            ? _RecoveryFailure(
                message: _recoveryFailureText(_failure!, strings),
                onRetry: _load,
              )
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
                  children: [
                    Text(
                      strings.recoveryCenterIntro,
                      style: TextStyle(
                        color: colors.textSecondary,
                        fontSize: 12.5,
                        height: 1.35,
                      ),
                    ),
                    if (widget.readOnly)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: _RecoveryNotice(
                          icon: Icons.lock_outline_rounded,
                          text: strings.recoveryCenterReadOnlyNotice,
                        ),
                      ),
                    HermesSectionHeader(strings.recoveryCenterTimelineSection),
                    if (timeline?.enabled == false)
                      _RecoveryMessage(
                        icon: Icons.history_toggle_off_rounded,
                        title: strings.recoveryCenterDisabledTitle,
                        body: strings.recoveryCenterDisabledBody,
                        compact: true,
                      )
                    else if (timeline == null || timeline.checkpoints.isEmpty)
                      _RecoveryMessage(
                        icon: Icons.history_rounded,
                        title: strings.recoveryCenterEmptyTitle,
                        body: strings.recoveryCenterEmptyBody,
                        compact: true,
                      )
                    else
                      ...timeline.checkpoints.map(
                        (checkpoint) => Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: HermesCard(
                            key: ValueKey(
                              'recovery-checkpoint-${checkpoint.hash}',
                            ),
                            onTap: () => _openCheckpoint(checkpoint),
                            child: Row(
                              children: [
                                const HermesIconTile(
                                  Icons.restore_page_outlined,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        _safeRemoteText(
                                          checkpoint.message.isEmpty
                                              ? strings
                                                    .recoveryCenterSavedFallback
                                              : checkpoint.message,
                                          strings,
                                        ),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: colors.textPrimary,
                                          fontWeight: FontWeight.w600,
                                          fontSize: 14,
                                        ),
                                      ),
                                      const SizedBox(height: 5),
                                      Text(
                                        [
                                          _shortHash(checkpoint.hash),
                                          if (checkpoint.timestamp.isNotEmpty)
                                            _safeRemoteText(
                                              checkpoint.timestamp,
                                              strings,
                                            ),
                                        ].join(' · '),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: colors.textSecondary,
                                          fontFamily: 'monospace',
                                          fontSize: 11.5,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Icon(
                                  Icons.chevron_right_rounded,
                                  color: colors.textDisabled,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    if (_failure != null && timeline != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          strings.recoveryCenterStaleView(
                            _recoveryFailureText(_failure!, strings),
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

class _RecoveryCheckpointSheet extends StatefulWidget {
  final HermesDesktopControlGateway gateway;
  final String runtimeSessionId;
  final RecoveryCheckpoint checkpoint;
  final bool readOnly;

  const _RecoveryCheckpointSheet({
    required this.gateway,
    required this.runtimeSessionId,
    required this.checkpoint,
    required this.readOnly,
  });

  @override
  State<_RecoveryCheckpointSheet> createState() =>
      _RecoveryCheckpointSheetState();
}

class _RecoveryCheckpointSheetState extends State<_RecoveryCheckpointSheet> {
  RecoveryDiff? _diff;
  Object? _failure;
  bool _loading = true;
  bool _restoring = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadDiff());
  }

  Future<void> _loadDiff() async {
    setState(() {
      _loading = true;
      _failure = null;
    });
    try {
      final diff = await widget.gateway.diffRecovery(
        widget.runtimeSessionId,
        widget.checkpoint.hash,
      );
      if (!mounted) return;
      setState(() => _diff = diff);
    } catch (error) {
      if (!mounted) return;
      setState(() => _failure = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _restore() async {
    if (widget.readOnly || _restoring) return;
    final approved = await _confirmExactCheckpoint();
    if (approved != true || !mounted || widget.readOnly) return;
    final lock = context.findAncestorStateOfType<HermesAppState>()?.appLock;
    if (lock != null) {
      final verified = await LockScreen.verify(
        context,
        lock,
        reason: Strings.of(context).recoveryCenterRestoreAction,
      );
      if (!verified || !mounted || widget.readOnly) return;
    }
    setState(() {
      _restoring = true;
      _failure = null;
    });
    try {
      final result = await widget.gateway.restoreRecovery(
        widget.runtimeSessionId,
        widget.checkpoint.hash,
      );
      if (!mounted) return;
      if (!result.success) {
        setState(
          () => _failure = const DesktopControlFailure(
            DesktopControlFailureKind.rejected,
          ),
        );
        return;
      }
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() => _failure = error);
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  Future<bool?> _confirmExactCheckpoint() async {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) =>
          _RecoveryConfirmationDialog(checkpointHash: widget.checkpoint.hash),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final diff = _diff;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 12, 10),
          child: Row(
            children: [
              const Icon(Icons.restore_page_outlined),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _safeRemoteText(
                        widget.checkpoint.message.isEmpty
                            ? strings.recoveryCenterDetailFallback
                            : widget.checkpoint.message,
                        strings,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      widget.checkpoint.hash,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.textSecondary,
                        fontFamily: 'monospace',
                        fontSize: 10.5,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: strings.commonClose,
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _loading && diff == null
              ? const Center(child: CircularProgressIndicator())
              : _failure != null && diff == null
              ? _RecoveryFailure(
                  message: _recoveryDetailFailureText(_failure!, strings),
                  onRetry: _loadDiff,
                )
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    if (widget.readOnly)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _RecoveryNotice(
                          icon: Icons.lock_outline_rounded,
                          text: strings.recoveryCenterReadOnlyRestore,
                        ),
                      ),
                    if (diff != null && diff.stat.isNotEmpty) ...[
                      Text(
                        _safeRemoteText(diff.stat, strings),
                        style: TextStyle(
                          color: colors.textSecondary,
                          fontSize: 12.5,
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    HermesPanel(
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: SelectionArea(
                          child: Text(
                            diff == null || diff.diff.isEmpty
                                ? strings.recoveryCenterNoDiff
                                : _safeRemoteText(diff.diff, strings),
                            style: TextStyle(
                              color: colors.textPrimary,
                              fontFamily: 'monospace',
                              fontSize: 11.5,
                              height: 1.45,
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (_failure != null && diff != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          _recoveryDetailFailureText(_failure!, strings),
                          style: TextStyle(color: colors.warning, fontSize: 12),
                        ),
                      ),
                    const SizedBox(height: 16),
                    HermesSecondaryButton(
                      label: _restoring
                          ? strings.recoveryCenterRestoring
                          : strings.recoveryCenterRestoreAction,
                      icon: Icons.settings_backup_restore_rounded,
                      color: colors.error,
                      onTap: widget.readOnly || _restoring ? null : _restore,
                    ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _RecoveryConfirmationDialog extends StatefulWidget {
  final String checkpointHash;

  const _RecoveryConfirmationDialog({required this.checkpointHash});

  @override
  State<_RecoveryConfirmationDialog> createState() =>
      _RecoveryConfirmationDialogState();
}

class _RecoveryConfirmationDialogState
    extends State<_RecoveryConfirmationDialog> {
  late final TextEditingController _controller;
  bool _matches = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    return AlertDialog(
      title: Text(strings.recoveryCenterConfirmTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(strings.recoveryCenterConfirmBody),
            const SizedBox(height: 14),
            SelectableText(
              widget.checkpointHash,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5),
            ),
            const SizedBox(height: 14),
            TextField(
              key: const ValueKey('recovery-confirmation-field'),
              controller: _controller,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: strings.recoveryCenterHashLabel,
                hintText: strings.recoveryCenterHashHint,
              ),
              onChanged: (value) {
                final matches = value == widget.checkpointHash;
                if (_matches != matches) setState(() => _matches = matches);
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(strings.commonCancel),
        ),
        FilledButton(
          onPressed: _matches ? () => Navigator.pop(context, true) : null,
          child: Text(strings.recoveryCenterRestoreNow),
        ),
      ],
    );
  }
}

class _RecoveryNotice extends StatelessWidget {
  final IconData icon;
  final String text;

  const _RecoveryNotice({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return HermesPanel(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(icon, size: 19, color: colors.warning),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: TextStyle(
                  color: colors.textSecondary,
                  fontSize: 12,
                  height: 1.35,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RecoveryMessage extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  final bool compact;

  const _RecoveryMessage({
    required this.icon,
    required this.title,
    required this.body,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Center(
      child: Padding(
        padding: compact
            ? const EdgeInsets.symmetric(vertical: 18)
            : const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 34, color: colors.textDisabled),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: colors.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              body,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: colors.textSecondary,
                fontSize: 12.5,
                height: 1.35,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RecoveryFailure extends StatelessWidget {
  final String message;
  final Future<void> Function() onRetry;

  const _RecoveryFailure({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline_rounded, size: 34),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 14),
          OutlinedButton(
            onPressed: onRetry,
            child: Text(Strings.of(context).commonRetry),
          ),
        ],
      ),
    ),
  );
}

String _shortHash(String hash) =>
    hash.length <= 8 ? hash : hash.substring(0, 8);

String _recoveryFailureText(Object failure, Strings strings) {
  if (failure is DesktopControlFailure) {
    return switch (failure.kind) {
      DesktopControlFailureKind.unsupported =>
        strings.recoveryCenterFailureUnsupported,
      DesktopControlFailureKind.forbidden =>
        strings.recoveryCenterFailureForbidden,
      DesktopControlFailureKind.invalidResponse =>
        strings.recoveryCenterFailureInvalidResponse,
      DesktopControlFailureKind.unavailable =>
        strings.recoveryCenterFailureUnavailable,
      DesktopControlFailureKind.rejected =>
        strings.recoveryCenterFailureRejected,
    };
  }
  return strings.recoveryCenterFailureUnknown;
}

String _recoveryDetailFailureText(Object failure, Strings strings) {
  if (failure is DesktopControlFailure) {
    return switch (failure.kind) {
      DesktopControlFailureKind.unsupported =>
        strings.recoveryCenterDetailFailureUnsupported,
      DesktopControlFailureKind.forbidden =>
        strings.recoveryCenterDetailFailureForbidden,
      DesktopControlFailureKind.invalidResponse =>
        strings.recoveryCenterDetailFailureInvalidResponse,
      DesktopControlFailureKind.unavailable =>
        strings.recoveryCenterDetailFailureUnavailable,
      DesktopControlFailureKind.rejected =>
        strings.recoveryCenterDetailFailureRejected,
    };
  }
  return strings.recoveryCenterDetailFailureUnknown;
}

String _safeRemoteText(String value, Strings strings) {
  var result = value;
  final unixHostPath = RegExp(
    r'(^|[\s(\[])/(?:home|private|users|root|srv|var|etc|opt|mnt|tmp|data|run)(?:/[^\s)\],;]+)+',
    caseSensitive: false,
    multiLine: true,
  );
  result = result.replaceAllMapped(
    unixHostPath,
    (match) =>
        '${match.group(1) ?? ''}${strings.desktopCenterServerPathRedacted}',
  );
  final windowsHostPath = RegExp(
    r'(^|[\s(\[])[a-z]:\\(?:[^\s)\],;]+\\)*[^\s)\],;]+',
    caseSensitive: false,
    multiLine: true,
  );
  result = result.replaceAllMapped(
    windowsHostPath,
    (match) =>
        '${match.group(1) ?? ''}${strings.desktopCenterServerPathRedacted}',
  );
  result = result.replaceAll(
    RegExp(
      r'\b(?:sk|ghp|glpat|xoxb|xoxp|xoxa|xoxr)[-_][a-z0-9_-]{6,}\b',
      caseSensitive: false,
    ),
    strings.desktopCenterSecretRedacted,
  );
  return result;
}
