// Capabilities hub: one place for skills, plugins, MCP servers and account
// connectors, read from the profile's own server. Catalog · Installed ·
// Connectors; search + facet filter; each row opens an action-first detail.
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
import 'capabilities_adapters.dart';
import 'capabilities_repository.dart';
import 'capability_detail_screen.dart';
import 'capability_models.dart';
import 'capability_ui.dart';
import 'connector_detail_screen.dart';
import 'mcp_runtime_status.dart';
import '../widgets/console_loader.dart';
import '../feedback/feedback_policy.dart';

enum CapabilitiesSegment { catalog, installed, connectors }

/// Everything the hub shows, loaded in one pass. Sources that the server
/// does not publish are simply absent; sources that failed are counted so
/// the page can say so honestly.
final class CapabilitiesSnapshot {
  final List<CapabilityItem> catalog;
  final List<CapabilityItem> installed;
  final List<CapabilityItem> mcpServers;

  /// Live MCP state by server name; empty when the server lacks it.
  final Map<String, McpRuntimeRow> mcpRuntime;
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
    this.connectors,
    this.connectorPolicyReadable = false,
    this.connectorsFailed = false,
    this.partial = false,
    this.skillsUpdatable = false,
    this.complete = true,
  });

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
  final WidgetBuilder? advancedBuilder;

  const CapabilitiesHub({
    super.key,
    required this.connection,
    this.profile = '',
    this.advancedBuilder,
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
    advancedBuilder: advancedBuilder,
  );
}

class _CapabilitiesHubBody extends StatefulWidget {
  final SavedConnection connection;
  final String profile;
  final WidgetBuilder? advancedBuilder;

  const _CapabilitiesHubBody({
    super.key,
    required this.connection,
    required this.profile,
    this.advancedBuilder,
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
    advancedBuilder: widget.advancedBuilder,
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
  final WidgetBuilder? advancedBuilder;
  final CapabilitiesSegment initialSegment;
  final Duration searchDebounce;

  const CapabilitiesScreen({
    super.key,
    required this.repository,
    this.snapshotCache,
    this.snapshotKey = '',
    this.readOnly = false,
    this.instanceId = '',
    this.destinationLabel = '',
    this.advancedBuilder,
    this.initialSegment = CapabilitiesSegment.catalog,
    this.searchDebounce = const Duration(milliseconds: 450),
  });

  @override
  State<CapabilitiesScreen> createState() => _CapabilitiesScreenState();
}

enum _MenuAction { updateSkills, advanced }

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

  late CapabilitiesSegment _segment = widget.initialSegment;
  CapabilitiesSnapshot? _snapshot;
  Object? _error;
  bool _loading = true;
  CapabilityFilter _filter = const CapabilityFilter();
  final TextEditingController _search = TextEditingController();
  final GlobalKey _moreKey = GlobalKey(debugLabel: 'cph-more');
  final GlobalKey _filterKey = GlobalKey(debugLabel: 'cph-filter');
  final Set<CapabilityKind> _expanded = {};
  Timer? _debounce;
  List<CapabilityItem> _hubResults = const [];
  bool _hubFailed = false;
  int _hubGeneration = 0;
  bool _busy = false;

  /// A cached snapshot is on screen while the server answers again.
  bool _revalidating = false;

  CapabilitiesRepository get _repo => widget.repository;

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
    _search.dispose();
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
    _debounce?.cancel();
    final q = value.trim();
    if (q.length < 3 || _repo.supports(CapabilityFeature.hubSearch) == false) {
      setState(() {
        _hubResults = const [];
        _hubFailed = false;
      });
      return;
    }
    final generation = ++_hubGeneration;
    _debounce = Timer(widget.searchDebounce, () async {
      try {
        final results = await _repo.searchHub(q);
        if (!mounted || generation != _hubGeneration) return;
        setState(() {
          _hubResults = results;
          _hubFailed = false;
        });
      } catch (error) {
        if (!mounted || generation != _hubGeneration) return;
        setState(() {
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
        HermesOption(
          key: const ValueKey('cph-filter-kind-all'),
          value: const _KindFacet(null),
          label: s.cphFilterAllTypes,
          group: kindGroup,
        ),
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

  Future<void> _openMenu() async {
    final s = Strings.of(context);
    final snapshot = _snapshot;
    final chosen = await showHermesMenu<_MenuAction>(
      context: context,
      anchorKey: _moreKey,
      actions: [
        if (!widget.readOnly && (snapshot?.skillsUpdatable ?? false))
          HermesAction(
            key: const ValueKey('cph-menu-update-skills'),
            value: _MenuAction.updateSkills,
            label: s.cphMenuUpdateSkills,
            icon: Icons.system_update_alt_rounded,
          ),
        if (widget.advancedBuilder != null)
          HermesAction(
            key: const ValueKey('cph-menu-advanced'),
            value: _MenuAction.advanced,
            label: s.cphMenuAdvanced,
            icon: Icons.tune_rounded,
          ),
      ],
    );
    if (!mounted || chosen == null) return;
    switch (chosen) {
      case _MenuAction.updateSkills:
        await _updateSkills();
      case _MenuAction.advanced:
        await Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: widget.advancedBuilder!));
        if (mounted) _reloadAfterChange();
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

  Widget _row(CapabilityItem item) {
    final s = Strings.of(context);
    final status = capabilityRowStatus(s, item);
    return HermesListRow(
      key: ValueKey('cph-row-${item.id}'),
      icon: capabilityKindIcon(item.kind),
      title: item.name,
      subtitle: item.description == 'oauth' ? null : item.description,
      onTap: () => _openDetail(item),
      trailing: status == null
          ? null
          : Padding(
              padding: const EdgeInsets.only(left: 10),
              child: HermesStatusText(
                label: status.label,
                tone: status.tone,
                maxLines: 1,
              ),
            ),
    );
  }

  List<Widget> _groups(List<CapabilityItem> items) {
    final s = Strings.of(context);
    final out = <Widget>[];
    for (final kind in CapabilityKind.values) {
      final rows = items.where((item) => item.kind == kind).toList();
      if (rows.isEmpty) continue;
      final expanded = _expanded.contains(kind) || rows.length <= _groupCap;
      final visible = expanded ? rows : rows.take(_groupCap).toList();
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
          HermesListGroup(
            children: [
              for (final item in visible) _row(item),
              if (!expanded)
                HermesListRow(
                  key: ValueKey('cph-show-all-${kind.name}'),
                  title: s.cphShowAll(rows.length),
                  muted: true,
                  onTap: () => setState(() => _expanded.add(kind)),
                ),
            ],
          ),
        );
    }
    return out;
  }

  List<Widget> _catalog(CapabilitiesSnapshot snapshot) {
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
        HermesListGroup(children: [for (final item in hub) _row(item)]),
      ],
      // Sources still answering: never claim that nothing matches.
      if (items.isEmpty && hub.isEmpty && !snapshot.complete)
        const Padding(
          padding: EdgeInsets.only(top: 64),
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

  List<Widget> _installed(CapabilitiesSnapshot snapshot) {
    final s = Strings.of(context);
    final items = filterCapabilities(snapshot.installed, _filter);
    if (items.isEmpty && snapshot.installed.isEmpty && !snapshot.complete) {
      // The installed list has not answered yet: never claim it is empty.
      return const [
        Padding(
          padding: EdgeInsets.only(top: 64),
          child: Center(
            child: ConsoleLoader.large(key: ValueKey('cph-loading-installed')),
          ),
        ),
      ];
    }
    if (items.isEmpty) {
      final none = snapshot.installed.isEmpty;
      return [
        HermesEmptyStateView(
          key: const ValueKey('cph-empty-installed'),
          icon: none ? Icons.inventory_2_outlined : Icons.search_off_rounded,
          title: none ? s.cphEmptyInstalled : s.cphEmptyCatalog,
          body: none ? s.cphEmptyInstalledBody : s.cphEmptyCatalogBody,
        ),
      ];
    }
    return _groups(items);
  }

  List<Widget> _connectorsSection(CapabilitiesSnapshot snapshot) {
    final s = Strings.of(context);
    final servers = filterCapabilities(
      snapshot.mcpServers,
      _filter.copyWith(clearKind: true, clearTrust: true),
    );
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
      HermesSectionHeader(s.cphKindMcp),
      if (servers.isEmpty)
        Padding(
          padding: const EdgeInsets.only(left: 6, bottom: 4),
          child: Text(
            s.cphNoMcpServers,
            key: const ValueKey('cph-no-mcp'),
            style: HermesType.support.copyWith(
              color: Theme.of(context).hermes.textSecondary,
            ),
          ),
        )
      else
        HermesListGroup(
          children: [
            for (final server in servers)
              _mcpRow(server, snapshot.mcpRuntime[server.name]),
          ],
        ),
      HermesSectionHeader(s.cphConnectorsAccounts),
      if (accounts.isNotEmpty)
        HermesListGroup(
          children: [
            // Rows open the policy detail only when the server answers
            // `connectors.policy.get`; connecting accounts is not wired in
            // Console yet, so otherwise they carry state without a tap.
            for (final connector in accounts)
              HermesListRow(
                key: ValueKey('cph-account-${connector.slug}'),
                icon: Icons.account_circle_outlined,
                title: connector.name,
                onTap: snapshot.connectorPolicyReadable
                    ? () => _openConnector(connector)
                    : null,
                subtitle: connector.statusReason.isNotEmpty
                    ? connector.statusReason
                    : connector.description,
                trailing: Padding(
                  padding: const EdgeInsets.only(left: 10),
                  child: HermesStatusText(
                    label: connector.connected
                        ? s.cphConnected
                        : s.cphNotConnected,
                    tone: connector.connected
                        ? HermesStatusTone.ok
                        : HermesStatusTone.neutral,
                    maxLines: 1,
                  ),
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

  Widget _mcpRow(CapabilityItem server, McpRuntimeRow? runtime) {
    final s = Strings.of(context);
    final target = server.url.isNotEmpty
        ? server.url
        : server.command.isNotEmpty
        ? server.command
        : null;
    final live = runtime == null
        ? null
        : mcpRuntimeStatusLabel(s, runtime.status);
    final tools = runtime == null || runtime.tools == 0
        ? null
        : s.cphMcpToolCount(runtime.tools);
    final status =
        live ??
        (
          label: server.enabled == false
              ? s.cphStatusDisabled
              : s.cphStatusEnabled,
          tone: server.enabled == false
              ? HermesStatusTone.neutral
              : HermesStatusTone.ok,
        );
    return HermesListRow(
      key: ValueKey('cph-row-${server.id}'),
      icon: capabilityKindIcon(server.kind),
      title: server.name,
      subtitle: [?target, ?tools].isEmpty
          ? null
          : [?target, ?tools].join(' · '),
      onTap: () => _openDetail(server),
      trailing: Padding(
        padding: const EdgeInsets.only(left: 10),
        child: HermesStatusText(
          label: status.label,
          tone: status.tone,
          maxLines: 1,
        ),
      ),
    );
  }

  String _errorBody(Strings s, Object error) =>
      switch (capabilityFailureKindOf(error)) {
        CapabilityFailureKind.forbidden => s.cphErrorForbidden,
        CapabilityFailureKind.unsupported => s.cphErrorUnsupported,
        _ => s.cphErrorOffline,
      };

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final snapshot = _snapshot;
    final filtersActive = _filter.kind != null || _filter.trust != null;

    final header = <Widget>[
      HermesSegmentedControl<CapabilitiesSegment>(
        value: _segment,
        onChanged: (value) => setState(() => _segment = value),
        segments: [
          HermesSegment(
            key: const ValueKey('cph-seg-catalog'),
            value: CapabilitiesSegment.catalog,
            label: s.cphSegCatalog,
          ),
          HermesSegment(
            key: const ValueKey('cph-seg-installed'),
            value: CapabilitiesSegment.installed,
            label: s.cphSegInstalled,
          ),
          HermesSegment(
            key: const ValueKey('cph-seg-connectors'),
            value: CapabilitiesSegment.connectors,
            label: s.cphSegConnectors,
          ),
        ],
      ),
      const SizedBox(height: HermesSpace.x3),
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
                hintText: s.cphSearchHint,
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
          if (_segment != CapabilitiesSegment.connectors) ...[
            const SizedBox(width: HermesSpace.x1),
            IconButton(
              key: _filterKey,
              tooltip: s.cphFilter,
              isSelected: filtersActive,
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              icon: Badge(
                isLabelVisible: filtersActive,
                smallSize: 7,
                child: const Icon(Icons.tune_rounded),
              ),
              onPressed: _openFilter,
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
          padding: EdgeInsets.only(top: 64),
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
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: _load,
            child: Text(s.commonRetry),
          ),
        ),
      ];
    } else {
      body = switch (_segment) {
        CapabilitiesSegment.catalog => _catalog(snapshot),
        CapabilitiesSegment.installed => _installed(snapshot),
        CapabilitiesSegment.connectors when !snapshot.complete => const [
          Padding(
            padding: EdgeInsets.only(top: 64),
            child: Center(
              child: ConsoleLoader.large(key: ValueKey('cph-loading')),
            ),
          ),
        ],
        CapabilitiesSegment.connectors => _connectorsSection(snapshot),
      };
    }

    final hasMenu =
        widget.advancedBuilder != null ||
        (!widget.readOnly && (snapshot?.skillsUpdatable ?? false));

    return HermesPage(
      listKey: const ValueKey('cph-list'),
      title: s.cphTitle,
      onRefresh: snapshot == null ? null : _load,
      actions: [
        if (hasMenu)
          IconButton(
            key: _moreKey,
            tooltip: s.cphMore,
            icon: const Icon(Icons.more_vert_rounded),
            onPressed: _busy ? null : _openMenu,
          ),
      ],
      children: [...header, ...body],
    );
  }
}
