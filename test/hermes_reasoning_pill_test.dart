import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_reasoning_pill.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

const _levels = [
  HermesReasoningLevel('none', 'Off'),
  HermesReasoningLevel('low', 'Low'),
  HermesReasoningLevel('medium', 'Medium'),
  HermesReasoningLevel('high', 'High'),
];

Widget _app(Widget child) => MaterialApp(
  theme: AppTheme.hermesRedDark,
  locale: const Locale('en'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  home: Scaffold(
    body: Center(child: SizedBox(width: 360, child: child)),
  ),
);

final _track = find.byKey(const ValueKey('model-picker-reasoning-track'));

Offset _stepAt(WidgetTester tester, int i) {
  final rect = tester.getRect(_track);
  final usable = rect.width - 2 * kReasoningTrackInset;
  return Offset(
    rect.left + kReasoningTrackInset + usable * i / (_levels.length - 1),
    rect.center.dy,
  );
}

void main() {
  testWidgets('tap picks the level, drag commits once on release', (
    tester,
  ) async {
    final picked = <String>[];
    await tester.pumpWidget(
      _app(
        HermesReasoningPill(
          levels: _levels,
          value: 'low',
          title: 'Reasoning',
          defaultLabel: 'Default',
          onChanged: picked.add,
        ),
      ),
    );
    await tester.tapAt(_stepAt(tester, 3));
    await tester.pump();
    expect(picked, ['high']);
    picked.clear();
    final gesture = await tester.startGesture(_stepAt(tester, 1));
    await gesture.moveTo(_stepAt(tester, 2));
    await gesture.moveTo(_stepAt(tester, 3));
    expect(picked, isEmpty);
    await gesture.up();
    await tester.pump();
    expect(picked, ['high']);
  });

  testWidgets('keys step the level; the current one is read', (tester) async {
    final picked = <String>[];
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(
        HermesReasoningPill(
          levels: _levels,
          value: 'medium',
          title: 'Reasoning',
          defaultLabel: 'Default',
          onChanged: picked.add,
        ),
      ),
    );
    expect(find.text('REASONING'), findsOneWidget);
    final data = tester
        .getSemantics(find.bySemanticsLabel('Reasoning'))
        .getSemanticsData();
    expect(data.value, 'Medium');
    expect(data.increasedValue, 'High');
    expect(data.decreasedValue, 'Low');
    expect(data.hasAction(SemanticsAction.increase), isTrue);
    expect(data.hasAction(SemanticsAction.decrease), isTrue);
    await tester.tapAt(_stepAt(tester, 2));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.pump();
    expect(picked, contains('high'));
    semantics.dispose();
  });

  testWidgets('no explicit level: no live label until chosen; unsupported '
      'is dimmed, says why and does not change', (tester) async {
    final picked = <String>[];
    await tester.pumpWidget(
      _app(
        HermesReasoningPill(
          levels: _levels,
          value: null,
          supported: false,
          title: 'Reasoning',
          defaultLabel: 'Default',
          unavailableText: 'This model does not reason',
          onChanged: picked.add,
        ),
      ),
    );
    expect(
      find.byKey(const ValueKey('model-picker-reasoning-dim')),
      findsOneWidget,
    );
    expect(find.text('This model does not reason'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('model-picker-reasoning-label')),
      findsNothing,
    );
    await tester.tapAt(_stepAt(tester, 2));
    await tester.pump();
    expect(picked, isEmpty);
  });

  testWidgets('the picker closes with the level tapped', (tester) async {
    String? result;
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showHermesReasoningPicker(
                context: context,
                title: 'Reasoning',
                levels: _levels,
                selected: 'low',
                defaultLabel: 'Default',
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    // The squares blink for as long as the sheet is open: no settling.
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byKey(const ValueKey('reasoning-pill')), findsOneWidget);
    expect(find.byKey(const ValueKey('reasoning-pill-inherit')), findsNothing);
    await tester.tapAt(_stepAt(tester, 3));
    await tester.pumpAndSettle();
    expect(result, 'high');
    expect(find.byKey(const ValueKey('reasoning-pill')), findsNothing);
  });

  testWidgets('the picker can follow the general value', (tester) async {
    String? result;
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showHermesReasoningPicker(
                context: context,
                title: 'Reasoning',
                levels: _levels,
                selected: 'high',
                defaultLabel: 'General',
                inheritLabel: 'Use general setting',
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    // The squares blink for as long as the sheet is open: no settling.
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.byKey(const ValueKey('reasoning-pill-inherit')));
    await tester.pumpAndSettle();
    expect(result, '');
  });

  testWidgets('the picker answers with the level already in force', (
    tester,
  ) async {
    String? result;
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showHermesReasoningPicker(
                context: context,
                title: 'Reasoning',
                levels: _levels,
                selected: 'low',
                defaultLabel: 'Default',
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tapAt(_stepAt(tester, 1));
    await tester.pumpAndSettle();
    expect(result, 'low');
  });
}
