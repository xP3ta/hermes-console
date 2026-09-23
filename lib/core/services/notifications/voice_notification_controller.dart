import 'dart:ui' show Color;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'notification_service.dart';
import 'notification_strings.dart';

/// Estado de la sesión de voz que se refleja en su notificación dedicada.
enum VoiceNotifState {
  listening,
  transcribing,
  thinking,
  tool,
  waitingApproval,
  speaking,
  error,
}

/// Fachada de plataforma para postar/cancelar la notificación de voz. Se aísla
/// en una interfaz para poder testear el controlador con un fake, igual que el
/// patrón de las notificaciones de runs (sin depender del plugin Android).
abstract interface class VoicePlatformNotifier {
  /// Crea (idempotente) el canal dedicado de voz. Additivo: no toca otros
  /// canales ni el handler de tap de [NotificationService].
  Future<void> ensureChannel();

  /// Postea/actualiza UNA notificación con [id] (mismo id ⇒ se actualiza en
  /// sitio, sin sonido). Devuelve si llegó a postear (permiso/ajuste).
  Future<bool> post({required int id, required String title, required String body});

  /// Cancela la notificación [id].
  Future<void> cancel(int id);
}

/// Capa fina sobre [VoicePlatformNotifier] que da al modo voz una notificación
/// PROPIA y actualizable, separada de alerts/runs/transfers. Una única
/// notificación por sesión de voz: cada estado ACTUALIZA la misma (no genera
/// spam ni vibra/suena en cada cambio). No conoce la UI, no abre SSE, no toca
/// RunRegistry ni el controlador de notificaciones de runs.
class VoiceNotificationController {
  /// Id reservado para la notificación de voz. Fuera de los rangos de runs
  /// (7100–8123 finalizados, 9000–9511 en vivo), alertas fijas (7000–7004,
  /// 7200–7201) e instalación local: no colisiona con ninguna.
  static const int notifId = 8801;

  /// Id del canal dedicado (separado de hermes_alerts/transfers/listener/runs).
  static const String channelId = 'hermes_voice';
  static const String channelName = 'Hermes Voice';
  static const String channelDesc = 'Estado del modo voz activo';

  final VoicePlatformNotifier _platform;
  VoiceNotifState? _last;
  bool _channelReady = false;

  VoiceNotificationController(this._platform);

  Future<void> showListening() => _set(VoiceNotifState.listening);
  Future<void> showTranscribing() => _set(VoiceNotifState.transcribing);
  Future<void> showThinking() => _set(VoiceNotifState.thinking);
  Future<void> showToolRunning() => _set(VoiceNotifState.tool);
  Future<void> showWaitingApproval() => _set(VoiceNotifState.waitingApproval);
  Future<void> showSpeaking() => _set(VoiceNotifState.speaking);
  Future<void> showError() => _set(VoiceNotifState.error);

  /// Quita la notificación de voz (fin/cancelación de la sesión).
  Future<void> clearVoiceNotification() async {
    if (_last == null) return; // ya limpia: nada que cancelar
    _last = null;
    await _platform.cancel(notifId);
  }

  Future<void> _set(VoiceNotifState state) async {
    // Anti-spam: el mismo estado consecutivo no vuelve a postear.
    if (_last == state) return;
    _last = state;
    if (!_channelReady) {
      await _platform.ensureChannel();
      _channelReady = true;
    }
    final t = NotifL10n.of(await SharedPreferences.getInstance());
    await _platform.post(id: notifId, title: t.voiceTitle, body: _body(state, t));
  }

  static String _body(VoiceNotifState s, NotifL10n t) => switch (s) {
        VoiceNotifState.listening => t.vListening,
        VoiceNotifState.transcribing => t.vTranscribing,
        VoiceNotifState.thinking => t.vThinking,
        VoiceNotifState.tool => t.vTool,
        VoiceNotifState.waitingApproval => t.vWaitingApproval,
        VoiceNotifState.speaking => t.vSpeaking,
        VoiceNotifState.error => t.vError,
      };

  /// Implementación real respaldada por el plugin. Reutiliza el singleton de
  /// [FlutterLocalNotificationsPlugin] (canales y notificaciones son globales a
  /// la app) y se apoya en la superficie PÚBLICA de [NotificationService]
  /// (`init`/`enabled`/`available`/`permissionGranted`) solo para respetar el
  /// permiso — sin modificarlo. No llama a `initialize()` (eso pisaría el handler
  /// de tap del servicio principal): asume que [NotificationService.init] ya corrió.
  static VoicePlatformNotifier platform(NotificationService svc) =>
      _PluginVoiceNotifier(svc);
}

class _PluginVoiceNotifier implements VoicePlatformNotifier {
  final NotificationService _svc;
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  _PluginVoiceNotifier(this._svc);

  AndroidFlutterLocalNotificationsPlugin? get _android => _plugin
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();

  Future<bool> _ready() async {
    await _svc.init();
    if (!_svc.available || !_svc.enabled) return false;
    return _svc.permissionGranted();
  }

  @override
  Future<void> ensureChannel() async {
    final t = NotifL10n.of(await SharedPreferences.getInstance());
    await _android?.createNotificationChannel(AndroidNotificationChannel(
      VoiceNotificationController.channelId,
      t.chVoice,
      description: t.chVoiceDesc,
      importance: Importance.low, // visible sin ruido: no suena ni vibra
      enableVibration: false,
      playSound: false,
      showBadge: false,
    ));
  }

  @override
  Future<bool> post({
    required int id,
    required String title,
    required String body,
  }) async {
    if (!await _ready()) return false;
    final t = NotifL10n.of(await SharedPreferences.getInstance());
    final details = AndroidNotificationDetails(
      VoiceNotificationController.channelId,
      t.chVoice,
      channelDescription: t.chVoiceDesc,
      importance: Importance.low,
      priority: Priority.low,
      icon: 'ic_stat_hermes',
      color: const Color(0xFFE8821C),
      groupKey: 'hermes',
      onlyAlertOnce: true, // actualizar en sitio sin re-alertar
      ongoing: true, // sesión activa: el usuario no la desliza por error
      autoCancel: false,
      silent: true,
      showWhen: false,
      category: AndroidNotificationCategory.status,
    );
    await _plugin.show(id, title, body, NotificationDetails(android: details));
    return true;
  }

  @override
  Future<void> cancel(int id) => _plugin.cancel(id);
}
