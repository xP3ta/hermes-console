import 'package:flutter/widgets.dart';

import '../../l10n/app_localizations.dart';

final class MissionControlCopy {
  final bool _english;
  final bool _zhHant;
  final Strings _strings;

  const MissionControlCopy._(this._english, this._zhHant, this._strings);

  factory MissionControlCopy.of(BuildContext context) {
    final languageCode = Localizations.localeOf(
      context,
    ).languageCode.toLowerCase();
    return MissionControlCopy._(
      languageCode == 'en' || languageCode == 'zh',
      languageCode == 'zh',
      Strings.of(context),
    );
  }

  String _t(String en, String es, String zh) => _zhHant
      ? zh
      : _english
      ? en
      : es;

  String get title => _strings.missionTitle;
  String get allAgents => _t('All agents', 'Todos los agentes', '所有 Bot');
  String get chooseWorkspace =>
      _t('Choose workspace', 'Elegir espacio de trabajo', '選擇工作區');
  String get workspaces => _t('Workspaces', 'Espacios de trabajo', '工作區');
  String workspaceAgentCount(int count) => _zhHant
      ? '$count 位 Bot'
      : _english
      ? '$count ${count == 1 ? 'agent' : 'agents'}'
      : '$count ${count == 1 ? 'agente' : 'agentes'}';
  String get createOrganization =>
      _t('Create workspace', 'Crear espacio de trabajo', '建立工作區');
  String get editOrganization =>
      _t('Edit workspace', 'Editar espacio de trabajo', '編輯工作區');
  String get organizationName =>
      _t('Workspace name', 'Nombre del espacio de trabajo', '工作區名稱');
  String get organizationHint =>
      _t('e.g. Homelab', 'p. ej. Homelab', '例如：Homelab');
  String get chooseProfiles =>
      _t('Choose profiles', 'Selecciona profiles', '選擇設定檔');
  String get save => _strings.missionHostedSave;
  String get cancel => _strings.missionHostedCancel;
  String get delete => _t('Delete', 'Eliminar', '刪除');
  String get deleteOrganizationTitle =>
      _t('Delete workspace?', '¿Eliminar espacio de trabajo?', '刪除工作區？');
  String get deleteOrganizationBody => _t(
    'Only this local workspace is removed. Hermes profiles are not changed.',
    'Solo se elimina este espacio local. Los profiles de Hermes no cambian.',
    '只會移除此本機工作區，不會變更 Hermes 設定檔。',
  );
  String get loading =>
      _t('Reading team state…', 'Leyendo el equipo…', '正在讀取團隊狀態…');
  String get retry => _t('Retry', 'Reintentar', '重試');
  String get refresh => _t('Refresh', 'Actualizar', '重新整理');
  String get overview => _t('Overview', 'Resumen', '概覽');
  String get tasks => _t('Tasks', 'Tareas', '任務');
  String assignedTasks(int count) => _t(
    'Assigned tasks ($count)',
    'Tareas asignadas ($count)',
    '已分配任務（$count）',
  );
  String get activity => _t('Activity', 'Actividad', '活動');
  String get recentActivity =>
      _t('Recent activity', 'Actividad reciente', '最近活動');
  String get showAllActivity =>
      _t('Show all activity', 'Ver toda la actividad', '顯示所有活動');
  String get showLess => _t('Show less', 'Mostrar menos', '顯示較少');
  String get bots => _strings.missionBotsLabel;
  String botCount(int count) => _zhHant
      ? '$count 個 Bot'
      : _english
      ? '$count ${count == 1 ? 'bot' : 'bots'}'
      : '$count bots';
  String get rooms => _t('Local rooms', 'Salas locales', '本機房間');
  String get createLocalRoom =>
      _t('Create local room', 'Crear sala local', '建立本機房間');
  String get localRoomsExplanation => _t(
    'Stored only on this device; this is not a shared Room.',
    'Se guarda solo en este dispositivo; no es una Room compartida.',
    '只儲存在此裝置；這不是共享房間。',
  );
  String get sharedRoomName =>
      _t('Shared room name', 'Nombre de la sala compartida', '共享房間名稱');
  String get chooseSharedMembers =>
      _t('Choose official members', 'Elige miembros oficiales', '選擇官方成員');
  String get viewMembers => _t('View members', 'Ver miembros', '檢視成員');
  String get roomConversation => _t('Conversation', 'Conversación', '對話');
  String get replyInThread =>
      _t('Reply in thread', 'Responder en hilo', '回覆討論串');
  String get noRoomMessages => _t(
    'No messages have been published yet.',
    'Todavía no se han publicado mensajes.',
    '尚未發佈任何訊息。',
  );
  String get sharedRooms => _strings.missionSharedRooms;
  String get createSharedRoom => _strings.missionCreateSharedRoom;
  String get noSharedRooms => _strings.missionNoSharedRooms;
  String get sharedRoomsUnavailable => _strings.missionSharedRoomsUnavailable;
  String get sendSharedMessage => _strings.missionSendSharedMessage;
  String get renameSharedRoom => _strings.missionRenameSharedRoom;
  String get stopSharedRoom => _strings.missionStopSharedRoom;
  String get disbandSharedRoom => _strings.missionDisbandSharedRoom;
  String get confirm => _strings.missionConfirm;
  String get hostedActionFailed => _strings.missionHostedActionFailed;
  String get retrySharedTaskAvailable => _strings.missionHostedRetryAvailable;
  String get retrySharedTask => _strings.missionHostedRetryAction;
  String get retrySharedTaskConfirm => _strings.missionHostedRetryConfirm;
  String sharedRoomSemantics(String name, int members) =>
      _strings.missionSharedRoomSemantics(name, members);
  String get work => _strings.missionWorkLabel;
  String get globalWorkTray =>
      _t('Other pending work', 'Otros pendientes', '其他待處理工作');

  String get addToMissionControl =>
      _t('Add to Bots', 'Añadir a Bots', '加入 Bot');
  String get createAgent => _t('New agent', 'Nuevo agente', '新增 Bot');
  String get createAgentDescription => _t(
    'Create a real Hermes profile with its own model and capabilities.',
    'Crea un profile real de Hermes con su modelo y capacidades.',
    '建立具有獨立模型及功能的 Hermes 真實設定檔。',
  );
  String get createRoom => _t('Create room', 'Crear sala', '建立房間');
  String get createRoomDescription => _t(
    'Choose 2–6 bots and open their coordination room.',
    'Elige entre 2 y 6 bots y abre su sala de coordinación.',
    '選擇 2–6 個 Bot，並開啟其協作房間。',
  );
  String get startTeam => _t('Build your team', 'Crear tu equipo', '建立你的團隊');
  String get newAgent => _t('New agent', 'Nuevo agente', '新增 Bot');
  String get botChat => 'Bot Chat';
  String get botDetails => _t('Bot details', 'Detalles del bot', 'Bot 詳情');
  String get noBots => _t(
    'A bot is a named teammate with its own memory, skills and chat. Create the first one to get started.',
    'Un bot es un compañero con nombre propio, memoria, skills y chat propios. Crea el primero para empezar.',
    'Bot 是具名隊友，擁有自己的記憶、技能和聊天。建立第一個 Bot 開始使用。',
  );
  String get botNeedsYou => _t('needs you', 'te necesita', '需要你處理');
  String get needMoreBots => _t(
    'Create another bot before opening a room.',
    'Crea otro bot antes de abrir una sala.',
    '開啟房間前，請先建立另一個 Bot。',
  );
  String get needTwoAgents => _t(
    'Create at least two bots before opening a team room.',
    'Crea al menos dos bots antes de abrir una sala de equipo.',
    '開啟團隊房間前，請先建立至少兩個 Bot。',
  );
  String get searchAgents => _t('Search bots', 'Buscar bots', '搜尋 Bot');
  String get clearSearch => _t('Clear search', 'Borrar búsqueda', '清除搜尋');
  String get activeNow => _t('Active now', 'Activos ahora', '目前活躍');
  String get otherBots => _t('Other bots', 'Otros bots', '其他 Bot');
  String get allBots => _t('All bots', 'Todos los bots', '所有 Bot');
  String get searchResults => _t('Results', 'Resultados', '搜尋結果');
  String showHiddenBots(int count) =>
      _t('Show hidden ($count)', 'Mostrar ocultos ($count)', '顯示已隱藏（$count）');
  String get hideHiddenBots => _t('Hide hidden', 'Ocultar ocultos', '隱藏已隱藏');
  String get pinBot => _t('Pin to top', 'Fijar arriba', '置頂');
  String get unpinBot => _t('Unpin', 'Dejar de fijar', '取消置頂');
  String get hideBot => _t('Hide from Bots', 'Ocultar de Bots', '從 Bots 隱藏');
  String get showBot => _t('Show in Bots', 'Mostrar en Bots', '在 Bots 顯示');
  String get botRosterUpdateFailed => _t(
    'Hermes did not update this bot.',
    'Hermes no pudo actualizar este bot.',
    'Hermes 未能更新此 Bot。',
  );
  String get noMatchingAgents =>
      _t('No matching bots', 'No hay bots que coincidan', '沒有符合的 Bot');
  String get roomCoordinator => _t('Coordinator', 'Coordinador', '協調員');
  String get roomSelectionHint =>
      _t('Choose 2 to 6 bots.', 'Elige de 2 a 6 bots.', '選擇 2 至 6 個 Bot。');
  String roomSelectionCount(int count) =>
      _t('$count of 6 selected', '$count de 6 seleccionados', '已選 $count／6 個');
  String agentCreated(String name) => _t(
    'Bot @$name created. Add it to a room when you are ready.',
    'Bot @$name creado. Añádelo a una sala cuando quieras.',
    'Bot @$name 已建立。準備好後可將它加入房間。',
  );
  String get editRoom => _t('Edit room', 'Editar sala', '編輯房間');
  String get roomName => _t('Room name', 'Nombre de la sala', '房間名稱');
  String get roomHint => _t('e.g. homelab', 'p. ej. homelab', '例如：homelab');
  String get roomPurpose => _t('Purpose', 'Objetivo', '用途');
  String get roomPurposeHint => _t(
    'e.g. Keep production stable',
    'p. ej. Mantener producción estable',
    '例如：保持生產環境穩定',
  );
  String get roomNameInvalid => _t(
    'Enter a name after the # symbol.',
    'Escribe un nombre después del símbolo #.',
    '請在 # 符號後輸入名稱。',
  );
  String get roomManager => _t('Room manager', 'Manager de la sala', '房間管理員');
  String get roomMembers => _t('Room members', 'Miembros de la sala', '房間成員');
  String get roomCoordinatorShort => _t('Coordinator', 'Coordinador', '協調員');
  String get roomTeam => _t('Team', 'Equipo', '團隊');
  String get roomSummary => _t('Summary', 'Resumen', '摘要');
  String get roomTasks => _t('Room tasks', 'Tareas de la sala', '房間任務');
  String get roomActivity =>
      _t('Room activity', 'Actividad de la sala', '房間活動');
  String get roomReady => _t('Ready', 'Preparada', '就緒');
  String get roomActive => _t('Active', 'Activa', '活躍');
  String get roomReview => _t('In review', 'En revisión', '審核中');
  String get roomBlocked => _t('Blocked', 'Bloqueada', '已封鎖');
  String get roomNoPurpose =>
      _t('No goal defined yet', 'Sin objetivo definido', '尚未定義目標');
  String get roomNoActivity => _t(
    'No activity has been published for this room yet.',
    'Todavía no hay actividad publicada para esta sala.',
    '此房間尚未發佈任何活動。',
  );
  String talkToCoordinator(String profile) =>
      _t('Talk to @$profile', 'Hablar con @$profile', '聯絡 @$profile');
  String get roomNoLinkedWork =>
      _t('No linked work yet', 'Sin trabajo enlazado todavía', '尚未連結工作');
  String roomMemberCount(int count) => _strings.missionHostedMemberCount(count);
  String roomHomeSummary(int agents, int rooms) => _zhHant
      ? '$agents 個 Bot · $rooms 個房間'
      : _english
      ? '$agents ${agents == 1 ? 'agent' : 'agents'} · $rooms ${rooms == 1 ? 'room' : 'rooms'}'
      : '$agents ${agents == 1 ? 'agente' : 'agentes'} · $rooms ${rooms == 1 ? 'sala' : 'salas'}';
  String roomCount(int count) => _strings.missionHostedRoomCount(count);
  String attentionSummary(int approvals, int blocked) => _zhHant
      ? '$approvals 個批准 · $blocked 個已封鎖'
      : _english
      ? '$approvals ${approvals == 1 ? 'approval' : 'approvals'} · $blocked blocked'
      : '$approvals ${approvals == 1 ? 'aprobación' : 'aprobaciones'} · $blocked bloqueados';
  String get noRooms => _t(
    'Create a room to start talking with your team.',
    'Crea una sala para empezar a hablar con tu equipo.',
    '建立房間，開始與團隊交流。',
  );
  String get openRoom => _t('Open room', 'Abrir sala', '開啟房間');
  String get linkedWork => _t('linked tasks', 'tareas enlazadas', '個已連結任務');
  String unavailableTaskLink(String boardId, String taskId) => _t(
    'Board $boardId · $taskId · not loaded',
    'Tablero $boardId · $taskId · no cargada',
    '任務板 $boardId · $taskId · 未載入',
  );
  String get unavailableLinkedWork => _t(
    'Linked work unavailable',
    'Trabajo enlazado no disponible',
    '已連結工作不可用',
  );
  String get roomContract => _t(
    'The coordinator receives your messages and assigns confirmed work to the team.',
    'El coordinador recibe tus mensajes y reparte el trabajo confirmado al equipo.',
    '協調員會接收你的訊息，並將已確認的工作分配給團隊。',
  );
  String get deleteRoomTitle => _t('Delete room?', '¿Eliminar sala?', '刪除房間？');
  String get deleteRoomBody => _t(
    'Only this room is removed. Its chats and tasks are kept.',
    'Solo se elimina esta sala. Sus chats y tareas se conservan.',
    '只會移除此房間，房間內的聊天和任務會保留。',
  );
  String get roomOperationPending => _t(
    'Finish or recover the pending Room task before editing or deleting this Room.',
    'Finaliza o recupera la tarea pendiente antes de editar o eliminar esta sala.',
    '請先完成或復原待處理的房間任務，才可編輯或刪除此房間。',
  );
  String get needsYou => _t('Needs you', 'Necesita tu atención', '需要你處理');
  String get usage => _t('Usage', 'Uso', '用量');
  String get profilesUnavailable => _t(
    'This Hermes installation does not publish profiles.',
    'Esta instalación de Hermes no publica profiles.',
    '此 Hermes 安裝沒有提供設定檔。',
  );
  String get roomsBrowseOnly => _t(
    'Hermes cannot verify the team right now. Saved rooms remain visible in browse-only mode.',
    'Hermes no puede verificar el equipo ahora. Las salas guardadas siguen visibles en modo consulta.',
    'Hermes 現在無法驗證團隊。已儲存的房間仍會以僅瀏覽模式顯示。',
  );
  String get offline => _strings.missionOffline;
  String get staleData => _strings.missionStaleData;
  String get noProfiles => _t(
    'No bots are available here.',
    'No hay bots disponibles aquí.',
    '這裡沒有可用的 Bot。',
  );
  String get noTasks => _t(
    'There are no tasks here yet.',
    'Todavía no hay tareas aquí.',
    '這裡目前沒有任務。',
  );
  String get kanbanUnavailable => _strings.missionKanbanUnavailable;
  String get noActivity => _t(
    'Hermes has not published recent activity for this scope.',
    'Hermes no ha publicado actividad reciente para este ámbito.',
    'Hermes 尚未為此範圍發佈最近活動。',
  );
  String get noApprovals => _t(
    'No observed approvals need attention.',
    'No hay aprobaciones observadas pendientes.',
    '沒有需要處理的已觀察批准。',
  );
  String get openChat => _t('Open chat', 'Abrir chat', '開啟聊天');
  String get review => _t('Review', 'Revisar', '審核');
  String get openKanban => _t('Full task board', 'Tablero completo', '完整任務板');
  String get manageProfiles => _t('Manage bots', 'Gestionar bots', '管理 Bot');
  String get editProfile => _t('Edit profile', 'Editar profile', '編輯設定檔');
  String get routines => _t('Routines', 'Rutinas', '例行程序');
  String get memory => _t('Memory', 'Memoria', '記憶');
  String get skills => _t('Skills', 'Skills', '技能');
  String get soul => _t('SOUL', 'SOUL', 'SOUL');
  String get recentSessions =>
      _t('Recent sessions', 'Sesiones recientes', '最近工作階段');
  String get modelUnavailable =>
      _t('Model not published', 'Modelo no publicado', '模型未提供');
  String get costUnavailable =>
      _t('Cost not published', 'Coste no publicado', '費用未提供');
  String get partialCost => _t('Partial coverage', 'Cobertura parcial', '部分涵蓋');
  String get staleProfiles => _t(
    'Some saved profiles no longer exist. Edit the organization to update it.',
    'Algunos profiles guardados ya no existen. Edita la organización para actualizarla.',
    '部分已儲存的設定檔已不存在。請編輯工作區以更新。',
  );
  String unattributedSessions(int count) => _zhHant
      ? '$count 個工作階段沒有提供設定檔擁有者，只會計入整體用量。'
      : _english
      ? '$count session${count == 1 ? '' : 's'} did not publish a profile owner. They are included only in overall usage.'
      : '$count ${count == 1 ? 'sesión no publicó' : 'sesiones no publicaron'} su profile propietario. Solo se incluyen en el uso global.';
  String get working => _t('working', 'trabajando', '工作中');
  String get approvals => _t('approvals', 'aprobaciones', '批准');
  String get blocked => _t('blocked', 'bloqueados', '已封鎖');
  String get tokens => _t('tokens', 'tokens', 'Token');
  String get input => _t('input', 'input', '輸入');
  String get output => _t('output', 'output', '輸出');
  String get cached => _t('cached', 'caché', '快取');
  String get reasoning => _t('reasoning', 'razonamiento', '推理');
  String get unknown => _t('Unknown', 'Desconocido', '未知');
  String get profileLabel => _t('Profile', 'Profile', '設定檔');
  String get modelLabel => _t('Model', 'Modelo', '模型');
  String get managerLabel => _t('Manager', 'Manager', '管理員');
  String get tokensUnavailable =>
      _t('Tokens not published', 'Tokens no publicados', 'Token 未提供');

  // Editor del bot (identidad visible del profile: nombre, cara y sprite).
  String get editBotTitle => _t('Edit bot', 'Editar bot', '編輯 Bot');
  String get botDisplayName => _t('Display name', 'Nombre visible', '顯示名稱');
  String get botDisplayNameHint =>
      _t('e.g. Researcher', 'p. ej. Investigador', '例如：Researcher');
  String get botShapeLabel => _t('Shape', 'Forma', '形狀');
  String get botColorLabel => _t('Color', 'Color', '顏色');
  String get botFaceFallbackHint => _t(
    'Shape and color are only used when the bot has no sprite.',
    'La forma y el color solo se usan si el bot no tiene sprite.',
    '只有在 Bot 沒有 Sprite 時才會使用形狀和顏色。',
  );
  String get botSpriteLabel => _t('Sprite', 'Sprite', 'Sprite');
  String get botSpriteHint => _t(
    'The sprite becomes this bot\'s picture.',
    'El sprite se convierte en la imagen de este bot.',
    'Sprite 會成為此 Bot 的圖片。',
  );
  String get botSpriteNone => _t('No sprite', 'Sin sprite', '沒有 Sprite');
  String get botSpriteSearchHint =>
      _t('Search sprites…', 'Buscar sprites…', '搜尋 Sprite…');
  String get botSpriteEmpty => _t(
    'No sprites available.',
    'No hay sprites disponibles.',
    '沒有可用的 Sprite。',
  );
  String get botSpriteUnsupported => _t(
    'This Hermes installation does not support profile sprites.',
    'Esta instalación de Hermes no admite sprites por profile.',
    '此 Hermes 安裝不支援設定檔 Sprite。',
  );
  String get botEditorSaved => _t('Bot updated', 'Bot actualizado', 'Bot 已更新');
  String get botEditorSaveFailed => _t(
    'Hermes did not apply the changes.',
    'Hermes no aplicó los cambios.',
    'Hermes 未能套用變更。',
  );

  // Creación de bots (paridad con CreateAgentDialog de Hermes Desktop).
  String get createAgentSubtitle => _t(
    'A named teammate with its own memory, skills, and chat. It can message your other agents.',
    'Un compañero con nombre propio, memoria, skills y chat propios. Puede escribir a tus otros agentes.',
    '具名隊友，擁有自己的記憶、技能和聊天，也能向其他代理程式發訊息。',
  );
  String get agentNameLabel => _t('Name', 'Nombre', '名稱');
  String get agentNameHint => 'inbox-triage';
  String get agentNameInvalid => _t(
    'Use lowercase letters, numbers, dashes and underscores.',
    'Usa minúsculas, números, guiones y guiones bajos.',
    '請使用小寫字母、數字、連字號和底線。',
  );
  String get agentNameTaken => _t(
    'An agent with this name already exists.',
    'Ya existe un agente con este nombre.',
    '已有代理程式使用此名稱。',
  );
  String get agentTitleLabel => _t('Title', 'Título', '標題');
  String get agentTitleHint => 'Inbox Triage';
  String get agentDescriptionLabel => _t('Description', 'Descripción', '描述');
  String get agentDescriptionHint => _t(
    'What should this bot help with?',
    '¿En qué debería ayudar este bot?',
    '這個 Bot 應該協助處理甚麼？',
  );
  String get modelInherited => _t(
    'Inherited from the launch profile',
    'Heredado del profile de arranque',
    '繼承自啟動設定檔',
  );
  String get modelPickerTitle => _t('Choose model', 'Elegir modelo', '選擇模型');
  String get modelCatalogEmpty => _t(
    'This Hermes installation did not publish a model catalog. Enter provider and model manually.',
    'Esta instalación de Hermes no publicó un catálogo de modelos. Escribe proveedor y modelo a mano.',
    '此 Hermes 安裝沒有提供模型目錄。請手動輸入供應商和模型。',
  );
  String get providerLabel => _t('Provider', 'Proveedor', '供應商');
  String get advanced => _t('Advanced', 'Avanzado', '進階');
  String get cloneFromLabel => _t('Clone from profile', 'Clonar de', '複製自設定檔');
  String get cloneFresh => _t(
    'Fresh profile (bundled skills)',
    'Profile nuevo (skills incluidas)',
    '全新設定檔（內置技能）',
  );
  String get shareAuthLabel => _t(
    'Share keys & accounts with the main profile',
    'Compartir claves y cuentas con el profile principal',
    '與主要設定檔共用金鑰及帳戶',
  );
  String get shareAuthHint => _t(
    'Subscriptions, OAuth logins, and API keys stay shared (not copied), so token refreshes never invalidate each other. Uncheck for an isolated snapshot copy.',
    'Suscripciones, logins OAuth y API keys quedan compartidos (no copiados), así que los refrescos de token nunca se invalidan entre sí. Desmárcalo para una copia aislada.',
    '訂閱、OAuth 登入和 API 金鑰會保持共用（不會複製），因此 Token 更新不會互相失效。取消勾選即可建立獨立的快照副本。',
  );
  String get noSkillsLabel => _t(
    'Create empty (skip bundled skills)',
    'Crear vacío (sin skills incluidas)',
    '建立空白設定檔（略過內置技能）',
  );
  String get soulOptionalLabel =>
      _t('SOUL.md (optional)', 'SOUL.md (opcional)', 'SOUL.md（可選）');
  String get soulOptionalHint => _t(
    'Leave blank to auto-generate from name/title/description.',
    'Déjalo en blanco para autogenerarla a partir de nombre, título y descripción.',
    '留空即可根據名稱、標題和描述自動產生。',
  );
  String get skillsLoading =>
      _t('Loading skills…', 'Cargando skills…', '正在載入技能…');
  String get skillsUnavailable => _t(
    'The skill catalog needs a newer gateway (update Hermes and restart it).',
    'El catálogo de skills necesita un gateway más reciente (actualiza Hermes y reinícialo).',
    '技能目錄需要較新的 Gateway（請更新 Hermes 並重新啟動）。',
  );
  String skillsFromSource(String source) => _t(
    'Catalog from $source — unchecked skills are disabled after creation.',
    'Catálogo de $source: las skills desmarcadas se desactivan tras la creación.',
    '目錄來源：$source —— 建立後會停用未勾選的技能。',
  );
  String get createAgentSubmit => _t('Create agent', 'Crear agente', '建立代理程式');
  String createAgentError(String detail) => _t(
    'Could not create the agent: $detail',
    'No se pudo crear el agente: $detail',
    '無法建立代理程式：$detail',
  );

  String status(String value) => switch (value) {
    'idle' => _t('Idle', 'Inactivo', '閒置'),
    'thinking' => _t('Thinking', 'Pensando', '思考中'),
    'working' => _t('Working', 'Trabajando', '工作中'),
    'responding' => _t('Responding', 'Respondiendo', '回應中'),
    'blocked' => _t('Blocked', 'Bloqueado', '已封鎖'),
    'approvalRequired' => _t(
      'Approval required',
      'Aprobación requerida',
      '需要批准',
    ),
    'error' => _t('Error', 'Error', '錯誤'),
    _ => unknown,
  };

  String activityLabel(String value) => switch (value) {
    'sessionUpdated' => _t('Session active', 'Sesión activa', '工作階段活躍'),
    'taskCreated' => _t('Task created', 'Tarea creada', '任務已建立'),
    'taskStarted' => _t('Task started', 'Tarea iniciada', '任務已開始'),
    'taskCompleted' => _t('Task completed', 'Tarea completada', '任務已完成'),
    'taskBlocked' => _t('Task blocked', 'Tarea bloqueada', '任務已封鎖'),
    _ => value,
  };

  String taskStatus(String value) => switch (value) {
    'ready' => _t('ready', 'lista', '就緒'),
    'running' => _t('running', 'en curso', '進行中'),
    'blocked' => _t('blocked', 'bloqueada', '已封鎖'),
    'review' => _t('review', 'en revisión', '審核中'),
    'done' => _t('done', 'completada', '已完成'),
    'scheduled' => _t('scheduled', 'programada', '已排程'),
    'todo' => _t('to do', 'pendiente', '待辦'),
    'triage' => _t('triage', 'triaje', '分流'),
    _ => value,
  };
}
