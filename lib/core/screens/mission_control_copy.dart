import 'package:flutter/widgets.dart';

import '../../l10n/app_localizations.dart';

/// Typed facade over the i18n131Mc ARB family.
final class MissionControlCopy {
  final Strings _strings;

  const MissionControlCopy._(this._strings);

  factory MissionControlCopy.of(BuildContext context) =>
      MissionControlCopy._(Strings.of(context));

  String get title => _strings.missionTitle;
  String get allAgents =>
      _strings.i18n131McAllAgents;
  String get workspaces =>
      _strings.i18n131McWorkspaces;
  String workspaceAgentCount(int count) => count == 1
      ? _strings.i18n131McWorkspaceAgentCountOne(count)
      : _strings.i18n131McWorkspaceAgentCountOther(count);
  String get createOrganization => _strings.i18n131McCreateOrganization;
  String get editOrganization => _strings.i18n131McEditOrganization;
  String get organizationName => _strings.i18n131McOrganizationName;
  String get organizationHint =>
      _strings.i18n131McOrganizationHint;
  String get chooseProfiles =>
      _strings.i18n131McChooseProfiles;
  String get save => _strings.missionHostedSave;
  String get cancel => _strings.missionHostedCancel;
  String get delete => _strings.i18n131McDelete;
  String get deleteOrganizationTitle => _strings.i18n131McDeleteOrganizationTitle;
  String get deleteOrganizationBody => _strings.i18n131McDeleteOrganizationBody;
  String get loading =>
      _strings.i18n131McLoading;
  String get retry => _strings.i18n131McRetry;
  String get refresh => _strings.i18n131McRefresh;
  String get tasks => _strings.i18n131McTasks;
  String get activity => _strings.i18n131McActivity;
  String get showLess => _strings.i18n131McShowLess;
  String get bots => _strings.missionBotsLabel;
  String get sharedRoomName =>
      _strings.i18n131McSharedRoomName;
  String get chooseSharedMembers => _strings.i18n131McChooseSharedMembers;

  String get createSharedRoom => _strings.missionCreateSharedRoom;
  String get roomRefreshFailed => _strings.i18n131McRoomRefreshFailed;
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

  String get newAgent => _strings.i18n131McNewAgent;
  String get botChat => _strings.i18n131McBotChat;
  String get noBots => _strings.i18n131McNoBots;
  String get searchAgents =>
      _strings.i18n131McSearchAgents;
  String get clearSearch =>
      _strings.i18n131McClearSearch;
  String get activeNow => _strings.i18n131McActiveNow;
  String get botRosterUpdateFailed => _strings.i18n131McBotRosterUpdateFailed;
  String get noMatchingAgents => _strings.i18n131McNoMatchingAgents;
  String roomMemberCount(int count) => _strings.missionHostedMemberCount(count);
  String roomCount(int count) => _strings.missionHostedRoomCount(count);
  String attentionSummary(int approvals, int blocked) => approvals == 1
      ? _strings.i18n131McAttentionSummaryOne(approvals, blocked)
      : _strings.i18n131McAttentionSummaryOther(approvals, blocked);
  String get needsYou =>
      _strings.i18n131McNeedsYou;
  String get usage => _strings.i18n131McUsage;
  String get profilesUnavailable => _strings.i18n131McProfilesUnavailable;
  String get offline => _strings.missionOffline;
  String get staleData => _strings.missionStaleData;
  String get review => _strings.i18n131McReview;
  String get memory => _strings.i18n131McMemory;
  String get skills => _strings.i18n131McSkills;
  String get soul => _strings.i18n131McSoul;
  String get staleProfiles => _strings.i18n131McStaleProfiles;
  String unattributedSessions(int count) => count == 1
      ? _strings.i18n131McUnattributedSessionsOne(count)
      : _strings.i18n131McUnattributedSessionsOther(count);
  String get working => _strings.i18n131McWorking;
  String get approvals => _strings.i18n131McApprovals;
  String get blocked => _strings.i18n131McBlocked;
  String get tokens => _strings.i18n131McTokens;
  String get input => _strings.i18n131McInput;
  String get output => _strings.i18n131McOutput;
  String get reasoning => _strings.i18n131McReasoning;
  String get unknown => _strings.i18n131McUnknown;
  String get modelLabel => _strings.i18n131McModelLabel;
  String get managerLabel => _strings.i18n131McManagerLabel;

  // Editor del bot (identidad visible del profile: nombre, cara y sprite).
  String get editBotTitle =>
      _strings.i18n131McEditBotTitle;
  String get botDisplayName =>
      _strings.i18n131McBotDisplayName;
  String get botDisplayNameHint =>
      _strings.i18n131McBotDisplayNameHint;
  String get botSpriteHint => _strings.i18n131McBotSpriteHint;
  String get botSpriteSearchHint =>
      _strings.i18n131McBotSpriteSearchHint;
  String get botSpriteEmpty => _strings.i18n131McBotSpriteEmpty;
  String get botSpriteLoadFailed => _strings.i18n131McBotSpriteLoadFailed;
  String get botSpriteUnsupported => _strings.i18n131McBotSpriteUnsupported;
  String get botEditorSaved =>
      _strings.i18n131McBotEditorSaved;
  String get botEditorSaveFailed => _strings.i18n131McBotEditorSaveFailed;

  // Creación de bots (paridad con CreateAgentDialog de Hermes Desktop).
  String get createAgentSubtitle => _strings.i18n131McCreateAgentSubtitle;
  String get agentNameLabel => _strings.i18n131McAgentNameLabel;
  String get agentNameHint => _strings.i18n131McAgentNameHint;
  String get agentNameInvalid => _strings.i18n131McAgentNameInvalid;
  String get agentNameTaken => _strings.i18n131McAgentNameTaken;
  String get agentTitleLabel => _strings.i18n131McAgentTitleLabel;
  String get agentTitleHint => _strings.i18n131McAgentTitleHint;
  String get agentDescriptionLabel =>
      _strings.i18n131McAgentDescriptionLabel;
  String get agentDescriptionHint => _strings.i18n131McAgentDescriptionHint;
  String get modelInherited => _strings.i18n131McModelInherited;
  String get providerLabel => _strings.i18n131McProviderLabel;
  String get advanced => _strings.i18n131McAdvanced;
  String get cloneFromLabel =>
      _strings.i18n131McCloneFromLabel;
  String get cloneFresh => _strings.i18n131McCloneFresh;
  String get shareAuthLabel => _strings.i18n131McShareAuthLabel;
  String get shareAuthHint => _strings.i18n131McShareAuthHint;
  String get noSkillsLabel => _strings.i18n131McNoSkillsLabel;
  String get soulOptionalLabel =>
      _strings.i18n131McSoulOptionalLabel;
  String get soulOptionalHint => _strings.i18n131McSoulOptionalHint;
  String get createAgentSubmit =>
      _strings.i18n131McCreateAgentSubmit;
  String createAgentError(String detail) => _strings.i18n131McCreateAgentError(detail);
  String agentCreated(String name) => _strings.i18n131McAgentCreated(name);

  String status(String value) => switch (value) {
    'idle' => _strings.i18n131McStatusIdle,
    'thinking' => _strings.i18n131McStatusThinking,
    'working' => _strings.i18n131McStatusWorking,
    'responding' => _strings.i18n131McStatusResponding,
    'blocked' => _strings.i18n131McStatusBlocked,
    'approvalRequired' => _strings.i18n131McStatusApprovalRequired,
    'error' => _strings.i18n131McStatusError,
    _ => unknown,
  };

  String activityLabel(String value) => switch (value) {
    'sessionUpdated' => _strings.i18n131McActivityLabelSessionUpdated,
    'taskCreated' => _strings.i18n131McActivityLabelTaskCreated,
    'taskStarted' => _strings.i18n131McActivityLabelTaskStarted,
    'taskCompleted' => _strings.i18n131McActivityLabelTaskCompleted,
    'taskBlocked' => _strings.i18n131McActivityLabelTaskBlocked,
    _ => value,
  };
}
