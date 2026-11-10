import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../design/tokens.dart';
import '../feedback/feedback_policy.dart';
import '../models/git_review.dart';
import '../services/desktop_control_gateway.dart';
import '../services/git_review_controller.dart';
import '../services/git_review_gateway.dart';
import '../theme/app_theme.dart';
import '../theme/hermes_tokens.dart' show HermesIcon, HermesSize;
import '../theme/readable_ink.dart';
import '../theme/text_scale.dart';
import '../design/modal.dart' show HermesAction, HermesMenuButton;
import '../widgets/console_loader.dart';
import '../widgets/hermes_notice.dart' show HermesNoticeAction;
import '../widgets/workspace/chat_workspace_host.dart'
    show ChatWorkspacePaneScope;

/// Localized text for a failed git read or action. The server's own text
/// (git's stderr) never reaches the screen.
String gitFailureText(Object failure, Strings strings) {
  if (failure is GitActionFailure) {
    return switch (failure.problem) {
      GitActionProblem.conflict => strings.gitProblemConflict,
      GitActionProblem.noIdentity => strings.gitProblemNoIdentity,
      GitActionProblem.nothingToCommit => strings.gitNoDiffs,
      GitActionProblem.pushRejected => strings.ghtProblemPushRejected,
      GitActionProblem.remoteAuth => strings.ghtProblemRemoteAuth,
      GitActionProblem.remoteUnreachable => strings.ghtProblemRemoteUnreachable,
      GitActionProblem.noRemote => strings.ghtProblemNoRemote,
      GitActionProblem.ghNotReady => strings.ghtProblemGhNotReady,
      GitActionProblem.prExists => strings.ghtProblemPrExists,
      GitActionProblem.prNoCommits => strings.ghtProblemPrNoCommits,
      GitActionProblem.localChanges => strings.ghtProblemLocalChanges,
      GitActionProblem.branchNotFound => strings.ghtProblemBranchNotFound,
    };
  }
  if (failure is DesktopControlFailure) {
    return switch (failure.kind) {
      DesktopControlFailureKind.unsupported => strings.gitFailureUnsupported,
      DesktopControlFailureKind.forbidden => strings.gitFailureForbidden,
      DesktopControlFailureKind.unavailable =>
        strings.projectsCenterFailureUnavailable,
      DesktopControlFailureKind.rejected => strings.gitFailureRejected,
      DesktopControlFailureKind.invalidResponse => strings.gitFailureUnknown,
    };
  }
  return strings.gitFailureUnknown;
}

/// Failures only fixed by hand on the server: the notice offers Terminal.
bool gitFailureNeedsTerminal(Object failure) =>
    failure is GitActionFailure &&
    switch (failure.problem) {
      GitActionProblem.conflict ||
      GitActionProblem.noIdentity ||
      GitActionProblem.remoteAuth ||
      GitActionProblem.ghNotReady ||
      GitActionProblem.pushRejected => true,
      _ => false,
    };

/// Git for the conversation's folder, as Hermes Desktop's review pane
/// (uncommitted scope) laid out for a narrow screen: a one-line header with
/// the branch and its counts, the changed files, each file's diff full
/// screen, and the commit bar pinned at the bottom.
///
/// Everything goes through the Dashboard `/api/git/*` routes Desktop uses on
/// a remote gateway; the server runs git.
class GitReviewScreen extends StatefulWidget {
  const GitReviewScreen({
    super.key,
    required this.gateway,
    required this.connectionId,
    required this.repoPath,
    this.onOpenTerminal,
  });

  final HermesGitReviewGateway gateway;
  final String connectionId;

  /// The conversation's working folder (Desktop's `$currentCwd`).
  final String repoPath;

  /// Opens the instance's terminal on top (conflicts and a missing author
  /// identity are fixed there). Null when the instance has none.
  final VoidCallback? onOpenTerminal;

  @override
  State<GitReviewScreen> createState() => _GitReviewScreenState();
}

class _GitReviewScreenState extends State<GitReviewScreen> {
  late final GitReviewController _controller = GitReviewController(
    gateway: widget.gateway,
    connectionId: widget.connectionId,
    repoPath: widget.repoPath,
  );
  final TextEditingController _message = TextEditingController();

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
    _message.addListener(_onChanged);
    // After the first frame: a read notifies at once, and setState is not
    // allowed inside initState.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_controller.refresh());
    });
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    _message.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _refresh() => _controller.refresh();

  /// Captured before a commit starts: it may still fail after the user left
  /// the screen (hooks run on the server), and the app's notice lane
  /// outlives it (Desktop's notifyError is global too).
  ({FeedbackSink sink, Strings strings}) _failureLane() =>
      (sink: AppFeedback.of(context), strings: Strings.of(context));

  void _notifyFailure(
    Object error, [
    ({FeedbackSink sink, Strings strings})? lane,
  ]) {
    if (lane == null && !mounted) return;
    final target = lane ?? _failureLane();
    final strings = target.strings;
    final terminal = mounted ? widget.onOpenTerminal : null;
    target.sink.notify(
      FeedbackKind.error,
      gitFailureText(error, strings),
      action: terminal != null && gitFailureNeedsTerminal(error)
          ? HermesNoticeAction(
              label: strings.chaControlTerminal,
              onPressed: terminal,
            )
          : null,
    );
  }

  Future<void> _commit() async {
    final lane = _failureLane();
    try {
      final done = await _controller.commit(_message.text);
      if (done && mounted) _message.clear();
    } catch (error) {
      _notifyFailure(error, lane);
    }
  }

  Future<void> _openFile(GitReviewFile file) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => GitDiffScreen(controller: _controller, file: file),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final controller = _controller;
    final showBar =
        controller.phase == GitReviewPhase.ready &&
        controller.hasFiles &&
        controller.writesAllowed;
    return Scaffold(
      key: const ValueKey('git-review-screen'),
      // In the pane the pane's own surface shows (audit T1).
      backgroundColor: ChatWorkspacePaneScope.backgroundOf(
        context,
        colors.background,
      ),
      body: SafeArea(
        child: Column(
          children: [
            _GitHeader(
              status: controller.status,
              onRefresh: controller.loading ? null : _refresh,
            ),
            Expanded(child: _body(context)),
            if (showBar)
              _GitCommitBar(
                message: _message,
                conflicts: controller.conflicts,
                onOpenTerminal: widget.onOpenTerminal,
                busy: controller.commitBusy,
                onCommit: _commit,
              ),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final strings = Strings.of(context);
    final controller = _controller;
    switch (controller.phase) {
      case GitReviewPhase.loading:
        return const Center(child: ConsoleLoader.medium());
      case GitReviewPhase.notRepo:
        return GitStateMessage(
          key: const ValueKey('git-state-not-repo'),
          text: strings.gitNotRepo,
          onRetry: controller.refresh,
        );
      case GitReviewPhase.unsupported:
        return GitStateMessage(
          key: const ValueKey('git-state-unsupported'),
          text: strings.gitFailureUnsupported,
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
    return RefreshIndicator(
      onRefresh: controller.refresh,
      child: controller.hasFiles
          ? GitFilesCard(
              child: ListView.builder(
                key: const ValueKey('git-file-list'),
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(HermesSpace.x1 + 2),
                itemCount: controller.files.length,
                itemBuilder: (context, index) {
                  final file = controller.files[index];
                  return GitFileRow(file: file, onTap: () => _openFile(file));
                },
              ),
            )
          : ListView(
              key: const ValueKey('git-state-no-diffs'),
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: HermesSpace.x6,
                    vertical: HermesSpace.x8,
                  ),
                  child: Text(
                    strings.gitNoDiffs,
                    textAlign: TextAlign.center,
                    style: HermesType.text.copyWith(
                      color: Theme.of(context).hermes.textTertiary,
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

/// `+A −R` in green and red, tabular figures. Nothing when both are zero;
/// a zero side is left out (Desktop's `DiffCount`).
class GitDiffCount extends StatelessWidget {
  const GitDiffCount({
    super.key,
    required this.added,
    required this.removed,
    this.fontSize = 13,
  });

  final int added;
  final int removed;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    if (added <= 0 && removed <= 0) return const SizedBox.shrink();
    final colors = Theme.of(context).hermes;
    TextStyle style(Color color) => TextStyle(
      fontSize: fontSize,
      fontWeight: FontWeight.w600,
      // The bundled mono (audit T5), never the platform's.
      fontFamily: HermesType.monoFamily,
      fontFeatures: const [FontFeature.tabularFigures()],
      color: color,
    );
    final plus = '+$added';
    final minus = '−$removed';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (added > 0) Text(plus, style: style(colors.success)),
        if (added > 0 && removed > 0) const SizedBox(width: HermesSpace.x1),
        if (removed > 0) Text(minus, style: style(colors.error)),
      ],
    );
  }
}

/// Glyph and tone per git status letter (Desktop's `STATUS_GLYPH`, on the
/// app's tokens).
/// What a screen reader says for a status letter (Desktop shows only the
/// glyph; the app names it so a deletion is not told by colour alone).
String gitStatusLabel(String status, Strings strings) => switch (status) {
  'A' => strings.gitStatusAdded,
  'C' => strings.gitStatusCopied,
  'D' => strings.gitStatusDeleted,
  'R' => strings.gitStatusRenamed,
  'U' => strings.gitStatusConflicted,
  '?' => strings.gitStatusUntracked,
  _ => strings.gitStatusModified,
};

(IconData, Color) gitStatusGlyph(String status, HermesThemeColors colors) =>
    switch (status) {
      'A' || 'C' => (Icons.add_box_outlined, colors.success),
      'D' => (Icons.indeterminate_check_box_outlined, colors.error),
      'R' => (Icons.drive_file_rename_outline, colors.accentText),
      'U' => (Icons.warning_amber_rounded, colors.error),
      '?' => (Icons.add_box_outlined, colors.textTertiary),
      _ => (Icons.edit_outlined, colors.warning),
    };

/// One line: back, the branch pill, Desktop's coding-row counts (↑ahead
/// ↓behind, `+A −R` or «N cambios») and the refresh button.
class _GitHeader extends StatelessWidget {
  const _GitHeader({required this.status, required this.onRefresh});

  final GitRepoStatus? status;

  /// Desktop's refresh button (pull to refresh has no reliable action for
  /// a screen reader); null while a read is running.
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final status = this.status;
    final countStyle = TextStyle(
      fontSize: 13,
      fontFeatures: const [FontFeature.tabularFigures()],
      color: colors.textSecondary,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        HermesSpace.x1,
        HermesSpace.x1,
        HermesSpace.x2,
        HermesSpace.x1,
      ),
      child: Row(
        children: [
          // In the workspace pane Git is its tab's first page: there is
          // nothing to go back to, so no dead arrow for TalkBack to offer
          // (Archivos does the same without a way back to the chat).
          if (Navigator.of(context).canPop())
            IconButton(
              key: const ValueKey('git-back'),
              tooltip: MaterialLocalizations.of(context).backButtonTooltip,
              onPressed: () => Navigator.of(context).maybePop(),
              icon: Icon(Icons.arrow_back_rounded, color: colors.textPrimary),
            )
          else
            const SizedBox(width: HermesSpace.x3),
          // The branch and its counts take the free width; the actions keep
          // theirs (a Spacer would halve what a long branch name gets).
          // The branch and its counts share the free width, half each at
          // most: the pill always keeps room for its icon and a few letters,
          // and the counts scale down instead of pushing past the edge at
          // large text.
          Expanded(
            child: Row(
              children: [
                if (status != null) ...[
                  Flexible(
                    child: GitBranchPill(
                      label: status.detached
                          ? strings.gitDetached
                          : status.branch ?? strings.gitNoBranch,
                    ),
                  ),
                  const SizedBox(width: HermesSpace.x2),
                  Flexible(
                    child: FittedBox(
                      key: const ValueKey('git-header-counts'),
                      fit: BoxFit.scaleDown,
                      alignment: AlignmentDirectional.centerStart,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (status.ahead > 0)
                            Semantics(
                              label: strings.gitAhead(status.ahead),
                              child: ExcludeSemantics(
                                child: Text(
                                  '↑${status.ahead}',
                                  style: countStyle,
                                ),
                              ),
                            ),
                          if (status.ahead > 0)
                            const SizedBox(width: HermesSpace.x1),
                          if (status.behind > 0)
                            Semantics(
                              label: strings.gitBehind(status.behind),
                              child: ExcludeSemantics(
                                child: Text(
                                  '↓${status.behind}',
                                  style: countStyle,
                                ),
                              ),
                            ),
                          if (status.behind > 0)
                            const SizedBox(width: HermesSpace.x2),
                          if (status.hasLineDelta)
                            GitDiffCount(
                              added: status.added,
                              removed: status.removed,
                            )
                          else if (status.untrackedOnly)
                            Text(
                              strings.gitChanged(status.untracked),
                              maxLines: 1,
                              style: countStyle.copyWith(color: colors.warning),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            key: const ValueKey('git-refresh'),
            tooltip: strings.gitRefresh,
            onPressed: onRefresh,
            icon: Icon(Icons.refresh_rounded, color: colors.textSecondary),
          ),
        ],
      ),
    );
  }
}

class GitBranchPill extends StatelessWidget {
  const GitBranchPill({super.key, required this.label, this.onTap, this.hint});

  final String label;

  /// Set, the pill is a button (the hub's branch picker) and says [hint].
  final VoidCallback? onTap;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final tint = colors.accent.withValues(alpha: 0.16);
    // Ola 8: accentText alone fell to 3.9-4.3:1 on this tint.
    final ink = readableInkOnTint(colors.accentText, tint, colors);
    final onTap = this.onTap;
    final pill = Container(
      key: const ValueKey('git-branch'),
      constraints: onTap == null
          ? null
          : const BoxConstraints(minHeight: HermesSize.tap),
      padding: const EdgeInsets.symmetric(
        horizontal: HermesSpace.x3,
        vertical: 6,
      ),
      decoration: BoxDecoration(
        color: tint,
        borderRadius: BorderRadius.circular(HermesRadius.tag),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.call_split_rounded, size: 16, color: colors.accentText),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              // Ola 8: a long branch wraps once the text is enlarged.
              maxLines: labelMaxLines(context),
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: ink,
              ),
            ),
          ),
          if (onTap != null) ...[
            const SizedBox(width: HermesSpace.x1),
            Icon(Icons.expand_more_rounded, size: 16, color: ink),
          ],
        ],
      ),
    );
    if (onTap == null) return pill;
    return Semantics(
      button: true,
      label: hint,
      child: InkWell(
        key: const ValueKey('ght-branch-button'),
        borderRadius: BorderRadius.circular(HermesRadius.tag),
        onTap: onTap,
        child: pill,
      ),
    );
  }
}

/// The changed files in a rounded card with its inset margin (mock 136
/// v2-A `.cardin`, Cadu), as Files.
class GitFilesCard extends StatelessWidget {
  const GitFilesCard({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final radius = BorderRadius.circular(HermesRadius.card);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        HermesSpace.inset,
        HermesSpace.x1,
        HermesSpace.inset,
        HermesSpace.x2,
      ),
      child: DecoratedBox(
        key: const ValueKey('git-files-card'),
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          borderRadius: radius,
          border: Border.all(color: HermesChrome.of(colors).line),
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: ColoredBox(color: HermesSurfaces.group(colors), child: child),
        ),
      ),
    );
  }
}

/// One changed file (v2-A `.frow`): its status glyph in a 32 dp box, the
/// name 13/600 with its folder under it, `+A −R` in mono, radius 16 and
/// 48 dp to touch.
class GitFileRow extends StatelessWidget {
  const GitFileRow({
    super.key,
    required this.file,
    required this.onTap,
    this.trailing,
  });

  final GitReviewFile file;
  final VoidCallback onTap;

  /// Takes the chevron's place (the hub's per-file actions).
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final (glyph, tone) = gitStatusGlyph(file.status, colors);
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: InkWell(
        key: ValueKey('git-file-${file.path}'),
        borderRadius: BorderRadius.circular(HermesRadius.row),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: HermesSize.tap),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: HermesSpace.x2 + 2,
              vertical: HermesSpace.x2,
            ),
            child: Row(
              children: [
                Semantics(
                  label: gitStatusLabel(file.status, strings),
                  child: Container(
                    key: ValueKey('git-file-icon-${file.path}'),
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: HermesChrome.of(colors).opaque,
                      borderRadius: BorderRadius.circular(HermesRadius.control),
                    ),
                    child: Icon(glyph, size: HermesIcon.sm, color: tone),
                  ),
                ),
                const SizedBox(width: HermesSpace.gap),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        file.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HermesType.value.copyWith(
                          fontWeight: FontWeight.w600,
                          color: colors.textPrimary,
                        ),
                      ),
                      if (file.directory.isNotEmpty)
                        Text(
                          file.directory,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: HermesType.support.copyWith(
                            color: colors.textTertiary,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: HermesSpace.x2),
                GitDiffCount(added: file.added, removed: file.removed),
                if (file.staged) ...[
                  const SizedBox(width: HermesSpace.x2),
                  Semantics(
                    label: strings.gitStaged,
                    child: Container(
                      key: ValueKey('git-staged-${file.path}'),
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: colors.success.withValues(alpha: 0.7),
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ],
                const SizedBox(width: HermesSpace.x1),
                trailing ??
                    Icon(
                      Icons.chevron_right_rounded,
                      size: HermesIcon.md,
                      color: colors.textTertiary,
                    ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A short state line with an optional retry.
class GitStateMessage extends StatelessWidget {
  const GitStateMessage({
    super.key,
    required this.text,
    this.onRetry,
    this.icon,
    this.title,
  });

  final String text;
  final Future<void> Function()? onRetry;

  /// An empty state's glyph and headline over [text] (the panel's «No es
  /// un repositorio Git»).
  final IconData? icon;
  final String? title;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final onRetry = this.onRetry;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(HermesSpace.x6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: HermesIcon.xl, color: colors.textTertiary),
              const SizedBox(height: HermesSpace.x4),
            ],
            if (title != null) ...[
              Semantics(
                header: true,
                child: Text(
                  title!,
                  textAlign: TextAlign.center,
                  style: HermesType.title.copyWith(color: colors.textPrimary),
                ),
              ),
              const SizedBox(height: HermesSpace.x2),
            ],
            Text(
              text,
              textAlign: TextAlign.center,
              style: HermesType.text.copyWith(color: colors.textSecondary),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: HermesSpace.x4),
              GitPillButton(
                key: const ValueKey('git-retry'),
                label: Strings.of(context).commonRetry,
                onPressed: onRetry,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The mock's pill buttons: filled accent for the main action, outlined for
/// the other. 48 dp tall.
class GitPillButton extends StatelessWidget {
  const GitPillButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.primary = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    // v2-A `.pb`: 13/600.
    final style = HermesType.value.copyWith(fontWeight: FontWeight.w600);
    const padding = EdgeInsets.symmetric(horizontal: HermesSpace.x5);
    const minimum = Size(HermesSpace.tap, HermesSpace.tap);
    final text = Text(
      label,
      maxLines: 2,
      textAlign: TextAlign.center,
      overflow: TextOverflow.ellipsis,
    );
    if (primary) {
      return FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: colors.accent,
          foregroundColor: colors.onAccent,
          disabledBackgroundColor: colors.surfaceVariant,
          disabledForegroundColor: colors.textTertiary,
          shape: const StadiumBorder(),
          minimumSize: minimum,
          padding: padding,
          textStyle: style,
        ),
        child: text,
      );
    }
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: colors.textPrimary,
        disabledForegroundColor: colors.textTertiary,
        side: BorderSide(color: HermesChrome.of(colors).line),
        shape: const StadiumBorder(),
        minimumSize: minimum,
        padding: padding,
        textStyle: style,
      ),
      child: text,
    );
  }
}

/// Desktop's commit field and button for a narrow screen. Shown only while
/// there are changes, like Desktop.
class _GitCommitBar extends StatelessWidget {
  const _GitCommitBar({
    required this.message,
    required this.conflicts,
    required this.onOpenTerminal,
    required this.busy,
    required this.onCommit,
  });

  final TextEditingController message;

  /// Unresolved conflicts: commit is off and the bar says so.
  final int conflicts;
  final VoidCallback? onOpenTerminal;
  final bool busy;
  final VoidCallback onCommit;

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final canCommit = !busy && conflicts == 0 && message.text.trim().isNotEmpty;
    final chrome = HermesChrome.of(colors);
    // Mock 136 v2-A `.pillbar` (Cadu): no band and no rule over it, the
    // message in a pill with the commit button beside it. The page under it
    // is the screen's own (the pane's surface shows in the pane).
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
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('git-commit-message'),
                    controller: message,
                    enabled: !busy,
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
                      // A pill at one line (48 dp, half of it); with more
                      // lines (up to 4) a card with 24 dp corners, never a
                      // tall capsule whose ends clip the text.
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
                GitPillButton(
                  key: const ValueKey('git-commit'),
                  label: strings.gitCommit,
                  primary: true,
                  onPressed: canCommit ? onCommit : null,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// «N conflictos sin resolver», in the warning tone, with Terminal when the
/// instance has one.
class GitConflictLine extends StatelessWidget {
  const GitConflictLine({super.key, required this.count, this.onOpenTerminal});

  final int count;
  final VoidCallback? onOpenTerminal;

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final onOpenTerminal = this.onOpenTerminal;
    return Row(
      key: const ValueKey('git-conflicts'),
      children: [
        Icon(Icons.warning_amber_rounded, size: 18, color: colors.warning),
        const SizedBox(width: HermesSpace.x2),
        Expanded(
          child: Text(
            strings.gitConflicts(count),
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: colors.textPrimary,
            ),
          ),
        ),
        if (onOpenTerminal != null)
          TextButton(
            key: const ValueKey('git-open-terminal'),
            onPressed: onOpenTerminal,
            style: TextButton.styleFrom(
              foregroundColor: colors.accentText,
              minimumSize: const Size(HermesSpace.tap, HermesSpace.tap),
            ),
            child: Text(strings.chaControlTerminal),
          ),
      ],
    );
  }
}

enum _GitDiffAction { discard }

/// One file's diff, full screen with a back button (the mock's 3b): the
/// header carries the name, its `+A −R` and Desktop's stage / unstage.
class GitDiffScreen extends StatefulWidget {
  const GitDiffScreen({
    super.key,
    required this.controller,
    required this.file,
    this.onDiscard,
  });

  final GitReviewController controller;
  final GitReviewFile file;

  /// The hub's «Descartar cambios» for this file (it confirms and runs
  /// the revert; the diff then leaves). Null hides the action.
  final Future<bool> Function(GitReviewFile file)? onDiscard;

  @override
  State<GitDiffScreen> createState() => _GitDiffScreenState();
}

class _GitDiffScreenState extends State<GitDiffScreen> {
  late GitReviewFile _file = widget.file;
  late Future<GitReviewDiff> _diff = widget.controller.diffOf(_file);
  bool _staging = false;

  void _reload() {
    setState(() => _diff = widget.controller.diffOf(_file));
  }

  Future<void> _toggleStaged() async {
    // Captured now: a refusal that lands after the user left the diff is
    // still said (like a failed commit), on the app's notice lane.
    final feedback = AppFeedback.of(context);
    final strings = Strings.of(context);
    setState(() => _staging = true);
    try {
      await widget.controller.toggleStaged(_file);
      if (!mounted) return;
      // Staging flips which side (cached vs working tree) the diff reads.
      final fresh = widget.controller.files
          .where((file) => file.path == _file.path)
          .firstOrNull;
      if (fresh != null) _file = fresh;
      _reload();
    } catch (error) {
      feedback.notify(FeedbackKind.error, gitFailureText(error, strings));
    } finally {
      if (mounted) setState(() => _staging = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final stageLabel = _file.staged ? strings.gitUnstage : strings.gitStage;
    return Scaffold(
      key: const ValueKey('git-diff-screen'),
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
                    key: const ValueKey('git-diff-back'),
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
                    child: Text(
                      _file.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                  GitDiffCount(added: _file.added, removed: _file.removed),
                  if (widget.controller.writesAllowed)
                    IconButton(
                      key: const ValueKey('git-diff-stage'),
                      tooltip: stageLabel,
                      onPressed: _staging ? null : _toggleStaged,
                      icon: Icon(
                        _file.staged ? Icons.remove_rounded : Icons.add_rounded,
                        color: colors.textSecondary,
                      ),
                    ),
                  if (widget.controller.writesAllowed &&
                      widget.onDiscard != null)
                    HermesMenuButton<_GitDiffAction>(
                      key: const ValueKey('git-diff-menu'),
                      tooltip: strings.ghtFileActions,
                      iconColor: colors.textSecondary,
                      surfaceKey: const ValueKey('git-diff-menu-surface'),
                      actions: (_) => [
                        HermesAction(
                          key: const ValueKey('git-diff-discard'),
                          value: _GitDiffAction.discard,
                          label: strings.ghtDiscardFile,
                          icon: Icons.undo_rounded,
                          destructive: true,
                        ),
                      ],
                      onSelected: (_) async {
                        final navigator = Navigator.of(context);
                        final done = await widget.onDiscard!(_file);
                        if (done && mounted && navigator.canPop()) {
                          navigator.pop();
                        }
                      },
                    ),
                ],
              ),
            ),
            Divider(height: 1, color: colors.divider),
            Expanded(
              child: FutureBuilder<GitReviewDiff>(
                future: _diff,
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return GitStateMessage(
                      key: const ValueKey('git-diff-failed'),
                      text: gitFailureText(snapshot.error!, strings),
                      onRetry: () async => _reload(),
                    );
                  }
                  final diff = snapshot.data;
                  if (diff == null) {
                    return const Center(child: ConsoleLoader.small());
                  }
                  if (diff.tooLarge && diff.lines.isEmpty) {
                    return GitStateMessage(
                      key: const ValueKey('git-diff-too-large'),
                      text: strings.gitDiffTooLarge,
                    );
                  }
                  if (diff.binary) {
                    return GitStateMessage(
                      key: const ValueKey('git-diff-binary'),
                      text: strings.gitDiffBinary,
                    );
                  }
                  if (diff.isEmpty) {
                    return GitStateMessage(
                      key: const ValueKey('git-diff-empty'),
                      text: strings.gitNoDiff,
                    );
                  }
                  return _GitDiffView(
                    diff: diff,
                    path: _file.path,
                    tooLargeNote: diff.tooLarge
                        ? strings.gitDiffTooLarge
                        : null,
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A hunk header's row and how many lines follow it, for folding.
typedef GitHunkRange = ({int header, int lines});

/// The hunks of a diff: each `@@` row and the count of lines up to the
/// next one.
List<GitHunkRange> gitDiffHunks(GitReviewDiff diff) {
  final hunks = <GitHunkRange>[];
  int? header;
  for (var i = 0; i < diff.lines.length; i++) {
    if (diff.lines[i].kind != GitDiffLineKind.hunk) continue;
    if (header != null) hunks.add((header: header, lines: i - header - 1));
    header = i;
  }
  if (header != null) {
    hunks.add((header: header, lines: diff.lines.length - header - 1));
  }
  return hunks;
}

/// The mock's diff card: a hunk header line, then numbered lines, added on
/// a green tint and removed on a red one. Lines do not wrap; the card
/// scrolls sideways. A tap on a hunk header folds its lines (a long diff
/// is read hunk by hunk); the header then says how many are hidden.
class _GitDiffView extends StatefulWidget {
  const _GitDiffView({
    required this.diff,
    required this.path,
    this.tooLargeNote,
  });

  final GitReviewDiff diff;
  final String path;

  /// Shown after the lines when the diff was cut.
  final String? tooLargeNote;

  @override
  State<_GitDiffView> createState() => _GitDiffViewState();
}

class _GitDiffViewState extends State<_GitDiffView> {
  static const double _fontSize = 13;

  /// Row indices of the hunk headers folded now.
  final Set<int> _folded = {};

  @override
  void didUpdateWidget(_GitDiffView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.diff, widget.diff)) _folded.clear();
  }

  /// The rows drawn: every line, minus those of a folded hunk.
  List<int> _visibleRows() {
    final diff = widget.diff;
    if (_folded.isEmpty) {
      return List.generate(diff.lines.length, (i) => i, growable: false);
    }
    final rows = <int>[];
    var skipUntil = -1;
    for (var i = 0; i < diff.lines.length; i++) {
      final line = diff.lines[i];
      if (line.kind == GitDiffLineKind.hunk) {
        rows.add(i);
        skipUntil = _folded.contains(i) ? i : -1;
        continue;
      }
      if (skipUntil >= 0) continue;
      rows.add(i);
    }
    return rows;
  }

  int _hunkLength(int header) {
    final diff = widget.diff;
    var n = 0;
    for (var i = header + 1; i < diff.lines.length; i++) {
      if (diff.lines[i].kind == GitDiffLineKind.hunk) break;
      n++;
    }
    return n;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final diff = widget.diff;
    final tooLargeNote = widget.tooLargeNote;
    final scaled = MediaQuery.textScalerOf(context).scale(_fontSize);
    final longest = diff.lines.fold<int>(
      0,
      (max, line) => math.max(max, line.text.length),
    );
    final digits = diff.lines
        .fold<int>(0, (max, line) => math.max(max, line.number ?? 0))
        .toString()
        .length;
    final gutter = (digits + 1) * scaled * 0.62;
    final width = gutter + (math.min(longest, 400) + 4) * scaled * 0.62;
    final style = TextStyle(
      fontFamily: 'monospace',
      fontSize: _fontSize,
      height: 1.5,
      color: colors.textPrimary,
    );
    final rows = _visibleRows();
    return LayoutBuilder(
      builder: (context, constraints) {
        final contentWidth = math.max(
          constraints.maxWidth - 2 * HermesSpace.x3,
          width,
        );
        return Padding(
          padding: const EdgeInsets.all(HermesSpace.x3),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(HermesRadius.group),
              border: Border.all(color: colors.divider),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(HermesRadius.group),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: contentWidth,
                  child: ListView.builder(
                    key: const ValueKey('git-diff-lines'),
                    itemCount: rows.length + (tooLargeNote == null ? 0 : 1),
                    itemBuilder: (context, index) {
                      if (index == rows.length) {
                        return Padding(
                          padding: const EdgeInsets.all(HermesSpace.x3),
                          child: Text(
                            tooLargeNote!,
                            style: style.copyWith(color: colors.textTertiary),
                          ),
                        );
                      }
                      final row = rows[index];
                      final line = diff.lines[row];
                      final folded =
                          line.kind == GitDiffLineKind.hunk &&
                          _folded.contains(row);
                      return _GitDiffLineRow(
                        line: line,
                        path: widget.path,
                        gutter: gutter,
                        style: style,
                        folded: folded,
                        hiddenLines: folded ? _hunkLength(row) : 0,
                        onToggleFold: line.kind == GitDiffLineKind.hunk
                            ? () => setState(() {
                                if (!_folded.remove(row)) _folded.add(row);
                              })
                            : null,
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _GitDiffLineRow extends StatelessWidget {
  const _GitDiffLineRow({
    required this.line,
    required this.path,
    required this.gutter,
    required this.style,
    this.folded = false,
    this.hiddenLines = 0,
    this.onToggleFold,
  });

  final GitDiffLine line;
  final String path;
  final double gutter;
  final TextStyle style;

  /// Hunk headers only: folded, and how many lines the fold hides.
  final bool folded;
  final int hiddenLines;
  final VoidCallback? onToggleFold;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    if (line.kind == GitDiffLineKind.hunk) {
      final strings = Strings.of(context);
      final label = folded
          ? '${line.text} · ${strings.ghtHunkHidden(hiddenLines)}'
          : '${line.text} · $path';
      return Semantics(
        button: onToggleFold != null,
        label:
            '$label. '
            '${folded ? strings.ghtHunkExpand : strings.ghtHunkCollapse}',
        excludeSemantics: true,
        child: InkWell(
          onTap: onToggleFold,
          child: Container(
            color: colors.surfaceVariant,
            constraints: const BoxConstraints(minHeight: HermesSize.tap - 8),
            padding: const EdgeInsets.symmetric(
              horizontal: HermesSpace.x3,
              vertical: HermesSpace.x1,
            ),
            child: Row(
              children: [
                Icon(
                  folded
                      ? Icons.chevron_right_rounded
                      : Icons.expand_more_rounded,
                  size: HermesIcon.sm,
                  color: colors.textSecondary,
                ),
                const SizedBox(width: HermesSpace.x1),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.clip,
                    style: style.copyWith(color: colors.textSecondary),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    final (background, sign) = switch (line.kind) {
      GitDiffLineKind.added => (colors.success.withValues(alpha: 0.16), '+'),
      GitDiffLineKind.removed => (colors.error.withValues(alpha: 0.16), '-'),
      _ => (null, ' '),
    };
    final number = line.number?.toString() ?? '';
    return Container(
      color: background,
      padding: const EdgeInsets.only(right: HermesSpace.x3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: gutter + HermesSpace.x3,
            child: Padding(
              padding: const EdgeInsets.only(left: HermesSpace.x3),
              child: Text(
                number,
                maxLines: 1,
                softWrap: false,
                style: style.copyWith(color: colors.textTertiary),
              ),
            ),
          ),
          const SizedBox(width: HermesSpace.x2),
          Text(sign, style: style.copyWith(color: colors.textSecondary)),
          const SizedBox(width: HermesSpace.x2),
          Expanded(
            child: Text(
              line.text,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.clip,
              style: line.kind == GitDiffLineKind.note
                  ? style.copyWith(color: colors.textTertiary)
                  : style,
            ),
          ),
        ],
      ),
    );
  }
}
