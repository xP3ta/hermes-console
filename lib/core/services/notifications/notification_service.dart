// Notificaciones locales del agente — 100% on-device, sin FCM/Google/push.
//
// Las dispara la propia app para avisar de eventos importantes mientras está
// en segundo plano: aprobaciones pendientes, ejecuciones terminadas y
// respuestas listas. Privacidad: nada sale del dispositivo; no hay token de
// push ni servidor intermedio. El usuario controla qué eventos avisan.
import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../utils/markdown_clipboard.dart';
import 'notification_event_ledger.dart';
import 'notification_strings.dart';

/// Tipos de evento que pueden notificar (cada uno con su toggle).
enum NotificationKind { approval, run, reply, test, localAgent }

/// Superficie propietaria de una sesión accionable.
///
/// Los payloads legacy no incluían este campo y se interpretan como [normal].
enum NotificationChatSurface {
  normal,
  bot,
  room;

  static NotificationChatSurface fromWire(Object? raw) =>
      switch (raw?.toString().trim().toLowerCase()) {
        'bot' => bot,
        'room' => room,
        _ => normal,
      };
}

/// Estado del canal de alertas a ojos del sistema (para el diagnóstico de la UI).
enum ChannelStatus {
  /// El canal existe y el sistema lo deja sonar (importancia > none).
  active,

  /// El canal existe pero el usuario lo bloqueó en los ajustes del sistema
  /// (importancia = none): los avisos NO aparecerán aunque el permiso esté dado.
  blocked,

  /// El canal aún no se ha creado (init no corrió) o no se pudo consultar.
  missing,
}

/// Destino de una notificación que el usuario pulsa: identifica la sesión (y su
/// instancia) a la que navegar. Lo decodifica [NotificationService] del payload
/// y lo entrega a quien haya registrado [NotificationService.onOpenSession].
class NotificationOpen {
  final String connId;
  final String sessionId;
  final String? title;
  final String? profile;
  final NotificationChatSurface surface;
  final String? roomId;

  /// Tarjeta Kanban exacta que debe abrirse al tocar el aviso.
  final String? taskId;

  /// ID de la ejecución (v1/runs). Presente cuando la notificación proviene
  /// del Task Center; ausente en notificaciones de chat (compatibilidad).
  final String? runId;

  const NotificationOpen({
    required this.connId,
    this.sessionId = '',
    this.title,
    this.profile,
    this.surface = NotificationChatSurface.normal,
    this.roomId,
    this.runId,
    this.taskId,
  });

  String toPayload({String? base}) => jsonEncode({
    'conn': connId,
    if (sessionId.isNotEmpty) 'sid': sessionId,
    if (title != null && title!.isNotEmpty) 'title': title,
    if (runId != null && runId!.isNotEmpty) 'rid': runId,
    if (taskId != null && taskId!.isNotEmpty) 'tid': taskId,
    if (profile != null && profile!.isNotEmpty) 'profile': profile,
    'surface': surface.name,
    if (roomId != null && roomId!.isNotEmpty) 'room': roomId,
    if (base != null && base.isNotEmpty) 'base': base,
  });

  /// Decodifica payloads actuales y legacy. Campos desconocidos se ignoran.
  static NotificationOpen? tryParse(String? payload) {
    if (payload == null || payload.isEmpty) return null;
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map) return null;
      final m = Map<String, dynamic>.from(decoded);
      final conn = (m['conn'] ?? '').toString();
      if (conn.isEmpty) return null;
      final sid = (m['sid'] ?? '').toString();
      final runId = (m['rid'] ?? '').toString();
      final taskId = (m['tid'] ?? '').toString();
      if (sid.isEmpty && runId.isEmpty && taskId.isEmpty) return null;
      final title = m['title']?.toString();
      final profile = m['profile']?.toString();
      final roomId = m['room']?.toString();
      return NotificationOpen(
        connId: conn,
        sessionId: sid,
        title: title,
        profile: profile?.isNotEmpty == true ? profile : null,
        surface: NotificationChatSurface.fromWire(m['surface']),
        roomId: roomId?.isNotEmpty == true ? roomId : null,
        runId: runId.isNotEmpty ? runId : null,
        taskId: taskId.isNotEmpty ? taskId : null,
      );
    } catch (e) {
      debugPrint('[hermes-notif] excepción silenciada (se devuelve null): $e');
      return null;
    }
  }
}

/// Devuelve `true` cuando el destino se pudo abrir. Si la shell todavía no
/// tiene un Navigator o la conexión aún no está disponible, devuelve `false`
/// para que [NotificationService] conserve el toque y lo reintente.
typedef NotificationOpenHandler = bool Function(NotificationOpen open);

/// Aviso discreto para mostrar DENTRO de la app (una tarjeta flotante con acción
/// "Ir"), no como notificación del sistema. Se emite cuando un evento (respuesta
/// lista, aprobación, fin de ejecución) ocurre en un chat distinto al que el
/// usuario está mirando, con la app en primer plano (Regla 2): la notificación
/// del sistema sería ruido, pero el usuario debe enterarse igualmente.
class InAppNotice {
  final NotificationKind kind;
  final String title;
  final String body;

  /// Destino al que navegar si el usuario pulsa "Ir" (mismo payload que usaría
  /// la notificación del sistema).
  final NotificationOpen open;

  const InAppNotice({
    required this.kind,
    required this.title,
    required this.body,
    required this.open,
  });
}

/// Interfaz mínima que NotificationController necesita de NotificationService.
/// Permite testear el controlador sin instanciar el servicio real.
abstract interface class RunNotificationFacade {
  bool get notifyRuns;
  Future<void> runLive({
    required String runId,
    required String title,
    required String body,
    String? connId,
    String? sessionId,
  });
  Future<void> runFinished({
    required String title,
    required bool ok,
    String? connId,
    String? sessionId,
    String? runId,
    String? profile,
  });
  Future<void> approvalPending({
    required String tool,
    String? instance,
    String? connId,
    String? sessionId,
    String? sessionTitle,
    String? runId,
    String? base,
    NotificationChatSurface surface = NotificationChatSurface.normal,
    String? profile,
    String? roomId,
  });
  Future<void> cancelRun(String runId);

  /// Cancela la notificación de aprobación global (ID 7001).
  /// No-op si no hay ninguna mostrándose.
  Future<void> cancelApproval();
}

class NotificationService implements RunNotificationFacade {
  final SharedPreferences _prefs;
  late final NotificationEventLedger _eventLedger = NotificationEventLedger(
    _prefs,
  );
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _inited = false;
  bool _available = false;
  Future<void>? _initFuture;

  /// Evita adelantar la inicialización diferida durante el Splash cuando la
  /// shell solo quiere recuperar un `onNewIntent` al volver al foreground.
  bool get initialized => _inited;

  /// Si la app está en primer plano no molestamos con notificaciones (el
  /// usuario ya ve la UI); las aprobaciones son la excepción configurable.
  bool appInForeground = true;

  /// Sesión que el usuario está MIRANDO ahora mismo. La pantalla de chat la fija
  /// al hacerse visible y la limpia al ocultarse (vía RouteAware + lifecycle).
  /// Junto a [appInForeground] implementa la Regla 1/6: si un evento (aprobación,
  /// respuesta, fin de ejecución) es de ESTE chat y la app está delante, la UI
  /// inline ya lo muestra → NO duplicamos con una notificación del sistema.
  /// Null = no hay ningún chat en pantalla (home, ajustes, otra pestaña…).
  String? visibleSessionId;

  /// Sesión cuya respuesta ya está cubierta por la tarjeta de conversación de
  /// voz. Solo la fija el harness QA mientras esa superficie está activa.
  ///
  /// Evita que el mismo desenlace aparezca a la vez como tarjeta de voz y como
  /// “Hermes respondió”. Otras sesiones conservan sus avisos y las aprobaciones
  /// no pasan por esta regla.
  String? activeVoiceSessionId;

  /// Avisos discretos para mostrar DENTRO de la app cuando un evento es
  /// de un chat distinto al visible y la app está en primer plano (Regla 2). La
  /// shell de la app los escucha y muestra una tarjeta flotante con "Ir".
  /// Broadcast: vive lo que viva el singleton; sin oyentes simplemente se ignora.
  final StreamController<InAppNotice> _inApp =
      StreamController<InAppNotice>.broadcast();
  Stream<InAppNotice> get inAppNotices => _inApp.stream;

  /// Diagnóstico: traza el ciclo de vida de cada notificación. Solo activo en
  /// builds de debug (`kDebugMode`); silencioso en release.
  static const bool _debugLog = kDebugMode;

  void _log(String msg) {
    if (_debugLog) debugPrint('[hermes-notif] $msg');
  }

  /// Acento de marca (ámbar) para teñir el icono y el encabezado.
  static const Color _accent = Color(0xFFE8821C);

  /// Grupo común: agrupa todas las notificaciones de Hermes bajo un mismo hilo
  /// en la bandeja (en vez de sueltas).
  static const String _groupKey = 'hermes';

  /// ID fijo del resumen de grupo. Fuera de todos los rangos de alertas
  /// (reply 6000+, approval 7001, run 7100+, live 9000+, kanban 10000+).
  static const int _groupSummaryId = 500;

  /// ID de la notificación de prueba (no es una alerta hija del grupo).
  static const int _testNotificationId = 7000;

  /// ID de la notificación ongoing de modo voz (espejo de
  /// `VoiceNotificationController.notifId`): jerarquía D, nunca cuenta como
  /// hija de alerta aunque comparta `groupKey`. Se duplica el literal para no
  /// acoplar ambos servicios.
  static const int _voiceOngoingId = 8801;

  // Un canal POR TIPO para que el usuario ajuste sonido/importancia de cada
  // clase por separado en los ajustes de Android (premium). El antiguo canal
  // único `hermes_alerts` se borra en init (migración).
  static const String _chApprovals = 'hermes_approvals';
  static const String _chReplies = 'hermes_replies';
  static const String _chRuns = 'hermes_runs';
  static const String _legacyChannel = 'hermes_alerts';

  // Canal de baja importancia (sin sonido) para el progreso de transferencias
  // SFTP en segundo plano: barra de progreso silenciosa que no molesta.
  static const String _transferChannelId = 'hermes_transfers';
  static const String _transferChannelName = 'SFTP Transfers';
  static const String _transferChannelDesc =
      'Upload and download progress via SFTP';

  /// Llamado cuando el usuario pulsa una notificación con sesión asociada. Lo
  /// cablea HermesAppState para navegar al chat correcto. Si es null al pulsar
  /// (p.ej. la app se abrió desde cero por la notificación, antes de montar la
  /// UI), el destino se guarda en [_pendingOpen] y se consume con
  /// [takePendingOpen] tras el arranque.
  NotificationOpenHandler? _onOpenSession;

  set onOpenSession(NotificationOpenHandler? handler) {
    _onOpenSession = handler;
    if (handler != null) retryPendingOpen();
  }

  NotificationOpen? _pendingOpen;
  String? _lastPlatformOpenFingerprint;

  /// Última notificación mostrada con la app en 2º plano (respuesta/ejecución/
  /// aprobación). Se guarda para poder RE-AFIRMARLA tras parar el foreground
  /// service: `stopService()` ejecuta `stopForeground(STOP_FOREGROUND_REMOVE)`,
  /// que en algunos dispositivos arrastra la notificación recién posteada (el
  /// sistema enlaza la notificación persistente del servicio con la de alerta
  /// como dueña de sonido/vibración). Re-mostrarla —en silencio— garantiza que
  /// sobreviva al desmontaje del servicio. Ver [reassertRecent].
  _LastBgNotif? _lastBg;

  NotificationService(this._prefs);

  // ── Ajustes (persistidos) ───────────────────────────────────────────────
  static const _kEnabled = 'notif_enabled';
  static const _kApprovals = 'notif_approvals';
  static const _kRuns = 'notif_runs';
  static const _kCronResults = 'notif_cron_results';
  static const _kKanbanResults = 'notif_kanban_results';
  static const _kReplies = 'notif_replies';
  static const _kForeground = 'notif_even_foreground';
  static const _kHideSensitive = 'notif_hide_sensitive_content';
  // Marca de que ya se pidió el permiso una vez (para no insistir en cada
  // arranque; Android 13+ solo muestra el diálogo la primera vez de todos modos).
  static const _kPermRequested = 'notif_perm_requested';

  /// El descubrimiento de resultados cron necesita el listener persistente.
  /// Compartir la clave evita que UI y servicio mantengan dos opt-ins distintos.
  static const backgroundListenPreferenceKey = 'notif_background_listen';

  bool get enabled => _prefs.getBool(_kEnabled) ?? true;
  Future<void> setEnabled(bool v) => _prefs.setBool(_kEnabled, v);

  bool get notifyApprovals => _prefs.getBool(_kApprovals) ?? true;
  Future<void> setNotifyApprovals(bool v) => _prefs.setBool(_kApprovals, v);

  @override
  bool get notifyRuns => _prefs.getBool(_kRuns) ?? true;
  Future<void> setNotifyRuns(bool v) => _prefs.setBool(_kRuns, v);

  bool get notifyCronResults =>
      _prefs.getBool(_kCronResults) ??
      (_prefs.getBool(backgroundListenPreferenceKey) ?? false);
  Future<void> setNotifyCronResults(bool v) => _prefs.setBool(_kCronResults, v);

  /// Kanban tiene opt-in propio, independiente del de Cron. Si el usuario
  /// nunca lo tocó (p. ej. al actualizar desde una versión sin esta clave),
  /// hereda el opt-in de automatizaciones —la escucha en segundo plano,
  /// estable— para no silenciar avisos que ya estaban activos. Nunca consulta
  /// la preferencia de Cron: apagar Cron no puede apagar Kanban.
  bool get notifyKanbanResults =>
      _prefs.getBool(_kKanbanResults) ??
      (_prefs.getBool(backgroundListenPreferenceKey) ?? false);
  Future<void> setNotifyKanbanResults(bool v) =>
      _prefs.setBool(_kKanbanResults, v);

  bool get notifyReplies => _prefs.getBool(_kReplies) ?? true;
  Future<void> setNotifyReplies(bool v) => _prefs.setBool(_kReplies, v);

  /// Avisar también con la app en primer plano (por defecto no, salvo aprobaciones).
  bool get evenInForeground => _prefs.getBool(_kForeground) ?? false;
  Future<void> setEvenInForeground(bool v) => _prefs.setBool(_kForeground, v);

  /// Sustituye títulos y cuerpos por un aviso genérico en la bandeja del
  /// sistema. Los banners dentro de la app conservan el contenido completo.
  bool get hideSensitiveContent => _prefs.getBool(_kHideSensitive) ?? false;
  Future<void> setHideSensitiveContent(bool v) =>
      _prefs.setBool(_kHideSensitive, v);

  bool get available => _available;

  // ── Inicialización ──────────────────────────────────────────────────────
  Future<void> init() async {
    if (_inited) return;
    final pending = _initFuture;
    if (pending != null) return pending;
    _initFuture = _doInit();
    return _initFuture!;
  }

  Future<void> _doInit() async {
    const android = AndroidInitializationSettings('ic_stat_hermes');
    const settings = InitializationSettings(android: android);
    try {
      await _plugin.initialize(
        settings,
        // Tap con la app viva (primer plano o 2º plano): navega a la sesión.
        // No hay acciones de fondo: las aprobaciones solo ofrecen "Abrir" y
        // la decisión se toma siempre dentro de la app, nunca desde la
        // bandeja ni desde la pantalla de bloqueo.
        onDidReceiveNotificationResponse: _onNotificationTap,
      );
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      final t = NotifL10n.of(_prefs);
      // Migración: borra el canal único antiguo para que no quede huérfano en
      // los ajustes del sistema. Sus notificaciones ya caducaron.
      try {
        await android?.deleteNotificationChannel(_legacyChannel);
      } catch (e) {
        debugPrint(
          '[hermes-notif] excepción silenciada (se ignora sin más): $e',
        );
      }
      // Un canal por tipo (nombres localizados). Aprobaciones y respuestas
      // alertan (heads-up); ejecuciones es de importancia normal (menos ruido).
      await android?.createNotificationChannel(
        AndroidNotificationChannel(
          _chApprovals,
          t.chApprovals,
          description: t.chApprovalsDesc,
          importance: Importance.high,
          ledColor: _accent,
          enableLights: true,
          enableVibration: true,
          playSound: true,
        ),
      );
      await android?.createNotificationChannel(
        AndroidNotificationChannel(
          _chReplies,
          t.chReplies,
          description: t.chRepliesDesc,
          importance: Importance.high,
          ledColor: _accent,
          enableLights: true,
          enableVibration: true,
          playSound: true,
        ),
      );
      await android?.createNotificationChannel(
        AndroidNotificationChannel(
          _chRuns,
          t.chRuns,
          description: t.chRunsDesc,
          importance: Importance.defaultImportance,
          ledColor: _accent,
          enableLights: true,
        ),
      );
      _log('canales por tipo creados (approvals/replies/runs)');
      await android?.createNotificationChannel(
        const AndroidNotificationChannel(
          _transferChannelId,
          _transferChannelName,
          description: _transferChannelDesc,
          importance: Importance.low,
          enableVibration: false,
          playSound: false,
        ),
      );
      // Si la app se ABRIÓ pulsando una notificación estando muerta, recupera el
      // destino para navegar tras montar la UI (solo en el isolate de UI).
      if (appInForeground) {
        try {
          final launch = await _plugin.getNotificationAppLaunchDetails();
          if (launch?.didNotificationLaunchApp ?? false) {
            final response = launch!.notificationResponse;
            if (response != null) {
              _handleOpenResponse(response, suppressRecentDuplicate: true);
            }
          }
        } catch (e) {
          debugPrint(
            '[hermes-notif] excepción silenciada (se ignora sin más): $e',
          );
        }
      }
      _available = true;
      _log('init OK (appInForeground=$appInForeground)');
      // Pide el permiso (Android 13+) en el arranque, una sola vez. Nunca desde
      // el isolate del servicio en 2º plano (no hay Activity para el diálogo).
      await _maybeAutoRequestPermission();
    } catch (e) {
      _available = false;
      _log('init FALLÓ: $e');
    } finally {
      _inited = true;
      _initFuture = null;
    }
  }

  /// Pide POST_NOTIFICATIONS una única vez al arrancar (si la app está en primer
  /// plano y no se pidió antes). Idempotente: Android no re-muestra el diálogo.
  Future<void> _maybeAutoRequestPermission() async {
    if (!appInForeground) return;
    if (_prefs.getBool(_kPermRequested) == true) return;
    await _prefs.setBool(_kPermRequested, true);
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    try {
      final granted = await android?.requestNotificationsPermission();
      _log('POST_NOTIFICATIONS solicitado al arranque → granted=$granted');
    } catch (e) {
      _log('POST_NOTIFICATIONS request falló: $e');
    }
  }

  // ── Navegación al pulsar ────────────────────────────────────────────────

  void _onNotificationTap(NotificationResponse response) {
    _handleOpenResponse(response);
  }

  bool _handleOpenResponse(
    NotificationResponse response, {
    bool suppressRecentDuplicate = false,
  }) {
    final open = _decodePayload(response.payload);
    if (open == null) {
      _log('tap ignorado: payload sin destino válido');
      return false;
    }
    final fingerprint = '${response.id ?? -1}\u001f${response.payload ?? ''}';
    final duplicate =
        suppressRecentDuplicate && fingerprint == _lastPlatformOpenFingerprint;
    if (duplicate) {
      _log('tap de plataforma ya entregado; se omite duplicado inmediato');
      return false;
    }
    _lastPlatformOpenFingerprint = fingerprint;
    return _deliverOrQueue(open);
  }

  bool _deliverOrQueue(NotificationOpen open) {
    final handler = _onOpenSession;
    if (handler != null) {
      try {
        if (handler(open)) {
          _pendingOpen = null;
          _log('tap entregado a la navegación');
          return true;
        }
      } catch (error) {
        _log('navegación del tap no disponible todavía: $error');
      }
    }
    _pendingOpen = open;
    _log('tap conservado para reintento');
    return false;
  }

  /// Reintenta un toque que llegó antes de que la shell pudiera navegar.
  bool retryPendingOpen() {
    final open = _pendingOpen;
    if (open == null) return false;
    return _deliverOrQueue(open);
  }

  /// Red de seguridad para Android: si `onNewIntent` reanudó la Activity pero
  /// el callback del plugin no alcanzó el isolate de UI, vuelve a leer el
  /// intent que conserva `flutter_local_notifications`. El callback vivo no se
  /// deduplica; solo se impide que el mismo intent persistente sea recuperado
  /// otra vez en cada `resumed` posterior.
  Future<bool> recoverPlatformOpen() async {
    await init();
    if (retryPendingOpen()) return true;
    try {
      final launch = await _plugin.getNotificationAppLaunchDetails();
      if (!(launch?.didNotificationLaunchApp ?? false)) return false;
      final response = launch!.notificationResponse;
      if (response == null) return false;
      return _handleOpenResponse(response, suppressRecentDuplicate: true);
    } catch (error) {
      _log('no se pudo recuperar el tap de plataforma: $error');
      return false;
    }
  }

  /// Devuelve (y limpia) el destino pendiente de una notificación que abrió la
  /// app. Lo llama HermesAppState tras el primer frame.
  NotificationOpen? takePendingOpen() {
    final o = _pendingOpen;
    _pendingOpen = null;
    return o;
  }

  static String? _encodePayload(
    String? connId,
    String? sessionId,
    String? title, {
    String? runId,
    String? base,
    String? profile,
    NotificationChatSurface surface = NotificationChatSurface.normal,
    String? roomId,
    String? taskId,
  }) {
    if (connId == null || connId.isEmpty) return null;
    final hasSid = sessionId != null && sessionId.isNotEmpty;
    final hasRid = runId != null && runId.isNotEmpty;
    final hasTaskId = taskId != null && taskId.isNotEmpty;
    // Chat necesita sessionId; runs y Kanban llevan su objeto autoritativo.
    if (!hasSid && !hasRid && !hasTaskId) return null;
    return NotificationOpen(
      connId: connId,
      sessionId: hasSid ? sessionId : '',
      title: title,
      profile: profile,
      surface: surface,
      roomId: roomId,
      runId: hasRid ? runId : null,
      taskId: hasTaskId ? taskId : null,
    ).toPayload(base: base);
  }

  static NotificationOpen? _decodePayload(String? payload) =>
      NotificationOpen.tryParse(payload);

  /// Pide el permiso POST_NOTIFICATIONS (Android 13+). Devuelve si quedó
  /// concedido. Idempotente y seguro de llamar varias veces.
  Future<bool> requestPermission() async {
    await init();
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    return await android?.requestNotificationsPermission() ?? false;
  }

  Future<bool> permissionGranted() async {
    await init();
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    return await android?.areNotificationsEnabled() ?? false;
  }

  /// Estado del canal `hermes_alerts` según el sistema. Permite avisar al usuario
  /// de que tiene el permiso global pero ha bloqueado ESTE canal (causa silenciosa
  /// muy común de "no me llegan las notificaciones" en móviles reales).
  Future<ChannelStatus> alertChannelStatus() async {
    await init();
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (android == null) return ChannelStatus.missing;
    try {
      final channels = await android.getNotificationChannels() ?? const [];
      AndroidNotificationChannel? ch;
      for (final c in channels) {
        if (c.id == _chApprovals) ch = c;
      }
      if (ch == null) return ChannelStatus.missing;
      return ch.importance == Importance.none
          ? ChannelStatus.blocked
          : ChannelStatus.active;
    } catch (e) {
      _log('no se pudo leer el estado del canal: $e');
      return ChannelStatus.missing;
    }
  }

  // ── Disparadores de alto nivel ──────────────────────────────────────────

  /// El agente pide aprobar una herramienta. Importante: por defecto avisa
  /// aunque la app esté en primer plano (es accionable y sensible al tiempo).
  @override
  Future<void> approvalPending({
    required String tool,
    String? instance,
    String? connId,
    String? sessionId,
    String? sessionTitle,
    String? runId,
    String? base,
    NotificationChatSurface surface = NotificationChatSurface.normal,
    String? profile,
    String? roomId,
  }) async {
    if (!notifyApprovals) return;
    if (!await _eventLedger.claim(
      connId: connId ?? '',
      profile: profile,
      objectId: runId ?? '',
      eventKind: 'approval_required',
    )) {
      return;
    }
    final t = NotifL10n.of(_prefs);
    final where = (instance != null && instance.isNotEmpty)
        ? ' · $instance'
        : '';
    // La aprobación NUNCA se resuelve desde la bandeja: el plugin no puede
    // exigir desbloqueo por acción y una decisión de seguridad no debe poder
    // tomarse desde la pantalla de bloqueo. Solo "Abrir", que trae la app al
    // frente; la decisión vive dentro, tras la autenticación del sistema.
    try {
      await _show(
        kind: NotificationKind.approval,
        id: 7001,
        title: t.approvalTitle,
        body: t.approvalBody(tool, where),
        ongoingFeel: true,
        bypassForeground: true,
        targetSessionId: sessionId,
        subText: instance,
        payload: _encodePayload(
          connId,
          sessionId,
          sessionTitle ?? instance,
          runId: runId,
          base: base,
          profile: profile,
          surface: surface,
          roomId: roomId,
        ),
        actions: <AndroidNotificationAction>[
          AndroidNotificationAction(
            'open',
            t.actOpen,
            showsUserInterface: true,
            cancelNotification: true,
          ),
        ],
      );
    } catch (_) {
      await _eventLedger.release(
        connId: connId ?? '',
        profile: profile,
        objectId: runId ?? '',
        eventKind: 'approval_required',
      );
      rethrow;
    }
  }

  /// Una ejecución terminó (ok o con error).
  @override
  Future<void> runFinished({
    required String title,
    required bool ok,
    String? connId,
    String? sessionId,
    String? runId,
    String? profile,
  }) async {
    if (!notifyRuns) return;
    if (!await _eventLedger.claim(
      connId: connId ?? '',
      profile: profile,
      objectId: runId ?? '',
      eventKind: 'run_terminal',
    )) {
      return;
    }
    final t = NotifL10n.of(_prefs);
    try {
      await _show(
        kind: NotificationKind.run,
        id: eventNotificationId(
          base: 7100,
          span: 1024,
          parts: [connId ?? '', profile ?? '', runId ?? '', 'run_terminal'],
        ),
        title: ok ? t.runCompleted : t.runFailed,
        body: title,
        targetSessionId: sessionId,
        payload: _encodePayload(
          connId,
          sessionId,
          title,
          runId: runId,
          profile: profile,
        ),
      );
    } catch (_) {
      await _eventLedger.release(
        connId: connId ?? '',
        profile: profile,
        objectId: runId ?? '',
        eventKind: 'run_terminal',
      );
      rethrow;
    }
  }

  /// Resultado de una automatización cron descubierta desde las sesiones de
  /// Hermes Desktop. Usa su propio opt-in ([notifyCronResults]), independiente
  /// del de Kanban y del toggle de runs iniciadas desde Task Center.
  Future<void> cronFinished({
    required String title,
    required bool ok,
    required String connId,
    required String sessionId,
    required String executionId,
    required String jobId,
    String? profile,
    String? preview,
  }) async {
    if (!notifyCronResults) return;
    if (!await _eventLedger.claim(
      connId: connId,
      profile: profile,
      objectId: executionId,
      eventKind: 'cron_terminal',
    )) {
      return;
    }
    final t = NotifL10n.of(_prefs);
    try {
      await _show(
        kind: NotificationKind.run,
        id: eventNotificationId(
          base: 7100,
          span: 1024,
          parts: [
            connId,
            profile ?? '',
            executionId.isNotEmpty ? executionId : jobId,
            'cron_terminal',
          ],
        ),
        title: ok ? t.cronCompleted : t.cronFailed,
        body: compactAutomationPreview(preview, fallback: title),
        targetSessionId: sessionId,
        subText: compactSessionLabel(title),
        payload: _encodePayload(connId, sessionId, title, profile: profile),
      );
    } catch (_) {
      await _eventLedger.release(
        connId: connId,
        profile: profile,
        objectId: executionId,
        eventKind: 'cron_terminal',
      );
      rethrow;
    }
  }

  /// Convierte la respuesta final del agente en texto legible para la bandeja.
  /// Nunca usa el prompt del job como fallback: si el Dashboard no publica el
  /// último turno del asistente, muestra únicamente el nombre de la tarea.
  @visibleForTesting
  static String compactAutomationPreview(
    String? raw, {
    required String fallback,
  }) {
    final source = (raw ?? '')
        .replaceAll(RegExp(r'[\u0000-\u001F\u007F-\u009F]'), ' ')
        .replaceAll(RegExp(r'[\u202A-\u202E\u2066-\u2069]'), ' ');
    final compact = markdownToCompactText(source).trim();
    final visible = compact.isEmpty ? compactSessionLabel(fallback) : compact;
    const maxRunes = 280;
    final runes = visible.runes.toList(growable: false);
    if (runes.length <= maxRunes) return visible;
    return '${String.fromCharCodes(runes.take(maxRunes - 1))}…';
  }

  /// Transición relevante del Kanban oficial de Hermes Agent 0.20. El aviso
  /// lleva el `taskId` autoritativo en el payload: el tap abre la tarjeta
  /// exacta en TasksScreen, sin inventar un destino de Task Center.
  /// Opt-in propio ([notifyKanbanResults]), independiente del de Cron.
  Future<void> kanbanTransition({
    required String connId,
    required String taskId,
    required String title,
    required String status,
  }) {
    if (!notifyKanbanResults) return Future.value();
    final t = NotifL10n.of(_prefs);
    final notificationTitle = switch (status) {
      'done' => t.kanbanCompleted,
      'blocked' => t.kanbanBlocked,
      'triage' => t.kanbanNeedsAttention,
      _ => t.kanbanUpdated,
    };
    return _show(
      kind: NotificationKind.run,
      id: 10000 + (taskId.hashCode & 0x3ff),
      title: notificationTitle,
      body: title,
      subText: 'Kanban · $taskId',
      payload: _encodePayload(connId, null, title, taskId: taskId),
    );
  }

  /// Notificación de progreso de una ejecución en curso (Task Center). Rango
  /// de IDs reservado: 9000–9511 (no colisiona con BackgroundListener 7100–8123).
  /// [onlyAlertOnce: true] para no repetir sonido en cada actualización.
  @override
  Future<void> runLive({
    required String runId,
    required String title,
    required String body,
    String? connId,
    String? sessionId,
  }) {
    if (!notifyRuns) return Future.value();
    return _show(
      kind: NotificationKind.run,
      id: 9000 + (runId.hashCode & 0x1ff),
      title: title,
      body: body,
      ongoingFeel: true,
      targetSessionId: sessionId,
      payload: _encodePayload(connId, sessionId, title, runId: runId),
    );
  }

  /// Cancela la notificación de progreso de un run (si la hay).
  @override
  Future<void> cancelRun(String runId) =>
      cancelById(9000 + (runId.hashCode & 0x1ff), 'cancelRun');

  /// La respuesta del asistente está lista (app en segundo plano). [session] es
  /// el título legible de la sesión: si se conoce, lo nombramos para que el
  /// usuario sepa de qué chat se trata sin abrir la app.
  Future<void> replyReady({
    required String preview,
    String? instance,
    String? session,
    String? connId,
    String? sessionId,
    NotificationChatSurface surface = NotificationChatSurface.normal,
    String? profile,
    String? roomId,
  }) {
    if (!notifyReplies) return Future.value();
    if (shouldSuppressReplyForActiveVoice(
      activeVoiceSessionId: activeVoiceSessionId,
      targetSessionId: sessionId,
    )) {
      return Future.value();
    }
    final t = NotifL10n.of(_prefs);
    final label = compactSessionLabel(session);
    final visibleLabel = _replyIdentity(instance: instance, session: label);
    return _show(
      kind: NotificationKind.reply,
      id: replyNotificationId(
        connId: connId,
        sessionId: sessionId,
        session: label,
      ),
      title: t.replyTitle(visibleLabel),
      // La bandeja identifica el chat, pero nunca replica la respuesta: además
      // de evitar Markdown crudo, mantiene el aviso pequeño y no filtra texto.
      body: t.replyReadyBody,
      targetSessionId: sessionId,
      payload: _encodePayload(
        connId,
        sessionId,
        label,
        profile: profile,
        surface: surface,
        roomId: roomId,
      ),
      compact: true,
    );
  }

  /// El turno del agente falló (app en segundo plano). Se agrupa con las
  /// respuestas (mismo toggle [notifyReplies]) porque es el desenlace —fallido—
  /// del mensaje que el usuario envió.
  Future<void> replyFailed({
    required String session,
    String? instance,
    String? detail,
    String? connId,
    String? sessionId,
    NotificationChatSurface surface = NotificationChatSurface.normal,
    String? profile,
    String? roomId,
  }) {
    if (!notifyReplies) return Future.value();
    final t = NotifL10n.of(_prefs);
    final label = compactSessionLabel(session);
    final visibleLabel = _replyIdentity(instance: instance, session: label);
    return _show(
      kind: NotificationKind.reply,
      id: replyNotificationId(
        connId: connId,
        sessionId: sessionId,
        session: label,
      ),
      title: t.replyFailedTitle(visibleLabel),
      // El detalle puede contener salida parcial, Markdown, rutas o mensajes de
      // transporte. La causa completa permanece dentro del chat; la bandeja
      // solo comunica el estado y la conversación afectada.
      body: t.replyFailedBody,
      targetSessionId: sessionId,
      payload: _encodePayload(
        connId,
        sessionId,
        label,
        profile: profile,
        surface: surface,
        roomId: roomId,
      ),
      compact: true,
    );
  }

  /// Una alerta por conversación: el éxito y el fallo del mismo turno se
  /// reemplazan entre sí, mientras chats distintos pueden convivir. El rango
  /// 6000–6511 queda separado de alertas fijas, runs y modo voz.
  @visibleForTesting
  static int replyNotificationId({
    String? connId,
    String? sessionId,
    String? session,
  }) {
    final identity = [
      connId?.trim() ?? '',
      sessionId?.trim() ?? '',
      session?.trim() ?? '',
    ].join('\u001f');
    // `String.hashCode` no forma parte de un contrato persistente entre
    // procesos. Una función FNV-1a fija evita que, tras reiniciar Android, el
    // mismo chat deje dos avisos en vez de reemplazar el anterior.
    var hash = 0x811c9dc5;
    for (final byte in utf8.encode(identity)) {
      hash ^= byte;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return 6000 + (hash & 0x1ff);
  }

  /// ID estable entre procesos derivado solo de identidad autoritativa.
  @visibleForTesting
  static int eventNotificationId({
    required int base,
    required int span,
    required List<String> parts,
  }) {
    var hash = 0x811c9dc5;
    for (final byte in utf8.encode(parts.join('\u001f'))) {
      hash ^= byte;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return base + (hash % span);
  }

  /// Los títulos proceden del servidor y pueden contener Markdown, controles o
  /// varias líneas. La bandeja solo necesita una etiqueta breve y legible.
  @visibleForTesting
  static String compactSessionLabel(String? raw) {
    final source = (raw ?? '')
        .replaceAll(RegExp(r'[\u0000-\u001F\u007F-\u009F]'), ' ')
        .replaceAll(RegExp(r'[\u202A-\u202E\u2066-\u2069]'), ' ');
    final compact = markdownToCompactText(
      source,
    ).replaceAll(RegExp(r'\s+'), ' ').trim();
    const maxRunes = 56;
    final runes = compact.runes.toList(growable: false);
    if (runes.length <= maxRunes) return compact;
    return '${String.fromCharCodes(runes.take(maxRunes - 1))}…';
  }

  static String _replyIdentity({String? instance, String? session}) {
    final instanceLabel = compactSessionLabel(instance);
    final sessionLabel = compactSessionLabel(session);
    if (instanceLabel.isEmpty) return sessionLabel;
    if (sessionLabel.isEmpty || sessionLabel == instanceLabel) {
      return instanceLabel;
    }
    return '$instanceLabel · $sessionLabel';
  }

  /// La instalación del agente local terminó (éxito o fallo). Solo avisa si la
  /// app NO está en primer plano (segundo plano, pantalla apagada o bloqueada):
  /// es para enterarse del desenlace de una operación larga que el usuario dejó
  /// corriendo; si está mirando la pantalla ya lo ve y no hace falta molestar.
  /// No usa bypassForeground, así que respeta la supresión en primer plano.
  Future<void> localInstallFinished({required bool ok, String? detail}) {
    final t = NotifL10n.of(_prefs);
    final reason = detail?.trim();
    return _show(
      kind: NotificationKind.localAgent,
      id: 7200,
      title: ok ? t.localInstalled : t.localInstallError,
      body: ok
          ? t.localInstalledBody
          : (reason != null && reason.isNotEmpty
                ? reason
                : t.localInstallErrorBody),
    );
  }

  /// La desinstalación del agente local terminó (éxito o con restos). Mismas
  /// reglas que [localInstallFinished]: solo avisa con la app en segundo plano.
  Future<void> localUninstallFinished({required bool ok, String? detail}) {
    final t = NotifL10n.of(_prefs);
    final reason = detail?.trim();
    return _show(
      kind: NotificationKind.localAgent,
      id: 7201,
      title: ok ? t.localRemoved : t.localRemoveError,
      body: ok
          ? t.localRemovedBody
          : (reason != null && reason.isNotEmpty
                ? reason
                : t.localRemoveErrorBody),
    );
  }

  /// Notificación de prueba (desde Ajustes), para que el usuario vea el estilo.
  Future<bool> sendTest() {
    final t = NotifL10n.of(_prefs);
    return _show(
      kind: NotificationKind.test,
      id: 7000,
      title: t.testTitle,
      body: t.testBody,
      bypassForeground: true,
      // La prueba muestra también el botón interactivo "Abrir" (las reales lo
      // traen por su destino vía payload).
      actions: [
        AndroidNotificationAction(
          'open',
          t.actOpen,
          showsUserInterface: true,
          cancelNotification: true,
        ),
      ],
    );
  }

  // ── Transferencias SFTP (progreso silencioso) ────────────────────────────

  /// Notificación de progreso de una transferencia (barra). [progress] y [max]
  /// en la misma unidad (p.ej. bytes/1024). [indeterminate] si no se sabe el
  /// total. Canal de baja importancia: no suena ni vibra. Se muestra también en
  /// primer plano (es informativa, no molesta) para que persista al salir.
  Future<void> transferProgress({
    required int id,
    required String title,
    required String body,
    required int progress,
    required int max,
    bool indeterminate = false,
  }) async {
    await init();
    if (!_available || !await permissionGranted()) return;
    final details = AndroidNotificationDetails(
      _transferChannelId,
      _transferChannelName,
      channelDescription: _transferChannelDesc,
      importance: Importance.low,
      priority: Priority.low,
      icon: 'ic_stat_hermes',
      color: _accent,
      onlyAlertOnce: true,
      ongoing: true,
      autoCancel: false,
      showProgress: true,
      maxProgress: max <= 0 ? 100 : max,
      progress: progress.clamp(0, max <= 0 ? 100 : max),
      indeterminate: indeterminate,
      category: AndroidNotificationCategory.progress,
    );
    await _plugin.show(id, title, body, NotificationDetails(android: details));
  }

  /// Notificación final de una transferencia (completada o con error). Reemplaza
  /// la de progreso (mismo [id]). Avisa con sonido si la app está en 2º plano.
  Future<void> transferDone({
    required int id,
    required String title,
    required String body,
    required bool ok,
  }) async {
    await init();
    if (!_available || !await permissionGranted()) return;
    final foreground = appInForeground;
    final t = NotifL10n.of(_prefs);
    final alert = ok && !foreground; // suena solo al terminar OK en 2º plano
    final details = AndroidNotificationDetails(
      alert ? _chRuns : _transferChannelId,
      alert ? t.chRuns : _transferChannelName,
      channelDescription: alert ? t.chRunsDesc : _transferChannelDesc,
      importance: foreground ? Importance.low : Importance.high,
      priority: foreground ? Priority.low : Priority.high,
      icon: 'ic_stat_hermes',
      color: _accent,
      onlyAlertOnce: true,
      ongoing: false,
      autoCancel: true,
      category: AndroidNotificationCategory.status,
    );
    await _plugin.show(id, title, body, NotificationDetails(android: details));
  }

  Future<void> cancelTransfer(int id) => cancelById(id, 'transfer');

  /// ¿Debe mostrarse una notificación del sistema, dada la situación de primer
  /// plano? Pura y testeable: concentra las Reglas 1/2/6.
  ///
  ///  - App en 2º plano → siempre se evalúa mostrar (true): el usuario no ve la UI.
  ///  - App en primer plano y el evento es del chat que está MIRANDO → false:
  ///    la tarjeta/respuesta inline ya lo muestra; notificar sería un duplicado.
  ///  - App en primer plano y el evento es de OTRO chat (o ninguno): solo si el
  ///    evento lo exige ([bypassForeground], p.ej. aprobaciones) o el usuario
  ///    activó avisos incluso en primer plano ([evenInForeground]). El aviso
  ///    discreto in-app de "otro chat" (Regla 2) lo gestiona la capa de UI.
  @visibleForTesting
  static bool shouldShowInForeground({
    required bool appInForeground,
    required bool bypassForeground,
    required bool evenInForeground,
    required String? targetSessionId,
    required String? visibleSessionId,
  }) {
    if (!appInForeground) return true;
    final viewingThisChat =
        targetSessionId != null &&
        targetSessionId.isNotEmpty &&
        targetSessionId == visibleSessionId;
    if (viewingThisChat) return false;
    return bypassForeground || evenInForeground;
  }

  /// Una respuesta exitosa del chat propietario ya se representa y se narra en
  /// la sesión de voz. No suprime otros chats ni eventos de aprobación/error.
  @visibleForTesting
  static bool shouldSuppressReplyForActiveVoice({
    required String? activeVoiceSessionId,
    required String? targetSessionId,
  }) {
    final active = activeVoiceSessionId?.trim() ?? '';
    final target = targetSessionId?.trim() ?? '';
    return active.isNotEmpty && target.isNotEmpty && active == target;
  }

  /// Canal (id/nombre/descripción/importancia) según el tipo de evento.
  ({
    String id,
    String name,
    String desc,
    Importance importance,
    Priority priority,
  })
  _channelFor(NotificationKind kind, NotifL10n t) {
    switch (kind) {
      case NotificationKind.approval:
      case NotificationKind.test:
        return (
          id: _chApprovals,
          name: t.chApprovals,
          desc: t.chApprovalsDesc,
          importance: Importance.high,
          priority: Priority.high,
        );
      case NotificationKind.reply:
        return (
          id: _chReplies,
          name: t.chReplies,
          desc: t.chRepliesDesc,
          importance: Importance.high,
          priority: Priority.high,
        );
      case NotificationKind.run:
      case NotificationKind.localAgent:
        return (
          id: _chRuns,
          name: t.chRuns,
          desc: t.chRunsDesc,
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
        );
    }
  }

  // ── Núcleo ──────────────────────────────────────────────────────────────
  Future<bool> _show({
    required NotificationKind kind,
    required int id,
    required String title,
    required String body,
    bool ongoingFeel = false,
    bool bypassForeground = false,
    String? payload,
    String? targetSessionId,
    String? subText,
    List<AndroidNotificationAction>? actions,
    bool compact = false,
  }) async {
    await init();
    // Cada return false registra el motivo: es el único modo de saber por qué un
    // aviso no aparece cuando la app está en 2º plano (sin UI que observar).
    if (!enabled) {
      _log(
        '${kind.name} suprimida: notificaciones desactivadas por el usuario',
      );
      return false;
    }
    // Regla 2: evento de OTRO chat con la app en primer plano → aviso discreto
    // DENTRO de la app (banner con "Ir"), no notificación del sistema. Se decide
    // aquí, antes de los chequeos de permiso/disponibilidad del sistema, porque
    // el banner informa aunque el usuario haya denegado POST_NOTIFICATIONS. Si el
    // usuario activó "avisar incluso en primer plano" ([evenInForeground]) se
    // respeta su preferencia y se deja caer al camino de notificación del sistema.
    if (appInForeground &&
        !evenInForeground &&
        targetSessionId != null &&
        targetSessionId.isNotEmpty &&
        targetSessionId != visibleSessionId) {
      final open = _decodePayload(payload);
      if (open != null) {
        _inApp.add(
          InAppNotice(kind: kind, title: title, body: body, open: open),
        );
        _log('${kind.name} → aviso in-app (otro chat, no al sistema)');
        return false;
      }
    }
    if (!_available) {
      _log('${kind.name} suprimida: servicio no disponible (init falló)');
      return false;
    }
    if (!await permissionGranted()) {
      _log('${kind.name} suprimida: POST_NOTIFICATIONS no concedido');
      return false;
    }
    // Decisión de primer plano centralizada (testeable): Regla 1/6 (mismo chat
    // visible → la UI inline ya lo muestra, no duplicar) + la regla previa de
    // "en primer plano solo si lo pidió o el evento lo exige".
    if (!shouldShowInForeground(
      appInForeground: appInForeground,
      bypassForeground: bypassForeground,
      evenInForeground: evenInForeground,
      targetSessionId: targetSessionId,
      visibleSessionId: visibleSessionId,
    )) {
      _log(
        '${kind.name} suprimida en primer plano '
        '(targetKnown=${targetSessionId?.isNotEmpty == true}, '
        'visibleMatch=${targetSessionId == visibleSessionId}, '
        'bypass=$bypassForeground, even=$evenInForeground)',
      );
      return false;
    }

    // Acciones: por defecto un botón "Open" en toda notificación accionable
    // (no permanente y con destino), para que sean interactivas de un toque.
    // `showsUserInterface` trae la app al frente → el tap dispara el mismo
    // payload que tocar el cuerpo (sin manejo extra en segundo plano).
    final t = NotifL10n.of(_prefs);
    final redact = hideSensitiveContent;
    final displayTitle = redact ? t.privateTitle : title;
    final displayBody = redact ? t.privateBody : body;
    final effectiveActions = compact
        ? null
        : redact
        // Con contenido oculto nunca se resuelve nada desde la bandeja: solo
        // "Abrir" (la app decide tras el desbloqueo).
        ? ((actions != null || !ongoingFeel) && payload != null
              ? <AndroidNotificationAction>[
                  AndroidNotificationAction(
                    'open',
                    t.actOpen,
                    showsUserInterface: true,
                    cancelNotification: true,
                  ),
                ]
              : null)
        : actions ??
              ((!ongoingFeel && payload != null)
                  ? <AndroidNotificationAction>[
                      AndroidNotificationAction(
                        'open',
                        t.actOpen,
                        showsUserInterface: true,
                        cancelNotification: true,
                      ),
                    ]
                  : null);

    final ch = _channelFor(kind, t);
    final summary = redact
        ? t.brand
        : (subText != null && subText.trim().isNotEmpty)
        ? subText.trim()
        : t.brand;

    final details = AndroidNotificationDetails(
      ch.id,
      ch.name,
      channelDescription: ch.desc,
      importance: ongoingFeel ? Importance.max : ch.importance,
      priority: ongoingFeel ? Priority.max : ch.priority,
      icon: 'ic_stat_hermes',
      color: _accent,
      colorized: false,
      subText: compact ? null : summary,
      groupKey: _groupKey,
      // Re-publicar el mismo objeto actualiza la tarjeta sin repetir sonido.
      onlyAlertOnce: true,
      category: compact
          ? AndroidNotificationCategory.status
          : ongoingFeel
          ? AndroidNotificationCategory.call
          : AndroidNotificationCategory.message,
      styleInformation: compact
          ? null
          : BigTextStyleInformation(
              displayBody,
              contentTitle: '<b>$displayTitle</b>',
              htmlFormatContentTitle: true,
              summaryText: summary,
              htmlFormatSummaryText: false,
            ),
      ticker: displayTitle,
      actions: effectiveActions,
      visibility: redact
          ? NotificationVisibility.secret
          : NotificationVisibility.private,
    );
    await _plugin.show(
      id,
      displayTitle,
      displayBody,
      NotificationDetails(android: details),
      payload: payload,
    );
    _log('${kind.name} MOSTRADA (id=$id, fg=$appInForeground)');
    // Jerarquía D→A: las alertas hijas conservan su tap individual; con 2+
    // activas se publica un resumen de grupo silencioso que las agrupa.
    if (!compact && kind != NotificationKind.test) {
      await _refreshGroupSummary(channelId: ch.id, t: t);
    }
    // Recuerda la última alerta de 2º plano para re-afirmarla si el desmontaje
    // del foreground service la borra (la de prueba no: es de primer plano).
    if (!appInForeground && kind != NotificationKind.test) {
      _lastBg = _LastBgNotif(
        id: id,
        channelId: ch.id,
        title: displayTitle,
        body: displayBody,
        payload: payload,
        compact: compact,
        at: DateTime.now(),
      );
    }
    return true;
  }

  /// Publica o retira el resumen del grupo según las alertas hijas REALMENTE
  /// activas en la bandeja del sistema. Consultar al SO —en vez de memoria del
  /// isolate— lo hace coherente entre productores (UI, listener, foreground
  /// service), tras recrear el proceso y cuando el usuario descarta una hija a
  /// mano. Silencioso ([GroupAlertBehavior.children]) y estable: nunca compite
  /// con el contenido de las hijas. Sin [channelId]/[t] solo puede retirar el
  /// resumen (camino de cancelación), nunca publicarlo.
  Future<void> _refreshGroupSummary({String? channelId, NotifL10n? t}) async {
    final children = await _countActiveChildren();
    if (children < 2) {
      await _plugin.cancel(_groupSummaryId);
      return;
    }
    if (channelId == null || t == null) return;
    final details = AndroidNotificationDetails(
      channelId,
      channelId,
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
      icon: 'ic_stat_hermes',
      color: _accent,
      groupKey: _groupKey,
      setAsGroupSummary: true,
      groupAlertBehavior: GroupAlertBehavior.children,
      onlyAlertOnce: true,
    );
    await _plugin.show(
      _groupSummaryId,
      t.brand,
      t.groupSummaryBody,
      NotificationDetails(android: details),
    );
  }

  /// ¿Es esta notificación activa una ALERTA hija del grupo (jerarquía A/B)?
  /// Excluye el resumen, la prueba, las respuestas compactas (canal replies),
  /// los servicios ongoing (voz, FGS) y las transferencias: ninguno debe
  /// disparar ni sostener el resumen. Pura y testeable.
  @visibleForTesting
  static bool isAlertChildNotification({
    required int? id,
    required String? channelId,
    required String? groupKey,
  }) {
    if (groupKey != _groupKey) return false;
    if (id == null || id == _groupSummaryId || id == _testNotificationId) {
      return false;
    }
    if (channelId == _chApprovals || channelId == _chRuns) return true;
    // API < 26 no expone channelId: degradar al rango de IDs de alerta.
    if (channelId == null) {
      return id == 7001 || (id >= 7100 && id != _voiceOngoingId);
    }
    return false;
  }

  /// Cuenta las alertas hijas activas consultando la bandeja del sistema.
  /// Ante cualquier fallo de plataforma devuelve 0 (degrada a "sin resumen",
  /// nunca bloquea la alerta que se acaba de mostrar).
  Future<int> _countActiveChildren() async {
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (android == null) return 0;
    try {
      final active = await android.getActiveNotifications();
      return active
          .where(
            (n) => isAlertChildNotification(
              id: n.id,
              channelId: n.channelId,
              groupKey: n.groupKey,
            ),
          )
          .length;
    } catch (e) {
      _log('no se pudieron consultar las notificaciones activas: $e');
      return 0;
    }
  }

  /// Vuelve a mostrar la última notificación de 2º plano si se posteó hace poco.
  /// Se llama JUSTO DESPUÉS de parar el foreground service: `stopForeground`
  /// emite un evento de borrado que en algunos dispositivos arrastra la alerta
  /// recién posteada. La re-emitimos en silencio (sin volver a sonar/vibrar ni
  /// hacer heads-up) y con el mismo id, así que si sigue viva es un no-op visual
  /// y si la borraron, reaparece sin molestar. Idempotente y sin secretos.
  Future<void> reassertRecent({
    Duration within = const Duration(seconds: 8),
  }) async {
    final last = _lastBg;
    if (last == null) return;
    if (!_available || !enabled) return;
    if (DateTime.now().difference(last.at) > within) return;
    final t = NotifL10n.of(_prefs);
    final details = AndroidNotificationDetails(
      last.channelId,
      last.channelId,
      importance: Importance.high,
      priority: Priority.high,
      icon: 'ic_stat_hermes',
      color: _accent,
      groupKey: _groupKey,
      subText: last.compact ? null : t.brand,
      // Re-afirmación silenciosa: ya alertó al mostrarse; no repetir.
      onlyAlertOnce: true,
      silent: true,
      category: last.compact
          ? AndroidNotificationCategory.status
          : AndroidNotificationCategory.message,
      styleInformation: last.compact
          ? null
          : BigTextStyleInformation(
              last.body,
              contentTitle: '<b>${last.title}</b>',
              htmlFormatContentTitle: true,
              summaryText: t.brand,
              htmlFormatSummaryText: false,
            ),
    );
    await _plugin.show(
      last.id,
      last.title,
      last.body,
      NotificationDetails(android: details),
      payload: last.payload,
    );
    _log('re-afirmada notificación de 2º plano (id=${last.id}) tras parar FGS');
  }

  @override
  Future<void> cancelApproval() => cancelById(7001, 'cancelApproval');

  /// Cancela una notificación por id dejando rastro de QUIÉN y POR QUÉ. Es el
  /// único camino permitido para cancelar: así cualquier borrado programático
  /// queda en el log con su pila de llamadas, para depurar desapariciones
  /// inesperadas (p.ej. una notificación que se borra sola a los pocos ms).
  Future<void> cancelById(int id, String reason) async {
    _log('CANCEL id=$id motivo="$reason"\n${StackTrace.current}');
    await _plugin.cancel(id);
    await _refreshGroupSummary();
  }
}

/// Instantánea de la última notificación mostrada en 2º plano, para re-afirmarla
/// si el desmontaje del foreground service la borra. Ver [NotificationService].
class _LastBgNotif {
  final int id;
  final String channelId;
  final String title;
  final String body;
  final String? payload;
  final bool compact;
  final DateTime at;
  const _LastBgNotif({
    required this.id,
    required this.channelId,
    required this.title,
    required this.body,
    required this.payload,
    required this.compact,
    required this.at,
  });
}
