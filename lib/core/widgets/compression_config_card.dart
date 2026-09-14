import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../models/compression_config.dart';
import '../theme/app_theme.dart';
import 'hermes_ui.dart';

typedef CompressionConfigLoader = Future<CompressionConfigSnapshot> Function();
typedef CompressionConfigSaver =
    Future<CompressionConfigSnapshot> Function(
      CompressionConfigSnapshot base,
      CompressionConfig configuration,
    );

final class CompressionConfigCardController {
  _CompressionConfigCardState? _state;

  void _attach(_CompressionConfigCardState state) => _state = state;

  void _detach(_CompressionConfigCardState state) {
    if (identical(_state, state)) _state = null;
  }

  /// Descarta cualquier escritura pendiente antes de revocar credenciales.
  void disarmPendingSave() => _state?._disarmPendingSave();
}

/// Editor acotado de los ajustes nativos de autocompresion de Hermes.
///
/// La tarjeta no inventa defaults ni guarda al montarse. Cada cambio del
/// usuario se agrupa durante 550 ms y se envia mediante [save]. Si Hermes lo
/// rechaza, el control vuelve al ultimo snapshot confirmado por el servidor.
class CompressionConfigCard extends StatefulWidget {
  const CompressionConfigCard({
    required this.canRead,
    required this.canWrite,
    this.load,
    this.save,
    this.controller,
    this.profile,
    super.key,
  }) : assert(!canWrite || canRead),
       assert(!canRead || load != null),
       assert(!canWrite || save != null);

  final CompressionConfigLoader? load;
  final CompressionConfigSaver? save;
  final bool canRead;
  final bool canWrite;
  final CompressionConfigCardController? controller;
  final String? profile;

  @override
  State<CompressionConfigCard> createState() => _CompressionConfigCardState();
}

class _CompressionConfigCardState extends State<CompressionConfigCard> {
  static const _saveDelay = Duration(milliseconds: 550);

  Timer? _saveDebounce;
  int _loadEpoch = 0;
  bool _loading = true;
  bool _saving = false;
  bool _saved = false;
  bool _loadFailed = false;
  bool _saveFailed = false;
  bool _advanced = false;
  bool _disarmed = false;
  final TextEditingController _thresholdTokensController =
      TextEditingController();
  CompressionConfigSnapshot? _snapshot;
  CompressionConfig? _confirmed;
  CompressionConfig? _draft;

  @override
  void initState() {
    super.initState();
    widget.controller?._attach(this);
    if (widget.canRead) {
      unawaited(_load());
    } else {
      _loading = false;
    }
  }

  @override
  void didUpdateWidget(covariant CompressionConfigCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller?._detach(this);
      widget.controller?._attach(this);
    }
    if (oldWidget.canWrite && !widget.canWrite) {
      _disarmPendingSave();
    }
    if (oldWidget.profile != widget.profile ||
        oldWidget.canRead != widget.canRead) {
      _disarmed = false;
      _saveDebounce?.cancel();
      if (widget.canRead) {
        unawaited(_load());
      } else {
        _loadEpoch++;
        _syncThresholdTokens(null);
        setState(() {
          _loading = false;
          _saving = false;
          _saved = false;
          _loadFailed = false;
          _saveFailed = false;
          _snapshot = null;
          _confirmed = null;
          _draft = null;
        });
      }
    }
  }

  @override
  void dispose() {
    final base = _snapshot;
    final proposed = _draft;
    final shouldFlush =
        !_saving &&
        !_disarmed &&
        widget.canRead &&
        widget.canWrite &&
        base != null &&
        proposed != null &&
        proposed != _confirmed;
    _saveDebounce?.cancel();
    if (shouldFlush) {
      unawaited(_saveDetached(base, proposed));
    }
    widget.controller?._detach(this);
    _thresholdTokensController.dispose();
    _loadEpoch++;
    super.dispose();
  }

  void _disarmPendingSave() {
    _disarmed = true;
    _saveDebounce?.cancel();
    _saveDebounce = null;
    _loadEpoch++;
    if (mounted && _saving) {
      setState(() => _saving = false);
    }
  }

  Future<void> _saveDetached(
    CompressionConfigSnapshot base,
    CompressionConfig proposed,
  ) async {
    final save = widget.save;
    if (!widget.canWrite || save == null) return;
    try {
      await save(base, proposed);
    } catch (_) {
      // La tarjeta ya no existe para mostrar un error. La siguiente apertura
      // vuelve a leer el estado autoritativo de Hermes.
    }
  }

  Future<void> _load() async {
    final load = widget.load;
    if (!widget.canRead || load == null) return;
    final epoch = ++_loadEpoch;
    _saveDebounce?.cancel();
    _syncThresholdTokens(null);
    if (mounted) {
      setState(() {
        _loading = true;
        _saving = false;
        _saved = false;
        _loadFailed = false;
        _saveFailed = false;
        _snapshot = null;
        _confirmed = null;
        _draft = null;
      });
    }
    try {
      final snapshot = await load();
      if (!mounted || epoch != _loadEpoch) return;
      _syncThresholdTokens(snapshot.configuration);
      setState(() {
        _loading = false;
        _snapshot = snapshot;
        _confirmed = snapshot.configuration;
        _draft = snapshot.configuration;
      });
    } catch (_) {
      if (!mounted || epoch != _loadEpoch) return;
      setState(() {
        _loading = false;
        _loadFailed = true;
      });
    }
  }

  void _stage(CompressionConfig next) {
    if (!widget.canWrite ||
        _disarmed ||
        _saving ||
        _loading ||
        _snapshot == null) {
      return;
    }
    setState(() {
      _draft = next;
      _saved = false;
      _saveFailed = false;
    });
    _saveDebounce?.cancel();
    _saveDebounce = Timer(_saveDelay, () => unawaited(_save()));
  }

  Future<void> _save() async {
    _saveDebounce?.cancel();
    _saveDebounce = null;
    final base = _snapshot;
    final proposed = _draft;
    final save = widget.save;
    if (!mounted ||
        !widget.canWrite ||
        _disarmed ||
        _saving ||
        base == null ||
        proposed == null ||
        save == null ||
        proposed == _confirmed) {
      return;
    }
    final saveEpoch = _loadEpoch;
    setState(() {
      _saving = true;
      _saved = false;
      _saveFailed = false;
    });
    try {
      final saved = await save(base, proposed);
      if (!mounted || _disarmed || saveEpoch != _loadEpoch) return;
      final effective = saved.configuration ?? proposed;
      _syncThresholdTokens(effective);
      setState(() {
        _snapshot = saved;
        _confirmed = effective;
        _draft = effective;
        _saving = false;
        _saved = true;
      });
    } catch (_) {
      if (!mounted || _disarmed || saveEpoch != _loadEpoch) return;
      _syncThresholdTokens(_confirmed);
      setState(() {
        _draft = _confirmed;
        _saving = false;
        _saved = false;
        _saveFailed = true;
      });
    }
  }

  void _syncThresholdTokens(CompressionConfig? configuration) {
    final text = configuration?.thresholdTokens?.toString() ?? '';
    if (_thresholdTokensController.text == text) return;
    _thresholdTokensController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  void _commitThresholdTokens() {
    if (!widget.canWrite || _saving || _loading) {
      return;
    }
    final configuration = _draft;
    if (configuration == null) return;
    final raw = _thresholdTokensController.text.trim();
    final parsed = int.tryParse(raw);
    if (parsed == null || parsed <= 0) {
      _syncThresholdTokens(configuration);
      return;
    }
    if (parsed != configuration.thresholdTokens) {
      _stage(configuration.copyWith(thresholdTokens: parsed));
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    return Container(
      key: const ValueKey('compression-config-card'),
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.surfaceVariant.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.divider.withValues(alpha: 0.75)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.auto_awesome_rounded, size: 18, color: colors.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  strings.chaCompressionConfigTitle,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              _ProfileBadge(profile: widget.profile),
            ],
          ),
          const SizedBox(height: 7),
          Text(
            strings.chaCompressionConfigIntro,
            style: TextStyle(fontSize: 12, color: colors.textSecondary),
          ),
          const SizedBox(height: 12),
          if (_loading)
            _StatusLine(
              key: const ValueKey('compression-config-loading'),
              icon: const SizedBox(
                width: 15,
                height: 15,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              text: strings.chaCompressionConfigLoading,
            )
          else if (!widget.canRead)
            Semantics(
              key: const ValueKey('compression-config-unavailable'),
              container: true,
              excludeSemantics: true,
              enabled: false,
              label: strings.chaCompressionConfigUnsupported,
              child: _StatusLine(
                icon: Icon(
                  Icons.info_outline_rounded,
                  size: 17,
                  color: colors.textSecondary,
                ),
                text: strings.chaCompressionConfigUnsupported,
              ),
            )
          else if (_loadFailed)
            _LoadFailure(onRetry: _load)
          else if (_snapshot?.isSupported != true)
            _StatusLine(
              key: const ValueKey('compression-config-unsupported'),
              icon: Icon(
                Icons.info_outline_rounded,
                size: 17,
                color: colors.textSecondary,
              ),
              text: strings.chaCompressionConfigUnsupported,
            )
          else if (_draft != null && _snapshot?.limits != null)
            _buildEditor(
              context,
              configuration: _draft!,
              limits: _snapshot!.limits!,
              optionalFields: _snapshot!.optionalFields,
            ),
        ],
      ),
    );
  }

  Widget _buildEditor(
    BuildContext context, {
    required CompressionConfig configuration,
    required CompressionConfigLimits limits,
    required CompressionConfigOptionalFields optionalFields,
  }) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final editable = widget.canWrite && !_saving;
    final thresholdPercent = (configuration.threshold * 100).round();
    final targetPercent = (configuration.targetRatio * 100).round();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Material(
          color: Colors.transparent,
          child: HermesSwitchTile(
            controlKey: const ValueKey('compression-config-enabled'),
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: configuration.enabled,
            onChanged: editable
                ? (value) => _stage(configuration.copyWith(enabled: value))
                : null,
            title: strings.chaCompressionConfigEnabled,
            subtitle: strings.chaCompressionConfigEnabledHint,
          ),
        ),
        _SliderLabel(
          text: strings.chaCompressionConfigThreshold(thresholdPercent),
        ),
        _AccessibleSlider(
          sliderKey: const ValueKey('compression-config-threshold'),
          semanticsLabel: strings.chaCompressionConfigThresholdSemantics,
          value: configuration.threshold
              .clamp(limits.thresholdMinimum, limits.thresholdMaximum)
              .toDouble(),
          min: limits.thresholdMinimum,
          max: limits.thresholdMaximum,
          divisions: _fractionDivisions(
            limits.thresholdMinimum,
            limits.thresholdMaximum,
          ),
          formatValue: (value) => '${(value * 100).round()}%',
          onChanged: editable
              ? (value) => _stage(
                  configuration.copyWith(threshold: _twoDecimals(value)),
                )
              : null,
        ),
        TextButton.icon(
          key: const ValueKey('compression-config-advanced'),
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
            minimumSize: const Size(48, 40),
          ),
          onPressed: () => setState(() => _advanced = !_advanced),
          icon: Icon(
            _advanced ? Icons.expand_less_rounded : Icons.expand_more_rounded,
            size: 18,
          ),
          label: Text(strings.chaCompressionConfigAdvanced),
        ),
        if (_advanced) ...[
          _SliderLabel(text: strings.chaCompressionConfigTarget(targetPercent)),
          _AccessibleSlider(
            sliderKey: const ValueKey('compression-config-target-ratio'),
            semanticsLabel: strings.chaCompressionConfigTargetSemantics,
            value: configuration.targetRatio
                .clamp(limits.targetRatioMinimum, limits.targetRatioMaximum)
                .toDouble(),
            min: limits.targetRatioMinimum,
            max: limits.targetRatioMaximum,
            divisions: _fractionDivisions(
              limits.targetRatioMinimum,
              limits.targetRatioMaximum,
            ),
            formatValue: (value) => '${(value * 100).round()}%',
            onChanged: editable
                ? (value) => _stage(
                    configuration.copyWith(targetRatio: _twoDecimals(value)),
                  )
                : null,
          ),
          _SliderLabel(
            text: strings.chaCompressionConfigProtect(
              configuration.protectLastN,
            ),
          ),
          _AccessibleSlider(
            sliderKey: const ValueKey('compression-config-protect-last-n'),
            semanticsLabel: strings.chaCompressionConfigProtectSemantics,
            value: configuration.protectLastN
                .clamp(limits.protectLastNMinimum, limits.protectLastNMaximum)
                .toDouble(),
            min: limits.protectLastNMinimum.toDouble(),
            max: limits.protectLastNMaximum.toDouble(),
            divisions: math.max(
              1,
              limits.protectLastNMaximum - limits.protectLastNMinimum,
            ),
            formatValue: (value) => '${value.round()}',
            onChanged: editable
                ? (value) => _stage(
                    configuration.copyWith(protectLastN: value.round()),
                  )
                : null,
          ),
          if (optionalFields.thresholdTokens) ...[
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('compression-config-threshold-tokens'),
              controller: _thresholdTokensController,
              enabled: editable,
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.done,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                labelText: strings.chaCompressionConfigThresholdTokens,
                helperText: strings.chaCompressionConfigThresholdTokensHint,
                helperMaxLines: 3,
                suffixIcon: IconButton(
                  key: const ValueKey(
                    'compression-config-threshold-tokens-apply',
                  ),
                  tooltip: strings.chaCompressionConfigThresholdTokensApply,
                  onPressed: editable ? _commitThresholdTokens : null,
                  icon: const Icon(Icons.check_rounded),
                ),
              ),
              onSubmitted: editable ? (_) => _commitThresholdTokens() : null,
            ),
          ],
          if (optionalFields.minTailUserMessages &&
              configuration.minTailUserMessages != null) ...[
            const SizedBox(height: 10),
            _IntegerStepper(
              key: const ValueKey('compression-config-min-tail-users'),
              label: strings.chaCompressionConfigMinTailUsers,
              hint: strings.chaCompressionConfigMinTailUsersHint,
              value: configuration.minTailUserMessages!,
              decreaseTooltip: strings.chaCompressionConfigMinTailUsersDecrease,
              increaseTooltip: strings.chaCompressionConfigMinTailUsersIncrease,
              onDecrease: editable && configuration.minTailUserMessages! > 1
                  ? () {
                      final current = _draft;
                      final value = current?.minTailUserMessages;
                      if (current != null && value != null && value > 1) {
                        _stage(
                          current.copyWith(minTailUserMessages: value - 1),
                        );
                      }
                    }
                  : null,
              onIncrease: editable
                  ? () {
                      final current = _draft;
                      final value = current?.minTailUserMessages;
                      if (current != null && value != null) {
                        _stage(
                          current.copyWith(minTailUserMessages: value + 1),
                        );
                      }
                    }
                  : null,
            ),
          ],
          if (optionalFields.progressNotices &&
              configuration.progressNotices != null)
            Material(
              color: Colors.transparent,
              child: HermesSwitchTile(
                controlKey: const ValueKey(
                  'compression-config-progress-notices',
                ),
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: configuration.progressNotices!,
                onChanged: editable
                    ? (value) {
                        final current = _draft;
                        if (current != null) {
                          _stage(current.copyWith(progressNotices: value));
                        }
                      }
                    : null,
                title: strings.chaCompressionConfigProgressNotices,
                subtitle: strings.chaCompressionConfigProgressNoticesHint,
              ),
            ),
        ],
        if (!widget.canWrite)
          Semantics(
            key: const ValueKey('compression-config-read-only'),
            container: true,
            excludeSemantics: true,
            enabled: false,
            label: strings.chaCompressionConfigReadOnly,
            child: _StatusLine(
              icon: Icon(
                Icons.lock_outline_rounded,
                size: 17,
                color: colors.warning,
              ),
              text: strings.chaCompressionConfigReadOnly,
            ),
          )
        else if (_saving)
          _StatusLine(
            key: const ValueKey('compression-config-saving'),
            icon: const SizedBox(
              width: 15,
              height: 15,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            text: strings.chaCompressionConfigSaving,
          )
        else if (_saveFailed)
          _StatusLine(
            key: const ValueKey('compression-config-save-failed'),
            icon: Icon(
              Icons.sync_problem_rounded,
              size: 17,
              color: colors.warning,
            ),
            text: strings.chaCompressionConfigSaveFailed,
          )
        else if (_saved)
          _StatusLine(
            key: const ValueKey('compression-config-saved'),
            icon: Icon(
              Icons.check_circle_outline_rounded,
              size: 17,
              color: colors.success,
            ),
            text: strings.chaCompressionConfigSaved,
          ),
      ],
    );
  }
}

class _AccessibleSlider extends StatelessWidget {
  const _AccessibleSlider({
    required this.sliderKey,
    required this.semanticsLabel,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.formatValue,
    required this.onChanged,
  });

  final Key sliderKey;
  final String semanticsLabel;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String Function(double value) formatValue;
  final ValueChanged<double>? onChanged;

  @override
  Widget build(BuildContext context) {
    final step = (max - min) / divisions;
    final increased = math.min(max, value + step);
    final decreased = math.max(min, value - step);
    final editable = onChanged != null;
    return Semantics(
      container: true,
      excludeSemantics: true,
      label: semanticsLabel,
      value: formatValue(value),
      increasedValue: formatValue(increased),
      decreasedValue: formatValue(decreased),
      slider: true,
      enabled: editable,
      onIncrease: editable && value < max ? () => onChanged!(increased) : null,
      onDecrease: editable && value > min ? () => onChanged!(decreased) : null,
      child: Slider(
        key: sliderKey,
        value: value,
        min: min,
        max: max,
        divisions: divisions,
        label: formatValue(value),
        semanticFormatterCallback: formatValue,
        onChanged: onChanged,
      ),
    );
  }
}

class _IntegerStepper extends StatelessWidget {
  const _IntegerStepper({
    required this.label,
    required this.hint,
    required this.value,
    required this.decreaseTooltip,
    required this.increaseTooltip,
    required this.onDecrease,
    required this.onIncrease,
    super.key,
  });

  final String label;
  final String hint;
  final int value;
  final String decreaseTooltip;
  final String increaseTooltip;
  final VoidCallback? onDecrease;
  final VoidCallback? onIncrease;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 2),
        Text(hint, style: TextStyle(fontSize: 11, color: colors.textSecondary)),
        const SizedBox(height: 5),
        Row(
          children: [
            IconButton(
              key: const ValueKey('compression-config-min-tail-users-decrease'),
              tooltip: decreaseTooltip,
              onPressed: onDecrease,
              constraints: const BoxConstraints.tightFor(width: 48, height: 48),
              icon: const Icon(Icons.remove_rounded),
            ),
            SizedBox(
              width: 54,
              child: Text(
                '$value',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            IconButton(
              key: const ValueKey('compression-config-min-tail-users-increase'),
              tooltip: increaseTooltip,
              onPressed: onIncrease,
              constraints: const BoxConstraints.tightFor(width: 48, height: 48),
              icon: const Icon(Icons.add_rounded),
            ),
          ],
        ),
      ],
    );
  }
}

class _ProfileBadge extends StatelessWidget {
  const _ProfileBadge({required this.profile});

  final String? profile;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final value = profile?.trim();
    return Container(
      key: const ValueKey('compression-config-profile'),
      constraints: const BoxConstraints(maxWidth: 145),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        color: colors.accent.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Text(
        value == null || value.isEmpty || value == 'default'
            ? strings.chaCompressionConfigDefaultProfile
            : strings.chaCompressionConfigProfile(value),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: colors.textSecondary,
        ),
      ),
    );
  }
}

class _SliderLabel extends StatelessWidget {
  const _SliderLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 3),
    child: ExcludeSemantics(
      child: Text(
        text,
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      ),
    ),
  );
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.icon, required this.text, super.key});

  final Widget icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          icon,
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 12, color: colors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

class _LoadFailure extends StatelessWidget {
  const _LoadFailure({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _StatusLine(
          key: const ValueKey('compression-config-load-failed'),
          icon: Icon(
            Icons.sync_problem_rounded,
            size: 17,
            color: colors.warning,
          ),
          text: strings.chaCompressionConfigLoadFailed,
        ),
        TextButton.icon(
          key: const ValueKey('compression-config-retry'),
          onPressed: onRetry,
          icon: const Icon(Icons.refresh_rounded, size: 18),
          label: Text(strings.commonRetry),
        ),
      ],
    );
  }
}

int _fractionDivisions(double minimum, double maximum) =>
    math.max(1, ((maximum - minimum) * 100).round());

double _twoDecimals(double value) => (value * 100).roundToDouble() / 100;
