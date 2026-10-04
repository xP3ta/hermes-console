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
//   MCP live RPC mcp.servers.status · GET /api/logs (on demand, one read)
//   hosted   RPC connectors.{list,catalog,accounts,connect,operation.status,
//            operation.wake,accounts.remove,tools,policy.get,policy.set}
//            · connection.respond
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
import 'connector_policy.dart';
import 'mcp_log_filter.dart';
import 'mcp_runtime_status.dart';

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
  mcpStatus,
  mcpLogs,
  hostedConnectors,
  connectorPolicy,
  connectorTools,
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

  const CapabilityFailure(this.kind, {this.detail = ''});

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
    final deadline = DateTime.now().add(actionTimeout);
    while (true) {
      final status = await _call(
        feature,
        () async => CapabilityActionStatus.fromJson(
          await rest.get('actions/${_seg(name)}/status?lines=200'),
        ),
      );
      onProgress?.call(status);
      if (!status.running) {
        if (status.succeeded) return status;
        throw CapabilityFailure(
          status.blockedByScan
              ? CapabilityFailureKind.blockedByScan
              : CapabilityFailureKind.rejected,
          detail: status.tail,
        );
      }
      if (DateTime.now().isAfter(deadline)) {
        throw const CapabilityFailure(CapabilityFailureKind.unavailable);
      }
      await _sleep(actionPollInterval);
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

  /// Cached runtime state per configured server, keyed by name. One RPC;
  /// `-32601` marks it unsupported and callers keep today's static rows.
  Future<Map<String, McpRuntimeRow>> mcpRuntimeStatus() =>
      _call(CapabilityFeature.mcpStatus, () async {
        final result = await _rpc(
          'mcp.servers.status',
          const {},
          feature: CapabilityFeature.mcpStatus,
        );
        final servers = result['servers'];
        if (servers is! List) throw const FormatException('list expected');
        return {
          for (final row in servers.map(McpRuntimeRow.tryParse).nonNulls)
            row.name: row,
        };
      });

  /// One read of the server's log for [server]. stdio servers log into the
  /// shared MCP stderr file (cut to their own sections); others are found in
  /// the agent log by name. Lines are returned to the caller and never kept.
  Future<List<String>> mcpLogLines(String server, {required bool stdio}) =>
      _call(CapabilityFeature.mcpLogs, () async {
        final query = stdio
            ? 'logs?file=mcp&lines=500'
            : 'logs?file=agent&lines=300'
                  '&search=${Uri.encodeQueryComponent(server)}';
        final result = await rest.get(_withProfile(query));
        final lines = result['lines'];
        if (lines is! List) throw const FormatException('list expected');
        final text = lines.whereType<String>().toList(growable: false);
        return stdio ? filterStdioSections(text, server) : text;
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

  Future<Map<String, dynamic>> _rpc(
    String method,
    Map<String, dynamic> p, {
    CapabilityFeature feature = CapabilityFeature.hostedConnectors,
  }) {
    final call = rpc;
    if (call == null) {
      _support[feature] = false;
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

  // ── Connector policy (member rules, org locks) ──────────────────────────

  Future<ConnectorPolicy> connectorPolicy() =>
      _call(CapabilityFeature.connectorPolicy, () async {
        final result = await _rpc(
          'connectors.policy.get',
          const {},
          feature: CapabilityFeature.connectorPolicy,
        );
        return ConnectorPolicy.fromJson(result);
      });

  Future<List<ConnectorTool>> connectorTools(String slug) =>
      _call(CapabilityFeature.connectorTools, () async {
        final result = await _rpc('connectors.tools', {
          'slug': slug.trim(),
        }, feature: CapabilityFeature.connectorTools);
        final tools = result['tools'];
        if (tools is! List) throw const FormatException('list expected');
        return [
          for (final row in tools.whereType<Map>())
            ConnectorTool.fromJson(Map<String, dynamic>.from(row)),
        ].where((tool) => tool.slug.isNotEmpty).toList(growable: false);
      });

  /// Saves the member's full `disabled_tools` list for [slug]. Returns the
  /// member layer's new revision. A stale [expectedRevision] fails with
  /// detail `POLICY_CONFLICT`.
  Future<String> setConnectorTools(
    String slug,
    List<String> disabledTools, {
    required String expectedRevision,
  }) => _policySet({
    'type': 'tools',
    'connector': slug.trim(),
    'disabled_tools': disabledTools,
  }, expectedRevision);

  Future<String> setConnectorEnabled(
    String slug,
    bool enabled, {
    required String expectedRevision,
  }) => _policySet({
    'type': 'connector',
    'connector': slug.trim(),
    'enabled': enabled,
  }, expectedRevision);

  Future<String> _policySet(
    Map<String, dynamic> change,
    String expectedRevision,
  ) => _call(CapabilityFeature.connectorPolicy, () async {
    final result = await _rpc('connectors.policy.set', {
      'change': change,
      'expected_revision': expectedRevision,
    }, feature: CapabilityFeature.connectorPolicy);
    final revision = result['revision'];
    if (revision is! String || revision.isEmpty) {
      throw const FormatException('revision expected');
    }
    return revision;
  });
}
