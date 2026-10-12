// re1215: re-entering a chat whose turn finished while the user was away.
//
// QA 9480: the phone's own turn ended (and Hermes started a background
// review on the same session, which Desktop never shows as work). The list
// still said «trabajando», entering showed a «working» pill that vanished a
// moment later, and the list kept the stale state until the chat was opened
// again.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_active_session.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/models/session_live_status.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/global_activity_aggregate.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'session_identity_peer_test.dart' as peer;
import 'support/in_memory_compression_restore_storage.dart';

final _connection = SavedConnection(
  id: 'peer',
  label: 'Peer',
  host: 'example.invalid',
  port: 443,
  apiKey: 'k',
  useHttps: true,
  kind: InstanceKind.vps,
);

DesktopSessionSnapshot _snapshot({required bool running}) =>
    DesktopSessionSnapshot.fromJson(
      {
        'session_id': 'runtime-peer',
        'session_key': 'stored-peer',
        'message_count': 1,
        'messages': [peer.publicSnapshot],
        'running': running,
        if (running) 'inflight': {'assistant': '', 'streaming': true},
      },
      requestedStoredSessionId: 'stored-peer',
      created: false,
      method: 'session.resume',
    );

/// A roster read that started at [generation] and lands now.
void _applyRoster(
  ActiveChatService service,
  String status, {
  int? generation,
  DateTime? lastActiveAt,
}) => service.globalActivity.applyRoster(
  connectionId: 'peer',
  profile: 'default',
  replayEpoch: 'current',
  requestGeneration:
      generation ??
      service.globalActivity.beginRosterRequest('peer', 'default'),
  roster: DesktopActiveSessionList(
    sessions: [
      DesktopActiveSession(
        runtimeSessionId: 'runtime-peer',
        storedSessionId: 'stored-peer',
        status: status,
        lastActiveAt: lastActiveAt,
      ),
    ],
  ),
);

ActiveChat _attach(ActiveChatService service, peer.PeerGateway gateway) =>
    service.attach(
      connection: _connection,
      sessionId: 'stored-peer',
      sessionTitle: 'Peer',
      api: ApiClient(
        baseUrl: 'https://example.invalid',
        apiKey: 'k',
        httpClient: MockClient((_) async => http.Response('nf', 404)),
      ),
      desktopGateway: gateway,
      allowUnownedDesktopSnapshotForTesting: true,
      disableForegroundKeepAlive: true,
    );

/// What the Conversaciones row and the Inicio card resolve.
SessionLiveStatus _listStatus(ActiveChatService service) {
  final chat = service.of('peer', 'stored-peer');
  final global =
      service.globalActivity.isActive('peer', 'default', 'stored-peer')
      ? service.globalActivity.activityFor('peer', 'default', 'stored-peer')
      : null;
  return resolveSessionLiveStatus(
    chat: chat?.liveStatus,
    chatAuthoritative:
        chat != null && (chat.hasDesktopRuntime || chat.lastTerminalAt != null),
    chatSettledAt: chat?.lastTerminalAt,
    global: global,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => call.method == 'readAll' ? <String, String>{} : null,
        );
  });

  group('own turn ended while the user was away', () {
    late ActiveChatService service;
    late peer.PeerGateway gateway;
    late ActiveChat chat;
    late DateTime clock;

    setUp(() async {
      clock = DateTime.now().toUtc();
      service = ActiveChatService(
        compressionRestoreStore: testCompressionRestoreStore(),
        globalActivity: GlobalActivityAggregate.inMemory(now: () => clock),
      );
      addTearDown(service.dispose);
      // The list saw the turn busy while it ran.
      _applyRoster(service, 'working');
      gateway = peer.PeerGateway(_snapshot(running: true));
      addTearDown(gateway.close);
      chat = _attach(service, gateway);
      await chat.loadMessages();
      expect(chat.isStreaming, isTrue);
    });

    Future<void> finishTurn() async {
      gateway.emit('message.complete', {'text': 'Hecho', 'status': 'complete'});
      // Background review fork: emits nothing to the client (Desktop parity).
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(chat.isStreaming, isFalse);
    }

    test('the list says idle once the chat is released, even though the '
        'roster entry was observed busy', () async {
      await finishTurn();
      expect(_listStatus(service).isLive, isFalse);
      // Leaving the chat releases it: only the roster aggregate remains.
      service.debugDisposeChatForTesting('peer', 'stored-peer');
      expect(service.of('peer', 'stored-peer'), isNull);
      expect(
        _listStatus(service).isLive,
        isFalse,
        reason: 'the busy roster row predates the turn end this device saw',
      );
    });

    test('a roster read in flight across the turn end, or made while the '
        'server still clears its running flag, cannot revive it; a later '
        'busy roster (new turn elsewhere) still can', () async {
      final inFlight = service.globalActivity.beginRosterRequest(
        'peer',
        'default',
      );
      await finishTurn();
      service.debugDisposeChatForTesting('peer', 'stored-peer');
      _applyRoster(service, 'working', generation: inFlight);
      expect(_listStatus(service).isLive, isFalse);
      // Hermes sets `running = False` only after the turn's post-processing
      // (a few seconds after message.complete).
      clock = clock.add(const Duration(seconds: 3));
      _applyRoster(service, 'working');
      expect(_listStatus(service).isLive, isFalse);
      clock = clock.add(GlobalActivityAggregate.ownTurnEndGrace);
      _applyRoster(service, 'working');
      expect(_listStatus(service).phase, SessionLivePhase.working);
    });

    // External review of 4f45a6b: the suppression keys on the finished turn,
    // not on every busy row read inside the window. The roster's
    // `last_active` is the server's stamp of the turn that owns the row: a
    // turn started from Desktop right after this one ends carries a newer
    // stamp and must show at once, also on an aggregate that has lived for
    // hours; a row still stamped by the finished turn stays suppressed.
    test('a new turn started elsewhere right after the end shows at once on '
        'a long-lived aggregate', () async {
      // Server stamp of the turn this chat runs, seen by the list meanwhile.
      final turnStartedAt = DateTime.now().toUtc().subtract(
        const Duration(seconds: 30),
      );
      _applyRoster(service, 'working', lastActiveAt: turnStartedAt);
      // The aggregate has lived long before this turn ends.
      clock = clock.add(const Duration(hours: 1));
      await finishTurn();
      final endedAt = chat.lastTerminalAt!;
      service.debugDisposeChatForTesting('peer', 'stored-peer');

      clock = clock.add(const Duration(seconds: 1));
      _applyRoster(service, 'working', lastActiveAt: turnStartedAt);
      expect(
        _listStatus(service).isLive,
        isFalse,
        reason: 'a busy row stamped by the finished turn is that same turn',
      );

      clock = clock.add(const Duration(seconds: 1));
      _applyRoster(
        service,
        'working',
        lastActiveAt: endedAt.add(const Duration(seconds: 2)),
      );
      expect(
        _listStatus(service).phase,
        SessionLivePhase.working,
        reason: 'a turn started after the end is a new turn',
      );
    });

    // External review of 3ccc3a8: the roster may not have provided
    // `last_active` while this chat's turn ran (setUp's busy row carries no
    // stamp), so the settle has no baseline. A Desktop turn started right
    // after the end still carries a stamp newer than that end and must
    // show at once; a stamp from before the end is the finished turn.
    test('without a baseline stamp, a busy row stamped after the end shows '
        'at once and one stamped before it stays suppressed', () async {
      await finishTurn();
      final endedAt = chat.lastTerminalAt!;
      service.debugDisposeChatForTesting('peer', 'stored-peer');

      clock = clock.add(const Duration(seconds: 1));
      _applyRoster(
        service,
        'working',
        lastActiveAt: endedAt.subtract(const Duration(seconds: 30)),
      );
      expect(
        _listStatus(service).isLive,
        isFalse,
        reason: 'a stamp from before the end is the finished turn',
      );

      clock = clock.add(const Duration(seconds: 1));
      _applyRoster(
        service,
        'working',
        lastActiveAt: endedAt.add(const Duration(seconds: 1)),
      );
      expect(
        _listStatus(service).phase,
        SessionLivePhase.working,
        reason: 'a turn stamped after the end is a new turn',
      );
    });

    test('re-entering shows no provisional «working» pill', () async {
      await finishTurn();
      service.debugDisposeChatForTesting('peer', 'stored-peer');
      final next = peer.PeerGateway(_snapshot(running: false))
        ..resumeHold = Completer<void>();
      addTearDown(next.close);
      final reopened = _attach(service, next);
      expect(
        reopened.liveStatus.isLive,
        isFalse,
        reason: 'no pill that vanishes when the snapshot lands',
      );
      final load = reopened.loadMessages();
      next.resumeHold!.complete();
      await load;
      expect(reopened.liveStatus.isLive, isFalse);
    });
  });
}
