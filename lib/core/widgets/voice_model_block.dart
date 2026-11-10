// QA 9709 (the owner, maqueta 140-qa9709 voz-ajustes-modelo): the model that
// answers when you speak, at the top of Settings › Voice, easy to see and to
// change. It is the profile's auxiliary `voice_chat` model, the one the
// server sends every voice turn to; until now it lived only in Models ›
// Models by function › «Voice conversation».
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/app_localizations.dart';
import '../design/hermes_design.dart'
    show
        HermesDialogAction,
        HermesDialogActionStyle,
        HermesListGroup,
        HermesListRow,
        HermesModelChoice,
        HermesModelGroup,
        showHermesDialog,
        showHermesModelPicker;
import '../feedback/feedback_policy.dart';
import '../models/model_provider.dart';
import '../services/connection_manager.dart' show DashboardClient;
import '../theme/app_theme.dart';
import '../theme/hermes_tokens.dart';
import '../utils/api_error.dart';
import 'hermes_reasoning_pill.dart';

/// The auxiliary task the server sends voice turns to.
const String kVoiceModelTask = 'voice_chat';

/// The reasoning levels the voice model offers, like Models' row for it:
/// '' follows the general value.
const List<String> kVoiceModelEfforts = [
  '',
  'none',
  'minimal',
  'low',
  'medium',
  'high',
  'xhigh',
];

/// What the block shows: the voice's model, its reasoning and what can be
/// chosen.
@immutable
class VoiceModelChoice {
  const VoiceModelChoice({
    required this.provider,
    required this.model,
    required this.reasoning,
    required this.groups,
    this.mainModel,
  });

  /// `auto` (or empty) when it follows the main model.
  final String provider;
  final String model;

  /// The task's reasoning effort; '' follows the general value.
  final String reasoning;

  /// The ready models, by provider, the same Models offers.
  final List<HermesModelGroup> groups;

  /// The main model «Automático» follows, when the server says it.
  final String? mainModel;

  bool get isAuto => provider.isEmpty || provider == 'auto' || model.isEmpty;

  /// Nothing to pick: no provider has a model ready.
  bool get empty => groups.every((group) => group.models.isEmpty);
}

/// The server said no to a change of the voice's model.
class VoiceModelRejected implements Exception {
  const VoiceModelRejected();
}

/// Where the block reads and writes the voice's model.
abstract interface class VoiceModelSource {
  Future<VoiceModelChoice> load();

  /// [provider] `auto` with an empty [model] follows the main model.
  Future<void> choose({required String provider, required String model});

  Future<void> setReasoning(VoiceModelChoice current, String effort);
}

/// The profile's voice model on the server, read and written like Models
/// does (`GET /api/model/auxiliary`, `GET /api/model/options`,
/// `POST /api/model/set` with scope `auxiliary`, task `voice_chat`).
class DashboardVoiceModelSource implements VoiceModelSource {
  DashboardVoiceModelSource(this.client, {this.profile});

  final DashboardClient client;
  final String? profile;

  /// The providers and models this device took out of the catalog, the keys
  /// Models keeps them under (`models_screen.dart`): the same list there and
  /// here.
  static const String hiddenProvidersKey = 'hidden_providers';
  static const String hiddenModelsKey = 'hidden_models';

  @override
  Future<VoiceModelChoice> load() async {
    final (aux, providers, prefs) = await (
      client.getAuxiliaryModels(profile: profile),
      client.getModelOptions(profile: profile),
      SharedPreferences.getInstance(),
    ).wait;
    final tasks = aux['tasks'];
    if (tasks is! List) throw const FormatException('Invalid auxiliary');
    final task = tasks
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .where((e) => e['task'] == kVoiceModelTask)
        .firstOrNull;
    final main = aux['main'];
    final mainModel = main is Map ? main['model'] : null;
    final hidden = prefs.getStringList(hiddenProvidersKey)?.toSet() ?? {};
    final hiddenModels = prefs.getStringList(hiddenModelsKey)?.toSet() ?? {};
    return VoiceModelChoice(
      provider: (task?['provider'] as String?)?.trim() ?? 'auto',
      model: (task?['model'] as String?)?.trim() ?? '',
      reasoning: (task?['reasoning_effort'] as String?) ?? '',
      mainModel: mainModel is String && mainModel.trim().isNotEmpty
          ? mainModel.trim()
          : null,
      groups: [
        for (final ModelProvider provider in providers)
          if (provider.authenticated && !hidden.contains(provider.slug))
            HermesModelGroup(
              slug: provider.slug,
              name: provider.name,
              models: [
                for (final model in provider.models)
                  if (!hiddenModels.contains('${provider.slug}/$model')) model,
              ],
              unavailableModels: provider.unavailableModels,
            ),
      ],
    );
  }

  @override
  Future<void> choose({required String provider, required String model}) =>
      _set(provider: provider, model: model);

  @override
  Future<void> setReasoning(VoiceModelChoice current, String effort) => _set(
    provider: current.isAuto ? 'auto' : current.provider,
    model: current.isAuto ? '' : current.model,
    reasoning: true,
    effort: effort,
  );

  Future<void> _set({
    required String provider,
    required String model,
    bool reasoning = false,
    String effort = '',
  }) async {
    final accepted = await client.setActiveModel(
      providerSlug: provider,
      modelId: model,
      scope: 'auxiliary',
      task: kVoiceModelTask,
      profile: profile,
      updateReasoningEffort: reasoning,
      // null is the server's explicit inherit; omission keeps the slot.
      reasoningEffort: reasoning && effort.isNotEmpty ? effort : null,
    );
    if (!accepted) throw const VoiceModelRejected();
  }
}

/// The first block of Settings › Voice: «Modelo de la voz», the model's name
/// large with «Cambiar», and its reasoning below.
///
/// [source] null: still waiting for the server (nothing to change yet).
/// [readOnly]: it is read, with a lock, and nothing opens. [liveEngine]:
/// GPT-Live answers with its own model, so the block is dimmed and says so.
class VoiceModelBlock extends StatefulWidget {
  const VoiceModelBlock({
    required this.source,
    this.readOnly = false,
    this.liveEngine = false,
    this.onOpenModels,
    super.key,
  });

  final VoiceModelSource? source;
  final bool readOnly;
  final bool liveEngine;

  /// «Abrir Modelos», offered when there is nothing to pick.
  final VoidCallback? onOpenModels;

  /// Narrower than this, «Cambiar» goes under the model's name.
  static const double stackBelow = 320;

  @override
  State<VoiceModelBlock> createState() => _VoiceModelBlockState();
}

class _VoiceModelBlockState extends State<VoiceModelBlock> {
  VoiceModelChoice? _choice;
  bool _failed = false;
  bool _busy = false;
  int _load = 0;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void didUpdateWidget(VoiceModelBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.source, widget.source)) _reload();
  }

  void _reload() {
    final source = widget.source;
    final load = ++_load;
    if (source == null) return;
    _failed = false;
    unawaited(
      source.load().then(
        (choice) {
          if (!mounted || load != _load) return;
          setState(() => _choice = choice);
        },
        onError: (Object _) {
          if (!mounted || load != _load) return;
          setState(() => _failed = true);
        },
      ),
    );
  }

  Future<void> _write(Future<void> Function(VoiceModelSource) write) async {
    final source = widget.source;
    if (source == null || _busy) return;
    final feedback = AppFeedback.of(context);
    final strings = Strings.of(context);
    setState(() => _busy = true);
    try {
      await write(source);
      final choice = await source.load();
      if (mounted) setState(() => _choice = choice);
    } catch (error) {
      feedback.error(
        error is VoiceModelRejected
            ? strings.mdlApplyModelError
            : localizedApiError(strings, error),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _change() async {
    final choice = _choice;
    if (choice == null) return;
    final s = Strings.of(context);
    if (choice.empty) {
      final open = widget.onOpenModels;
      final picked = await showHermesDialog<bool>(
        context: context,
        surfaceKey: const ValueKey('voice-model-empty'),
        title: s.voiceModelEmptyTitle,
        message: s.voiceModelEmptyBody,
        actions: [
          HermesDialogAction(
            key: const ValueKey('voice-model-empty-close'),
            label: s.commonClose,
            value: false,
            style: HermesDialogActionStyle.cancel,
          ),
          if (open != null)
            HermesDialogAction(
              key: const ValueKey('voice-model-open-models'),
              label: s.voiceModelOpenModels,
              value: true,
            ),
        ],
      );
      if (picked == true && mounted) open?.call();
      return;
    }
    final main = choice.mainModel;
    final picked = await showHermesModelPicker(
      context: context,
      surfaceKey: const ValueKey('voice-model-picker'),
      keyPrefix: 'voice-model',
      title: s.voiceModelTitle,
      subtitle: s.voiceModelPickerHint,
      defaultLabel: s.mdlAutomatic,
      defaultSubtitle: main == null ? null : s.voiceModelMain(main),
      current: choice.isAuto
          ? const HermesModelChoice.defaultModel()
          : HermesModelChoice(choice.provider, choice.model),
      groups: choice.groups,
    );
    if (picked == null || !mounted) return;
    await _write(
      (source) => source.choose(
        provider: picked.isDefault ? 'auto' : picked.provider,
        model: picked.isDefault ? '' : picked.model,
      ),
    );
  }

  String _effortLabel(Strings s, String effort) => switch (effort) {
    '' => s.chaControlInherit,
    'none' => s.chaControlOff,
    'minimal' => s.reasoningEffortMinimal,
    'low' => s.reasoningEffortLow,
    'medium' => s.reasoningEffortMedium,
    'high' => s.reasoningEffortHigh,
    'xhigh' => s.reasoningEffortXhigh,
    _ => effort,
  };

  Future<void> _reasoning() async {
    final choice = _choice;
    if (choice == null) return;
    final s = Strings.of(context);
    final effort = kVoiceModelEfforts.contains(choice.reasoning)
        ? choice.reasoning
        : '';
    final picked = await showHermesReasoningPicker(
      context: context,
      title: s.chaSessionReasoningLabel,
      selected: effort,
      inheritLabel: _effortLabel(s, ''),
      defaultLabel: _effortLabel(s, ''),
      levels: [
        for (final value in kVoiceModelEfforts)
          if (value.isNotEmpty)
            HermesReasoningLevel(value, _effortLabel(s, value)),
      ],
    );
    if (picked == null || picked == effort || !mounted) return;
    await _write((source) => source.setReasoning(choice, picked));
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final choice = _choice;
    final waiting = choice == null && !_failed;
    final name = _failed
        ? '—'
        : choice == null
        ? '…'
        : choice.isAuto
        ? s.mdlAutomatic
        : choice.model;
    final changeable =
        !widget.readOnly && !_busy && (choice != null || _failed);
    final VoidCallback? onChange = !changeable
        ? null
        : _failed
        ? _reload
        : _change;
    final hero = Semantics(
      key: const ValueKey('voice-model-current'),
      container: true,
      button: onChange != null,
      label: [s.voiceModelTitle, name].join(': '),
      hint: widget.readOnly
          ? s.voiceModelReadOnly
          : _failed
          ? s.voiceModelLoadError
          : null,
      onTap: onChange,
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.all(HermesSpace.x3),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final icon = Container(
              width: HermesSize.iconButton,
              height: HermesSize.iconButton,
              decoration: BoxDecoration(
                color: colors.accent.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(HermesRadius.control),
              ),
              child: Icon(
                Icons.auto_awesome_rounded,
                size: HermesIcon.lg,
                color: colors.accent,
              ),
            );
            final texts = Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s.voiceModelTitle,
                    style: HermesType.support.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                  Text(
                    name,
                    key: const ValueKey('voice-model-name'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: HermesType.title.copyWith(
                      color: waiting ? colors.textTertiary : colors.textPrimary,
                    ),
                  ),
                  if (_failed)
                    Text(
                      s.voiceModelLoadError,
                      style: HermesType.support.copyWith(color: colors.error),
                    ),
                ],
              ),
            );
            final Widget action = widget.readOnly
                ? Row(
                    key: const ValueKey('voice-model-read-only'),
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.lock_outline_rounded,
                        size: HermesIcon.sm,
                        color: colors.textSecondary,
                      ),
                      const SizedBox(width: HermesSpace.x1),
                      Flexible(
                        child: Text(
                          s.voiceModelReadOnly,
                          style: HermesType.support.copyWith(
                            color: colors.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  )
                : _PillButton(
                    key: const ValueKey('voice-model-change'),
                    label: _failed ? s.commonRetry : s.voiceModelChange,
                    onPressed: onChange,
                  );
            // Narrow (or large text): the action takes a line of its own
            // rather than squeezing the model's name.
            if (constraints.maxWidth < VoiceModelBlock.stackBelow) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      icon,
                      const SizedBox(width: HermesSpace.x3),
                      texts,
                    ],
                  ),
                  const SizedBox(height: HermesSpace.x2),
                  Align(alignment: Alignment.centerRight, child: action),
                ],
              );
            }
            return Row(
              children: [
                icon,
                const SizedBox(width: HermesSpace.x3),
                texts,
                const SizedBox(width: HermesSpace.x2),
                action,
              ],
            );
          },
        ),
      ),
    );
    final reasoning = choice == null
        ? null
        : HermesListRow(
            key: const ValueKey('voice-model-reasoning'),
            title: s.chaSessionReasoningLabel,
            value: _effortLabel(s, choice.reasoning),
            onTap: widget.readOnly || _busy ? null : _reasoning,
            showChevron: !widget.readOnly,
          );
    return Column(
      key: const ValueKey('voice-model-block'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Opacity(
          // GPT-Live answers with its own model: this one is not in use.
          opacity: widget.liveEngine ? 0.55 : 1,
          child: HermesListGroup(children: [hero, ?reasoning]),
        ),
        if (widget.liveEngine)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              HermesSpace.x2,
              HermesSpace.x2,
              HermesSpace.x2,
              0,
            ),
            child: Text(
              s.voiceModelLiveNote,
              key: const ValueKey('voice-model-live-note'),
              style: HermesType.support.copyWith(color: colors.textSecondary),
            ),
          ),
      ],
    );
  }
}

/// «Cambiar»: a 48 dp target around a pill in the group's quiet tint.
class _PillButton extends StatelessWidget {
  const _PillButton({required this.label, required this.onPressed, super.key});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onPressed,
        customBorder: const StadiumBorder(),
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minWidth: HermesSize.tap,
            minHeight: HermesSize.tap,
          ),
          child: Center(
            widthFactor: 1,
            child: Ink(
              padding: const EdgeInsets.symmetric(
                horizontal: HermesSpace.x4,
                vertical: HermesSpace.x2,
              ),
              decoration: ShapeDecoration(
                color: colors.surfaceVariant,
                shape: const StadiumBorder(),
              ),
              child: Text(
                label,
                maxLines: 1,
                style: HermesType.value.copyWith(
                  color: onPressed == null
                      ? colors.textTertiary
                      : colors.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
