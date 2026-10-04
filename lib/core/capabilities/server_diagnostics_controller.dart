// Controller of the read-only Diagnostics screen.
//
// Reads once per section when the screen opens and on a manual refresh; doctor
// and the security audit only run after a tap and are followed only while the
// screen is on show; late answers of another profile, or after dispose, are
// dropped. Nothing is persisted or sent anywhere.
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../services/active_profile_scope.dart';
import '../services/server_restart_signal.dart';
import 'capabilities_repository.dart';
import 'capability_models.dart';
import 'server_diagnostics_models.dart';

/// State of one section of the screen.
enum DiagPhase {
  idle,
  loading,
  ready,

  /// MCP only: no chat socket is connected, and none is opened to find out.
  noSocket,

  /// The server answered with an error: shown as "not available now".
  unavailable,

  /// The server does not have it (404 / 405 / -32601): the section is hidden.
  hidden,
}

enum OpsPhase { idle, running, finished, failed }

/// What the screen shows for doctor or the audit.
final class OpsView {
  final OpsPhase phase;

  /// Output after the last `=== <name> started` marker.
  final List<String> lines;
  final int? exitCode;
  final CapabilityFailureKind? failure;

  const OpsView({
    this.phase = OpsPhase.idle,
    this.lines = const [],
    this.exitCode,
    this.failure,
  });
}

class ServerDiagnosticsController extends ChangeNotifier {
  ServerDiagnosticsController({
    required this.scope,
    required this.repoFor,
    required this.mcpReader,
    required this.restartHosts,
  }) {
    _repo = repoFor(scope.name);
    scope.addListener(_onProfileChanged);
  }

  final ActiveProfileScope scope;

  /// Repository bound to a profile (empty name = default).
  final CapabilitiesRepository Function(String profile) repoFor;

  /// Reads the live MCP state over an already connected gateway socket, or
  /// returns null when there is none (it must not open one).
  final Future<List<McpServerStatus>?> Function(CapabilitiesRepository repo)
  mcpReader;

  /// Hosts the passive "restart required" note may be filed under.
  final List<String> restartHosts;

  late CapabilitiesRepository _repo;
  bool _disposed = false;
  bool _foreground = true;

  /// Bumped on every profile switch: answers of an older one are dropped.
  int _generation = 0;

  // Server.
  DiagPhase serverPhase = DiagPhase.idle;
  ServerHealth? health;
  ServerIdle? idle;
  bool idleSupported = true;

  // MCP.
  DiagPhase mcpPhase = DiagPhase.idle;
  List<McpServerStatus> mcpServers = const [];

  // Usage.
  DiagPhase usagePhase = DiagPhase.idle;
  UsageAnalytics? usage;
  int usageDays = 30;

  // Doctor and audit.
  final Map<OpsAction, OpsView> _ops = {};
  final Map<OpsAction, int> _loop = {};
  final Set<OpsAction> _active = {};
  final Set<OpsAction> _missing = {};

  bool get doctorAvailable => !_missing.contains(OpsAction.doctor);
  bool get auditAvailable => !_missing.contains(OpsAction.securityAudit);

  OpsView ops(OpsAction action) => _ops[action] ?? const OpsView();

  /// The passive note that the server needs a restart after an update.
  String? get restartNote => ServerRestartSignals.textFor(restartHosts);

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  bool _stale(int generation) => _disposed || generation != _generation;

  // ── Reads ───────────────────────────────────────────────────────────────

  /// Opens the screen: one read per section.
  Future<void> load() => refresh();

  /// Manual refresh: one read per section again.
  Future<void> refresh() {
    final generation = _generation;
    final repo = _repo;
    return Future.wait([
      _loadServer(generation, repo),
      _loadMcp(generation, repo),
      _loadUsage(generation, repo),
    ]);
  }

  Future<void> _loadServer(int generation, CapabilitiesRepository repo) async {
    serverPhase = DiagPhase.loading;
    _notify();
    ServerHealth? nextHealth;
    ServerIdle? nextIdle;
    var healthMissing = false;
    var idleMissing = false;
    try {
      nextHealth = await repo.serverHealth();
    } on CapabilityFailure catch (failure) {
      healthMissing = failure.kind == CapabilityFailureKind.unsupported;
    }
    try {
      nextIdle = await repo.serverIdle();
    } on CapabilityFailure catch (failure) {
      idleMissing = failure.kind == CapabilityFailureKind.unsupported;
    }
    if (_stale(generation)) return;
    health = nextHealth ?? health;
    idle = nextIdle;
    idleSupported = !idleMissing;
    serverPhase = nextHealth != null || nextIdle != null
        ? DiagPhase.ready
        : healthMissing && idleMissing
        ? DiagPhase.hidden
        : DiagPhase.unavailable;
    _notify();
  }

  Future<void> _loadMcp(int generation, CapabilitiesRepository repo) async {
    mcpPhase = DiagPhase.loading;
    _notify();
    try {
      final servers = await mcpReader(repo);
      if (_stale(generation)) return;
      mcpServers = servers ?? const [];
      mcpPhase = servers == null ? DiagPhase.noSocket : DiagPhase.ready;
    } on CapabilityFailure catch (failure) {
      if (_stale(generation)) return;
      mcpServers = const [];
      mcpPhase = failure.kind == CapabilityFailureKind.unsupported
          ? DiagPhase.hidden
          : DiagPhase.unavailable;
    }
    _notify();
  }

  Future<void> _loadUsage(int generation, CapabilitiesRepository repo) async {
    usagePhase = DiagPhase.loading;
    _notify();
    final days = usageDays;
    try {
      final result = await repo.usage(days);
      if (_stale(generation) || days != usageDays) return;
      usage = result;
      usagePhase = DiagPhase.ready;
    } on CapabilityFailure catch (failure) {
      if (_stale(generation) || days != usageDays) return;
      usage = null;
      usagePhase = failure.kind == CapabilityFailureKind.unsupported
          ? DiagPhase.hidden
          : DiagPhase.unavailable;
    }
    _notify();
  }

  /// Usage for another preset: exactly one request.
  Future<void> setUsageDays(int days) async {
    if (!UsageAnalytics.presets.contains(days) || days == usageDays) return;
    usageDays = days;
    await _loadUsage(_generation, _repo);
  }

  // ── Doctor and audit ────────────────────────────────────────────────────

  /// Runs [action] (or attaches to a run in progress) and follows it. A second
  /// tap while it is followed does nothing.
  Future<void> runOps(OpsAction action) => _follow(action, attach: false);

  Future<void> _follow(OpsAction action, {required bool attach}) async {
    if (_active.contains(action) || _disposed) return;
    _active.add(action);
    final generation = _generation;
    final loop = _loop[action] = (_loop[action] ?? 0) + 1;
    final repo = _repo;
    bool shouldStop() =>
        _stale(generation) || !_foreground || _loop[action] != loop;
    void show(OpsView view) {
      if (_stale(generation) || _loop[action] != loop) return;
      _ops[action] = view;
      _notify();
    }

    show(OpsView(phase: OpsPhase.running, lines: ops(action).lines));
    try {
      void onProgress(CapabilityActionStatus status) => show(
        OpsView(
          phase: status.running ? OpsPhase.running : OpsPhase.finished,
          lines: opsActionOutput(action.actionName, status.lines),
          exitCode: status.running ? null : status.exitCode,
        ),
      );
      final result = attach
          ? await repo.attachOps(
              action,
              onProgress: onProgress,
              shouldStop: shouldStop,
            )
          : await repo.runOps(
              action,
              onProgress: onProgress,
              shouldStop: shouldStop,
            );
      if (result != null) onProgress(result);
    } on CapabilityFailure catch (failure) {
      if (failure.kind == CapabilityFailureKind.unsupported) {
        _missing.add(action);
        show(const OpsView());
      } else {
        show(
          OpsView(
            phase: OpsPhase.failed,
            lines: ops(action).lines,
            failure: failure.kind,
          ),
        );
      }
    } finally {
      _active.remove(action);
    }
  }

  /// The screen is hidden (another route, or the app in the background): the
  /// follow loops end at their next check. The server process keeps running.
  void pause() {
    _foreground = false;
  }

  /// The screen is back: runs the user had started and not seen finish
  /// re-attach by reading the state. Nothing is relaunched.
  Future<void> resume() {
    _foreground = true;
    return Future.wait([
      for (final action in OpsAction.values)
        if (ops(action).phase == OpsPhase.running && !_active.contains(action))
          _follow(action, attach: true),
    ]);
  }

  // ── Profile ─────────────────────────────────────────────────────────────

  void _onProfileChanged() {
    if (_disposed) return;
    _generation++;
    _loop.updateAll((_, value) => value + 1);
    _ops.clear();
    health = null;
    idle = null;
    mcpServers = const [];
    mcpPhase = DiagPhase.idle;
    usage = null;
    usagePhase = DiagPhase.idle;
    serverPhase = DiagPhase.idle;
    _repo = repoFor(scope.name);
    _notify();
    unawaited(load());
  }

  @override
  void dispose() {
    _disposed = true;
    scope.removeListener(_onProfileChanged);
    super.dispose();
  }
}
