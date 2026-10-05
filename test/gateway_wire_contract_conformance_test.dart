// Contract conformance: every server→client request, event and RPC result
// Console reads is generated from Hermes' published wire contract
// (test/fixtures/contract/gateway-contract.openrpc.json) in several shapes —
// required fields only, every nullable field as null, every field present,
// unknown extra keys, every enum value plus an unknown one — and fed to the
// real Console parser. A parser may ignore what it does not understand, but it
// must never throw on a contract-valid payload nor drop the whole item.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/capabilities/server_diagnostics_models.dart';
import 'package:hermes_android/core/models/foreign_session.dart';
import 'package:hermes_android/core/models/terminal_exec.dart';
import 'package:hermes_android/core/models/agent_task_list.dart';
import 'package:hermes_android/core/models/desktop_active_session.dart';
import 'package:hermes_android/core/models/desktop_context_breakdown.dart';
import 'package:hermes_android/core/models/desktop_control_center.dart';
import 'package:hermes_android/core/models/desktop_model_catalog.dart';
import 'package:hermes_android/core/models/desktop_session_config.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/models/interactive_prompt.dart';
import 'package:hermes_android/core/models/session_workspace_move.dart';
import 'package:hermes_android/core/models/subagent_activity.dart';
import 'package:hermes_android/core/models/turn_error_surface.dart';
import 'package:hermes_android/core/services/approval_policy.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/json_rpc_wire.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/models/tool_output.dart';
import 'package:hermes_android/core/utils/unified_diff.dart';

import 'support/contract/gateway_contract.dart';

/// Outcome of one parser over one sample: `true` kept the item, `false`
/// dropped it. Throwing is reported separately.
typedef _Parse = bool Function(Map<String, dynamic> sample);

final class _Consumer {
  final String kind; // event | request | result
  final String name;
  final Map<String, dynamic> Function(GatewayContract c) schema;
  final _Parse parse;

  /// Contract-valid samples the parser may legitimately ignore because the
  /// payload carries nothing renderable (documented per consumer).
  final bool Function(Map<String, dynamic> sample)? semanticallyEmpty;

  const _Consumer(
    this.kind,
    this.name,
    this.schema,
    this.parse, {
    this.semanticallyEmpty,
  });
}

bool _renderableSurface(Object? surface) =>
    surface is Map &&
    const {
      'provider',
      'endpoint',
      'streaming',
      'auth',
      'billing',
      'gateway',
      'runtime',
      'disk',
    }.contains(surface['layer']);

bool _renderableBilling(Object? billing) {
  if (billing is! Map) return false;
  final label = billing['provider_label'];
  return label is String &&
      label.trim().isNotEmpty &&
      label.trim().length <= 128;
}

String _id(Object? value, String fallback) =>
    value is String && value.trim().isNotEmpty ? value : fallback;

/// The transport adapts a server request frame into the legacy `*.request`
/// payload: `session_id` moves to the envelope, the frame id becomes
/// `request_id` (tui_gateway_client.dart `_deliverServerRequest`).
TuiGatewayEvent? _adaptServerRequest(
  String method,
  Map<String, dynamic> params,
) => TuiGatewayClient.openServerRequestEvent({
  'id': 'srq-contract0001',
  'method': method,
  'params': {...params, 'session_id': 'runtime-contract'},
});

bool _interactive(String method, Map<String, dynamic> params) {
  final event = _adaptServerRequest(method, params);
  if (event == null) return false;
  final request = InteractivePromptRequest.fromGatewayEvent(
    type: event.type,
    runtimeSessionId: event.sessionId,
    payload: event.payload,
  );
  return request.key.requestId == 'srq-contract0001';
}

final _scope = SubagentActivityScope(
  connectionId: 'conn-contract',
  parentSessionId: 'stored-contract',
  runtimeSessionId: 'runtime-contract',
  turnEpoch: 1,
);

bool _subagent(String type, Map<String, dynamic> payload) =>
    SubagentActivityEvent.tryParseNative(
      type: type,
      scope: _scope,
      payload: payload,
    ) !=
    null;

DesktopSessionSnapshot _snapshot(Map<String, dynamic> json, String method) =>
    DesktopSessionSnapshot.fromJson(
      json,
      requestedStoredSessionId: 'stored-contract',
      created: method == 'session.create',
      method: method,
    );

/// Every event Console reads a field from, every server request it answers
/// and every RPC result it parses into a typed model.
final List<_Consumer> _consumers = [
  // ── server → client requests ──────────────────────────────────────────
  _Consumer(
    'request',
    'clarify',
    (c) => c.serverRequestParamsSchema('clarify'),
    (s) => _interactive('clarify', s),
    // Hermes never sends a clarify without a question or a batch; Desktop
    // auto-answers such a frame with an empty answer instead of rendering it.
    semanticallyEmpty: (s) =>
        (s['questions'] is! List || (s['questions'] as List).isEmpty) &&
        (s['question'] is! String || (s['question'] as String).trim().isEmpty),
  ),
  _Consumer(
    'request',
    'sudo',
    (c) => c.serverRequestParamsSchema('sudo'),
    (s) => _interactive('sudo', s),
  ),
  _Consumer(
    'request',
    'secret',
    (c) => c.serverRequestParamsSchema('secret'),
    (s) => _interactive('secret', s),
  ),
  _Consumer(
    'request',
    'terminal.read',
    (c) => c.serverRequestParamsSchema('terminal.read'),
    (s) => _interactive('terminal.read', s),
  ),
  _Consumer(
    'request',
    'approval',
    (c) => c.serverRequestParamsSchema('approval'),
    (s) => permittedApprovalChoices(s).isNotEmpty || s['choices'] is List,
  ),
  for (final vault in const [
    'vault.unlock_prompt',
    'vault.save_login',
    'vault.code',
  ])
    _Consumer(
      'request',
      vault,
      (c) => c.serverRequestParamsSchema(vault),
      // Console renders only a "continue on Desktop" notice: the transport
      // must route the frame, whatever its fields.
      (s) => _adaptServerRequest(vault, s) != null,
    ),

  // ── events ────────────────────────────────────────────────────────────
  for (final type in const [
    'subagent.spawn_requested',
    'subagent.start',
    'subagent.thinking',
    'subagent.tool',
    'subagent.progress',
    'subagent.complete',
  ])
    _Consumer(
      'event',
      type,
      (c) => c.eventPayloadSchema(type),
      (s) => _subagent(type, s),
    ),
  // pt1215: a file edit's `inline_diff` becomes a diff card (any tool name
  // the server marks as an edit; `patch` stands in for it here).
  _Consumer(
    'event',
    'tool.complete',
    (c) => c.eventPayloadSchema('tool.complete'),
    (s) =>
        ToolOutputRecord.fromCompletePayload({...s, 'name': 'patch'}) != null,
    // A diff with no change and no hunk is no card (qa9485).
    semanticallyEmpty: (s) {
      final raw = s['inline_diff'];
      if (raw is! String) return true;
      final cleaned = cleanInlineDiff(raw);
      return countDiffLineStats(cleaned).isEmpty &&
          !RegExp(r'^@@', multiLine: true).hasMatch(cleaned);
    },
  ),
  _Consumer(
    'event',
    'todo.updated',
    (c) => c.eventPayloadSchema('todo.updated'),
    (s) => AgentTaskList.tryParse(s) != null,
    // `{todos: [], revision: 0}` is the store's "never used" snapshot.
    semanticallyEmpty: (s) => s['revision'] == 0,
  ),
  _Consumer(
    'event',
    'session.control.update',
    (c) => c.eventPayloadSchema('session.control.update'),
    (s) {
      SessionControlSnapshot.fromJson(s['control']);
      return true;
    },
  ),
  _Consumer(
    'event',
    'session.info',
    (c) => c.eventPayloadSchema('session.info'),
    (s) {
      DesktopSessionRuntimeInfo.fromJson(s);
      return true;
    },
  ),

  // ── RPC results ───────────────────────────────────────────────────────
  for (final method in const [
    'session.resume',
    'session.activate',
    'session.create',
  ])
    _Consumer('result', method, (c) => c.methodResultSchema(method), (s) {
      final snapshot = _snapshot(s, method);
      return snapshot.runtimeSessionId.isNotEmpty;
    }),
  _Consumer(
    'result',
    'session.active_list',
    (c) => c.methodResultSchema('session.active_list'),
    (s) {
      final list = DesktopActiveSessionList.fromJson(s);
      return !list.hasMalformedRows &&
          list.sessions.length == (s['sessions'] as List).length;
    },
  ),
  _Consumer(
    'result',
    'model.options',
    (c) => c.methodResultSchema('model.options'),
    (s) {
      final catalog = DesktopModelCatalog.fromJson(s);
      final rows = (s['providers'] as List).whereType<Map>().where(
        (row) => row['models'] is List && (row['models'] as List).isNotEmpty,
      );
      return catalog.providers.length >= rows.length;
    },
  ),
  for (final method in const ['prompt.btw', 'prompt.background'])
    _Consumer(
      'result',
      method,
      (c) => c.methodResultSchema(method),
      (s) => TuiGatewayClient.parseSideAgentTaskId(s) != null,
    ),
  for (final method in const ['session.branch', 'session.branch_whole'])
    _Consumer(
      'result',
      method,
      (c) => c.methodResultSchema(method),
      (s) => TuiGatewayClient.parseBranchResult(s) != null,
    ),
  _Consumer(
    'result',
    'subagent.list',
    (c) => c.schemaNamed('SubagentSnapshot'),
    (s) => DesktopSubagentSnapshot.tryParse(s) != null,
    // The list is the LIVE roster: a terminal row carries no card to keep,
    // its end arrives as subagent.complete (checked above).
    semanticallyEmpty: (s) => const {
      'completed',
      'failed',
      'error',
      'timeout',
      'interrupted',
    }.contains(s['status']),
  ),
  _Consumer(
    'result',
    'subagent.tail',
    (c) => c.methodResultSchema('subagent.tail'),
    (s) {
      DesktopSubagentTailResult.fromJson(s);
      return true;
    },
  ),
  _Consumer(
    'result',
    'subagent.steer',
    (c) => c.methodResultSchema('subagent.steer'),
    (s) {
      DesktopSubagentSteerResult.fromJson(
        s,
        requestedSubagentId: _id(s['subagent_id'], 'child-1'),
      );
      return true;
    },
  ),
  _Consumer(
    'result',
    'subagent.interrupt',
    (c) => c.methodResultSchema('subagent.interrupt'),
    (s) {
      DesktopSubagentInterruptResult.fromJson(
        s,
        requestedSubagentId: _id(s['subagent_id'], 'child-1'),
      );
      return true;
    },
  ),
  _Consumer(
    'result',
    'session.context_breakdown',
    (c) => c.methodResultSchema('session.context_breakdown'),
    (s) {
      DesktopContextBreakdown.fromJson(s);
      return true;
    },
  ),
  _Consumer(
    'result',
    'shell.exec',
    (c) => c.methodResultSchema('shell.exec'),
    (s) => ShellExecResult.tryParse(s) != null,
  ),
  _Consumer(
    'result',
    'process.list',
    (c) => c.methodResultSchema('process.list'),
    (s) {
      final rows = s['processes'];
      if (rows is! List) return false;
      for (final row in rows) {
        AgentProcessSeed.tryParse(row);
      }
      return true;
    },
    semanticallyEmpty: (s) => (s['processes'] as List?)?.isEmpty ?? true,
  ),
  for (final type in const ['agent.terminal.output', 'terminal.close'])
    _Consumer(
      'event',
      type,
      (c) => c.eventPayloadSchema(type),
      (s) => parseAgentTerminalEvent(s) != null,
    ),
  _Consumer(
    'result',
    'session.control.read',
    (c) => c.methodResultSchema('session.control.read'),
    (s) {
      SessionControlSnapshot.fromJson(s['control']);
      return true;
    },
  ),
  _Consumer(
    'result',
    'session.foreign.list',
    (c) => c.methodResultSchema('session.foreign.list'),
    (s) {
      final page = ForeignSessionPage.fromJson(s);
      return page.sessions.length ==
          ((s['sessions'] as List?) ?? const []).length;
    },
  ),
  _Consumer(
    'result',
    'session.foreign.preview',
    (c) => c.methodResultSchema('session.foreign.preview'),
    (s) {
      final preview = ForeignPreview.fromJson(s);
      return preview.messages.length ==
          ((s['messages'] as List?) ?? const []).length;
    },
  ),
  _Consumer(
    'result',
    'session.foreign.import',
    (c) => c.methodResultSchema('session.foreign.import'),
    (s) => ForeignImportResult.tryParse(s) != null,
  ),
  _Consumer(
    'result',
    'approval.respond',
    (c) => c.methodResultSchema('approval.respond'),
    (s) {
      DesktopApprovalResult.fromJson({...s, 'resolved': 1});
      return true;
    },
  ),
  for (final method in const ['clarify.lock', 'request.answer'])
    _Consumer('result', method, (c) => c.methodResultSchema(method), (s) {
      DesktopPromptResponse.fromJson(s, method: method, allowExpired: true);
      return true;
    }),
  _Consumer('result', 'config.set', (c) => c.methodResultSchema('config.set'), (
    s,
  ) {
    // key/value/scope echo what Console asked for (`<model> --session`): a
    // different key or scope is a refusal, not a shape question.
    DesktopConfigSetResult.fromJson({
      ...s,
      'key': 'model',
      'value': 'gpt-x',
      if (s['scope'] != null) 'scope': 'session',
    }, expectedKey: DesktopSessionConfigKey.model);
    return true;
  }),
  // A failed turn: the card reads `error_surface` and `billing`, each on its
  // own (`turnFailureMetadata`).
  _Consumer(
    'event',
    'message.complete',
    (c) => c.eventPayloadSchema('message.complete'),
    (s) {
      final metadata = turnFailureMetadata(
        errorSurface: s['error_surface'],
        billing: s['billing'],
      );
      if (_renderableSurface(s['error_surface']) &&
          metadata[turnErrorSurfaceKey] == null) {
        return false;
      }
      return !(_renderableBilling(s['billing']) &&
          metadata[turnBillingBlockKey] == null);
    },
    // Empty only when neither descriptor could be rendered: a layer Console
    // does not know and a billing block that names no provider.
    semanticallyEmpty: (s) =>
        (s['error_surface'] is Map || s['billing'] is Map) &&
        !_renderableSurface(s['error_surface']) &&
        !_renderableBilling(s['billing']),
  ),
  // Move a stored session to a project folder.
  _Consumer(
    'result',
    'session.workspace.move',
    (c) => c.methodResultSchema('session.workspace.move'),
    (s) => SessionWorkspaceMoveResult.tryParse(s) != null,
    // A result without a folder carries nothing to apply to the row.
    semanticallyEmpty: (s) =>
        s['cwd'] is! String || (s['cwd'] as String).trim().isEmpty,
  ),
  // Live MCP state for Diagnostics: every row with a name is kept.
  _Consumer(
    'result',
    'mcp.servers.status',
    (c) => c.methodResultSchema('mcp.servers.status'),
    (s) {
      final rows = (s['servers'] as List).cast<Map<String, dynamic>>();
      return rows
              .where((row) => McpServerStatus.tryParse(row) != null)
              .length ==
          rows.length;
    },
    // A row without a name has nothing to show.
    semanticallyEmpty: (s) => (s['servers'] as List).any(
      (row) => row is! Map || (row['name'] as String? ?? '').trim().isEmpty,
    ),
  ),
  _Consumer(
    'result',
    'session.events.since',
    (c) => c.methodResultSchema('session.events.since'),
    (s) {
      for (final entry in (s['open_requests'] as List).cast<Map>()) {
        final params = Map<String, dynamic>.from(entry['params'] as Map);
        final event = TuiGatewayClient.openServerRequestEvent({
          'id': 'srq-contract0002',
          'method': 'clarify',
          'params': {
            ...params,
            'session_id': 'runtime-contract',
            'question': 'Q?',
          },
        });
        if (event == null) return false;
      }
      return true;
    },
  ),
];

/// Unknown enum values a parser is allowed to reject as a whole because the
/// value IS the answer (an RPC status Console must not guess).
bool _unknownEnumMayFail(_Consumer consumer, String label) =>
    label.endsWith('=$contractUnknownEnumValue') &&
    const {
      'clarify.lock',
      'request.answer',
      'subagent.steer',
    }.contains(consumer.name);

void main() {
  final contract = GatewayContract.load();
  final sampler = ContractSampler(contract);

  test('the vendored contract is the pinned upstream copy', () {
    expect(contract.document['openrpc'], isA<String>());
    expect(contract.eventNames, isNotEmpty);
    expect(contract.serverRequestNames, isNotEmpty);
  });

  test('every consumed name exists in the contract', () {
    for (final consumer in _consumers) {
      final known = switch (consumer.kind) {
        'event' => contract.eventNames,
        'request' => contract.serverRequestNames,
        _ => contract.methodNames,
      };
      expect(known, contains(consumer.name), reason: consumer.name);
    }
  });

  group('parsers accept every contract shape without dropping it', () {
    for (final consumer in _consumers) {
      final id = '${consumer.kind} ${consumer.name}';
      test(id, () {
        final failures = <String>[];
        for (final sample in sampler.samples(consumer.schema(contract))) {
          final value = sample.value;
          if (consumer.semanticallyEmpty?.call(value) == true) continue;
          try {
            if (!consumer.parse(value)) {
              failures.add('DROPPED ${sample.label}');
            }
          } catch (error) {
            if (_unknownEnumMayFail(consumer, sample.label)) continue;
            failures.add('THREW ${sample.label}: $error');
          }
        }
        expect(failures, isEmpty, reason: failures.join('\n'));
      });
    }
  });

  group('the wire envelope accepts every contract frame', () {
    for (final event in contract.eventNames.toList()..sort()) {
      test('event $event', () {
        final failures = <String>[];
        for (final sample in sampler.samples(
          contract.eventPayloadSchema(event),
        )) {
          final frame = {
            'jsonrpc': '2.0',
            'method': 'event',
            'params': {
              'type': event,
              'session_id': 'runtime-contract',
              'seq': 7,
              'payload': sample.value,
            },
          };
          try {
            final parsed = JsonRpcWireDecoder.decodeText(
              _encode(frame),
              replayCapable: true,
            );
            if (parsed is! JsonRpcEventFrame ||
                parsed.event.type != event ||
                parsed.event.payload.length != sample.value.length) {
              failures.add('DROPPED ${sample.label}');
            }
          } catch (error) {
            failures.add('THREW ${sample.label}: $error');
          }
        }
        expect(failures, isEmpty, reason: failures.join('\n'));
      });
    }
    for (final method in contract.serverRequestNames.toList()..sort()) {
      test('server request $method', () {
        final failures = <String>[];
        for (final sample in sampler.samples(
          contract.serverRequestParamsSchema(method),
        )) {
          final frame = {
            'jsonrpc': '2.0',
            'id': 'srq-contract0003',
            'method': method,
            'params': sample.value,
          };
          try {
            final parsed = JsonRpcWireDecoder.decodeText(
              _encode(frame),
              replayCapable: true,
            );
            if (parsed is! JsonRpcServerRequestFrame ||
                parsed.method != method ||
                parsed.params.length != sample.value.length) {
              failures.add('DROPPED ${sample.label}');
            }
          } catch (error) {
            failures.add('THREW ${sample.label}: $error');
          }
        }
        expect(failures, isEmpty, reason: failures.join('\n'));
      });
    }
  });
  group('the real transport adopts every contract gateway.ready', () {
    for (final sample in sampler.samples(
      contract.eventPayloadSchema('gateway.ready'),
    )) {
      test(sample.label, () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((request) async {
          final socket = await WebSocketTransformer.upgrade(request);
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'method': 'event',
              'params': {'type': 'gateway.ready', 'payload': sample.value},
            }),
          );
          await for (final raw in socket) {
            final frame = jsonDecode(raw as String) as Map<String, dynamic>;
            if (frame['method'] is! String) continue;
            socket.add(
              jsonEncode({
                'jsonrpc': '2.0',
                'id': frame['id'],
                'result': <String, dynamic>{},
              }),
            );
          }
        });
        final client = TuiGatewayClient(
          SavedConnection(
            id: 'conn-contract',
            label: 'Contract',
            host: '127.0.0.1',
            port: 8642,
            apiKey: 'unused',
            dashboardUrl: 'http://127.0.0.1:${server.port}',
          ),
          dashboard: _TicketDashboardClient(),
        );
        addTearDown(client.close);

        await client.connect().timeout(const Duration(seconds: 3));

        expect(client.isConnected, isTrue);
        expect(
          client.changeEventsAvailable,
          sample.value['change_events'] == true,
        );
      });
    }
  });
}

class _TicketDashboardClient extends DashboardClient {
  _TicketDashboardClient()
    : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(queryName: 'ticket', credential: 'contract');
}

String _encode(Object value) => jsonEncode(value);
