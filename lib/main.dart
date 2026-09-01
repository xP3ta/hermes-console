import 'dart:async';
import 'dart:io';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'core/app_header_title.dart';
import 'core/companion/data/companion_preferences.dart';
import 'core/companion/data/companion_repository.dart';
import 'core/companion/hatch/mock_hatch_provider.dart';
import 'core/companion/state/companion_controller.dart';
import 'core/companion/state/companion_presence_controller.dart';
import 'core/config/flavor.dart';
import 'core/models/new_session_launch_action.dart';
import 'core/models/home_widget_snapshot.dart';
import 'core/navigation/chat_route.dart';
import 'core/screens/chat_screen.dart';
import 'core/screens/home_dashboard_screen.dart';
import 'core/screens/mission_control_screen.dart';
import 'core/screens/session_list_screen.dart';
import 'core/screens/runs_screen.dart';

import 'core/screens/tasks_screen.dart';
import 'core/services/run_registry.dart';
import 'core/screens/lock_screen.dart';
import 'core/screens/instance_edit_screen.dart';
import 'core/screens/onboarding_screen.dart';
import 'core/screens/splash_screen.dart';
import 'core/services/pairing_link.dart';
import 'core/services/pairing_link_delivery_gate.dart';
import 'core/services/active_chat_service.dart';
import 'core/services/android_launch_action_inbox.dart';
import 'core/services/android_share_inbox.dart';
import 'core/services/app_lock.dart';
import 'core/services/approval_policy.dart';
import 'core/services/bridge_manager.dart';
import 'core/services/chat_draft_store.dart';
import 'core/services/connection_manager.dart';
import 'core/services/font_size_service.dart';
import 'core/services/home_widget_publisher.dart';
import 'core/services/notifications/background_listener.dart';
import 'core/services/notifications/notification_service.dart';
import 'core/services/new_session_launch_coordinator.dart';
import 'core/services/profile_pet_service.dart';
import 'core/services/platform/native_appearance.dart';
import 'core/services/secure_storage.dart';
import 'core/services/screen_security.dart';
import 'core/services/sftp_transfer_service.dart';
import 'core/services/ssh_manager.dart';
import 'core/services/ssh_session_service.dart';
import 'core/services/tui_gateway_client.dart';
import 'core/services/voice/conversation/local_voice_conversation_controller.dart';
import 'core/services/voice/read_aloud_session.dart';
import 'core/services/voice/voice_phase.dart';
import 'core/services/voice/voice_latency_trace.dart';
import 'core/services/voice/voice_service.dart';
import 'core/services/voice/voice_settings.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/component_profile.dart';
import 'core/theme/scroll_behavior.dart';
import 'core/theme/theme_profile_store.dart';
import 'core/widgets/attachment_source_sheet.dart';
import 'core/widgets/hermes_floating_notice.dart';
import 'core/widgets/hermes_premium_ui.dart';
import 'l10n/app_localizations.dart';

/// Observador global de rutas. Lo usa [ChatScreen] (vía RouteAware) para saber
/// cuándo su pantalla es la visible en pila y fijar/limpiar
/// [NotificationService.visibleSessionId]. Así la app sabe qué chat estás
/// mirando y no duplica notificaciones del sistema con la UI inline (Regla 1/6).
final RouteObserver<PageRoute<dynamic>> hermesRouteObserver =
    RouteObserver<PageRoute<dynamic>>();

@visibleForTesting
bool shouldReplaceInAppNotice(
  NotificationKind? current,
  NotificationKind incoming,
) =>
    current != NotificationKind.approval ||
    incoming == NotificationKind.approval;

@visibleForTesting
Duration? inAppNoticeAutoDismissDelay(NotificationKind kind) =>
    kind == NotificationKind.approval ? null : const Duration(seconds: 7);

@visibleForTesting
MissionControlOpenTarget? missionControlTargetForNotification(
  NotificationOpen open,
) => switch (open.surface) {
  NotificationChatSurface.bot => MissionControlOpenTarget.bot(
    sessionId: open.sessionId,
    profile: open.profile?.trim() ?? '',
  ),
  NotificationChatSurface.room => MissionControlOpenTarget.room(
    sessionId: open.sessionId,
    roomId: open.roomId?.trim() ?? '',
    profile: open.profile?.trim(),
  ),
  NotificationChatSurface.normal => null,
};

@visibleForTesting
Future<T?> pushNotificationOwnerRoute<T>(
  NavigatorState navigator,
  Route<T> route,
) => navigator.pushAndRemoveUntil(route, (candidate) => candidate.isFirst);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kVoiceRuntimeEnabled) {
    FlutterForegroundTask.initCommunicationPort();
  }
  final prefs = await SharedPreferences.getInstance();
  final themeProfileStore = ThemeProfileStore(prefs);
  final initialThemeProfiles = await themeProfileStore.load();
  final cancelledTurnStore = CancelledTurnTombstoneStore.secure();
  await cancelledTurnStore.initialize();
  final connManager = await ConnectionManager.create(
    prefs,
    clearCancelledTurns: cancelledTurnStore.removeConnection,
  );
  // Arranque en frío: si el usuario fijó una instancia predeterminada, la app
  // abre con ella (sembrándola como activa). El cambio de instancia en caliente
  // se sigue respetando durante la sesión.
  await connManager.applyDefaultOnLaunch();
  final appLock = AppLockService(prefs);
  final approvalPolicy = ApprovalPolicyService(prefs);
  final fontSize = FontSizeService(prefs);
  final bridgeManager = BridgeManager(SecureStorage(), connManager);
  final sshManager = SshManager(SecureStorage(), connManager);
  final notifications = NotificationService(prefs);
  await ScreenSecurityService(prefs).apply();
  final sftpTransfers = SftpTransferService(sshManager, notifications);
  final sshSessions = SshSessionService(sshManager);
  final activeChats = ActiveChatService(
    notifications: notifications,
    policy: approvalPolicy,
    prefs: prefs,
    cancelledTurnStore: cancelledTurnStore,
  );
  runApp(
    HermesApp(
      connManager: connManager,
      appLock: appLock,
      approvalPolicy: approvalPolicy,
      fontSize: fontSize,
      bridgeManager: bridgeManager,
      sshManager: sshManager,
      sftpTransfers: sftpTransfers,
      sshSessions: sshSessions,
      notifications: notifications,
      activeChats: activeChats,
      themeProfileStore: themeProfileStore,
      initialThemeProfiles: initialThemeProfiles,
    ),
  );
}

/// Una opción del selector de estilo de fuente. `family` es null para la fuente
/// del sistema (Roboto en Android); el resto son fuentes empaquetadas localmente
/// (ver `pubspec.yaml` y `assets/fonts/`). No se descarga nada en runtime.
class AppFontOption {
  const AppFontOption(this.id, this.label, this.family);

  final String id;
  final String label;

  /// Familia declarada en pubspec, o null = fuente del sistema.
  final String? family;
}

/// Catálogo de fuentes disponibles y persistencia de la elegida.
class AppFonts {
  AppFonts._();

  /// Clave en SharedPreferences. Valor por defecto: [defaultId].
  static const String prefKey = 'font_family';
  static const String defaultId = 'system';
  static const String systemFamily = 'Roboto';

  /// Catálogo local curado y redistribuible bajo SIL OFL 1.1. Todas viajan
  /// dentro del APK; el selector nunca descarga fuentes ni contacta a terceros.
  static const List<AppFontOption> all = [
    AppFontOption('system', 'System', null),
    AppFontOption('inter', 'Inter', 'Inter'),
    AppFontOption('montserrat', 'Montserrat', 'Montserrat'),
    AppFontOption('nunito', 'Nunito', 'Nunito'),
    AppFontOption('jetbrains', 'JetBrains Mono', 'JetBrainsMono'),
  ];

  /// Mantiene la preferencia visual de instalaciones que guardaron una familia
  /// Fontshare antes de que el catálogo pasara a usar solo fuentes OFL.
  static const Map<String, String> legacyIds = {
    'satoshi': 'inter',
    'general-sans': 'inter',
    'switzer': 'inter',
    'supreme': 'montserrat',
    'cabinet': 'montserrat',
    'clash': 'montserrat',
    'chillax': 'nunito',
    'sentient': 'montserrat',
    'zodiak': 'montserrat',
  };

  /// Un id retirado se migra a su equivalente OFL; basura desconocida cae a
  /// `system` sin crash y sin tocar el resto de preferencias.
  static AppFontOption byId(String? id) {
    final canonicalId = legacyIds[id] ?? id;
    return all.firstWhere(
      (font) => font.id == canonicalId,
      orElse: () => all.first,
    );
  }

  /// Devuelve siempre una familia concreta. Los presets traen su propia fuente,
  /// así que dejar `null` conservaría la del tema en vez de usar la del sistema.
  static String resolvedFamily(AppFontOption option) =>
      option.family ?? systemFamily;

  /// Aplica la fuente a todo el tema, incluida la AppBar. Algunos presets fijan
  /// ahí su familia de forma explícita y cambiar solo `textTheme` dejaba partes
  /// de la interfaz con la tipografía anterior.
  static ThemeData applyToTheme(ThemeData theme, AppFontOption option) {
    final family = resolvedFamily(option);
    return theme.copyWith(
      textTheme: theme.textTheme.apply(fontFamily: family),
      primaryTextTheme: theme.primaryTextTheme.apply(fontFamily: family),
      appBarTheme: theme.appBarTheme.copyWith(
        titleTextStyle: theme.appBarTheme.titleTextStyle?.copyWith(
          fontFamily: family,
        ),
        toolbarTextStyle: theme.appBarTheme.toolbarTextStyle?.copyWith(
          fontFamily: family,
        ),
      ),
    );
  }
}

/// Una opción del selector de idioma. `locale` es null para "seguir el idioma
/// del sistema"; el resto fijan un idioma concreto soportado por la app.
class AppLocaleOption {
  const AppLocaleOption(this.id, this.label, this.locale);

  final String id;
  final String label;

  /// Locale forzado, o null = idioma del sistema.
  final Locale? locale;
}

/// Catálogo de idiomas disponibles y persistencia del elegido. Mismo patrón que
/// [AppFonts]. Por defecto sigue el idioma del sistema; los textos traducidos
/// viven en `lib/l10n/*.arb` y se migran de forma incremental.
class AppLocales {
  AppLocales._();

  /// Clave en SharedPreferences. Valor por defecto: [defaultId].
  static const String prefKey = 'app_locale';
  static const String defaultId = 'system';

  static const List<AppLocaleOption> all = [
    AppLocaleOption('system', 'Sistema', null),
    AppLocaleOption('es', 'Español', Locale('es')),
    AppLocaleOption('en', 'English', Locale('en')),
  ];

  static AppLocaleOption byId(String? id) =>
      all.firstWhere((o) => o.id == id, orElse: () => all.first);
}

class HermesApp extends StatefulWidget {
  final ConnectionManager connManager;
  final AppLockService appLock;
  final ApprovalPolicyService approvalPolicy;
  final FontSizeService fontSize;
  final BridgeManager bridgeManager;
  final SshManager sshManager;
  final SftpTransferService sftpTransfers;
  final SshSessionService sshSessions;
  final NotificationService notifications;
  final ActiveChatService activeChats;
  final ThemeProfileStore? themeProfileStore;
  final ThemeProfileStoreSnapshot? initialThemeProfiles;
  const HermesApp({
    required this.connManager,
    required this.appLock,
    required this.approvalPolicy,
    required this.fontSize,
    required this.bridgeManager,
    required this.sshManager,
    required this.sftpTransfers,
    required this.sshSessions,
    required this.notifications,
    required this.activeChats,
    this.themeProfileStore,
    this.initialThemeProfiles,
    super.key,
  });

  @override
  State<HermesApp> createState() => HermesAppState();

  /// Id del tema activo. Lee la clave `theme_mode` (compatible con las claves
  /// antiguas dark/oled/teal/light, que se mapean a los nuevos ids).
  static String getThemeId(SharedPreferences prefs) {
    final active = prefs.getString(ThemeProfileStore.activeProfileKey);
    if (active != null && active.isNotEmpty) return active;
    return AppTheme.themeIdFromLegacy(prefs.getString('theme_mode'));
  }

  static Future<void> setThemeId(SharedPreferences prefs, String id) async {
    await prefs.setString('theme_mode', id);
  }

  /// Id de la fuente activa (`system`, `inter`, …). Por defecto, la del sistema.
  static String getFontId(SharedPreferences prefs) {
    return AppFonts.byId(prefs.getString(AppFonts.prefKey)).id;
  }

  static Future<void> setFontId(SharedPreferences prefs, String id) async {
    await prefs.setString(AppFonts.prefKey, id);
  }

  /// Id del idioma activo (`system`, `es`, `en`). Por defecto, el del sistema.
  static String getLocaleId(SharedPreferences prefs) {
    return prefs.getString(AppLocales.prefKey) ?? AppLocales.defaultId;
  }

  static Future<void> setLocaleId(SharedPreferences prefs, String id) async {
    await prefs.setString(AppLocales.prefKey, id);
  }
}

class HermesAppState extends State<HermesApp> with WidgetsBindingObserver {
  late final ValueNotifier<String> themeId;
  late final ThemeProfileStore themeProfileStore;
  late final ValueNotifier<ThemeProfileStoreSnapshot> themeProfiles;

  /// Vigilante de sesiones SSH ociosas mientras la app está en background
  /// (U-11, spec 028). Se arma al pasar a paused y se cancela al volver.
  Timer? _sshIdleTimer;

  late final ExternalDataSyncDemandGate _externalDataSyncDemandGate;
  static const MethodChannel _externalDataSyncControl = MethodChannel(
    'hermes/foreground_external_data_sync',
  );

  Timer? _deferredNotificationInitTimer;

  // La selección phone/server ocurre antes de que el controller publique
  // `active`. Serializar ese preflight evita que dos ChatScreen solapadas
  // configuren rutas distintas y que la primera capture la ruta de la segunda.
  Future<void> _voiceEntryTail = Future<void>.value();

  /// Id de la fuente activa (estilo de fuente de Ajustes). Reactivo: cambiarlo
  /// reconstruye el [ThemeData] sin reiniciar la app. Acceso desde descendientes
  /// vía `context.findAncestorStateOfType<HermesAppState>()?.fontId`.
  late final ValueNotifier<String> fontId;

  /// Id del idioma activo (selector de Ajustes). Reactivo: cambiarlo reconstruye
  /// el [MaterialApp] con el nuevo `locale` sin reiniciar la app.
  late final ValueNotifier<String> localeId;

  /// Navigator raíz: el gate de App Lock presenta la pantalla de bloqueo como
  /// ruta sobre este Navigator (no en un Overlay casero).
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  // Deep link hermes://pair (abrir la app ya rellena desde un enlace tocado).
  // La suscripción mantiene viva la instancia de AppLinks mientras escucha.
  StreamSubscription<Uri>? _linkSub;
  final PairingLinkDeliveryGate _pairingLinkDeliveryGate =
      PairingLinkDeliveryGate();
  bool _pairingLinkRetryScheduled = false;

  // Share Sheet Android. La bandeja cifra el contenido hasta convertirlo en un
  // borrador local; nunca lo envía automáticamente al agente.
  final AndroidShareInbox _shareInbox = AndroidShareInbox();
  StreamSubscription<AndroidSharedContent>? _shareSub;
  bool _openingSharedContent = false;
  bool _shareWaitingNoticeShown = false;

  // Shortcut y widget “Nueva conversación”. Ambos entran por el mismo contrato
  // nativo y quedan en memoria hasta superar Splash, onboarding y App Lock.
  final AndroidLaunchActionInbox _newSessionLaunchInbox =
      AndroidLaunchActionInbox();
  StreamSubscription<NewSessionLaunchAction>? _newSessionLaunchSub;
  late final NewSessionLaunchCoordinator _newSessionLaunchCoordinator;

  /// Única salida Flutter hacia el widget Glance. Las pantallas publican
  /// cambios semánticos sobre este snapshot; ninguna escribe preferencias
  /// nativas directamente.
  final HermesHomeWidgetPublisher homeWidgetPublisher =
      HermesHomeWidgetPublisher();

  /// Para mostrar el banner discreto in-app (Regla 2) desde fuera del árbol de
  /// una pantalla concreta (lo dispara un evento de otro chat).
  final GlobalKey<ScaffoldMessengerState> _messengerKey =
      GlobalKey<ScaffoldMessengerState>();

  /// Suscripción a los avisos in-app del NotificationService.
  StreamSubscription<InAppNotice>? _inAppSub;

  /// Un único aviso flotante a la vez. Sustituye al MaterialBanner pegado al
  /// borde superior y deja la pantalla actual visible y operable.
  OverlayEntry? _inAppNoticeOverlay;
  Timer? _inAppNoticeTimer;
  NotificationKind? _inAppNoticeKind;

  /// Estado previo de "hay chats activos" (para detectar transiciones de ánimo).
  bool _presenceRunning = false;

  // Cola serial de cambios del único foreground service de voz. Evita carreras
  // start/update/downgrade si llegan varios tokens o acciones seguidas.
  Future<void> _voiceForegroundTail = Future<void>.value();
  ForegroundAudioOwner _foregroundAudioOwner = ForegroundAudioOwner.dataSync;
  bool _voiceChatOpenRequested = false;
  bool _voiceChatRouteOpen = false;

  /// Acceso para pantallas descendientes (mismo patrón que el tema):
  /// `context.findAncestorStateOfType<HermesAppState>()?.appLock`.
  AppLockService get appLock => widget.appLock;

  /// Política de aprobaciones (modos / YOLO / read-only), compartida por chat,
  /// runs y la tarjeta de aprobación. Acceso vía
  /// `context.findAncestorStateOfType<HermesAppState>()?.approvalPolicy`.
  ApprovalPolicyService get approvalPolicy => widget.approvalPolicy;

  /// Escala global de texto (ajuste de tamaño de fuente de Ajustes). Aplicada en
  /// `MaterialApp.builder` vía `MediaQuery.textScaler`. Acceso vía
  /// `context.findAncestorStateOfType<HermesAppState>()?.fontSize`.
  FontSizeService get fontSize => widget.fontSize;

  /// Resolución/sondeo centralizado del Mobile Bridge (memoria, SOUL, cron,
  /// config, skills). Acceso vía
  /// `context.findAncestorStateOfType<HermesAppState>()?.bridgeManager`.
  BridgeManager get bridgeManager => widget.bridgeManager;

  /// Gestor SSH (terminal/SFTP) centralizado por instancia. Acceso vía
  /// `context.findAncestorStateOfType<HermesAppState>()?.sshManager`.
  SshManager get sshManager => widget.sshManager;

  /// Transferencias SFTP en segundo plano. Acceso vía
  /// `context.findAncestorStateOfType<HermesAppState>()?.sftpTransfers`.
  SftpTransferService get sftpTransfers => widget.sftpTransfers;

  /// Sesiones SSH/terminal persistentes. Acceso vía
  /// `context.findAncestorStateOfType<HermesAppState>()?.sshSessions`.
  SshSessionService get sshSessions => widget.sshSessions;

  /// Gestor de instancias/conexiones (incluye el estado de perfil activo).
  /// Acceso vía `context.findAncestorStateOfType<HermesAppState>()?.connManager`.
  ConnectionManager get connManager => widget.connManager;

  Future<void> updateHomeWidget(
    HermesHomeWidgetSnapshot Function(HermesHomeWidgetSnapshot current)
    transform,
  ) async {
    try {
      await homeWidgetPublisher.update(transform);
    } catch (error) {
      debugPrint(
        '[home-widget] publicación no disponible (${error.runtimeType})',
      );
    }
  }

  /// Servicio de voz (dictado STT + lectura TTS). Acceso vía
  /// `context.findAncestorStateOfType<HermesAppState>()?.voice`.
  late final VoiceService voice = VoiceService(
    widget.connManager.prefs,
    SecureStorage(),
    // El harness físico debe demostrar audio APK-only aunque el QA conserve
    // una preferencia histórica de STT servidor. La copia no se guarda.
    initialSettings: kVoiceQaHarnessEnabled
        ? VoiceSettings.load(widget.connManager.prefs).copyWith(
            sttEngine: SttEngineKind.sherpaLive,
            ttsEngine: TtsEngineKind.onnx,
          )
        : null,
  );

  /// Único controlador público de conversación. Vive aquí (no en la pantalla)
  /// para sobrevivir a la navegación y usa exclusivamente el ActiveChat visible,
  /// STT/TTS de la APK y el submit/steer/queue normal del chat.
  /// Acceso vía `context.findAncestorStateOfType<HermesAppState>()?.voiceConvo`.
  ///
  /// Gate `kVoiceModeEnabled` (spec 027): el inicializador `late final` es
  /// perezosos, así que el servicio NO se instancia mientras nadie lo lea.
  /// Todos los accesos de esta clase están condicionados al gate; los de la
  /// pantalla de chat también. Con el gate en false, nunca llega a existir.
  late final LocalVoiceConversationController voiceConvo =
      LocalVoiceConversationController(voice);

  AppLifecycleState _appLifecycle =
      WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;

  /// Notificaciones locales del agente (aprobaciones, ejecuciones, respuestas).
  /// Acceso vía `context.findAncestorStateOfType<HermesAppState>()?.notifications`.
  NotificationService get notifications => widget.notifications;

  /// Chats con streaming activo que sobreviven a la navegación (la respuesta del
  /// agente sigue aunque salgas de la pantalla del chat). Acceso vía
  /// `context.findAncestorStateOfType<HermesAppState>()?.activeChats`.
  ActiveChatService get activeChats => widget.activeChats;

  Future<T> serializeVoiceEntry<T>(Future<T> Function() action) async {
    final previous = _voiceEntryTail;
    final release = Completer<void>();
    _voiceEntryTail = release.future;
    await previous;
    try {
      return await action();
    } finally {
      release.complete();
    }
  }

  /// Galería de mascotas cosméticas "Companion" (capa visual; no afecta a voz,
  /// runtime ni gateway). Acceso vía
  /// `context.findAncestorStateOfType<HermesAppState>()?.companion`.
  late final CompanionController companion = CompanionController(
    CompanionRepository(importedRootProvider: _companionImportRoot),
    CompanionPreferences(widget.connManager.prefs),
    // Proveedor de "Hatch" v1: generador local **offline** (avatar procedural,
    // sin red, sin cuentas). El proveedor de la conexión Hermes (gated por
    // probe/opt-in) se conectará cuando el gateway exponga generación de
    // imágenes; mientras tanto, esto mantiene la feature local y privada.
    hatchProvider: const MockHatchProvider(),
  );

  /// Cliente `pet.*` de la instancia activa para la mascota por perfil (uno
  /// por conexión; se cierra al cambiar de instancia o al destruir el estado).
  TuiGatewayClient? _companionPetGateway;
  ProfilePetService? _companionPetSvc;
  String? _companionPetGatewayConnId;

  /// Ámbito (conexión, perfil) actual de la mascota, o `null` si no hay
  /// instancia activa (→ comportamiento local global legado). El perfil se lee
  /// siempre fresco del store: el notifier `activeProfile` solo refleja el
  /// último [ConnectionManager.setActiveProfile] y no viaja con el cambio de
  /// conexión.
  CompanionScope? _companionScope() {
    final connId = widget.connManager.activeConnectionId.value;
    if (connId == null || connId.isEmpty) return null;
    return CompanionScope(connId, widget.connManager.activeProfileFor(connId));
  }

  /// Servicio `pet.*` de la instancia [connId]. En solo lectura se mantienen
  /// `pet.info` y `pet.changed` para poder materializar la identidad remota,
  /// pero la propia frontera bloquea `pet.select` y `pet.disable`.
  ProfilePetService? _companionPetService(String connId) {
    SavedConnection? active;
    for (final connection in widget.connManager.getConnections()) {
      if (connection.id == connId) {
        active = connection;
        break;
      }
    }
    if (active == null) return null;
    if (_companionPetGatewayConnId != connId) {
      unawaited(_companionPetGateway?.close());
      _companionPetGateway = TuiGatewayClient(active);
      _companionPetGatewayConnId = connId;
      _companionPetSvc = ProfilePetService(
        _companionPetGateway!,
        allowWrites: !active.readOnly,
      );
    }
    return _companionPetSvc;
  }

  /// Presencia ambiental del Companion (feature 006): ánimo central compartido
  /// por Home/Mascotas, dirigido por los eventos de chat (`ActiveChatService`) y
  /// el ciclo de la app. No toca voz/runtime/gateway. Acceso vía
  /// `context.findAncestorStateOfType<HermesAppState>()?.companionPresence`.
  late final CompanionPresenceController companionPresence =
      CompanionPresenceController();

  /// Reacciona a la actividad de chat: si hay runs activos → "pensando"; al
  /// vaciarse → respuesta completada (éxito → idle). Observa `activeIds` sin
  /// tocar el runtime/voz.
  void _onActiveChatsChanged() {
    final running = activeChats.activeIds.value.isNotEmpty;
    if (running == _presenceRunning) return;
    _presenceRunning = running;
    companionPresence.onEvent(
      running ? PresenceEvent.messageSent : PresenceEvent.responseCompleted,
    );
  }

  /// Compensa una adquisición física que terminó después de que Exit retirase
  /// la lease lógica. `startForVoice()` ya pudo publicar los tipos microphone y
  /// mediaPlayback aunque el owner Dart siguiese en dataSync, por lo que el
  /// downgrade no puede depender de [_foregroundAudioOwner].
  Future<void> _compensateStaleVoiceForegroundAcquisition() async {
    _foregroundAudioOwner = ForegroundAudioOwner.dataSync;
    await BackgroundListener.downgradeFromVoice();
    await widget.activeChats.maybeReleaseForeground();
    completeVoiceLeaseTrace(
      VoiceLatencyTrace.current.currentTurn,
      releaseConfirmed: false,
    );
  }

  Future<void> _queueVoiceForegroundSync() {
    _voiceForegroundTail = _voiceForegroundTail.then((_) async {
      if (!mounted) return;
      final voiceActive = kVoiceRuntimeEnabled && voiceConvo.active;
      widget.notifications.activeVoiceSessionId = voiceActive
          ? voiceConvo.sessionId
          : null;
      final readSnapshot = voice.readAloud.value;
      final readPaused = readSnapshot.phase == ReadAloudPhase.paused;
      final desired = resolveForegroundAudioOwner(
        voiceConversationNeedsForeground:
            kVoiceRuntimeEnabled &&
            voiceRuntimeNeedsForeground(
              active: voiceConvo.audioLeaseRequired,
              continueWhenLocked: voice.continueVoiceWhenLocked,
            ),
        readAloudNeedsForeground: _readAloudNeedsForeground,
      );

      switch (desired) {
        case ForegroundAudioOwner.voiceConversation:
          if (_foregroundAudioOwner != desired) {
            final started = await BackgroundListener.startForVoice();
            if (!started) return;
            if (!mounted || !voiceConvo.audioLeaseRequired) {
              await _compensateStaleVoiceForegroundAcquisition();
              return;
            }
            _foregroundAudioOwner = desired;
          }
          if (!mounted || !voiceConvo.audioLeaseRequired) return;
          await BackgroundListener.updateVoiceNotification(
            state: voiceConvo.phase == VoicePhase.waitingPermission
                ? VoiceNotificationState.waitingPermission
                : voiceConvo.userPaused
                ? VoiceNotificationState.paused
                : VoiceNotificationState.active,
          );
        case ForegroundAudioOwner.readAloud:
          if (_foregroundAudioOwner != desired) {
            final started = await BackgroundListener.startForReadAloud(
              paused: readPaused,
            );
            if (!started || !mounted) return;
            _foregroundAudioOwner = desired;
          } else {
            await BackgroundListener.updateReadAloudNotification(
              paused: readPaused,
            );
          }
        case ForegroundAudioOwner.dataSync:
          final previous = _foregroundAudioOwner;
          _foregroundAudioOwner = desired;
          if (previous == ForegroundAudioOwner.voiceConversation) {
            await BackgroundListener.downgradeFromVoice();
          } else if (previous == ForegroundAudioOwner.readAloud) {
            await BackgroundListener.downgradeFromReadAloud();
          }
          // La degradacion retira los tipos de audio, pero puede dejar un FGS
          // dataSync recien creado. Pasa siempre por el arbitro compartido: el
          // conserva chats, SSH/SFTP y el opt-in de notificaciones, y detiene
          // el servicio cuando Voz o ReadAloud eran su ultimo propietario.
          await widget.activeChats.maybeReleaseForeground();
          completeVoiceLeaseTrace(
            VoiceLatencyTrace.current.currentTurn,
            // flutter_foreground_task no devuelve el conjunto de tipos activo
            // tras downgrade; no se puede afirmar un ACK de liberación.
            releaseConfirmed: false,
          );
      }
    }, onError: (_) {});
    return _voiceForegroundTail;
  }

  Future<bool> _prepareReadAloudPlayback() async {
    await _queueVoiceForegroundSync();
    if (!mounted) return false;
    if (_foregroundAudioOwner == ForegroundAudioOwner.readAloud ||
        _foregroundAudioOwner == ForegroundAudioOwner.voiceConversation) {
      return true;
    }
    // En foreground el audio sigue siendo seguro aunque Android rechazara el
    // FGS; en background fallamos cerrado para no reproducir una pista muda.
    return _appLifecycle == AppLifecycleState.resumed;
  }

  void _onVoiceRuntimeChanged() {
    voice.setVoiceConversationActive(voiceConvo.active);
    voice.setVoiceConversationAudioLeaseActive(voiceConvo.audioLeaseRequired);
    _queueVoiceForegroundSync();
    if (_voiceChatOpenRequested) {
      unawaited(_openVoiceOwnerChatIfReady());
    }
  }

  void _onVoiceConsentChanged() {
    _queueVoiceForegroundSync();
  }

  void _onReadAloudRuntimeChanged() {
    _queueVoiceForegroundSync();
  }

  bool get _readAloudNeedsForeground {
    final snapshot = voice.readAloud.value;
    return snapshot.isActive || snapshot.phase == ReadAloudPhase.paused;
  }

  void _onVoicePrivacyGateChanged() {
    if (!kVoiceRuntimeEnabled) return;
    if (widget.appLock.locked.value) {
      unawaited(voiceConvo.suspendForPrivacy());
    } else if (_appLifecycle == AppLifecycleState.resumed) {
      unawaited(voiceConvo.resumeFullDuplexCaptureIfNeeded());
      unawaited(_openVoiceOwnerChatIfReady());
    }
  }

  Future<void> _openVoiceOwnerChatIfReady() async {
    if (!_voiceChatOpenRequested ||
        _voiceChatRouteOpen ||
        !mounted ||
        _appLifecycle != AppLifecycleState.resumed ||
        _showSplash ||
        _showOnboarding ||
        widget.appLock.locked.value) {
      return;
    }
    final owner = voiceConvo.ownerChat;
    if (owner == null) {
      _voiceChatOpenRequested = false;
      return;
    }
    final visible = widget.notifications.visibleSessionId;
    if (visible != null &&
        <String?>{
          owner.sessionId,
          owner.serverSessionId,
          owner.logicalSessionId,
          owner.storedSessionId,
        }.contains(visible)) {
      _voiceChatOpenRequested = false;
      voiceConvo.resumeOverlay();
      return;
    }
    final navigator = _navigatorKey.currentState;
    if (navigator == null || !navigator.mounted) return;
    final model =
        widget.connManager.prefs.getString('selected_model') ?? 'hermes-agent';
    final session = Session(
      id: owner.sessionId,
      title: owner.sessionTitle,
      model: model,
      source: 'mobile',
      messageCount: owner.messages.length,
      isActive: owner.isStreaming,
      preview: '',
      startedAt: 0,
      lineageRootId: owner.logicalSessionId,
      profile: owner.sessionProfile,
    );
    _voiceChatOpenRequested = false;
    _voiceChatRouteOpen = true;
    voiceConvo.resumeOverlay();
    try {
      await openChatFromHomeNavigator<void>(
        navigator,
        builder: (_) =>
            ChatScreen(connection: owner.connection, session: session),
      );
    } finally {
      _voiceChatRouteOpen = false;
    }
  }

  Future<void> _resumeVoiceFromNotification() async {
    if (!voiceConvo.active || widget.appLock.locked.value) return;
    await voiceConvo.resumeFullDuplexCaptureIfNeeded();
    if (widget.appLock.locked.value) return;
    await voiceConvo.resumeFromSystemControl();
  }

  void _onVoiceTaskData(Object data) {
    if (BackgroundListener.foregroundStopRequestedFromData(data)) {
      unawaited(_handleForegroundStopRequest());
      return;
    }
    final readAction = BackgroundListener.readAloudActionFromData(data);
    if (readAction != null) {
      switch (readAction) {
        case ReadAloudNotificationAction.pause:
          unawaited(voice.pauseReadAloudFromSystemControl());
        case ReadAloudNotificationAction.resume:
          unawaited(voice.resumeReadAloudFromSystemControl());
        case ReadAloudNotificationAction.end:
          unawaited(voice.stopAndDiscardReadAloud());
      }
      _queueVoiceForegroundSync();
      return;
    }
    if (!kVoiceRuntimeEnabled) return;
    final action = BackgroundListener.voiceSessionActionFromData(data);
    if (action == null) return;
    switch (action) {
      case VoiceSessionAction.open:
        _voiceChatOpenRequested = true;
        unawaited(_openVoiceOwnerChatIfReady());
        return;
      case VoiceSessionAction.pause:
        if (!voiceConvo.active) return;
        unawaited(voiceConvo.pauseFromSystemControl());
        break;
      case VoiceSessionAction.continueSession:
        if (!voiceConvo.active) return;
        unawaited(_resumeVoiceFromNotification());
        break;
      case VoiceSessionAction.end:
        if (voiceConvo.active) voiceConvo.exit();
        break;
    }
    _queueVoiceForegroundSync();
  }

  Future<void> _handleForegroundStopRequest() async {
    await BackgroundListener.stopAutomation();
    await _stopExternalDataSyncOwners();
  }

  /// Directorio del sandbox donde se guardan las mascotas importadas por el
  /// usuario (`<appSupport>/companions/`). Solo almacenamiento local de la app.
  static Future<Directory> _companionImportRoot() async {
    final base = await getApplicationSupportDirectory();
    return Directory('${base.path}/companions');
  }

  HomeWidgetTheme _homeWidgetTheme(ThemeProfileStoreSnapshot profiles) {
    final id = profiles.activeProfileId.toLowerCase();
    if (id.contains('oled')) return HomeWidgetTheme.oled;
    final custom = profiles.customById(profiles.activeProfileId);
    final theme = custom == null
        ? AppTheme.fromId(profiles.activeProfileId)
        : AppTheme.fromProfile(custom);
    return theme.brightness == Brightness.light
        ? HomeWidgetTheme.light
        : HomeWidgetTheme.dark;
  }

  SavedConnection? _activeHomeWidgetConnection() {
    final connections = widget.connManager.getConnections();
    if (connections.isEmpty) return null;
    final activeId =
        widget.connManager.activeConnectionId.value ??
        widget.connManager.prefs.getString(ConnectionManager.lastConnKey);
    for (final connection in connections) {
      if (connection.id == activeId) return connection;
    }
    return connections.length == 1 ? connections.single : null;
  }

  Future<void> _publishHomeWidgetBase() {
    final connections = widget.connManager.getConnections();
    final active = _activeHomeWidgetConnection();
    return updateHomeWidget(
      (current) => mergeHomeWidgetBaseSnapshot(
        current: current,
        configured: connections.isNotEmpty,
        instanceId: active?.id,
        instanceLabel: active?.label,
        connectionState: connections.isEmpty
            ? HomeWidgetConnectionState.unconfigured
            : active == null
            ? HomeWidgetConnectionState.noInstance
            : HomeWidgetConnectionState.connecting,
        agentState: active == null
            ? HomeWidgetAgentState.disconnected
            : HomeWidgetAgentState.idle,
        theme: _homeWidgetTheme(themeProfiles.value),
      ),
    );
  }

  void _onHomeWidgetConnectionChanged() {
    unawaited(_syncHomeWidgetConnection());
  }

  Future<void> _syncHomeWidgetConnection() async {
    final connectionId = _activeHomeWidgetConnection()?.id;
    await widget.activeChats.setHomeWidgetActiveConnection(connectionId);
    await _publishHomeWidgetBase();
  }

  @override
  void initState() {
    super.initState();
    widget.activeChats.bindHomeWidgetPublisher(
      homeWidgetPublisher,
      activeConnectionId: _activeHomeWidgetConnection()?.id,
    );
    // Carga (no bloqueante) de las mascotas locales y la preferencia guardada.
    // La selección es por perfil: se re-resuelve al cambiar de instancia o de
    // perfil, cruzando con `pet.info` del gateway cuando éste soporta `pet.*`.
    companion.bindProfileScope(
      resolveScope: _companionScope,
      resolvePetService: _companionPetService,
      changes: Listenable.merge([
        widget.connManager.activeConnectionId,
        widget.connManager.activeProfile,
      ]),
    );
    unawaited(companion.init());
    themeProfileStore =
        widget.themeProfileStore ?? ThemeProfileStore(widget.connManager.prefs);
    final initialThemes =
        widget.initialThemeProfiles ??
        ThemeProfileStoreSnapshot(
          customProfiles: const [],
          activeProfileId: HermesApp.getThemeId(widget.connManager.prefs),
          activeComponentProfileId: ComponentProfiles.minimal.id,
        );
    themeProfiles = ValueNotifier(initialThemes);
    themeId = ValueNotifier(initialThemes.activeProfileId);
    unawaited(_syncNativeAppearance(initialThemes));
    if (widget.initialThemeProfiles == null) {
      unawaited(refreshThemeProfiles(force: true));
    }
    fontId = ValueNotifier(HermesApp.getFontId(widget.connManager.prefs));
    localeId = ValueNotifier(HermesApp.getLocaleId(widget.connManager.prefs));
    loadHeaderTitle(widget.connManager.prefs);
    _showOnboarding =
        widget.connManager.prefs.getBool('onboarding_done') != true;
    _newSessionLaunchCoordinator = NewSessionLaunchCoordinator(
      connections: widget.connManager.getConnections,
      activeConnectionId: () => widget.connManager.activeConnectionId.value,
      defaultConnectionId: () => widget.connManager.defaultConnectionId,
      onboardingComplete: () => !_showOnboarding,
      unlocked: () => !widget.appLock.locked.value,
      navigatorReady: () =>
          !_showSplash && _navigatorKey.currentState?.mounted == true,
      newChatTitle: () =>
          Strings.of(_navigatorKey.currentContext!).drawerNewChat,
      selectConnection: _selectNewSessionConnection,
      navigate: _openNewSessionDraft,
      openApp: _openWidgetApp,
      openSetup: _openWidgetSetup,
      openSession: _openWidgetSession,
    );
    widget.connManager.activeConnectionId.addListener(
      _onHomeWidgetConnectionChanged,
    );
    unawaited(_publishHomeWidgetBase());
    if (!_showOnboarding) {
      _scheduleHomeInitialLoad();
    }
    WidgetsBinding.instance.addObserver(this);
    // `didHaveMemoryPressure` no lleva nivel y también se dispara al pasar a
    // background: MainActivity reenvía onTrimMemory con su nivel para que la
    // voz solo evacúe modelos pesados ante presión real del sistema.
    const MethodChannel('hermes/memory').setMethodCallHandler((call) async {
      if (call.method == 'trimMemory') {
        final level = (call.arguments as Map?)?['level'];
        unawaited(voice.onTrimMemory(level is int ? level : -1));
      }
      return null;
    });
    // Al pulsar una notificación del agente, navega a la sesión correcta.
    widget.notifications.onOpenSession = _openSessionFromNotification;
    // Regla 2: avisos discretos de eventos en OTRO chat con la app delante.
    _inAppSub = widget.notifications.inAppNotices.listen(_showInAppNotice);
    // Presencia (006): saluda al abrir y reacciona a la actividad de chat.
    companionPresence.onEvent(PresenceEvent.appOpened);
    activeChats.activeIds.addListener(_onActiveChatsChanged);
    // Crear canales toca el hilo principal nativo durante cientos de ms en
    // algunos Android. Se difiere hasta terminar la entrada del splash para no
    // congelar una animación ya visible.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _deferredNotificationInitTimer = Timer(
        const Duration(milliseconds: 1400),
        () {
          widget.notifications.init().then((_) {
            if (!mounted) return;
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => widget.notifications.retryPendingOpen(),
            );
          });
        },
      );
    });
    // Re-arranca la escucha en 2º plano si el usuario la dejó activada.
    BackgroundListener.ensureInitialized();
    unawaited(
      BackgroundCronWatch.syncConnections(widget.connManager.getConnections()),
    );
    widget.connManager.connectionsRevision.addListener(
      _syncBackgroundCronConnections,
    );
    unawaited(BackgroundListener.setUiForeground(true));
    BackgroundListener.restoreIfEnabled(widget.connManager.prefs);
    voice.prepareReadAloudPlayback = _prepareReadAloudPlayback;
    voice.readAloud.addListener(_onReadAloudRuntimeChanged);
    FlutterForegroundTask.addTaskDataCallback(_onVoiceTaskData);
    // Deep link hermes://pair → abrir el alta de instancia ya rellena.
    _initDeepLinks();
    // ACTION_SEND/ACTION_SEND_MULTIPLE → borrador revisable en un chat nuevo.
    widget.connManager.activeConnectionId.addListener(_retryPendingShare);
    unawaited(_initShareInbox());
    widget.connManager.activeConnectionId.addListener(
      _retryPendingNewSessionLaunch,
    );
    widget.appLock.locked.addListener(_retryPendingNewSessionLaunch);
    widget.appLock.locked.addListener(_onAppLockNoticeGateChanged);
    unawaited(_initNewSessionLaunchInbox());
    // Cableado del modo conversación. Con el kill-switch de compilación no se
    // instancia ningún orquestador; STT/TTS del chat siguen independientes.
    if (kVoiceRuntimeEnabled) {
      voiceConvo.addListener(_onVoiceRuntimeChanged);
      voice.voiceConsent.addListener(_onVoiceConsentChanged);
      voice.speaking.addListener(_onVoicePrivacyGateChanged);
      widget.appLock.locked.addListener(_onVoicePrivacyGateChanged);
    }
    // Mantener vivo el proceso mientras: (a) la voz sigue hablando (solo con el
    // modo voz habilitado; el cortocircuito evita instanciar el servicio), o
    // (b) hay transferencias SFTP en curso. Así una descarga/subida no se corta
    // al salir.
    widget.activeChats.keepAliveWhile = () =>
        (kVoiceRuntimeEnabled &&
            voiceRuntimeNeedsForeground(
              active: voiceConvo.audioLeaseRequired,
              continueWhenLocked: voice.continueVoiceWhenLocked,
            )) ||
        _readAloudNeedsForeground ||
        widget.sftpTransfers.hasActive ||
        widget.sshSessions.hasActive;
    // SFTP y las sesiones de terminal levantan el foreground service al empezar y
    // delegan su parada en la coordinación central (que respeta voz/runs/el otro).
    _externalDataSyncDemandGate = ExternalDataSyncDemandGate(
      _applyExternalDataSyncDemand,
    );
    widget.sftpTransfers.onNeedForeground = _syncExternalDataSyncDemand;
    widget.sftpTransfers.onMaybeRelease = _syncExternalDataSyncDemand;
    widget.sshSessions.onNeedForeground = _syncExternalDataSyncDemand;
    widget.sshSessions.onMaybeRelease = _syncExternalDataSyncDemand;
    _externalDataSyncControl.setMethodCallHandler((call) async {
      if (call.method == 'stopRequested') {
        final released = await _stopExternalDataSyncOwners();
        if (!released) {
          throw StateError('external dataSync release was not confirmed');
        }
      }
      return null;
    });
    unawaited(_consumePendingExternalDataSyncStop());
    _syncExternalDataSyncDemand();
  }

  @override
  void didHaveMemoryPressure() {
    super.didHaveMemoryPressure();
    // Los atlas de mascotas y previews generados pueden ser grandes una vez
    // decodificados. Android ya nos está pidiendo memoria: soltar entradas no
    // visibles permite recuperarla sin tocar el chat ni el estado del agente.
    final imageCache = PaintingBinding.instance.imageCache;
    imageCache.clear();
    imageCache.clearLiveImages();
    // La voz NO reacciona aquí: esta señal binaria también llega al pasar a
    // background y evacuaba Sherpa/Whisper/ONNX en cada ida (recarga de
    // varios segundos por turno). La evacuación la decide `onTrimMemory` con
    // el nivel real de ComponentCallbacks2 (canal hermes/memory).
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appLifecycle = state;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      unawaited(updateHomeWidget((snapshot) => snapshot));
    }
    if (kVoiceRuntimeEnabled) {
      if (state == AppLifecycleState.resumed) {
        if (!widget.appLock.locked.value) {
          unawaited(voiceConvo.resumeFullDuplexCaptureIfNeeded());
        }
      } else {
        unawaited(voiceConvo.suspendFullDuplexForAppBackground());
      }
    }
    // Solo molestamos con notificaciones cuando la app no está en primer plano.
    widget.notifications.appInForeground = state == AppLifecycleState.resumed;
    unawaited(
      BackgroundListener.setUiForeground(state == AppLifecycleState.resumed),
    );
    // Al volver de 2º plano, reconcilia cualquier chat cuyo SSE pudiera haberse
    // cortado mientras la app estaba suspendida (red de seguridad: con el
    // foreground service activo normalmente no hace falta, pero si el SO mató el
    // isolate igualmente, re-sincronizamos los mensajes desde el servidor).
    if (state == AppLifecycleState.resumed) {
      _sshIdleTimer?.cancel();
      _sshIdleTimer = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (widget.notifications.initialized) {
          unawaited(widget.notifications.recoverPlatformOpen());
        }
      });
      widget.activeChats.reconcileAfterResume();
      // Volver a primer plano no deshace una pausa explícita; el usuario puede
      // continuar con el orbe o desde la notificación.
      if (kVoiceRuntimeEnabled) {
        voiceConvo.onAppResumed(appUnlocked: !widget.appLock.locked.value);
      }
      unawaited(_openVoiceOwnerChatIfReady());
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      // No cerramos el WebSocket por lifecycle. Android puede encadenar
      // hidden/paused/detached durante un selector, un cambio de red o una
      // suspensión breve; cerrar aquí convierte una transición local en
      // client_gone y el gateway puede cancelar un turno remoto aún activo.
      // Al volver a foreground, reconcileAfterResume recupera cualquier corte
      // real de transporte sin destruir trabajo deliberadamente.
      // Sin opt-in de pantalla bloqueada, pausa y silencia micro+TTS. Con opt-in
      // no se toca el bucle: ya está protegido por el FGS iniciado en foreground.
      if (kVoiceRuntimeEnabled &&
          voiceConvo.active &&
          !voice.continueVoiceWhenLocked) {
        unawaited(voiceConvo.onAppBackgrounded());
      }
      // U-11 (spec 028): una shell SSH parada en el prompt mantiene vivos el
      // FGS (keepAliveWhile) y los keepalive de red indefinidamente. Mientras
      // el FGS nos deje correr, vigila cada 2 min y cierra las sesiones sin
      // tráfico >10 min; al cerrar la última, la coordinación existente
      // (onMaybeRelease) apaga el servicio. Un comando largo que produce
      // salida refresca lastActivityAt y no se corta.
      _sshIdleTimer ??= Timer.periodic(const Duration(minutes: 2), (_) {
        widget.sshSessions.closeIdle(const Duration(minutes: 10));
      });
    }
  }

  void _syncBackgroundCronConnections() {
    unawaited(
      BackgroundCronWatch.syncConnections(widget.connManager.getConnections()),
    );
  }

  void _syncExternalDataSyncDemand() {
    unawaited(
      _externalDataSyncDemandGate.reconcile(
        sftpActive: widget.sftpTransfers.hasActive,
        sshActive: widget.sshSessions.hasActive,
      ),
    );
  }

  Future<bool> _applyExternalDataSyncDemand(bool required) async {
    final applied = await BackgroundListener.setExternalDataSyncRequired(
      required,
    );
    if (!required) await widget.activeChats.maybeReleaseForeground();
    return applied;
  }

  Future<void> _consumePendingExternalDataSyncStop() async {
    try {
      final pending =
          await _externalDataSyncControl.invokeMethod<bool>(
            'takePendingStopRequested',
          ) ==
          true;
      if (pending) {
        final released = await _stopExternalDataSyncOwners();
        if (released) await _acknowledgeExternalDataSyncStop();
      }
    } catch (_) {
      // Canal ausente fuera de Android o durante teardown: no hay acción nativa.
    }
  }

  Future<bool> _stopExternalDataSyncOwners() async {
    widget.sftpTransfers.cancelAll();
    widget.sshSessions.closeAll();
    return await _externalDataSyncDemandGate.confirmReleased();
  }

  Future<void> _acknowledgeExternalDataSyncStop() async {
    try {
      await _externalDataSyncControl.invokeMethod<void>(
        'acknowledgeStopRequested',
      );
    } catch (_) {
      // Sin ACK la orden nativa permanece durable y se reintenta al arrancar.
    }
  }

  /// Abre el chat de la sesión indicada por una notificación pulsada. Resuelve
  /// la instancia por id; construye una [Session] mínima (ChatScreen recarga los
  /// mensajes reales del servidor por id). No hace nada si la instancia ya no
  /// existe o el Navigator aún no está montado.
  /// Tarjeta flotante para un evento en OTRO chat (Regla 2).
  ///
  /// Tocar abre el destino y deslizar horizontalmente solo oculta la tarjeta:
  /// una aprobación pendiente nunca se interpreta como aprobada o denegada.
  /// No usa notificación del sistema; solo aparece con la app delante.
  void _showInAppNotice(InAppNotice notice) {
    // Presencia (006): un aviso de aprobación pone la mascota en "esperando
    // permiso" (waiting). Se hace antes del early-return del banner para que la
    // mascota reaccione aunque no haya messenger montado. La resolución (vuelta
    // a thinking/idle/success) la dirige el fin del run vía `activeIds` en
    // `_onActiveChatsChanged`. Capa puramente aditiva: no toca runtime ni voz.
    if (notice.kind == NotificationKind.approval) {
      companionPresence.onEvent(PresenceEvent.approvalNeeded);
    }
    if (_showSplash || _showOnboarding || widget.appLock.locked.value) return;
    // Una respuesta o run informativo nunca desplaza una aprobacion que aun
    // necesita al usuario. Otra aprobacion mas reciente si puede actualizarla.
    if (!shouldReplaceInAppNotice(_inAppNoticeKind, notice.kind)) {
      return;
    }
    final ctx = _messengerKey.currentContext ?? _navigatorKey.currentContext;
    final overlay = _navigatorKey.currentState?.overlay;
    if (ctx == null || overlay == null) return;
    final s = Strings.of(ctx);
    final colors = Theme.of(ctx).hermes;
    final (IconData icon, Color tint) = switch (notice.kind) {
      NotificationKind.approval => (
        Icons.verified_user_outlined,
        colors.warning,
      ),
      NotificationKind.reply => (Icons.check_circle_outline, colors.success),
      NotificationKind.run => (Icons.task_alt, colors.accent),
      _ => (Icons.notifications_none, colors.accent),
    };
    // Un solo aviso a la vez: el evento más reciente manda.
    _dismissInAppNotice();
    final entry = OverlayEntry(
      builder: (overlayContext) => Positioned(
        top: 0,
        left: 0,
        right: 0,
        child: SafeArea(
          minimum: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: HermesFloatingNotice(
                noticeKey: ValueKey(
                  'in-app-notice-${notice.kind.name}-${notice.open.sessionId}',
                ),
                icon: icon,
                tint: tint,
                title: notice.title,
                body: notice.body,
                actionLabel: s.inAppGo,
                dismissLabel: s.inAppDismiss,
                onOpen: () {
                  if (_openSessionFromNotification(notice.open)) {
                    _dismissInAppNotice();
                  }
                },
                onDismissed: _dismissInAppNotice,
              ),
            ),
          ),
        ),
      ),
    );
    _inAppNoticeOverlay = entry;
    _inAppNoticeKind = notice.kind;
    overlay.insert(entry);
    // Una aprobacion requiere una decision explicita. Deslizar solo la oculta;
    // nunca desaparece sola mientras siga pendiente.
    final dismissDelay = inAppNoticeAutoDismissDelay(notice.kind);
    if (dismissDelay != null) {
      _inAppNoticeTimer = Timer(dismissDelay, _dismissInAppNotice);
    }
  }

  void _dismissInAppNotice() {
    _inAppNoticeTimer?.cancel();
    _inAppNoticeTimer = null;
    _inAppNoticeOverlay?.remove();
    _inAppNoticeOverlay = null;
    _inAppNoticeKind = null;
  }

  void _onAppLockNoticeGateChanged() {
    if (widget.appLock.locked.value) {
      _dismissInAppNotice();
      return;
    }
    widget.notifications.retryPendingOpen();
  }

  final Set<String> _hydratingNotificationRuns = <String>{};

  String _sessionProfileOwner(SavedConnection connection, {String? owner}) =>
      Session.profileOwner(
        owner,
        fallback: widget.connManager.activeProfileFor(connection.id),
      );

  bool _openSessionFromNotification(NotificationOpen open) {
    SavedConnection? conn;
    for (final c in widget.connManager.getConnections()) {
      if (c.id == open.connId) {
        conn = c;
        break;
      }
    }
    final connection = conn;
    final nav = _navigatorKey.currentState;
    if (connection == null || nav == null) return false;
    if (widget.appLock.locked.value) return false;

    // Si la notificación es de una ejecución (runId presente), navegar a
    // RunDetailScreen; si el run ya expiró, fallback a TaskCenterScreen.
    final runId = open.runId;
    if (runId != null && runId.isNotEmpty) {
      final profile = open.profile?.trim().toLowerCase();
      if (profile == null || profile.isEmpty) return false;
      final hydrationKey =
          '${connection.id}\u0000$profile\u0000$runId\u0000${open.requestId ?? ''}';
      if (_hydratingNotificationRuns.add(hydrationKey)) {
        unawaited(() async {
          try {
            for (var attempt = 0; mounted && attempt < 20; attempt++) {
              if (widget.appLock.locked.value) {
                await Future<void>.delayed(const Duration(milliseconds: 250));
                continue;
              }
              final opened = await _openRunDetailFromNotification(
                nav,
                connection,
                runId,
                profile: profile,
                requestId: open.requestId,
                onApprovalReady: open.requestId == null
                    ? null
                    : () => _completeApprovalOpenWhenUnlocked(open),
              );
              if (opened) {
                if (open.requestId == null) {
                  widget.notifications.completePendingOpen(open);
                }
                return;
              }
              await Future<void>.delayed(const Duration(milliseconds: 250));
            }
          } finally {
            _hydratingNotificationRuns.remove(hydrationKey);
          }
        }());
      }
      return false;
    }

    final taskId = open.taskId;
    if (taskId != null && taskId.isNotEmpty) {
      nav.push(
        MaterialPageRoute(
          builder: (_) =>
              TasksScreen(connection: connection, initialTaskId: taskId),
        ),
      );
      return true;
    }

    final ownedTarget = missionControlTargetForNotification(open);
    if (ownedTarget != null) {
      unawaited(
        _openMissionControlFromNotification(nav, connection, ownedTarget),
      );
      return true;
    }

    // Sin runId: comportamiento anterior — abrir la sesión de chat.
    if (open.sessionId.isEmpty) return false;
    final liveOwner = activeChats
        .of(open.connId, open.sessionId, profile: open.profile)
        ?.sessionProfile;
    final owner = open.profile ?? liveOwner;
    if (owner == null || owner.trim().isEmpty) {
      // Los payloads legacy no llevaban perfil. Resolver la fila autoritativa
      // antes de reconstruir evita abrirla contra el perfil global actual.
      unawaited(_openWidgetSession(connection, open.sessionId));
      return true;
    }
    final profile = _sessionProfileOwner(connection, owner: owner);
    final session = Session(
      id: open.sessionId,
      title: open.title ?? '',
      model: '',
      source: '',
      messageCount: 0,
      isActive: true,
      preview: '',
      startedAt: 0,
      profile: profile,
      isDefaultProfile: profile == 'default',
    );
    openChatFromHomeNavigator<void>(
      nav,
      builder: (_) => ChatScreen(connection: connection, session: session),
    );
    return true;
  }

  Future<void> _openMissionControlFromNotification(
    NavigatorState nav,
    SavedConnection connection,
    MissionControlOpenTarget target,
  ) async {
    if (widget.connManager.activeConnectionId.value != connection.id) {
      await widget.connManager.setActiveConnection(connection.id);
    }
    if (!nav.mounted) return;
    await pushNotificationOwnerRoute<void>(
      nav,
      MaterialPageRoute<void>(
        builder: (_) => MissionControlScreen(
          connection: connection,
          connManager: widget.connManager,
          activeChats: activeChats,
          initialOpenTarget: target,
        ),
      ),
    );
  }

  /// Si la notificación lleva un runId, navega a RunDetailScreen de ese run.
  /// Fallback a TaskCenterScreen si el run ya expiró o no está en el registry.
  Future<bool> _openRunDetailFromNotification(
    NavigatorState nav,
    SavedConnection conn,
    String runId, {
    required String profile,
    String? requestId,
    VoidCallback? onApprovalReady,
  }) async {
    try {
      final registry = await RunRegistry.load(
        widget.connManager.prefs,
        conn.id,
      );
      if (!nav.mounted) {
        return false; // navigator puede haberse desmontado durante await
      }
      final record = registry.records
          .where((r) => r.runId == runId && r.profile == profile)
          .firstOrNull;
      if (record != null) {
        if (widget.appLock.locked.value) return false;
        nav.push(
          MaterialPageRoute(
            builder: (_) => RunDetailScreen(
              connection: conn,
              record: record,
              initialApprovalId: requestId,
              onInitialApprovalReady: onApprovalReady,
            ),
          ),
        );
        return true;
      }
    } catch (e) {
      debugPrint('main: no se pudo abrir el run exacto: $e');
    }
    return false;
  }

  Future<void> _completeApprovalOpenWhenUnlocked(NotificationOpen open) async {
    while (mounted && widget.appLock.locked.value) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    if (!mounted) return;
    widget.notifications.completePendingOpen(open);
  }

  /// Onboarding de primera ejecución (se muestra una sola vez).
  late bool _showOnboarding;

  /// Intro animada al abrir la app. En instalaciones configuradas permanece
  /// sobre Home hasta que conexiones y conversaciones iniciales estén listas.
  bool _showSplash = true;
  bool _startHomeInitialLoad = false;
  bool _homeInitialLoadComplete = false;
  Timer? _homeInitialLoadTimer;
  Timer? _homeReadyTimer;
  final ValueNotifier<double> _startupProgress = ValueNotifier<double>(0.06);

  @visibleForTesting
  static const homeInitialLoadDeferral = Duration(milliseconds: 1500);

  void _reportStartupProgress(double value) {
    final next = value.clamp(0.0, 1.0);
    if (next > _startupProgress.value) _startupProgress.value = next;
  }

  void _scheduleHomeInitialLoad() {
    if (_startHomeInitialLoad || _homeInitialLoadTimer?.isActive == true) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _showOnboarding ||
          _startHomeInitialLoad ||
          _homeInitialLoadTimer?.isActive == true) {
        return;
      }
      _reportStartupProgress(0.20);
      // Deja que la entrada de marca termine antes de construir el Home
      // completo. La carga sigue cubierta por este mismo splash, pero ya no
      // compite con su animación en los primeros frames.
      _homeInitialLoadTimer = Timer(homeInitialLoadDeferral, () {
        if (!mounted || _showOnboarding || _startHomeInitialLoad) return;
        _reportStartupProgress(0.34);
        setState(() => _startHomeInitialLoad = true);
      });
    });
  }

  void _finishSplash() {
    if (!mounted || !_showSplash) return;
    setState(() => _showSplash = false);
    _retryPendingNewSessionLaunch();
    unawaited(_openVoiceOwnerChatIfReady());
  }

  void _markHomeInitialLoadComplete() {
    if (!mounted ||
        _homeInitialLoadComplete ||
        _homeReadyTimer?.isActive == true) {
      return;
    }
    _reportStartupProgress(1);
    // Deja que la barra alcance visualmente el 100 % y que Home conserve un
    // frame ya pintado antes de iniciar el cross-fade del splash.
    _homeReadyTimer = Timer(const Duration(milliseconds: 240), () {
      if (!mounted || _homeInitialLoadComplete) return;
      setState(() => _homeInitialLoadComplete = true);
    });
  }

  Future<void> _finishOnboarding() async {
    await widget.connManager.prefs.setBool('onboarding_done', true);
    if (mounted) {
      setState(() {
        _showOnboarding = false;
        // El onboarding ya ha ocupado el arranque: Home puede montarse al
        // terminar sin volver a mostrar ni retrasar otra pantalla intermedia.
        _startHomeInitialLoad = true;
      });
      _retryPendingNewSessionLaunch();
      unawaited(_openVoiceOwnerChatIfReady());
    }
  }

  Future<void> _initNewSessionLaunchInbox() async {
    _newSessionLaunchSub = _newSessionLaunchInbox.events.listen(
      (action) => unawaited(_newSessionLaunchCoordinator.enqueue(action)),
    );
    try {
      final initial = await _newSessionLaunchInbox.initialize();
      if (initial != null) {
        await _newSessionLaunchCoordinator.enqueue(initial);
      }
    } catch (error) {
      debugPrint(
        'main: acceso Nueva conversación no disponible '
        '(${error.runtimeType})',
      );
    }
  }

  void _retryPendingNewSessionLaunch() {
    if (!mounted || !_newSessionLaunchCoordinator.hasPending) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_newSessionLaunchCoordinator.retry());
    });
  }

  Future<SavedConnection?> _selectNewSessionConnection(
    List<SavedConnection> candidates,
  ) async {
    final context = _navigatorKey.currentContext;
    if (context == null || candidates.isEmpty) return null;
    if (candidates.length == 1) return candidates.single;
    return showHermesFloatingSurface<SavedConnection>(
      context: context,
      surfaceKey: const ValueKey('new-session-instance-surface'),
      maxWidth: 480,
      builder: (surfaceContext) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: 12),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 10),
            child: Text(
              Strings.of(surfaceContext).drawerInstances,
              style: Theme.of(surfaceContext).textTheme.titleMedium,
            ),
          ),
          for (final connection in candidates)
            ListTile(
              leading: const Icon(Icons.dns_outlined),
              title: Text(connection.label),
              onTap: () => Navigator.of(surfaceContext).pop(connection),
            ),
        ],
      ),
    );
  }

  Future<void> _openNewSessionDraft(
    SavedConnection connection,
    Session draft,
    NewSessionLaunchTarget target,
  ) async {
    final navigator = _navigatorKey.currentState;
    if (navigator == null || !navigator.mounted) {
      throw StateError('root navigator unavailable');
    }
    if (widget.connManager.activeConnectionId.value != connection.id) {
      await widget.connManager.setActiveConnection(connection.id);
    }
    final ownedDraft = draft.copyWith(
      profile: _sessionProfileOwner(connection, owner: draft.profile),
    );
    unawaited(
      openChatFromHomeNavigator<void>(
        navigator,
        builder: (_) => ChatScreen(
          connection: connection,
          session: ownedDraft,
          requestComposerFocus: target == NewSessionLaunchTarget.composer,
          initialAttachmentSource: switch (target) {
            NewSessionLaunchTarget.camera => AttachmentSourceChoice.camera,
            NewSessionLaunchTarget.gallery => AttachmentSourceChoice.photos,
            _ => null,
          },
          initialVoiceMode: target == NewSessionLaunchTarget.voice,
        ),
      ),
    );
    await WidgetsBinding.instance.endOfFrame;
  }

  Future<void> _openWidgetApp() async {
    final navigator = _navigatorKey.currentState;
    if (navigator == null || !navigator.mounted) {
      throw StateError('root navigator unavailable');
    }
    navigator.popUntil((route) => route.isFirst);
    await WidgetsBinding.instance.endOfFrame;
  }

  Future<void> _openWidgetSetup() async {
    final navigator = _navigatorKey.currentState;
    if (navigator == null || !navigator.mounted) {
      throw StateError('root navigator unavailable');
    }
    if (_showOnboarding) {
      navigator.popUntil((route) => route.isFirst);
    } else {
      unawaited(
        navigator.push<void>(
          MaterialPageRoute<void>(
            builder: (_) => InstanceEditScreen(connManager: widget.connManager),
          ),
        ),
      );
    }
    await WidgetsBinding.instance.endOfFrame;
  }

  Future<void> _openWidgetSession(
    SavedConnection connection,
    String sessionId,
  ) async {
    final navigator = _navigatorKey.currentState;
    if (navigator == null || !navigator.mounted) {
      throw StateError('root navigator unavailable');
    }
    if (widget.connManager.activeConnectionId.value != connection.id) {
      await widget.connManager.setActiveConnection(connection.id);
    }
    final client = ApiClient(
      baseUrl: connection.baseUrl,
      apiKey: connection.apiKey,
      connectionId: connection.id,
    );
    Session? session;
    try {
      session = await client.getSession(sessionId);
    } catch (_) {
      // El widget conserva el último estado conocido. Si esa sesión ya no
      // existe, abrir la biblioteca es más útil y seguro que crear un chat
      // fantasma con el identificador obsoleto.
    } finally {
      client.close();
    }
    if (!navigator.mounted) return;
    final target = session;
    if (target == null) {
      unawaited(
        navigator.push<void>(
          MaterialPageRoute<void>(
            builder: (_) => SessionListScreen(
              connection: connection,
              connManager: widget.connManager,
            ),
          ),
        ),
      );
    } else {
      unawaited(
        openChatFromHomeNavigator<void>(
          navigator,
          builder: (_) => ChatScreen(connection: connection, session: target),
        ),
      );
    }
    await WidgetsBinding.instance.endOfFrame;
  }

  Future<void> setThemeId(String id) async {
    await themeProfileStore.activate(id);
    await refreshThemeProfiles();
  }

  Future<void> _syncNativeAppearance(ThemeProfileStoreSnapshot snapshot) async {
    final custom = snapshot.customById(snapshot.activeProfileId);
    final theme = custom == null
        ? AppTheme.fromId(snapshot.activeProfileId)
        : AppTheme.fromProfile(custom);
    await NativeAppearance.sync(theme.brightness);
  }

  Future<ThemeProfileStoreSnapshot> refreshThemeProfiles({
    bool force = false,
  }) async {
    final snapshot = await themeProfileStore.load(force: force);
    if (!mounted) return snapshot;
    themeProfiles.value = snapshot;
    themeId.value = snapshot.activeProfileId;
    unawaited(_syncNativeAppearance(snapshot));
    unawaited(
      updateHomeWidget(
        (current) => current.copyWith(theme: _homeWidgetTheme(snapshot)),
      ),
    );
    return snapshot;
  }

  Future<void> setFontId(String id) async {
    await HermesApp.setFontId(widget.connManager.prefs, id);
    fontId.value = id;
  }

  Future<void> setLocaleId(String id) async {
    await HermesApp.setLocaleId(widget.connManager.prefs, id);
    localeId.value = id;
  }

  /// Inicializa la escucha de deep links `hermes://pair` (enlace de emparejado).
  /// Cubre el arranque en frío (getInitialLink) y la app ya abierta (stream).
  Future<void> _initDeepLinks() async {
    try {
      final links = AppLinks();
      final initial = await links.getInitialLink();
      if (initial != null) _handlePairingUri(initial);
      _linkSub = links.uriLinkStream.listen(_handlePairingUri, onError: (_) {});
    } catch (e) {
      // Sin deep links disponibles: el resto del onboarding sigue funcionando.
      debugPrint('main: _initDeepLinks falló (sin deep links disponibles): $e');
    }
  }

  /// Si la URI es un enlace de emparejado válido, abre el alta de instancia ya
  /// precargada (reutiliza InstanceEditScreen.initialLink). Si no, la ignora.
  void _handlePairingUri(Uri uri) {
    final link = PairingLink.tryParse(uri.toString());
    if (link == null) return;
    final nav = _navigatorKey.currentState;
    if (nav == null) {
      _pairingLinkDeliveryGate.defer(uri);
      _scheduleDeferredPairingLink();
      return;
    }
    if (!_pairingLinkDeliveryGate.shouldHandle(uri)) return;
    nav.push(
      MaterialPageRoute(
        builder: (_) => InstanceEditScreen(
          connManager: widget.connManager,
          initialLink: link,
          fromDeepLink: true,
        ),
      ),
    );
    if (_pairingLinkDeliveryGate.hasDeferred) {
      _scheduleDeferredPairingLink();
    }
  }

  void _scheduleDeferredPairingLink() {
    if (_pairingLinkRetryScheduled || !mounted) return;
    _pairingLinkRetryScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pairingLinkRetryScheduled = false;
      if (!mounted) return;
      final pending = _pairingLinkDeliveryGate.takeDeferredIf(
        _navigatorKey.currentState != null,
      );
      if (pending == null) {
        if (_pairingLinkDeliveryGate.hasDeferred) {
          _scheduleDeferredPairingLink();
        }
        return;
      }
      _handlePairingUri(pending);
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  Future<void> _initShareInbox() async {
    _shareSub = _shareInbox.events.listen((_) => _retryPendingShare());
    try {
      await _shareInbox.initialize();
      _retryPendingShare();
    } catch (error) {
      debugPrint('main: Share Sheet no disponible (${error.runtimeType})');
    }
  }

  void _retryPendingShare() {
    if (!mounted || _openingSharedContent) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_openPendingSharedContent());
    });
  }

  Future<void> _openPendingSharedContent() async {
    if (!mounted || _openingSharedContent) return;
    final content = await _shareInbox.peek();
    if (content == null || !mounted) return;
    final nav = _navigatorKey.currentState;
    if (nav == null) return;

    final connections = widget.connManager.getConnections();
    if (connections.isEmpty) {
      if (!_shareWaitingNoticeShown) {
        _shareWaitingNoticeShown = true;
        _messengerKey.currentState?.showSnackBar(
          SnackBar(content: Text(Strings.of(nav.context).shareNeedsInstance)),
        );
      }
      return;
    }

    var connection = connections.first;
    final activeId = widget.connManager.activeConnectionId.value;
    for (final candidate in connections) {
      if (candidate.id == activeId) {
        connection = candidate;
        break;
      }
    }

    _openingSharedContent = true;
    try {
      if (content.text.trim().isEmpty && content.attachments.isEmpty) {
        await _shareInbox.acknowledge(content.id);
        if (mounted) {
          _messengerKey.currentState?.showSnackBar(
            SnackBar(content: Text(Strings.of(nav.context).shareFilesRejected)),
          );
        }
        return;
      }

      final sessionId = GatewayChatClient.generateSessionId();
      await ChatDraftStore(
        widget.connManager.prefs,
      ).save(connection.id, sessionId, content.text, content.attachments);
      await _shareInbox.acknowledge(content.id);
      if (!mounted) return;

      final textTitle = Session.titleFromText(content.text);
      final attachmentTitle = content.attachments.isEmpty
          ? ''
          : content.attachments.first.name.trim();
      final title = textTitle.isNotEmpty
          ? textTitle
          : attachmentTitle.isNotEmpty
          ? attachmentTitle
          : Strings.of(nav.context).drawerNewChat;
      final now = DateTime.now().millisecondsSinceEpoch / 1000;
      final session = Session(
        id: sessionId,
        title: title,
        model: 'hermes-agent',
        source: 'android-share',
        messageCount: 0,
        isActive: false,
        preview: content.text,
        startedAt: now,
        updatedAt: now,
        hasLocalDraft: true,
        profile: _sessionProfileOwner(connection),
      );
      _shareWaitingNoticeShown = false;
      if (content.rejectedAttachments > 0) {
        _messengerKey.currentState?.showSnackBar(
          SnackBar(
            content: Text(Strings.of(nav.context).shareSomeFilesRejected),
          ),
        );
      }
      unawaited(
        openChatFromHomeNavigator<void>(
          nav,
          builder: (_) => ChatScreen(connection: connection, session: session),
        ).then((_) => _retryPendingShare()),
      );
    } catch (_) {
      if (mounted) {
        _messengerKey.currentState?.showSnackBar(
          SnackBar(content: Text(Strings.of(nav.context).shareOpenFailed)),
        );
      }
    } finally {
      _openingSharedContent = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _homeInitialLoadTimer?.cancel();
    _homeReadyTimer?.cancel();
    _startupProgress.dispose();
    _deferredNotificationInitTimer?.cancel();

    _sshIdleTimer?.cancel();
    _externalDataSyncControl.setMethodCallHandler(null);
    _linkSub?.cancel();
    widget.connManager.activeConnectionId.removeListener(_retryPendingShare);
    widget.connManager.connectionsRevision.removeListener(
      _syncBackgroundCronConnections,
    );
    _shareSub?.cancel();
    unawaited(_shareInbox.dispose());
    widget.connManager.activeConnectionId.removeListener(
      _retryPendingNewSessionLaunch,
    );
    widget.connManager.activeConnectionId.removeListener(
      _onHomeWidgetConnectionChanged,
    );
    widget.appLock.locked.removeListener(_retryPendingNewSessionLaunch);
    widget.appLock.locked.removeListener(_onAppLockNoticeGateChanged);
    _newSessionLaunchSub?.cancel();
    unawaited(_newSessionLaunchInbox.dispose());
    _inAppSub?.cancel();
    _dismissInAppNotice();
    activeChats.activeIds.removeListener(_onActiveChatsChanged);
    companion.dispose();
    unawaited(_companionPetGateway?.close());
    companionPresence.dispose();
    themeId.dispose();
    themeProfiles.dispose();
    fontId.dispose();
    localeId.dispose();
    voice.prepareReadAloudPlayback = null;
    voice.readAloud.removeListener(_onReadAloudRuntimeChanged);
    FlutterForegroundTask.removeTaskDataCallback(_onVoiceTaskData);
    // Gateado (spec 027): con el modo voz apagado el controlador nunca se
    // instanció (late final perezoso); leerlo aquí lo crearía solo para
    // destruirlos. `voice` (dictado/lectura) se libera siempre.
    if (kVoiceRuntimeEnabled) {
      voice.speaking.removeListener(_onVoicePrivacyGateChanged);
      widget.appLock.locked.removeListener(_onVoicePrivacyGateChanged);
      voiceConvo.removeListener(_onVoiceRuntimeChanged);
      voice.voiceConsent.removeListener(_onVoiceConsentChanged);
      widget.notifications.activeVoiceSessionId = null;
      voiceConvo.dispose();
    }
    voice.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeProfileStoreSnapshot>(
      valueListenable: themeProfiles,
      builder: (context, profiles, _) {
        final id = profiles.activeProfileId;
        final custom = profiles.customById(id);
        final component = ComponentProfiles.minimal;
        final activeTheme = custom == null
            ? AppTheme.fromId(id, componentProfile: component)
            : AppTheme.fromProfile(custom, componentProfile: component);
        return ValueListenableBuilder<String>(
          valueListenable: fontId,
          builder: (context, font, _) => ValueListenableBuilder<String>(
            valueListenable: localeId,
            builder: (context, locId, _) => MaterialApp(
              title: 'Hermes Console',
              debugShowCheckedModeBanner: false,
              // Scroll con inercia (coasting) en toda la app: un flick sigue
              // rodando y frena solo, en vez del frenazo seco de Material.
              scrollBehavior: const MomentumScrollBehavior(),
              locale: AppLocales.byId(locId).locale,
              localizationsDelegates: Strings.localizationsDelegates,
              supportedLocales: Strings.supportedLocales,
              // El único idioma completo además del inglés es el español: si el
              // sistema (o la elección manual) es español lo usamos; en cualquier
              // otro caso caemos a inglés, nunca a un español a medias. Cubre los
              // tres casos: elección manual 'es'/'en' y modo "Sistema" (locale
              // nulo → llega el idioma del dispositivo).
              localeResolutionCallback: (locale, supported) {
                if (locale?.languageCode == 'es') return const Locale('es');
                return const Locale('en');
              },
              theme: AppFonts.applyToTheme(activeTheme, AppFonts.byId(font)),
              // Transición suave al cambiar de tema (sensación premium).
              themeAnimationDuration: const Duration(milliseconds: 420),
              themeAnimationCurve: Curves.easeInOutCubic,
              navigatorKey: _navigatorKey,
              scaffoldMessengerKey: _messengerKey,
              navigatorObservers: [hermesRouteObserver],
              // El gate orquesta una ruta de bloqueo sobre el Navigator raíz: cubre
              // también las rutas empujadas, sin Overlay casero.
              builder: (context, navChild) => ListenableBuilder(
                // Escala global de texto: reconstruye el MediaQuery raíz al cambiar
                // el nivel, sin reiniciar la app. Envuelve también el AppLockGate
                // para que la pantalla de bloqueo respete el tamaño elegido.
                listenable: widget.fontSize,
                builder: (context, _) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    // Composición, no reemplazo: si el usuario activó texto
                    // grande en Ajustes del sistema (accesibilidad), esa
                    // preferencia debe notarse aunque no toque el selector de
                    // tamaño interno de la app. Multiplicar el factor del
                    // sistema por el nuestro respeta ambos ajustes a la vez
                    // (auditoría 2026-07-02, hallazgo C5b).
                    textScaler: TextScaler.linear(
                      MediaQuery.of(context).textScaler.scale(1.0) *
                          widget.fontSize.scale,
                    ),
                  ),
                  child: WithForegroundTask(
                    child: AppLockGate(
                      lock: widget.appLock,
                      navigatorKey: _navigatorKey,
                      child: navChild!,
                    ),
                  ),
                ),
              ),
              home: _showOnboarding
                  ? _showSplash
                        ? SplashScreen(onDone: _finishSplash)
                        : OnboardingScreen(
                            connManager: widget.connManager,
                            onDone: _finishOnboarding,
                          )
                  : Stack(
                      fit: StackFit.expand,
                      children: [
                        if (_startHomeInitialLoad)
                          HomeDashboardScreen(
                            connManager: widget.connManager,
                            onInitialLoadProgress: _reportStartupProgress,
                            onInitialLoadComplete: _markHomeInitialLoadComplete,
                          ),
                        if (_showSplash)
                          SplashScreen(
                            ready: _homeInitialLoadComplete,
                            progress: _startupProgress,
                            onDone: _finishSplash,
                          ),
                      ],
                    ),
            ),
          ),
        );
      },
    );
  }
}
