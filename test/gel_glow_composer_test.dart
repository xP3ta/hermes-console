// The glow of the composer's accent gels (send, stop, the dictation's send
// and stop) is never cut by a layer or a clip smaller than the glow: not at
// rest, not while the send and stop buttons swap, not while dictating. A
// fade paints into a layer as large as its box, so a fade the size of the
// button cut the glow to a hard-edged square.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/glass_strip.dart';
import 'package:hermes_android/core/design/smoked_glass.dart';
import 'package:hermes_android/core/design/tokens.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat/console_composer.dart';
import 'package:hermes_android/core/widgets/chat_status_pill.dart';
import 'package:hermes_android/core/widgets/frosted_backdrop.dart';
import 'package:hermes_android/core/widgets/session_context_usage.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'support/gel_glow.dart';

const _composer = ValueKey('glow-composer');
const _footStrip = ValueKey('glow-foot-strip');

class _Foot {
  final text = TextEditingController(text: 'Hola');
  final focus = FocusNode();
  final stop = ValueNotifier(false);
  final recording = ValueNotifier(false);
  final metrics = ValueNotifier(const SessionContextMetrics(percent: 23));

  Widget app({bool footerInside = false}) {
    final theme = AppTheme.fromId('dark');
    final colors = theme.hermes;
    final chrome = HermesChrome.of(colors);
    return MaterialApp(
      theme: theme,
      locale: const Locale('en'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      home: Scaffold(
        body: Stack(
          children: [
            Positioned.fill(
              child: ListView(
                children: [
                  for (var i = 0; i < 40; i++)
                    Container(
                      height: 36,
                      color: i.isEven ? Colors.white : colors.accent,
                    ),
                ],
              ),
            ),
            // The chat foot: the composer in the toned bottom strip.
            Align(
              alignment: Alignment.bottomCenter,
              child: HermesGlassStrip(
                key: _footStrip,
                zone: FrostedZone.bottom,
                priority: 1,
                tone: HermesSmokedGlass.of(chrome),
                toneInks: HermesSmokedGlass.footInks(colors),
                child: ListenableBuilder(
                  listenable: Listenable.merge([stop, recording]),
                  builder: (context, _) => ConsoleComposer(
                    key: _composer,
                    controller: text,
                    focusNode: focus,
                    onSend: (_, _) {},
                    onStop: () {},
                    showStop: stop.value,
                    dictation: ConsoleComposerDictation(
                      onStart: () {},
                      onStop: () {},
                      onCancel: () {},
                      onSend: () {},
                      recording: recording.value,
                      sendEnabled: true,
                    ),
                    footer: footerInside
                        ? ChatStatusPill(
                            metrics: metrics,
                            onOpenContext: () {},
                            modelLabel: 'Model',
                            onOpenModel: () {},
                          )
                        : null,
                    footerInside: footerInside,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void dispose() {
    text.dispose();
    focus.dispose();
    stop.dispose();
    recording.dispose();
    metrics.dispose();
  }
}

Future<_Foot> _pump(WidgetTester tester, {bool footerInside = false}) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  // A phone's gesture bar: the composer stands on it, as on a device.
  tester.view.padding = const FakeViewPadding(bottom: 24);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPadding);
  final foot = _Foot();
  addTearDown(foot.dispose);
  await tester.pumpWidget(foot.app(footerInside: footerInside));
  await tester.pumpAndSettle();
  return foot;
}

// The one named exception: the foot's glass strip paints into its own layer
// as large as the foot, and the glow over the composer's top edge reaches
// past it. That edge is not the composer's and is reported on its own; every
// layer and clip of the composer itself must hold the whole glow.
void _expectUncut(WidgetTester tester, int gels, String state) =>
    expectGlowsUncut(
      tester,
      find.byKey(_composer),
      expected: gels,
      surfaceEdges: {tester.renderObject(find.byKey(_footStrip))},
      reason: state,
    );

void main() {
  testWidgets('send and stop keep their whole glow at rest and while they '
      'swap', (tester) async {
    final foot = await _pump(tester);
    _expectUncut(tester, 1, 'send at rest');

    foot.stop.value = true;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 110));
    // Both buttons are on screen, the one leaving fading out.
    _expectUncut(tester, 2, 'send becoming stop');
    await tester.pumpAndSettle();
    _expectUncut(tester, 1, 'stop at rest');

    foot.stop.value = false;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    _expectUncut(tester, 2, 'stop becoming send');
    await tester.pumpAndSettle();
    _expectUncut(tester, 1, 'send at rest again');
  });

  testWidgets('the dictation send and stop keep their whole glow', (
    tester,
  ) async {
    final foot = await _pump(tester);
    foot.recording.value = true;
    await tester.pumpAndSettle();
    _expectUncut(tester, 2, 'dictating');
  });

  testWidgets('with the controls stacked under the text the send keeps its '
      'whole glow', (tester) async {
    final foot = await _pump(tester, footerInside: true);
    foot.focus.requestFocus();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('composer-control-row')),
      findsOneWidget,
    );
    _expectUncut(tester, 1, 'stacked send at rest');
  });

  testWidgets('the room keeps the button where it was and its touch target '
      'the same', (tester) async {
    await _pump(tester);
    final send = find.byKey(const ValueKey('send'));
    // The 48 dp slot, with the 48 dp target of the button inside it.
    expect(tester.getSize(send), const Size(48, 48));
    final center = tester.getCenter(send);
    final hit = tester.hitTestOnBinding(center + const Offset(0, 23));
    expect(
      hit.path.any((entry) => entry.target == tester.renderObject(send)),
      isTrue,
    );
    // The glow margin around it takes no touch of its own.
    final outside = tester.hitTestOnBinding(center + const Offset(30, 0));
    expect(
      outside.path.any((entry) => entry.target == tester.renderObject(send)),
      isFalse,
    );
  });
}
