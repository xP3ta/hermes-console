// Textos de las notificaciones, localizados SIN BuildContext.
//
// Las notificaciones se disparan también desde un isolate de segundo plano
// (BackgroundListener) donde no hay `BuildContext` ni `AppLocalizations`. Por eso
// no podemos usar gen-l10n aquí: resolvemos el idioma leyendo la misma clave que
// usa la app (`app_locale` de AppLocales) y devolvemos los textos a mano (es/en).
// Mantener en sintonía con lib/l10n cuando cambie el tono.
import 'dart:ui' show PlatformDispatcher;

import 'package:shared_preferences/shared_preferences.dart';

class NotifL10n {
  /// true = español; false = inglés (único fallback).
  final bool es;
  const NotifL10n(this.es);

  /// Resuelve el idioma desde SharedPreferences (clave `app_locale`): 'es'/'en'
  /// fuerzan; 'system' (o ausente) sigue el idioma del dispositivo.
  factory NotifL10n.of(SharedPreferences prefs) {
    final id = prefs.getString('app_locale') ?? 'system';
    final code = id == 'system'
        ? PlatformDispatcher.instance.locale.languageCode
        : id;
    return NotifL10n(code == 'es');
  }

  String _(String es_, String en) => es ? es_ : en;

  // ── Marca / genéricos ─────────────────────────────────────────────────────
  String get brand => 'Hermes';
  String get agentTask => _('Tarea del agente', 'Agent task');
  String get privateTitle =>
      _('Nueva actividad en Hermes', 'New Hermes activity');
  String get privateBody => _(
    'Abre la aplicación para ver los detalles.',
    'Open the app to view the details.',
  );
  String get groupSummaryBody => _(
    'Tienes varios avisos recientes.',
    'You have several recent alerts.',
  );

  // ── Canales (nombre + descripción) ────────────────────────────────────────
  String get chApprovals => _('Aprobaciones', 'Approvals');
  String get chApprovalsDesc => _(
    'Permisos que el agente necesita de ti',
    'Permissions the agent needs from you',
  );
  String get chReplies => _('Respuestas', 'Replies');
  String get chRepliesDesc => _(
    'Cuando el agente termina de responder',
    'When the agent finishes replying',
  );
  String get chRuns => _('Ejecuciones', 'Runs');
  String get chRunsDesc =>
      _('Estado de las tareas en ejecución', 'Status of running tasks');
  String get chTransfers => _('Transferencias', 'Transfers');
  String get chTransfersDesc => _(
    'Progreso de subidas y descargas SFTP',
    'SFTP upload and download progress',
  );
  String get chVoice => _('Modo voz', 'Voice mode');
  String get chVoiceDesc =>
      _('Estado del modo voz activo', 'Active voice mode status');

  // ── Aprobaciones ──────────────────────────────────────────────────────────
  String get approvalTitle =>
      _('Hermes necesita tu permiso', 'Hermes needs your permission');
  String approvalBody(String tool, String where) => _(
    'Decisión pendiente sobre «$tool»$where',
    'Pending decision on “$tool”$where',
  );

  // ── Ejecuciones ───────────────────────────────────────────────────────────
  String get runCompleted => _('Ejecución completada', 'Run completed');
  String get runFailed => _('Ejecución con errores', 'Run failed');
  String get cronCompleted => _('Cron completado', 'Cron completed');
  String get cronFailed => _('Cron falló', 'Cron failed');
  String get kanbanCompleted =>
      _('Tarea de Kanban completada', 'Kanban task completed');
  String get kanbanBlocked =>
      _('Tarea de Kanban bloqueada', 'Kanban task blocked');
  String get kanbanNeedsAttention =>
      _('Kanban necesita tu atención', 'Kanban needs your attention');
  String get kanbanUpdated =>
      _('Tarea de Kanban actualizada', 'Kanban task updated');

  // ── Respuestas ────────────────────────────────────────────────────────────
  String replyTitle(String? session) {
    final s = session?.trim() ?? '';
    if (s.isEmpty) return _('Hermes respondió', 'Hermes replied');
    return _('Hermes respondió en $s', 'Hermes replied in $s');
  }

  String get replyReadyBody =>
      _('Respuesta lista. Toca para abrir.', 'Reply ready. Tap to open.');

  String replyFailedTitle(String? session) {
    final s = session?.trim() ?? '';
    if (s.isEmpty) {
      return _('Hermes encontró un problema', 'Hermes hit a problem');
    }
    return _('Problema en $s', 'Problem in $s');
  }

  String get replyFailedBody => _(
    'El agente no pudo completar la tarea.',
    'The agent could not complete the task.',
  );

  // ── Agente local ──────────────────────────────────────────────────────────
  String get localInstalled =>
      _('Hermes local instalado', 'Local Hermes installed');
  String get localInstallError =>
      _('Error al instalar Hermes local', 'Error installing local Hermes');
  String get localInstalledBody => _(
    'El agente Hermes local se instaló en el dispositivo.',
    'The local Hermes agent was installed on the device.',
  );
  String get localInstallErrorBody => _(
    'No se pudo completar la instalación.',
    'Could not complete installation.',
  );
  String get localRemoved =>
      _('Hermes local eliminado', 'Local Hermes removed');
  String get localRemoveError =>
      _('Error al eliminar Hermes local', 'Error removing local Hermes');
  String get localRemovedBody => _(
    'El agente Hermes local se eliminó del dispositivo.',
    'The local Hermes agent was removed from the device.',
  );
  String get localRemoveErrorBody => _(
    'No se pudieron eliminar algunos archivos.',
    'Some files could not be removed.',
  );

  // ── Prueba ────────────────────────────────────────────────────────────────
  String get testTitle => 'Hermes Console';
  String get testBody => _(
    'Las notificaciones funcionan. Te avisaré de aprobaciones, ejecuciones y respuestas.',
    'Notifications are working. I will notify you of approvals, runs and replies.',
  );

  // ── Acciones ──────────────────────────────────────────────────────────────
  String get actApprove => _('Aprobar', 'Approve');
  String get actDeny => _('Rechazar', 'Deny');
  String get actOpen => _('Abrir', 'Open');

  // ── Servicio en segundo plano (foreground service) ────────────────────────
  String get bgChannel => _('Servicio en segundo plano', 'Background service');
  String get bgChannelDesc => _(
    'Mantiene a Hermes activo con la app cerrada',
    'Keeps Hermes active while the app is closed',
  );
  String get bgActive =>
      _('Activo en segundo plano', 'Active in the background');
  String bgWatching(int n) =>
      _('Vigilando $n ejecución(es)', 'Watching $n run(s)');
  String get bgStop => _('Detener', 'Stop');

  // ── Modo voz (estados) ────────────────────────────────────────────────────
  String get voiceTitle => _('Modo voz', 'Voice mode');
  String get vListening => _('Escuchando…', 'Listening…');
  String get vTranscribing => _('Transcribiendo…', 'Transcribing…');
  String get vThinking => _('Pensando…', 'Thinking…');
  String get vTool => _('Ejecutando una herramienta…', 'Running a tool…');
  String get vWaitingApproval => _('Necesita aprobación', 'Needs approval');
  String get vSpeaking => _('Hablando…', 'Speaking…');
  String get vError => _('Error en modo voz', 'Voice mode error');
  String get voiceActive => _(
    'Puedes seguir hablando · toca para abrir Hermes',
    'Keep talking · tap to open Hermes',
  );
  String get voicePaused => _(
    'Conversación en pausa · pulsa Continuar o abre Hermes',
    'Conversation paused · tap Continue or open Hermes',
  );
  String get voiceWaitingApproval => _(
    'Hermes necesita aprobación · pulsa Revisar',
    'Hermes needs approval · tap Review',
  );
  String get voiceOpenHintActive => _(
    'Sigue hablando · toca para abrir Hermes',
    'Keep talking · tap to open Hermes',
  );
  String get voiceOpenHintPaused => _(
    'Pulsa Continuar o toca para abrir Hermes',
    'Tap Continue or tap to open Hermes',
  );
  String get voiceOpenHintApproval => _(
    'Pulsa Revisar para aprobar en Hermes',
    'Tap Review to approve in Hermes',
  );
  String get voiceCardListening => _('Escuchando', 'Listening');
  String get voiceCardPaused => _('En pausa', 'Paused');
  String get voiceCardWaitingApproval =>
      _('Necesita aprobación', 'Needs approval');
  String get voiceCardMicActive => _('Micrófono activo', 'Microphone active');
  String get voiceCardMicPaused => _('Micrófono pausado', 'Microphone paused');
  String get voiceCardOrbDescription =>
      _('Estado de voz de Hermes', 'Hermes voice status');
  String get voiceCardDurationDescription =>
      _('Duración de la conversación', 'Conversation duration');
  String get voicePause => _('Pausar', 'Pause');
  String get voiceContinue => _('Continuar', 'Continue');
  String get voiceReviewApproval => _('Revisar', 'Review');
  String get voiceEnd => _('Terminar', 'End');
  String get voiceEndConversation =>
      _('Terminar conversación', 'End conversation');
  String get readAloudPlaying => _('Leyendo respuesta', 'Reading response');
  String get readAloudPaused => _('Lectura en pausa', 'Reading paused');
}
