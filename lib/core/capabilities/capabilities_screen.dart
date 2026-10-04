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
import '../services/tui_gateway_client.dart';
import '../theme/app_theme.dart';
import '../widgets/action_approval.dart';
import '../widgets/hermes_notice.dart';
import '../widgets/hermes_premium_ui.dart'
    show HermesSegment, HermesSegmentedControl;
import 'capabilities_adapters.dart';
import 'capabilities_repository.dart';
import 'capability_detail_screen.dart';
import 'capability_models.dart';
import 'capability_ui.dart';
import 'mcp_runtime_status.dart';

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
  final bool connectorsFailed;
  final bool partial;
  final bool skillsUpdatable;

  const CapabilitiesSnapshot({
    this.catalog = const [],
    this.installed = const [],
    this.mcpServers = const [],
    this.mcpRuntime = const {},
    this.connectors,
    this.connectorsFailed = false,
    this.partial = false,
    this.skillsUpdatable = false,
  });

  static Future<CapabilitiesSnapshot> load(CapabilitiesRepository repo) async {
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

    final lists = await Future.wait([
      guard(repo.installedSkills),
      guard(repo.officialSkills),
      guard(repo.pluginCatalog),
      guard(repo.installedPlugins),
      guard(repo.mcpCatalog),
      guard(repo.mcpServers),
    ]);
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
    try {
      connectors = await repo.hostedConnectors();
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

    final skills = mergeSkills(installed: lists[0], official: lists[1]);
    final plugins = _mergePlugins(catalog: lists[2], installed: lists[3]);
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
      connectorsFailed: connectorsFailed,
      partial: real.isNotEmpty,
      skillsUpdatable:
          repo.supports(CapabilityFeature.skillsUpdate) != false &&
          skills.any((s) => s.installed && s.provenance == 'hub'),
    );
  }

  static List<CapabilityItem> _mergePlugins({
    required List<CapabilityItem> catalog,
    required List<CapabilityItem> installed,
  }) {
    final byName = {for (final p in installed) p.installedName: p};
    final used = <String>{};
    final out = <CapabilityItem>[];
    for (final entry in catalog) {
      final local = byName[entry.installedName];
      if (local != null) {
        used.add(local.installedName);
        out.add(
          entry.copyWith(
            installed: true,
            enabled: local.enabled,
            canRemove: local.canRemove,
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
class CapabilitiesHub extends StatefulWidget {
  final SavedConnection connection;
  final String profile;
  final WidgetBuilder? advancedBuilder;
  final WidgetBuilder? classicSkillsBuilder;

  const CapabilitiesHub({
    super.key,
    required this.connection,
    this.profile = '',
    this.advancedBuilder,
    this.classicSkillsBuilder,
  });

  @override
  State<CapabilitiesHub> createState() => _CapabilitiesHubState();
}

class _CapabilitiesHubState extends State<CapabilitiesHub> {
  late final DashboardClient _dashboard = DashboardClient.lazy(
    widget.connection,
  );
  late final TuiGatewayClient _gateway = TuiGatewayClient(
    widget.connection,
    dashboard: _dashboard,
  );
  late final CapabilitiesRepository _repository = CapabilitiesRepository(
    rest: DashboardCapabilitiesRest(
      _dashboard,
      readOnly: widget.connection.readOnly,
    ),
    rpc: gatewayCapabilitiesRpc(_gateway),
    profile: widget.profile,
  );

  @override
  void dispose() {
    unawaited(_gateway.close());
    _dashboard.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CapabilitiesScreen(
    repository: _repository,
    readOnly: widget.connection.readOnly,
    instanceId: widget.connection.id,
    advancedBuilder: widget.advancedBuilder,
    classicSkillsBuilder: widget.classicSkillsBuilder,
  );
}

class CapabilitiesScreen extends StatefulWidget {
  final CapabilitiesRepository repository;
  final bool readOnly;
  final String instanceId;
  final WidgetBuilder? advancedBuilder;
  final WidgetBuilder? classicSkillsBuilder;
  final CapabilitiesSegment initialSegment;
  final Duration searchDebounce;

  const CapabilitiesScreen({
    super.key,
    required this.repository,
    this.readOnly = false,
    this.instanceId = '',
    this.advancedBuilder,
    this.classicSkillsBuilder,
    this.initialSegment = CapabilitiesSegment.catalog,
    this.searchDebounce = const Duration(milliseconds: 450),
  });

  @override
  State<CapabilitiesScreen> createState() => _CapabilitiesScreenState();
}

enum _MenuAction { updateSkills, advanced, classicSkills }

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

  CapabilitiesRepository get _repo => widget.repository;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = _snapshot == null;
      _error = null;
    });
    try {
      final snapshot = await CapabilitiesSnapshot.load(_repo);
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
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
        if (widget.classicSkillsBuilder != null)
          HermesAction(
            key: const ValueKey('cph-menu-classic'),
            value: _MenuAction.classicSkills,
            label: s.cphMenuClassicSkills,
            icon: Icons.auto_awesome_outlined,
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
        if (mounted) unawaited(_load());
      case _MenuAction.classicSkills:
        await Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: widget.classicSkillsBuilder!));
        if (mounted) unawaited(_load());
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
    final notices = HermesNotice.of(context);
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
      notices.show(
        message: s.cphDoneSkillsUpdated,
        kind: HermesNoticeKind.success,
      );
      unawaited(_load());
    } catch (error) {
      if (!mounted) return;
      notices.show(
        message: capabilityFailureMessage(s, error),
        kind: HermesNoticeKind.error,
      );
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
          onChanged: () => changed = true,
        ),
      ),
    );
    if (changed && mounted) unawaited(_load());
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
      if (items.isEmpty && hub.isEmpty)
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
            // Read-only rows: connecting accounts is not wired in Console
            // yet, so the rows carry state but no tap affordance.
            for (final connector in accounts)
              HermesListRow(
                key: ValueKey('cph-account-${connector.slug}'),
                icon: Icons.account_circle_outlined,
                title: connector.name,
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
            child: CircularProgressIndicator(key: ValueKey('cph-loading')),
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
        CapabilitiesSegment.connectors => _connectorsSection(snapshot),
      };
    }

    final hasMenu =
        widget.advancedBuilder != null ||
        widget.classicSkillsBuilder != null ||
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
