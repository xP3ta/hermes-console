// SKILL.md of a skill: read it rendered, and, for the user's own skills,
// rewrite it.
//
//  * [SkillContentScreen] shows the text with the chat's Markdown. It serves
//    an installed skill (`GET /api/skills/content`) and the preview of a hub
//    skill that is not installed yet (text already in hand).
//  * [SkillEditPage] edits the raw text. The text is kept exactly as the
//    server stored it; the original of the first read stays in memory so the
//    user can put it back. A rewrite is a high-risk action (the agent follows
//    these instructions): it is confirmed, it re-reads the server copy first
//    and asks again if that changed, and a failed save keeps the typed text.
//    Restoring the original goes through the same guarded write, and after
//    any write the viewer shows what the server now holds, not what was sent.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../design/hermes_design.dart';
import '../feedback/feedback_policy.dart';
import '../services/command_risk.dart';
import '../theme/app_theme.dart';
import '../widgets/action_approval.dart';
import '../widgets/compact_markdown.dart';
import '../widgets/console_loader.dart';
import '../widgets/form_page.dart';
import '../widgets/hermes_ui.dart' show HermesCard;
import 'capability_ui.dart';
import 'spp_copy.dart';
import 'spp_safety.dart';

/// The text rendered at first; the rest is one tap away, so a 100 000
/// character skill never lays out in a single frame.
const int _firstChunk = 12000;

class SkillContentScreen extends StatefulWidget {
  final String name;

  /// Reads the raw SKILL.md. Called on open, on retry and before a rewrite.
  final Future<String> Function() load;

  /// Rewrites the SKILL.md; `null` means the skill cannot be edited here.
  final Future<void> Function(String content)? save;

  /// Why editing is not offered (shown as a note), when it is not.
  final String? readOnlyReason;

  final String instanceId;
  final bool readOnly;

  /// Files of a hub skill's preview, listed under the text.
  final List<String> files;

  /// Called after the server accepted a rewrite.
  final VoidCallback? onChanged;

  const SkillContentScreen({
    super.key,
    required this.name,
    required this.load,
    this.save,
    this.readOnlyReason,
    this.instanceId = '',
    this.readOnly = false,
    this.files = const [],
    this.onChanged,
  });

  @override
  State<SkillContentScreen> createState() => _SkillContentScreenState();
}

class _SkillContentScreenState extends State<SkillContentScreen> {
  bool _loading = true;
  bool _failed = false;
  bool _all = false;
  bool _busy = false;

  /// The text on the server now, as far as this screen knows.
  String _current = '';

  /// The first text this screen read: what "restore original" writes back.
  String? _original;

  bool get _canEdit =>
      widget.save != null &&
      !widget.readOnly &&
      !_loading &&
      !_failed &&
      _current.length <= sppSkillContentMax;

  bool get _canRestore =>
      widget.save != null &&
      !widget.readOnly &&
      _original != null &&
      _original != _current;

  @override
  void initState() {
    super.initState();
    unawaited(_read());
  }

  Future<void> _read() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final text = await widget.load();
      if (!mounted) return;
      setState(() {
        _current = text;
        _original ??= text;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _loading = false;
      });
    }
  }

  Future<void> _edit() async {
    final save = widget.save;
    if (save == null || _busy) return;
    final saved = await pushHermesFormPage<String>(
      context,
      name: 'skill-edit',
      builder: (_) => SkillEditPage(
        name: widget.name,
        initial: _current,
        reload: widget.load,
        save: save,
        instanceId: widget.instanceId,
        readOnly: widget.readOnly,
      ),
    );
    if (!mounted || saved == null) return;
    await _showServerCopy(saved);
    if (!mounted) return;
    widget.onChanged?.call();
    AppFeedback.of(
      context,
    ).notify(FeedbackKind.routine, Strings.of(context).sppSaved);
  }

  /// After a write, shows the copy the server holds now. If it cannot be
  /// read, the text that was sent stands in for it (the write did succeed).
  Future<void> _showServerCopy(String written) async {
    String text;
    try {
      text = await widget.load();
    } catch (_) {
      text = written;
    }
    if (!mounted) return;
    setState(() => _current = text);
  }

  Future<void> _restore() async {
    final save = widget.save;
    final original = _original;
    if (save == null || original == null || _busy) return;
    final s = Strings.of(context);
    final notices = AppFeedback.of(context);
    setState(() => _busy = true);
    try {
      final wrote = await _guardedRewrite(
        context,
        setBusy: (busy) => setState(() => _busy = busy),
        instanceId: widget.instanceId,
        readOnly: widget.readOnly,
        title: s.sppRestoreTitle,
        detail: s.sppRestoreBody,
        known: _current,
        text: original,
        reload: widget.load,
        save: save,
      );
      if (!wrote || !mounted) return;
      await _showServerCopy(original);
      if (!mounted) return;
      widget.onChanged?.call();
      notices.notify(FeedbackKind.routine, s.sppRestored);
    } catch (error) {
      if (mounted) {
        notices.notify(FeedbackKind.error, capabilityFailureMessage(s, error));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final parts = sppSplitSkill(_current);
    final shown = _all || parts.body.length <= _firstChunk
        ? parts.body
        : _cut(parts.body, _firstChunk);
    final body = <Widget>[];
    if (_loading) {
      body.add(
        const Padding(
          padding: EdgeInsets.only(top: 64),
          child: Center(
            child: ConsoleLoader.large(key: ValueKey('spp-content-loading')),
          ),
        ),
      );
    } else if (_failed) {
      body
        ..add(
          HermesEmptyStateView(
            key: const ValueKey('spp-content-error'),
            icon: Icons.cloud_off_rounded,
            title: s.sppContentErrorTitle,
            body: s.sppContentErrorBody,
          ),
        )
        ..add(
          Center(
            child: TextButton(
              key: const ValueKey('spp-content-retry'),
              style: TextButton.styleFrom(
                minimumSize: const Size(HermesSpace.tap, HermesSpace.tap),
              ),
              onPressed: _read,
              child: Text(s.commonRetry),
            ),
          ),
        );
    } else {
      if (widget.readOnlyReason != null) {
        body.add(
          Padding(
            padding: const EdgeInsets.only(bottom: HermesSpace.x3),
            child: HermesInlineNotice(
              key: const ValueKey('spp-content-readonly'),
              icon: Icons.lock_outline_rounded,
              message: widget.readOnlyReason!,
            ),
          ),
        );
      } else if (widget.save != null &&
          !widget.readOnly &&
          _current.length > sppSkillContentMax) {
        body.add(
          Padding(
            padding: const EdgeInsets.only(bottom: HermesSpace.x3),
            child: HermesInlineNotice(
              key: const ValueKey('spp-content-too-long'),
              tone: HermesStatusTone.warn,
              icon: Icons.warning_amber_rounded,
              message: s.sppContentTooLongToEdit,
            ),
          ),
        );
      }
      if (parts.fields.isNotEmpty) {
        body
          ..add(HermesSectionHeader(s.sppDetailsHeader))
          ..add(
            HermesCard(
              key: const ValueKey('spp-content-fields'),
              padding: const EdgeInsets.all(HermesSpace.x4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final entry in parts.fields.entries)
                    Padding(
                      padding: const EdgeInsets.only(bottom: HermesSpace.x2),
                      child: Semantics(
                        container: true,
                        child: Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: '${entry.key}: ',
                                style: HermesType.support.copyWith(
                                  color: colors.textSecondary,
                                ),
                              ),
                              TextSpan(
                                text: entry.value,
                                style: HermesType.body.copyWith(
                                  color: colors.textPrimary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
      }
      body
        ..add(HermesSectionHeader(s.sppContentHeader))
        ..add(
          HermesCard(
            key: const ValueKey('spp-content-body'),
            padding: const EdgeInsets.all(HermesSpace.x4),
            child: CompactMarkdown(
              data: shown,
              tone: CompactMarkdownTone.body,
              fontSize: HermesType.textSize,
            ),
          ),
        );
      if (shown.length < parts.body.length) {
        body.add(
          Center(
            child: TextButton(
              key: const ValueKey('spp-content-more'),
              style: TextButton.styleFrom(
                minimumSize: const Size(HermesSpace.tap, HermesSpace.tap),
              ),
              onPressed: () => setState(() => _all = true),
              child: Text(s.sppShowRest(parts.body.length - shown.length)),
            ),
          ),
        );
      }
      if (widget.files.isNotEmpty) {
        body
          ..add(HermesSectionHeader(s.cphPreviewFiles))
          ..add(
            HermesCard(
              key: const ValueKey('spp-content-files'),
              padding: const EdgeInsets.all(HermesSpace.x4),
              child: Text(
                widget.files.join('\n'),
                style: HermesType.support.copyWith(
                  fontFamily: HermesType.monoFamily,
                  color: colors.textSecondary,
                ),
              ),
            ),
          );
      }
      if (_canRestore) {
        body
          ..add(const SizedBox(height: HermesSpace.x4))
          ..add(
            HermesActionButton(
              key: const ValueKey('spp-content-restore'),
              label: s.sppRestoreOriginal,
              icon: Icons.history_rounded,
              onPressed: _busy ? null : _restore,
            ),
          );
      }
    }
    return HermesPage(
      listKey: const ValueKey('spp-content-list'),
      title: widget.name,
      actions: [
        if (_canEdit)
          IconButton(
            key: const ValueKey('spp-content-edit'),
            tooltip: s.sppEdit,
            constraints: const BoxConstraints(
              minWidth: HermesSpace.tap,
              minHeight: HermesSpace.tap,
            ),
            icon: const Icon(Icons.edit_outlined),
            onPressed: _busy ? null : _edit,
          ),
      ],
      children: body,
    );
  }

  /// [text] cut at a line end near [limit].
  static String _cut(String text, int limit) {
    final at = text.lastIndexOf('\n', limit);
    return text.substring(0, at > limit ~/ 2 ? at : limit);
  }
}

/// The one way a SKILL.md is written: confirm the high-risk action, read the
/// server copy again and, if it is not the [known] text any more (the agent or
/// the CLI rewrote it), ask before overwriting; then write [text]. `false`
/// when the person said no or the screen went away. Errors propagate: the
/// caller keeps what the person typed and says why.
Future<bool> _guardedRewrite(
  BuildContext context, {
  required void Function(bool busy) setBusy,
  required String instanceId,
  required bool readOnly,
  required String title,
  required String detail,
  required String known,
  required String text,
  required Future<String> Function() reload,
  required Future<void> Function(String content) save,
}) async {
  final s = Strings.of(context);
  final ok = await confirmMutatingAction(
    context,
    instanceId: instanceId,
    readOnlyInstance: readOnly,
    risk: CommandRisk.high,
    title: title,
    detail: detail,
  );
  if (!ok || !context.mounted) return false;
  setBusy(true);
  final server = await reload();
  if (!context.mounted) return false;
  setBusy(false);
  if (server != known) {
    final overwrite = await showHermesDialog<bool>(
      context: context,
      surfaceKey: const ValueKey('spp-changed-dialog'),
      title: s.sppChangedTitle,
      message: s.sppChangedBody,
      actions: [
        HermesDialogAction(
          label: s.commonCancel,
          value: false,
          style: HermesDialogActionStyle.cancel,
        ),
        HermesDialogAction(
          key: const ValueKey('spp-changed-overwrite'),
          label: s.sppOverwrite,
          value: true,
          style: HermesDialogActionStyle.destructive,
        ),
      ],
    );
    if (overwrite != true || !context.mounted) return false;
  }
  setBusy(true);
  await save(text);
  return context.mounted;
}

/// Raw editor of a SKILL.md. Pops with the saved text.
class SkillEditPage extends StatefulWidget {
  final String name;

  /// The text as the server had it when the user opened the viewer.
  final String initial;

  /// Reads the server copy again, right before a rewrite.
  final Future<String> Function() reload;
  final Future<void> Function(String content) save;
  final String instanceId;
  final bool readOnly;

  const SkillEditPage({
    super.key,
    required this.name,
    required this.initial,
    required this.reload,
    required this.save,
    this.instanceId = '',
    this.readOnly = false,
  });

  @override
  State<SkillEditPage> createState() => _SkillEditPageState();
}

class _SkillEditPageState extends State<SkillEditPage> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  )..addListener(_changed);
  bool _busy = false;

  /// A save is under way (including the dialogs it opens): no second one.
  bool _submitting = false;

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_changed)
      ..dispose();
    super.dispose();
  }

  bool get _dirty => _controller.text != widget.initial;

  SppSkillIssue? get _issue => sppCheckSkillContent(_controller.text);

  Future<void> _submit() async {
    if (_submitting || !_dirty || _issue != null) return;
    final s = Strings.of(context);
    final notices = AppFeedback.of(context);
    final text = _controller.text;
    _submitting = true;
    try {
      final wrote = await _guardedRewrite(
        context,
        setBusy: (busy) => setState(() => _busy = busy),
        instanceId: widget.instanceId,
        readOnly: widget.readOnly,
        title: s.sppSaveTitle(widget.name),
        detail: s.sppSaveBody,
        known: widget.initial,
        text: text,
        reload: widget.reload,
        save: widget.save,
      );
      if (!wrote || !mounted) return;
      Navigator.of(context).pop(text);
    } catch (error) {
      // The typed text stays on screen: nothing was lost.
      if (mounted) {
        notices.notify(FeedbackKind.error, capabilityFailureMessage(s, error));
      }
    } finally {
      _submitting = false;
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final issue = _issue;
    final length = _controller.text.length;
    return HermesFormPage(
      bodyKey: const ValueKey('spp-edit-body'),
      title: s.sppEditTitle(widget.name),
      submitLabel: s.sppSave,
      submitKey: const ValueKey('spp-edit-submit'),
      dirty: _dirty,
      busy: _busy,
      onSubmit: _dirty && issue == null ? _submit : null,
      children: [
        HermesInlineNotice(
          icon: Icons.warning_amber_rounded,
          tone: HermesStatusTone.warn,
          message: s.sppEditWarning,
        ),
        const SizedBox(height: HermesSpace.x3),
        TextField(
          key: const ValueKey('spp-edit-field'),
          controller: _controller,
          enabled: !_busy,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.multiline,
          minLines: 14,
          maxLines: null,
          style: HermesType.text.copyWith(
            fontFamily: HermesType.monoFamily,
            color: colors.textPrimary,
          ),
          decoration: InputDecoration(
            labelText: s.sppEditorLabel,
            alignLabelWithHint: true,
            counterText: s.sppCharCount(length, sppSkillContentMax),
          ),
        ),
        if (issue != null)
          Padding(
            padding: const EdgeInsets.only(top: HermesSpace.x3),
            child: Semantics(
              liveRegion: true,
              child: Text(
                sppSkillIssueText(s, issue),
                key: const ValueKey('spp-edit-issue'),
                style: HermesType.support.copyWith(color: colors.error),
              ),
            ),
          ),
      ],
    );
  }
}
