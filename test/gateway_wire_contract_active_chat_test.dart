// Every event Hermes' wire contract publishes, in every generated shape, is
// delivered to a live ActiveChat through the real `_onDesktopEvent` dispatch.
// No contract-valid payload may throw inside the handler (an uncaught error
// in the event listener fails the test). Each event is either HANDLED — and
// then every sample must produce the observable effect listed in [_handled],
// so a handler turned into a no-op fails — or listed in [_ignored] with the
// reason the chat deliberately does nothing, and then it must stay inert.
// The two lists partition the contract exactly.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/connection_request.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/contract/gateway_contract.dart';
import 'support/in_memory_compression_restore_storage.dart';

class _FakeDesktopGateway implements HermesDesktopGateway {
  final StreamController<TuiGatewayEvent> _events =
      StreamController<TuiGatewayEvent>.broadcast(sync: true);

  @override
  Stream<TuiGatewayEvent> get events => _events.stream;

  @override
  bool get isConnected => true;

  @override
  Future<void> connect() async {}

  @override
  Future<DesktopSessionBinding> resumeSession(
    String storedSessionId, {
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => DesktopSessionBinding(
    runtimeSessionId: 'runtime-contract',
    storedSessionId: storedSessionId,
    created: false,
  );

  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async {}

  @override
  Future<void> steer(String runtimeSessionId, String text) async {}

  @override
  Future<void> interrupt(String runtimeSessionId) async {}

  @override
  Future<void> resolveApproval(
    String runtimeSessionId,
    String choice, {
    bool resolveAll = false,
    String? requestId,
  }) async {}

  @override
  Future<void> close() async {}

  void emit(String type, Map<String, dynamic> payload) => _events.add(
    TuiGatewayEvent(
      type: type,
      sessionId: 'runtime-contract',
      payload: Map<String, dynamic>.unmodifiable(payload),
    ),
  );
}

Future<ActiveChat> _liveChat(_FakeDesktopGateway gateway) async {
  final chat = ActiveChat(
    compressionRestoreStore: testCompressionRestoreStore(),
    connection: SavedConnection(
      id: 'conn-contract',
      label: 'Contract',
      host: 'example.invalid',
      port: 443,
      apiKey: 'unused',
      useHttps: true,
      kind: InstanceKind.vps,
    ),
    sessionId: 'stored-contract',
    sessionTitle: 'Contract',
    notifications: null,
    onTerminal: () {},
    api: ApiClient(
      baseUrl: 'https://example.invalid',
      apiKey: 'unused',
      httpClient: MockClient((_) async => http.Response('unused', 500)),
    ),
    desktopGateway: gateway,
  );
  addTearDown(chat.dispose);
  expect(
    await chat.send(fullText: 'hola', model: 'hermes-agent', history: const []),
    isTrue,
  );
  return chat;
}

/// What a handled event must visibly do to a live chat.
final class _Effect {
  /// Contract-valid variant of a generated sample that carries the content
  /// the effect needs (e.g. a real task row where the schema says `items: {}`).
  /// When set, the effect is asserted on the enriched variants only; the raw
  /// samples must still be handled without throwing.
  final Map<String, dynamic> Function(Map<String, dynamic> sample)? enrich;

  /// Puts the chat in the state the event is addressed to.
  final void Function(ActiveChat chat)? prepare;

  /// Waits for deferred effects (the 30 Hz token flush).
  final Duration settle;

  /// Asserts the effect; returns false when this sample carries nothing the
  /// handler should render (it must then still not throw).
  final bool Function(
    ActiveChat chat,
    Map<String, dynamic> payload,
    List<ActiveChatEvent> emitted,
    String label,
  )
  check;

  const _Effect(
    this.check, {
    this.enrich,
    this.prepare,
    this.settle = Duration.zero,
  });
}

bool _nonEmpty(Object? value) => value is String && value.trim().isNotEmpty;

bool _emits(
  List<ActiveChatEvent> emitted,
  ActiveChatEvent expected,
  String label,
) {
  expect(emitted, contains(expected), reason: label);
  return true;
}

_Effect _emitsAlways(ActiveChatEvent event) =>
    _Effect((_, _, emitted, label) => _emits(emitted, event, label));

/// A child event opens or updates the card it names; one naming no child
/// carries nothing to render.
final _subagentEffect = _Effect((_, payload, emitted, label) {
  if (!_nonEmpty(payload['subagent_id'])) return false;
  return _emits(emitted, ActiveChatEvent.subagentActivity, label);
});

final _reasoningEffect = _Effect((chat, payload, emitted, label) {
  if (!_nonEmpty(payload['text'])) return false;
  expect(chat.state, ChatPipelineState.executing, reason: label);
  return _emits(emitted, ActiveChatEvent.toolProgress, label);
});

final _toolRunningEffect = _Effect((chat, _, emitted, label) {
  expect(chat.state, ChatPipelineState.executing, reason: label);
  return _emits(emitted, ActiveChatEvent.toolProgress, label);
});

/// The gateway of the sample under test, for effects that need a prior frame.
_FakeDesktopGateway? _sampleGateway;

/// A request that can be bound to a tool row opens the card; one that cannot
/// carries nothing to render.
final _connectionRequestEffect = _Effect((chat, payload, emitted, label) {
  if (normalizeConnectionRequest(payload) == null) return false;
  expect(chat.connectionRequest, isNotNull, reason: label);
  return _emits(emitted, ActiveChatEvent.toolProgress, label);
});

const _wireOp = 'op-wire';

/// An update advances the open card it names (seeded by `prepare`).
final _connectionUpdateEffect = _Effect(
  prepare: (_) => _sampleGateway!.emit('connection.request', {
    'op_id': _wireOp,
    'seq': 1,
    'deadline_at': 1790000000.0,
    'tool_call_id': 'call-wire',
    'targets': [
      {'name': 'gmail', 'kind': 'connector', 'action': 'authorize'},
    ],
  }),
  enrich: (sample) => {...sample, 'op_id': _wireOp, 'seq': 50},
  (chat, payload, emitted, label) {
    expect(chat.connectionRequest!.seq, 50, reason: label);
    return _emits(emitted, ActiveChatEvent.toolProgress, label);
  },
);

/// Events the live chat renders or acts on, with the effect each must show.
final Map<String, _Effect> _handled = {
  'connection.request': _connectionRequestEffect,
  'connection.update': _connectionUpdateEffect,
  'message.start': _emitsAlways(ActiveChatEvent.waiting),
  'message.delta': _Effect(settle: const Duration(milliseconds: 150), (
    chat,
    payload,
    emitted,
    label,
  ) {
    if (!_nonEmpty(payload['text'])) return false;
    expect(chat.assistantContent, contains(payload['text']), reason: label);
    return _emits(emitted, ActiveChatEvent.token, label);
  }),
  'message.interim': _Effect((chat, payload, emitted, label) {
    if (!_nonEmpty(payload['text'])) return false;
    return _emits(emitted, ActiveChatEvent.toolProgress, label);
  }),
  'reasoning.delta': _reasoningEffect,
  'thinking.delta': _reasoningEffect,
  'reasoning.available': _reasoningEffect,
  'tool.start': _toolRunningEffect,
  'tool.generating': _toolRunningEffect,
  'tool.complete': _emitsAlways(ActiveChatEvent.toolProgress),
  // Every completion settles the open turn; an empty one may settle through
  // transcript recovery without a `done` emission, a failed one reports it.
  'message.complete': _Effect((chat, payload, emitted, label) {
    expect(chat.isStreaming, isFalse, reason: label);
    if ((payload['status'] ?? '').toString().trim().toLowerCase() == 'error') {
      _emits(emitted, ActiveChatEvent.error, label);
    }
    return true;
  }),
  'error': _emitsAlways(ActiveChatEvent.error),
  // An empty info (every field optional) changes nothing; a model does.
  'session.info': _Effect((_, payload, emitted, label) {
    if (!_nonEmpty(payload['model'])) return false;
    return _emits(emitted, ActiveChatEvent.sessionInfo, label);
  }),
  'sessions.changed': _emitsAlways(ActiveChatEvent.sessionInfo),
  'session.control.update': _emitsAlways(ActiveChatEvent.goalUpdated),
  'session.reclaimed': _Effect(
    enrich: (sample) => {
      ...sample,
      'session_id': 'runtime-contract',
      'stored_session_id': 'stored-contract',
    },
    prepare: (chat) => chat.markDesktopRuntimeConsoleOwnedForTesting(),
    (_, _, emitted, label) =>
        _emits(emitted, ActiveChatEvent.sessionInfo, label),
  ),
  'session.resume_progress': _Effect((chat, payload, _, label) {
    final status = payload['status'];
    if (status is! String) return false;
    final hydrating = switch (status) {
      'loading' => true,
      'complete' || 'failed' => false,
      _ => null,
    };
    if (hydrating == null) return false;
    expect(chat.isHydratingDesktopHistory, hydrating, reason: label);
    return true;
  }),
  'status.update': _Effect(
    enrich: (sample) => {...sample, 'kind': 'compacting'},
    (chat, _, _, label) {
      expect(chat.desktopCompressionInFlight, isTrue, reason: label);
      return true;
    },
  ),
  'todo.updated': _Effect(
    enrich: (sample) => {
      ...sample,
      'todos': [
        {'id': 'task-contract', 'content': 'Contract task'},
      ],
    },
    (chat, _, _, label) {
      expect(chat.agentTasks.items.map((item) => item.id), [
        'task-contract',
      ], reason: label);
      return true;
    },
  ),
  'background.complete': _Effect((chat, payload, emitted, label) {
    final taskId = payload['task_id'];
    if (!_nonEmpty(taskId)) return false;
    expect(
      chat.backgroundTaskOutcomes.containsKey((taskId as String).trim()),
      isTrue,
      reason: label,
    );
    return _emits(emitted, ActiveChatEvent.backgroundTaskComplete, label);
  }),
  'btw.complete': _Effect((chat, payload, emitted, label) {
    final taskId = payload['task_id'];
    if (!_nonEmpty(taskId) || !_nonEmpty(payload['text'])) return false;
    expect(
      chat.messages.any(
        (message) =>
            message['display_kind'] == 'side_answer' &&
            message['_btwTaskId'] == (taskId as String).trim(),
      ),
      isTrue,
      reason: label,
    );
    return _emits(emitted, ActiveChatEvent.backgroundTaskComplete, label);
  }),
  'message.reaction': _Effect((chat, payload, emitted, label) {
    final row = payload['row_id'];
    if (row is! int) return false;
    expect(chat.reactionsFor(row), isNotNull, reason: label);
    return _emits(emitted, ActiveChatEvent.reactionsChanged, label);
  }),
  'agent.terminal.output': _emitsAlways(ActiveChatEvent.subagentActivity),
  'terminal.close': _emitsAlways(ActiveChatEvent.subagentActivity),
  for (final type in const [
    'subagent.spawn_requested',
    'subagent.start',
    'subagent.thinking',
    'subagent.tool',
    'subagent.progress',
    'subagent.complete',
  ])
    type: _subagentEffect,
};

const _desktopOnly =
    'Desktop-only surface (window, voice, preview, pet, setup, billing, '
    'browser, MoA, notifications); the chat has no view for it';

/// Events the live chat deliberately does nothing with, and why. Each must
/// stay inert: a new handler has to move its event to [_handled].
const Map<String, String> _ignored = {
  'gateway.ready':
      'transport handshake consumed by TuiGatewayClient.connect before any '
      'chat binds',
  'request.cancel':
      'the transport re-emits it as the matching *.expire '
      '(_translateRequestCancel); raw, it only confirms an interrupt the '
      'user started (covered by the stop tests)',
  'session.title': 'titles are read from the session list, not the live chat',
  'session.usage': 'usage is read by session.info / context breakdown',
  'cron.changed': 'consumed by the cron screens, not the chat',
  'pet.changed': 'consumed by ProfilePetService, not the chat',
  'projects.changed': 'no projects view in the chat',
  'platforms.changed': 'no platforms view in the chat',
  'pairing.changed': 'no pairing view in the chat',
  'bot_relay.outbox.pending': 'bot relay is a gateway-side queue',
  'reaction': 'legacy spelling of message.reaction; Console reads the new one',
  'review.summary': 'review panes are Desktop-only',
  'tool.output_risk': 'risk banner is Desktop-only',
  'notice': _desktopOnly,
  'tip.show': _desktopOnly,
  'skin.changed': _desktopOnly,
  'setup.ready': _desktopOnly,
  'layout.apply': _desktopOnly,
  'pane.reveal': _desktopOnly,
  'notification.show': _desktopOnly,
  'notification.clear': _desktopOnly,
  'billing.step_up.verification': _desktopOnly,
  'browser.controller.cancel': _desktopOnly,
  'browser.controller.command': _desktopOnly,
  'browser.progress': _desktopOnly,
  'display.install.done': _desktopOnly,
  'display.install.log': _desktopOnly,
  'display.lease': _desktopOnly,
  'display.status': _desktopOnly,
  'moa.aggregating': _desktopOnly,
  'moa.phase': _desktopOnly,
  'moa.progress': _desktopOnly,
  'moa.reference': _desktopOnly,
  'pet.generate.progress': _desktopOnly,
  'pet.hatch.progress': _desktopOnly,
  'preview.close': _desktopOnly,
  'preview.open': _desktopOnly,
  'preview.restart.complete': _desktopOnly,
  'preview.restart.progress': _desktopOnly,
  'voice.interrupted': _desktopOnly,
  'voice.status': _desktopOnly,
  'voice.transcript': _desktopOnly,
  'wake.detected': _desktopOnly,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  final contract = GatewayContract.load();
  final sampler = ContractSampler(contract);

  // Terminal events end the live turn, after which the chat (correctly)
  // ignores later turn events; run them last so every other one is seen by
  // an open turn.
  const terminal = {'message.complete', 'error'};
  final events = contract.eventNames.toList()
    ..sort((a, b) {
      final rank =
          (terminal.contains(a) ? 1 : 0) - (terminal.contains(b) ? 1 : 0);
      return rank != 0 ? rank : a.compareTo(b);
    });

  test('handled and ignored events partition the contract exactly', () {
    final handled = _handled.keys.toSet();
    final ignored = _ignored.keys.toSet();
    expect(handled.intersection(ignored), isEmpty);
    expect(handled.union(ignored), contract.eventNames);
  });

  for (final event in events) {
    final effect = _handled[event];
    final kind = effect == null ? 'ignores' : 'handles';
    test('ActiveChat $kind every contract shape of $event', () async {
      var asserted = 0;
      final samples = sampler.samples(contract.eventPayloadSchema(event));
      final enrich = effect?.enrich;
      final payloads = [
        for (final sample in samples) (sample.label, sample.value, false),
        if (enrich != null)
          for (final sample in samples)
            ('${sample.label} (enriched)', enrich(sample.value), true),
      ];
      for (final (label, payload, enriched) in payloads) {
        // A fresh live turn per sample: one shape must not hide another.
        final gateway = _FakeDesktopGateway();
        final chat = await _liveChat(gateway);
        _sampleGateway = gateway;
        await Future<void>.delayed(Duration.zero);
        effect?.prepare?.call(chat);
        final emitted = <ActiveChatEvent>[];
        final subscription = chat.changes.listen(emitted.add);
        addTearDown(subscription.cancel);
        final stateBefore = chat.state;
        gateway.emit(event, payload);
        await Future<void>.delayed(effect?.settle ?? Duration.zero);
        expect(chat.sessionId, 'stored-contract', reason: label);
        if (effect == null) {
          expect(emitted, isEmpty, reason: '$label: ${_ignored[event]}');
          expect(chat.state, stateBefore, reason: label);
        } else if ((enrich == null || enriched) &&
            effect.check(chat, payload, emitted, label)) {
          asserted++;
        }
      }
      if (effect != null) {
        expect(asserted, greaterThan(0), reason: 'no sample showed the effect');
      }
    });
  }
}
