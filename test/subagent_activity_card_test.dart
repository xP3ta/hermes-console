import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/subagent_activity.dart';
import 'package:hermes_android/core/screens/subagent_detail_screen.dart';
import 'package:hermes_android/core/services/active_chat_service.dart'
    show ProfileTranscriptAccessRequired;
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/accent_card.dart';
import 'package:hermes_android/core/widgets/subagent_activity_card.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'support/inter_font.dart';

final SubagentActivityScope _scope = SubagentActivityScope(
  connectionId: 'connection-card',
  parentSessionId: 'parent-card',
  runtimeSessionId: 'runtime-card',
  turnEpoch: 1,
);

SubagentActivity _nativeActivity({
  String subagentId = 'child-card',
  String? childSessionId = 'child-session-card',
  String goalPreview = 'Revisar el proyecto',
  String? summaryPreview,
  SubagentActivityPhase phase = SubagentActivityPhase.running,
  String? model,
  String? activeToolName,
  int? toolCount,
  int? apiCalls,
  int? filesReadCount,
  int? filesWrittenCount,
  double? durationSeconds,
  SubagentTaskProgress? progress,
  String? detailPreview,
  String? activeToolPreview,
  DateTime? startedAt,
}) => SubagentActivity(
  key: SubagentActivityKey(
    scope: _scope,
    identityKind: SubagentIdentityKind.subagent,
    stableId: subagentId,
  ),
  source: SubagentActivitySource.native,
  phase: phase,
  subagentId: subagentId,
  childSessionId: childSessionId,
  details: SubagentActivityDetails(
    goalPreview: goalPreview,
    summaryPreview: summaryPreview,
    detailPreview: detailPreview,
    activeToolPreview: activeToolPreview,
    model: model,
    activeToolName: activeToolName,
    toolCount: toolCount,
    filesReadCount: filesReadCount,
    filesWrittenCount: filesWrittenCount,
    durationSeconds: durationSeconds,
    progress: progress,
    startedAt: startedAt,
    usage: apiCalls == null ? null : SubagentUsage(apiCalls: apiCalls),
  ),
);

SubagentActivity _legacyActivity() => SubagentActivity(
  key: SubagentActivityKey(
    scope: _scope,
    identityKind: SubagentIdentityKind.legacyToolCall,
    stableId: 'legacy-call-card',
  ),
  source: SubagentActivitySource.legacyDelegateTask,
  phase: SubagentActivityPhase.running,
  legacyToolCallId: 'legacy-call-card',
  details: const SubagentActivityDetails(),
);

Widget _host(Widget child, {Locale locale = const Locale('es')}) => MaterialApp(
  locale: locale,
  theme: AppTheme.fromId('dark'),
  localizationsDelegates: const [
    Strings.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: Strings.supportedLocales,
  home: Scaffold(body: SafeArea(child: child)),
);

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  setUpAll(loadInterFont);

  group('in-chat row', () {
    testWidgets('single subagent: flat row with goal, status and elapsed', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          SubagentActivityCard(
            activities: [_nativeActivity(durationSeconds: 83)],
            canSteer: (_) => true,
            canInterrupt: (_) => false,
          ),
        ),
      );
      expect(find.text('Subagente · Revisar el proyecto'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('Trabajando, 1:23')), findsWidgets);
      expect(find.byType(AccentCard), findsNothing);
      // Flat: no elevation, no stadium pill.
      final material = tester.widget<Material>(
        find.byKey(const ValueKey('subagent-disclosure')),
      );
      expect(material.type, MaterialType.transparency);
      expect(
        tester
            .getSize(find.byKey(const ValueKey('subagent-disclosure')))
            .height,
        greaterThanOrEqualTo(48),
      );
    });

    testWidgets('several: one grouped row, tap opens floating list', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          SubagentActivityCard(
            activities: [
              _nativeActivity(subagentId: 'a', goalPreview: 'Auditar Android'),
              _nativeActivity(subagentId: 'b', goalPreview: 'Revisar iOS'),
              _nativeActivity(
                subagentId: 'c',
                goalPreview: 'Verificar notas',
                phase: SubagentActivityPhase.completed,
              ),
            ],
            canSteer: (_) => true,
            canInterrupt: (_) => false,
          ),
        ),
      );
      expect(find.text('3 subagentes'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('2 trabajando')), findsWidgets);
      expect(find.text('Auditar Android'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('subagent-disclosure')));
      await _settle(tester);
      expect(find.byKey(const ValueKey('subagent-panel')), findsOneWidget);
      expect(find.byKey(const ValueKey('subagent-row-a')), findsOneWidget);
      expect(find.byKey(const ValueKey('subagent-row-c')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('Auditar Android')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('subagent-row-b')));
      await _settle(tester);
      expect(find.byType(SubagentDetailScreen), findsOneWidget);
      expect(find.text('Revisar iOS'), findsWidgets);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('non-owner surface never reveals goals or ids', (tester) async {
      const privateGoal = 'PRIVATE_SUBAGENT_GOAL';
      const privateResult = 'PRIVATE_SUBAGENT_RESULT';
      const privateId = 'PRIVATE_SUBAGENT_ID';
      await tester.pumpWidget(
        _host(
          SubagentActivityCard(
            activities: [
              _nativeActivity(
                subagentId: privateId,
                goalPreview: privateGoal,
                summaryPreview: privateResult,
                detailPreview: 'PRIVATE_REASONING',
                activeToolPreview: 'PRIVATE_TOOL_INPUT',
              ),
            ],
            canInterrupt: (_) => false,
          ),
        ),
      );
      for (final t in [privateGoal, privateResult, privateId]) {
        expect(find.textContaining(t), findsNothing);
      }
      await tester.tap(find.byKey(const ValueKey('subagent-disclosure')));
      await _settle(tester);
      expect(find.byType(SubagentDetailScreen), findsOneWidget);
      for (final t in [
        privateGoal,
        privateResult,
        privateId,
        'PRIVATE_REASONING',
        'PRIVATE_TOOL_INPUT',
      ]) {
        expect(find.textContaining(t), findsNothing, reason: t);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('failure and unknown never claim success', (tester) async {
      for (final phases in [
        [SubagentActivityPhase.cancelled],
        [SubagentActivityPhase.completed, SubagentActivityPhase.unknown],
      ]) {
        await tester.pumpWidget(
          _host(
            SubagentActivityCard(
              activities: [
                for (var i = 0; i < phases.length; i++)
                  _nativeActivity(subagentId: 'c$i', phase: phases[i]),
              ],
              canInterrupt: (_) => false,
            ),
          ),
        );
        expect(
          find.bySemanticsLabel(RegExp('Terminado|todos terminados')),
          findsNothing,
        );
      }
      await tester.pumpWidget(
        _host(
          SubagentActivityCard(
            activities: [_nativeActivity(phase: SubagentActivityPhase.failed)],
            canInterrupt: (_) => false,
          ),
        ),
      );
      expect(find.bySemanticsLabel(RegExp('Falló')), findsWidgets);
    });

    testWidgets('dismiss only once nothing is live', (tester) async {
      var dismissed = 0;
      Widget build(SubagentActivityPhase phase) => _host(
        SubagentActivityCard(
          activities: [_nativeActivity(phase: phase)],
          canInterrupt: (_) => false,
          onDismiss: () => dismissed++,
        ),
      );
      await tester.pumpWidget(build(SubagentActivityPhase.running));
      expect(find.byIcon(Icons.close_rounded), findsNothing);
      await tester.pumpWidget(build(SubagentActivityPhase.completed));
      await tester.tap(find.byIcon(Icons.close_rounded));
      expect(dismissed, 1);
    });

    testWidgets('2x text at 360 keeps the row bounded without overflow', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 800);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(360, 800),
            textScaler: TextScaler.linear(2),
          ),
          child: _host(
            SubagentActivityCard(
              activities: [
                _nativeActivity(goalPreview: 'objetivo largo ' * 30),
              ],
              canSteer: (_) => true,
              canInterrupt: (_) => true,
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      final title = tester.widget<Text>(
        find.byKey(const ValueKey('subagent-row-title')),
      );
      expect(title.maxLines, 1);
    });
  });

  group('historical completion row', () {
    testWidgets('homogeneous completion is terminal and privacy-safe', (
      tester,
    ) async {
      const privateId = 'sa-private-should-not-render';
      await tester.pumpWidget(
        _host(
          SubagentCompletionCard(
            data: SubagentCompletionCardData(
              completionKey: 'completion-safe',
              delegationId: 'deleg_c0ffee12',
              taskCount: 1,
              completedCount: 1,
              failedCount: 0,
              durationSeconds: 0.05,
              subagentIds: const [privateId],
            ),
          ),
        ),
      );
      expect(find.bySemanticsLabel(RegExp('1 completado')), findsWidgets);
      expect(find.textContaining(privateId), findsNothing);
      expect(find.textContaining('deleg_c0ffee12'), findsNothing);
      expect(find.text('Detener'), findsNothing);
    });

    testWidgets('failures are the headline and ids stay hidden', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          SubagentCompletionCard(
            data: SubagentCompletionCardData(
              completionKey: 'mixed',
              delegationId: 'deleg_mixed',
              taskCount: 3,
              completedCount: 2,
              failedCount: 1,
              subagentIds: const ['sa-one', 'sa-two', 'sa-three'],
            ),
          ),
        ),
      );
      expect(find.text('3 subagentes'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('1 falló')), findsWidgets);
      expect(find.textContaining('sa-one'), findsNothing);
      expect(find.textContaining('deleg_mixed'), findsNothing);
    });
  });

  group('detail page', () {
    Future<ValueNotifier<List<SubagentActivity>>> pumpDetail(
      WidgetTester tester,
      SubagentActivity activity, {
      bool canInterrupt = true,
      bool canSteer = true,
      SubagentStopRequester? onStop,
      SubagentSteerSender? onSteer,
      SubagentTailLoader? onTail,
      SubagentTailScheduler? scheduler,
      ValueChanged<SubagentActivity>? onOpen,
      RouteObserver<PageRoute<dynamic>>? observer,
      bool hideGoal = false,
      TextScaler textScaler = TextScaler.noScaling,
    }) async {
      final roster = ValueNotifier<List<SubagentActivity>>([activity]);
      addTearDown(roster.dispose);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('es'),
          theme: AppTheme.fromId('dark'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          navigatorObservers: [?observer],
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: textScaler),
            child: child!,
          ),
          home: SubagentDetailScreen(
            roster: roster,
            activityKey: activity.key,
            parentTitle: 'Chat de prueba',
            canInterrupt: (_) => canInterrupt,
            onStopRequested: onStop,
            canSteer: (_) => canSteer,
            onSteer: onSteer,
            onTail: onTail,
            onOpenConversation: onOpen,
            scheduleTailPoll: scheduler,
            clock: () => DateTime.utc(2026, 9, 27, 12),
            routeObserver: observer ?? RouteObserver<PageRoute<dynamic>>(),
            hideGoal: hideGoal,
          ),
        ),
      );
      await tester.pump();
      return roster;
    }

    testWidgets('running: goal title, status, Stop primary, no dead buttons', (
      tester,
    ) async {
      SubagentActivity? stopped;
      await pumpDetail(
        tester,
        _nativeActivity(durationSeconds: 83, toolCount: 4),
        onStop: (a) async {
          stopped = a;
          return true;
        },
      );
      expect(find.text('Revisar el proyecto'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('Trabajando, 1:23')), findsWidgets);
      expect(
        find.byKey(const ValueKey('subagent-detail-stop')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('subagent-detail-open')), findsNothing);
      for (final dead in ['Duplicar', 'Archivar', 'Eliminar', 'Reanudar']) {
        expect(find.text(dead), findsNothing);
      }
      expect(find.text('4 herramientas usadas'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('subagent-detail-stop')));
      await tester.pump();
      expect(stopped, isNotNull);
      final button = tester.widget<FilledButton>(
        find.descendant(
          of: find.byKey(const ValueKey('subagent-detail-stop')),
          matching: find.byType(FilledButton),
        ),
      );
      expect(button.onPressed, isNull, reason: 'stays pending until terminal');
    });

    testWidgets('finished: result block and Open conversation primary', (
      tester,
    ) async {
      SubagentActivity? opened;
      await pumpDetail(
        tester,
        _nativeActivity(
          phase: SubagentActivityPhase.completed,
          summaryPreview: 'Todo revisado, 3 fallos corregidos.',
        ),
        onOpen: (a) => opened = a,
      );
      expect(find.byKey(const ValueKey('subagent-detail-stop')), findsNothing);
      expect(find.text('Todo revisado, 3 fallos corregidos.'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('subagent-detail-open')));
      expect(opened, isNotNull);
      expect(find.byKey(const ValueKey('subagent-steer-input')), findsNothing);
    });

    testWidgets('private fields never render; metrics stay collapsed', (
      tester,
    ) async {
      await pumpDetail(
        tester,
        _nativeActivity(
          model: 'model-x',
          apiCalls: 5,
          detailPreview: 'PRIVATE_REASONING',
          activeToolPreview: 'PRIVATE_TOOL_INPUT',
          summaryPreview: 'PRIVATE_RESULT_WHILE_RUNNING',
          subagentId: 'PRIVATE_OPAQUE_ID',
        ),
      );
      for (final t in [
        'PRIVATE_REASONING',
        'PRIVATE_TOOL_INPUT',
        'PRIVATE_RESULT_WHILE_RUNNING',
        'PRIVATE_OPAQUE_ID',
      ]) {
        expect(find.textContaining(t), findsNothing, reason: t);
      }
      expect(find.text('model-x'), findsNothing);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('subagent-detail-technical')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byKey(const ValueKey('subagent-detail-technical')));
      await tester.pump();
      expect(find.text('model-x'), findsOneWidget);
      expect(find.text('Llamadas a la API'), findsOneWidget);
    });

    testWidgets('hideGoal keeps the goal private', (tester) async {
      await pumpDetail(tester, _nativeActivity(), hideGoal: true);
      expect(find.text('Revisar el proyecto'), findsNothing);
      expect(find.text('Subagente'), findsWidgets);
    });

    testWidgets('legacy child: no stop, no open, no steer', (tester) async {
      await pumpDetail(
        tester,
        _legacyActivity(),
        canInterrupt: false,
        canSteer: false,
        onOpen: (_) {},
      );
      expect(find.byKey(const ValueKey('subagent-detail-stop')), findsNothing);
      expect(find.byKey(const ValueKey('subagent-detail-open')), findsNothing);
      expect(
        find.byKey(const ValueKey('subagent-detail-open-row')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('subagent-steer-input')), findsNothing);
    });

    testWidgets('steer: queued clears and explains; rejection keeps draft', (
      tester,
    ) async {
      var status = 'rejected';
      await pumpDetail(
        tester,
        _nativeActivity(),
        onSteer: (_, _) async => SubagentSteerView(status: status),
      );
      final input = find.byKey(const ValueKey('subagent-steer-input'));
      final send = find.byKey(const ValueKey('subagent-steer-send'));
      await tester.enterText(input, 'Conserva este borrador');
      await tester.pump();
      await tester.tap(send);
      await tester.pump();
      expect(find.text('Conserva este borrador'), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp('No aceptó la indicación')),
        findsOneWidget,
      );
      status = 'queued';
      await tester.tap(send);
      await tester.pump();
      expect(find.text('Conserva este borrador'), findsNothing);
      expect(
        find.bySemanticsLabel(
          RegExp('Enviado · lo aplicará en su próximo paso'),
        ),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(RegExp('puede que no llegue a leerlo')),
        findsOneWidget,
      );
      expect(tester.getSize(send).height, greaterThanOrEqualTo(48));
    });

    testWidgets('live tail: appends, adapts interval, stops when covered', (
      tester,
    ) async {
      final observer = RouteObserver<PageRoute<dynamic>>();
      final scheduled = <(Duration, VoidCallback)>[];
      var calls = 0;
      var content = 'línea 1';
      await pumpDetail(
        tester,
        _nativeActivity(),
        observer: observer,
        scheduler: (delay, cb) {
          final entry = (delay, cb);
          scheduled.add(entry);
          return () => scheduled.remove(entry);
        },
        onTail: (_) async {
          calls++;
          return SubagentTailView(
            available: true,
            content: content,
            truncated: false,
          );
        },
      );
      await tester.pump();
      expect(calls, 1);
      expect(find.text('línea 1'), findsOneWidget);
      expect(scheduled.single.$1, SubagentDetailScreen.tailFast);

      // Unchanged → interval grows towards the slow cap.
      var next = scheduled.removeLast();
      next.$2();
      await tester.pump();
      expect(calls, 2);
      expect(scheduled.single.$1, greaterThan(SubagentDetailScreen.tailFast));

      // New output → appended, back to fast.
      content = 'línea 1\nlínea 2';
      next = scheduled.removeLast();
      next.$2();
      await tester.pump();
      expect(find.text('línea 1\nlínea 2'), findsOneWidget);
      expect(scheduled.single.$1, SubagentDetailScreen.tailFast);

      // Covered by another route → no pending poll.
      final nav = tester.state<NavigatorState>(find.byType(Navigator));
      nav.push(MaterialPageRoute<void>(builder: (_) => const SizedBox()));
      await _settle(tester);
      expect(scheduled, isEmpty);
      final covered = calls;

      // Uncovered → resumes immediately.
      nav.pop();
      await _settle(tester);
      expect(calls, covered + 1);

      // App paused → stops; resumed → polls again.
      scheduled.clear();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(scheduled, isEmpty);
      final paused = calls;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump();
      expect(calls, paused + 1);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('live tail follows child events instead of waiting a poll', (
      tester,
    ) async {
      final scheduled = <(Duration, VoidCallback)>[];
      var calls = 0;
      var content = 'línea 1';
      Completer<SubagentTailView>? gate;
      final roster = await pumpDetail(
        tester,
        _nativeActivity(),
        scheduler: (delay, cb) {
          final entry = (delay, cb);
          scheduled.add(entry);
          return () => scheduled.remove(entry);
        },
        onTail: (_) {
          calls++;
          final pending = gate;
          if (pending != null) return pending.future;
          return Future.value(
            SubagentTailView(
              available: true,
              content: content,
              truncated: false,
            ),
          );
        },
      );
      await tester.pump();
      expect(calls, 1);
      // Back off to the slow cadence while nothing changes.
      for (var i = 0; i < 4; i++) {
        scheduled.removeLast().$2();
        await tester.pump();
      }
      expect(calls, 5);
      expect(scheduled.single.$1, SubagentDetailScreen.tailSlow);

      // A child event lands: the tail is read on that frame, not 5 s later.
      content = 'línea 1\nlínea 2';
      roster.value = [_nativeActivity(activeToolName: 'terminal')];
      await tester.pump();
      expect(calls, 6);
      expect(find.text('línea 1\nlínea 2'), findsOneWidget);
      expect(scheduled.single.$1, SubagentDetailScreen.tailFast);

      // A burst while a read is in flight coalesces into one follow-up read.
      gate = Completer<SubagentTailView>();
      roster.value = [_nativeActivity(activeToolName: 'read_file')];
      await tester.pump();
      expect(calls, 7);
      roster.value = [_nativeActivity(activeToolName: 'search_files')];
      await tester.pump();
      roster.value = [_nativeActivity(activeToolName: 'write_file')];
      await tester.pump();
      expect(calls, 7);
      final inFlight = gate;
      gate = null;
      content = 'línea 1\nlínea 2\nlínea 3';
      inFlight.complete(
        const SubagentTailView(
          available: true,
          content: 'línea 1\nlínea 2',
          truncated: false,
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(calls, 8);
      expect(find.text('línea 1\nlínea 2\nlínea 3'), findsOneWidget);
      expect(scheduled, hasLength(1));

      // A roster notification without a change to this child reads nothing.
      roster.value = List.of(roster.value);
      await tester.pump();
      expect(calls, 8);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('terminal child never polls the tail', (tester) async {
      var calls = 0;
      await pumpDetail(
        tester,
        _nativeActivity(phase: SubagentActivityPhase.completed),
        onTail: (_) async {
          calls++;
          return const SubagentTailView(
            available: true,
            content: 'x',
            truncated: false,
          );
        },
      );
      await tester.pump();
      expect(calls, 0);
      expect(find.byKey(const ValueKey('subagent-live-panel')), findsNothing);
    });

    testWidgets('tail transport failure keeps the last valid output', (
      tester,
    ) async {
      final scheduled = <VoidCallback>[];
      var calls = 0;
      await pumpDetail(
        tester,
        _nativeActivity(),
        scheduler: (_, cb) {
          scheduled.add(cb);
          return () => scheduled.remove(cb);
        },
        onTail: (_) {
          calls++;
          if (calls == 1) {
            return Future.value(
              const SubagentTailView(
                available: true,
                content: 'Última salida válida',
                truncated: false,
              ),
            );
          }
          return Future.error(StateError('transport'));
        },
      );
      await tester.pump();
      expect(find.text('Última salida válida'), findsOneWidget);
      scheduled.removeLast()();
      await tester.pump();
      expect(calls, 2);
      expect(find.text('Última salida válida'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('2x text at 390x844: no overflow, 48 dp targets', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);
      await pumpDetail(
        tester,
        _nativeActivity(goalPreview: 'verificación larga ' * 20),
        onStop: (_) async => true,
        onSteer: (_, _) async => const SubagentSteerView(status: 'queued'),
        textScaler: const TextScaler.linear(2),
      );
      expect(tester.takeException(), isNull);
      expect(
        tester
            .getSize(find.byKey(const ValueKey('subagent-detail-stop')))
            .height,
        greaterThanOrEqualTo(48),
      );
    });

    test('live tail model appends and caps memory', () {
      var tail = const SubagentLiveTail();
      tail = tail.apply(
        const SubagentTailView(
          available: true,
          content: 'a\nb',
          truncated: false,
        ),
      );
      expect(tail.lines, ['a', 'b']);
      final r = tail.revision;
      tail = tail.apply(
        const SubagentTailView(
          available: true,
          content: 'a\nb',
          truncated: false,
        ),
      );
      expect(tail.revision, r);
      tail = tail.apply(
        const SubagentTailView(
          available: true,
          content: 'a\nbc\nd',
          truncated: false,
        ),
      );
      expect(tail.lines, ['a', 'bc', 'd']);
      final big = List.generate(1000, (i) => 'l$i').join('\n');
      tail = tail.apply(
        SubagentTailView(available: true, content: big, truncated: false),
      );
      expect(tail.lines.length, SubagentLiveTail.maxLines);
      expect(tail.truncated, isTrue);
      expect(tail.lines.last, 'l999');
    });
  });

  testWidgets('English copy has no Spanish', (tester) async {
    final roster = ValueNotifier<List<SubagentActivity>>([_nativeActivity()]);
    addTearDown(roster.dispose);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: SubagentDetailScreen(
          roster: roster,
          activityKey: roster.value.single.key,
          parentTitle: '',
          canInterrupt: (_) => true,
          onStopRequested: (_) async => true,
          canSteer: (_) => true,
          onSteer: (_, _) async => const SubagentSteerView(status: 'queued'),
          routeObserver: RouteObserver<PageRoute<dynamic>>(),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Stop'), findsOneWidget);
    expect(find.text('GUIDE'), findsOneWidget);
    expect(find.text('Detener'), findsNothing);
    expect(find.text('GUIAR'), findsNothing);
  });

  testWidgets('transcript page names the missing Dashboard access of a '
      'named profile and retries on demand', (tester) async {
    var loads = 0;
    await tester.pumpWidget(
      _host(
        SubagentTranscriptPage(
          title: 'Child',
          load: () async {
            loads += 1;
            throw const ProfileTranscriptAccessRequired();
          },
        ),
      ),
    );
    await _settle(tester);

    expect(
      find.textContaining('El historial de este perfil no se puede cargar'),
      findsOneWidget,
    );
    expect(loads, 1);
    await tester.pump(const Duration(seconds: 30));
    expect(loads, 1, reason: 'no automatic retry');

    await tester.tap(find.text('Reintentar'));
    await _settle(tester);
    expect(loads, 2);
  });
}
