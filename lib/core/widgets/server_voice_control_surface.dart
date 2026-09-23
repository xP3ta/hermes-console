import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../services/connection_manager.dart';
import '../services/voice/tts_toolset_config.dart';
import '../theme/app_theme.dart';
import 'hermes_notice.dart';
import 'hermes_premium_ui.dart';
import 'hermes_ui.dart';

/// Configurador remoto de voz basado exclusivamente en los contratos que
/// publica Hermes. Los secretos solo viven en los controladores mientras el
/// usuario los escribe y se limpian inmediatamente después de enviarlos.
class ServerVoiceControlSurface extends StatefulWidget {
  const ServerVoiceControlSurface({
    super.key,
    required this.dashboard,
    required this.readOnly,
    required this.onServerChanged,
    this.profile,
  });

  final DashboardClient dashboard;
  final bool readOnly;
  final String? profile;
  final VoidCallback onServerChanged;

  @override
  State<ServerVoiceControlSurface> createState() =>
      _ServerVoiceControlSurfaceState();
}

class _ServerVoiceControlSurfaceState extends State<ServerVoiceControlSurface> {
  Map<String, dynamic> _config = const {};
  Map<String, dynamic> _schema = const {};
  HermesTtsToolsetConfig? _ttsToolset;
  HermesTtsToolsetConfig? _sttToolset;
  final Map<String, TextEditingController> _credentialControllers = {};
  bool _loading = true;
  String? _loadError;
  String? _expandedProvider;
  String? _busyProvider;
  String? _busyCredential;
  String? _busySetup;
  List<String> _setupLines = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    for (final controller in _credentialControllers.values) {
      controller.clear();
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _loadError = null;
      });
    }
    Map<String, dynamic>? rawConfig;
    Map<String, dynamic>? schema;
    HermesTtsToolsetConfig? tts;
    HermesTtsToolsetConfig? stt;
    Future<(Map<String, dynamic>?, Object?)> capture(
      Future<Map<String, dynamic>> request,
    ) async {
      try {
        return (await request, null);
      } catch (error) {
        return (null, error);
      }
    }

    final results = await Future.wait([
      capture(widget.dashboard.getServerConfig(profile: widget.profile)),
      capture(widget.dashboard.getServerConfigSchema(profile: widget.profile)),
      capture(widget.dashboard.getTtsToolsetConfig(profile: widget.profile)),
      capture(widget.dashboard.getSttToolsetConfig(profile: widget.profile)),
    ]);
    final configResponse = results[0].$1;
    if (configResponse != null) rawConfig = _unwrapConfig(configResponse);
    schema = results[1].$1;
    final ttsResponse = results[2].$1;
    if (ttsResponse != null) tts = HermesTtsToolsetConfig.fromJson(ttsResponse);
    final sttResponse = results[3].$1;
    if (sttResponse != null) stt = HermesTtsToolsetConfig.fromJson(sttResponse);
    final firstError = results[0].$2 ?? results[1].$2;
    if (!mounted) return;
    final config = rawConfig == null
        ? null
        : _sanitizedVoiceConfig(rawConfig, schema ?? const {});
    setState(() {
      _config = config ?? const {};
      _schema = schema ?? const {};
      _ttsToolset = tts;
      _sttToolset = stt;
      _loading = false;
      _loadError = config == null && schema == null
          ? firstError.runtimeType.toString()
          : null;
    });
  }

  static Map<String, dynamic> _unwrapConfig(Map<String, dynamic> response) {
    final nested = response['config'];
    return Map<String, dynamic>.from(nested is Map ? nested : response);
  }

  static Map<String, dynamic> _sanitizedVoiceConfig(
    Map<String, dynamic> source,
    Map<String, dynamic> schema,
  ) {
    final safe = <String, dynamic>{};
    final paths = <String>{'stt.provider', 'tts.provider'};
    final fields = schema['fields'];
    if (fields is Map) {
      paths.addAll(
        fields.entries
            .where((entry) {
              final key = entry.key.toString();
              return (key.startsWith('stt.') || key.startsWith('tts.')) &&
                  !_isSecretSchemaField(key, entry.value);
            })
            .map((entry) => entry.key.toString()),
      );
    }
    for (final path in paths) {
      final value = _readPath(source, path);
      if (value != null) _writePath(safe, path, value);
    }
    return safe;
  }

  String? _activeConfigProvider(String section) {
    final value = _readPath(_config, '$section.provider');
    final text = value?.toString().trim();
    if (text != null && text.isNotEmpty) return text;

    // Hermes intentionally omits default values from config.yaml. In that
    // state the toolset catalog is the canonical source for the effective
    // provider (for example Local Whisper publishes `stt_provider: local`).
    // Resolving that identifier keeps the guided editor available without
    // inventing a provider or writing config merely by opening this surface.
    final toolset = section == 'stt' ? _sttToolset : _ttsToolset;
    HermesTtsToolsetProvider? active;
    if (toolset != null) {
      for (final provider in toolset.providers) {
        if (provider.isActive == true ||
            provider.name?.trim() == toolset.activeProvider?.trim()) {
          active = provider;
          break;
        }
      }
    }
    if (active != null) {
      final catalogValue = section == 'stt'
          ? active.extraFields['stt_provider']
          : active.ttsProvider;
      final catalogText = catalogValue?.toString().trim();
      if (catalogText != null && catalogText.isNotEmpty) return catalogText;

      // Hermes Agent currently publishes `tts_provider` but may omit the
      // symmetric `stt_provider` from the Dashboard row. Resolve the human
      // catalog name against provider sections in the official config schema.
      // Require one unambiguous match so unfamiliar future providers fail
      // closed instead of selecting an arbitrary backend.
      final activeToken = _providerToken(
        active.name ?? toolset?.activeProvider,
      );
      if (activeToken.isNotEmpty) {
        final matches = _schemaProviders(section)
            .where((candidate) {
              final candidateToken = _providerToken(candidate);
              return candidateToken.isNotEmpty &&
                  (activeToken == candidateToken ||
                      activeToken.startsWith(candidateToken) ||
                      activeToken.endsWith(candidateToken));
            })
            .toList(growable: false);
        if (matches.length == 1) return matches.single;
      }
    }

    // Hermes omits defaults from config.yaml and its canonical STT default is
    // Local Whisper. Some Dashboard versions also omit STT catalog rows. The
    // provider-specific schema route is enough to prove that this backend is
    // supported, so expose its editor without persisting config on open.
    final fields = _schema['fields'];
    if (section == 'stt' &&
        fields is Map &&
        fields.containsKey('stt.local.model')) {
      return 'local';
    }
    return null;
  }

  static String _providerToken(Object? value) =>
      value?.toString().trim().toLowerCase().replaceAll(
        RegExp('[^a-z0-9]'),
        '',
      ) ??
      '';

  bool _hasGuidedParameters(String section, String provider) {
    final rawFields = _schema['fields'];
    if (rawFields is! Map) return false;
    final fields = Map<String, dynamic>.from(rawFields);
    final keys = deduplicateServerVoiceSchemaFieldPaths(
      section: section,
      provider: provider,
      fields: fields,
    );
    for (final key in keys) {
      final rawSpec = fields[key];
      final spec = rawSpec is Map
          ? Map<String, dynamic>.from(rawSpec)
          : const <String, dynamic>{};
      final options = spec['options'] ?? spec['enum'];
      final concept = _fieldConcept(key);
      if (concept == 'vad' ||
          (options is List && options.isNotEmpty) ||
          _officialVoiceOptionPaths.contains(key.toLowerCase()) ||
          const {
            'language',
            'speed',
            'vad',
            'silence_duration',
            'no_speech_threshold',
            'confidence_threshold',
          }.contains(concept)) {
        return true;
      }
    }
    return false;
  }

  Future<void> _selectProvider(
    String toolset,
    HermesTtsToolsetProvider provider,
  ) async {
    if (widget.readOnly || provider.name == null || _busyProvider != null) {
      return;
    }
    final s = Strings.of(context);
    setState(() => _busyProvider = '$toolset:${provider.name}');
    try {
      final response = await widget.dashboard.setVoiceToolsetProvider(
        toolset,
        provider.name!,
        profile: widget.profile,
      );
      if (response['ok'] == false) throw StateError('provider rejected');
      if (!mounted) return;
      _snack(
        response['needs_nous_auth'] == true
            ? s.voiceServerProviderNeedsAuth
            : s.voiceServerProviderChanged(provider.name!),
      );
      widget.onServerChanged();
      await _load();
    } catch (_) {
      if (mounted) _snack(s.voiceServerProviderChangeFailed);
    } finally {
      if (mounted) setState(() => _busyProvider = null);
    }
  }

  Future<void> _selectSchemaProvider(String section, String provider) async {
    if (widget.readOnly || _busyProvider != null) return;
    final s = Strings.of(context);
    setState(() => _busyProvider = '$section:$provider');
    try {
      await widget.dashboard.putServerConfigPatch({
        section: {'provider': provider},
      }, profile: widget.profile);
      if (!mounted) return;
      _snack(s.voiceServerProviderChanged(_providerLabel(provider)));
      widget.onServerChanged();
      await _load();
    } catch (_) {
      if (mounted) _snack(s.voiceServerProviderChangeFailed);
    } finally {
      if (mounted) setState(() => _busyProvider = null);
    }
  }

  Future<void> _saveCredential(
    String toolset,
    HermesTtsToolsetEnvVar env,
  ) async {
    final key = env.key;
    final controller = key == null ? null : _credentialControllers[key];
    final value = controller?.text.trim() ?? '';
    if (widget.readOnly || key == null || value.isEmpty) return;
    final s = Strings.of(context);
    setState(() => _busyCredential = key);
    try {
      final response = await widget.dashboard.setVoiceToolsetCredentials(
        toolset,
        {key: value},
        profile: widget.profile,
      );
      if (response['ok'] == false) throw StateError('credential rejected');
      controller!.clear();
      if (!mounted) return;
      _snack(s.voiceServerCredentialSaved);
      widget.onServerChanged();
      await _load();
    } catch (_) {
      if (mounted) _snack(s.voiceServerCredentialFailed);
    } finally {
      controller?.clear();
      if (mounted) setState(() => _busyCredential = null);
    }
  }

  Future<void> _runSetup(String toolset, String key) async {
    if (widget.readOnly || _busySetup != null) return;
    final s = Strings.of(context);
    setState(() {
      _busySetup = '$toolset:$key';
      _setupLines = const [];
    });
    var ok = false;
    try {
      final started = await widget.dashboard.startVoiceToolsetPostSetup(
        toolset,
        key,
        profile: widget.profile,
      );
      if (started['ok'] != true) throw StateError('setup not started');
      final actionName = started['name']?.toString() ?? 'tools-post-setup';
      for (var attempt = 0; attempt < 150 && mounted; attempt += 1) {
        await Future<void>.delayed(const Duration(milliseconds: 1200));
        if (!mounted) return;
        final status = await widget.dashboard.getActionStatus(actionName);
        final rawLines = status['lines'];
        setState(() {
          _setupLines = rawLines is List
              ? rawLines.map((line) => line.toString()).toList(growable: false)
              : const [];
        });
        if (status['running'] != true) {
          ok = status['exit_code'] == 0;
          break;
        }
      }
      if (!mounted) return;
      _snack(ok ? s.voiceServerSetupComplete : s.voiceServerSetupFailed);
      widget.onServerChanged();
      await _load();
    } catch (_) {
      if (mounted) _snack(s.voiceServerSetupFailed);
    } finally {
      if (mounted) setState(() => _busySetup = null);
    }
  }

  Future<void> _openParameters({
    required String section,
    required String provider,
    required String label,
    bool allowProviderChoice = false,
  }) async {
    final changed = await showHermesFloatingSurface<bool>(
      context: context,
      surfaceKey: ValueKey('server-$section-parameters-surface'),
      maxWidth: 560,
      builder: (_) => _ServerVoiceParametersEditor(
        dashboard: widget.dashboard,
        profile: widget.profile,
        readOnly: widget.readOnly,
        section: section,
        provider: provider,
        providerLabel: label,
        config: _config,
        schema: _schema,
        allowProviderChoice: allowProviderChoice,
      ),
    );
    if (changed == true && mounted) {
      widget.onServerChanged();
      await _load();
    }
  }

  void _snack(String message) {
    HermesNotice.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    if (_loading) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Flexible(child: Text(s.voiceServerManageLoading)),
          ],
        ),
      );
    }

    return ListView(
      key: const ValueKey('server-voice-manager'),
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s.voiceServerManageTitle,
                    key: const ValueKey('server-voice-manager-title'),
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      height: 1.2,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    s.voiceServerManageSub,
                    style: TextStyle(
                      color: colors.textSecondary,
                      fontSize: 13,
                      height: 1.45,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: s.voiceServerClose,
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close_rounded),
            ),
          ],
        ),
        if (widget.profile != null && widget.profile!.trim().isNotEmpty) ...[
          const SizedBox(height: 8),
          _InfoPill(
            label: Strings.of(context).voiceProfileLabel(widget.profile!),
            accent: true,
          ),
        ],
        if (widget.readOnly) ...[
          const SizedBox(height: 12),
          _Notice(text: s.voiceServerReadOnlyManager),
        ],
        if (_loadError != null) ...[
          const SizedBox(height: 12),
          _Notice(text: s.voiceServerManageUnavailable),
        ],
        const SizedBox(height: 18),
        _voiceRoleCard(
          key: const ValueKey('server-voice-stt-card'),
          colors: colors,
          title: s.voiceServerRecognitionTitle,
          subtitle: s.voiceServerRecognitionSub,
          icon: Icons.mic_none_rounded,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _recognitionSummary(colors, s),
              const SizedBox(height: 6),
              _providerChooser('stt', _sttToolset, colors, s),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _voiceRoleCard(
          key: const ValueKey('server-voice-tts-card'),
          colors: colors,
          title: s.voiceServerTtsProvidersTitle,
          subtitle: s.voiceServerTtsProvidersSub,
          icon: Icons.volume_up_outlined,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _providerSummary('tts', colors, s),
              const SizedBox(height: 6),
              _providerChooser('tts', _ttsToolset, colors, s),
            ],
          ),
        ),
        const SizedBox(height: 14),
        _Notice(text: s.voiceServerSecurityNote),
      ],
    );
  }

  Widget _voiceRoleCard({
    required Key key,
    required HermesThemeColors colors,
    required String title,
    required String subtitle,
    required IconData icon,
    required Widget child,
  }) => Container(
    key: key,
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
    decoration: BoxDecoration(
      color: colors.surface,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: colors.divider.withValues(alpha: 0.55)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 42,
              height: 42,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: colors.accent.withValues(alpha: 0.11),
                borderRadius: BorderRadius.circular(13),
              ),
              child: Icon(icon, size: 22, color: colors.accentHover),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontSize: 15.5,
                      fontWeight: FontWeight.w700,
                      height: 1.25,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: colors.textSecondary,
                      fontSize: 12.5,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        child,
      ],
    ),
  );

  Widget _recognitionSummary(HermesThemeColors colors, Strings s) {
    final provider = _activeConfigProvider('stt');
    final providerLabel = provider == null
        ? (_sttToolset?.activeProvider ?? s.voiceServerChoiceAutomatic)
        : _providerLabel(provider);
    final detail = provider == null
        ? ''
        : _activeProviderDetail('stt', provider);
    return Material(
      color: colors.background.withValues(alpha: 0.42),
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final summary = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  providerLabel,
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    height: 1.25,
                  ),
                ),
                if (detail.isNotEmpty && detail != '—') ...[
                  const SizedBox(height: 4),
                  Text(
                    detail,
                    style: TextStyle(
                      color: colors.textSecondary,
                      fontSize: 12.5,
                      height: 1.35,
                    ),
                  ),
                ],
              ],
            );
            final action = OutlinedButton.icon(
              key: const ValueKey('server-stt-parameters'),
              onPressed:
                  provider == null || !_hasGuidedParameters('stt', provider)
                  ? null
                  : () => _openParameters(
                      section: 'stt',
                      provider: provider,
                      label: _providerLabel(provider),
                      allowProviderChoice: false,
                    ),
              icon: const Icon(Icons.tune_rounded, size: 18),
              label: Text(s.voiceServerParametersAction),
            );
            if (constraints.maxWidth < 420) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  summary,
                  const SizedBox(height: 4),
                  Align(alignment: Alignment.centerLeft, child: action),
                ],
              );
            }
            return Row(
              children: [
                Expanded(child: summary),
                action,
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _providerSummary(String section, HermesThemeColors colors, Strings s) {
    final provider = _activeConfigProvider(section) ?? '—';
    final detail = _activeProviderDetail(section, provider);
    final canEdit = provider != '—' && _hasGuidedParameters(section, provider);
    return Material(
      color: colors.background.withValues(alpha: 0.42),
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final largeText = MediaQuery.textScalerOf(context).scale(12) >= 18;
            final summary = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _providerLabel(provider),
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    height: 1.25,
                  ),
                ),
                if (detail != '—') ...[
                  const SizedBox(height: 3),
                  Text(
                    detail,
                    style: TextStyle(
                      color: colors.textSecondary,
                      fontSize: 12.5,
                      height: 1.35,
                    ),
                  ),
                ],
                if (section == 'tts' && provider != '—') ...[
                  const SizedBox(height: 4),
                  Text(
                    _supportsPcm(provider)
                        ? s.voiceServerProviderPcmCapable
                        : s.voiceServerProviderPhraseOnly,
                    style: TextStyle(
                      color: colors.textSecondary,
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                ],
              ],
            );
            final action = OutlinedButton.icon(
              key: ValueKey('server-$section-active-parameters'),
              onPressed: canEdit
                  ? () => _openParameters(
                      section: section,
                      provider: provider,
                      label: _providerLabel(provider),
                    )
                  : null,
              icon: const Icon(Icons.tune_rounded, size: 18),
              label: Text(s.voiceServerParametersAction),
            );
            if (constraints.maxWidth < 420 || largeText) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  summary,
                  if (canEdit) ...[
                    const SizedBox(height: 4),
                    Align(alignment: Alignment.centerLeft, child: action),
                  ],
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: summary),
                if (canEdit) action,
              ],
            );
          },
        ),
      ),
    );
  }

  String _activeProviderDetail(String section, String provider) {
    final model =
        _readPath(_config, '$section.$provider.model') ??
        _readPath(_config, '$section.$provider.model_id');
    final language =
        _readPath(_config, '$section.$provider.language') ??
        _readPath(_config, '$section.$provider.language_code') ??
        _readPath(_config, '$section.language');
    final voice =
        _readPath(_config, '$section.$provider.voice') ??
        _readPath(_config, '$section.$provider.voice_id');
    final values = [model, voice, language]
        .where((value) => value != null && value.toString().trim().isNotEmpty)
        .map((value) => value.toString());
    if (values.isNotEmpty) return values.join(' · ');
    if (section == 'stt' && provider == 'local') return 'base';
    return '—';
  }

  Widget _providerChooser(
    String toolset,
    HermesTtsToolsetConfig? toolsetConfig,
    HermesThemeColors colors,
    Strings s,
  ) => Material(
    color: Colors.transparent,
    child: ExpansionTile(
      key: ValueKey('server-$toolset-provider-chooser'),
      initiallyExpanded: false,
      maintainState: false,
      tilePadding: const EdgeInsets.symmetric(horizontal: 2),
      childrenPadding: const EdgeInsets.fromLTRB(0, 0, 0, 8),
      shape: const Border(),
      collapsedShape: const Border(),
      leading: Icon(
        Icons.swap_horiz_rounded,
        size: 18,
        color: colors.textSecondary,
      ),
      title: Text(
        s.voiceServerProvidersAdvancedTitle,
        style: TextStyle(
          color: colors.textPrimary,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Text(
        s.voiceServerProvidersAdvancedSub,
        style: TextStyle(
          color: colors.textSecondary,
          fontSize: 12,
          height: 1.4,
        ),
      ),
      children: [_providerList(toolset, toolsetConfig, colors, s)],
    ),
  );

  Widget _providerList(
    String toolset,
    HermesTtsToolsetConfig? toolsetConfig,
    HermesThemeColors colors,
    Strings s,
  ) {
    final providers = <HermesTtsToolsetProvider>[...?toolsetConfig?.providers];
    if (toolset == 'tts') {
      final announced = providers
          .map((provider) => provider.ttsProvider)
          .whereType<String>()
          .toSet();
      for (final key in _schemaProviders('tts')) {
        if (!announced.contains(key)) {
          providers.add(
            HermesTtsToolsetProvider(
              name: _providerLabel(key),
              status: _activeConfigProvider('tts') == key ? 'ready' : null,
              isActive: _activeConfigProvider('tts') == key,
              ttsProvider: key,
              extraFields: const {'schema_only': true},
            ),
          );
        }
      }
    }
    if (providers.isEmpty) {
      return _Notice(text: s.voiceServerManageUnavailable);
    }
    return Column(
      children: [
        for (final provider in providers) ...[
          _providerCard(toolset, provider, colors, s),
          const SizedBox(height: 8),
        ],
      ],
    );
  }

  Widget _providerCard(
    String toolset,
    HermesTtsToolsetProvider provider,
    HermesThemeColors colors,
    Strings s,
  ) {
    final name = provider.name ?? '—';
    final id = '$toolset:$name';
    final expanded = _expandedProvider == id;
    final active = provider.isActive == true;
    final status = provider.status;
    final providerKey = toolset == 'tts'
        ? provider.ttsProvider
        : active
        ? _activeConfigProvider('stt')
        : null;
    final schemaOnly = provider.extraFields['schema_only'] == true;
    final setupKey = _postSetupKey(provider.postSetup);
    final setupBusy = _busySetup == '$toolset:$setupKey';
    return Material(
      key: ValueKey('server-$toolset-provider-$name'),
      color: Colors.transparent,
      child: Column(
        children: [
          InkWell(
            onTap: () =>
                setState(() => _expandedProvider = expanded ? null : id),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 10, 4, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: 7,
                          runSpacing: 5,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              name,
                              style: TextStyle(
                                color: colors.textPrimary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            _InfoPill(
                              label: _statusLabel(status, active, s),
                              accent: active || status == 'ready',
                            ),
                          ],
                        ),
                        if ((provider.tag ?? '').trim().isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Text(
                            provider.tag!,
                            style: TextStyle(
                              color: colors.textSecondary,
                              fontSize: 11,
                            ),
                          ),
                        ],
                        if (toolset == 'tts' && providerKey != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            _supportsPcm(providerKey)
                                ? s.voiceServerProviderPcmCapable
                                : s.voiceServerProviderPhraseOnly,
                            style: TextStyle(
                              color: colors.textSecondary,
                              fontSize: 10.5,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  Icon(
                    expanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    color: colors.textSecondary,
                  ),
                ],
              ),
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Divider(color: colors.divider.withValues(alpha: 0.5)),
                  if (!active)
                    OutlinedButton.icon(
                      key: ValueKey('server-$toolset-use-$name'),
                      onPressed: widget.readOnly || _busyProvider != null
                          ? null
                          : () => schemaOnly && providerKey != null
                                ? _selectSchemaProvider(toolset, providerKey)
                                : _selectProvider(toolset, provider),
                      icon: _busyProvider == id
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.check_circle_outline_rounded),
                      label: Text(
                        _busyProvider == id
                            ? s.voiceServerProviderSwitching
                            : s.voiceServerProviderUse,
                      ),
                    ),
                  for (final env in provider.envVars)
                    _credentialField(toolset, env, colors, s),
                  if (setupKey != null) ...[
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      key: ValueKey('server-$toolset-setup-$setupKey'),
                      onPressed: widget.readOnly || _busySetup != null
                          ? null
                          : () => _runSetup(toolset, setupKey),
                      icon: setupBusy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.download_for_offline_outlined),
                      label: Text(
                        setupBusy
                            ? s.voiceServerSetupRunning
                            : status == 'ready'
                            ? s.voiceServerSetupRerun
                            : s.voiceServerSetupRun,
                      ),
                    ),
                    if (setupBusy && _setupLines.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      SelectionArea(
                        child: Text(
                          _setupLines.reversed
                              .take(6)
                              .toList()
                              .reversed
                              .join('\n'),
                          style: TextStyle(
                            color: colors.textSecondary,
                            fontFamily: 'monospace',
                            fontSize: 10.5,
                            height: 1.35,
                          ),
                        ),
                      ),
                    ],
                  ],
                  if (providerKey != null &&
                      _hasGuidedParameters(toolset, providerKey)) ...[
                    const SizedBox(height: 8),
                    TextButton.icon(
                      key: ValueKey('server-$toolset-parameters-$providerKey'),
                      onPressed: () => _openParameters(
                        section: toolset,
                        provider: providerKey,
                        label: name,
                      ),
                      icon: const Icon(Icons.tune_rounded),
                      label: Text(s.voiceServerParametersAction),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _credentialField(
    String toolset,
    HermesTtsToolsetEnvVar env,
    HermesThemeColors colors,
    Strings s,
  ) {
    final key = env.key;
    if (key == null) return const SizedBox.shrink();
    final label = env.label ?? env.extraFields['prompt']?.toString() ?? key;
    final controller = _credentialControllers.putIfAbsent(
      key,
      TextEditingController.new,
    );
    final busy = _busyCredential == key;
    return Padding(
      padding: const EdgeInsets.only(top: 9),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              _InfoPill(
                label: env.isSet == true
                    ? s.voiceServerCredentialConfigured
                    : s.voiceServerCredentialMissing,
                accent: env.isSet == true,
              ),
            ],
          ),
          const SizedBox(height: 6),
          TextField(
            key: ValueKey('server-credential-$key'),
            controller: controller,
            enabled: !widget.readOnly && !busy,
            obscureText: env.secret != false,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              isDense: true,
              hintText: s.voiceServerCredentialHint(label),
              suffixIcon: IconButton(
                tooltip: s.voiceServerCredentialSave,
                onPressed: widget.readOnly || busy
                    ? null
                    : () => _saveCredential(toolset, env),
                icon: busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_outlined),
              ),
            ),
            onSubmitted: (_) => _saveCredential(toolset, env),
          ),
        ],
      ),
    );
  }

  List<String> _schemaProviders(String section) {
    final fields = _schema['fields'];
    if (fields is! Map) return const [];
    final providers = <String>{};
    final node = fields['$section.provider'];
    final options = node is Map ? node['options'] ?? node['enum'] : null;
    if (options is List) {
      providers.addAll(
        options.whereType<String>().where((value) => value.trim().isNotEmpty),
      );
    }
    final prefix = '$section.';
    for (final rawKey in fields.keys) {
      final key = rawKey.toString();
      if (!key.startsWith(prefix)) continue;
      final parts = key.split('.');
      if (parts.length >= 3 && parts[1].trim().isNotEmpty) {
        providers.add(parts[1]);
      }
    }
    return providers.toList(growable: false);
  }

  static String? _postSetupKey(Object? value) {
    if (value is String && value.trim().isNotEmpty) return value.trim();
    if (value is Map) {
      for (final key in const ['key', 'name', 'action']) {
        final candidate = value[key]?.toString().trim();
        if (candidate != null && candidate.isNotEmpty) return candidate;
      }
    }
    return null;
  }

  static bool _supportsPcm(String provider) => const {
    'elevenlabs',
    'openai',
    'gemini',
    'xai',
  }.contains(provider.toLowerCase());

  static String _statusLabel(String? status, bool active, Strings s) {
    if (active) return s.voiceServerProviderActive;
    return switch (status) {
      'ready' => s.voiceServerProviderReady,
      'needs_keys' => s.voiceServerProviderNeedsKeys,
      'needs_auth' => s.voiceServerProviderNeedsAuth,
      'needs_setup' => s.voiceServerProviderNeedsSetup,
      _ => s.artifactUnknown,
    };
  }
}

class _ServerVoiceParametersEditor extends StatefulWidget {
  const _ServerVoiceParametersEditor({
    required this.dashboard,
    required this.readOnly,
    required this.section,
    required this.provider,
    required this.providerLabel,
    required this.config,
    required this.schema,
    required this.allowProviderChoice,
    this.profile,
  });

  final DashboardClient dashboard;
  final bool readOnly;
  final String section;
  final String provider;
  final String providerLabel;
  final Map<String, dynamic> config;
  final Map<String, dynamic> schema;
  final bool allowProviderChoice;
  final String? profile;

  @override
  State<_ServerVoiceParametersEditor> createState() =>
      _ServerVoiceParametersEditorState();
}

class _ServerVoiceParametersEditorState
    extends State<_ServerVoiceParametersEditor> {
  late Map<String, dynamic> _patch;
  late String _provider;
  final ExpansibleController _advancedController = ExpansibleController();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _patch = <String, dynamic>{};
    _provider = widget.provider;
  }

  @override
  void dispose() {
    _advancedController.dispose();
    super.dispose();
  }

  Map<String, dynamic> get _fields {
    final fields = widget.schema['fields'];
    return fields is Map ? Map<String, dynamic>.from(fields) : const {};
  }

  List<String> get _parameterKeys {
    return deduplicateServerVoiceSchemaFieldPaths(
          section: widget.section,
          provider: _provider,
          fields: _fields,
        )
        .where((key) {
          if (_fieldConcept(key) == 'enabled') return false;
          final rawSpec = _fields[key];
          final spec = rawSpec is Map
              ? Map<String, dynamic>.from(rawSpec)
              : const <String, dynamic>{};
          final value = _value(key) ?? spec['default'];
          return _fieldConcept(key) == 'vad' ||
              _selectableValues(key, spec, value).isNotEmpty;
        })
        .toList(growable: false);
  }

  Object? _value(String path) {
    final direct = _readPath(_patch, path) ?? _readPath(widget.config, path);
    if (direct != null && direct.toString().trim().isNotEmpty) return direct;
    final fallbacks = switch (_fieldConcept(path)) {
      'language' => <String>[
        '${widget.section}.language',
        '${widget.section}.language_code',
      ],
      'model' => <String>[
        '${widget.section}.model',
        '${widget.section}.model_id',
      ],
      'voice' => <String>[
        '${widget.section}.voice',
        '${widget.section}.voice_id',
      ],
      _ => const <String>[],
    };
    for (final fallback in fallbacks) {
      if (fallback == path) continue;
      final value =
          _readPath(_patch, fallback) ?? _readPath(widget.config, fallback);
      if (value != null && value.toString().trim().isNotEmpty) return value;
    }
    // `base` is the documented Hermes/faster-whisper default when the
    // provider-specific key is absent. Show the effective value instead of an
    // empty selector, while still persisting only after an explicit change.
    if (path == 'stt.local.model') return 'base';
    final rawSpec = _fields[path];
    return rawSpec is Map ? rawSpec['default'] : direct;
  }

  void _set(String path, Object? value) {
    setState(() => _writePath(_patch, path, value));
  }

  Future<void> _save() async {
    if (widget.readOnly || _saving || _patch.isEmpty) return;
    final s = Strings.of(context);
    setState(() => _saving = true);
    try {
      await widget.dashboard.putServerConfigPatch(
        _patch,
        profile: widget.profile,
      );
      if (!mounted) return;
      HermesNotice.of(context).showSnackBar(
        SnackBar(content: Text(s.voiceServerParametersSaved)),
        kind: HermesNoticeKind.success,
      );
      Navigator.pop(context, true);
    } catch (_) {
      if (!mounted) return;
      HermesNotice.of(context).showSnackBar(
        SnackBar(content: Text(s.voiceServerParametersFailed)),
        kind: HermesNoticeKind.error,
      );
      setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final keys = _parameterKeys;
    final basicKeys = keys
        .where(
          (key) => const {
            'model',
            'voice',
            'language',
            'device',
          }.contains(_fieldConcept(key)),
        )
        .toList(growable: false);
    final advancedKeys = keys
        .where((key) => !basicKeys.contains(key))
        .toList(growable: false);
    return ListView(
      key: ValueKey('server-${widget.section}-parameters-editor'),
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 20),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s.voiceServerParametersTitle(widget.providerLabel),
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    s.voiceServerParametersSub,
                    style: TextStyle(
                      color: colors.textSecondary,
                      fontSize: 11.5,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: s.voiceServerClose,
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close_rounded),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (widget.allowProviderChoice) ...[
          _providerField(colors, s),
          const SizedBox(height: 16),
        ],
        for (final key in basicKeys) ...[
          _field(key, colors),
          const SizedBox(height: 14),
        ],
        if (keys.isEmpty)
          _Notice(text: s.voiceServerNoParameters)
        else if (advancedKeys.isNotEmpty)
          Material(
            color: Colors.transparent,
            clipBehavior: Clip.antiAlias,
            child: ExpansionTile(
              key: const ValueKey('server-voice-advanced'),
              controller: _advancedController,
              initiallyExpanded: false,
              maintainState: false,
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.fromLTRB(0, 4, 0, 8),
              shape: const Border(),
              collapsedShape: const Border(),
              leading: Icon(
                Icons.tune_rounded,
                color: colors.textSecondary,
                size: 20,
              ),
              title: Text(
                s.voiceServerFineTuneTitle,
                style: TextStyle(
                  color: colors.textPrimary,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              subtitle: Text(
                s.voiceServerFineTuneSub,
                style: TextStyle(
                  color: colors.textSecondary,
                  fontSize: 10,
                  height: 1.35,
                ),
              ),
              children: [
                for (final key in advancedKeys) ...[
                  _field(key, colors),
                  if (key != advancedKeys.last) const SizedBox(height: 14),
                ],
              ],
            ),
          ),
        if (widget.section == 'tts' && _provider.toLowerCase() == 'neutts') ...[
          const SizedBox(height: 12),
          _Notice(text: s.voiceServerNeuTtsReferenceHelp),
        ],
        const SizedBox(height: 16),
        FilledButton.icon(
          key: const ValueKey('server-voice-parameters-save'),
          onPressed: widget.readOnly || _saving || _patch.isEmpty
              ? null
              : _save,
          icon: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.save_outlined),
          label: Text(s.voiceServerParametersSave),
        ),
      ],
    );
  }

  Widget _providerField(HermesThemeColors colors, Strings s) {
    final spec = _fields['${widget.section}.provider'];
    final rawOptions = spec is Map ? spec['options'] ?? spec['enum'] : null;
    final options = rawOptions is List
        ? rawOptions.map((item) => item.toString()).toList()
        : <String>[];
    if (_provider.isNotEmpty && !options.contains(_provider)) {
      options.add(_provider);
    }
    if (options.isEmpty) return const SizedBox.shrink();
    return _labeledControl(
      colors: colors,
      label: widget.section == 'stt'
          ? s.voiceServerProviderRecognitionLabel
          : s.voiceServerProviderSpeechLabel,
      child: DropdownButtonFormField<String>(
        key: ValueKey('server-voice-field-${widget.section}.provider'),
        initialValue: options.contains(_provider) ? _provider : null,
        isExpanded: true,
        menuMaxHeight: 360,
        style: TextStyle(color: colors.textPrimary, fontSize: 13),
        hint: Text(s.voiceServerChooseOption),
        decoration: _controlDecoration(colors),
        items: [
          for (final option in options)
            DropdownMenuItem(
              value: option,
              child: Text(_providerLabel(option), softWrap: true),
            ),
        ],
        onChanged: widget.readOnly
            ? null
            : (next) {
                if (next == null) return;
                _set('${widget.section}.provider', next);
                setState(() => _provider = next);
              },
      ),
    );
  }

  List<String> _selectableValues(
    String key,
    Map<String, dynamic> spec,
    Object? value,
  ) {
    final published = spec['options'] ?? spec['enum'];
    final values = published is List
        ? published
              .map((item) => item.toString().trim())
              .where((item) => item.isNotEmpty)
              .toList()
        : <String>[];
    if (values.isEmpty) {
      values.addAll(_officialVoiceOptions(key));
    }
    if (values.isEmpty) {
      switch (_fieldConcept(key)) {
        case 'language':
          values.addAll(const ['auto', 'es', 'en', 'fr', 'de', 'pt', 'it']);
        case 'voice':
          if (widget.section == 'tts' && _provider.toLowerCase() == 'edge') {
            values.addAll(const [
              'es-ES-ElviraNeural',
              'es-ES-AlvaroNeural',
              'es-MX-DaliaNeural',
              'es-MX-JorgeNeural',
              'en-US-AriaNeural',
              'en-US-GuyNeural',
            ]);
          }
        case 'speed':
          values.addAll(const ['0.75', '1', '1.25', '1.5']);
        case 'silence_duration':
          final unit = _fieldUnit(key, spec);
          values.addAll(
            unit == 's'
                ? const ['0.3', '0.5', '0.7', '1']
                : const ['300', '500', '700', '1000'],
          );
        case 'no_speech_threshold' || 'confidence_threshold':
          values.addAll(const ['0.2', '0.4', '0.6', '0.8']);
      }
    }
    final current = value?.toString().trim();
    if (values.isNotEmpty &&
        current != null &&
        current.isNotEmpty &&
        !values.contains(current)) {
      values.insert(0, current);
    }
    return values.toSet().toList(growable: false);
  }

  List<String> _officialVoiceOptions(String key) {
    final normalized = key.toLowerCase();
    return switch (normalized) {
      'tts.edge.voice' => const [
        'es-ES-ElviraNeural',
        'es-ES-AlvaroNeural',
        'es-MX-DaliaNeural',
        'es-MX-JorgeNeural',
        'es-US-PalomaNeural',
        'es-US-AlonsoNeural',
        'en-US-AriaNeural',
        'en-US-JennyNeural',
        'en-US-AndrewNeural',
        'en-US-BrianNeural',
        'en-US-GuyNeural',
        'en-GB-SoniaNeural',
      ],
      'tts.openai.model' => const ['gpt-4o-mini-tts', 'tts-1', 'tts-1-hd'],
      'tts.openai.voice' => const [
        'alloy',
        'ash',
        'ballad',
        'cedar',
        'coral',
        'echo',
        'fable',
        'marin',
        'nova',
        'onyx',
        'sage',
        'shimmer',
        'verse',
      ],
      'tts.elevenlabs.model_id' => const [
        'eleven_multilingual_v2',
        'eleven_turbo_v2_5',
        'eleven_flash_v2_5',
      ],
      'tts.gemini.model' => const [
        'gemini-2.5-flash-preview-tts',
        'gemini-2.5-pro-preview-tts',
      ],
      'tts.gemini.voice' => const [
        'Zephyr',
        'Puck',
        'Charon',
        'Kore',
        'Fenrir',
        'Leda',
        'Orus',
        'Aoede',
        'Callirrhoe',
        'Autonoe',
        'Enceladus',
        'Iapetus',
        'Umbriel',
        'Algieba',
        'Despina',
        'Erinome',
        'Algenib',
        'Rasalgethi',
        'Laomedeia',
        'Achernar',
        'Alnilam',
        'Schedar',
        'Gacrux',
        'Pulcherrima',
        'Achird',
        'Zubenelgenubi',
        'Vindemiatrix',
        'Sadachbia',
        'Sadaltager',
        'Sulafat',
      ],
      'tts.xai.voice_id' => const ['eve'],
      'tts.minimax.model' => const ['speech-02-hd', 'speech-02-turbo'],
      'tts.mistral.model' => const ['voxtral-mini-tts-2603'],
      'tts.neutts.model' => const [
        'neuphonic/neutts-air-q4-gguf',
        'neuphonic/neutts-air-q8-gguf',
        'neuphonic/neutts-air',
      ],
      'tts.neutts.device' => const ['cpu', 'cuda', 'mps'],
      'tts.kittentts.model' => const [
        'KittenML/kitten-tts-nano-0.8-int8',
        'KittenML/kitten-tts-micro-0.8-int8',
        'KittenML/kitten-tts-mini-0.8-int8',
      ],
      'tts.kittentts.voice' => const ['Jasper'],
      'tts.piper.voice' => const [
        'en_US-lessac-medium',
        'en_US-amy-medium',
        'en_US-ryan-high',
        'en_GB-alan-medium',
      ],
      'stt.local.model' => const [
        'tiny',
        'base',
        'small',
        'medium',
        'large-v3',
      ],
      'stt.groq.model' => const [
        'whisper-large-v3-turbo',
        'whisper-large-v3',
        'distil-whisper-large-v3-en',
      ],
      'stt.openai.model' => const [
        'whisper-1',
        'gpt-4o-mini-transcribe',
        'gpt-4o-transcribe',
        'gpt-transcribe',
      ],
      'stt.elevenlabs.model_id' => const ['scribe_v2', 'scribe_v1'],
      _ => const [],
    };
  }

  String _choiceLabel(String key, String value) {
    final s = Strings.of(context);
    switch (_fieldConcept(key)) {
      case 'language':
        return switch (value.toLowerCase()) {
          'auto' => s.voiceServerChoiceAutomatic,
          'es' || 'es-es' => 'Español',
          'en' || 'en-us' => 'English',
          'fr' || 'fr-fr' => 'Français',
          'de' || 'de-de' => 'Deutsch',
          'pt' || 'pt-br' => 'Português',
          'it' || 'it-it' => 'Italiano',
          _ => value,
        };
      case 'voice':
        final parts = value.split('-');
        if (parts.length >= 3) {
          final name = parts
              .sublist(2)
              .join('-')
              .replaceFirst(RegExp(r'Neural$'), '');
          return '$name · ${parts[0]}-${parts[1]}';
        }
      case 'speed':
        return '$value×';
      case 'no_speech_threshold' || 'confidence_threshold':
        final number = double.tryParse(value);
        if (number != null) {
          if (number < 0) return s.voiceServerChoiceAutomatic;
          return '${(number * 100).round()} %';
        }
      case 'silence_duration':
        final rawSpec = _fields[key];
        final spec = rawSpec is Map
            ? Map<String, dynamic>.from(rawSpec)
            : const <String, dynamic>{};
        return '$value ${_fieldUnit(key, spec) ?? 'ms'}';
    }
    return value;
  }

  Widget _field(String key, HermesThemeColors colors) {
    final rawSpec = _fields[key];
    final spec = rawSpec is Map
        ? Map<String, dynamic>.from(rawSpec)
        : const <String, dynamic>{};
    final type = spec['type']?.toString();
    final label = _fieldLabel(context, key, spec);
    final help = _fieldHelp(context, key, spec);
    final value = _value(key);
    if (type == 'boolean' || value is bool) {
      return HermesSwitchTile(
        controlKey: ValueKey('server-voice-field-$key'),
        contentPadding: EdgeInsets.zero,
        title: label,
        subtitle: help,
        value: value == true,
        onChanged: widget.readOnly ? null : (next) => _set(key, next),
      );
    }
    final values = _selectableValues(key, spec, value);
    if (values.isNotEmpty) {
      final current = value?.toString().trim();
      return _labeledControl(
        colors: colors,
        label: label,
        help: help,
        child: DropdownButtonFormField<String>(
          key: ValueKey('server-voice-field-$key'),
          initialValue:
              current != null && current.isNotEmpty && values.contains(current)
              ? current
              : null,
          isExpanded: true,
          menuMaxHeight: 360,
          style: TextStyle(color: colors.textPrimary, fontSize: 13),
          hint: Text(Strings.of(context).voiceServerChooseOption),
          decoration: _controlDecoration(colors),
          items: [
            for (final option in values)
              DropdownMenuItem(
                value: option,
                child: Text(
                  _choiceLabel(key, option),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: widget.readOnly
              ? null
              : (next) {
                  if (next == null) return;
                  _set(
                    key,
                    type == 'number' ? num.tryParse(next) ?? next : next,
                  );
                },
        ),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _labeledControl({
    required HermesThemeColors colors,
    required String label,
    required Widget child,
    String? help,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: TextStyle(
          color: colors.textPrimary,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
      if (help != null) ...[
        const SizedBox(height: 3),
        Text(
          help,
          style: TextStyle(
            color: colors.textSecondary,
            fontSize: 10,
            height: 1.35,
          ),
        ),
      ],
      const SizedBox(height: 7),
      child,
    ],
  );

  InputDecoration _controlDecoration(HermesThemeColors colors) =>
      InputDecoration(
        isDense: true,
        filled: true,
        fillColor: colors.background.withValues(alpha: 0.55),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 11,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: colors.divider),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: colors.divider.withValues(alpha: 0.65)),
        ),
      );
}

class _InfoPill extends StatelessWidget {
  const _InfoPill({required this.label, this.accent = false});

  final String label;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: accent
            ? colors.accent.withValues(alpha: 0.12)
            : colors.background.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: accent
              ? colors.accent.withValues(alpha: 0.45)
              : colors.divider.withValues(alpha: 0.55),
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: accent ? colors.accent : colors.textSecondary,
          fontSize: 9.5,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Container(
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.divider.withValues(alpha: 0.45)),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: colors.textSecondary,
          fontSize: 11,
          height: 1.4,
        ),
      ),
    );
  }
}

Object? _readPath(Map<String, dynamic> root, String path) {
  Object? current = root;
  for (final segment in path.split('.')) {
    if (current is! Map || !current.containsKey(segment)) return null;
    current = current[segment];
  }
  return current;
}

void _writePath(Map<String, dynamic> root, String path, Object? value) {
  final segments = path.split('.');
  var current = root;
  for (final segment in segments.take(segments.length - 1)) {
    final existing = current[segment];
    final next = existing is Map
        ? Map<String, dynamic>.from(existing)
        : <String, dynamic>{};
    current[segment] = next;
    current = next;
  }
  current[segments.last] = value;
}

bool _isSecretSchemaField(String key, Object? rawSpec) {
  if (_looksSecret(key)) return true;
  if (rawSpec is! Map) return false;

  final nodes = <Map<dynamic, dynamic>>[rawSpec];
  for (final metadataKey in const ['ui', 'metadata', 'annotations', 'x-ui']) {
    final nested = rawSpec[metadataKey];
    if (nested is Map) nodes.add(nested);
  }

  for (final node in nodes) {
    for (final entry in node.entries) {
      final metadataKey = _collapsed(entry.key.toString());
      final value = entry.value;
      if (const {
            'secret',
            'issecret',
            'sensitive',
            'issensitive',
            'writeonly',
            'obscuretext',
            'obscured',
          }.contains(metadataKey) &&
          _metadataFlag(value)) {
        return true;
      }
      if ((metadataKey == 'format' ||
              metadataKey == 'type' ||
              metadataKey == 'inputtype' ||
              metadataKey.endsWith('widget')) &&
          _secretDescriptor(value)) {
        return true;
      }
    }
  }
  return false;
}

bool _looksSecret(String key) {
  final normalized = _collapsed(key);
  return const [
    'apikey',
    'token',
    'secret',
    'password',
    'passwd',
    'credential',
    'authorization',
    'privatekey',
    'bearer',
    'authcookie',
    'sessioncookie',
  ].any(normalized.contains);
}

String _collapsed(String value) =>
    value.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');

bool _metadataFlag(Object? value) {
  if (value is bool) return value;
  final normalized = value?.toString().trim().toLowerCase();
  return normalized == 'true' || normalized == 'yes' || normalized == '1';
}

bool _secretDescriptor(Object? value) {
  final normalized = _collapsed(value?.toString() ?? '');
  return const [
    'password',
    'secret',
    'credential',
    'token',
    'apikey',
    'privatekey',
  ].any(normalized.contains);
}

@visibleForTesting
List<String> deduplicateServerVoiceSchemaFieldPaths({
  required String section,
  required String provider,
  required Map<String, dynamic> fields,
}) {
  final selected = <String, String>{};
  final providerPrefix = '$section.$provider.';
  for (final key in fields.keys) {
    if (key == '$section.provider' || _isSecretSchemaField(key, fields[key])) {
      continue;
    }
    final parts = key.split('.');
    final isCommon = parts.length == 2 && parts.first == section;
    final isProviderSpecific = key.startsWith(providerPrefix);
    if (!isCommon && !isProviderSpecific) continue;

    // The provider-specific setting is the effective one when Hermes also
    // publishes a section-wide fallback for the same concept.
    final concept = _fieldConcept(key);
    if (!selected.containsKey(concept) || isProviderSpecific) {
      selected[concept] = key;
    }
  }
  final keys = selected.values.toList(growable: false);
  keys.sort((left, right) {
    final byKind = _fieldOrder(left).compareTo(_fieldOrder(right));
    return byKind != 0 ? byKind : left.compareTo(right);
  });
  return keys;
}

String _providerLabel(String value) => switch (value.toLowerCase()) {
  'edge' => 'Microsoft Edge TTS',
  'elevenlabs' => 'ElevenLabs',
  'openai' => 'OpenAI',
  'gemini' => 'Google Gemini',
  'xai' => 'xAI',
  'kittentts' => 'KittenTTS',
  'piper' => 'Piper',
  'neutts' => 'NeuTTS',
  'minimax' => 'MiniMax',
  'mistral' => 'Mistral',
  'deepinfra' => 'DeepInfra',
  'local' => 'Whisper local',
  'groq' => 'Groq',
  _ => value,
};

const Set<String> _officialVoiceOptionPaths = {
  'tts.edge.voice',
  'tts.openai.model',
  'tts.openai.voice',
  'tts.elevenlabs.model_id',
  'tts.gemini.model',
  'tts.gemini.voice',
  'tts.xai.voice_id',
  'tts.minimax.model',
  'tts.mistral.model',
  'tts.neutts.model',
  'tts.neutts.device',
  'tts.kittentts.model',
  'tts.kittentts.voice',
  'tts.piper.voice',
  'stt.local.model',
  'stt.groq.model',
  'stt.openai.model',
  'stt.elevenlabs.model_id',
};

String _fieldLabel(
  BuildContext context,
  String key,
  Map<String, dynamic> spec,
) {
  String? publishedLabel;
  for (final schemaKey in const [
    'label',
    'title',
    'display_name',
    'displayName',
  ]) {
    final published = spec[schemaKey]?.toString().trim();
    if (published != null &&
        published.isNotEmpty &&
        !_isTechnicalSchemaText(published, key)) {
      publishedLabel = published;
      break;
    }
  }

  final s = Strings.of(context);
  if (publishedLabel != null) return publishedLabel;
  final concept = _fieldConcept(key);
  final part = key.split('.').last;
  final localized = switch (concept) {
    'provider' => s.voiceServerProviderLabel,
    'model' => s.voiceFieldModel,
    'voice' => s.voiceServerVoiceLabel,
    'language' => s.languageSettingTitle,
    'device' => s.voiceServerFieldDevice,
    'speed' => s.voiceServerFieldSpeed,
    'enabled' => s.voiceServerFieldEnabled,
    'vad' => s.voiceServerFieldVad,
    'silence_duration' => s.voiceServerFieldSilenceDuration,
    'no_speech_threshold' => s.voiceServerFieldNoSpeechThreshold,
    'confidence_threshold' => s.voiceServerFieldConfidenceThreshold,
    _ => null,
  };
  if (localized != null) return _sentenceCase(localized);
  return _sentenceCase(part.replaceAll('_', ' '));
}

String? _fieldHelp(
  BuildContext context,
  String key,
  Map<String, dynamic> spec,
) {
  final s = Strings.of(context);
  switch (_fieldConcept(key)) {
    case 'model':
      return s.voiceServerFieldModelHelp;
    case 'voice':
      return s.voiceServerFieldVoiceHelp;
    case 'language':
      return s.voiceServerFieldLanguageHelp;
    case 'speed':
      return s.voiceServerFieldSpeedHelp;
    case 'device':
      return s.voiceServerFieldDeviceHelp;
    case 'vad':
      return s.voiceServerFieldVadHelp;
    case 'silence_duration':
      return s.voiceServerFieldSilenceDurationHelp;
    case 'no_speech_threshold':
      return s.voiceServerFieldNoSpeechThresholdHelp;
    case 'confidence_threshold':
      return s.voiceServerFieldConfidenceThresholdHelp;
  }
  final description = spec['description']?.toString().trim();
  if (description != null &&
      description.isNotEmpty &&
      !_isTechnicalSchemaText(description, key)) {
    return description;
  }
  return null;
}

String? _fieldUnit(String key, Map<String, dynamic> spec) {
  for (final schemaKey in const ['unit', 'units', 'suffix']) {
    final unit = spec[schemaKey]?.toString().trim();
    if (unit != null && unit.isNotEmpty && unit.length <= 12) return unit;
  }
  final normalized = _collapsed(key);
  if (normalized.endsWith('ms') || normalized.contains('durationms')) {
    return 'ms';
  }
  if (normalized.endsWith('seconds') || normalized.endsWith('secs')) {
    return 's';
  }
  return null;
}

String _fieldConcept(String key) {
  final part = _collapsed(key.split('.').last);
  if (part == 'provider') return 'provider';
  if (part == 'model' || part == 'modelid' || part.endsWith('modelid')) {
    return 'model';
  }
  if (part == 'voice' || part == 'voiceid' || part.endsWith('voiceid')) {
    return 'voice';
  }
  if (part == 'language' || part == 'languagecode' || part == 'lang') {
    return 'language';
  }
  if (part == 'speed' || part == 'rate' || part == 'speakingrate') {
    return 'speed';
  }
  if (part == 'enabled' || part == 'active') return 'enabled';
  if (part.contains('nospeech') && part.contains('threshold')) {
    return 'no_speech_threshold';
  }
  if ((part.contains('logprob') || part.contains('confidence')) &&
      part.contains('threshold')) {
    return 'confidence_threshold';
  }
  if (part.contains('silence') &&
      (part.contains('duration') || part.contains('timeout'))) {
    return 'silence_duration';
  }
  if (part == 'vad' ||
      part == 'usevad' ||
      (part.contains('vad') &&
          (part.contains('enabled') || part.contains('active')))) {
    return 'vad';
  }
  return part;
}

int _fieldOrder(String key) => switch (_fieldConcept(key)) {
  'model' => 10,
  'voice' => 20,
  'language' => 30,
  'speed' => 40,
  'vad' => 50,
  'silence_duration' => 60,
  'no_speech_threshold' => 70,
  'confidence_threshold' => 80,
  'enabled' => 90,
  _ => 100,
};

bool _isTechnicalSchemaText(String value, String key) {
  final normalized = value.trim().toLowerCase();
  final path = key.toLowerCase();
  if (normalized.contains('→') ||
      normalized.contains(path) ||
      normalized.startsWith('stt.') ||
      normalized.startsWith('tts.')) {
    return true;
  }
  final words = normalized
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .trim()
      .split(RegExp(r'\s+'));
  return words.length >= 3 &&
      (words.first == 'stt' || words.first == 'tts') &&
      words.contains(key.split('.').last.toLowerCase());
}

String _sentenceCase(String value) => value.isEmpty
    ? value
    : '${value.substring(0, 1).toUpperCase()}${value.substring(1)}';
