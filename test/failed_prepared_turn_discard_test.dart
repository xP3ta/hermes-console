import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_android/core/models/prepared_turn.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/chat_draft_store.dart';
import 'package:hermes_android/core/services/session_deletion.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';

final class _BarrierSecureStorage extends FlutterSecureStorage {
  final Map<String, String> values = <String, String>{};
  String? blockNextWriteKey;
  Completer<void>? blockedWriteEntered;
  Completer<void>? releaseBlockedWrite;

  void blockNextWrite(String key) {
    blockNextWriteKey = key;
    blockedWriteEntered = Completer<void>();
    releaseBlockedWrite = Completer<void>();
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (blockNextWriteKey == key) {
      blockNextWriteKey = null;
      blockedWriteEntered!.complete();
      await releaseBlockedWrite!.future;
    }
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => values[key];

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    values.remove(key);
  }

  @override
  Future<Map<String, String>> readAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => Map<String, String>.from(values);
}

PreparedTurn _turn({
  required int now,
  String connection = 'connection-target',
  String profile = 'profile-target',
  String session = 'session-target',
  String id = 'client-target',
  String text = 'prompt privado objetivo',
  PreparedTurnState state = PreparedTurnState.failedBeforeAcceptance,
}) => PreparedTurn(
  connectionId: connection,
  profile: profile,
  sessionId: session,
  clientTurnId: id,
  createdAtMs: now,
  updatedAtMs: now,
  text: text,
  attachments: const [],
  model: 'hermes-agent',
  state: state,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _BarrierSecureStorage secure;
  late SharedPreferences prefs;
  var now = 0;

  setUp(() async {
    secure = _BarrierSecureStorage();
    now = DateTime.now().millisecondsSinceEpoch;
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await SharedPreferences.getInstance();
    LocalConversationCleanupFence.resetForTesting();
    TurnOutboxStore.resetSerializationForTesting();
  });

  test(
    'discard exacto cerca save admitido, callback viejo y permite sucesor',
    () async {
      final store = TurnOutboxStore(secureStorage: secure, nowMs: () => now);
      final target = _turn(now: now);
      final sameChatNeighbor = _turn(
        now: now + 1,
        id: 'client-neighbor',
        text: 'vecino mismo chat',
      );
      final profileNeighbor = _turn(
        now: now + 2,
        profile: 'profile-neighbor',
        text: 'vecino otro profile',
      );
      final sessionNeighbor = _turn(
        now: now + 3,
        session: 'session-neighbor',
        text: 'vecino otra session',
      );
      final connectionNeighbor = _turn(
        now: now + 4,
        connection: 'connection-neighbor',
        text: 'vecino otra connection',
      );
      for (final neighbor in <PreparedTurn>[
        sameChatNeighbor,
        profileNeighbor,
        sessionNeighbor,
        connectionNeighbor,
      ]) {
        await store.save(neighbor);
      }
      final before =
          jsonDecode(secure.values[TurnOutboxStore.storageKeyForTesting]!)
              as Map<String, dynamic>;
      final neighborBytes = <String, String>{
        for (final neighbor in <PreparedTurn>[
          sameChatNeighbor,
          profileNeighbor,
          sessionNeighbor,
          connectionNeighbor,
        ])
          neighbor.storageId: jsonEncode(before[neighbor.storageId]),
      };

      secure.blockNextWrite(TurnOutboxStore.storageKeyForTesting);
      final admittedOldSave = store.save(target);
      await secure.blockedWriteEntered!.future;
      final delivery = ActiveTurnDelivery(prepared: target, store: store);
      final discard = delivery.discardFailedBeforeAcceptance();
      secure.releaseBlockedWrite!.complete();
      await admittedOldSave;
      expect(await discard, isTrue);

      // Ambos callbacks pertenecen al productor P0 y llegan tras el descarte.
      await delivery.markUnaccepted();
      await delivery.markRejectedBeforeAcceptance();
      await store.save(target.copyWith(updatedAtMs: now + 10));

      final successor = _turn(
        now: now + 11,
        id: 'client-successor',
        text: 'sucesor legítimo incluso con el mismo chat',
        state: PreparedTurnState.prepared,
      );
      await store.save(successor);

      final after =
          jsonDecode(secure.values[TurnOutboxStore.storageKeyForTesting]!)
              as Map<String, dynamic>;
      for (final entry in neighborBytes.entries) {
        expect(jsonEncode(after[entry.key]), entry.value);
      }
      expect(after.containsKey(target.storageId), isFalse);

      // Simula process death: solo sobrevive el backend cifrado.
      LocalConversationCleanupFence.resetForTesting();
      TurnOutboxStore.resetSerializationForTesting();
      final restarted = TurnOutboxStore(
        secureStorage: secure,
        nowMs: () => now,
      );
      expect(
        await restarted.isFailedBeforeAcceptanceDiscarded(
          connectionId: target.connectionId,
          profile: target.profile,
          sessionId: target.sessionId,
          clientTurnId: target.clientTurnId,
        ),
        isTrue,
      );
      final restored = await restarted.loadAllForChat(
        target.connectionId,
        target.sessionId,
        profile: target.profile,
      );
      expect(restored.map((turn) => turn.clientTurnId), <String>[
        sameChatNeighbor.clientTurnId,
        successor.clientTurnId,
      ]);
    },
  );

  test(
    'tombstone manda entre stores y save draft viejo no puede revivirlo',
    () async {
      final outbox = TurnOutboxStore(secureStorage: secure, nowMs: () => now);
      final drafts = ChatDraftStore(
        prefs,
        secureStorage: secure,
        mutationNamespaceForTesting: 'objective-c-cross-store',
      );
      final target = _turn(now: now);
      const neighborText = 'draft vecino byte-equivalente';
      await outbox.save(target);
      await drafts.save(
        target.connectionId,
        target.sessionId,
        target.text,
        const [],
        profile: target.profile,
        preparedTurnClientTurnId: target.clientTurnId,
      );
      await drafts.save(
        target.connectionId,
        'session-draft-neighbor',
        neighborText,
        const [],
        profile: target.profile,
      );
      final neighborKey = ChatDraftStore.keyForTesting(
        target.connectionId,
        'session-draft-neighbor',
        profile: target.profile,
      );
      final neighborBytes = secure.values[neighborKey];

      // Un autosave P0 ya entró en storage antes de que el usuario vaciase.
      final targetDraftKey = ChatDraftStore.keyForTesting(
        target.connectionId,
        target.sessionId,
        profile: target.profile,
      );
      secure.blockNextWrite(targetDraftKey);
      final admittedOldDraftSave = drafts.save(
        target.connectionId,
        target.sessionId,
        target.text,
        const [],
        profile: target.profile,
        preparedTurnClientTurnId: target.clientTurnId,
      );
      await secure.blockedWriteEntered!.future;
      final discard = outbox.discardFailedBeforeAcceptance(target);
      secure.releaseBlockedWrite!.complete();
      await admittedOldDraftSave;
      expect(await discard, isTrue);

      // Corte real entre stores: tombstone confirmado, clear aún no ejecutado.
      LocalConversationCleanupFence.resetForTesting();
      TurnOutboxStore.resetSerializationForTesting();
      final recoveredDrafts = ChatDraftStore(
        prefs,
        secureStorage: secure,
        mutationNamespaceForTesting: 'objective-c-cold-readback',
      );
      final recoveredOutbox = TurnOutboxStore(
        secureStorage: secure,
        nowMs: () => now,
      );
      final recovered = await recoveredDrafts.load(
        target.connectionId,
        target.sessionId,
        profile: target.profile,
      );
      expect(recovered.preparedTurnClientTurnId, target.clientTurnId);
      expect(
        await recoveredOutbox.isFailedBeforeAcceptanceDiscarded(
          connectionId: target.connectionId,
          profile: target.profile,
          sessionId: target.sessionId,
          clientTurnId: recovered.preparedTurnClientTurnId!,
        ),
        isTrue,
      );

      final beforeStaleCallback = secure.values[targetDraftKey];
      await recoveredDrafts.save(
        target.connectionId,
        target.sessionId,
        'callback P0 tardío',
        const [],
        profile: target.profile,
        preparedTurnClientTurnId: target.clientTurnId,
      );
      expect(secure.values[targetDraftKey], beforeStaleCallback);

      await recoveredDrafts.clear(
        target.connectionId,
        target.sessionId,
        profile: target.profile,
      );
      expect(
        (await recoveredDrafts.load(
          target.connectionId,
          target.sessionId,
          profile: target.profile,
        )).text,
        isEmpty,
      );
      expect(secure.values[neighborKey], neighborBytes);

      await recoveredDrafts.save(
        target.connectionId,
        target.sessionId,
        'draft del sucesor',
        const [],
        profile: target.profile,
        preparedTurnClientTurnId: 'client-successor',
      );
      expect(
        (await recoveredDrafts.load(
          target.connectionId,
          target.sessionId,
          profile: target.profile,
        )).text,
        'draft del sucesor',
      );
      expect(secure.values[neighborKey], neighborBytes);
    },
  );

  test(
    'ambiguo no se autodescarta y tombstones son privados/acotados',
    () async {
      final store = TurnOutboxStore(secureStorage: secure, nowMs: () => now);
      final ambiguous = _turn(
        now: now,
        id: 'client-ambiguous',
        text: 'resultado ambiguo privado',
        state: PreparedTurnState.ambiguous,
      );
      await store.save(ambiguous);
      expect(await store.discardFailedBeforeAcceptance(ambiguous), isFalse);
      expect(
        (await store.loadAllForChat(
          ambiguous.connectionId,
          ambiguous.sessionId,
          profile: ambiguous.profile,
        )).single.state,
        PreparedTurnState.ambiguous,
      );

      await store.delete(ambiguous);
      for (
        var index = 0;
        index < TurnOutboxStore.maxDiscardTombstones + 7;
        index++
      ) {
        now += 1;
        expect(
          await store.discardFailedBeforeAcceptance(
            _turn(now: now, id: 'discard-$index', text: 'secreto-$index'),
          ),
          isTrue,
        );
      }
      final encoded = secure.values[TurnOutboxStore.storageKeyForTesting]!;
      final records = jsonDecode(encoded) as Map<String, dynamic>;
      final tombstones = records.values.where(
        (value) =>
            value is Map<String, dynamic> &&
            value['record_type'] == 'failed_before_acceptance_discard',
      );
      expect(tombstones.length, TurnOutboxStore.maxDiscardTombstones);
      expect(encoded, isNot(contains('secreto-')));
      expect(
        (await SharedPreferences.getInstance()).getKeys(),
        isNot(contains('chat_turn_outbox_v1')),
      );

      now += TurnOutboxStore.discardTombstoneMaxAge.inMilliseconds + 1;
      expect(await store.prune(), 0);
      expect(
        secure.values.containsKey(TurnOutboxStore.storageKeyForTesting),
        isFalse,
      );
    },
  );

  test('compactar tombstone retira primero solo su draft enlazado', () async {
    final store = TurnOutboxStore(secureStorage: secure, nowMs: () => now);
    final drafts = ChatDraftStore(
      prefs,
      secureStorage: secure,
      mutationNamespaceForTesting: 'objective-c-retention-cut',
    );
    final oldest = _turn(now: now, id: 'discard-oldest-linked');
    await drafts.save(
      oldest.connectionId,
      oldest.sessionId,
      oldest.text,
      const [],
      profile: oldest.profile,
      preparedTurnClientTurnId: oldest.clientTurnId,
    );
    await drafts.save(
      oldest.connectionId,
      'draft-neighbor-retention',
      'vecino que no pertenece al tombstone',
      const [],
      profile: oldest.profile,
    );
    final targetDraftKey = ChatDraftStore.keyForTesting(
      oldest.connectionId,
      oldest.sessionId,
      profile: oldest.profile,
    );
    final neighborKey = ChatDraftStore.keyForTesting(
      oldest.connectionId,
      'draft-neighbor-retention',
      profile: oldest.profile,
    );
    final neighborBytes = secure.values[neighborKey];
    expect(await store.discardFailedBeforeAcceptance(oldest), isTrue);

    for (var index = 0; index < TurnOutboxStore.maxDiscardTombstones; index++) {
      now += 1;
      await store.discardFailedBeforeAcceptance(
        _turn(now: now, id: 'newer-discard-$index'),
      );
    }

    expect(secure.values.containsKey(targetDraftKey), isFalse);
    expect(secure.values[neighborKey], neighborBytes);
    expect(
      await store.isFailedBeforeAcceptanceDiscarded(
        connectionId: oldest.connectionId,
        profile: oldest.profile,
        sessionId: oldest.sessionId,
        clientTurnId: oldest.clientTurnId,
      ),
      isFalse,
    );
  });
}
