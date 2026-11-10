// Contrato único entre la pantalla de chat y la conversación de voz.
//
// La implementación pública es LocalVoiceConversationController. Mantener esta
// interfaz evita que ChatScreen posea el micrófono, el TTS o el ciclo del turno.
import 'package:flutter/foundation.dart' show Listenable;

import '../../active_chat_service.dart' show ActiveChat;
import '../voice_phase.dart';
import '../voice_service.dart' show SttCheck;
import 'voice_care.dart';

/// Superficie pública que la pantalla de chat necesita del modo voz.
/// `Listenable` aporta `addListener`/`removeListener` para actualizar la UI.
abstract class VoiceUiSurface implements Listenable {
  /// ¿El modo voz está activo (entrado) sobre algún chat?
  bool get active;

  /// Herramienta en ejecución ahora mismo (para el overlay), o `null` si
  /// ninguna.
  String? get activeTool;

  /// Texto de la respuesta del agente acumulado en streaming durante el
  /// turno en curso; vacío fuera de un turno.
  String get assistantResponse;

  /// Comentario assistant público y breve del turno (`message.interim`).
  /// Nunca deriva de reasoning, herramientas, argumentos o logs.
  String get publicCommentary => '';

  /// Arranca el modo voz sobre `chat`. `onBeforeSend` (opcional) corre antes
  /// de cada envío para tareas de la pantalla (p.ej. auto-título).
  Future<void> enter({
    required ActiveChat chat,
    required String model,
    String profile,
    bool allowTransportFallback = false,
    Future<void> Function(String prompt)? onBeforeSend,
  });

  /// Sale del modo voz: libera motores STT/TTS y limpia el estado de turno.
  Future<void> exit();

  /// What the user can do now about a failure or a pause, typed; the screen
  /// words it. Null when there is nothing to act on.
  VoiceCare? get care;

  /// Text of a message dictated but not sent, kept so Retry sends the same
  /// words. Null when nothing is held.
  String? get heldTurnText;

  /// Hands the held message back (to the composer, when the conversation is
  /// closed) and forgets it. Null when nothing is held.
  String? takeHeldTurnText();

  /// Aviso honesto en el overlay ("no te he oído", "en cola: …"), o `null`.
  String? get note;

  /// ¿El modo voz está atado a ESTE objeto de chat? Comparación por
  /// identidad, no por `sessionId` (ver doc de la implementación vieja).
  bool ownsChat(ActiveChat chat);

  /// Chat propietario de la conversación de voz activa. Permite que otra
  /// pantalla muestre un retorno explícito sin crear un segundo runtime.
  ActiveChat? get ownerChat => null;

  /// Transcripción parcial del usuario mientras dicta (vista en vivo); vacía
  /// fuera de una captura.
  String get partialTranscript;

  /// Notifies when [partialTranscript] changes. A partial is not a state
  /// change: an engine that keeps it out of its own notifications gives a
  /// narrower listenable here, so the live draft rebuilds alone.
  Listenable get partialTranscriptChanges => this;

  /// Último final STT aceptado. Se conserva durante el turno del asistente para
  /// que la zona “Tú” no desaparezca al cerrar el micrófono.
  String get userTranscript => partialTranscript;

  /// Pausa explícita de conversación (distinta de [paused], que solo aparta el
  /// overlay para tocar una aprobación).
  bool get userPaused => false;

  /// Privacy (App Lock, the app hidden) is hiding the conversation's words:
  /// the phase reads idle then, which is not the end of a turn, and nothing
  /// heard may stay on screen.
  bool get privacyHidden => false;

  /// El chat propietario mantiene un run o submit vivo.
  bool get backendActive => false;

  /// La captura full-duplex está realmente armada para aceptar voz ahora.
  /// Preferencia o capability por sí solas no autorizan a la UI a prometer
  /// interrupción.
  bool get spokenInterruptionArmed => false;

  /// A spoken reply is playing (or its audio is still in flight). A typed
  /// send now cuts it and tells Hermes so (Desktop `isVoicePlaybackActive`,
  /// voice-playback.ts:824-826, used by use-prompt-actions/submit.ts:332).
  bool get voicePlaybackActive => false;

  /// Pausa/Reanudar conservan el cursor de narración.
  void pauseConversation() => onOrbTap();
  void playConversation() => onOrbTap();

  /// Silencia la revisión actual, conserva el backend y abre el micro.
  void stopAndTalk() => onOrbTap();

  /// Finaliza de forma explícita la captura manual y pasa a transcripción.
  ///
  /// El fallback conserva compatibilidad con motores legacy. Las superficies
  /// modernas deben exponer esta acción mediante un botón con nombre, nunca
  /// únicamente mediante un tap sobre la mascota.
  void finishListening() => onOrbTap();

  /// Cancela únicamente el backend actual.
  void cancelBackend() => onOrbTap();

  /// Reintenta la preparación/captura después de un error recuperable.
  void retry() => onOrbTap();

  /// ¿El overlay está pausado para que la tarjeta de aprobación del chat sea
  /// accionable?
  bool get paused;

  /// Solo aparta la superficie de voz. No pausa STT, TTS ni el turno.
  bool get overlayMinimized => false;

  void minimizeOverlay() {}

  /// Pausa el overlay (sin salir del modo voz) para accionar una tarjeta de
  /// aprobación pendiente.
  void pauseForApproval();

  /// Fase actual del modo voz proyectada por el controlador público.
  VoicePhase get phase;

  /// ¿Ya llegó el primer token de la respuesta de este turno?
  bool get responding;

  /// Reanuda el overlay tras [pauseForApproval].
  void resumeOverlay();

  /// ¿El motor STT activo requiere un toque para terminar de dictar (Whisper
  /// sin VAD)?
  bool get whisper;

  /// Gestiona el toque del usuario sobre el orbe, según la fase actual.
  void onOrbTap();

  /// Emite cuando el dictado no pudo arrancar, con la causa concreta (la
  /// pantalla la usa para mostrar el diálogo correspondiente).
  Stream<SttCheck> get unavailable;
}
