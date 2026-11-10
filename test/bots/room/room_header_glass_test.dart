import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/ui/room/room_gateway.dart';
import 'package:hermes_android/core/bots/ui/room/room_prefs.dart';
import 'package:hermes_android/core/bots/ui/room/room_screen.dart';
import 'package:hermes_android/core/design/glass_strip.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/floating_chat_header.dart';
import 'package:hermes_android/core/widgets/frosted_backdrop.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import '../../support/inter_font.dart';
import 'room_fixtures.dart';

/// The owner (QA 1.4.0, room «prueba» on the Fold's cover screen): a room's
/// header was an opaque dark band with a hard edge above «Hoy», while a
/// normal chat scrolls behind the translucent header of the composer's
/// glass. A room's header takes exactly the chat's treatment: the same
/// strip, the same soft fade and the same blur policy.
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

Future<void> _pump(WidgetTester tester) async {
  tester.view.devicePixelRatio = 2.625;
  tester.view.physicalSize = const Size(412 * 2.625, 915 * 2.625);
  tester.view.padding = const FakeViewPadding(top: 63, bottom: 55);
  tester.view.viewPadding = const FakeViewPadding(top: 63, bottom: 55);
  addTearDown(tester.view.reset);
  final seq = EventSeq();
  final events = <Map<String, dynamic>>[];
  for (var i = 0; i < 8; i++) {
    final u = seq.user('question $i', thread: 't$i', id: 'user-$i');
    events
      ..add(u)
      ..add(
        seq.member(
          'm-builder',
          'builder',
          'answer $i\n\nline two',
          u['event_id'] as String,
          thread: 't$i',
        ),
      );
  }
  final log = buildLog(events);
  final room = buildRoom(latestSeq: log.latestSeq, name: 'prueba');
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      locale: const Locale('es'),
      theme: AppTheme.hermesRedDark,
      home: RoomScreen(
        room: room,
        log: log,
        gateway: _Gateway(room, log),
        capabilities: const RoomCapabilities(canSend: true),
        profileFor: (_) => null,
        prefs: MemoryRoomPrefs(),
        pollTimer: (_, _) => _FakeTimer(),
        clock: () => DateTime.fromMillisecondsSinceEpoch(1790000400 * 1000),
      ),
    ),
  );
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Finder get _header => find.byKey(const ValueKey('room-header-bar'));

LinearGradient _scrim(WidgetTester tester) =>
    (tester
                .widget<DecoratedBox>(
                  find.descendant(
                    of: _header,
                    matching: find.byKey(
                      const ValueKey('floating-header-scrim'),
                    ),
                  ),
                )
                .decoration
            as BoxDecoration)
        .gradient!
        as LinearGradient;

void main() {
  setUpAll(loadInterFont);
  tearDown(() {
    FrostedBackdropPolicy.blurAllowed.value = true;
    FrostedBackdropPolicy.reducedPerformance.value = false;
  });

  group('room header: the same glass as a normal chat', () {
    testWidgets('the header is the chat\'s glass strip with its soft fade, '
        'never an opaque band', (tester) async {
      await _pump(tester);
      expect(tester.takeException(), isNull);
      final header = tester.widget<FloatingChatHeader>(_header);
      // The chat's own configuration (chat_screen.dart builds its header
      // with `glass: true` and the chat priority).
      expect(header.glass, isTrue, reason: 'a room header is not glass');
      expect(header.glassPriority, FloatingChatHeader.chatGlassPriority);
      expect(
        find.ancestor(of: _header, matching: find.byType(HermesGlassStrip)),
        findsNothing,
      );
      expect(
        find.descendant(of: _header, matching: find.byType(HermesGlassStrip)),
        findsOneWidget,
      );
      // Never a solid band: denser over the status bar, lighter towards
      // the pieces' foot, gone below.
      final scrim = _scrim(tester);
      expect(
        [for (final c in scrim.colors) c.a],
        [
          closeTo(HermesGlassStrip.fadeTop, 0.002),
          closeTo(HermesGlassStrip.fadeStatus, 0.002),
          closeTo(HermesGlassStrip.fadeEdge, 0.002),
          0,
        ],
      );
    });

    testWidgets('the transcript runs under the header region', (
      tester,
    ) async {
      await _pump(tester);
      final transcript = tester.getRect(
        find.byKey(const ValueKey('room-transcript')),
      );
      final header = tester.getRect(
        find.descendant(
          of: _header,
          matching: find.byKey(const ValueKey('floating-header')),
        ),
      );
      expect(transcript.top, lessThanOrEqualTo(header.top + 0.5));
      expect(transcript.bottom, greaterThan(header.bottom));
    });

    // Control: the blur policy is the chat's. Where the device does not
    // blur, the chat's header falls back to the solid header, and so does
    // the room's.
    testWidgets('control: a device that does not blur keeps the solid '
        'header, as a chat does', (tester) async {
      FrostedBackdropPolicy.blurAllowed.value = false;
      await _pump(tester);
      expect(tester.layers.whereType<BackdropFilterLayer>(), isEmpty);
      expect(_scrim(tester).colors[1].a, 1);
    });
  });
}
