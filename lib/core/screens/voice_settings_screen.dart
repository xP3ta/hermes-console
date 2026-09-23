// Ajustes de voz separados por intención: convertir voz a texto y texto a voz.
// Los catálogos e integraciones técnicas permanecen plegados hasta solicitarlos.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/app_localizations.dart';
import '../../main.dart';
import '../config/flavor.dart';
import '../widgets/hermes_notice.dart';
import 'instance_edit_screen.dart';
import '../services/connection_manager.dart';
import '../services/voice/conversation/native_voice.dart';
import '../services/voice/hermes_speech_stream.dart';
import '../services/voice/tts_engine.dart';
import '../services/voice/model_download.dart';
import '../services/voice/server_voice_config.dart';
import '../services/voice/stt_remote.dart';
import '../services/voice/stt_sherpa.dart';
import '../services/voice/tts_model_manager.dart';
import '../services/voice/voice_service.dart';
import '../services/voice/voice_settings.dart';
import '../theme/app_theme.dart';
import '../utils/api_error.dart';
import '../utils/transport_privacy.dart';
import '../utils/voice_error.dart';
import '../widgets/general_dock_shell.dart';
import '../widgets/hermes_ui.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/hermes_premium_ui.dart';
import '../widgets/server_voice_control_surface.dart';
import '../widgets/voice_disclosure_dialog.dart';

typedef KokoroDiscoveryCallback =
    Future<KokoroTtsDiscovery> Function({
      required String address,
      required String port,
      required String apiKey,
    });

typedef HermesServerPreviewEngineFactory =
    TtsEngine Function(HermesSpeakRequest synthesize);

/// Momento en el que el usuario quiere recibir la transcripción. El motor STT
/// concreto se elige aparte solo para el modo en directo.
enum _SttSetupMode { live, afterSpeaking }

@visibleForTesting
String? resolveVoiceServerProfile({
  required String? requestedProfile,
  required ConnectionManager? manager,
  required SavedConnection connection,
}) {
  final candidate =
      requestedProfile ?? manager?.activeProfileFor(connection.id);
  final normalized = candidate?.trim();
  return normalized == null || normalized.isEmpty || normalized == 'default'
      ? null
      : normalized;
}

class VoiceSettingsScreen extends StatefulWidget {
  final KokoroDiscoveryCallback? kokoroDiscover;
  final VoiceService? voiceService;
  final SavedConnection? connection;
  final DashboardClientFactory? dashboardClientFactory;
  final SharedPreferences? preferences;
  final String? profile;
  final HermesServerPreviewEngineFactory? serverPreviewEngineFactory;

  const VoiceSettingsScreen({
    super.key,
    this.kokoroDiscover,
    this.connection,
    @visibleForTesting this.voiceService,
    @visibleForTesting this.dashboardClientFactory,
    @visibleForTesting this.preferences,
    @visibleForTesting this.serverPreviewEngineFactory,
    this.profile,
  });

  @override
  State<VoiceSettingsScreen> createState() => _VoiceSettingsScreenState();
}

/// Elección visible para Lectura. Kokoro y OpenAI-compatible son dos caminos
/// distintos para el usuario aunque compartan el motor HTTP interno.
enum _TtsSetupChoice {
  device,
  onDeviceNeural,
  kokoro,
  openAiCompatible,
  elevenLabs,
  customRest,
}

class _VoiceSettingsScreenState extends State<VoiceSettingsScreen> {
  final _scrollController = ScrollController();
  VoiceService? _voice;
  late VoiceSettings _s;
  final _keyCtrl = TextEditingController();
  final _voiceIdCtrl = TextEditingController();
  bool _keyObscured = true;
  bool _loaded = false;
  bool _testingVoice = false;
  TtsEngine? _previewEngine;
  int _previewEpoch = 0;
  SttEngineKind _lastLiveSttEngine = SttEngineKind.sherpaLive;

  // Estado del modelo Whisper.
  bool _whisperReady = false;
  bool _downloading = false;
  double _progress = 0;

  // Estado de la voz neuronal on-device (sherpa-onnx).
  final Set<String> _onnxReady = {};
  String? _onnxBusyVoiceId; // voz que se está descargando/extrayendo
  String? _onnxDeletingVoiceId;
  double _onnxProgress = 0;
  TtsPrepPhase _onnxPhase = TtsPrepPhase.downloading;

  // Estado de los modelos del STT en vivo (sherpa-onnx).
  final Set<String> _sherpaReady = {};
  String? _sherpaBusyId; // modelo que se está descargando/extrayendo
  double _sherpaProgress = 0;
  SherpaPrepPhase _sherpaPhase = SherpaPrepPhase.downloading;

  // Estado del STT por servidor (faster-whisper).
  final _serverUrlCtrl = TextEditingController();
  final _serverTokenCtrl = TextEditingController();
  bool _serverTokenObscured = true;
  bool _serverTesting = false;
  bool? _serverTestOk; // null = sin probar

  // Estado del TTS por streaming (Kokoro local / nube formato OpenAI).
  final _streamUrlCtrl = TextEditingController();
  final _streamVoiceCtrl = TextEditingController();
  final _streamModelCtrl = TextEditingController();
  final _streamTokenCtrl = TextEditingController();
  bool _streamTokenObscured = true;
  final _kokoroAddressCtrl = TextEditingController();
  final _kokoroPortCtrl = TextEditingController(text: '8880');
  List<String> _kokoroVoices = const [];
  bool _kokoroDiscovering = false;

  // Estado del TTS HTTP/REST personalizado. La credencial se carga y guarda
  // aparte en Keystore; el resto es configuración no secreta.
  final _customUrlCtrl = TextEditingController();
  final _customVoiceCtrl = TextEditingController();
  final _customModelCtrl = TextEditingController();
  final _customBodyCtrl = TextEditingController();
  final _customHeaderCtrl = TextEditingController();
  final _customPrefixCtrl = TextEditingController();
  final _customSecretCtrl = TextEditingController();
  final _customBase64PathCtrl = TextEditingController();
  final _customMimeCtrl = TextEditingController();
  bool _customSecretObscured = true;

  String? _nativeVoiceIdentity;
  DashboardClient? _nativeVoiceDashboard;
  bool _ownsNativeVoiceDashboard = false;
  String? _effectiveProfile;
  NativeVoiceCapability? _nativeVoiceCapability;
  NativeVoiceConsent _nativeVoiceConsent = NativeVoiceConsent.pending;
  NativeVoiceMode _nativeVoiceMode = NativeVoiceMode.phone;
  bool _nativeVoiceLoading = false;
  int _nativeVoiceLoadEpoch = 0;
  SavedConnection? _nativeVoiceConnection;
  Map<String, dynamic>? _serverVoiceConfig;
  HermesServerVoiceSummary? _serverVoiceSummary;
  String? _serverTtsProvider;
  bool _serverVoiceConfigLoading = false;
  bool _serverVoiceTesting = false;
  bool _serverVoiceConfigFailed = false;
  Object? _serverVoiceConfigError;
  bool _serverVoiceDetailsExpanded = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    final appState = context.findAncestorStateOfType<HermesAppState>();
    _voice = widget.voiceService ?? appState?.voice;
    _s = _voice?.settings ?? const VoiceSettings();
    if (_s.sttEngine != SttEngineKind.whisper &&
        _s.sttEngine != SttEngineKind.hermesServer) {
      _lastLiveSttEngine = _s.sttEngine;
    }
    _voiceIdCtrl.text = _s.elevenVoiceId;
    _voice?.elevenKey().then((k) {
      if (mounted && k != null) _keyCtrl.text = k;
    });
    _voice?.whisperModelReady().then((r) {
      if (mounted) setState(() => _whisperReady = r);
    });
    _refreshOnnxReady();
    _refreshSherpaReady();
    _serverUrlCtrl.text = _s.serverSttUrl;
    _voice?.serverSttToken().then((t) {
      if (mounted && t != null) _serverTokenCtrl.text = t;
    });
    _applyStreamingProfileToControllers(_s);
    unawaited(_loadStreamingToken(_s.streamingTtsProfile));
    _customUrlCtrl.text = _s.customTtsUrl;
    _customVoiceCtrl.text = _s.customTtsVoice;
    _customModelCtrl.text = _s.customTtsModel;
    _customBodyCtrl.text = _s.customTtsBodyTemplate;
    _customHeaderCtrl.text = _s.customTtsHeaderName;
    _customPrefixCtrl.text = _s.customTtsHeaderPrefix;
    _customBase64PathCtrl.text = _s.customTtsBase64Path;
    _customMimeCtrl.text = _s.customTtsMimeType;
    _voice?.customTtsSecret().then((secret) {
      if (mounted && secret != null) _customSecretCtrl.text = secret;
    });
    _loaded = true;
    unawaited(_loadNativeVoiceChoice());
  }

  Future<void> _loadNativeVoiceChoice() async {
    final app = context.findAncestorStateOfType<HermesAppState>();
    final manager = app?.connManager;
    final preferences = widget.preferences ?? manager?.prefs;
    if (preferences == null) return;

    // Las rutas de voz ya conocen la instancia con la que se abrieron y la
    // pasan directamente. El fallback cubre accesos antiguos y el caso sin
    // instancia predeterminada, donde el notifier puede seguir en null aunque
    // `last_connection_id` y el Home sí tengan una conexión válida.
    var connection = widget.connection;
    final preferredConnectionId = connection?.id;
    if (preferredConnectionId != null && manager != null) {
      for (final candidate in manager.getConnections()) {
        if (candidate.id == preferredConnectionId) {
          connection = candidate;
          break;
        }
      }
    }
    if (connection == null) {
      if (manager == null) return;
      final activeId =
          manager.activeConnectionId.value ??
          manager.prefs.getString(ConnectionManager.lastConnKey);
      for (final candidate in manager.getConnections()) {
        if (candidate.id == activeId) {
          connection = candidate;
          break;
        }
      }
    }
    if (connection == null) return;

    final epoch = ++_nativeVoiceLoadEpoch;
    final effectiveProfile = resolveVoiceServerProfile(
      requestedProfile: widget.profile,
      manager: manager,
      connection: connection,
    );
    final injectedFactory = widget.dashboardClientFactory;
    final ownsDashboard = injectedFactory == null;
    late final DashboardClient dashboard;
    try {
      dashboard =
          injectedFactory?.call(connection) ?? DashboardClient.lazy(connection);
    } catch (error) {
      debugPrint(
        '[voice-settings] dashboard client unavailable '
        '(${error.runtimeType})',
      );
      if (!mounted || epoch != _nativeVoiceLoadEpoch) return;
      setState(() {
        _nativeVoiceConnection = connection;
        _effectiveProfile = effectiveProfile;
        _nativeVoiceLoading = false;
        _serverVoiceConfigLoading = false;
        _serverVoiceConfigFailed = true;
        _serverVoiceConfigError = error;
      });
      return;
    }
    if (!mounted) {
      if (ownsDashboard) dashboard.close();
      return;
    }
    final identity = nativeVoicePreferenceIdentity(
      dashboard.baseUrl,
      profile: effectiveProfile,
    );
    final store = NativeVoiceConsentStore(preferences);
    final modeStore = NativeVoiceModeStore(preferences);
    final capabilityStore = NativeVoiceCapabilityStore(preferences);
    final storedConsent = store.read(identity);
    final storedMode = modeStore.read(identity);
    var capability = capabilityStore.read(identity);
    if (mounted) {
      setState(() {
        _nativeVoiceIdentity = identity;
        _nativeVoiceDashboard = dashboard;
        _ownsNativeVoiceDashboard = ownsDashboard;
        _effectiveProfile = effectiveProfile;
        _nativeVoiceConnection = connection;
        _nativeVoiceConsent = storedConsent;
        _nativeVoiceMode = storedMode;
        _nativeVoiceCapability = capability;
        _nativeVoiceLoading =
            capability == null || !capabilityStore.isFresh(capability);
      });
    }
    if (storedMode == NativeVoiceMode.server &&
        storedConsent == NativeVoiceConsent.accepted) {
      unawaited(_loadServerVoiceConfig(dashboard, epoch));
    }

    if (capability == null || !capabilityStore.isFresh(capability)) {
      capability = await probeNativeVoiceCapability(
        statusOf: (name) =>
            dashboard.probeAudioEndpoint(name, profile: effectiveProfile),
      );
      await capabilityStore.write(identity, capability);
    }
    if (!mounted || epoch != _nativeVoiceLoadEpoch) return;
    setState(() {
      _nativeVoiceCapability = capability;
      _nativeVoiceLoading = false;
    });
  }

  static String? _configString(Map<String, dynamic> config, List<String> path) {
    Object? value = config;
    for (final segment in path) {
      if (value is! Map || !value.containsKey(segment)) return null;
      value = value[segment];
    }
    final text = value?.toString().trim();
    return text == null || text.isEmpty ? null : text;
  }

  Future<void> _loadServerVoiceConfig(
    DashboardClient dashboard,
    int epoch,
  ) async {
    if (mounted && epoch == _nativeVoiceLoadEpoch) {
      setState(() {
        _serverVoiceConfigLoading = true;
        _serverVoiceConfigFailed = false;
        _serverVoiceConfigError = null;
      });
    }
    try {
      Map<String, dynamic>? schema;
      try {
        schema = await dashboard.getServerConfigSchema(
          profile: _effectiveProfile,
        );
      } catch (_) {
        // Config y schema tienen compatibilidad independiente. Un Hermes
        // antiguo puede servir la voz efectiva sin publicar todavía catálogo.
      }
      final config = sanitizeHermesServerVoiceConfig(
        await dashboard.getServerConfig(profile: _effectiveProfile),
        schema ?? const {},
      );
      final provider = _configString(config, const ['tts', 'provider']);
      final summary = HermesServerVoiceSummary.fromConfig(
        config,
        pcmStreamingObserved: _pcmObservedForConfig(config, dashboard.baseUrl),
      );
      if (!mounted || epoch != _nativeVoiceLoadEpoch) return;
      setState(() {
        _serverVoiceConfig = config;
        _serverVoiceSummary = summary;
        _serverTtsProvider = provider;
        _serverVoiceConfigLoading = false;
        _serverVoiceConfigFailed = false;
        _serverVoiceConfigError = null;
      });
    } catch (error) {
      final reason = error is DashboardHttpException
          ? 'http_${error.statusCode}'
          : error.runtimeType.toString();
      debugPrint('[voice-settings] server config unavailable ($reason)');
      if (!mounted || epoch != _nativeVoiceLoadEpoch) return;
      setState(() {
        _serverVoiceConfigLoading = false;
        _serverVoiceConfigFailed = true;
        _serverVoiceConfigError = error;
      });
    }
  }

  bool _pcmObservedForConfig(
    Map<String, dynamic> config,
    String dashboardBaseUrl,
  ) => HermesSpeechStreamEvidence.pcmObserved(
    dashboardBaseUrl,
    profile: _effectiveProfile,
    ttsConfigurationSignature: hermesServerTtsConfigurationSignature(config),
  );

  Future<void> _selectNativeVoice(bool useServer) async {
    final identity = _nativeVoiceIdentity;
    final dashboard = _nativeVoiceDashboard;
    final voice = _voice;
    final app = context.findAncestorStateOfType<HermesAppState>();
    final preferences = widget.preferences ?? app?.connManager.prefs;
    if (identity == null ||
        dashboard == null ||
        voice == null ||
        preferences == null) {
      return;
    }
    setState(() => _nativeVoiceLoading = true);
    final mode = useServer ? NativeVoiceMode.server : NativeVoiceMode.phone;
    var consent = _nativeVoiceConsent;
    // Persistir primero el consentimiento y después el modo hace que una
    // escritura interrumpida falle de forma privada: sin la clave de modo
    // nueva la siguiente apertura seguirá usando el teléfono.
    if (useServer) {
      consent = NativeVoiceConsent.accepted;
      await NativeVoiceConsentStore(preferences).write(identity, consent);
    }
    await NativeVoiceModeStore(preferences).write(identity, mode);
    if (useServer && _nativeVoiceCapability?.ok == true) {
      voice.enableNativeVoice(
        speak: (text) =>
            dashboard.synthesizeSpeech(text, profile: _effectiveProfile),
        transcribe: (dataUrl, mimeType) => dashboard.transcribeAudio(
          dataUrl,
          mimeType: mimeType,
          profile: _effectiveProfile,
        ),
      );
      if (_serverVoiceConfig == null && !_serverVoiceConfigLoading) {
        unawaited(_loadServerVoiceConfig(dashboard, _nativeVoiceLoadEpoch));
      }
    } else {
      voice.disableNativeVoice();
    }
    if (!mounted) return;
    setState(() {
      _nativeVoiceConsent = consent;
      _nativeVoiceMode = mode;
      _nativeVoiceLoading = false;
    });
  }

  Future<void> _refreshOnnxReady() async {
    final v = _voice;
    if (v == null) return;
    for (final voice in kNeuralVoices) {
      final ready = await v.ttsModels.isReady(voice);
      if (!mounted) return;
      setState(() {
        if (ready) {
          _onnxReady.add(voice.id);
        } else {
          _onnxReady.remove(voice.id);
        }
      });
    }
  }

  Future<void> _downloadOnnx(NeuralVoice voice) async {
    final v = _voice;
    if (v == null) return;
    setState(() {
      _onnxBusyVoiceId = voice.id;
      _onnxProgress = 0;
      _onnxPhase = TtsPrepPhase.downloading;
    });
    try {
      await v.ttsModels.download(
        voice,
        onProgress: (p) {
          if (mounted) {
            setState(() {
              _onnxPhase = p.phase;
              _onnxProgress = p.value;
            });
          }
        },
      );
      if (mounted) setState(() => _onnxReady.add(voice.id));
      // Si la voz elegida ya no existe (p.ej. Carlos se borró antes de descargar
      // David), la recién preparada pasa a ser la activa. Así nunca queda ONNX
      // apuntando silenciosamente a una carpeta ausente.
      final selected = neuralVoiceById(_s.onnxVoiceId);
      final selectedReady =
          selected != null && await v.ttsModels.isReady(selected);
      if (!selectedReady) {
        await _update(_s.copyWith(onnxVoiceId: voice.id));
      } else if (_s.onnxVoiceId == voice.id) {
        await v.saveSettings(_s);
      }
    } on ModelDownloadCancelled {
      // Cancelación solicitada por el usuario: no es un fallo.
    } catch (e) {
      if (mounted) {
        _snack(
          Strings.of(context).voiceDownloadFailed(e.toString()),
        ); // mounted check before context use
      }
    } finally {
      if (mounted) setState(() => _onnxBusyVoiceId = null);
    }
  }

  void _cancelOnnx(NeuralVoice voice) {
    _voice?.ttsModels.cancelDownload(voice);
  }

  Future<void> _deleteOnnx(NeuralVoice voice) async {
    final service = _voice;
    if (service == null || _onnxDeletingVoiceId != null || _testingVoice) {
      return;
    }
    setState(() => _onnxDeletingVoiceId = voice.id);
    try {
      // Orden obligatorio: primero parar y liberar el worker/modelo; después
      // tocar su carpeta. El orden inverso era el bloqueo Carlos → David.
      await service.releaseTtsForModelMutation();
      await service.ttsModels.delete(voice);
      _onnxReady.remove(voice.id);

      if (_s.onnxVoiceId == voice.id) {
        final fallback = await service.ttsModels.firstReady();
        if (fallback != null) {
          await _update(_s.copyWith(onnxVoiceId: fallback.id));
        } else {
          // Conserva la preferencia para que una nueva descarga de esa voz la
          // reactive, pero persiste el estado con el motor ya liberado.
          await service.saveSettings(_s);
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _onnxReady.remove(voice.id);
          _onnxDeletingVoiceId = null;
        });
      }
    }
  }

  Future<void> _refreshSherpaReady() async {
    final v = _voice;
    if (v == null) return;
    for (final m in kSherpaSttModels) {
      final ready = await v.sherpaReady(m);
      if (!mounted) return;
      setState(() {
        if (ready) {
          _sherpaReady.add(m.id);
        } else {
          _sherpaReady.remove(m.id);
        }
      });
    }
  }

  Future<void> _downloadSherpa(SherpaSttModel m) async {
    final v = _voice;
    if (v == null) return;
    setState(() {
      _sherpaBusyId = m.id;
      _sherpaProgress = 0;
      _sherpaPhase = SherpaPrepPhase.downloading;
    });
    try {
      await v.downloadSherpaModel(
        m,
        onProgress: (p) {
          if (mounted) {
            setState(() {
              _sherpaPhase = p.phase;
              _sherpaProgress = p.value;
            });
          }
        },
      );
      if (mounted) setState(() => _sherpaReady.add(m.id));
      // Si es el modelo elegido, fuerza reconstruir el motor activo.
      if (_s.sherpaModel == m.kind) await _voice?.saveSettings(_s);
    } on ModelDownloadCancelled {
      // Cancelación solicitada por el usuario: no es un fallo.
    } catch (e) {
      if (mounted) {
        _snack(Strings.of(context).voiceDownloadFailed(e.toString()));
      }
    } finally {
      if (mounted) setState(() => _sherpaBusyId = null);
    }
  }

  void _cancelSherpa(SherpaSttModel model) {
    _voice?.sherpaModels.cancelDownload(model);
  }

  Future<void> _deleteSherpa(SherpaSttModel m) async {
    await _voice?.deleteSherpaModel(m);
    if (mounted) setState(() => _sherpaReady.remove(m.id));
  }

  Future<void> _downloadWhisper() async {
    final v = _voice;
    if (v == null) return;
    setState(() {
      _downloading = true;
      _progress = 0;
    });
    try {
      await v.downloadWhisperModel(
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      if (mounted) setState(() => _whisperReady = true);
    } catch (e) {
      if (mounted) {
        _snack(
          Strings.of(context).voiceDownloadFailed(e.toString()),
        ); // mounted check before context use
      }
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  @override
  void dispose() {
    ++_nativeVoiceLoadEpoch;
    final dashboard = _nativeVoiceDashboard;
    _nativeVoiceDashboard = null;
    if (_ownsNativeVoiceDashboard) dashboard?.close();
    _ownsNativeVoiceDashboard = false;
    ++_previewEpoch;
    final previewEngine = _previewEngine;
    _previewEngine = null;
    if (previewEngine != null) {
      unawaited(_disposePreviewEngine(previewEngine));
    }
    _scrollController.dispose();
    _keyCtrl.dispose();
    _voiceIdCtrl.dispose();
    _serverUrlCtrl.dispose();
    _serverTokenCtrl.dispose();
    _streamUrlCtrl.dispose();
    _streamVoiceCtrl.dispose();
    _streamModelCtrl.dispose();
    _streamTokenCtrl.dispose();
    _kokoroAddressCtrl.dispose();
    _kokoroPortCtrl.dispose();
    _customUrlCtrl.dispose();
    _customVoiceCtrl.dispose();
    _customModelCtrl.dispose();
    _customBodyCtrl.dispose();
    _customHeaderCtrl.dispose();
    _customPrefixCtrl.dispose();
    _customSecretCtrl.dispose();
    _customBase64PathCtrl.dispose();
    _customMimeCtrl.dispose();
    super.dispose();
  }

  void _loadKokoroAddress(String baseUrl) {
    final uri = Uri.tryParse(baseUrl.trim());
    if (uri == null || uri.host.isEmpty) {
      _kokoroAddressCtrl.clear();
      _kokoroPortCtrl.text = '8880';
      return;
    }
    _kokoroAddressCtrl.text = Uri(
      scheme: uri.scheme,
      host: uri.host,
    ).toString().replaceAll(RegExp(r'/+$'), '');
    _kokoroPortCtrl.text = uri.hasPort
        ? '${uri.port}'
        : (uri.scheme == 'https' ? '443' : '8880');
  }

  void _applyStreamingProfileToControllers(VoiceSettings settings) {
    _streamUrlCtrl.text = settings.streamingTtsUrl;
    _streamVoiceCtrl.text = settings.streamingTtsVoice;
    _streamModelCtrl.text = settings.streamingTtsModel;
    if (settings.streamingTtsProfile == StreamingTtsProfile.kokoro) {
      _loadKokoroAddress(settings.kokoroTtsUrl);
    }
  }

  Future<void> _loadStreamingToken(StreamingTtsProfile profile) async {
    _streamTokenCtrl.clear();
    final token = await _voice?.streamingTtsToken(profile: profile);
    if (!mounted || _s.streamingTtsProfile != profile) return;
    _streamTokenCtrl.text = token ?? '';
  }

  /// Guarda URL (prefs) + token (Keystore) del servidor STT y prueba la conexión.
  Future<void> _saveServerStt({bool test = false}) async {
    final v = _voice;
    if (v == null) return;
    final url = _serverUrlCtrl.text.trim();
    await _update(_s.copyWith(serverSttUrl: url));
    await v.setServerSttToken(_serverTokenCtrl.text.trim());
    if (!test) {
      if (mounted) setState(() => _serverTestOk = null);
      return;
    }
    setState(() {
      _serverTesting = true;
      _serverTestOk = null;
    });
    final ok = await ServerSttEngine(
      baseUrl: url,
      token: _serverTokenCtrl.text.trim(),
    ).ping();
    if (mounted) {
      setState(() {
        _serverTesting = false;
        _serverTestOk = ok;
      });
    }
  }

  Future<void> _update(VoiceSettings s) async {
    setState(() => _s = s);
    await _voice?.saveSettings(s);
  }

  Future<void> _setContinueWhenLocked(bool value) async {
    final voice = _voice;
    if (voice == null) return;
    if (!value) {
      await voice.setContinueVoiceWhenLocked(false);
      if (mounted) setState(() {});
      return;
    }
    if (!voice.voiceDisclosureAccepted) {
      final choice = await showVoiceDisclosureDialog(context);
      if (!mounted || choice == null) return;
      await voice.acceptVoiceDisclosure(
        continueWhenLocked: choice == VoiceDisclosureChoice.continueWhenLocked,
      );
    } else {
      await voice.setContinueVoiceWhenLocked(true);
    }
    if (mounted) setState(() {});
  }

  Future<void> _selectEngine({SttEngineKind? stt, TtsEngineKind? tts}) async {
    await _update(_s.copyWith(sttEngine: stt, ttsEngine: tts));
  }

  _SttSetupMode get _sttSetupMode =>
      _s.sttEngine == SttEngineKind.whisper ||
          _s.sttEngine == SttEngineKind.hermesServer
      ? _SttSetupMode.afterSpeaking
      : _SttSetupMode.live;

  Future<void> _selectSttSetupMode(_SttSetupMode mode) async {
    if (mode == _sttSetupMode) return;
    if (mode == _SttSetupMode.afterSpeaking) {
      _lastLiveSttEngine = _s.sttEngine;
      await _selectEngine(stt: SttEngineKind.whisper);
      return;
    }
    await _selectEngine(stt: _lastLiveSttEngine);
  }

  Future<void> _selectLiveSttEngine(SttEngineKind engine) async {
    _lastLiveSttEngine = engine;
    await _selectEngine(stt: engine);
  }

  Future<void> _selectHermesDictation(bool useServer) async {
    if (!useServer) {
      _lastLiveSttEngine = SttEngineKind.sherpaLive;
      await _update(
        _s.copyWith(
          sttEngine: SttEngineKind.sherpaLive,
          sherpaModel: SherpaModelKind.parakeetV3,
        ),
      );
      return;
    }
    final identity = _nativeVoiceIdentity;
    final dashboard = _nativeVoiceDashboard;
    final app = context.findAncestorStateOfType<HermesAppState>();
    final preferences = widget.preferences ?? app?.connManager.prefs;
    if (identity == null || dashboard == null || preferences == null) return;
    if (_nativeVoiceCapability?.transcribe != true) return;
    await NativeVoiceConsentStore(
      preferences,
    ).write(identity, NativeVoiceConsent.accepted);
    if (!mounted) return;
    setState(() => _nativeVoiceConsent = NativeVoiceConsent.accepted);
    await _selectEngine(stt: SttEngineKind.hermesServer);
  }

  _TtsSetupChoice get _ttsChoice {
    return switch (_s.ttsEngine) {
      TtsEngineKind.device => _TtsSetupChoice.device,
      TtsEngineKind.onnx => _TtsSetupChoice.onDeviceNeural,
      TtsEngineKind.streaming =>
        _s.streamingTtsProfile == StreamingTtsProfile.kokoro
            ? _TtsSetupChoice.kokoro
            : _TtsSetupChoice.openAiCompatible,
      TtsEngineKind.elevenlabs => _TtsSetupChoice.elevenLabs,
      TtsEngineKind.customHttp => _TtsSetupChoice.customRest,
    };
  }

  Future<void> _selectTtsChoice(_TtsSetupChoice choice) async {
    switch (choice) {
      case _TtsSetupChoice.device:
        await _selectEngine(tts: TtsEngineKind.device);
      case _TtsSetupChoice.onDeviceNeural:
        await _selectEngine(tts: TtsEngineKind.onnx);
      case _TtsSetupChoice.kokoro:
        final next = _s.copyWith(
          ttsEngine: TtsEngineKind.streaming,
          streamingTtsProfile: StreamingTtsProfile.kokoro,
        );
        _applyStreamingProfileToControllers(next);
        await _update(next);
        if (mounted) {
          await _loadStreamingToken(StreamingTtsProfile.kokoro);
        }
      case _TtsSetupChoice.openAiCompatible:
        final next = _s.copyWith(
          ttsEngine: TtsEngineKind.streaming,
          streamingTtsProfile: StreamingTtsProfile.openAiCompatible,
        );
        _applyStreamingProfileToControllers(next);
        await _update(next);
        if (mounted) {
          await _loadStreamingToken(StreamingTtsProfile.openAiCompatible);
        }
      case _TtsSetupChoice.elevenLabs:
        await _selectEngine(tts: TtsEngineKind.elevenlabs);
      case _TtsSetupChoice.customRest:
        await _selectEngine(tts: TtsEngineKind.customHttp);
    }
  }

  Future<void> _saveKey() async {
    final s = Strings.of(context);
    await _voice?.setElevenKey(_keyCtrl.text.trim());
    if (mounted) _snack(s.voiceKeySaved);
  }

  /// Persiste la config del TTS por streaming: URL/voz/modelo en ajustes y el
  /// token (si lo hay) en el Keystore. El motor se reconstruye al cambiar ajustes.
  Future<void> _saveStream() async {
    final strings = Strings.of(context);
    final url = _streamUrlCtrl.text.trim();
    if (url.isEmpty) {
      _snack(strings.voiceStreamNeedUrl);
      return;
    }
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.host.isEmpty ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      _snack(strings.voiceStreamInvalidUrl);
      return;
    }
    try {
      TransportPrivacy.requireAllowed(url);
    } on ArgumentError {
      _snack(strings.voiceStreamUnsafeUrl);
      return;
    }
    final profile = _s.streamingTtsProfile;
    final voice = _streamVoiceCtrl.text.trim();
    final model = _streamModelCtrl.text.trim();
    final defaultVoice = profile == StreamingTtsProfile.kokoro
        ? VoiceSettings.defaultStreamingVoiceFor(
            Localizations.localeOf(context).languageCode,
          )
        : 'alloy';
    final defaultModel = profile == StreamingTtsProfile.kokoro
        ? 'kokoro'
        : 'tts-1';
    final settings = _s.copyWith(
      streamingTtsUrl: url,
      streamingTtsVoice: voice.isEmpty ? defaultVoice : voice,
      streamingTtsModel: model.isEmpty ? defaultModel : model,
    );
    _applyStreamingProfileToControllers(settings);
    await _update(settings);
    await _voice?.setStreamingTtsToken(
      _streamTokenCtrl.text.trim(),
      profile: profile,
    );
    if (mounted) _snack(strings.voiceStreamSaved);
  }

  Future<void> _discoverKokoro() async {
    if (_kokoroDiscovering) return;
    final strings = Strings.of(context);
    setState(() => _kokoroDiscovering = true);
    try {
      final result =
          await (widget.kokoroDiscover?.call(
                address: _kokoroAddressCtrl.text,
                port: _kokoroPortCtrl.text,
                apiKey: _streamTokenCtrl.text.trim(),
              ) ??
              KokoroTtsSetup.discover(
                address: _kokoroAddressCtrl.text,
                port: _kokoroPortCtrl.text,
                apiKey: _streamTokenCtrl.text.trim(),
              ));
      if (!mounted) return;
      final current = _streamVoiceCtrl.text.trim();
      final selected = result.voices.contains(current)
          ? current
          : result.voices.first;
      _streamUrlCtrl.text = result.baseUrl;
      _streamModelCtrl.text = 'kokoro';
      _streamVoiceCtrl.text = selected;
      await _update(
        _s.copyWith(
          ttsEngine: TtsEngineKind.streaming,
          streamingTtsProfile: StreamingTtsProfile.kokoro,
          streamingTtsUrl: result.baseUrl,
          streamingTtsVoice: selected,
          streamingTtsModel: 'kokoro',
        ),
      );
      await _voice?.setStreamingTtsToken(
        _streamTokenCtrl.text.trim(),
        profile: StreamingTtsProfile.kokoro,
      );
      if (!mounted) return;
      setState(() => _kokoroVoices = result.voices);
      _snack(strings.voiceKokoroDetected(result.voices.length));
    } catch (error) {
      if (mounted) {
        _snack(
          strings.voiceKokoroDetectionFailed(
            localizedVoiceError(strings, error),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _kokoroDiscovering = false);
    }
  }

  void _selectCustomAuth(CustomTtsAuthMode mode) {
    switch (mode) {
      case CustomTtsAuthMode.none:
        break;
      case CustomTtsAuthMode.bearer:
        _customHeaderCtrl.text = 'Authorization';
        _customPrefixCtrl.text = 'Bearer';
      case CustomTtsAuthMode.apiKey:
        _customHeaderCtrl.text = 'x-api-key';
        _customPrefixCtrl.clear();
      case CustomTtsAuthMode.custom:
        if (_customHeaderCtrl.text.trim().isEmpty) {
          _customHeaderCtrl.text = 'Authorization';
        }
    }
    _update(_s.copyWith(customTtsAuthMode: mode));
  }

  Future<bool> _saveCustom({bool notify = true}) async {
    final (header, prefix) = _customAuthParts();
    try {
      CustomHttpTtsEngine.buildRequest(
        url: _customUrlCtrl.text.trim(),
        bodyTemplate: _customBodyCtrl.text.trim(),
        text: Strings.of(context).voiceSampleText,
        voice: _customVoiceCtrl.text.trim(),
        model: _customModelCtrl.text.trim(),
        authHeaderName: header,
        authHeaderPrefix: prefix,
        authSecret: _customSecretCtrl.text.trim(),
        mimeType: _customMimeCtrl.text.trim(),
      );
    } catch (_) {
      if (mounted) _snack(Strings.of(context).voiceCustomInvalidConfiguration);
      return false;
    }
    final settings = _s.copyWith(
      customTtsUrl: _customUrlCtrl.text.trim(),
      customTtsVoice: _customVoiceCtrl.text.trim(),
      customTtsModel: _customModelCtrl.text.trim(),
      customTtsBodyTemplate: _customBodyCtrl.text.trim(),
      customTtsHeaderName: _customHeaderCtrl.text.trim(),
      customTtsHeaderPrefix: _customPrefixCtrl.text.trim(),
      // El motor ya reconoce audio binario y los JSON habituales. Las opciones
      // históricas se conservan al cargar preferencias, pero cualquier guardado
      // desde el formulario guiado converge al modo automático.
      customTtsResponseKind: CustomTtsResponseKind.auto,
      customTtsBase64Path: _customBase64PathCtrl.text.trim(),
      customTtsMimeType: _customMimeCtrl.text.trim(),
    );
    await _update(settings);
    await _voice?.setCustomTtsSecret(_customSecretCtrl.text.trim());
    if (notify && mounted) _snack(Strings.of(context).voiceCustomSaved);
    return true;
  }

  (String, String) _customAuthParts() {
    if (_s.customTtsAuthMode == CustomTtsAuthMode.none) return ('', '');
    return (_customHeaderCtrl.text.trim(), _customPrefixCtrl.text.trim());
  }

  void _snack(String m) =>
      HermesNotice.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _disposePreviewEngine(TtsEngine? engine) async {
    if (engine == null) return;
    try {
      await engine.stop().timeout(const Duration(seconds: 2));
    } catch (error) {
      debugPrint('[hermes-voice] no se pudo parar la prueba TTS: $error');
    }
    try {
      await engine.dispose().timeout(const Duration(seconds: 2));
    } catch (error) {
      debugPrint('[hermes-voice] no se pudo cerrar la prueba TTS: $error');
    }
  }

  Future<bool> _claimPreviewEngine(TtsEngine engine, int epoch) async {
    if (!mounted || epoch != _previewEpoch) {
      await _disposePreviewEngine(engine);
      return false;
    }
    _previewEngine = engine;
    return true;
  }

  Future<void> _releasePreviewEngine(TtsEngine? engine) async {
    if (engine == null || !identical(_previewEngine, engine)) return;
    _previewEngine = null;
    await _disposePreviewEngine(engine);
  }

  Future<void> _testVoice() async {
    final v = _voice;
    if (v == null || _testingVoice) return;
    final s = Strings.of(context);
    final sample = s.voiceSampleText;
    final previewEpoch = ++_previewEpoch;
    TtsEngine? previewEngine;
    setState(() => _testingVoice = true);
    try {
      if (_s.ttsEngine == TtsEngineKind.elevenlabs) {
        previewEngine = ElevenLabsTtsEngine(
          apiKey: _keyCtrl.text.trim(),
          voiceId: _voiceIdCtrl.text.trim().isEmpty
              ? _s.elevenVoiceId
              : _voiceIdCtrl.text.trim(),
          modelId: _s.elevenModelId,
        );
        if (!await _claimPreviewEngine(previewEngine, previewEpoch)) return;
        await v.previewTts(previewEngine, sample);
      } else if (_s.ttsEngine == TtsEngineKind.onnx) {
        final voice = neuralVoiceById(_s.onnxVoiceId);
        previewEngine = voice == null ? null : await v.buildOnnxPreview(voice);
        if (previewEngine == null) {
          _snack(s.voiceDownloadFirst);
          return;
        }
        if (!await _claimPreviewEngine(previewEngine, previewEpoch)) return;
        await v.previewTts(previewEngine, sample);
      } else if (_s.ttsEngine == TtsEngineKind.streaming) {
        final url = _streamUrlCtrl.text.trim();
        if (url.isEmpty) {
          _snack(s.voiceStreamNeedUrl);
          return;
        }
        final voiceId = _streamVoiceCtrl.text.trim();
        final model = _streamModelCtrl.text.trim();
        final kokoro = _s.streamingTtsProfile == StreamingTtsProfile.kokoro;
        previewEngine = OpenAiStreamingTtsEngine(
          baseUrl: url,
          voice: voiceId.isEmpty
              ? (kokoro
                    ? VoiceSettings.defaultStreamingVoiceFor(
                        Localizations.localeOf(context).languageCode,
                      )
                    : 'alloy')
              : voiceId,
          model: model.isEmpty ? (kokoro ? 'kokoro' : 'tts-1') : model,
          apiKey: _streamTokenCtrl.text.trim(),
        );
        if (!await _claimPreviewEngine(previewEngine, previewEpoch)) return;
        await v.previewTts(previewEngine, sample);
      } else if (_s.ttsEngine == TtsEngineKind.customHttp) {
        final (header, prefix) = _customAuthParts();
        previewEngine = CustomHttpTtsEngine(
          url: _customUrlCtrl.text.trim(),
          voice: _customVoiceCtrl.text.trim(),
          model: _customModelCtrl.text.trim(),
          bodyTemplate: _customBodyCtrl.text.trim(),
          authHeaderName: header,
          authHeaderPrefix: prefix,
          authSecret: _customSecretCtrl.text.trim(),
          autoDetectResponse: true,
          responseIsJsonBase64: false,
          base64Path: _customBase64PathCtrl.text.trim(),
          mimeType: _customMimeCtrl.text.trim(),
        );
        if (!await _claimPreviewEngine(previewEngine, previewEpoch)) return;
        await v.previewTts(previewEngine, sample);
        if (!await _saveCustom(notify: false)) return;
      } else {
        // Mudo si el móvil no tiene motor TTS (GrapheneOS): evita el crash de
        // flutter_tts (recursión → StackOverflow no capturable).
        previewEngine = await systemTtsOrSilent(lang: v.voiceLang);
        if (!await _claimPreviewEngine(previewEngine, previewEpoch)) return;
        await v.previewTts(previewEngine, sample);
      }
      if (mounted) _snack(s.voiceTestPlayed);
    } catch (e) {
      if (mounted) _snack(s.voiceNoPreview(localizedVoiceError(s, e)));
    } finally {
      await _releasePreviewEngine(previewEngine);
      if (mounted) setState(() => _testingVoice = false);
    }
  }

  Widget _streamingTtsSection(HermesThemeColors colors, Strings s) {
    final kokoro = _ttsChoice == _TtsSetupChoice.kokoro;
    final currentVoice = _kokoroVoices.contains(_streamVoiceCtrl.text.trim())
        ? _streamVoiceCtrl.text.trim()
        : (_kokoroVoices.isEmpty ? null : _kokoroVoices.first);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _disclaimer(
          colors,
          kokoro ? s.voiceKokoroDisclaimer : s.voiceOpenAiDisclaimer,
        ),
        const SizedBox(height: 12),
        if (kokoro) ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                flex: 3,
                child: _field(
                  colors: colors,
                  label: s.voiceServerAddress,
                  controller: _kokoroAddressCtrl,
                  hint: '192.168.1.10',
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _field(
                  colors: colors,
                  label: s.voiceServerPort,
                  controller: _kokoroPortCtrl,
                  hint: '8880',
                  keyboardType: TextInputType.number,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _field(
            colors: colors,
            label: s.voiceKokoroTokenHint,
            controller: _streamTokenCtrl,
            obscure: _streamTokenObscured,
            suffix: IconButton(
              icon: Icon(
                _streamTokenObscured ? Icons.visibility_off : Icons.visibility,
              ),
              iconSize: 20,
              color: colors.textSecondary,
              onPressed: () =>
                  setState(() => _streamTokenObscured = !_streamTokenObscured),
            ),
          ),
          const SizedBox(height: 10),
          HermesSecondaryButton(
            label: _kokoroDiscovering
                ? s.voiceDetectingKokoro
                : s.voiceDetectKokoro,
            icon: _kokoroDiscovering
                ? Icons.sync_rounded
                : Icons.auto_fix_high_outlined,
            onTap: _kokoroDiscovering ? null : _discoverKokoro,
          ),
          if (_streamUrlCtrl.text.trim().isNotEmpty) ...[
            const SizedBox(height: 12),
            _field(
              key: const ValueKey('stream_tts_url'),
              colors: colors,
              label: s.voiceDetectedBaseUrl,
              controller: _streamUrlCtrl,
              readOnly: true,
            ),
          ],
          if (_kokoroVoices.isNotEmpty) ...[
            const SizedBox(height: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _fieldLabel(colors, s.voiceFieldVoice),
                DropdownButtonFormField<String>(
                  key: const ValueKey('stream_tts_kokoro_voice'),
                  initialValue: currentVoice,
                  dropdownColor: colors.surface,
                  style: Theme.of(context).dropdownMenuTheme.textStyle,
                  decoration: _dropdownDecoration(colors),
                  items: [
                    for (final voice in _kokoroVoices)
                      DropdownMenuItem(value: voice, child: Text(voice)),
                  ],
                  onChanged: (voice) {
                    if (voice == null) return;
                    _streamVoiceCtrl.text = voice;
                    _saveStream();
                  },
                ),
              ],
            ),
          ],
        ] else ...[
          _field(
            key: const ValueKey('stream_tts_url'),
            colors: colors,
            label: s.voiceBaseUrl,
            controller: _streamUrlCtrl,
            hint: 'https://api.example.com/v1',
            onSubmitted: (_) => _saveStream(),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _field(
                  key: const ValueKey('stream_tts_voice'),
                  colors: colors,
                  label: s.voiceFieldVoice,
                  controller: _streamVoiceCtrl,
                  hint: 'alloy',
                  onSubmitted: (_) => _saveStream(),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _field(
                  key: const ValueKey('stream_tts_model'),
                  colors: colors,
                  label: s.voiceFieldModel,
                  controller: _streamModelCtrl,
                  hint: 'tts-1',
                  onSubmitted: (_) => _saveStream(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _field(
            colors: colors,
            label: s.voiceOpenAiTokenHint,
            controller: _streamTokenCtrl,
            obscure: _streamTokenObscured,
            suffix: IconButton(
              icon: Icon(
                _streamTokenObscured ? Icons.visibility_off : Icons.visibility,
              ),
              iconSize: 20,
              color: colors.textSecondary,
              onPressed: () =>
                  setState(() => _streamTokenObscured = !_streamTokenObscured),
            ),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: HermesSecondaryButton(
              key: const ValueKey('stream_tts_save'),
              label: s.voiceSaveConfiguration,
              icon: Icons.save_outlined,
              onTap: _saveStream,
            ),
          ),
        ],
      ],
    );
  }

  Widget _customTtsSection(HermesThemeColors colors, Strings s) {
    final authMode = _s.customTtsAuthMode;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _disclaimer(colors, s.voiceCustomDisclaimer),
        const SizedBox(height: 14),
        _field(
          key: const ValueKey('custom_tts_url'),
          colors: colors,
          label: s.voiceCustomEndpoint,
          controller: _customUrlCtrl,
          hint: 'https://tts.example.com/synthesize',
        ),
        const SizedBox(height: 12),
        _fieldLabel(colors, s.voiceCustomAuthentication),
        DropdownButtonFormField<CustomTtsAuthMode>(
          initialValue: authMode,
          dropdownColor: colors.surface,
          decoration: _dropdownDecoration(colors),
          style: TextStyle(
            color: colors.textPrimary,
            fontSize: 14,
            fontWeight: FontWeight.w400,
          ),
          iconEnabledColor: colors.textSecondary,
          items: [
            DropdownMenuItem(
              value: CustomTtsAuthMode.none,
              child: Text(s.voiceAuthNone),
            ),
            DropdownMenuItem(
              value: CustomTtsAuthMode.bearer,
              child: Text(s.voiceAuthBearer),
            ),
            DropdownMenuItem(
              value: CustomTtsAuthMode.apiKey,
              child: Text(s.voiceAuthApiKey),
            ),
            DropdownMenuItem(
              value: CustomTtsAuthMode.custom,
              child: Text(s.voiceAuthCustom),
            ),
          ],
          onChanged: (mode) {
            if (mode != null) _selectCustomAuth(mode);
          },
        ),
        if (authMode != CustomTtsAuthMode.none) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _field(
                  colors: colors,
                  label: s.voiceAuthHeader,
                  controller: _customHeaderCtrl,
                  hint: 'Authorization',
                  readOnly: authMode != CustomTtsAuthMode.custom,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _field(
                  colors: colors,
                  label: s.voiceAuthPrefix,
                  controller: _customPrefixCtrl,
                  hint: 'Bearer',
                  readOnly: authMode != CustomTtsAuthMode.custom,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _field(
            colors: colors,
            label: s.voiceAuthSecret,
            controller: _customSecretCtrl,
            obscure: _customSecretObscured,
            suffix: IconButton(
              icon: Icon(
                _customSecretObscured ? Icons.visibility_off : Icons.visibility,
              ),
              iconSize: 20,
              color: colors.textSecondary,
              onPressed: () => setState(
                () => _customSecretObscured = !_customSecretObscured,
              ),
            ),
          ),
        ],
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _field(
                colors: colors,
                label: s.voiceCustomVoice,
                controller: _customVoiceCtrl,
                hint: s.voiceOptional,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _field(
                colors: colors,
                label: s.voiceCustomModel,
                controller: _customModelCtrl,
                hint: s.voiceOptional,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(horizontal: 4),
            childrenPadding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
            iconColor: colors.accent,
            collapsedIconColor: colors.textSecondary,
            title: Text(
              s.voiceCustomAdvancedTitle,
              style: TextStyle(
                color: colors.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            subtitle: Text(
              s.voiceCustomAdvancedSub,
              style: TextStyle(color: colors.textSecondary, fontSize: 12),
            ),
            children: [
              _field(
                key: const ValueKey('custom_tts_body'),
                colors: colors,
                label: s.voiceCustomJsonTemplate,
                controller: _customBodyCtrl,
                hint: '{"text":"{{text}}"}',
                minLines: 4,
                maxLines: 8,
                keyboardType: TextInputType.multiline,
              ),
              const SizedBox(height: 6),
              Text(
                s.voiceCustomTemplateHelp,
                style: TextStyle(color: colors.textSecondary, fontSize: 11.5),
              ),
              const SizedBox(height: 12),
              Text(
                s.voiceResponseAutoSub,
                style: TextStyle(color: colors.textSecondary, fontSize: 11.5),
              ),
              const SizedBox(height: 10),
              _field(
                colors: colors,
                label: s.voiceBase64Path,
                controller: _customBase64PathCtrl,
                hint: 'data.audio',
              ),
              const SizedBox(height: 10),
              _field(
                colors: colors,
                label: s.voiceAudioMime,
                controller: _customMimeCtrl,
                hint: 'audio/mpeg',
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: HermesSecondaryButton(
            label: s.voiceSaveConfiguration,
            icon: Icons.save_outlined,
            onTap: _saveCustom,
          ),
        ),
      ],
    );
  }

  bool get _usesAdvancedTts => switch (_ttsChoice) {
    _TtsSetupChoice.kokoro ||
    _TtsSetupChoice.openAiCompatible ||
    _TtsSetupChoice.elevenLabs ||
    _TtsSetupChoice.customRest => true,
    _ => false,
  };

  String _advancedTtsChoiceName(Strings s) => switch (_ttsChoice) {
    _TtsSetupChoice.kokoro => s.voiceKokoroProfile,
    _TtsSetupChoice.openAiCompatible => s.voiceOpenAiProfile,
    _TtsSetupChoice.elevenLabs => 'ElevenLabs',
    _TtsSetupChoice.customRest => s.voiceCustomLabel,
    _ => '',
  };

  Widget _advancedTtsSection(HermesThemeColors colors, Strings s) => Column(
    key: const ValueKey('voice_tts_advanced'),
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        s.voiceOtherVoicesTitle,
        style: TextStyle(
          color: colors.textPrimary,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
      const SizedBox(height: 3),
      Text(
        _usesAdvancedTts
            ? s.voiceAdvancedActive(_advancedTtsChoiceName(s))
            : s.voiceOtherVoicesSub,
        style: TextStyle(color: colors.textSecondary, fontSize: 12),
      ),
      const SizedBox(height: 8),
      _Choice<_TtsSetupChoice>(
        colors: colors,
        value: _ttsChoice,
        options: [
          (
            _TtsSetupChoice.kokoro,
            s.voiceKokoroProfile,
            s.voiceKokoroProfileSub,
          ),
          (
            _TtsSetupChoice.openAiCompatible,
            s.voiceOpenAiProfile,
            s.voiceOpenAiProfileSub,
          ),
          (_TtsSetupChoice.elevenLabs, 'ElevenLabs', s.voiceElevenSub),
          (_TtsSetupChoice.customRest, s.voiceCustomLabel, s.voiceCustomSub),
        ],
        disabled: const {},
        onChanged: _selectTtsChoice,
      ),
      if (_s.ttsEngine == TtsEngineKind.elevenlabs) ...[
        _disclaimer(colors, s.voiceElevenDisclaimer),
        const SizedBox(height: 14),
        _field(
          colors: colors,
          label: s.voiceElevenKeyLabel,
          controller: _keyCtrl,
          obscure: _keyObscured,
          suffix: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: Icon(
                  _keyObscured ? Icons.visibility_off : Icons.visibility,
                ),
                iconSize: 20,
                color: colors.textSecondary,
                onPressed: () => setState(() => _keyObscured = !_keyObscured),
              ),
              IconButton(
                icon: const Icon(Icons.save_outlined),
                iconSize: 20,
                color: colors.accent,
                tooltip: s.voiceSaveKey,
                onPressed: _saveKey,
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _field(
          colors: colors,
          label: s.voiceElevenVoiceIdLabel,
          controller: _voiceIdCtrl,
          hint: '21m00Tcm4TlvDq8ikWAM',
          onSubmitted: (v) => _update(_s.copyWith(elevenVoiceId: v.trim())),
        ),
      ],
      if (_s.ttsEngine == TtsEngineKind.streaming)
        _streamingTtsSection(colors, s),
      if (_s.ttsEngine == TtsEngineKind.customHttp)
        _customTtsSection(colors, s),
    ],
  );

  Widget _settingsExpansion({
    required Key key,
    required HermesThemeColors colors,
    required IconData icon,
    required String title,
    required String subtitle,
    required List<Widget> children,
    bool initiallyExpanded = false,
  }) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Material(
      color: Colors.transparent,
      child: ExpansionTile(
        key: key,
        initiallyExpanded: initiallyExpanded,
        maintainState: true,
        shape: Border(
          top: BorderSide(color: colors.divider.withValues(alpha: 0.45)),
        ),
        collapsedShape: Border(
          top: BorderSide(color: colors.divider.withValues(alpha: 0.45)),
        ),
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 10),
        iconColor: colors.textSecondary,
        collapsedIconColor: colors.textSecondary,
        leading: Icon(icon, size: 20, color: colors.textSecondary),
        title: Text(
          title,
          style: TextStyle(
            color: colors.textPrimary,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: Text(
          subtitle,
          style: TextStyle(color: colors.textSecondary, fontSize: 12),
        ),
        children: children,
      ),
    ),
  );

  SherpaSttModel get _selectedSherpaModel {
    for (final model in kSherpaSttModels) {
      if (model.kind == _s.sherpaModel) return model;
    }
    return kSherpaSttModels.first;
  }

  NeuralVoice get _selectedOnnxVoice {
    for (final voice in kNeuralVoices) {
      if (voice.id == _s.onnxVoiceId) return voice;
    }
    return kNeuralVoices.first;
  }

  String _assetStatus(Strings s, String name, {required bool ready}) => ready
      ? s.voiceSelectedAssetReady(name)
      : s.voiceSelectedAssetDownloadNeeded(name);

  Widget _sherpaModelManager(HermesThemeColors colors, Strings s) {
    final model = _selectedSherpaModel;
    return _settingsExpansion(
      key: const ValueKey('voice_stt_models'),
      colors: colors,
      icon: Icons.download_for_offline_outlined,
      title: s.voiceManageLiveDictationModel,
      subtitle: _assetStatus(
        s,
        model.displayName,
        ready: _sherpaReady.contains(model.id),
      ),
      initiallyExpanded: _sherpaBusyId != null,
      children: [_sherpaModelSection(colors, s)],
    );
  }

  Widget _whisperModelManager(HermesThemeColors colors, Strings s) {
    final name = _s.whisperModel == SttModelSize.tiny
        ? 'Whisper tiny'
        : 'Whisper base';
    return _settingsExpansion(
      key: const ValueKey('voice_whisper_models'),
      colors: colors,
      icon: Icons.download_for_offline_outlined,
      title: s.voiceManageFinishedDictationModel,
      subtitle: _assetStatus(s, name, ready: _whisperReady),
      initiallyExpanded: _downloading,
      children: [_whisperModelTile(colors, s)],
    );
  }

  Widget _onnxVoiceManager(HermesThemeColors colors, Strings s) {
    final voice = _selectedOnnxVoice;
    return _settingsExpansion(
      key: const ValueKey('voice_onnx_models'),
      colors: colors,
      icon: Icons.record_voice_over_outlined,
      title: s.voiceManageOfflineVoices,
      subtitle: _assetStatus(
        s,
        voice.displayName,
        ready: _onnxReady.contains(voice.id),
      ),
      initiallyExpanded: _onnxBusyVoiceId != null,
      children: [
        const SizedBox(height: 4),
        for (final item in kNeuralVoices) _onnxVoiceTile(colors, item, s),
      ],
    );
  }

  String _liveSttEngineName(Strings s) => switch (_s.sttEngine) {
    SttEngineKind.hermesServer => s.voiceModeServerTitle,
    SttEngineKind.server => s.voiceServerLabel,
    SttEngineKind.system => s.voiceSystemLabel,
    _ => s.voiceSttOnDeviceLabel,
  };

  Widget _liveSttLocationContent(HermesThemeColors colors, Strings s) => Column(
    key: const ValueKey('voice_stt_location'),
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        s.voiceSttLocationTitle,
        style: TextStyle(
          color: colors.textPrimary,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
      const SizedBox(height: 6),
      _Choice<SttEngineKind>(
        colors: colors,
        value: _s.sttEngine,
        options: [
          (
            SttEngineKind.sherpaLive,
            s.voiceSttOnDeviceLabel,
            s.voiceSttOnDeviceSub,
          ),
          (
            SttEngineKind.hermesServer,
            s.voiceModeServerTitle,
            s.voiceHermesDictationSub,
          ),
          (SttEngineKind.server, s.voiceServerLabel, s.voiceServerSub),
          (SttEngineKind.system, s.voiceSystemLabel, s.voiceSystemSub),
        ],
        disabled: const {},
        onChanged: _selectLiveSttEngine,
      ),
      if (_s.sttEngine == SttEngineKind.server) _serverSttSection(colors, s),
    ],
  );

  Widget _fieldLabel(HermesThemeColors colors, String label) => Padding(
    padding: const EdgeInsets.only(left: 4, bottom: 6),
    child: Text(
      label,
      style: TextStyle(
        fontSize: 12.5,
        fontWeight: FontWeight.w500,
        color: colors.textSecondary,
      ),
    ),
  );

  InputDecoration _dropdownDecoration(HermesThemeColors colors) =>
      InputDecoration(
        isDense: true,
        filled: true,
        fillColor: colors.surfaceVariant.withValues(alpha: 0.3),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      );

  String _providerName(String? provider) => switch (provider) {
    'edge' => 'Edge',
    'elevenlabs' => 'ElevenLabs',
    'openai' => 'OpenAI',
    'gemini' => 'Gemini',
    'xai' => 'xAI',
    'minimax' => 'MiniMax',
    'mistral' => 'Mistral',
    'deepinfra' => 'DeepInfra',
    'neutts' => 'NeuTTS',
    'kittentts' => 'KittenTTS',
    'kokoro' => 'Kokoro',
    'piper' => 'Piper',
    'local' => 'Whisper',
    'local_command' => 'Local command',
    'groq' => 'Groq',
    final value? => value,
    null => '—',
  };

  String _edgeVoiceName(String? voice) {
    if (voice == null || voice.isEmpty) return '—';
    final parts = voice.split('-');
    if (parts.length < 3) return voice;
    final locale = '${parts[0]}-${parts[1]}';
    final name = parts
        .sublist(2)
        .join('-')
        .replaceFirst(RegExp(r'Neural$'), '');
    return '$name · $locale';
  }

  String _localTtsName(Strings s) => switch (_ttsChoice) {
    _TtsSetupChoice.device => s.voiceDeviceLabel,
    _TtsSetupChoice.onDeviceNeural =>
      '${s.voiceNeuralLabel} · ${_selectedOnnxVoice.displayName}',
    _ => _advancedTtsChoiceName(s),
  };

  bool get _usesHermesServer =>
      _nativeVoiceIdentity != null &&
      _nativeVoiceMode == NativeVoiceMode.server &&
      _nativeVoiceConsent == NativeVoiceConsent.accepted;

  (String, Color) _conversationStatus(HermesThemeColors colors, Strings s) {
    if (_nativeVoiceLoading || _serverVoiceConfigLoading) {
      return (s.voiceStatusChecking, colors.textSecondary);
    }
    final serverError = _serverVoiceConfigError;
    if (serverError != null &&
        classifyDashboardDependencyFailure(serverError) ==
            DashboardDependencyFailure.credentials) {
      return (localizedApiError(s, serverError), colors.warning);
    }
    if (_nativeVoiceCapability?.ok != true) {
      return (s.voiceStatusUsingFallback, colors.warning);
    }
    if (_serverVoiceConfigFailed || _serverTtsProvider == null) {
      return (s.voiceStatusServerReadyConfigUnknown, colors.warning);
    }
    return (s.voiceStatusServerReady, colors.success);
  }

  String _serverSttDescription() {
    final summary = _serverVoiceSummary;
    if (summary == null) return '—';
    return [
      summary.sttProvider == null ? null : _providerName(summary.sttProvider),
      summary.sttModel,
      summary.sttLanguage,
    ].whereType<String>().where((value) => value.isNotEmpty).join(' · ');
  }

  String? _serverSttLanguageWarning(Strings s) {
    final serverLanguage = _serverVoiceSummary?.sttLanguage;
    final appLanguage = Localizations.localeOf(context).languageCode;
    if (!hermesServerSttLanguageMismatch(
      serverLanguage: serverLanguage,
      appLanguage: appLanguage,
    )) {
      return null;
    }
    String languageName(String value) => switch (value.toLowerCase()) {
      'es' => s.languageSpanish,
      'en' => s.languageEnglish,
      final value => value.toUpperCase(),
    };
    return s.voiceServerLanguageMismatch(
      languageName(serverLanguage!),
      languageName(appLanguage),
    );
  }

  String _serverTtsDescription() {
    final summary = _serverVoiceSummary;
    if (summary == null) return '—';
    final voice = summary.ttsProvider == 'edge'
        ? _edgeVoiceName(summary.ttsVoice)
        : summary.ttsVoice;
    return [
      _providerName(summary.ttsProvider),
      summary.ttsModel,
      voice,
    ].whereType<String>().where((value) => value.isNotEmpty).join(' · ');
  }

  String _serverDeliveryDescription(Strings s) =>
      switch (_serverVoiceSummary?.delivery) {
        HermesServerSpeechDelivery.pcmStreaming => s.voiceServerDeliveryPcm,
        HermesServerSpeechDelivery.phraseFallback =>
          s.voiceServerDeliveryPhrases,
        _ => s.voiceServerDeliveryCheck,
      };

  Future<void> _checkServerVoice() async {
    final dashboard = _nativeVoiceDashboard;
    final identity = _nativeVoiceIdentity;
    final app = context.findAncestorStateOfType<HermesAppState>();
    final preferences = widget.preferences ?? app?.connManager.prefs;
    if (dashboard == null || identity == null || preferences == null) return;
    setState(() => _nativeVoiceLoading = true);
    final capability = await probeNativeVoiceCapability(
      statusOf: (name) =>
          dashboard.probeAudioEndpoint(name, profile: _effectiveProfile),
    );
    await NativeVoiceCapabilityStore(preferences).write(identity, capability);
    if (!mounted) return;
    setState(() {
      _nativeVoiceCapability = capability;
      _nativeVoiceLoading = false;
    });
    if (capability.ok) {
      await _loadServerVoiceConfig(dashboard, _nativeVoiceLoadEpoch);
    }
  }

  void _showServerUpdateHelp() =>
      _snack(Strings.of(context).voiceServerUpdateHelp);

  Future<void> _openDashboardAuthentication() async {
    final app = context.findAncestorStateOfType<HermesAppState>();
    final connection = _nativeVoiceConnection;
    if (app == null || connection == null) {
      final error = _serverVoiceConfigError;
      _snack(
        error == null
            ? Strings.of(context).voiceErrorDashboardLogin
            : localizedApiError(Strings.of(context), error),
      );
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => InstanceEditScreen(
          connManager: app.connManager,
          initial: connection,
        ),
      ),
    );
    if (!mounted) return;

    ++_nativeVoiceLoadEpoch;
    final dashboard = _nativeVoiceDashboard;
    _nativeVoiceDashboard = null;
    if (_ownsNativeVoiceDashboard) dashboard?.close();
    _ownsNativeVoiceDashboard = false;
    setState(() {
      _nativeVoiceCapability = null;
      _serverVoiceConfig = null;
      _serverVoiceSummary = null;
      _serverTtsProvider = null;
      _serverVoiceConfigFailed = false;
      _serverVoiceConfigError = null;
    });
    await _loadNativeVoiceChoice();
  }

  String _dictationSelection(Strings s) => switch (_s.sttEngine) {
    SttEngineKind.hermesServer => s.voiceModeServerTitle,
    SttEngineKind.whisper => s.voiceCurrentFinishedDictation(
      _s.whisperModel == SttModelSize.tiny ? 'Whisper tiny' : 'Whisper base',
    ),
    _ => s.voiceCurrentLiveDictation(_liveSttEngineName(s)),
  };

  (String, Color) _dictationStatus(HermesThemeColors colors, Strings s) {
    if (_s.sttEngine == SttEngineKind.hermesServer) {
      if (_nativeVoiceLoading) {
        return (s.voiceStatusChecking, colors.textSecondary);
      }
      final languageWarning = _serverSttLanguageWarning(s);
      if (languageWarning != null) {
        return (languageWarning, colors.warning);
      }
      return _nativeVoiceCapability?.transcribe == true
          ? (s.voiceStatusServerReady, colors.success)
          : (s.voiceStatusServerNoResponse, colors.error);
    }
    if (_s.sttEngine == SttEngineKind.whisper) {
      return _whisperReady
          ? (s.voiceStatusReady, colors.success)
          : (s.voiceStatusDownloadNeeded, colors.warning);
    }
    if (_s.sttEngine == SttEngineKind.sherpaLive) {
      return _sherpaReady.contains(_selectedSherpaModel.id)
          ? (s.voiceStatusReady, colors.success)
          : (s.voiceStatusDownloadNeeded, colors.warning);
    }
    if (_s.sttEngine == SttEngineKind.system) {
      return (s.voiceStatusDependsOnAndroid, colors.textSecondary);
    }
    if (_s.serverSttUrl.trim().isEmpty) {
      return (s.voiceStatusConfigurationNeeded, colors.warning);
    }
    if (_serverTestOk == true) {
      return (s.voiceStatusServerVerified, colors.success);
    }
    if (_serverTestOk == false) {
      return (s.voiceStatusServerNoResponse, colors.error);
    }
    return (s.voiceStatusServerNotTested, colors.textSecondary);
  }

  String _readingSelection(Strings s) => _localTtsName(s);

  (String, Color) _readingStatus(HermesThemeColors colors, Strings s) {
    if (_s.ttsEngine == TtsEngineKind.onnx) {
      return _onnxReady.contains(_selectedOnnxVoice.id)
          ? (s.voiceStatusReady, colors.success)
          : (s.voiceStatusDownloadNeeded, colors.warning);
    }
    if (_s.ttsEngine == TtsEngineKind.device) {
      return (s.voiceStatusDependsOnAndroid, colors.textSecondary);
    }
    final configured = switch (_s.ttsEngine) {
      TtsEngineKind.streaming => _s.streamingTtsUrl.trim().isNotEmpty,
      TtsEngineKind.elevenlabs => _s.elevenVoiceId.trim().isNotEmpty,
      TtsEngineKind.customHttp => _s.customTtsUrl.trim().isNotEmpty,
      _ => true,
    };
    return configured
        ? (s.voiceStatusExternalConfigured, colors.success)
        : (s.voiceStatusConfigurationNeeded, colors.warning);
  }

  Future<void> _openServerVoiceManager() async {
    final dashboard = _nativeVoiceDashboard;
    if (dashboard == null) return;
    await showHermesFloatingSurface<void>(
      context: context,
      surfaceKey: const ValueKey('server-voice-control-surface'),
      maxWidth: 620,
      maxHeightFactor: 0.9,
      builder: (_) => ServerVoiceControlSurface(
        dashboard: dashboard,
        readOnly: _nativeVoiceConnection?.readOnly == true,
        profile: _effectiveProfile,
        onServerChanged: () =>
            unawaited(_loadServerVoiceConfig(dashboard, _nativeVoiceLoadEpoch)),
      ),
    );
  }

  Future<void> _testServerVoice() async {
    final dashboard = _nativeVoiceDashboard;
    final voice = _voice;
    if (dashboard == null || voice == null || _serverVoiceTesting) return;
    final s = Strings.of(context);
    final previewEpoch = ++_previewEpoch;
    TtsEngine? previewEngine;
    setState(() => _serverVoiceTesting = true);
    try {
      Future<Map<String, dynamic>> synthesize(String text) =>
          dashboard.synthesizeSpeech(text, profile: _effectiveProfile);
      previewEngine =
          widget.serverPreviewEngineFactory?.call(synthesize) ??
          HermesServerTtsEngine(synthesize: synthesize);
      if (!await _claimPreviewEngine(previewEngine, previewEpoch)) return;
      await voice.previewTts(previewEngine, s.voiceSampleText);
      if (mounted && previewEpoch == _previewEpoch) {
        _snack(s.voiceTestPlayed);
      }
    } catch (error) {
      if (mounted && previewEpoch == _previewEpoch) {
        _snack(s.voiceNoPreview(localizedVoiceError(s, error)));
      }
    } finally {
      await _releasePreviewEngine(previewEngine);
      if (mounted && previewEpoch == _previewEpoch) {
        setState(() => _serverVoiceTesting = false);
      }
    }
  }

  Future<void> _stopServerVoiceTest() async {
    ++_previewEpoch;
    final previewEngine = _previewEngine;
    _previewEngine = null;
    await _disposePreviewEngine(previewEngine);
    if (mounted) setState(() => _serverVoiceTesting = false);
  }

  Widget _serverVoiceCard(HermesThemeColors colors, Strings s) {
    final readOnly = _nativeVoiceConnection?.readOnly == true;
    final status = _conversationStatus(colors, s);
    final unavailable = _nativeVoiceCapability?.ok != true;
    final conclusiveUnavailable =
        unavailable && _nativeVoiceCapability?.conclusive == true;
    final serverError = _serverVoiceConfigError;
    final authRequired =
        serverError != null &&
        classifyDashboardDependencyFailure(serverError) ==
            DashboardDependencyFailure.credentials;
    final loading = _nativeVoiceLoading || _serverVoiceConfigLoading;
    final hasDetails =
        !loading && serverError == null && !_serverVoiceConfigFailed;
    return HermesCard(
      key: const ValueKey('voice_server_summary_card'),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: colors.accent.withValues(alpha: 0.09),
                  borderRadius: BorderRadius.circular(HermesRadii.field),
                ),
                child: Icon(
                  Icons.dns_rounded,
                  size: 19,
                  color: colors.accentHover,
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s.voiceServerCardTitle,
                      style: TextStyle(
                        color: colors.textPrimary,
                        fontWeight: FontWeight.w700,
                        fontSize: 14.5,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _effectiveProfile != null
                          ? s.voiceServerCardProfileSub(_effectiveProfile!)
                          : s.voiceServerCardSub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.textSecondary,
                        fontSize: 11.5,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (loading)
            Row(
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    s.voiceServerConfigLoading,
                    style: TextStyle(color: colors.textSecondary, fontSize: 12),
                  ),
                ),
              ],
            )
          else
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: status.$2.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(HermesRadii.chip),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 5),
                    child: Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: status.$2,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      status.$1,
                      style: TextStyle(
                        color: colors.textSecondary,
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 12),
          if (authRequired)
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                key: const ValueKey('voice_server_auth_action'),
                onPressed: _openDashboardAuthentication,
                icon: const Icon(Icons.lock_open_rounded),
                label: Text(s.voiceServerAuthAction),
              ),
            )
          else if (conclusiveUnavailable)
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                key: const ValueKey('voice_server_update_action'),
                onPressed: _showServerUpdateHelp,
                icon: const Icon(Icons.system_update_alt_rounded),
                label: Text(s.voiceServerUpdateAction),
              ),
            )
          else if (unavailable || _serverVoiceConfigFailed)
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                key: const ValueKey('voice_server_check_action'),
                onPressed: _nativeVoiceLoading ? null : _checkServerVoice,
                icon: const Icon(Icons.refresh_rounded),
                label: Text(s.voiceServerCheckAction),
              ),
            )
          else
            LayoutBuilder(
              builder: (context, constraints) {
                final stack =
                    constraints.maxWidth < 360 ||
                    MediaQuery.textScalerOf(context).scale(12) >= 18;
                final configure = OutlinedButton.icon(
                  key: const ValueKey('voice_manage_server_voice'),
                  onPressed: _openServerVoiceManager,
                  icon: const Icon(Icons.tune_rounded),
                  label: Text(s.voiceServerManageAction),
                );
                final test = FilledButton.icon(
                  key: const ValueKey('voice_test_server_voice'),
                  onPressed: _serverVoiceTesting
                      ? _stopServerVoiceTest
                      : _testServerVoice,
                  icon: _serverVoiceTesting
                      ? const Icon(Icons.stop_rounded)
                      : const Icon(Icons.play_arrow_rounded),
                  label: Text(
                    _serverVoiceTesting
                        ? s.voiceServerStopTestAction
                        : s.voiceServerTestAction,
                  ),
                );
                if (stack) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [configure, const SizedBox(height: 8), test],
                  );
                }
                return Row(
                  children: [
                    Expanded(child: configure),
                    const SizedBox(width: 8),
                    Expanded(child: test),
                  ],
                );
              },
            ),
          if (hasDetails) ...[
            const SizedBox(height: 4),
            TextButton.icon(
              key: const ValueKey('voice_server_details_toggle'),
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 48),
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              onPressed: () => setState(
                () =>
                    _serverVoiceDetailsExpanded = !_serverVoiceDetailsExpanded,
              ),
              icon: Icon(
                _serverVoiceDetailsExpanded
                    ? Icons.expand_less_rounded
                    : Icons.expand_more_rounded,
              ),
              label: Text(
                _serverVoiceDetailsExpanded
                    ? s.voiceServerHideDetailsAction
                    : s.voiceServerDetailsAction,
              ),
            ),
            if (_serverVoiceDetailsExpanded) ...[
              Divider(
                color: colors.divider.withValues(alpha: 0.55),
                height: 14,
              ),
              _serverValueRow(
                colors,
                s.voiceServerSttLabel,
                _serverSttDescription(),
              ),
              const SizedBox(height: 10),
              _serverValueRow(
                colors,
                s.voiceServerTtsLabel,
                _serverTtsDescription(),
              ),
              const SizedBox(height: 10),
              _serverValueRow(
                colors,
                s.voiceServerDeliveryLabel,
                _serverDeliveryDescription(s),
              ),
            ],
          ],
          if (readOnly) ...[
            const SizedBox(height: 6),
            Text(
              s.voiceServerReadOnly,
              style: TextStyle(color: colors.textSecondary, fontSize: 11.5),
            ),
          ],
        ],
      ),
    );
  }

  Widget _serverValueRow(
    HermesThemeColors colors,
    String label,
    String value,
  ) => LayoutBuilder(
    builder: (context, constraints) {
      final stacked =
          constraints.maxWidth < 330 ||
          MediaQuery.textScalerOf(context).scale(12) >= 19;
      final labelWidget = Text(
        label,
        style: TextStyle(color: colors.textSecondary, fontSize: 12),
      );
      final valueWidget = Text(
        value,
        style: TextStyle(
          color: colors.textPrimary,
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          height: 1.35,
        ),
      );
      if (stacked) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [labelWidget, const SizedBox(height: 3), valueWidget],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 112, child: labelWidget),
          Expanded(child: valueWidget),
        ],
      );
    },
  );

  Widget _voiceModeHeader(HermesThemeColors colors, Strings s) {
    final hasConnection = _nativeVoiceConnection != null;
    final serverDisabled = _nativeVoiceLoading || _nativeVoiceDashboard == null;
    return Column(
      key: const ValueKey('voice_conversation_section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          s.voiceModeTitle,
          style: TextStyle(
            color: colors.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 10),
        _appliedVoiceRoutes(colors, s, serverDisabled: serverDisabled),
        if (!hasConnection)
          Text(
            s.voiceServerNoConnection,
            style: TextStyle(
              color: colors.textSecondary,
              fontSize: 12,
              height: 1.4,
            ),
          ),
        if (hasConnection && _nativeVoiceDashboard == null)
          Text(
            s.voiceServerConfigUnavailable,
            style: TextStyle(
              color: colors.textSecondary,
              fontSize: 12,
              height: 1.4,
            ),
          ),
        HermesSwitchTile(
          controlKey: const ValueKey('voice_continue_when_locked'),
          contentPadding: EdgeInsets.zero,
          title: s.voiceContinueLockedSettingTitle,
          subtitle: s.voiceContinueLockedSettingSub,
          value: _voice?.continueVoiceWhenLocked ?? false,
          onChanged: _voice == null ? null : _setContinueWhenLocked,
        ),
        HermesSwitchTile(
          controlKey: const ValueKey('voice_barge_in_enabled'),
          contentPadding: EdgeInsets.zero,
          title: s.voiceBargeInTitle,
          subtitle: s.voiceBargeInSub,
          value: _s.bargeInEnabled,
          onChanged: _voice == null
              ? null
              : (value) => _update(_s.copyWith(bargeInEnabled: value)),
        ),
      ],
    );
  }

  Widget _appliedVoiceRoutes(
    HermesThemeColors colors,
    Strings s, {
    required bool serverDisabled,
  }) => Container(
    key: const ValueKey('voice_applied_routes'),
    width: double.infinity,
    padding: const EdgeInsets.fromLTRB(12, 10, 12, 11),
    decoration: BoxDecoration(
      color: colors.accent.withValues(alpha: 0.055),
      borderRadius: BorderRadius.circular(HermesRadii.field),
      border: Border.all(color: colors.accent.withValues(alpha: 0.18)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.check_circle_rounded, size: 16, color: colors.accent),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                s.voiceAppliedNow,
                style: TextStyle(
                  color: colors.accentHover,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _appliedRouteSelector(
          colors,
          label: s.voiceAppliedVoiceMode,
          currentValue: _usesHermesServer
              ? s.voiceModeServerTitle
              : s.voiceModePhoneTitle,
          valueKey: const ValueKey('voice_applied_mode_value'),
          first: _voiceModeOption(
            key: const ValueKey('voice_mode_phone_option'),
            colors: colors,
            icon: Icons.smartphone_rounded,
            label: s.voiceModePhoneTitle,
            selected: !_usesHermesServer,
            enabled: !_nativeVoiceLoading,
            onTap: () => _selectNativeVoice(false),
          ),
          second: _voiceModeOption(
            key: const ValueKey('voice_mode_server_option'),
            colors: colors,
            icon: Icons.dns_rounded,
            label: s.voiceModeServerTitle,
            selected: _usesHermesServer,
            enabled: !serverDisabled,
            onTap: () => _selectNativeVoice(true),
          ),
        ),
        const SizedBox(height: 12),
        _appliedRouteSelector(
          colors,
          label: s.voiceAppliedChatDictation,
          currentValue: _appliedDictationValue(s),
          valueKey: const ValueKey('voice_applied_dictation_value'),
          first: _voiceModeOption(
            key: const ValueKey('voice_dictation_phone_option'),
            colors: colors,
            icon: Icons.phone_android_rounded,
            label: s.voiceParakeetLocalTitle,
            selected:
                _s.sttEngine == SttEngineKind.sherpaLive &&
                _s.sherpaModel == SherpaModelKind.parakeetV3,
            enabled: true,
            onTap: () => _selectHermesDictation(false),
          ),
          second: _voiceModeOption(
            key: const ValueKey('voice_dictation_server_option'),
            colors: colors,
            icon: Icons.cloud_outlined,
            label: s.voiceModeServerTitle,
            selected: _s.sttEngine == SttEngineKind.hermesServer,
            enabled:
                !serverDisabled && _nativeVoiceCapability?.transcribe == true,
            onTap: () => _selectHermesDictation(true),
          ),
        ),
        if ((_usesHermesServer || _s.sttEngine == SttEngineKind.hermesServer) &&
            _serverSttLanguageWarning(s) != null) ...[
          const SizedBox(height: 10),
          Container(
            key: const ValueKey('voice_server_language_mismatch'),
            padding: const EdgeInsets.fromLTRB(10, 7, 6, 7),
            decoration: BoxDecoration(
              color: colors.warning.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(HermesRadii.field),
              border: Border.all(color: colors.warning.withValues(alpha: 0.28)),
            ),
            child: Row(
              children: [
                Icon(Icons.translate_rounded, size: 17, color: colors.warning),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _serverSttLanguageWarning(s)!,
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontSize: 11.5,
                      height: 1.3,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                TextButton(
                  key: const ValueKey('voice_fix_server_language'),
                  onPressed: _nativeVoiceDashboard == null
                      ? null
                      : _openServerVoiceManager,
                  child: Text(s.voiceServerManageAction),
                ),
              ],
            ),
          ),
        ],
      ],
    ),
  );

  Widget _appliedRouteSelector(
    HermesThemeColors colors, {
    required String label,
    required String currentValue,
    required Key valueKey,
    required Widget first,
    required Widget second,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      LayoutBuilder(
        builder: (context, constraints) {
          final labelText = Text(
            label,
            style: TextStyle(
              color: colors.textSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          );
          final valueText = Text(
            currentValue,
            key: valueKey,
            textAlign: constraints.maxWidth < 420
                ? TextAlign.start
                : TextAlign.end,
            style: TextStyle(
              color: colors.textPrimary,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          );
          if (constraints.maxWidth < 420 ||
              MediaQuery.textScalerOf(context).scale(12) >= 17) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [labelText, const SizedBox(height: 3), valueText],
            );
          }
          return Row(
            children: [
              Expanded(child: labelText),
              const SizedBox(width: 12),
              Flexible(child: valueText),
            ],
          );
        },
      ),
      const SizedBox(height: 6),
      Material(
        color: colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: colors.divider.withValues(alpha: 0.65)),
        ),
        clipBehavior: Clip.antiAlias,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final stacked =
                constraints.maxWidth < 300 ||
                MediaQuery.textScalerOf(context).scale(12) >= 19;
            if (stacked) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  first,
                  Container(height: 1, color: colors.divider),
                  second,
                ],
              );
            }
            return Row(
              children: [
                Expanded(child: first),
                Container(width: 1, height: 32, color: colors.divider),
                Expanded(child: second),
              ],
            );
          },
        ),
      ),
    ],
  );

  String _appliedDictationValue(Strings s) => switch (_s.sttEngine) {
    SttEngineKind.sherpaLive => s.voiceAppliedOnDevice(
      _selectedSherpaModel.displayName,
    ),
    SttEngineKind.whisper => s.voiceAppliedOnDevice(
      _s.whisperModel == SttModelSize.tiny ? 'Whisper tiny' : 'Whisper base',
    ),
    SttEngineKind.system => s.voiceAppliedOnDevice(s.voiceSystemLabel),
    SttEngineKind.hermesServer => s.voiceModeServerTitle,
    SttEngineKind.server => s.voiceServerLabel,
  };

  Widget _voiceModeOption({
    required Key key,
    required HermesThemeColors colors,
    required IconData icon,
    required String label,
    required bool selected,
    required bool enabled,
    required VoidCallback onTap,
  }) => Semantics(
    button: true,
    selected: selected,
    enabled: enabled,
    child: InkWell(
      key: key,
      onTap: enabled ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        constraints: const BoxConstraints(minHeight: 52),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: selected ? colors.accent : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 19,
              color: enabled
                  ? selected
                        ? colors.accent
                        : colors.textSecondary
                  : colors.textDisabled,
            ),
            const SizedBox(width: 7),
            Flexible(
              child: Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: enabled ? colors.textPrimary : colors.textDisabled,
                  fontSize: 12.5,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _voiceSection({
    required Key key,
    required HermesThemeColors colors,
    required IconData icon,
    required String title,
    required String selection,
    required String status,
    required Color statusColor,
    required List<Widget> children,
    bool initiallyExpanded = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Material(
      color: Colors.transparent,
      child: ExpansionTile(
        key: key,
        initiallyExpanded: initiallyExpanded,
        maintainState: true,
        tilePadding: const EdgeInsets.fromLTRB(2, 8, 2, 8),
        childrenPadding: const EdgeInsets.fromLTRB(2, 0, 2, 14),
        shape: Border(
          bottom: BorderSide(color: colors.divider.withValues(alpha: 0.55)),
        ),
        collapsedShape: Border(
          bottom: BorderSide(color: colors.divider.withValues(alpha: 0.55)),
        ),
        iconColor: colors.textSecondary,
        collapsedIconColor: colors.textSecondary,
        leading: Icon(icon, size: 20, color: colors.textSecondary),
        title: Text(
          title,
          style: TextStyle(
            color: colors.textPrimary,
            fontSize: 14.5,
            fontWeight: FontWeight.w700,
          ),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 5),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                selection,
                style: TextStyle(
                  color: colors.textPrimary,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  height: 1.3,
                ),
              ),
              const SizedBox(height: 4),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 5),
                    child: Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: statusColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      status,
                      style: TextStyle(
                        color: colors.textSecondary,
                        fontSize: 11.5,
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        children: children,
      ),
    ),
  );

  Widget _sttAdvancedSection(HermesThemeColors colors, Strings s) =>
      _settingsExpansion(
        key: const ValueKey('voice_stt_advanced'),
        colors: colors,
        icon: Icons.tune_outlined,
        title: s.voiceAdvancedSettingsTitle,
        subtitle: _sttSetupMode == _SttSetupMode.live
            ? s.voiceAdvancedActive(_liveSttEngineName(s))
            : s.voiceAdvancedActive(
                _s.whisperModel == SttModelSize.tiny
                    ? 'Whisper tiny'
                    : 'Whisper base',
              ),
        initiallyExpanded:
            _serverTesting || _downloading || _sherpaBusyId != null,
        children: [
          if (_sttSetupMode == _SttSetupMode.live) ...[
            _liveSttLocationContent(colors, s),
            if (_s.sttEngine == SttEngineKind.sherpaLive)
              _sherpaModelManager(colors, s),
          ] else ...[
            _whisperModelManager(colors, s),
            if (kVoiceModeEnabled)
              HermesSwitchTile(
                contentPadding: EdgeInsets.zero,
                title: s.voiceVadTitle,
                subtitle: s.voiceVadSub,
                value: _s.vadEnabled,
                onChanged: (value) => _update(_s.copyWith(vadEnabled: value)),
              ),
          ],
        ],
      );

  Widget _readingAdvancedSection(HermesThemeColors colors, Strings s) =>
      _settingsExpansion(
        key: const ValueKey('voice_reading_advanced'),
        colors: colors,
        icon: Icons.tune_outlined,
        title: s.voiceReadingAdvancedTitle,
        subtitle: _usesAdvancedTts
            ? s.voiceAdvancedActive(_advancedTtsChoiceName(s))
            : s.voiceReadingAdvancedSub,
        initiallyExpanded: _usesAdvancedTts,
        children: [
          Text(
            s.voiceReadBehaviorTitle,
            key: const ValueKey('voice_read_aloud_behavior_title'),
            style: TextStyle(
              color: colors.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          _Choice<ReadAloudStopBehavior>(
            colors: colors,
            value: _s.readAloudStopBehavior,
            options: [
              (
                ReadAloudStopBehavior.pauseAndResume,
                s.voicePauseAndResumeTitle,
                s.voicePauseAndResumeSub,
              ),
              (
                ReadAloudStopBehavior.stopAndRestart,
                s.voiceStopAndRestartTitle,
                s.voiceStopAndRestartSub,
              ),
            ],
            disabled: const {},
            onChanged: (value) =>
                _update(_s.copyWith(readAloudStopBehavior: value)),
          ),
          Divider(color: colors.divider.withValues(alpha: 0.5), height: 28),
          _advancedTtsSection(colors, s),
        ],
      );

  // Voz es alcanzable sin instancia activa (configuración local del
  // dispositivo), así que el dock solo se añade cuando hay conexión y
  // ConnectionManager disponibles — igual que el resto de pantallas que lo
  // usan, sin forzar una dependencia que esta pantalla no siempre tiene.
  Widget _wrapWithDock(BuildContext context, Widget body) {
    final conn = widget.connection;
    final connManager = context
        .findAncestorStateOfType<HermesAppState>()
        ?.connManager;
    if (conn == null || connManager == null) return body;
    return GeneralDockShell(
      connection: conn,
      connManager: connManager,
      body: body,
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final dictationStatus = _dictationStatus(colors, s);
    final readingStatus = _readingStatus(colors, s);
    return Scaffold(
      backgroundColor: colors.background,
      appBar: HermesAppBar(
        // Sin estilo local: hereda el titleTextStyle del tema, como Ajustes y
        // Notificaciones (spec 028 A-203).
        title: Text(s.voiceTitle),
      ),
      body: _wrapWithDock(
        context,
        LayoutBuilder(
          builder: (context, constraints) => ListView(
            controller: _scrollController,
            padding: EdgeInsets.zero,
            children: [
              Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (kVoiceModeEnabled) ...[
                          _voiceModeHeader(colors, s),
                          const SizedBox(height: 12),
                        ],
                        if (_usesHermesServer) ...[
                          _serverVoiceCard(colors, s),
                          const SizedBox(height: 12),
                        ],
                        ...[
                          _voiceSection(
                            key: const ValueKey('voice_listening_section'),
                            colors: colors,
                            icon: Icons.mic_none_rounded,
                            title: s.voiceListeningSectionTitle,
                            selection: _dictationSelection(s),
                            status: dictationStatus.$1,
                            statusColor: dictationStatus.$2,
                            children: [
                              Text(
                                s.voiceListeningSectionSub,
                                style: TextStyle(
                                  color: colors.textSecondary,
                                  fontSize: 12.5,
                                  height: 1.4,
                                ),
                              ),
                              const SizedBox(height: 8),
                              _Choice<_SttSetupMode>(
                                colors: colors,
                                value: _sttSetupMode,
                                options: [
                                  (
                                    _SttSetupMode.live,
                                    s.voiceSherpaLiveLabel,
                                    s.voiceLiveModeSub,
                                  ),
                                  (
                                    _SttSetupMode.afterSpeaking,
                                    s.voiceWhisperLabel,
                                    s.voiceWhisperSub,
                                  ),
                                ],
                                disabled: const {},
                                onChanged: _selectSttSetupMode,
                              ),
                              _sttAdvancedSection(colors, s),
                            ],
                          ),
                          _voiceSection(
                            key: const ValueKey('voice_reading_section'),
                            colors: colors,
                            icon: Icons.volume_up_outlined,
                            title: s.voiceReadingSectionTitle,
                            selection: _readingSelection(s),
                            status: readingStatus.$1,
                            statusColor: readingStatus.$2,
                            children: [
                              Text(
                                s.voiceReadingSectionSub,
                                style: TextStyle(
                                  color: colors.textSecondary,
                                  fontSize: 12.5,
                                  height: 1.4,
                                ),
                              ),
                              const SizedBox(height: 8),
                              _Choice<_TtsSetupChoice>(
                                colors: colors,
                                value: _ttsChoice,
                                options: [
                                  (
                                    _TtsSetupChoice.device,
                                    s.voiceDeviceLabel,
                                    s.voiceDeviceSub,
                                  ),
                                  (
                                    _TtsSetupChoice.onDeviceNeural,
                                    s.voiceNeuralLabel,
                                    s.voiceNeuralSub,
                                  ),
                                ],
                                disabled: const {},
                                onChanged: _selectTtsChoice,
                              ),
                              if (_s.ttsEngine == TtsEngineKind.onnx) ...[
                                _disclaimer(colors, s.voiceNeuralDisclaimer),
                                _onnxVoiceManager(colors, s),
                              ],
                              const SizedBox(height: 12),
                              SizedBox(
                                width: double.infinity,
                                child: OutlinedButton.icon(
                                  key: const ValueKey(
                                    'voice_setup_test_action',
                                  ),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: colors.textPrimary,
                                    minimumSize: const Size.fromHeight(48),
                                    side: BorderSide(
                                      color: colors.divider.withValues(
                                        alpha: 0.7,
                                      ),
                                    ),
                                  ),
                                  onPressed: _testingVoice ? null : _testVoice,
                                  icon: _testingVoice
                                      ? const SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : const Icon(Icons.volume_up_outlined),
                                  label: Text(
                                    _testingVoice
                                        ? s.voiceTestPreparing
                                        : s.voiceTestButton,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 6),
                              HermesSwitchTile(
                                contentPadding: EdgeInsets.zero,
                                title: s.voiceAutoSpeakTitle,
                                subtitle: s.voiceAutoSpeakSub,
                                value: _s.autoSpeak,
                                onChanged: (value) =>
                                    _update(_s.copyWith(autoSpeak: value)),
                              ),
                              _readingAdvancedSection(colors, s),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Campo de texto limpio: etiqueta breve ARRIBA (mono, tenue) + campo relleno
  /// y redondeado, sin el outline ni el label flotante feos. Misma estética que
  /// el resto del rediseño. No cambia ninguna lógica: mismos controllers/callbacks.
  Widget _field({
    Key? key,
    required HermesThemeColors colors,
    required String label,
    required TextEditingController controller,
    String? hint,
    bool obscure = false,
    bool readOnly = false,
    int minLines = 1,
    int maxLines = 1,
    TextInputType? keyboardType,
    Widget? suffix,
    void Function(String)? onSubmitted,
    void Function(String)? onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 6),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w500,
              color: colors.textSecondary,
            ),
          ),
        ),
        TextField(
          key: key,
          controller: controller,
          obscureText: obscure,
          readOnly: readOnly,
          minLines: obscure ? 1 : minLines,
          maxLines: obscure ? 1 : maxLines,
          keyboardType: keyboardType,
          onSubmitted: onSubmitted,
          onChanged: onChanged,
          style: TextStyle(color: colors.textPrimary, fontSize: 14),
          decoration: InputDecoration(
            isDense: true,
            hintText: hint,
            hintStyle: TextStyle(color: colors.textDisabled, fontSize: 13.5),
            filled: true,
            fillColor: colors.surfaceVariant.withValues(alpha: 0.3),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 13,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(
                color: colors.accent.withValues(alpha: 0.6),
                width: 1.2,
              ),
            ),
            suffixIcon: suffix,
          ),
        ),
      ],
    );
  }

  Widget _disclaimer(HermesThemeColors colors, String text) => Padding(
    padding: const EdgeInsets.only(top: 10, left: 4, right: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.privacy_tip_outlined, size: 14, color: colors.textDisabled),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 11.5,
              height: 1.4,
              color: colors.textSecondary,
            ),
          ),
        ),
      ],
    ),
  );

  /// Los campos `quality` de los catálogos son claves estables ('ligera',
  /// 'media', 'alta'), no texto de UI: aquí se traducen al idioma activo
  /// (spec 031 — antes se interpolaban crudos y salían en español en UI
  /// inglesa).
  String _voiceQualityLabel(Strings s, String quality) => switch (quality) {
    'ligera' => s.voiceQualityLight,
    'alta' => s.voiceQualityHigh,
    _ => s.voiceQualityMedium,
  };

  /// Descripción localizada de cada modelo de dictado (spec 031 — antes se
  /// mostraba `m.quality` crudo en español).
  String _sttModelSub(Strings s, SherpaModelKind kind) => switch (kind) {
    SherpaModelKind.whisperBase => s.sttModelWhisperBaseSub,
    SherpaModelKind.whisperSmall => s.sttModelWhisperSmallSub,
    SherpaModelKind.parakeetV3 => s.sttModelParakeetSub,
  };

  Widget _onnxVoiceTile(
    HermesThemeColors colors,
    NeuralVoice voice,
    Strings s,
  ) {
    final selected = _s.onnxVoiceId == voice.id;
    final ready = _onnxReady.contains(voice.id);
    final busy = _onnxBusyVoiceId == voice.id;
    final deleting = _onnxDeletingVoiceId == voice.id;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? colors.accent : colors.divider,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: ready && !_testingVoice && _onnxDeletingVoiceId == null
                  ? () => _update(_s.copyWith(onnxVoiceId: voice.id))
                  : null,
              child: Row(
                children: [
                  Icon(
                    selected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 18,
                    color: selected
                        ? colors.accent
                        : (ready ? colors.textSecondary : colors.textDisabled),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          voice.displayName,
                          style: TextStyle(
                            color: colors.textPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          s.voiceQualityInfo(
                            voice.locale,
                            _voiceQualityLabel(s, voice.quality),
                            '${voice.sizeMb}',
                          ),
                          style: TextStyle(
                            color: colors.textSecondary,
                            fontSize: 11.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (ready)
                    Icon(Icons.check_circle, size: 18, color: colors.success),
                ],
              ),
            ),
            if (busy) ...[
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value:
                      _onnxPhase == TtsPrepPhase.downloading &&
                          _onnxProgress > 0
                      ? _onnxProgress
                      : null,
                  color: colors.accent,
                  backgroundColor: colors.surfaceVariant,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _onnxPhase == TtsPrepPhase.extracting
                    ? s.voicePreparingVoice
                    : s.voiceDownloadingPct(
                        (_onnxProgress * 100).toStringAsFixed(0),
                      ),
                style: TextStyle(fontSize: 11, color: colors.textDisabled),
              ),
              if (_onnxPhase == TtsPrepPhase.downloading)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () => _cancelOnnx(voice),
                    icon: Icon(Icons.close, size: 16, color: colors.error),
                    label: Text(
                      s.commonCancel,
                      style: TextStyle(color: colors.error, fontSize: 12),
                    ),
                  ),
                ),
            ] else if (!ready) ...[
              const SizedBox(height: 10),
              HermesSecondaryButton(
                label: s.voiceDownloadButton,
                icon: Icons.download_rounded,
                onTap: _onnxBusyVoiceId == null
                    ? () => _downloadOnnx(voice)
                    : null,
              ),
            ] else ...[
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: deleting || _testingVoice
                      ? null
                      : () => _deleteOnnx(voice),
                  icon: Icon(
                    deleting
                        ? Icons.hourglass_top_rounded
                        : Icons.delete_outline,
                    size: 16,
                    color: colors.textSecondary,
                  ),
                  label: Text(
                    s.voiceDeleteButton,
                    style: TextStyle(color: colors.textSecondary, fontSize: 12),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _changeSherpaModel(SherpaModelKind kind) async {
    if (_s.sherpaModel == kind) return;
    await _update(_s.copyWith(sherpaModel: kind));
    if (mounted) setState(() {}); // refresca el estado "listo" del seleccionado
  }

  /// Configuración del STT por servidor: URL + token + probar conexión, con el
  /// aviso de privacidad (el audio sale del teléfono hacia tu servidor).
  Widget _serverSttSection(HermesThemeColors colors, Strings s) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Aviso de privacidad: esta opción SÍ envía audio fuera del teléfono.
          Container(
            padding: const EdgeInsets.all(11),
            decoration: BoxDecoration(
              color: colors.accent.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: colors.accent.withValues(alpha: 0.35)),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.privacy_tip_outlined,
                  size: 16,
                  color: colors.accent,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    Strings.of(context).voiceServerPrivacyNote,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: colors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _field(
            colors: colors,
            label: Strings.of(context).voiceServerUrl,
            controller: _serverUrlCtrl,
            hint: 'ws://192.168.1.10:9123',
            onChanged: (_) => setState(() => _serverTestOk = null),
          ),
          const SizedBox(height: 12),
          _field(
            colors: colors,
            label: Strings.of(context).commonToken,
            controller: _serverTokenCtrl,
            hint: Strings.of(context).voiceTokenServerHint,
            obscure: _serverTokenObscured,
            onChanged: (_) => setState(() => _serverTestOk = null),
            suffix: IconButton(
              icon: Icon(
                _serverTokenObscured ? Icons.visibility_off : Icons.visibility,
                size: 20,
                color: colors.textSecondary,
              ),
              onPressed: () =>
                  setState(() => _serverTokenObscured = !_serverTokenObscured),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              HermesSecondaryButton(
                label: _serverTesting
                    ? Strings.of(context).commonTesting
                    : Strings.of(context).voiceSaveTest,
                icon: Icons.wifi_tethering,
                onTap: _serverTesting ? null : () => _saveServerStt(test: true),
              ),
              const SizedBox(width: 12),
              if (_serverTestOk == true)
                Row(
                  children: [
                    Icon(Icons.check_circle, size: 16, color: colors.success),
                    const SizedBox(width: 4),
                    Text(
                      Strings.of(context).commonConnected,
                      style: TextStyle(fontSize: 12.5, color: colors.success),
                    ),
                  ],
                )
              else if (_serverTestOk == false)
                Expanded(
                  child: Row(
                    children: [
                      Icon(Icons.error_outline, size: 16, color: colors.error),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          Strings.of(context).voiceConnNoResponse,
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// Selector de los 3 modelos del STT en vivo (Whisper base/small, Parakeet v3),
  /// cada uno con su descarga/borrado bajo demanda.
  Widget _sherpaModelSection(HermesThemeColors colors, Strings s) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        children: [
          for (final m in kSherpaSttModels)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _sherpaModelTile(colors, s, m),
            ),
        ],
      ),
    );
  }

  Widget _sherpaModelTile(
    HermesThemeColors colors,
    Strings s,
    SherpaSttModel m,
  ) {
    final selected = _s.sherpaModel == m.kind;
    final ready = _sherpaReady.contains(m.id);
    final busy = _sherpaBusyId == m.id;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _changeSherpaModel(m.kind),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: selected
              ? colors.accent.withValues(alpha: 0.08)
              : colors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected
                ? colors.accent.withValues(alpha: 0.7)
                : colors.divider.withValues(alpha: 0.55),
            width: selected ? 1.4 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 18,
                  color: selected ? colors.accent : colors.textDisabled,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    m.displayName,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: colors.textPrimary,
                    ),
                  ),
                ),
                if (ready)
                  Icon(Icons.check_circle, size: 16, color: colors.success),
              ],
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(left: 26),
              child: Text(
                '${_sttModelSub(s, m.kind)} · ~${m.sizeMb} MB',
                style: TextStyle(fontSize: 12, color: colors.textSecondary),
              ),
            ),
            if (m.heavyRam) ...[
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.only(left: 26),
                child: Row(
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      size: 13,
                      color: colors.accent,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        Strings.of(context).voiceHeavyRamWarning,
                        style: TextStyle(
                          fontSize: 11,
                          color: colors.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (busy) ...[
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value:
                      _sherpaPhase == SherpaPrepPhase.extracting ||
                          _sherpaProgress <= 0
                      ? null
                      : _sherpaProgress,
                  color: colors.accent,
                  backgroundColor: colors.surfaceVariant,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _sherpaPhase == SherpaPrepPhase.extracting
                    ? Strings.of(context).voiceExtracting
                    : '${(_sherpaProgress * 100).toStringAsFixed(0)} %',
                style: TextStyle(fontSize: 11, color: colors.textDisabled),
              ),
              if (_sherpaPhase == SherpaPrepPhase.downloading)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () => _cancelSherpa(m),
                    icon: Icon(Icons.close, size: 16, color: colors.error),
                    label: Text(
                      s.commonCancel,
                      style: TextStyle(color: colors.error, fontSize: 12),
                    ),
                  ),
                ),
            ] else ...[
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.only(left: 26),
                child: ready
                    ? Row(
                        children: [
                          Text(
                            Strings.of(context).commonDownloaded,
                            style: TextStyle(
                              fontSize: 12,
                              color: colors.success,
                            ),
                          ),
                          const Spacer(),
                          TextButton(
                            onPressed: () => _deleteSherpa(m),
                            child: Text(
                              Strings.of(context).voiceDeleteButton,
                              style: TextStyle(
                                fontSize: 12.5,
                                color: colors.textSecondary,
                              ),
                            ),
                          ),
                        ],
                      )
                    : HermesSecondaryButton(
                        label: Strings.of(context).voiceDownloadModel,
                        icon: Icons.download_rounded,
                        onTap: _sherpaBusyId == null
                            ? () => _downloadSherpa(m)
                            : null,
                      ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _changeWhisperModel(SttModelSize size) async {
    if (_s.whisperModel == size) return;
    await _update(_s.copyWith(whisperModel: size));
    // Re-chequea si el modelo recién elegido ya está descargado.
    final r = await _voice?.whisperModelReady() ?? false;
    if (mounted) setState(() => _whisperReady = r);
  }

  Widget _whisperModelTile(HermesThemeColors colors, Strings s) {
    final isTiny = _s.whisperModel == SttModelSize.tiny;
    final sizeMb = isTiny ? 75 : 142;
    final name = isTiny ? 'tiny' : 'base';
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: colors.divider.withValues(alpha: 0.55)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Selector de tamaño: tiny (rápido) / base (más preciso).
            Row(
              children: [
                Expanded(
                  child: _SizePill(
                    colors: colors,
                    label: 'tiny',
                    sub: s.voiceWhisperTinySub,
                    selected: isTiny,
                    onTap: () => _changeWhisperModel(SttModelSize.tiny),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _SizePill(
                    colors: colors,
                    label: 'base',
                    sub: s.voiceWhisperBaseSub,
                    selected: !isTiny,
                    onTap: () => _changeWhisperModel(SttModelSize.base),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(
                  _whisperReady
                      ? Icons.check_circle
                      : Icons.cloud_download_outlined,
                  size: 18,
                  color: _whisperReady ? colors.success : colors.accent,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _whisperReady
                        ? s.voiceWhisperReady(name)
                        : s.voiceWhisperNotReady(name, sizeMb.toString()),
                    style: TextStyle(fontSize: 12.5, color: colors.textPrimary),
                  ),
                ),
              ],
            ),
            if (_downloading) ...[
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: _progress > 0 ? _progress : null,
                  color: colors.accent,
                  backgroundColor: colors.surfaceVariant,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${(_progress * 100).toStringAsFixed(0)} %',
                style: TextStyle(fontSize: 11, color: colors.textDisabled),
              ),
            ] else if (!_whisperReady) ...[
              const SizedBox(height: 10),
              HermesSecondaryButton(
                label: s.voiceDownloadModelButton,
                icon: Icons.download_rounded,
                onTap: _downloadWhisper,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SizePill extends StatelessWidget {
  final HermesThemeColors colors;
  final String label;
  final String sub;
  final bool selected;
  final VoidCallback onTap;
  const _SizePill({
    required this.colors,
    required this.label,
    required this.sub,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
        decoration: BoxDecoration(
          color: selected
              ? colors.accent.withValues(alpha: 0.12)
              : colors.surfaceVariant,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? colors.accent : colors.divider,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 15,
                  color: selected ? colors.accent : colors.textDisabled,
                ),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              sub,
              style: TextStyle(color: colors.textSecondary, fontSize: 10.5),
            ),
          ],
        ),
      ),
    );
  }
}

class _Choice<T> extends StatelessWidget {
  final HermesThemeColors colors;
  final T value;
  final List<(T, String, String)> options;
  final Set<T> disabled;
  final ValueChanged<T> onChanged;
  const _Choice({
    required this.colors,
    required this.value,
    required this.options,
    required this.disabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final (v, title, sub) in options)
          Semantics(
            button: true,
            selected: value == v,
            enabled: !disabled.contains(v),
            child: Opacity(
              opacity: disabled.contains(v) ? 0.5 : 1,
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  value == v
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: value == v ? colors.accent : colors.textDisabled,
                ),
                title: Text(
                  title,
                  style: TextStyle(color: colors.textPrimary, fontSize: 14),
                ),
                subtitle: Text(
                  sub,
                  style: TextStyle(color: colors.textSecondary, fontSize: 12),
                ),
                onTap: disabled.contains(v) ? null : () => onChanged(v),
              ),
            ),
          ),
      ],
    );
  }
}
