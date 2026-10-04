import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../design/content.dart';
import '../design/modal.dart';
import '../services/server_config_repository.dart';
import 'hermes_notice.dart';

/// One editable server config field of Settings › Advanced.
///
/// Switches and option lists save when picked; numbers, text and lists save
/// only when the editor is confirmed, never per keystroke. A save is written,
/// re-read from the server, and only then shown as the new value: when the
/// server disagrees the row goes back to what the server has.
class ServerConfigFieldRow extends StatefulWidget {
  const ServerConfigFieldRow({
    required this.field,
    required this.repository,
    required this.writable,
    this.isCurrent,
    this.highlighted = false,
    super.key,
  });

  final ServerConfigField field;
  final ServerConfigRepository repository;

  /// False for a read-only connection: the controls stay but do nothing.
  final bool writable;

  /// Asked after each await: false once the profile changed.
  final bool Function()? isCurrent;

  /// Scrolls the row into view and tints it once (a search result).
  final bool highlighted;

  @override
  State<ServerConfigFieldRow> createState() => _ServerConfigFieldRowState();
}

class _ServerConfigFieldRowState extends State<ServerConfigFieldRow> {
  late Object? _value = widget.field.value;
  bool _saving = false;
  bool _tinted = false;
  Timer? _tintTimer;

  @override
  void initState() {
    super.initState();
    if (widget.highlighted) {
      _tinted = true;
      _tintTimer = Timer(const Duration(milliseconds: 1600), () {
        if (mounted) setState(() => _tinted = false);
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(
            Scrollable.ensureVisible(
              context,
              duration: const Duration(milliseconds: 250),
              alignment: .3,
            ),
          );
        }
      });
    }
  }

  @override
  void dispose() {
    _tintTimer?.cancel();
    super.dispose();
  }

  bool get _canEdit => widget.writable && !_saving;

  Future<void> _commit(Object? next) async {
    if (_saving) return;
    final notices = HermesNotice.of(context);
    final failed = Strings.of(context).ad1215SaveFailed;
    setState(() => _saving = true);
    try {
      final result = await widget.repository.save(
        widget.field.path,
        next,
        isCurrent: widget.isCurrent,
      );
      if (!mounted) return;
      switch (result.outcome) {
        case ServerConfigSaveOutcome.confirmed:
          setState(() => _value = result.serverValue ?? next);
        case ServerConfigSaveOutcome.mismatch:
          setState(() => _value = result.serverValue);
          notices.showSnackBar(
            SnackBar(content: Text(failed)),
            kind: HermesNoticeKind.error,
          );
        case ServerConfigSaveOutcome.stale:
          break;
      }
    } on ServerConfigException {
      if (!mounted) return;
      notices.showSnackBar(
        SnackBar(content: Text(failed)),
        kind: HermesNoticeKind.error,
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _summary() {
    final value = _value;
    if (value == null) return '—';
    if (value is List) return value.join(', ');
    return value.toString();
  }

  Future<void> _pickOption() async {
    final field = widget.field;
    final choice = await showHermesOptions<String>(
      context: context,
      title: field.description,
      selected: _value?.toString(),
      options: [
        for (final option in field.options)
          HermesOption(value: option, label: option),
      ],
    );
    if (choice != null && choice != _value?.toString() && mounted) {
      await _commit(choice);
    }
  }

  Future<void> _edit() async {
    final s = Strings.of(context);
    final field = widget.field;
    final isList = field.type == 'list';
    final isNumber = field.type == 'number';
    var text = isList
        ? ((_value as List?)?.join('\n') ?? '')
        : (_value?.toString() ?? '');
    final saved = await showHermesFormDialog<bool>(
      context: context,
      title: field.description,
      message: isList ? s.ad1215ListHint : null,
      actions: [
        HermesDialogAction(label: s.commonCancel, value: false),
        HermesDialogAction(label: s.commonSave, value: true),
      ],
      enabled: (save) => !save || !isNumber || _parse(text) != null,
      body: (context, setState) => ServerConfigTextEditor(
        initial: text,
        multiline: isList,
        numeric: isNumber,
        // Nothing leaves the screen per keystroke; this only refreshes the
        // Save button.
        onChanged: (value) => setState(() => text = value),
      ),
    );
    if (saved != true || !mounted) return;
    final next = isList
        ? [
            for (final line in text.split('\n'))
              if (line.trim().isNotEmpty) line.trim(),
          ]
        : isNumber
        ? _parse(text)
        : text.trim();
    if (next == null) return;
    await _commit(next);
  }

  static num? _parse(String text) {
    final value = num.tryParse(text.trim());
    if (value == null || !value.isFinite) return null;
    return value;
  }

  @override
  Widget build(BuildContext context) {
    final field = widget.field;
    final Widget row = switch (field.type) {
      'boolean' => HermesToggleRow(
        key: ValueKey('adv-toggle-${field.path}'),
        title: field.description,
        value: _value == true,
        onChanged: _canEdit ? _commit : null,
      ),
      'select' => HermesSelectRow(
        key: ValueKey('adv-select-${field.path}'),
        title: field.description,
        value: _summary(),
        onTap: _canEdit ? _pickOption : null,
      ),
      _ => HermesSelectRow(
        key: ValueKey('adv-edit-${field.path}'),
        title: field.description,
        value: _summary(),
        onTap: _canEdit ? _edit : null,
      ),
    };
    return AnimatedContainer(
      key: ValueKey('adv-field-${field.path}'),
      duration: const Duration(milliseconds: 200),
      color: _tinted
          ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.14)
          : Colors.transparent,
      child: row,
    );
  }
}

/// The text box of an editor dialog. It owns its controller, so the controller
/// goes away with the box and never while the dialog is still animating out.
class ServerConfigTextEditor extends StatefulWidget {
  const ServerConfigTextEditor({
    required this.initial,
    required this.onChanged,
    this.multiline = false,
    this.numeric = false,
    this.obscure = false,
    this.hintText,
    super.key,
  });

  final String initial;
  final ValueChanged<String> onChanged;
  final bool multiline;
  final bool numeric;
  final bool obscure;
  final String? hintText;

  @override
  State<ServerConfigTextEditor> createState() => _ServerConfigTextEditorState();
}

class _ServerConfigTextEditorState extends State<ServerConfigTextEditor> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    key: const ValueKey('server-config-editor'),
    controller: _controller,
    autofocus: true,
    obscureText: widget.obscure,
    autocorrect: !widget.obscure,
    enableSuggestions: !widget.obscure,
    minLines: widget.multiline ? 3 : 1,
    maxLines: widget.obscure ? 1 : (widget.multiline ? 8 : 1),
    keyboardType: widget.numeric
        ? const TextInputType.numberWithOptions(decimal: true)
        : widget.multiline
        ? TextInputType.multiline
        : TextInputType.text,
    decoration: widget.hintText == null
        ? null
        : InputDecoration(hintText: widget.hintText),
    onChanged: widget.onChanged,
  );
}
