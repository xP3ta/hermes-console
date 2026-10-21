// Ajustes de voz. La pantalla principal es una lista corta de etiqueta y
// valor. «Dictado» y «Voz de las respuestas» preguntan lo mismo: Servidor
// Hermes o este teléfono, y solo la opción elegida enseña sus filas (los
// campos de Hermes Desktop, o el modelo o la voz del teléfono). «Avanzado»
// reúne el resto de campos de Desktop y dos interruptores del teléfono.
//
// Todo se pinta al abrir con lo último que la app sabe (ajustes locales y la
// última configuración de voz leída del servidor) y se refresca después.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/app_localizations.dart';
import '../../main.dart';
import '../config/flavor.dart';
import '../design/hermes_design.dart'
    show
        HermesDialogAction,
        HermesDialogActionStyle,
        HermesListGroup,
        HermesListRow,
        HermesOption,
        HermesSectionHeader,
        HermesSpace,
        HermesStatusText,
        HermesStatusTone,
        HermesToggleRow,
        HermesType,
        showHermesFormDialog,
        showHermesOptions;
import 'chat_screen.dart';
import 'instance_edit_screen.dart';
import '../navigation/chat_route.dart';
import '../services/connection_manager.dart';
import '../services/new_session_factory.dart';
import '../services/voice/conversation/native_voice.dart';
import '../services/voice/hermes_speech_stream.dart';
import '../services/voice/live/voice_chat_mode_store.dart';
import '../services/voice/live/voice_live_api.dart';
import '../services/voice/live/voice_live_protocol.dart';
import '../services/voice/tts_engine.dart';
import '../services/voice/model_download.dart';
import '../services/voice/removed_voice_engines.dart';
import '../services/voice/server_voice_config.dart';
import '../services/voice/server_voice_fields.dart';
import '../services/voice/stt_sherpa.dart';
import '../services/voice/tts_model_manager.dart';
import '../services/voice/voice_service.dart';
import '../services/voice/voice_settings.dart';
import '../theme/app_theme.dart';
import '../utils/api_error.dart';
import '../utils/voice_error.dart';
import '../widgets/general_dock_shell.dart';
import '../widgets/hermes_ui.dart' hide HermesSectionHeader;
import '../widgets/hermes_app_bar.dart';
import '../widgets/hermes_premium_ui.dart'
    show HermesSegment, HermesSegmentedControl;
import '../widgets/read_only.dart' show showReadOnlyNotice;
import '../widgets/voice_disclosure_dialog.dart';
import '../feedback/feedback_policy.dart';

typedef HermesServerPreviewEngineFactory =
    TtsEngine Function(HermesSpeakRequest synthesize);

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

/// Opens the chat in which a voice conversation is tried.
typedef VoiceTryChatOpener =
    void Function(
      BuildContext context,
      SavedConnection connection,
      Session session,
    );

class VoiceSettingsScreen extends StatefulWidget {
  final VoiceService? voiceService;
  final SavedConnection? connection;
  final DashboardClientFactory? dashboardClientFactory;
  final SharedPreferences? preferences;
  final String? profile;
  final HermesServerPreviewEngineFactory? serverPreviewEngineFactory;
  final VoiceTryChatOpener? voiceTryChatOpener;

  const VoiceSettingsScreen({
    super.key,
    this.connection,
    @visibleForTesting this.voiceService,
    @visibleForTesting this.dashboardClientFactory,
    @visibleForTesting this.preferences,
    @visibleForTesting this.serverPreviewEngineFactory,
    @visibleForTesting this.voiceTryChatOpener,
    this.profile,
  });

  /// The chat "Probar" opens for GPT-Live: a new conversation with the voice
  /// conversation already starting, the same entry the home voice shortcut
  /// uses (`ChatScreen.initialVoiceMode`). The privacy notice and the
  /// microphone permission are asked there, as always, and the conversation
  /// runs on GPT-Live because that is the mode the profile is set to.
  @visibleForTesting
  static ChatScreen voiceTryChat(SavedConnection connection, Session session) =>
      ChatScreen(
        connection: connection,
        session: session,
        initialVoiceMode: true,
      );

  static void _openVoiceTryChat(
    BuildContext context,
    SavedConnection connection,
    Session session,
  ) => unawaited(
    openChatFromHome<void>(
      context,
      builder: (_) => voiceTryChat(connection, session),
    ),
  );

  @override
  State<VoiceSettingsScreen> createState() => _VoiceSettingsScreenState();
}

/// Subpantallas de Voz. Son rutas propias, pero pintan con el estado de la
/// pantalla principal, que conserva todos los controladores y acciones.
enum _VoicePage { dictation, speech, advanced }

class _VoiceSubPage extends StatelessWidget {
  final _VoiceSettingsScreenState owner;
  final _VoicePage page;
  const _VoiceSubPage({required this.owner, required this.page});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: owner._revision,
    builder: (context, _) => owner._paints
        ? owner._buildPage(context, page)
        : const SizedBox.shrink(),
  );
}

class _VoiceSettingsScreenState extends State<VoiceSettingsScreen>
    with WidgetsBindingObserver {
  int _gptLiveProbeEpoch = 0;

  /// Cambia con cada `setState` para que la subpantalla abierta, que vive en
  /// otra ruta, se repinte con el mismo estado.
  final ValueNotifier<int> _revision = ValueNotifier<int>(0);

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _revision.value++;
  }

  /// Falso desde que la pantalla sale del árbol: entre `deactivate` y
  /// `dispose` sigue «montada», pero su `context` ya no puede consultar el
  /// tema ni el idioma, y la subpantalla abierta aún se repinta una vez.
  bool _inTree = true;
  bool get _paints => mounted && _inTree;

  @override
  void activate() {
    super.activate();
    _inTree = true;
  }

  @override
  void deactivate() {
    _inTree = false;
    super.deactivate();
  }

  /// Subpantallas abiertas. Si esta pantalla desaparece con una encima, la
  /// subpantalla se retira con ella: no puede seguir pintando sin su estado.
  final List<Route<void>> _openPages = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) return;
    _gptLiveProbeEpoch++;
    if (_gptLiveStatusRequested && !_gptLiveStatusLoaded) {
      _gptLiveStatusRequested = false;
      _gptLiveStatusLoaded = true;
      _gptLiveFailure = const VoiceLiveStatusException(
        VoiceLiveStatusFailure.transient,
      );
      if (mounted) setState(() {});
    }
  }

  final _scrollController = ScrollController();
  VoiceService? _voice;
  late VoiceSettings _s;
  bool _loaded = false;
  bool _testingVoice = false;
  TtsEngine? _previewEngine;
  int _previewEpoch = 0;

  /// El motor del teléfono que se usó por última vez, para volver a él al
  /// elegir «En este teléfono» en «Dictado».
  SttEngineKind _lastPhoneDictation = SttEngineKind.sherpaLive;

  // La pantalla principal solo avisa de lo que no funciona. Hasta que termina
  // la primera comprobación de cada modelo no se sabe si falta, así que no se
  // avisa de nada: un «falta descargar» que desaparece al instante confunde.
  bool _whisperChecked = false;
  bool _sherpaChecked = false;
  bool _onnxChecked = false;

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

  /// Los campos de voz de Hermes Desktop para este perfil. Empiezan con lo
  /// último leído (guardado en el teléfono) y se refrescan en segundo plano.
  ServerVoiceFields _serverFields = ServerVoiceFields.empty;
  ServerVoiceFieldsStore? _serverFieldsStore;
  String? _savingServerField;
  String? _serverTtsProvider;
  bool _serverVoiceConfigLoading = false;
  bool _serverVoiceTesting = false;

  /// Motivo del último «Probar» fallido. La configuración leída no prueba que
  /// el proveedor funcione; tras un fallo real la tarjeta no puede seguir en
  /// verde. Se limpia con una prueba correcta o al recargar la configuración.
  Object? _serverVoiceTestError;
  bool _serverVoiceConfigFailed = false;
  Object? _serverVoiceConfigError;
  bool _serverVoiceDetailsExpanded = false;

  // GPT-Live (experimental): a single status read when the screen opens, no
  // polling. `null` = server without the feature (404/405) or an error.
  bool _gptLiveStatusRequested = false;
  bool _gptLiveStatusLoaded = false;
  VoiceLiveStatus? _gptLiveStatus;

  /// Último modo conocido por conexión y perfil, el mismo que consulta la
  /// conversación de voz al arrancar.
  VoiceChatModeStore? _chatModes;
  VoiceLiveMode? _pendingChatMode;
  VoiceLiveStatusException? _gptLiveFailure;
  bool _liveReasonExpanded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    final appState = context.findAncestorStateOfType<HermesAppState>();
    _voice = widget.voiceService ?? appState?.voice;
    _s = _voice?.settings ?? const VoiceSettings();
    if (_isPhoneDictation(_s.sttEngine)) _lastPhoneDictation = _s.sttEngine;
    _voice?.whisperModelReady().then((r) {
      if (!mounted) return;
      setState(() {
        _whisperReady = r;
        _whisperChecked = true;
      });
    });
    _refreshOnnxReady();
    _refreshSherpaReady();
    _loaded = true;
    // La voz no depende de la conexión; el dictado sí, y espera a saber qué
    // ofrece el servidor.
    unawaited(_migrateRemovedEngines(serverKnown: false));
    unawaited(
      _loadNativeVoiceChoice().whenComplete(
        () => _migrateRemovedEngines(serverKnown: true),
      ),
    );
  }

  /// Reuses the screen's own Dashboard client: one extra GET, no second login.
  Future<void> _loadGptLiveStatus(
    DashboardClient dashboard,
    String? profile,
  ) async {
    if (_gptLiveStatusRequested) return;
    _gptLiveStatusRequested = true;
    final epoch = ++_gptLiveProbeEpoch;
    VoiceLiveStatus? status;
    VoiceLiveStatusException? failure;
    try {
      status = await DashboardVoiceLiveApi(
        dashboard,
      ).fetchStatusChecked(profile: profile ?? '');
      // An answer is an answer even if this screen has moved on: the next
      // voice conversation of this connection and profile starts from it.
      final connection = _nativeVoiceConnection;
      if (connection != null) {
        _chatModes?.remember(
          VoiceChatModeStore.identity(connection.id, profile),
          status,
        );
      }
    } on VoiceLiveStatusException catch (error) {
      failure = error;
    }
    if (WidgetsBinding.instance.lifecycleState != null &&
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      _gptLiveStatusRequested = false;
      return;
    }
    if (!mounted || epoch != _gptLiveProbeEpoch) return;
    setState(() {
      // Si la comprobación falla se sigue viendo el último modo conocido.
      if (failure == null) _gptLiveStatus = status;
      _gptLiveFailure = failure;
      _gptLiveStatusLoaded = true;
    });
  }

  /// El modo lo decide el servidor, por perfil (`voice.voice_chat_mode`), como
  /// en Desktop (`selectedVoiceChatMode`): GPT-Live solo si el estado lo dice.
  /// Mientras se guarda un cambio se muestra ya la opción recién tocada.
  bool get _liveSelected =>
      (_pendingChatMode ?? _gptLiveStatus?.mode) == VoiceLiveMode.gptLive;

  /// Una conexión de solo lectura ve el modo, pero no lo cambia.
  bool get _canEditChatMode =>
      _nativeVoiceDashboard != null &&
      _nativeVoiceConnection?.readOnly != true &&
      _pendingChatMode == null;

  /// Escribe `voice.voice_chat_mode` del perfil activo con el mismo parche
  /// de configuración que usa el gestor de voz del servidor, y vuelve a leer
  /// el estado. Se aplica a la siguiente conversación. Si la escritura falla,
  /// la selección vuelve a ser la que el servidor tenía.
  Future<void> _setVoiceChatMode(VoiceLiveMode mode) async {
    final dashboard = _nativeVoiceDashboard;
    if (dashboard == null || !_canEditChatMode) return;
    if (_gptLiveStatus?.mode == mode) return;
    if (mode == VoiceLiveMode.gptLive && _liveUnavailable) return;
    final s = Strings.of(context);
    final profile = _effectiveProfile;
    setState(() => _pendingChatMode = mode);
    try {
      await dashboard.putServerConfigPatch({
        'voice': {
          'voice_chat_mode': mode == VoiceLiveMode.gptLive
              ? 'gpt-live'
              : 'chained',
        },
      }, profile: profile);
      _gptLiveStatusRequested = false;
      await _loadGptLiveStatus(dashboard, profile);
    } catch (_) {
      if (mounted) _snack(s.voiceChatModeSaveFailed);
    } finally {
      if (mounted) setState(() => _pendingChatMode = null);
    }
  }

  /// El servidor conoce GPT-Live y dice que no puede arrancarlo. Vale también
  /// para el último estado recordado, que se pinta antes de volver a preguntar.
  bool get _liveUnavailable => _gptLiveStatus?.available == false;

  /// El motivo que da el servidor es que le falta la clave de OpenAI
  /// (`tools/voice_live.py`: "no OpenAI API key (set OPENAI_API_KEY or
  /// voice.gpt_live.api_key)").
  bool get _liveNeedsKey {
    final reason = _gptLiveStatus?.reason?.toLowerCase() ?? '';
    return _liveUnavailable &&
        (reason.contains('openai api key') ||
            reason.contains('openai_api_key'));
  }

  /// Lo que el servidor dijo con sus palabras cuando el motivo no es la
  /// clave. Solo se enseña detrás de «Ver detalles».
  String? get _liveServerReason {
    final reason = _gptLiveStatus?.reason?.trim() ?? '';
    return !_liveUnavailable || _liveNeedsKey || reason.isEmpty ? null : reason;
  }

  /// No se pudo comprobar si el servidor ofrece GPT-Live: qué pasó, para
  /// «Avanzado», donde está el reintento.
  (String, HermesStatusTone)? _gptLiveProbeProblem(Strings s) {
    final failure = _gptLiveFailure;
    if (failure == null) return null;
    return (
      failure.failure == VoiceLiveStatusFailure.accessRequired
          ? s.voiceGuardProbeAccess
          : s.voiceGuardProbeTransient,
      HermesStatusTone.warn,
    );
  }

  /// Tras guardar la clave se vuelve a leer el estado: si el servidor ya
  /// puede arrancar GPT-Live, la opción queda disponible sin salir de aquí.
  Future<void> _recheckGptLive() async {
    final dashboard = _nativeVoiceDashboard;
    if (dashboard == null) return;
    _gptLiveStatusRequested = false;
    await _loadGptLiveStatus(dashboard, _effectiveProfile);
  }

  Future<void> _loadNativeVoiceChoice() async {
    final app = context.findAncestorStateOfType<HermesAppState>();
    final manager = app?.connManager;
    final preferences = widget.preferences ?? manager?.prefs;
    if (preferences == null) return;
    _chatModes = VoiceChatModeStore(preferences);

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
    // Lo último que se supo del servidor se pinta ya; lo que sigue lo
    // refresca sin tapar nada: ni la capacidad caducada, ni los campos de
    // voz, ni el modo de conversación esperan a la red para verse.
    final fieldsStore = ServerVoiceFieldsStore(preferences);
    final knownFields = fieldsStore.read(identity);
    final knownLive = _chatModes?.lastStatus(
      VoiceChatModeStore.identity(connection.id, effectiveProfile),
    );
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
        _nativeVoiceLoading = capability == null;
        _serverFieldsStore = fieldsStore;
        if (knownFields != null && _serverFields.isEmpty) {
          _serverFields = knownFields;
          _serverVoiceSummary ??= HermesServerVoiceSummary.fromConfig(
            knownFields.asConfig(),
          );
          _serverTtsProvider ??= knownFields.speech;
        }
        if (!_gptLiveStatusLoaded) _gptLiveStatus ??= knownLive;
      });
      unawaited(_loadGptLiveStatus(dashboard, effectiveProfile));
    }
    unawaited(_loadServerVoiceConfig(dashboard, epoch));

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
        _serverVoiceTestError = null;
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
      final response = await dashboard.getServerConfig(
        profile: _effectiveProfile,
      );
      final config = sanitizeHermesServerVoiceConfig(
        response,
        schema ?? const {},
      );
      final fields = ServerVoiceFields.read(response, schema ?? const {});
      final provider = _configString(config, const ['tts', 'provider']);
      final summary = HermesServerVoiceSummary.fromConfig(
        config,
        pcmStreamingObserved: _pcmObservedForConfig(config, dashboard.baseUrl),
      );
      if (!mounted || epoch != _nativeVoiceLoadEpoch) return;
      final identity = _nativeVoiceIdentity;
      if (identity != null) {
        unawaited(_serverFieldsStore?.write(identity, fields));
      }
      setState(() {
        _serverVoiceConfig = config;
        _serverVoiceSummary = summary;
        _serverFields = fields;
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
    final connection = _nativeVoiceConnection;
    if (useServer && _nativeVoiceCapability?.ok == true && connection != null) {
      // La voz vive más que esta pantalla: recibe su propio cliente y lo
      // cierra ella misma al desactivarse o sustituirse. Reutilizar el de
      // Ajustes la dejaba sobre un cliente cerrado al salir, y «Leer en voz
      // alta» fallaba en silencio hasta reiniciar.
      final voiceDashboard =
          widget.dashboardClientFactory?.call(connection) ??
          DashboardClient.lazy(connection);
      final profile = _effectiveProfile;
      final installed = voice.enableNativeVoice(
        speak: (text) =>
            voiceDashboard.synthesizeSpeech(text, profile: profile),
        transcribe: (dataUrl, mimeType) => voiceDashboard.transcribeAudio(
          dataUrl,
          mimeType: mimeType,
          profile: profile,
        ),
        ttsLease: (lease, active) =>
            voiceDashboard.setTtsLease(lease, active: active, profile: profile),
        onDispose: voiceDashboard.close,
      );
      if (!installed) voiceDashboard.close();
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
    if (mounted) setState(() => _onnxChecked = true);
  }

  Future<void> _downloadOnnx(NeuralVoice voice, {bool select = false}) async {
    final v = _voice;
    if (v == null || _onnxBusyVoiceId != null) return;
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
      if (select) {
        // Se pidió esta voz en el selector: en cuanto está, es la elegida.
        await _update(
          _s.copyWith(ttsEngine: TtsEngineKind.onnx, onnxVoiceId: voice.id),
        );
      } else if (!selectedReady) {
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
    if (mounted) setState(() => _sherpaChecked = true);
  }

  Future<void> _downloadSherpa(SherpaSttModel m, {bool select = false}) async {
    final v = _voice;
    if (v == null || _sherpaBusyId != null) return;
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
      if (select) {
        // Se pidió este modelo en el selector: en cuanto está, es el elegido.
        _lastPhoneDictation = SttEngineKind.sherpaLive;
        await _update(
          _s.copyWith(sttEngine: SttEngineKind.sherpaLive, sherpaModel: m.kind),
        );
      } else if (_s.sherpaModel == m.kind) {
        // Si es el modelo elegido, fuerza reconstruir el motor activo.
        await _voice?.saveSettings(_s);
      }
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
    WidgetsBinding.instance.removeObserver(this);
    _gptLiveProbeEpoch++;
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
    _revision.dispose();
    for (final route in List.of(_openPages)) {
      // El árbol está bloqueado durante `dispose`: se retira justo después.
      scheduleMicrotask(() {
        if (route.isActive) route.navigator?.removeRoute(route);
      });
    }
    super.dispose();
  }

  Future<void> _update(VoiceSettings s) async {
    setState(() => _s = s);
    await _voice?.saveSettings(s);
  }

  /// Un motor guardado que esta pantalla ya no ofrece (un servicio propio de
  /// voz o de dictado) pasa, una vez y sin avisos, a uno que sí ofrece. Las
  /// direcciones y claves guardadas no se tocan.
  ///
  /// Las dos pasadas (la voz al abrir, el dictado cuando el servidor ha
  /// contestado) van una detrás de otra: en paralelo, la segunda vería un
  /// ajuste cambiado por la primera y se retiraría.
  Future<void> _migrateRemovedEngines({required bool serverKnown}) =>
      _removedEngineMigration = _removedEngineMigration.then((_) async {
        final voice = _voice;
        if (!mounted || voice == null) return;
        if (!RemovedVoiceEngines.pending(voice.settings)) return;
        final changed = await RemovedVoiceEngines.migrate(
          voice: voice,
          serverDictation: () async => serverKnown
              ? _nativeVoiceConsent == NativeVoiceConsent.accepted &&
                    _nativeVoiceCapability?.transcribe == true
              : null,
        );
        if (changed && mounted) setState(() => _s = voice.settings);
      });

  Future<void> _removedEngineMigration = Future<void>.value();

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

  static bool _isPhoneDictation(SttEngineKind kind) => switch (kind) {
    SttEngineKind.sherpaLive ||
    SttEngineKind.whisper ||
    SttEngineKind.system => true,
    SttEngineKind.hermesServer || SttEngineKind.server => false,
  };

  /// El motor del teléfono que «En este teléfono» usa o volvería a usar.
  SttEngineKind get _phoneDictationEngine =>
      _isPhoneDictation(_s.sttEngine) ? _s.sttEngine : _lastPhoneDictation;

  Future<void> _selectHermesDictation(bool useServer) async {
    if (!useServer) {
      if (_isPhoneDictation(_s.sttEngine)) return;
      await _selectEngine(stt: _lastPhoneDictation);
      return;
    }
    if (_s.sttEngine == SttEngineKind.hermesServer) return;
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
    if (_isPhoneDictation(_s.sttEngine)) _lastPhoneDictation = _s.sttEngine;
    setState(() => _nativeVoiceConsent = NativeVoiceConsent.accepted);
    await _selectEngine(stt: SttEngineKind.hermesServer);
  }

  void _snack(String m, [FeedbackKind kind = FeedbackKind.error]) =>
      AppFeedback.notify(context, kind, m);

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
      if (_s.ttsEngine == TtsEngineKind.onnx) {
        final voice = neuralVoiceById(_s.onnxVoiceId);
        previewEngine = voice == null ? null : await v.buildOnnxPreview(voice);
        if (previewEngine == null) {
          _snack(s.voiceDownloadFirst);
          return;
        }
        if (!await _claimPreviewEngine(previewEngine, previewEpoch)) return;
        await v.previewTts(previewEngine, sample);
      } else {
        // Mudo si el móvil no tiene motor TTS (GrapheneOS): evita el crash de
        // flutter_tts (recursión → StackOverflow no capturable).
        previewEngine = await systemTtsOrSilent(lang: v.voiceLang);
        if (!await _claimPreviewEngine(previewEngine, previewEpoch)) return;
        await v.previewTts(previewEngine, sample);
      }
      if (mounted) _snack(s.voiceTestPlayed, FeedbackKind.routine);
    } catch (e) {
      if (mounted) _snack(s.voiceNoPreview(localizedVoiceError(s, e)));
    } finally {
      await _releasePreviewEngine(previewEngine);
      if (mounted) setState(() => _testingVoice = false);
    }
  }

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

  bool get _usesHermesServer =>
      _nativeVoiceIdentity != null &&
      _nativeVoiceMode == NativeVoiceMode.server &&
      _nativeVoiceConsent == NativeVoiceConsent.accepted;

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
      _snack(Strings.of(context).voiceServerUpdateHelp, FeedbackKind.critical);

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
      _serverVoiceTestError = null;
    });
    await _loadNativeVoiceChoice();
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
        setState(() => _serverVoiceTestError = null);
        _snack(s.voiceTestPlayed, FeedbackKind.routine);
      }
    } catch (error) {
      if (mounted && previewEpoch == _previewEpoch) {
        setState(() => _serverVoiceTestError = error);
        // Si el motivo lo escribió el servidor, el aviso lleva el mismo
        // resumen de una línea que el bloque; su texto completo queda tras
        // «Ver detalles». Los fallos locales ya llegan traducidos.
        _snack(
          serverVoiceErrorFullDetail(error) == null
              ? s.voiceNoPreview(localizedVoiceError(s, error))
              : _serverTestFailureSummary(s, error),
        );
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

  bool get _serverAuthRequired {
    final error = _serverVoiceConfigError;
    return error != null &&
        classifyDashboardDependencyFailure(error) ==
            DashboardDependencyFailure.credentials;
  }

  ButtonStyle _quietButtonStyle(HermesThemeColors colors) =>
      OutlinedButton.styleFrom(
        foregroundColor: colors.textPrimary,
        visualDensity: VisualDensity.compact,
        side: BorderSide(color: colors.divider.withValues(alpha: 0.7)),
      );

  /// Única acción de la ruta «Servidor Hermes» mientras necesita atención. Con
  /// la ruta sana no hay nada que resolver aquí: configurar y probar la voz
  /// del servidor viven en «Texto a voz», junto a la voz que suena.
  Widget? _serverRouteAction(HermesThemeColors colors, Strings s) {
    final unavailable = _nativeVoiceCapability?.ok != true;
    final style = _quietButtonStyle(colors);
    if (_serverAuthRequired) {
      return OutlinedButton.icon(
        key: const ValueKey('voice_server_auth_action'),
        style: style,
        onPressed: _openDashboardAuthentication,
        icon: const Icon(Icons.lock_open_rounded),
        label: Text(s.voiceServerAuthAction),
      );
    }
    if (unavailable && _nativeVoiceCapability?.conclusive == true) {
      return OutlinedButton.icon(
        key: const ValueKey('voice_server_update_action'),
        style: style,
        onPressed: _showServerUpdateHelp,
        icon: const Icon(Icons.system_update_alt_rounded),
        label: Text(s.voiceServerUpdateAction),
      );
    }
    if (unavailable || _serverVoiceConfigFailed) {
      return OutlinedButton.icon(
        key: const ValueKey('voice_server_check_action'),
        style: style,
        onPressed: _nativeVoiceLoading ? null : _checkServerVoice,
        icon: const Icon(Icons.refresh_rounded),
        label: Text(s.voiceServerCheckAction),
      );
    }
    return null;
  }

  /// El servidor explica en inglés por qué falló la síntesis. La falta de
  /// clave es reconocible (`… API_KEY not set`, `neither …api_key … is set`);
  /// cualquier otro texto queda como detalle bajo una línea genérica.
  static bool _serverTextSaysKeyMissing(String text) {
    final normalized = text.toLowerCase();
    return normalized.contains('api_key') &&
        (normalized.contains('not set') ||
            normalized.contains('neither') ||
            normalized.contains('missing'));
  }

  /// Resumen de una línea del último «Probar» fallido de la voz del servidor.
  String _serverTestFailureSummary(Strings s, Object error) {
    final text = serverVoiceErrorFullDetail(error);
    if (text == null || !_serverTextSaysKeyMissing(text)) {
      return s.voiceServerTestFailedShort;
    }
    final provider = _serverVoiceSummary?.ttsProvider ?? _serverTtsProvider;
    return provider == null
        ? s.voiceServerTestMissingKeyGeneric
        : s.voiceServerTestMissingKey(_providerName(provider));
  }

  /// Texto completo del fallo para «Ver detalles»: lo que respondió el
  /// servidor, sin recortar a media palabra, o el motivo local traducido.
  String _serverTestFailureDetail(Strings s, Object error) =>
      serverVoiceErrorFullDetail(error) ?? localizedVoiceError(s, error);

  /// Proveedor y voz del servidor, sin el modelo: lo que cabe en una fila.
  String? _serverVoiceShort() {
    final summary = _serverVoiceSummary;
    final provider = summary?.ttsProvider;
    if (summary == null || provider == null) return null;
    final voice = provider == 'edge'
        ? _edgeVoiceName(summary.ttsVoice).split(' · ').first
        : summary.ttsVoice;
    return [_providerName(provider), voice]
        .whereType<String>()
        .where((part) => part.isNotEmpty && part != '—')
        .join(' · ');
  }

  /// La voz elegida en este teléfono, con su nombre a secas.
  String _phoneVoiceShort(Strings s) => _s.ttsEngine == TtsEngineKind.onnx
      ? _selectedOnnxVoice.displayName
      : s.voiceDeviceLabel;

  /// Variable que el servidor lee para la clave de voz de cada proveedor
  /// (`tools/tts_tool_openai.py`, `tools/tts_tool_providers.py`). Para OpenAI
  /// es la propia de la voz, que no toca la clave del modelo de chat.
  static const Map<String, String> _serverSpeechKeyVariables = {
    'openai': 'VOICE_TOOLS_OPENAI_KEY',
    'elevenlabs': 'ELEVENLABS_API_KEY',
    'gemini': 'GEMINI_API_KEY',
    'mistral': 'MISTRAL_API_KEY',
    'deepinfra': 'DEEPINFRA_API_KEY',
    'xai': 'XAI_API_KEY',
  };

  String? get _serverSpeechProvider =>
      _serverVoiceSummary?.ttsProvider ?? _serverTtsProvider;

  /// La última prueba dijo que al proveedor de voz le falta su clave y la app
  /// sabe en qué variable guardarla.
  bool get _serverVoiceNeedsKey {
    final error = _serverVoiceTestError;
    if (error == null) return false;
    final text = serverVoiceErrorFullDetail(error);
    return text != null &&
        _serverTextSaysKeyMissing(text) &&
        _serverSpeechKeyVariables.containsKey(_serverSpeechProvider);
  }

  /// Pide la clave en un diálogo de un solo campo y la guarda en el servidor
  /// para el perfil activo, por la misma vía que las claves de proveedor en
  /// Modelos (`PUT /api/env` con escritura vigilada). No se guarda en el
  /// teléfono, no se registra y no vuelve a mostrarse.
  ///
  /// GPT-Live resuelve su clave por la misma cadena de audio de OpenAI que la
  /// voz (`tools/voice_live.py`: `voice.gpt_live.api_key`, si no
  /// `VOICE_TOOLS_OPENAI_KEY`, si no `OPENAI_API_KEY`), así que la variable de
  /// OpenAI de este diálogo también lo habilita. [recheck] vuelve a preguntar
  /// al servidor lo que la clave debía arreglar.
  Future<void> _addServerVoiceKey({
    required String? provider,
    required Future<void> Function() recheck,
  }) async {
    final dashboard = _nativeVoiceDashboard;
    final connection = _nativeVoiceConnection;
    final variable = _serverSpeechKeyVariables[provider];
    if (dashboard == null || connection == null || variable == null) return;
    if (connection.readOnly) {
      showReadOnlyNotice(context);
      return;
    }
    final s = Strings.of(context);
    final profile = _effectiveProfile;
    var typed = '';
    final save = await showHermesFormDialog<bool>(
      context: context,
      surfaceKey: const ValueKey('voice_server_key_dialog'),
      title: s.voiceServerKeyTitle(_providerName(provider)),
      message: s.voiceServerKeyMessage,
      actions: [
        HermesDialogAction(
          value: false,
          label: s.commonCancel,
          style: HermesDialogActionStyle.cancel,
        ),
        HermesDialogAction(
          key: const ValueKey('voice_server_key_save'),
          value: true,
          label: s.commonSave,
        ),
      ],
      enabled: (confirm) => !confirm || typed.trim().isNotEmpty,
      body: (context, setState) => _SecretField(
        fieldKey: const ValueKey('voice_server_key_field'),
        hint: s.voiceServerKeyHint,
        onChanged: (value) => setState(() => typed = value),
      ),
    );
    final key = typed.trim();
    typed = '';
    if (save != true || key.isEmpty || !mounted) return;
    // La clave es del perfil y la conexión donde se pidió: si cambian o la
    // conexión pasa a solo lectura mientras el diálogo está abierto, no se
    // escribe en otro sitio.
    bool authorized() =>
        mounted &&
        _nativeVoiceConnection?.id == connection.id &&
        _nativeVoiceConnection?.readOnly == false &&
        _effectiveProfile == profile;
    try {
      await DashboardClient.guardedWrite(
        authorized,
        () => dashboard.setEnvVar(variable, key, profile: profile),
      );
      if (!mounted) return;
      _snack(s.voiceServerCredentialSaved, FeedbackKind.routine);
    } catch (_) {
      if (mounted) _snack(s.voiceServerCredentialFailed);
      return;
    }
    await recheck();
  }

  /// Lo único que se dice de la voz del servidor cuando no puede hablar: una
  /// frase. Con todo en orden, nada.
  (String, HermesStatusTone)? _serverVoiceProblem(Strings s) {
    if (_nativeVoiceLoading || _serverVoiceFirstLoad) return null;
    if (_serverAuthRequired) {
      return (s.voiceProblemServerAccess, HermesStatusTone.warn);
    }
    if (_nativeVoiceCapability?.ok != true) {
      return (s.voiceProblemServerUnavailable, HermesStatusTone.warn);
    }
    final testError = _serverVoiceTestError;
    if (testError != null) {
      return (_serverTestFailureSummary(s, testError), HermesStatusTone.error);
    }
    if (_serverVoiceConfigFailed) {
      return (s.voiceStatusServerReadyConfigUnknown, HermesStatusTone.warn);
    }
    return null;
  }

  // ── Campos de voz del servidor (los de Hermes Desktop) ───────────────────

  bool get _serverReadOnly => _nativeVoiceConnection?.readOnly == true;

  /// La primera lectura aún no ha vuelto y no hay nada guardado que enseñar.
  /// En cualquier otro refresco se siguen viendo los valores anteriores.
  bool get _serverVoiceFirstLoad =>
      _serverVoiceConfigLoading &&
      _serverVoiceSummary == null &&
      _serverFields.isEmpty;

  String _serverFieldLabel(Strings s, String path) => switch (path) {
    ServerVoiceFields.liveVoice => s.voiceRowLiveVoice,
    ServerVoiceFields.livePersonality => s.voiceRowLivePersonality,
    ServerVoiceFields.maxRecordingSeconds => s.voiceRowMaxRecording,
    _ => switch (ServerVoiceFields.kindOf(path)) {
      ServerVoiceFieldKind.provider => s.voiceRowProvider,
      ServerVoiceFieldKind.model => s.voiceRowModel,
      ServerVoiceFieldKind.voice => s.voiceRowVoice,
      ServerVoiceFieldKind.language => s.voiceRowLanguage,
      ServerVoiceFieldKind.other => path,
    },
  };

  String _languageName(Strings s, String code) => switch (code.toLowerCase()) {
    '' || 'auto' => s.voiceServerChoiceAutomatic,
    'es' => s.languageSpanish,
    'en' => s.languageEnglish,
    'fr' => 'Français',
    'de' => 'Deutsch',
    'pt' => 'Português',
    'it' => 'Italiano',
    final other => other.toUpperCase(),
  };

  String _serverOptionLabel(Strings s, String path, String value) =>
      switch (ServerVoiceFields.kindOf(path)) {
        ServerVoiceFieldKind.provider => _providerName(value),
        ServerVoiceFieldKind.language => _languageName(s, value),
        ServerVoiceFieldKind.voice when path == 'tts.edge.voice' =>
          _edgeVoiceName(value),
        _ => value,
      };

  String _serverFieldValue(Strings s, String path) {
    if (ServerVoiceFields.kindOf(path) == ServerVoiceFieldKind.language) {
      return _languageName(s, _serverFields.text(path) ?? '');
    }
    if (path == ServerVoiceFields.transcriptionProvider) {
      return _providerName(_serverFields.transcriber);
    }
    if (path == ServerVoiceFields.maxRecordingSeconds) {
      final seconds = _serverFields.number(path);
      return seconds == null ? '—' : s.voiceSecondsValue('${seconds.round()}');
    }
    final value = _serverFields.text(path);
    return value == null ? '—' : _serverOptionLabel(s, path, value);
  }

  /// Un campo se puede cambiar si hay de dónde elegir y la conexión deja
  /// escribir. Sin opciones (Desktop lo deja a texto libre) se ve y no se toca.
  bool _serverFieldEditable(String path) =>
      _nativeVoiceDashboard != null &&
      !_serverReadOnly &&
      _serverFields.options(path).isNotEmpty;

  /// Escribe un campo con el mismo parche de configuración que Desktop
  /// (`PUT /api/config`, perfil activo) y vuelve a leer. Mientras tanto, y si
  /// falla, se siguen viendo los valores anteriores.
  Future<void> _writeServerField(String path, Object value) async {
    final dashboard = _nativeVoiceDashboard;
    if (dashboard == null || _serverReadOnly || _savingServerField != null) {
      return;
    }
    final s = Strings.of(context);
    setState(() => _savingServerField = path);
    try {
      await dashboard.putServerConfigPatch(
        ServerVoiceFields.patch(path, value),
        profile: _effectiveProfile,
      );
      if (!mounted) return;
      await _loadServerVoiceConfig(dashboard, _nativeVoiceLoadEpoch);
    } catch (_) {
      if (mounted) _snack(s.voiceServerParametersFailed);
    } finally {
      if (mounted) setState(() => _savingServerField = null);
    }
  }

  /// Abre las opciones de un campo: las que ofrece Hermes Desktop, nunca
  /// texto libre.
  Future<void> _pickServerField(String path, {String? label}) async {
    if (!_serverFieldEditable(path) || _savingServerField != null) return;
    final s = Strings.of(context);
    final language =
        ServerVoiceFields.kindOf(path) == ServerVoiceFieldKind.language;
    final stored = _serverFields.text(path);
    // Console 1.2.14 guardaba «Automático» como el texto `auto`, que el
    // proveedor rechaza: elegir Automático lo deja vacío, como Hermes espera.
    final literalAuto = language && stored?.toLowerCase() == 'auto';
    final current = language
        ? (stored == null || literalAuto ? '' : stored.toLowerCase())
        : stored;
    final picked = await showHermesOptions<String>(
      context: context,
      surfaceKey: const ValueKey('voice_field_options'),
      title: label ?? _serverFieldLabel(s, path),
      selected: current,
      options: [
        for (final option in _serverFields.options(path))
          HermesOption(
            key: ValueKey('voice_option_$option'),
            value: option,
            label: _serverOptionLabel(s, path, option),
          ),
      ],
    );
    if (picked == null || !mounted) return;
    if (picked == current && !literalAuto) return;
    await _writeServerField(path, picked);
  }

  /// Fila de un campo del servidor bajo la opción elegida.
  Widget _serverFieldRow(HermesThemeColors colors, Strings s, String path) =>
      _FieldRow(
        tapKey: ValueKey('voice_field_$path'),
        colors: colors,
        label: _serverFieldLabel(s, path),
        value: _serverFieldValue(s, path),
        onTap: _serverFieldEditable(path) ? () => _pickServerField(path) : null,
      );

  /// Bajo «Servidor Hermes», solo cuando está elegido: los campos de «Texto a
  /// voz» de Hermes Desktop (proveedor y, debajo, su modelo y su voz), probar
  /// y, si algo falla, la frase que lo dice con la acción que lo arregla.
  Widget _serverVoiceActions(HermesThemeColors colors, Strings s) {
    final hasDetails =
        !_nativeVoiceLoading &&
        !_serverVoiceFirstLoad &&
        _serverVoiceConfigError == null &&
        !_serverVoiceConfigFailed;
    final problem = _serverVoiceProblem(s);
    final routeAction = _serverRouteAction(colors, s);
    final testError = _serverVoiceTestError;
    final style = _quietButtonStyle(colors);
    return Padding(
      key: const ValueKey('voice_server_summary_card'),
      padding: const EdgeInsets.only(left: 32, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_serverFields.reports(ServerVoiceFields.speechProvider))
            _serverFieldRow(colors, s, ServerVoiceFields.speechProvider),
          for (final path in _serverFields.speechFields)
            _serverFieldRow(colors, s, path),
          if (problem != null)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 2),
              child: HermesStatusText(
                label: problem.$1,
                tone: problem.$2,
                maxLines: 3,
              ),
            ),
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ?routeAction,
              if (routeAction == null)
                OutlinedButton.icon(
                  key: const ValueKey('voice_test_server_voice'),
                  style: style,
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
                ),
              if (_serverVoiceNeedsKey && !_serverReadOnly)
                FilledButton(
                  key: const ValueKey('voice_server_add_key'),
                  onPressed: () => _addServerVoiceKey(
                    provider: _serverSpeechProvider,
                    recheck: _checkServerVoice,
                  ),
                  child: Text(s.voiceServerAddKey),
                ),
              if (hasDetails)
                TextButton(
                  key: const ValueKey('voice_server_details_toggle'),
                  style: TextButton.styleFrom(minimumSize: const Size(0, 48)),
                  onPressed: () => setState(
                    () => _serverVoiceDetailsExpanded =
                        !_serverVoiceDetailsExpanded,
                  ),
                  child: Text(
                    _serverVoiceDetailsExpanded
                        ? s.voiceServerHideDetailsAction
                        : s.voiceServerDetailsAction,
                  ),
                ),
            ],
          ),
          if (hasDetails && _serverVoiceDetailsExpanded) ...[
            const SizedBox(height: 4),
            _serverValueRow(
              colors,
              s.voiceServerDeliveryLabel,
              _serverDeliveryDescription(s),
            ),
            if (testError != null) ...[
              const SizedBox(height: 10),
              Text(
                s.voiceServerTestResponseLabel,
                style: TextStyle(color: colors.textSecondary, fontSize: 12),
              ),
              const SizedBox(height: 3),
              SelectableText(
                _serverTestFailureDetail(s, testError),
                key: const ValueKey('voice_server_test_error_detail'),
                style: TextStyle(
                  color: colors.textPrimary,
                  fontSize: 12.5,
                  height: 1.4,
                ),
              ),
            ],
            const SizedBox(height: 6),
          ],
          // La ruta del servidor empareja escuchar y hablar: se dice en una
          // línea para que «Dictado» no parezca decidir también esto.
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              _serverReadOnly
                  ? s.voiceServerReadOnly
                  : s.voiceServerAlsoListens,
              style: TextStyle(
                color: colors.textTertiary,
                fontSize: 11.5,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Proveedor y modelo con los que el servidor transcribe, en dos palabras.
  String? _serverDictationShort() {
    final provider =
        _serverFields.transcriber ?? _serverVoiceSummary?.sttProvider;
    if (provider == null) return null;
    String? model;
    for (final path in _serverFields.transcriptionFields) {
      if (ServerVoiceFields.kindOf(path) == ServerVoiceFieldKind.model) {
        model = _serverFields.text(path);
      }
    }
    return [
      _providerName(provider),
      model ?? _serverVoiceSummary?.sttModel,
    ].whereType<String>().where((part) => part.isNotEmpty).join(' · ');
  }

  /// Los campos de «Voz a texto» de Hermes Desktop para el proveedor en uso:
  /// proveedor y, debajo, su modelo y su idioma.
  List<Widget> _serverDictationFieldRows(HermesThemeColors colors, Strings s) =>
      [
        if (_serverFields.reports(ServerVoiceFields.transcriptionProvider))
          _serverFieldRow(colors, s, ServerVoiceFields.transcriptionProvider),
        for (final path in _serverFields.transcriptionFields)
          _serverFieldRow(colors, s, path),
      ];

  /// Aviso de que el servidor reconoce un idioma distinto al de la app, con
  /// la acción que deja elegir otro.
  Widget _serverLanguageMismatch(
    HermesThemeColors colors,
    Strings s,
    String warning,
  ) {
    final path = _serverFields.transcriptionLanguagePath;
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Container(
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
                warning,
                style: TextStyle(
                  color: colors.textPrimary,
                  fontSize: 11.5,
                  height: 1.3,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (path != null && !_serverReadOnly)
              TextButton(
                key: const ValueKey('voice_fix_server_language'),
                onPressed: _nativeVoiceDashboard == null
                    ? null
                    : () => _pickServerField(path),
                child: Text(s.voiceChangeLanguage),
              ),
          ],
        ),
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
          SizedBox(width: 124, child: labelWidget),
          Expanded(child: valueWidget),
        ],
      );
    },
  );

  bool get _showsGptLiveRetry =>
      kVoiceModeEnabled && _gptLiveFailure?.retryable == true;

  void _retryGptLiveStatus() {
    if (WidgetsBinding.instance.lifecycleState != null &&
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    _gptLiveStatusRequested = false;
    unawaited(_loadGptLiveStatus(_nativeVoiceDashboard!, _effectiveProfile));
  }

  Widget _blockDivider(HermesThemeColors colors) => Divider(
    height: 17,
    thickness: 1,
    color: colors.divider.withValues(alpha: 0.45),
  );

  /// Un grupo de controles con, si hace falta, su título de sección y una
  /// línea de estado. La línea solo aparece cuando algo necesita atención:
  /// mientras todo funciona, el grupo no anuncia nada.
  Widget _voiceSection({
    required Key key,
    required List<Widget> children,
    String? title,
    (String, HermesStatusTone)? status,
  }) {
    final attention =
        status != null &&
            (status.$2 == HermesStatusTone.warn ||
                status.$2 == HermesStatusTone.error)
        ? status
        : null;
    return Padding(
      key: key,
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null)
            HermesSectionHeader(
              title,
              padding: const EdgeInsets.fromLTRB(6, 4, 6, 6),
            ),
          if (attention != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: HermesStatusText(
                  label: attention.$1,
                  tone: attention.$2,
                  maxLines: 4,
                ),
              ),
            ),
          if (children.isNotEmpty)
            HermesListGroup(
              children: [
                Material(
                  type: MaterialType.transparency,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 2, 14, 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: children,
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

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
      pet: false,
      body: body,
    );
  }

  // ── Pantalla principal: una lista corta de etiqueta y valor ──────────────

  /// La fila de motor existe siempre que el servidor conoce GPT-Live: contestó
  /// a la consulta de estado, ahora o la última vez. Como en Hermes Desktop
  /// (`voice-engine-rows.tsx`), si no puede arrancarlo la opción se ve, no se
  /// puede elegir y debajo va el motivo. Un servidor sin esa consulta no
  /// enseña nada de GPT-Live.
  bool get _showsMainEngineChoice =>
      kVoiceModeEnabled && _gptLiveStatus != null;

  /// De dónde sale el dictado, en dos o tres palabras.
  String _dictationSourceLabel(Strings s) => switch (_s.sttEngine) {
    SttEngineKind.hermesServer => s.voiceModeServerTitle,
    SttEngineKind.system => s.voiceSystemLabel,
    SttEngineKind.sherpaLive ||
    SttEngineKind.whisper ||
    SttEngineKind.server => s.voiceModePhoneTitle,
  };

  /// La voz que de verdad suena: la del servidor cuando la conversación usa
  /// «Servidor Hermes», y si no la elegida en este teléfono.
  String _replyVoiceLabel(Strings s) {
    if (_usesHermesServer) {
      return _serverVoiceShort() ?? s.voiceModeServerTitle;
    }
    return _s.ttsEngine == TtsEngineKind.onnx
        ? s.voiceAppliedOnDevice(_selectedOnnxVoice.displayName)
        : _phoneVoiceShort(s);
  }

  /// Qué le falta al dictado, o null si funciona o aún no se ha comprobado.
  String? _dictationProblem(Strings s) => switch (_s.sttEngine) {
    SttEngineKind.hermesServer =>
      _nativeVoiceLoading ||
              _nativeVoiceDashboard == null ||
              _nativeVoiceCapability?.transcribe == true
          ? null
          : s.voiceProblemTapDictation(s.voiceProblemDictationServer),
    SttEngineKind.whisper =>
      !_whisperChecked || _whisperReady
          ? null
          : s.voiceProblemTapDictation(s.voiceProblemDictationModel),
    SttEngineKind.sherpaLive =>
      !_sherpaChecked || _sherpaReady.contains(_selectedSherpaModel.id)
          ? null
          : s.voiceProblemTapDictation(s.voiceProblemDictationModel),
    SttEngineKind.server || SttEngineKind.system => null,
  };

  /// Qué le falta a la voz de este teléfono, o null si funciona.
  String? _phoneVoiceProblem(Strings s) => switch (_s.ttsEngine) {
    TtsEngineKind.onnx =>
      !_onnxChecked || _onnxReady.contains(_selectedOnnxVoice.id)
          ? null
          : s.voiceProblemTapReplyVoice(s.voiceProblemVoiceModel),
    _ => null,
  };

  /// Lo único que la pantalla principal dice de estado: una frase por cada
  /// cosa que no funciona, con la fila que la arregla. Sin problemas, nada.
  List<String> _mainProblems(Strings s) {
    String sentence(String text) => text.replaceFirst(RegExp(r'[.…]+$'), '');
    final serverRoute = _usesHermesServer;
    final checking = _nativeVoiceLoading || _serverVoiceFirstLoad;
    final testError = _serverVoiceTestError;
    final language = serverRoute || _s.sttEngine == SttEngineKind.hermesServer
        ? _serverSttLanguageWarning(s)
        : null;
    // Con «Servidor Hermes» habla el servidor: la voz del teléfono no es un
    // problema de la conversación y se revisa en su propia pantalla.
    final phoneVoice = serverRoute ? null : _phoneVoiceProblem(s);
    return [
      if (serverRoute && !checking)
        if (_serverAuthRequired)
          s.voiceProblemTapReplyVoice(s.voiceProblemServerAccess)
        else if (_nativeVoiceCapability?.ok != true)
          s.voiceProblemTapReplyVoice(s.voiceProblemServerUnavailable)
        else if (testError != null)
          s.voiceProblemTapReplyVoice(_serverTestFailureSummary(s, testError)),
      if (language != null) s.voiceProblemTapReplyVoice(sentence(language)),
      ?_dictationProblem(s),
      ?phoneVoice,
    ];
  }

  /// Valor de una fila que abre una subpantalla: pegado al borde, en una
  /// línea, y sin quitarle a la etiqueta más de media fila.
  Widget _mainRowValue(HermesThemeColors colors, String value) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width.clamp(0, 720) * 0.44,
        ),
        child: Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.end,
          style: HermesType.value.copyWith(color: colors.textSecondary),
        ),
      ),
      const SizedBox(width: 2),
      Icon(Icons.chevron_right_rounded, size: 18, color: colors.textDisabled),
    ],
  );

  Widget _mainEngineRow(HermesThemeColors colors, Strings s) => Padding(
    padding: const EdgeInsets.fromLTRB(
      HermesSpace.rowH,
      12,
      HermesSpace.rowH,
      12,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          s.voiceMainConversation,
          style: HermesType.body.copyWith(color: colors.textPrimary),
        ),
        const SizedBox(height: 10),
        // Una conexión de solo lectura ve el modo, pero no lo cambia.
        IgnorePointer(
          ignoring: !_canEditChatMode,
          child: Opacity(
            opacity: _nativeVoiceConnection?.readOnly == true ? 0.5 : 1,
            child: HermesSegmentedControl<bool>(
              semanticLabel: s.voiceMainConversation,
              value: _liveSelected,
              segments: [
                HermesSegment(
                  key: const ValueKey('voice_conversation_chained'),
                  value: false,
                  label: s.voiceMainEngineNormal,
                ),
                HermesSegment(
                  key: const ValueKey('voice_gpt_live_enabled'),
                  value: true,
                  label: s.voiceGptLiveTitle,
                  enabled: !_liveUnavailable,
                ),
              ],
              onChanged: (live) => _setVoiceChatMode(
                live ? VoiceLiveMode.gptLive : VoiceLiveMode.chained,
              ),
            ),
          ),
        ),
        if (_liveUnavailable) ..._liveUnavailableLines(colors, s),
        if (_liveInUse) ..._liveSetupRows(colors, s),
      ],
    ),
  );

  /// GPT-Live es el modo del perfil y puede arrancar: entonces, y solo
  /// entonces, la fila enseña cómo configurarlo y probarlo.
  bool get _liveInUse =>
      _gptLiveStatus?.available == true &&
      _gptLiveStatus?.mode == VoiceLiveMode.gptLive;

  /// Bajo la fila con GPT-Live elegido: su voz, su personalidad y «Probar»,
  /// con el mismo patrón que la opción elegida en «Dictado» y «Voz de las
  /// respuestas». Con «Normal» elegido la fila se queda en una línea.
  List<Widget> _liveSetupRows(HermesThemeColors colors, Strings s) {
    final canWrite = _nativeVoiceDashboard != null && !_serverReadOnly;
    final voice =
        _serverFields.text(ServerVoiceFields.liveVoice) ??
        _gptLiveStatus?.voice?.trim();
    return [
      const SizedBox(height: 6),
      _FieldRow(
        tapKey: const ValueKey('voice_field_voice.gpt_live.voice'),
        colors: colors,
        label: s.voiceRowVoice,
        value: voice == null || voice.isEmpty ? '—' : voice,
        onTap: _serverFieldEditable(ServerVoiceFields.liveVoice)
            ? () => _pickServerField(ServerVoiceFields.liveVoice)
            : null,
      ),
      _FieldRow(
        tapKey: const ValueKey('voice_field_voice.gpt_live.instructions'),
        colors: colors,
        label: s.voiceRowPersonality,
        value:
            _serverFields.text(ServerVoiceFields.livePersonality) ??
            s.voicePersonalityDefault,
        onTap: canWrite ? _editLivePersonality : null,
      ),
      // Una conexión de solo lectura no puede conversar: no hay qué probar.
      if (_nativeVoiceConnection != null && !_serverReadOnly) ...[
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            key: const ValueKey('voice_live_try'),
            style: _quietButtonStyle(colors),
            onPressed: _tryLiveConversation,
            icon: const Icon(Icons.play_arrow_rounded),
            label: Text(s.voiceServerTestAction),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            s.voiceLiveTryHint,
            style: TextStyle(
              color: colors.textTertiary,
              fontSize: 11.5,
              height: 1.35,
            ),
          ),
        ),
      ],
    ];
  }

  /// «Probar» de GPT-Live es una conversación de voz de verdad, no una
  /// muestra: abre un chat nuevo del perfil activo con la conversación de voz
  /// arrancando, por el camino que ya usa el acceso de voz de la pantalla de
  /// inicio. Allí se piden el aviso de privacidad y el permiso del micrófono,
  /// y el coordinador elige GPT-Live porque es el modo del perfil.
  void _tryLiveConversation() {
    final connection = _nativeVoiceConnection;
    if (connection == null || !_liveInUse) return;
    final session = Session(
      id: generateSessionId(),
      title: Strings.of(context).drawerNewChat,
      model: 'hermes-agent',
      source: 'mobile',
      messageCount: 0,
      isActive: true,
      preview: '',
      startedAt: DateTime.now().millisecondsSinceEpoch.toDouble() / 1000,
      profile: Session.profileOwner(_effectiveProfile),
    );
    (widget.voiceTryChatOpener ?? VoiceSettingsScreen._openVoiceTryChat)(
      context,
      connection,
      session,
    );
  }

  /// Bajo la fila cuando GPT-Live no puede arrancar: una línea con el motivo
  /// en palabras llanas y, si lo que falta es la clave, el botón que la pide.
  /// Para cualquier otro motivo la línea es genérica y el texto del servidor
  /// queda detrás de «Ver detalles».
  List<Widget> _liveUnavailableLines(HermesThemeColors colors, Strings s) {
    final serverReason = _liveServerReason;
    final canAddKey =
        _liveNeedsKey && _nativeVoiceDashboard != null && !_serverReadOnly;
    return [
      const SizedBox(height: 10),
      HermesStatusText(
        key: const ValueKey('voice_live_reason'),
        label: _liveNeedsKey ? s.voiceLiveNeedsKey : s.voiceLiveUnavailable,
        // Con GPT-Live elegido la conversación no arrancará con él: es un
        // aviso. Con la conversación normal elegida solo es información.
        tone: _liveSelected ? HermesStatusTone.warn : HermesStatusTone.neutral,
        maxLines: 3,
      ),
      if (canAddKey || serverReason != null)
        Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (canAddKey)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: FilledButton(
                  key: const ValueKey('voice_live_add_key'),
                  onPressed: () => _addServerVoiceKey(
                    provider: 'openai',
                    recheck: _recheckGptLive,
                  ),
                  child: Text(s.voiceServerAddKey),
                ),
              ),
            if (serverReason != null)
              TextButton(
                key: const ValueKey('voice_live_reason_toggle'),
                style: TextButton.styleFrom(minimumSize: const Size(0, 48)),
                onPressed: () =>
                    setState(() => _liveReasonExpanded = !_liveReasonExpanded),
                child: Text(
                  _liveReasonExpanded
                      ? s.voiceServerHideDetailsAction
                      : s.voiceServerDetailsAction,
                ),
              ),
          ],
        ),
      if (serverReason != null && _liveReasonExpanded)
        SelectableText(
          serverReason,
          key: const ValueKey('voice_live_reason_detail'),
          style: TextStyle(
            color: colors.textPrimary,
            fontSize: 12.5,
            height: 1.4,
          ),
        ),
    ];
  }

  Future<void> _openPage(_VoicePage page) async {
    final route = MaterialPageRoute<void>(
      builder: (_) => _VoiceSubPage(owner: this, page: page),
    );
    _openPages.add(route);
    try {
      await Navigator.of(context).push<void>(route);
    } finally {
      _openPages.remove(route);
    }
  }

  Widget _pageList(
    List<Widget> children, {
    Key? key,
    ScrollController? controller,
  }) => ListView(
    clipBehavior: hermesUnderHeader,
    key: key,
    controller: controller,
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
              children: children,
            ),
          ),
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final voice = _voice;
    return Scaffold(
      backgroundColor: colors.background,
      appBar: HermesAppBar(
        // Sin estilo local: hereda el titleTextStyle del tema, como Ajustes y
        // Notificaciones (spec 028 A-203).
        title: Text(s.voiceTitle),
      ),
      body: _wrapWithDock(
        context,
        _pageList(controller: _scrollController, [
          for (final problem in _mainProblems(s))
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 0, 6, 10),
              child: Align(
                alignment: Alignment.centerLeft,
                child: HermesStatusText(
                  label: problem,
                  tone: HermesStatusTone.warn,
                  maxLines: 3,
                ),
              ),
            ),
          HermesListGroup(
            key: const ValueKey('voice_main_list'),
            dividerIndent: HermesSpace.rowH,
            children: [
              if (_showsMainEngineChoice) _mainEngineRow(colors, s),
              HermesListRow(
                key: const ValueKey('voice_main_dictation'),
                title: s.voiceMainDictation,
                trailing: _mainRowValue(colors, _dictationSourceLabel(s)),
                onTap: () => _openPage(_VoicePage.dictation),
              ),
              HermesListRow(
                key: const ValueKey('voice_main_reply_voice'),
                title: s.voiceMainReplyVoice,
                trailing: _mainRowValue(colors, _replyVoiceLabel(s)),
                onTap: () => _openPage(_VoicePage.speech),
              ),
              HermesToggleRow(
                title: s.voiceAutoSpeakTitle,
                value: _s.autoSpeak,
                switchKey: const ValueKey('voice_auto_speak'),
                onChanged: (value) => _update(_s.copyWith(autoSpeak: value)),
              ),
              HermesToggleRow(
                title: s.voiceContinueLockedSettingTitle,
                value: voice?.continueVoiceWhenLocked ?? false,
                switchKey: const ValueKey('voice_continue_when_locked'),
                onChanged: voice == null ? null : _setContinueWhenLocked,
              ),
              HermesListRow(
                key: const ValueKey('voice_main_advanced'),
                title: s.voiceBlockAdvanced,
                onTap: () => _openPage(_VoicePage.advanced),
              ),
            ],
          ),
        ]),
      ),
    );
  }

  // ── Subpantallas ─────────────────────────────────────────────────────────

  Widget _buildPage(BuildContext context, _VoicePage page) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final (title, children) = switch (page) {
      _VoicePage.dictation => (s.voiceMainDictation, _dictationPage(colors, s)),
      _VoicePage.speech => (s.voiceMainReplyVoice, _speechPage(colors, s)),
      _VoicePage.advanced => (s.voiceBlockAdvanced, _advancedPage(colors, s)),
    };
    return Scaffold(
      backgroundColor: colors.background,
      appBar: HermesAppBar(title: Text(title)),
      body: _wrapWithDock(
        context,
        _pageList(key: ValueKey('voice_page_${page.name}'), children),
      ),
    );
  }

  /// «Dictado»: Servidor Hermes o este teléfono. Solo la opción elegida
  /// enseña sus filas; la otra queda en una línea con lo que usaría.
  List<Widget> _dictationPage(HermesThemeColors colors, Strings s) {
    final serverDisabled = _nativeVoiceLoading || _nativeVoiceDashboard == null;
    final hermesDictation = _s.sttEngine == SttEngineKind.hermesServer;
    final canTranscribe = _nativeVoiceCapability?.transcribe == true;
    final languageWarning = hermesDictation
        ? _serverSttLanguageWarning(s)
        : null;
    return [
      _voiceSection(
        key: const ValueKey('voice_listening_section'),
        children: [
          _RadioRow(
            tapKey: const ValueKey('voice_dictation_server_option'),
            colors: colors,
            title: s.voiceModeServerTitle,
            value: _serverDictationShort(),
            selected: hermesDictation,
            enabled: hermesDictation || (!serverDisabled && canTranscribe),
            onTap: () => _selectHermesDictation(true),
          ),
          if (hermesDictation)
            Padding(
              key: const ValueKey('voice_dictation_server_fields'),
              padding: const EdgeInsets.only(left: 32, bottom: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ..._serverDictationFieldRows(colors, s),
                  if (!serverDisabled && !canTranscribe)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: HermesStatusText(
                        label: s.voiceProblemDictationServer,
                        tone: HermesStatusTone.warn,
                        maxLines: 3,
                      ),
                    ),
                ],
              ),
            ),
          if (languageWarning != null)
            _serverLanguageMismatch(colors, s, languageWarning),
          _blockDivider(colors),
          _RadioRow(
            tapKey: const ValueKey('voice_dictation_phone_option'),
            colors: colors,
            title: s.voiceModePhoneTitle,
            value: _phoneDictationName(s),
            selected: !hermesDictation,
            onTap: () => _selectHermesDictation(false),
          ),
          if (!hermesDictation) _phoneDictationRows(colors, s),
        ],
      ),
    ];
  }

  static String _whisperName(SttModelSize size) =>
      size == SttModelSize.tiny ? 'Whisper tiny' : 'Whisper base';

  static int _whisperSizeMb(SttModelSize size) =>
      size == SttModelSize.tiny ? 75 : 142;

  /// El modelo de dictado del teléfono, con su nombre a secas.
  String _phoneDictationName(Strings s) => switch (_phoneDictationEngine) {
    SttEngineKind.whisper => _whisperName(_s.whisperModel),
    SttEngineKind.system => s.voiceSystemLabel,
    _ => _selectedSherpaModel.displayName,
  };

  static const String _androidDictation = 'system';

  String get _phoneDictationId => switch (_phoneDictationEngine) {
    SttEngineKind.whisper => 'whisper:${_s.whisperModel.id}',
    SttEngineKind.system => _androidDictation,
    _ => 'sherpa:${_selectedSherpaModel.id}',
  };

  /// Un solo selector para el dictado del teléfono: los modelos que escriben
  /// mientras hablas, el reconocedor de Android y los que transcriben al
  /// terminar. Un modelo que aún no está en el teléfono se descarga al
  /// elegirlo y pasa a ser el elegido cuando termina.
  Future<void> _pickPhoneDictation() async {
    final s = Strings.of(context);
    final picked = await showHermesOptions<String>(
      context: context,
      surfaceKey: const ValueKey('voice_phone_dictation_options'),
      title: s.voiceRowModel,
      selected: _phoneDictationId,
      options: [
        for (final model in kSherpaSttModels)
          HermesOption(
            key: ValueKey('voice_option_sherpa_${model.id}'),
            value: 'sherpa:${model.id}',
            label: model.displayName,
            subtitle: _sherpaReady.contains(model.id)
                ? null
                : s.voiceNeedsDownload('${model.sizeMb}'),
            group: s.voiceSherpaLiveLabel,
          ),
        HermesOption(
          key: const ValueKey('voice_option_system'),
          value: _androidDictation,
          label: s.voiceSystemLabel,
          group: s.voiceSherpaLiveLabel,
        ),
        for (final size in SttModelSize.values)
          HermesOption(
            key: ValueKey('voice_option_whisper_${size.id}'),
            value: 'whisper:${size.id}',
            label: _whisperName(size),
            group: s.voiceWhisperLabel,
          ),
      ],
    );
    if (picked == null || !mounted) return;
    if (picked == _androidDictation) {
      _lastPhoneDictation = SttEngineKind.system;
      await _selectEngine(stt: SttEngineKind.system);
      return;
    }
    for (final size in SttModelSize.values) {
      if (picked != 'whisper:${size.id}') continue;
      _lastPhoneDictation = SttEngineKind.whisper;
      await _update(
        _s.copyWith(sttEngine: SttEngineKind.whisper, whisperModel: size),
      );
      // Solo se sabe si está descargado el tamaño elegido.
      final ready = await _voice?.whisperModelReady() ?? false;
      if (mounted) setState(() => _whisperReady = ready);
      return;
    }
    for (final model in kSherpaSttModels) {
      if (picked != 'sherpa:${model.id}') continue;
      if (!_sherpaReady.contains(model.id)) {
        await _downloadSherpa(model, select: true);
        return;
      }
      _lastPhoneDictation = SttEngineKind.sherpaLive;
      await _update(
        _s.copyWith(
          sttEngine: SttEngineKind.sherpaLive,
          sherpaModel: model.kind,
        ),
      );
      return;
    }
  }

  /// Una descarga en curso: qué se descarga, cuánto lleva y cómo pararla.
  Widget _downloadProgress(
    HermesThemeColors colors,
    Strings s, {
    required Key key,
    required String label,
    VoidCallback? onCancel,
  }) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: 48),
    child: Row(
      children: [
        Expanded(
          child: Text(
            label,
            key: key,
            style: TextStyle(
              color: colors.textSecondary,
              fontSize: 12.5,
              height: 1.35,
            ),
          ),
        ),
        if (onCancel != null)
          TextButton(onPressed: onCancel, child: Text(s.commonCancel)),
      ],
    ),
  );

  /// Bajo «En este teléfono» en «Dictado»: el modelo y, en la misma fila de
  /// acciones, lo único que toca hacer con él (descargarlo, cancelar o
  /// quitarlo del teléfono).
  Widget _phoneDictationRows(HermesThemeColors colors, Strings s) {
    final engine = _phoneDictationEngine;
    final model = _selectedSherpaModel;
    SherpaSttModel? busy;
    for (final candidate in kSherpaSttModels) {
      if (candidate.id == _sherpaBusyId) busy = candidate;
    }
    final downloaded =
        engine == SttEngineKind.sherpaLive && _sherpaReady.contains(model.id);
    final missing = switch (engine) {
      SttEngineKind.sherpaLive => _sherpaChecked && !downloaded,
      SttEngineKind.whisper => _whisperChecked && !_whisperReady,
      _ => false,
    };
    final sizeMb = engine == SttEngineKind.whisper
        ? _whisperSizeMb(_s.whisperModel)
        : model.sizeMb;
    final style = _quietButtonStyle(colors);
    const progressKey = ValueKey('voice_phone_dictation_progress');
    return Padding(
      key: const ValueKey('voice_phone_dictation_picker'),
      padding: const EdgeInsets.only(left: 32, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _FieldRow(
            tapKey: const ValueKey('voice_phone_dictation_model'),
            colors: colors,
            label: s.voiceRowModel,
            value: _phoneDictationName(s),
            onTap: busy != null || _downloading ? null : _pickPhoneDictation,
          ),
          if (busy != null)
            _downloadProgress(
              colors,
              s,
              key: progressKey,
              label:
                  '${busy.displayName} · '
                  '${_sherpaPhase == SherpaPrepPhase.downloading ? s.voiceDownloadingPct((_sherpaProgress * 100).toStringAsFixed(0)) : s.voiceExtracting}',
              onCancel: _sherpaPhase == SherpaPrepPhase.downloading
                  ? () => _cancelSherpa(busy!)
                  : null,
            )
          else if (_downloading)
            _downloadProgress(
              colors,
              s,
              key: progressKey,
              label:
                  '${_whisperName(_s.whisperModel)} · '
                  '${s.voiceDownloadingPct((_progress * 100).toStringAsFixed(0))}',
            )
          else if (missing)
            OutlinedButton.icon(
              key: const ValueKey('voice_phone_dictation_download'),
              style: style,
              onPressed: engine == SttEngineKind.whisper
                  ? _downloadWhisper
                  : () => _downloadSherpa(model),
              icon: const Icon(Icons.download_rounded),
              label: Text('${s.voiceDownloadAction} · $sizeMb MB'),
            )
          else if (downloaded)
            TextButton(
              key: const ValueKey('voice_phone_dictation_delete'),
              onPressed: () => _deleteSherpa(model),
              child: Text(s.voiceRemoveDownload),
            ),
        ],
      ),
    );
  }

  /// «Voz de las respuestas»: la misma pregunta que «Dictado». La voz sale
  /// del servidor Hermes o de este teléfono; solo la opción elegida enseña
  /// sus filas. Es la ruta por conexión y perfil (`NativeVoiceModeStore`).
  List<Widget> _speechPage(HermesThemeColors colors, Strings s) {
    final serverRoute = _usesHermesServer;
    final hasConnection = _nativeVoiceConnection != null;
    final serverDisabled = _nativeVoiceLoading || _nativeVoiceDashboard == null;
    final languageWarning = serverRoute ? _serverSttLanguageWarning(s) : null;
    return [
      _voiceSection(
        key: const ValueKey('voice_reading_section'),
        children: [
          _RadioRow(
            tapKey: const ValueKey('voice_mode_server_option'),
            colors: colors,
            title: s.voiceModeServerTitle,
            value: _serverVoiceShort(),
            selected: serverRoute,
            enabled: serverRoute || !serverDisabled,
            onTap: () => _selectNativeVoice(true),
          ),
          if (serverRoute) _serverVoiceActions(colors, s),
          if (!hasConnection || (!_nativeVoiceLoading && serverDisabled))
            Padding(
              padding: const EdgeInsets.only(left: 32, bottom: 8),
              child: Text(
                hasConnection
                    ? s.voiceServerConfigUnavailable
                    : s.voiceServerNoConnection,
                style: TextStyle(
                  color: colors.textTertiary,
                  fontSize: 11.5,
                  height: 1.35,
                ),
              ),
            ),
          if (languageWarning != null)
            _serverLanguageMismatch(colors, s, languageWarning),
          _blockDivider(colors),
          _RadioRow(
            tapKey: const ValueKey('voice_mode_phone_option'),
            colors: colors,
            title: s.voiceModePhoneTitle,
            value: _phoneVoiceShort(s),
            selected: !serverRoute,
            onTap: () => _selectNativeVoice(false),
          ),
          if (!serverRoute) _phoneVoiceRows(colors, s),
        ],
      ),
    ];
  }

  static const String _androidVoice = 'android';

  /// Un solo selector para la voz del teléfono: la de Android y las
  /// descargables, por su nombre. Una voz que aún no está en el teléfono se
  /// descarga al elegirla y pasa a ser la elegida cuando termina.
  Future<void> _pickPhoneVoice() async {
    final s = Strings.of(context);
    final picked = await showHermesOptions<String>(
      context: context,
      surfaceKey: const ValueKey('voice_phone_voice_options'),
      title: s.voiceRowVoice,
      selected: _s.ttsEngine == TtsEngineKind.onnx
          ? _s.onnxVoiceId
          : _androidVoice,
      options: [
        HermesOption(
          key: const ValueKey('voice_phone_voice_android'),
          value: _androidVoice,
          label: s.voiceDeviceLabel,
        ),
        for (final voice in kNeuralVoices)
          HermesOption(
            key: ValueKey('voice_phone_voice_${voice.id}'),
            value: voice.id,
            label: voice.displayName,
            subtitle: _onnxReady.contains(voice.id)
                ? null
                : s.voiceNeedsDownload('${voice.sizeMb}'),
          ),
      ],
    );
    if (picked == null || !mounted) return;
    if (picked == _androidVoice) {
      await _selectEngine(tts: TtsEngineKind.device);
      return;
    }
    final voice = neuralVoiceById(picked);
    if (voice == null) return;
    if (!_onnxReady.contains(voice.id)) {
      await _downloadOnnx(voice, select: true);
      return;
    }
    await _update(
      _s.copyWith(ttsEngine: TtsEngineKind.onnx, onnxVoiceId: voice.id),
    );
  }

  /// Bajo «En este teléfono» en «Voz de las respuestas»: la voz y, en la
  /// misma fila de acciones, probarla o lo que haga falta antes (descargarla,
  /// cancelar) y quitarla del teléfono.
  Widget _phoneVoiceRows(HermesThemeColors colors, Strings s) {
    final neural = _s.ttsEngine == TtsEngineKind.onnx;
    final selected = _selectedOnnxVoice;
    final busyId = _onnxBusyVoiceId;
    final busy = busyId == null ? null : neuralVoiceById(busyId);
    final downloaded = neural && _onnxReady.contains(selected.id);
    final missing = neural && _onnxChecked && !downloaded;
    final idle = !_testingVoice && _onnxDeletingVoiceId == null;
    final style = _quietButtonStyle(colors);
    return Padding(
      key: const ValueKey('voice_phone_voice_picker'),
      padding: const EdgeInsets.only(left: 32, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _FieldRow(
            tapKey: const ValueKey('voice_phone_voice'),
            colors: colors,
            label: s.voiceRowVoice,
            value: _phoneVoiceShort(s),
            onTap: busy == null && idle ? _pickPhoneVoice : null,
          ),
          if (busy != null)
            _downloadProgress(
              colors,
              s,
              key: const ValueKey('voice_phone_voice_progress'),
              label:
                  '${busy.displayName} · '
                  '${_onnxPhase == TtsPrepPhase.downloading ? s.voiceDownloadingPct((_onnxProgress * 100).toStringAsFixed(0)) : s.voicePreparingVoice}',
              onCancel: _onnxPhase == TtsPrepPhase.downloading
                  ? () => _cancelOnnx(busy)
                  : null,
            )
          else
            Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (missing)
                  OutlinedButton.icon(
                    key: const ValueKey('voice_phone_voice_download'),
                    style: style,
                    onPressed: () => _downloadOnnx(selected),
                    icon: const Icon(Icons.download_rounded),
                    label: Text(
                      '${s.voiceDownloadAction} · ${selected.sizeMb} MB',
                    ),
                  )
                else
                  OutlinedButton.icon(
                    key: const ValueKey('voice_setup_test_action'),
                    style: style,
                    onPressed: _testingVoice ? null : _testVoice,
                    icon: _testingVoice
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.play_arrow_rounded),
                    label: Text(
                      _testingVoice
                          ? s.voiceTestPreparing
                          : s.voiceServerTestAction,
                    ),
                  ),
                if (downloaded)
                  TextButton(
                    key: const ValueKey('voice_phone_voice_delete'),
                    onPressed: idle ? () => _deleteOnnx(selected) : null,
                    child: Text(s.voiceRemoveDownload),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  // ── Avanzado ─────────────────────────────────────────────────────────────

  /// Valor de una fila que no se puede cambiar aquí: sin flecha.
  Widget _fixedRowValue(HermesThemeColors colors, String value) =>
      ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width.clamp(0, 720) * 0.44,
        ),
        child: Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.end,
          style: HermesType.value.copyWith(color: colors.textSecondary),
        ),
      );

  /// Fila de «Avanzado»: etiqueta y valor, como las de la pantalla principal.
  Widget _advancedRow(
    HermesThemeColors colors, {
    required Key key,
    required String title,
    required String value,
    VoidCallback? onTap,
  }) => HermesListRow(
    key: key,
    title: title,
    trailing: onTap == null
        ? _fixedRowValue(colors, value)
        : _mainRowValue(colors, value),
    onTap: onTap,
    showChevron: false,
  );

  /// Un campo de Hermes Desktop como fila de «Avanzado».
  Widget _advancedFieldRow(HermesThemeColors colors, Strings s, String path) =>
      _advancedRow(
        colors,
        key: ValueKey('voice_field_$path'),
        title: _serverFieldLabel(s, path),
        value: _serverFieldValue(s, path),
        onTap: _serverFieldEditable(path) ? () => _pickServerField(path) : null,
      );

  /// Un interruptor de Hermes Desktop. Solo se enseña cuando el servidor da
  /// su valor: sin él no se sabe si está encendido.
  Widget _advancedToggle(String path, String title) => HermesToggleRow(
    title: title,
    value: _serverFields.flag(path) ?? false,
    switchKey: ValueKey('voice_field_$path'),
    onChanged: _nativeVoiceDashboard == null || _serverReadOnly
        ? null
        : (value) => _writeServerField(path, value),
  );

  Future<void> _pickMaxRecording() async {
    final s = Strings.of(context);
    final current = _serverFields
        .number(ServerVoiceFields.maxRecordingSeconds)
        ?.round();
    final offered = {...kServerMaxRecordingSeconds, ?current}.toList()..sort();
    final picked = await showHermesOptions<int>(
      context: context,
      surfaceKey: const ValueKey('voice_field_options'),
      title: s.voiceRowMaxRecording,
      selected: current,
      options: [
        for (final seconds in offered)
          HermesOption(
            key: ValueKey('voice_option_$seconds'),
            value: seconds,
            label: s.voiceSecondsValue('$seconds'),
          ),
      ],
    );
    if (picked == null || picked == current || !mounted) return;
    await _writeServerField(ServerVoiceFields.maxRecordingSeconds, picked);
  }

  /// La personalidad de GPT-Live es texto en Hermes Desktop: se escribe en un
  /// diálogo y se guarda como el resto de campos.
  Future<void> _editLivePersonality() async {
    final s = Strings.of(context);
    final before = _serverFields.text(ServerVoiceFields.livePersonality) ?? '';
    var typed = before;
    final save = await showHermesFormDialog<bool>(
      context: context,
      surfaceKey: const ValueKey('voice_live_personality_dialog'),
      title: s.voiceRowLivePersonality,
      actions: [
        HermesDialogAction(
          value: false,
          label: s.commonCancel,
          style: HermesDialogActionStyle.cancel,
        ),
        HermesDialogAction(
          key: const ValueKey('voice_live_personality_save'),
          value: true,
          label: s.commonSave,
        ),
      ],
      body: (context, setState) => _TextAreaField(
        fieldKey: const ValueKey('voice_live_personality_field'),
        initial: before,
        hint: s.voicePersonalityHint,
        onChanged: (value) => typed = value,
      ),
    );
    if (save != true || !mounted || typed.trim() == before) return;
    await _writeServerField(ServerVoiceFields.livePersonality, typed.trim());
  }

  Widget _advancedSection({
    required Key key,
    required String title,
    required List<Widget> rows,
    (String, HermesStatusTone)? status,
    Widget? footer,
  }) => Padding(
    key: key,
    padding: const EdgeInsets.only(bottom: 18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        HermesSectionHeader(
          title,
          padding: const EdgeInsets.fromLTRB(6, 4, 6, 6),
        ),
        if (status != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: HermesStatusText(
                label: status.$1,
                tone: status.$2,
                maxLines: 4,
              ),
            ),
          ),
        HermesListGroup(dividerIndent: HermesSpace.rowH, children: rows),
        ?footer,
      ],
    ),
  );

  /// «Avanzado»: los campos de Hermes Desktop que no están ya en la pantalla
  /// principal (el modo de conversación y, con GPT-Live, su voz y su
  /// personalidad), en «Dictado» ni en «Voz de las respuestas», como filas
  /// sin explicación, bajo sus mismos títulos, y los dos interruptores
  /// propios del teléfono. Un campo que el servidor no da no se enseña.
  List<Widget> _advancedPage(HermesThemeColors colors, Strings s) {
    final fields = _serverFields;
    final canWrite = _nativeVoiceDashboard != null && !_serverReadOnly;
    // Con el dictado en el servidor estos campos ya están en «Dictado». Aquí
    // solo hacen falta cuando el servidor escucha la conversación de voz y el
    // dictado es del teléfono.
    final serverListensOnly =
        _usesHermesServer && _s.sttEngine != SttEngineKind.hermesServer;
    return [
      _advancedSection(
        key: const ValueKey('voice_conversation_section'),
        title: s.voiceBlockConversation,
        // El modo se elige en la pantalla principal; aquí solo se dice si no
        // se pudo comprobar, junto al reintento.
        status: kVoiceModeEnabled ? _gptLiveProbeProblem(s) : null,
        rows: [
          if (fields.reports(ServerVoiceFields.maxRecordingSeconds))
            _advancedRow(
              colors,
              key: const ValueKey('voice_field_voice.max_recording_seconds'),
              title: s.voiceRowMaxRecording,
              value: _serverFieldValue(
                s,
                ServerVoiceFields.maxRecordingSeconds,
              ),
              onTap: canWrite ? _pickMaxRecording : null,
            ),
          HermesToggleRow(
            title: s.voiceBargeInTitle,
            value: _s.bargeInEnabled,
            switchKey: const ValueKey('voice_barge_in_enabled'),
            onChanged: _voice == null
                ? null
                : (value) => _update(_s.copyWith(bargeInEnabled: value)),
          ),
        ],
        footer: _showsGptLiveRetry
            ? Row(
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: Text(
                        s.voiceEngineProbeFailed,
                        style: TextStyle(
                          color: colors.textSecondary,
                          fontSize: 12,
                          height: 1.35,
                        ),
                      ),
                    ),
                  ),
                  TextButton(
                    key: const ValueKey('voice_gpt_live_retry'),
                    onPressed: _nativeVoiceDashboard == null
                        ? null
                        : _retryGptLiveStatus,
                    child: Text(s.chaVoiceRetry),
                  ),
                ],
              )
            : null,
      ),
      _advancedSection(
        key: const ValueKey('voice_stt_advanced'),
        title: s.voiceBlockTranscription,
        rows: [
          if (fields.flag(ServerVoiceFields.transcription) != null)
            _advancedToggle(
              ServerVoiceFields.transcription,
              s.voiceBlockTranscription,
            ),
          if (fields.flag(ServerVoiceFields.echoTranscripts) != null)
            _advancedToggle(ServerVoiceFields.echoTranscripts, s.voiceRowEcho),
          if (fields.flag(ServerVoiceFields.liveTranscription) != null)
            _advancedToggle(
              ServerVoiceFields.liveTranscription,
              s.voiceRowLiveTranscription,
            ),
          if (serverListensOnly) ...[
            if (fields.reports(ServerVoiceFields.transcriptionProvider))
              _advancedFieldRow(
                colors,
                s,
                ServerVoiceFields.transcriptionProvider,
              ),
            for (final path in fields.transcriptionFields)
              _advancedFieldRow(colors, s, path),
          ],
          HermesToggleRow(
            title: s.voiceVadTitle,
            value: _s.vadEnabled,
            switchKey: const ValueKey('voice_vad_enabled'),
            onChanged: (value) => _update(_s.copyWith(vadEnabled: value)),
          ),
        ],
      ),
    ];
  }
}

/// Fila de un campo bajo la opción elegida: etiqueta, valor y, si se puede
/// cambiar, la flecha que abre sus opciones.
class _FieldRow extends StatelessWidget {
  final HermesThemeColors colors;
  final Key? tapKey;
  final String label;
  final String value;
  final VoidCallback? onTap;
  const _FieldRow({
    required this.colors,
    required this.label,
    required this.value,
    this.tapKey,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) => Semantics(
    button: onTap != null,
    child: InkWell(
      key: tapKey,
      onTap: onTap,
      borderRadius: BorderRadius.circular(HermesRadii.chip),
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsets.symmetric(vertical: 6),
        // La etiqueta ocupa lo que sobra y el valor queda pegado al borde,
        // en una línea y sin pasar de algo más de media fila.
        child: LayoutBuilder(
          builder: (context, constraints) => Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 14,
                    height: 1.3,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: constraints.maxWidth * 0.6,
                ),
                child: Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.end,
                  style: TextStyle(
                    color: colors.textSecondary,
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
              ),
              if (onTap != null) ...[
                const SizedBox(width: 2),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 18,
                  color: colors.textTertiary,
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}

/// Campo de varias líneas para un texto largo que no es secreto. Es dueño de
/// su controlador: el texto solo sale por [onChanged].
class _TextAreaField extends StatefulWidget {
  final Key fieldKey;
  final String initial;
  final String hint;
  final ValueChanged<String> onChanged;
  const _TextAreaField({
    required this.fieldKey,
    required this.initial,
    required this.hint,
    required this.onChanged,
  });

  @override
  State<_TextAreaField> createState() => _TextAreaFieldState();
}

class _TextAreaFieldState extends State<_TextAreaField> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return TextField(
      key: widget.fieldKey,
      controller: _controller,
      autofocus: true,
      minLines: 3,
      maxLines: 8,
      textCapitalization: TextCapitalization.sentences,
      onChanged: widget.onChanged,
      style: TextStyle(color: colors.textPrimary, fontSize: 14, height: 1.4),
      decoration: InputDecoration(
        isDense: true,
        hintText: widget.hint,
        hintStyle: TextStyle(color: colors.textTertiary, fontSize: 13.5),
        filled: true,
        fillColor: colors.surfaceVariant.withValues(alpha: 0.3),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

/// Fila de opción única: radio, título y, a la derecha, lo que esa opción
/// usa ahora. «Dictado» y «Voz de las respuestas» la comparten para que la
/// elección se lea igual en las dos pantallas.
class _RadioRow extends StatelessWidget {
  final HermesThemeColors colors;
  final Key? tapKey;
  final String title;

  /// Valor actual de la opción (la voz que usa), a la derecha del título.
  final String? value;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;
  const _RadioRow({
    required this.colors,
    required this.title,
    required this.selected,
    required this.onTap,
    this.tapKey,
    this.value,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final value = this.value;
    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      child: InkWell(
        key: tapKey,
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(HermesRadii.chip),
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: 20,
                color: !enabled
                    ? colors.textDisabled
                    : selected
                    ? colors.accent
                    : colors.textSecondary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    color: enabled ? colors.textPrimary : colors.textDisabled,
                    fontSize: 14,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    height: 1.3,
                  ),
                ),
              ),
              if (value != null && value.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 10, top: 1),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 170),
                    child: Text(
                      value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.end,
                      style: TextStyle(
                        color: colors.textSecondary,
                        fontSize: 13,
                        height: 1.4,
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
}

/// Campo único y oculto para escribir una clave. Es dueño de su controlador:
/// el texto solo sale por [onChanged] y desaparece con el diálogo.
class _SecretField extends StatefulWidget {
  final Key fieldKey;
  final String hint;
  final ValueChanged<String> onChanged;
  const _SecretField({
    required this.fieldKey,
    required this.hint,
    required this.onChanged,
  });

  @override
  State<_SecretField> createState() => _SecretFieldState();
}

class _SecretFieldState extends State<_SecretField> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return TextField(
      key: widget.fieldKey,
      controller: _controller,
      autofocus: true,
      obscureText: true,
      autocorrect: false,
      enableSuggestions: false,
      onChanged: widget.onChanged,
      style: TextStyle(color: colors.textPrimary, fontSize: 14),
      decoration: InputDecoration(
        isDense: true,
        hintText: widget.hint,
        hintStyle: TextStyle(color: colors.textTertiary, fontSize: 13.5),
        filled: true,
        fillColor: colors.surfaceVariant.withValues(alpha: 0.3),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}
