import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/hermes_design.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

const _viewports = <Size>[Size(360, 800), Size(390, 844)];
const _scales = <double>[1.0, 1.3, 2.0];

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(390, 844),
  double scale = 1,
  Locale locale = const Locale('en'),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.hermesRedDark,
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

const _long =
    'Search today\'s news in Spain and send me a summary with the five most '
    'important headlines and a link to each one. Keep it short, in Spanish, '
    'and skip sports. Group by topic: politics, economy, technology, '
    'culture and international. Add one sentence of context per headline. '
    'If nothing important happened, say so in one line instead of padding. '
    'End with the weather in Madrid for tomorrow morning and evening.';

void main() {
  group('HermesListRow / Group / SectionHeader', () {
    testWidgets('reference metrics: 52 dp rows, uppercase caption header', (
      tester,
    ) async {
      await _pump(
        tester,
        Scaffold(
          body: ListView(
            children: [
              const HermesSectionHeader('Model'),
              HermesListGroup(
                children: [
                  HermesListRow(
                    key: const ValueKey('row'),
                    icon: Icons.memory_rounded,
                    title: 'Model',
                    value: 'openai · gpt-5.5',
                    onTap: () {},
                  ),
                  const HermesListRow(title: 'Machine', value: 'homelab'),
                ],
              ),
            ],
          ),
        ),
      );
      expect(find.text('MODEL'), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const ValueKey('row'))).height,
        greaterThanOrEqualTo(52),
      );
      expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);
      final header = tester.widget<Text>(find.text('MODEL'));
      expect(header.style?.fontSize, 11.5);
    });

    for (final size in _viewports) {
      for (final scale in _scales) {
        testWidgets('long rows wrap without overflow at $size ×$scale', (
          tester,
        ) async {
          await _pump(
            tester,
            Scaffold(
              body: ListView(
                children: [
                  HermesListGroup(
                    children: [
                      HermesListRow(
                        icon: Icons.schedule_rounded,
                        title: _long,
                        subtitle: _long,
                        value: 'A very long value that must ellipsize',
                        onTap: () {},
                      ),
                      HermesToggleRow(
                        title: 'Notify me when it finishes',
                        subtitle: _long,
                        value: true,
                        onChanged: (_) {},
                      ),
                      HermesSelectRow(
                        title: 'Model',
                        value: 'Default of the profile',
                        onTap: () {},
                      ),
                    ],
                  ),
                  const HermesStatusText(
                    label: 'Scheduled',
                    meta: 'next today 18:30 · every weekday',
                  ),
                  const HermesTag(label: 'Read-only'),
                ],
              ),
            ),
            size: size,
            scale: scale,
          );
          expect(tester.takeException(), isNull);
        });
      }
    }
  });

  group('HermesToggleRow', () {
    testWidgets('whole row toggles and is 48 dp+', (tester) async {
      var value = false;
      await _pump(
        tester,
        StatefulBuilder(
          builder: (context, setState) => Scaffold(
            body: HermesToggleRow(
              key: const ValueKey('toggle'),
              title: 'Only if it fails',
              value: value,
              onChanged: (v) => setState(() => value = v),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Only if it fails'));
      await tester.pump();
      expect(value, isTrue);
      expect(
        tester.getSize(find.byKey(const ValueKey('toggle'))).height,
        greaterThanOrEqualTo(48),
      );
    });
  });

  group('HermesStatusText', () {
    testWidgets('dot + label, no box', (tester) async {
      await _pump(
        tester,
        const Scaffold(
          body: HermesStatusText(
            label: 'Failed',
            tone: HermesStatusTone.error,
            meta: '2 h ago',
          ),
        ),
      );
      expect(find.text('Failed · 2 h ago', findRichText: true), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(HermesStatusText),
          matching: find.byWidgetPredicate(
            (w) =>
                w is Container &&
                w.decoration is BoxDecoration &&
                (w.decoration as BoxDecoration).border != null,
          ),
        ),
        findsNothing,
      );
    });
  });

  group('HermesTextBlock', () {
    testWidgets('has no scrollable of its own and collapses with Show all', (
      tester,
    ) async {
      await _pump(
        tester,
        Scaffold(
          body: ListView(
            children: const [HermesTextBlock(text: _long, collapsedLines: 3)],
          ),
        ),
        size: const Size(360, 800),
      );
      // Only the page list is scrollable.
      expect(find.byType(Scrollable), findsOneWidget);
      final text = find.byKey(const ValueKey('hermes-text-block-text'));
      expect(tester.widget<Text>(text).maxLines, 3);
      final collapsedHeight = tester.getSize(text).height;
      await tester.tap(find.text('Show all'));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(text).maxLines, isNull);
      expect(tester.getSize(text).height, greaterThan(collapsedHeight));
      expect(find.text('Show less'), findsOneWidget);
    });

    testWidgets('short text shows no toggle', (tester) async {
      await _pump(
        tester,
        const Scaffold(body: HermesTextBlock(text: 'Short.')),
      );
      expect(find.text('Show all'), findsNothing);
    });

    testWidgets('Spanish copy', (tester) async {
      await _pump(
        tester,
        Scaffold(
          body: ListView(
            children: const [HermesTextBlock(text: _long, collapsedLines: 2)],
          ),
        ),
        locale: const Locale('es'),
      );
      expect(find.text('Ver todo'), findsOneWidget);
    });

    testWidgets('huge text opens a single-scroll log page', (tester) async {
      final huge = List.generate(260, (i) => 'line $i').join('\n');
      await _pump(
        tester,
        Scaffold(
          body: ListView(
            children: [
              HermesTextBlock(text: huge, mono: true, openTitle: 'Output'),
            ],
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('hermes-text-block-open')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('hermes-log-page')), findsOneWidget);
      expect(find.text('Output'), findsOneWidget);
    });
  });

  group('HermesDetailScaffold', () {
    for (final size in _viewports) {
      for (final scale in const [1.0, 1.3, 2.0]) {
        testWidgets('one page scroll, no overflow at $size ×$scale', (
          tester,
        ) async {
          await _pump(
            tester,
            HermesDetailScaffold(
              title: 'Daily news summary with an extra long name for wrapping',
              status: const HermesStatusText(
                label: 'Active',
                tone: HermesStatusTone.ok,
                meta: 'next today 18:30',
              ),
              primaryAction: HermesActionButton(
                primary: true,
                icon: Icons.play_arrow_rounded,
                label: 'Run now',
                onPressed: () {},
              ),
              secondaryAction: HermesActionButton(
                label: 'Pause',
                onPressed: () {},
              ),
              sections: const [
                HermesSectionHeader('What it does'),
                HermesTextBlock(text: _long),
              ],
            ),
            size: size,
            scale: scale,
          );
          expect(tester.takeException(), isNull);
          expect(find.byType(Scrollable), findsOneWidget);
        });
      }
    }
  });
}
