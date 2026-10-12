// Owner report (1.2.15): the notch sheet looked broken when swiped closed;
// "review the other pills". The floating surfaces a chat opens over itself
// (sheets, pickers, menus, the dock popover, the message actions) are sampled
// frame by frame through a close that interrupts their opening: a quick
// outside tap, Back, or a row tapped at once.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/modal.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat/quick_reaction_bar.dart';
import 'package:hermes_android/core/widgets/dock_anchored_popover.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

const _frame = Duration(milliseconds: 16);
const _surface = ValueKey('surface-under-test');
final _anchor = GlobalKey(debugLabel: 'anchor');

Future<void> _pumpHost(
  WidgetTester tester,
  void Function(BuildContext context) open,
) async {
  tester.view.physicalSize = const Size(412, 892);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.hermesRedDark,
      home: Scaffold(
        body: Builder(
          builder: (context) => Align(
            alignment: const Alignment(0, 0.8),
            child: GestureDetector(
              key: _anchor,
              onTap: () => open(context),
              child: const SizedBox(
                width: 48,
                height: 48,
                child: Center(child: Text('+')),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

const _content = SizedBox(
  key: _surface,
  width: 260,
  height: 220,
  child: Center(child: Text('contenido')),
);

/// The route transition a surface is wrapped in: its fade, and its scale
/// when it has one.
({double opacity, double scale}) _transition(WidgetTester tester) {
  final fade = tester.widget<FadeTransition>(
    find
        .ancestor(
          of: find.byKey(_surface),
          matching: find.byType(FadeTransition),
        )
        .first,
  );
  final scales = find.ancestor(
    of: find.byKey(_surface),
    matching: find.byType(ScaleTransition),
  );
  return (
    opacity: fade.opacity.value,
    scale: scales.evaluate().isEmpty
        ? 1
        : tester.widget<ScaleTransition>(scales.first).scale.value,
  );
}

/// Opens with [open], closes it with Back half-way through its opening and
/// checks that the close continues from what was on screen: no frame drops
/// most of the opacity at once, and neither value ever goes back up.
Future<void> _expectInterruptedCloseContinues(
  WidgetTester tester,
  void Function(BuildContext context) open,
  Duration halfWay,
) async {
  await _pumpHost(tester, open);
  await tester.tap(find.byKey(_anchor));
  await tester.pump();
  await tester.pump(halfWay);
  final before = _transition(tester);
  expect(before.opacity, inExclusiveRange(0.5, 1.0), reason: 'still opening');
  await tester.binding.handlePopRoute();
  final log = StringBuffer('before $before\n');
  var previous = before;
  var frames = 0;
  for (; frames < 30; frames++) {
    await tester.pump(_frame);
    if (find.byKey(_surface).evaluate().isEmpty) break;
    final now = _transition(tester);
    log.writeln('  $frames: $now');
    expect(
      now.opacity,
      lessThanOrEqualTo(previous.opacity + 1e-6),
      reason: 'frame $frames\n$log',
    );
    expect(
      previous.opacity - now.opacity,
      lessThanOrEqualTo(0.4),
      reason: 'frame $frames: it vanished at once instead of fading\n$log',
    );
    expect(
      now.scale,
      lessThanOrEqualTo(previous.scale + 1e-6),
      reason: 'frame $frames\n$log',
    );
    previous = now;
  }
  expect(find.byKey(_surface), findsNothing, reason: '$log');
  expect(frames, greaterThan(1), reason: 'it fades out\n$log');
}

void main() {
  group('closed while it is still opening, it fades from where it is', () {
    testWidgets('floating surface (sheets, pickers and menus of a chat)', (
      tester,
    ) async {
      await _expectInterruptedCloseContinues(
        tester,
        (context) =>
            showHermesSurface<void>(context: context, builder: (_) => _content),
        const Duration(milliseconds: 100),
      );
    });

    testWidgets('dock popover', (tester) async {
      await _expectInterruptedCloseContinues(
        tester,
        (context) => showDockAnchoredPopover<void>(
          context: context,
          anchorKey: _anchor,
          builder: (_) => _content,
        ),
        const Duration(milliseconds: 100),
      );
    });

    testWidgets('message actions', (tester) async {
      await _pumpHost(
        tester,
        (context) => showMessageActions(
          context: context,
          message: const Rect.fromLTWH(40, 300, 300, 60),
          press: const Offset(190, 330),
          scope: MessageQuickReactScope(
            onReact: (_) {},
            copyText: () => 'mensaje',
            child: const SizedBox.shrink(),
          ),
        ),
      );
      await tester.tap(find.byKey(_anchor));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      final bar = find.byType(QuickReactionBar);
      double opacity() => tester
          .widget<FadeTransition>(
            find.ancestor(of: bar, matching: find.byType(FadeTransition)).first,
          )
          .opacity
          .value;
      var previous = opacity();
      expect(previous, inExclusiveRange(0.5, 1.0), reason: 'still opening');
      await tester.binding.handlePopRoute();
      var frames = 0;
      for (; frames < 12; frames++) {
        await tester.pump(_frame);
        if (bar.evaluate().isEmpty) break;
        final now = opacity();
        expect(
          previous - now,
          inInclusiveRange(-1e-6, 0.4),
          reason: 'f$frames',
        );
        previous = now;
      }
      expect(bar, findsNothing);
      expect(frames, greaterThan(1), reason: 'it fades out');
    });
  });
}
