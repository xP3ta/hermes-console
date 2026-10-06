import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/ui/room/room_gateway.dart';
import 'package:hermes_android/core/bots/ui/room/room_prefs.dart';
import 'package:hermes_android/core/bots/ui/room/room_screen.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/core/bots/ui/room/room_header.dart';

import '../../support/inter_font.dart';
import 'room_fixtures.dart';

/// Owner QA (room "Hermes Console Devs"): the room top was three stacked
/// layers (mosaic + name + availability, then a faces strip with the round
/// line). fh1215: the header now FLOATS over the transcript (no app bar
/// band): a round back button and the room's activity pill with the member
/// faces sitting on it. Idle, the pill says the room name; while someone
/// works or needs you it says that one line. Tapping it opens the round /
/// members detail; a long press opens the room menu.
final class _FakeTimer implements Timer {
  @override
  void cancel() {}
  @override
  bool get isActive => true;
  @override
  int get tick => 0;
}

final class _Gateway implements RoomGateway {
  HostedGroupRoom room;
  HostedGroupLogPage log;
  RoomDriverStatus? status;

  _Gateway({required this.room, required this.log, this.status});

  HostedGroupWorkspaceReadback get _readback => HostedGroupWorkspaceReadback(
    room: room,
    log: log,
    capabilityGeneration: 1,
    driverStatus: status,
  );

  @override
  Future<HostedGroupWorkspaceReadback> read(HostedGroupRoom room) async =>
      _readback;
  @override
  Future<HostedGroupWorkspaceReadback> send(
    HostedGroupRoom room, {
    required String text,
    required HostedGroupSendAttempt attempt,
  }) async => _readback;
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

const _caps = RoomCapabilities(
  canSend: true,
  canStop: true,
  canApprove: true,
  canRetry: true,
);

const _statusBar = 24.0;

Future<void> _pump(
  WidgetTester tester, {
  required List<Map<String, dynamic>> events,
  RoomDriverStatus? status,
  List<Map<String, dynamic>>? members,
  Locale locale = const Locale('en'),
  Size size = const Size(412, 915),
  double textScale = 1,
}) async {
  tester.view.physicalSize = size * 3;
  tester.view.devicePixelRatio = 3;
  tester.view.padding = const FakeViewPadding(top: _statusBar * 3);
  tester.view.viewPadding = const FakeViewPadding(top: _statusBar * 3);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final log = buildLog(events);
  final room = buildRoom(latestSeq: log.latestSeq, members: members);
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      locale: locale,
      theme: AppTheme.hermesRedDark,
      home: RoomScreen(
        room: room,
        log: log,
        driverStatus: status,
        gateway: _Gateway(room: room, log: log, status: status),
        capabilities: _caps,
        profileFor: (_) => null,
        prefs: MemoryRoomPrefs(),
        pollTimer: (_, _) => _FakeTimer(),
        clock: () => DateTime.fromMillisecondsSinceEpoch(1790000400 * 1000),
      ),
    ),
  );
  await _frames(tester);
}

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Finder get _header => find.byKey(const ValueKey('room-header'));
Finder get _cluster => find.byKey(const ValueKey('room-header-cluster'));
Finder get _pillText => find.descendant(
  of: _header,
  matching: find.byKey(const ValueKey('floating-header-text')),
);
Finder get _bar => find.byKey(const ValueKey('room-header-bar'));
Finder get _transcript => find.byKey(const ValueKey('room-transcript'));

/// The room's status line: shown in the pill while someone works or needs
/// you; idle it lives in the header's semantics.
String _statusText(WidgetTester tester) =>
    tester.widget<RoomHeaderBar>(find.byType(RoomHeaderBar)).status;

String _pillLine(WidgetTester tester) => tester.widget<Text>(_pillText).data!;

List<Map<String, dynamic>> _finished(EventSeq seq) {
  final u = seq.user('@builder go');
  final disc = u['event_id'] as String;
  return [
    u,
    seq.started('m-builder', disc),
    seq.member('m-builder', 'builder', 'done', disc),
    seq.settled('m-builder', disc),
  ];
}

List<Map<String, dynamic>> _longRoom(EventSeq seq) => [
  for (var r = 0; r < 12; r++)
    ...() {
      final u = seq.user('question $r @builder', thread: 'thread-$r');
      final disc = u['event_id'] as String;
      return [
        u,
        seq.started('m-builder', disc),
        seq.member(
          'm-builder',
          'builder',
          List.generate(6, (i) => 'Answer $r paragraph $i.').join('\n\n'),
          disc,
          thread: 'thread-$r',
        ),
        seq.settled('m-builder', disc),
      ];
    }(),
];

void main() {
  setUpAll(loadInterFont);

  group('room header · one calm layer', () {
    testWidgets('floating: faces sit on the pill, idle says the room name; '
        'no app bar band, no mosaic, no strip', (tester) async {
      await _pump(tester, events: _finished(EventSeq()), status: driver());
      expect(find.byType(AppBar), findsNothing);
      expect(find.descendant(of: _bar, matching: _cluster), findsOneWidget);
      expect(_pillLine(tester), 'Console Devs');
      expect(
        _statusText(tester),
        matches(RegExp(r'^4 bots · round finished \d+ min ago$')),
      );
      final cluster = tester.getRect(_cluster);
      final pill = tester.getRect(_header);
      expect(cluster.top, lessThan(pill.top));
      expect(cluster.bottom, greaterThan(pill.top), reason: 'sits on it');
      expect((cluster.center.dx - pill.center.dx).abs(), lessThan(24));
      // The old layers are gone: the 2×2 mosaic, the availability subtitle
      // and the second strip of faces under the app bar.
      expect(find.byKey(const ValueKey('room-header-faces')), findsNothing);
      expect(find.byKey(const ValueKey('room-availability')), findsNothing);
      expect(find.byKey(const ValueKey('room-status-strip')), findsNothing);
      // The conversation runs UNDER the header, from the top of the screen.
      expect(tester.getTopLeft(_transcript).dy, 0);
      expect(pill.top, greaterThanOrEqualTo(_statusBar));
      expect(tester.takeException(), isNull);
    });

    testWidgets('status merges presence and round state (ES)', (tester) async {
      await _pump(
        tester,
        events: _finished(EventSeq()),
        status: driver(),
        locale: const Locale('es'),
      );
      expect(
        _statusText(tester),
        matches(RegExp(r'^4 bots · ronda terminada hace \d+ min$')),
      );
    });

    testWidgets('an unavailable member shows in the presence part', (
      tester,
    ) async {
      final seq = EventSeq();
      final events = _finished(seq)..add(seq.unavailable('m-radar'));
      await _pump(tester, events: events, status: driver());
      expect(_statusText(tester), startsWith('3 of 4 bots · '));
    });

    testWidgets('an empty room shows only who is in it', (tester) async {
      await _pump(tester, events: const [], status: null);
      expect(_statusText(tester), '4 bots');
    });

    testWidgets('who is replying replaces the idle line', (tester) async {
      final seq = EventSeq();
      final u = seq.user('@radar go');
      await _pump(
        tester,
        events: [u, seq.started('m-radar', u['event_id'] as String)],
        status: driver(working: true, counts: {'running': 1}),
      );
      expect(
        _statusText(tester),
        matches(RegExp(r'^console-radar is replying · \d+:\d\d$')),
      );
      // Working: the pill says it, with a green dot.
      expect(_pillLine(tester), _statusText(tester));
      expect(
        find.byKey(const ValueKey('floating-header-dot-working')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('room-header-dot-m-radar-working')),
        findsOneWidget,
      );
    });

    testWidgets('two waiting on you read "Te esperan 2"', (tester) async {
      final seq = EventSeq();
      final u = seq.user('@builder @lead ship');
      final disc = u['event_id'] as String;
      await _pump(
        tester,
        events: [
          u,
          seq.started('m-builder', disc),
          seq.started('m-lead', disc),
        ],
        status: driver(
          working: true,
          pending: [
            approvalAction(),
            approvalAction(
              member: 'm-builder',
              task: 'task-m-builder-0',
              request: 'apr-2',
            ),
          ],
        ),
        locale: const Locale('es'),
      );
      expect(_statusText(tester), 'Te esperan 2');
      // Needs you: amber in the pill.
      expect(_pillLine(tester), 'Te esperan 2');
      final text = tester.widget<Text>(_pillText);
      expect(
        text.style!.color,
        Theme.of(tester.element(_pillText)).hermes.warning,
      );
    });

    testWidgets('at most four faces plus "+N", working face first', (
      tester,
    ) async {
      final seq = EventSeq();
      final u = seq.user('@sixth go');
      await _pump(
        tester,
        members: [
          for (final h in ['builder', 'review', 'lead', 'radar', 'fifth'])
            memberJson('m-$h', h, displayName: 'console-$h'),
          memberJson('m-sixth', 'sixth', displayName: 'console-sixth'),
        ],
        events: [u, seq.started('m-sixth', u['event_id'] as String)],
        status: driver(working: true, counts: {'running': 1}),
      );
      final faces = find.descendant(
        of: _cluster,
        matching: find.byWidgetPredicate(
          (w) =>
              w.key is ValueKey<String> &&
              (w.key! as ValueKey<String>).value.startsWith(
                'room-header-face-',
              ),
        ),
      );
      expect(faces, findsNWidgets(4));
      expect(
        find.descendant(of: _cluster, matching: find.text('+2')),
        findsOneWidget,
      );
      final sixth = tester.getTopLeft(
        find.byKey(const ValueKey('room-header-face-m-sixth')),
      );
      for (final e in faces.evaluate()) {
        final box = e.renderObject! as RenderBox;
        expect(
          box.localToGlobal(Offset.zero).dx,
          greaterThanOrEqualTo(sixth.dx),
        );
      }
    });

    testWidgets('header is centred and announces name and status', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, events: _finished(EventSeq()), status: driver());
      final centre = tester.getCenter(_header).dx;
      expect(centre, closeTo(412 / 2, 24));
      expect(
        find.bySemanticsLabel(RegExp(r'Console Devs.*4 bots · round finished')),
        findsOneWidget,
      );
      handle.dispose();
    });
  });

  group('room header · opens the detail', () {
    testWidgets('tap opens the round detail, which leads to members', (
      tester,
    ) async {
      final seq = EventSeq();
      final u = seq.user('@builder @lead ship it');
      final disc = u['event_id'] as String;
      await _pump(
        tester,
        events: [
          u,
          seq.started('m-builder', disc),
          seq.started('m-lead', disc),
        ],
        status: driver(working: true, pending: [approvalAction()]),
      );
      final top = tester.getTopLeft(_transcript).dy;
      await tester.tap(_header);
      await _frames(tester);
      expect(find.byKey(const ValueKey('room-round-sheet')), findsOneWidget);
      expect(find.text('Wants to run gh pr ready 51'), findsOneWidget);
      expect(tester.getTopLeft(_transcript).dy, top);
      await tester.tap(find.byKey(const ValueKey('room-round-members')));
      await _frames(tester);
      expect(find.byKey(const ValueKey('room-members-sheet')), findsOneWidget);
    });

    testWidgets('without a round the tap opens the members sheet', (
      tester,
    ) async {
      await _pump(tester, events: const [], status: null);
      await tester.tap(_header);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('room-members-sheet')), findsOneWidget);
    });
  });

  group('room header · floating and scale', () {
    testWidgets('scrolling never changes the header; the oldest row is not '
        'hidden under it', (tester) async {
      await _pump(tester, events: _longRoom(EventSeq()), status: driver());
      final before = tester.getRect(_header);
      await tester.drag(_transcript, const Offset(0, 500));
      await _frames(tester);
      expect(tester.getRect(_header), before);
      expect(_cluster, findsOneWidget);
      // At the very top the first row starts below the header.
      final position = tester
          .state<ScrollableState>(
            find.descendant(of: _transcript, matching: find.byType(Scrollable)),
          )
          .position;
      position.jumpTo(position.maxScrollExtent);
      await _frames(tester);
      final first = find.textContaining('question 0 @builder');
      expect(first, findsOneWidget);
      expect(
        tester.getTopLeft(first).dy,
        greaterThan(tester.getBottomLeft(_header).dy),
      );
    });

    testWidgets('long press on the pill opens the room menu', (tester) async {
      await _pump(tester, events: _finished(EventSeq()), status: driver());
      expect(find.byKey(const ValueKey('room-overflow')), findsNothing);
      await tester.longPress(_header);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('room-overflow-menu')), findsOneWidget);
    });

    for (final (label, size) in const [
      ('phone', Size(360, 800)),
      ('tablet', Size(1280, 800)),
    ]) {
      testWidgets('text scale 2.0 on $label: one line, centred, fits', (
        tester,
      ) async {
        await _pump(
          tester,
          events: _finished(EventSeq()),
          status: driver(),
          size: size,
          textScale: 2,
          locale: const Locale('es'),
        );
        expect(tester.takeException(), isNull);
        final p = tester.renderObject<RenderParagraph>(
          find.descendant(of: _pillText, matching: find.byType(RichText)),
        );
        final line = p.text.style?.fontSize ?? 14;
        expect(
          tester.getSize(_pillText).height,
          lessThan(line * p.textScaler.scale(1) * 2),
          reason: 'one line',
        );
        expect(p.textScaler.scale(1), greaterThan(1));
        expect(tester.getCenter(_header).dx, closeTo(size.width / 2, 2));
        final bar = tester.getRect(_bar);
        expect(tester.getRect(_header).bottom, lessThan(bar.bottom));
      });
    }
  });
}
