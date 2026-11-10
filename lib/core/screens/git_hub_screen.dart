import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_localizations.dart';
import '../../main.dart' show HermesAppState;
import '../design/modal.dart'
    show
        HermesAction,
        HermesDialogAction,
        HermesDialogActionStyle,
        HermesMenuButton,
        HermesOption,
        showHermesFormDialog,
        showHermesOptions;
import '../design/tokens.dart';
import '../feedback/feedback_policy.dart';
import '../models/desktop_control_center.dart' show ProjectGitBranch;
import '../models/git_hub.dart';
import '../models/git_review.dart';
import '../services/git_hub_controller.dart';
import '../services/git_hub_gateway.dart';
import '../services/git_review_controller.dart';
import '../services/git_review_gateway.dart';
import '../theme/app_theme.dart';
import '../theme/hermes_tokens.dart' show HermesIcon, HermesSize;
import '../theme/text_scale.dart';
import '../utils/server_path.dart' show serverPathBaseName;
import '../widgets/console_loader.dart';
import '../widgets/hermes_notice.dart' show HermesNoticeAction;
import '../widgets/hermes_premium_ui.dart'
    show HermesSegment, HermesSegmentedControl, showHermesConfirmDialog;
import '../widgets/hermes_ui.dart' show HermesSwitchTile;
import '../widgets/projects/project_actions.dart' show isValidGitRef;
import '../widgets/workspace/chat_workspace_host.dart'
    show ChatWorkspacePaneScope;
import 'git_hub_worktrees_screen.dart';
import 'git_review_screen.dart';
import 'lock_screen.dart';

/// «Cambios»: Git for the chat's folder as a tab of the workspace. The
/// folder's name over its branch, a path search, the scope (the working
/// tree, or the branch against its base), the file count, the files by
/// state with stage / unstage / discard, the commit bar with the server's
/// context, and one row that opens push and the pull request. Branches
/// and worktrees hang from the branch and the menu.
///
/// Everything goes through the Dashboard `/api/git/*` routes; the server
/// runs git and gh. On a wide screen outside the pane the ship page sits
/// beside the list. A gateway without the hub routes (an older fake)
/// falls back to the review pane alone.
class GitHubScreen extends StatefulWidget {
  const GitHubScreen({
    super.key,
    required this.gateway,
    required this.connectionId,
    required this.repoPath,
    this.onOpenTerminal,
    this.sessionReadOnly = false,
  });

  final HermesGitReviewGateway gateway;
  final String connectionId;

  /// The folder (Desktop's `$currentCwd`, a project's root, a worktree).
  final String repoPath;

  /// Opens the instance's terminal on top (conflicts, identity, remote
  /// credentials are fixed there). Null when the instance has none.
  final VoidCallback? onOpenTerminal;

  /// The chat's approval policy says read-only for this session: no write
  /// is offered even when the connection itself may write.
  final bool sessionReadOnly;

  /// From this width (outside the pane) the ship page sits beside the
  /// list.
  static const double wideBreakpoint = 720;

  @override
  State<GitHubScreen> createState() => _GitHubScreenState();
}

class _GitHubScreenState extends State<GitHubScreen> {
  GitHubController? _controller;
  final TextEditingController _message = TextEditingController();
  final TextEditingController _search = TextEditingController();
  bool _pushAfterCommit = false;
  bool _commitOptions = false;

  HermesGitHubGateway? get _hub => switch (widget.gateway) {
    final HermesGitHubGateway hub => hub,
    _ => null,
  };

  @override
  void initState() {
    super.initState();
    final hub = _hub;
    if (hub != null) {
      final controller = GitHubController(
        gateway: hub,
        connectionId: widget.connectionId,
        repoPath: widget.repoPath,
      );
      controller.addListener(_onChanged);
      _controller = controller;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(controller.refresh());
      });
    }
    _message.addListener(_onChanged);
    _search.addListener(_onChanged);
  }

  @override
  void dispose() {
    _controller?.removeListener(_onChanged);
    _controller?.dispose();
    _message.dispose();
    _search.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  bool get _writes =>
      !widget.sessionReadOnly && (_controller?.writesAllowed ?? false);

  ({FeedbackSink sink, Strings strings}) _lane() =>
      (sink: AppFeedback.of(context), strings: Strings.of(context));

  void _fail(Object error, ({FeedbackSink sink, Strings strings}) lane) {
    final terminal = mounted ? widget.onOpenTerminal : null;
    lane.sink.notify(
      FeedbackKind.error,
      gitFailureText(error, lane.strings),
      action: terminal != null && gitFailureNeedsTerminal(error)
          ? HermesNoticeAction(
              label: lane.strings.chaControlTerminal,
              onPressed: terminal,
            )
          : null,
    );
  }

  /// App Lock before a destructive or publishing action, as Recovery and
  /// SFTP do. True when the app has no lock.
  Future<bool> _unlock(String reason) async {
    final lock = context.findAncestorStateOfType<HermesAppState>()?.appLock;
    if (lock == null) return true;
    final ok = await LockScreen.verify(context, lock, reason: reason);
    return ok && mounted;
  }

  Future<bool> _confirmDestructive({
    required String title,
    required String message,
    required String confirmLabel,
  }) async {
    final strings = Strings.of(context);
    final ok = await showHermesConfirmDialog(
      context: context,
      title: title,
      message: message,
      confirmLabel: confirmLabel,
      cancelLabel: strings.commonCancel,
      destructive: true,
    );
    return ok && mounted;
  }

  // ── changes ─────────────────────────────────────────────────────────

  Future<void> _openFile(GitReviewFile file) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => GitDiffScreen(
        controller: _controller!,
        file: file,
        onDiscard: _writes && _controller!.isUncommittedScope ? _discard : null,
      ),
    ),
  );

  Future<bool> _discard(GitReviewFile file) async {
    final strings = Strings.of(context);
    final lane = _lane();
    final ok = await _confirmDestructive(
      title: strings.ghtDiscardTitle(file.name),
      message: strings.ghtDiscardBody,
      confirmLabel: strings.ghtDiscardAction,
    );
    if (!ok || !await _unlock(strings.ghtLockReasonDiscard)) return false;
    try {
      await _controller!.revert(file: file);
      lane.sink.notify(FeedbackKind.routine, strings.ghtDiscarded);
      return true;
    } catch (error) {
      _fail(error, lane);
      return false;
    }
  }

  Future<void> _discardAll() async {
    final controller = _controller!;
    final strings = Strings.of(context);
    final lane = _lane();
    final ok = await _confirmDestructive(
      title: strings.ghtDiscardAllTitle,
      message: strings.ghtDiscardAllBody(controller.files.length),
      confirmLabel: strings.ghtDiscardAction,
    );
    if (!ok || !await _unlock(strings.ghtLockReasonDiscard)) return;
    try {
      await controller.revert();
      lane.sink.notify(FeedbackKind.routine, strings.ghtDiscarded);
    } catch (error) {
      _fail(error, lane);
    }
  }

  Future<void> _stageAll(bool stage) async {
    final lane = _lane();
    try {
      if (stage) {
        await _controller!.stageAll();
      } else {
        await _controller!.unstageAll();
      }
    } catch (error) {
      _fail(error, lane);
    }
  }

  Future<void> _toggleStaged(GitReviewFile file) async {
    final lane = _lane();
    try {
      await _controller!.toggleStaged(file);
    } catch (error) {
      _fail(error, lane);
    }
  }

  // ── commit & push ────────────────────────────────────────────────────

  Future<void> _commit() async {
    final strings = Strings.of(context);
    final lane = _lane();
    final push = _pushAfterCommit;
    if (push && !await _unlock(strings.ghtLockReasonPush)) return;
    try {
      final done = await _controller!.commitChanges(_message.text, push: push);
      if (!done) return;
      if (mounted) _message.clear();
      lane.sink.notify(
        FeedbackKind.routine,
        push ? strings.ghtCommitPushedDone : strings.ghtCommitDone,
      );
    } catch (error) {
      _fail(error, lane);
    }
  }

  Future<void> _push() async {
    final strings = Strings.of(context);
    final lane = _lane();
    if (!await _unlock(strings.ghtLockReasonPush)) return;
    try {
      await _controller!.push();
      lane.sink.notify(FeedbackKind.routine, strings.ghtPushDone);
    } catch (error) {
      _fail(error, lane);
    }
  }

  Future<void> _toggleCommitOptions() async {
    final controller = _controller!;
    setState(() => _commitOptions = !_commitOptions);
    if (_commitOptions && controller.commitContext == null) {
      await controller.loadCommitContext();
    }
  }

  // ── pull requests ────────────────────────────────────────────────────

  Future<void> _openLink(String url) async {
    final strings = Strings.of(context);
    final lane = _lane();
    final uri = gitSafeHttpsUrl(url);
    if (uri == null) {
      lane.sink.notify(FeedbackKind.error, strings.ghtPrLinkUnsafe);
      return;
    }
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok) throw Exception('launchUrl=false');
    } catch (_) {
      lane.sink.notify(FeedbackKind.error, strings.aboutLinkError);
    }
  }

  Future<void> _createPullRequest() async {
    final controller = _controller!;
    final strings = Strings.of(context);
    final lane = _lane();
    final branch = controller.status?.branch ?? '';
    if (controller.baseBranches.isEmpty) {
      try {
        await controller.loadBaseBranches();
      } catch (_) {
        // The confirmation then names the trunk the status knows.
      }
      if (!mounted) return;
    }
    final base = controller.defaultBase;
    final ok = await showHermesConfirmDialog(
      context: context,
      title: strings.ghtPrCreateConfirmTitle,
      message: strings.ghtPrCreateConfirmBody(
        branch,
        base.isEmpty ? '—' : base,
      ),
      confirmLabel: strings.ghtBranchNewCreate,
      cancelLabel: strings.commonCancel,
    );
    if (!ok || !mounted || !await _unlock(strings.ghtLockReasonPr)) return;
    try {
      final created = await controller.createPullRequest();
      final url = created.url;
      lane.sink.notify(
        FeedbackKind.critical,
        strings.ghtPrCreated,
        action: gitSafeHttpsUrl(url) == null
            ? null
            : HermesNoticeAction(
                label: strings.ghtPrOpenLink,
                onPressed: () => _openLink(url),
              ),
      );
    } catch (error) {
      _fail(error, lane);
    }
  }

  Future<void> _loadPullRequests() async {
    final lane = _lane();
    try {
      await _controller!.loadPullRequests();
    } catch (error) {
      _fail(error, lane);
    }
  }

  Future<void> _openShip() => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => _ShipScreen(
        controller: _controller!,
        writes: _writes,
        onPush: _push,
        onCreate: _createPullRequest,
        onLoadList: _loadPullRequests,
        onOpenLink: _openLink,
      ),
    ),
  );

  // ── branches & worktrees ─────────────────────────────────────────────

  static const String _newBranchChoice = '\u0000new-branch';

  Future<void> _pickBranch() async {
    final controller = _controller!;
    final strings = Strings.of(context);
    final lane = _lane();
    try {
      await controller.loadBranches();
    } catch (error) {
      _fail(error, lane);
      return;
    }
    if (!mounted) return;
    final current = controller.status?.branch;
    final choice = await showHermesOptions<String>(
      context: context,
      title: strings.ghtBranchesTitle,
      selected: current,
      surfaceKey: const ValueKey('ght-branch-sheet'),
      options: [
        if (_writes)
          HermesOption(
            key: const ValueKey('ght-branch-new'),
            value: _newBranchChoice,
            label: strings.ghtBranchNew,
            icon: Icons.add_rounded,
          ),
        for (final branch in controller.branches)
          HermesOption(
            key: ValueKey('ght-branch-${branch.name}'),
            value: branch.name,
            label: branch.name,
            icon: branch.isRemote
                ? Icons.cloud_outlined
                : Icons.call_split_rounded,
            subtitle: branch.name == current
                ? strings.ghtBranchCurrent
                : branch.worktreePath.isNotEmpty &&
                      branch.worktreePath != widget.repoPath
                ? strings.ghtBranchInWorktree(branch.worktreePath)
                : branch.isRemote
                ? strings.ghtBranchRemote
                : null,
            // Switching needs a write; a branch of another worktree is
            // opened there instead.
            enabled:
                branch.name != current &&
                (_writes || branch.worktreePath.isNotEmpty),
          ),
        if (controller.branches.isEmpty)
          HermesOption(value: '', label: strings.ghtBranchNone, enabled: false),
      ],
    );
    if (choice == null || choice.isEmpty || !mounted) return;
    if (choice == _newBranchChoice) {
      await _newBranch();
      return;
    }
    final branch = controller.branches
        .where((b) => b.name == choice)
        .firstOrNull;
    if (branch == null) return;
    await _switchTo(branch);
  }

  Future<void> _switchTo(ProjectGitBranch branch) async {
    final controller = _controller!;
    final strings = Strings.of(context);
    final lane = _lane();
    if (branch.worktreePath.isNotEmpty &&
        branch.worktreePath != widget.repoPath) {
      _openHubAt(branch.worktreePath);
      return;
    }
    final changed = controller.status?.changed ?? 0;
    // `git switch feature` creates the tracking branch of origin/feature
    // itself; the remote prefix is not a branch git can switch to.
    final target = branch.isRemote && branch.name.contains('/')
        ? branch.name.substring(branch.name.indexOf('/') + 1)
        : branch.name;
    if (changed > 0) {
      final ok = await _confirmDestructive(
        title: strings.ghtBranchSwitchConfirmTitle(target),
        message: strings.ghtBranchSwitchConfirmBody(changed),
        confirmLabel: strings.ghtSwitchAction,
      );
      if (!ok || !await _unlock(strings.ghtLockReasonSwitch)) return;
    }
    try {
      await controller.switchBranch(target);
      lane.sink.notify(FeedbackKind.routine, strings.ghtBranchSwitched(target));
    } catch (error) {
      _fail(error, lane);
    }
  }

  Future<void> _newBranch() async {
    final controller = _controller!;
    final strings = Strings.of(context);
    final lane = _lane();
    try {
      await controller.loadBaseBranches();
    } catch (_) {
      // Without the list the server picks its own base (HEAD).
    }
    if (!mounted) return;
    final name = TextEditingController();
    var base = controller.defaultBase;
    final create = await showHermesFormDialog<bool>(
      context: context,
      title: strings.ghtBranchNew,
      message: strings.ghtBranchNewHint,
      surfaceKey: const ValueKey('ght-new-branch-dialog'),
      enabled: (value) => !value || isValidGitRef(name.text.trim()),
      actions: [
        HermesDialogAction(
          label: strings.commonCancel,
          value: false,
          style: HermesDialogActionStyle.cancel,
        ),
        HermesDialogAction(
          key: const ValueKey('ght-new-branch-create'),
          label: strings.ghtBranchNewCreate,
          value: true,
        ),
      ],
      body: (dialogContext, setState) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const ValueKey('ght-new-branch-name'),
            controller: name,
            autofocus: true,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(labelText: strings.ghtBranchNewName),
          ),
          if (controller.baseBranches.isNotEmpty) ...[
            const SizedBox(height: HermesSpace.x3),
            OutlinedButton.icon(
              key: const ValueKey('ght-new-branch-base'),
              onPressed: () async {
                final picked = await showHermesOptions<String>(
                  context: dialogContext,
                  title: strings.ghtBranchNewBase,
                  selected: base,
                  options: [
                    for (final b in controller.baseBranches)
                      HermesOption(
                        value: b.name,
                        label: b.name,
                        subtitle: b.isRemote ? strings.ghtBranchRemote : null,
                      ),
                  ],
                );
                if (picked != null) setState(() => base = picked);
              },
              icon: const Icon(Icons.call_split_rounded, size: HermesIcon.sm),
              label: Text(
                '${strings.ghtBranchNewBase}: $base',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ],
      ),
    );
    final branch = name.text.trim();
    name.dispose();
    if (create != true || !mounted) return;
    try {
      final result = await controller.addWorktree(
        branch: branch,
        base: base.isEmpty ? null : base,
      );
      lane.sink.notify(
        FeedbackKind.critical,
        strings.ghtWorktreeCreated(result.path),
        action: HermesNoticeAction(
          label: strings.ghtWorktreeOpen,
          onPressed: () => _openHubAt(result.path),
        ),
      );
    } catch (error) {
      _fail(error, lane);
    }
  }

  void _openHubAt(String path) {
    if (!mounted) return;
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => GitHubScreen(
            gateway: widget.gateway,
            connectionId: widget.connectionId,
            repoPath: path,
            onOpenTerminal: widget.onOpenTerminal,
            sessionReadOnly: widget.sessionReadOnly,
          ),
        ),
      ),
    );
  }

  Future<void> _openWorktrees() => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => GitWorktreesScreen(
        controller: _controller!,
        writes: _writes,
        onOpen: _openHubAt,
        unlock: _unlock,
        onFailure: (error) => _fail(error, _lane()),
      ),
    ),
  );

  Future<void> _onMenu(_GitHubMenu action) async {
    switch (action) {
      case _GitHubMenu.ship:
        await _openShip();
      case _GitHubMenu.worktrees:
        await _openWorktrees();
      case _GitHubMenu.refreshGitHub:
        await _controller!.refreshShip(refreshAuth: true);
      case _GitHubMenu.discardAll:
        await _discardAll();
    }
  }

  // ── build ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) {
      return GitReviewScreen(
        gateway: widget.gateway,
        connectionId: widget.connectionId,
        repoPath: widget.repoPath,
        onOpenTerminal: widget.onOpenTerminal,
      );
    }
    final colors = Theme.of(context).hermes;
    return Scaffold(
      key: const ValueKey('ght-screen'),
      backgroundColor: ChatWorkspacePaneScope.backgroundOf(
        context,
        colors.background,
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide =
                constraints.maxWidth >= GitHubScreen.wideBreakpoint &&
                !ChatWorkspacePaneScope.isInPane(context);
            final column = _column(context, controller, wide: wide);
            if (!wide) return column;
            return Row(
              key: const ValueKey('ght-wide'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(flex: 5, child: column),
                VerticalDivider(width: 1, color: colors.divider),
                Expanded(
                  flex: 4,
                  child: controller.phase == GitReviewPhase.ready
                      ? _ShipPage(
                          controller: controller,
                          writes: _writes,
                          onPush: _push,
                          onCreate: _createPullRequest,
                          onLoadList: _loadPullRequests,
                          onOpenLink: _openLink,
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _column(
    BuildContext context,
    GitHubController controller, {
    required bool wide,
  }) {
    final strings = Strings.of(context);
    final ready = controller.phase == GitReviewPhase.ready;
    final showBar =
        ready &&
        _writes &&
        controller.isUncommittedScope &&
        controller.hasFiles;
    return Column(
      children: [
        _TopRow(
          controller: controller,
          writes: _writes,
          onMenu: _onMenu,
          showShip: !wide,
        ),
        _FolderTitle(
          path: widget.repoPath,
          status: controller.status,
          onPickBranch: ready && !controller.isBusy ? _pickBranch : null,
        ),
        _StatusStrip(controller: controller, readOnly: !_writes),
        if (ready) ...[
          _SearchField(controller: _search),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              HermesSpace.inset,
              HermesSpace.x2,
              HermesSpace.inset,
              0,
            ),
            child: HermesSegmentedControl<GitReviewScope>(
              key: const ValueKey('ght-scope'),
              value: controller.scope,
              semanticLabel: strings.ghtPanelTitle,
              onChanged: controller.loading
                  ? (_) {}
                  : (scope) => unawaited(controller.setScope(scope)),
              segments: [
                HermesSegment(
                  key: const ValueKey('ght-scope-uncommitted'),
                  value: GitReviewScope.uncommitted,
                  label: strings.ghtScopeUncommitted,
                ),
                HermesSegment(
                  key: const ValueKey('ght-scope-branch'),
                  value: GitReviewScope.branch,
                  label: strings.ghtScopeBranch,
                ),
              ],
            ),
          ),
          _CountRow(
            controller: controller,
            onOpenShip: wide ? null : _openShip,
          ),
        ],
        Expanded(child: _body(context, controller)),
        if (showBar)
          _CommitBar(
            controller: controller,
            message: _message,
            options: _commitOptions,
            onToggleOptions: _toggleCommitOptions,
            pushAfterCommit: _pushAfterCommit,
            onPushAfterCommit: (value) =>
                setState(() => _pushAfterCommit = value),
            onCommit: _commit,
            onOpenTerminal: widget.onOpenTerminal,
          ),
      ],
    );
  }

  Widget _body(BuildContext context, GitHubController controller) {
    final strings = Strings.of(context);
    switch (controller.phase) {
      case GitReviewPhase.loading:
        return const Center(child: ConsoleLoader.medium());
      case GitReviewPhase.notRepo:
        return GitStateMessage(
          key: const ValueKey('git-state-not-repo'),
          icon: Icons.folder_off_outlined,
          title: strings.gitNotRepo,
          text: strings.ghtNotRepoBody,
          onRetry: controller.refresh,
        );
      case GitReviewPhase.unsupported:
        return GitStateMessage(
          key: const ValueKey('git-state-unsupported'),
          icon: Icons.cloud_off_outlined,
          title: strings.gitFailureUnsupported,
          text: strings.ghtUnsupportedBody,
        );
      case GitReviewPhase.failed:
        return GitStateMessage(
          key: const ValueKey('git-state-failed'),
          text: gitFailureText(controller.failure ?? Object(), strings),
          onRetry: controller.refresh,
        );
      case GitReviewPhase.ready:
        break;
    }
    return _ChangesList(
      controller: controller,
      writes: _writes,
      query: _search.text,
      onOpen: _openFile,
      onToggleStaged: _toggleStaged,
      onDiscard: _discard,
      onStageAll: () => _stageAll(true),
      onUnstageAll: () => _stageAll(false),
    );
  }
}

enum _GitHubMenu { ship, worktrees, refreshGitHub, discardAll }

/// Back (when there is somewhere to go), refresh and the hub's menu.
class _TopRow extends StatelessWidget {
  const _TopRow({
    required this.controller,
    required this.writes,
    required this.onMenu,
    required this.showShip,
  });

  final GitHubController controller;
  final bool writes;
  final ValueChanged<_GitHubMenu> onMenu;

  /// The ship entry in the menu (not on a wide screen, where it is beside).
  final bool showShip;

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final ready = controller.phase == GitReviewPhase.ready;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        HermesSpace.x1,
        HermesSpace.x1,
        HermesSpace.x2,
        0,
      ),
      child: Row(
        children: [
          if (Navigator.of(context).canPop())
            IconButton(
              key: const ValueKey('git-back'),
              tooltip: MaterialLocalizations.of(context).backButtonTooltip,
              onPressed: () => Navigator.of(context).maybePop(),
              icon: Icon(Icons.arrow_back_rounded, color: colors.textPrimary),
            ),
          const Spacer(),
          IconButton(
            key: const ValueKey('git-refresh'),
            tooltip: strings.gitRefresh,
            onPressed: controller.loading ? null : controller.refresh,
            icon: Icon(Icons.refresh_rounded, color: colors.textSecondary),
          ),
          if (ready)
            HermesMenuButton<_GitHubMenu>(
              key: const ValueKey('ght-menu'),
              tooltip: strings.ghtMore,
              iconColor: colors.textSecondary,
              surfaceKey: const ValueKey('ght-menu-surface'),
              enabled: !controller.isBusy,
              actions: (_) => [
                if (showShip)
                  HermesAction(
                    key: const ValueKey('ght-menu-ship'),
                    value: _GitHubMenu.ship,
                    label: strings.ghtShipTitle,
                    icon: Icons.cloud_upload_outlined,
                  ),
                HermesAction(
                  key: const ValueKey('ght-menu-worktrees'),
                  value: _GitHubMenu.worktrees,
                  label: strings.ghtWorktrees,
                  icon: Icons.account_tree_outlined,
                ),
                HermesAction(
                  key: const ValueKey('ght-menu-refresh-github'),
                  value: _GitHubMenu.refreshGitHub,
                  label: strings.ghtRefreshGitHub,
                  icon: Icons.cloud_sync_outlined,
                ),
                if (writes &&
                    controller.hasFiles &&
                    controller.isUncommittedScope)
                  HermesAction(
                    key: const ValueKey('ght-discard-all'),
                    value: _GitHubMenu.discardAll,
                    label: strings.ghtDiscardAll,
                    icon: Icons.undo_rounded,
                    destructive: true,
                  ),
              ],
              onSelected: onMenu,
            ),
        ],
      ),
    );
  }
}

/// The folder's name over its branch (the branch picker) and the
/// coding-row counts (↑ahead ↓behind, +A −R).
class _FolderTitle extends StatelessWidget {
  const _FolderTitle({
    required this.path,
    required this.status,
    required this.onPickBranch,
  });

  final String path;
  final GitRepoStatus? status;
  final VoidCallback? onPickBranch;

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final name = serverPathBaseName(path);
    final status = this.status;
    final folder = name.isEmpty ? path : name;
    final branch = status == null
        ? strings.ghtPanelTitle
        : status.detached
        ? strings.gitDetached
        : status.branch ?? strings.gitNoBranch;
    final countStyle = TextStyle(
      fontSize: HermesType.supportSize,
      fontFeatures: const [FontFeature.tabularFigures()],
      color: colors.textSecondary,
    );
    final onPick = status == null ? null : onPickBranch;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        HermesSpace.x4,
        0,
        HermesSpace.x4,
        HermesSpace.x1,
      ),
      child: Column(
        key: const ValueKey('ght-folder-title'),
        children: [
          Semantics(
            header: true,
            label: strings.ghtFolderLabel(folder),
            excludeSemantics: true,
            child: Text(
              folder,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: HermesType.title.copyWith(color: colors.textPrimary),
            ),
          ),
          Semantics(
            button: onPick != null,
            label: onPick == null ? null : strings.ghtBranchPick,
            value: branch,
            excludeSemantics: true,
            child: InkWell(
              key: const ValueKey('ght-branch-button'),
              borderRadius: BorderRadius.circular(HermesRadius.tag),
              onTap: onPick,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: HermesSpace.x3,
                  vertical: HermesSpace.x1,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        branch,
                        key: const ValueKey('git-branch'),
                        maxLines: labelMaxLines(context),
                        overflow: TextOverflow.ellipsis,
                        style: HermesType.text.copyWith(
                          color: onPick == null
                              ? colors.textSecondary
                              : colors.accentText,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (onPick != null)
                      Icon(
                        Icons.expand_more_rounded,
                        size: HermesIcon.sm,
                        color: colors.accentText,
                      ),
                    if (status != null) ...[
                      if (status.ahead > 0) ...[
                        const SizedBox(width: HermesSpace.x2),
                        Semantics(
                          label: strings.gitAhead(status.ahead),
                          child: ExcludeSemantics(
                            child: Text('↑${status.ahead}', style: countStyle),
                          ),
                        ),
                      ],
                      if (status.behind > 0) ...[
                        const SizedBox(width: HermesSpace.x1),
                        Semantics(
                          label: strings.gitBehind(status.behind),
                          child: ExcludeSemantics(
                            child: Text('↓${status.behind}', style: countStyle),
                          ),
                        ),
                      ],
                      if (status.hasLineDelta) ...[
                        const SizedBox(width: HermesSpace.x2),
                        GitDiffCount(
                          added: status.added,
                          removed: status.removed,
                          fontSize: HermesType.supportSize,
                        ),
                      ],
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Only what needs attention: gh missing or signed out, the author
/// identity known missing, read-only.
class _StatusStrip extends StatelessWidget {
  const _StatusStrip({required this.controller, required this.readOnly});

  final GitHubController controller;
  final bool readOnly;

  @override
  Widget build(BuildContext context) {
    if (controller.phase != GitReviewPhase.ready) {
      return const SizedBox.shrink();
    }
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final auth = controller.ghAuth;
    final chips = <(Key, IconData, String, Color)>[
      if (auth != null && !auth.available)
        (
          const ValueKey('ght-github-state'),
          Icons.cloud_off_outlined,
          strings.ghtGitHubMissing,
          colors.textSecondary,
        )
      else if (auth != null && !auth.authenticated)
        (
          const ValueKey('ght-github-state'),
          Icons.cloud_outlined,
          strings.ghtGitHubSignedOut,
          colors.warning,
        ),
      if (controller.identity == GitIdentityState.missing)
        (
          const ValueKey('ght-identity'),
          Icons.badge_outlined,
          strings.ghtIdentityMissing,
          colors.warning,
        ),
      if (readOnly)
        (
          const ValueKey('ght-read-only'),
          Icons.lock_outline_rounded,
          strings.statusReadOnly,
          colors.textTertiary,
        ),
    ];
    if (chips.isEmpty) return const SizedBox.shrink();
    final style = TextStyle(
      fontSize: HermesType.supportSize,
      height: 1.3,
      fontWeight: FontWeight.w600,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        HermesSpace.x4,
        0,
        HermesSpace.x4,
        HermesSpace.x1,
      ),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: HermesSpace.x4,
        runSpacing: HermesSpace.x1,
        children: [
          for (final (key, icon, text, tone) in chips)
            Row(
              key: key,
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: HermesIcon.sm, color: tone),
                const SizedBox(width: HermesSpace.x1),
                Flexible(
                  child: Text(
                    text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: style.copyWith(color: tone),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// «Buscar rutas»: filters the list by path.
class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final chrome = HermesChrome.of(colors);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        HermesSpace.inset,
        HermesSpace.x1,
        HermesSpace.inset,
        0,
      ),
      child: TextField(
        key: const ValueKey('ght-search'),
        controller: controller,
        textInputAction: TextInputAction.search,
        style: HermesType.text.copyWith(color: colors.textPrimary),
        decoration: InputDecoration(
          hintText: strings.ghtSearchPaths,
          hintStyle: TextStyle(color: chrome.mutedInk),
          prefixIcon: Icon(
            Icons.search_rounded,
            size: HermesIcon.lg,
            color: chrome.mutedInk,
          ),
          suffixIcon: controller.text.isEmpty
              ? null
              : IconButton(
                  key: const ValueKey('ght-search-clear'),
                  tooltip: MaterialLocalizations.of(context).clearButtonTooltip,
                  onPressed: controller.clear,
                  icon: const Icon(Icons.close_rounded, size: HermesIcon.lg),
                ),
          filled: true,
          fillColor: chrome.opaque,
          isDense: true,
          constraints: const BoxConstraints(minHeight: HermesSize.tap),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: HermesSpace.x4,
            vertical: HermesSpace.x3,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(HermesSize.tap / 2),
            borderSide: BorderSide(color: chrome.line),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(HermesSize.tap / 2),
            borderSide: BorderSide(color: chrome.line),
          ),
        ),
      ),
    );
  }
}

/// «N archivos» and, at the end, the ship row: what is left to push and
/// the branch's pull request, opening the ship page.
class _CountRow extends StatelessWidget {
  const _CountRow({required this.controller, required this.onOpenShip});

  final GitHubController controller;
  final VoidCallback? onOpenShip;

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final status = controller.status;
    final ship = controller.shipInfo;
    final pr = ship?.pullRequest;
    final parts = <String>[
      if ((status?.ahead ?? 0) > 0) strings.ghtPushAhead(status!.ahead),
      if (pr != null)
        '${strings.ghtPrNumber(pr.number)} · '
            '${gitPrStateLabel(pr.state, false, strings)}'
      else if (ship != null && ship.ghReady)
        strings.ghtPrNone
      else if (controller.ghAuth?.authenticated ?? false)
        strings.ghtGitHubConnected,
    ];
    final onOpenShip = this.onOpenShip;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        HermesSpace.x4,
        HermesSpace.x2,
        HermesSpace.x2,
        HermesSpace.x1,
      ),
      child: Row(
        children: [
          Text(
            strings.ghtFileCount(controller.files.length),
            key: const ValueKey('ght-file-count'),
            style: HermesType.support.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(width: HermesSpace.x3),
          if (onOpenShip != null)
            Expanded(
              child: Align(
                alignment: AlignmentDirectional.centerEnd,
                child: Semantics(
                  button: true,
                  label: strings.ghtShipOpen,
                  value: parts.join(', '),
                  excludeSemantics: true,
                  child: InkWell(
                    key: const ValueKey('ght-ship-row'),
                    borderRadius: BorderRadius.circular(HermesRadius.tag),
                    onTap: onOpenShip,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        minHeight: HermesSpace.tap - HermesSpace.x2,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: HermesSpace.x2,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                parts.isEmpty
                                    ? strings.ghtShipTitle
                                    : parts.join(' · '),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.end,
                                style: HermesType.support.copyWith(
                                  color: colors.accentText,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            Icon(
                              Icons.chevron_right_rounded,
                              size: HermesIcon.md,
                              color: colors.accentText,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// What a PR state says, in words.
String gitPrStateLabel(String state, bool draft, Strings strings) {
  if (draft) return strings.ghtPrStateDraft;
  return switch (state) {
    'open' => strings.ghtPrStateOpen,
    'merged' => strings.ghtPrStateMerged,
    'closed' => strings.ghtPrStateClosed,
    _ => state,
  };
}

enum _FileAction { diff, stage, unstage, discard }

/// The changed files by state (staged, unstaged, untracked) with each
/// group's batch action and each row's menu; a flat list in the branch
/// scope. Filtered by the path search; the clean states when empty.
class _ChangesList extends StatelessWidget {
  const _ChangesList({
    required this.controller,
    required this.writes,
    required this.query,
    required this.onOpen,
    required this.onToggleStaged,
    required this.onDiscard,
    required this.onStageAll,
    required this.onUnstageAll,
  });

  final GitHubController controller;
  final bool writes;
  final String query;
  final ValueChanged<GitReviewFile> onOpen;
  final ValueChanged<GitReviewFile> onToggleStaged;
  final Future<bool> Function(GitReviewFile) onDiscard;
  final VoidCallback onStageAll;
  final VoidCallback onUnstageAll;

  bool _matches(GitReviewFile file) {
    final needle = query.trim().toLowerCase();
    return needle.isEmpty || file.path.toLowerCase().contains(needle);
  }

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final uncommitted = controller.isUncommittedScope;
    if (!controller.hasFiles) {
      return RefreshIndicator(
        onRefresh: controller.refresh,
        child: ListView(
          key: const ValueKey('git-state-no-diffs'),
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            Padding(
              padding: const EdgeInsets.only(top: HermesSpace.x8),
              child: GitStateMessage(
                key: ValueKey(uncommitted ? 'ght-clean' : 'ght-branch-clean'),
                icon: Icons.check_circle_outline_rounded,
                title: uncommitted
                    ? strings.ghtCleanTitle
                    : strings.ghtBranchCleanTitle,
                text: uncommitted
                    ? strings.ghtCleanBody
                    : strings.ghtBranchCleanBody,
              ),
            ),
          ],
        ),
      );
    }
    final busy = controller.isBusy;
    final actionsOn = writes && uncommitted;
    final groups = uncommitted
        ? <(String, Key, List<GitReviewFile>, Widget?)>[
            (
              strings.ghtGroupStaged,
              const ValueKey('ght-group-staged'),
              controller.stagedFiles,
              actionsOn
                  ? _GroupAction(
                      key: const ValueKey('ght-unstage-all'),
                      label: strings.ghtUnstageAll,
                      onPressed: busy ? null : onUnstageAll,
                    )
                  : null,
            ),
            (
              strings.ghtGroupUnstaged,
              const ValueKey('ght-group-unstaged'),
              controller.unstagedFiles,
              actionsOn
                  ? _GroupAction(
                      key: const ValueKey('ght-stage-all'),
                      label: strings.ghtStageAll,
                      onPressed: busy ? null : onStageAll,
                    )
                  : null,
            ),
            (
              strings.ghtGroupUntracked,
              const ValueKey('ght-group-untracked'),
              controller.untrackedFiles,
              actionsOn && controller.unstagedFiles.isEmpty
                  ? _GroupAction(
                      key: const ValueKey('ght-stage-all-untracked'),
                      label: strings.ghtStageAll,
                      onPressed: busy ? null : onStageAll,
                    )
                  : null,
            ),
          ]
        : <(String, Key, List<GitReviewFile>, Widget?)>[
            (
              strings.ghtBranchScopeHint,
              const ValueKey('ght-group-branch'),
              controller.files,
              null,
            ),
          ];
    final rows = <Widget>[];
    var shown = 0;
    for (final (title, key, files, action) in groups) {
      final matching = files.where(_matches).toList(growable: false);
      if (matching.isEmpty) continue;
      shown += matching.length;
      rows.add(
        _GroupHeader(
          key: key,
          title: title,
          count: matching.length,
          action: action,
        ),
      );
      for (final file in matching) {
        rows.add(
          GitFileRow(
            file: file,
            onTap: () => onOpen(file),
            trailing: actionsOn
                ? HermesMenuButton<_FileAction>(
                    key: ValueKey('ght-file-menu-${file.path}'),
                    tooltip: strings.ghtFileActions,
                    iconColor: colors.textTertiary,
                    iconSize: HermesIcon.md,
                    surfaceKey: const ValueKey('ght-file-menu-surface'),
                    enabled: !busy,
                    actions: (_) => [
                      HermesAction(
                        value: _FileAction.diff,
                        label: strings.ghtViewDiff,
                        icon: Icons.difference_outlined,
                      ),
                      if (file.staged)
                        HermesAction(
                          key: ValueKey('ght-file-unstage-${file.path}'),
                          value: _FileAction.unstage,
                          label: strings.gitUnstage,
                          icon: Icons.remove_rounded,
                        )
                      else
                        HermesAction(
                          key: ValueKey('ght-file-stage-${file.path}'),
                          value: _FileAction.stage,
                          label: strings.gitStage,
                          icon: Icons.add_rounded,
                        ),
                      HermesAction(
                        key: ValueKey('ght-file-discard-${file.path}'),
                        value: _FileAction.discard,
                        label: strings.ghtDiscardFile,
                        icon: Icons.undo_rounded,
                        destructive: true,
                      ),
                    ],
                    onSelected: (action) {
                      switch (action) {
                        case _FileAction.diff:
                          onOpen(file);
                        case _FileAction.stage:
                        case _FileAction.unstage:
                          onToggleStaged(file);
                        case _FileAction.discard:
                          unawaited(onDiscard(file));
                      }
                    },
                  )
                : null,
          ),
        );
      }
    }
    if (shown == 0) {
      return ListView(
        key: const ValueKey('ght-no-matches'),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: HermesSpace.x6,
              vertical: HermesSpace.x8,
            ),
            child: Text(
              strings.ghtNoMatches,
              textAlign: TextAlign.center,
              style: HermesType.text.copyWith(color: colors.textTertiary),
            ),
          ),
        ],
      );
    }
    return RefreshIndicator(
      onRefresh: controller.refresh,
      child: GitFilesCard(
        child: ListView(
          key: const ValueKey('git-file-list'),
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(HermesSpace.x1 + 2),
          children: rows,
        ),
      ),
    );
  }
}

class _GroupAction extends StatelessWidget {
  const _GroupAction({super.key, required this.label, required this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: colors.accentText,
        minimumSize: const Size(HermesSpace.tap, HermesSpace.tap),
        textStyle: HermesType.value.copyWith(fontWeight: FontWeight.w600),
      ),
      child: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis),
    );
  }
}

/// «Preparados · 3» with its batch action at the end.
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    super.key,
    required this.title,
    required this.count,
    this.action,
  });

  final String title;
  final int count;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        HermesSpace.x3,
        HermesSpace.x2,
        HermesSpace.x1,
        0,
      ),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                '$title · $count',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: HermesType.sectionSize,
                  letterSpacing: HermesType.sectionTracking,
                  fontWeight: FontWeight.w700,
                  color: colors.textSecondary,
                ),
              ),
            ),
          ),
          if (action case final action?) Flexible(child: action),
        ],
      ),
    );
  }
}

/// The commit bar pinned at the bottom: the message with the commit
/// button, the options (push after the commit, the server's context) over
/// it when opened, the conflict line when there are any.
class _CommitBar extends StatelessWidget {
  const _CommitBar({
    required this.controller,
    required this.message,
    required this.options,
    required this.onToggleOptions,
    required this.pushAfterCommit,
    required this.onPushAfterCommit,
    required this.onCommit,
    this.onOpenTerminal,
  });

  final GitHubController controller;
  final TextEditingController message;
  final bool options;
  final VoidCallback onToggleOptions;
  final bool pushAfterCommit;
  final ValueChanged<bool> onPushAfterCommit;
  final VoidCallback onCommit;
  final VoidCallback? onOpenTerminal;

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final chrome = HermesChrome.of(colors);
    final conflicts = controller.conflicts;
    final detached = controller.status?.detached ?? false;
    final canCommit =
        !controller.commitBusy &&
        !controller.isBusy &&
        conflicts == 0 &&
        message.text.trim().isNotEmpty;
    final hint = HermesType.support.copyWith(color: colors.textTertiary);
    return DecoratedBox(
      key: const ValueKey('git-commit-bar'),
      decoration: BoxDecoration(
        color: ChatWorkspacePaneScope.backgroundOf(context, colors.background),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          HermesSpace.inset,
          0,
          HermesSpace.inset,
          HermesSpace.inset,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (conflicts > 0) ...[
              GitConflictLine(count: conflicts, onOpenTerminal: onOpenTerminal),
              const SizedBox(height: HermesSpace.x2),
            ],
            if (options) ...[
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * 0.4,
                ),
                child: SingleChildScrollView(
                  key: const ValueKey('ght-commit-options'),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Its own Material: the bar's page colour sits
                      // under it, and a list tile paints on the nearest
                      // Material.
                      Material(
                        type: MaterialType.transparency,
                        child: HermesSwitchTile(
                          controlKey: const ValueKey('ght-push-switch'),
                          title: strings.ghtCommitAndPush,
                          subtitle: strings.ghtPushUpstreamHint,
                          contentPadding: EdgeInsets.zero,
                          value: pushAfterCommit,
                          onChanged: detached || controller.commitBusy
                              ? null
                              : onPushAfterCommit,
                        ),
                      ),
                      Text(
                        controller.stagedCount == 0
                            ? strings.ghtCommitStagesAllHint
                            : '${strings.ghtGroupStaged} · '
                                  '${controller.stagedCount}',
                        key: const ValueKey('ght-commit-hint'),
                        style: hint,
                      ),
                      const SizedBox(height: HermesSpace.x2),
                      _CommitContextView(controller: controller),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: HermesSpace.x2),
            ],
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('git-commit-message'),
                    controller: message,
                    enabled: !controller.commitBusy,
                    minLines: 1,
                    maxLines: 4,
                    textCapitalization: TextCapitalization.sentences,
                    style: HermesType.text.copyWith(color: colors.textPrimary),
                    decoration: InputDecoration(
                      hintText: strings.gitCommitMessage,
                      hintStyle: TextStyle(color: chrome.mutedInk),
                      filled: true,
                      fillColor: chrome.opaque,
                      isDense: true,
                      constraints: const BoxConstraints(
                        minHeight: HermesSize.tap,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: HermesSpace.x4,
                        vertical: HermesSpace.x3 + 2,
                      ),
                      suffixIcon: IconButton(
                        key: const ValueKey('ght-commit-options-toggle'),
                        tooltip: strings.ghtCommitOptions,
                        isSelected: options,
                        onPressed: onToggleOptions,
                        icon: Icon(
                          options
                              ? Icons.expand_more_rounded
                              : Icons.tune_rounded,
                          size: HermesIcon.lg,
                          color: pushAfterCommit
                              ? colors.accentText
                              : colors.textSecondary,
                        ),
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(HermesSize.tap / 2),
                        borderSide: BorderSide(color: chrome.line),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(HermesSize.tap / 2),
                        borderSide: BorderSide(color: chrome.line),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: HermesSpace.x2),
                // Flexible: at large text the label wraps instead of
                // pushing past the edge of a narrow phone.
                Flexible(
                  child: GitPillButton(
                    key: const ValueKey('git-commit'),
                    label: pushAfterCommit
                        ? '${strings.gitCommit} ↑'
                        : strings.gitCommit,
                    primary: true,
                    onPressed: canCommit ? onCommit : null,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The server's commit context: recent subjects and the diff it would
/// commit, masked line by line, in the diff's mono.
class _CommitContextView extends StatelessWidget {
  const _CommitContextView({required this.controller});

  final GitHubController controller;

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final ctx = controller.commitContext;
    if (controller.commitContextLoading || ctx == null) {
      return const Padding(
        padding: EdgeInsets.all(HermesSpace.x3),
        child: Center(child: ConsoleLoader.small()),
      );
    }
    final title = HermesType.value.copyWith(
      fontWeight: FontWeight.w700,
      color: colors.textPrimary,
    );
    final mono = TextStyle(
      fontFamily: 'monospace',
      fontSize: HermesType.supportSize,
      height: 1.45,
      color: colors.textSecondary,
    );
    if (ctx.isEmpty) {
      return Text(
        strings.ghtCommitContextEmpty,
        key: const ValueKey('ght-context-empty'),
        style: HermesType.text.copyWith(color: colors.textTertiary),
      );
    }
    return Column(
      key: const ValueKey('ght-context'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Text(strings.ghtCommitContextTitle, style: title),
        ),
        if (ctx.recentSubjects.isNotEmpty) ...[
          const SizedBox(height: HermesSpace.x2),
          Text(
            strings.ghtCommitContextRecent,
            style: HermesType.support.copyWith(color: colors.textTertiary),
          ),
          for (final subject in ctx.recentSubjects)
            Padding(
              padding: const EdgeInsets.only(top: HermesSpace.x1),
              child: Text(
                '· $subject',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: HermesType.text.copyWith(color: colors.textSecondary),
              ),
            ),
        ],
        if (ctx.diffLines.isNotEmpty) ...[
          const SizedBox(height: HermesSpace.x3),
          Text(
            ctx.truncated
                ? '${strings.ghtCommitContextDiff} · '
                      '${strings.ghtCommitContextTruncated}'
                : strings.ghtCommitContextDiff,
            style: HermesType.support.copyWith(color: colors.textTertiary),
          ),
          const SizedBox(height: HermesSpace.x1),
          DecoratedBox(
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(HermesRadius.group),
              border: Border.all(color: colors.divider),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(HermesRadius.group),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.all(HermesSpace.x3),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final line in ctx.diffLines)
                      Text(
                        line,
                        maxLines: 1,
                        softWrap: false,
                        style: mono.copyWith(
                          color: line.startsWith('+')
                              ? colors.success
                              : line.startsWith('-')
                              ? colors.error
                              : colors.textSecondary,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// The ship page pushed from the row: push with its upstream note, the
/// branch's pull request, create-pr, the PRs of the local branches.
class _ShipScreen extends StatelessWidget {
  const _ShipScreen({
    required this.controller,
    required this.writes,
    required this.onPush,
    required this.onCreate,
    required this.onLoadList,
    required this.onOpenLink,
  });

  final GitHubController controller;
  final bool writes;
  final VoidCallback onPush;
  final VoidCallback onCreate;
  final VoidCallback onLoadList;
  final ValueChanged<String> onOpenLink;

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return Scaffold(
      key: const ValueKey('ght-ship-screen'),
      backgroundColor: ChatWorkspacePaneScope.backgroundOf(
        context,
        colors.background,
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                HermesSpace.x1,
                HermesSpace.x1,
                HermesSpace.x2,
                HermesSpace.x1,
              ),
              child: Row(
                children: [
                  IconButton(
                    key: const ValueKey('ght-ship-back'),
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).backButtonTooltip,
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: Icon(
                      Icons.arrow_back_rounded,
                      color: colors.textPrimary,
                    ),
                  ),
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text(
                        strings.ghtShipTitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: HermesType.title.copyWith(
                          color: colors.textPrimary,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListenableBuilder(
                listenable: controller,
                builder: (context, _) => _ShipPage(
                  controller: controller,
                  writes: writes,
                  onPush: onPush,
                  onCreate: onCreate,
                  onLoadList: onLoadList,
                  onOpenLink: onOpenLink,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Push, then the pull request blocks (ship-info, create-pr, pr-list).
class _ShipPage extends StatelessWidget {
  const _ShipPage({
    required this.controller,
    required this.writes,
    required this.onPush,
    required this.onCreate,
    required this.onLoadList,
    required this.onOpenLink,
  });

  final GitHubController controller;
  final bool writes;
  final VoidCallback onPush;
  final VoidCallback onCreate;
  final VoidCallback onLoadList;
  final ValueChanged<String> onOpenLink;

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final status = controller.status;
    final ship = controller.shipInfo;
    final auth = controller.ghAuth;
    final ghReady = ship?.ghReady ?? auth?.authenticated ?? false;
    final detached = status?.detached ?? false;
    final busy = controller.isBusy || controller.commitBusy;
    final title = HermesType.value.copyWith(
      fontWeight: FontWeight.w700,
      color: colors.textPrimary,
    );
    final body = HermesType.text.copyWith(color: colors.textSecondary);
    final hint = HermesType.support.copyWith(color: colors.textTertiary);
    final pr = ship?.pullRequest;
    final list = controller.pullRequests;
    final canPush = writes && !detached && !busy && (status?.ahead ?? 0) > 0;
    return ListView(
      key: const ValueKey('ght-ship-page'),
      padding: const EdgeInsets.fromLTRB(
        HermesSpace.x4,
        HermesSpace.x2,
        HermesSpace.x4,
        HermesSpace.pageBottom,
      ),
      children: [
        Semantics(header: true, child: Text(strings.ghtPush, style: title)),
        const SizedBox(height: HermesSpace.x1),
        Text(
          key: const ValueKey('ght-push-state'),
          detached
              ? strings.ghtDetachedNoPublish
              : (status?.ahead ?? 0) > 0
              ? strings.ghtPushAhead(status!.ahead)
              : strings.ghtPushNothing,
          style: body,
        ),
        if ((status?.behind ?? 0) > 0) ...[
          const SizedBox(height: HermesSpace.x1),
          Text(
            strings.ghtPushBehindHint(status!.behind),
            style: hint.copyWith(color: colors.warning),
          ),
        ],
        const SizedBox(height: HermesSpace.x1),
        Text(strings.ghtPushUpstreamHint, style: hint),
        if (writes) ...[
          const SizedBox(height: HermesSpace.x2),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: GitPillButton(
              key: const ValueKey('ght-push'),
              label: strings.ghtPush,
              primary: true,
              onPressed: canPush ? onPush : null,
            ),
          ),
        ],
        const SizedBox(height: HermesSpace.sectionTop),
        Semantics(header: true, child: Text(strings.ghtPrTitle, style: title)),
        const SizedBox(height: HermesSpace.x1),
        if (!ghReady && (auth != null || ship != null))
          Text(
            strings.ghtGhNotReady,
            key: const ValueKey('ght-gh-not-ready'),
            style: body.copyWith(color: colors.warning),
          )
        else if (pr != null)
          _PullRequestRow(
            key: const ValueKey('ght-pr-current'),
            number: pr.number,
            title: '',
            state: gitPrStateLabel(pr.state, false, strings),
            url: pr.url,
            onOpen: onOpenLink,
          )
        else if (ship != null)
          Text(
            strings.ghtPrNone,
            key: const ValueKey('ght-pr-none'),
            style: body,
          )
        else
          const Padding(
            padding: EdgeInsets.all(HermesSpace.x2),
            child: ConsoleLoader.small(),
          ),
        const SizedBox(height: HermesSpace.sectionTop),
        Semantics(header: true, child: Text(strings.ghtPrCreate, style: title)),
        const SizedBox(height: HermesSpace.x1),
        Text(strings.ghtPrCreateHint, style: hint),
        if (controller.defaultBase.isNotEmpty) ...[
          const SizedBox(height: HermesSpace.x1),
          Text(
            strings.ghtPrCreateBase(controller.defaultBase),
            key: const ValueKey('ght-pr-base'),
            style: body,
          ),
        ],
        if (detached) ...[
          const SizedBox(height: HermesSpace.x1),
          Text(strings.ghtDetachedNoPublish, style: body),
        ],
        if (writes) ...[
          const SizedBox(height: HermesSpace.x2),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: GitPillButton(
              key: const ValueKey('ght-pr-create'),
              label: strings.ghtPrCreate,
              onPressed: !busy && ghReady && !detached && pr == null
                  ? onCreate
                  : null,
            ),
          ),
        ],
        const SizedBox(height: HermesSpace.sectionTop),
        Semantics(
          header: true,
          child: Text(strings.ghtPrListTitle, style: title),
        ),
        const SizedBox(height: HermesSpace.x2),
        if (list == null)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: GitPillButton(
              key: const ValueKey('ght-pr-load'),
              label: strings.ghtPrListLoad,
              onPressed: busy ? null : onLoadList,
            ),
          )
        else if (controller.busy == GitHubBusy.pullRequests)
          const Padding(
            padding: EdgeInsets.all(HermesSpace.x2),
            child: ConsoleLoader.small(),
          )
        else if (!list.ghReady)
          Text(
            strings.ghtGhNotReady,
            key: const ValueKey('ght-pr-list-not-ready'),
            style: body.copyWith(color: colors.warning),
          )
        else if (list.prs.isEmpty)
          Text(
            strings.ghtPrListEmpty,
            key: const ValueKey('ght-pr-list-empty'),
            style: body,
          )
        else
          for (final item in list.prs)
            _PullRequestRow(
              key: ValueKey('ght-pr-${item.number}'),
              number: item.number,
              title: item.title,
              branch: item.branch,
              state: gitPrStateLabel(item.state, item.draft, strings),
              url: item.url,
              onOpen: onOpenLink,
            ),
      ],
    );
  }
}

/// «#12 · Abierta», its title and branch, and «Abrir en el navegador».
class _PullRequestRow extends StatelessWidget {
  const _PullRequestRow({
    super.key,
    required this.number,
    required this.title,
    required this.state,
    required this.url,
    required this.onOpen,
    this.branch = '',
  });

  final int number;
  final String title;
  final String branch;
  final String state;
  final String url;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final safeTitle = gitSafeText(title);
    final safeUrl = gitSafeText(url);
    final canOpen = gitSafeHttpsUrl(url) != null;
    return Padding(
      padding: const EdgeInsets.only(bottom: HermesSpace.x3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  number > 0
                      ? '${strings.ghtPrNumber(number)} · $state'
                      : state,
                  style: HermesType.value.copyWith(
                    fontWeight: FontWeight.w700,
                    color: colors.textPrimary,
                  ),
                ),
                if (safeTitle.isNotEmpty)
                  Text(
                    safeTitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: HermesType.text.copyWith(color: colors.textPrimary),
                  ),
                Text(
                  branch.isNotEmpty ? '$branch · $safeUrl' : safeUrl,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: HermesType.support.copyWith(
                    color: colors.textTertiary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: HermesSpace.x2),
          IconButton(
            key: const ValueKey('ght-pr-open'),
            tooltip: strings.ghtPrOpenLink,
            onPressed: canOpen ? () => onOpen(url) : null,
            icon: Icon(
              Icons.open_in_new_rounded,
              size: HermesIcon.md,
              color: canOpen ? colors.accentText : colors.textDisabled,
            ),
          ),
        ],
      ),
    );
  }
}
