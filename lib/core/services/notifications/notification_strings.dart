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
  String get privateTitle =>
      _('Nueva actividad en Hermes', 'New Hermes activity');
  String get privateBody => _('Toca para verla', 'Tap to see it');

  /// Resumen del grupo con el número real de avisos activos (más concreto que
  /// "varios" y estable a la vista en la bandeja).
  String groupSummaryCount(int n) =>
      _('$n avisos recientes', '$n recent alerts');

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
  String get chOperations => _('Operaciones locales', 'Local operations');
  String get chOperationsDesc => _(
    'Progreso de operaciones locales que has iniciado',
    'Progress of local operations you started',
  );

  // ── Aprobaciones ──────────────────────────────────────────────────────────
  String get approvalTitle =>
      _('Hermes necesita tu atención', 'Hermes needs your attention');
  String approvalBody(String tool, String where) =>
      _('Toca para responder', 'Tap to answer');

  // ── Ejecuciones ───────────────────────────────────────────────────────────
  String get runCompleted => _('Terminó', 'Finished');
  String get runFailed => _('No pudo terminar', 'Couldn’t finish');

  // ── Actividad en otra superficie (Desktop / otra Console / TUI) ──────────
  String get sessionActivityFinishedTitle =>
      _('Terminó en otro dispositivo', 'Finished on another device');
  String get sessionActivityFailedTitle =>
      _('Falló en otro dispositivo', 'Failed on another device');
  String get sessionActivityInterruptedTitle =>
      _('Se detuvo en otro dispositivo', 'Stopped on another device');
  String get sessionActivityBody =>
      _('Toca para ver el resultado', 'Tap to see the result');

  // ── Tarea en segundo plano (prompt.background / background.complete) ─────
  String get backgroundTaskFinishedTitle =>
      _('Terminó una tarea en segundo plano', 'A background task finished');
  String get backgroundTaskFailedTitle =>
      _('Falló una tarea en segundo plano', 'A background task failed');
  String get backgroundTaskBody =>
      _('Toca para ver el resultado', 'Tap to see the result');
  String get cronCompleted =>
      _('Tarea programada terminada', 'Scheduled task finished');
  String get cronFailed =>
      _('Falló una tarea programada', 'Scheduled task failed');
  String get kanbanCompleted => _('Tarea terminada', 'Task done');
  String get kanbanBlocked => _('Tarea bloqueada', 'Task blocked');
  String get kanbanNeedsAttention =>
      _('Una tarea te necesita', 'A task needs you');
  String get kanbanUpdated => _('Tarea actualizada', 'Task updated');
  String get kanbanCrashed => _(
    'Una tarea falló y se va a reintentar',
    'A task failed and will be retried',
  );
  String get kanbanTimedOut => _(
    'Una tarea tardó demasiado y se va a reintentar',
    'A task took too long and will be retried',
  );
  String get kanbanGaveUp => _('Tarea detenida', 'Task stopped');
  String get kanbanBlockLoop =>
      _('Una tarea necesita que decidas', 'A task needs your decision');

  // ── Standing goals ────────────────────────────────────────────────────────
  String get goalDone => _('Objetivo cumplido', 'Goal reached');
  String get goalPaused => _('Objetivo en pausa', 'Goal paused');
  String get goalBlocked => _('Objetivo bloqueado', 'Goal blocked');
  String get goalWaiting => _('Objetivo en espera', 'Goal waiting');
  String goalBody(String title) =>
      title.isEmpty ? _('Sin título', 'Untitled') : title;

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
  String get testTitle => 'Console';
  String get testBody => _(
    'Las notificaciones funcionan. Te avisaré cuando Hermes termine o te necesite.',
    'Notifications work. I’ll tell you when Hermes finishes or needs you.',
  );

  // ── Acciones ──────────────────────────────────────────────────────────────
  String get actOpen => _('Abrir', 'Open');

  // ── Servicio en segundo plano (foreground service) ────────────────────────
  String get bgChannel => _('Servicio en segundo plano', 'Background service');
  String get bgChannelDesc => _(
    'Mantiene a Hermes activo con la app cerrada',
    'Keeps Hermes active while the app is closed',
  );
  String get bgActive =>
      _('Activo en segundo plano', 'Active in the background');

  /// The fixed card while Console stays connected with the app closed.
  String get bgConnected => _('Conectado a Hermes', 'Connected to Hermes');
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
