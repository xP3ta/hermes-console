import 'package:flutter/widgets.dart';

import '../../l10n/app_localizations.dart';

final class MissionControlCopy {
  final String _lang;
  final Strings _strings;

  const MissionControlCopy._(this._lang, this._strings);

  factory MissionControlCopy.of(BuildContext context) => MissionControlCopy._(
    switch (Localizations.localeOf(context).languageCode.toLowerCase()) {
      'es' => 'es',
      'pt' => 'pt',
      _ => 'en',
    },
    Strings.of(context),
  );

  String _t(String en, String es, String pt) => switch (_lang) {
    'es' => es,
    'pt' => pt,
    _ => en,
  };

  String get title => _strings.missionTitle;
  String get allAgents =>
      _t('All profiles', 'Todos los perfiles', 'Todos os perfis');
  String get workspaces =>
      _t('Workspaces', 'Espacios de trabajo', 'Espaços de trabalho');
  String workspaceAgentCount(int count) => _t(
    '$count ${count == 1 ? 'profile' : 'profiles'}',
    '$count ${count == 1 ? 'perfil' : 'perfiles'}',
    '$count ${count == 1 ? 'perfil' : 'perfis'}',
  );
  String get createOrganization => _t(
    'Create workspace',
    'Crear espacio de trabajo',
    'Criar espaço de trabalho',
  );
  String get editOrganization => _t(
    'Edit workspace',
    'Editar espacio de trabajo',
    'Editar espaço de trabalho',
  );
  String get organizationName => _t(
    'Workspace name',
    'Nombre del espacio de trabajo',
    'Nome do espaço de trabalho',
  );
  String get organizationHint =>
      _t('e.g. Homelab', 'p. ej. Homelab', 'ex.: Homelab');
  String get chooseProfiles =>
      _t('Choose profiles', 'Elige perfiles', 'Escolher perfis');
  String get save => _strings.missionHostedSave;
  String get cancel => _strings.missionHostedCancel;
  String get delete => _t('Delete', 'Eliminar', 'Excluir');
  String get deleteOrganizationTitle => _t(
    'Delete workspace?',
    '¿Eliminar espacio de trabajo?',
    'Excluir espaço de trabalho?',
  );
  String get deleteOrganizationBody => _t(
    'Only this local workspace is removed. Hermes profiles are not changed.',
    'Solo se elimina este espacio local. Tus perfiles de Hermes no cambian.',
    'Apenas este espaço de trabalho local é removido. Seus perfis do Hermes não mudam.',
  );
  String get loading =>
      _t('Loading profiles…', 'Cargando perfiles…', 'Carregando perfis…');
  String get retry => _t('Retry', 'Reintentar', 'Tentar novamente');
  String get refresh => _t('Refresh', 'Actualizar', 'Atualizar');
  String get tasks => _t('Tasks', 'Tareas', 'Tarefas');
  String get activity => _t('Activity', 'Actividad', 'Atividade');
  String get showLess => _t('Show less', 'Mostrar menos', 'Mostrar menos');
  String get bots => _strings.missionBotsLabel;
  String get sharedRoomName =>
      _t('Room name', 'Nombre de la sala', 'Nome da sala');
  String get chooseSharedMembers => _t(
    'Choose official members',
    'Elige miembros oficiales',
    'Escolher membros oficiais',
  );

  String get createSharedRoom => _strings.missionCreateSharedRoom;
  String get roomRefreshFailed => _t(
    'Could not refresh this room. Reopen it to reconnect.',
    'No se pudo actualizar esta sala. Vuelve a abrirla para reconectar.',
    'Não foi possível atualizar esta sala. Reabra-a para reconectar.',
  );
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
  String get disbandSharedRoomAction => _strings.missionDisbandSharedRoomAction;
  String get confirm => _strings.missionConfirm;
  String get hostedActionFailed => _strings.missionHostedActionFailed;

  String get newAgent => _t('New profile', 'Nuevo perfil', 'Novo perfil');
  String get botChat => 'Bot Chat';
  String get noBots => _t(
    'A profile has its own name, memory, skills and chat. Create the first one to get started.',
    'Un perfil tiene nombre, memoria, skills y chat propios. Crea el primero para empezar.',
    'Um perfil tem nome, memória, skills e chat próprios. Crie o primeiro para começar.',
  );
  String get searchAgents =>
      _t('Search profiles', 'Buscar perfiles', 'Buscar perfis');
  String get clearSearch =>
      _t('Clear search', 'Borrar búsqueda', 'Limpar busca');
  String get activeNow => _t('Active now', 'Activos ahora', 'Ativos agora');
  String get botRosterUpdateFailed => _t(
    'Hermes did not update this profile.',
    'Hermes no pudo actualizar este perfil.',
    'O Hermes não atualizou este perfil.',
  );
  String get noMatchingAgents => _t(
    'No matching profiles',
    'No hay perfiles que coincidan',
    'Nenhum perfil correspondente',
  );
  String roomMemberCount(int count) => _strings.missionHostedMemberCount(count);
  String roomCount(int count) => _strings.missionHostedRoomCount(count);
  String attentionSummary(int approvals, int blocked) => _t(
    '$approvals ${approvals == 1 ? 'approval' : 'approvals'} · $blocked blocked',
    '$approvals ${approvals == 1 ? 'aprobación' : 'aprobaciones'} · $blocked bloqueados',
    '$approvals ${approvals == 1 ? 'aprovação' : 'aprovações'} · $blocked bloqueados',
  );
  String get needsYou =>
      _t('Needs you', 'Necesita tu atención', 'Precisa de você');
  String get usage => _t('Usage', 'Uso', 'Uso');
  String get profilesUnavailable => _t(
    'This Hermes installation does not publish profiles.',
    'Esta instalación de Hermes no publica perfiles.',
    'Esta instalação do Hermes não publica perfis.',
  );
  String get offline => _strings.missionOffline;
  String get staleData => _strings.missionStaleData;
  String get review => _t('Review', 'Revisar', 'Revisar');
  String get memory => _t('Memory', 'Memoria', 'Memória');
  String get skills => 'Skills';
  String get soul => 'SOUL';
  String get staleProfiles => _t(
    'Some saved profiles no longer exist. Edit the organization to update it.',
    'Algunos perfiles guardados ya no existen. Edita la organización para actualizarla.',
    'Alguns perfis salvos não existem mais. Edite o espaço de trabalho para atualizá-lo.',
  );
  String unattributedSessions(int count) => _t(
    '$count session${count == 1 ? '' : 's'} did not publish a profile owner. They are included only in overall usage.',
    '$count ${count == 1 ? 'sesión no publicó' : 'sesiones no publicaron'} su perfil propietario. Solo se incluyen en el uso global.',
    '$count ${count == 1 ? 'sessão não publicou' : 'sessões não publicaram'} o perfil proprietário. Elas são incluídas apenas no uso geral.',
  );
  String get working => _t('working', 'trabajando', 'trabalhando');
  String get approvals => _t('approvals', 'aprobaciones', 'aprovações');
  String get blocked => _t('blocked', 'bloqueados', 'bloqueados');
  String get tokens => _t('tokens', 'tokens', 'tokens');
  String get input => 'input';
  String get output => 'output';
  String get reasoning => 'reasoning';
  String get unknown => _t('Unknown', 'Desconocido', 'Desconhecido');
  String get modelLabel => _t('Model', 'Modelo', 'Modelo');
  String get managerLabel => 'Manager';

  // Editor del bot (identidad visible del profile: nombre, cara y sprite).
  String get editBotTitle =>
      _t('Edit profile', 'Editar perfil', 'Editar perfil');
  String get botDisplayName =>
      _t('Display name', 'Nombre visible', 'Nome de exibição');
  String get botDisplayNameHint =>
      _t('e.g. Researcher', 'p. ej. Investigador', 'ex.: Pesquisador');
  String get botSpriteHint => _t(
    'The sprite becomes this profile\'s picture.',
    'El sprite se convierte en la imagen de este perfil.',
    'O sprite se torna a imagem deste perfil.',
  );
  String get botSpriteSearchHint =>
      _t('Search sprites…', 'Buscar sprites…', 'Buscar sprites…');
  String get botSpriteEmpty => _t(
    'No sprites available.',
    'No hay sprites disponibles.',
    'Nenhum sprite disponível.',
  );
  String get botSpriteLoadFailed => _t(
    'Couldn\'t load the list.',
    'No se pudo cargar la lista.',
    'Não foi possível carregar a lista.',
  );
  String get botSpriteUnsupported => _t(
    'This Hermes installation does not support profile sprites.',
    'Esta instalación de Hermes no admite sprites por perfil.',
    'Esta instalação do Hermes não oferece suporte a sprites por perfil.',
  );
  String get botEditorSaved =>
      _t('Profile updated', 'Perfil actualizado', 'Perfil atualizado');
  String get botEditorSaveFailed => _t(
    'Hermes did not apply the changes.',
    'Hermes no aplicó los cambios.',
    'O Hermes não aplicou as alterações.',
  );

  // Creación de bots (paridad con CreateAgentDialog de Hermes Desktop).
  String get createAgentSubtitle => _t(
    'A profile has its own name, memory, skills and chat. It can message your other profiles.',
    'Un perfil tiene nombre, memoria, skills y chat propios. Puede escribir a tus otros perfiles.',
    'Um perfil tem nome, memória, skills e chat próprios. Ele pode enviar mensagens aos seus outros perfis.',
  );
  String get agentNameLabel => _t('Name', 'Nombre', 'Nome');
  String get agentNameHint => 'inbox-triage';
  String get agentNameInvalid => _t(
    'Use lowercase letters, numbers, dashes and underscores.',
    'Usa minúsculas, números, guiones y guiones bajos.',
    'Use letras minúsculas, números, hífens e sublinhados.',
  );
  String get agentNameTaken => _t(
    'A profile with this name already exists.',
    'Ya existe un perfil con este nombre.',
    'Já existe um perfil com este nome.',
  );
  String get agentTitleLabel => _t('Title', 'Título', 'Título');
  String get agentTitleHint => 'Inbox Triage';
  String get agentDescriptionLabel =>
      _t('Description', 'Descripción', 'Descrição');
  String get agentDescriptionHint => _t(
    'What should this profile help with?',
    '¿En qué debería ayudar este perfil?',
    'Com o que este perfil deve ajudar?',
  );
  String get modelInherited => _t(
    'Inherited from the launch profile',
    'Heredado del perfil de arranque',
    'Herdado do perfil de inicialização',
  );
  String get providerLabel => _t('Provider', 'Proveedor', 'Provedor');
  String get advanced => _t('Advanced', 'Avanzado', 'Avançado');
  String get cloneFromLabel =>
      _t('Clone from profile', 'Clonar de', 'Clonar de');
  String get cloneFresh => _t(
    'Fresh profile (bundled skills)',
    'Perfil nuevo (skills incluidas)',
    'Perfil novo (skills incluídas)',
  );
  String get shareAuthLabel => _t(
    'Share keys & accounts with the main profile',
    'Compartir claves y cuentas con el perfil principal',
    'Compartilhar chaves e contas com o perfil principal',
  );
  String get shareAuthHint => _t(
    'Subscriptions, OAuth logins, and API keys stay shared (not copied), so token refreshes never invalidate each other. Uncheck for an isolated snapshot copy.',
    'Suscripciones, logins OAuth y API keys quedan compartidos (no copiados), así que los refrescos de token nunca se invalidan entre sí. Desmárcalo para una copia aislada.',
    'Assinaturas, logins OAuth e API keys ficam compartilhados (não copiados), então as renovações de token nunca se invalidam entre si. Desmarque para uma cópia isolada.',
  );
  String get noSkillsLabel => _t(
    'Create empty (skip bundled skills)',
    'Crear vacío (sin skills incluidas)',
    'Criar vazio (sem skills incluídas)',
  );
  String get soulOptionalLabel =>
      _t('SOUL.md (optional)', 'SOUL.md (opcional)', 'SOUL.md (opcional)');
  String get soulOptionalHint => _t(
    'Leave blank to auto-generate from name/title/description.',
    'Déjalo en blanco para autogenerarla a partir de nombre, título y descripción.',
    'Deixe em branco para gerar automaticamente a partir de nome, título e descrição.',
  );
  String get createAgentSubmit =>
      _t('Create profile', 'Crear perfil', 'Criar perfil');
  String createAgentError(String detail) => _t(
    'Could not create the profile: $detail',
    'No se pudo crear el perfil: $detail',
    'Não foi possível criar o perfil: $detail',
  );
  String agentCreated(String name) => _t(
    'Profile @$name created. Add it to a room when you are ready.',
    'Perfil @$name creado. Añádelo a una sala cuando quieras.',
    'Perfil @$name criado. Adicione-o a uma sala quando quiser.',
  );

  String status(String value) => switch (value) {
    'idle' => _t('Idle', 'Inactivo', 'Ocioso'),
    'thinking' => _t('Thinking', 'Pensando', 'Pensando'),
    'working' => _t('Working', 'Trabajando', 'Trabalhando'),
    'responding' => _t('Responding', 'Respondiendo', 'Respondendo'),
    'blocked' => _t('Blocked', 'Bloqueado', 'Bloqueado'),
    'approvalRequired' => _t(
      'Approval required',
      'Aprobación requerida',
      'Aprovação necessária',
    ),
    'error' => 'Error',
    _ => unknown,
  };

  String activityLabel(String value) => switch (value) {
    'sessionUpdated' => _t('Session active', 'Sesión activa', 'Sessão ativa'),
    'taskCreated' => _t('Task created', 'Tarea creada', 'Tarefa criada'),
    'taskStarted' => _t('Task started', 'Tarea iniciada', 'Tarefa iniciada'),
    'taskCompleted' => _t(
      'Task completed',
      'Tarea completada',
      'Tarefa concluída',
    ),
    'taskBlocked' => _t('Task blocked', 'Tarea bloqueada', 'Tarefa bloqueada'),
    _ => value,
  };
}
