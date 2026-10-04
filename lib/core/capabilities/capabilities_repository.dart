// Capabilities hub — one repository over the profile's own backend.
//
// Endpoints are the ones Hermes Desktop's Capabilities area calls:
//   skills   GET /api/skills · PUT /api/skills/toggle
//            GET /api/skills/hub/{official,sources,search}
//            POST /api/skills/hub/{install,uninstall,update}
//            GET /api/actions/{name}/status        (background action poll)
//   plugins  GET /api/dashboard/plugins/{catalog,hub}
//            POST /api/dashboard/agent-plugins/install · …/{n}/{enable,disable,update}
//            DELETE /api/dashboard/agent-plugins/{n}
//   MCP      GET /api/mcp/{catalog,servers} · POST /api/mcp/catalog/install
//            PUT /api/mcp/servers/{n}/enabled · DELETE /api/mcp/servers/{n}
//            POST /api/mcp/servers[/{n}/test|/{n}/auth] · GET /api/mcp/oauth/flows/{id}
//   hosted   RPC connectors.{list,catalog,accounts,connect,operation.status,
//            operation.wake,accounts.remove} · connection.respond
//
// Every capability is detected per server: a 404/405 (REST) or -32601 (RPC)
// marks it unsupported for this repository's lifetime and the UI hides it
// with an honest note. Nothing is ever faked.
import 'dart:async';

import '../models/admin_integrations.dart';
import '../models/desktop_control_center.dart';
import '../services/connection_manager.dart'
    show DashboardAuthException, DashboardHttpException;
import '../services/desktop_control_gateway.dart';
import '../services/tui_gateway_client.dart' show TuiGatewayRpcError;
import 'capability_models.dart';
import 'server_diagnostics_models.dart';

/// Minimal REST surface (implemented by `DashboardClient`).
abstract interface class CapabilitiesRest {
  Future<Map<String, dynamic>> get(String endpoint);
  Future<Map<String, dynamic>> post(
    String endpoint, {
    Map<String, dynamic>? body,
    Duration? timeout,
  });
  Future<Map<String, dynamic>> put(String endpoint, Map<String, dynamic> body);
  Future<void> delete(String endpoint);
}

/// Gateway JSON-RPC call (implemented by `TuiGatewayClient`).
typedef CapabilitiesRpc =
    Future<Map<String, dynamic>> Function(
      String method,
      Map<String, dynamic> params,
    );

/// Server features the hub probes.
enum CapabilityFeature {
  skillsList,
  skillToggle,
  officialSkills,
  hubSearch,
  skillInstall,
  skillsUpdate,
  pluginCatalog,
  pluginInstalled,
  pluginMutations,
  mcpCatalog,
  mcpServers,
  hostedConnectors,
  opsDoctor,
  opsSecurityAudit,
  mcpLiveStatus,
  usageAnalytics,
  serverHealth,
  serverIdle,
}

enum CapabilityFailureKind {
  unsupported,
  forbidden,
  rejected,
  unavailable,
  blockedByScan,
  invalidResponse,
}

final class CapabilityFailure implements Exception {
  final CapabilityFailureKind kind;

  /// Short, sanitised server detail (last log line / error reason). Never a
  /// secret: only emitted for action logs and connector reasons.
  final String detail;

  /// Whether the server itself answered (an HTTP error status or an RPC
  /// error), as opposed to no answer at all (unreachable, timeout). Only an
  /// answer is evidence about what the server has.
  final bool answered;

  const CapabilityFailure(this.kind, {this.detail = '', this.answered = false});

  @override
  String toString() => 'CapabilityFailure(${kind.name})';
}

class CapabilitiesRepository implements HermesMcpProvisioningGateway {
  final CapabilitiesRest rest;
  final CapabilitiesRpc? rpc;
  final String profile;
  final Duration actionPollInterval;
  final Duration actionTimeout;
  final Future<void> Function(Duration) _sleep;
  final DateTime Function() _clock;
  final Map<CapabilityFeature, bool> _support = {};

  CapabilitiesRepository({
    required this.rest,
    this.rpc,
    this.profile = '',
    this.actionPollInterval = const Duration(milliseconds: 1200),
    this.actionTimeout = const Duration(minutes: 10),
    Future<void> Function(Duration)? sleep,
    DateTime Function()? clock,
    this.launchScope,
  }) : _sleep = sleep ?? Future<void>.delayed,
       _clock = clock ?? DateTime.now;

  /// Names the server (connection and profile) this repository launches
  /// doctor and the audit on. Repositories that share a scope never launch the
  /// same action at the same time; without one, only this repository's own
  /// launches are ordered.
  final String? launchScope;

  /// `true` supported, `false` unsupported, `null` not probed yet.
  bool? supports(CapabilityFeature feature) => _support[feature];

  String get _q {
    final value = profile.trim();
    if (value.isEmpty || value == 'default') return '';
    return 'profile=${Uri.encodeQueryComponent(value)}';
  }

  String _withProfile(String endpoint) {
    final q = _q;
    if (q.isEmpty) return endpoint;
    return endpoint.contains('?') ? '$endpoint&$q' : '$endpoint?$q';
  }

  Map<String, dynamic> _profileBody([Map<String, dynamic>? body]) {
    final value = profile.trim();
    return {
      ...?body,
      if (value.isNotEmpty && value != 'default') 'profile': value,
    };
  }

  Future<T> _call<T>(
    CapabilityFeature feature,
    Future<T> Function() run,
  ) async {
    if (_support[feature] == false) {
      throw const CapabilityFailure(CapabilityFailureKind.unsupported);
    }
    try {
      final result = await run();
      _support[feature] = true;
      return result;
    } on CapabilityFailure {
      rethrow;
    } on DashboardAuthException {
      throw const CapabilityFailure(CapabilityFailureKind.forbidden);
    } on DashboardHttpException catch (error) {
      final status = error.statusCode;
      if (status == 404 || status == 405) {
        _support[feature] = false;
        throw const CapabilityFailure(CapabilityFailureKind.unsupported);
      }
      if (status == 401 || status == 403) {
        throw const CapabilityFailure(CapabilityFailureKind.forbidden);
      }
      if (status >= 400 && status < 500) {
        throw CapabilityFailure(
          CapabilityFailureKind.rejected,
          detail: _detailOf(error.body),
        );
      }
      throw const CapabilityFailure(
        CapabilityFailureKind.unavailable,
        answered: true,
      );
    } on TuiGatewayRpcError catch (error) {
      if (error.code == -32601) {
        _support[feature] = false;
        throw const CapabilityFailure(CapabilityFailureKind.unsupported);
      }
      throw CapabilityFailure(
        CapabilityFailureKind.rejected,
        detail: error.reason ?? '',
      );
    } on TypeError {
      throw const CapabilityFailure(CapabilityFailureKind.invalidResponse);
    } on FormatException {
      throw const CapabilityFailure(CapabilityFailureKind.invalidResponse);
    } on TimeoutException {
      throw const CapabilityFailure(CapabilityFailureKind.unavailable);
    } on Exception {
      // The dashboard could not be reached (socket error, no dashboard).
      throw const CapabilityFailure(CapabilityFailureKind.unavailable);
    }
  }

  static String _detailOf(String body) {
    final match = RegExp(r'"detail"\s*:\s*"([^"]{1,240})"').firstMatch(body);
    return match?.group(1) ?? '';
  }

  static List<Map<String, dynamic>> _list(Object? value) => value is List
      ? value
            .whereType<Map>()
            .map((row) => Map<String, dynamic>.from(row))
            .toList(growable: false)
      : throw const FormatException('list expected');

  static String _seg(String value) {
    final clean = value.trim();
    if (clean.isEmpty ||
        clean.length > 200 ||
        clean.contains('..') ||
        clean.contains('\\') ||
        clean.contains('\u0000')) {
      throw const CapabilityFailure(CapabilityFailureKind.rejected);
    }
    return Uri.encodeComponent(clean);
  }

  // ── Skills ──────────────────────────────────────────────────────────────

  Future<List<CapabilityItem>> installedSkills() =>
      _call(CapabilityFeature.skillsList, () async {
        final result = await rest.get(_withProfile('skills'));
        return _list(result['data'] ?? result['skills'])
            .map(CapabilityItem.installedSkill)
            .whereType<CapabilityItem>()
            .toList(growable: false);
      });

  Future<List<CapabilityItem>> officialSkills() =>
      _call(CapabilityFeature.officialSkills, () async {
        final result = await rest.get(_withProfile('skills/hub/official'));
        return _list(result['skills'])
            .map((row) => CapabilityItem.hubSkill(row, official: true))
            .whereType<CapabilityItem>()
            .toList(growable: false);
      });

  Future<List<CapabilityItem>> searchHub(String query) {
    final q = query.trim();
    if (q.length < 2) return Future.value(const []);
    return _call(CapabilityFeature.hubSearch, () async {
      final result = await rest.get(
        _withProfile(
          'skills/hub/search?q=${Uri.encodeQueryComponent(q)}&limit=30',
        ),
      );
      final installed = result['installed'] is Map
          ? (result['installed'] as Map).keys.map((k) => '$k').toSet()
          : const <String>{};
      return _list(result['results'])
          .map(
            (row) =>
                CapabilityItem.hubSkill(row, installedIdentifiers: installed),
          )
          .whereType<CapabilityItem>()
          .toList(growable: false);
    });
  }

  Future<void> setSkillEnabled(String name, bool enabled) =>
      _call(CapabilityFeature.skillToggle, () async {
        final result = await rest.put(
          _withProfile('skills/toggle'),
          _profileBody({'name': name.trim(), 'enabled': enabled}),
        );
        if (result['ok'] != true) {
          throw const CapabilityFailure(CapabilityFailureKind.invalidResponse);
        }
      });

  /// Starts `hermes skills install` on the server and waits for its exit.
  Future<CapabilityActionStatus> installSkill(
    String identifier, {
    void Function(CapabilityActionStatus)? onProgress,
  }) => _runAction(
    CapabilityFeature.skillInstall,
    'skills/hub/install',
    _profileBody({'identifier': identifier.trim()}),
    onProgress,
  );

  Future<CapabilityActionStatus> uninstallSkill(
    String name, {
    void Function(CapabilityActionStatus)? onProgress,
  }) => _runAction(
    CapabilityFeature.skillInstall,
    'skills/hub/uninstall',
    _profileBody({'name': name.trim()}),
    onProgress,
  );

  Future<CapabilityActionStatus> updateSkills({
    void Function(CapabilityActionStatus)? onProgress,
  }) => _runAction(
    CapabilityFeature.skillsUpdate,
    'skills/hub/update',
    _profileBody(),
    onProgress,
  );

  Future<CapabilityActionStatus> _runAction(
    CapabilityFeature feature,
    String endpoint,
    Map<String, dynamic> body,
    void Function(CapabilityActionStatus)? onProgress,
  ) async {
    final started = await _call(
      feature,
      () => rest.post(_withProfile(endpoint), body: body),
    );
    final name = '${started['name'] ?? ''}'.trim();
    if (started['ok'] != true || name.isEmpty) {
      throw const CapabilityFailure(CapabilityFailureKind.invalidResponse);
    }
    return (await _followAction(feature, name, onProgress, null))!;
  }

  /// Polls `GET actions/{name}/status` until the action exits. [shouldStop]
  /// is asked before every read: once true the follow ends with `null` and no
  /// further request (the server process keeps running). Gives up after
  /// [actionTimeout] of the repository clock.
  Future<CapabilityActionStatus?> _followAction(
    CapabilityFeature feature,
    String name,
    void Function(CapabilityActionStatus)? onProgress,
    bool Function()? shouldStop, {
    bool throwOnFailure = true,
  }) async {
    final deadline = _clock().add(actionTimeout);
    while (true) {
      if (shouldStop?.call() ?? false) return null;
      final status = await _call(
        feature,
        () async => CapabilityActionStatus.fromJson(
          await rest.get('actions/${_seg(name)}/status?lines=200'),
        ),
      );
      onProgress?.call(status);
      if (!status.running) {
        if (status.succeeded || !throwOnFailure) return status;
        throw CapabilityFailure(
          status.blockedByScan
              ? CapabilityFailureKind.blockedByScan
              : CapabilityFailureKind.rejected,
          detail: status.tail,
        );
      }
      if (_clock().isAfter(deadline)) {
        throw const CapabilityFailure(CapabilityFailureKind.unavailable);
      }
      await _sleep(actionPollInterval);
    }
  }

  // ── Server diagnostics (read-only) ──────────────────────────────────────

  static CapabilityFeature _opsFeature(OpsAction action) => switch (action) {
    OpsAction.doctor => CapabilityFeature.opsDoctor,
    OpsAction.securityAudit => CapabilityFeature.opsSecurityAudit,
  };

  /// The state of doctor / the audit: `GET actions/<name>/status`.
  Future<CapabilityActionStatus> opsStatus(OpsAction action) => _call(
    _opsFeature(action),
    () async => CapabilityActionStatus.fromJson(
      await rest.get('actions/${action.actionName}/status?lines=200'),
    ),
  );

  /// Runs doctor or the security audit and follows it to its exit, or attaches
  /// to a run already in progress. The server has no single-run guard (two
  /// launches would write the same log), so the state is read first and
  /// nothing is posted while `running`. A non-zero exit is a result, not an
  /// error. [shouldStop] ends the follow with `null`; the server process keeps
  /// going and a later call attaches to it.
  Future<CapabilityActionStatus?> runOps(
    OpsAction action, {
    void Function(CapabilityActionStatus)? onProgress,
    bool Function()? shouldStop,
  }) async {
    final feature = _opsFeature(action);
    if (shouldStop?.call() ?? false) return null;
    // The read of the state and the launch are one step for every launcher in
    // this app that shares the scope: a second one waits for the first launch
    // to land, then reads `running` and attaches instead of launching again.
    var stopped = false;
    await _exclusiveLaunch(action, () async {
      final current = await opsStatus(action);
      onProgress?.call(current);
      if (current.running) return;
      if (shouldStop?.call() ?? false) {
        stopped = true;
        return;
      }
      final started = await _call(
        feature,
        () => rest.post(_withProfile(action.endpoint)),
      );
      if (started['ok'] != true) {
        throw const CapabilityFailure(CapabilityFailureKind.invalidResponse);
      }
    });
    if (stopped) return null;
    return _followAction(
      feature,
      action.actionName,
      onProgress,
      shouldStop,
      throwOnFailure: false,
    );
  }

  /// Launches of one action on one server, in this process, one at a time.
  /// Another device or client cannot be ordered from here: the server has no
  /// guard of its own.
  static final Map<String, Future<void>> _launches = {};

  Future<void> _exclusiveLaunch(
    OpsAction action,
    Future<void> Function() step,
  ) async {
    final key =
        '${launchScope ?? 'rest-${identityHashCode(rest)}'}|${action.actionName}';
    final previous = _launches[key];
    final done = Completer<void>();
    final mine = done.future;
    _launches[key] = mine;
    try {
      if (previous != null) await previous;
      await step();
    } finally {
      done.complete();
      if (identical(_launches[key], mine)) _launches.remove(key);
    }
  }

  /// Re-attaches to doctor / the audit after the screen was left: reads the
  /// state and follows a run in progress, or returns the finished one. It
  /// never launches anything.
  Future<CapabilityActionStatus?> attachOps(
    OpsAction action, {
    void Function(CapabilityActionStatus)? onProgress,
    bool Function()? shouldStop,
  }) async {
    if (shouldStop?.call() ?? false) return null;
    final current = await opsStatus(action);
    onProgress?.call(current);
    if (!current.running) return current;
    return _followAction(
      _opsFeature(action),
      action.actionName,
      onProgress,
      shouldStop,
      throwOnFailure: false,
    );
  }

  /// `mcp.servers.status` over [call] (a connected gateway socket): the cached
  /// runtime state of every MCP server, never connecting or probing.
  Future<List<McpServerStatus>> mcpLiveStatus(CapabilitiesRpc call) =>
      _call(CapabilityFeature.mcpLiveStatus, () async {
        final result = await call('mcp.servers.status', _profileBody());
        return [
          for (final row in _list(result['servers']))
            ?McpServerStatus.tryParse(row),
        ];
      });

  /// `GET analytics/usage?days=` for one of [UsageAnalytics.presets].
  Future<UsageAnalytics> usage(int days) async {
    if (!UsageAnalytics.presets.contains(days)) {
      throw ArgumentError.value(days, 'days', 'not a usage preset');
    }
    return _call(CapabilityFeature.usageAnalytics, () async {
      final result = await rest.get(_withProfile('analytics/usage?days=$days'));
      return UsageAnalytics.fromJson(result, days: days);
    });
  }

  Future<ServerHealth> serverHealth() => _call(
    CapabilityFeature.serverHealth,
    () async => ServerHealth.fromJson(await rest.get('health')),
  );

  Future<ServerIdle> serverIdle() => _call(
    CapabilityFeature.serverIdle,
    () async => ServerIdle.fromJson(await rest.get('health/idle')),
  );

  // ── Plugins ─────────────────────────────────────────────────────────────

  Future<List<CapabilityItem>> pluginCatalog() =>
      _call(CapabilityFeature.pluginCatalog, () async {
        final result = await rest.get('dashboard/plugins/catalog');
        return _list(result['entries'])
            .map(CapabilityItem.catalogPlugin)
            .whereType<CapabilityItem>()
            .toList(growable: false);
      });

  Future<List<CapabilityItem>> installedPlugins() =>
      _call(CapabilityFeature.pluginInstalled, () async {
        final result = await rest.get(_withProfile('dashboard/plugins/hub'));
        return _list(result['plugins'])
            .where((row) => row['user_hidden'] != true)
            .map(CapabilityItem.installedPlugin)
            .whereType<CapabilityItem>()
            .toList(growable: false);
      });

  Future<PluginMutationResult> installPlugin(String catalogName) =>
      _call(CapabilityFeature.pluginMutations, () async {
        final result = PluginMutationResult.fromJson(
          await rest.post(
            'dashboard/agent-plugins/install',
            body: {
              'identifier': '',
              'catalog_name': catalogName.trim(),
              'force': false,
              'enable': true,
            },
            timeout: const Duration(minutes: 3),
          ),
        );
        if (!result.ok && !result.consentRequired) {
          throw const CapabilityFailure(CapabilityFailureKind.rejected);
        }
        return result;
      });

  Future<PluginMutationResult> updatePlugin(
    String name, {
    bool acceptCapabilities = false,
  }) => _call(CapabilityFeature.pluginMutations, () async {
    final result = PluginMutationResult.fromJson(
      await rest.post(
        'dashboard/agent-plugins/${_seg(name)}/update',
        body: acceptCapabilities ? {'accept_capabilities': true} : null,
        timeout: const Duration(minutes: 3),
      ),
    );
    if (!result.ok && !result.consentRequired) {
      throw const CapabilityFailure(CapabilityFailureKind.rejected);
    }
    return result;
  });

  Future<void> setPluginEnabled(
    String name,
    bool enabled,
  ) => _call(CapabilityFeature.pluginMutations, () async {
    final result = await rest.post(
      'dashboard/agent-plugins/${_seg(name)}/${enabled ? 'enable' : 'disable'}',
    );
    if (result['ok'] != true) {
      throw const CapabilityFailure(CapabilityFailureKind.rejected);
    }
  });

  Future<void> removePlugin(String name) => _call(
    CapabilityFeature.pluginMutations,
    () => rest.delete('dashboard/agent-plugins/${_seg(name)}'),
  );

  // ── MCP ─────────────────────────────────────────────────────────────────

  Future<List<CapabilityItem>> mcpCatalog() =>
      _call(CapabilityFeature.mcpCatalog, () async {
        final result = await rest.get(_withProfile('mcp/catalog'));
        return _list(result['entries'] ?? result['servers'])
            .map(CapabilityItem.catalogMcp)
            .whereType<CapabilityItem>()
            .toList(growable: false);
      });

  Future<List<CapabilityItem>> mcpServers() =>
      _call(CapabilityFeature.mcpServers, () async {
        final result = await rest.get(_withProfile('mcp/servers'));
        return _list(result['servers'])
            .map(CapabilityItem.mcpServer)
            .whereType<CapabilityItem>()
            .toList(growable: false);
      });

  Future<void> installMcp(
    String name, {
    Map<String, String> environment = const {},
  }) => _call(CapabilityFeature.mcpCatalog, () async {
    for (final key in environment.keys) {
      if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,127}$').hasMatch(key)) {
        throw const CapabilityFailure(CapabilityFailureKind.rejected);
      }
    }
    final result = await rest.post(
      _withProfile('mcp/catalog/install'),
      body: _profileBody({
        'name': name.trim(),
        'env': environment,
        'enable': true,
      }),
      timeout: const Duration(minutes: 2),
    );
    if (result['ok'] != true) {
      throw const CapabilityFailure(CapabilityFailureKind.rejected);
    }
  });

  Future<void> setMcpEnabled(String name, bool enabled) =>
      _call(CapabilityFeature.mcpServers, () async {
        final result = await rest.put(
          _withProfile('mcp/servers/${_seg(name)}/enabled'),
          {'enabled': enabled},
        );
        if (result['ok'] != true) {
          throw const CapabilityFailure(CapabilityFailureKind.invalidResponse);
        }
      });

  Future<void> removeMcp(String name) => _call(
    CapabilityFeature.mcpServers,
    () => rest.delete(_withProfile('mcp/servers/${_seg(name)}')),
  );

  Future<DesktopMcpProbeResult> testMcp(String name) =>
      _call(CapabilityFeature.mcpServers, () async {
        final result = await rest.post(
          _withProfile('mcp/servers/${_seg(name)}/test'),
          timeout: const Duration(minutes: 1),
        );
        if (result['ok'] is! bool) {
          throw const CapabilityFailure(CapabilityFailureKind.invalidResponse);
        }
        return DesktopMcpProbeResult.fromJson(result);
      });

  @override
  Future<DesktopMcpServerEntry> addMcpServer(McpServerDraft draft) =>
      _mcpProvision(() async {
        final result = await rest.post(
          _withProfile('mcp/servers'),
          body: _profileBody(draft.toRequestJson()),
          timeout: const Duration(minutes: 1),
        );
        final parsed = DesktopMcpServerEntry.tryParse(result);
        if (parsed == null) {
          throw const DesktopControlFailure(
            DesktopControlFailureKind.invalidResponse,
          );
        }
        return parsed;
      });

  @override
  Future<McpOAuthFlow> startMcpOAuth(String name) => _mcpProvision(
    () async => McpOAuthFlow.fromJson(
      await rest.post(
        _withProfile('mcp/servers/${_seg(name)}/auth'),
        timeout: const Duration(seconds: 45),
      ),
    ),
  );

  @override
  Future<McpOAuthFlow> mcpOAuthFlow(String flowId) => _mcpProvision(
    () async => McpOAuthFlow.fromJson(
      await rest.get('mcp/oauth/flows/${_seg(flowId)}'),
    ),
  );

  /// The shared OAuth surface speaks `DesktopControlFailure`; map to it.
  Future<T> _mcpProvision<T>(Future<T> Function() run) async {
    try {
      return await _call(CapabilityFeature.mcpServers, run);
    } on CapabilityFailure catch (error) {
      throw DesktopControlFailure(switch (error.kind) {
        CapabilityFailureKind.unsupported =>
          DesktopControlFailureKind.unsupported,
        CapabilityFailureKind.forbidden => DesktopControlFailureKind.forbidden,
        CapabilityFailureKind.rejected || CapabilityFailureKind.blockedByScan =>
          DesktopControlFailureKind.rejected,
        CapabilityFailureKind.invalidResponse =>
          DesktopControlFailureKind.invalidResponse,
        CapabilityFailureKind.unavailable =>
          DesktopControlFailureKind.unavailable,
      });
    }
  }

  // ── Hosted connectors (Nous account) ────────────────────────────────────

  static const Map<String, String> _account = {'type': 'account'};

  Future<Map<String, dynamic>> _rpc(String method, Map<String, dynamic> p) {
    final call = rpc;
    if (call == null) {
      _support[CapabilityFeature.hostedConnectors] = false;
      throw const CapabilityFailure(CapabilityFailureKind.unsupported);
    }
    final value = profile.trim();
    return call(method, {
      ...p,
      if (value.isNotEmpty && value != 'default') 'profile': value,
    });
  }

  Future<HostedConnectorsSnapshot> hostedConnectors() async {
    try {
      return await _call(CapabilityFeature.hostedConnectors, () async {
        final list = await _rpc('connectors.list', {'owner': _account});
        if (list['available'] != true) {
          return const HostedConnectorsSnapshot(
            availability: ConnectorAvailability.unavailable,
          );
        }
        final extra = await Future.wait([
          _rpc(
            'connectors.catalog',
            const {},
          ).catchError((_) => <String, dynamic>{}),
          _rpc(
            'connectors.accounts',
            const {},
          ).catchError((_) => <String, dynamic>{}),
        ]);
        return HostedConnectorsSnapshot.join(
          list: list,
          catalog: extra[0],
          accounts: extra[1],
        );
      });
    } on CapabilityFailure catch (error) {
      if (error.kind == CapabilityFailureKind.unsupported) {
        return const HostedConnectorsSnapshot(
          availability: ConnectorAvailability.unsupported,
        );
      }
      if (error.detail == 'NEEDS_NOUS_AUTH') {
        return const HostedConnectorsSnapshot(
          availability: ConnectorAvailability.signedOut,
        );
      }
      if (error.detail == 'CONNECTORS_UNAVAILABLE' ||
          error.detail == 'UNSUPPORTED_RUNTIME') {
        return const HostedConnectorsSnapshot(
          availability: ConnectorAvailability.unavailable,
        );
      }
      rethrow;
    }
  }

  Future<ConnectOperation> connectAccount(
    String slug, {
    bool reconnect = false,
  }) => _call(
    CapabilityFeature.hostedConnectors,
    () async => ConnectOperation.fromJson(
      await _rpc('connectors.connect', {
        'connectors': [slug.trim()],
        'owner': _account,
        'reconnect': reconnect,
      }),
    ),
  );

  Future<ConnectOperation> operationStatus(String opId) => _call(
    CapabilityFeature.hostedConnectors,
    () async => ConnectOperation.fromJson(
      await _rpc('connectors.operation.status', {
        'op_id': opId,
        'owner': _account,
      }),
    ),
  );

  /// The browser leg came back: ask the server to read the accounts now.
  Future<void> wakeOperation(String opId) => _call(
    CapabilityFeature.hostedConnectors,
    () => _rpc('connectors.operation.wake', {'op_id': opId, 'owner': _account}),
  );

  /// "Stop waiting": settle the operation as `continue` (Desktop `giveUp`).
  Future<void> abandonOperation(String opId) => _call(
    CapabilityFeature.hostedConnectors,
    () => _rpc('connection.respond', {
      'op_id': opId,
      'owner': _account,
      'result': {'settled_by': 'continue'},
    }),
  );

  Future<void> disconnectAccount(String connectionId) => _call(
    CapabilityFeature.hostedConnectors,
    () => _rpc('connectors.accounts.remove', {'connection_id': connectionId}),
  );
}
