import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/ui/room/room_gateway.dart';
import 'package:hermes_android/core/bots/ui/room/room_prefs.dart';
import 'package:hermes_android/core/bots/ui/room/room_screen.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat/console_composer.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import '../../support/inter_font.dart';
import 'room_fixtures.dart';

/// rr1215: replying to one message in a room leads visibly to the answers.
/// Rooms have no reactions (owner decision after QA 9495): long-press opens
/// one panel with Copy, Reply and Select text, and Console sends no
/// `reply_to` nor `groups.react`.
final class _FakeTimer implements Timer {
  bool cancelled = false;
  @override
  void cancel() => cancelled = true;
  @override
  bool get isActive => !cancelled;
  @override
  int get tick => 0;
}

/// A server: `send` appends the owner's message to the log (and, when
/// [answer] is set, a member answer to it).
final class _Server implements RoomGateway {
  HostedGroupRoom room;
  HostedGroupLogPage log;
  final EventSeq seq;
  List<Map<String, dynamic>> events;
  final List<HostedGroupSendAttempt> sends = [];
  final List<String> sentTexts = [];

  /// Member answer appended after each send: (member id, handle, text).
  (String, String, String)? answer;

  _Server(this.seq, this.events)
    : log = buildLog(events),
      room = buildRoom(latestSeq: events.length);

  HostedGroupWorkspaceReadback get _readback => HostedGroupWorkspaceReadback(
    room: room,
    log: log,
    capabilityGeneration: 1,
    driverStatus: driver(),
  );

  void publish(List<Map<String, dynamic>> next) {
    events = next;
    log = buildLog(next);
    room = buildRoom(latestSeq: log.latestSeq);
  }

  @override
  Future<HostedGroupWorkspaceReadback> read(HostedGroupRoom room) async =>
      _readback;

  @override
  Future<HostedGroupWorkspaceReadback> send(
    HostedGroupRoom room, {
    required String text,
    required HostedGroupSendAttempt attempt,
  }) async {
    sends.add(attempt);
    sentTexts.add(text);
    final user = seq.user(
      text,
      thread: attempt.threadId,
      id: attempt.durableEventId,
    );
    final next = [...events, user];
    final a = answer;
    if (a != null) {
      next.add(
        seq.member(
          a.$1,
          a.$2,
          a.$3,
          attempt.durableEventId,
          thread: attempt.threadId,
        ),
      );
    }
    publish(next);
    return _readback;
  }

  @override
  Future<HostedGroupWorkspaceReadback> rename(
    HostedGroupRoom room, {
    required String name,
  }) async => _readback;
  @override
  Future<HostedGroupWorkspaceReadback> stop(HostedGroupRoom room) async =>
      _readback;
  @override
  Future<HostedGroupWorkspaceReadback> disband(HostedGroupRoom room) async =>
      _readback;
  @override
  Future<void> approve(
    HostedGroupRoom room, {
    required RoomApprovalAction action,
    required String choice,
  }) async {}
  @override
  Future<void> retry(HostedGroupRoom room, {required String taskId}) async {}
}

Future<_Server> _pump(
  WidgetTester tester,
  EventSeq seq,
  List<Map<String, dynamic>> events,
) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  final server = _Server(seq, events);
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      locale: const Locale('en'),
      theme: AppTheme.hermesRedDark,
      home: RoomScreen(
        room: server.room,
        log: server.log,
        driverStatus: driver(),
        gateway: server,
        capabilities: const RoomCapabilities(canSend: true),
        profileFor: (_) => null,
        prefs: MemoryRoomPrefs(),
        pollTimer: (_, _) => _FakeTimer(),
        clock: () => DateTime.fromMillisecondsSinceEpoch(1790000400 * 1000),
      ),
    ),
  );
  await _frames(tester);
  return server;
}


Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _refresh(WidgetTester tester) async {
  await tester.runAsync(
    () => tester
        .state<RoomScreenState>(find.byType(RoomScreen, skipOffstage: false))
        .refresh(),
  );
  await _frames(tester);
}

/// Selection overlays (handles/toolbar) currently up in any message.
List<SelectionOverlay> _selectionOverlays(WidgetTester tester) => [
  for (final state in tester.stateList<SelectionAreaState>(
    find.byType(SelectionArea, skipOffstage: false),
  ))
    ?state.selectableRegion.selectionOverlay,
];

Finder get _field => find.descendant(
  of: find.byType(ConsoleComposer),
  matching: find.byType(TextField),
);

Future<void> _send(WidgetTester tester, String text) async {
  final controller = tester.widget<TextField>(_field).controller!;
  await tester.enterText(_field, '${controller.text}$text');
  await tester.pump();
  await tester.tap(
    find.byKey(const ValueKey('composer-primary-action-switcher')),
  );
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 20)),
  );
  await _frames(tester);
}

/// The owner's question, two bot answers in its thread.
({List<Map<String, dynamic>> events, String bot, String other}) _talk(
  EventSeq seq,
) {
  final u = seq.user('¿Qué foto va en la portada?');
  final disc = u['event_id'] as String;
  final bot = seq.member('m-builder', 'builder', 'La tercera.', disc);
  final other = seq.member('m-lead', 'lead', 'Yo pondría la primera.', disc);
  return (
    events: [u, bot, other],
    bot: bot['event_id'] as String,
    other: other['event_id'] as String,
  );
}

void main() {
  setUpAll(loadInterFont);

  group('rr1215 replying to one bot message', () {
    testWidgets('the owner reply and the bot answer to it show at the bottom '
        '(never folded away into a thread summary)', (tester) async {
      final seq = EventSeq();
      final talk = _talk(seq);
      final server = await _pump(tester, seq, talk.events)
        ..answer = ('m-builder', 'builder', 'Porque tiene mejor luz.');
      await tester.tap(find.byKey(ValueKey('room-reply-${talk.bot}')));
      await tester.pump();
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('room-thread-banner-text')))
            .data,
        'Replying to console-builder: La tercera.',
      );
      await _send(tester, '¿por qué?');
      expect(server.sentTexts.single, '@builder ¿por qué?');
      expect(server.sends.single.threadId, 'thread-1');
      final sent = server.sends.single.durableEventId;
      final answer = server.events.last['event_id'] as String;
      expect(
        find.byKey(ValueKey('room-user-bubble-$sent')),
        findsOneWidget,
        reason: 'the reply itself stays in the timeline',
      );
      final card = find.byKey(ValueKey('room-member-card-$answer'));
      expect(card, findsOneWidget, reason: 'the answer is on screen');
      final viewport = tester.getRect(
        find.byKey(const ValueKey('room-transcript')),
      );
      expect(tester.getRect(card).bottom, lessThanOrEqualTo(viewport.bottom));
      expect(
        tester
            .widget<Text>(find.byKey(ValueKey('room-quote-text-$answer')))
            .textSpan!
            .toPlainText(),
        'You: @builder ¿por qué?',
      );
      expect(
        find.byWidgetPredicate(
          (w) =>
              w.key is ValueKey<String> &&
              (w.key! as ValueKey<String>).value.startsWith(
                'room-thread-summary-',
              ),
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a reply sends the plain payload: same thread and the '
        '@mention, no reply_to', (tester) async {
      final seq = EventSeq();
      final talk = _talk(seq);
      final server = await _pump(tester, seq, talk.events);
      await tester.tap(find.byKey(ValueKey('room-reply-${talk.bot}')));
      await tester.pump();
      await _send(tester, 'vale');
      expect(server.sentTexts.single, '@builder vale');
      expect(server.sends.single.threadId, 'thread-1');
    });
  });


  testWidgets('rr1215 opening a room never leaves the newest answer cut at '
      'the bottom to show a header at the top', (tester) async {
    final seq = EventSeq();
    final u = seq.user('¿Qué foto ponemos en la portada? @builder @lead');
    final d = u['event_id'] as String;
    final bot = seq.member(
      'm-builder',
      'builder',
      'La tercera: tiene la mejor luz y se lee bien el título encima.',
      d,
    );
    final lead = seq.member(
      'm-lead',
      'lead',
      'Yo pondría la primera, es más limpia.',
      d,
    );
    final reply = seq.user('@builder ¿y si la recortamos un poco?');
    final rd = reply['event_id'] as String;
    final answer = seq.member(
      'm-builder',
      'builder',
      'Sí: recortando el borde izquierdo queda centrada y el título '
          'respira.\n\nY la luz sigue igual de bien.',
      rd,
    );
    await _pump(tester, seq, [u, bot, lead, reply, answer]);
    final card = find.byKey(ValueKey('room-member-card-${answer['event_id']}'));
    expect(card, findsOneWidget);
    final viewport = tester.getRect(
      find.byKey(const ValueKey('room-transcript')),
    );
    expect(
      tester.getRect(card).bottom,
      lessThanOrEqualTo(viewport.bottom + 0.5),
      reason: 'the newest answer is fully on screen',
    );
  });

  group('rr1215 pill', () {
    List<Map<String, dynamic>> longRoom(EventSeq seq) => [
      for (var r = 0; r < 10; r++)
        ...() {
          final u = seq.user('question $r', thread: 'thread-$r');
          final d = u['event_id'] as String;
          return [
            u,
            seq.member(
              'm-builder',
              'builder',
              List.generate(5, (i) => 'Answer $r paragraph $i.').join('\n\n'),
              d,
              thread: 'thread-$r',
            ),
          ];
        }(),
    ];

    String? pillText(WidgetTester tester) {
      final pill = find.byKey(const ValueKey('room-new-pill'));
      if (pill.evaluate().isEmpty) return null;
      return tester
          .widget<Text>(
            find.descendant(of: pill, matching: find.byType(Text)).first,
          )
          .data;
    }

    testWidgets('answers to your newest message while you read above: '
        '"1 new reply to your message", no yank', (tester) async {
      final seq = EventSeq();
      final base = longRoom(seq);
      final ask = seq.user('¿y ahora? @review', thread: 'thread-ask');
      final server = await _pump(tester, seq, [...base, ask]);
      await tester.drag(
        find.byKey(const ValueKey('room-transcript')),
        const Offset(0, 600),
      );
      await _frames(tester);
      final anchor = find
          .byWidgetPredicate(
            (w) =>
                w.key is ValueKey<String> &&
                (w.key! as ValueKey<String>).value.startsWith('room-message-'),
          )
          .first;
      final anchorKey = tester.widget(anchor).key!;
      final before = tester.getTopLeft(find.byKey(anchorKey));
      server.publish([
        ...server.events,
        seq.member(
          'm-review',
          'review',
          'Ahora sí.',
          ask['event_id'] as String,
          thread: 'thread-ask',
        ),
      ]);
      await _refresh(tester);
      expect(pillText(tester), '1 new reply to your message');
      expect(
        tester.getTopLeft(find.byKey(anchorKey)),
        before,
        reason: 'the reader is never moved',
      );
    });

    testWidgets('control: arrivals answering an older message keep the '
        'plain count', (tester) async {
      final seq = EventSeq();
      final base = longRoom(seq);
      final old = seq.user('vieja @review', thread: 'thread-old');
      final newest = seq.user('nueva @lead', thread: 'thread-new');
      // Your newest message already has its answer (read before scrolling).
      final answered = seq.member(
        'm-lead',
        'lead',
        'Contestada.',
        newest['event_id'] as String,
        thread: 'thread-new',
      );
      final server = await _pump(tester, seq, [...base, old, newest, answered]);
      await tester.drag(
        find.byKey(const ValueKey('room-transcript')),
        const Offset(0, 600),
      );
      await _frames(tester);
      server.publish([
        ...server.events,
        seq.member(
          'm-review',
          'review',
          'Sobre la vieja.',
          old['event_id'] as String,
          thread: 'thread-old',
        ),
      ]);
      await _refresh(tester);
      expect(pillText(tester), '1 new');
    });
  });


  group('rr1215 room long-press panel (no reactions)', () {
    Finder messageText(String text) => find.text(text, findRichText: true);

    testWidgets('one panel with Copy, Reply and Select text and no reactions '
        'row; no reactions under messages', (tester) async {
      final seq = EventSeq();
      final talk = _talk(seq);
      // Even a log that carries reactions shows none.
      talk.events[1]['reactions'] = {
        '❤️': ['m-lead'],
      };
      await _pump(tester, seq, talk.events);
      await tester.longPress(messageText('La tercera.'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('message-actions-surface')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('quick-reaction-bar')), findsNothing);
      for (final e in const ['👍', '❤️', '😂', '😮', '🙏', '👎']) {
        expect(find.byKey(ValueKey('quick-reaction-$e')), findsNothing);
      }
      for (final a in const ['copy', 'reply', 'select']) {
        expect(find.byKey(ValueKey('message-action-$a')), findsOneWidget);
      }
      expect(_selectionOverlays(tester), isEmpty);
      expect(find.byType(AdaptiveTextSelectionToolbar), findsNothing);
      // Above the pressed card, never over its text.
      final card = tester.getRect(
        find.byKey(ValueKey('room-member-card-${talk.bot}')),
      );
      expect(
        tester
            .getRect(find.byKey(const ValueKey('message-actions-surface')))
            .overlaps(card),
        isFalse,
      );
      expect(
        find.byWidgetPredicate(
          (w) =>
              w.key is ValueKey<String> &&
              ((w.key! as ValueKey<String>).value.startsWith(
                    'room-reactions-',
                  ) ||
                  (w.key! as ValueKey<String>).value.startsWith(
                    'room-answers-',
                  )),
        ),
        findsNothing,
      );
    });

    testWidgets('«Copy message» copies it, «Select text» '
        'starts the selection, «Reply» answers the pressed message', (
      tester,
    ) async {
      final clip = <String?>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clip.add((call.arguments as Map)['text'] as String?);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final seq = EventSeq();
      final talk = _talk(seq);
      await _pump(tester, seq, talk.events);
      await tester.longPress(messageText('La tercera.'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('message-action-copy')));
      await _frames(tester);
      expect(clip, ['La tercera.']);

      await tester.longPress(messageText('La tercera.'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('message-action-select')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('message-actions-surface')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('quick-reaction-bar')), findsNothing);
      expect(_selectionOverlays(tester), hasLength(1));

      await tester.longPress(messageText('La tercera.'));
      await tester.pumpAndSettle();
      expect(
        _selectionOverlays(tester),
        isEmpty,
        reason: 'opening the surface drops the earlier selection',
      );
      await tester.tap(find.byKey(const ValueKey('message-action-reply')));
      await _frames(tester);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('room-thread-banner-text')))
            .data,
        'Replying to console-builder: La tercera.',
      );
    });
  });
}
