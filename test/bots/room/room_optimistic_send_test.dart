import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:hermes_android/core/bots/ui/room/room_gateway.dart';
import 'package:hermes_android/core/bots/ui/room/room_launcher.dart';
import 'package:hermes_android/core/bots/ui/room/room_prefs.dart';
import 'package:hermes_android/core/bots/ui/room/room_screen.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/services/chat_draft_store.dart';
import 'package:hermes_android/core/services/session_deletion.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat/console_composer.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'room_fixtures.dart';

/// Every RPC of the real path costs [rpc]; a send is the acknowledgement
/// plus its verified readback, like `groups.send` + `groups.log`.
const _rpc = Duration(milliseconds: 400);

final class _FakeTimer implements Timer {
  bool cancelled = false;
  @override
  void cancel() => cancelled = true;
  @override
  bool get isActive => !cancelled;
  @override
  int get tick => 0;
}

final class _SlowRoomGateway implements RoomGateway {
  HostedGroupRoom room;
  final List<Map<String, dynamic>> events;
  final List<({String text, String clientEventId, String thread})> sends = [];
  int completedSends = 0;
  bool failSend = false;

  /// Publishes the event on the server before the acknowledgement returns,
  /// so a refresh can observe it while the send is still in flight.
  bool publishBeforeAck = false;

  /// The server stores the event but the acknowledgement/readback fails.
  bool failAfterPublish = false;

  /// The room cannot be read (offline, refresh unavailable).
  bool failRead = false;

  /// The acknowledgement answers at once, before any storage work queued by
  /// the send could run.
  bool instantAck = false;

  _SlowRoomGateway({required this.room, required this.events});

  int get _seq => events.isEmpty ? 0 : events.last['seq'] as int;

  HostedGroupLogPage get log => buildLog(events);

  HostedGroupWorkspaceReadback get _readback => HostedGroupWorkspaceReadback(
    room: room,
    log: log,
    capabilityGeneration: 1,
  );

  void _publish(String text, HostedGroupSendAttempt attempt) {
    final id = TuiGatewayClient.durableGroupEventId(attempt.clientEventId);
    if (events.any((e) => e['event_id'] == id)) return;
    final seq = _seq + 1;
    events.add({
      'room_id': roomId,
      'seq': seq,
      'event_id': id,
      'kind': 'message.user',
      'actor': {'kind': 'user', 'id': 'desktop'},
      'authority_epoch': 2,
      'payload': {'text': text, 'thread_id': attempt.threadId},
      'created_at': 1790000300.0 + seq,
      'idempotent': false,
    });
  }

  @override
  Future<HostedGroupWorkspaceReadback> read(HostedGroupRoom room) async {
    await Future<void>.delayed(_rpc);
    if (failRead) throw StateError('offline');
    return _readback;
  }

  @override
  Future<HostedGroupWorkspaceReadback> send(
    HostedGroupRoom room, {
    required String text,
    required HostedGroupSendAttempt attempt,
  }) async {
    sends.add((
      text: text,
      clientEventId: attempt.clientEventId,
      thread: attempt.threadId,
    ));
    if (publishBeforeAck && !failSend) _publish(text, attempt);
    if (!instantAck) await Future<void>.delayed(_rpc * 2);
    if (failSend) throw StateError('network down');
    _publish(text, attempt);
    if (failAfterPublish) throw StateError('readback failed');
    completedSends++;
    return _readback;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _RecordingDrafts implements RoomDraftStore {
  final List<String> calls = [];
  final String storedText;
  final String? storedPreparedId;

  _RecordingDrafts({this.storedText = '', this.storedPreparedId});

  @override
  Future<RoomDraft> load() async => (
    text: storedText,
    threadId: null,
    preparedId: storedPreparedId,
    preparedText: null,
  );

  @override
  Future<void> save(
    String text, {
    String? threadId,
    String? preparedId,
    String? preparedText,
  }) async => calls.add('save:$text:${preparedId ?? '-'}');

  @override
  Future<void> clear({required String preparedId}) async =>
      calls.add('clear:$preparedId');
}

Finder get _field => find.descendant(
  of: find.byType(ConsoleComposer),
  matching: find.byType(TextField),
);

Finder _keyPrefix(String prefix) => find.byWidgetPredicate(
  (w) =>
      w.key is ValueKey<String> &&
      (w.key! as ValueKey<String>).value.startsWith(prefix),
);

String _composerText(WidgetTester tester) =>
    tester.widget<TextField>(_field).controller!.text;

Future<_SlowRoomGateway> _pump(
  WidgetTester tester, {
  RoomDraftStore? drafts,
  String? publishedAttempt,
  bool memberReply = false,
}) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  final seq = EventSeq();
  final user = seq.user('Earlier message');
  final events = <Map<String, dynamic>>[
    user,
    if (memberReply)
      seq.member(
        'm-builder',
        'builder',
        'Reply here',
        user['event_id'] as String,
      ),
  ];
  if (publishedAttempt != null) {
    final ev = seq.user('already sent');
    ev['event_id'] = TuiGatewayClient.durableGroupEventId(publishedAttempt);
    events.add(ev);
  }
  final log = buildLog(events);
  final room = buildRoom(latestSeq: log.latestSeq);
  final gateway = _SlowRoomGateway(room: room, events: events);
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      locale: const Locale('en'),
      theme: AppTheme.hermesRedDark,
      home: RoomScreen(
        room: room,
        log: log,
        gateway: gateway,
        capabilities: const RoomCapabilities(canSend: true),
        profileFor: (_) => null,
        prefs: MemoryRoomPrefs(),
        drafts: drafts,
        pollTimer: (_, _) => _FakeTimer(),
        clock: () => DateTime.fromMillisecondsSinceEpoch(1790000400 * 1000),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return gateway;
}

/// Key of the Retry button of the pending bubble showing [text].
ValueKey<String> _retryOf(String text) {
  final bubble = find.ancestor(
    of: find.text(text),
    matching: _keyPrefix('room-pending-bubble-'),
  );
  final key = (bubble.evaluate().first.widget.key! as ValueKey<String>).value;
  return ValueKey(
    key.replaceFirst('room-pending-bubble-', 'room-pending-retry-'),
  );
}

Future<void> _tapSend(WidgetTester tester) async {
  await tester.pump();
  await tester.tap(
    find.byKey(const ValueKey('composer-primary-action-switcher')),
  );
  // Exactly one frame: nothing here waits on the network.
  await tester.pump();
}

/// One stored room draft slot, like `ChatDraftStore` behind
/// `ChatDraftRoomStore`: a save replaces it, a clear only retires the draft
/// still bound to the acknowledged attempt. It retires the whole slot, so a
/// test never relies on the store keeping text typed after the send.
final class _MemoryDrafts implements RoomDraftStore {
  String text;
  String? threadId;
  String? preparedId;
  String? preparedText;

  _MemoryDrafts({this.text = '', this.preparedId});

  @override
  Future<RoomDraft> load() async {
    await Future<void>.value();
    return (
      text: text,
      threadId: threadId,
      preparedId: preparedId,
      preparedText: preparedText,
    );
  }

  @override
  Future<void> save(
    String text, {
    String? threadId,
    String? preparedId,
    String? preparedText,
  }) async {
    await Future<void>.value();
    this.text = text;
    this.threadId = threadId;
    this.preparedId = preparedId;
    this.preparedText = preparedId == null ? null : preparedText;
  }

  @override
  Future<void> clear({required String preparedId}) async {
    await Future<void>.value();
    if (this.preparedId != preparedId) return;
    text = '';
    threadId = null;
    this.preparedId = null;
    preparedText = null;
  }
}

/// Opens the room as Mission Control does: [snapshot] is the log captured
/// when the room list was read, which may predate the latest send.
Future<void> _enterRoom(
  WidgetTester tester,
  _SlowRoomGateway gateway,
  HostedGroupLogPage snapshot,
  RoomDraftStore drafts,
) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      locale: const Locale('en'),
      theme: AppTheme.hermesRedDark,
      home: RoomScreen(
        key: UniqueKey(),
        room: gateway.room,
        log: snapshot,
        gateway: gateway,
        capabilities: const RoomCapabilities(canSend: true),
        profileFor: (_) => null,
        prefs: MemoryRoomPrefs(),
        drafts: drafts,
        pollTimer: (_, _) => _FakeTimer(),
        clock: () => DateTime.fromMillisecondsSinceEpoch(1790000400 * 1000),
      ),
    ),
  );
}

Future<void> _leaveRoom(WidgetTester tester) =>
    tester.pumpWidget(const SizedBox.shrink());

/// A room whose server log holds one earlier message; the returned log is
/// the snapshot Mission Control captured before any send.
({_SlowRoomGateway gateway, HostedGroupLogPage snapshot}) _staleRoom() {
  final events = [EventSeq().user('Earlier message')];
  final snapshot = buildLog(events);
  final room = buildRoom(latestSeq: snapshot.latestSeq);
  return (
    gateway: _SlowRoomGateway(room: room, events: List.of(events)),
    snapshot: snapshot,
  );
}

void main() {
  testWidgets('send clears the composer and shows the message in one frame', (
    tester,
  ) async {
    final gateway = await _pump(tester);
    await tester.enterText(_field, 'hello room');
    await _tapSend(tester);

    expect(gateway.completedSends, 0, reason: 'the network is still busy');
    expect(_composerText(tester), isEmpty);
    expect(find.text('hello room'), findsOneWidget);
    final id = gateway.sends.single.clientEventId;
    expect(find.byKey(ValueKey('room-pending-$id')), findsOneWidget);
    expect(find.byKey(ValueKey('room-pending-sending-$id')), findsOneWidget);
    final composer = tester.widget<ConsoleComposer>(
      find.byType(ConsoleComposer),
    );
    expect(composer.busy, isFalse, reason: 'no spinner on the send button');

    // A second message can be typed and sent right away.
    await tester.enterText(_field, 'next');
    await tester.pump();
    expect(
      tester.widget<ConsoleComposer>(find.byType(ConsoleComposer)).sendEnabled,
      isTrue,
    );

    await tester.pump(_rpc * 3);
    await tester.pumpAndSettle();
    final durable = TuiGatewayClient.durableGroupEventId(id);
    expect(gateway.completedSends, 1);
    expect(find.text('hello room'), findsOneWidget, reason: 'no duplicate');
    expect(find.byKey(ValueKey('room-user-bubble-$durable')), findsOneWidget);
    expect(_keyPrefix('room-pending-'), findsNothing);
    expect(_composerText(tester), 'next', reason: 'the new draft is kept');
  });

  testWidgets('reply-seeded mention is the unchanged groups.send text', (
    tester,
  ) async {
    final gateway = await _pump(tester, memberReply: true);
    await tester.tap(find.byKey(const ValueKey('room-reply-message.member-2')));
    await tester.pump();
    expect(_composerText(tester), '@builder ');

    await _tapSend(tester);

    expect(gateway.sends.single.text, '@builder');
    expect(gateway.sends.single.thread, 'thread-1');
    await tester.pump(_rpc * 3);
    await tester.pumpAndSettle();
  });

  testWidgets('quick sends keep their order and reconcile once each', (
    tester,
  ) async {
    final gateway = await _pump(tester);
    await tester.enterText(_field, 'first');
    await _tapSend(tester);
    await tester.enterText(_field, 'second');
    await _tapSend(tester);
    await tester.enterText(_field, 'third');
    await _tapSend(tester);

    expect(_composerText(tester), isEmpty);
    expect(find.text('first'), findsOneWidget);
    expect(find.text('second'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('first')).dy,
      lessThan(tester.getTopLeft(find.text('second')).dy),
    );

    await tester.pump(_rpc * 9);
    await tester.pumpAndSettle();
    expect(
      [for (final s in gateway.sends) s.text],
      ['first', 'second', 'third'],
    );
    expect(gateway.completedSends, 3);
    expect(find.text('third'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('second')).dy,
      lessThan(tester.getTopLeft(find.text('third')).dy),
    );
    expect(find.text('first'), findsOneWidget);
    expect(find.text('second'), findsOneWidget);
    expect(_keyPrefix('room-pending-'), findsNothing);
    expect(
      tester.getTopLeft(find.text('first')).dy,
      lessThan(tester.getTopLeft(find.text('second')).dy),
    );
  });

  testWidgets('a failed send stays visible with Retry and keeps the attempt', (
    tester,
  ) async {
    final gateway = await _pump(tester);
    gateway.failSend = true;
    await tester.enterText(_field, 'do not lose me');
    await _tapSend(tester);
    await tester.pump(_rpc * 3);
    await tester.pumpAndSettle();

    final id = gateway.sends.single.clientEventId;
    expect(find.text('do not lose me'), findsOneWidget);
    expect(find.byKey(ValueKey('room-pending-failed-$id')), findsOneWidget);
    expect(find.byKey(ValueKey('room-pending-sending-$id')), findsNothing);
    expect(find.byKey(ValueKey('room-pending-retry-$id')), findsOneWidget);

    gateway.failSend = false;
    await tester.tap(find.byKey(ValueKey('room-pending-retry-$id')));
    await tester.pump();
    expect(find.byKey(ValueKey('room-pending-sending-$id')), findsOneWidget);
    await tester.pump(_rpc * 3);
    await tester.pumpAndSettle();

    expect(gateway.sends, hasLength(2));
    expect(gateway.sends.last.clientEventId, id, reason: 'idempotent retry');
    expect(gateway.sends.last.text, 'do not lose me');
    expect(find.text('do not lose me'), findsOneWidget);
    expect(_keyPrefix('room-pending-'), findsNothing);
  });

  testWidgets('a later message never overtakes one that failed', (
    tester,
  ) async {
    final gateway = await _pump(tester);
    gateway.failSend = true;
    await tester.enterText(_field, 'first');
    await _tapSend(tester);
    await tester.enterText(_field, 'second');
    await _tapSend(tester);
    await tester.pump(_rpc * 3);
    await tester.pumpAndSettle();

    final first = gateway.sends.single.clientEventId;
    expect(
      [for (final s in gateway.sends) s.text],
      ['first'],
      reason: 'the second message waits behind the failed one',
    );
    expect(find.byKey(ValueKey('room-pending-failed-$first')), findsOneWidget);
    expect(find.byKey(_retryOf('second')), findsOneWidget);

    gateway.failSend = false;
    await tester.tap(find.byKey(ValueKey('room-pending-retry-$first')));
    await tester.pump(_rpc * 3);
    await tester.pumpAndSettle();
    expect(
      [for (final s in gateway.sends) s.text],
      ['first', 'first'],
      reason: 'retrying the first does not silently send the second',
    );

    await tester.tap(find.byKey(_retryOf('second')));
    await tester.pump(_rpc * 3);
    await tester.pumpAndSettle();
    expect(
      [for (final s in gateway.sends) s.text],
      ['first', 'first', 'second'],
    );
    expect(_keyPrefix('room-pending-'), findsNothing);
    expect(
      tester.getTopLeft(find.text('first')).dy,
      lessThan(tester.getTopLeft(find.text('second')).dy),
    );
  });

  testWidgets('a refresh that sees the message first never duplicates it', (
    tester,
  ) async {
    final gateway = await _pump(tester)
      ..publishBeforeAck = true;
    await tester.enterText(_field, 'seen early');
    await _tapSend(tester);
    final state = tester.state<RoomScreenState>(find.byType(RoomScreen));
    unawaited(state.refresh());
    await tester.pump(_rpc);
    await tester.pump();
    expect(gateway.completedSends, 0);
    expect(find.text('seen early'), findsOneWidget);

    await tester.pump(_rpc * 3);
    await tester.pumpAndSettle();
    expect(find.text('seen early'), findsOneWidget);
    expect(_keyPrefix('room-pending-'), findsNothing);
  });

  testWidgets('the in-flight text stays in the draft until acknowledged', (
    tester,
  ) async {
    final drafts = _RecordingDrafts();
    final gateway = await _pump(tester, drafts: drafts);
    await tester.enterText(_field, 'keep safe');
    await _tapSend(tester);
    final id = gateway.sends.single.clientEventId;
    // Past the draft debounce, while the send is still in flight.
    await tester.pump(const Duration(milliseconds: 500));
    expect(gateway.completedSends, 0);
    expect(drafts.calls.last, 'save:keep safe:$id');
    expect(drafts.calls.where((c) => c.startsWith('save::')), isEmpty);

    await tester.pump(_rpc * 3);
    await tester.pumpAndSettle();
    expect(drafts.calls.last, 'clear:$id');
  });

  testWidgets('a send stored by the server but answered with an error is '
      'retired, not left as a draft', (tester) async {
    final drafts = _RecordingDrafts();
    final gateway = await _pump(tester, drafts: drafts)
      ..failAfterPublish = true;
    await tester.enterText(_field, 'stored anyway');
    await _tapSend(tester);
    final id = gateway.sends.single.clientEventId;
    await tester.pump(_rpc * 3);
    await tester.pumpAndSettle();
    // The next refresh sees the durable event in the log.
    gateway.failAfterPublish = false;
    // Not awaited: the fake read only completes when the clock is pumped.
    unawaited(tester.state<RoomScreenState>(find.byType(RoomScreen)).refresh());
    await tester.pump(_rpc * 2);
    await tester.pumpAndSettle();

    expect(find.text('stored anyway'), findsOneWidget);
    expect(_keyPrefix('room-pending-'), findsNothing);
    expect(drafts.calls.last, 'clear:$id');
    expect(_composerText(tester), isEmpty);
  });

  testWidgets('reopening never restores the draft of a message already in '
      'the room', (tester) async {
    const id = 'prepared-already-sent';
    final drafts = _RecordingDrafts(
      storedText: 'already sent',
      storedPreparedId: id,
    );
    await _pump(tester, drafts: drafts, publishedAttempt: id);
    await tester.pumpAndSettle();
    expect(_composerText(tester), isEmpty);
    expect(drafts.calls, contains('clear:$id'));
  });

  testWidgets('reopening still restores a draft whose send never landed', (
    tester,
  ) async {
    final drafts = _RecordingDrafts(
      storedText: 'not sent yet',
      storedPreparedId: 'prepared-lost',
    );
    await _pump(tester, drafts: drafts);
    // Restored once a fresh read of the room confirms it never landed.
    await tester.pump(_rpc);
    await tester.pumpAndSettle();
    expect(_composerText(tester), 'not sent yet');
    expect(drafts.calls.where((c) => c.startsWith('clear:')), isEmpty);
  });

  group('re-entering a room after a send', () {
    testWidgets('coming back before the acknowledgement never puts the sent '
        'text back in the composer', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final (:gateway, :snapshot) = _staleRoom();
      final drafts = _MemoryDrafts();
      await _enterRoom(tester, gateway, snapshot, drafts);
      await tester.pumpAndSettle();
      await tester.enterText(_field, 'sent once');
      await _tapSend(tester);
      final id = gateway.sends.single.clientEventId;
      expect(drafts.preparedId, id, reason: 'in flight: bound to the attempt');

      await _leaveRoom(tester);
      await tester.pump(const Duration(milliseconds: 100));
      expect(gateway.completedSends, 0, reason: 'still waiting for the ack');
      await _enterRoom(tester, gateway, snapshot, drafts);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(_composerText(tester), isEmpty);

      await tester.pump(_rpc * 4);
      await tester.pumpAndSettle();
      expect(gateway.completedSends, 1);
      expect(_composerText(tester), isEmpty);
      expect(drafts.text, isEmpty);
      expect(drafts.preparedId, isNull);
      expect(gateway.sends, hasLength(1), reason: 'never sent twice');
    });

    testWidgets('a send the server stored but answered with an error is not '
        'restored on a stale re-entry', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final (:gateway, :snapshot) = _staleRoom();
      gateway.failAfterPublish = true;
      final drafts = _MemoryDrafts();
      await _enterRoom(tester, gateway, snapshot, drafts);
      await tester.pumpAndSettle();
      await tester.enterText(_field, 'stored, ack lost');
      await _tapSend(tester);
      await tester.pump(_rpc * 3);
      await tester.pumpAndSettle();
      final id = gateway.sends.single.clientEventId;
      expect(drafts.preparedId, id);

      await _leaveRoom(tester);
      await _enterRoom(tester, gateway, snapshot, drafts);
      await tester.pump();
      expect(_composerText(tester), isEmpty);
      await tester.pump(_rpc * 2);
      await tester.pumpAndSettle();
      expect(_composerText(tester), isEmpty);
      expect(drafts.text, isEmpty);
      expect(find.text('stored, ack lost'), findsOneWidget, reason: 'the log');
    });

    testWidgets('a draft left by a killed app is retired once the room shows '
        'its message', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      const id = 'prepared-killed-after-send';
      final (:gateway, :snapshot) = _staleRoom();
      gateway.room = buildRoom(latestSeq: snapshot.latestSeq);
      final ev = EventSeq()..seq = snapshot.latestSeq;
      gateway.events.add(
        ev.user('landed before the kill')
          ..['event_id'] = TuiGatewayClient.durableGroupEventId(id),
      );
      final drafts = _MemoryDrafts(
        text: 'landed before the kill',
        preparedId: id,
      );
      await _enterRoom(tester, gateway, snapshot, drafts);
      await tester.pump();
      expect(_composerText(tester), isEmpty);
      await tester.pump(_rpc * 2);
      await tester.pumpAndSettle();
      expect(_composerText(tester), isEmpty);
      expect(drafts.text, isEmpty);
      expect(gateway.sends, isEmpty);
    });

    testWidgets('a draft left by a killed app whose send never landed comes '
        'back once the room confirms it', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final (:gateway, :snapshot) = _staleRoom();
      final drafts = _MemoryDrafts(
        text: 'never reached the server',
        preparedId: 'prepared-never-landed',
      );
      await _enterRoom(tester, gateway, snapshot, drafts);
      await tester.pump(_rpc * 2);
      await tester.pumpAndSettle();
      expect(_composerText(tester), 'never reached the server');
      expect(drafts.text, 'never reached the server');
      expect(gateway.sends, isEmpty);
    });

    testWidgets('a send that fails after leaving comes back when re-entered '
        'while it was still in flight', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final (:gateway, :snapshot) = _staleRoom();
      gateway.failSend = true;
      final drafts = _MemoryDrafts();
      await _enterRoom(tester, gateway, snapshot, drafts);
      await tester.pumpAndSettle();
      await tester.enterText(_field, 'network dropped');
      await _tapSend(tester);
      await _leaveRoom(tester);
      await tester.pump(const Duration(milliseconds: 100));
      await _enterRoom(tester, gateway, snapshot, drafts);
      await tester.pump(_rpc * 4);
      await tester.pumpAndSettle();
      expect(gateway.events, hasLength(1), reason: 'nothing was published');
      expect(_composerText(tester), 'network dropped');
      expect(drafts.text, 'network dropped');
    });

    testWidgets('text typed while the room is checked is kept with an unsent '
        'draft', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final (:gateway, :snapshot) = _staleRoom();
      final drafts = _MemoryDrafts(
        text: 'unsent before',
        preparedId: 'prepared-unsent-typed',
      );
      await _enterRoom(tester, gateway, snapshot, drafts);
      await tester.pump();
      await tester.enterText(_field, 'typed now');
      // Past the autosave debounce, before the room read answers.
      await tester.pump(const Duration(milliseconds: 370));
      expect(drafts.text, 'unsent before', reason: 'never overwritten');
      expect(drafts.preparedId, 'prepared-unsent-typed');
      await tester.pump(_rpc * 2);
      await tester.pumpAndSettle();
      expect(_composerText(tester), contains('unsent before'));
      expect(_composerText(tester), contains('typed now'));
      await _leaveRoom(tester);
      await tester.pump();
      expect(drafts.text, contains('unsent before'));
      expect(drafts.text, contains('typed now'));
    });
    testWidgets('leaving before an unsent draft is confirmed keeps it and '
        'the text typed meanwhile', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final (:gateway, :snapshot) = _staleRoom();
      final drafts = _MemoryDrafts(
        text: 'unsent before',
        preparedId: 'prepared-unsent-leave',
      );
      await _enterRoom(tester, gateway, snapshot, drafts);
      await tester.pump();
      await tester.enterText(_field, 'typed now');
      await _leaveRoom(tester);
      await tester.pump(_rpc * 2);
      await tester.pumpAndSettle();
      expect(drafts.text, contains('unsent before'));
      expect(drafts.text, contains('typed now'));
    });

    testWidgets('leaving before a sent draft is confirmed keeps only the '
        'text typed meanwhile', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      const id = 'prepared-sent-leave';
      final (:gateway, :snapshot) = _staleRoom();
      final ev = EventSeq()..seq = snapshot.latestSeq;
      gateway.events.add(
        ev.user('already in the room')
          ..['event_id'] = TuiGatewayClient.durableGroupEventId(id),
      );
      final drafts = _MemoryDrafts(text: 'already in the room', preparedId: id);
      await _enterRoom(tester, gateway, snapshot, drafts);
      await tester.pump();
      await tester.enterText(_field, 'typed now');
      await _leaveRoom(tester);
      await tester.pump(_rpc * 2);
      await tester.pumpAndSettle();
      expect(drafts.text, 'typed now');
      expect(drafts.preparedId, isNull);
    });

    testWidgets('a new send while an unsent draft is checked does not lose '
        'the unsent text', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final (:gateway, :snapshot) = _staleRoom();
      final drafts = _MemoryDrafts(
        text: 'unsent before',
        preparedId: 'prepared-unsent-send',
      );
      await _enterRoom(tester, gateway, snapshot, drafts);
      await tester.pump();
      await tester.enterText(_field, 'quick one');
      await _tapSend(tester);
      await tester.pump(_rpc * 4);
      await tester.pumpAndSettle();
      expect(gateway.completedSends, 1);
      expect(_composerText(tester), 'unsent before');
      expect(drafts.text, 'unsent before');
    });

    testWidgets('leaving an unreadable room keeps the held draft and the '
        'text typed meanwhile', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final (:gateway, :snapshot) = _staleRoom();
      gateway.failRead = true;
      final drafts = _MemoryDrafts(
        text: 'unproven send',
        preparedId: 'prepared-offline',
      );
      await _enterRoom(tester, gateway, snapshot, drafts);
      await tester.pump(_rpc * 2);
      await tester.pumpAndSettle();
      expect(_composerText(tester), isEmpty, reason: 'not proven unsent');
      await tester.enterText(_field, 'typed offline');
      await _leaveRoom(tester);
      await tester.pump(_rpc * 2);
      await tester.pumpAndSettle();
      expect(drafts.text, contains('unproven send'));
      expect(drafts.text, contains('typed offline'));
      expect(drafts.preparedId, 'prepared-offline');
    });

    testWidgets('text typed offline next to a send that did land survives '
        'the next visit', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      const id = 'prepared-landed-offline';
      final (:gateway, :snapshot) = _staleRoom();
      gateway.failRead = true;
      final drafts = _MemoryDrafts(text: 'landed send', preparedId: id);
      await _enterRoom(tester, gateway, snapshot, drafts);
      await tester.pump(_rpc * 2);
      await tester.pumpAndSettle();
      await tester.enterText(_field, 'typed offline');
      await _leaveRoom(tester);
      await tester.pump(_rpc * 2);
      await tester.pumpAndSettle();
      expect(drafts.preparedId, id, reason: 'still unproven, still bound');

      // Back online: the room now shows that the held send did land.
      gateway.failRead = false;
      final ev = EventSeq()..seq = snapshot.latestSeq;
      gateway.events.add(
        ev.user('landed send')
          ..['event_id'] = TuiGatewayClient.durableGroupEventId(id),
      );
      await _enterRoom(tester, gateway, snapshot, drafts);
      await tester.pump(_rpc * 2);
      await tester.pumpAndSettle();
      expect(_composerText(tester), 'typed offline');
      await _leaveRoom(tester);
      await tester.pump();
      expect(drafts.text, 'typed offline');
      expect(drafts.preparedId, isNull);
    });

    testWidgets('text typed offline next to a send that never landed comes '
        'back with it on the next visit', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final (:gateway, :snapshot) = _staleRoom();
      gateway.failRead = true;
      final drafts = _MemoryDrafts(
        text: 'lost send',
        preparedId: 'prepared-lost-offline',
      );
      await _enterRoom(tester, gateway, snapshot, drafts);
      await tester.pump(_rpc * 2);
      await tester.pumpAndSettle();
      await tester.enterText(_field, 'typed offline');
      await _leaveRoom(tester);
      await tester.pump(_rpc * 2);
      await tester.pumpAndSettle();

      gateway.failRead = false;
      await _enterRoom(tester, gateway, snapshot, drafts);
      await tester.pump(_rpc * 2);
      await tester.pumpAndSettle();
      expect(_composerText(tester), 'lost send\ntyped offline');
      expect(gateway.sends, isEmpty);
    });

    testWidgets('an instant acknowledgement leaves no draft of the sent '
        'message in the real store', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      LocalConversationCleanupFence.resetForTesting();
      SharedPreferences.setMockInitialValues({});
      final secure = <String, String>{};
      const channel = MethodChannel(
        'plugins.it_nomads.com/flutter_secure_storage',
      );
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        final args = (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
        switch (call.method) {
          case 'write':
            secure[args['key'] as String] = args['value'] as String;
          case 'read':
            return secure[args['key'] as String];
          case 'delete':
            secure.remove(args['key'] as String);
          case 'readAll':
            return Map<String, String>.from(secure);
          case 'containsKey':
            return secure.containsKey(args['key'] as String);
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final drafts = ChatDraftRoomStore(
        store: ChatDraftStore(await SharedPreferences.getInstance()),
        connectionId: 'conn-room',
        profile: 'default',
        sessionId: 'mob-room-instant-ack',
      );
      final (:gateway, :snapshot) = _staleRoom();
      gateway.instantAck = true;
      await _enterRoom(tester, gateway, snapshot, drafts);
      await tester.pumpAndSettle();
      await tester.enterText(_field, 'acked at once');
      await _tapSend(tester);
      await tester.pumpAndSettle();
      expect(gateway.completedSends, 1);
      expect(secure, isEmpty, reason: 'the sent text is no draft any more');

      // Re-entering offline must not bring the sent text back either.
      gateway.failRead = true;
      await _leaveRoom(tester);
      await _enterRoom(tester, gateway, snapshot, drafts);
      await tester.pump(_rpc * 2);
      await tester.pumpAndSettle();
      expect(_composerText(tester), isEmpty);
    });

    testWidgets('a send readback settles a held draft the room refresh '
        'could not', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final (:gateway, :snapshot) = _staleRoom();
      gateway.failRead = true;
      final drafts = _MemoryDrafts(
        text: 'unsent, checked late',
        preparedId: 'prepared-readback',
      );
      await _enterRoom(tester, gateway, snapshot, drafts);
      await tester.pump(_rpc * 2);
      await tester.pumpAndSettle();
      expect(_composerText(tester), isEmpty, reason: 'not proven unsent');
      await tester.enterText(_field, 'next one');
      await _tapSend(tester);
      await tester.pump(_rpc * 3);
      await tester.pumpAndSettle();
      expect(gateway.completedSends, 1);
      expect(_composerText(tester), 'unsent, checked late');
      expect(drafts.text, 'unsent, checked late');
    });
  });
}
