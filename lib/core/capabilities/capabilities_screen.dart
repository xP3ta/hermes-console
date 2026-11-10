// Extensions: ONE screen for skills, plugins and MCP servers (with the account
// connectors under MCP), read from the profile's own server. Three tabs, each
// self-sufficient: search, «N installed · M active», the status filter, flat
// rows with the switch at the end, and a «+» menu with the tab's own actions.
// The hubs (Skill Hub, Plugin Hub, MCP catalog) open as a stacked page whose
// back button returns to the same tab. The ⋯ menu of the header carries what
// is about the whole server: Tools and Webhooks / server status.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../design/hermes_design.dart';
import '../models/connection.dart';
import '../services/command_risk.dart';
import '../services/connection_manager.dart' show DashboardClient;
import '../services/shared_gateway_pool.dart';
import '../theme/app_theme.dart';
import '../widgets/action_approval.dart';
import '../widgets/hermes_premium_ui.dart'
    show HermesSegment, HermesSegmentedControl;
import '../widgets/hermes_premium_ui.dart'
    as premium
    show HermesListRow, HermesListSection;
import '../widgets/form_page.dart' show pushHermesFormPage;
import '../widgets/hermes_row_switch.dart';
import '../widgets/mcp_provisioning_surface.dart'
    show McpServerDraftSurface, showMcpOAuthFlowSurface;
import '../screens/admin_integrations_screen.dart'
    show AdminIntegrationsScreen, AdminIntegrationsSection;
import '../screens/extensions_tools_screen.dart' show ExtensionsToolsScreen;
import '../models/admin_integrations.dart'
    show McpAuthMode, McpOAuthFlow, McpServerDraft;
import '../services/desktop_control_gateway.dart'
    show DesktopControlFailure, DesktopControlFailureKind;
import 'capabilities_adapters.dart';
import 'capabilities_repository.dart';
import 'capability_detail_screen.dart';
import 'capability_models.dart';
import 'capability_ui.dart';
import 'connector_detail_screen.dart';
import 'mcp_runtime_status.dart';
import 'capability_plain_rows.dart';
import 'las_chat.dart' show LasChatLauncher;
import 'las_learn_screen.dart';
import 'las_request.dart';
import 'plugin_source_install.dart';
import 'skill_create_screen.dart';
import 'spp_copy.dart';
import 'spp_safety.dart';
import '../widgets/console_loader.dart';
import '../feedback/feedback_policy.dart';

/// The three tabs of the Extensions screen.
enum ExtensionsTab { skills, plugins, mcp }

/// Where the screens that used to be separate now live. Kept so that every
/// older caller still lands in the right place:
///
/// * `installed` opens the tab of [CapabilitiesScreen.initialKind] (Skills
///   when none),
/// * `connectors` opens the MCP tab (the accounts are listed under the
///   servers),
/// * `catalog` opens the hub page of that kind (a stacked page over a tab).
enum CapabilitiesSegment { catalog, installed, connectors }

extension on CapabilityKind {
  ExtensionsTab get tab => switch (this) {
    CapabilityKind.skill => ExtensionsTab.skills,
    CapabilityKind.plugin => ExtensionsTab.plugins,
    CapabilityKind.mcp => ExtensionsTab.mcp,
  };
}

extension on ExtensionsTab {
  CapabilityKind get kind => switch (this) {
    ExtensionsTab.skills => CapabilityKind.skill,
    ExtensionsTab.plugins => CapabilityKind.plugin,
    ExtensionsTab.mcp => CapabilityKind.mcp,
  };
}

/// Everything the hub shows, loaded in one pass. Sources that the server
/// does not publish are simply absent; sources that failed are counted so
/// the page can say so honestly.
final class CapabilitiesSnapshot {
  final List<CapabilityItem> catalog;
  final List<CapabilityItem> installed;
  final List<CapabilityItem> mcpServers;

  /// Live MCP state by server name; empty when the server lacks it.
  final Map<String, McpRuntimeRow> mcpRuntime;
  final Map<String, int> mcpToolCounts;
  final HostedConnectorsSnapshot? connectors;

  /// `connectors.policy.get` answered: hosted rows may open their detail.
  final bool connectorPolicyReadable;
  final bool connectorsFailed;
  final bool partial;
  final bool skillsUpdatable;

  /// `false` for the early skills-only snapshot: plugins, MCP and connectors
  /// are still loading, so their absence is not an empty answer.
  final bool complete;

  const CapabilitiesSnapshot({
    this.catalog = const [],
    this.installed = const [],
    this.mcpServers = const [],
    this.mcpRuntime = const {},
    this.mcpToolCounts = const {},
    this.connectors,
    this.connectorPolicyReadable = false,
    this.connectorsFailed = false,
    this.partial = false,
    this.skillsUpdatable = false,
    this.complete = true,
  });

  /// The same snapshot with the enabled flag of every installed [kind] item
  /// named [installedName] set to [enabled]: a confirmed switch is patched in
  /// place, without reading everything again.
  CapabilitiesSnapshot withEnabled(
    CapabilityKind kind,
    String installedName,
    bool enabled,
  ) {
    List<CapabilityItem> patch(List<CapabilityItem> items) => [
      for (final item in items)
        item.kind == kind &&
                item.installed &&
                item.installedName == installedName
            ? item.copyWith(enabled: enabled)
            : item,
    ];
    return CapabilitiesSnapshot(
      catalog: patch(catalog),
      installed: patch(installed),
      mcpServers: patch(mcpServers),
      mcpRuntime: mcpRuntime,
      mcpToolCounts: mcpToolCounts,
      connectors: connectors,
      connectorPolicyReadable: connectorPolicyReadable,
      connectorsFailed: connectorsFailed,
      partial: partial,
      skillsUpdatable: skillsUpdatable,
      complete: complete,
    );
  }

  /// Loads every source. [onSkills] receives an early, incomplete snapshot
  /// as soon as both skill sources answered, so skills never wait for the
  /// plugin, MCP and connector reads (Desktop queries skills on their own).
  static Future<CapabilitiesSnapshot> load(
    CapabilitiesRepository repo, {
    void Function(CapabilitiesSnapshot skillsOnly)? onSkills,
  }) async {
    final failures = <Object>[];
    var attempted = 0;
    Future<List<CapabilityItem>> guard(
      Future<List<CapabilityItem>> Function() run,
    ) async {
      attempted++;
      try {
        return await run();
      } catch (error) {
        failures.add(error);
        return const [];
      }
    }

    // Each skill source paints on its own (Desktop queries installed skills
    // independently of the official catalog). Until the installed list has
    // answered successfully, catalog rows carry an unknown installed state,
    // never "not installed", so no action relies on it.
    List<CapabilityItem>? installedAnswer;
    List<CapabilityItem>? officialAnswer;
    var installedKnown = false;
    void paintSkills() {
      if (onSkills == null) return;
      final official = officialAnswer;
      final installed = installedKnown ? installedAnswer : null;
      final List<CapabilityItem> skills;
      if (official == null) {
        skills = installed ?? const [];
      } else if (installed == null) {
        skills = [
          for (final entry in official)
            entry.copyWith(
              installed: false,
              stateUnknown: true,
              enabled: false,
              updateAvailable: false,
            ),
        ];
      } else {
        skills = mergeSkills(installed: installed, official: official);
      }
      if (skills.isEmpty) return;
      onSkills(
        CapabilitiesSnapshot(
          catalog: [...skills.where((item) => item.installId.isNotEmpty)],
          installed: [...skills.where((item) => item.installed)],
          skillsUpdatable:
              installed != null &&
              repo.supports(CapabilityFeature.skillsUpdate) != false &&
              skills.any((s) => s.installed && s.provenance == 'hub'),
          complete: false,
        ),
      );
    }

    var installedOk = false;
    final installedSkills = guard(() async {
      final value = await repo.installedSkills();
      installedOk = true;
      return value;
    });
    final officialSkills = guard(repo.officialSkills);
    final rest = [
      guard(repo.pluginCatalog),
      guard(repo.installedPlugins),
      guard(repo.mcpCatalog),
      guard(repo.mcpServers),
    ];
    unawaited(
      installedSkills.then((value) {
        installedAnswer = value;
        installedKnown = installedOk;
        paintSkills();
      }),
    );
    unawaited(
      officialSkills.then((value) {
        officialAnswer = value;
        paintSkills();
      }),
    );
    final lists = await Future.wait([installedSkills, officialSkills, ...rest]);
    // Per-profile installed state (Desktop rule); a server without
    // `plugins.manage` keeps the REST flags.
    List<InstalledPluginRow>? pluginRows;
    try {
      pluginRows = await repo.installedPluginsRpc();
    } catch (_) {
      pluginRows = null;
    }
    // On a named profile the REST flags describe the launch profile, so a
    // missing list means the installed state is unknown, not "as REST says".
    final pluginStateUnknown = pluginRows == null && !repo.usesDefaultProfile;
    // Optional enrichment, asked once per load: any failure keeps the
    // static rows and is not counted as a failed source.
    var mcpRuntime = const <String, McpRuntimeRow>{};
    if (lists[5].isNotEmpty) {
      try {
        mcpRuntime = await repo.mcpRuntimeStatus();
      } catch (_) {}
    }
    final mcpToolCounts = <String, int>{};
    if (lists[5].isNotEmpty) {
      try {
        final names = lists[5].map((server) => server.installedName).toSet();
        for (final toolset in await repo.toolsets()) {
          final name = toolset.mcpServerName(names);
          if (name == null || !names.contains(name)) continue;
          // Bare aliases and registry names can describe the same tools.
          final previous = mcpToolCounts[name] ?? 0;
          if (toolset.toolCount >= previous) {
            mcpToolCounts[name] = toolset.toolCount;
          }
        }
      } catch (_) {
        // Optional enrichment: static rows and runtime counts remain usable.
      }
    }
    HostedConnectorsSnapshot? connectors;
    var connectorsFailed = false;
    var connectorPolicyReadable = false;
    try {
      connectors = await repo.hostedConnectors();
      if (connectors.availability == ConnectorAvailability.available &&
          connectors.connectors.isNotEmpty) {
        try {
          await repo.connectorPolicy();
          connectorPolicyReadable = true;
        } catch (_) {}
      }
    } catch (_) {
      connectorsFailed = true;
    }

    final real = failures
        .where(
          (e) =>
              capabilityFailureKindOf(e) != CapabilityFailureKind.unsupported,
        )
        .toList();
    if (failures.length == attempted) {
      // Nothing loaded: surface the most telling reason.
      throw real.isNotEmpty ? real.first : failures.first;
    }

    // A failed installed list leaves the catalog's installed state unknown,
    // as while it was pending: never "not installed".
    final skills = installedOk
        ? mergeSkills(installed: lists[0], official: lists[1])
        : [
            for (final entry in lists[1])
              entry.copyWith(
                installed: false,
                stateUnknown: true,
                enabled: false,
                updateAvailable: false,
              ),
          ];
    final plugins = _mergePlugins(
      catalog: lists[2],
      installed: lists[3],
      rows: pluginRows,
      stateUnknown: pluginStateUnknown,
    );
    final catalog = [
      ...skills.where((item) => item.installId.isNotEmpty),
      ...plugins.where((item) => item.installId.isNotEmpty),
      ...lists[4],
    ];
    final installed = [
      ...skills.where((item) => item.installed),
      ...plugins.where((item) => item.installed),
    ];
    return CapabilitiesSnapshot(
      catalog: catalog,
      installed: installed,
      mcpServers: lists[5],
      mcpRuntime: mcpRuntime,
      mcpToolCounts: mcpToolCounts,
      connectors: connectors,
      connectorPolicyReadable: connectorPolicyReadable,
      connectorsFailed: connectorsFailed,
      partial: real.isNotEmpty || pluginStateUnknown,
      skillsUpdatable:
          repo.supports(CapabilityFeature.skillsUpdate) != false &&
          skills.any((s) => s.installed && s.provenance == 'hub'),
    );
  }

  static List<CapabilityItem> _mergePlugins({
    required List<CapabilityItem> catalog,
    required List<CapabilityItem> installed,
    List<InstalledPluginRow>? rows,
    bool stateUnknown = false,
  }) {
    final byName = {for (final p in installed) p.installedName: p};
    final used = <String>{};
    final out = <CapabilityItem>[];
    for (final entry in catalog) {
      if (stateUnknown) {
        out.add(
          entry.copyWith(
            installed: false,
            stateUnknown: true,
            enabled: false,
            updateAvailable: false,
          ),
        );
        continue;
      }
      if (rows != null) {
        final row = rows.match(
          catalogName: entry.installId,
          name: entry.installedName,
        );
        if (row == null) {
          out.add(
            entry.copyWith(
              installed: false,
              enabled: false,
              updateAvailable: false,
            ),
          );
          continue;
        }
        final local = byName[row.name];
        used.add(row.name);
        out.add(
          entry.copyWith(
            installed: true,
            enabled: row.enabled,
            updateAvailable: row.updateAvailable,
            installedName: row.name,
            installedKey: row.key,
            canRemove: local?.canRemove ?? true,
            origin: row.source.isNotEmpty ? row.source : local?.origin,
            version: row.version.isNotEmpty
                ? row.version
                : (local?.version.isNotEmpty ?? false)
                ? local!.version
                : null,
          ),
        );
        continue;
      }
      final local = byName[entry.installedName];
      if (local != null) {
        used.add(local.installedName);
        out.add(
          entry.copyWith(
            installed: true,
            enabled: local.enabled,
            canRemove: local.canRemove,
            installedKey: local.installedKey,
            origin: local.origin,
            version: local.version.isNotEmpty ? local.version : null,
          ),
        );
      } else {
        out.add(entry);
      }
    }
    for (final p in installed) {
      if (!used.contains(p.installedName)) out.add(p);
    }
    return out;
  }
}

/// Route entry point: builds the transports for [connection] and owns them.
class CapabilitiesHub extends StatelessWidget {
  final SavedConnection connection;
  final String profile;

  /// The tab shown first. Null falls back to the legacy [initialSegment] /
  /// [initialKind] pair (see [CapabilitiesSegment]).
  final ExtensionsTab? initialTab;

  /// Legacy way to say where to land; see [CapabilitiesSegment].
  final CapabilitiesSegment initialSegment;

  /// A type the legacy pair is about (the Plugin Hub is `catalog` + `plugin`).
  final CapabilityKind? initialKind;

  /// Opens the chat that learns a skill; null leaves the entry out.
  final LasChatLauncher? learnLauncher;

  /// The live conversation, when the screen was opened from one: its tool
  /// groups are then the conversation's, not the instance's.
  final String runtimeSessionId;

  const CapabilitiesHub({
    super.key,
    required this.connection,
    this.profile = '',
    this.initialTab,
    this.initialSegment = CapabilitiesSegment.installed,
    this.initialKind,
    this.learnLauncher,
    this.runtimeSessionId = '',
  });

  // Transports, repository and loaded state belong to one (connection,
  // access, profile) owner: when any of them changes the hub is rebuilt from
  // scratch instead of showing or mutating the previous owner's data.
  @override
  Widget build(BuildContext context) => _CapabilitiesHubBody(
    key: ValueKey((
      connection.id,
      connection.readOnly,
      profile.trim().isEmpty ? 'default' : profile.trim(),
    )),
    connection: connection,
    profile: profile,
    initialTab: initialTab,
    initialSegment: initialSegment,
    initialKind: initialKind,
    learnLauncher: learnLauncher,
    runtimeSessionId: runtimeSessionId,
  );
}

class _CapabilitiesHubBody extends StatefulWidget {
  final SavedConnection connection;
  final String profile;
  final ExtensionsTab? initialTab;
  final CapabilitiesSegment initialSegment;
  final CapabilityKind? initialKind;
  final LasChatLauncher? learnLauncher;
  final String runtimeSessionId;

  const _CapabilitiesHubBody({
    super.key,
    required this.connection,
    required this.profile,
    required this.initialSegment,
    required this.runtimeSessionId,
    this.initialTab,
    this.initialKind,
    this.learnLauncher,
  });

  @override
  State<_CapabilitiesHubBody> createState() => _CapabilitiesHubState();
}

class _CapabilitiesHubState extends State<_CapabilitiesHubBody> {
  late final DashboardClient _dashboard = DashboardClient.lazy(
    widget.connection,
  );
  // The connection's shared gateway (Desktop keeps one gateway per backend):
  // reopening the hub reuses a warm socket instead of paying a new WebSocket
  // handshake per visit. The pool keys by connection, endpoint, credential
  // and read-only state, so a changed connection never inherits this socket.
  late final SharedGatewayLease _gatewayLease = SharedGatewayPool.instance
      .acquire(widget.connection);
  late final CapabilitiesRepository _repository = CapabilitiesRepository(
    rest: DashboardCapabilitiesRest(
      _dashboard,
      readOnly: widget.connection.readOnly,
    ),
    rpc: gatewayCapabilitiesRpc(_gatewayLease.client),
    profile: widget.profile,
  );

  @override
  void dispose() {
    _gatewayLease.release();
    _dashboard.close();
    super.dispose();
  }

  // The ⋯ menu and the install-from-source flow talk to the server itself,
  // through the same shared gateway (never closed by the pages that use it).
  @override
  Widget build(BuildContext context) => CapabilitiesScreen(
    repository: _repository,
    snapshotCache: CapabilitiesSnapshotCache.shared,
    snapshotKey: CapabilitiesSnapshotCache.keyOf(
      widget.connection,
      widget.profile,
    ),
    readOnly: widget.connection.readOnly,
    instanceId: widget.connection.id,
    destinationLabel:
        '${widget.connection.label} · ${widget.profile.trim().isEmpty ? 'default' : widget.profile.trim()}',
    initialTab: widget.initialTab,
    initialSegment: widget.initialSegment,
    initialKind: widget.initialKind,
    learnLauncher: widget.learnLauncher,
    toolsBuilder: (_) => ExtensionsToolsScreen(
      gateway: _gatewayLease.client,
      runtimeSessionId: widget.runtimeSessionId,
      readOnly: widget.connection.readOnly,
    ),
    serverBuilder: (context) => AdminIntegrationsScreen(
      gateway: _gatewayLease.client,
      readOnly: widget.connection.readOnly,
      initialSection: AdminIntegrationsSection.webhooks,
      title: Strings.of(context).exuMoreServer,
    ),
    sourceInstaller: _gatewayLease.client.installPlugin,
  );
}

/// The last complete hub read per connection and profile, in memory only.
///
/// Like Desktop's query cache, reopening Capabilities paints what it showed
/// last and refreshes behind (a thin progress line says so). Every change
/// made from the hub drops the entry before it reloads, so a later open never
/// paints the pre-change state as current. Nothing is written to disk.
final class CapabilitiesSnapshotCache {
  CapabilitiesSnapshotCache({this.capacity = 8});

  static final shared = CapabilitiesSnapshotCache();

  final int capacity;
  final Map<String, CapabilitiesSnapshot> _entries = {};

  /// Another server, access level or profile is another key.
  static String keyOf(SavedConnection connection, String profile) {
    final owner = profile.trim().isEmpty ? 'default' : profile.trim();
    return '${connection.id}|${connection.baseUrl}|'
        '${connection.effectiveDashboardUrl}|${connection.readOnly}|$owner';
  }

  CapabilitiesSnapshot? read(String key) => _entries[key];

  void write(String key, CapabilitiesSnapshot snapshot) {
    if (!snapshot.complete || snapshot.partial) return;
    _entries.remove(key);
    _entries[key] = snapshot;
    while (_entries.length > capacity) {
      _entries.remove(_entries.keys.first);
    }
  }

  void remove(String key) => _entries.remove(key);
}

class CapabilitiesScreen extends StatefulWidget {
  final CapabilitiesRepository repository;

  /// Optional last-read cache; [snapshotKey] names this screen's entry.
  final CapabilitiesSnapshotCache? snapshotCache;
  final String snapshotKey;
  final bool readOnly;
  final String instanceId;

  /// `<server label> · <profile>` shown in install confirmations.
  final String destinationLabel;

  /// The tab shown first. Null falls back to the legacy pair below.
  final ExtensionsTab? initialTab;

  /// Legacy way to say where to land; see [CapabilitiesSegment]. `catalog`
  /// makes this a hub page (no tabs); the default opens the Skills tab.
  final CapabilitiesSegment initialSegment;

  /// With the `installed` segment, the tab to open; with `catalog`, the kind
  /// of the hub (`plugin` is the Plugin Hub, `mcp` the MCP catalog).
  final CapabilityKind? initialKind;
  final Duration searchDebounce;

  /// Opens the chat of the profile's agent that learns a skill; null (a
  /// read-only connection) leaves the menu entry out.
  final LasChatLauncher? learnLauncher;

  /// The tool groups page, under the ⋯ menu; null leaves the entry out.
  final WidgetBuilder? toolsBuilder;

  /// The webhooks and server status page, under the ⋯ menu; null leaves the
  /// entry out.
  final WidgetBuilder? serverBuilder;

  /// Installs a plugin from an owner/repo or Git URL; null leaves the entry
  /// out of the Plugins «+» menu.
  final PluginSourceInstaller? sourceInstaller;

  const CapabilitiesScreen({
    super.key,
    required this.repository,
    this.snapshotCache,
    this.snapshotKey = '',
    this.readOnly = false,
    this.instanceId = '',
    this.destinationLabel = '',
    this.initialTab,
    this.initialSegment = CapabilitiesSegment.installed,
    this.initialKind,
    this.searchDebounce = const Duration(milliseconds: 450),
    this.learnLauncher,
    this.toolsBuilder,
    this.serverBuilder,
    this.sourceInstaller,
  });

  @override
  State<CapabilitiesScreen> createState() => _CapabilitiesScreenState();
}

enum _AddAction {
  skillHub,
  newSkill,
  learnSkill,
  updateSkills,
  pluginHub,
  installFromSource,
  mcpCatalog,
  addMcp,
}

enum _MoreAction { tools, server }

/// Which installed items a tab lists.
enum _StatusFilter { all, active, inactive }

/// Facet values offered by the filter surface.
sealed class _Facet {
  const _Facet();
}

final class _KindFacet extends _Facet {
  final CapabilityKind? kind;
  const _KindFacet(this.kind);
  @override
  bool operator ==(Object other) => other is _KindFacet && other.kind == kind;
  @override
  int get hashCode => kind.hashCode;
}

final class _TrustFacet extends _Facet {
  final CapabilityTrust? trust;
  const _TrustFacet(this.trust);
  @override
  bool operator ==(Object other) =>
      other is _TrustFacet && other.trust == trust;
  @override
  int get hashCode => trust.hashCode ^ 7;
}

final class _ActiveFacets extends _Facet {
  const _ActiveFacets();
}

class _CapabilitiesScreenState extends State<CapabilitiesScreen> {
  static const int _groupCap = 30;
  static const int _revealStep = 60;

  /// A hub page: the catalog of one kind (or of every kind), stacked over a
  /// tab. Without it this is the Extensions screen with its three tabs.
  late final bool _isHub =
      widget.initialTab == null &&
      widget.initialSegment == CapabilitiesSegment.catalog;

  late ExtensionsTab _tab =
      widget.initialTab ??
      (widget.initialSegment == CapabilitiesSegment.connectors
          ? ExtensionsTab.mcp
          : (widget.initialKind?.tab ?? ExtensionsTab.skills));
  CapabilitiesSnapshot? _snapshot;
  Object? _error;
  bool _loading = true;
  late CapabilityFilter _filter = CapabilityFilter(
    kind: _isHub ? widget.initialKind : null,
  );
  final TextEditingController _search = TextEditingController();
  final GlobalKey _moreKey = GlobalKey(debugLabel: 'cph-more');
  final GlobalKey _addKey = GlobalKey(debugLabel: 'exu-add');
  final GlobalKey _filterKey = GlobalKey(debugLabel: 'cph-filter');

  /// How many rows of a kind are on screen beyond the first [_groupCap]; a
  /// long list grows in steps, so opening 153 skills never builds them all.
  final Map<CapabilityKind, int> _shownRows = {};
  Timer? _debounce;
  List<CapabilityItem> _hubResults = const [];
  bool _hubFailed = false;
  bool _hubSearching = false;
  int _hubGeneration = 0;
  bool _busy = false;

  /// Switches with a request in flight, and what each one shows meanwhile.
  /// A failed request removes its entry, which is the rollback.
  final Set<String> _toggling = {};
  final Map<String, bool> _shown = {};

  /// Each tab keeps its own search text and status filter.
  final Map<ExtensionsTab, String> _queries = {};
  final Map<ExtensionsTab, _StatusFilter> _statuses = {};

  /// One scroll position per tab: switching tabs never lands the reader in
  /// the middle of another list.
  final ScrollController _scroll = ScrollController();
  final Map<ExtensionsTab, double> _offsets = {};

  /// A cached snapshot is on screen while the server answers again.
  bool _revalidating = false;

  /// Skills that appeared while the learn chat was open: shown tinted for a
  /// few seconds, once.
  Set<String> _learned = const {};
  Timer? _learnedTimer;

  CapabilitiesRepository get _repo => widget.repository;

  _StatusFilter get _status => _statuses[_tab] ?? _StatusFilter.all;

  /// The catalog filtered to plugins: the Plugin Hub.
  bool get _hubMode => _isHub && _filter.kind == CapabilityKind.plugin;

  /// Opens the hub of [kind] as its own page over this tab; back returns to
  /// the same tab and reads the lists again, as something may have been
  /// installed there.
  Future<void> _openHub(CapabilityKind kind) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CapabilitiesScreen(
          repository: _repo,
          snapshotCache: widget.snapshotCache,
          snapshotKey: widget.snapshotKey,
          readOnly: widget.readOnly,
          instanceId: widget.instanceId,
          destinationLabel: widget.destinationLabel,
          initialSegment: CapabilitiesSegment.catalog,
          initialKind: kind,
          searchDebounce: widget.searchDebounce,
        ),
      ),
    );
    if (mounted) _reloadAfterChange();
  }

  /// A change was made: the cached read no longer describes the server.
  void _dropCached() => widget.snapshotCache?.remove(widget.snapshotKey);

  void _reloadAfterChange() {
    _dropCached();
    unawaited(_load());
  }

  @override
  void initState() {
    super.initState();
    final cached = widget.snapshotCache?.read(widget.snapshotKey);
    if (cached != null) {
      _snapshot = cached;
      _loading = false;
      _revalidating = true;
    }
    unawaited(_load());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _learnedTimer?.cancel();
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  int _loadGeneration = 0;

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    bool current() => mounted && generation == _loadGeneration;
    var settled = false;
    setState(() {
      _loading = _snapshot == null;
      _error = null;
    });
    try {
      final snapshot = await CapabilitiesSnapshot.load(
        _repo,
        onSkills: (early) {
          // Early paints only while nothing complete is shown: a refresh
          // keeps its complete snapshot, and a late early answer never
          // replaces the final one.
          if (!current() || settled || _snapshot?.complete == true) return;
          setState(() {
            _snapshot = early;
            _loading = false;
          });
        },
      );
      settled = true;
      if (!current()) return;
      setState(() {
        _snapshot = snapshot;
        _loading = false;
        _revalidating = false;
      });
      widget.snapshotCache?.write(widget.snapshotKey, snapshot);
    } catch (error) {
      settled = true;
      if (!current()) return;
      setState(() {
        _revalidating = false;
        // An early skills paint stays; the failure of the rest is partial.
        if (_snapshot?.complete == false) {
          _snapshot = CapabilitiesSnapshot(
            catalog: _snapshot!.catalog,
            installed: _snapshot!.installed,
            skillsUpdatable: _snapshot!.skillsUpdatable,
            partial: true,
          );
        } else {
          _error = error;
        }
        _loading = false;
      });
    }
  }

  void _onQuery(String value) {
    setState(() => _filter = _filter.copyWith(query: value));
    if (!_isHub) {
      // A tab searches what is installed, on the phone, for each keystroke.
      _queries[_tab] = value;
      return;
    }
    _debounce?.cancel();
    final q = value.trim();
    // The skills hub search never lists plugins: a plugin search is local, over
    // the catalog the server published.
    if (q.length < 3 ||
        _filter.kind == CapabilityKind.plugin ||
        _repo.supports(CapabilityFeature.hubSearch) == false) {
      _hubGeneration++;
      setState(() {
        _hubResults = const [];
        _hubFailed = false;
        _hubSearching = false;
      });
      return;
    }
    final generation = ++_hubGeneration;
    setState(() => _hubSearching = true);
    _debounce = Timer(widget.searchDebounce, () async {
      try {
        final results = await _repo.searchHub(q);
        if (!mounted || generation != _hubGeneration) return;
        setState(() {
          _hubResults = results;
          _hubFailed = false;
          _hubSearching = false;
        });
      } catch (error) {
        if (!mounted || generation != _hubGeneration) return;
        setState(() {
          _hubSearching = false;
          _hubResults = const [];
          _hubFailed =
              capabilityFailureKindOf(error) !=
              CapabilityFailureKind.unsupported;
        });
      }
    });
  }

  Future<void> _openFilter() async {
    final s = Strings.of(context);
    final kindGroup = s.cphFilterType;
    final trustGroup = s.cphFilterTrust;
    final chosen = await showHermesOptions<_Facet>(
      context: context,
      anchorKey: _filterKey,
      title: s.cphFilter,
      searchThreshold: 100,
      selected: const _ActiveFacets(),
      equals: (option, _) => switch (option) {
        _KindFacet(:final kind) => kind == _filter.kind,
        _TrustFacet(:final trust) => trust == _filter.trust,
        _ActiveFacets() => false,
      },
      options: [
        if (widget.initialKind == null)
          HermesOption(
            key: const ValueKey('cph-filter-kind-all'),
            value: const _KindFacet(null),
            label: s.cphFilterAllTypes,
            group: kindGroup,
          ),
        if (widget.initialKind == null)
          for (final kind in CapabilityKind.values)
            HermesOption(
              key: ValueKey('cph-filter-kind-${kind.name}'),
              value: _KindFacet(kind),
              label: capabilityKindGroupLabel(s, kind),
              icon: capabilityKindIcon(kind),
              group: kindGroup,
            ),
        HermesOption(
          key: const ValueKey('cph-filter-trust-all'),
          value: const _TrustFacet(null),
          label: s.cphFilterAnyTrust,
          group: trustGroup,
        ),
        for (final trust in const [
          CapabilityTrust.official,
          CapabilityTrust.trusted,
          CapabilityTrust.community,
          CapabilityTrust.local,
        ])
          HermesOption(
            key: ValueKey('cph-filter-trust-${trust.name}'),
            value: _TrustFacet(trust),
            label: capabilityTrustLabel(s, trust),
            group: trustGroup,
          ),
      ],
    );
    if (chosen == null || !mounted) return;
    setState(() {
      _filter = switch (chosen) {
        _KindFacet(:final kind) => _filter.copyWith(
          kind: kind,
          clearKind: kind == null,
        ),
        _TrustFacet(:final trust) => _filter.copyWith(
          trust: trust,
          clearTrust: trust == null,
        ),
        _ActiveFacets() => _filter,
      };
    });
  }

  /// The actions of the «+» of the current tab. The hubs are navigation, so
  /// they stay available on a read-only connection (installing there is what
  /// is refused, in the detail).
  List<HermesAction<_AddAction>> _addActions() {
    final s = Strings.of(context);
    final writable = !widget.readOnly;
    return switch (_tab) {
      ExtensionsTab.skills => [
        HermesAction(
          key: const ValueKey('exu-add-skill-hub'),
          value: _AddAction.skillHub,
          label: s.exuMenuSkillHub,
          icon: Icons.storefront_outlined,
        ),
        if (writable && _repo.supports(CapabilityFeature.skillCreate) != false)
          HermesAction(
            key: const ValueKey('spp-menu-new-skill'),
            value: _AddAction.newSkill,
            label: s.sppMenuNewSkill,
            icon: Icons.add_rounded,
          ),
        if (_canLearn)
          HermesAction(
            key: const ValueKey('las-menu-learn-skill'),
            value: _AddAction.learnSkill,
            label: s.lasMenuLearn,
            icon: Icons.auto_awesome_rounded,
          ),
        if (writable && (_snapshot?.skillsUpdatable ?? false))
          HermesAction(
            key: const ValueKey('cph-menu-update-skills'),
            value: _AddAction.updateSkills,
            label: s.cphMenuUpdateSkills,
            icon: Icons.system_update_alt_rounded,
          ),
      ],
      ExtensionsTab.plugins => [
        if (_repo.supports(CapabilityFeature.pluginCatalog) != false)
          HermesAction(
            key: const ValueKey('exu-add-plugin-hub'),
            value: _AddAction.pluginHub,
            label: s.exuMenuPluginHub,
            icon: Icons.storefront_outlined,
          ),
        if (writable && widget.sourceInstaller != null)
          HermesAction(
            key: const ValueKey('exu-add-plugin-source'),
            value: _AddAction.installFromSource,
            label: s.exuMenuInstallSource,
            icon: Icons.download_rounded,
          ),
      ],
      ExtensionsTab.mcp => [
        HermesAction(
          key: const ValueKey('exu-add-mcp-catalog'),
          value: _AddAction.mcpCatalog,
          label: s.exuMenuMcpCatalog,
          icon: Icons.storefront_outlined,
        ),
        if (writable && _repo.supports(CapabilityFeature.mcpServers) != false)
          HermesAction(
            key: const ValueKey('spp-menu-add-mcp'),
            value: _AddAction.addMcp,
            label: s.sppMenuAddMcp,
            icon: Icons.hub_outlined,
          ),
      ],
    };
  }

  Future<void> _openAdd() async {
    final actions = _addActions();
    if (actions.isEmpty) return;
    final chosen = await showHermesMenu<_AddAction>(
      context: context,
      anchorKey: _addKey,
      actions: actions,
    );
    if (!mounted || chosen == null) return;
    switch (chosen) {
      case _AddAction.skillHub:
        await _openHub(CapabilityKind.skill);
      case _AddAction.newSkill:
        await _newSkill();
      case _AddAction.learnSkill:
        await _learnSkill();
      case _AddAction.updateSkills:
        await _updateSkills();
      case _AddAction.pluginHub:
        await _openHub(CapabilityKind.plugin);
      case _AddAction.installFromSource:
        await _installFromSource();
      case _AddAction.mcpCatalog:
        await _openHub(CapabilityKind.mcp);
      case _AddAction.addMcp:
        await _addMcp();
    }
  }

  /// The ⋯ of the header: what concerns the whole server, not one tab.
  Future<void> _openMore() async {
    final s = Strings.of(context);
    final chosen = await showHermesMenu<_MoreAction>(
      context: context,
      anchorKey: _moreKey,
      actions: [
        if (widget.toolsBuilder != null)
          HermesAction(
            key: const ValueKey('exu-more-tools'),
            value: _MoreAction.tools,
            label: s.exuToolGroupsTitle,
            icon: Icons.handyman_outlined,
          ),
        if (widget.serverBuilder != null)
          HermesAction(
            key: const ValueKey('exu-more-server'),
            value: _MoreAction.server,
            label: s.exuMoreServer,
            icon: Icons.admin_panel_settings_outlined,
          ),
      ],
    );
    if (!mounted || chosen == null) return;
    final builder = switch (chosen) {
      _MoreAction.tools => widget.toolsBuilder!,
      _MoreAction.server => widget.serverBuilder!,
    };
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: builder));
    // The server pages can change what the tabs list (an MCP added or
    // authorised there): read again on the way back.
    if (mounted) _reloadAfterChange();
  }

  /// Plugin from an owner/repo or Git URL: validated, confirmed, then asked
  /// of the server's own installer. It lands where every plugin lands:
  /// switched off unless the person chose otherwise in the form.
  Future<void> _installFromSource() async {
    final install = widget.sourceInstaller;
    if (_busy || widget.readOnly || install == null) return;
    final s = Strings.of(context);
    final notices = AppFeedback.of(context);
    setState(() => _busy = true);
    try {
      final result = await installPluginFromSource(context, install: install);
      if (result == null || !mounted) return;
      final withNotice = result.notices.isNotEmpty;
      notices.notify(
        withNotice ? FeedbackKind.critical : FeedbackKind.routine,
        withNotice
            ? s.extensionsCenterPluginInstalledWithNotice
            : s.extensionsCenterPluginInstalled,
        warning: withNotice,
      );
      _reloadAfterChange();
    } catch (error) {
      if (mounted) {
        notices.notify(FeedbackKind.error, _installFailureText(s, error));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _updateSkills() async {
    if (_busy) return;
    final s = Strings.of(context);
    final ok = await confirmMutatingAction(
      context,
      instanceId: widget.instanceId,
      readOnlyInstance: widget.readOnly,
      risk: CommandRisk.medium,
      title: s.cphConfirmUpdateSkills,
    );
    if (!ok || !mounted) return;
    final notices = AppFeedback.of(context);
    setState(() => _busy = true);
    try {
      await runCapabilityProgress(
        context,
        label: s.cphProgressUpdatingSkills,
        task: (line) => _repo.updateSkills(
          onProgress: (status) => line.value = status.tail,
        ),
      );
      if (!mounted) return;
      notices.notify(FeedbackKind.routine, s.cphDoneSkillsUpdated);
      _reloadAfterChange();
    } catch (error) {
      if (!mounted) return;
      notices.notify(FeedbackKind.error, capabilityFailureMessage(s, error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _newSkill() async {
    if (_busy || widget.readOnly) return;
    final created = await pushHermesFormPage<String>(
      context,
      name: 'skill-create',
      builder: (_) => SkillCreateScreen(
        repository: _repo,
        instanceId: widget.instanceId,
        readOnly: widget.readOnly,
        destinationLabel: widget.destinationLabel,
      ),
    );
    if (!mounted) return;
    if (created != null) {
      AppFeedback.of(context).notify(
        FeedbackKind.routine,
        Strings.of(context).sppSkillCreated(created),
      );
      _reloadAfterChange();
    } else {
      // A server without the route learned it while trying: the entry goes.
      setState(() {});
    }
  }

  bool get _canLearn => !widget.readOnly && widget.learnLauncher != null;

  Set<String> _installedSkillNames(CapabilitiesSnapshot snapshot) => {
    for (final item in snapshot.installed)
      if (item.kind == CapabilityKind.skill) item.installedName,
  };

  /// Learn a skill: the form words the request, the profile's agent does the
  /// work in a chat of its own, and on the way back the list is read again.
  /// A skill that was not there before is tinted once. The agent may still be
  /// working when the user comes back; a later pull to refresh shows it.
  Future<void> _learnSkill() async {
    final launch = widget.learnLauncher;
    if (_busy || !_canLearn || launch == null) return;
    final request = await pushHermesFormPage<String>(
      context,
      name: 'skill-learn',
      builder: (_) => LasLearnScreen(destinationLabel: widget.destinationLabel),
    );
    if (!mounted || request == null) return;
    final known = _snapshot;
    final before = known == null ? null : _installedSkillNames(known);
    await launch(context, LasRequest.buildPrompt(request));
    if (!mounted) return;
    _dropCached();
    await _load();
    final fresh = _snapshot;
    if (!mounted || before == null || fresh == null) return;
    final added = _installedSkillNames(fresh).difference(before);
    if (added.isEmpty) return;
    _learnedTimer?.cancel();
    setState(() => _learned = added);
    _learnedTimer = Timer(const Duration(seconds: 8), () {
      if (mounted) setState(() => _learned = const {});
    });
  }

  String _controlFailureText(Strings s, Object error) =>
      switch (error is DesktopControlFailure
      ? error.kind
      : DesktopControlFailureKind.unavailable) {
        DesktopControlFailureKind.unsupported => s.cphFailUnsupported,
        DesktopControlFailureKind.forbidden => s.cphFailForbidden,
        DesktopControlFailureKind.rejected => s.sppMcpAddRejected,
        DesktopControlFailureKind.invalidResponse => s.cphFailInvalid,
        DesktopControlFailureKind.unavailable => s.cphFailUnavailable,
      };

  /// Adds an MCP server through the shared form: the phone only sends the
  /// description; the server stores it and nothing runs here.
  Future<void> _addMcp() async {
    if (_busy || widget.readOnly) return;
    final draft = await pushHermesFormPage<McpServerDraft>(
      context,
      name: 'mcp-manual-create',
      builder: (_) => McpServerDraftSurface(
        connectionId: widget.instanceId.isEmpty ? null : widget.instanceId,
      ),
    );
    if (!mounted || draft == null) return;
    final s = Strings.of(context);
    final notices = AppFeedback.of(context);
    final approved = await confirmMutatingAction(
      context,
      instanceId: widget.instanceId,
      readOnlyInstance: widget.readOnly,
      risk: CommandRisk.high,
      title: s.sppMcpAddConfirmTitle(draft.name),
      detail: s.sppMcpAddConfirmBody,
    );
    if (!approved || !mounted) return;
    setState(() => _busy = true);
    var created = false;
    try {
      await _repo.addMcpServer(draft);
      created = true;
      if (mounted) {
        notices.notify(FeedbackKind.routine, s.sppMcpAdded(draft.name));
      }
    } catch (error) {
      if (mounted) {
        notices.notify(FeedbackKind.error, _controlFailureText(s, error));
      }
    }
    McpOAuthFlow? flow;
    if (created && draft.auth == McpAuthMode.oauth) {
      try {
        flow = await _repo.startMcpOAuth(draft.name);
      } catch (error) {
        if (mounted) {
          notices.notify(FeedbackKind.error, _controlFailureText(s, error));
        }
      }
    }
    if (mounted) setState(() => _busy = false);
    if (created && mounted) _dropCached();
    if (mounted && flow != null) {
      await showMcpOAuthFlowSurface(
        context: context,
        gateway: _repo,
        initialFlow: flow,
      );
    }
    if (created && mounted) unawaited(_load());
  }

  // ── Switches ────────────────────────────────────────────────────────────

  bool _switchable(CapabilityItem item) =>
      item.installed &&
      !item.stateUnknown &&
      item.enabled != null &&
      item.installedName.isNotEmpty &&
      (item.kind != CapabilityKind.plugin || item.installedKey.isNotEmpty);

  bool _isOn(CapabilityItem item) => _shown[item.id] ?? item.enabled ?? false;

  /// Flips [item] on screen first and asks the server; a refusal, a timeout
  /// or a lost connection puts the switch back and says why. A second tap
  /// while the first is in flight does nothing.
  Future<void> _toggle(CapabilityItem item, bool value) async {
    if (widget.readOnly || _toggling.contains(item.id) || !_switchable(item)) {
      return;
    }
    final s = Strings.of(context);
    final notices = AppFeedback.of(context);
    setState(() => _toggling.add(item.id));
    try {
      final approved = await confirmMutatingAction(
        context,
        instanceId: widget.instanceId,
        readOnlyInstance: widget.readOnly,
        risk: CommandRisk.low,
        title: value ? s.cphActionEnable : s.cphActionDisable,
        detail: item.name,
      );
      if (!approved || !mounted) return;
      setState(() => _shown[item.id] = value);
      var restart = false;
      switch (item.kind) {
        case CapabilityKind.skill:
          await _repo.setSkillEnabled(item.installedName, value);
        case CapabilityKind.plugin:
          final result = await _repo.setPluginEnabled(
            item.installedName,
            value,
            key: item.installedKey,
          );
          restart = result.restartRequired;
        case CapabilityKind.mcp:
          await _repo.setMcpEnabled(item.installedName, value);
      }
      if (!mounted) return;
      _dropCached();
      final snapshot = _snapshot;
      if (snapshot != null) {
        setState(
          () => _snapshot = snapshot.withEnabled(
            item.kind,
            item.installedName,
            value,
          ),
        );
      }
      final done = value
          ? s.cphDoneEnabled(item.name)
          : s.cphDoneDisabled(item.name);
      if (restart) {
        // The change is saved but not live: the user has something to do.
        notices.notify(
          FeedbackKind.critical,
          '$done\n${s.cphRestartRequired}',
          warning: true,
        );
      } else {
        notices.notify(FeedbackKind.routine, done);
      }
    } catch (error) {
      if (!mounted) return;
      if (capabilityFailureKindOf(error) == CapabilityFailureKind.uncertain) {
        // It may have landed: read the truth, never retry.
        notices.notify(
          FeedbackKind.error,
          s.cphUncertainRefreshed,
          warning: true,
        );
        _reloadAfterChange();
      } else {
        notices.notify(
          FeedbackKind.error,
          '${s.sppToggleFailed(item.name)}\n${capabilityFailureMessage(s, error)}',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _toggling.remove(item.id);
          _shown.remove(item.id);
        });
      }
    }
  }

  void _selectTab(ExtensionsTab value) {
    if (value == _tab) return;
    if (_scroll.hasClients) _offsets[_tab] = _scroll.offset;
    final query = _queries[value] ?? '';
    setState(() {
      _tab = value;
      _filter = _filter.copyWith(query: query);
      _search.text = query;
    });
    final target = _offsets[value] ?? 0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.jumpTo(target.clamp(0.0, _scroll.position.maxScrollExtent));
    });
  }

  Future<void> _openDetail(CapabilityItem item) async {
    var changed = false;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CapabilityDetailScreen(
          item: item,
          repository: _repo,
          readOnly: widget.readOnly,
          instanceId: widget.instanceId,
          destinationLabel: widget.destinationLabel,
          onChanged: () {
            changed = true;
            _dropCached();
          },
        ),
      ),
    );
    if (changed && mounted) _reloadAfterChange();
  }

  Future<void> _openConnector(HostedConnector connector) async {
    var changed = false;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ConnectorDetailScreen(
          connector: connector,
          repository: _repo,
          readOnly: widget.readOnly,
          onChanged: () {
            changed = true;
            _dropCached();
          },
        ),
      ),
    );
    if (changed && mounted) _reloadAfterChange();
  }

  // ── Building ────────────────────────────────────────────────────────────

  /// A catalog row of a hub page: where it comes from and what it is, and
  /// the state in words at the end. The detail does the installing.
  Widget _row(CapabilityItem item) {
    final s = Strings.of(context);
    final status = capabilityRowStatus(s, item);
    // A catalog plugin card: publisher, version and tier above the text.
    final cardMeta = item.kind == CapabilityKind.plugin
        ? [
            if (item.author.isNotEmpty) item.author,
            if (item.version.isNotEmpty) s.sppVersion(item.version),
            capabilityTrustLabel(s, item.trust),
          ].join(' · ')
        : '';
    final description = item.description == 'oauth' ? '' : item.description;
    final subtitle = [
      cardMeta,
      description,
    ].where((part) => part.isNotEmpty).join('\n');
    return premium.HermesListRow(
      key: ValueKey('cph-row-${item.id}'),
      icon: capabilityKindIcon(item.kind),
      title: item.name,
      subtitle: subtitle.isEmpty ? null : subtitle,
      onTap: () => _openDetail(item),
      trailing: status == null
          ? null
          : HermesStatusText(
              label: status.label,
              tone: status.tone,
              maxLines: 1,
            ),
    );
  }

  /// Version, origin and a pending update, in that order.
  String _metaLine(Strings s, CapabilityItem item) => [
    if (item.kind == CapabilityKind.plugin && item.version.isNotEmpty)
      s.sppVersion(item.version),
    sppOriginLabel(s, item),
    if (item.updateAvailable) s.cphStatusUpdateShort,
  ].where((part) => part.isNotEmpty).join(' · ');

  /// What a tab row says under the name: a skill its description, a plugin
  /// its version and origin over the description, an MCP server how it is
  /// doing, where it points (credentials hidden) and how many tools it has.
  String _tabDescription(
    Strings s,
    CapabilityItem item,
    McpRuntimeRow? runtime,
  ) {
    final description = item.description == 'oauth' ? '' : item.description;
    switch (item.kind) {
      case CapabilityKind.skill:
        return description.isNotEmpty ? description : _metaLine(s, item);
      case CapabilityKind.plugin:
        return [
          _metaLine(s, item),
          description,
        ].where((part) => part.isNotEmpty).join('\n');
      case CapabilityKind.mcp:
        final target = item.url.isNotEmpty
            ? item.url
            : item.command.isNotEmpty
            ? item.command
            : null;
        final live = runtime == null
            ? null
            : mcpRuntimeStatusLabel(s, runtime.status);
        final count =
            _snapshot?.mcpToolCounts[item.installedName] ??
            runtime?.tools ??
            item.tools.length;
        final tools = s.extensionsCenterToolCount(count);
        final state =
            live?.label ??
            (item.enabled == false ? s.cphStatusDisabled : s.cphStatusEnabled);
        return [
          tools,
          state,
          if (target != null) sppSafeTarget(target),
        ].join(' · ');
    }
  }

  /// A row of a tab: no card and no icon, the name in bold over at most two
  /// lines, and the switch in the same slot on every row of every tab.
  Widget _tabRow(CapabilityItem item, {McpRuntimeRow? runtime}) {
    final s = Strings.of(context);
    final switchable =
        item.installed && !item.stateUnknown && item.enabled != null;
    final status = switchable ? null : capabilityRowStatus(s, item);
    return CapabilityPlainRow(
      key: ValueKey('cph-row-${item.id}'),
      title: sppRedactHostText(item.name, s),
      description: sppRedactHostText(_tabDescription(s, item, runtime), s),
      highlighted: _learned.contains(item.installedName),
      semanticHint: s.pghOpenDetail,
      onTap: () => _openDetail(item),
      trailing: switchable
          ? HermesRowSwitch(
              switchKey: ValueKey('spp-switch-${item.id}'),
              label: s.sppSwitchLabel(item.name),
              value: _isOn(item),
              enabled:
                  !widget.readOnly &&
                  !_toggling.contains(item.id) &&
                  _switchable(item),
              onChanged: (value) => _toggle(item, value),
            )
          : status == null
          ? null
          : HermesStatusText(
              label: status.label,
              tone: status.tone,
              maxLines: 1,
            ),
    );
  }

  /// The rows of a hub page, grouped by kind.
  List<Widget> _groups(List<CapabilityItem> items) {
    final s = Strings.of(context);
    final out = <Widget>[];
    for (final kind in CapabilityKind.values) {
      final rows = items.where((item) => item.kind == kind).toList();
      if (rows.isEmpty) continue;
      final limit = _groupCap + (_shownRows[kind] ?? 0);
      final visible = rows.length <= limit ? rows : rows.take(limit).toList();
      final hidden = rows.length - visible.length;
      final children = <Widget>[
        for (final item in visible) _row(item),
        if (hidden > 0)
          premium.HermesListRow(
            key: ValueKey('cph-show-all-${kind.name}'),
            title: s.sppShowMore(hidden < _revealStep ? hidden : _revealStep),
            onTap: () => setState(
              () => _shownRows[kind] = (_shownRows[kind] ?? 0) + _revealStep,
            ),
          ),
      ];
      out
        ..add(
          HermesSectionHeader(
            capabilityKindGroupLabel(s, kind),
            trailing: Text(
              '${rows.length}',
              style: HermesType.caption.copyWith(
                color: Theme.of(context).hermes.textSecondary,
              ),
            ),
          ),
        )
        ..add(
          premium.HermesListSection(
            margin: EdgeInsets.zero,
            children: children,
          ),
        );
    }
    return out;
  }

  /// Plugin Hub: the curated catalog the server publishes, with the installed
  /// plugins that have a newer version first. The server offers no search,
  /// update-check or validate route for plugins: the search here is local and
  /// the update flag is the one the server last computed.
  List<Widget> _pluginHub(CapabilitiesSnapshot snapshot) {
    final s = Strings.of(context);
    final catalogPlugins = snapshot.catalog
        .where((item) => item.kind == CapabilityKind.plugin)
        .toList(growable: false);
    final intro = Padding(
      padding: const EdgeInsets.only(top: HermesSpace.x3),
      child: Text(
        s.pghHubIntro,
        key: const ValueKey('pgh-hub-intro'),
        style: HermesType.support.copyWith(
          color: Theme.of(context).hermes.textSecondary,
        ),
      ),
    );
    if (!snapshot.complete) {
      return [
        intro,
        const Padding(
          padding: EdgeInsets.only(top: HermesSpace.x8 + HermesSpace.x8),
          child: Center(
            child: ConsoleLoader.large(key: ValueKey('cph-loading-catalog')),
          ),
        ),
      ];
    }
    if (catalogPlugins.isEmpty) {
      return [
        intro,
        HermesEmptyStateView(
          key: const ValueKey('pgh-no-catalog'),
          icon: Icons.storefront_outlined,
          title: s.pghNoCatalogTitle,
          body: s.pghNoCatalogBody,
        ),
      ];
    }
    final matching = filterCapabilities(snapshot.catalog, _filter);
    final updates = matching
        .where((item) => item.installed && item.updateAvailable)
        .toList(growable: false);
    final rest = matching
        .where((item) => !(item.installed && item.updateAvailable))
        .toList(growable: false);
    return [
      intro,
      if (updates.isNotEmpty) ...[
        HermesSectionHeader(
          s.pghUpdatesGroup,
          trailing: Text(
            '${updates.length}',
            style: HermesType.caption.copyWith(
              color: Theme.of(context).hermes.textSecondary,
            ),
          ),
        ),
        premium.HermesListSection(
          key: const ValueKey('pgh-updates'),
          margin: EdgeInsets.zero,
          children: [for (final item in updates) _row(item)],
        ),
      ],
      ..._groups(rest),
      if (matching.isEmpty)
        HermesEmptyStateView(
          key: const ValueKey('cph-empty-catalog'),
          icon: Icons.search_off_rounded,
          title: s.cphEmptyCatalog,
          body: s.cphEmptyCatalogBody,
        ),
    ];
  }

  List<Widget> _catalog(CapabilitiesSnapshot snapshot) {
    if (_hubMode) return _pluginHub(snapshot);
    final s = Strings.of(context);
    final items = filterCapabilities(snapshot.catalog, _filter);
    final known = snapshot.catalog.map((item) => item.installId).toSet();
    final hub = _filter.kind == null || _filter.kind == CapabilityKind.skill
        ? filterCapabilities(
            _hubResults.where((item) => !known.contains(item.installId)),
            _filter.copyWith(query: ''),
          )
        : const <CapabilityItem>[];
    return [
      if (_hubFailed)
        Padding(
          padding: const EdgeInsets.only(top: HermesSpace.x3),
          child: HermesInlineNotice(
            key: const ValueKey('cph-hub-failed'),
            message: s.cphHubSearchFailed,
            tone: HermesStatusTone.warn,
          ),
        ),
      ..._groups(items),
      if (hub.isNotEmpty) ...[
        HermesSectionHeader(s.cphHubResults),
        premium.HermesListSection(
          margin: EdgeInsets.zero,
          children: [for (final item in hub) _row(item)],
        ),
      ],
      // The hub is still answering: say so instead of "no results".
      if (_hubSearching)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: HermesSpace.x4),
          child: Row(
            key: const ValueKey('spp-hub-searching'),
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const ConsoleLoader.small(),
              const SizedBox(width: HermesSpace.x3),
              Flexible(
                child: Text(
                  s.sppSearchingHub,
                  style: HermesType.support.copyWith(
                    color: Theme.of(context).hermes.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
      // Sources still answering: never claim that nothing matches.
      if (items.isEmpty && hub.isEmpty && _hubSearching)
        const SizedBox.shrink()
      else if (items.isEmpty && hub.isEmpty && !snapshot.complete)
        const Padding(
          padding: EdgeInsets.only(top: HermesSpace.x8 + HermesSpace.x8),
          child: Center(
            child: ConsoleLoader.large(key: ValueKey('cph-loading-catalog')),
          ),
        )
      else if (items.isEmpty && hub.isEmpty)
        HermesEmptyStateView(
          key: const ValueKey('cph-empty-catalog'),
          icon: Icons.search_off_rounded,
          title: s.cphEmptyCatalog,
          body: s.cphEmptyCatalogBody,
        ),
    ];
  }

  /// What the tab lists: the installed skills or plugins of its kind, or the
  /// MCP servers the server has configured.
  List<CapabilityItem> _tabItems(CapabilitiesSnapshot snapshot) =>
      _tab == ExtensionsTab.mcp
      ? snapshot.mcpServers
      : snapshot.installed.where((item) => item.kind == _tab.kind).toList();

  /// The body of a tab: «N installed · M active», the status filter and one
  /// flat list, plus, under MCP, the connected accounts.
  List<Widget> _tabBody(CapabilitiesSnapshot snapshot) {
    final s = Strings.of(context);
    final all = _tabItems(snapshot);
    final out = <Widget>[];
    if (all.isEmpty && !snapshot.complete) {
      // The list has not answered yet: never claim it is empty.
      out.add(
        const Padding(
          padding: EdgeInsets.only(top: HermesSpace.x8 + HermesSpace.x8),
          child: Center(
            child: ConsoleLoader.large(key: ValueKey('cph-loading-installed')),
          ),
        ),
      );
    } else if (all.isEmpty) {
      out.add(
        _tab == ExtensionsTab.mcp
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(
                      left: HermesSpace.x1,
                      top: HermesSpace.x3,
                      bottom: HermesSpace.x2,
                    ),
                    child: Text(
                      s.cphNoMcpServers,
                      key: const ValueKey('cph-no-mcp'),
                      style: HermesType.support.copyWith(
                        color: Theme.of(context).hermes.textSecondary,
                      ),
                    ),
                  ),
                  if (!widget.readOnly &&
                      _repo.supports(CapabilityFeature.mcpServers) != false)
                    TextButton(
                      key: const ValueKey('spp-add-mcp-empty'),
                      style: TextButton.styleFrom(
                        minimumSize: const Size(
                          HermesSpace.tap,
                          HermesSpace.tap,
                        ),
                      ),
                      onPressed: _busy ? null : _addMcp,
                      child: Text(s.sppMenuAddMcp),
                    ),
                ],
              )
            : HermesEmptyStateView(
                key: const ValueKey('cph-empty-installed'),
                icon: Icons.inventory_2_outlined,
                title: s.cphEmptyInstalled,
                body: s.cphEmptyInstalledBody,
              ),
      );
    } else {
      final on = all.where((item) => item.enabled != false).length;
      var items = filterCapabilities(all, _filter)
          .where(
            (item) => switch (_status) {
              _StatusFilter.all => true,
              _StatusFilter.active => item.enabled != false,
              _StatusFilter.inactive => item.enabled == false,
            },
          )
          .toList(growable: false);
      if (_tab == ExtensionsTab.skills && _learned.isNotEmpty) {
        // What was just learned leads the list, so a long list never hides it.
        items = [
          ...items.where((item) => _learned.contains(item.installedName)),
          ...items.where((item) => !_learned.contains(item.installedName)),
        ];
      }
      out
        ..add(
          Padding(
            padding: const EdgeInsets.only(
              left: HermesSpace.x1,
              top: HermesSpace.x1,
              bottom: HermesSpace.x2,
            ),
            child: Semantics(
              liveRegion: true,
              child: Text(
                s.sppInstalledSummary(all.length, on),
                key: const ValueKey('spp-installed-summary'),
                style: HermesType.support.copyWith(
                  color: Theme.of(context).hermes.textSecondary,
                ),
              ),
            ),
          ),
        )
        ..add(
          HermesSegmentedControl<_StatusFilter>(
            value: _status,
            semanticLabel: s.sppStatusFilter,
            onChanged: (value) => setState(() => _statuses[_tab] = value),
            segments: [
              HermesSegment(
                key: const ValueKey('spp-status-all'),
                value: _StatusFilter.all,
                label: s.sppFilterAll,
              ),
              HermesSegment(
                key: const ValueKey('spp-status-active'),
                value: _StatusFilter.active,
                label: s.sppFilterActive,
              ),
              HermesSegment(
                key: const ValueKey('spp-status-inactive'),
                value: _StatusFilter.inactive,
                label: s.sppFilterInactive,
              ),
            ],
          ),
        )
        ..add(const SizedBox(height: HermesSpace.x3));
      if (items.isEmpty) {
        out.add(
          HermesEmptyStateView(
            key: const ValueKey('cph-empty-installed'),
            icon: Icons.search_off_rounded,
            title: s.cphEmptyCatalog,
            body: s.cphEmptyCatalogBody,
          ),
        );
      } else {
        final limit = _groupCap + (_shownRows[_tab.kind] ?? 0);
        final visible = items.length <= limit
            ? items
            : items.take(limit).toList();
        final hidden = items.length - visible.length;
        out.add(
          CapabilityPlainList(
            children: [
              for (final item in visible)
                _tabRow(item, runtime: snapshot.mcpRuntime[item.name]),
              if (hidden > 0)
                premium.HermesListRow(
                  key: ValueKey('cph-show-all-${_tab.kind.name}'),
                  title: s.sppShowMore(
                    hidden < _revealStep ? hidden : _revealStep,
                  ),
                  onTap: () => setState(
                    () => _shownRows[_tab.kind] =
                        (_shownRows[_tab.kind] ?? 0) + _revealStep,
                  ),
                ),
            ],
          ),
        );
      }
    }
    if (_tab == ExtensionsTab.mcp && snapshot.complete) {
      out.addAll(_accountsBlock(snapshot));
    }
    return out;
  }

  /// The accounts of the hosted connectors, under the MCP servers: what used
  /// to be a tab of its own.
  List<Widget> _accountsBlock(CapabilitiesSnapshot snapshot) {
    final s = Strings.of(context);
    final hosted = snapshot.connectors;
    final q = _filter.query.trim().toLowerCase();
    final accounts = (hosted?.connectors ?? const <HostedConnector>[])
        .where(
          (c) =>
              q.isEmpty ||
              '${c.name} ${c.description} ${c.category}'.toLowerCase().contains(
                q,
              ),
        )
        .toList();
    String? accountsNote;
    if (snapshot.connectorsFailed) {
      accountsNote = s.cphConnectorsError;
    } else {
      accountsNote = switch (hosted?.availability) {
        null || ConnectorAvailability.unsupported => s.cphConnectorsUnsupported,
        ConnectorAvailability.signedOut => s.cphConnectorsSignedOut,
        ConnectorAvailability.unavailable => s.cphConnectorsUnavailable,
        ConnectorAvailability.available =>
          accounts.isEmpty && q.isEmpty
              ? s.cphConnectorsEmpty
              : s.cphConnectorsConnectHint,
      };
    }
    return [
      HermesSectionHeader(s.cphConnectorsAccounts),
      if (accounts.isNotEmpty)
        premium.HermesListSection(
          margin: EdgeInsets.zero,
          children: [
            // Rows open the policy detail only when the server answers
            // `connectors.policy.get`; connecting accounts is not wired in
            // Console yet, so otherwise they carry state without a tap.
            for (final connector in accounts)
              premium.HermesListRow(
                key: ValueKey('cph-account-${connector.slug}'),
                icon: Icons.account_circle_outlined,
                title: connector.name,
                onTap: snapshot.connectorPolicyReadable
                    ? () => _openConnector(connector)
                    : null,
                subtitle: connector.statusReason.isNotEmpty
                    ? connector.statusReason
                    : connector.description,
                trailing: HermesStatusText(
                  label: connector.connected
                      ? s.cphConnected
                      : s.cphNotConnected,
                  tone: connector.connected
                      ? HermesStatusTone.ok
                      : HermesStatusTone.neutral,
                  maxLines: 1,
                ),
              ),
          ],
        ),
      Padding(
        padding: const EdgeInsets.only(top: HermesSpace.x2),
        child: HermesInlineNotice(
          key: const ValueKey('cph-accounts-note'),
          message: accountsNote,
        ),
      ),
    ];
  }

  String _errorBody(Strings s, Object error) =>
      switch (capabilityFailureKindOf(error)) {
        CapabilityFailureKind.forbidden => s.cphErrorForbidden,
        CapabilityFailureKind.unsupported => s.cphErrorUnsupported,
        _ => s.cphErrorOffline,
      };

  /// What the title says: the three tabs are «Extensions»; a hub page is
  /// named after what it browses.
  String _title(Strings s) {
    if (!_isHub) return s.extensionsCenterTitle;
    return switch (widget.initialKind) {
      CapabilityKind.skill => s.exuHubSkillTitle,
      CapabilityKind.plugin => s.pghHubTitle,
      CapabilityKind.mcp => s.extensionsCenterMcpCatalogTitle,
      null => s.cphTitle,
    };
  }

  String _searchHint(Strings s) => _isHub
      ? s.cphSearchHint
      : switch (_tab) {
          ExtensionsTab.skills => s.exuSearchSkills,
          ExtensionsTab.plugins => s.exuSearchPlugins,
          ExtensionsTab.mcp => s.exuSearchMcp,
        };

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final snapshot = _snapshot;
    final filtersActive = _filter.kind != null || _filter.trust != null;
    final addActions = _isHub
        ? const <HermesAction<_AddAction>>[]
        : _addActions();

    final header = <Widget>[
      if (!_isHub) ...[
        HermesSegmentedControl<ExtensionsTab>(
          value: _tab,
          semanticLabel: s.exuTabsLabel,
          onChanged: _selectTab,
          segments: [
            HermesSegment(
              key: const ValueKey('exu-tab-skills'),
              value: ExtensionsTab.skills,
              label: s.cphKindSkills,
            ),
            HermesSegment(
              key: const ValueKey('exu-tab-plugins'),
              value: ExtensionsTab.plugins,
              label: s.cphKindPlugins,
            ),
            HermesSegment(
              key: const ValueKey('exu-tab-mcp'),
              value: ExtensionsTab.mcp,
              label: s.navMcp,
            ),
          ],
        ),
        const SizedBox(height: HermesSpace.x3),
      ],
      Row(
        children: [
          Expanded(
            child: TextField(
              key: const ValueKey('cph-search'),
              controller: _search,
              onChanged: _onQuery,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                isDense: true,
                hintText: _searchHint(s),
                prefixIcon: const Icon(Icons.search_rounded, size: 20),
                filled: true,
                fillColor: Theme.of(
                  context,
                ).hermes.surfaceVariant.withValues(alpha: .6),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(HermesRadius.control),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          if (_isHub) ...[
            const SizedBox(width: HermesSpace.x1),
            IconButton(
              key: _filterKey,
              tooltip: s.cphFilter,
              isSelected: filtersActive,
              constraints: const BoxConstraints(
                minWidth: HermesSpace.tap,
                minHeight: HermesSpace.tap,
              ),
              icon: Badge(
                isLabelVisible: filtersActive,
                smallSize: 7,
                child: const Icon(Icons.tune_rounded),
              ),
              onPressed: _openFilter,
            ),
          ] else if (addActions.isNotEmpty) ...[
            const SizedBox(width: HermesSpace.x1),
            KeyedSubtree(
              key: _addKey,
              child: IconButton(
                key: const ValueKey('exu-add'),
                tooltip: s.exuAddTooltip,
                constraints: const BoxConstraints(
                  minWidth: HermesSpace.tap,
                  minHeight: HermesSpace.tap,
                ),
                icon: const Icon(Icons.add_rounded),
                onPressed: _busy ? null : _openAdd,
              ),
            ),
          ],
        ],
      ),
      if (widget.readOnly) ...[
        const SizedBox(height: HermesSpace.x3),
        HermesInlineNotice(
          key: const ValueKey('cph-readonly'),
          icon: Icons.lock_outline_rounded,
          message: s.cphReadOnly,
        ),
      ],
      // The slot stays once content shows, so the list never jumps when the
      // last source answers and the line goes away.
      if (snapshot != null) ...[
        const SizedBox(height: HermesSpace.x3),
        SizedBox(
          height: 2,
          child: !snapshot.complete || _revalidating
              ? const LinearProgressIndicator(
                  key: ValueKey('cph-loading-more'),
                  minHeight: 2,
                )
              : null,
        ),
      ],
      if (snapshot?.partial ?? false) ...[
        const SizedBox(height: HermesSpace.x3),
        HermesInlineNotice(
          key: const ValueKey('cph-partial'),
          tone: HermesStatusTone.warn,
          icon: Icons.warning_amber_rounded,
          message: s.cphPartial,
          actionLabel: s.commonRetry,
          onAction: _load,
        ),
      ],
    ];

    final List<Widget> body;
    if (_loading) {
      body = const [
        Padding(
          padding: EdgeInsets.only(top: HermesSpace.x8 + HermesSpace.x8),
          child: Center(
            child: ConsoleLoader.large(key: ValueKey('cph-loading')),
          ),
        ),
      ];
    } else if (snapshot == null) {
      body = [
        HermesEmptyStateView(
          key: const ValueKey('cph-error'),
          icon: Icons.cloud_off_rounded,
          title: s.cphErrorTitle,
          body: _errorBody(s, _error ?? const Object()),
        ),
        Center(
          child: TextButton(
            key: const ValueKey('cph-retry'),
            style: TextButton.styleFrom(
              minimumSize: const Size(HermesSpace.tap, HermesSpace.tap),
            ),
            onPressed: _load,
            child: Text(s.commonRetry),
          ),
        ),
      ];
    } else {
      body = _isHub ? _catalog(snapshot) : _tabBody(snapshot);
    }

    // The ⋯ exists only when it would have something in it.
    final hasMore =
        !_isHub &&
        (widget.toolsBuilder != null || widget.serverBuilder != null);

    return HermesPage(
      listKey: const ValueKey('cph-list'),
      controller: _scroll,
      title: _title(s),
      onRefresh: snapshot == null ? null : _load,
      actions: [
        if (hasMore)
          IconButton(
            key: _moreKey,
            tooltip: s.cphMore,
            icon: const Icon(Icons.more_vert_rounded),
            onPressed: _openMore,
          ),
      ],
      children: [...header, ...body],
    );
  }
}

String _installFailureText(Strings s, Object error) {
  if (error is DesktopControlFailure) {
    return switch (error.kind) {
      DesktopControlFailureKind.unsupported =>
        s.extensionsCenterMutationFailureUnsupported,
      DesktopControlFailureKind.forbidden =>
        s.extensionsCenterMutationFailureForbidden,
      DesktopControlFailureKind.invalidResponse =>
        s.extensionsCenterMutationFailureInvalidResponse,
      DesktopControlFailureKind.unavailable =>
        s.extensionsCenterMutationFailureUnavailable,
      DesktopControlFailureKind.rejected =>
        s.extensionsCenterMutationFailureRejected,
    };
  }
  return s.extensionsCenterMutationFailureUnknown;
}
