import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/ui/room/room_gateway.dart';
import 'package:hermes_android/core/bots/ui/room/room_prefs.dart';
import 'package:hermes_android/core/bots/ui/room/room_screen.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/scroll_behavior.dart';
import 'package:hermes_android/core/widgets/chat/console_composer.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import '../../support/inter_font.dart';
import 'room_fixtures.dart';

/// The owner (QA 1.4.0, Fold cover screen, room «prueba»): after
/// «@console-builder hola?» the console-builder's reply (quote line
/// «↳ Tú: …» first) stayed BEHIND the composer, its face peeking out at the
/// composer's left and the quote line under it, near the gesture bar. A
/// reader at the bottom must see the newest row whole, above the composer
/// region (the composer and the notch's grabber on its top edge), as in a
/// single-profile chat.
final class _FakeTimer implements Timer {
  @override
  void cancel() {}
  @override
  bool get isActive => true;
  @override
  int get tick => 0;
}

/// A room server: `send` publishes the owner's message and, while the
/// mentioned member works, its `turn.started`; [reply] publishes its answer.
final class _Server implements RoomGateway {
  HostedGroupRoom room;
  HostedGroupLogPage log;
  final EventSeq seq;
  List<Map<String, dynamic>> events;
  RoomDriverStatus status = driver();
  final bool announceWork;
  String? lastSent;

  _Server(this.seq, this.events, {required this.announceWork})
    : log = buildLog(events),
      room = buildRoom(latestSeq: events.length, name: 'prueba');

  HostedGroupWorkspaceReadback get _readback => HostedGroupWorkspaceReadback(
    room: room,
    log: log,
    capabilityGeneration: 1,
    driverStatus: status,
  );

  void _publish(List<Map<String, dynamic>> next) {
    events = next;
    log = buildLog(next);
    room = buildRoom(latestSeq: log.latestSeq, name: 'prueba');
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
    final user = seq.user(
      text,
      thread: attempt.threadId,
      id: attempt.durableEventId,
    );
    lastSent = user['event_id'] as String;
    _publish([
      ...events,
      user,
      if (announceWork) seq.started('m-builder', lastSent!, round: 1),
    ]);
    if (announceWork) status = driver(working: true);
    return _readback;
  }

  /// The mentioned member answers the owner's last message.
  String reply() {
    final answer = seq.member(
      'm-builder',
      'builder',
      '¡Hola! Aquí console-builder. Dime qué necesitas y lo miro.',
      lastSent!,
      round: 1,
    );
    _publish([
      ...events,
      answer,
      seq.settled('m-builder', lastSent!, round: 1),
    ]);
    status = driver();
    return answer['event_id'] as String;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// «Hola» answered by one member while another passes: the scene above the
/// owner's mention in the report.
List<Map<String, dynamic>> _history(EventSeq seq) {
  final hola = seq.user('Hola');
  final disc = hola['event_id'] as String;
  return [
    hola,
    seq.started('m-lead', disc),
    seq.started('m-review', disc),
    seq.member('m-lead', 'lead', '¡Hola! Por aquí.', disc),
    seq.settled('m-lead', disc),
    seq.settled('m-review', disc, passed: true),
  ];
}

Future<_Server> _pump(
  WidgetTester tester, {
  required Size size,
  required bool announceWork,
}) async {
  const dpr = 2.625;
  tester.view.devicePixelRatio = dpr;
  tester.view.physicalSize = size * dpr;
  // Status bar and a gesture-navigation bar, as on the owner's phone.
  tester.view.padding = const FakeViewPadding(top: 24 * dpr, bottom: 21 * dpr);
  tester.view.viewPadding = const FakeViewPadding(
    top: 24 * dpr,
    bottom: 21 * dpr,
  );
  addTearDown(tester.view.reset);
  final seq = EventSeq();
  final server = _Server(seq, _history(seq), announceWork: announceWork);
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      locale: const Locale('es'),
      theme: AppTheme.hermesRedDark,
      // The app's own scroll behaviour (main.dart).
      scrollBehavior: const MomentumScrollBehavior(),
      home: RoomScreen(
        room: server.room,
        log: server.log,
        driverStatus: server.status,
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

Future<void> _frames(WidgetTester tester, [int count = 12]) async {
  for (var i = 0; i < count; i++) {
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

Finder get _field => find.descendant(
  of: find.byType(ConsoleComposer),
  matching: find.byType(TextField),
);

Future<void> _send(WidgetTester tester, String text) async {
  await tester.tap(_field);
  await tester.enterText(_field, text);
  await tester.pump();
  await tester.tap(
    find.byKey(const ValueKey('composer-primary-action-switcher')),
  );
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 20)),
  );
  await _frames(tester);
}

ScrollPosition _position(WidgetTester tester) => tester
    .state<ScrollableState>(
      find
          .descendant(
            of: find.byKey(
              const ValueKey('room-transcript'),
              skipOffstage: false,
            ),
            matching: find.byType(Scrollable, skipOffstage: false),
            skipOffstage: false,
          )
          .first,
    )
    .position;

/// Bottom edge of the row [id] (its tile or its card, whichever reaches
/// lower); null when the row is not built at all.
double? _rowBottom(WidgetTester tester, String id) {
  double? bottom;
  for (final key in ['room-message-$id', 'room-member-card-$id']) {
    final found = find.byKey(ValueKey(key), skipOffstage: false);
    if (found.evaluate().isEmpty) continue;
    final rect = tester.getRect(found.first);
    bottom = math.max(bottom ?? rect.bottom, rect.bottom);
  }
  return bottom;
}

/// Top of the composer region: the composer pill, or the notch's grabber
/// on its top edge when that sits higher.
double _composerRegionTop(WidgetTester tester) {
  var top = tester.getRect(find.byKey(const ValueKey('room-composer'))).top;
  final grabber = find.byKey(const ValueKey('chat-notch-grabber'));
  if (grabber.evaluate().isNotEmpty) {
    top = math.min(top, tester.getRect(grabber.first).top);
  }
  return top;
}

String _diag(WidgetTester tester, String id) {
  final p = _position(tester);
  int count(Key key) =>
      find.byKey(key, skipOffstage: false).evaluate().length;
  final inset = count(const ValueKey('room-bottom-inset'));
  final pill = count(const ValueKey('room-new-pill'));
  final row = _rowBottom(tester, id)?.toStringAsFixed(1);
  final region = _composerRegionTop(tester).toStringAsFixed(1);
  return 'pixels=${p.pixels.toStringAsFixed(1)} '
      'min=${p.minScrollExtent.toStringAsFixed(1)} '
      'max=${p.maxScrollExtent.toStringAsFixed(1)} '
      'newerInset=$inset pill=$pill row=$row region=$region';
}

/// A poll read lands (its setState) with no frame pumped after it.
Future<void> _readNoFrame(WidgetTester tester) => tester.runAsync(
  () => tester
      .state<RoomScreenState>(find.byType(RoomScreen, skipOffstage: false))
      .refresh(),
);

Finder get _transcript => find.byKey(const ValueKey('room-transcript'));

/// A phone keyboard, in physical pixels.
const double _keyboard = 300 * 2.625;

void main() {
  setUpAll(loadInterFont);

  for (final size in const [Size(412, 915), Size(360, 640)]) {
    for (final announceWork in const [true, false]) {
      for (final keyboard in const [false, true]) {
        final label =
            '${size.width.toInt()}x${size.height.toInt()}'
            '${announceWork ? ', typing row first' : ''}'
            '${keyboard ? ', keyboard up' : ''}';
        testWidgets('$label: the mentioned member\'s reply lands whole above '
            'the composer and the reader keeps following', (tester) async {
          final server = await _pump(
            tester,
            size: size,
            announceWork: announceWork,
          );
          if (keyboard) {
            tester.view.viewInsets = const FakeViewPadding(bottom: _keyboard);
            await _frames(tester, 4);
          }
          await _send(tester, '@builder hola?');
          expect(server.lastSent, isNotNull);
          final position = _position(tester);
          expect(
            position.pixels,
            lessThanOrEqualTo(position.minScrollExtent + 0.5),
            reason: 'at the bottom after sending',
          );
          final id = server.reply();
          await _refresh(tester);
          debugPrint('[diag-rs] $label ${_diag(tester, id)}');
          final bottom = _rowBottom(tester, id);
          expect(bottom, isNotNull, reason: 'the reply row is built');
          expect(
            find.byKey(ValueKey('room-quote-text-$id'), skipOffstage: false),
            findsOneWidget,
            reason: 'the reply opens with its quote line',
          );
          expect(
            bottom,
            lessThanOrEqualTo(_composerRegionTop(tester) + 0.5),
            reason:
                'the newest row is fully visible above the composer '
                '(${_diag(tester, id)})',
          );
          expect(
            position.pixels,
            lessThanOrEqualTo(position.minScrollExtent + 0.5),
            reason: 'auto-follow stays on for a reader at the bottom',
          );
          if (keyboard) {
            tester.view.viewInsets = FakeViewPadding.zero;
            await _frames(tester);
            debugPrint('[diag-rs] $label keyboard down ${_diag(tester, id)}');
            expect(
              _rowBottom(tester, id),
              lessThanOrEqualTo(_composerRegionTop(tester) + 0.5),
              reason: 'still whole once the keyboard is down',
            );
          }
          expect(tester.takeException(), isNull);
        });
      }
    }
  }

  // Probe P1 (gate bugrs2): the reader's finger starts moving in the frame
  // where the read that carries the reply has landed but is not built yet.
  // Reading began with the boundary at the last BUILT row and the ceiling
  // at the log's newest seq, so the reply went below the boundary (behind
  // the composer) already counted as seen: no pill said it was there.
  for (final size in const [Size(412, 915), Size(360, 640)]) {
    final w = '${size.width.toInt()}x${size.height.toInt()}';
    testWidgets('$w: a drag that starts while the reply\'s read is still '
        'unbuilt never leaves the reply behind the composer unannounced', (
      tester,
    ) async {
      final server = await _pump(tester, size: size, announceWork: true);
      await _send(tester, '@builder hola?');
      final id = server.reply();
      await _readNoFrame(tester);
      final gesture = await tester.startGesture(tester.getCenter(_transcript));
      await gesture.moveBy(const Offset(0, 24));
      await gesture.moveBy(const Offset(0, 16));
      await tester.pump();
      await gesture.up();
      await _frames(tester, 20);
      final diag = _diag(tester, id);
      debugPrint('[diag-rs] $w drag in the read frame $diag');
      final bottom = _rowBottom(tester, id);
      expect(bottom, isNotNull, reason: 'the reply row is built');
      final hidden = bottom! > _composerRegionTop(tester) + 0.5;
      if (hidden) {
        expect(
          find.byKey(const ValueKey('room-new-pill')),
          findsOneWidget,
          reason: 'a reply below the composer is announced ($diag)',
        );
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('room-new-pill')),
            matching: find.text('1 respuesta nueva a tu mensaje'),
          ),
          findsOneWidget,
          reason: 'it answers the owner\'s message ($diag)',
        );
      }
      expect(tester.takeException(), isNull);
    });
  }
}
