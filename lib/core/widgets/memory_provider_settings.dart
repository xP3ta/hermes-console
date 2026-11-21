// The memory provider of a profile: which one is active, which one is
// selected, and the settings the provider's plugin declares.
//
// Behaviour copied from Hermes Desktop (`apps/desktop/src/app/settings/`):
//  - `memory/memory-layers.tsx`: the active provider is the saved one that
//    `GET /api/memory` reports; the selected one is this page's choice,
//    shown apart only while it differs; the built-in layer is never
//    replaced by a provider.
//  - `config-settings.tsx:225-287,565-581`: the provider is the generic
//    `memory.provider` select, saved by itself 550 ms after a change, with
//    no question asked; a choice made and left before that is not saved.
//  - `memory/provider-config-panel.tsx`, `provider-config-modal.tsx`,
//    `field-control.tsx`: a form made of the fields the plugin declares,
//    each saved alone when committed; «Full config…» only when a field is
//    not inline; secrets are write-only and blank keeps the stored one.
//  - `memory/connect.tsx`: OAuth connect only where the status route
//    answers, polled every 1.5 s for at most two minutes.
//
// Nothing a field holds is ever logged.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_localizations.dart';
import '../design/hermes_design.dart'
    show
        HermesAction,
        HermesActionButton,
        HermesInlineNotice,
        HermesRadius,
        HermesSpace,
        HermesStatusTone,
        HermesStatusToneColor,
        HermesTag,
        HermesType,
        showHermesMenu;
import '../design/hicons.dart';
import '../feedback/feedback_policy.dart';
import '../models/memory_info.dart';
import '../models/memory_provider_config.dart';
import '../services/memory_settings_api.dart';
import '../theme/app_theme.dart';
import 'hermes_app_bar.dart';

/// Desktop `POLL_MS` / `POLL_TIMEOUT_MS` (`memory/connect.tsx:10-11`):
/// 1500 ms and 120 s. Waits of the protocol, not motion: no HermesMotion
/// token stands for them.
const Duration kMemoryOAuthPoll = Duration(seconds: 1, milliseconds: 500);
const Duration kMemoryOAuthPollLimit = Duration(seconds: 120);

/// Desktop's autosave delay (`config-settings.tsx:285`): 550 ms, a wait
/// before a write, not motion.
const Duration kMemoryProviderSaveDelay = Duration(
  microseconds: 550 * Duration.microsecondsPerMillisecond,
);

class MemoryProviderSettings extends StatefulWidget {
  const MemoryProviderSettings({
    required this.api,
    required this.status,
    required this.onStatusChanged,
    required this.profileLabel,
    this.readOnly = false,
    super.key,
  });

  final MemorySettingsApi api;

  /// What `GET /api/memory` answered for this profile.
  final MemoryInfo status;

  /// Reads the status again (a save may have changed what is active or
  /// whether it is ready).
  final Future<void> Function() onStatusChanged;

  /// The profile's name as the full configuration names it.
  final String profileLabel;
  final bool readOnly;

  @override
  State<MemoryProviderSettings> createState() => _MemoryProviderSettingsState();
}

class _MemoryProviderSettingsState extends State<MemoryProviderSettings> {
  Map<String, dynamic>? _memory;
  List<String>? _options;
  bool _loading = true;
  bool _configMissing = false;
  bool _configFailed = false;

  /// This page's choice of provider; null until the config is read.
  String? _draft;
  Timer? _saveTimer;
  int _load = 0;
  final GlobalKey _selectAnchor = GlobalKey(debugLabel: 'memory-provider');

  @override
  void initState() {
    super.initState();
    unawaited(_read());
  }

  @override
  void didUpdateWidget(MemoryProviderSettings old) {
    super.didUpdateWidget(old);
    if (old.api.profile != widget.api.profile) {
      _saveTimer?.cancel();
      _draft = null;
      _memory = null;
      unawaited(_read());
    }
  }

  @override
  void dispose() {
    // Like Desktop, a choice made less than the delay ago is not saved.
    _saveTimer?.cancel();
    super.dispose();
  }

  Future<void> _read() async {
    final load = ++_load;
    setState(() {
      _loading = true;
      _configMissing = false;
      _configFailed = false;
    });
    Map<String, dynamic>? memory;
    var missing = false;
    var failed = false;
    try {
      memory = await widget.api.memoryConfig();
    } catch (error) {
      missing = memoryRouteMissing(error);
      failed = !missing;
    }
    List<String>? options;
    if (memory != null) {
      try {
        options = await widget.api.providerOptions();
      } catch (_) {
        options = null;
      }
    }
    if (!mounted || load != _load) return;
    setState(() {
      _loading = false;
      _memory = memory;
      _options = options;
      _configMissing = missing;
      _configFailed = failed;
      final saved = memory?['provider'];
      _draft = memory == null ? null : (saved is String ? saved.trim() : '');
    });
  }

  MemoryProviderStatus? _statusOf(String name) {
    for (final provider in widget.status.providers) {
      if (provider.name == name) {
        return provider.status == MemoryProviderStatus.unknown
            ? null
            : provider.status;
      }
    }
    return null;
  }

  String? get _activeName {
    final active = widget.status.active.trim();
    return isExternalMemoryProvider(active) ? active : null;
  }

  String? get _selectedName {
    final draft = _draft;
    if (draft == null) return null;
    return isExternalMemoryProvider(draft) ? draft : null;
  }

  /// The select's choices: «Built-in only», then what the server's schema
  /// lists; without a schema list, the providers the status names. The
  /// current choice is always among them.
  List<String> get _choices {
    final listed =
        _options ??
        [
          for (final provider in widget.status.providers)
            if (isExternalMemoryProvider(provider.name)) provider.name,
        ];
    final selected = _selectedName;
    return [
      '',
      for (final name in listed)
        if (isExternalMemoryProvider(name)) name,
      if (selected != null && !listed.contains(selected)) selected,
    ];
  }

  Future<void> _pick() async {
    final strings = Strings.of(context);
    final current = _selectedName ?? '';
    final chosen = await showHermesMenu<String>(
      context: context,
      anchorKey: _selectAnchor,
      title: strings.mempProviderField,
      actions: [
        for (final choice in _choices)
          HermesAction<String>(
            key: ValueKey('memory-provider-option-$choice'),
            value: choice,
            label: choice.isEmpty ? strings.mempBuiltinOnly : choice,
            selected: choice == current,
          ),
      ],
    );
    if (chosen == null || !mounted || chosen == current) return;
    setState(() => _draft = chosen);
    _saveTimer?.cancel();
    _saveTimer = Timer(kMemoryProviderSaveDelay, () => unawaited(_save()));
  }

  Future<void> _save() async {
    final draft = _draft;
    if (draft == null || !mounted) return;
    final notices = AppFeedback.of(context);
    final failed = Strings.of(context).mempProviderSaveFailed;
    try {
      await widget.api.putMemoryConfig({'provider': draft});
      // The summary's active provider is the saved one: read it again.
      await widget.onStatusChanged();
    } catch (_) {
      if (mounted) notices.notify(FeedbackKind.error, failed);
    }
  }

  Widget _providerName(String? name) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    if (name == null) {
      return Text(
        strings.mempNoProvider,
        style: TextStyle(
          fontSize: HermesType.valueSize,
          color: colors.textSecondary,
        ),
      );
    }
    final status = _statusOf(name);
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          name,
          style: TextStyle(
            fontFamily: 'JetBrainsMono',
            fontSize: HermesType.valueSize,
            color: colors.textPrimary,
          ),
        ),
        if (status != null)
          HermesTag(
            key: ValueKey('memory-provider-status-$name'),
            tone: switch (status) {
              MemoryProviderStatus.ready => HermesStatusTone.ok,
              MemoryProviderStatus.needsConfig => HermesStatusTone.warn,
              _ => HermesStatusTone.error,
            },
            label: switch (status) {
              MemoryProviderStatus.ready => strings.mempStatusReady,
              MemoryProviderStatus.needsConfig => strings.mempStatusNeedsSetup,
              MemoryProviderStatus.unavailable =>
                strings.mempStatusUnavailable,
              _ => strings.mempStatusMissing,
            },
          ),
      ],
    );
  }

  /// Recall is claimed only for a saved provider the status calls ready
  /// (`memory-layers.tsx:79-90`).
  String _activeDescription(String? name) {
    final strings = Strings.of(context);
    if (name == null) return strings.mempNoProviderDesc;
    final status = _statusOf(name);
    if (status == null) return strings.mempProviderUnknownDesc(name);
    return status == MemoryProviderStatus.ready
        ? strings.mempProviderDesc(name)
        : strings.mempProviderNotReadyDesc(name);
  }

  Widget _builtinPill() {
    final strings = Strings.of(context);
    final memory = _memory;
    if (memory == null) {
      return HermesTag(
        tone: HermesStatusTone.ok,
        label: strings.mempOnByDefault,
      );
    }
    final file = memory['memory_enabled'] != false;
    final user = memory['user_profile_enabled'] != false;
    if (file && user) {
      return HermesTag(tone: HermesStatusTone.ok, label: strings.mempOn);
    }
    if (!file && !user) {
      return HermesTag(tone: HermesStatusTone.neutral, label: strings.mempOff);
    }
    return HermesTag(
      tone: HermesStatusTone.warn,
      label: strings.mempOnlyFile(file ? 'MEMORY.md' : 'USER.md'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final active = _activeName;
    final selected = _selectedName;
    final showSelected = _draft != null && selected != active;
    final external = selected;
    return Card(
      key: const ValueKey('memory-provider-settings'),
      color: colors.surfaceVariant.withValues(alpha: 0.35),
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(HermesRadius.control),
      ),
      child: Padding(
        padding: const EdgeInsets.all(HermesSpace.x4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (showSelected) ...[
              _LayerRow(
                key: const ValueKey('memory-selected-provider'),
                title: strings.mempSelectedProvider,
                description: strings.mempSelectedDesc(
                  active ?? strings.mempBuiltinMemory,
                ),
                trailing: _providerName(selected),
              ),
              const SizedBox(height: HermesSpace.x4),
            ],
            _LayerRow(
              key: const ValueKey('memory-active-provider'),
              title: strings.mempActiveProvider,
              description: _activeDescription(active),
              trailing: _providerName(active),
            ),
            const SizedBox(height: HermesSpace.x4),
            _LayerRow(
              key: const ValueKey('memory-builtin-layer'),
              title: strings.mempBuiltinLayer,
              description: strings.mempBuiltinDesc,
              trailing: _builtinPill(),
            ),
            const SizedBox(height: HermesSpace.x4),
            if (_loading && _memory == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Center(
                  child: SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            else if (_memory == null)
              HermesInlineNotice(
                key: const ValueKey('memory-provider-config-unavailable'),
                message: _configMissing
                    ? strings.mempSelectUnsupported
                    : strings.mempConfigUnavailable,
                tone: _configMissing
                    ? HermesStatusTone.neutral
                    : HermesStatusTone.warn,
                actionLabel: _configFailed ? strings.commonRetry : null,
                onAction: _configFailed ? () => unawaited(_read()) : null,
              )
            else ...[
              _ProviderSelect(
                key: const ValueKey('memory-provider-select'),
                anchorKey: _selectAnchor,
                title: strings.mempProviderField,
                value: selected ?? strings.mempBuiltinOnly,
                onTap: widget.readOnly ? null : () => unawaited(_pick()),
              ),
              if (external != null) ...[
                MemoryProviderConnect(
                  key: ValueKey('memory-connect-$external'),
                  api: widget.api,
                  provider: external,
                  readOnly: widget.readOnly,
                  onConnected: widget.onStatusChanged,
                ),
                MemoryProviderConfigPanel(
                  key: ValueKey('memory-config-$external'),
                  api: widget.api,
                  provider: external,
                  profileLabel: widget.profileLabel,
                  readOnly: widget.readOnly,
                  onSaved: widget.onStatusChanged,
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _LayerRow extends StatelessWidget {
  const _LayerRow({
    required this.title,
    required this.description,
    required this.trailing,
    super.key,
  });

  final String title;
  final String description;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 12,
            color: colors.textSecondary,
            letterSpacing: 0.6,
          ),
        ),
        const SizedBox(height: 6),
        trailing,
        const SizedBox(height: 6),
        Text(
          description,
          style: TextStyle(
            fontSize: HermesType.valueSize,
            height: 1.35,
            color: colors.textSecondary,
          ),
        ),
      ],
    );
  }
}

class _ProviderSelect extends StatelessWidget {
  const _ProviderSelect({
    required this.anchorKey,
    required this.title,
    required this.value,
    required this.onTap,
    super.key,
  });

  final GlobalKey anchorKey;
  final String title;
  final String value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: '$title: $value',
      excludeSemantics: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(HermesRadius.control),
        onTap: onTap,
        child: Container(
          key: anchorKey,
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.symmetric(
            horizontal: HermesSpace.x3,
            vertical: 8,
          ),
          decoration: BoxDecoration(
            border: Border.all(color: colors.divider),
            borderRadius: BorderRadius.circular(HermesRadius.control),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      value,
                      style: TextStyle(
                        fontSize: HermesType.valueSize,
                        fontWeight: FontWeight.w600,
                        color: onTap == null
                            ? colors.textSecondary
                            : colors.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                HIcons.expand_more,
                size: 18,
                color: colors.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// The provider's own settings
// ---------------------------------------------------------------------------

/// What the inline fields hold when the panel opens: a secret starts blank
/// (`provider-config-panel.tsx` `seedValues`).
Map<String, String> _seed(Iterable<MemoryProviderField> fields) => {
  for (final field in fields) field.key: field.isSecret ? '' : field.value,
};

class MemoryProviderConfigPanel extends StatefulWidget {
  const MemoryProviderConfigPanel({
    required this.api,
    required this.provider,
    required this.profileLabel,
    required this.onSaved,
    this.readOnly = false,
    super.key,
  });

  final MemorySettingsApi api;
  final String provider;
  final String profileLabel;
  final Future<void> Function() onSaved;
  final bool readOnly;

  @override
  State<MemoryProviderConfigPanel> createState() =>
      _MemoryProviderConfigPanelState();
}

class _MemoryProviderConfigPanelState
    extends State<MemoryProviderConfigPanel> {
  MemoryProviderConfig? _config;
  bool _unsupported = false;
  String? _loadError;
  Map<String, String> _values = {};
  Map<String, String> _saved = {};
  bool _expanded = true;
  int _load = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    final load = ++_load;
    try {
      final next = await widget.api.providerConfig(widget.provider);
      if (!mounted || load != _load) return;
      setState(() {
        _config = next;
        _unsupported = next == null;
        _loadError = null;
        final seed = next == null
            ? <String, String>{}
            : _seed(next.inlineFields);
        _values = Map.of(seed);
        _saved = seed;
      });
    } catch (error) {
      if (!mounted || load != _load) return;
      setState(() {
        _config = null;
        _unsupported = memoryRouteMissing(error);
        _loadError = _unsupported
            ? null
            : (memoryServerDetail(error) ?? error.toString());
      });
    }
  }

  /// One key, alone, when a field is committed; silent when it works
  /// (`provider-config-panel.tsx:56-85`).
  Future<void> _commit(MemoryProviderField field, String value) async {
    if (widget.readOnly) return;
    if (value == (_saved[field.key] ?? '') ||
        (field.isSecret && value.trim().isEmpty)) {
      return;
    }
    final notices = AppFeedback.of(context);
    final failed = Strings.of(context).mempSaveFieldFailed(field.label);
    try {
      await widget.api.saveProviderConfig(widget.provider, {field.key: value});
      unawaited(widget.onSaved());
      if (!mounted) return;
      setState(() {
        if (field.isSecret) {
          _values = {..._values, field.key: ''};
          final config = _config;
          if (config != null) {
            _config = MemoryProviderConfig(
              name: config.name,
              label: config.label,
              docsUrl: config.docsUrl,
              fields: [
                for (final other in config.fields)
                  other.key == field.key ? other.copyWith(isSet: true) : other,
              ],
            );
          }
        } else {
          _saved = {..._saved, field.key: value};
        }
      });
    } catch (error) {
      if (!mounted) return;
      // The server's reason, never for a secret: it could repeat the value.
      final detail = field.isSecret ? null : memoryServerDetail(error);
      notices.notify(
        FeedbackKind.error,
        detail == null ? failed : '$failed: $detail',
      );
    }
  }

  Future<void> _openFull(MemoryProviderConfig config) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => MemoryProviderFullConfigScreen(
          api: widget.api,
          provider: widget.provider,
          config: config,
          profileLabel: widget.profileLabel,
          readOnly: widget.readOnly,
        ),
      ),
    );
    if (saved != true || !mounted) return;
    unawaited(widget.onSaved());
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final config = _config;
    if (config == null) {
      if (_unsupported) {
        return Padding(
          padding: const EdgeInsets.only(top: HermesSpace.x3),
          child: HermesInlineNotice(
            key: const ValueKey('memory-config-unsupported'),
            message: strings.mempUnsupported,
          ),
        );
      }
      final error = _loadError;
      if (error != null) {
        return Padding(
          padding: const EdgeInsets.only(top: HermesSpace.x3),
          child: HermesInlineNotice(
            key: const ValueKey('memory-config-failed'),
            message: strings.mempLoadFailed(error),
            tone: HermesStatusTone.warn,
            actionLabel: strings.commonRetry,
            onAction: () => unawaited(_refresh()),
          ),
        );
      }
      return Padding(
        padding: const EdgeInsets.only(top: HermesSpace.x4),
        child: Row(
          children: [
            const SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                strings.mempLoading,
                style: TextStyle(
                  fontSize: HermesType.valueSize,
                  color: colors.textSecondary,
                ),
              ),
            ),
          ],
        ),
      );
    }
    // A provider that declares nothing (the built-in one) shows nothing.
    if (config.fields.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: HermesSpace.x4),
      child: Column(
        key: const ValueKey('memory-config-panel'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            key: const ValueKey('memory-config-toggle'),
            borderRadius: BorderRadius.circular(HermesRadius.control),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Icon(
                    _expanded ? HIcons.expand_more : HIcons.chevron_right,
                    size: 18,
                    color: colors.textSecondary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Semantics(
                      header: true,
                      expanded: _expanded,
                      child: Text(
                        strings.mempSettingsTitle(config.label),
                        style: TextStyle(
                          fontSize: HermesType.valueSize,
                          fontWeight: FontWeight.w600,
                          color: colors.textPrimary,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (config.secretFields.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final field in config.secretFields)
                    HermesTag(
                      key: ValueKey('memory-secret-pill-${field.key}'),
                      tone: field.isSet
                          ? HermesStatusTone.ok
                          : HermesStatusTone.neutral,
                      label: field.isSet
                          ? strings.mempSecretSet(field.label)
                          : strings.mempSecretNotSet(field.label),
                    ),
                ],
              ),
            ),
          if (config.hasFullConfig)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: HermesActionButton(
                key: const ValueKey('memory-full-config'),
                label: strings.mempFullConfig,
                icon: HIcons.tune,
                onPressed: () => unawaited(_openFull(config)),
              ),
            ),
          if (_expanded)
            for (final field in config.inlineFields)
              MemoryProviderFieldRow(
                key: ValueKey('memory-field-${field.key}'),
                field: field,
                value: _values[field.key] ?? '',
                enabled: !widget.readOnly,
                onChanged: (value) =>
                    setState(() => _values = {..._values, field.key: value}),
                onCommit: (value) => unawaited(_commit(field, value)),
              ),
        ],
      ),
    );
  }
}

/// A field's name, what it is for, and its control under them.
class MemoryProviderFieldRow extends StatelessWidget {
  const MemoryProviderFieldRow({
    required this.field,
    required this.value,
    required this.onChanged,
    this.onCommit,
    this.enabled = true,
    super.key,
  });

  final MemoryProviderField field;
  final String value;
  final ValueChanged<String> onChanged;

  /// Present where a field saves by itself: a switch or a choice commits
  /// when it changes, text when it loses the focus. Absent in the full
  /// configuration, where edits wait for «Save changes».
  final ValueChanged<String>? onCommit;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final isSwitch = field.kind == MemoryProviderFieldKind.bool;
    final title = Row(
      children: [
        Flexible(
          child: Text(
            field.label,
            style: TextStyle(
              fontSize: HermesType.valueSize,
              fontWeight: FontWeight.w600,
              color: colors.textPrimary,
            ),
          ),
        ),
        if (field.info.isNotEmpty)
          Tooltip(
            message: field.info,
            triggerMode: TooltipTriggerMode.tap,
            showDuration: const Duration(seconds: 8),
            child: Semantics(
              label: strings.mempAboutField(field.label),
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Icon(
                  HIcons.info_outline_rounded,
                  size: 16,
                  color: colors.textSecondary,
                ),
              ),
            ),
          ),
      ],
    );
    final control = _MemoryFieldControl(
      field: field,
      value: value,
      enabled: enabled,
      onChanged: onChanged,
      onCommit: onCommit,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isSwitch)
            Row(
              children: [
                Expanded(child: title),
                control,
              ],
            )
          else
            title,
          if (field.description.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              field.description,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.35,
                color: colors.textSecondary,
              ),
            ),
          ],
          if (!isSwitch) ...[const SizedBox(height: 8), control],
        ],
      ),
    );
  }
}

class _MemoryFieldControl extends StatefulWidget {
  const _MemoryFieldControl({
    required this.field,
    required this.value,
    required this.enabled,
    required this.onChanged,
    required this.onCommit,
  });

  final MemoryProviderField field;
  final String value;
  final bool enabled;
  final ValueChanged<String> onChanged;
  final ValueChanged<String>? onCommit;

  @override
  State<_MemoryFieldControl> createState() => _MemoryFieldControlState();
}

class _MemoryFieldControlState extends State<_MemoryFieldControl> {
  late final TextEditingController _text = TextEditingController(
    text: widget.value,
  );
  final FocusNode _focus = FocusNode();
  final GlobalKey _anchor = GlobalKey(debugLabel: 'memory-field');

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
  }

  @override
  void didUpdateWidget(_MemoryFieldControl old) {
    super.didUpdateWidget(old);
    // A saved secret empties; a refreshed form brings its own values.
    if (widget.value != _text.text) _text.text = widget.value;
  }

  @override
  void dispose() {
    _focus
      ..removeListener(_onFocus)
      ..dispose();
    _text.dispose();
    super.dispose();
  }

  void _onFocus() {
    if (!_focus.hasFocus) widget.onCommit?.call(_text.text);
  }

  void _set(String next) {
    widget.onChanged(next);
    widget.onCommit?.call(next);
  }

  Future<void> _choose() async {
    final field = widget.field;
    final chosen = await showHermesMenu<String>(
      context: context,
      anchorKey: _anchor,
      title: field.label,
      actions: [
        for (final option in field.options)
          HermesAction<String>(
            key: ValueKey('memory-field-${field.key}-option-${option.value}'),
            value: option.value,
            label: option.label,
            selected: option.value == widget.value,
          ),
      ],
    );
    if (chosen == null || !mounted || chosen == widget.value) return;
    _set(chosen);
  }

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final field = widget.field;
    switch (field.kind) {
      case MemoryProviderFieldKind.bool:
        return Switch(
          key: ValueKey('memory-field-${field.key}-switch'),
          value: widget.value == 'true',
          onChanged: widget.enabled
              ? (checked) => _set(checked ? 'true' : 'false')
              : null,
        );
      case MemoryProviderFieldKind.select:
        String label = widget.value;
        for (final option in field.options) {
          if (option.value == widget.value) label = option.label;
        }
        return InkWell(
          key: ValueKey('memory-field-${field.key}-select'),
          borderRadius: BorderRadius.circular(HermesRadius.control),
          onTap: widget.enabled ? () => unawaited(_choose()) : null,
          child: Container(
            key: _anchor,
            constraints: const BoxConstraints(minHeight: 44),
            padding: const EdgeInsets.symmetric(
              horizontal: HermesSpace.x3,
              vertical: 8,
            ),
            decoration: BoxDecoration(
              border: Border.all(color: colors.divider),
              borderRadius: BorderRadius.circular(HermesRadius.control),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: HermesType.valueSize,
                      color: colors.textPrimary,
                    ),
                  ),
                ),
                Icon(
                  HIcons.expand_more,
                  size: 18,
                  color: colors.textSecondary,
                ),
              ],
            ),
          ),
        );
      case MemoryProviderFieldKind.secret:
      case MemoryProviderFieldKind.number:
      case MemoryProviderFieldKind.json:
      case MemoryProviderFieldKind.text:
        final secret = field.isSecret;
        final json = field.kind == MemoryProviderFieldKind.json;
        final input = TextField(
          key: ValueKey('memory-field-${field.key}-input'),
          controller: _text,
          focusNode: _focus,
          enabled: widget.enabled,
          // A secret is never shown: there is nothing to reveal, the stored
          // value is not sent to the app.
          obscureText: secret,
          autocorrect: false,
          enableSuggestions: false,
          enableIMEPersonalizedLearning: !secret,
          autofillHints: const <String>[],
          smartDashesType: SmartDashesType.disabled,
          smartQuotesType: SmartQuotesType.disabled,
          keyboardType: secret
              ? TextInputType.visiblePassword
              : field.kind == MemoryProviderFieldKind.number
              ? const TextInputType.numberWithOptions(
                  signed: true,
                  decimal: true,
                )
              : json
              ? TextInputType.multiline
              : TextInputType.text,
          inputFormatters: field.kind == MemoryProviderFieldKind.number
              ? [FilteringTextInputFormatter.allow(RegExp(r'[0-9eE+\-.]'))]
              : null,
          minLines: json ? 3 : 1,
          maxLines: secret
              ? 1
              : json
              ? 8
              : 1,
          textInputAction: json ? TextInputAction.newline : TextInputAction.done,
          onChanged: widget.onChanged,
          onSubmitted: json ? null : (_) => _focus.unfocus(),
          style: TextStyle(
            fontFamily: 'JetBrainsMono',
            fontSize: HermesType.valueSize,
            color: colors.textPrimary,
          ),
          decoration: InputDecoration(
            isDense: true,
            hintText: secret && field.isSet
                ? strings.mempSecretKeep
                : (field.placeholder.isEmpty ? null : field.placeholder),
            hintStyle: TextStyle(
              color: colors.textSecondary.withValues(alpha: 0.55),
            ),
            contentPadding: const EdgeInsets.symmetric(
              vertical: 10,
              horizontal: HermesSpace.x3,
            ),
          ),
        );
        if (!secret || !field.isSet) return input;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            input,
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  HIcons.check,
                  size: 13,
                  color: HermesStatusTone.ok.colorIn(colors),
                ),
                const SizedBox(width: 4),
                Text(
                  strings.mempSecretIsSet,
                  style: TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 11,
                    color: colors.textSecondary,
                  ),
                ),
              ],
            ),
          ],
        );
    }
  }
}

// ---------------------------------------------------------------------------
// Full configuration
// ---------------------------------------------------------------------------

/// Every field the provider declares, grouped; nothing is saved until
/// «Save changes», which sends only what was edited
/// (`provider-config-modal.tsx`). A dialog in Desktop, a screen on a phone.
/// Pops true once saved.
class MemoryProviderFullConfigScreen extends StatefulWidget {
  const MemoryProviderFullConfigScreen({
    required this.api,
    required this.provider,
    required this.config,
    required this.profileLabel,
    this.readOnly = false,
    super.key,
  });

  final MemorySettingsApi api;
  final String provider;
  final MemoryProviderConfig config;
  final String profileLabel;
  final bool readOnly;

  @override
  State<MemoryProviderFullConfigScreen> createState() =>
      _MemoryProviderFullConfigScreenState();
}

class _MemoryProviderFullConfigScreenState
    extends State<MemoryProviderFullConfigScreen> {
  late final Map<String, String> _seeded = _seed(widget.config.fields);
  late Map<String, String> _values = Map.of(_seeded);
  bool _saving = false;

  Future<void> _save() async {
    if (_saving) return;
    final strings = Strings.of(context);
    final notices = AppFeedback.of(context);
    final navigator = Navigator.of(context);
    final label = widget.config.label;
    // Untouched keys are not sent: the runtime's defaults still own them.
    final edited = {
      for (final entry in _values.entries)
        if (entry.value != _seeded[entry.key]) entry.key: entry.value,
    };
    setState(() => _saving = true);
    try {
      await widget.api.saveProviderConfig(widget.provider, edited);
      notices.notify(FeedbackKind.routine, strings.mempSaved(label));
      if (mounted) navigator.pop(true);
    } catch (error) {
      // Only when no secret was among the edits: a reason could repeat it.
      final hasSecret = widget.config.secretFields.any(
        (field) => edited.containsKey(field.key),
      );
      final detail = hasSecret ? null : memoryServerDetail(error);
      final failed = strings.mempSaveFailed(label);
      notices.notify(
        FeedbackKind.error,
        detail == null ? failed : '$failed: $detail',
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _openDocs() async {
    final uri = Uri.tryParse(widget.config.docsUrl);
    if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      // No browser to open it with: nothing else to do here.
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final config = widget.config;
    return Scaffold(
      appBar: HermesAppBar(
        glass: false,
        title: Text(
          strings.mempFullTitle(config.label),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(HermesSpace.x4),
                children: [
                  Text(
                    strings.mempFullDesc(config.label, widget.profileLabel),
                    style: TextStyle(
                      fontSize: HermesType.valueSize,
                      height: 1.35,
                      color: colors.textSecondary,
                    ),
                  ),
                  if (config.docsUrl.isNotEmpty)
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: TextButton.icon(
                        key: const ValueKey('memory-full-docs'),
                        onPressed: () => unawaited(_openDocs()),
                        icon: const Icon(HIcons.open_in_new, size: 16),
                        label: Text(strings.mempDocsLink(config.label)),
                      ),
                    ),
                  for (final (group, fields) in config.grouped(
                    strings.mempGroupOther,
                  )) ...[
                    Padding(
                      padding: const EdgeInsets.only(
                        top: HermesSpace.x5,
                        bottom: 4,
                      ),
                      child: Semantics(
                        header: true,
                        child: Text(
                          group.toUpperCase(),
                          style: TextStyle(
                            fontFamily: 'JetBrainsMono',
                            fontSize: 11,
                            letterSpacing: 0.6,
                            color: colors.accent,
                          ),
                        ),
                      ),
                    ),
                    Divider(height: 1, color: colors.divider),
                    for (final field in fields)
                      MemoryProviderFieldRow(
                        key: ValueKey('memory-full-field-${field.key}'),
                        field: field,
                        value: _values[field.key] ?? '',
                        enabled: !widget.readOnly && !_saving,
                        onChanged: (value) => setState(
                          () => _values = {..._values, field.key: value},
                        ),
                      ),
                  ],
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                HermesSpace.x4,
                HermesSpace.x2,
                HermesSpace.x4,
                HermesSpace.x3,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    key: const ValueKey('memory-full-cancel'),
                    onPressed: () => Navigator.of(context).pop(false),
                    child: Text(strings.commonCancel),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    key: const ValueKey('memory-full-save'),
                    onPressed: _saving || widget.readOnly
                        ? null
                        : () => unawaited(_save()),
                    icon: _saving
                        ? const SizedBox.square(
                            dimension: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(HIcons.save_outlined, size: 16),
                    label: Text(strings.mempSaveChanges),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// OAuth connect
// ---------------------------------------------------------------------------

enum _ConnectPhase { idle, pending, error }

/// «Connect» under the provider select, only for a provider whose status
/// route answers (`memory/connect.tsx`: one without an OAuth flow answers
/// 404 and shows nothing). The flow itself runs on the server: it opens the
/// consent page in a browser on the computer that runs Hermes and listens
/// there (`hermes_cli/memory_oauth.py:51-58`), which the pending state says.
class MemoryProviderConnect extends StatefulWidget {
  const MemoryProviderConnect({
    required this.api,
    required this.provider,
    required this.onConnected,
    this.readOnly = false,
    super.key,
  });

  final MemorySettingsApi api;
  final String provider;
  final Future<void> Function() onConnected;
  final bool readOnly;

  @override
  State<MemoryProviderConnect> createState() => _MemoryProviderConnectState();
}

class _MemoryProviderConnectState extends State<MemoryProviderConnect> {
  bool _capable = false;
  bool _connected = false;
  String? _auth;
  _ConnectPhase _phase = _ConnectPhase.idle;
  String _detail = '';
  Timer? _poll;
  Timer? _clearError;
  DateTime? _deadline;
  bool _polling = false;

  @override
  void initState() {
    super.initState();
    unawaited(_probe());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _clearError?.cancel();
    super.dispose();
  }

  Future<void> _probe() async {
    try {
      final status = await widget.api.oauthStatus(widget.provider);
      if (!mounted) return;
      setState(() {
        _capable = true;
        _connected = status.connected;
        _auth = status.auth;
      });
    } catch (_) {
      // Any failure hides the affordance, like Desktop.
    }
  }

  void _stop() {
    _poll?.cancel();
    _poll = null;
  }

  void _fail(String detail) {
    _stop();
    setState(() {
      _phase = _ConnectPhase.error;
      _detail = detail;
    });
    // Not sticky: back to the steady state after a moment.
    _clearError?.cancel();
    _clearError = Timer(const Duration(seconds: 6), () {
      if (!mounted || _phase != _ConnectPhase.error) return;
      setState(() {
        _phase = _ConnectPhase.idle;
        _detail = '';
      });
    });
  }

  Future<void> _connect() async {
    final strings = Strings.of(context);
    setState(() => _phase = _ConnectPhase.pending);
    try {
      await widget.api.oauthStart(widget.provider);
    } catch (_) {
      if (mounted) _fail(strings.mempConnectStartFailed);
      return;
    }
    if (!mounted || _phase != _ConnectPhase.pending) return;
    _deadline = DateTime.now().add(kMemoryOAuthPollLimit);
    _stop();
    _poll = Timer.periodic(kMemoryOAuthPoll, (_) => unawaited(_tick(strings)));
  }

  Future<void> _tick(Strings strings) async {
    if (_polling) return;
    _polling = true;
    try {
      final next = await widget.api.oauthStatus(widget.provider);
      if (!mounted || _phase != _ConnectPhase.pending) return;
      if (next.state == 'pending') {
        final deadline = _deadline;
        if (deadline != null && DateTime.now().isAfter(deadline)) {
          _fail(strings.mempConnectTimedOut);
        }
        return;
      }
      _stop();
      _connected = next.connected;
      _auth = next.auth;
      if (next.state == 'error') {
        _fail(next.detail.isEmpty ? strings.mempConnectFailed : next.detail);
      } else {
        setState(() => _phase = _ConnectPhase.idle);
        unawaited(widget.onConnected());
      }
    } catch (_) {
      // A poll that failed: keep trying until the deadline.
      final deadline = _deadline;
      if (mounted &&
          _phase == _ConnectPhase.pending &&
          deadline != null &&
          DateTime.now().isAfter(deadline)) {
        _fail(strings.mempConnectTimedOut);
      }
    } finally {
      _polling = false;
    }
  }

  void _cancel() {
    _stop();
    setState(() => _phase = _ConnectPhase.idle);
  }

  @override
  Widget build(BuildContext context) {
    if (!_capable) return const SizedBox.shrink();
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final caption = TextStyle(fontSize: 12.5, color: colors.textSecondary);
    final label = _connected
        ? (_auth == 'apikey' ? strings.mempConnectOAuth : strings.mempReconnect)
        : strings.mempConnect;
    return Padding(
      key: const ValueKey('memory-connect'),
      padding: const EdgeInsets.only(top: HermesSpace.x3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (_phase == _ConnectPhase.idle && _connected)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(HIcons.check, size: 14, color: colors.textSecondary),
                    const SizedBox(width: 4),
                    Text(
                      _auth == 'apikey'
                          ? strings.mempApiKeySet
                          : strings.mempOAuthSet,
                      style: caption,
                    ),
                  ],
                ),
              if (_phase == _ConnectPhase.pending) ...[
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox.square(
                      dimension: 12,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(strings.mempWaitingConsent, style: caption),
                    ),
                  ],
                ),
                TextButton(
                  key: const ValueKey('memory-connect-cancel'),
                  onPressed: _cancel,
                  child: Text(strings.commonCancel),
                ),
              ] else
                TextButton.icon(
                  key: const ValueKey('memory-connect-button'),
                  onPressed: widget.readOnly ? null : () => unawaited(_connect()),
                  icon: const Icon(HIcons.open_in_new, size: 14),
                  label: Text(label),
                ),
              if (_phase == _ConnectPhase.error && _detail.isNotEmpty)
                Text(
                  _detail,
                  style: caption.copyWith(
                    color: HermesStatusTone.error.colorIn(colors),
                  ),
                ),
            ],
          ),
          if (_phase == _ConnectPhase.pending)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(strings.mempConsentWhere, style: caption),
            ),
        ],
      ),
    );
  }
}
