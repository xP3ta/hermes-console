import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/app_localizations.dart';
import '../../main.dart';
import '../design/content.dart' show HermesToggleRow;
import '../design/modal.dart'
    show HermesDialogAction, HermesDialogActionStyle, showHermesDialog;
import '../design/page.dart' show HermesActionButton;
import '../services/action_follower.dart';
import '../services/app_lock.dart';
import '../services/backup_restore_flow.dart';
import '../services/backup_zip_summary.dart';
import '../services/bot_roster_store.dart';
import '../services/connection_manager.dart';
import '../services/dashboard_backup_gateway.dart';
import '../services/restore_refresh.dart';
import '../services/screen_security.dart';
import '../theme/app_theme.dart';
import '../widgets/hermes_notice.dart';
import '../widgets/hermes_ui.dart' show HermesGroup, HermesNavRow;
import 'lock_screen.dart';

typedef BackupLockVerifier =
    Future<bool> Function(
      BuildContext context,
      AppLockService lock,
      String reason,
    );

enum _Access { idle, appLockRequired, locked, unsupported, unreachable, ready }

/// Settings › Data › Backup and restore. Creating, saving and restoring a
/// server backup, each behind App Lock and an explicit confirmation. The page
/// is blocked from screenshots while it is visible; archives live in memory
/// (a server path) or in a temp file that is deleted right away.
class BackupRestoreScreen extends StatefulWidget {
  const BackupRestoreScreen({
    required this.connection,
    required this.profile,
    this.onOpenSecurity,
    this.gateway,
    this.appLock,
    this.verifyLock,
    this.pickZip,
    this.saveToPhone,
    this.tempDirectory,
    this.refresh,
    this.followerFor,
    super.key,
  });

  final SavedConnection connection;
  final String profile;
  final VoidCallback? onOpenSecurity;

  // Seams for tests; the defaults are the real Dashboard, file picker and
  // share sheet.
  final HermesBackupGateway? gateway;
  final AppLockService? appLock;
  final BackupLockVerifier? verifyLock;
  final Future<File?> Function()? pickZip;
  final Future<void> Function(File file)? saveToPhone;
  final Future<Directory> Function()? tempDirectory;
  final Future<void> Function()? refresh;
  final ActionFollower Function(
    Future<Map<String, dynamic>> Function(String name) read,
  )?
  followerFor;

  @override
  State<BackupRestoreScreen> createState() => _BackupRestoreScreenState();
}

class _BackupRestoreScreenState extends State<BackupRestoreScreen>
    with WidgetsBindingObserver {
  DashboardClient? _dashboard;
  late final HermesBackupGateway _gateway;
  late final BackupRestoreFlow _flow;
  AppLockService? _appLock;
  SecureScopeLease? _secureScope;
  _Access _access = _Access.idle;
  bool _foreground = true;
  bool _disposed = false;
  bool _safetyBackup = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _appLock =
        widget.appLock ??
        context.findAncestorStateOfType<HermesAppState>()?.appLock;
    if (widget.gateway != null) {
      _gateway = widget.gateway!;
    } else {
      final dashboard = DashboardClient.lazy(widget.connection);
      _dashboard = dashboard;
      _gateway = DashboardBackupGateway(dashboard);
    }
    _flow = BackupRestoreFlow(
      gateway: _gateway,
      profile: widget.profile,
      verify: _verify,
      refresh: widget.refresh ?? _defaultRefresh,
      tempDirectory: widget.tempDirectory ?? getTemporaryDirectory,
      saveToPhone: widget.saveToPhone ?? _defaultShare,
      isVisible: _isVisible,
      followerFor: widget.followerFor,
    )..addListener(_onFlow);
    _appLock?.locked.addListener(_onAppLocked);
    // Nothing is verified, probed or shown until FLAG_SECURE is applied.
    final secured = _enterSecureScope();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await secured;
      } catch (_) {
        return;
      }
      if (!_disposed) unawaited(_open());
    });
  }

  bool _isVisible() {
    if (_disposed || !mounted || !_foreground) return false;
    return ModalRoute.of(context)?.isCurrent ?? true;
  }

  Future<void> _enterSecureScope() async {
    final prefs = await SharedPreferences.getInstance();
    final lease = await ScreenSecurityService(prefs).pushSecureScope();
    if (_disposed) {
      await lease.release();
      return;
    }
    _secureScope = lease;
  }

  Future<bool> _verify(String _) async {
    final lock = _appLock;
    if (!mounted || lock == null) return false;
    final reason = Strings.of(context).backupVerifyReason;
    final verify = widget.verifyLock ?? _defaultVerify;
    return verify(context, lock, reason);
  }

  static Future<bool> _defaultVerify(
    BuildContext context,
    AppLockService lock,
    String reason,
  ) => LockScreen.verify(context, lock, reason: reason);

  Future<void> _defaultRefresh() => refreshAfterRestore(
    connection: widget.connection,
    readProfiles: () async {
      final client = DashboardClient.lazy(widget.connection);
      try {
        return await client.getProfiles();
      } finally {
        client.close();
      }
    },
    roster: BotRosterRegistry.shared,
  );

  static Future<void> _defaultShare(File file) async {
    await Share.shareXFiles([XFile(file.path, mimeType: 'application/zip')]);
  }

  Future<void> _open() async {
    if (_disposed) return;
    if (widget.connection.readOnly) {
      setState(() => _access = _Access.unsupported);
      return;
    }
    if (!(_appLock?.enabled ?? false)) {
      setState(() => _access = _Access.appLockRequired);
      return;
    }
    await _unlock();
  }

  Future<void> _unlock() async {
    if (!(_appLock?.enabled ?? false)) {
      setState(() => _access = _Access.appLockRequired);
      return;
    }
    final epoch = _lockEpoch;
    final ok = await _verify('open');
    if (_disposed) return;
    if (_relocked(epoch)) {
      setState(() => _access = _Access.locked);
      return;
    }
    if (!ok) {
      setState(() => _access = _Access.locked);
      return;
    }
    final bool available;
    try {
      available = await _gateway.available();
    } catch (_) {
      if (_disposed) return;
      // A re-lock while the probe was pending already put the page in the
      // locked state; never replace it with a retry prompt.
      setState(
        () => _access = _relocked(epoch) ? _Access.locked : _Access.unreachable,
      );
      return;
    }
    if (_disposed) return;
    if (_relocked(epoch)) {
      setState(() => _access = _Access.locked);
      return;
    }
    setState(() => _access = available ? _Access.ready : _Access.unsupported);
  }

  /// Bumped every time App Lock re-locks; an answer that was pending across
  /// one is stale and must not open the page.
  int _lockEpoch = 0;

  bool _relocked(int epoch) => epoch != _lockEpoch;

  void _onAppLocked() {
    if (_disposed || _appLock?.locked.value != true) return;
    _lockEpoch++;
    _flow.cancel();
    setState(() => _access = _Access.locked);
  }

  void _onFlow() {
    if (_disposed) return;
    if (_flow.failure?.kind == BackupFailureKind.unsupported) {
      _access = _Access.unsupported;
    }
    setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _appLock?.locked.removeListener(_onAppLocked);
    final idle = _flow.idle;
    _flow
      ..removeListener(_onFlow)
      ..dispose();
    // An import that already started is followed to its end first.
    final dashboard = _dashboard;
    if (dashboard != null) unawaited(idle.whenComplete(dashboard.close));
    final scope = _secureScope;
    if (scope != null) unawaited(scope.release());
    super.dispose();
  }

  // ── actions ────────────────────────────────────────────────────────────

  Future<void> _create() async {
    final s = Strings.of(context);
    final confirmed = await showHermesDialog<bool>(
      context: context,
      title: s.backupCreateWarnTitle,
      message: s.backupCreateWarn,
      actions: [
        HermesDialogAction(
          label: s.backupCancel,
          value: false,
          style: HermesDialogActionStyle.cancel,
        ),
        HermesDialogAction(
          key: const ValueKey('backup-create-confirm'),
          label: s.backupCreate,
          value: true,
        ),
      ],
    );
    if (confirmed != true || !mounted) return;
    await _flow.createBackup(confirmed: true);
  }

  Future<void> _save({bool safety = false}) async {
    await _flow.downloadToPhone(safety: safety);
    if (!mounted || _flow.failure == null) return;
    HermesNotice.of(context).showSnackBar(
      SnackBar(content: Text(Strings.of(context).backupSaveFailed)),
      kind: HermesNoticeKind.warning,
    );
  }

  Future<File?> _pick() async {
    final custom = widget.pickZip;
    if (custom != null) return custom();
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['zip'],
    );
    final path = result?.files.single.path;
    return path == null ? null : File(path);
  }

  Future<void> _pickAndInspect() async {
    final file = await _pick();
    if (file == null || !mounted) return;
    _safetyBackup = true;
    await _flow.inspect(file, deleteSourceWhenDone: true);
  }

  // ── build ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(s.backupTitle)),
      body: SafeArea(
        child: switch (_access) {
          _Access.idle => const SizedBox.shrink(),
          _Access.appLockRequired => _notice(
            s.backupLockNotice,
            action: widget.onOpenSecurity == null
                ? null
                : HermesNoticeAction(
                    label: s.termLockAction,
                    onPressed: widget.onOpenSecurity!,
                    closesNotice: false,
                  ),
          ),
          _Access.locked => _locked(s),
          _Access.unsupported => _notice(s.backupUnsupported),
          _Access.unreachable => _unreachable(s),
          _Access.ready => _ready(s),
        },
      ),
    );
  }

  Widget _notice(
    String message, {
    HermesNoticeAction? action,
    HermesNoticeKind kind = HermesNoticeKind.info,
    Key? key,
  }) => HermesNoticeCard(
    noticeKey: key ?? ValueKey('backup-notice-${message.hashCode}'),
    kind: kind,
    message: message,
    action: action,
    onDismissed: () {},
  );

  Widget _locked(Strings s) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(s.backupLocked),
        const SizedBox(height: 16),
        HermesActionButton(
          key: const ValueKey('backup-unlock'),
          label: s.backupUnlock,
          primary: true,
          onPressed: () => unawaited(_unlock()),
        ),
      ],
    ),
  );

  Widget _unreachable(Strings s) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(s.backupUnreachable),
        const SizedBox(height: 16),
        HermesActionButton(
          key: const ValueKey('backup-retry'),
          label: s.backupRetry,
          primary: true,
          onPressed: () => unawaited(_open()),
        ),
      ],
    ),
  );

  bool get _working => const {
    BackupFlowStep.backupRunning,
    BackupFlowStep.safetyBackup,
    BackupFlowStep.upload,
    BackupFlowStep.importing,
    BackupFlowStep.status,
    BackupFlowStep.refresh,
  }.contains(_flow.step);

  Widget _ready(Strings s) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_working)
          ..._progress(s)
        else if (_flow.step == BackupFlowStep.confirm)
          ..._confirm(s)
        else
          ..._idle(s),
      ],
    );
  }

  List<Widget> _progress(Strings s) => [
    const LinearProgressIndicator(),
    const SizedBox(height: 12),
    Text(s.backupWorking),
    if (_flow.lines.isNotEmpty) ...[
      const SizedBox(height: 12),
      SelectableText(
        _flow.lines.take(12).join('\n'),
        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
      ),
    ],
  ];

  List<Widget> _idle(Strings s) {
    final hasArchive = _flow.archive != null;
    return [
      if (_flow.step == BackupFlowStep.done) ...[
        _notice(
          s.backupRestoreDone,
          kind: HermesNoticeKind.success,
          key: const ValueKey('backup-restore-done'),
        ),
        if (_flow.failure?.kind == BackupFailureKind.refreshFailed) ...[
          const SizedBox(height: 8),
          _notice(s.backupRefreshFailed, kind: HermesNoticeKind.warning),
        ],
        const SizedBox(height: 16),
      ],
      if (_flow.step == BackupFlowStep.failed) ..._failure(s),
      if (hasArchive) ...[
        _notice(s.backupDone, kind: HermesNoticeKind.success),
        const SizedBox(height: 12),
        HermesActionButton(
          key: const ValueKey('backup-save'),
          label: s.backupSave,
          primary: true,
          onPressed: _flow.busy ? null : () => unawaited(_save()),
        ),
        const SizedBox(height: 12),
      ],
      HermesActionButton(
        key: const ValueKey('backup-create'),
        label: s.backupCreate,
        primary: !hasArchive,
        onPressed: _flow.busy ? null : () => unawaited(_create()),
      ),
      const SizedBox(height: 16),
      HermesGroup(
        children: [
          HermesNavRow(
            key: const ValueKey('backup-restore-pick'),
            icon: Icons.settings_backup_restore_rounded,
            title: s.backupRestorePick,
            onTap: () {
              if (!_flow.busy) unawaited(_pickAndInspect());
            },
          ),
        ],
      ),
    ];
  }

  List<Widget> _failure(Strings s) {
    final failure = _flow.failure;
    if (failure == null) return const [];
    final message = switch (failure.kind) {
      BackupFailureKind.lockDenied => null,
      BackupFailureKind.unsupported => s.backupUnsupported,
      BackupFailureKind.badArchive => switch (failure.zipProblem) {
        BackupZipProblem.tooLarge => s.backupFailTooLarge,
        BackupZipProblem.unsafePath => s.backupFailUnsafe,
        _ => s.backupFailBadZip,
      },
      BackupFailureKind.backupFailed => s.backupFailBackup,
      BackupFailureKind.safetyBackupFailed => s.backupFailSafety,
      BackupFailureKind.importFailed => s.backupFailImport,
      BackupFailureKind.timedOut => s.backupFailTimedOut,
      BackupFailureKind.cancelled => s.backupFailCancelled,
      BackupFailureKind.refreshFailed => s.backupRefreshFailed,
      BackupFailureKind.network => s.backupFailGeneric,
    };
    if (message == null) return const [];
    return [
      _notice(message, kind: HermesNoticeKind.warning),
      if (failure.kind == BackupFailureKind.importFailed ||
          failure.kind == BackupFailureKind.backupFailed) ...[
        if (_flow.lines.isNotEmpty) ...[
          const SizedBox(height: 8),
          SelectableText(
            _flow.lines.join('\n'),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ],
      ],
      if (failure.kind == BackupFailureKind.importFailed &&
          _flow.safetyArchive != null) ...[
        const SizedBox(height: 8),
        Text(s.backupRecoveryHint),
        const SizedBox(height: 8),
        HermesActionButton(
          key: const ValueKey('backup-save-safety'),
          label: s.backupSave,
          onPressed: _flow.busy ? null : () => unawaited(_save(safety: true)),
        ),
      ],
      const SizedBox(height: 16),
    ];
  }

  String _size(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit += 1;
    }
    return '${value.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
  }

  String _itemLabel(Strings s, BackupItem item, BackupZipSummary summary) =>
      switch (item) {
        BackupItem.config => s.backupItemConfig,
        BackupItem.env => s.backupItemEnv,
        BackupItem.auth => s.backupItemAuth,
        BackupItem.sessions => s.backupItemSessions,
        BackupItem.memories => s.backupItemMemories,
        BackupItem.skills => s.backupItemSkills,
        BackupItem.cron => s.backupItemCron,
        BackupItem.profiles =>
          summary.profileNames.isEmpty
              ? s.backupItemProfiles
              : '${s.backupItemProfiles}: ${summary.profileNames.join(', ')}',
      };

  List<Widget> _confirm(Strings s) {
    final summary = _flow.summary;
    if (summary == null) return const [];
    final colors = Theme.of(context).hermes;
    return [
      Text(
        s.backupRestoreTitle,
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 4),
      Text(
        s.backupRestoreCounts(summary.fileCount, _size(summary.totalBytes)),
        style: TextStyle(color: colors.textSecondary),
      ),
      const SizedBox(height: 16),
      Text(
        s.backupReplacesTitle,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 4),
      for (final item in summary.replaces) Text(_itemLabel(s, item, summary)),
      if (summary.otherFiles > 0) Text(s.backupOtherFiles(summary.otherFiles)),
      if (summary.keptRuntimeFiles.isNotEmpty) ...[
        const SizedBox(height: 12),
        Text(
          s.backupKeptTitle,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        for (final name in summary.keptRuntimeFiles) Text(name),
      ],
      const SizedBox(height: 16),
      _notice(
        s.backupRestoreWarn(summary.profile),
        kind: HermesNoticeKind.warning,
        key: const ValueKey('backup-restore-warning'),
      ),
      const SizedBox(height: 8),
      HermesGroup(
        children: [
          HermesToggleRow(
            title: s.backupSafetyFirst,
            value: _safetyBackup,
            switchKey: const ValueKey('backup-safety-switch'),
            onChanged: (v) => setState(() => _safetyBackup = v),
          ),
        ],
      ),
      const SizedBox(height: 16),
      FilledButton(
        key: const ValueKey('backup-restore-confirm'),
        style: FilledButton.styleFrom(
          backgroundColor: colors.error,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(48),
        ),
        onPressed: () => unawaited(
          _flow.restore(confirmed: true, safetyBackup: _safetyBackup),
        ),
        child: Text(s.backupRestoreAction),
      ),
      const SizedBox(height: 8),
      TextButton(
        key: const ValueKey('backup-restore-cancel'),
        onPressed: _flow.cancel,
        child: Text(s.backupCancel),
      ),
    ];
  }
}
