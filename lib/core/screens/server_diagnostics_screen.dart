import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../../main.dart' show hermesRouteObserver;
import '../capabilities/capabilities_adapters.dart';
import '../capabilities/capabilities_repository.dart';
import '../capabilities/server_diagnostics_controller.dart';
import '../capabilities/server_diagnostics_models.dart';
import '../capabilities/server_diagnostics_scope.dart';
import '../capabilities/server_diagnostics_probe.dart';
import '../design/page.dart';
import '../services/active_profile_scope.dart';
import '../services/connection_manager.dart';
import '../services/shared_gateway_pool.dart';
import '../theme/app_theme.dart';
import '../widgets/hermes_notice.dart';
import '../widgets/hermes_pill.dart';
import '../widgets/hermes_premium_ui.dart';
import '../widgets/hermes_ui.dart';

/// Settings › Advanced › Diagnostics: the server's state, read-only.
///
/// Doctor and the security audit, the live MCP state, the server version and
/// busy state, and usage. Every section exists only if the server has it. The
/// output of doctor and the audit is the server's own text: it is shown, and
/// copied only when the user taps Copy; it is never logged or kept.
class ServerDiagnosticsScreen extends StatefulWidget {
  final SavedConnection connection;
  final ConnectionManager connManager;

  /// What Advanced already learnt about the server, so nothing is probed twice.
  final DiagnosticsAvailability? availability;

  @visibleForTesting
  final CapabilitiesRepository Function(String profile)? repositoryFor;

  /// Replaces the Dashboard transport only (the launch scope stays real).
  @visibleForTesting
  final CapabilitiesRest Function(SavedConnection connection)? restFor;

  /// Reads the live MCP state; null when no chat socket is connected.
  @visibleForTesting
  final Future<List<McpServerStatus>?> Function(CapabilitiesRepository repo)?
  mcpReader;

  const ServerDiagnosticsScreen({
    super.key,
    required this.connection,
    required this.connManager,
    this.availability,
    this.repositoryFor,
    this.restFor,
    this.mcpReader,
  });

  @override
  State<ServerDiagnosticsScreen> createState() =>
      _ServerDiagnosticsScreenState();
}

class _ServerDiagnosticsScreenState extends State<ServerDiagnosticsScreen>
    with WidgetsBindingObserver, RouteAware {
  DashboardClient? _client;
  late final ServerDiagnosticsController _controller;
  PageRoute<dynamic>? _route;

  CapabilitiesRepository _repoFor(String profile) {
    final custom = widget.repositoryFor;
    if (custom != null) return custom(profile);
    final restFor = widget.restFor;
    return CapabilitiesRepository(
      rest: restFor != null
          ? restFor(widget.connection)
          : DashboardCapabilitiesRest(
              _client ??= DashboardClient.lazy(widget.connection),
              readOnly: widget.connection.readOnly,
            ),
      profile: profile,
      // Every Diagnostics screen that reaches this Dashboard and profile, from
      // whichever saved connection, shares one launch order for doctor and the
      // audit.
      launchScope: diagnosticsLaunchScope(widget.connection, profile),
    );
  }

  /// The live MCP state over the shared gateway socket, only if one is already
  /// connected: none is opened to find out.
  Future<List<McpServerStatus>?> _readMcp(CapabilitiesRepository repo) async {
    final custom = widget.mcpReader;
    if (custom != null) return custom(repo);
    final lease = SharedGatewayPool.instance.acquireIfConnected(
      widget.connection,
    );
    if (lease == null) return null;
    try {
      return await repo.mcpLiveStatus(gatewayCapabilitiesRpc(lease.client));
    } finally {
      lease.release();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final connection = widget.connection;
    final dashboardHost = Uri.tryParse(connection.effectiveDashboardUrl)?.host;
    _controller = ServerDiagnosticsController(
      scope: ActiveProfileScope.of(widget.connManager, connection.id),
      repoFor: _repoFor,
      mcpReader: _readMcp,
      restartHosts: [
        connection.host,
        if (dashboardHost != null && dashboardHost.isNotEmpty) dashboardHost,
      ],
      knownHealth: widget.availability?.health,
      missing: widget.availability?.missing ?? const {},
    );
    unawaited(_controller.load());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute<dynamic> && !identical(route, _route)) {
      hermesRouteObserver.unsubscribe(this);
      _route = route;
      hermesRouteObserver.subscribe(this, route);
    }
  }

  @override
  void didPushNext() => _controller.pause();

  @override
  void didPopNext() => unawaited(_controller.resume());

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_controller.resume());
    } else {
      _controller.pause();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    hermesRouteObserver.unsubscribe(this);
    _controller.dispose();
    _client?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final c = _controller;
        final showServer = ServerDiagnosticsController.shows(c.serverPhase);
        final showMcp = ServerDiagnosticsController.shows(c.mcpPhase);
        final showUsage = ServerDiagnosticsController.shows(c.usagePhase);
        final anyShown =
            showServer ||
            c.doctorAvailable ||
            c.auditAvailable ||
            showMcp ||
            showUsage;
        // Sections the server has not confirmed are not on screen; while
        // nothing is confirmed yet there is only one loader for the page.
        final waiting = const {
          DiagPhase.idle,
          DiagPhase.loading,
        }.any({c.serverPhase, c.mcpPhase, c.usagePhase}.contains);
        final nothing = !anyShown && !waiting;
        final note = c.restartNote;
        return HermesPage(
          title: s.sd1215Diagnostics,
          onRefresh: c.refresh,
          children: [
            if (nothing) HermesInfoBanner(s.sd1215NothingToShow),
            if (!anyShown && waiting)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: TuiLoader()),
              ),
            if (note != null) ...[
              HermesInfoBanner(
                s.sd1215RestartRequired,
                icon: Icons.restart_alt_rounded,
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
                child: Text(
                  note,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).hermes.textSecondary,
                  ),
                ),
              ),
            ],
            if (showServer) ..._serverSection(s, c),
            if (c.doctorAvailable)
              ..._opsSection(s, c, OpsAction.doctor, s.sd1215Doctor, 'doctor'),
            if (c.auditAvailable)
              ..._opsSection(
                s,
                c,
                OpsAction.securityAudit,
                s.sd1215Audit,
                'audit',
              ),
            if (showMcp) ..._mcpSection(s, c),
            if (showUsage) ..._usageSection(s, c),
          ],
        );
      },
    );
  }

  // ── Server ──────────────────────────────────────────────────────────────

  Widget _row(BuildContext context, String label, String value, {Key? key}) {
    final colors = Theme.of(context).hermes;
    return Padding(
      key: key,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(fontSize: 14, color: colors.textPrimary),
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: TextStyle(fontSize: 14, color: colors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _note(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 13,
        color: Theme.of(context).hermes.textSecondary,
      ),
    ),
  );

  List<Widget> _serverSection(Strings s, ServerDiagnosticsController c) {
    final health = c.health;
    final idle = c.idle;
    return [
      HermesSectionHeader(s.sd1215Server),
      HermesGroup(
        children: [
          if (c.serverPhase == DiagPhase.loading && health == null)
            const Padding(padding: EdgeInsets.all(16), child: TuiLoader())
          else if (c.serverPhase == DiagPhase.unavailable)
            _note(context, s.sd1215Unavailable)
          else ...[
            if (health != null)
              _row(
                context,
                s.sd1215ServerVersion,
                health.displayVersion.isEmpty ? '—' : health.displayVersion,
              ),
            if (c.idleSupported)
              _row(context, s.sd1215ServerState, switch (idle?.idle) {
                true => s.sd1215ServerFree,
                false => s.sd1215ServerBusy,
                null => s.sd1215ServerUnknown,
              }),
          ],
        ],
      ),
    ];
  }

  // ── Doctor and audit ────────────────────────────────────────────────────

  List<Widget> _opsSection(
    Strings s,
    ServerDiagnosticsController c,
    OpsAction action,
    String title,
    String key,
  ) {
    final view = c.ops(action);
    final colors = Theme.of(context).hermes;
    final running = view.phase == OpsPhase.running;
    final result = switch (view.phase) {
      OpsPhase.running => s.sd1215Running,
      OpsPhase.finished =>
        view.exitCode == 0
            ? s.sd1215NoIssues
            : s.sd1215ExitWarnings(view.exitCode ?? -1),
      OpsPhase.failed => s.sd1215RunFailed,
      OpsPhase.idle => null,
    };
    return [
      HermesSectionHeader(title),
      HermesGroup(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    result ?? '',
                    style: TextStyle(
                      fontSize: 13,
                      color: view.phase == OpsPhase.failed
                          ? colors.error
                          : colors.textSecondary,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                HermesSecondaryButton(
                  key: ValueKey('sd1215-run-$key'),
                  label: s.sd1215Run,
                  onTap: running || widget.connection.readOnly
                      ? null
                      : () => unawaited(c.runOps(action)),
                ),
              ],
            ),
          ),
          if (view.lines.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _OutputBlock(lines: view.lines),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: HermesSecondaryButton(
                      key: ValueKey('sd1215-copy-$key'),
                      label: s.sd1215CopyOutput,
                      icon: Icons.copy_rounded,
                      onTap: () => unawaited(_copy(view.lines.join('\n'))),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    ];
  }

  Future<void> _copy(String text) async {
    final notices = HermesNotice.of(context);
    final copied = Strings.of(context).sd1215Copied;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    notices.showSnackBar(
      SnackBar(content: Text(copied)),
      kind: HermesNoticeKind.success,
    );
  }

  // ── MCP ─────────────────────────────────────────────────────────────────

  String _mcpState(Strings s, McpServerState state) => switch (state) {
    McpServerState.connected => s.sd1215McpConnected,
    McpServerState.disabled => s.sd1215McpDisabled,
    McpServerState.connecting => s.sd1215McpConnecting,
    McpServerState.failed => s.sd1215McpFailed,
    McpServerState.lazy => s.sd1215McpLazy,
    McpServerState.configured => s.sd1215McpConfigured,
    McpServerState.unknown => s.sd1215McpUnknown,
  };

  List<Widget> _mcpSection(Strings s, ServerDiagnosticsController c) {
    final colors = Theme.of(context).hermes;
    return [
      HermesSectionHeader(s.sd1215Mcp),
      HermesGroup(
        children: [
          if (c.mcpPhase == DiagPhase.loading)
            const Padding(padding: EdgeInsets.all(16), child: TuiLoader())
          else if (c.mcpPhase == DiagPhase.unavailable)
            _note(context, s.sd1215Unavailable)
          else if (c.mcpServers.isEmpty)
            _note(context, s.sd1215McpNone)
          else
            for (final server in c.mcpServers)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      server.name,
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                        color: colors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [
                        _mcpState(s, server.state),
                        s.sd1215McpTools(server.tools),
                        switch (server.source) {
                          McpServerSource.plugin =>
                            server.plugin == null
                                ? null
                                : s.sd1215McpFromPlugin(server.plugin!),
                          McpServerSource.config => s.sd1215McpFromConfig,
                          null => null,
                        },
                      ].whereType<String>().join(' · '),
                      style: TextStyle(
                        fontSize: 12,
                        color: server.state == McpServerState.failed
                            ? colors.error
                            : colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
        ],
      ),
    ];
  }

  // ── Usage ───────────────────────────────────────────────────────────────

  String _money(double value) => '\$${value.toStringAsFixed(2)}';

  List<Widget> _usageSection(Strings s, ServerDiagnosticsController c) {
    final usage = c.usage;
    final colors = Theme.of(context).hermes;
    return [
      HermesSectionHeader(s.sd1215Usage),
      HermesSegmentedControl<int>(
        value: c.usageDays,
        onChanged: (days) => unawaited(c.setUsageDays(days)),
        segments: [
          HermesSegment(value: 7, label: s.sd1215Days7),
          HermesSegment(value: 30, label: s.sd1215Days30),
          HermesSegment(value: 90, label: s.sd1215Days90),
        ],
      ),
      const SizedBox(height: 12),
      HermesGroup(
        children: [
          if (c.usagePhase == DiagPhase.loading && usage == null)
            const Padding(padding: EdgeInsets.all(16), child: TuiLoader())
          else if (c.usagePhase == DiagPhase.unavailable || usage == null)
            _note(context, s.sd1215HistoryUnavailable)
          else ...[
            _row(context, s.sd1215UsageInput, '${usage.totals.input}'),
            _row(context, s.sd1215UsageOutput, '${usage.totals.output}'),
            _row(context, s.sd1215UsageCache, '${usage.totals.cacheRead}'),
            _row(context, s.sd1215UsageReasoning, '${usage.totals.reasoning}'),
            _row(
              context,
              s.sd1215UsageEstimated,
              _money(usage.totals.estimatedCost),
            ),
            _row(context, s.sd1215UsageActual, _money(usage.totals.actualCost)),
            _row(context, s.sd1215UsageSessions, '${usage.totals.sessions}'),
            _row(context, s.sd1215UsageCalls, '${usage.totals.apiCalls}'),
          ],
        ],
      ),
      if (usage != null && usage.byModel.isNotEmpty) ...[
        HermesSectionHeader(s.sd1215UsageByModel),
        HermesGroup(
          children: [
            for (final model in usage.byModel)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      model.model,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: colors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${model.input} / ${model.output} · '
                      '${_money(model.estimatedCost)} · '
                      '${model.sessions}',
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ],
      if (usage != null && usage.daily.isNotEmpty) ...[
        HermesSectionHeader(s.sd1215UsageDaily),
        HermesGroup(
          children: [
            for (final day in usage.daily)
              _row(
                context,
                day.day,
                '${day.input} / ${day.output} · ${_money(day.estimatedCost)}',
              ),
          ],
        ),
      ],
    ];
  }
}

/// The server's own text, monospace and read-only (Text, not SelectableText:
/// it is replaced while a run streams).
class _OutputBlock extends StatelessWidget {
  final List<String> lines;
  const _OutputBlock({required this.lines});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 260),
      decoration: BoxDecoration(
        color: colors.background.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.divider.withValues(alpha: 0.55)),
      ),
      padding: const EdgeInsets.all(10),
      child: SingleChildScrollView(
        reverse: true,
        child: Text(
          lines.join('\n'),
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 12,
            height: 1.4,
            color: colors.textSecondary,
          ),
        ),
      ),
    );
  }
}
