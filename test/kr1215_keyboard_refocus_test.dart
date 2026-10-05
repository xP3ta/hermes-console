import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/modal.dart';
import 'package:hermes_android/core/models/activity_snapshot.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/activity_panel.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

// QA 1.2.15: focused composer, system Back hides the keyboard (the field keeps
// focus), open a sheet and close it -> the keyboard reopened by itself because
// the chat route restored focus to the composer on pop. The keyboard may only
// come back when it was visible when the sheet opened.

final DateTime _t0 = DateTime(2026, 10, 5, 12);

ActivitySnapshot _live() => ActivitySnapshot(
  turnActive: true,
  turnStartedAt: _t0,
  current: ActivityStep(
    id: 'step-1',
    kind: ActivityStepKind.tool,
    label: 'terminal',
    status: ActivityStepStatus.running,
    detail: 'date',
    startedAt: _t0,
  ),
);

class _ChatLike extends StatelessWidget {
  const _ChatLike({required this.composerFocus});

  final FocusNode composerFocus;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        const Expanded(child: SizedBox.expand()),
        ActivityPillHost(
          snapshot: _live(),
          clock: () => _t0.add(const Duration(seconds: 10)),
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
  await tester.tap(find.byKey(const ValueKey('activity-pill')));
  await _settle(tester);
  expect(find.byKey(const ValueKey('activity-panel')), findsOneWidget);
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
    ('activity panel', _openPill, 'activity-panel'),
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
    });
  }
}
