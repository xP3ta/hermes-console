import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../design/modal.dart'
    show HermesDialogAction, HermesDialogActionStyle, showHermesDialog;
import '../../services/desktop_control_gateway.dart';
import '../../theme/app_theme.dart';
import '../hermes_app_bar.dart';
import '../hermes_notice.dart';

/// Server cap of `POST /api/fs/write-text` (`_FS_TEXT_WRITE_MAX_BYTES`).
const int projectTextWriteMaxBytes = 8 * 1024 * 1024;

/// Plain text editor for one project file, the phone counterpart of Desktop's
/// preview spot editor (`preview-file.tsx`): edit, "Guardar" writes the whole
/// file with `POST /api/fs/write-text`, and before writing the file is re-read
/// so a change made on the server meanwhile is never overwritten silently.
/// Pops with the saved text, or null when nothing was saved.
class ProjectTextEditorScreen extends StatefulWidget {
  const ProjectTextEditorScreen({
    required this.name,
    required this.path,
    required this.initialText,
    required this.files,
    required this.writes,
    required this.failureText,
    super.key,
  });

  final String name;
  final String path;
  final String initialText;
  final HermesProjectFilesGateway files;
  final HermesProjectFileWritesGateway writes;
  final String Function(Object failure) failureText;

  @override
  State<ProjectTextEditorScreen> createState() =>
      _ProjectTextEditorScreenState();
}

class _ProjectTextEditorScreenState extends State<ProjectTextEditorScreen> {
  late final TextEditingController _text = TextEditingController(
    text: widget.initialText,
  );
  late String _baseline = widget.initialText;
  bool _saving = false;
  bool _leaving = false;

  bool get _dirty => _text.text != _baseline;

  @override
  void initState() {
    super.initState();
    _text.addListener(_onChanged);
  }

  void _onChanged() => setState(() {});

  @override
  void dispose() {
    _text.removeListener(_onChanged);
    _text.dispose();
    super.dispose();
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    required String confirm,
    required String cancel,
  }) async =>
      await showHermesDialog<bool>(
        context: context,
        title: title,
        message: message,
        actions: [
          HermesDialogAction(
            label: cancel,
            value: false,
            style: HermesDialogActionStyle.cancel,
          ),
          HermesDialogAction(
            key: const ValueKey('pw1215-editor-confirm'),
            label: confirm,
            value: true,
            style: HermesDialogActionStyle.destructive,
          ),
        ],
      ) ==
      true;

  Future<void> _save() async {
    if (_saving || !_dirty) return;
    final strings = Strings.of(context);
    final notice = HermesNotice.of(context);
    final draft = _text.text;
    if (utf8.encode(draft).length > projectTextWriteMaxBytes) {
      notice.showSnackBar(
        SnackBar(content: Text(strings.pw1215SaveTooLarge)),
        kind: HermesNoticeKind.error,
      );
      return;
    }
    setState(() => _saving = true);
    try {
      // Stale-on-disk guard (Desktop parity): compare what is on the server
      // now with what the user started from.
      String? current;
      try {
        final preview = await widget.files.readProjectFileText(widget.path);
        if (!preview.binary && !preview.truncated) current = preview.text;
      } catch (_) {
        // Could not re-read: attempt the write, like Desktop.
      }
      if (!mounted) return;
      if (current != null && current != _baseline) {
        // No spinner behind the question: the save is paused on the user.
        setState(() => _saving = false);
        final overwrite = await _confirm(
          title: strings.pw1215ConflictTitle,
          message: strings.pw1215ConflictBody,
          confirm: strings.pw1215Overwrite,
          cancel: strings.commonCancel,
        );
        if (!overwrite || !mounted) return;
        setState(() => _saving = true);
      }
      await widget.writes.writeProjectFileText(widget.path, draft);
      if (!mounted) return;
      _baseline = draft;
      _leaving = true;
      notice.showSnackBar(
        SnackBar(content: Text(strings.pw1215Saved)),
        kind: HermesNoticeKind.success,
      );
      Navigator.of(context).pop(draft);
    } catch (error) {
      if (!mounted) return;
      notice.showSnackBar(
        SnackBar(content: Text(widget.failureText(error))),
        kind: HermesNoticeKind.error,
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _confirmLeave() async {
    final strings = Strings.of(context);
    final discard = await _confirm(
      title: strings.pw1215DiscardTitle,
      message: strings.pw1215DiscardBody,
      confirm: strings.pw1215Discard,
      cancel: strings.pw1215KeepEditing,
    );
    if (!discard || !mounted) return;
    setState(() => _leaving = true);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return PopScope<String>(
      canPop: _leaving || !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_confirmLeave());
      },
      child: Scaffold(
        appBar: HermesAppBar(
          title: Text(
            widget.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _saving
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : TextButton(
                      key: const ValueKey('pw1215-editor-save'),
                      onPressed: _dirty ? () => unawaited(_save()) : null,
                      child: Text(strings.commonSave),
                    ),
            ),
          ],
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            child: TextField(
              key: const ValueKey('pw1215-editor-field'),
              controller: _text,
              expands: true,
              maxLines: null,
              minLines: null,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.multiline,
              textAlignVertical: TextAlignVertical.top,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                height: 1.4,
                color: colors.textPrimary,
              ),
              decoration: const InputDecoration(
                border: InputBorder.none,
                isCollapsed: true,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
