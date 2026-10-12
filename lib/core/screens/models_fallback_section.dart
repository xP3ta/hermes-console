// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hermes Console contributors
//
// "Fallback models" of the Models screen: Desktop's Settings → Model →
// Fallback models (`fallback-models-field.tsx`). The chain is the profile's
// `fallback_providers` list; rows are added, changed and removed one at a
// time and the list on screen is always the one the server returned.

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../design/hermes_design.dart'
    show
        HermesDialogAction,
        HermesDialogActionStyle,
        HermesStatusText,
        HermesStatusTone,
        showHermesDialog;
import '../models/fallback_chain.dart';
import '../services/connection_manager.dart';
import '../theme/app_theme.dart';
import '../widgets/hermes_premium_ui.dart'
    show HermesListRow, HermesListSection;
import 'models_look.dart';
import 'models_write.dart';

typedef ModelsPickModel =
    Future<({String provider, String model})?> Function(String title);

class ModelsFallbackSection extends StatefulWidget {
  const ModelsFallbackSection({
    required this.dashboard,
    required this.chain,
    required this.beginWrite,
    required this.pickModel,
    required this.providerName,
    required this.onChain,
    this.enabled = true,
    super.key,
  });

  /// Owned by the caller; this section never closes it.
  final DashboardClient dashboard;

  /// The chain the server last returned for the profile on screen.
  final List<FallbackEntry> chain;
  final ModelsBeginWrite beginWrite;
  final ModelsPickModel pickModel;

  /// Display name of a provider id; the id itself when it is not known.
  final String Function(String provider) providerName;

  /// The chain the server returned after a read or a write of this section.
  final ValueChanged<List<FallbackEntry>> onChain;
  final bool enabled;

  @override
  State<ModelsFallbackSection> createState() => _ModelsFallbackSectionState();
}

class _ModelsFallbackSectionState extends State<ModelsFallbackSection> {
  /// Why the last change is not on the server, as one sentence. The caller
  /// keys this section by profile, so it never outlives the profile it is
  /// about.
  String? _problem;

  Future<List<FallbackEntry>> _read(String profile) async =>
      fallbackChainOfConfigAnswer(
        await widget.dashboard.getServerConfig(profile: profile),
      );

  /// Applies [change] to the chain the server holds now, provided it still
  /// is the one the user was looking at, and shows what the server kept.
  Future<void> _write(
    ModelsWrite write,
    List<FallbackEntry> shown,
    List<FallbackEntry> Function(List<FallbackEntry> chain) change,
  ) async {
    final s = Strings.of(context);
    String? problem;
    final done = await write.run(() async {
      final before = await _read(write.profile);
      if (!sameFallbackChain(before, shown)) {
        // Changed elsewhere meanwhile: writing the list on screen would
        // undo it. Show the server's and let the user decide again.
        if (write.isCurrent) widget.onChain(before);
        problem = s.mdlFallbackChanged;
        return;
      }
      final next = change(before);
      Object? failure;
      Map<String, dynamic>? answer;
      try {
        answer = await widget.dashboard.putServerConfigPatch({
          'fallback_providers': next,
        }, profile: write.profile);
      } on DashboardWriteRevoked {
        rethrow;
      } catch (error) {
        failure = error;
      }
      // Whatever the write answered, the list on screen is the server's.
      final after = await _read(write.profile);
      if (write.isCurrent) widget.onChain(after);
      if (failure != null ||
          answer?['ok'] != true ||
          !sameFallbackChain(completeFallbacks(after), next)) {
        problem = s.mdlNotSaved;
      }
    });
    if (!mounted || !write.isCurrent) return;
    setState(() => _problem = done ? problem : null);
  }

  Future<void> _add() async {
    final write = widget.beginWrite();
    if (write == null) return;
    final shown = widget.chain;
    final picked = await widget.pickModel(Strings.of(context).mdlFallbackAdd);
    if (picked == null || !mounted || !write.isCurrent) return;
    await _write(
      write,
      shown,
      (chain) => fallbackAdded(chain, picked.provider, picked.model),
    );
  }

  Future<void> _replace(int index) async {
    final write = widget.beginWrite();
    if (write == null) return;
    final shown = widget.chain;
    final picked = await widget.pickModel(
      Strings.of(context).mdlSectionFallbacks,
    );
    if (picked == null || !mounted || !write.isCurrent) return;
    await _write(
      write,
      shown,
      (chain) => fallbackReplaced(chain, index, picked.provider, picked.model),
    );
  }

  Future<void> _remove(int index, FallbackEntry entry) async {
    final write = widget.beginWrite();
    if (write == null) return;
    final shown = widget.chain;
    final s = Strings.of(context);
    final confirmed = await showHermesDialog<bool>(
      context: context,
      title: s.mdlRemoveNamed(entry['model'] as String),
      actions: [
        HermesDialogAction(
          label: s.commonCancel,
          value: false,
          style: HermesDialogActionStyle.cancel,
        ),
        HermesDialogAction(
          label: s.mdlRemove,
          value: true,
          style: HermesDialogActionStyle.destructive,
        ),
      ],
    );
    if (confirmed != true || !mounted || !write.isCurrent) return;
    await _write(write, shown, (chain) => fallbackRemoved(chain, index));
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final rows = completeFallbacks(widget.chain);
    final problem = _problem;
    return Column(
      key: const ValueKey('models-fallbacks'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ModelsSectionLabel(s.mdlSectionFallbacks),
        // The card the page always had for its fallback, now with one row
        // per entry of the chain.
        HermesListSection(
          margin: EdgeInsets.zero,
          children: [
            for (final (index, entry) in rows.indexed)
              HermesListRow(
                key: ValueKey('models-fallback-row-$index'),
                padding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
                leading: SizedBox.square(
                  dimension: HermesListRow.leadingExtent,
                  child: Center(
                    child: Text(
                      '${index + 1}',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: colors.accentHover,
                      ),
                    ),
                  ),
                ),
                title: entry['model'] as String,
                subtitle: widget.providerName(entry['provider'] as String),
                onTap: widget.enabled ? () => _replace(index) : null,
                trailing: IconButton(
                  key: ValueKey('models-fallback-remove-$index'),
                  tooltip: s.mdlRemove,
                  icon: Icon(Icons.close, size: 18, color: colors.textDisabled),
                  onPressed: widget.enabled
                      ? () => _remove(index, entry)
                      : null,
                ),
              ),
            HermesListRow(
              key: const ValueKey('models-fallback-add'),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              icon: Icons.alt_route,
              iconColor: colors.accentHover,
              title: s.mdlFallbackAdd,
              trailing: Icon(
                Icons.chevron_right,
                size: 18,
                color: colors.textDisabled,
              ),
              onTap: widget.enabled ? _add : null,
            ),
          ],
        ),
        if (problem != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
            child: HermesStatusText(
              key: const ValueKey('models-fallback-error'),
              label: problem,
              tone: HermesStatusTone.error,
            ),
          ),
      ],
    );
  }
}
