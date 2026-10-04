import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../design/modal.dart';

/// Expands a collapsed large paste so it can be read and edited before it is
/// sent. Returns the edited text, or null when the user cancels.
Future<String?> showPastedTextEditor(BuildContext context, String text) async {
  final s = Strings.of(context);
  final latest = _LatestText(text);
  final saved = await showHermesFormDialog<bool>(
    context: context,
    title: s.t1215PastedContent,
    surfaceKey: const ValueKey('pasted-text-editor'),
    body: (context, setState) => _PastedTextField(
      initial: text,
      onChanged: (value) => latest.value = value,
    ),
    actions: [
      HermesDialogAction(
        label: s.commonCancel,
        value: false,
        style: HermesDialogActionStyle.cancel,
      ),
      HermesDialogAction(
        key: const ValueKey('pasted-text-save'),
        label: s.t1215PastedContentSave,
        value: true,
      ),
    ],
  );
  return saved == true ? latest.value : null;
}

final class _LatestText {
  String value;
  _LatestText(this.value);
}

/// Owns its controller so the dialog's close animation never reads a disposed
/// one.
class _PastedTextField extends StatefulWidget {
  final String initial;
  final ValueChanged<String> onChanged;

  const _PastedTextField({required this.initial, required this.onChanged});

  @override
  State<_PastedTextField> createState() => _PastedTextFieldState();
}

class _PastedTextFieldState extends State<_PastedTextField> {
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
    key: const ValueKey('pasted-text-field'),
    controller: _controller,
    minLines: 6,
    maxLines: 14,
    keyboardType: TextInputType.multiline,
    style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
    onChanged: widget.onChanged,
  );
}
