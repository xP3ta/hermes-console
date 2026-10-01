import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../theme/app_theme.dart';

class InlineMessageEditor extends StatefulWidget {
  const InlineMessageEditor({
    required this.initialText,
    required this.onCancel,
    required this.onSave,
    this.attachments,
    this.saving = false,
    this.draftText,
    super.key,
  });

  /// The message as it stands; Save stays off until the text differs.
  final String initialText;

  /// Text to show instead of [initialText], such as an edit whose save
  /// failed. It is compared against [initialText], not against itself, so the
  /// user can retry the same rewrite.
  final String? draftText;
  final VoidCallback onCancel;
  final ValueChanged<String> onSave;
  final Widget? attachments;
  final bool saving;

  @override
  State<InlineMessageEditor> createState() => _InlineMessageEditorState();
}

class _InlineMessageEditorState extends State<InlineMessageEditor>
    with WidgetsBindingObserver {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  bool _submitted = false;

  bool get _canSave {
    final value = _controller.text.trim();
    return !_submitted &&
        !widget.saving &&
        value.isNotEmpty &&
        value != widget.initialText.trim();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final text = widget.draftText ?? widget.initialText;
    _controller = TextEditingController(text: text)
      ..selection = TextSelection.collapsed(offset: text.length)
      ..addListener(_onTextChanged);
    _focusNode = FocusNode();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusNode.requestFocus();
      // Salta sin animar: pedir el foco abre el teclado un frame después, así
      // que animar ya aquí apunta a un objetivo con el viewport todavía sin
      // encoger. didChangeMetrics hace la corrección real (animada) en cuanto
      // el teclado cambia los insets; animar los dos deja un doble salto.
      _ensureVisible(animate: false);
    });
  }

  @override
  void didUpdateWidget(InlineMessageEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A save that ended without closing the editor failed: let the user try
    // again or cancel.
    if (oldWidget.saving && !widget.saving) _submitted = false;
    final draft = widget.draftText;
    // A returned draft also means the save ended without closing the editor,
    // even when the parent never painted a frame with `saving` on.
    if (draft != oldWidget.draftText && !widget.saving) _submitted = false;
    if (draft != null && draft != oldWidget.draftText) {
      if (_controller.text != draft) {
        _controller.value = TextEditingValue(
          text: draft,
          selection: TextSelection.collapsed(offset: draft.length),
        );
      }
    }
  }

  @override
  void didChangeMetrics() {
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _ensureVisible(animate: true),
    );
  }

  void _onTextChanged() {
    if (mounted) setState(() {});
  }

  void _ensureVisible({required bool animate}) {
    if (!mounted || !_focusNode.hasFocus) return;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    unawaited(
      Scrollable.ensureVisible(
        context,
        alignment: 0.35,
        duration: !animate || reduceMotion
            ? Duration.zero
            : const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  void _save() {
    if (!_canSave) return;
    final value = _controller.text.trim();
    setState(() => _submitted = true);
    widget.onSave(value);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller
      ..removeListener(_onTextChanged)
      ..dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final actionsEnabled = !_submitted && !widget.saving;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && actionsEnabled) widget.onCancel();
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.attachments case final attachments?) ...[
            attachments,
            const SizedBox(height: 6),
          ],
          TextField(
            key: const ValueKey('inline-message-editor-field'),
            controller: _controller,
            focusNode: _focusNode,
            autofocus: true,
            // Alto = contenido: arranca con espacio para varias líneas (no una
            // caja diminuta de una sola línea) y sube hasta ~10 antes de
            // desplazar, para que editar se sienta como escribir, no como
            // rellenar un campo estrecho.
            minLines: 3,
            maxLines: 10,
            textCapitalization: TextCapitalization.sentences,
            keyboardType: TextInputType.multiline,
            textInputAction: TextInputAction.newline,
            // Sin relleno, sin borde y sin el relleno vertical del tema: el
            // texto se edita directamente sobre la burbuja.
            decoration: InputDecoration(
              isCollapsed: true,
              isDense: true,
              filled: false,
              fillColor: Colors.transparent,
              contentPadding: EdgeInsets.zero,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              disabledBorder: InputBorder.none,
              errorBorder: InputBorder.none,
              focusedErrorBorder: InputBorder.none,
              hintText: strings.chaEditHint,
              // Una burbuja estrecha partía el aviso en 3 líneas y dejaba un
              // hueco vacío: el alto sale del contenido, no del aviso.
              hintMaxLines: 1,
            ),
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: colors.textPrimary,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 4),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Semantics(
                  label: strings.chaEditCancel,
                  button: true,
                  enabled: actionsEnabled,
                  child: ExcludeSemantics(
                    child: IconButton(
                      key: const ValueKey('inline-message-editor-cancel'),
                      onPressed: actionsEnabled ? widget.onCancel : null,
                      tooltip: strings.chaEditCancel,
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints(
                        minWidth: 40,
                        minHeight: 40,
                      ),
                      icon: const Icon(Icons.close_rounded, size: 18),
                    ),
                  ),
                ),
                const SizedBox(width: 2),
                Semantics(
                  label: strings.chaEditSave,
                  button: true,
                  enabled: _canSave,
                  child: ExcludeSemantics(
                    child: IconButton.filled(
                      key: const ValueKey('inline-message-editor-save'),
                      onPressed: _canSave ? _save : null,
                      tooltip: strings.chaEditSave,
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints(
                        minWidth: 40,
                        minHeight: 40,
                      ),
                      icon: const Icon(Icons.arrow_upward_rounded, size: 18),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
