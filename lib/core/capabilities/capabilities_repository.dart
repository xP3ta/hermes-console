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
import '../services/tui_gateway_client.dart'
    show TuiGatewayRpcError, TuiGatewayRpcFailureKind;
import 'capability_models.dart';

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
  pluginsManage,
  mcpCatalog,
  mcpServers,
  hostedConnectors,
}

enum CapabilityFailureKind {
  unsupported,
  forbidden,
  rejected,
  unavailable,
  blockedByScan,

  /// The request may still have landed (client timeout): refresh, never retry.
  uncertain,
  invalidResponse,
}

final class CapabilityFailure implements Exception {
  final CapabilityFailureKind kind;

  /// Short, sanitised server detail (last log line / error reason). Never a
  /// secret: only emitted for action logs and connector reasons.
  final String detail;

  /// High-risk finding count of a blocked skill install, when stated.
  final int? findings;

  const CapabilityFailure(this.kind, {this.detail = '', this.findings});

  @override
  String toString() => 'CapabilityFailure(${kind.name})';
}

/// Cooperative cancel / pause handle for the action loop. A cancelled loop
/// ends with [CapabilityActionAbandoned]; a paused one (app in background,
/// route covered) makes no reads until [resume], which reads exactly once.
final class CapabilityActionToken {
  bool _cancelled = false;
  Completer<void>? _gate;

  bool get cancelled => _cancelled;
  bool get paused => _gate != null;

  void cancel() {
    _cancelled = true;
    _release();
  }

  void pause() {
    if (!_cancelled) _gate ??= Completer<void>();
  }

  void resume() => _release();

  void _release() {
    final gate = _gate;
    _gate = null;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  Future<void> _untilResumed() async {
    while (_gate != null) {
      await _gate!.future;
    }
  }
}

/// The action loop was cancelled: not a success and not a failure to report.
final class CapabilityActionAbandoned implements Exception {
  const CapabilityActionAbandoned();

  @override
  String toString() => 'CapabilityActionAbandoned';
}

class CapabilitiesRepository implements HermesMcpProvisioningGateway {
  final CapabilitiesRest rest;
  final CapabilitiesRpc? rpc;
  final String profile;
  final Duration actionPollInterval;
  final Duration actionTimeout;
  final Future<void> Function(Duration) _sleep;
  final Map<CapabilityFeature, bool> _support = {};

  CapabilitiesRepository({
    required this.rest,
    this.rpc,
    this.profile = '',
    this.actionPollInterval = const Duration(milliseconds: 1200),
    this.actionTimeout = const Duration(minutes: 10),
    Future<void> Function(Duration)? sleep,
  }) : _sleep = sleep ?? Future<void>.delayed;

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
      throw const CapabilityFailure(CapabilityFailureKind.unavailable);
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
    CapabilityActionToken? token,
  }) => _runAction(
    CapabilityFeature.skillInstall,
    'skills/hub/install',
    _profileBody({'identifier': identifier.trim()}),
    onProgress,
    token,
  );

  Future<CapabilityActionStatus> uninstallSkill(
    String name, {
    void Function(CapabilityActionStatus)? onProgress,
    CapabilityActionToken? token,
  }) => _runAction(
    CapabilityFeature.skillInstall,
    'skills/hub/uninstall',
    _profileBody({'name': name.trim()}),
    onProgress,
    token,
  );

  Future<CapabilityActionStatus> updateSkills({
    void Function(CapabilityActionStatus)? onProgress,
    CapabilityActionToken? token,
  }) => _runAction(
    CapabilityFeature.skillsUpdate,
    'skills/hub/update',
    _profileBody(),
    onProgress,
    token,
  );

  Future<CapabilityActionStatus> _runAction(
    CapabilityFeature feature,
    String endpoint,
    Map<String, dynamic> body,
    void Function(CapabilityActionStatus)? onProgress,
    CapabilityActionToken? token,
  ) async {
    if (token?.cancelled ?? false) throw const CapabilityActionAbandoned();
    final started = await _call(
      feature,
      () => rest.post(_withProfile(endpoint), body: body),
    );
    final name = '${started['name'] ?? ''}'.trim();
    if (started['ok'] != true || name.isEmpty) {
      throw const CapabilityFailure(CapabilityFailureKind.invalidResponse);
    }
    return _followAction(feature, name, onProgress, token);
  }

  /// Polls `/api/actions/{name}/status` on the one shared cadence. The loop
  /// never outlives its [token]: cancelled → abandoned, paused → no reads
  /// until resumed (then one read, and on only while still running).
  Future<CapabilityActionStatus> _followAction(
    CapabilityFeature feature,
    String name,
    void Function(CapabilityActionStatus)? onProgress,
    CapabilityActionToken? token,
  ) async {
    var elapsed = Duration.zero;
    while (true) {
      if (token?.cancelled ?? false) throw const CapabilityActionAbandoned();
      final status = await _call(
        feature,
        () async => CapabilityActionStatus.fromJson(
          await rest.get('actions/${_seg(name)}/status?lines=200'),
        ),
      );
      if (token?.cancelled ?? false) throw const CapabilityActionAbandoned();
      onProgress?.call(status);
      if (!status.running) {
        if (status.succeeded) return status;
        throw CapabilityFailure(
          status.blockedByScan
              ? CapabilityFailureKind.blockedByScan
              : CapabilityFailureKind.rejected,
          detail: status.tail,
          findings: status.scanFindings,
        );
      }
      if (elapsed >= actionTimeout) {
        throw const CapabilityFailure(CapabilityFailureKind.unavailable);
      }
      await _sleep(actionPollInterval);
      elapsed += actionPollInterval;
      if (token != null) {
        await token._untilResumed();
      }
    }
  }

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

  bool get _defaultProfile {
    final value = profile.trim();
    return value.isEmpty || value == 'default';
  }

  /// `plugins.manage` list: the installed state of the hub profile.
  Future<List<InstalledPluginRow>> installedPluginsRpc() =>
      _call(CapabilityFeature.pluginsManage, () async {
        final result = await _rpc('plugins.manage', {'action': 'list'});
        return _list(result['plugins'])
            .map(InstalledPluginRow.tryParse)
            .whereType<InstalledPluginRow>()
            .toList(growable: false);
      });

  /// Runs a plugin mutation on the hub profile through `plugins.manage`.
  /// Without the method, the REST routes (server launch profile) are used
  /// only when the hub is on the default profile; otherwise the mutation is
  /// unsupported and the UI hides it.
  Future<T> _pluginMutation<T>(
    Map<String, dynamic> params,
    T Function(Map<String, dynamic>) parse,
    Future<T> Function() viaRest,
  ) async {
    final call = rpc;
    if (call != null && _support[CapabilityFeature.pluginsManage] != false) {
      try {
        final result = await _call(CapabilityFeature.pluginsManage, () async {
          try {
            return await _rpc('plugins.manage', params);
          } on TuiGatewayRpcError catch (error) {
            if (error.failureKind == TuiGatewayRpcFailureKind.timeout) {
              throw const CapabilityFailure(CapabilityFailureKind.uncertain);
            }
            rethrow;
          }
        });
        _support[CapabilityFeature.pluginMutations] = true;
        return parse(result);
      } on CapabilityFailure catch (error) {
        if (error.kind != CapabilityFailureKind.unsupported) rethrow;
      }
    }
    if (!_defaultProfile) {
      _support[CapabilityFeature.pluginMutations] = false;
      throw const CapabilityFailure(CapabilityFailureKind.unsupported);
    }
    return _call(CapabilityFeature.pluginMutations, viaRest);
  }

  PluginMutationResult _checked(PluginMutationResult result) {
    if (!result.ok && !result.consentRequired) {
      throw const CapabilityFailure(CapabilityFailureKind.rejected);
    }
    return result;
  }

  Future<PluginMutationResult> installPlugin(String catalogName) {
    final name = catalogName.trim();
    return _pluginMutation(
      {
        'action': 'install',
        'catalog_name': name,
        'enable': true,
        'force': false,
      },
      (json) => _checked(PluginMutationResult.fromJson(json)),
      () async => _checked(
        PluginMutationResult.fromJson(
          await rest.post(
            'dashboard/agent-plugins/install',
            body: {
              'identifier': '',
              'catalog_name': name,
              'force': false,
              'enable': true,
            },
            timeout: const Duration(minutes: 3),
          ),
        ),
      ),
    );
  }

  Future<PluginMutationResult> updatePlugin(
    String name, {
    bool acceptCapabilities = false,
  }) => _pluginMutation(
    {
      'action': 'update',
      'name': name.trim(),
      if (acceptCapabilities) 'accept_capabilities': true,
    },
    (json) => _checked(PluginMutationResult.fromJson(json)),
    () async => _checked(
      PluginMutationResult.fromJson(
        await rest.post(
          'dashboard/agent-plugins/${_seg(name)}/update',
          body: acceptCapabilities ? {'accept_capabilities': true} : null,
          timeout: const Duration(minutes: 3),
        ),
      ),
    ),
  );

  Future<void> setPluginEnabled(String name, bool enabled) async {
    await _pluginMutation(
      {
        'action': 'toggle',
        'name': name.trim(),
        'key': name.trim(),
        'enable': enabled,
      },
      (json) => _checked(PluginMutationResult.fromJson(json)),
      () async {
        final result = await rest.post(
          'dashboard/agent-plugins/${_seg(name)}/${enabled ? 'enable' : 'disable'}',
        );
        if (result['ok'] != true) {
          throw const CapabilityFailure(CapabilityFailureKind.rejected);
        }
        return const PluginMutationResult(ok: true);
      },
    );
  }

  Future<void> removePlugin(String name) async {
    await _pluginMutation(
      {'action': 'remove', 'name': name.trim()},
      (json) => _checked(PluginMutationResult.fromJson(json)),
      () async {
        await rest.delete('dashboard/agent-plugins/${_seg(name)}');
        return const PluginMutationResult(ok: true);
      },
    );
  }

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

  /// Installs a catalog MCP entry through the server's secret path.
  ///
  /// [environment] values are secrets: only keys in [declaredEnv] are sent
  /// (when given), values never reach an error, log or notice, and a git
  /// bootstrap (`background: true`) is followed to its exit.
  Future<void> installMcp(
    String name, {
    Map<String, String> environment = const {},
    List<String>? declaredEnv,
    void Function(CapabilityActionStatus)? onProgress,
    CapabilityActionToken? token,
  }) async {
    final env = <String, String>{};
    for (final entry in environment.entries) {
      if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,127}$').hasMatch(entry.key)) {
        throw const CapabilityFailure(CapabilityFailureKind.rejected);
      }
      if (declaredEnv != null && !declaredEnv.contains(entry.key)) continue;
      env[entry.key] = entry.value;
    }
    final Map<String, dynamic> result;
    try {
      result = await _call(
        CapabilityFeature.mcpCatalog,
        () => rest.post(
          _withProfile('mcp/catalog/install'),
          body: _profileBody({
            'name': name.trim(),
            'env': Map<String, String>.of(env),
            'enable': true,
          }),
          timeout: const Duration(minutes: 2),
        ),
      );
    } on CapabilityFailure catch (error) {
      throw CapabilityFailure(
        error.kind,
        detail: _redact(error.detail, env.values),
      );
    } finally {
      env.clear();
    }
    if (result['ok'] != true) {
      throw const CapabilityFailure(CapabilityFailureKind.rejected);
    }
    final action = '${result['action'] ?? ''}'.trim();
    if (result['background'] == true && action.isNotEmpty) {
      await _followAction(
        CapabilityFeature.mcpCatalog,
        action,
        onProgress,
        token,
      );
    }
  }

  static String _redact(String text, Iterable<String> secrets) {
    var out = text;
    for (final secret in secrets) {
      if (secret.isNotEmpty) out = out.replaceAll(secret, '…');
    }
    return out;
  }

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
        CapabilityFailureKind.unavailable || CapabilityFailureKind.uncertain =>
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
