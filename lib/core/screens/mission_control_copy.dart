import 'package:flutter/widgets.dart';

import '../../l10n/app_localizations.dart';

final class MissionControlCopy {
  final bool _english;
  final Strings _strings;

  const MissionControlCopy._(this._english, this._strings);

  factory MissionControlCopy.of(BuildContext context) => MissionControlCopy._(
    Localizations.localeOf(context).languageCode.toLowerCase() == 'en',
    Strings.of(context),
  );

  String get title => _strings.missionTitle;
  String get allAgents => _english ? 'All profiles' : 'Todos los perfiles';
  String get workspaces => _english ? 'Workspaces' : 'Espacios de trabajo';
  String workspaceAgentCount(int count) => _english
      ? '$count ${count == 1 ? 'profile' : 'profiles'}'
      : '$count ${count == 1 ? 'perfil' : 'perfiles'}';
  String get createOrganization =>
      _english ? 'Create workspace' : 'Crear espacio de trabajo';
  String get editOrganization =>
      _english ? 'Edit workspace' : 'Editar espacio de trabajo';
  String get organizationName =>
      _english ? 'Workspace name' : 'Nombre del espacio de trabajo';
  String get organizationHint => _english ? 'e.g. Homelab' : 'p. ej. Homelab';
  String get chooseProfiles =>
      _english ? 'Choose profiles' : 'Elige perfiles';
  String get save => _strings.missionHostedSave;
  String get cancel => _strings.missionHostedCancel;
  String get delete => _english ? 'Delete' : 'Eliminar';
  String get deleteOrganizationTitle =>
      _english ? 'Delete workspace?' : '¿Eliminar espacio de trabajo?';
  String get deleteOrganizationBody => _english
      ? 'Only this local workspace is removed. Hermes profiles are not changed.'
      : 'Solo se elimina este espacio local. Tus perfiles de Hermes no cambian.';
  String get loading => _english ? 'Loading profiles…' : 'Cargando perfiles…';
  String get retry => _english ? 'Retry' : 'Reintentar';
  String get refresh => _english ? 'Refresh' : 'Actualizar';
  String get tasks => _english ? 'Tasks' : 'Tareas';
  String get activity => _english ? 'Activity' : 'Actividad';
  String get showLess => _english ? 'Show less' : 'Mostrar menos';
  String get bots => _strings.missionBotsLabel;
  String get sharedRoomName =>
      _english ? 'Room name' : 'Nombre de la sala';
  String get chooseSharedMembers =>
      _english ? 'Choose official members' : 'Elige miembros oficiales';

  String get createSharedRoom => _strings.missionCreateSharedRoom;
  String get roomRefreshFailed => _english
      ? 'Could not refresh this room. Reopen it to reconnect.'
      : 'No se pudo actualizar esta sala. Vuelve a abrirla para reconectar.';
  String get renameSharedRoom => _strings.missionRenameSharedRoom;
  // "¿Detener/Disolver la sala compartida?" es el título del diálogo de
  // confirmación (pregunta, tiene sentido ahí) — reutilizado tal cual como
  // etiqueta del ítem del menú de los "..." leía como una pregunta suelta,
  // inconsistente con "Renombrar sala compartida" justo al lado (confirmado
  // en dispositivo real). Los *Action de abajo son la forma imperativa,
  // solo para las filas del menú; los diálogos de confirmación siguen
  // usando `stopSharedRoom`/`disbandSharedRoom` tal cual.
  String get stopSharedRoom => _strings.missionStopSharedRoom;
  String get disbandSharedRoom => _strings.missionDisbandSharedRoom;
  String get stopSharedRoomAction => _strings.missionStopSharedRoomAction;
  String get disbandSharedRoomAction =>
      _strings.missionDisbandSharedRoomAction;
  String get confirm => _strings.missionConfirm;
  String get hostedActionFailed => _strings.missionHostedActionFailed;

  String get newAgent => _english ? 'New profile' : 'Nuevo perfil';
  String get botChat => 'Bot Chat';
  String get noBots => _english
      ? 'A profile has its own name, memory, skills and chat. Create the first one to get started.'
      : 'Un perfil tiene nombre, memoria, skills y chat propios. Crea el primero para empezar.';
  String get searchAgents => _english ? 'Search profiles' : 'Buscar perfiles';
  String get clearSearch => _english ? 'Clear search' : 'Borrar búsqueda';
  String get activeNow => _english ? 'Active now' : 'Activos ahora';
  String get botRosterUpdateFailed => _english
      ? 'Hermes did not update this profile.'
      : 'Hermes no pudo actualizar este perfil.';
  String get noMatchingAgents =>
      _english ? 'No matching profiles' : 'No hay perfiles que coincidan';
  String roomMemberCount(int count) => _strings.missionHostedMemberCount(count);
  String roomCount(int count) => _strings.missionHostedRoomCount(count);
  String attentionSummary(int approvals, int blocked) => _english
      ? '$approvals ${approvals == 1 ? 'approval' : 'approvals'} · $blocked blocked'
      : '$approvals ${approvals == 1 ? 'aprobación' : 'aprobaciones'} · $blocked bloqueados';
  String get needsYou => _english ? 'Needs you' : 'Necesita tu atención';
  String get usage => _english ? 'Usage' : 'Uso';
  String get profilesUnavailable => _english
      ? 'This Hermes installation does not publish profiles.'
      : 'Esta instalación de Hermes no publica perfiles.';
  String get offline => _strings.missionOffline;
  String get staleData => _strings.missionStaleData;
  String get review => _english ? 'Review' : 'Revisar';
  String get memory => _english ? 'Memory' : 'Memoria';
  String get skills => 'Skills';
  String get soul => 'SOUL';
  String get staleProfiles => _english
      ? 'Some saved profiles no longer exist. Edit the organization to update it.'
      : 'Algunos perfiles guardados ya no existen. Edita la organización para actualizarla.';
  String unattributedSessions(int count) => _english
      ? '$count session${count == 1 ? '' : 's'} did not publish a profile owner. They are included only in overall usage.'
      : '$count ${count == 1 ? 'sesión no publicó' : 'sesiones no publicaron'} su perfil propietario. Solo se incluyen en el uso global.';
  String get working => _english ? 'working' : 'trabajando';
  String get approvals => _english ? 'approvals' : 'aprobaciones';
  String get blocked => _english ? 'blocked' : 'bloqueados';
  String get tokens => _english ? 'tokens' : 'tokens';
  String get input => 'input';
  String get output => 'output';
  String get reasoning => 'reasoning';
  String get unknown => _english ? 'Unknown' : 'Desconocido';
  String get modelLabel => _english ? 'Model' : 'Modelo';
  String get managerLabel => 'Manager';

  // Editor del bot (identidad visible del profile: nombre, cara y sprite).
  String get editBotTitle => _english ? 'Edit profile' : 'Editar perfil';
  String get botDisplayName => _english ? 'Display name' : 'Nombre visible';
  String get botDisplayNameHint =>
      _english ? 'e.g. Researcher' : 'p. ej. Investigador';
  String get botSpriteHint => _english
      ? 'The sprite becomes this profile\'s picture.'
      : 'El sprite se convierte en la imagen de este perfil.';
  String get botSpriteSearchHint =>
      _english ? 'Search sprites…' : 'Buscar sprites…';
  String get botSpriteEmpty =>
      _english ? 'No sprites available.' : 'No hay sprites disponibles.';
  String get botSpriteUnsupported => _english
      ? 'This Hermes installation does not support profile sprites.'
      : 'Esta instalación de Hermes no admite sprites por perfil.';
  String get botEditorSaved =>
      _english ? 'Profile updated' : 'Perfil actualizado';
  String get botEditorSaveFailed => _english
      ? 'Hermes did not apply the changes.'
      : 'Hermes no aplicó los cambios.';

  // Creación de bots (paridad con CreateAgentDialog de Hermes Desktop).
  String get createAgentSubtitle => _english
      ? 'A profile has its own name, memory, skills and chat. It can message your other profiles.'
      : 'Un perfil tiene nombre, memoria, skills y chat propios. Puede escribir a tus otros perfiles.';
  String get agentNameLabel => _english ? 'Name' : 'Nombre';
  String get agentNameHint => 'inbox-triage';
  String get agentNameInvalid => _english
      ? 'Use lowercase letters, numbers, dashes and underscores.'
      : 'Usa minúsculas, números, guiones y guiones bajos.';
  String get agentNameTaken => _english
      ? 'A profile with this name already exists.'
      : 'Ya existe un perfil con este nombre.';
  String get agentTitleLabel => _english ? 'Title' : 'Título';
  String get agentTitleHint => 'Inbox Triage';
  String get agentDescriptionLabel => _english ? 'Description' : 'Descripción';
  String get agentDescriptionHint => _english
      ? 'What should this profile help with?'
      : '¿En qué debería ayudar este perfil?';
  String get modelInherited => _english
      ? 'Inherited from the launch profile'
      : 'Heredado del perfil de arranque';
  String get modelCatalogEmpty => _english
      ? 'This Hermes installation did not publish a model catalog. Enter provider and model manually.'
      : 'Esta instalación de Hermes no publicó un catálogo de modelos. Escribe proveedor y modelo a mano.';
  String get providerLabel => _english ? 'Provider' : 'Proveedor';
  String get advanced => _english ? 'Advanced' : 'Avanzado';
  String get cloneFromLabel => _english ? 'Clone from profile' : 'Clonar de';
  String get cloneFresh => _english
      ? 'Fresh profile (bundled skills)'
      : 'Perfil nuevo (skills incluidas)';
  String get shareAuthLabel => _english
      ? 'Share keys & accounts with the main profile'
      : 'Compartir claves y cuentas con el perfil principal';
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
  String get createAgentSubmit => _english ? 'Create profile' : 'Crear perfil';
  String createAgentError(String detail) => _english
      ? 'Could not create the profile: $detail'
      : 'No se pudo crear el perfil: $detail';
  String agentCreated(String name) => _english
      ? 'Profile @$name created. Add it to a room when you are ready.'
      : 'Perfil @$name creado. Añádelo a una sala cuando quieras.';

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
}
