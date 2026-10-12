import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/generated_video_card.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'support/fake_video_player_platform.dart';

/// Videos in a chat must play on first view AND every time the row comes
/// back: after leaving and re-entering the chat, after the lazy transcript
/// remounts the row, after a platform error, and from the full-screen viewer.
void main() {
  late FakeVideoPlayerPlatform platform;
  late Directory directory;
  late File file;

  setUp(() {
    platform = FakeVideoPlayerPlatform.install();
    directory = Directory.systemTemp.createTempSync('video-replay-');
    file = File('${directory.path}/clip.mp4')
      ..writeAsBytesSync(<int>[0, 0, 0, 24, 0x66, 0x74, 0x79, 0x70]);
    GeneratedVideoCard.clearPlaybackMemoryForTesting();
  });

  tearDown(() => directory.deleteSync(recursive: true));

  Widget host(ValueNotifier<Object?> slot) => MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: Strings.localizationsDelegates,
    supportedLocales: Strings.supportedLocales,
    theme: AppTheme.hermesRedDark,
    home: Scaffold(
      body: ValueListenableBuilder<Object?>(
        valueListenable: slot,
        builder: (context, key, _) => key == null
            ? const SizedBox.shrink()
            : SingleChildScrollView(
                child: KeyedSubtree(
                  key: ValueKey<Object>(key),
                  child: GeneratedVideoCard(file: file),
                ),
              ),
      ),
    ),
  );

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump();
    }
  }

  testWidgets('first view shows the poster frame, play button and duration '
      'without autoplaying', (tester) async {
    final slot = ValueNotifier<Object?>('row');
    await tester.pumpWidget(host(slot));
    await settle(tester);

    expect(platform.live, [1]);
    expect(find.byKey(const ValueKey('fake-video-1')), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow_rounded), findsWidgets);
    expect(find.text('0:05'), findsOneWidget);
    expect(platform.calls.where((c) => c.startsWith('play:')), isEmpty);
  });

  testWidgets('leaving and re-entering the chat creates a fresh controller '
      'that plays', (tester) async {
    final slot = ValueNotifier<Object?>('row');
    await tester.pumpWidget(host(slot));
    await settle(tester);
    await tester.tap(find.byIcon(Icons.play_arrow_rounded).last);
    await settle(tester);
    expect(platform.calls, contains('play:1'));

    slot.value = null; // leave the chat
    await settle(tester);
    expect(platform.disposed, contains(1));

    slot.value = 'row-again'; // re-enter
    await settle(tester);
    expect(platform.live, [2]);
    await tester.tap(find.byIcon(Icons.play_arrow_rounded).last);
    await settle(tester);
    expect(platform.calls, contains('play:2'));
  });

  testWidgets('a remounted row keeps the playback position', (tester) async {
    final slot = ValueNotifier<Object?>('row');
    await tester.pumpWidget(host(slot));
    await settle(tester);
    await tester.tap(find.byIcon(Icons.play_arrow_rounded).last);
    await settle(tester);
    await platform.seekTo(1, const Duration(seconds: 3));
    // The controller polls the position every 500 ms while playing.
    await tester.pump(const Duration(milliseconds: 600));
    await settle(tester);

    slot.value = 'remounted';
    await settle(tester);

    expect(platform.live, [2]);
    expect(platform.calls, contains('seek:2:3000'));
  });

  testWidgets('a playback error after init shows Retry, and Retry builds a '
      'new controller', (tester) async {
    final slot = ValueNotifier<Object?>('row');
    await tester.pumpWidget(host(slot));
    await settle(tester);

    platform.emitError(1);
    await settle(tester);

    expect(find.text('Retry'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await settle(tester);

    expect(platform.disposed, contains(1));
    expect(platform.live, [2]);
    expect(find.byKey(const ValueKey('fake-video-2')), findsOneWidget);
  });

  testWidgets('the full-screen viewer keeps playing after the row that '
      'opened it is disposed', (tester) async {
    final slot = ValueNotifier<Object?>('row');
    await tester.pumpWidget(host(slot));
    await settle(tester);

    await tester.tap(find.byIcon(Icons.fullscreen_rounded));
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 300));

    // The lazy transcript disposes the row under the open viewer.
    slot.value = null;
    await settle(tester);

    final viewer = find.byKey(
      const ValueKey('generated-video-viewer-safe-area'),
    );
    expect(viewer, findsOneWidget);
    platform.calls.clear();
    Future<void> tapInViewer(IconData icon) async {
      await tester.tap(
        find.descendant(of: viewer, matching: find.byIcon(icon)).last,
      );
      await settle(tester);
    }

    // Toggle playback from the viewer's own bar: pause if it is already
    // playing, then play.
    if (find
        .descendant(of: viewer, matching: find.byIcon(Icons.pause_rounded))
        .evaluate()
        .isNotEmpty) {
      await tapInViewer(Icons.pause_rounded);
    }
    await tapInViewer(Icons.play_arrow_rounded);

    final played = platform.calls
        .where((c) => c.startsWith('play:'))
        .map((c) => int.parse(c.split(':').last))
        .toList();
    expect(played, isNotEmpty, reason: 'the viewer must drive a live player');
    expect(played.every((id) => !platform.disposed.contains(id)), isTrue);

    // Closing the viewer releases its player.
    await tester.tap(find.byIcon(Icons.close));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await settle(tester);
    expect(viewer, findsNothing);
    expect(platform.live, isEmpty);
  });
}
