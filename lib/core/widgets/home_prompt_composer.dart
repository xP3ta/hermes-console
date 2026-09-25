import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
import 'attachment_source_sheet.dart';
import 'hermes_premium_ui.dart';

/// Composer compacto de Inicio.
///
/// A diferencia de la antigua pastilla decorativa, expone un [TextField] real y
/// solo habilita el envío cuando existe texto significativo.
class HomePromptComposer extends StatefulWidget {
  const HomePromptComposer({
    super.key,
    required this.hintText,
    required this.attachmentTooltip,
    required this.dictationTooltip,
    required this.voiceTooltip,
    required this.sendTooltip,
    required this.onAttachmentSelected,
    required this.onDictationPressed,
    required this.onVoicePressed,
    required this.onSubmitted,
    this.enabled = true,
    this.restoredText,
    this.onTextChanged,
  });

  final String hintText;
  final String attachmentTooltip;
  final String dictationTooltip;
  final String voiceTooltip;
  final String sendTooltip;
  final ValueChanged<AttachmentSourceChoice> onAttachmentSelected;
  final VoidCallback onDictationPressed;
  final VoidCallback onVoicePressed;
  final ValueChanged<String> onSubmitted;
  final bool enabled;

  /// Borrador persistido a restaurar. Llega de forma asíncrona: solo se
  /// aplica mientras el usuario no haya escrito nada en este compositor.
  final String? restoredText;

  /// Cada cambio de texto (incluida la limpieza al enviar) para persistirlo.
  final ValueChanged<String>? onTextChanged;

  @override
  State<HomePromptComposer> createState() => _HomePromptComposerState();
}

class _HomePromptComposerState extends State<HomePromptComposer> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  bool _hasText = false;
  bool _userEdited = false;
  String _lastReportedText = '';

  bool get _canSubmit => widget.enabled && _hasText;

  @override
  void initState() {
    super.initState();
    _applyRestoredText(widget.restoredText);
    _focusNode.addListener(_handleFocusChanged);
    _controller.addListener(_handleTextChanged);
  }

  @override
  void didUpdateWidget(covariant HomePromptComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.restoredText != oldWidget.restoredText) {
      _applyRestoredText(widget.restoredText);
    }
  }

  void _applyRestoredText(String? text) {
    if (text == null ||
        text.isEmpty ||
        _userEdited ||
        _controller.text.isNotEmpty) {
      return;
    }
    _lastReportedText = text;
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _hasText = text.trim().isNotEmpty;
  }

  void _handleFocusChanged() => setState(() {});

  void _handleTextChanged() {
    final text = _controller.text;
    if (text != _lastReportedText) {
      _lastReportedText = text;
      _userEdited = true;
      widget.onTextChanged?.call(text);
    }
    final hasText = text.trim().isNotEmpty;
    // Solo cambia el chrome al alternar voz/envío. El campo gestiona sus
    // propias ediciones, incluida la limpieza programática tras enviar.
    if (hasText != _hasText) setState(() => _hasText = hasText);
  }

  @override
  void dispose() {
    _focusNode
      ..removeListener(_handleFocusChanged)
      ..dispose();
    _controller
      ..removeListener(_handleTextChanged)
      ..dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    if (!widget.enabled || text.isEmpty) return;
    HapticFeedback.selectionClick();
    FocusManager.instance.primaryFocus?.unfocus();
    // Limpia antes de iniciar la navegación. Si el callback abre Chat de forma
    // síncrona, la transición no conserva durante uno o dos frames el texto en
    // el compositor de Inicio.
    _controller.clear();
    widget.onSubmitted(text);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final canSubmit = _canSubmit;
    return HermesComposerSurface(
      focused: _focusNode.hasFocus,
      // En reposo queda más recogido; al tocarlo recupera el ancho disponible
      // con la animación compartida, sin cambiar la altura ni los hitboxes.
      unfocusedHorizontalInset: 12,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          AttachmentSourceMenuButton(
            key: const ValueKey('home-prompt-attach'),
            semanticLabel: widget.attachmentTooltip,
            onSelected: widget.onAttachmentSelected,
            enabled: widget.enabled,
          ),
          Expanded(
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.enter, control: true):
                    _submit,
                const SingleActivator(LogicalKeyboardKey.enter, meta: true):
                    _submit,
              },
              child: TextField(
                controller: _controller,
                focusNode: _focusNode,
                enabled: widget.enabled,
                minLines: 1,
                maxLines: 4,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                onTapOutside: (_) =>
                    FocusManager.instance.primaryFocus?.unfocus(),
                style: TextStyle(
                  fontSize: 14,
                  height: 1.25,
                  color: colors.textPrimary,
                ),
                decoration: InputDecoration(
                  hintText: widget.hintText,
                  hintStyle: TextStyle(
                    color: colors.textSecondary,
                    fontSize: 14,
                  ),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  disabledBorder: InputBorder.none,
                  errorBorder: InputBorder.none,
                  focusedErrorBorder: InputBorder.none,
                  filled: false,
                  isCollapsed: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
          ),
          HermesTactileAction(
            key: const ValueKey('home-prompt-dictation'),
            icon: Icons.mic_none_rounded,
            iconSize: 23,
            semanticLabel: widget.dictationTooltip,
            onPressed: widget.enabled ? widget.onDictationPressed : null,
            foregroundColor: colors.textPrimary,
            enabled: widget.enabled,
            size: 38,
            visual: HermesTactileActionVisual.quiet,
          ),
          SizedBox.square(
            dimension: 48,
            child: Center(
              child: HermesTactileAction(
                key: const ValueKey('home-prompt-send'),
                icon: canSubmit
                    ? Icons.arrow_upward_rounded
                    : Icons.graphic_eq_rounded,
                semanticLabel: canSubmit
                    ? widget.sendTooltip
                    : widget.voiceTooltip,
                onPressed: !widget.enabled
                    ? null
                    : canSubmit
                    ? _submit
                    : widget.onVoicePressed,
                backgroundColor: colors.accent,
                foregroundColor: colors.onAccent,
                enabled: widget.enabled,
                size: 42,
                iconSize: canSubmit ? 20 : 21,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
