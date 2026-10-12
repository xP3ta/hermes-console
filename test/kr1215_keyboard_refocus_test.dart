import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/modal.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/island_card.dart';
import 'package:hermes_android/core/widgets/pill_morph.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

// QA 1.2.15: focused composer, system Back hides the keyboard (the field keeps
// focus), open a sheet and close it -> the keyboard reopened by itself because
// the chat route restored focus to the composer on pop. The keyboard may only
// come back when it was visible when the sheet opened.

class _ChatLike extends StatelessWidget {
  const _ChatLike({required this.composerFocus});

  final FocusNode composerFocus;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        const Expanded(child: SizedBox.expand()),
        Builder(
          builder: (context) => TextButton(
            key: const ValueKey('open-card'),
            onPressed: () => showIslandCard(
              context: context,
              origin: () {
                final box = context.findRenderObject()! as RenderBox;
                return box.localToGlobal(Offset.zero) & box.size;
              },
              dismissLabel: 'Cerrar',
              header: (_, _) => const SizedBox(height: 44),
              builder: (_) => const SizedBox(
                key: ValueKey('card-body'),
                height: 120,
                child: Text('card'),
              ),
            ),
            child: const Text('card'),
          ),
        ),
        Builder(
          builder: (context) => TextButton(
            key: const ValueKey('open-surface'),
            onPressed: () => showHermesSurface<void>(
              context: context,
              builder: (_) => const SizedBox(
                key: ValueKey('surface-body'),
                height: 120,
                child: Text('surface'),
              ),
            ),
            child: const Text('open'),
          ),
        ),
        SizedBox(
          height: 56,
          child: TextField(
            key: const ValueKey('composer'),
            focusNode: composerFocus,
          ),
        ),
      ],
    ),
  );
}

Future<FocusNode> _pump(WidgetTester tester) async {
  final focus = FocusNode(debugLabel: 'composer');
  addTearDown(focus.dispose);
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: const [
        Strings.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.hermesRedDark,
      builder: (context, home) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true),
        child: home!,
      ),
      home: _ChatLike(composerFocus: focus),
    ),
  );
  await tester.pump();
  return focus;
}

void _setKeyboard(WidgetTester tester, {required bool visible}) {
  tester.view.viewInsets = FakeViewPadding(bottom: visible ? 600 : 0);
  addTearDown(tester.view.resetViewInsets);
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

bool _showCalled(WidgetTester tester) => tester.testTextInput.log.any(
  (MethodCall c) => c.method == 'TextInput.show',
);

Future<void> _openPill(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('open-card')));
  await _settle(tester);
  expect(find.byKey(const ValueKey('card-body')), findsOneWidget);
}

Future<void> _openSurface(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('open-surface')));
  await _settle(tester);
  expect(find.byKey(const ValueKey('surface-body')), findsOneWidget);
}

Future<void> _systemBack(WidgetTester tester) async {
  await tester.binding.handlePopRoute();
  await _settle(tester);
}

void main() {
  for (final (name, open, body) in [
    ('island card', _openPill, 'card-body'),
    ('floating surface', _openSurface, 'surface-body'),
  ]) {
    group(name, () {
      testWidgets('keyboard hidden while the composer kept focus: closing it '
          'does not refocus the composer nor show the keyboard', (
        tester,
      ) async {
        final focus = await _pump(tester);
        await tester.tap(find.byKey(const ValueKey('composer')));
        await tester.pump();
        expect(focus.hasFocus, isTrue);
        // System Back hid the IME; the field is still the focused node.
        _setKeyboard(tester, visible: false);
        await tester.pump();
        expect(focus.hasFocus, isTrue);

        await open(tester);
        tester.testTextInput.log.clear();
        await _systemBack(tester);

        expect(find.byKey(ValueKey(body)), findsNothing);
        expect(focus.hasFocus, isFalse);
        expect(_showCalled(tester), isFalse);
        expect(tester.testTextInput.isVisible, isFalse);
      });

      testWidgets('keyboard visible when it opened: closing it restores the '
          'composer focus', (tester) async {
        final focus = await _pump(tester);
        _setKeyboard(tester, visible: true);
        await tester.tap(find.byKey(const ValueKey('composer')));
        await tester.pump();
        expect(focus.hasFocus, isTrue);

        await open(tester);
        await _systemBack(tester);

        expect(find.byKey(ValueKey(body)), findsNothing);
        expect(focus.hasFocus, isTrue);
      });

      // QA 9495: open and close it several times in a row with the keyboard
      // up. Closing gives the focus back and asks for the keyboard, but the
      // IME needs a moment before it reports an inset; reopening inside that
      // moment read "focused, no inset" as "keyboard dismissed with Back",
      // released the focus, and the keyboard never came back.
      for (final trips in [3, 5]) {
        testWidgets('$trips quick open/close cycles with the keyboard up: '
            'the composer gets the keyboard back (QA 9495)', (tester) async {
          final focus = await _pump(tester);
          _setKeyboard(tester, visible: true);
          await tester.tap(find.byKey(const ValueKey('composer')));
          await tester.pump();
          expect(focus.hasFocus, isTrue);
          for (var i = 0; i < trips; i++) {
            await open(tester);
            // The composer lost the focus to the sheet: the IME slides away.
            tester.view.viewInsets = const FakeViewPadding(bottom: 300);
            await tester.pump();
            _setKeyboard(tester, visible: false);
            await tester.pump();
            final route = ModalRoute.of(
              tester.element(find.byKey(ValueKey(body))),
            );
            if (route is PillMorphRoute) {
              expect(route.reduceMotion, isTrue);
              expect(route.reverseTransitionDuration, kPillMorphFade);
            }
            await tester.binding.handlePopRoute();
            await tester.pump();
            // Logical pop restores focus immediately; the painted surface
            // closes using the contractual bounded reduced-motion fade.
            expect(focus.hasFocus, isTrue, reason: 'cycle $i');
            await tester.pump(kPillMorphFade);
            if (route is PillMorphRoute) {
              expect(route.animation!.value, 0);
            }
            // Flutter's interpolation finishes strictly AFTER its duration.
            await tester.pump(const Duration(microseconds: 1));
            await tester.pump();
            expect(find.byKey(ValueKey(body)), findsNothing);
            // Still reopened before the IME reported its inset again.
            await tester.pump(const Duration(milliseconds: 50));
          }
          // Left alone, the keyboard rises.
          _setKeyboard(tester, visible: true);
          await _settle(tester);
          expect(focus.hasFocus, isTrue);
        });
      }

      testWidgets('dismissed with Back after a quick cycle: the next close '
          'keeps the keyboard closed', (tester) async {
        final focus = await _pump(tester);
        _setKeyboard(tester, visible: true);
        await tester.tap(find.byKey(const ValueKey('composer')));
        await tester.pump();
        await open(tester);
        _setKeyboard(tester, visible: false);
        await tester.pump();
        await _systemBack(tester);
        expect(focus.hasFocus, isTrue);
        // The keyboard came up, then the user hid it with system Back.
        _setKeyboard(tester, visible: true);
        await tester.pump(const Duration(milliseconds: 300));
        _setKeyboard(tester, visible: false);
        await tester.pump(const Duration(milliseconds: 300));
        expect(focus.hasFocus, isTrue);

        await open(tester);
        tester.testTextInput.log.clear();
        await _systemBack(tester);
        expect(focus.hasFocus, isFalse);
        expect(_showCalled(tester), isFalse);
      });

      testWidgets('focused composer whose keyboard never rose for a while: '
          'closing it does not refocus', (tester) async {
        final focus = await _pump(tester);
        await tester.tap(find.byKey(const ValueKey('composer')));
        await tester.pump();
        // Hidden with Back before it showed; well past the IME's latency.
        await tester.pump(const Duration(seconds: 2));
        expect(focus.hasFocus, isTrue);
        await open(tester);
        tester.testTextInput.log.clear();
        await _systemBack(tester);
        expect(focus.hasFocus, isFalse);
        expect(_showCalled(tester), isFalse);
      });
    });
  }

  testWidgets('quick push/pop of another screen with the keyboard up gives '
      'the focus back every time (QA 9495)', (tester) async {
    final focus = await _pump(tester);
    _setKeyboard(tester, visible: true);
    await tester.tap(find.byKey(const ValueKey('composer')));
    await tester.pump();
    final nav = tester.state<NavigatorState>(find.byType(Navigator));
    for (var i = 0; i < 5; i++) {
      unawaited(
        nav.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('other chat')),
          ),
        ),
      );
      await tester.pump();
      _setKeyboard(tester, visible: false);
      await tester.pump(const Duration(milliseconds: 50));
      nav.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(focus.hasFocus, isTrue, reason: 'cycle $i');
    }
  });
}
