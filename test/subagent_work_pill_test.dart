import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/hermes_design.dart';
import 'package:hermes_android/core/models/activity_snapshot.dart';
import 'package:hermes_android/core/models/subagent_activity.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/activity_pill.dart';
import 'package:hermes_android/core/widgets/subagent_work_pill.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'support/inter_font.dart';

Widget host(Widget child, {double scale = 1}) => MaterialApp(
  theme: AppTheme.fromId('dark'),
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  home: Scaffold(
    body: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(scale)),
      child: child,
    ),
  ),
);
void main() {
  setUpAll(loadInterFont);
  testWidgets(
    'queued count shares the work pill and stays visible paused at 320dp/2x',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final semantics = tester.ensureSemantics();

      for (final scale in [1.0, 2.0]) {
        for (final working in [true, false]) {
          var taps = 0;
          var resumes = 0;
          await tester.pumpWidget(
            host(
              SubagentWorkPill(
                key: ValueKey('$scale/$working'),
                working: working,
                queuedCount: 1,
                queuePaused: !working,
                onResumeQueue: !working ? () => resumes++ : null,
                count: const SubagentGroupCount(2, 2),
                onTap: () => taps++,
              ),
              scale: scale,
            ),
          );
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.text('1 en cola'), findsOneWidget);
          expect(
            find.text('Reanudar'),
            working ? findsNothing : findsOneWidget,
          );
          final hit = find.byKey(const ValueKey('subagent-work-hit-target'));
          expect(tester.getSize(hit).height, greaterThanOrEqualTo(48));
          final rect = tester.getRect(
            find.byKey(const ValueKey('subagent-work-pill')),
          );
          expect(rect.right, lessThanOrEqualTo(320));
          final spoken = tester
              .getSemantics(find.byKey(const ValueKey('subagent-work-status')))
              .label;
          expect(spoken, contains('1 en cola'));
          if (!working) expect(spoken, contains('En pausa'));
          await tester.tap(find.byKey(const ValueKey('subagent-work-chevron')));
          expect(taps, 1);
          if (!working) {
            final resume = find.byKey(const ValueKey('subagent-work-resume'));
            expect(
              tester.getSize(resume).shortestSide,
              greaterThanOrEqualTo(48),
            );
            await tester.tap(resume);
            expect(resumes, 1);
            expect(taps, 1, reason: 'Resume does not open the activity sheet');
          }
          expect(tester.takeException(), isNull);
        }
      }
      await tester.pumpWidget(
        host(const SubagentWorkPill(working: false, queuedCount: 1)),
      );
      final spoken = tester
          .getSemantics(find.byKey(const ValueKey('subagent-work-status')))
          .label;
      expect(spoken, '1 en cola');
      semantics.dispose();
    },
  );

  testWidgets(
    'one work line counts agents processes and queued input, omitting zero counts',
    (tester) async {
      await tester.pumpWidget(
        host(
          SubagentWorkPill(
            working: true,
            agentIcon: true,
            count: const SubagentGroupCount(1, 2),
            processCount: 1,
            queuedCount: 1,
            onTap: () {},
          ),
        ),
      );
      expect(find.text('1/2'), findsOneWidget);
      expect(find.text('1 proceso'), findsOneWidget);
      expect(find.text('1 en cola'), findsOneWidget);
      final spoken = tester
          .getSemantics(find.byKey(const ValueKey('subagent-work-status')))
          .label;
      expect(spoken, contains('1/2'));
      expect(spoken, contains('1 proceso'));
      await tester.pumpWidget(
        host(const SubagentWorkPill(working: true, agentIcon: true)),
      );
      expect(find.text('0 agentes'), findsNothing);
      expect(find.text('0 procesos'), findsNothing);
      expect(find.text('0 en cola'), findsNothing);
    },
  );

  testWidgets(
    'Stop and the round chevron have independent 48dp actions in a slim bar',
    (tester) async {
      var opens = 0;
      var stops = 0;
      await tester.pumpWidget(
        host(
          SubagentWorkPill(
            working: true,
            statusLabel: 'Ejecutando npm test',
            onTap: () => opens++,
            onStop: () => stops++,
          ),
        ),
      );
      final stop = find.byKey(const ValueKey('subagent-work-stop'));
      final chevron = find.byKey(const ValueKey('subagent-work-chevron'));
      final stopStyle = tester
          .widget<TextButton>(stop)
          .style!
          .textStyle!
          .resolve({});
      expect(
        stopStyle!.fontFamily,
        isNotNull,
        reason: 'the action must use the app font, not a fallback',
      );
      expect(
        stopStyle.fontFamily,
        Theme.of(tester.element(stop)).textTheme.labelLarge!.fontFamily,
      );
      for (final hit in [
        stop,
        chevron,
        find.byKey(const ValueKey('subagent-work-hit-target')),
      ]) {
        expect(tester.getSize(hit).height, greaterThanOrEqualTo(48));
        expect(tester.getSize(hit).width, greaterThanOrEqualTo(48));
      }
      expect(
        tester.getSize(find.byKey(const ValueKey('subagent-work-pill'))).height,
        lessThanOrEqualTo(28),
      );
      expect(find.textContaining('Ejecutando npm test'), findsOneWidget);
      await tester.tap(stop);
      expect(stops, 1);
      expect(opens, 0);
      await tester.tap(chevron);
      expect(opens, 1);
      await tester.tap(find.byKey(const ValueKey('subagent-work-hit-target')));
      expect(opens, 2);
      await tester.pumpWidget(
        host(SubagentWorkPill(working: true, onTap: () => opens++)),
      );
      expect(find.byKey(const ValueKey('subagent-work-stop')), findsNothing);
      expect(chevron, findsOneWidget);
    },
  );

  testWidgets('waiting for a response is amber; unconfirmed stays muted', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        const SubagentWorkPill(
          working: true,
          waitingForUser: true,
          statusLabel: 'Esperando tu respuesta',
        ),
      ),
    );
    Text text() =>
        tester.widget<Text>(find.byKey(const ValueKey('subagent-work-clock')));
    final context = tester.element(
      find.byKey(const ValueKey('subagent-work-pill')),
    );
    expect(text().data, contains('Esperando tu respuesta'));
    expect(text().style!.color, Theme.of(context).hermes.warning);
    await tester.pumpWidget(
      host(
        const SubagentWorkPill(
          working: true,
          unconfirmed: true,
          waitingForUser: true,
          statusLabel: 'Esperando tu respuesta',
        ),
      ),
    );
    expect(text().data, 'Esperando tu respuesta');
    expect(text().style!.color, Theme.of(context).hermes.warning);
    await tester.pumpWidget(
      host(const SubagentWorkPill(working: false, unconfirmed: true)),
    );
    expect(text().data, 'Sin confirmar');
    expect(
      text().style!.color,
      HermesChrome.of(Theme.of(context).hermes).mutedInk,
    );
  });

  testWidgets(
    'a paused queue stays explicit during work; Resume is a real action',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final semantics = tester.ensureSemantics();
      var resumes = 0;
      for (final scale in [1.0, 2.0]) {
        await tester.pumpWidget(
          host(
            SubagentWorkPill(
              working: true,
              queuedCount: 1,
              queuePaused: true,
              onResumeQueue: () => resumes++,
              onStop: () {},
            ),
            scale: scale,
          ),
        );
        expect(find.text('En pausa'), findsOneWidget);
        final resume = find.byKey(const ValueKey('subagent-work-resume'));
        expect(tester.getSize(resume).shortestSide, greaterThanOrEqualTo(48));
        expect(tester.getRect(resume).right, lessThanOrEqualTo(320));
        expect(tester.getSemantics(resume).label, contains('Reanudar'));
        final parent = tester.getSemantics(
          find.byKey(const ValueKey('subagent-work-status')),
        );
        expect(parent.label, contains('En pausa'));
        expect(
          parent.label,
          isNot(contains('Reanudar')),
          reason: 'the action has its own semantics',
        );
        await tester.tap(resume);
        expect(tester.takeException(), isNull);
      }
      expect(resumes, 2);
      semantics.dispose();
    },
  );

  test('elapsed clamps negative values and formats hour boundaries', () {
    expect(formatTurnElapsed(const Duration(seconds: -1)), '0:00');
    expect(formatTurnElapsed(const Duration(seconds: 259)), '4:19');
    expect(formatTurnElapsed(const Duration(seconds: 3599)), '59:59');
    expect(formatTurnElapsed(const Duration(seconds: 3600)), '1:00:00');
    expect(formatTurnElapsed(const Duration(seconds: 3661)), '1:01:01');
  });
  testWidgets('one clock, completed/total, no animated faces; tap opens', (
    tester,
  ) async {
    var now = DateTime.utc(2026, 11, 3, 12, 4, 19);
    var taps = 0;
    await tester.pumpWidget(
      host(
        SubagentWorkPill(
          working: true,
          count: const SubagentGroupCount(1, 2),
          startedAt: DateTime.utc(2026, 11, 3, 12),
          clock: () => now,
          onTap: () => taps++,
        ),
      ),
    );
    expect(find.text('Trabajando 4:19'), findsOneWidget);
    expect(find.text('1/2'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(ActivityTicker), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('subagent-work-pill'))).height,
      lessThanOrEqualTo(40),
    );
    final hit = find.byKey(const ValueKey('subagent-work-hit-target'));
    expect(tester.getSize(hit).height, greaterThanOrEqualTo(48));
    expect(tester.getSize(hit).width, greaterThanOrEqualTo(48));
    final semantics = tester.getSemantics(
      find.byKey(const ValueKey('subagent-work-status')),
    );
    expect(semantics.rect.height, greaterThanOrEqualTo(48));
    expect(semantics.flagsCollection.isButton, isTrue);
    expect(semantics.flagsCollection.isLiveRegion, isTrue);
    expect(semantics.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    expect(semantics.label, contains('Trabajando'));
    expect(semantics.label, contains('1/2'));
    // The invisible space above the painted capsule must really accept taps.
    final invisible = tester.getTopLeft(hit) + const Offset(8, 4);
    expect(
      tester
          .getRect(find.byKey(const ValueKey('subagent-work-pill')))
          .contains(invisible),
      isFalse,
    );
    await tester.tapAt(invisible);
    expect(taps, 1);
    await tester.tap(hit);
    expect(taps, 2);
    now = now.add(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Trabajando 4:20'), findsOneWidget);
  });

  testWidgets('content-sized one-line surface, small tokens and quiet chrome', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    for (final count in [
      SubagentGroupCount.none,
      const SubagentGroupCount(2, 2),
    ]) {
      await tester.pumpWidget(
        host(
          SubagentWorkPill(
            working: true,
            count: count,
            clock: () => DateTime.utc(2026, 11, 3, 12, 4, 19),
            startedAt: DateTime.utc(2026, 11, 3, 12),
            onTap: count.total == 0 ? null : () {},
          ),
        ),
      );
      final pill = find.byKey(const ValueKey('subagent-work-pill'));
      final rect = tester.getRect(pill);
      expect(rect.height, lessThanOrEqualTo(40));
      expect(rect.width, lessThan(200));
      final material = tester.widget<Material>(pill);
      expect(material.color!.a, 1);
      expect((material.shape! as StadiumBorder).side, BorderSide.none);
      final clock = find.byKey(const ValueKey('subagent-work-clock'));
      expect(
        tester.widget<Text>(clock).style!.fontSize,
        HermesType.captionSize,
      );
      expect(find.byIcon(Icons.group_outlined), findsNothing);
      if (count.total > 0) {
        final countLabel = find.byKey(const ValueKey('subagent-work-count'));
        final chevron = find.byIcon(Icons.keyboard_arrow_down_rounded);
        expect(chevron, findsOneWidget);
        expect(
          tester.getCenter(countLabel).dy,
          closeTo(tester.getCenter(clock).dy, 1),
        );
        expect(
          tester.getCenter(chevron).dy,
          closeTo(tester.getCenter(clock).dy, 1),
        );
        expect(find.text('·'), findsOneWidget);
      } else {
        expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsNothing);
      }
    }
  });

  testWidgets('all states stay slim at 1x and fit 320dp at 2x', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    for (final scale in [1.0, 2.0]) {
      Widget pill({bool working = false, bool unconfirmed = false}) => host(
        SubagentWorkPill(
          key: ValueKey(scale),
          working: working,
          unconfirmed: unconfirmed,
          count: const SubagentGroupCount(2, 2),
          clock: () => DateTime.utc(2026, 11, 3, 13, 1, 1),
          startedAt: DateTime.utc(2026, 11, 3, 12),
          onTap: () {},
        ),
        scale: scale,
      );
      for (final state in ['working', 'unconfirmed', 'done']) {
        await tester.pumpWidget(
          pill(
            working: state == 'working',
            unconfirmed: state == 'unconfirmed',
          ),
        );
        await tester.pump(const Duration(milliseconds: 300));
        final rect = tester.getRect(
          find.byKey(const ValueKey('subagent-work-pill')),
        );
        expect(tester.takeException(), isNull, reason: '$state at $scale');
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(320));
        if (scale == 1) expect(rect.height, lessThanOrEqualTo(40));
        final label = switch (state) {
          'working' => 'Trabajando 1:01:01',
          'unconfirmed' => 'Sin confirmar',
          _ => 'Terminado',
        };
        expect(find.text(label), findsOneWidget);
        final semantics = tester.getSemantics(
          find.byKey(const ValueKey('subagent-work-status')),
        );
        expect(semantics.label, contains(label.split(' 1:').first));
        expect(semantics.rect.height, greaterThanOrEqualTo(48));
      }
    }
  });
  testWidgets('turn without agents, completion linger, and fresh turn', (
    tester,
  ) async {
    var now = DateTime.utc(2026, 11, 3, 12);
    Widget pill(bool working, SubagentGroupCount count) => host(
      SubagentWorkPill(working: working, count: count, clock: () => now),
    );
    await tester.pumpWidget(pill(true, SubagentGroupCount.none));
    expect(find.text('Trabajando'), findsOneWidget);
    expect(find.byIcon(Icons.group_outlined), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('subagent-work-pill')),
        matching: find.byType(Wrap),
      ),
      findsNothing,
    );
    await tester.pumpWidget(pill(true, const SubagentGroupCount(0, 2)));
    expect(find.text('Trabajando 0:00'), findsOneWidget);
    await tester.pumpWidget(pill(false, const SubagentGroupCount(2, 2)));
    expect(find.text('Terminado'), findsOneWidget);
    now = now.add(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('subagent-work-pill')), findsNothing);
    await tester.pumpWidget(pill(true, SubagentGroupCount.none));
    expect(find.text('Trabajando'), findsOneWidget);
  });
  testWidgets(
    'unconfirmed stays muted without ticking or claiming completion',
    (tester) async {
      await tester.pumpWidget(
        host(
          const SubagentWorkPill(
            working: false,
            unconfirmed: true,
            count: SubagentGroupCount(1, 2),
          ),
        ),
      );
      expect(find.text('Sin confirmar'), findsOneWidget);
      expect(find.textContaining('Trabajando'), findsNothing);
      expect(find.text('Terminado'), findsNothing);
      expect(
        tester.widget<ActivityTicker>(find.byType(ActivityTicker)).active,
        isFalse,
      );
    },
  );
  testWidgets('320dp with 2x text remains bounded', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      host(
        SubagentWorkPill(
          working: true,
          startedAt: DateTime.utc(2026, 11, 3, 12),
          clock: () => DateTime.utc(2026, 11, 3, 13, 1, 1),
          count: const SubagentGroupCount(2, 2),
        ),
        scale: 2,
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Trabajando 1:01:01'), findsOneWidget);
    await tester.pumpWidget(
      host(
        SubagentWorkPill(
          working: true,
          clock: () => DateTime.utc(2026, 11, 3, 13, 1, 1),
        ),
        scale: 2,
      ),
    );
    expect(tester.takeException(), isNull);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('subagent-work-pill')),
        matching: find.byType(Wrap),
      ),
      findsNothing,
    );
  });
  testWidgets(
    'stale origins are rejected and reconnects keep an observed origin',
    (tester) async {
      var now = DateTime.utc(2026, 11, 3, 12);
      Widget pill({DateTime? start, bool unknown = false}) => host(
        SubagentWorkPill(
          working: !unknown,
          count: const SubagentGroupCount(0, 1),
          unconfirmed: unknown,
          startedAt: start,
          clock: () => now,
        ),
      );
      await tester.pumpWidget(
        pill(start: DateTime.fromMillisecondsSinceEpoch(1)),
      );
      expect(find.text('Trabajando 0:00'), findsOneWidget);
      await tester.pumpWidget(pill());
      now = now.add(const Duration(seconds: 10));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Trabajando 0:10'), findsOneWidget);
      await tester.pumpWidget(pill(unknown: true));
      now = now.add(const Duration(seconds: 10));
      await tester.pumpWidget(pill());
      expect(find.text('Trabajando 0:20'), findsOneWidget);
    },
  );

  testWidgets('continuous work keeps its clock when the source changes', (
    tester,
  ) async {
    var now = DateTime.utc(2026, 11, 3, 12);
    Widget pill(DateTime? start) => host(
      SubagentWorkPill(
        working: true,
        count: const SubagentGroupCount(0, 1),
        startedAt: start,
        clock: () => now,
      ),
    );
    await tester.pumpWidget(pill(null));
    now = now.add(const Duration(seconds: 19));
    await tester.pumpWidget(pill(now));
    expect(find.text('Trabajando 0:19'), findsOneWidget);
    now = now.add(const Duration(seconds: 40));
    await tester.pumpWidget(pill(DateTime.utc(2026, 11, 3, 11)));
    expect(find.text('Trabajando 0:59'), findsOneWidget);
  });

  testWidgets('opening an already finished roster never flashes completion', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        const SubagentWorkPill(working: false, count: SubagentGroupCount(2, 2)),
      ),
    );
    expect(find.text('Terminado'), findsNothing);
    expect(
      tester.widget<ActivityTicker>(find.byType(ActivityTicker)).active,
      isFalse,
    );
    expect(find.byKey(const ValueKey('subagent-work-pill')), findsNothing);
    await tester.pump(const Duration(seconds: 3));
    expect(find.byKey(const ValueKey('subagent-work-pill')), findsNothing);
  });

  group('SubagentGroupCount', () {
    SubagentActivity activity(String id, SubagentActivityPhase phase) =>
        SubagentActivity(
          key: SubagentActivityKey(
            scope: SubagentActivityScope(
              connectionId: 'c',
              parentSessionId: 'p',
              runtimeSessionId: 'r',
              turnEpoch: 1,
            ),
            identityKind: SubagentIdentityKind.subagent,
            stableId: id,
          ),
          source: SubagentActivitySource.native,
          phase: phase,
          subagentId: id,
          details: const SubagentActivityDetails(),
        );

    test('finished counts every ended phase; unknown and live do not', () {
      final count = SubagentGroupCount.of([
        activity('a', SubagentActivityPhase.completed),
        activity('b', SubagentActivityPhase.failed),
        activity('c', SubagentActivityPhase.cancelled),
        activity('d', SubagentActivityPhase.running),
        activity('e', SubagentActivityPhase.unknown),
      ]);
      expect(count, const SubagentGroupCount(3, 5));
      expect(count.allFinished, isFalse);
      expect(
        SubagentGroupCount.of([
          activity('a', SubagentActivityPhase.completed),
        ]).allFinished,
        isTrue,
      );
    });

    test('a roster known only by number counts 0/N', () {
      expect(
        SubagentGroupCount.of(const [], genericTotal: 3),
        const SubagentGroupCount(0, 3),
      );
    });

    test('the snapshot exposes the same count for the live pill', () {
      final snapshot = ActivitySnapshot(
        subagents: [
          activity('a', SubagentActivityPhase.completed),
          activity('b', SubagentActivityPhase.running),
        ],
      );
      expect(snapshot.subagentGroupCount, const SubagentGroupCount(1, 2));
    });
  });
}
