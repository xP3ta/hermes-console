import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../capabilities/capabilities_adapters.dart';
import '../capabilities/capabilities_repository.dart';
import '../capabilities/server_diagnostics_models.dart';
import '../capabilities/server_diagnostics_probe.dart';
import '../design/page.dart';
import '../models/server_toolset.dart';
import '../services/active_profile_scope.dart';
import '../services/connection_manager.dart';
import '../services/server_config_repository.dart';
import '../services/server_toolsets_repository.dart';
import '../settings/server_config_labels.dart';
import '../settings/server_config_pages.dart';
import '../settings/settings_deep_link.dart';
import '../settings/settings_search.dart';
import '../widgets/hermes_pill.dart';
import '../widgets/hermes_premium_ui.dart' show HermesSearchField;
import '../widgets/hermes_ui.dart';
import 'server_config_page_screen.dart';
import 'server_diagnostics_screen.dart';
import 'server_toolsets_screen.dart';

/// Settings › Advanced: the server settings Desktop keeps on its
/// configuration pages, out of the main Settings list.
///
/// Opening it reads the config schema (unless the Settings entry already did)
/// and the toolsets list, once each, to know which pages exist. The search at
/// the top works on what is loaded; typing never touches the network.
///
/// It also holds the read-only Diagnostics entry: three cheap routes are read
/// when Advanced opens to decide whether Diagnostics exists on this server;
/// nothing of it is read when Settings opens and nothing is launched.
class AdvancedSettingsScreen extends StatefulWidget {
  final SavedConnection connection;
  final ConnectionManager connManager;

  /// The schema the Settings entry already read for the active profile.
  final Map<String, dynamic>? initialSchema;

  @visibleForTesting
  final ServerConfigStoreFactory? storeFor;

  @visibleForTesting
  final ServerToolsetsFactory? toolsetsFor;

  /// Diagnostics repository for a profile; the default talks to the Dashboard.
  @visibleForTesting
  final CapabilitiesRepository Function(String profile)? repositoryFor;

  /// Reader of the live MCP state, handed to Diagnostics.
  @visibleForTesting
  final Future<List<McpServerStatus>?> Function(CapabilitiesRepository repo)?
  mcpReader;

  const AdvancedSettingsScreen({
    super.key,
    required this.connection,
    required this.connManager,
    this.initialSchema,
    this.storeFor,
    this.toolsetsFor,
    this.repositoryFor,
    this.mcpReader,
  });

  @override
  State<AdvancedSettingsScreen> createState() => _AdvancedSettingsScreenState();
}

class _AdvancedSettingsScreenState extends State<AdvancedSettingsScreen> {
  DashboardClient? _client;
  late final ActiveProfileScope _scope = ActiveProfileScope.of(
    widget.connManager,
    widget.connection.id,
  );
  final TextEditingController _query = TextEditingController();

  Map<String, dynamic>? _schema;
  List<ServerToolset> _toolsets = const [];
  ServerConfigFailureKind? _failure;
  bool _loading = true;
  Map<String, dynamic>? _seed;
  List<SettingsSearchEntry> _index = const [];
  DiagnosticsAvailability? _availability;
  bool _probing = true;

  bool get _readOnly =>
      widget.connection.readOnly ||
      widget.connManager.loadCapabilities(widget.connection.id).configWrite ==
          CapState.no;

  @override
  void initState() {
    super.initState();
    _seed = widget.initialSchema;
    _scope.addListener(_onProfileChanged);
    unawaited(_load());
    unawaited(_probeDiagnostics());
  }

  @override
  void dispose() {
    _scope.removeListener(_onProfileChanged);
    _query.dispose();
    _client?.close();
    super.dispose();
  }

  void _onProfileChanged() {
    // The schema handed in belonged to the previous profile.
    _seed = null;
    setState(() {
      _schema = null;
      _toolsets = const [];
      _failure = null;
      _loading = true;
      _index = const [];
      _availability = null;
      _probing = true;
    });
    unawaited(_load());
    unawaited(_probeDiagnostics());
  }

  CapabilitiesRepository _diagnosticsRepoFor(String profile) {
    final custom = widget.repositoryFor;
    if (custom != null) return custom(profile);
    final client = _client ??= DashboardClient.lazy(widget.connection);
    return CapabilitiesRepository(
      rest: DashboardCapabilitiesRest(
        client,
        readOnly: widget.connection.readOnly,
      ),
      profile: profile,
    );
  }

  Future<void> _probeDiagnostics() async {
    final ticket = _scope.capture();
    final result = await probeDiagnostics(_diagnosticsRepoFor(ticket.name));
    // A late answer of another profile is not this screen's.
    if (!mounted || !ticket.isCurrent) return;
    setState(() {
      _availability = result;
      _probing = false;
    });
  }

  Future<void> _load() async {
    final ticket = _scope.capture();
    final writable = !_readOnly;
    final client = _client ??= DashboardClient.lazy(widget.connection);
    final store =
        widget.storeFor?.call(ticket.name, writable: writable) ??
        ServerConfigRepository(
          client,
          profile: ticket.name,
          writable: writable,
        );
    final toolsets =
        widget.toolsetsFor?.call(ticket.name, writable: writable) ??
        ServerToolsetsRepository(
          client,
          profile: ticket.name,
          writable: writable,
        );
    Map<String, dynamic>? schema = _seed;
    ServerConfigFailureKind? failure;
    // Advanced is reachable without a schema (it also holds Diagnostics):
    // a connection whose config reads are denied is never asked for one.
    if (schema == null &&
        widget.connManager.loadCapabilities(widget.connection.id).configRead ==
            CapState.no) {
      failure = ServerConfigFailureKind.permissionDenied;
    }
    var tools = const <ServerToolset>[];
    await Future.wait([
      () async {
        if (schema != null || failure != null) return;
        try {
          schema = await store.readSchema();
        } on ServerConfigException catch (error) {
          failure = error.kind;
        }
      }(),
      () async {
        try {
          tools = await toolsets.list();
        } on ServerConfigException {
          tools = const [];
        }
      }(),
    ]);
    if (!mounted || !ticket.isCurrent) return;
    final loaded = schema;
    setState(() {
      _schema = loaded;
      _toolsets = tools;
      _failure = failure;
      _loading = false;
      _index = loaded == null
          ? const []
          : buildSettingsSearchIndex(
              s: Strings.of(context),
              schema: loaded,
              toolsets: tools,
            );
    });
  }

  Future<void> _refresh() async {
    _seed = null;
    setState(() {
      _loading = true;
      _probing = true;
    });
    await Future.wait([_load(), _probeDiagnostics()]);
  }

  void _openPage(ServerConfigPage page, {String? highlight}) {
    final schema = _schema;
    if (schema == null) return;
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => ServerConfigPageScreen(
          connection: widget.connection,
          connManager: widget.connManager,
          page: page,
          schema: schema,
          highlightPath: highlight,
          storeFor: widget.storeFor,
        ),
      ),
    );
  }

  void _openTools() => Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => ServerToolsetsScreen(
        connection: widget.connection,
        connManager: widget.connManager,
        toolsetsFor: widget.toolsetsFor,
      ),
    ),
  );

  void _open(SettingsSearchEntry hit) {
    switch (hit.kind) {
      case SettingsSearchKind.page:
        _openPage(hit.page!);
      case SettingsSearchKind.field:
        _openPage(hit.page!, highlight: hit.path);
      case SettingsSearchKind.tools:
      case SettingsSearchKind.toolset:
        _openTools();
      case SettingsSearchKind.settingsSection:
        SettingsDeepLink.request(hit.settingsSection!);
        Navigator.of(context).pop();
    }
  }

  Key _hitKey(SettingsSearchEntry hit) => ValueKey(switch (hit.kind) {
    SettingsSearchKind.page => 'adv1215-hit-page-${hit.page!.name}',
    SettingsSearchKind.field => 'adv1215-hit-${hit.path}',
    SettingsSearchKind.tools => 'adv1215-hit-tools',
    SettingsSearchKind.toolset => 'adv1215-hit-toolset-${hit.toolset}',
    SettingsSearchKind.settingsSection =>
      'adv1215-hit-section-${hit.settingsSection!.name}',
  });

  static IconData _pageIcon(ServerConfigPage page) => switch (page) {
    ServerConfigPage.main => Icons.auto_awesome_outlined,
    ServerConfigPage.behavior => Icons.chat_bubble_outline,
    ServerConfigPage.projects => Icons.folder_outlined,
    ServerConfigPage.shell => Icons.terminal,
    ServerConfigPage.files => Icons.description_outlined,
    ServerConfigPage.network => Icons.public,
    ServerConfigPage.context => Icons.compress,
    ServerConfigPage.conversation => Icons.record_voice_over_outlined,
    ServerConfigPage.runtime => Icons.speed,
  };

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final schema = _schema;
    final children = <Widget>[];
    if (_loading) {
      children.add(
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Center(child: TuiLoader()),
        ),
      );
    } else if (schema == null) {
      children.add(
        HermesInfoBanner(switch (_failure) {
          ServerConfigFailureKind.authentication ||
          ServerConfigFailureKind.permissionDenied => s.adv1215LoadDenied,
          ServerConfigFailureKind.unsupported => s.adv1215Unreadable,
          _ => s.adv1215LoadFailed,
        }),
      );
    } else {
      final pages = serverConfigPagesWithFields(schema);
      if (pages.isEmpty && _toolsets.isEmpty) {
        children.add(HermesInfoBanner(s.adv1215Unreadable));
      } else {
        children.add(
          HermesSearchField(
            controller: _query,
            hintText: s.adv1215SearchHint,
            clearTooltip: s.adv1215SearchClear,
            onChanged: (_) => setState(() {}),
          ),
        );
        children.add(const SizedBox(height: 12));
        final text = _query.text;
        if (text.trim().isNotEmpty) {
          final hits = searchSettings(_index, text);
          children.add(
            hits.isEmpty
                ? HermesInfoBanner(s.adv1215SearchEmpty)
                : HermesGroup(
                    children: [
                      for (final hit in hits)
                        HermesNavRow(
                          key: _hitKey(hit),
                          icon: switch (hit.kind) {
                            SettingsSearchKind.settingsSection =>
                              Icons.settings_outlined,
                            SettingsSearchKind.tools ||
                            SettingsSearchKind.toolset => Icons.build_outlined,
                            _ => _pageIcon(hit.page!),
                          },
                          title: hit.title,
                          subtitle: hit.subtitle,
                          onTap: () => _open(hit),
                        ),
                    ],
                  ),
          );
        } else {
          children.add(
            HermesGroup(
              children: [
                for (final page in pages)
                  HermesNavRow(
                    key: ValueKey('adv1215-page-${page.name}'),
                    icon: _pageIcon(page),
                    title: serverConfigPageTitle(s, page),
                    subtitle: serverConfigPageSubtitle(s, page),
                    onTap: () => _openPage(page),
                  ),
                if (_toolsets.isNotEmpty)
                  HermesNavRow(
                    key: const ValueKey('adv1215-page-tools'),
                    icon: Icons.build_outlined,
                    title: s.drawerTools,
                    subtitle: s.adv1215SubTools,
                    onTap: _openTools,
                  ),
              ],
            ),
          );
        }
      }
    }
    final configEmpty =
        schema == null ||
        (serverConfigPagesWithFields(schema).isEmpty && _toolsets.isEmpty);
    final searching = schema != null && _query.text.trim().isNotEmpty;
    final availability = _availability;
    if (!_loading && _probing) {
      children.add(
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Center(child: TuiLoader()),
        ),
      );
    } else if (!_probing && availability != null && availability.any) {
      if (!searching) {
        children.add(const SizedBox(height: 12));
        children.add(
          HermesGroup(
            children: [
              HermesNavRow(
                icon: Icons.monitor_heart_outlined,
                title: s.sd1215Diagnostics,
                subtitle: s.sd1215DiagnosticsSub,
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => ServerDiagnosticsScreen(
                      connection: widget.connection,
                      connManager: widget.connManager,
                      availability: availability,
                      repositoryFor: widget.repositoryFor,
                      mcpReader: widget.mcpReader,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      }
    } else if (!_probing && !_loading && configEmpty) {
      children.add(const SizedBox(height: 12));
      children.add(HermesInfoBanner(s.sd1215NothingToShow));
    }
    return HermesPage(
      title: s.drawerAdvanced,
      onRefresh: _refresh,
      children: children,
    );
  }
}
