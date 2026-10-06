// MEMORY.md / USER.md entries edited on the server through the dashboard
// (see memory_entries_repository.dart). Replaces the Mobile Bridge editor:
// works for every profile and needs no bridge.
//
// Guarantees:
// - nothing is read while the app is locked (and an open entry is hidden
//   when the app relocks);
// - every save/delete re-reads the entry first and refuses when it changed
//   since it was opened, so an edit made in Desktop or by the agent is never
//   silently overwritten;
// - writes pass the approval policy (read-only blocks, ask confirms + App
//   Lock) and the size limits (client cap here, the memory tool's own
//   character limit on the server).
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../main.dart';
import '../design/hermes_design.dart' as d show HermesListRow;
import '../design/hermes_design.dart'
    show
        HermesDialogAction,
        HermesDialogActionStyle,
        HermesInlineNotice,
        HermesListGroup,
        HermesStatusTone,
        showHermesDialog;
import '../services/command_risk.dart';
import '../services/memory_entries_repository.dart';
import '../theme/app_theme.dart';
import '../widgets/action_approval.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/hermes_notice.dart';
import '../widgets/read_only.dart';
import 'lock_screen.dart';

/// App-lock state for these screens: the app's own lock unless a test
/// passes one. Null means there is no lock (unlocked).
ValueListenable<bool>? _appLockedOf(
  BuildContext context,
  ValueListenable<bool>? override,
) =>
    override ??
    context.findAncestorStateOfType<HermesAppState>()?.appLock.locked;

String _fileLabel(MemoryFileKind file) =>
    file == MemoryFileKind.memory ? 'MEMORY.md' : 'USER.md';

/// Mixin: tracks the app lock and calls [onUnlocked] on every unlock edge.
mixin _LockAware<T extends StatefulWidget> on State<T> {
  ValueListenable<bool>? _lock;
  bool get locked => _lock?.value ?? false;

  ValueListenable<bool>? get lockOverride;
  void onUnlocked();

  bool _lockBound = false;
  bool _wasLocked = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_lockBound) return;
    _lockBound = true;
    _lock = _appLockedOf(context, lockOverride);
    _lock?.addListener(_onLockChanged);
    _wasLocked = locked;
    if (!locked) onUnlocked();
  }

  void _onLockChanged() {
    if (!mounted) return;
    final now = locked;
    setState(() {});
    if (_wasLocked && !now) onUnlocked();
    _wasLocked = now;
  }

  @override
  void dispose() {
    _lock?.removeListener(_onLockChanged);
    super.dispose();
  }
}

class MemoryEntriesScreen extends StatefulWidget {
  final MemoryEntriesRepository repository;
  final MemoryFileKind file;
  final String instanceId;
  final bool readOnly;
  final ValueListenable<bool>? appLockedForTesting;

  const MemoryEntriesScreen({
    super.key,
    required this.repository,
    required this.file,
    required this.instanceId,
    this.readOnly = false,
    this.appLockedForTesting,
  });

  @override
  State<MemoryEntriesScreen> createState() => _MemoryEntriesScreenState();
}

class _MemoryEntriesScreenState extends State<MemoryEntriesScreen>
    with _LockAware<MemoryEntriesScreen> {
  List<MemoryEntry>? _entries;
  MemoryEntryFailureKind? _failure;
  bool _loading = false;
  int _generation = 0;

  @override
  ValueListenable<bool>? get lockOverride => widget.appLockedForTesting;

  @override
  void onUnlocked() => _load();

  Future<void> _load() async {
    if (locked) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _failure = null;
    });
    try {
      final entries = await widget.repository.list(widget.file);
      if (!mounted || generation != _generation) return;
      setState(() {
        _entries = entries;
        _loading = false;
      });
    } on MemoryEntryFailure catch (failure) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _failure = failure.kind;
        _loading = false;
      });
    }
  }

  Future<void> _open(MemoryEntry entry) async {
    if (locked) return;
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => MemoryEntryEditorScreen(
          repository: widget.repository,
          file: widget.file,
          entry: entry,
          instanceId: widget.instanceId,
          readOnly: widget.readOnly,
          appLockedForTesting: widget.appLockedForTesting,
        ),
      ),
    );
    // Saved, deleted or found stale: the ids changed, list again.
    if (mounted && changed == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final Widget body;
    if (locked) {
      body = _Message(s.memEntriesLocked, icon: Icons.lock_outline_rounded);
    } else if (_failure != null && _entries == null) {
      body = _Message(
        _failure == MemoryEntryFailureKind.unsupported
            ? s.memEntriesUnsupported
            : s.memEntriesLoadFailed,
        icon: Icons.cloud_off_outlined,
        actionLabel: s.commonRetry,
        onAction: _load,
      );
    } else if (_entries == null) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_entries!.isEmpty) {
      body = _Message(s.memEntriesEmpty, icon: Icons.notes_rounded);
    } else {
      final entries = _entries!;
      body = RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            HermesListGroup(
              children: [
                for (var i = 0; i < entries.length; i++)
                  d.HermesListRow(
                    key: ValueKey('memory-entry-$i'),
                    title: entries[i].label.isEmpty ? '…' : entries[i].label,
                    subtitleMaxLines: 2,
                    onTap: () => _open(entries[i]),
                  ),
              ],
            ),
          ],
        ),
      );
    }
    return Scaffold(
      appBar: HermesAppBar(
        title: Text(_fileLabel(widget.file)),
        actions: [
          IconButton(
            tooltip: s.commonRefresh,
            icon: _loading
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: colors.textSecondary,
                    ),
                  )
                : const Icon(Icons.refresh),
            onPressed: _loading || locked ? null : _load,
          ),
        ],
      ),
      body: body,
    );
  }
}

class MemoryEntryEditorScreen extends StatefulWidget {
  final MemoryEntriesRepository repository;
  final MemoryFileKind file;
  final MemoryEntry entry;
  final String instanceId;
  final bool readOnly;
  final ValueListenable<bool>? appLockedForTesting;

  const MemoryEntryEditorScreen({
    super.key,
    required this.repository,
    required this.file,
    required this.entry,
    required this.instanceId,
    this.readOnly = false,
    this.appLockedForTesting,
  });

  @override
  State<MemoryEntryEditorScreen> createState() =>
      _MemoryEntryEditorScreenState();
}

class _MemoryEntryEditorScreenState extends State<MemoryEntryEditorScreen>
    with _LockAware<MemoryEntryEditorScreen> {
  final _controller = TextEditingController();

  /// The entry exactly as loaded: the base every write is checked against.
  LoadedMemoryEntry? _loaded;
  MemoryEntryFailureKind? _loadFailure;
  String? _error;
  bool _busy = false;

  @override
  ValueListenable<bool>? get lockOverride => widget.appLockedForTesting;

  @override
  void onUnlocked() {
    // Read once; after a relock the text the user typed stays in place.
    if (_loaded == null) _load();
  }

  Future<void> _load() async {
    if (locked) return;
    setState(() => _loadFailure = null);
    try {
      final loaded = await widget.repository.read(widget.entry.id);
      if (!mounted) return;
      setState(() {
        _loaded = loaded;
        _controller.text = loaded.content;
      });
    } on MemoryEntryFailure catch (failure) {
      if (!mounted) return;
      setState(() => _loadFailure = failure.kind);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Approval policy + App Lock before a write. False = do not write.
  Future<bool> _approve({required bool delete}) async {
    final s = Strings.of(context);
    final gate = approvalGate(
      context,
      instanceId: widget.instanceId,
      readOnlyInstance: widget.readOnly,
      risk: CommandRisk.medium,
      patternKey: 'memory_write',
    );
    if (gate == ActionGate.blocked) {
      showReadOnlyNotice(context);
      return false;
    }
    if (gate == ActionGate.proceed) return true;
    FocusManager.instance.primaryFocus?.unfocus();
    final ok = await showHermesDialog<bool>(
      context: context,
      title: delete ? s.memEntryDeleteTitle : s.memEntrySaveTitle,
      message: delete
          ? s.memEntryDeleteBody
          : s.memEntrySaveBody(
              _fileLabel(widget.file),
              widget.repository.profile,
            ),
      actions: [
        HermesDialogAction(
          label: s.commonCancel,
          value: false,
          style: HermesDialogActionStyle.cancel,
        ),
        HermesDialogAction(
          key: const ValueKey('memory-entry-confirm'),
          label: delete ? s.memEntryDelete : s.memEntrySave,
          value: true,
          style: delete
              ? HermesDialogActionStyle.destructive
              : HermesDialogActionStyle.primary,
        ),
      ],
    );
    if (ok != true || !mounted) return false;
    final lock = context.findAncestorStateOfType<HermesAppState>()?.appLock;
    if (lock != null && lock.enabled) {
      final verified = await LockScreen.verify(
        context,
        lock,
        reason: s.memEntryLockReason,
      );
      if (!verified || !mounted) return false;
    }
    return true;
  }

  Future<void> _write({required bool delete}) async {
    final loaded = _loaded;
    if (loaded == null || _busy || locked) return;
    final s = Strings.of(context);
    final text = _controller.text;
    setState(() => _error = null);
    // Size first: an oversized entry never reaches the confirmation.
    if (!delete && MemoryEntriesRepository.exceedsLimit(text)) {
      setState(() => _error = s.memEntryTooLarge);
      return;
    }
    if (!await _approve(delete: delete) || !mounted || locked) return;
    setState(() => _busy = true);
    try {
      if (delete) {
        await widget.repository.delete(loaded);
      } else {
        await widget.repository.save(loaded, text);
      }
      if (!mounted) return;
      HermesNotice.of(context).show(
        message: delete ? s.memEntryDeleted : s.memEntrySaved,
        kind: HermesNoticeKind.success,
      );
      Navigator.of(context).pop(true);
    } on MemoryEntryFailure catch (failure) {
      if (!mounted) return;
      setState(() => _busy = false);
      switch (failure.kind) {
        case MemoryEntryFailureKind.conflict:
          await _conflict();
        case MemoryEntryFailureKind.tooLarge:
          setState(() => _error = s.memEntryTooLarge);
        case MemoryEntryFailureKind.rejected:
          setState(
            () => _error = failure.detail.isEmpty
                ? s.memEntryFailed
                : s.memEntryRejected(failure.detail),
          );
        case MemoryEntryFailureKind.unsupported:
          setState(() => _error = s.memEntriesUnsupported);
        case MemoryEntryFailureKind.unavailable:
          setState(() => _error = s.memEntryFailed);
      }
    }
  }

  /// The entry changed elsewhere: nothing was written. The user keeps their
  /// text or goes back to the refreshed list to see the server version.
  Future<void> _conflict() async {
    final s = Strings.of(context);
    final reload = await showHermesDialog<bool>(
      context: context,
      surfaceKey: const ValueKey('memory-entry-conflict'),
      title: s.memEntryConflictTitle,
      message: s.memEntryConflictBody,
      actions: [
        HermesDialogAction(
          key: const ValueKey('memory-entry-conflict-keep'),
          label: s.memEntryConflictKeep,
          value: false,
          style: HermesDialogActionStyle.cancel,
        ),
        HermesDialogAction(
          key: const ValueKey('memory-entry-conflict-reload'),
          label: s.memEntryConflictReload,
          value: true,
        ),
      ],
    );
    if (!mounted) return;
    if (reload == true) {
      Navigator.of(context).pop(true);
    } else {
      setState(() => _error = s.memEntryConflictBody);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final canWrite = !widget.readOnly && _loaded != null && !locked;
    final Widget body;
    if (locked) {
      body = _Message(s.memEntriesLocked, icon: Icons.lock_outline_rounded);
    } else if (_loadFailure != null) {
      body = _Message(
        _loadFailure == MemoryEntryFailureKind.unsupported
            ? s.memEntriesUnsupported
            : s.memEntryGone,
        icon: Icons.cloud_off_outlined,
        actionLabel: s.memEntryConflictReload,
        onAction: () => Navigator.of(context).pop(true),
      );
    } else if (_loaded == null) {
      body = const Center(child: CircularProgressIndicator());
    } else {
      body = Column(
        children: [
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: HermesInlineNotice(
                key: const ValueKey('memory-entry-error'),
                message: _error!,
                icon: Icons.error_outline_rounded,
                tone: HermesStatusTone.error,
              ),
            ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(
                key: const ValueKey('memory-entry-field'),
                controller: _controller,
                readOnly: widget.readOnly,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                keyboardType: TextInputType.multiline,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  color: colors.textPrimary,
                ),
                decoration: InputDecoration(hintText: s.memEntryHint),
              ),
            ),
          ),
        ],
      );
    }
    return Scaffold(
      appBar: HermesAppBar(
        title: Text(_fileLabel(widget.file)),
        actions: [
          if (canWrite) ...[
            IconButton(
              key: const ValueKey('memory-entry-delete'),
              tooltip: s.memEntryDelete,
              icon: const Icon(Icons.delete_outline_rounded),
              onPressed: _busy ? null : () => _write(delete: true),
            ),
            IconButton(
              key: const ValueKey('memory-entry-save'),
              tooltip: s.memEntrySave,
              icon: _busy
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: colors.textSecondary,
                      ),
                    )
                  : const Icon(Icons.check_rounded),
              onPressed: _busy ? null : () => _write(delete: false),
            ),
          ],
        ],
      ),
      body: body,
    );
  }
}

class _Message extends StatelessWidget {
  final String text;
  final IconData icon;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _Message(
    this.text, {
    required this.icon,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(20),
    child: Align(
      alignment: Alignment.topCenter,
      child: HermesInlineNotice(
        message: text,
        icon: icon,
        actionLabel: actionLabel,
        onAction: onAction,
      ),
    ),
  );
}
