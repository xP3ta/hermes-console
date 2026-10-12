// Credentials sheet for catalog installs that need environment variables.
//
// Every value is a secret: fields are obscured with no autocorrect,
// suggestions or personalised keyboard learning, the typed text lives only in
// these controllers (cleared on dispose) and the result is handed back to the
// caller, which sends it through the server's secret path and clears it.
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../design/hermes_design.dart';
import '../theme/app_theme.dart';
import '../widgets/hermes_ui.dart' show HermesField;
import 'capability_models.dart';

class CapabilityEnvSheet extends StatefulWidget {
  final String name;
  final List<CapabilityEnvField> fields;

  const CapabilityEnvSheet({
    super.key,
    required this.name,
    required this.fields,
  });

  @override
  State<CapabilityEnvSheet> createState() => _CapabilityEnvSheetState();
}

class _CapabilityEnvSheetState extends State<CapabilityEnvSheet> {
  late final Map<String, TextEditingController> _controllers = {
    for (final field in widget.fields) field.name: TextEditingController(),
  };
  bool _missing = false;

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller
        ..clear()
        ..dispose();
    }
    super.dispose();
  }

  void _submit() {
    final values = <String, String>{
      for (final entry in _controllers.entries)
        if (entry.value.text.isNotEmpty) entry.key: entry.value.text,
    };
    final complete = widget.fields.every(
      (field) => !field.required || values.containsKey(field.name),
    );
    if (!complete) {
      setState(() => _missing = true);
      return;
    }
    Navigator.of(context).pop(values);
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            s.cphEnvSheetTitle(widget.name),
            style: HermesType.title.copyWith(color: colors.textPrimary),
          ),
          const SizedBox(height: 6),
          Text(
            s.cphEnvSheetBody,
            style: HermesType.support.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: 14),
          for (final field in widget.fields) ...[
            HermesField(
              key: ValueKey('cph-env-field-${field.name}'),
              label: field.required
                  ? field.name
                  : '${field.name} · ${s.cphEnvOptional}',
              controller: _controllers[field.name]!,
              obscure: true,
              autocorrect: false,
              enableSuggestions: false,
              enableIMEPersonalizedLearning: false,
              helperText: field.prompt.isEmpty ? null : field.prompt,
              errorText:
                  _missing &&
                      field.required &&
                      _controllers[field.name]!.text.isEmpty
                  ? s.cphEnvRequired
                  : null,
            ),
            const SizedBox(height: 12),
          ],
          const SizedBox(height: 4),
          HermesActionButton(
            key: const ValueKey('cph-env-submit'),
            primary: true,
            label: s.cphEnvSubmit,
            icon: Icons.download_rounded,
            onPressed: _submit,
          ),
        ],
      ),
    );
  }
}
