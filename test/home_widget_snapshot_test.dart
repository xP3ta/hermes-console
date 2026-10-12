import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/home_widget_snapshot.dart';
import 'package:hermes_android/core/services/home_widget_publisher.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';

class _FakeStore implements HomeWidgetStore {
  final values = <String, Object?>{};
  final writes = <String>[];
  int updates = 0;
  bool failNextUpdate = false;

  @override
  Future<Object?> read(String key) async => values[key];

  @override
  Future<void> requestUpdate() async {
    if (failNextUpdate) {
      failNextUpdate = false;
      throw StateError('launcher unavailable');
    }
    updates++;
  }

  @override
  Future<void> write(String key, Object? value) async {
    writes.add(key);
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }
}

Future<void> _waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue);
}

void main() {
  test(
    'el reducer publica exactamente el contexto aceptado por el chat',
    () async {
      final store = _FakeStore();
      final publisher = HermesHomeWidgetPublisher(
        store: store,
        nowMs: () => 1234,
      );
      final service = ActiveChatService();
      service.bindHomeWidgetPublisher(publisher, activeConnectionId: 'demo');
      final connection = SavedConnection(
        id: 'demo',
        label: 'Server',
        host: '127.0.0.1',
        port: 8642,
        apiKey: 'test-only',
      );
      final chat = service.attach(
        connection: connection,
        sessionId: 'session-1',
        sessionTitle: 'Contexto',
        disableForegroundKeepAlive: true,
      );

      service.updateHomeWidgetSessionContext(
        chat,
        contextUsed: 330,
        contextMax: 1000,
        contextPercent: 33,
      );
      await _waitFor(() => publisher.latest.contextPercent == 33);

      expect(publisher.latest.contextUsed, 330);
      expect(publisher.latest.contextMax, 1000);
      expect(store.values['hermes_widget_context_used'], 330);
      expect(store.values['hermes_widget_context_max'], 1000);
      expect(store.values['hermes_widget_context_percent'], 33);

      service.updateHomeWidgetSessionContext(
        chat,
        contextUsed: null,
        contextMax: null,
        contextPercent: null,
      );
      await _waitFor(() => publisher.latest.contextUsed == null);
      expect(store.values.containsKey('hermes_widget_context_used'), isFalse);
      expect(store.values.containsKey('hermes_widget_context_max'), isFalse);
      expect(
        store.values.containsKey('hermes_widget_context_percent'),
        isFalse,
      );
      service.dispose();
    },
  );

  test(
    'reanudar la misma sesión no reemplaza su título por Untitled',
    () async {
      final store = _FakeStore();
      final publisher = HermesHomeWidgetPublisher(
        store: store,
        nowMs: () => 1234,
      );
      await publisher.publish(
        const HermesHomeWidgetSnapshot(
          configured: true,
          instanceId: 'demo',
          instanceLabel: 'Server',
          connectionState: HomeWidgetConnectionState.connected,
          sessionId: 'session-1',
          sessionTitle: 'Resumen diario',
          agentState: HomeWidgetAgentState.idle,
        ),
      );
      final service = ActiveChatService();
      service.bindHomeWidgetPublisher(publisher, activeConnectionId: 'demo');
      final chat = service.attach(
        connection: SavedConnection(
          id: 'demo',
          label: 'Server',
          host: '127.0.0.1',
          port: 8642,
          apiKey: 'test-only',
        ),
        sessionId: 'session-1',
        sessionTitle: 'Untitled',
        disableForegroundKeepAlive: true,
      );

      service.updateHomeWidgetSessionContext(
        chat,
        contextUsed: 170,
        contextMax: 1000,
        contextPercent: 17,
      );
      await _waitFor(() => publisher.latest.contextPercent == 17);

      expect(publisher.latest.sessionTitle, 'Resumen diario');
      expect(
        publisher.latest.connectionState,
        HomeWidgetConnectionState.connected,
      );
      service.dispose();
    },
  );

  group('HermesHomeWidgetSnapshot', () {
    test('round-trips bounded non-sensitive state', () {
      const snapshot = HermesHomeWidgetSnapshot(
        configured: true,
        instanceId: 'demo-1',
        instanceLabel: 'Server',
        connectionState: HomeWidgetConnectionState.connected,
        model: 'gpt-5.5',
        provider: 'openai-codex',
        sessionId: 'session:1',
        sessionTitle: 'Auditoría',
        agentState: HomeWidgetAgentState.toolExecution,
        toolName: 'shell',
        contextUsed: 72000,
        contextMax: 100000,
        contextPercent: 72,
        inputTokens: 10000,
        outputTokens: 2400,
        cacheReadTokens: 4000,
        cacheWriteTokens: 500,
        firstTokenLatencyMs: 840,
        lastActivityAtMs: 900,
        updatedAtMs: 1000,
        theme: HomeWidgetTheme.oled,
      );

      expect(HermesHomeWidgetSnapshot.fromMap(snapshot.toMap()), snapshot);
      expect(snapshot.cachePercent, 28);
      expect(snapshot.toMap().keys, isNot(contains('api_key')));
      expect(snapshot.toMap().keys, isNot(contains('url')));
      expect(snapshot.toMap().keys, isNot(contains('prompt')));
    });

    test('unknown schema and corrupt values fail closed', () {
      expect(
        HermesHomeWidgetSnapshot.fromMap({'schema_version': 9}),
        HermesHomeWidgetSnapshot.empty,
      );
      final parsed = HermesHomeWidgetSnapshot.fromMap({
        'schema_version': 1,
        'configured': true,
        'instance_id': '../token',
        'connection_state': 'rooted',
        'agent_state': 'hallucinating',
        'context_used': -1,
        'context_max': 0,
        'context_percent': 500,
        'updated_at_ms': 'oops',
      });
      expect(parsed.instanceId, isNull);
      expect(parsed.connectionState, HomeWidgetConnectionState.unconfigured);
      expect(parsed.agentState, HomeWidgetAgentState.disconnected);
      expect(parsed.contextUsed, isNull);
      expect(parsed.contextPercent, isNull);
      expect(parsed.updatedAtMs, 0);
    });

    test('staleness is derived from the publication timestamp', () {
      final snapshot = HermesHomeWidgetSnapshot(
        updatedAtMs: DateTime(2026, 8, 2, 12).millisecondsSinceEpoch,
      );
      expect(
        snapshot.isStaleAt(DateTime(2026, 8, 2, 12, 14).millisecondsSinceEpoch),
        isFalse,
      );
      expect(
        snapshot.isStaleAt(DateTime(2026, 8, 2, 12, 16).millisecondsSinceEpoch),
        isTrue,
      );
    });
  });

  group('HermesHomeWidgetPublisher', () {
    test('cold-start base preserves known session for the same instance', () {
      const persisted = HermesHomeWidgetSnapshot(
        configured: true,
        instanceId: 'demo',
        instanceLabel: 'Server',
        connectionState: HomeWidgetConnectionState.connected,
        model: 'gpt-5.5',
        provider: 'openai-codex',
        sessionId: 'session:1',
        sessionTitle: 'Persisted',
        inputTokens: 0,
        outputTokens: 812,
        cacheReadTokens: 348160,
        firstTokenLatencyMs: 2076,
        lastActivityAtMs: 1900,
        updatedAtMs: 2000,
      );

      final merged = mergeHomeWidgetBaseSnapshot(
        current: persisted,
        configured: true,
        instanceId: 'demo',
        instanceLabel: 'Server actualizado',
        connectionState: HomeWidgetConnectionState.connecting,
        agentState: HomeWidgetAgentState.idle,
        theme: HomeWidgetTheme.oled,
      );

      expect(merged.sessionId, 'session:1');
      expect(merged.sessionTitle, 'Persisted');
      expect(merged.model, 'gpt-5.5');
      expect(merged.provider, 'openai-codex');
      expect(merged.inputTokens, 0);
      expect(merged.outputTokens, 812);
      expect(merged.cacheReadTokens, 348160);
      expect(merged.firstTokenLatencyMs, 2076);
      expect(merged.lastActivityAtMs, 1900);
      expect(merged.instanceLabel, 'Server actualizado');
      expect(merged.connectionState, HomeWidgetConnectionState.connected);
      expect(merged.agentState, HomeWidgetAgentState.idle);
      expect(merged.theme, HomeWidgetTheme.oled);
    });

    test('base refresh preserves confirmed live agent state', () {
      const persisted = HermesHomeWidgetSnapshot(
        configured: true,
        instanceId: 'demo',
        connectionState: HomeWidgetConnectionState.connected,
        agentState: HomeWidgetAgentState.toolExecution,
        toolName: 'shell',
      );

      final merged = mergeHomeWidgetBaseSnapshot(
        current: persisted,
        configured: true,
        instanceId: 'demo',
        instanceLabel: 'Server',
        connectionState: HomeWidgetConnectionState.connecting,
        agentState: HomeWidgetAgentState.idle,
        theme: HomeWidgetTheme.dark,
      );

      expect(merged.connectionState, HomeWidgetConnectionState.connected);
      expect(merged.agentState, HomeWidgetAgentState.toolExecution);
      expect(merged.toolName, 'shell');
    });

    test('cold-start base clears session when the instance changed', () {
      const persisted = HermesHomeWidgetSnapshot(
        configured: true,
        instanceId: 'demo',
        sessionId: 'session:1',
        sessionTitle: 'Persisted',
        cacheReadTokens: 348160,
        firstTokenLatencyMs: 2076,
      );

      final merged = mergeHomeWidgetBaseSnapshot(
        current: persisted,
        configured: true,
        instanceId: 'server-b',
        instanceLabel: 'Backup',
        connectionState: HomeWidgetConnectionState.connecting,
        agentState: HomeWidgetAgentState.idle,
        theme: HomeWidgetTheme.dark,
      );

      expect(merged.instanceId, 'server-b');
      expect(merged.sessionId, isNull);
      expect(merged.sessionTitle, isNull);
      expect(merged.cacheReadTokens, isNull);
      expect(merged.firstTokenLatencyMs, isNull);
    });

    test('serializes writes and commits schema last', () async {
      final store = _FakeStore();
      final publisher = HermesHomeWidgetPublisher(
        store: store,
        nowMs: () => 1234,
      );
      await publisher.publish(
        const HermesHomeWidgetSnapshot(
          configured: true,
          instanceId: 'demo',
          instanceLabel: 'Server',
        ),
      );

      const schemaKey = 'hermes_widget_schema_version';
      expect(store.writes.first, HermesHomeWidgetSnapshot.atomicStorageKey);
      expect(
        store.values[HermesHomeWidgetSnapshot.atomicStorageKey],
        contains('"instance_id":"demo"'),
      );
      expect(store.values[schemaKey], HermesHomeWidgetSnapshot.schemaVersion);
      expect(store.values['hermes_widget_updated_at_ms'], 1234);
      expect(store.writes.last, schemaKey);
      expect(store.updates, 1);
    });

    test(
      'deduplicates identical published state at the same timestamp',
      () async {
        final store = _FakeStore();
        final publisher = HermesHomeWidgetPublisher(
          store: store,
          nowMs: () => 1234,
        );
        const snapshot = HermesHomeWidgetSnapshot(configured: true);
        await publisher.publish(snapshot);
        await publisher.publish(snapshot);
        expect(store.updates, 1);
      },
    );

    test('updates one field without discarding the shared snapshot', () async {
      final store = _FakeStore();
      final publisher = HermesHomeWidgetPublisher(
        store: store,
        nowMs: () => 1234,
      );
      await publisher.publish(
        const HermesHomeWidgetSnapshot(
          configured: true,
          instanceId: 'demo',
          instanceLabel: 'Server',
        ),
      );
      await publisher.update(
        (current) => current.copyWith(
          connectionState: HomeWidgetConnectionState.connected,
        ),
      );

      expect(publisher.latest.instanceId, 'demo');
      expect(publisher.latest.instanceLabel, 'Server');
      expect(
        publisher.latest.connectionState,
        HomeWidgetConnectionState.connected,
      );
      expect(store.updates, 2);
    });

    test('restores the native snapshot before the first base update', () async {
      const persisted = HermesHomeWidgetSnapshot(
        configured: true,
        instanceId: 'demo',
        instanceLabel: 'Server',
        connectionState: HomeWidgetConnectionState.connected,
        sessionId: 'session:1',
        sessionTitle: 'Persisted',
        contextUsed: 42000,
        contextMax: 128000,
        inputTokens: 56000,
        cacheReadTokens: 348000,
        firstTokenLatencyMs: 2076,
        updatedAtMs: 1200,
      );
      final store = _FakeStore()..values.addAll(persisted.toStorageMap());
      final publisher = HermesHomeWidgetPublisher(
        store: store,
        nowMs: () => 1234,
      );

      await publisher.update(
        (current) => current.copyWith(
          connectionState: HomeWidgetConnectionState.connected,
        ),
      );

      expect(publisher.latest.sessionId, 'session:1');
      expect(publisher.latest.contextUsed, 42000);
      expect(publisher.latest.inputTokens, 56000);
      expect(publisher.latest.cacheReadTokens, 348000);
      expect(publisher.latest.firstTokenLatencyMs, 2076);
    });

    test(
      'restores the atomic snapshot without reading a partial legacy frame',
      () async {
        const persisted = HermesHomeWidgetSnapshot(
          configured: true,
          instanceId: 'demo',
          connectionState: HomeWidgetConnectionState.connected,
          sessionId: 'session:1',
          sessionTitle: 'Atomic',
          updatedAtMs: 1200,
        );
        final store = _FakeStore()
          ..values[HermesHomeWidgetSnapshot.atomicStorageKey] = persisted
              .toAtomicStorageValue();
        final publisher = HermesHomeWidgetPublisher(
          store: store,
          nowMs: () => 1234,
        );

        await publisher.flush();

        expect(publisher.latest, persisted);
        expect(publisher.latest.sessionTitle, 'Atomic');
      },
    );

    test('a platform failure does not poison later publications', () async {
      final store = _FakeStore()..failNextUpdate = true;
      final publisher = HermesHomeWidgetPublisher(
        store: store,
        nowMs: () => 1234,
      );

      await expectLater(
        publisher.publish(const HermesHomeWidgetSnapshot(instanceId: 'first')),
        throwsStateError,
      );
      await publisher.publish(
        const HermesHomeWidgetSnapshot(instanceId: 'second'),
      );

      expect(publisher.latest.instanceId, 'second');
      expect(store.updates, 1);
    });
  });

  group('limits identity (additive field of schema 2)', () {
    const group = HomeWidgetLimitGroup(
      provider: 'openai-codex',
      providerName: 'OpenAI Codex',
      plan: 'Plus',
      inUse: true,
      windows: [
        HomeWidgetLimitWindow(
          label: 'Sesión actual',
          usedPercent: 28,
          detail: 'Se reinicia en 2 h 13 min',
        ),
      ],
    );

    test('round trips with the same schema version', () {
      const snapshot = HermesHomeWidgetSnapshot(limits: [group]);
      final map = snapshot.toMap();
      expect(map['schema_version'], 2);
      expect((map['limits'] as List).single, {
        'provider': 'openai-codex',
        'provider_name': 'OpenAI Codex',
        'plan': 'Plus',
        'in_use': true,
        'windows': [
          {
            'label': 'Sesión actual',
            'used_percent': 28,
            'detail': 'Se reinicia en 2 h 13 min',
          },
        ],
      });
      final back = HermesHomeWidgetSnapshot.fromMap(map);
      expect(back.limits.single.provider, 'openai-codex');
      expect(back.limits.single.plan, 'Plus');
      expect(back.limits.single.windows.single.usedPercent, 28);
    });

    test('a plan the server did not give is absent, never invented', () {
      const none = HomeWidgetLimitGroup(
        provider: 'anthropic',
        providerName: 'Anthropic',
      );
      final map = const HermesHomeWidgetSnapshot(limits: [none]).toMap();
      expect((map['limits'] as List).single, isNot(contains('plan')));
    });

    test('a snapshot written before the field reads with no limits, and '
        'a bad provider id is dropped', () {
      final old = const HermesHomeWidgetSnapshot().toMap()..remove('limits');
      expect(HermesHomeWidgetSnapshot.fromMap(old).limits, isEmpty);
      final bad = const HermesHomeWidgetSnapshot().toMap()
        ..['limits'] = [
          {'provider': 'https://x.example', 'provider_name': 'X'},
        ];
      expect(HermesHomeWidgetSnapshot.fromMap(bad).limits, isEmpty);
    });
  });
}
