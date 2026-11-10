// Terminal authority of one accepted delivery against the REAL encrypted
// outbox (TurnOutboxStore) behind the storage-plugin seam. Pairs with the
// owning-service integration tests in canonical_session_authority_chat_test.
// Contract (R4 section 4): accepted -> running -> terminal -> absent is
// monotonic per exact identity; a terminal wins over later accepted/running
// writes of the SAME producer; the first closure wins and later ones are
// no-ops that still finish a failed cleanup; rejection before acceptance stays
// durable and retryable with the same id.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/prepared_turn.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';

class _Effect {
  _Effect(this.index, this.method, this.key, this.rows);
  final int index;
  final String method;
  final String key;
  final Map<String, String> rows;
  String stateOf(String needle) {
    for (final entry in rows.entries) {
      if (entry.key.contains(needle)) return entry.value;
    }
    return 'absent';
  }
}

Map<String, String> _rowStates(Map<String, String> secure) {
  final raw = secure[TurnOutboxStore.storageKeyForTesting];
  if (raw == null || raw.isEmpty) return <String, String>{};
  final decoded = jsonDecode(raw) as Map<String, dynamic>;
  return {
    for (final entry in decoded.entries)
      if (!(entry.value as Map).containsKey('record_type'))
        entry.key: '${(entry.value as Map)['state']}',
  };
}

bool _rawHasState(String? raw, String needle, String state) {
  if (raw == null || raw.isEmpty) return false;
  final decoded = jsonDecode(raw) as Map<String, dynamic>;
  return decoded.entries.any(
    (entry) =>
        entry.key.contains(needle) &&
        entry.value is Map &&
        (entry.value as Map)['state'] == state,
  );
}

PreparedTurn _prepared(String id) {
  final now = DateTime.now().millisecondsSinceEpoch;
  return PreparedTurn(
    connectionId: 'c',
    sessionId: 's',
    clientTurnId: id,
    createdAtMs: now,
    updatedAtMs: now,
    text: id,
    fullText: id,
    desktopText: id,
    attachments: const [],
    model: 'm',
    profile: 'default',
    state: PreparedTurnState.prepared,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final secure = <String, String>{};
  final effects = <_Effect>[];
  Future<void>? Function(String method, String? raw)? interceptor;

  setUp(() {
    TurnOutboxStore.resetSerializationForTesting();
    secure.clear();
    effects.clear();
    interceptor = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final args = (call.arguments as Map).cast<String, dynamic>();
            final isOutbox = args['key'] == TurnOutboxStore.storageKeyForTesting;
            switch (call.method) {
              case 'read':
                return secure[args['key']];
              case 'readAll':
                return Map<String, String>.of(secure);
              case 'write':
                if (isOutbox) await interceptor?.call('write', args['value']);
                secure[args['key']] = args['value'];
                if (isOutbox) {
                  effects.add(
                    _Effect(
                      effects.length,
                      'write',
                      '${args['key']}',
                      _rowStates(secure),
                    ),
                  );
                }
              case 'delete':
                if (isOutbox) await interceptor?.call('delete', null);
                secure.remove(args['key']);
                if (isOutbox) {
                  effects.add(
                    _Effect(
                      effects.length,
                      'delete',
                      '${args['key']}',
                      <String, String>{},
                    ),
                  );
                }
            }
            return null;
          },
        );
  });

  List<String> trail(String needle, {int from = 0}) => [
    for (final e in effects.skip(from)) e.stateOf(needle),
  ];
  String full(String needle) => [
    for (final e in effects) '${e.index}:${e.method}:${e.stateOf(needle)}',
  ].join(' ');

  Future<ActiveTurnDelivery> accepted(
    TurnOutboxStore store,
    String id, {
    bool running = false,
  }) async {
    final delivery = ActiveTurnDelivery(prepared: _prepared(id), store: store);
    expect(await delivery.persistPrepared(), isTrue);
    expect(
      await delivery.beginTransport(PreparedTurnTransport.desktop),
      isTrue,
    );
    await delivery.markAccepted();
    if (running) await delivery.markRunning();
    return delivery;
  }

  Future<List<PreparedTurn>> reopened(String id) async =>
      (await TurnOutboxStore().loadAllForChat('c', 's', profile: 'default'))
          .where((t) => t.clientTurnId == id)
          .toList();

  group('same-producer terminal authority (real outbox, storage seam)', () {
    test(
      'R-1 lower level: accepted write held, the terminal edge and the finish path both close, then a late running: one terminal save, one delete, nothing after',
      () async {
        final store = TurnOutboxStore();
        final delivery = ActiveTurnDelivery(
          prepared: _prepared('turn-b'),
          store: store,
        );
        expect(await delivery.persistPrepared(), isTrue);
        expect(
          await delivery.beginTransport(PreparedTurnTransport.desktop),
          isTrue,
        );
        var armed = true;
        final gate = Completer<void>();
        final held = Completer<void>();
        interceptor = (method, raw) {
          if (!armed ||
              method != 'write' ||
              !_rawHasState(raw, 'turn-b', 'accepted')) {
            return null;
          }
          armed = false;
          held.complete();
          return gate.future;
        };
        final heldIndex = effects.length;
        final acceptedFuture = delivery.markAccepted();
        await held.future;
        // Terminal edge (finalize) and the suspended finish path: two closers.
        final first = delivery.markTerminalAndDelete();
        final late = delivery.markRunning();
        final second = delivery.markTerminalAndDelete();
        gate.complete();
        await Future.wait([acceptedFuture, first, late, second]);
        expect(
          trail('turn-b', from: heldIndex),
          ['accepted', 'terminal', 'absent'],
          reason: full('turn-b'),
        );
        expect(await reopened('turn-b'), isEmpty);
        expect(_rowStates(secure), isEmpty);
      },
    );

    test(
      'R-2 lower level: markAccepted/markRunning after the close never write again (same producer, recovery markRunning shape)',
      () async {
        final store = TurnOutboxStore();
        final delivery = await accepted(store, 'turn-b');
        await delivery.markTerminalAndDelete();
        final closedAt = effects.length;
        await delivery.markRunning();
        await delivery.markAccepted();
        await delivery.markRunning();
        await delivery.markTerminalAndDelete();
        expect(effects.length, closedAt, reason: full('turn-b'));
        expect(delivery.current.state, PreparedTurnState.terminal);
        expect(trail('turn-b').last, 'absent');
        expect(await reopened('turn-b'), isEmpty);
      },
    );

    test('control: normal accepted -> running -> terminal -> absent is monotonic',
        () async {
      final store = TurnOutboxStore();
      final delivery = await accepted(store, 'turn-b');
      await delivery.markRunning();
      await delivery.markTerminalAndDelete();
      expect(
        trail('turn-b'),
        ['prepared', 'submitting', 'accepted', 'running', 'terminal', 'absent'],
        reason: full('turn-b'),
      );
    });

    test('control: terminal-only (no running admission) closes once', () async {
      final store = TurnOutboxStore();
      final delivery = await accepted(store, 'turn-b');
      await delivery.markTerminalAndDelete();
      expect(
        trail('turn-b'),
        ['prepared', 'submitting', 'accepted', 'terminal', 'absent'],
        reason: full('turn-b'),
      );
    });

    test(
      'control pair (write failure): a failed terminal save is retried by the next closer; a late running cannot overwrite the terminal intent; no unhandled error',
      () async {
        final store = TurnOutboxStore();
        final delivery = await accepted(store, 'turn-b');
        var failWrite = true;
        interceptor = (method, raw) {
          if (failWrite &&
              method == 'write' &&
              _rawHasState(raw, 'turn-b', 'terminal')) {
            failWrite = false;
            throw PlatformException(code: 'keystore');
          }
          return null;
        };
        await delivery.markTerminalAndDelete();
        expect(delivery.persistenceFailed, isTrue);
        expect(trail('turn-b').last, 'accepted',
            reason: 'the failed save left the durable accepted row');
        final afterFailure = effects.length;
        await delivery.markRunning();
        expect(effects.length, afterFailure,
            reason: 'running after a terminal intent is a no-op');
        await delivery.markTerminalAndDelete();
        expect(
          trail('turn-b', from: afterFailure),
          ['terminal', 'absent'],
          reason: full('turn-b'),
        );
        expect(await reopened('turn-b'), isEmpty);
      },
    );

    test(
      'control pair (delete failure): a failed delete is retried by the next closer WITHOUT a second terminal save',
      () async {
        final store = TurnOutboxStore();
        final delivery = await accepted(store, 'turn-b');
        var failDelete = true;
        interceptor = (method, raw) {
          if (failDelete && method == 'delete') {
            failDelete = false;
            throw PlatformException(code: 'keystore');
          }
          return null;
        };
        final base = effects.length;
        await delivery.markTerminalAndDelete();
        expect(delivery.persistenceFailed, isTrue);
        expect(trail('turn-b', from: base), ['terminal']);
        await delivery.markTerminalAndDelete();
        expect(trail('turn-b', from: base), ['terminal', 'absent'],
            reason: full('turn-b'));
        await delivery.markTerminalAndDelete();
        expect(trail('turn-b', from: base), ['terminal', 'absent'],
            reason: 'third closer is a no-op: ${full('turn-b')}');
      },
    );

    test(
      'control: an accepted save that fails keeps the ACK truth latched and the terminal still closes',
      () async {
        final store = TurnOutboxStore();
        final delivery = ActiveTurnDelivery(
          prepared: _prepared('turn-b'),
          store: store,
        );
        expect(await delivery.persistPrepared(), isTrue);
        expect(
          await delivery.beginTransport(PreparedTurnTransport.desktop),
          isTrue,
        );
        interceptor = (method, raw) {
          if (method == 'write' && _rawHasState(raw, 'turn-b', 'accepted')) {
            throw PlatformException(code: 'keystore');
          }
          return null;
        };
        await delivery.markAccepted();
        interceptor = null;
        expect(delivery.acknowledged, isTrue);
        expect(delivery.persistenceFailed, isTrue);
        await delivery.markTerminalAndDelete();
        expect(trail('turn-b').last, 'absent', reason: full('turn-b'));
        expect(await reopened('turn-b'), isEmpty);
      },
    );

    test(
      'control: rejection before acceptance stays durable as failedBeforeAcceptance and an explicit retry with the same id closes once',
      () async {
        final store = TurnOutboxStore();
        final delivery = ActiveTurnDelivery(
          prepared: _prepared('turn-b'),
          store: store,
        );
        expect(await delivery.persistPrepared(), isTrue);
        expect(
          await delivery.beginTransport(PreparedTurnTransport.desktop),
          isTrue,
        );
        await delivery.markRejectedBeforeAcceptance();
        expect(trail('turn-b').last, 'failedBeforeAcceptance');
        final restored = await reopened('turn-b');
        expect(restored, hasLength(1));
        expect(restored.single.state, PreparedTurnState.failedBeforeAcceptance);
        // Explicit retry, same id.
        expect(
          await delivery.beginTransport(PreparedTurnTransport.desktop),
          isTrue,
        );
        await delivery.markAccepted();
        await delivery.markRunning();
        await delivery.markTerminalAndDelete();
        expect(
          trail('turn-b'),
          [
            'prepared',
            'submitting',
            'failedBeforeAcceptance',
            'submitting',
            'accepted',
            'running',
            'terminal',
            'absent',
          ],
          reason: full('turn-b'),
        );
      },
    );

    test(
      'control: a new distinct turn C after B closed is persisted and closes once; B stays closed (two independent handles)',
      () async {
        final storeB = TurnOutboxStore();
        final storeC = TurnOutboxStore();
        final b = await accepted(storeB, 'turn-b');
        final c = ActiveTurnDelivery(prepared: _prepared('turn-c'), store: storeC);
        final closeB = b.markTerminalAndDelete();
        final saveC = c.persistPrepared();
        await Future.wait([closeB, saveC]);
        expect(_rowStates(secure).keys.any((k) => k.contains('turn-b')), isFalse,
            reason: full('turn-b'));
        expect(_rowStates(secure).keys.any((k) => k.contains('turn-c')), isTrue,
            reason: 'C survives the delete of B');
        expect(
          await c.beginTransport(PreparedTurnTransport.desktop),
          isTrue,
        );
        await c.markAccepted();
        await c.markTerminalAndDelete();
        expect(trail('turn-c').where((s) => s == 'terminal'), hasLength(1),
            reason: full('turn-c'));
        expect(trail('turn-c').last, 'absent');
        expect(await reopened('turn-b'), isEmpty);
        expect(await reopened('turn-c'), isEmpty);
      },
    );

    test(
      'B closed on one handle, C saved on another, then B\'s late running/accepted: B never returns and C survives',
      () async {
        final storeB = TurnOutboxStore();
        final storeC = TurnOutboxStore();
        final b = await accepted(storeB, 'turn-b');
        final c = ActiveTurnDelivery(prepared: _prepared('turn-c'), store: storeC);
        final closeB = b.markTerminalAndDelete();
        final saveC = c.persistPrepared();
        final lateB = b.markRunning();
        await Future.wait([closeB, saveC, lateB]);
        await b.markAccepted();
        expect(_rowStates(secure).keys.any((k) => k.contains('turn-b')), isFalse,
            reason: full('turn-b'));
        expect(_rowStates(secure).keys.any((k) => k.contains('turn-c')), isTrue,
            reason: 'C survives: ${full('turn-c')}');
      },
    );
  });
}
