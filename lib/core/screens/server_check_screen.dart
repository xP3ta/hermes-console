import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../services/action_follower.dart';
import '../services/connection_manager.dart';
import '../theme/app_theme.dart';
import '../widgets/hermes_app_bar.dart';
import '../design/page.dart' show HermesActionButton;
import '../design/tokens.dart';

/// The two maintenance actions Desktop runs from its Maintenance panel
/// (`app/command-center/maintenance.tsx`): `hermes doctor` and
/// `hermes security audit`, started with `POST /api/ops/doctor` and
/// `/api/ops/security-audit` (`api/system.ts` `runDoctor`,
/// `runSecurityAudit`).
enum ServerCheck {
  doctor('ops/doctor', 'doctor'),
  securityAudit('ops/security-audit', 'security-audit');

  const ServerCheck(this.route, this.actionName);

  final String route;

  /// The name of the action the route spawns, for `/api/actions/<name>/status`
  /// when the answer does not name it.
  final String actionName;

  String title(Strings s) => switch (this) {
    ServerCheck.doctor => s.srvCheckDoctor,
    ServerCheck.securityAudit => s.srvCheckAudit,
  };

  String subtitle(Strings s) => switch (this) {
    ServerCheck.doctor => s.srvCheckDoctorSub,
    ServerCheck.securityAudit => s.srvCheckAuditSub,
  };
}

/// Starts one [ServerCheck] on the server and shows its log as the action
/// writes it, like Desktop: the lines of the action's status, in a
/// monospace block, with "Running…" beside the heading while it goes on.
/// Nothing is requested until the user presses Run; the log is followed at
/// the 1.2 s / 240-read pace of Desktop's `ACTION_POLL_MS` and
/// `ACTION_POLL_LIMIT` and only while this page is open.
class ServerCheckScreen extends StatefulWidget {
  const ServerCheckScreen({
    required this.check,
    required this.connection,
    required this.profile,
    this.client,
    this.followerFor,
    super.key,
  });

  final ServerCheck check;
  final SavedConnection connection;
  final String profile;

  // Seams for tests; the defaults are the real Dashboard and the 1.2 s pace.
  final DashboardClient? client;
  final ActionFollower Function(
    Future<Map<String, dynamic>> Function(String name) read,
  )?
  followerFor;

  @override
  State<ServerCheckScreen> createState() => _ServerCheckScreenState();
}

enum _Notice { none, unavailable, startFailed, lost }

class _ServerCheckScreenState extends State<ServerCheckScreen> {
  late final DashboardClient _client;
  late final bool _ownsClient;
  bool _running = false;
  bool _ran = false;
  _Notice _notice = _Notice.none;
  ActionOutcome? _outcome;
  List<String> _lines = const [];

  @override
  void initState() {
    super.initState();
    final injected = widget.client;
    _ownsClient = injected == null;
    _client = injected ?? DashboardClient.lazy(widget.connection);
  }

  @override
  void dispose() {
    if (_ownsClient) _client.close();
    super.dispose();
  }

  Future<void> _run() async {
    if (_running) return;
    setState(() {
      _running = true;
      _ran = true;
      _notice = _Notice.none;
      _outcome = null;
      _lines = const [];
    });
    String name = widget.check.actionName;
    try {
      final started = await _client.apiPost(
        '${widget.check.route}'
        '?profile=${Uri.encodeQueryComponent(widget.profile)}',
        body: const {},
      );
      final named = started['name'];
      if (named is String && named.isNotEmpty) name = named;
    } on DashboardHttpException catch (error) {
      _stop(
        error.statusCode == 404 || error.statusCode == 405
            ? _Notice.unavailable
            : _Notice.startFailed,
      );
      return;
    } catch (_) {
      _stop(_Notice.startFailed);
      return;
    }
    if (!mounted) return;
    final follower =
        widget.followerFor?.call(_client.getActionStatus) ??
        ActionFollower(read: _client.getActionStatus, maxReads: 240);
    try {
      final outcome = await follower.follow(
        name,
        keepGoing: () => mounted,
        onLines: (lines) {
          if (mounted) setState(() => _lines = lines);
        },
      );
      if (!mounted) return;
      setState(() {
        _running = false;
        _outcome = outcome;
      });
    } catch (_) {
      // Desktop stops tailing when the status read fails.
      _stop(_Notice.lost);
    }
  }

  void _stop(_Notice notice) {
    if (!mounted) return;
    setState(() {
      _running = false;
      _notice = notice;
    });
  }

  String? _verdict(Strings s) {
    final outcome = _outcome;
    if (outcome == null) return null;
    return switch (outcome.state) {
      ActionFollowState.timedOut => s.srvCheckStillRunning,
      ActionFollowState.cancelled => null,
      ActionFollowState.finished =>
        outcome.succeeded
            ? s.srvCheckFinished
            : s.srvCheckFinishedCode(outcome.exitCode?.toString() ?? '?'),
    };
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final theme = Theme.of(context);
    final notice = switch (_notice) {
      _Notice.none => null,
      _Notice.unavailable => s.srvCheckUnavailable,
      _Notice.startFailed => s.srvCheckStartFailed,
      _Notice.lost => s.srvCheckLost,
    };
    final verdict = _verdict(s);
    return Scaffold(
      appBar: HermesAppBar(title: Text(widget.check.title(s))),
      body: ListView(
        clipBehavior: hermesUnderHeader,
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            widget.check.subtitle(s),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: 16),
          HermesActionButton(
            key: const ValueKey('server-check-run'),
            label: _running ? s.srvCheckRunning : s.srvCheckRun,
            primary: true,
            onPressed: _running ? null : () => unawaited(_run()),
          ),
          if (notice != null) ...[
            const SizedBox(height: 12),
            Text(
              notice,
              key: const ValueKey('server-check-notice'),
              style: theme.textTheme.bodyMedium?.copyWith(color: colors.error),
            ),
          ],
          if (_ran && notice == null) ...[
            const SizedBox(height: 16),
            // A wrap: at a large text size the verdict goes to its own line.
            Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  s.srvCheckLog,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
                if (_running)
                  Text(
                    s.srvCheckRunning,
                    key: const ValueKey('server-check-running'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.textSecondary,
                    ),
                  )
                else if (verdict != null)
                  Text(
                    verdict,
                    key: const ValueKey('server-check-verdict'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              key: const ValueKey('server-check-log'),
              constraints: const BoxConstraints(maxHeight: 420),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colors.surface,
                borderRadius: BorderRadius.circular(HermesRadius.control),
                border: Border.all(color: colors.divider),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  _lines.join('\n'),
                  style: TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 11.5,
                    height: 1.35,
                    color: colors.textSecondary,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
