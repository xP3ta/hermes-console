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

  /// The server answered with an error: shown as "not available now".
  unavailable,

  /// Nothing confirms the server has it (404 / 405 / -32601, or no answer at
  /// all): the section is not shown.
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
    ServerHealth? knownHealth,
    Set<OpsAction> missing = const {},
  }) {
    _knownHealth = knownHealth;
    _missing.addAll(missing);
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

  /// The health the Advanced screen already read while probing: used by the
  /// first load instead of reading it twice.
  ServerHealth? _knownHealth;
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

  /// Actions the screen asked to re-attach while their paused follow was still
  /// unwinding: they re-attach as soon as that follow is gone.
  final Set<OpsAction> _reattach = {};
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

  /// A section the server has answered before (a good read) stays on screen
  /// as "not available now" when a later read fails; a section it has never
  /// answered stays absent whatever the failure (missing route, error status,
  /// auth, no answer): only a good response confirms a capability.
  bool _serverConfirmed = false;
  bool _mcpConfirmed = false;
  bool _usageConfirmed = false;

  static DiagPhase _failedPhase(
    CapabilityFailure failure, {
    required bool confirmed,
  }) => failure.kind != CapabilityFailureKind.unsupported && confirmed
      ? DiagPhase.unavailable
      : DiagPhase.hidden;

  /// Whether a section in [phase] is on screen: only after a good answer (or
  /// a later failure of an already confirmed one); never while unknown or
  /// loading.
  static bool shows(DiagPhase phase) =>
      phase == DiagPhase.ready || phase == DiagPhase.unavailable;

  Future<void> _loadServer(int generation, CapabilitiesRepository repo) async {
    serverPhase = DiagPhase.loading;
    _notify();
    ServerHealth? nextHealth = _knownHealth;
    _knownHealth = null;
    ServerIdle? nextIdle;
    var healthPhase = DiagPhase.hidden;
    var idlePhase = DiagPhase.hidden;
    if (nextHealth == null) {
      try {
        nextHealth = await repo.serverHealth();
      } on CapabilityFailure catch (failure) {
        healthPhase = _failedPhase(failure, confirmed: _serverConfirmed);
      }
    }
    try {
      nextIdle = await repo.serverIdle();
    } on CapabilityFailure catch (failure) {
      idlePhase = _failedPhase(failure, confirmed: _serverConfirmed);
    }
    if (_stale(generation)) return;
    health = nextHealth ?? health;
    idle = nextIdle;
    idleSupported = idlePhase != DiagPhase.hidden || nextIdle != null;
    serverPhase = nextHealth != null || nextIdle != null
        ? DiagPhase.ready
        : healthPhase == DiagPhase.unavailable ||
              idlePhase == DiagPhase.unavailable
        ? DiagPhase.unavailable
        : DiagPhase.hidden;
    _serverConfirmed = serverPhase != DiagPhase.hidden;
    _notify();
  }

  Future<void> _loadMcp(int generation, CapabilitiesRepository repo) async {
    mcpPhase = DiagPhase.loading;
    _notify();
    try {
      final servers = await mcpReader(repo);
      if (_stale(generation)) return;
      mcpServers = servers ?? const [];
      // No connected chat socket (none is opened to find out) is no answer:
      // the section stays absent until a real MCP response confirms it.
      mcpPhase = servers == null ? DiagPhase.hidden : DiagPhase.ready;
      if (servers != null) _mcpConfirmed = true;
    } on CapabilityFailure catch (failure) {
      if (_stale(generation)) return;
      mcpServers = const [];
      mcpPhase = _failedPhase(failure, confirmed: _mcpConfirmed);
      if (mcpPhase == DiagPhase.hidden) _mcpConfirmed = false;
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
      _usageConfirmed = true;
    } on CapabilityFailure catch (failure) {
      if (_stale(generation) || days != usageDays) return;
      usage = null;
      usagePhase = _failedPhase(failure, confirmed: _usageConfirmed);
      if (usagePhase == DiagPhase.hidden) _usageConfirmed = false;
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
      if (_reattach.remove(action) &&
          !_disposed &&
          _foreground &&
          ops(action).phase == OpsPhase.running) {
        unawaited(_follow(action, attach: true));
      }
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
        if (ops(action).phase == OpsPhase.running)
          if (_active.contains(action))
            _queueReattach(action)
          else
            _follow(action, attach: true),
    ]);
  }

  Future<void> _queueReattach(OpsAction action) {
    _reattach.add(action);
    return Future.value();
  }

  // ── Profile ─────────────────────────────────────────────────────────────

  void _onProfileChanged() {
    if (_disposed) return;
    _generation++;
    _knownHealth = null;
    _loop.updateAll((_, value) => value + 1);
    _ops.clear();
    health = null;
    idle = null;
    mcpServers = const [];
    mcpPhase = DiagPhase.idle;
    usage = null;
    usagePhase = DiagPhase.idle;
    serverPhase = DiagPhase.idle;
    _serverConfirmed = false;
    _mcpConfirmed = false;
    _usageConfirmed = false;
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
