import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/platform/native_appearance.dart';
import 'package:hermes_android/core/widgets/startup_handoff.dart';

Color _xmlColor(String path) {
  final xml = File(path).readAsStringSync();
  final match = RegExp(
    r'<color name="splash_background">#([0-9A-Fa-f]{6})</color>',
  ).firstMatch(xml)!;
  return Color(int.parse('FF${match.group(1)}', radix: 16));
}

class _Probe extends StatefulWidget {
  const _Probe({required this.color, required this.mounts});

  final Color color;
  final List<int> mounts;

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  void initState() {
    super.initState();
    widget.mounts.add(1);
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
    key: const ValueKey('probe-ui'),
    color: widget.color,
    child: const Center(child: Text('UI')),
  );
}

void main() {
  group('native splash and first frame agree', () {
    test('the hand-off colours are the native splash colours, light and '
        'dark', () {
      expect(
        NativeAppearance.splashBackgroundLight,
        _xmlColor('android/app/src/main/res/values/colors.xml'),
      );
      expect(
        NativeAppearance.splashBackgroundDark,
        _xmlColor('android/app/src/main/res/values-night/colors.xml'),
      );
      expect(
        NativeAppearance.splashBackground(Brightness.light),
        NativeAppearance.splashBackgroundLight,
      );
      expect(
        NativeAppearance.splashBackground(Brightness.dark),
        NativeAppearance.splashBackgroundDark,
      );
    });

    test('Android 12+ splash uses that colour and the same mark in both '
        'modes', () {
      for (final dir in ['values-v31', 'values-night-v31']) {
        final xml = File(
          'android/app/src/main/res/$dir/styles.xml',
        ).readAsStringSync();
        expect(xml, contains('@color/splash_background'), reason: dir);
        expect(xml, contains('@drawable/splash_logo'), reason: dir);
      }
      // The hand-off paints the very file Android shows, so a new logo
      // (one mark for both modes) carries over with no Flutter change.
      final day = File(StartupHandoff.markAsset).readAsBytesSync();
      final nightFile = File(
        'android/app/src/main/res/drawable-night-nodpi/splash_logo.png',
      );
      if (nightFile.existsSync()) {
        expect(nightFile.readAsBytesSync(), day, reason: 'same mark at night');
      }
      expect(
        File('pubspec.yaml').readAsStringSync(),
        contains('- ${StartupHandoff.markAsset}'),
      );
    });

    test('nothing keeps the native splash up past the first frame', () {
      final sources = Directory('android/app/src/main/kotlin')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.kt') || f.path.endsWith('.java'));
      for (final file in sources) {
        final text = file.readAsStringSync();
        expect(text, isNot(contains('setKeepOnScreenCondition')));
        expect(text, isNot(contains('OnPreDrawListener')));
        expect(text, isNot(contains('installSplashScreen')));
      }
    });
  });

  group('StartupHandoff', () {
    const native = Color(0xFF030306);
    const appBackground = Color(0xFF16161A);

    Future<List<int>> pumpHandoff(
      WidgetTester tester, {
      bool reduceMotion = false,
    }) async {
      final mounts = <int>[];
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(disableAnimations: reduceMotion),
          child: RepaintBoundary(
            key: const ValueKey('screen'),
            child: StartupHandoff(
              background: native,
              child: Directionality(
                textDirection: TextDirection.ltr,
                child: _Probe(color: appBackground, mounts: mounts),
              ),
            ),
          ),
        ),
      );
      return mounts;
    }

    double appOpacity(WidgetTester tester) => tester
        .widget<FadeTransition>(
          find.byKey(const ValueKey('startup-handoff-app-opacity')),
        )
        .opacity
        .value;

    double? markOpacity(WidgetTester tester) {
      final f = find.byKey(const ValueKey('startup-handoff-mark-opacity'));
      if (f.evaluate().isEmpty) return null;
      return tester.widget<FadeTransition>(f).opacity.value;
    }

    Future<Color> cornerPixel(WidgetTester tester) async {
      final boundary =
          tester.renderObject(find.byKey(const ValueKey('screen')))
              as RenderRepaintBoundary;
      final bytes = (await tester.runAsync(() async {
        final image = await boundary.toImage();
        final data = await image.toByteData(
          format: ui.ImageByteFormat.rawStraightRgba,
        );
        image.dispose();
        return data!;
      }))!;
      return Color.fromARGB(
        bytes.getUint8(3),
        bytes.getUint8(0),
        bytes.getUint8(1),
        bytes.getUint8(2),
      );
    }

    testWidgets('first frame: native background and the mark, app hidden', (
      tester,
    ) async {
      await pumpHandoff(tester);
      expect(markOpacity(tester), 1);
      expect(appOpacity(tester), 0);
      expect(
        find.byKey(const ValueKey('startup-handoff-mark')),
        findsOneWidget,
      );
      final mark = tester.getRect(find.byType(ClipOval));
      final screen = tester.getRect(find.byKey(const ValueKey('screen')));
      expect(mark.center, screen.center, reason: 'centred like Android');
      expect(mark.width, StartupHandoff.markVisible);
      expect(await cornerPixel(tester), native);
    });

    testWidgets('every frame shows the mark or the app (opacities add up '
        'to one), never a white frame, and it ends within 400 ms', (
      tester,
    ) async {
      final mounts = await pumpHandoff(tester);
      var elapsed = 0;
      int? endedAt;
      double lastApp = 0;
      while (elapsed <= 700) {
        final mark = markOpacity(tester);
        final app = appOpacity(tester);
        if (mark == null) {
          endedAt ??= elapsed;
          expect(app, 1);
        } else {
          expect(mark + app, closeTo(1, 1e-9), reason: '$elapsed ms');
          expect(app, greaterThanOrEqualTo(lastApp), reason: 'monotonic');
        }
        lastApp = app;
        if (elapsed % 96 == 0) {
          final pixel = await cornerPixel(tester);
          expect(pixel.a, 1, reason: 'opaque at $elapsed ms');
          expect(
            pixel.computeLuminance(),
            lessThan(0.05),
            reason: 'no light flash in a dark theme at $elapsed ms',
          );
        }
        await tester.pump(const Duration(milliseconds: 16));
        elapsed += 16;
      }
      expect(endedAt, isNotNull);
      expect(
        endedAt,
        inInclusiveRange(
          StartupHandoff.duration.inMilliseconds,
          StartupHandoff.duration.inMilliseconds + 48,
        ),
      );
      expect(await cornerPixel(tester), appBackground);
      expect(mounts, [1], reason: 'the app is never rebuilt from scratch');
      expect(tester.binding.hasScheduledFrame, isFalse, reason: 'idle after');
    });

    testWidgets('the app scales in from 0.98', (tester) async {
      await pumpHandoff(tester);
      ScaleTransition appScale() => tester.widget<ScaleTransition>(
        find
            .descendant(
              of: find.byKey(const ValueKey('startup-handoff-app-opacity')),
              matching: find.byType(ScaleTransition),
            )
            .first,
      );
      expect(appScale().scale.value, closeTo(0.98, 1e-9));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      final mid = appScale().scale.value;
      expect(mid, greaterThan(0.98));
      expect(mid, lessThan(1));
      await tester.pump(const Duration(milliseconds: 300));
      expect(appScale().scale.value, 1);
    });

    testWidgets('reduced motion: a plain 150 ms crossfade, no scaling', (
      tester,
    ) async {
      await pumpHandoff(tester, reduceMotion: true);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('startup-handoff-app-opacity')),
          matching: find.byType(ScaleTransition),
        ),
        findsNothing,
      );
      var elapsed = 0;
      int? endedAt;
      while (elapsed <= 400) {
        final mark = markOpacity(tester);
        if (mark == null) {
          endedAt ??= elapsed;
        } else {
          expect(mark + appOpacity(tester), closeTo(1, 1e-9));
        }
        await tester.pump(const Duration(milliseconds: 16));
        elapsed += 16;
      }
      expect(endedAt, isNotNull);
      expect(endedAt, lessThanOrEqualTo(150 + 32));
    });
  });
}
