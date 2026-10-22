// Textos de las notificaciones, localizados SIN BuildContext.
//
// Las notificaciones se disparan también desde un isolate de segundo plano
// (BackgroundListener) donde no hay `BuildContext` ni `AppLocalizations`. Por eso
// no podemos usar gen-l10n aquí: resolvemos el idioma leyendo la misma clave que
// usa la app (`app_locale` de AppLocales) y devolvemos los textos a mano
// (es/en/pt). Mantener en sintonía con lib/l10n cuando cambie el tono.
import 'dart:ui' show PlatformDispatcher;

import 'package:shared_preferences/shared_preferences.dart';

class NotifL10n {
  /// true = español; false + [pt] = false = inglés (único fallback histórico).
  final bool es;

  /// true = português (Brasil); gana sobre [es] si ambos fueran true.
  final bool pt;

  const NotifL10n(this.es, [this.pt = false]);

  /// Idioma resuelto: `'es'`, `'pt'` o `'en'` (igual que `effectiveVoiceLang`).
  String get lang => pt ? 'pt' : es ? 'es' : 'en';

  /// Resuelve el idioma desde SharedPreferences (clave `app_locale`):
  /// 'es'/'en'/'pt' fuerzan; 'system' (o ausente) sigue el idioma del
  /// dispositivo.
  factory NotifL10n.of(SharedPreferences prefs) {
    final id = prefs.getString('app_locale') ?? 'system';
    final code = id == 'system'
        ? PlatformDispatcher.instance.locale.languageCode
        : id;
    return NotifL10n(code == 'es', code == 'pt');
  }

  // [pt] es opcional como red de seguridad, pero todos los textos lo definen.
  String _(String es_, String en, [String? pt]) =>
      pt != null && this.pt ? pt : es ? es_ : en;

  // ── Marca / genéricos ─────────────────────────────────────────────────────
  String get brand => 'Hermes';
  String get privateTitle =>
      _('Nueva actividad en Hermes', 'New Hermes activity', 'Nova atividade no Hermes');
  String get privateBody =>
      _('Toca para verla', 'Tap to see it', 'Toque para ver');

  /// Resumen del grupo con el número real de avisos activos (más concreto que
  /// "varios" y estable a la vista en la bandeja).
  String groupSummaryCount(int n) =>
      _('$n avisos recientes', '$n recent alerts', '$n avisos recentes');

  // ── Canales (nombre + descripción) ────────────────────────────────────────
  String get chApprovals => _('Aprobaciones', 'Approvals', 'Aprovações');
  String get chApprovalsDesc => _(
    'Permisos que el agente necesita de ti',
    'Permissions the agent needs from you',
    'Permissões de que o agente precisa de você',
  );
  String get chReplies => _('Respuestas', 'Replies', 'Respostas');
  String get chRepliesDesc => _(
    'Cuando el agente termina de responder',
    'When the agent finishes replying',
    'Quando o agente termina de responder',
  );
  String get chRuns => _('Ejecuciones', 'Runs', 'Execuções');
  String get chRunsDesc => _(
    'Estado de las tareas en ejecución',
    'Status of running tasks',
    'Estado das tarefas em execução',
  );
  String get chTransfers => _('Transferencias', 'Transfers', 'Transferências');
  String get chTransfersDesc => _(
    'Progreso de subidas y descargas SFTP',
    'SFTP upload and download progress',
    'Progresso de envios e downloads SFTP',
  );
  String get chVoice => _('Modo voz', 'Voice mode', 'Modo voz');
  String get chVoiceDesc => _(
    'Estado del modo voz activo',
    'Active voice mode status',
    'Estado do modo voz ativo',
  );
  String get chOperations =>
      _('Operaciones locales', 'Local operations', 'Operações locais');
  String get chOperationsDesc => _(
    'Progreso de operaciones locales que has iniciado',
    'Progress of local operations you started',
    'Progresso das operações locais que você iniciou',
  );

  // ── Aprobaciones ──────────────────────────────────────────────────────────
  String get approvalTitle => _(
    'Hermes necesita tu atención',
    'Hermes needs your attention',
    'Hermes precisa da sua atenção',
  );
  String approvalBody(String tool, String where) => _(
    'Toca para responder',
    'Tap to answer',
    'Toque para responder',
  );

  // ── Ejecuciones ───────────────────────────────────────────────────────────
  String get runCompleted => _('Terminó', 'Finished', 'Concluiu');
  String get runFailed => _('No pudo terminar', 'Couldn’t finish', 'Não concluiu');

  // ── Actividad en otra superficie (Desktop / otra Console / TUI) ──────────
  String get sessionActivityFinishedTitle => _(
    'Terminó en otro dispositivo',
    'Finished on another device',
    'Concluiu em outro dispositivo',
  );
  String get sessionActivityFailedTitle => _(
    'Falló en otro dispositivo',
    'Failed on another device',
    'Falhou em outro dispositivo',
  );
  String get sessionActivityInterruptedTitle => _(
    'Se detuvo en otro dispositivo',
    'Stopped on another device',
    'Parou em outro dispositivo',
  );
  String get sessionActivityBody => _(
    'Toca para ver el resultado',
    'Tap to see the result',
    'Toque para ver o resultado',
  );

  // ── Tarea en segundo plano (prompt.background / background.complete) ─────
  String get backgroundTaskFinishedTitle => _(
    'Terminó una tarea en segundo plano',
    'A background task finished',
    'Uma tarefa em segundo plano foi concluída',
  );
  String get backgroundTaskFailedTitle => _(
    'Falló una tarea en segundo plano',
    'A background task failed',
    'Falhou uma tarefa em segundo plano',
  );
  String get backgroundTaskBody => _(
    'Toca para ver el resultado',
    'Tap to see the result',
    'Toque para ver o resultado',
  );
  String get cronCompleted => _(
    'Tarea programada terminada',
    'Scheduled task finished',
    'Tarefa agendada concluída',
  );
  String get cronFailed => _(
    'Falló una tarea programada',
    'Scheduled task failed',
    'Falhou uma tarefa agendada',
  );
  String get kanbanCompleted =>
      _('Tarea terminada', 'Task done', 'Tarefa concluída');
  String get kanbanBlocked =>
      _('Tarea bloqueada', 'Task blocked', 'Tarefa bloqueada');
  String get kanbanNeedsAttention => _(
    'Una tarea te necesita',
    'A task needs you',
    'Uma tarefa precisa de você',
  );
  String get kanbanUpdated =>
      _('Tarea actualizada', 'Task updated', 'Tarefa atualizada');
  String get kanbanCrashed => _(
    'Una tarea falló y se va a reintentar',
    'A task failed and will be retried',
    'Uma tarefa falhou e será tentada novamente',
  );
  String get kanbanTimedOut => _(
    'Una tarea tardó demasiado y se va a reintentar',
    'A task took too long and will be retried',
    'Uma tarefa demorou demais e será tentada novamente',
  );
  String get kanbanGaveUp =>
      _('Tarea detenida', 'Task stopped', 'Tarefa interrompida');
  String get kanbanBlockLoop => _(
    'Una tarea necesita que decidas',
    'A task needs your decision',
    'Uma tarefa precisa de uma decisão sua',
  );

  // ── Standing goals ────────────────────────────────────────────────────────
  String get goalDone =>
      _('Objetivo cumplido', 'Goal reached', 'Objetivo alcançado');
  String get goalPaused => _('Objetivo en pausa', 'Goal paused', 'Objetivo em pausa');
  String get goalBlocked =>
      _('Objetivo bloqueado', 'Goal blocked', 'Objetivo bloqueado');
  String get goalWaiting =>
      _('Objetivo en espera', 'Goal waiting', 'Objetivo em espera');
  String goalBody(String title) =>
      title.isEmpty ? _('Sin título', 'Untitled', 'Sem título') : title;

  // ── Respuestas ────────────────────────────────────────────────────────────
  String replyTitle(String? session) {
    final s = session?.trim() ?? '';
    if (s.isEmpty) {
      return _('Hermes respondió', 'Hermes replied', 'Hermes respondeu');
    }
    return _(
      'Hermes respondió en $s',
      'Hermes replied in $s',
      'Hermes respondeu em $s',
    );
  }

  String get replyReadyBody => _(
    'Respuesta lista. Toca para abrir.',
    'Reply ready. Tap to open.',
    'Resposta pronta. Toque para abrir.',
  );

  String replyFailedTitle(String? session) {
    final s = session?.trim() ?? '';
    if (s.isEmpty) {
      return _(
        'Hermes encontró un problema',
        'Hermes hit a problem',
        'Hermes encontrou um problema',
      );
    }
    return _('Problema en $s', 'Problem in $s', 'Problema em $s');
  }

  String get replyFailedBody => _(
    'El agente no pudo completar la tarea.',
    'The agent could not complete the task.',
    'O agente não conseguiu concluir a tarefa.',
  );

  // ── Agente local ──────────────────────────────────────────────────────────
  String get localInstalled => _(
    'Hermes local instalado',
    'Local Hermes installed',
    'Hermes local instalado',
  );
  String get localInstallError => _(
    'Error al instalar Hermes local',
    'Error installing local Hermes',
    'Erro ao instalar o Hermes local',
  );
  String get localInstalledBody => _(
    'El agente Hermes local se instaló en el dispositivo.',
    'The local Hermes agent was installed on the device.',
    'O agente Hermes local foi instalado no dispositivo.',
  );
  String get localInstallErrorBody => _(
    'No se pudo completar la instalación.',
    'Could not complete installation.',
    'Não foi possível concluir a instalação.',
  );
  String get localRemoved => _(
    'Hermes local eliminado',
    'Local Hermes removed',
    'Hermes local removido',
  );
  String get localRemoveError => _(
    'Error al eliminar Hermes local',
    'Error removing local Hermes',
    'Erro ao remover o Hermes local',
  );
  String get localRemovedBody => _(
    'El agente Hermes local se eliminó del dispositivo.',
    'The local Hermes agent was removed from the device.',
    'O agente Hermes local foi removido do dispositivo.',
  );
  String get localRemoveErrorBody => _(
    'No se pudieron eliminar algunos archivos.',
    'Some files could not be removed.',
    'Não foi possível remover alguns arquivos.',
  );

  // ── Prueba ────────────────────────────────────────────────────────────────
  String get testTitle => 'Console';
  String get testBody => _(
    'Las notificaciones funcionan. Te avisaré cuando Hermes termine o te necesite.',
    'Notifications work. I’ll tell you when Hermes finishes or needs you.',
    'As notificações funcionam. Vou avisar quando o Hermes terminar ou precisar de você.',
  );

  // ── Acciones ──────────────────────────────────────────────────────────────
  String get actOpen => _('Abrir', 'Open', 'Abrir');

  // ── Servicio en segundo plano (foreground service) ────────────────────────
  String get bgChannel => _(
    'Servicio en segundo plano',
    'Background service',
    'Serviço em segundo plano',
  );
  String get bgChannelDesc => _(
    'Mantiene a Hermes activo con la app cerrada',
    'Keeps Hermes active while the app is closed',
    'Mantém o Hermes ativo com o app fechado',
  );
  String get bgActive => _(
    'Activo en segundo plano',
    'Active in the background',
    'Ativo em segundo plano',
  );

  /// The fixed card while Console stays connected with the app closed.
  String get bgConnected => _(
    'Conectado a Hermes',
    'Connected to Hermes',
    'Conectado ao Hermes',
  );
  String get bgStop => _('Detener', 'Stop', 'Parar');

  // ── Modo voz (estados) ────────────────────────────────────────────────────
  String get voiceTitle => _('Modo voz', 'Voice mode', 'Modo voz');
  String get vListening => _('Escuchando…', 'Listening…', 'Ouvindo…');
  String get vTranscribing => _('Transcribiendo…', 'Transcribing…', 'Transcrevendo…');
  String get vThinking => _('Pensando…', 'Thinking…', 'Pensando…');
  String get vTool => _(
    'Ejecutando una herramienta…',
    'Running a tool…',
    'Executando uma ferramenta…',
  );
  String get vWaitingApproval => _(
    'Necesita aprobación',
    'Needs approval',
    'Precisa de aprovação',
  );
  String get vSpeaking => _('Hablando…', 'Speaking…', 'Falando…');
  String get vError => _('Error en modo voz', 'Voice mode error', 'Erro no modo voz');
  String get voiceActive => _(
    'Puedes seguir hablando · toca para abrir Hermes',
    'Keep talking · tap to open Hermes',
    'Pode continuar falando · toque para abrir o Hermes',
  );
  String get voicePaused => _(
    'Conversación en pausa · pulsa Continuar o abre Hermes',
    'Conversation paused · tap Continue or open Hermes',
    'Conversa em pausa · toque em Continuar ou abra o Hermes',
  );
  String get voiceWaitingApproval => _(
    'Hermes necesita aprobación · pulsa Revisar',
    'Hermes needs approval · tap Review',
    'Hermes precisa de aprovação · toque em Revisar',
  );
  String get voiceOpenHintActive => _(
    'Sigue hablando · toca para abrir Hermes',
    'Keep talking · tap to open Hermes',
    'Continue falando · toque para abrir o Hermes',
  );
  String get voiceOpenHintPaused => _(
    'Pulsa Continuar o toca para abrir Hermes',
    'Tap Continue or tap to open Hermes',
    'Toque em Continuar ou abra o Hermes',
  );
  String get voiceOpenHintApproval => _(
    'Pulsa Revisar para aprobar en Hermes',
    'Tap Review to approve in Hermes',
    'Toque em Revisar para aprovar no Hermes',
  );
  String get voiceCardListening =>
      _('Escuchando', 'Listening', 'Ouvindo');
  String get voiceCardPaused => _('En pausa', 'Paused', 'Em pausa');
  String get voiceCardWaitingApproval => _(
    'Necesita aprobación',
    'Needs approval',
    'Precisa de aprovação',
  );
  String get voiceCardMicActive => _(
    'Micrófono activo',
    'Microphone active',
    'Microfone ativo',
  );
  String get voiceCardMicPaused => _(
    'Micrófono pausado',
    'Microphone paused',
    'Microfone pausado',
  );
  String get voiceCardOrbDescription => _(
    'Estado de voz de Hermes',
    'Hermes voice status',
    'Estado de voz do Hermes',
  );
  String get voiceCardDurationDescription => _(
    'Duración de la conversación',
    'Conversation duration',
    'Duração da conversa',
  );
  String get voicePause => _('Pausar', 'Pause', 'Pausar');
  String get voiceContinue => _('Continuar', 'Continue', 'Continuar');
  String get voiceReviewApproval => _('Revisar', 'Review', 'Revisar');
  String get voiceEnd => _('Terminar', 'End', 'Encerrar');
  String get voiceEndConversation => _(
    'Terminar conversación',
    'End conversation',
    'Encerrar conversa',
  );
  String get readAloudPlaying => _(
    'Leyendo respuesta',
    'Reading response',
    'Lendo a resposta',
  );
  String get readAloudPaused => _(
    'Lectura en pausa',
    'Reading paused',
    'Leitura em pausa',
  );

  /// Fallback para el nombre de la herramienta en curso cuando el servidor
  /// no envió una etiqueta legible (NotifL10n está disponible sin contexto).
  String get tool => _('herramienta', 'tool', 'ferramenta');
}
