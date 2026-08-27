import 'package:flutter/widgets.dart';

final class MissionControlCopy {
  final bool _english;

  const MissionControlCopy._(this._english);

  factory MissionControlCopy.of(BuildContext context) => MissionControlCopy._(
    Localizations.localeOf(context).languageCode.toLowerCase() == 'en',
  );

  String get title => 'Bots';
  String get allAgents => _english ? 'All agents' : 'Todos los agentes';
  String get chooseWorkspace =>
      _english ? 'Choose workspace' : 'Elegir espacio de trabajo';
  String get workspaces => _english ? 'Workspaces' : 'Espacios de trabajo';
  String workspaceAgentCount(int count) => _english
      ? '$count ${count == 1 ? 'agent' : 'agents'}'
      : '$count ${count == 1 ? 'agente' : 'agentes'}';
  String get createOrganization =>
      _english ? 'Create workspace' : 'Crear espacio de trabajo';
  String get editOrganization =>
      _english ? 'Edit workspace' : 'Editar espacio de trabajo';
  String get organizationName =>
      _english ? 'Workspace name' : 'Nombre del espacio de trabajo';
  String get organizationHint => _english ? 'e.g. Homelab' : 'p. ej. Homelab';
  String get chooseProfiles =>
      _english ? 'Choose profiles' : 'Selecciona profiles';
  String get save => _english ? 'Save' : 'Guardar';
  String get cancel => _english ? 'Cancel' : 'Cancelar';
  String get delete => _english ? 'Delete' : 'Eliminar';
  String get deleteOrganizationTitle =>
      _english ? 'Delete workspace?' : '¿Eliminar espacio de trabajo?';
  String get deleteOrganizationBody => _english
      ? 'Only this local workspace is removed. Hermes profiles are not changed.'
      : 'Solo se elimina este espacio local. Los profiles de Hermes no cambian.';
  String get loading => _english ? 'Reading team state…' : 'Leyendo el equipo…';
  String get retry => _english ? 'Retry' : 'Reintentar';
  String get refresh => _english ? 'Refresh' : 'Actualizar';
  String get overview => _english ? 'Overview' : 'Resumen';
  String get tasks => _english ? 'Tasks' : 'Tareas';
  String assignedTasks(int count) =>
      _english ? 'Assigned tasks ($count)' : 'Tareas asignadas ($count)';
  String get activity => _english ? 'Activity' : 'Actividad';
  String get recentActivity =>
      _english ? 'Recent activity' : 'Actividad reciente';
  String get showAllActivity =>
      _english ? 'Show all activity' : 'Ver toda la actividad';
  String get showLess => _english ? 'Show less' : 'Mostrar menos';
  String get bots => 'Bots';
  String botCount(int count) =>
      _english ? '$count ${count == 1 ? 'bot' : 'bots'}' : '$count bots';
  String get rooms => _english ? 'Rooms' : 'Salas';
  String get work => _english ? 'Work' : 'Trabajo';
  String get globalWorkTray =>
      _english ? 'Other pending work' : 'Otros pendientes';

  String get addToMissionControl => _english ? 'Add to Bots' : 'Añadir a Bots';
  String get createAgent => _english ? 'New agent' : 'Nuevo agente';
  String get createAgentDescription => _english
      ? 'Create a real Hermes profile with its own model and capabilities.'
      : 'Crea un profile real de Hermes con su modelo y capacidades.';
  String get createRoom => _english ? 'Create room' : 'Crear sala';
  String get createRoomDescription => _english
      ? 'Choose 2–6 bots and open their coordination room.'
      : 'Elige entre 2 y 6 bots y abre su sala de coordinación.';
  String get startTeam => _english ? 'Build your team' : 'Crear tu equipo';
  String get newAgent => _english ? 'New agent' : 'Nuevo agente';
  String get botChat => 'Bot Chat';
  String get botDetails => _english ? 'Bot details' : 'Detalles del bot';
  String get noBots => _english
      ? 'A bot is a named teammate with its own memory, skills and chat. Create the first one to get started.'
      : 'Un bot es un compañero con nombre propio, memoria, skills y chat propios. Crea el primero para empezar.';
  String get botNeedsYou => _english ? 'needs you' : 'te necesita';
  String get needMoreBots => _english
      ? 'Create another bot before opening a room.'
      : 'Crea otro bot antes de abrir una sala.';
  String get needTwoAgents => _english
      ? 'Create at least two bots before opening a team room.'
      : 'Crea al menos dos bots antes de abrir una sala de equipo.';
  String get searchAgents => _english ? 'Search bots' : 'Buscar bots';
  String get clearSearch => _english ? 'Clear search' : 'Borrar búsqueda';
  String get activeNow => _english ? 'Active now' : 'Activos ahora';
  String get otherBots => _english ? 'Other bots' : 'Otros bots';
  String get allBots => _english ? 'All bots' : 'Todos los bots';
  String get searchResults => _english ? 'Results' : 'Resultados';
  String showHiddenBots(int count) =>
      _english ? 'Show hidden ($count)' : 'Mostrar ocultos ($count)';
  String get hideHiddenBots => _english ? 'Hide hidden' : 'Ocultar ocultos';
  String get pinBot => _english ? 'Pin to top' : 'Fijar arriba';
  String get unpinBot => _english ? 'Unpin' : 'Dejar de fijar';
  String get hideBot => _english ? 'Hide from Bots' : 'Ocultar de Bots';
  String get showBot => _english ? 'Show in Bots' : 'Mostrar en Bots';
  String get botRosterUpdateFailed => _english
      ? 'Hermes did not update this bot.'
      : 'Hermes no pudo actualizar este bot.';
  String get noMatchingAgents =>
      _english ? 'No matching bots' : 'No hay bots que coincidan';
  String get roomCoordinator => _english ? 'Coordinator' : 'Coordinador';
  String get roomSelectionHint =>
      _english ? 'Choose 2 to 6 bots.' : 'Elige de 2 a 6 bots.';
  String roomSelectionCount(int count) =>
      _english ? '$count of 6 selected' : '$count de 6 seleccionados';
  String agentCreated(String name) => _english
      ? 'Bot @$name created. Add it to a room when you are ready.'
      : 'Bot @$name creado. Añádelo a una sala cuando quieras.';
  String get editRoom => _english ? 'Edit room' : 'Editar sala';
  String get roomName => _english ? 'Room name' : 'Nombre de la sala';
  String get roomHint => _english ? 'e.g. homelab' : 'p. ej. homelab';
  String get roomPurpose => _english ? 'Purpose' : 'Objetivo';
  String get roomPurposeHint => _english
      ? 'e.g. Keep production stable'
      : 'p. ej. Mantener producción estable';
  String get roomNameInvalid => _english
      ? 'Enter a name after the # symbol.'
      : 'Escribe un nombre después del símbolo #.';
  String get roomManager => _english ? 'Room manager' : 'Manager de la sala';
  String get roomMembers => _english ? 'Room members' : 'Miembros de la sala';
  String get roomCoordinatorShort => _english ? 'Coordinator' : 'Coordinador';
  String get roomTeam => _english ? 'Team' : 'Equipo';
  String get roomSummary => _english ? 'Summary' : 'Resumen';
  String get roomTasks => _english ? 'Room tasks' : 'Tareas de la sala';
  String get roomActivity =>
      _english ? 'Room activity' : 'Actividad de la sala';
  String get roomReady => _english ? 'Ready' : 'Preparada';
  String get roomActive => _english ? 'Active' : 'Activa';
  String get roomReview => _english ? 'In review' : 'En revisión';
  String get roomBlocked => _english ? 'Blocked' : 'Bloqueada';
  String get roomNoPurpose =>
      _english ? 'No goal defined yet' : 'Sin objetivo definido';
  String get roomNoActivity => _english
      ? 'No activity has been published for this room yet.'
      : 'Todavía no hay actividad publicada para esta sala.';
  String talkToCoordinator(String profile) =>
      _english ? 'Talk to @$profile' : 'Hablar con @$profile';
  String get roomNoLinkedWork =>
      _english ? 'No linked work yet' : 'Sin trabajo enlazado todavía';
  String roomMemberCount(int count) => _english
      ? '$count ${count == 1 ? 'member' : 'members'}'
      : '$count ${count == 1 ? 'miembro' : 'miembros'}';
  String roomHomeSummary(int agents, int rooms) => _english
      ? '$agents ${agents == 1 ? 'agent' : 'agents'} · $rooms ${rooms == 1 ? 'room' : 'rooms'}'
      : '$agents ${agents == 1 ? 'agente' : 'agentes'} · $rooms ${rooms == 1 ? 'sala' : 'salas'}';
  String roomCount(int count) => _english
      ? '$count ${count == 1 ? 'room' : 'rooms'}'
      : '$count ${count == 1 ? 'sala' : 'salas'}';
  String attentionSummary(int approvals, int blocked) => _english
      ? '$approvals ${approvals == 1 ? 'approval' : 'approvals'} · $blocked blocked'
      : '$approvals ${approvals == 1 ? 'aprobación' : 'aprobaciones'} · $blocked bloqueados';
  String get noRooms => _english
      ? 'Create a room to start talking with your team.'
      : 'Crea una sala para empezar a hablar con tu equipo.';
  String get openRoom => _english ? 'Open room' : 'Abrir sala';
  String get linkedWork => _english ? 'linked tasks' : 'tareas enlazadas';
  String unavailableTaskLink(String boardId, String taskId) => _english
      ? 'Board $boardId · $taskId · not loaded'
      : 'Tablero $boardId · $taskId · no cargada';
  String get unavailableLinkedWork =>
      _english ? 'Linked work unavailable' : 'Trabajo enlazado no disponible';
  String get roomContract => _english
      ? 'The coordinator receives your messages and assigns confirmed work to the team.'
      : 'El coordinador recibe tus mensajes y reparte el trabajo confirmado al equipo.';
  String get deleteRoomTitle => _english ? 'Delete room?' : '¿Eliminar sala?';
  String get deleteRoomBody => _english
      ? 'Only this room is removed. Its chats and tasks are kept.'
      : 'Solo se elimina esta sala. Sus chats y tareas se conservan.';
  String get roomOperationPending => _english
      ? 'Finish or recover the pending Room task before editing or deleting this Room.'
      : 'Finaliza o recupera la tarea pendiente antes de editar o eliminar esta sala.';
  String get needsYou => _english ? 'Needs you' : 'Necesita tu atención';
  String get usage => _english ? 'Usage' : 'Uso';
  String get profilesUnavailable => _english
      ? 'This Hermes installation does not publish profiles.'
      : 'Esta instalación de Hermes no publica profiles.';
  String get roomsBrowseOnly => _english
      ? 'Hermes cannot verify the team right now. Saved rooms remain visible in browse-only mode.'
      : 'Hermes no puede verificar el equipo ahora. Las salas guardadas siguen visibles en modo consulta.';
  String get offline => _english
      ? 'Hermes is unavailable. Existing team data remains visible.'
      : 'Hermes no está disponible. Los datos existentes del equipo siguen visibles.';
  String get staleData => _english
      ? 'Some team data may be out of date.'
      : 'Algunos datos del equipo pueden estar desactualizados.';
  String get noProfiles => _english
      ? 'No bots are available here.'
      : 'No hay bots disponibles aquí.';
  String get noTasks =>
      _english ? 'There are no tasks here yet.' : 'Todavía no hay tareas aquí.';
  String get kanbanUnavailable => _english
      ? 'The task board is not available on this Hermes installation.'
      : 'El tablero de tareas no está disponible en esta instalación de Hermes.';
  String get noActivity => _english
      ? 'Hermes has not published recent activity for this scope.'
      : 'Hermes no ha publicado actividad reciente para este ámbito.';
  String get noApprovals => _english
      ? 'No observed approvals need attention.'
      : 'No hay aprobaciones observadas pendientes.';
  String get openChat => _english ? 'Open chat' : 'Abrir chat';
  String get review => _english ? 'Review' : 'Revisar';
  String get openKanban => _english ? 'Full task board' : 'Tablero completo';
  String get manageProfiles => _english ? 'Manage bots' : 'Gestionar bots';
  String get editProfile => _english ? 'Edit profile' : 'Editar profile';
  String get routines => _english ? 'Routines' : 'Rutinas';
  String get memory => _english ? 'Memory' : 'Memoria';
  String get skills => 'Skills';
  String get soul => 'SOUL';
  String get recentSessions =>
      _english ? 'Recent sessions' : 'Sesiones recientes';
  String get modelUnavailable =>
      _english ? 'Model not published' : 'Modelo no publicado';
  String get costUnavailable =>
      _english ? 'Cost not published' : 'Coste no publicado';
  String get partialCost => _english ? 'Partial coverage' : 'Cobertura parcial';
  String get staleProfiles => _english
      ? 'Some saved profiles no longer exist. Edit the organization to update it.'
      : 'Algunos profiles guardados ya no existen. Edita la organización para actualizarla.';
  String unattributedSessions(int count) => _english
      ? '$count session${count == 1 ? '' : 's'} did not publish a profile owner. They are included only in overall usage.'
      : '$count ${count == 1 ? 'sesión no publicó' : 'sesiones no publicaron'} su profile propietario. Solo se incluyen en el uso global.';
  String get working => _english ? 'working' : 'trabajando';
  String get approvals => _english ? 'approvals' : 'aprobaciones';
  String get blocked => _english ? 'blocked' : 'bloqueados';
  String get tokens => _english ? 'tokens' : 'tokens';
  String get input => 'input';
  String get output => 'output';
  String get cached => _english ? 'cached' : 'caché';
  String get reasoning => 'reasoning';
  String get unknown => _english ? 'Unknown' : 'Desconocido';
  String get profileLabel => 'Profile';
  String get modelLabel => _english ? 'Model' : 'Modelo';
  String get managerLabel => 'Manager';
  String get tokensUnavailable =>
      _english ? 'Tokens not published' : 'Tokens no publicados';

  // Editor del bot (identidad visible del profile: nombre, cara y sprite).
  String get editBotTitle => _english ? 'Edit bot' : 'Editar bot';
  String get botDisplayName => _english ? 'Display name' : 'Nombre visible';
  String get botDisplayNameHint =>
      _english ? 'e.g. Researcher' : 'p. ej. Investigador';
  String get botShapeLabel => _english ? 'Shape' : 'Forma';
  String get botColorLabel => _english ? 'Color' : 'Color';
  String get botFaceFallbackHint => _english
      ? 'Shape and color are only used when the bot has no sprite.'
      : 'La forma y el color solo se usan si el bot no tiene sprite.';
  String get botSpriteLabel => 'Sprite';
  String get botSpriteHint => _english
      ? 'The sprite becomes this bot\'s picture.'
      : 'El sprite se convierte en la imagen de este bot.';
  String get botSpriteNone => _english ? 'No sprite' : 'Sin sprite';
  String get botSpriteSearchHint =>
      _english ? 'Search sprites…' : 'Buscar sprites…';
  String get botSpriteEmpty =>
      _english ? 'No sprites available.' : 'No hay sprites disponibles.';
  String get botSpriteUnsupported => _english
      ? 'This Hermes installation does not support profile sprites.'
      : 'Esta instalación de Hermes no admite sprites por profile.';
  String get botEditorSaved => _english ? 'Bot updated' : 'Bot actualizado';
  String get botEditorSaveFailed => _english
      ? 'Hermes did not apply the changes.'
      : 'Hermes no aplicó los cambios.';

  // Creación de bots (paridad con CreateAgentDialog de Hermes Desktop).
  String get createAgentSubtitle => _english
      ? 'A named teammate with its own memory, skills, and chat. It can message your other agents.'
      : 'Un compañero con nombre propio, memoria, skills y chat propios. Puede escribir a tus otros agentes.';
  String get agentNameLabel => _english ? 'Name' : 'Nombre';
  String get agentNameHint => 'inbox-triage';
  String get agentNameInvalid => _english
      ? 'Use lowercase letters, numbers, dashes and underscores.'
      : 'Usa minúsculas, números, guiones y guiones bajos.';
  String get agentNameTaken => _english
      ? 'An agent with this name already exists.'
      : 'Ya existe un agente con este nombre.';
  String get agentTitleLabel => _english ? 'Title' : 'Título';
  String get agentTitleHint => 'Inbox Triage';
  String get agentDescriptionLabel => _english ? 'Description' : 'Descripción';
  String get agentDescriptionHint => _english
      ? 'What should this bot help with?'
      : '¿En qué debería ayudar este bot?';
  String get modelInherited => _english
      ? 'Inherited from the launch profile'
      : 'Heredado del profile de arranque';
  String get modelPickerTitle => _english ? 'Choose model' : 'Elegir modelo';
  String get modelCatalogEmpty => _english
      ? 'This Hermes installation did not publish a model catalog. Enter provider and model manually.'
      : 'Esta instalación de Hermes no publicó un catálogo de modelos. Escribe proveedor y modelo a mano.';
  String get providerLabel => _english ? 'Provider' : 'Proveedor';
  String get advanced => _english ? 'Advanced' : 'Avanzado';
  String get cloneFromLabel => _english ? 'Clone from profile' : 'Clonar de';
  String get cloneFresh => _english
      ? 'Fresh profile (bundled skills)'
      : 'Profile nuevo (skills incluidas)';
  String get shareAuthLabel => _english
      ? 'Share keys & accounts with the main profile'
      : 'Compartir claves y cuentas con el profile principal';
  String get shareAuthHint => _english
      ? 'Subscriptions, OAuth logins, and API keys stay shared (not copied), so token refreshes never invalidate each other. Uncheck for an isolated snapshot copy.'
      : 'Suscripciones, logins OAuth y API keys quedan compartidos (no copiados), así que los refrescos de token nunca se invalidan entre sí. Desmárcalo para una copia aislada.';
  String get noSkillsLabel => _english
      ? 'Create empty (skip bundled skills)'
      : 'Crear vacío (sin skills incluidas)';
  String get soulOptionalLabel =>
      _english ? 'SOUL.md (optional)' : 'SOUL.md (opcional)';
  String get soulOptionalHint => _english
      ? 'Leave blank to auto-generate from name/title/description.'
      : 'Déjalo en blanco para autogenerarla a partir de nombre, título y descripción.';
  String get skillsLoading => _english ? 'Loading skills…' : 'Cargando skills…';
  String get skillsUnavailable => _english
      ? 'The skill catalog needs a newer gateway (update Hermes and restart it).'
      : 'El catálogo de skills necesita un gateway más reciente (actualiza Hermes y reinícialo).';
  String skillsFromSource(String source) => _english
      ? 'Catalog from $source — unchecked skills are disabled after creation.'
      : 'Catálogo de $source: las skills desmarcadas se desactivan tras la creación.';
  String get createAgentSubmit => _english ? 'Create agent' : 'Crear agente';
  String createAgentError(String detail) => _english
      ? 'Could not create the agent: $detail'
      : 'No se pudo crear el agente: $detail';

  String status(String value) => switch (value) {
    'idle' => _english ? 'Idle' : 'Inactivo',
    'thinking' => _english ? 'Thinking' : 'Pensando',
    'working' => _english ? 'Working' : 'Trabajando',
    'responding' => _english ? 'Responding' : 'Respondiendo',
    'blocked' => _english ? 'Blocked' : 'Bloqueado',
    'approvalRequired' =>
      _english ? 'Approval required' : 'Aprobación requerida',
    'error' => 'Error',
    _ => unknown,
  };

  String activityLabel(String value) => switch (value) {
    'sessionUpdated' => _english ? 'Session active' : 'Sesión activa',
    'taskCreated' => _english ? 'Task created' : 'Tarea creada',
    'taskStarted' => _english ? 'Task started' : 'Tarea iniciada',
    'taskCompleted' => _english ? 'Task completed' : 'Tarea completada',
    'taskBlocked' => _english ? 'Task blocked' : 'Tarea bloqueada',
    _ => value,
  };

  String taskStatus(String value) => switch (value) {
    'ready' => _english ? 'ready' : 'lista',
    'running' => _english ? 'running' : 'en curso',
    'blocked' => _english ? 'blocked' : 'bloqueada',
    'review' => _english ? 'review' : 'en revisión',
    'done' => _english ? 'done' : 'completada',
    'scheduled' => _english ? 'scheduled' : 'programada',
    'todo' => _english ? 'to do' : 'pendiente',
    'triage' => _english ? 'triage' : 'triaje',
    _ => value,
  };
}
