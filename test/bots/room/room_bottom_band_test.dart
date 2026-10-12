import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/ui/room/room_gateway.dart';
import 'package:hermes_android/core/bots/ui/room/room_prefs.dart';
import 'package:hermes_android/core/bots/ui/room/room_screen.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'package:hermes_android/core/widgets/extent_reporter.dart';

import '../../support/bottom_transparency.dart';
import '../../support/inter_font.dart';
import 'room_fixtures.dart';

final class _FakeTimer implements Timer {
  @override
  void cancel() {}
  @override
  bool get isActive => true;
  @override
  int get tick => 0;
}

final class _Gateway implements RoomGateway {
  final HostedGroupRoom room;
  final HostedGroupLogPage log;
  _Gateway(this.room, this.log);

  @override
  Future<HostedGroupWorkspaceReadback> read(HostedGroupRoom room) async =>
      HostedGroupWorkspaceReadback(
        room: this.room,
        log: log,
        capabilityGeneration: 1,
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _pump(
  WidgetTester tester,
  List<Map<String, dynamic>> events,
) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3;
  // A 21 dp gesture-navigation inset, as on the owner's phone.
  tester.view.padding = const FakeViewPadding(bottom: 63);
  tester.view.viewPadding = const FakeViewPadding(bottom: 63);
  addTearDown(tester.view.reset);
  final log = buildLog(events);
  final room = buildRoom(latestSeq: log.latestSeq);
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      locale: const Locale('en'),
      theme: AppTheme.hermesRedDark,
      home: RoomScreen(
        room: room,
        log: log,
        gateway: _Gateway(room, log),
        capabilities: const RoomCapabilities(
          canSend: true,
          canRename: true,
          canStop: true,
          canDisband: true,
          canApprove: true,
          canRetry: true,
        ),
        profileFor: (_) => null,
        prefs: MemoryRoomPrefs(),
        pollTimer: (_, _) => _FakeTimer(),
        clock: () => DateTime.fromMillisecondsSinceEpoch(1790000400 * 1000),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

List<Map<String, dynamic>> _longRoom(EventSeq seq) => [
  for (var i = 0; i < 20; i++)
    ...() {
      final u = seq.user('question $i', thread: 't$i', id: 'user-$i');
      return [
        u,
        seq.member(
          'm-builder',
          'builder',
          'answer $i\n\nline two\n\nline three',
          u['event_id'] as String,
          thread: 't$i',
        ),
      ];
    }(),
];

Finder get _transcript => find.byKey(const ValueKey('room-transcript'));
Finder get _composer => find.byKey(const ValueKey('room-composer'));
Finder get _stack => find.byKey(const ValueKey('room-bottom-stack'));

/// The newest painted message tile (largest bottom edge).
Rect _newestMessage(WidgetTester tester) {
  Rect? newest;
  for (final e
      in find
          .byWidgetPredicate(
            (w) =>
                w.key is ValueKey<String> &&
                (w.key! as ValueKey<String>).value.startsWith('room-message-'),
          )
          .evaluate()) {
    final box = e.renderObject;
    if (box is! RenderBox || !box.hasSize) continue;
    final r = box.localToGlobal(Offset.zero) & box.size;
    if (newest == null || r.bottom > newest.bottom) newest = r;
  }
  return newest!;
}

void main() {
  setUpAll(loadInterFont);
  setUp(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => Directory.systemTemp.path,
        );
  });

  // Owner (QA): a hard dark band about 90 dp tall cut the room transcript
  // above the composer. The list now runs to the bottom under a floating
  // composer and only a short fade softens the edge.
  group('room bottom: the transcript runs under the floating composer', () {
    testWidgets('the list viewport reaches the screen bottom (above the '
        'navigation inset), not the composer top', (tester) async {
      await _pump(tester, _longRoom(EventSeq()));
      final list = tester.getRect(_transcript);
      expect(list.bottom, closeTo(800 - 21, 0.5));
      expect(list.bottom, greaterThan(tester.getRect(_composer).bottom - 0.5));
    });

    testWidgets('at rest the newest message sits just above the composer, '
        'and scrolls under it when the reader moves', (tester) async {
      await _pump(tester, _longRoom(EventSeq()));
      final composerTop = tester.getRect(_composer).top;
      final newest = _newestMessage(tester);
      expect(newest.bottom, lessThanOrEqualTo(composerTop + 0.5));
      expect(
        newest.bottom,
        greaterThan(composerTop - kComposerFadeHeight - 24),
        reason: 'no empty band between the last message and the composer',
      );
      // Reading back moves rows into the area behind the composer.
      await tester.drag(_transcript, const Offset(0, -10));
      await tester.drag(_transcript, const Offset(0, 120));
      await tester.pumpAndSettle();
      var under = false;
      for (final e
          in find
              .byWidgetPredicate(
                (w) =>
                    w.key is ValueKey<String> &&
                    (w.key! as ValueKey<String>).value.startsWith(
                      'room-message-',
                    ),
              )
              .evaluate()) {
        final box = e.renderObject;
        if (box is! RenderBox || !box.hasSize) continue;
        final r = box.localToGlobal(Offset.zero) & box.size;
        if (r.bottom > composerTop + 1) under = true;
      }
      expect(under, isTrue, reason: 'rows pass under the composer');
    });

    // pm1215 (owner, QA 9494): like under the floating header, nothing is
    // painted above or around the composer: no band, no fade. Only the
    // composer pill (and the notch) have a surface.
    testWidgets('nothing painted between the list and the composer: no '
        'band, no fade', (tester) async {
      await _pump(tester, _longRoom(EventSeq()));
      final gap = find.byKey(const ValueKey('room-bottom-gap'));
      expect(find.byKey(const ValueKey('room-bottom-fade')), findsNothing);
      expect(
        find.descendant(
          of: gap,
          matching: find.byWidgetPredicate(
            (w) => w is DecoratedBox || w is ColoredBox,
          ),
        ),
        findsNothing,
      );
      final fadeRect = tester.getRect(gap);
      expect(fadeRect.height, inInclusiveRange(24, 32));
      expect(fadeRect.bottom, closeTo(tester.getRect(_composer).top, 0.5));
      // No other filled surface in the floating stack outside the composer.
      final inComposer = find
          .descendant(
            of: _composer,
            matching: find.byWidgetPredicate((_) => true),
          )
          .evaluate()
          .toSet();
      for (final e
          in find
              .descendant(
                of: _stack,
                matching: find.byWidgetPredicate(
                  (w) => w is ColoredBox || w is DecoratedBox,
                ),
              )
              .evaluate()) {
        if (inComposer.contains(e)) continue;
        final w = e.widget;
        final opaque = w is ColoredBox
            ? w.color.a > 0
            : ((w as DecoratedBox).decoration is BoxDecoration &&
                  (((w.decoration as BoxDecoration).color?.a ?? 0) > 0 ||
                      (w.decoration as BoxDecoration).gradient != null));
        expect(opaque, isFalse, reason: 'band: ${w.key}');
      }
      // The stack starts right at the empty slot: no band above it.
      expect(tester.getRect(_stack).top, closeTo(fadeRect.top, 0.5));
    });

    testWidgets('the foot behind the composer is dimmed, and nothing above '
        'it (owner, QA 9529)', (tester) async {
      await _pump(tester, _longRoom(EventSeq()));
      final scrim = tester.getRect(
        find.byKey(const ValueKey('room-foot-scrim')),
      );
      final gap = tester.getRect(find.byKey(const ValueKey('room-bottom-gap')));
      expect(scrim.top, closeTo(gap.bottom, 0.5));
      expect(scrim.bottom, closeTo(tester.getRect(_stack).bottom, 0.5));
      // It never takes a touch.
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('room-foot-scrim')),
          matching: find.byType(IgnorePointer),
        ),
        findsOneWidget,
      );
    });

    testWidgets('pm1215: transcript pixels remain visible above the room '
        'composer (no fade, no band)', (tester) async {
      await _pump(tester, _longRoom(EventSeq()));
      await tester.drag(_transcript, const Offset(0, -10));
      await tester.drag(_transcript, const Offset(0, 120));
      await tester.pumpAndSettle();
      final composer = tester.getRect(_composer);
      final transcript = tester.getRect(_transcript);
      final bg = Theme.of(tester.element(_composer)).hermes.background;
      final pixels = await ViewPixels.capture(tester);
      final strip = Rect.fromLTRB(
        transcript.left,
        composer.top - 12,
        transcript.right,
        composer.top - 1,
      );
      final overlap = find
          .byWidgetPredicate(
            (w) =>
                w.key is ValueKey<String> &&
                (w.key! as ValueKey<String>).value.startsWith('room-message-'),
          )
          .evaluate()
          .map((e) => e.renderObject)
          .whereType<RenderBox>()
          .map((b) => b.localToGlobal(Offset.zero) & b.size)
          .map((r) => r.intersect(strip))
          .firstWhere((r) => !r.isEmpty);
      expect(
        pixels.maxInk(overlap, bg),
        greaterThan(60),
        reason: 'transcript pixels remain visible beside the composer',
      );
    });

    testWidgets('a short room has no slack: dragging never parks its last '
        'message under the composer', (tester) async {
      final seq = EventSeq();
      final u = seq.user('hola', thread: 't0', id: 'user-0');
      await _pump(tester, [
        u,
        seq.member(
          'm-builder',
          'builder',
          'hola, aquí estoy',
          u['event_id'] as String,
          thread: 't0',
        ),
      ]);
      final composerTop = tester.getRect(_composer).top;
      expect(
        _newestMessage(tester).bottom,
        lessThanOrEqualTo(composerTop + 0.5),
      );
      await tester.drag(_transcript, const Offset(0, 20));
      await tester.drag(_transcript, const Offset(0, 200));
      await tester.pumpAndSettle();
      expect(
        _newestMessage(tester).bottom,
        lessThanOrEqualTo(composerTop + 0.5),
      );
    });
  });
}
