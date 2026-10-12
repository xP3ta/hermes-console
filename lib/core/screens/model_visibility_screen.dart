// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hermes Console contributors
//
// "Edit models": which models of the connected providers the pickers offer.
// Desktop's model-visibility dialog (`components/model-visibility-dialog.tsx`)
// with one difference: a provider is not hidden here. It is removed from the
// Models page, on the server, and is then gone from this list too. Nothing on
// this page reaches the server; the choice of models is this device's, like
// Desktop's is that window's.
//
// The page opens with every provider closed, each saying how many of its
// models are offered, so a server with many providers is still one short
// list.

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../design/hermes_design.dart'
    show
        HermesDialogAction,
        HermesDialogActionStyle,
        HermesListGroup,
        HermesListRow,
        HermesPage,
        HermesToggleRow,
        showHermesDialog;
import '../models/model_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/hermes_premium_ui.dart' show HermesSearchField;
import '../widgets/provider_logo.dart';

class ModelVisibilityScreen extends StatefulWidget {
  const ModelVisibilityScreen({
    required this.providers,
    required this.hiddenModels,
    required this.onChanged,
    super.key,
  });

  /// The connected providers that list models, in the order of the page.
  final List<ModelProvider> providers;

  /// The models taken out of the pickers, as `provider/model`.
  final Set<String> hiddenModels;
  final ValueChanged<Set<String>> onChanged;

  @override
  State<ModelVisibilityScreen> createState() => _ModelVisibilityScreenState();
}

class _ModelVisibilityScreenState extends State<ModelVisibilityScreen> {
  late final Set<String> _hidden = {...widget.hiddenModels};
  final Set<String> _open = {};
  String _query = '';

  void _setModel(String slug, String model, bool shown) {
    final key = '$slug/$model';
    setState(() => shown ? _hidden.remove(key) : _hidden.add(key));
    widget.onChanged({..._hidden});
  }

  Future<void> _reset() async {
    final s = Strings.of(context);
    final confirmed = await showHermesDialog<bool>(
      context: context,
      title: s.mdlVisibilityResetTitle,
      actions: [
        HermesDialogAction(
          label: s.commonCancel,
          value: false,
          style: HermesDialogActionStyle.cancel,
        ),
        HermesDialogAction(
          label: s.mdlVisibilityResetAction,
          value: true,
          style: HermesDialogActionStyle.destructive,
        ),
      ],
    );
    if (confirmed != true || !mounted) return;
    setState(_hidden.clear);
    widget.onChanged({});
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final query = _query.trim().toLowerCase();
    bool matches(ModelProvider provider, String model) =>
        query.isEmpty ||
        model.toLowerCase().contains(query) ||
        provider.name.toLowerCase().contains(query) ||
        provider.slug.toLowerCase().contains(query);
    final rows = <Widget>[];
    for (final provider in widget.providers) {
      final models = [
        for (final model in provider.models)
          if (matches(provider, model)) model,
      ];
      if (models.isEmpty) continue;
      // A search shows what it found; otherwise a provider is open only
      // once it has been tapped.
      final open = query.isNotEmpty || _open.contains(provider.slug);
      final shown = provider.models
          .where((model) => !_hidden.contains('${provider.slug}/$model'))
          .length;
      rows.add(
        Semantics(
          expanded: open,
          child: HermesListRow(
            key: ValueKey('model-visibility-provider-${provider.slug}'),
            leading: ProviderLogo(
              provider: provider.slug,
              providerName: provider.name,
              size: 20,
            ),
            title: provider.name.isEmpty ? provider.slug : provider.name,
            subtitle: s.mdlVisibleCount(shown, provider.models.length),
            trailing: Icon(
              open ? Icons.expand_less_rounded : Icons.expand_more_rounded,
              size: 20,
              color: colors.textDisabled,
            ),
            onTap: () => setState(
              () => _open.contains(provider.slug)
                  ? _open.remove(provider.slug)
                  : _open.add(provider.slug),
            ),
          ),
        ),
      );
      if (!open) continue;
      for (final model in models) {
        rows.add(
          HermesToggleRow(
            key: ValueKey('model-visibility-${provider.slug}-$model'),
            title: model,
            value: !_hidden.contains('${provider.slug}/$model'),
            onChanged: (shown) => _setModel(provider.slug, model, shown),
          ),
        );
      }
    }
    return HermesPage(
      // The short title the page always had: "Reset to defaults" sits next
      // to it and a longer one would be cut at phone width.
      title: s.mdlTitle,
      actions: [
        if (_hidden.isNotEmpty)
          TextButton(
            key: const ValueKey('model-visibility-reset'),
            onPressed: _reset,
            child: Text(s.mdlVisibilityReset),
          ),
      ],
      children: [
        HermesSearchField(
          hintText: s.mdlVisibilitySearch,
          clearTooltip: s.commonClose,
          onChanged: (value) => setState(() => _query = value),
        ),
        const SizedBox(height: 8),
        if (rows.isNotEmpty) HermesListGroup(children: rows),
      ],
    );
  }
}
