import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../models/desktop_session_config.dart';
import '../models/model_provider.dart';
import '../theme/app_theme.dart';
import 'provider_logo.dart';
import 'subscription_limit_block.dart';

/// What the catalog says about one model card. `null` capabilities are
/// unknown, never false.
@immutable
class SessionModelCardInfo {
  const SessionModelCardInfo({
    this.usable = true,
    this.reasoning,
    this.fast,
    this.free = false,
  });

  final bool usable;
  final bool? reasoning;
  final bool? fast;
  final bool free;
}

/// Body of «Modelo y sesión»: provider tabs, model cards (✓ on the active
/// one, capabilities as subtitle), reasoning Low/Medium/High and fast mode
/// when the model supports them, the subscription limit when Hermes
/// publishes it, and the «applies from the next turn» note.
///
/// Pure projection: the chat screen owns loading and applying; every change
/// goes through its callbacks, and a null callback disables that control.
class SessionModelSheetBody extends StatefulWidget {
  const SessionModelSheetBody({
    required this.providers,
    required this.isSelected,
    required this.isSelectedProvider,
    required this.cardInfo,
    required this.modelLabel,
    required this.onPick,
    required this.reasoning,
    required this.reasoningSupported,
    required this.onReasoning,
    required this.fastMode,
    required this.fastSupported,
    required this.onFastMode,
    this.limits,
    this.header,
    super.key,
  });

  final List<ModelProvider> providers;
  final bool Function(String providerSlug, String modelId) isSelected;
  final bool Function(String providerSlug) isSelectedProvider;
  final SessionModelCardInfo Function(String providerSlug, String modelId)
  cardInfo;
  final String Function(String modelId) modelLabel;
  final void Function(ModelProvider provider, String modelId)? onPick;

  final DesktopReasoningEffort? reasoning;
  final bool reasoningSupported;
  final ValueChanged<DesktopReasoningEffort>? onReasoning;

  final DesktopFastMode? fastMode;
  final bool fastSupported;
  final ValueChanged<DesktopFastMode>? onFastMode;

  /// Only real Hermes data; null hides the block.
  final SubscriptionLimits? limits;

  /// Optional widgets between the search field and the cards (loading,
  /// errors, the bridge install offer).
  final Widget? header;

  @override
  State<SessionModelSheetBody> createState() => _SessionModelSheetBodyState();
}

class _SessionModelSheetBodyState extends State<SessionModelSheetBody> {
  String _query = '';
  String? _tab;
  bool _moreLevels = false;

  static const _mainLevels = [
    DesktopReasoningEffort.low,
    DesktopReasoningEffort.medium,
    DesktopReasoningEffort.high,
  ];

  String _initialTab() {
    for (final p in widget.providers) {
      if (widget.isSelectedProvider(p.slug)) return p.slug;
    }
    for (final p in widget.providers) {
      if (p.isCurrent) return p.slug;
    }
    return widget.providers.first.slug;
  }

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final searching = _query.trim().isNotEmpty;
    final providers = filterModelProviders(widget.providers, _query);
    final children = <Widget>[
      TextField(
        key: const ValueKey('chat-model-search'),
        textInputAction: TextInputAction.search,
        onChanged: (value) => setState(() => _query = value),
        decoration: InputDecoration(
          hintText: strings.modelSearchHint,
          prefixIcon: const Icon(Icons.search_rounded),
          isDense: true,
        ),
      ),
      const SizedBox(height: 10),
      ?widget.header,
    ];

    if (widget.providers.isNotEmpty) {
      if (searching) {
        if (providers.isEmpty) {
          children.add(
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Text(
                strings.modelSearchEmpty,
                style: TextStyle(fontSize: 12.5, color: colors.textSecondary),
              ),
            ),
          );
        }
        for (final p in providers) {
          children
            ..add(_ProviderHeader(provider: p))
            ..add(_cards(p));
        }
      } else if (widget.providers.length == 1) {
        final p = widget.providers.single;
        children
          ..add(_ProviderHeader(provider: p))
          ..add(_cards(p));
      } else {
        final tab = widget.providers.any((p) => p.slug == _tab)
            ? _tab!
            : _initialTab();
        children.add(
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final p in widget.providers)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: _ProviderTab(
                      provider: p,
                      selected: p.slug == tab,
                      active: widget.isSelectedProvider(p.slug),
                      onTap: () => setState(() => _tab = p.slug),
                    ),
                  ),
              ],
            ),
          ),
        );
        children
          ..add(const SizedBox(height: 10))
          ..add(_cards(widget.providers.firstWhere((p) => p.slug == tab)));
      }
    }

    children
      ..add(const SizedBox(height: 6))
      ..add(const Divider(height: 20))
      ..add(_reasoningSection(strings, colors))
      ..add(const Divider(height: 20))
      ..add(_fastSection(strings, colors));
    final limits = widget.limits;
    if (limits != null) {
      children
        ..add(const SizedBox(height: 12))
        ..add(SubscriptionLimitBlock(limits: limits));
    }
    children
      ..add(const SizedBox(height: 12))
      ..add(
        Text(
          strings.sp1215AppliesNextTurn,
          style: TextStyle(fontSize: 12.5, color: colors.textSecondary),
        ),
      );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }

  Widget _cards(ModelProvider provider) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final twoColumns =
            constraints.maxWidth >= 300 &&
            MediaQuery.textScalerOf(context).scale(14) < 22;
        final width = twoColumns
            ? (constraints.maxWidth - 8) / 2
            : constraints.maxWidth;
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final id in provider.models)
              SizedBox(
                width: width,
                child: _ModelCard(
                  key: ValueKey('model-card-${provider.slug}-$id'),
                  provider: provider,
                  modelId: id,
                  label: widget.modelLabel(id),
                  info: widget.cardInfo(provider.slug, id),
                  active: widget.isSelected(provider.slug, id),
                  onPick: widget.onPick,
                ),
              ),
          ],
        );
      },
    );
  }

  String _levelLabel(Strings strings, DesktopReasoningEffort effort) =>
      switch (effort) {
        DesktopReasoningEffort.low => strings.sp1215ReasoningLow,
        DesktopReasoningEffort.medium => strings.sp1215ReasoningMedium,
        DesktopReasoningEffort.high => strings.sp1215ReasoningHigh,
        _ => effort.wire,
      };

  Widget _levelChip(Strings strings, DesktopReasoningEffort effort) {
    final onReasoning = widget.onReasoning;
    return ChoiceChip(
      label: Text(_levelLabel(strings, effort)),
      selected: widget.reasoning == effort,
      showCheckmark: false,
      visualDensity: VisualDensity.compact,
      onSelected: onReasoning == null || widget.reasoning == effort
          ? null
          : (_) => onReasoning(effort),
    );
  }

  Widget _reasoningSection(Strings strings, HermesThemeColors colors) {
    final current = widget.reasoning;
    final extraCurrent = current != null && !_mainLevels.contains(current)
        ? current
        : null;
    final others = [
      for (final e in DesktopReasoningEffort.values)
        if (!_mainLevels.contains(e) && e != extraCurrent) e,
    ];
    return _SettingBlock(
      title: strings.chaSessionReasoningLabel,
      hint: strings.sp1215ReasoningHint,
      control: !widget.reasoningSupported
          ? null
          : Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final e in _mainLevels) _levelChip(strings, e),
                if (extraCurrent != null) _levelChip(strings, extraCurrent),
                if (_moreLevels)
                  for (final e in others) _levelChip(strings, e)
                else
                  TextButton(
                    key: const ValueKey('session-reasoning-more'),
                    onPressed: () => setState(() => _moreLevels = true),
                    child: Text(strings.sp1215ReasoningMore),
                  ),
              ],
            ),
      unsupported: widget.reasoningSupported
          ? null
          : strings.chaModelReasoningUnavailable,
    );
  }

  Widget _fastSection(Strings strings, HermesThemeColors colors) {
    final onFastMode = widget.onFastMode;
    final enabled = widget.fastMode == DesktopFastMode.fast;
    return _SettingBlock(
      title: strings.chaSessionFastLabel,
      hint: strings.sp1215FastHint,
      inline: true,
      control: !widget.fastSupported
          ? null
          : Switch(
              key: const ValueKey('session-fast-switch'),
              value: enabled,
              onChanged: onFastMode == null
                  ? null
                  : (on) => onFastMode(
                      on ? DesktopFastMode.fast : DesktopFastMode.normal,
                    ),
            ),
      unsupported: widget.fastSupported
          ? null
          : strings.chaModelFastUnavailable,
    );
  }
}

class _SettingBlock extends StatelessWidget {
  const _SettingBlock({
    required this.title,
    required this.hint,
    required this.control,
    required this.unsupported,
    this.inline = false,
  });

  final String title;
  final String hint;
  final Widget? control;
  final String? unsupported;
  final bool inline;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final label = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: colors.textPrimary,
          ),
        ),
        Text(hint, style: TextStyle(fontSize: 12, color: colors.textSecondary)),
      ],
    );
    final children = <Widget>[];
    if (inline && control != null) {
      children.add(
        Row(
          children: [
            Expanded(child: label),
            const SizedBox(width: 8),
            control!,
          ],
        ),
      );
    } else {
      children.add(label);
      if (control != null) {
        children
          ..add(const SizedBox(height: 8))
          ..add(control!);
      }
    }
    if (unsupported != null) {
      children
        ..add(const SizedBox(height: 6))
        ..add(
          Text(
            unsupported!,
            style: TextStyle(fontSize: 12, color: colors.textSecondary),
          ),
        );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }
}

class _ProviderHeader extends StatelessWidget {
  const _ProviderHeader({required this.provider});

  final ModelProvider provider;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 8),
      child: Row(
        children: [
          ProviderLogo(
            key: ValueKey('provider-logo-picker-provider-${provider.slug}'),
            provider: provider.slug,
            providerName: provider.name,
            size: 16,
            color: colors.accent,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              (provider.name.isNotEmpty ? provider.name : provider.slug)
                  .toUpperCase(),
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
                color: colors.accent,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProviderTab extends StatelessWidget {
  const _ProviderTab({
    required this.provider,
    required this.selected,
    required this.active,
    required this.onTap,
  });

  final ModelProvider provider;
  final bool selected;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final name = provider.name.isNotEmpty ? provider.name : provider.slug;
    return Semantics(
      key: ValueKey('model-provider-tab-${provider.slug}'),
      button: true,
      selected: selected,
      child: Material(
        color: selected
            ? colors.surfaceVariant
            : colors.surfaceVariant.withValues(alpha: 0.35),
        shape: StadiumBorder(
          side: BorderSide(
            color: selected
                ? colors.accent.withValues(alpha: 0.6)
                : colors.divider.withValues(alpha: 0.6),
          ),
        ),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 40),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (active) ...[
                    Container(
                      key: const ValueKey('model-provider-active-dot'),
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: colors.accent,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  ProviderLogo(
                    key: ValueKey(
                      'provider-logo-picker-provider-${provider.slug}',
                    ),
                    provider: provider.slug,
                    providerName: provider.name,
                    size: 15,
                    color: selected ? colors.accent : colors.textSecondary,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    name,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: selected
                          ? colors.textPrimary
                          : colors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ModelCard extends StatelessWidget {
  const _ModelCard({
    required this.provider,
    required this.modelId,
    required this.label,
    required this.info,
    required this.active,
    required this.onPick,
    super.key,
  });

  final ModelProvider provider;
  final String modelId;
  final String label;
  final SessionModelCardInfo info;
  final bool active;
  final void Function(ModelProvider provider, String modelId)? onPick;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final known = info.reasoning != null || info.fast != null;
    final caps = [
      if (info.reasoning == true) strings.sp1215CapReasoning,
      if (info.fast == true) strings.sp1215CapFast,
      if (info.free) strings.sp1215CapFree,
    ];
    final subtitle = !info.usable
        ? '$modelId · ${strings.chaModelUnavailable}'
        : caps.isNotEmpty
        ? caps.join(' · ')
        : known
        ? strings.sp1215CapBasic
        // Unknown capabilities: the raw id tells same-named models apart,
        // unless the title already is that id.
        : label == modelId
        ? null
        : modelId;
    final pick = onPick;
    final enabled = pick != null && info.usable && !active;
    return Semantics(
      button: true,
      selected: active,
      enabled: info.usable,
      child: Material(
        color: active
            ? colors.accent.withValues(alpha: 0.14)
            : colors.surfaceVariant.withValues(alpha: 0.45),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
            color: active
                ? colors.accent.withValues(alpha: 0.7)
                : colors.divider.withValues(alpha: 0.5),
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: enabled ? () => pick(provider, modelId) : null,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 9, 10, 9),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 1, right: 8),
                    child: ProviderLogo(
                      key: ValueKey(
                        'provider-logo-picker-model-${provider.slug}-$modelId',
                      ),
                      provider: provider.slug,
                      providerName: provider.name,
                      model: modelId,
                      size: 16,
                      selected: active && info.usable,
                      color: info.usable ? null : colors.textDisabled,
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          label,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: !info.usable
                                ? colors.textDisabled
                                : colors.textPrimary,
                          ),
                        ),
                        if (subtitle != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            subtitle,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11.5,
                              color: colors.textSecondary,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (active)
                    Icon(Icons.check_rounded, size: 18, color: colors.accent)
                  else if (!info.usable)
                    Icon(
                      Icons.block_outlined,
                      size: 16,
                      color: colors.textDisabled,
                    )
                  else if (info.free)
                    Icon(
                      Icons.savings_outlined,
                      size: 16,
                      color: colors.success,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
