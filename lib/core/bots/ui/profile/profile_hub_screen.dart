import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../l10n/app_localizations.dart';
import '../../../capabilities/capabilities_screen.dart';
import '../../../capabilities/capability_models.dart';
import '../../../design/hermes_design.dart' show HermesStatusTone, HermesTag;
import '../../../models/agent_profile.dart';
import '../../../config/feature_flags.dart';
import '../../../navigation/agents_destination.dart';
import '../../../screens/activity_screen.dart';
import '../../../screens/artifacts_screen.dart';
import '../../../screens/backup_restore_screen.dart';
import '../../../screens/bot_profile_settings_screen.dart';
import '../../../screens/characters/character_studio_screen.dart';
import '../../../screens/characters/studio_ask_agent.dart';
import '../../../screens/cron_screen.dart';
import '../../../screens/env_keys_screen.dart';
import '../../../screens/memory_screen.dart';
import '../../../screens/profile_editor_screen.dart';
import '../../../screens/projects_center_screen.dart';
import '../../../screens/screen_peek_screen.dart';
import '../../../screens/security_info_screen.dart';
import '../../../screens/soul_screen.dart';
import '../../../screens/task_center_screen.dart';
import '../../../screens/tasks_screen.dart';
import '../../../screens/tools_hub_screen.dart';
import '../../../screens/usage_analytics_screen.dart';
import '../../../screens/vault_screen.dart';
import '../../../screens/voice_settings_screen.dart';
import '../../../services/active_profile_scope.dart';
import '../../../services/bot_profile_client.dart';
import '../../../services/bot_roster_store.dart';
import '../../../services/connection_manager.dart';
import '../../../services/shared_gateway_pool.dart';
import '../../../services/ssh_profile_presence.dart';
import '../../../services/tui_gateway_client.dart';
import '../../../theme/app_theme.dart';
import '../../../design/tokens.dart';
import '../../../widgets/hermes_app_bar.dart';
import '../../../widgets/hermes_drawer.dart' show buildCapabilitiesHub;
import '../../../widgets/hermes_notice.dart';
import '../../../widgets/hermes_ui.dart' show HermesGroup;
import '../../../widgets/owned_resource_host.dart';
import '../../../widgets/profile_face.dart';
import '../../../widgets/profile_switcher.dart';
import 'profile_model_picker.dart';

/// Where a row of the profile hub sits.
enum ProfileHubSection { integrations, work, agent, advanced }

/// A row of the hub and the section it is in.
@immutable
class ProfileHubEntry {
  const ProfileHubEntry(this.section, this.destination);

  final ProfileHubSection section;
  final HermesToolDestination destination;
}

/// The profile of one bot (1.4.0): everything that is of THAT bot in one
/// page: avatar, name and description
/// on top (a tap edits the profile), then Model and Skills, Integrations,
/// Work, Agent and a folded Advanced.
///
/// Every row acts on [profile], not on the app's active profile:
///
///  * the screens that take a profile (Memory, SOUL, Cron, Skills, Plugins,
///    MCP, Keys, Usage, Vault, Backup, Voice, Task center, the bot's screen,
///    Characters, Logs, Artifacts, Kanban's assignee) are opened with it;
///  * the model is read and written for [profile] (`profiles.configure`);
///  * Projects has no profile of its own and opens chats with the active
///    one, so its row makes [profile] the active profile first, in plain
///    sight (a notice says «Perfil activo: X») and says so under its name;
///  * Agents belong to the machine of the SSH profile, not to a bot.
///
/// «Cambiar de perfil» re-makes this same page for the picked profile: the
/// pick becomes the app's active profile (chats, Home, drawer, roster) and
/// the page shows it at once, with «Activo» following the real active one;
/// a profile that is not the active one offers «Hacer activo».
///
/// Opened from Bots (tap a bot) and from the avatar on Home (the active one).
class ProfileHubScreen extends StatefulWidget {
  const ProfileHubScreen({
    required this.connection,
    required this.connManager,
    required this.profile,
    this.onChat,
    this.onOpenBotCard,
    this.onChanged,
    this.onEdited,
    this.rosterRegistry,
    this.modelGateway,
    this.profileGateway,
    this.capabilitiesCache,
    this.preferences,
    @visibleForTesting this.editorBuilder,
    super.key,
  });

  final SavedConnection connection;
  final ConnectionManager connManager;

  /// The bot's profile name (`default` for the main one) the page opens on;
  /// «Cambiar de perfil» moves the page to another one.
  final String profile;

  /// Opens the chat of [profile]; the Chat pill shows only with it, and only
  /// while the page still shows that profile.
  final VoidCallback? onChat;

  /// Opens the card of [profile] (what it is doing now, rooms, duplicate,
  /// delete); the row shows only with it, as it needs the Bots screen, and
  /// only while the page still shows that profile.
  final VoidCallback? onOpenBotCard;

  /// Hermes accepted another model for this profile (the Bots screen reloads
  /// its roster).
  final VoidCallback? onChanged;

  /// The profile editor saved (name, face…): whoever lists this profile
  /// reloads it and forgets its cached avatar.
  final VoidCallback? onEdited;

  final BotRosterRegistry? rosterRegistry;

  /// Test seams; the connection's shared gateway otherwise.
  final BotModelGateway? modelGateway;
  final BotProfileGateway? profileGateway;
  final CapabilitiesSnapshotCache? capabilitiesCache;
  final SharedPreferences? preferences;

  /// Replaces «Editar perfil» (the profile editor needs a server) in tests.
  final Widget Function(BuildContext context, AgentProfile profile)?
  editorBuilder;

  /// Preference key of the folded Advanced section.
  static const advancedOpenKey = 'profile_hub_advanced_open';

  /// Stands in for every gateway of the hub where another screen opens it
  /// (Home's avatar, Bots) in widget tests; it must be a [BotModelGateway]
  /// and a [BotProfileGateway].
  @visibleForTesting
  static Object? debugGateway;

  @override
  State<ProfileHubScreen> createState() => _ProfileHubScreenState();
}

class _ProfileHubScreenState extends State<ProfileHubScreen> {
  SharedGatewayLease? _lease;
  late bool _advancedOpen;

  /// The profile the page shows now: [ProfileHubScreen.profile] until the
  /// user picks another one.
  late String _profile = widget.profile;

  /// The active profile before the last change, to tell whether the page was
  /// showing the active profile (then it follows it) or another one.
  late String _lastActive;
  late ActiveProfileScope _watched;

  SharedPreferences get _prefs =>
      widget.preferences ?? widget.connManager.prefs;

  BotRosterRegistry get _registry =>
      widget.rosterRegistry ?? BotRosterRegistry.shared;

  BotRosterStore get _roster => _registry.store(widget.connection.id);

  ActiveProfileScope get _scope =>
      ActiveProfileScope.of(widget.connManager, widget.connection.id);

  /// The gateway a test stands in for every other one (see
  /// [ProfileHubScreen.debugGateway]).
  Object? get _injected => ProfileHubScreen.debugGateway;

  BotModelGateway? get _modelGateway {
    final injected = _injected;
    if (injected is BotModelGateway) return injected;
    return widget.modelGateway ??
        (_lease?.client is BotModelGateway
            ? _lease!.client as BotModelGateway
            : null);
  }

  BotProfileGateway? get _profileGateway {
    final injected = _injected;
    if (injected is BotProfileGateway) return injected;
    return widget.profileGateway ??
        (_lease?.client is BotProfileGateway
            ? _lease!.client as BotProfileGateway
            : null);
  }

  @override
  void initState() {
    super.initState();
    _advancedOpen = _prefs.getBool(ProfileHubScreen.advancedOpenKey) ?? false;
    _registry.hydrate(widget.connection, prefs: _prefs);
    _watched = _scope;
    _lastActive = _watched.owner;
    _watched.addListener(_activeChanged);
    if (widget.modelGateway == null &&
        widget.profileGateway == null &&
        ProfileHubScreen.debugGateway == null) {
      _lease = SharedGatewayPool.instance.acquire(widget.connection);
    }
  }

  @override
  void didUpdateWidget(ProfileHubScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.profile != widget.profile) _profile = widget.profile;
    final scope = _scope;
    if (!identical(scope, _watched)) {
      _watched.removeListener(_activeChanged);
      _watched = scope;
      _lastActive = scope.owner;
      scope.addListener(_activeChanged);
    }
  }

  @override
  void dispose() {
    _watched.removeListener(_activeChanged);
    _lease?.release();
    super.dispose();
  }

  /// A page that showed the active profile keeps showing it when another
  /// part of the app switches; a page about another profile stays on it.
  void _activeChanged() {
    final previous = _lastActive;
    _lastActive = _scope.owner;
    if (!mounted || Session.profileOwner(_profile) != previous) return;
    setState(() => _profile = _scope.owner);
  }

  bool get _sameAsOrigin =>
      Session.profileOwner(_profile) == Session.profileOwner(widget.profile);

  Future<void> _switchProfile() async {
    final picked = await showProfileSwitcher(
      context,
      connection: widget.connection,
      connManager: widget.connManager,
      rosterRegistry: widget.rosterRegistry,
    );
    if (picked == null || !mounted) return;
    setState(() => _profile = picked);
  }

  void _toggleAdvanced() {
    setState(() => _advancedOpen = !_advancedOpen);
    unawaited(_prefs.setBool(ProfileHubScreen.advancedOpenKey, _advancedOpen));
  }

  AgentProfile? get _agentProfile => _roster.profile(_profile);

  bool get _isActive => _scope.owner == Session.profileOwner(_profile);

  /// Makes this profile the active one and says so. For the rows whose
  /// screen follows the app's active profile.
  Future<void> _makeActive() async {
    if (_isActive) return;
    await _scope.switchTo(_profile);
    if (!mounted) return;
    HermesNotice.of(context).showSnackBar(
      SnackBar(
        content: Text(Strings.of(context).navActiveProfileNotice(_displayName)),
      ),
      kind: HermesNoticeKind.info,
    );
  }

  String get _displayName {
    final profile = _agentProfile;
    if (profile != null) return profile.botListName;
    return _profile;
  }

  Future<void> _editProfile() async {
    final profile = _agentProfile;
    if (profile == null || widget.connection.readOnly) return;
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) =>
            widget.editorBuilder?.call(context, profile) ??
            ProfileEditorScreen(
              connection: widget.connection,
              profile: profile,
              onChanged: widget.onChanged,
              onOpenSkills: () => unawaited(
                openHermesToolDestination(context, _skillsDestination(context)),
              ),
            ),
      ),
    );
    if (saved == true && mounted) widget.onEdited?.call();
  }

  HermesToolDestination _skillsDestination(BuildContext context) {
    final strings = Strings.of(context);
    final profile = _agentProfile;
    return HermesToolDestination(
      id: 'skills',
      group: '',
      icon: Icons.extension_outlined,
      label: strings.botProfileSkills,
      value: profile != null && profile.skillCount > 0
          ? '${profile.skillCount}'
          : null,
      builder: (_) => _capabilities(ExtensionsTab.skills),
    );
  }

  Widget _capabilities(ExtensionsTab tab) => buildCapabilitiesHub(
    connection: widget.connection,
    connManager: widget.connManager,
    capabilities: widget.connManager.loadCapabilities(widget.connection.id),
    profileOverride: _profile,
    initialTab: tab,
  );

  /// The rows of the hub, without Model (a picker, not a screen) and with the
  /// profile of the hub fixed in every screen they open.
  List<ProfileHubEntry> entries(BuildContext context) => buildProfileHubEntries(
    context: context,
    connection: widget.connection,
    connManager: widget.connManager,
    profile: _profile,
    agentProfile: _agentProfile,
    isActive: _isActive,
    makeActive: _makeActive,
    profileGateway: _profileGateway,
    capabilitiesCache: widget.capabilitiesCache,
    onOpenBotCard: _sameAsOrigin ? widget.onOpenBotCard : null,
    hasSshProfile: SshProfilePresence.instance.value,
  );

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    return Scaffold(
      appBar: HermesAppBar(title: Text(strings.botProfileProfileSection)),
      body: SafeArea(
        top: false,
        child: ListenableBuilder(
          listenable: Listenable.merge([
            _roster,
            _scope,
            SshProfilePresence.instance,
          ]),
          builder: (context, _) => _body(context),
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final strings = Strings.of(context);
    final all = entries(context);
    List<HermesToolDestination> of(ProfileHubSection section) => [
      for (final entry in all)
        if (entry.section == section) entry.destination,
    ];
    Future<void> open(HermesToolDestination destination) =>
        openHermesToolDestination(context, destination);
    Widget group(String label, List<HermesToolDestination> rows) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        HermesToolGroupLabel(label),
        HermesToolGroup(destinations: rows, onOpen: open),
      ],
    );
    final integrations = of(ProfileHubSection.integrations);
    final work = of(ProfileHubSection.work);
    final agent = of(ProfileHubSection.agent);
    final advanced = of(ProfileHubSection.advanced);
    final list = ListView(
      key: const ValueKey('profile-hub-list'),
      padding: const EdgeInsets.fromLTRB(
        HermesSpace.x4,
        HermesSpace.x2,
        HermesSpace.x4,
        HermesSpace.x8,
      ),
      children: [
        _ProfileHubHeader(
          profile: _profile,
          agentProfile: _agentProfile,
          connection: widget.connection,
          connManager: widget.connManager,
          roster: _roster,
          registry: _registry,
          active: _isActive,
          canEdit: !widget.connection.readOnly && _agentProfile != null,
          onEdit: _editProfile,
          onChat: _sameAsOrigin ? widget.onChat : null,
          onSwitch: () => unawaited(_switchProfile()),
          onMakeActive: () => unawaited(_makeActive()),
        ),
        const SizedBox(height: 16),
        HermesGroup(
          children: [
            _modelRow(context),
            HermesToolRow(
              destination: _skillsDestination(context),
              onTap: () => unawaited(open(_skillsDestination(context))),
            ),
          ],
        ),
        group(strings.navSecIntegrations, integrations),
        group(strings.navSecWork, work),
        group(strings.navSecAgent, agent),
        const SizedBox(height: 8),
        _AdvancedToggle(open: _advancedOpen, onToggle: _toggleAdvanced),
        if (_advancedOpen)
          HermesToolGroup(destinations: advanced, onOpen: open),
      ],
    );
    // Keyed by the profile: the page of another profile starts clean (the
    // model picker, scroll position) instead of reusing the previous state.
    return KeyedSubtree(
      key: ValueKey('profile-hub-body-${Session.profileOwner(_profile)}'),
      child: list,
    );
  }

  Widget _modelRow(BuildContext context) {
    final strings = Strings.of(context);
    final profile = _agentProfile;
    return ProfileModelPicker(
      profile: _profile,
      scope: widget.connection.id,
      provider: profile?.provider ?? '',
      model: profile?.model ?? '',
      catalogGateway: _modelGateway,
      writer: _profileGateway,
      readOnly: widget.connection.readOnly,
      keyPrefix: 'profile-hub-model',
      onChanged: widget.onChanged,
      builder: (context, row) {
        final value = [
          if (row.provider.isNotEmpty) row.provider,
          if (row.model.isNotEmpty) row.model,
        ].join(' · ');
        return HermesToolRow(
          key: const ValueKey('profile-hub-model'),
          destination: HermesToolDestination(
            id: 'model',
            group: '',
            icon: Icons.memory_outlined,
            label: strings.botProfileModelSection,
            value: value.isEmpty ? null : value,
            builder: (_) => const SizedBox.shrink(),
          ),
          onTap: row.onTap ?? () {},
        );
      },
    );
  }
}

/// The rows of one profile's hub (everything but Model and Skills), in order.
/// A top-level function so the tests walk the same table the screen shows.
List<ProfileHubEntry> buildProfileHubEntries({
  required BuildContext context,
  required SavedConnection connection,
  required ConnectionManager connManager,
  required String profile,
  required AgentProfile? agentProfile,
  required bool isActive,
  required Future<void> Function() makeActive,
  BotProfileGateway? profileGateway,
  CapabilitiesSnapshotCache? capabilitiesCache,
  VoidCallback? onOpenBotCard,
  bool hasSshProfile = false,
}) {
  final strings = Strings.of(context);
  final conn = connection;
  final capabilities = connManager.loadCapabilities(conn.id);
  final cached = (capabilitiesCache ?? CapabilitiesSnapshotCache.shared).read(
    CapabilitiesSnapshotCache.keyOf(conn, profile),
  );
  final plugins = cached?.installed
      .where((i) => i.kind == CapabilityKind.plugin)
      .length;
  final mcp = cached?.mcpServers.length;

  Widget capabilitiesScreen(ExtensionsTab tab) => buildCapabilitiesHub(
    connection: conn,
    connManager: connManager,
    capabilities: capabilities,
    profileOverride: profile,
    initialTab: tab,
  );

  bool enabled([CapState? capability]) =>
      capability == null || !capability.isNo;
  String? reason([CapState? capability]) =>
      (capability?.isNo ?? false) ? strings.drawerUnsupported : null;

  HermesToolDestination row({
    required String id,
    required IconData icon,
    required String label,
    required WidgetBuilder builder,
    CapState? capability,
    String? value,
    String? subtitle,
    Future<void> Function()? beforeOpen,
  }) => HermesToolDestination(
    id: id,
    group: '',
    icon: icon,
    label: label,
    value: value,
    subtitle: subtitle,
    beforeOpen: beforeOpen,
    enabled: enabled(capability),
    disabledReason: reason(capability),
    builder: builder,
  );

  ProfileHubEntry integrations(HermesToolDestination d) =>
      ProfileHubEntry(ProfileHubSection.integrations, d);
  ProfileHubEntry work(HermesToolDestination d) =>
      ProfileHubEntry(ProfileHubSection.work, d);
  ProfileHubEntry agent(HermesToolDestination d) =>
      ProfileHubEntry(ProfileHubSection.agent, d);
  ProfileHubEntry advanced(HermesToolDestination d) =>
      ProfileHubEntry(ProfileHubSection.advanced, d);

  final owner = Session.profileOwner(profile);

  return [
    integrations(
      row(
        id: 'connections',
        icon: Icons.hub_outlined,
        label: strings.cphSegConnectors,
        builder: (_) => capabilitiesScreen(ExtensionsTab.mcp),
      ),
    ),
    integrations(
      row(
        id: 'plugins',
        icon: Icons.extension_outlined,
        label: strings.cphKindPlugins,
        value: plugins == null ? null : '$plugins',
        builder: (_) => capabilitiesScreen(ExtensionsTab.plugins),
      ),
    ),
    integrations(
      row(
        id: 'mcp',
        icon: Icons.power_outlined,
        label: strings.navMcp,
        value: mcp == null ? null : '$mcp',
        builder: (_) => capabilitiesScreen(ExtensionsTab.mcp),
      ),
    ),
    // Projects has no profile of its own and starts chats with the active
    // one: this row makes the hub's profile the active one first.
    work(
      row(
        id: 'projects',
        icon: Icons.folder_copy_outlined,
        label: strings.drawerProjects,
        subtitle: isActive ? null : strings.navFollowsActiveHint,
        beforeOpen: makeActive,
        builder: (_) => OwnedResourceHost<TuiGatewayClient>(
          create: () => TuiGatewayClient(conn),
          release: (gateway) => gateway.close(),
          builder: (_, gateway) => ProjectsCenterScreen(
            connection: conn,
            connectionManager: connManager,
            gateway: gateway,
          ),
        ),
      ),
    ),
    work(
      row(
        id: 'routines',
        icon: Icons.schedule_outlined,
        label: strings.botProfileRoutines,
        capability: capabilities.cronRead,
        builder: (_) => CronScreen(
          connection: conn,
          profileOverride: profile,
          botRoutines: true,
        ),
      ),
    ),
    work(
      row(
        id: 'artifacts',
        icon: Icons.view_in_ar_outlined,
        label: strings.chaArtifactsAction,
        capability: capabilities.sessionsRead,
        builder: (_) => ArtifactsScreen(connection: conn, profile: profile),
      ),
    ),
    work(
      row(
        id: 'kanban',
        icon: Icons.view_kanban_outlined,
        label: strings.drawerKanban,
        builder: (_) => TasksScreen(connection: conn, initialAssignee: profile),
      ),
    ),
    // The agents of the SSH machine: a section of their own, not of a bot.
    if (hasSshProfile && FeatureFlags.instance.agentsSection)
      work(
        row(
          id: 'agents',
          icon: Icons.terminal_outlined,
          label: strings.navAgents,
          builder: (context) => buildAgentsDestination(
            context,
            connection: conn,
            connManager: connManager,
          ),
        ),
      ),
    agent(
      row(
        id: 'soul',
        icon: Icons.auto_awesome_outlined,
        label: strings.botProfileSoul,
        builder: (_) => SoulScreen(connection: conn, profileOverride: profile),
      ),
    ),
    agent(
      row(
        id: 'memory',
        icon: Icons.psychology_outlined,
        label: strings.botProfileMemory,
        capability: capabilities.memoryRead,
        builder: (_) =>
            MemoryScreen(connection: conn, profileOverride: profile),
      ),
    ),
    agent(
      row(
        id: 'usage',
        icon: Icons.bar_chart_outlined,
        label: strings.kluUsageTitle,
        builder: (_) =>
            UsageAnalyticsScreen(connection: conn, profile: profile),
      ),
    ),
    advanced(
      row(
        id: 'voice',
        icon: Icons.graphic_eq_rounded,
        label: strings.voiceTitle,
        builder: (_) => VoiceSettingsScreen(connection: conn, profile: profile),
      ),
    ),
    advanced(
      row(
        id: 'keys',
        icon: Icons.key_outlined,
        label: strings.kluKeysTitle,
        builder: (_) => EnvKeysScreen(connection: conn, profile: profile),
      ),
    ),
    advanced(
      row(
        id: 'vault',
        icon: Icons.lock_outline_rounded,
        label: strings.vltSettingsTitle,
        builder: (_) => VaultScreen(connection: conn, profile: owner),
      ),
    ),
    advanced(
      row(
        id: 'logs',
        icon: Icons.receipt_long_outlined,
        label: strings.drawerActivity,
        capability: capabilities.logsRead,
        builder: (_) =>
            ActivityScreen(connection: conn, initialProfile: profile),
      ),
    ),
    advanced(
      row(
        id: 'task-center',
        icon: Icons.rocket_launch_outlined,
        label: strings.drawerTaskCenter,
        builder: (_) => TaskCenterScreen(connection: conn, profile: profile),
      ),
    ),
    advanced(
      row(
        id: 'bot-screen',
        icon: Icons.desktop_windows_outlined,
        label: strings.screenTitle,
        builder: (_) => OwnedResourceHost<TuiGatewayClient>(
          create: () => TuiGatewayClient(conn),
          release: (gateway) => gateway.close(),
          builder: (_, gateway) => ScreenPeekScreen(
            gateway: gateway,
            readOnly: conn.readOnly,
            profile: profile,
            botName: agentProfile?.botListName ?? profile,
            dashboardBase: Uri.parse(conn.effectiveDashboardUrl),
          ),
        ),
      ),
    ),
    advanced(
      row(
        id: 'characters',
        icon: Icons.face_outlined,
        label: strings.charactersTitle,
        builder: (_) => CharacterStudioScreen(
          profileName: profile,
          connectionId: conn.id,
          askAgent: studioAskAgentFor(conn, profile),
        ),
      ),
    ),
    if (!conn.readOnly)
      advanced(
        row(
          id: 'backup',
          icon: Icons.settings_backup_restore_rounded,
          label: strings.backupTitle,
          builder: (context) => BackupRestoreScreen(
            connection: conn,
            profile: owner,
            onOpenSecurity: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => SecurityInfoScreen(connManager: connManager),
              ),
            ),
          ),
        ),
      ),
    if (!conn.readOnly && profileGateway != null)
      advanced(
        row(
          id: 'advanced-settings',
          icon: Icons.tune_rounded,
          label: strings.botAdvanced,
          builder: (_) => BotProfileSettingsScreen(
            profile: profile,
            gateway: profileGateway,
          ),
        ),
      ),
    if (onOpenBotCard != null)
      advanced(
        HermesToolDestination(
          id: 'bot-card',
          group: '',
          icon: Icons.badge_outlined,
          label: strings.navBotCard,
          subtitle: strings.navBotCardSub,
          // The card needs the Bots screen: it opens from there, not by
          // pushing a screen built here.
          onOpen: onOpenBotCard,
          builder: (_) => const SizedBox.shrink(),
        ),
      ),
  ];
}

/// Avatar, name and description; a tap edits the profile. Pills: Chat,
/// Switch profile and «Activo» when it is the active one, «Hacer activo»
/// when it is not.
class _ProfileHubHeader extends StatelessWidget {
  const _ProfileHubHeader({
    required this.profile,
    required this.agentProfile,
    required this.connection,
    required this.connManager,
    required this.roster,
    required this.registry,
    required this.active,
    required this.canEdit,
    required this.onEdit,
    required this.onSwitch,
    required this.onMakeActive,
    this.onChat,
  });

  final String profile;
  final AgentProfile? agentProfile;
  final SavedConnection connection;
  final ConnectionManager connManager;
  final BotRosterStore roster;
  final BotRosterRegistry registry;
  final bool active;
  final bool canEdit;
  final VoidCallback onEdit;
  final VoidCallback onSwitch;
  final VoidCallback onMakeActive;
  final VoidCallback? onChat;

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final name = agentProfile?.botListName ?? profile;
    final description = agentProfile?.description.trim() ?? '';
    final faces = ProfileFace.cacheFor(connection, rosterTicket: roster.ticket);
    final identity = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ProfileFace(
          key: const ValueKey('profile-hub-avatar'),
          profileName: Session.profileOwner(profile),
          profile: agentProfile,
          avatarCache: faces,
          size: 96,
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                name,
                key: const ValueKey('profile-hub-name'),
                maxLines: 2,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: HermesType.title.copyWith(color: colors.textPrimary),
              ),
            ),
            if (canEdit) ...[
              const SizedBox(width: 6),
              Icon(Icons.edit_outlined, size: 16, color: colors.textSecondary),
            ],
          ],
        ),
      ],
    );
    return Column(
      children: [
        Semantics(
          button: canEdit,
          label: name,
          hint: canEdit ? strings.navEditProfile : null,
          excludeSemantics: true,
          onTap: canEdit ? onEdit : null,
          child: InkWell(
            key: const ValueKey('profile-hub-edit'),
            onTap: canEdit ? onEdit : null,
            borderRadius: BorderRadius.circular(HermesRadius.card),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: identity,
              ),
            ),
          ),
        ),
        if (description.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              HermesSpace.x2,
              HermesSpace.x1,
              HermesSpace.x2,
              0,
            ),
            child: Text(
              description,
              key: const ValueKey('profile-hub-description'),
              maxLines: 3,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: HermesType.support.copyWith(color: colors.textSecondary),
            ),
          ),
        const SizedBox(height: 12),
        Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            if (active)
              HermesTag(
                key: const ValueKey('profile-hub-active'),
                tone: HermesStatusTone.ok,
                label: strings.navProfileActive,
              )
            else
              _HubPill(
                key: const ValueKey('profile-hub-make-active'),
                icon: Icons.check_circle_outline_rounded,
                label: strings.psfMakeActive,
                onTap: onMakeActive,
              ),
            if (onChat != null)
              _HubPill(
                key: const ValueKey('profile-hub-chat'),
                icon: Icons.chat_bubble_outline_rounded,
                label: strings.botProfileChat,
                onTap: onChat!,
              ),
            _HubPill(
              key: const ValueKey('profile-hub-switch'),
              icon: Icons.swap_horiz_rounded,
              label: strings.navSwitchProfile,
              onTap: onSwitch,
            ),
          ],
        ),
      ],
    );
  }
}

/// A pill-shaped action of the header, at least 48 dp tall.
class _HubPill extends StatelessWidget {
  const _HubPill({
    required this.icon,
    required this.label,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        color: colors.surfaceVariant.withValues(alpha: 0.6),
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: HermesSpace.x4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 18, color: colors.textSecondary),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: HermesType.body.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The header of the folded Advanced section: a button that opens and closes
/// it, announcing its state.
class _AdvancedToggle extends StatelessWidget {
  const _AdvancedToggle({required this.open, required this.onToggle});

  final bool open;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return Semantics(
      button: true,
      expanded: open,
      label: strings.navAdvanced,
      hint: strings.navAdvancedHint,
      excludeSemantics: true,
      onTap: onToggle,
      child: InkWell(
        key: const ValueKey('profile-hub-advanced'),
        onTap: onToggle,
        borderRadius: BorderRadius.circular(HermesRadius.control),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 6,
              vertical: HermesSpace.x2,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        strings.navAdvanced,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: colors.textSecondary,
                        ),
                      ),
                      Text(
                        strings.navAdvancedHint,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  open ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                  color: colors.textSecondary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
