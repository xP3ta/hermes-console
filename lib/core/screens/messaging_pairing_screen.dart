import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../main.dart';
import '../design/hermes_design.dart'
    show HermesDialogAction, HermesDialogActionStyle, showHermesDialog;
import '../services/connection_manager.dart';
import '../services/messaging_pairing.dart';
import '../theme/app_theme.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/hermes_pill.dart';
import '../widgets/hermes_ui.dart' show HermesGroup, HermesSectionHeader;
import 'lock_screen.dart';

/// Settings › Security › Messaging access: who may message the bot. Someone
/// who writes to it for the first time waits in the pending list until an
/// admin approves them; an approved user can be revoked. Desktop shows the
/// same lists under each platform (`app/messaging/index.tsx`, the pending
/// and approved sections and their confirm dialog); here they are one page,
/// grouped by platform. Platform setup and QR onboarding are not part of it.
class MessagingPairingScreen extends StatefulWidget {
  const MessagingPairingScreen({
    required this.connection,
    required this.profile,
    this.client,
    this.verifyLock,
    super.key,
  });

  final SavedConnection connection;

  /// The profile whose store is read and written (`default` included).
  final String profile;

  // Seams for tests; the defaults are the real Dashboard and App Lock.
  final MessagingPairingClient? client;
  final Future<bool> Function(String reason)? verifyLock;

  @override
  State<MessagingPairingScreen> createState() => _MessagingPairingScreenState();
}

class _MessagingPairingScreenState extends State<MessagingPairingScreen> {
  DashboardClient? _dashboard;
  late final MessagingPairingClient _client;
  PairingSnapshot? _snapshot;
  bool _missing = false;
  bool _failed = false;
  String? _busy;
  String? _status;
  bool _statusIsError = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    final injected = widget.client;
    if (injected != null) {
      _client = injected;
    } else {
      final dashboard = DashboardClient.lazy(widget.connection);
      _dashboard = dashboard;
      _client = MessagingPairingClient(dashboard);
    }
    unawaited(_load());
  }

  @override
  void dispose() {
    _dashboard?.close();
    super.dispose();
  }

  static String _key(PairingEntry entry) =>
      '${entry.platform}:${entry.userId}';

  Future<void> _load() async {
    final generation = ++_generation;
    try {
      final snapshot = await _client.load(widget.profile);
      if (!mounted || generation != _generation) return;
      setState(() {
        _snapshot = snapshot;
        _missing = false;
        _failed = false;
      });
    } on PairingRouteMissing {
      if (!mounted || generation != _generation) return;
      setState(() {
        _missing = true;
        _failed = false;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() => _failed = _snapshot == null);
      if (_snapshot != null) {
        _say(Strings.of(context).msgPairLoadFailed, error: true);
      }
    }
  }

  void _say(String message, {bool error = false}) {
    setState(() {
      _status = message;
      _statusIsError = error;
    });
  }

  Future<bool> _verify(String reason) async {
    final custom = widget.verifyLock;
    if (custom != null) return custom(reason);
    final lock = context.findAncestorStateOfType<HermesAppState>()?.appLock;
    if (lock == null || !lock.enabled) return true;
    return LockScreen.verify(context, lock, reason: reason);
  }

  Future<void> _approve(PairingEntry entry) async {
    if (!entry.canApprove || _busy != null) return;
    final s = Strings.of(context);
    if (!await _verify(s.msgPairVerifyApprove) || !mounted) return;
    setState(() {
      _busy = _key(entry);
      _status = null;
    });
    try {
      await _client.approve(entry, widget.profile);
      if (!mounted) return;
      _say(s.msgPairApprovedDone(entry.label));
    } on PairingLockedOut {
      if (!mounted) return;
      _say(s.msgPairLockedOut, error: true);
    } catch (_) {
      if (!mounted) return;
      _say(s.msgPairApproveFailed(entry.label), error: true);
    }
    if (!mounted) return;
    setState(() => _busy = null);
    await _load();
  }

  Future<void> _revoke(PairingEntry entry) async {
    if (_busy != null) return;
    final s = Strings.of(context);
    final confirmed = await showHermesDialog<bool>(
      context: context,
      title: s.msgPairRevokeTitle,
      message: s.msgPairRevokeBody(entry.label),
      actions: [
        HermesDialogAction(
          label: s.commonCancel,
          value: false,
          style: HermesDialogActionStyle.cancel,
        ),
        HermesDialogAction(
          label: s.msgPairRevoke,
          value: true,
          style: HermesDialogActionStyle.destructive,
        ),
      ],
    );
    if (confirmed != true || !mounted) return;
    if (!await _verify(s.msgPairVerifyRevoke) || !mounted) return;
    setState(() {
      _busy = _key(entry);
      _status = null;
    });
    try {
      await _client.revoke(entry, widget.profile);
      if (!mounted) return;
      _say(s.msgPairRevokedDone(entry.label));
    } catch (_) {
      if (!mounted) return;
      _say(s.msgPairRevokeFailed(entry.label), error: true);
    }
    if (!mounted) return;
    setState(() => _busy = null);
    await _load();
  }

  /// Desktop `waitingSince`.
  String _waited(Strings s, int minutes) =>
      minutes < 1 ? s.msgPairJustNow : s.msgPairMinutesAgo(minutes);

  static String _platformName(String id) =>
      id.isEmpty ? id : id[0].toUpperCase() + id.substring(1);

  /// The rows of [entries] under a heading per platform, in the order the
  /// server listed them.
  List<Widget> _groups(
    List<PairingEntry> entries,
    Widget Function(PairingEntry entry) row,
  ) {
    final platforms = <String>[];
    for (final entry in entries) {
      if (!platforms.contains(entry.platform)) platforms.add(entry.platform);
    }
    final colors = Theme.of(context).hermes;
    return [
      for (final platform in platforms) ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 6),
          child: Text(
            _platformName(platform),
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: colors.textSecondary,
            ),
          ),
        ),
        HermesGroup(
          children: [
            for (final entry in entries)
              if (entry.platform == platform) row(entry),
          ],
        ),
        const SizedBox(height: 8),
      ],
    ];
  }

  Widget _pendingRow(PairingEntry entry) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final busy = _busy == _key(entry);
    final detail = [
      if (entry.userName.isNotEmpty) entry.userId,
      if (entry.ageMinutes != null) _waited(s, entry.ageMinutes!),
    ].join(' · ');
    return _PairingRow(
      key: ValueKey('pairing-pending-${_key(entry)}'),
      title: entry.label,
      detail: detail,
      action: TextButton(
        key: ValueKey('pairing-approve-${_key(entry)}'),
        onPressed: busy || _busy != null || !entry.canApprove
            ? null
            : () => unawaited(_approve(entry)),
        child: busy
            ? const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Text(s.msgPairApprove),
      ),
      colors: colors,
    );
  }

  Widget _approvedRow(PairingEntry entry) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return _PairingRow(
      key: ValueKey('pairing-approved-${_key(entry)}'),
      title: entry.label,
      detail: entry.userName.isNotEmpty ? entry.userId : '',
      action: TextButton(
        key: ValueKey('pairing-revoke-${_key(entry)}'),
        onPressed: _busy != null ? null : () => unawaited(_revoke(entry)),
        style: TextButton.styleFrom(foregroundColor: colors.error),
        child: Text(s.msgPairRevoke),
      ),
      colors: colors,
    );
  }

  Widget _body(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final snapshot = _snapshot;
    if (_missing) {
      return _Message(
        key: const ValueKey('pairing-unavailable'),
        text: s.msgPairUnavailable,
      );
    }
    if (snapshot == null) {
      if (_failed) {
        return _Message(
          key: const ValueKey('pairing-failed'),
          text: s.msgPairLoadFailed,
          action: TextButton(
            onPressed: () => unawaited(_load()),
            child: Text(s.commonRetry),
          ),
        );
      }
      return Center(child: TuiLoader());
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        clipBehavior: hermesUnderHeader,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            s.msgPairIntro,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: colors.textSecondary),
          ),
          if (_status != null) ...[
            const SizedBox(height: 12),
            Text(
              _status!,
              key: const ValueKey('pairing-status'),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: _statusIsError ? colors.error : colors.textPrimary,
              ),
            ),
          ],
          if (snapshot.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 24),
              child: Text(
                s.msgPairEmpty,
                key: const ValueKey('pairing-empty'),
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: colors.textSecondary),
              ),
            ),
          if (snapshot.pending.isNotEmpty) ...[
            HermesSectionHeader(s.msgPairPending(snapshot.pending.length)),
            ..._groups(snapshot.pending, _pendingRow),
          ],
          if (snapshot.approved.isNotEmpty) ...[
            HermesSectionHeader(s.msgPairApproved(snapshot.approved.length)),
            ..._groups(snapshot.approved, _approvedRow),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: HermesAppBar(title: Text(Strings.of(context).msgPairTitle)),
    body: _body(context),
  );
}

class _PairingRow extends StatelessWidget {
  const _PairingRow({
    required this.title,
    required this.detail,
    required this.action,
    required this.colors,
    super.key,
  });

  final String title;
  final String detail;
  final Widget action;
  final HermesThemeColors colors;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: colors.textPrimary,
                ),
              ),
              if (detail.isNotEmpty)
                Text(
                  detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        action,
      ],
    ),
  );
}

class _Message extends StatelessWidget {
  const _Message({required this.text, this.action, super.key});

  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(text, textAlign: TextAlign.center),
          if (action != null) ...[const SizedBox(height: 12), action!],
        ],
      ),
    ),
  );
}
