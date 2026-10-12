// Drift check between the names Console speaks on the gateway socket and the
// names Hermes' published wire contract defines
// (test/fixtures/contract/gateway-contract.openrpc.json).
//
// Every RPC method Console calls and every event type its gateway consumers
// branch on must either exist in the contract or be listed below with the
// reason it is allowed to differ. The list is exact in both directions: a new
// undeclared name fails, and so does a listed name Console no longer uses, so
// the report stays truthful when the contract is refreshed.
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/contract/gateway_contract.dart';

/// RPC methods Console still calls although the contract does not define
/// them. Each is a guarded fallback for older or newer gateways.
const _knownMethodDrift = <String, String>{
  'clarify.respond':
      'legacy (pre-v7) answer RPC; only used after request.answer/clarify.lock '
      'answer -32601',
  'sudo.respond': 'legacy answer RPC for gateways without server requests',
  'secret.respond': 'legacy answer RPC for gateways without server requests',
  'terminal.read.respond':
      'legacy answer RPC for gateways without server requests',
  'gateway.ping':
      'WebSocket-level heartbeat answered by tui_gateway/ws.py before '
      'JSON-RPC dispatch, so it never appears in the method registry',
  'turn.status':
      'idempotent turn probe of the exclusive-submit extension; Console '
      'treats a missing method as "unknown" and falls back',
};

/// Event types Console branches on that the contract does not publish.
final _knownEventDrift = <String, String>{
  'approval.request':
      'transport-adapted: the `approval` server request is re-emitted under '
      'its legacy event name (tui_gateway_client._serverRequestLegacyEvents)',
  'clarify.request': 'transport-adapted `clarify` server request',
  'sudo.request': 'transport-adapted `sudo` server request',
  'secret.request': 'transport-adapted `secret` server request',
  'terminal.read.request': 'transport-adapted `terminal.read` server request',
  'approval.responded':
      'transport-adapted `request.cancel` for an approval '
      '(_translateRequestCancel)',
  'clarify.expire': 'transport-adapted `request.cancel`',
  'sudo.expire': 'transport-adapted `request.cancel`',
  'secret.expire': 'transport-adapted `request.cancel`',
  'terminal.read.expire': 'transport-adapted `request.cancel`',
  for (final kind in const [
    'vault.unlock',
    'vault.save_login',
    'vault.code',
  ]) ...{
    '$kind.request': 'transport-adapted vault server request',
    '$kind.expire': 'transport-adapted `request.cancel`',
    '$kind.expired': 'legacy expiry spelling of pre-v7 gateways',
  },
  'mcp.setup':
      'blocking-prompt family of older gateways '
      '(global_activity_aggregate._blockingPromptFamily); no longer sent',
  'message.user':
      'hosted-room log event kind (groups.log), not a socket event type',
  'gateway.ping': 'WebSocket heartbeat frame, filtered before dispatch',
  'gateway.pong': 'WebSocket heartbeat frame, filtered before dispatch',
  'session.closed': 'legacy terminal event of pre-0.19 gateways',
  'tool.progress': 'legacy progress event of pre-0.19 gateways',
  'subagent.text': 'legacy child text event of pre-0.19 gateways',
  'tool.started': 'Runs API (/v1/runs SSE), not the gateway socket',
  'tool.completed': 'Runs API (/v1/runs SSE), not the gateway socket',
  'run.completed': 'Runs API (/v1/runs SSE), not the gateway socket',
  'run.failed': 'Runs API (/v1/runs SSE), not the gateway socket',
  'run.cancelled': 'Runs API (/v1/runs SSE), not the gateway socket',
};

/// Files whose event switches read the gateway event stream.
const _eventConsumerFiles = <String>[
  'lib/core/services/tui_gateway_client.dart',
  'lib/core/services/active_chat_service.dart',
  'lib/core/services/global_activity_aggregate.dart',
  'lib/core/services/profile_pet_service.dart',
  'lib/core/models/subagent_activity.dart',
  'lib/core/screens/session_list_screen.dart',
  'lib/core/screens/mission_control_screen.dart',
  'lib/core/screens/cron_screen.dart',
  'lib/core/screens/cron_detail_page.dart',
];

const _name = r"'([a-z_]+(?:\.[a-z_]+)+)'";

/// Calls that put a method name on the gateway socket.
final _rpcCall = RegExp(
  r'\b(?:_request|_requestConnected|_requestOptionalCapability|'
  r'_requestExclusiveSessionMutation|_controlRequest|_requestGroupOnLease|'
  r'_requestSessionRosterLease|_rpc|rpc|request|roomLinkRequest|_logRead|'
  r'_logWrite)\(\s*(?:[\w.]+,\s*)?'
  '$_name',
);
final _methodConst = RegExp(
  r'\bconst\s+(?:String\s+)?(?:method|\w+Method)\s*=\s*' + _name,
);
final _methodNamedArg = RegExp(r'\bmethod:\s*' + _name);
final _eventBranch = RegExp(
  r'\btype\s*[!=]=\s*' + _name + r'|\bcase\s+' + _name,
);
// Switch-expression arms: `'message.delta' || 'message.interim' => …`.
final _eventArm = RegExp(_name + r'\s*(?:=>|\|\|)');
final _eventSetBranch = RegExp(
  r'const\s*\{([^{}]*)\}\s*\.contains\(\s*(?:event\.)?type\)',
);
final _literal = RegExp(_name);

Map<String, Set<String>> _scan(Iterable<File> files, List<RegExp> patterns) {
  final found = <String, Set<String>>{};
  for (final file in files) {
    final source = file.readAsStringSync();
    for (final pattern in patterns) {
      for (final match in pattern.allMatches(source)) {
        final groups = [
          for (var i = 1; i <= match.groupCount; i++) match.group(i),
        ].whereType<String>();
        for (final group in groups) {
          final names = group.startsWith("'") || group.contains(',')
              ? _literal.allMatches(group).map((m) => m.group(1)!)
              : [group];
          for (final name in names) {
            (found[name] ??= <String>{}).add(file.path);
          }
        }
      }
    }
  }
  return found;
}

String _report(String title, Map<String, Set<String>> names, Set<String> ok) {
  final lines = [
    for (final name in names.keys.toList()..sort())
      if (!ok.contains(name)) '  $name  (${names[name]!.join(', ')})',
  ];
  return '$title:\n${lines.join('\n')}';
}

void main() {
  final contract = GatewayContract.load();
  final libFiles = Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => file.path.endsWith('.dart'));

  test('every RPC method Console calls is defined or a declared fallback', () {
    final called = _scan(libFiles, [_rpcCall, _methodConst, _methodNamedArg]);
    final drift = {
      for (final name in called.keys)
        if (!contract.methodNames.contains(name)) name,
    };
    // ignore: avoid_print
    print(
      'contract drift report — methods: ${called.length} called, '
      '${called.length - drift.length} in contract, ${drift.length} drift\n'
      '${_report('undeclared by contract', called, contract.methodNames)}',
    );
    expect(called.length, greaterThan(50), reason: 'scanner lost the calls');
    expect(
      drift.difference(_knownMethodDrift.keys.toSet()),
      isEmpty,
      reason: 'called but neither defined nor declared',
    );
    expect(
      _knownMethodDrift.keys.toSet().difference(drift),
      isEmpty,
      reason: 'declared drift no longer called: drop it from the list',
    );
  });

  test('every event Console branches on is published or declared', () {
    final consumed = _scan(_eventConsumerFiles.map(File.new), [
      _eventBranch,
      _eventArm,
      _eventSetBranch,
    ]);
    final known = {...contract.eventNames, ...contract.serverRequestNames};
    final drift = {
      for (final name in consumed.keys)
        if (!known.contains(name)) name,
    };
    // ignore: avoid_print
    print(
      'contract drift report — events: ${consumed.length} consumed, '
      '${consumed.length - drift.length} in contract, ${drift.length} drift\n'
      '${_report('undeclared by contract', consumed, known)}',
    );
    expect(consumed.length, greaterThan(30), reason: 'scanner lost events');
    expect(
      drift.difference(_knownEventDrift.keys.toSet()),
      isEmpty,
      reason: 'consumed but neither published nor declared',
    );
    expect(
      _knownEventDrift.keys.toSet().difference(drift),
      isEmpty,
      reason: 'declared drift no longer consumed: drop it from the list',
    );
  });

  test('the vendored contract records its upstream source', () {
    final source = File('test/fixtures/contract/SOURCE').readAsStringSync();
    String field(String key) =>
        RegExp('^$key: (.+)\$', multiLine: true)
            .firstMatch(source)
            ?.group(1)
            ?.trim() ??
        (throw StateError('SOURCE has no $key'));
    final commit = RegExp(r'^[0-9a-f]{40}$');
    expect(field('checkout_commit'), matches(commit));
    expect(field('contract_last_changed_commit'), matches(commit));
    // The recorded digest must name the bytes actually vendored: a hand-edited
    // or partially refreshed copy fails here.
    final vendored = File(
      'test/fixtures/contract/gateway-contract.openrpc.json',
    ).readAsBytesSync();
    expect(field('sha256'), sha256.convert(vendored).toString());
    expect(
      File('tool/contract/update_contract.sh').existsSync(),
      isTrue,
      reason: 'the refresh script must stay next to the vendored copy',
    );
  });
}
