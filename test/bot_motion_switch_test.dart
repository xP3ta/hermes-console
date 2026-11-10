import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/characters/bot_motion.dart';
import 'package:hermes_android/core/widgets/hermes_bot_face.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late BotMotionPrefs prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await BotMotionPrefs.load(await SharedPreferences.getInstance());
  });
  tearDown(() => BotMotionPrefs.debugUse(null));

  Widget host({required bool reduceMotion, bool scoped = true}) {
    final face = Center(
      child: HermesBotFace(
        visual: HermesBlobatarFaceVisual.tryParse(
          shapeWire: 'blobatar',
          profileName: 'ana',
        )!,
        animate: true,
      ),
    );
    return MediaQuery(
      data: MediaQueryData(disableAnimations: reduceMotion),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: scoped ? BotMotionScope(prefs: prefs, child: face) : face,
      ),
    );
  }

  testWidgets('animates by default, also with no scope', (tester) async {
    await tester.pumpWidget(host(reduceMotion: false));
    expect(tester.hasRunningAnimations, isTrue);
    await tester.pumpWidget(host(reduceMotion: false, scoped: false));
    expect(tester.hasRunningAnimations, isTrue);
  });

  testWidgets('"Animar bots" off stills the face and on resumes it', (
    tester,
  ) async {
    await tester.pumpWidget(host(reduceMotion: false));
    expect(tester.hasRunningAnimations, isTrue);

    await prefs.setAnimate(false);
    await tester.pump();
    expect(tester.hasRunningAnimations, isFalse);

    await prefs.setAnimate(true);
    await tester.pump();
    expect(tester.hasRunningAnimations, isTrue);
  });

  testWidgets('reduced motion still wins when the switch is on', (
    tester,
  ) async {
    await tester.pumpWidget(host(reduceMotion: true));
    expect(prefs.animate, isTrue);
    expect(tester.hasRunningAnimations, isFalse);
  });

  test('the switch persists', () async {
    await prefs.setAnimate(false);
    final raw = await SharedPreferences.getInstance();
    final reloaded = await BotMotionPrefs.load(raw);
    expect(reloaded.animate, isFalse);
  });
}
