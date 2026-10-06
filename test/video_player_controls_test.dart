import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/generated_video_card.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'support/fake_video_player_platform.dart';

/// The chat video card and the full-screen viewer behave like a normal
/// mobile player: replay at the end, a draggable timeline, ±10 s seeks, live
/// time labels, mute, speed, a full-screen round trip that keeps the
/// position, pause when the app or the route goes away, and controls that
/// hide while playing.
void main() {
  late FakeVideoPlayerPlatform platform;
  late Directory directory;
  late File file;
  late List<MethodCall> systemCalls;

  const overlayKey = ValueKey<String>('video-controls-overlay');
  const playKey = ValueKey<String>('video-play-pause');
  const sliderKey = ValueKey<String>('video-seek-slider');
  const positionKey = ValueKey<String>('video-position-label');
  const durationKey = ValueKey<String>('video-duration-label');
  const viewerKey = ValueKey<String>('generated-video-viewer-safe-area');

  void installPlatform(Duration duration) {
    platform = FakeVideoPlayerPlatform.install(duration: duration);
  }

  setUp(() {
    installPlatform(const Duration(seconds: 20));
    directory = Directory.systemTemp.createTempSync('video-controls-');
    file = File('${directory.path}/clip.mp4')
      ..writeAsBytesSync(<int>[0, 0, 0, 24, 0x66, 0x74, 0x79, 0x70]);
    GeneratedVideoCard.clearPlaybackMemoryForTesting();
    systemCalls = <MethodCall>[];
  });

  tearDown(() => directory.deleteSync(recursive: true));

  Future<void> pumpCard(
    WidgetTester tester, {
    bool disableAnimations = false,
    bool accessibleNavigation = false,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        systemCalls.add(call);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.hermesRedDark,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: disableAnimations,
            accessibleNavigation: accessibleNavigation,
          ),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: GeneratedVideoCard(file: file),
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump();
    }
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump();
    }
  }

  List<String> since(int mark) => platform.calls.sublist(mark);

  bool controlsVisible(WidgetTester tester, {Finder? within}) {
    final finder = within == null
        ? find.byKey(overlayKey).first
        : find.descendant(of: within, matching: find.byKey(overlayKey));
    return !tester.widget<IgnorePointer>(finder).ignoring;
  }

  String text(WidgetTester tester, Key key, {Finder? within}) {
    final finder = within == null
        ? find.byKey(key).first
        : find.descendant(of: within, matching: find.byKey(key));
    return tester.widget<Text>(finder).data!;
  }

  Future<void> tapKey(WidgetTester tester, Key key, {Finder? within}) async {
    final finder = within == null
        ? find.byKey(key).first
        : find.descendant(of: within, matching: find.byKey(key));
    await tester.tap(finder);
    await settle(tester);
  }

  Future<void> startPlaying(WidgetTester tester) async {
    await tapKey(tester, playKey);
    expect(platform.calls, contains('play:1'));
  }

  testWidgets('replay after the end restarts at 0 even when a late position '
      'poll lands short of the end', (tester) async {
    installPlatform(const Duration(seconds: 5));
    await pumpCard(tester);
    await startPlaying(tester);

    // A position poll is still in flight when the clip completes.
    platform.holdPositions = true;
    await tester.pump(const Duration(milliseconds: 510));
    expect(platform.heldPositionCount, greaterThan(0));
    platform.emitCompleted(1);
    await settle(tester);
    platform.releasePositions(const Duration(milliseconds: 4900));
    platform.holdPositions = false;
    await settle(tester);

    expect(controlsVisible(tester), isTrue);
    expect(
      find.descendant(
        of: find.byKey(playKey),
        matching: find.byIcon(Icons.replay_rounded),
      ),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('Replay'), findsWidgets);

    final mark = platform.calls.length;
    await tapKey(tester, playKey);
    final after = since(mark);
    expect(after, contains('seek:1:0'));
    expect(after, contains('play:1'));
    expect(
      after.indexOf('seek:1:0'),
      lessThan(after.lastIndexOf('play:1')),
      reason: 'rewind before playing again',
    );
    expect(text(tester, positionKey), '0:00');
  });

  testWidgets('after the end, scrubbing back then Play resumes from the '
      'scrubbed point, not from 0', (tester) async {
    installPlatform(const Duration(seconds: 5));
    await pumpCard(tester);
    await startPlaying(tester);
    platform.emitCompleted(1);
    await settle(tester);

    tester.widget<Slider>(find.byKey(sliderKey)).onChangeStart!(2000);
    tester.widget<Slider>(find.byKey(sliderKey)).onChanged!(2000);
    tester.widget<Slider>(find.byKey(sliderKey)).onChangeEnd!(2000);
    await settle(tester);
    expect(platform.calls, contains('seek:1:2000'));

    final mark = platform.calls.length;
    await tapKey(tester, playKey);
    expect(since(mark), contains('play:1'));
    expect(since(mark).where((c) => c.startsWith('seek:1:')), isEmpty);
  });

  testWidgets('dragging the timeline previews the time and seeks once to '
      'the dropped position', (tester) async {
    await pumpCard(tester);
    final slider = find.byKey(sliderKey);
    final rect = tester.getRect(slider);
    final mark = platform.calls.length;

    final gesture = await tester.startGesture(
      Offset(rect.left + 2, rect.center.dy),
    );
    await tester.pump(kPressTimeout);
    await gesture.moveTo(Offset(rect.center.dx, rect.center.dy));
    await tester.pump();
    // Live preview while the finger is down, no seek yet.
    final preview = text(tester, positionKey);
    expect(preview, isNot('0:00'));
    expect(since(mark).where((c) => c.startsWith('seek:')), isEmpty);

    await gesture.up();
    await settle(tester);
    final seeks = since(
      mark,
    ).where((c) => c.startsWith('seek:1:')).toList(growable: false);
    expect(seeks, hasLength(1));
    final ms = int.parse(seeks.single.split(':').last);
    expect(ms, inInclusiveRange(8500, 11500));
    expect(text(tester, positionKey), preview);
    expect(
      tester.widget<Slider>(slider).value,
      closeTo(ms.toDouble(), 1),
      reason: 'the thumb stays where it was dropped',
    );
  });

  testWidgets('the timeline shows the buffered range', (tester) async {
    await pumpCard(tester);
    platform.emitBuffered(1, const Duration(seconds: 8));
    await settle(tester);
    expect(
      tester.widget<Slider>(find.byKey(sliderKey)).secondaryTrackValue,
      8000,
    );
  });

  testWidgets('±10 s buttons seek by ten seconds and clamp to the clip', (
    tester,
  ) async {
    await pumpCard(tester);
    var mark = platform.calls.length;
    await tapKey(tester, const ValueKey('video-seek-forward'));
    expect(since(mark), contains('seek:1:10000'));
    expect(text(tester, positionKey), '0:10');

    mark = platform.calls.length;
    await tapKey(tester, const ValueKey('video-seek-forward'));
    expect(since(mark), contains('seek:1:20000'));
    expect(text(tester, positionKey), '0:20');

    // Already at the end: stays clamped to the clip.
    mark = platform.calls.length;
    await tapKey(tester, const ValueKey('video-seek-forward'));
    expect(since(mark), contains('seek:1:20000'));
    expect(text(tester, positionKey), '0:20');

    mark = platform.calls.length;
    await tapKey(tester, const ValueKey('video-seek-back'));
    expect(since(mark), contains('seek:1:10000'));

    await tapKey(tester, const ValueKey('video-seek-back'));
    mark = platform.calls.length;
    await tapKey(tester, const ValueKey('video-seek-back'));
    expect(since(mark), contains('seek:1:0'));
    expect(text(tester, positionKey), '0:00');
  });

  testWidgets('double tap on the right seeks forward, on the left back', (
    tester,
  ) async {
    await pumpCard(tester);
    final layer = tester.getRect(
      find.byKey(const ValueKey('video-gesture-layer')),
    );
    Future<void> doubleTapAt(Offset at) async {
      await tester.tapAt(at);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tapAt(at);
      await settle(tester);
    }

    var mark = platform.calls.length;
    await doubleTapAt(Offset(layer.right - 20, layer.center.dy));
    expect(since(mark), contains('seek:1:10000'));

    mark = platform.calls.length;
    await doubleTapAt(Offset(layer.left + 20, layer.center.dy));
    expect(since(mark), contains('seek:1:0'));
    // Let the gesture arena's double-tap window close.
    await tester.pump(kDoubleTapTimeout);
  });

  testWidgets('time labels follow playback', (tester) async {
    await pumpCard(tester);
    expect(text(tester, positionKey), '0:00');
    expect(text(tester, durationKey), '0:20');
    await startPlaying(tester);
    platform.setPosition(1, const Duration(seconds: 7));
    await tester.pump(const Duration(milliseconds: 600));
    await settle(tester);
    expect(text(tester, positionKey), '0:07');
  });

  testWidgets('speed menu applies the chosen speed', (tester) async {
    await pumpCard(tester);
    // The platform takes the speed while playing (iOS would start playback
    // if it were set while paused).
    await startPlaying(tester);
    await tapKey(tester, const ValueKey('video-speed'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const ValueKey('video-speed-1.5')));
    await tester.pump(const Duration(milliseconds: 400));
    await settle(tester);
    final speeds = platform.calls.where((c) => c.startsWith('speed:1:'));
    expect(speeds.last, 'speed:1:1.5');
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('video-speed')),
        matching: find.text('1.5×'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('mute toggles the volume both ways', (tester) async {
    await pumpCard(tester);
    final mark = platform.calls.length;
    await tapKey(tester, const ValueKey('video-mute'));
    expect(since(mark).last, 'volume:1:0.0');
    expect(find.bySemanticsLabel('Unmute'), findsOneWidget);
    await tapKey(tester, const ValueKey('video-mute'));
    expect(since(mark).last, 'volume:1:1.0');
  });

  testWidgets('full screen keeps position, playback, speed and mute, and '
      'hands the new position back', (tester) async {
    await pumpCard(tester);
    await startPlaying(tester);
    await tapKey(tester, const ValueKey('video-mute'));
    await tapKey(tester, const ValueKey('video-speed'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const ValueKey('video-speed-1.5')));
    await tester.pump(const Duration(milliseconds: 400));
    platform.setPosition(1, const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 600));
    await settle(tester);

    systemCalls.clear();
    await tapKey(tester, const ValueKey('video-fullscreen'));
    await tester.pump(const Duration(milliseconds: 300));
    await settle(tester);

    final viewer = find.byKey(viewerKey);
    expect(viewer, findsOneWidget);
    expect(platform.calls, contains('pause:1'));
    expect(platform.calls, contains('seek:2:3000'));
    expect(platform.calls, contains('volume:2:0.0'));
    expect(platform.calls, contains('play:2'));
    expect(
      platform.calls.where((c) => c.startsWith('speed:2:')).last,
      'speed:2:1.5',
    );
    final orientations = systemCalls
        .where((c) => c.method == 'SystemChrome.setPreferredOrientations')
        .toList();
    expect(orientations, isNotEmpty);
    expect(
      (orientations.last.arguments as List).cast<String>(),
      contains('DeviceOrientation.landscapeLeft'),
    );

    platform.setPosition(2, const Duration(seconds: 9));
    await tester.pump(const Duration(milliseconds: 600));
    await settle(tester);
    expect(text(tester, positionKey, within: viewer), '0:09');

    final mark = platform.calls.length;
    systemCalls.clear();
    await tapKey(tester, const ValueKey('video-fullscreen'), within: viewer);
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await settle(tester);
    expect(viewer, findsNothing);
    expect(platform.disposed, contains(2));
    final back = since(mark);
    expect(back, contains('seek:1:9000'));
    expect(back, contains('play:1'));
    final restored = systemCalls
        .where((c) => c.method == 'SystemChrome.setPreferredOrientations')
        .toList();
    expect(restored, isNotEmpty);
    expect(restored.last.arguments as List, isEmpty);
  });

  testWidgets('opening full screen from a paused card does not autoplay', (
    tester,
  ) async {
    await pumpCard(tester);
    await tapKey(tester, const ValueKey('video-fullscreen'));
    await tester.pump(const Duration(milliseconds: 300));
    await settle(tester);
    expect(find.byKey(viewerKey), findsOneWidget);
    expect(platform.calls.where((c) => c.startsWith('play:')), isEmpty);
  });

  testWidgets('backgrounding the app pauses playback and shows the controls', (
    tester,
  ) async {
    await pumpCard(tester);
    await startPlaying(tester);
    await tester.pump(const Duration(seconds: 4));
    expect(controlsVisible(tester), isFalse);
    final mark = platform.calls.length;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await settle(tester);
    expect(since(mark), contains('pause:1'));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await settle(tester);
    expect(controlsVisible(tester), isTrue);
    expect(since(mark).where((c) => c.startsWith('play:')), isEmpty);
  });

  testWidgets('a page pushed over the chat pauses the video', (tester) async {
    await pumpCard(tester);
    await startPlaying(tester);
    final mark = platform.calls.length;
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(MaterialPageRoute<void>(builder: (_) => const Scaffold()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await settle(tester);
    expect(since(mark), contains('pause:1'));
  });

  testWidgets('controls hide 3 s after playback starts and come back on tap', (
    tester,
  ) async {
    await pumpCard(tester);
    expect(controlsVisible(tester), isTrue);
    await tester.pump(const Duration(seconds: 5));
    expect(controlsVisible(tester), isTrue, reason: 'paused: stay visible');

    await startPlaying(tester);
    await tester.pump(const Duration(milliseconds: 2800));
    expect(controlsVisible(tester), isTrue);
    await tester.pump(const Duration(milliseconds: 400));
    expect(controlsVisible(tester), isFalse);

    final layer = tester.getRect(
      find.byKey(const ValueKey('video-gesture-layer')),
    );
    await tester.tapAt(layer.center);
    await tester.pump(const Duration(milliseconds: 350));
    expect(controlsVisible(tester), isTrue);
    await tester.tapAt(Offset(layer.left + 20, layer.center.dy));
    await tester.pump(const Duration(milliseconds: 350));
    expect(controlsVisible(tester), isFalse, reason: 'tap hides them again');
  });

  testWidgets('with a screen reader on, controls never auto-hide', (
    tester,
  ) async {
    await pumpCard(tester, accessibleNavigation: true);
    await startPlaying(tester);
    await tester.pump(const Duration(seconds: 5));
    expect(controlsVisible(tester), isTrue);
  });

  testWidgets('reduced motion hides the controls without a fade', (
    tester,
  ) async {
    await pumpCard(tester, disableAnimations: true);
    final fade = tester.widget<AnimatedOpacity>(
      find
          .ancestor(
            of: find.byKey(overlayKey),
            matching: find.byType(AnimatedOpacity),
          )
          .first,
    );
    expect(fade.duration, Duration.zero);
  });

  testWidgets('every player control is at least 48 dp and labelled', (
    tester,
  ) async {
    await pumpCard(tester);
    for (final key in const [
      'video-play-pause',
      'video-seek-back',
      'video-seek-forward',
      'video-mute',
      'video-speed',
      'video-fullscreen',
    ]) {
      final size = tester.getSize(find.byKey(ValueKey<String>(key)));
      expect(size.width, greaterThanOrEqualTo(48), reason: key);
      expect(size.height, greaterThanOrEqualTo(48), reason: key);
    }
    for (final label in const [
      'Play video',
      'Back 10 seconds',
      'Forward 10 seconds',
      'Mute',
      'Playback speed',
      'Full screen',
    ]) {
      expect(find.bySemanticsLabel(label), findsWidgets, reason: label);
    }
  });

  testWidgets('a full-screen load error offers Retry with a fresh player', (
    tester,
  ) async {
    await pumpCard(tester);
    platform.failNextInit = true;
    await tapKey(tester, const ValueKey('video-fullscreen'));
    await tester.pump(const Duration(milliseconds: 300));
    await settle(tester);
    final viewer = find.byKey(viewerKey);
    final retry = find.descendant(of: viewer, matching: find.text('Retry'));
    expect(retry, findsOneWidget);
    await tester.tap(retry);
    await settle(tester);
    expect(platform.live, containsAll(<int>[1, 3]));
    expect(
      find.descendant(
        of: viewer,
        matching: find.byKey(const ValueKey('fake-video-3')),
      ),
      findsOneWidget,
    );
  });
}
