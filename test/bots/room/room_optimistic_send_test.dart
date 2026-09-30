import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/ui/room/room_gateway.dart';
import 'package:hermes_android/core/bots/ui/room/room_prefs.dart';
import 'package:hermes_android/core/bots/ui/room/room_screen.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat/console_composer.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

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
    await Future<void>.delayed(_rpc * 2);
    if (failSend) throw StateError('network down');
    _publish(text, attempt);
    completedSends++;
    return _readback;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _RecordingDrafts implements RoomDraftStore {
  final List<String> calls = [];

  @override
  Future<({String text, String? threadId})> load() async =>
      (text: '', threadId: null);

  @override
  Future<void> save(
    String text, {
    String? threadId,
    String? preparedId,
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
}) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  final seq = EventSeq();
  final events = [seq.user('Earlier message')];
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
}
