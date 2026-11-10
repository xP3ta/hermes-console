import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/herdr_status.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/herdr_widgets.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

/// Real Herdr 0.9.5 snapshot: app (claude «reviewer» working, codex
/// blocked), logs (claude done), real (a shell).
final HerdrSnapshot _snapshot = parseHerdrSnapshotOutput(
  SshRemoteResult(
    stdout: File('test/fixtures/herdr/snapshot_0_9_5.json').readAsStringSync(),
    exitCode: 0,
  ),
);

HerdrSnapshot _focusing(String paneId) => HerdrSnapshot(
  workspaces: _snapshot.workspaces,
  focusedPaneId: paneId,
  version: _snapshot.version,
);

Widget _app(Widget child, {ThemeData? theme, double textScale = 1}) =>
    MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: const [
        Strings.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: Strings.supportedLocales,
      theme: theme ?? AppTheme.hermesRedDark,
      builder: (context, home) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: home!,
      ),
      home: Scaffold(body: child),
    );

final _themes = <String, ThemeData>{
  'dark': AppTheme.hermesRedDark,
  'light': AppTheme.hermesRedLight,
};

void main() {
  group('HerdrAgentBanner', () {
    testWidgets('focused agent: its name and state', (tester) async {
      await tester.pumpWidget(
        _app(HerdrAgentBanner(view: HerdrView(snapshot: _snapshot))),
      );
      expect(find.text('reviewer'), findsOneWidget);
      expect(find.text('Working'), findsOneWidget);
    });

    testWidgets('an agent without a name shows its kind', (tester) async {
      await tester.pumpWidget(
        _app(HerdrAgentBanner(view: HerdrView(snapshot: _focusing('w1:p2')))),
      );
      expect(find.text('codex'), findsOneWidget);
      expect(find.text('Needs you'), findsOneWidget);
    });

    testWidgets('a shell pane says no agent was detected', (tester) async {
      await tester.pumpWidget(
        _app(HerdrAgentBanner(view: HerdrView(snapshot: _focusing('w3:p1')))),
      );
      expect(find.text('Shell'), findsOneWidget);
      expect(find.text('No agent detected in this pane'), findsOneWidget);
    });

    // Review R5A P3-B4-3: TalkBack announces the banner only when the
    // agent needs you or is done, not on every poll.
    testWidgets('a live region only while the agent needs you or is done', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      const banner = ValueKey('herdr-agent-banner');
      await tester.pumpWidget(
        _app(HerdrAgentBanner(view: HerdrView(snapshot: _snapshot))),
      );
      expect(
        tester.getSemantics(find.byKey(banner)),
        isSemantics(isLiveRegion: false),
      );
      await tester.pumpWidget(
        _app(HerdrAgentBanner(view: HerdrView(snapshot: _focusing('w1:p2')))),
      );
      expect(
        tester.getSemantics(find.byKey(banner)),
        isSemantics(isLiveRegion: true),
      );
      semantics.dispose();
    });

    testWidgets('server stopped, read failed, or nothing yet', (tester) async {
      await tester.pumpWidget(
        _app(const HerdrAgentBanner(view: HerdrView(notRunning: true))),
      );
      expect(find.text('The Herdr server is not running.'), findsOneWidget);

      await tester.pumpWidget(
        _app(
          HerdrAgentBanner(
            view: HerdrView(snapshot: _snapshot, failed: true),
          ),
        ),
      );
      expect(find.text("Could not read Herdr's state."), findsOneWidget);

      await tester.pumpWidget(_app(const HerdrAgentBanner(view: HerdrView())));
      expect(find.byKey(const ValueKey('herdr-agent-banner')), findsNothing);
    });
  });

  group('HerdrPanel', () {
    testWidgets('workspaces with their panes; agents open, shells do not', (
      tester,
    ) async {
      final opened = <String>[];
      await tester.pumpWidget(
        _app(
          HerdrPanel(
            view: HerdrView(snapshot: _snapshot),
            onOpenAgent: (pane) => opened.add(pane.paneId),
          ),
        ),
      );

      for (final label in ['app', 'logs', 'real']) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.text('reviewer'), findsOneWidget);
      expect(find.text('codex'), findsOneWidget);
      expect(find.text('Finished'), findsOneWidget);
      expect(find.text('/home/demo/proyectos/app'), findsOneWidget);
      expect(
        find.text('Herdr keeps the agents running even if you close the app.'),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('herdr-pane-w1:p2')));
      await tester.tap(find.byKey(const ValueKey('herdr-pane-w3:p1')));
      expect(opened, ['w1:p2']);
    });

    // Review P2-F5-4: the workspace roll-up is not colour only.
    testWidgets('each workspace says its state to screen readers', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        _app(
          HerdrPanel(
            view: HerdrView(snapshot: _snapshot),
            onOpenAgent: (_) {},
          ),
        ),
      );
      expect(
        tester.getSemantics(find.byKey(const ValueKey('herdr-workspace-w1'))),
        isSemantics(label: 'app, Needs you', isHeader: true),
      );
      expect(
        tester.getSemantics(find.byKey(const ValueKey('herdr-workspace-w2'))),
        isSemantics(label: 'logs, Finished'),
      );
      semantics.dispose();
    });

    testWidgets('empty and stopped states', (tester) async {
      await tester.pumpWidget(
        _app(
          HerdrPanel(
            view: const HerdrView(snapshot: HerdrSnapshot(workspaces: [])),
            onOpenAgent: (_) {},
          ),
        ),
      );
      expect(find.text('Herdr has no open workspaces.'), findsOneWidget);

      await tester.pumpWidget(
        _app(
          HerdrPanel(
            view: const HerdrView(notRunning: true),
            onOpenAgent: (_) {},
          ),
        ),
      );
      expect(find.text('The Herdr server is not running.'), findsOneWidget);
    });

    for (final entry in _themes.entries) {
      testWidgets('${entry.key} theme: state dots use the theme tokens', (
        tester,
      ) async {
        final colors = entry.value.hermes;
        await tester.pumpWidget(
          _app(
            HerdrPanel(
              view: HerdrView(snapshot: _snapshot),
              onOpenAgent: (_) {},
            ),
            theme: entry.value,
          ),
        );
        Color dot(String paneId) {
          final container = tester.widget<Container>(
            find.descendant(
              of: find.descendant(
                of: find.byKey(ValueKey('herdr-pane-$paneId')),
                matching: find.byType(HerdrStatusDot),
              ),
              matching: find.byType(Container),
            ),
          );
          return (container.decoration! as BoxDecoration).color!;
        }

        expect(dot('w1:p1'), colors.accent);
        expect(dot('w1:p2'), colors.warning);
        expect(dot('w2:p1'), colors.success);
      });

      testWidgets('${entry.key} theme at 2x text: no overflow', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          _app(
            Column(
              children: [
                HerdrAgentBanner(view: HerdrView(snapshot: _snapshot)),
                Expanded(
                  child: HerdrPanel(
                    view: HerdrView(snapshot: _snapshot),
                    onOpenAgent: (_) {},
                  ),
                ),
              ],
            ),
            theme: entry.value,
            textScale: 2,
          ),
        );
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('HerdrPanelButton', () {
    testWidgets('badge counts agents that need you', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _app(HerdrPanelButton(needsYou: 2, onPressed: () => taps++)),
      );
      expect(find.text('2'), findsOneWidget);
      expect(
        find.byTooltip(
          'Herdr: workspaces and agents · Agents that need you: 2',
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('herdr-panel-button')));
      expect(taps, 1);

      await tester.pumpWidget(
        _app(HerdrPanelButton(needsYou: 0, onPressed: () {})),
      );
      expect(find.text('0'), findsNothing);
      expect(find.byTooltip('Herdr: workspaces and agents'), findsOneWidget);
    });
  });
}
