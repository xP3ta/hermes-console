import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../models/kanban.dart';
import '../design/hermes_design.dart';
import '../theme/app_theme.dart';

typedef KanbanTaskAction = Future<void> Function();
typedef KanbanCommentAction = Future<void> Function(String body);
typedef KanbanAttachmentAction =
    Future<void> Function(KanbanAttachment attachment);
typedef KanbanRunAction = Future<void> Function(KanbanRun run);
typedef KanbanLinkedTaskAction = Future<void> Function(String taskId);

/// Contenido del detalle Kanban 0.20 como página action-first (spec 080): una
/// sola columna desplazable, estado en línea, acciones primero y grupos
/// editoriales en lugar de tarjetas con borde. Las listas secundarias
/// (ejecuciones, actividad, comentarios…) se pliegan en una fila y solo se
/// construyen al abrirlas. La red y las confirmaciones permanecen en
/// [TasksScreen].
class KanbanTaskDetailSurface extends StatefulWidget {
  final KanbanTaskDetail detail;
  final bool readOnly;
  final KanbanCommentAction? onAddComment;
  final KanbanTaskAction? onUploadAttachment;
  final KanbanAttachmentAction? onDownloadAttachment;
  final KanbanAttachmentAction? onDeleteAttachment;
  final KanbanRunAction? onInspectRun;
  final KanbanRunAction? onTerminateRun;
  final KanbanTaskAction? onShowLog;
  final KanbanTaskAction? onReclaim;
  final KanbanTaskAction? onReassign;
  final KanbanTaskAction? onSpecify;
  final KanbanTaskAction? onDecompose;
  final KanbanTaskAction? onConfigureModel;
  final KanbanLinkedTaskAction? onOpenLinkedTask;
  final VoidCallback? onArchive;
  final VoidCallback? onDelete;
  final VoidCallback? onMove;
  final VoidCallback? onEdit;
  final bool notificationsMuted;
  final ValueChanged<bool>? onToggleNotificationsMuted;

  /// Spec 080: opt-in "Notify me when it's done" for this task.
  final bool notifyWhenDone;
  final ValueChanged<bool>? onToggleNotifyWhenDone;

  const KanbanTaskDetailSurface({
    required this.detail,
    required this.readOnly,
    this.onAddComment,
    this.onUploadAttachment,
    this.onDownloadAttachment,
    this.onDeleteAttachment,
    this.onInspectRun,
    this.onTerminateRun,
    this.onShowLog,
    this.onReclaim,
    this.onReassign,
    this.onSpecify,
    this.onDecompose,
    this.onConfigureModel,
    this.onOpenLinkedTask,
    this.onArchive,
    this.onDelete,
    this.onMove,
    this.onEdit,
    this.notificationsMuted = false,
    this.onToggleNotificationsMuted,
    this.notifyWhenDone = false,
    this.onToggleNotifyWhenDone,
    super.key,
  });

  @override
  State<KanbanTaskDetailSurface> createState() =>
      _KanbanTaskDetailSurfaceState();
}

class _KanbanTaskDetailSurfaceState extends State<KanbanTaskDetailSurface> {
  final TextEditingController _commentController = TextEditingController();
  String? _busyAction;
  bool _showAllEvents = false;
  final Set<String> _open = <String>{};

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant KanbanTaskDetailSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.detail.task.id != widget.detail.task.id) {
      _showAllEvents = false;
      _open.clear();
    }
  }

  Future<void> _run(String action, KanbanTaskAction callback) async {
    if (_busyAction != null) return;
    setState(() => _busyAction = action);
    try {
      await callback();
    } finally {
      if (mounted) setState(() => _busyAction = null);
    }
  }

  Future<void> _submitComment() async {
    final callback = widget.onAddComment;
    final body = _commentController.text.trim();
    if (callback == null || body.isEmpty || _busyAction != null) return;
    setState(() => _busyAction = 'comment');
    try {
      await callback(body);
      _commentController.clear();
    } finally {
      if (mounted) setState(() => _busyAction = null);
    }
  }

  void _toggle(String key) => setState(() {
    if (!_open.remove(key)) _open.add(key);
  });

  static String statusLabel(Strings s, String status) => switch (status) {
    'triage' => s.kanbanColTriage,
    'todo' => s.kanbanColTodo,
    'scheduled' => s.kanbanColScheduled,
    'ready' => s.kanbanColReady,
    'running' => s.kanbanColRunning,
    'blocked' => s.kanbanColBlocked,
    'review' => s.kanbanColReview,
    'done' => s.kanbanColDone,
    'archived' => s.kanbanFilterArchived,
    _ => status.replaceAll('_', ' '),
  };

  static HermesStatusTone statusTone(String status) => switch (status) {
    'running' => HermesStatusTone.active,
    'blocked' => HermesStatusTone.error,
    'review' => HermesStatusTone.warn,
    'done' => HermesStatusTone.ok,
    _ => HermesStatusTone.neutral,
  };

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final copy = _KanbanDetailCopy.forLocale(s.localeName);
    final detail = widget.detail;
    final task = detail.task;
    final meta = <String>[
      if (task.assignee?.isNotEmpty == true) task.assignee!,
      if (task.hasProgress)
        s.kanbanCardProgress(task.progressDone, task.progressTotal),
    ].join(' · ');

    final work = <Widget>[
      if (detail.runs.isNotEmpty && widget.onShowLog != null)
        HermesListRow(
          key: const ValueKey('kanban-task-log'),
          icon: Icons.terminal_rounded,
          title: s.kanbanUiWorkerLog,
          subtitle: s.kanbanUiWorkerLogHint,
          onTap: _busyAction == null
              ? () => _run('log', widget.onShowLog!)
              : null,
        ),
      if (detail.runs.isNotEmpty) ..._runs(colors, copy, detail.runs),
      if (detail.events.isNotEmpty) ..._events(colors, copy, detail.events),
      if (detail.diagnostics.isNotEmpty)
        ..._collapsible(
          key: 'kanban-detail-diagnostics',
          icon: Icons.health_and_safety_outlined,
          title: copy.diagnostics,
          count: detail.diagnostics.length,
          content: [
            for (final diagnostic in detail.diagnostics)
              _DiagnosticTile(colors: colors, diagnostic: diagnostic),
          ],
        ),
      if (_hasDependencies(detail)) ..._dependencies(colors, copy, detail),
      if (detail.childResults.isNotEmpty)
        ..._childResults(colors, copy, detail.childResults),
    ];

    final conversation = <Widget>[
      if (detail.supports(KanbanTaskDetailCapability.comments))
        ..._comments(colors, copy, detail.comments),
      if (detail.supports(KanbanTaskDetailCapability.attachments))
        ..._attachments(colors, copy, detail.attachments),
    ];

    final settings = _settings(copy, task);
    final destructive = _destructive(s, task);

    return SingleChildScrollView(
      key: const ValueKey('kanban-task-detail-rich'),
      padding: EdgeInsets.fromLTRB(
        HermesSpace.pageH,
        HermesSpace.x1,
        HermesSpace.pageH,
        HermesSpace.pageBottom + MediaQuery.paddingOf(context).bottom,
      ),
      child: Column(
        key: ValueKey('kanban-task-detail-${task.id}'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 2, top: 6),
            child: Semantics(
              header: true,
              child: Text(
                task.title,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: HermesType.display.copyWith(color: colors.textPrimary),
              ),
            ),
          ),
          const SizedBox(height: HermesSpace.x1),
          Padding(
            padding: const EdgeInsets.only(left: 2),
            child: Align(
              alignment: Alignment.centerLeft,
              child: HermesStatusText(
                key: const ValueKey('kanban-detail-status'),
                label: statusLabel(s, task.status),
                tone: statusTone(task.status),
                meta: meta.isEmpty ? null : meta,
              ),
            ),
          ),
          if (task.blockReason?.isNotEmpty == true) ...[
            const SizedBox(height: HermesSpace.x3),
            HermesInlineNotice(
              key: const ValueKey('kanban-detail-block-reason'),
              icon: Icons.warning_amber_rounded,
              tone: HermesStatusTone.error,
              message: task.blockReason!,
            ),
          ] else if (detail.diagnostics.isNotEmpty) ...[
            const SizedBox(height: HermesSpace.x3),
            HermesInlineNotice(
              icon: Icons.info_outline_rounded,
              tone: HermesStatusTone.warn,
              message:
                  '${detail.diagnostics.first.title}: '
                  '${detail.diagnostics.first.detail}',
            ),
          ],
          if (widget.readOnly) ...[
            const SizedBox(height: HermesSpace.x3),
            HermesInlineNotice(
              key: const ValueKey('kanban-detail-read-only'),
              icon: Icons.lock_outline_rounded,
              message: copy.readOnly,
            ),
          ],
          if (!widget.readOnly &&
              (widget.onEdit != null || widget.onMove != null)) ...[
            const SizedBox(height: 14),
            Row(
              children: [
                if (widget.onEdit != null)
                  Expanded(
                    child: HermesActionButton(
                      key: const ValueKey('kanban-task-edit'),
                      primary: true,
                      icon: Icons.edit_outlined,
                      label: s.kanbanEdit,
                      onPressed: widget.onEdit,
                    ),
                  ),
                if (widget.onEdit != null && widget.onMove != null)
                  const SizedBox(width: HermesSpace.x2),
                if (widget.onMove != null)
                  Expanded(
                    child: HermesActionButton(
                      key: const ValueKey('kanban-task-move'),
                      icon: Icons.swap_horiz_rounded,
                      label: s.kanbanMove,
                      onPressed: widget.onMove,
                    ),
                  ),
              ],
            ),
          ],
          if (task.body.isNotEmpty) ...[
            HermesSectionHeader(s.kanbanUiObjective),
            HermesTextBlock(
              key: const ValueKey('kanban-task-detail-body'),
              text: task.body,
              collapsedLines: 6,
              copyable: true,
              openTitle: s.kanbanUiObjective,
            ),
          ],
          if (task.result?.isNotEmpty == true) ...[
            HermesSectionHeader(copy.result),
            HermesTextBlock(
              key: const ValueKey('kanban-detail-result'),
              text: task.result!,
              collapsedLines: 6,
              copyable: true,
              openTitle: copy.result,
            ),
          ],
          if (task.latestSummary?.isNotEmpty == true &&
              task.latestSummary != task.result) ...[
            HermesSectionHeader(copy.latestSummary),
            HermesTextBlock(
              key: const ValueKey('kanban-detail-summary'),
              text: task.latestSummary!,
              collapsedLines: 4,
              openTitle: copy.latestSummary,
            ),
          ],
          if (work.isNotEmpty) ...[
            HermesSectionHeader(s.kanbanUiWork),
            HermesListGroup(children: work),
          ],
          if (conversation.isNotEmpty) ...[
            HermesSectionHeader(s.kanbanUiConversation),
            HermesListGroup(children: conversation),
          ],
          if (settings.isNotEmpty) ...[
            HermesSectionHeader(s.kanbanUiThisTask),
            HermesListGroup(
              key: const ValueKey('kanban-detail-operations'),
              children: settings,
            ),
          ],
          if (destructive.isNotEmpty) ...[
            const SizedBox(height: HermesSpace.x5),
            HermesListGroup(children: destructive),
          ],
        ],
      ),
    );
  }

  /// Header row of a folded list plus, when open, its content. Content is
  /// only built while open so private rows never render collapsed.
  List<Widget> _collapsible({
    required String key,
    required IconData icon,
    required String title,
    required int count,
    required List<Widget> content,
  }) {
    final open = _open.contains(key);
    return [
      HermesListRow(
        key: ValueKey(key),
        icon: icon,
        title: title,
        semanticLabel: '$title, $count',
        onTap: () => _toggle(key),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '$count',
              style: HermesType.value.copyWith(
                color: Theme.of(context).hermes.textSecondary,
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              open ? Icons.expand_less_rounded : Icons.expand_more_rounded,
              size: 20,
              color: Theme.of(context).hermes.textSecondary,
            ),
          ],
        ),
      ),
      if (open)
        Padding(
          padding: const EdgeInsets.fromLTRB(
            HermesSpace.rowH,
            HermesSpace.x1,
            HermesSpace.rowH,
            HermesSpace.x2,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: content,
          ),
        ),
    ];
  }

  bool _hasDependencies(KanbanTaskDetail detail) =>
      detail.links.parents.isNotEmpty ||
      detail.links.children.isNotEmpty ||
      detail.links.blockedBy.isNotEmpty ||
      detail.links.blocks.isNotEmpty;

  List<Widget> _dependencies(
    HermesThemeColors colors,
    _KanbanDetailCopy copy,
    KanbanTaskDetail detail,
  ) {
    final links = detail.links;
    return _collapsible(
      key: 'kanban-detail-links',
      icon: Icons.account_tree_outlined,
      title: copy.dependencies,
      count:
          links.parents.length +
          links.children.length +
          links.blockedBy.length +
          links.blocks.length,
      content: [
        _linkRow(colors, copy.parents, links.parents),
        _linkRow(colors, copy.children, links.children),
        _linkRow(colors, copy.blockedBy, links.blockedBy),
        _linkRow(colors, copy.blocks, links.blocks),
      ],
    );
  }

  Widget _linkRow(HermesThemeColors colors, String label, List<String> ids) {
    if (ids.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Wrap(
        spacing: 7,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            label,
            style: HermesType.support.copyWith(color: colors.textSecondary),
          ),
          for (final id in ids)
            ActionChip(
              label: Text(id, overflow: TextOverflow.ellipsis),
              tooltip: id,
              onPressed: widget.onOpenLinkedTask == null
                  ? null
                  : () => _run('link-$id', () => widget.onOpenLinkedTask!(id)),
            ),
        ],
      ),
    );
  }

  List<Widget> _childResults(
    HermesThemeColors colors,
    _KanbanDetailCopy copy,
    List<KanbanChildResult> children,
  ) {
    final s = Strings.of(context);
    return _collapsible(
      key: 'kanban-detail-children',
      icon: Icons.checklist_rounded,
      title: copy.childResults,
      count: children.length,
      content: [
        for (final child in children)
          _SubRow(
            key: ValueKey('kanban-child-${child.id}'),
            title: child.title,
            subtitle: child.latestSummary,
            trailing: Text(
              statusLabel(s, child.status),
              style: HermesType.support.copyWith(
                color: statusTone(child.status).colorIn(colors),
              ),
            ),
            onTap: widget.onOpenLinkedTask == null
                ? null
                : () => _run(
                    'child-${child.id}',
                    () => widget.onOpenLinkedTask!(child.id),
                  ),
          ),
      ],
    );
  }

  List<Widget> _comments(
    HermesThemeColors colors,
    _KanbanDetailCopy copy,
    List<KanbanComment> comments,
  ) {
    final canWrite = !widget.readOnly && widget.onAddComment != null;
    return _collapsible(
      key: 'kanban-detail-comments',
      icon: Icons.forum_outlined,
      title: copy.comments,
      count: comments.length,
      content: [
        if (comments.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              copy.noComments,
              style: HermesType.support.copyWith(color: colors.textSecondary),
            ),
          )
        else
          for (final comment in comments)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    comment.author.isEmpty ? copy.someone : comment.author,
                    style: HermesType.support.copyWith(
                      fontWeight: FontWeight.w600,
                      color: colors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  SelectableText(
                    comment.body,
                    style: HermesType.text.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
        if (canWrite) ...[
          const SizedBox(height: HermesSpace.x1),
          TextField(
            key: const ValueKey('kanban-comment-field'),
            controller: _commentController,
            minLines: 1,
            maxLines: 4,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              hintText: widget.detail.task.status == 'running'
                  ? copy.messageWorker
                  : copy.addComment,
              suffixIcon: IconButton(
                key: const ValueKey('kanban-comment-send'),
                tooltip: copy.send,
                onPressed: _busyAction == null ? _submitComment : null,
                icon: _busyAction == 'comment'
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send_rounded),
              ),
            ),
            onSubmitted: (_) => _submitComment(),
          ),
        ],
      ],
    );
  }

  List<Widget> _attachments(
    HermesThemeColors colors,
    _KanbanDetailCopy copy,
    List<KanbanAttachment> attachments,
  ) {
    final canWrite = !widget.readOnly;
    return [
      ..._collapsible(
        key: 'kanban-detail-attachments',
        icon: Icons.attach_file_rounded,
        title: copy.attachments,
        count: attachments.length,
        content: [
          if (attachments.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(
                copy.noAttachments,
                style: HermesType.support.copyWith(color: colors.textSecondary),
              ),
            )
          else
            for (final attachment in attachments)
              _SubRow(
                key: ValueKey('kanban-attachment-${attachment.id}'),
                title: attachment.safeFilename,
                subtitle: _formatBytes(attachment.size),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: copy.download,
                      onPressed:
                          widget.onDownloadAttachment == null ||
                              _busyAction != null
                          ? null
                          : () => _run(
                              'download-${attachment.id}',
                              () => widget.onDownloadAttachment!(attachment),
                            ),
                      icon: const Icon(Icons.download_rounded, size: 19),
                    ),
                    if (canWrite && widget.onDeleteAttachment != null)
                      IconButton(
                        tooltip: copy.deleteAttachment,
                        onPressed: _busyAction == null
                            ? () => _run(
                                'delete-attachment-${attachment.id}',
                                () => widget.onDeleteAttachment!(attachment),
                              )
                            : null,
                        icon: Icon(
                          Icons.delete_outline_rounded,
                          size: 19,
                          color: colors.error,
                        ),
                      ),
                  ],
                ),
              ),
        ],
      ),
      if (canWrite && widget.onUploadAttachment != null)
        HermesListRow(
          key: const ValueKey('kanban-attachment-upload'),
          icon: Icons.upload_file_rounded,
          title: copy.uploadAttachment,
          showChevron: false,
          onTap: _busyAction == null
              ? () => _run('upload', widget.onUploadAttachment!)
              : null,
        ),
    ];
  }

  List<Widget> _runs(
    HermesThemeColors colors,
    _KanbanDetailCopy copy,
    List<KanbanRun> runs,
  ) {
    return _collapsible(
      key: 'kanban-detail-runs',
      icon: Icons.play_circle_outline_rounded,
      title: copy.runs,
      count: runs.length,
      content: [
        for (final run in runs)
          _SubRow(
            key: ValueKey('kanban-run-${run.id}'),
            title: '${copy.run} #${run.id} · ${run.status}',
            subtitle: run.summary,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: copy.inspect,
                  onPressed: widget.onInspectRun == null || _busyAction != null
                      ? null
                      : () => _run(
                          'inspect-${run.id}',
                          () => widget.onInspectRun!(run),
                        ),
                  icon: const Icon(Icons.monitor_heart_outlined, size: 19),
                ),
                if (!widget.readOnly &&
                    run.endedAt == null &&
                    widget.onTerminateRun != null)
                  IconButton(
                    key: ValueKey('kanban-run-terminate-${run.id}'),
                    tooltip: copy.terminate,
                    onPressed: _busyAction == null
                        ? () => _run(
                            'terminate-${run.id}',
                            () => widget.onTerminateRun!(run),
                          )
                        : null,
                    icon: Icon(
                      Icons.stop_circle_outlined,
                      size: 20,
                      color: colors.error,
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  List<Widget> _events(
    HermesThemeColors colors,
    _KanbanDetailCopy copy,
    List<KanbanTaskEvent> events,
  ) {
    return _collapsible(
      key: 'kanban-detail-events',
      icon: Icons.history_rounded,
      title: copy.activity,
      count: events.length,
      content: [
        for (final event
            in (_showAllEvents ? events.reversed : events.reversed.take(5)))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Icon(
                    Icons.circle,
                    size: 6,
                    color: colors.textSecondary,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: SelectableText(
                    _eventText(event),
                    style: HermesType.support.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (events.length > 5)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const ValueKey('kanban-events-show-all'),
              style: TextButton.styleFrom(minimumSize: const Size(48, 44)),
              onPressed: () => setState(() => _showAllEvents = !_showAllEvents),
              child: Text(_showAllEvents ? copy.showLess : copy.showAll),
            ),
          ),
      ],
    );
  }

  String _eventText(KanbanTaskEvent event) {
    final label = event.kind.replaceAll('_', ' ');
    final primitive = event.payload.entries
        .where(
          (entry) =>
              entry.value == null ||
              entry.value is String ||
              entry.value is num ||
              entry.value is bool,
        )
        .map((entry) => '${entry.key}=${entry.value}')
        .join(' · ');
    return primitive.isEmpty ? label : '$label · $primitive';
  }

  /// Per-task settings and operations. Mutating rows are hidden (not
  /// disabled) on read-only connections; the model stays visible read-only.
  List<Widget> _settings(_KanbanDetailCopy copy, KanbanTask task) {
    final currentModel = task.modelOverride?.isNotEmpty == true
        ? '${task.providerOverride?.isNotEmpty == true ? '${task.providerOverride}: ' : ''}${task.modelOverride}'
        : copy.inheritModel;
    final canAct = !widget.readOnly && _busyAction == null;
    return [
      if (widget.onConfigureModel != null)
        HermesListRow(
          key: const ValueKey('kanban-model-override'),
          icon: Icons.memory_rounded,
          title: copy.model,
          value: task.reasoningEffort?.isNotEmpty == true
              ? '$currentModel · ${task.reasoningEffort}'
              : currentModel,
          showChevron: !widget.readOnly,
          onTap: canAct ? () => _run('model', widget.onConfigureModel!) : null,
        ),
      if (widget.onToggleNotifyWhenDone != null)
        HermesToggleRow(
          switchKey: const ValueKey('kanban-task-notify-done'),
          icon: Icons.notifications_active_outlined,
          title: copy.notifyWhenDone,
          value: widget.notifyWhenDone && !widget.notificationsMuted,
          onChanged: widget.notificationsMuted
              ? null
              : widget.onToggleNotifyWhenDone,
        ),
      if (widget.onToggleNotificationsMuted != null)
        HermesToggleRow(
          switchKey: const ValueKey('kanban-task-mute-notifications'),
          icon: Icons.notifications_off_outlined,
          title: copy.muteNotifications,
          subtitle: copy.muteNotificationsSub,
          value: widget.notificationsMuted,
          onChanged: widget.onToggleNotificationsMuted,
        ),
      if (!widget.readOnly) ...[
        if (widget.onReassign != null)
          HermesListRow(
            key: const ValueKey('kanban-task-reassign'),
            icon: Icons.person_search_outlined,
            title: copy.reassign,
            onTap: canAct ? () => _run('reassign', widget.onReassign!) : null,
          ),
        if (task.status == 'running' && widget.onReclaim != null)
          HermesListRow(
            key: const ValueKey('kanban-task-reclaim'),
            icon: Icons.restart_alt_rounded,
            title: copy.reclaim,
            showChevron: false,
            onTap: canAct ? () => _run('reclaim', widget.onReclaim!) : null,
          ),
        if (task.status == 'triage' && widget.onSpecify != null)
          HermesListRow(
            key: const ValueKey('kanban-task-specify'),
            icon: Icons.auto_fix_high_outlined,
            title: copy.specify,
            showChevron: false,
            onTap: canAct ? () => _run('specify', widget.onSpecify!) : null,
          ),
        if (task.status == 'triage' && widget.onDecompose != null)
          HermesListRow(
            key: const ValueKey('kanban-task-decompose'),
            icon: Icons.account_tree_outlined,
            title: copy.decompose,
            showChevron: false,
            onTap: canAct ? () => _run('decompose', widget.onDecompose!) : null,
          ),
      ],
    ];
  }

  List<Widget> _destructive(Strings s, KanbanTask task) {
    if (widget.readOnly) return const [];
    return [
      if (task.status != 'archived' && widget.onArchive != null)
        HermesListRow(
          key: const ValueKey('kanban-task-archive'),
          icon: Icons.archive_outlined,
          title: s.kanbanArchive,
          showChevron: false,
          onTap: widget.onArchive,
        ),
      if (widget.onDelete != null)
        HermesListRow(
          key: const ValueKey('kanban-task-delete-permanent'),
          icon: Icons.delete_forever_outlined,
          title: s.kanbanDeletePermanent,
          destructive: true,
          showChevron: false,
          onTap: widget.onDelete,
        ),
    ];
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
  }
}

/// Row inside an open folded list: title, optional support line, trailing.
class _SubRow extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  const _SubRow({
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final content = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: HermesSpace.tap),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: HermesType.body.copyWith(color: colors.textPrimary),
                  ),
                  if (subtitle?.isNotEmpty == true)
                    Text(
                      subtitle!,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: HermesType.support.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: HermesSpace.x2),
              trailing!,
            ],
          ],
        ),
      ),
    );
    if (onTap == null) return content;
    return InkWell(onTap: onTap, child: content);
  }
}

class _DiagnosticTile extends StatelessWidget {
  final HermesThemeColors colors;
  final KanbanDiagnostic diagnostic;

  const _DiagnosticTile({required this.colors, required this.diagnostic});

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: ValueKey('kanban-diagnostic-${diagnostic.kind}'),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          HermesStatusText(
            label:
                '${diagnostic.title}${diagnostic.count > 1 ? ' ×${diagnostic.count}' : ''}',
            tone: switch (diagnostic.severity) {
              KanbanDiagnosticSeverity.warning => HermesStatusTone.warn,
              KanbanDiagnosticSeverity.error ||
              KanbanDiagnosticSeverity.critical => HermesStatusTone.error,
              KanbanDiagnosticSeverity.unknown => HermesStatusTone.neutral,
            },
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(left: 12),
            child: SelectableText(
              diagnostic.detail,
              style: HermesType.support.copyWith(color: colors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

class _KanbanDetailCopy {
  final bool spanish;

  const _KanbanDetailCopy._(this.spanish);

  factory _KanbanDetailCopy.forLocale(String localeName) =>
      _KanbanDetailCopy._(localeName.toLowerCase().startsWith('es'));

  String get readOnly => spanish
      ? 'Esta instancia está en modo solo lectura.'
      : 'This instance is read-only.';
  String get objective =>
      spanish ? 'Objetivo · leer completo' : 'Objective · read all';
  String get result => spanish ? 'Resultado' : 'Result';
  String get latestSummary => spanish ? 'Último resumen' : 'Latest summary';
  String get diagnostics => spanish ? 'Diagnósticos' : 'Diagnostics';
  String get dependencies => spanish ? 'Dependencias' : 'Dependencies';
  String get parents => spanish ? 'Depende de' : 'Depends on';
  String get children => spanish ? 'Desbloquea' : 'Unblocks';
  String get blockedBy => spanish ? 'Bloqueada por' : 'Blocked by';
  String get blocks => spanish ? 'Bloquea' : 'Blocks';
  String get childResults => spanish ? 'Subtareas' : 'Child tasks';
  String get comments => spanish ? 'Comentarios' : 'Comments';
  String get noComments =>
      spanish ? 'Todavía no hay comentarios.' : 'No comments yet.';
  String get someone => spanish ? 'Alguien' : 'Someone';
  String get addComment => spanish ? 'Añadir comentario' : 'Add a comment';
  String get messageWorker =>
      spanish ? 'Enviar una nota al worker' : 'Message the worker';
  String get send => spanish ? 'Enviar' : 'Send';
  String get attachments => spanish ? 'Adjuntos' : 'Attachments';
  String get noAttachments => spanish ? 'No hay adjuntos.' : 'No attachments.';
  String get uploadAttachment =>
      spanish ? 'Subir adjunto' : 'Upload attachment';
  String get download => spanish ? 'Descargar' : 'Download';
  String get deleteAttachment =>
      spanish ? 'Eliminar adjunto' : 'Delete attachment';
  String get runs => spanish ? 'Ejecuciones' : 'Runs';
  String get run => spanish ? 'Ejecución' : 'Run';
  String get inspect => spanish ? 'Inspeccionar' : 'Inspect';
  String get terminate => spanish ? 'Terminar ejecución' : 'Terminate run';
  String get log => spanish ? 'Log' : 'Log';
  String get activity => spanish ? 'Actividad' : 'Activity';
  String get showAll => spanish ? 'Mostrar toda' : 'Show all';
  String get showLess => spanish ? 'Mostrar menos' : 'Show less';
  String get operations => spanish ? 'Operaciones' : 'Operations';
  String get model => spanish ? 'Modelo de esta tarea' : 'Task model';
  String get inheritModel =>
      spanish ? 'Heredar del perfil' : 'Inherit from profile';
  String get reassign => spanish ? 'Reasignar' : 'Reassign';
  String get reclaim =>
      spanish ? 'Recuperar y reencolar' : 'Reclaim and requeue';
  String get specify => spanish ? 'Especificar' : 'Specify';
  String get decompose => spanish ? 'Descomponer' : 'Decompose';
  String get notifyWhenDone =>
      spanish ? 'Avisarme cuando termine' : "Notify me when it's done";
  String get muteNotifications =>
      spanish ? 'Silenciar notificaciones' : 'Mute notifications';
  String get muteNotificationsSub => spanish
      ? 'No avisar de cambios de estado de esta tarea, aunque los resultados de Kanban estén activados'
      : "Don't notify status changes for this task, even if Kanban results are enabled";
}
