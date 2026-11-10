import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../main.dart' show HermesAppState;
import '../services/connection_manager.dart';
import '../services/ssh_profile_presence.dart';
import '../services/tui_gateway_client.dart';
import '../settings/settings_deep_link.dart';
import '../settings/settings_sections.dart';
import '../utils/responsive.dart';
import '../theme/app_theme.dart';
import '../widgets/owned_resource_host.dart';
import 'about_screen.dart';
import 'activity_screen.dart';
import 'cache_settings_screen.dart';
import 'companion/mascotas_screen.dart';
import 'extensions_center_screen.dart';
import 'gateway_manager_screen.dart';
import 'models_screen.dart';
import 'nous_account_screen.dart';
import 'notification_settings_screen.dart';
import 'profiles_screen.dart';
import 'settings_screen.dart';
import 'ssh_screen.dart';
import 'look_feel_screen.dart';
import 'tools_hub_screen.dart';

/// Ajustes de la app (1.4.0): what belongs to the app and the server, in the
/// groups of the approved layout. What belongs to one bot (model, skills,
/// memory, keys…) is in that bot's profile (`ProfileHubScreen`), not here.
///
/// It is the landing page of the dock's gear. Every row opens ITS screen with
/// only its own settings: Seguridad, Chat, Aspecto, Datos and Mantenimiento
/// are [SettingsSectionScreen]s (the same cards the full list shows for that
/// section, built once). [SettingsScreen] stays as the engine behind them
/// (its rows, the deep links) but has no row of its own here: every setting
/// is on the screen of its part, two taps from this page at most.
///
/// A request for a part of Settings ([SettingsDeepLink.request]) while this
/// screen is the one in front opens that part's screen. In a wide window
/// (the Fold unfolded, a tablet) the list sits beside a detail pane and the
/// rows that are sections show their screen there.
///
/// [connection] may be null (no instance yet): the rows that need a server
/// say so and the rest (Instancias) work.
class AppSettingsScreen extends StatefulWidget {
  const AppSettingsScreen({
    required this.connManager,
    this.connection,
    super.key,
  });

  final SavedConnection? connection;
  final ConnectionManager connManager;

  @override
  State<AppSettingsScreen> createState() => _AppSettingsScreenState();
}

class _AppSettingsScreenState extends State<AppSettingsScreen> {
  /// The section shown in the detail pane of a wide window.
  SettingsSection _selected = SettingsSection.security;

  @override
  void initState() {
    super.initState();
    SettingsDeepLink.pending.addListener(_onDeepLink);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onDeepLink());
  }

  @override
  void dispose() {
    SettingsDeepLink.pending.removeListener(_onDeepLink);
    super.dispose();
  }

  /// A part of Settings was asked for: show ITS screen (in the pane of a wide
  /// window), not the whole list. Only the screen in front answers; under
  /// the full list (when it is open) the request is that list's to scroll.
  void _onDeepLink() {
    final section = SettingsDeepLink.pending.value;
    final conn = widget.connection;
    if (!mounted ||
        section == null ||
        conn == null ||
        !(ModalRoute.of(context)?.isCurrent ?? false)) {
      return;
    }
    SettingsDeepLink.pending.value = null;
    if (Responsive.isExpanded(context) &&
        appSettingsPaneSections.contains(section)) {
      setState(() => _selected = section);
      return;
    }
    unawaited(
      openSettingsSection(
        context,
        section: section,
        connection: conn,
        connManager: widget.connManager,
      ),
    );
  }

  Future<void> _open(
    BuildContext context,
    HermesToolDestination destination,
  ) async {
    final section = appSettingsRowSections[destination.id];
    if (section != null &&
        destination.enabled &&
        appSettingsPaneSections.contains(section)) {
      setState(() => _selected = section);
      return;
    }
    await openHermesToolDestination(context, destination);
  }

  Widget _layout(BuildContext context, Widget list) {
    final conn = widget.connection!;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          key: const ValueKey('app-settings-list'),
          width: Responsive.settingsCategoryPaneWidth,
          child: list,
        ),
        VerticalDivider(
          width: 1,
          thickness: 1,
          color: Theme.of(context).hermes.divider,
        ),
        Expanded(
          child: KeyedSubtree(
            key: ValueKey('app-settings-detail-${_selected.name}'),
            child: ColoredBox(
              color: Theme.of(context).hermes.background,
              child: Material(
                type: MaterialType.transparency,
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: Responsive.maxContentWidth,
                    ),
                    child: settingsSectionScreen(
                      section: _selected,
                      connection: conn,
                      connManager: widget.connManager,
                      embedded: true,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final conn = widget.connection;
    final wide = conn != null && Responsive.isExpanded(context);
    // The SSH row says how to start while there is no SSH profile.
    return ValueListenableBuilder<bool>(
      valueListenable: SshProfilePresence.instance,
      builder: (context, hasSsh, _) => ToolsHubScreen(
        title: strings.setTitle,
        searchHint: strings.navSettingsSearch,
        destinations: buildAppSettingsDestinations(
          context: context,
          connection: conn,
          connManager: widget.connManager,
          capabilities: conn == null
              ? const CapabilityMatrix()
              : widget.connManager.loadCapabilities(conn.id),
          hasSshProfile: hasSsh,
        ),
        connection: conn,
        connManager: widget.connManager,
        opener: wide ? _open : null,
        bodyLayout: wide ? _layout : null,
      ),
    );
  }
}

/// The rows of [AppSettingsScreen] that are a section of Settings, and which.
const Map<String, SettingsSection> appSettingsRowSections = {
  'security': SettingsSection.security,
  'data': SettingsSection.data,
  'chat': SettingsSection.chat,
  'appearance-more': SettingsSection.appearance,
  'maintenance': SettingsSection.system,
};

/// The sections the detail pane of a wide window can hold (the ones that are
/// cards of preferences; the others are pages with a screen of their own).
final Set<SettingsSection> appSettingsPaneSections = {
  ...appSettingsRowSections.values,
};

/// The rows of [AppSettingsScreen], in order. One list is the table the tests
/// walk: every row must open its screen from here.
List<HermesToolDestination> buildAppSettingsDestinations({
  required BuildContext context,
  required SavedConnection? connection,
  required ConnectionManager connManager,
  required CapabilityMatrix capabilities,
  bool hasSshProfile = false,
}) {
  final strings = Strings.of(context);
  final conn = connection;

  bool enabled([CapState? capability]) =>
      conn != null && (capability == null || !capability.isNo);

  String? disabledReason([CapState? capability]) {
    if (conn == null) return strings.drawerNeedInstance;
    if (capability?.isNo ?? false) return strings.drawerUnsupported;
    return null;
  }

  /// A row that opens the screen of [section] with only its own cards. Its
  /// label is that screen's title, so the row and the page it opens say the
  /// same thing.
  HermesToolDestination settingsSection({
    required String id,
    required String group,
    required IconData icon,
    required SettingsSection section,
    String? subtitle,
  }) => HermesToolDestination(
    id: id,
    group: group,
    icon: icon,
    label: settingsSectionScreenTitle(strings, section),
    subtitle: subtitle,
    enabled: enabled(),
    disabledReason: disabledReason(),
    builder: (_) => settingsSectionScreen(
      section: section,
      connection: conn!,
      connManager: connManager,
    ),
  );

  final appState = context.findAncestorStateOfType<HermesAppState>();
  final coldStart = appState?.activeChats.coldStartStore;
  final cacheSettings = coldStart?.settings;

  final groupConnection = strings.navGroupConnection;
  final groupSecurity = strings.navGroupSecurityData;
  final groupLook = strings.navGroupLook;
  final groupAlerts = strings.navGroupAlerts;
  final groupServer = strings.navGroupServer;
  final groupHelp = strings.navGroupHelp;

  return [
    HermesToolDestination(
      id: 'instances',
      group: groupConnection,
      icon: Icons.router_outlined,
      label: strings.drawerInstances,
      builder: (_) => GatewayManagerScreen(connManager: connManager),
    ),
    HermesToolDestination(
      id: 'ssh',
      group: groupConnection,
      icon: Icons.terminal_outlined,
      label: strings.drawerSsh,
      subtitle: hasSshProfile ? null : strings.navSshStartHint,
      enabled: enabled(),
      disabledReason: disabledReason(),
      builder: (_) => SshScreen(connection: conn!),
    ),
    settingsSection(
      id: 'security',
      group: groupSecurity,
      icon: Icons.shield_outlined,
      section: SettingsSection.security,
    ),
    HermesToolDestination(
      id: 'cache',
      group: groupSecurity,
      icon: Icons.storage_rounded,
      label: strings.cacheTitle,
      enabled: enabled(),
      disabledReason: disabledReason(),
      // Its own page when the app has the cache store; otherwise the screen
      // of the Data section, which holds what is left of it.
      builder: (_) => cacheSettings == null || coldStart == null
          ? settingsSectionScreen(
              section: SettingsSection.data,
              connection: conn!,
              connManager: connManager,
            )
          : CacheSettingsScreen(store: coldStart, settings: cacheSettings),
    ),
    settingsSection(
      id: 'data',
      group: groupSecurity,
      icon: Icons.settings_backup_restore_rounded,
      section: SettingsSection.data,
    ),
    HermesToolDestination(
      id: 'appearance',
      group: groupLook,
      icon: Icons.palette_outlined,
      label: strings.lflTitle,
      enabled: enabled(),
      disabledReason: disabledReason(),
      builder: (_) => const LookFeelScreen(),
    ),
    HermesToolDestination(
      id: 'mascotas',
      group: groupLook,
      icon: Icons.pets_outlined,
      label: strings.navCharactersPets,
      enabled: enabled(),
      disabledReason: disabledReason(),
      builder: (_) => const MascotasScreen(),
    ),
    settingsSection(
      id: 'chat',
      group: groupLook,
      icon: Icons.chat_bubble_outline_rounded,
      section: SettingsSection.chat,
    ),
    settingsSection(
      id: 'appearance-more',
      group: groupLook,
      icon: Icons.tune_rounded,
      section: SettingsSection.appearance,
    ),
    HermesToolDestination(
      id: 'notifications',
      group: groupAlerts,
      icon: Icons.notifications_outlined,
      label: strings.notifTitle,
      subtitle: strings.navAlertsSub,
      builder: (_) => const NotificationSettingsScreen(),
    ),
    // Voice (dictation and reading replies): it had its row only in the full
    // list, so it is here, with the alerts, now that the list has no row.
    HermesToolDestination(
      id: 'voice-app',
      group: groupAlerts,
      icon: Icons.record_voice_over_outlined,
      label: settingsSectionScreenTitle(strings, SettingsSection.voice),
      subtitle: strings.setVoice,
      enabled: enabled(),
      disabledReason: disabledReason(),
      builder: (_) => settingsSectionScreen(
        section: SettingsSection.voice,
        connection: conn!,
        connManager: connManager,
      ),
    ),
    HermesToolDestination(
      id: 'models',
      group: groupServer,
      icon: Icons.memory_outlined,
      label: strings.navModelsProviders,
      enabled: enabled(capabilities.modelsRead),
      disabledReason: disabledReason(capabilities.modelsRead),
      builder: (_) => ModelsScreen(connection: conn!),
    ),
    HermesToolDestination(
      id: 'nous-account',
      group: groupServer,
      icon: Icons.account_circle_outlined,
      label: strings.nacScreenTitle,
      subtitle: strings.nacSettingsSubtitle,
      enabled: enabled(capabilities.modelsRead),
      disabledReason: disabledReason(capabilities.modelsRead),
      builder: (_) => NousAccountScreen(connection: conn!),
    ),
    HermesToolDestination(
      id: 'profiles',
      group: groupServer,
      icon: Icons.account_tree_outlined,
      label: strings.pfuManageProfiles,
      subtitle: strings.pfuManageProfilesSub,
      enabled: enabled(),
      disabledReason: disabledReason(),
      builder: (_) =>
          ProfilesScreen(connection: conn!, connManager: connManager),
    ),
    // The server-wide extensions centre: unreachable from a profile's own
    // Capabilities page (that one is scoped to the profile), so it is here.
    HermesToolDestination(
      id: 'extensions',
      group: groupServer,
      icon: Icons.extension_outlined,
      label: strings.drawerExtensions,
      enabled: enabled(),
      disabledReason: disabledReason(),
      builder: (_) {
        final active = conn!;
        return OwnedResourceHost<TuiGatewayClient>(
          create: () => TuiGatewayClient(active),
          release: (gateway) => gateway.close(),
          builder: (_, gateway) => ExtensionsCenterScreen(
            gateway: gateway,
            readOnly: active.readOnly,
          ),
        );
      },
    ),
    HermesToolDestination(
      id: 'logs',
      group: groupServer,
      icon: Icons.receipt_long_outlined,
      label: strings.drawerActivity,
      enabled: enabled(capabilities.logsRead),
      disabledReason: disabledReason(capabilities.logsRead),
      builder: (_) => ActivityScreen(connection: conn!),
    ),
    settingsSection(
      id: 'maintenance',
      group: groupServer,
      icon: Icons.build_outlined,
      section: SettingsSection.system,
    ),
    HermesToolDestination(
      id: 'about',
      group: groupHelp,
      icon: Icons.info_outline_rounded,
      label: strings.navAboutHelp,
      builder: (_) => const AboutScreen(),
    ),
  ];
}
