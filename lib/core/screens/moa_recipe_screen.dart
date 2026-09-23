import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/app_localizations.dart';
import '../models/moa_config.dart';
import '../services/connection_manager.dart';
import '../theme/app_theme.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/hermes_notice.dart';
import '../widgets/hermes_premium_ui.dart';
import '../widgets/hermes_ui.dart';
import '../widgets/read_only.dart';

/// Editor de la receta del Mixture of Agents (spec 029).
///
/// Lee `GET /api/model/moa` y el catálogo de proveedores (para el picker y el
/// aviso de "sin credencial"), permite editar el comité de referencias y el
/// agregador, ajustes finos, y guarda con `PUT /api/model/moa` (atómico:
/// reenvía todos los presets). Sin dashboard accesible → solo-lectura.
class MoaRecipeScreen extends StatefulWidget {
  final SavedConnection connection;
  const MoaRecipeScreen({required this.connection, super.key});

  @override
  State<MoaRecipeScreen> createState() => _MoaRecipeScreenState();
}

enum _Mode { loading, editable, readOnly, error }

class _MoaRecipeScreenState extends State<MoaRecipeScreen> {
  late final DashboardClient _client;
  _Mode _mode = _Mode.loading;
  String? _errorDetail;
  MoaConfig? _config;
  String _presetName = 'default';
  List<ModelProvider> _providers = [];
  bool _saving = false;

  static const int _maxReferences = 5;

  /// Clave de la última receta cacheada para esta instancia (modo solo-lectura
  /// cuando el Dashboard no responde).
  String get _cacheKey => 'moa_cache_${widget.connection.id}';

  @override
  void initState() {
    super.initState();
    _client = DashboardClient.lazy(widget.connection);
    _load();
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }

  MoaPreset? get _preset => _config?.presets[_presetName];

  Future<void> _load() async {
    setState(() => _mode = _Mode.loading);
    try {
      // Se lee el crudo para poder cachearlo íntegro (incluye fanout y
      // reference_max_tokens, que el toJson del PUT omite).
      final raw = await _client.apiGet('model/moa');
      final cfg = MoaConfig.fromJson(raw);
      List<ModelProvider> providers = const [];
      try {
        providers = await _client.getModelOptions();
      } catch (_) {
        // El catálogo es best-effort: sin él, el picker y el aviso de
        // credencial quedan limitados, pero la receta se puede ver/editar.
      }
      unawaited(_saveCache(raw));
      if (!mounted) return;
      setState(() {
        _config = cfg;
        _presetName = cfg.defaultPreset;
        _providers = providers;
        _mode = _Mode.editable;
      });
    } catch (e) {
      // Dashboard no accesible: si hay una receta cacheada, la mostramos en
      // solo-lectura en vez de un error seco (FR-006). La navegación nunca se
      // bloquea.
      final cached = await _loadCache();
      if (!mounted) return;
      if (cached != null) {
        setState(() {
          _config = cached;
          _presetName = cached.defaultPreset;
          _providers = const [];
          _mode = _Mode.readOnly;
          _errorDetail = e.toString();
        });
      } else {
        setState(() {
          _mode = _Mode.error;
          _errorDetail = e.toString();
        });
      }
    }
  }

  Future<void> _saveCache(Map<String, dynamic> raw) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_cacheKey, jsonEncode(raw));
    } catch (_) {
      // Cachear es best-effort.
    }
  }

  Future<MoaConfig?> _loadCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final s = prefs.getString(_cacheKey);
      if (s == null || s.isEmpty) return null;
      return MoaConfig.fromJson(jsonDecode(s) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  bool _providerAuthenticated(String slug) {
    final p = _providers.where((p) => p.slug == slug).cast<ModelProvider?>();
    if (p.isEmpty) return true; // sin catálogo no marcamos falso positivo
    return p.first?.authenticated ?? true;
  }

  void _mutatePreset(MoaPreset Function(MoaPreset) f) {
    final cfg = _config;
    final p = _preset;
    if (cfg == null || p == null) return;
    setState(() => _config = cfg.withPreset(_presetName, f(p)));
  }

  Future<void> _save() async {
    if (widget.connection.readOnly) {
      showReadOnlyNotice(context);
      return;
    }
    final cfg = _config;
    if (cfg == null) return;
    setState(() => _saving = true);
    final s = Strings.of(context);
    try {
      await _client.setMoa(cfg);
      if (!mounted) return;
      // Guardar la receta no la pone como modelo activo del gateway. Si el MoA
      // NO es ya el modelo activo, el aviso ofrece activarlo de un toque (así no
      // hacen falta dos botones permanentes que confunden). Activar también está
      // disponible desde la lista de Modelos (el radio junto al preset).
      final alreadyActive = await _moaIsActive();
      if (!mounted) return;
      HermesNotice.of(context).showSnackBar(
        SnackBar(
          content: Text(s.moaSaved),
          action: alreadyActive
              ? null
              : SnackBarAction(label: s.moaActivate, onPressed: _activate),
        ),
        kind: HermesNoticeKind.success,
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      HermesNotice.of(context).showSnackBar(
        SnackBar(content: Text(s.moaSaveError(e.toString()))),
        kind: HermesNoticeKind.error,
      );
      // Revierte a lo persistido: sin estado fantasma.
      await _load();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// ¿El MoA es ya el modelo activo del gateway? (para no ofrecer "activar" si
  /// ya lo está). Best-effort: ante cualquier fallo asume que no lo es.
  Future<bool> _moaIsActive() async {
    try {
      final info = await _client.getModelInfo();
      final provider = info.provider.toLowerCase();
      return provider == 'moa' || provider.startsWith('moa');
    } catch (_) {
      return false;
    }
  }

  Future<void> _activate() async {
    if (widget.connection.readOnly) {
      showReadOnlyNotice(context);
      return;
    }
    final s = Strings.of(context);
    try {
      await _client.setActiveModel(
        providerSlug: 'moa',
        modelId: _presetName,
        scope: 'main',
      );
      if (!mounted) return;
      HermesNotice.of(context).showSnackBar(
        SnackBar(content: Text(s.moaActivated)),
        kind: HermesNoticeKind.success,
      );
    } catch (e) {
      if (!mounted) return;
      HermesNotice.of(context).showSnackBar(
        SnackBar(content: Text(s.moaSaveError(e.toString()))),
        kind: HermesNoticeKind.error,
      );
    }
  }

  /// Picker de proveedor+modelo del catálogo (excluye "moa": no anidar).
  Future<MoaSlot?> _pickSlot() {
    final colors = Theme.of(context).hermes;
    return showHermesFloatingSurface<MoaSlot>(
      context: context,
      surfaceKey: const ValueKey('moa-model-picker-surface'),
      maxWidth: 560,
      maxHeightFactor: 0.88,
      builder: (ctx) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          Text(
            Strings.of(ctx).moaPickModel,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: colors.textPrimary,
            ),
          ),
          const SizedBox(height: 12),
          for (final p in _providers.where((p) => p.slug != 'moa'))
            ...p.models.map(
              (m) => ListTile(
                dense: true,
                leading: Icon(
                  p.authenticated ? Icons.memory_rounded : Icons.lock_outline,
                  size: 18,
                  color: p.authenticated ? colors.accent : colors.textDisabled,
                ),
                title: Text(
                  m,
                  style: TextStyle(fontSize: 14, color: colors.textPrimary),
                ),
                subtitle: Text(
                  p.name.isNotEmpty ? p.name : p.slug,
                  style: TextStyle(fontSize: 11, color: colors.textSecondary),
                ),
                onTap: () =>
                    Navigator.pop(ctx, MoaSlot(provider: p.slug, model: m)),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return Scaffold(
      appBar: HermesAppBar(title: Text(s.moaTitle)),
      body: switch (_mode) {
        _Mode.loading => const Center(child: CircularProgressIndicator()),
        _Mode.error => _errorState(s, colors),
        _Mode.editable || _Mode.readOnly => _recipe(s, colors),
      },
    );
  }

  Widget _errorState(Strings s, HermesThemeColors colors) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      Icon(Icons.cloud_off, size: 40, color: colors.textSecondary),
      const SizedBox(height: 12),
      Text(
        s.moaNoDashboard,
        textAlign: TextAlign.center,
        style: TextStyle(color: colors.textPrimary),
      ),
      if (_errorDetail != null) ...[
        const SizedBox(height: 6),
        Text(
          _errorDetail!,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 11, color: colors.textDisabled),
        ),
      ],
      const SizedBox(height: 16),
      Center(
        child: TextButton.icon(
          onPressed: _load,
          icon: const Icon(Icons.refresh, size: 18),
          label: Text(s.commonRetry),
        ),
      ),
    ],
  );

  Widget _recipe(Strings s, HermesThemeColors colors) {
    final cfg = _config!;
    final p = _preset!;
    // Solo-lectura si la instancia lo es (flag) o si estamos mostrando la
    // receta cacheada porque el Dashboard no respondió (_Mode.readOnly).
    final readOnly = widget.connection.readOnly || _mode == _Mode.readOnly;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_mode == _Mode.readOnly)
          Container(
            margin: const EdgeInsets.only(bottom: 14),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colors.warning.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(Icons.cloud_off, size: 18, color: colors.warning),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    s.moaCachedReadOnly,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: colors.textSecondary,
                    ),
                  ),
                ),
                TextButton(onPressed: _load, child: Text(s.commonRetry)),
              ],
            ),
          ),
        if (cfg.presets.length > 1) ...[
          _sectionLabel(s.moaPreset, colors),
          Wrap(
            spacing: 8,
            children: [
              for (final name in cfg.presets.keys)
                ChoiceChip(
                  label: Text(name),
                  selected: name == _presetName,
                  onSelected: (_) => setState(() => _presetName = name),
                ),
            ],
          ),
          const SizedBox(height: 18),
        ],
        _sectionLabel(s.moaCommittee, colors),
        for (var i = 0; i < p.referenceModels.length; i++)
          _slotTile(
            p.referenceModels[i],
            colors,
            onEdit: readOnly
                ? null
                : () async {
                    final picked = await _pickSlot();
                    if (picked == null) return;
                    _mutatePreset((pr) {
                      final refs = [...pr.referenceModels];
                      refs[i] = picked;
                      return pr.copyWith(referenceModels: refs);
                    });
                  },
            onRemove: (readOnly || p.referenceModels.length <= 1)
                ? null
                : () => _mutatePreset((pr) {
                    final refs = [...pr.referenceModels]..removeAt(i);
                    return pr.copyWith(referenceModels: refs);
                  }),
          ),
        if (!readOnly && p.referenceModels.length < _maxReferences)
          TextButton.icon(
            onPressed: () async {
              final picked = await _pickSlot();
              if (picked == null) return;
              _mutatePreset(
                (pr) => pr.copyWith(
                  referenceModels: [...pr.referenceModels, picked],
                ),
              );
            },
            icon: const Icon(Icons.add, size: 18),
            label: Text(s.moaAddReference),
          ),
        const SizedBox(height: 18),
        _sectionLabel(s.moaAggregator, colors),
        _slotTile(
          p.aggregator,
          colors,
          onEdit: readOnly
              ? null
              : () async {
                  final picked = await _pickSlot();
                  if (picked == null) return;
                  _mutatePreset((pr) => pr.copyWith(aggregator: picked));
                },
        ),
        const SizedBox(height: 18),
        _sectionLabel(s.moaFineTuning, colors),
        // Preset habilitado.
        HermesSwitchTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: s.moaEnabled,
          value: p.enabled,
          onChanged: readOnly
              ? null
              : (v) => _mutatePreset((pr) => pr.copyWith(enabled: v)),
        ),
        // Temperatura de las referencias (vacío = default del proveedor).
        _tempStepper(
          s.moaReferenceTemp,
          p.referenceTemperature,
          colors,
          readOnly: readOnly,
          onChanged: (v) => _mutatePreset(
            (pr) => pr.copyWith(
              referenceTemperature: v,
              clearReferenceTemperature: v == null,
            ),
          ),
        ),
        // Temperatura del agregador.
        _tempStepper(
          s.moaAggregatorTemp,
          p.aggregatorTemperature,
          colors,
          readOnly: readOnly,
          onChanged: (v) => _mutatePreset(
            (pr) => pr.copyWith(
              aggregatorTemperature: v,
              clearAggregatorTemperature: v == null,
            ),
          ),
        ),
        // Tope de tokens del agregador.
        _intStepper(
          s.moaMaxTokens,
          p.maxTokens,
          colors,
          step: 512,
          min: 256,
          max: 32768,
          readOnly: readOnly,
          onChanged: (v) => _mutatePreset((pr) => pr.copyWith(maxTokens: v)),
        ),
        const SizedBox(height: 10),
        // Parámetros que la API del servidor NO persiste: solo informativos.
        _readOnlyInfo(s.moaFanout(p.fanout), colors),
        _readOnlyInfo(
          s.moaReferenceMaxTokens(
            p.referenceMaxTokens?.toString() ?? s.moaUnset,
          ),
          colors,
        ),
        const SizedBox(height: 20),
        // Un solo botón: Guardar. Tras guardar, si el MoA no es ya el modelo
        // activo, el aviso ofrece activarlo (ver _save). Activar también está
        // en la lista de Modelos (radio del preset). Así se evita el segundo
        // botón permanente que confundía.
        if (!readOnly)
          FilledButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(s.commonSave),
          ),
      ],
    );
  }

  Widget _sectionLabel(String text, HermesThemeColors colors) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      text.toUpperCase(),
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.5,
        color: colors.textSecondary,
      ),
    ),
  );

  Widget _slotTile(
    MoaSlot slot,
    HermesThemeColors colors, {
    VoidCallback? onEdit,
    VoidCallback? onRemove,
  }) {
    final s = Strings.of(context);
    final authed = _providerAuthenticated(slot.provider);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: InkWell(
        onTap: onEdit,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      slot.model.isEmpty ? '—' : slot.model,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      slot.provider,
                      style: TextStyle(
                        fontSize: 11,
                        color: colors.textSecondary,
                      ),
                    ),
                    if (!authed) ...[
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(
                            Icons.warning_amber_rounded,
                            size: 13,
                            color: colors.warning,
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              s.moaNoCredential,
                              style: TextStyle(
                                fontSize: 11,
                                color: colors.warning,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              if (onRemove != null)
                IconButton(
                  icon: Icon(Icons.close, size: 18, color: colors.textDisabled),
                  onPressed: onRemove,
                ),
              if (onEdit != null)
                Icon(Icons.chevron_right, size: 18, color: colors.textDisabled),
            ],
          ),
        ),
      ),
    );
  }

  Widget _readOnlyInfo(String text, HermesThemeColors colors) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(
      children: [
        Icon(Icons.info_outline, size: 14, color: colors.textDisabled),
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

  /// Stepper de temperatura (null = default del proveedor). Bajar de 0.0 vuelve
  /// a null; nunca se fuerza un 0 (que cambiaría el comportamiento del modelo).
  Widget _tempStepper(
    String label,
    double? value,
    HermesThemeColors colors, {
    required bool readOnly,
    required void Function(double?) onChanged,
  }) {
    final display = value == null
        ? Strings.of(context).moaAuto
        : value.toStringAsFixed(1);
    return _stepperRow(
      label,
      display,
      colors,
      onMinus: readOnly
          ? null
          : () {
              if (value == null) return;
              final next = (value * 10 - 1).round() / 10;
              onChanged(next < 0 ? null : next);
            },
      onPlus: readOnly
          ? null
          : () {
              final next = value == null
                  ? 0.0
                  : ((value * 10 + 1).round() / 10);
              onChanged(next > 2.0 ? 2.0 : next);
            },
    );
  }

  Widget _intStepper(
    String label,
    int value,
    HermesThemeColors colors, {
    required int step,
    required int min,
    required int max,
    required bool readOnly,
    required void Function(int) onChanged,
  }) {
    return _stepperRow(
      label,
      value.toString(),
      colors,
      onMinus: (readOnly || value <= min)
          ? null
          : () => onChanged((value - step).clamp(min, max)),
      onPlus: (readOnly || value >= max)
          ? null
          : () => onChanged((value + step).clamp(min, max)),
    );
  }

  Widget _stepperRow(
    String label,
    String value,
    HermesThemeColors colors, {
    VoidCallback? onMinus,
    VoidCallback? onPlus,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(fontSize: 14, color: colors.textPrimary),
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: Icon(
              Icons.remove_circle_outline,
              size: 22,
              color: onMinus == null ? colors.textDisabled : colors.accent,
            ),
            onPressed: onMinus,
          ),
          SizedBox(
            width: 56,
            child: Text(
              value,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: colors.textPrimary,
              ),
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: Icon(
              Icons.add_circle_outline,
              size: 22,
              color: onPlus == null ? colors.textDisabled : colors.accent,
            ),
            onPressed: onPlus,
          ),
        ],
      ),
    );
  }
}
