import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/compression_restore_store.dart';

import 'support/in_memory_compression_restore_storage.dart';

class _FailingStorage implements CompressionRestoreStorage {
  @override
  Future<String?> read() async => throw StateError('keystore unavailable');

  @override
  Future<void> write(String value) async =>
      throw StateError('keystore unavailable');
}

CompressionRestoreRecord _record({
  String stored = 'stored-a',
  String runtime = 'runtime-a',
  String connection = 'connection-a',
  String profile = 'default',
}) => CompressionRestoreRecord(
  connectionId: connection,
  profile: profile,
  storedSessionId: stored,
  runtimeId: runtime,
  startedAtMs: 1000,
);

void main() {
  group('CompressionRestoreStore', () {
    test(
      'is keyed by the stored session id and survives a new instance',
      () async {
        final storage = InMemoryCompressionRestoreStorage();
        await CompressionRestoreStore(storage: storage).save(_record());
        final found = await CompressionRestoreStore(storage: storage).lookup(
          connectionId: 'connection-a',
          profile: 'default',
          storedSessionId: 'stored-a',
        );
        expect(found?.runtimeId, 'runtime-a');
        expect(found?.startedAtMs, 1000);
        expect(
          await CompressionRestoreStore(storage: storage).lookup(
            connectionId: 'connection-a',
            profile: 'default',
            storedSessionId: 'mob-draft',
          ),
          isNull,
        );
        // Only metadata: ids and a timestamp.
        final record =
            (jsonDecode(storage.value!)['records'] as List).single as Map;
        expect(record.keys.toSet(), {
          'connection_id',
          'profile',
          'stored_session_id',
          'runtime_id',
          'started_at_ms',
        });
      },
    );

    test('clear only removes the record for the same runtime', () async {
      final store = CompressionRestoreStore(
        storage: InMemoryCompressionRestoreStorage(),
      );
      await store.save(_record(runtime: 'runtime-new'));
      await store.clear(
        connectionId: 'connection-a',
        profile: 'default',
        storedSessionId: 'stored-a',
        runtimeId: 'runtime-old',
      );
      expect(
        (await store.lookup(
          connectionId: 'connection-a',
          profile: 'default',
          storedSessionId: 'stored-a',
        ))?.runtimeId,
        'runtime-new',
      );
      await store.clearConnection('connection-a');
      expect(
        await store.lookup(
          connectionId: 'connection-a',
          profile: 'default',
          storedSessionId: 'stored-a',
        ),
        isNull,
      );
    });

    test(
      'fails open: unreadable storage or garbage is "nothing recorded"',
      () async {
        final failing = CompressionRestoreStore(storage: _FailingStorage());
        await failing.save(_record());
        expect(
          await failing.lookup(
            connectionId: 'connection-a',
            profile: 'default',
            storedSessionId: 'stored-a',
          ),
          isNull,
        );
        final garbage = InMemoryCompressionRestoreStorage()
          ..value = jsonEncode({
            'v': 1,
            'records': [
              {'connection_id': 'connection-a', 'unexpected': 'x'},
              'nope',
            ],
          });
        expect(
          await CompressionRestoreStore(storage: garbage).lookup(
            connectionId: 'connection-a',
            profile: 'default',
            storedSessionId: 'stored-a',
          ),
          isNull,
        );
      },
    );

    test('free-form or invalid ids are never persisted', () async {
      final storage = InMemoryCompressionRestoreStorage();
      await CompressionRestoreStore(
        storage: storage,
      ).save(_record(runtime: 'prompt body with spaces'));
      expect(storage.value, isNull);
    });
  });

  group('CompressionReplayVerdict (session.events.since ring)', () {
    Map<String, dynamic> ring(
      List<Map<String, dynamic>> events, {
      int? latest,
      bool truncated = false,
    }) => {
      'events': events,
      'latest_seq': latest ?? events.length,
      'truncated': truncated,
    };
    Map<String, dynamic> status(String kind, [String? text]) => {
      'type': 'status.update',
      'payload': {'kind': kind, 'text': ?text},
    };
    final compressing = status(
      'compressing',
      'compressing 35 messages (~20,379 tok)',
    );
    final ready = status('status', 'ready');

    test(
      'pinned compressing without a terminal is the only positive answer',
      () {
        expect(
          CompressionReplayVerdict.evaluate(ring([compressing])),
          CompressionReplayVerdict.running,
        );
        expect(
          CompressionReplayVerdict.evaluate(
            ring([compressing, ready, compressing]),
          ),
          CompressionReplayVerdict.running,
        );
      },
    );

    test('ready, compacted or error after the pin means finished', () {
      for (final terminal in [
        ready,
        status('compacted', 'done'),
        {'type': 'error'},
      ]) {
        expect(
          CompressionReplayVerdict.evaluate(ring([compressing, terminal])),
          CompressionReplayVerdict.finished,
        );
      }
      expect(
        CompressionReplayVerdict.evaluate(
          ring([
            {'type': 'message.complete'},
          ]),
        ),
        CompressionReplayVerdict.finished,
      );
    });

    test('unknown runtime, truncation or malformed payloads prove nothing', () {
      for (final payload in <Map<String, dynamic>>[
        ring(const [], latest: 0),
        ring([ready], truncated: true),
        {'events': 'nope', 'latest_seq': 2, 'truncated': false},
        {'events': <Object>[], 'truncated': false},
      ]) {
        expect(
          CompressionReplayVerdict.evaluate(payload),
          CompressionReplayVerdict.unknown,
          reason: '$payload',
        );
      }
    });

    test('the latest pin text carries the before facts', () {
      expect(
        CompressionReplayVerdict.latestCompressingText(ring([compressing])),
        'compressing 35 messages (~20,379 tok)',
      );
    });
  });
}
