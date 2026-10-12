// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hermes Console contributors
//
// "API keys" of the Models screen: Desktop's Settings → Providers → API keys
// (`providers-settings.tsx`, `credential-key-ui.tsx`). The rows come from the
// server's `GET /api/env` for the profile on screen, never from the model
// catalog: a key that is set is listed and removable whatever the catalog
// says about its provider.

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../design/hermes_design.dart'
    show HermesAction, HermesStatusText, HermesStatusTone, showHermesMenu;
import '../models/provider_key_groups.dart';
import '../theme/app_theme.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/hermes_premium_ui.dart'
    show HermesListRow, HermesListSection;
import '../widgets/provider_logo.dart';
import 'models_look.dart';

enum _KeyAction { replace, remove }

class ModelsApiKeysSection extends StatelessWidget {
  const ModelsApiKeysSection({
    required this.groups,
    required this.onEnter,
    required this.onRemove,
    this.enabled = true,
    super.key,
  });

  /// Every provider that takes a key, set or not.
  final List<ProviderKeyGroup> groups;

  /// Enter (or replace) the key of a provider.
  final ValueChanged<ProviderKeyGroup> onEnter;
  final ValueChanged<ProviderKeyGroup> onRemove;
  final bool enabled;

  Future<void> _openMenu(BuildContext context, ProviderKeyGroup group) async {
    final s = Strings.of(context);
    final action = await showHermesMenu<_KeyAction>(
      context: context,
      title: group.name,
      actions: [
        HermesAction(
          key: ValueKey('models-key-replace-${group.keyEnv}'),
          value: _KeyAction.replace,
          label: s.mdlKeyReplace,
        ),
        HermesAction(
          key: ValueKey('models-key-remove-${group.keyEnv}'),
          value: _KeyAction.remove,
          label: s.mdlRemove,
          destructive: true,
        ),
      ],
    );
    switch (action) {
      case _KeyAction.replace:
        onEnter(group);
      case _KeyAction.remove:
        onRemove(group);
      case null:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    // Providers still without a key are offered with the other providers
    // to set up; this block is what is set.
    final set = [
      for (final group in groups)
        if (group.isSet) group,
    ];
    if (set.isEmpty) return const SizedBox.shrink();
    return Column(
      key: const ValueKey('models-api-keys'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ModelsSectionLabel(s.mdlSectionApiKeys),
        HermesListSection(
          margin: const EdgeInsets.only(bottom: 8),
          children: [
            for (final group in set)
              Builder(
                builder: (context) => HermesListRow(
                  key: ValueKey('configured-key-${group.keyEnv}'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  leading: SizedBox.square(
                    dimension: HermesListRow.leadingExtent,
                    child: Center(
                      child: ProviderLogo(
                        provider: group.slug.isEmpty ? group.name : group.slug,
                        providerName: group.name,
                        size: 20,
                      ),
                    ),
                  ),
                  title: group.name,
                  subtitle: s.commonConnected,
                  trailing: Icon(
                    Icons.chevron_right,
                    size: 18,
                    color: colors.textDisabled,
                  ),
                  onTap: enabled ? () => _openMenu(context, group) : null,
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// What the key page does after an attempt to save.
enum ProviderKeyOutcome {
  /// The server holds the key: close the page.
  saved,

  /// Nothing was stored; the page stays, with the reason when there is one.
  refused,

  /// The screen no longer shows the profile the key was for: close.
  voided,
}

typedef ProviderKeySave =
    Future<({ProviderKeyOutcome outcome, String? reason})> Function(String key);

/// Entry of one provider key, as a route (not a dialog). The key is only
/// handed to [onSave]; whether it is stored is the server's answer.
class ProviderKeyScreen extends StatefulWidget {
  const ProviderKeyScreen({
    required this.providerName,
    required this.onSave,
    super.key,
  });

  final String providerName;
  final ProviderKeySave onSave;

  @override
  State<ProviderKeyScreen> createState() => _ProviderKeyScreenState();
}

class _ProviderKeyScreenState extends State<ProviderKeyScreen> {
  final _controller = TextEditingController();
  bool _saving = false;
  String? _reason;

  void _releaseFocus() {
    final focus = FocusManager.instance.primaryFocus;
    if (focus != null && focus.hasFocus) focus.unfocus();
  }

  Future<void> _save() async {
    final key = _controller.text.trim();
    if (key.isEmpty || _saving) return;
    _releaseFocus();
    setState(() {
      _saving = true;
      _reason = null;
    });
    final result = await widget.onSave(key);
    if (!mounted) return;
    switch (result.outcome) {
      case ProviderKeyOutcome.saved:
        Navigator.of(context).pop(true);
      case ProviderKeyOutcome.voided:
        Navigator.of(context).pop(false);
      case ProviderKeyOutcome.refused:
        setState(() {
          _saving = false;
          _reason = result.reason;
        });
    }
  }

  @override
  void deactivate() {
    _releaseFocus();
    super.deactivate();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final reason = _reason;
    return Scaffold(
      appBar: HermesAppBar(
        title: Text(widget.providerName),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: s.commonClose,
          onPressed: _saving
              ? null
              : () {
                  _releaseFocus();
                  Navigator.of(context).pop(false);
                },
        ),
      ),
      body: ListView(
        clipBehavior: hermesUnderHeader,
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            key: const ValueKey('provider-key-field'),
            controller: _controller,
            autofocus: true,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            enabled: !_saving,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _save(),
            decoration: InputDecoration(
              labelText: s.mdlKeyPaste(widget.providerName),
              hintText: 'sk-…',
              border: const OutlineInputBorder(),
            ),
          ),
          if (reason != null) ...[
            const SizedBox(height: 12),
            HermesStatusText(
              key: const ValueKey('provider-key-reason'),
              label: reason,
              tone: HermesStatusTone.error,
              maxLines: 3,
            ),
          ],
          const SizedBox(height: 20),
          FilledButton(
            key: const ValueKey('provider-key-save'),
            onPressed: _saving || _controller.text.trim().isEmpty
                ? null
                : _save,
            child: Text(_saving ? s.mdlKeyChecking : s.commonSave),
          ),
        ],
      ),
    );
  }
}
