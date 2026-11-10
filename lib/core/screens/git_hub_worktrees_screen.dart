import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
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
import '../models/git_hub.dart';
import '../models/git_review.dart';
import '../services/git_hub_controller.dart';
import '../theme/app_theme.dart';
import '../theme/hermes_tokens.dart' show HermesIcon, HermesSize;
import '../utils/short_server_path.dart';
import '../widgets/console_loader.dart';
import '../widgets/hermes_premium_ui.dart' show showHermesConfirmDialog;
import '../widgets/projects/project_actions.dart' show isValidGitRef;
import '../widgets/workspace/chat_workspace_host.dart'
    show ChatWorkspacePaneScope;
import 'git_review_screen.dart'
    show GitPillButton, GitStateMessage, gitFailureText;

/// The repository's worktrees (`git worktree list`): each with its branch
/// and flags, «Abrir Git aquí», and for the ones that are not the main
/// tree «Quitar» behind a strong confirmation (a second one to force
/// when the tree has changes). «Añadir» creates a branch in a new tree.
class GitWorktreesScreen extends StatefulWidget {
  const GitWorktreesScreen({
    super.key,
    required this.controller,
    required this.writes,
    required this.onOpen,
    required this.unlock,
    required this.onFailure,
  });

  final GitHubController controller;
  final bool writes;

  /// Opens the hub at a worktree's folder.
  final ValueChanged<String> onOpen;

  /// App Lock before a removal; true when the app has no lock.
  final Future<bool> Function(String reason) unlock;
  final ValueChanged<Object> onFailure;

  @override
  State<GitWorktreesScreen> createState() => _GitWorktreesScreenState();
}

enum _WorktreeAction { open, remove }

class _GitWorktreesScreenState extends State<GitWorktreesScreen> {
  bool _loading = true;
  Object? _failure;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load());
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failure = null;
    });
    try {
      await widget.controller.loadWorktrees();
    } catch (error) {
      if (mounted) setState(() => _failure = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _remove(GitWorktree tree) async {
    final strings = Strings.of(context);
    final sink = AppFeedback.of(context);
    final shown = shortServerPath(tree.path);
    final ok = await showHermesConfirmDialog(
      context: context,
      title: strings.ghtWorktreeRemoveTitle,
      message: strings.ghtWorktreeRemoveBody(shown),
      confirmLabel: strings.ghtRemoveAction,
      cancelLabel: strings.commonCancel,
      destructive: true,
    );
    if (!ok || !mounted) return;
    if (!await widget.unlock(strings.ghtLockReasonWorktree) || !mounted) {
      return;
    }
    try {
      await widget.controller.removeWorktree(tree.path);
    } on GitActionFailure catch (failure) {
      if (failure.problem != GitActionProblem.localChanges || !mounted) {
        widget.onFailure(failure);
        return;
      }
      final force = await showHermesConfirmDialog(
        context: context,
        title: strings.ghtWorktreeRemoveForceTitle,
        message: strings.ghtWorktreeRemoveForceBody(shown),
        confirmLabel: strings.ghtWorktreeRemoveForce,
        cancelLabel: strings.commonCancel,
        destructive: true,
      );
      if (!force || !mounted) return;
      try {
        await widget.controller.removeWorktree(tree.path, force: true);
      } catch (error) {
        widget.onFailure(error);
        return;
      }
    } catch (error) {
      widget.onFailure(error);
      return;
    }
    sink.notify(FeedbackKind.routine, strings.ghtWorktreeRemoved);
  }

  Future<void> _add() async {
    final controller = widget.controller;
    final strings = Strings.of(context);
    final sink = AppFeedback.of(context);
    try {
      await controller.loadBaseBranches();
    } catch (_) {
      // Without the list the server branches from HEAD.
    }
    if (!mounted) return;
    final name = TextEditingController();
    var base = controller.defaultBase;
    final create = await showHermesFormDialog<bool>(
      context: context,
      title: strings.ghtWorktreeAdd,
      message: strings.ghtBranchNewHint,
      surfaceKey: const ValueKey('ght-worktree-add-dialog'),
      enabled: (value) => !value || isValidGitRef(name.text.trim()),
      actions: [
        HermesDialogAction(
          label: strings.commonCancel,
          value: false,
          style: HermesDialogActionStyle.cancel,
        ),
        HermesDialogAction(
          key: const ValueKey('ght-worktree-add-create'),
          label: strings.ghtBranchNewCreate,
          value: true,
        ),
      ],
      body: (dialogContext, setState) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const ValueKey('ght-worktree-add-name'),
            controller: name,
            autofocus: true,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(labelText: strings.ghtBranchNewName),
          ),
          if (controller.baseBranches.isNotEmpty) ...[
            const SizedBox(height: HermesSpace.x3),
            OutlinedButton.icon(
              key: const ValueKey('ght-worktree-add-base'),
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
      sink.notify(
        FeedbackKind.routine,
        strings.ghtWorktreeCreated(shortServerPath(result.path)),
      );
    } catch (error) {
      widget.onFailure(error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final controller = widget.controller;
    final trees = controller.worktrees;
    return Scaffold(
      key: const ValueKey('ght-worktrees-screen'),
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
                    key: const ValueKey('ght-worktrees-back'),
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
                        strings.ghtWorktrees,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: HermesType.title.copyWith(
                          color: colors.textPrimary,
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('ght-worktrees-refresh'),
                    tooltip: strings.gitRefresh,
                    onPressed: _loading ? null : _load,
                    icon: Icon(
                      Icons.refresh_rounded,
                      color: colors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _loading && trees.isEmpty
                  ? const Center(child: ConsoleLoader.medium())
                  : _failure != null && trees.isEmpty
                  ? GitStateMessage(
                      key: const ValueKey('ght-worktrees-failed'),
                      text: gitFailureText(_failure!, strings),
                      onRetry: _load,
                    )
                  : ListView(
                      key: const ValueKey('ght-worktrees-list'),
                      padding: const EdgeInsets.fromLTRB(
                        HermesSpace.inset,
                        0,
                        HermesSpace.inset,
                        HermesSpace.pageBottom,
                      ),
                      children: [
                        if (trees.length <= 1)
                          Padding(
                            padding: const EdgeInsets.all(HermesSpace.x3),
                            child: Text(
                              strings.ghtWorktreeNone,
                              key: const ValueKey('ght-worktrees-none'),
                              textAlign: TextAlign.center,
                              style: HermesType.text.copyWith(
                                color: colors.textTertiary,
                              ),
                            ),
                          ),
                        for (final tree in trees)
                          _WorktreeRow(
                            tree: tree,
                            current: tree.path == controller.repoPath,
                            writes: widget.writes,
                            busy: controller.isBusy,
                            onAction: (action) {
                              switch (action) {
                                case _WorktreeAction.open:
                                  widget.onOpen(tree.path);
                                case _WorktreeAction.remove:
                                  unawaited(_remove(tree));
                              }
                            },
                          ),
                        if (widget.writes) ...[
                          const SizedBox(height: HermesSpace.x3),
                          Align(
                            alignment: AlignmentDirectional.centerStart,
                            child: GitPillButton(
                              key: const ValueKey('ght-worktree-add'),
                              label: strings.ghtWorktreeAdd,
                              primary: true,
                              onPressed: controller.isBusy ? null : _add,
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

/// One worktree: its folder, branch and flags, with open and remove.
class _WorktreeRow extends StatelessWidget {
  const _WorktreeRow({
    required this.tree,
    required this.current,
    required this.writes,
    required this.busy,
    required this.onAction,
  });

  final GitWorktree tree;
  final bool current;
  final bool writes;
  final bool busy;
  final ValueChanged<_WorktreeAction> onAction;

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final flags = <String>[
      if (tree.isMain) strings.ghtWorktreeMain,
      if (tree.detached) strings.ghtWorktreeDetached else tree.branch,
      if (tree.locked) strings.ghtWorktreeLocked,
    ].where((f) => f.isNotEmpty).join(' · ');
    return InkWell(
      key: ValueKey('ght-worktree-${tree.path}'),
      borderRadius: BorderRadius.circular(HermesRadius.row),
      onTap: current ? null : () => onAction(_WorktreeAction.open),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: HermesSize.tap),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: HermesSpace.x2 + 2,
            vertical: HermesSpace.x2,
          ),
          child: Row(
            children: [
              Icon(
                tree.isMain ? Icons.home_outlined : Icons.account_tree_outlined,
                size: HermesIcon.lg,
                color: current ? colors.accentText : colors.textSecondary,
              ),
              const SizedBox(width: HermesSpace.gap),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      shortServerPath(tree.path),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: HermesType.value.copyWith(
                        fontWeight: FontWeight.w600,
                        color: colors.textPrimary,
                      ),
                    ),
                    if (flags.isNotEmpty)
                      Text(
                        flags,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: HermesType.support.copyWith(
                          color: colors.textTertiary,
                        ),
                      ),
                  ],
                ),
              ),
              HermesMenuButton<_WorktreeAction>(
                key: ValueKey('ght-worktree-menu-${tree.path}'),
                tooltip: strings.ghtMore,
                iconColor: colors.textTertiary,
                iconSize: HermesIcon.md,
                surfaceKey: const ValueKey('ght-worktree-menu-surface'),
                enabled: !busy,
                actions: (_) => [
                  if (!current)
                    HermesAction(
                      key: ValueKey('ght-worktree-open-${tree.path}'),
                      value: _WorktreeAction.open,
                      label: strings.ghtWorktreeOpen,
                      icon: Icons.open_in_new_rounded,
                    ),
                  if (writes && !tree.isMain && !current)
                    HermesAction(
                      key: ValueKey('ght-worktree-remove-${tree.path}'),
                      value: _WorktreeAction.remove,
                      label: strings.ghtWorktreeRemove,
                      icon: Icons.delete_outline_rounded,
                      destructive: true,
                    ),
                ],
                onSelected: onAction,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
