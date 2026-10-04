import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/subagent_activity.dart';
import 'package:hermes_android/core/screens/subagent_detail_screen.dart';
import 'package:hermes_android/core/services/subagent_live_watch.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/subagent_activity_card.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'support/fake_subagent_watch_gateway.dart';
import 'support/inter_font.dart';

final SubagentActivityScope _scope = SubagentActivityScope(
  connectionId: 'connection-watch',
  parentSessionId: 'parent-watch',
  runtimeSessionId: 'runtime-watch',
  turnEpoch: 1,
);

SubagentActivity _running({
  SubagentActivityPhase phase = SubagentActivityPhase.running,
}) => SubagentActivity(
  key: SubagentActivityKey(
    scope: _scope,
    identityKind: SubagentIdentityKind.subagent,
    stableId: 'sa-watch',
  ),
  source: SubagentActivitySource.native,
  phase: phase,
  subagentId: 'sa-watch',
  childSessionId: watchTestChild,
  details: const SubagentActivityDetails(goalPreview: 'Revisar el proyecto'),
);

void main() {
  setUpAll(loadInterFont);

  late FakeWatchGateway gateway;
  late int tailCalls;
  late List<(Duration, VoidCallback)> scheduled;
  late ValueNotifier<List<SubagentActivity>> roster;
  late RouteObserver<PageRoute<dynamic>> observer;

  setUp(() {
    gateway = FakeWatchGateway();
    tailCalls = 0;
    scheduled = [];
    observer = RouteObserver<PageRoute<dynamic>>();
  });

  Future<void> pumpPage(
    WidgetTester tester, {
    bool withWatch = true,
    SubagentActivity? activity,
  }) async {
    final subject = activity ?? _running();
    roster = ValueNotifier<List<SubagentActivity>>([subject]);
    addTearDown(roster.dispose);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        navigatorObservers: [observer],
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              key: const ValueKey('open-detail'),
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => SubagentDetailScreen(
                    roster: roster,
                    activityKey: subject.key,
                    parentTitle: 'Chat de prueba',
                    canTail: (_) => true,
                    onTail: (_) async {
                      tailCalls++;
                      return const SubagentTailView(
                        available: true,
                        content: 'cola sondeada',
                        truncated: false,
                      );
                    },
                    scheduleTailPoll: (delay, callback) {
                      final entry = (delay, callback);
                      scheduled.add(entry);
                      return () => scheduled.remove(entry);
                    },
                    openLiveWatch: withWatch
                        ? (_) => SubagentLiveWatch(
                            gateway: gateway,
                            childSessionId: watchTestChild,
                            profile: 'parent-profile',
                            isCurrent: () => true,
                            childIsLive: () =>
                                subagentIsLive(roster.value.single),
                          )
                        : null,
                    clock: () => DateTime.utc(2026, 9, 27, 12),
                    routeObserver: observer,
                  ),
                ),
              ),
              child: const Text('abrir'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open-detail')));
    await tester.pumpAndSettle();
  }

  testWidgets('shows the child text as it grows without polling the tail', (
    tester,
  ) async {
    await pumpPage(tester);
    expect(gateway.resumes, hasLength(1));

    gateway.emit('watch-1', 'message.delta', {'text': 'Leyendo '});
    gateway.emit('watch-1', 'message.delta', {'text': 'ficheros'});
    await tester.pump();

    expect(find.text('Leyendo ficheros'), findsOneWidget);
    expect(tailCalls, 0, reason: 'a live watch replaces the polled tail');
    expect(scheduled, isEmpty);
  });

  testWidgets('the full-screen live page has no composer', (tester) async {
    await pumpPage(tester);
    gateway.emit('watch-1', 'message.delta', {'text': 'hola'});
    await tester.pump();

    await tester.ensureVisible(
      find.byKey(const ValueKey('subagent-live-panel')),
    );
    await tester.tap(find.text('Pantalla completa'));
    await tester.pumpAndSettle();

    expect(find.byType(SubagentLiveLogPage), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(EditableText), findsNothing);
  });

  testWidgets('falls back to the polled tail when the resume is refused', (
    tester,
  ) async {
    gateway.answer = (_) => Future.error(StateError('Method not found'));
    await pumpPage(tester);

    expect(gateway.closed, isEmpty);
    expect(tailCalls, greaterThanOrEqualTo(1));
    expect(find.text('cola sondeada'), findsOneWidget);
  });

  testWidgets(
    'leaving the page closes the watch once and ignores late events',
    (tester) async {
      await pumpPage(tester);
      gateway.emit('watch-1', 'message.delta', {'text': 'antes'});
      await tester.pump();

      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pumpAndSettle();
      gateway.emit('watch-1', 'message.delta', {'text': 'tarde'});
      gateway.emit('watch-1', 'message.complete', {'text': 'tarde'});
      await tester.pump();

      expect(gateway.closed, ['watch-1']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a roster that ends the child closes the watch without message.complete',
    (tester) async {
      await pumpPage(tester);
      gateway.emit('watch-1', 'message.delta', {'text': 'trabajando'});
      await tester.pump();
      expect(gateway.closed, isEmpty);

      roster.value = [_running(phase: SubagentActivityPhase.completed)];
      await tester.pump();

      expect(gateway.closed, ['watch-1']);
      expect(gateway.released, ['watch-1']);
      // And nothing late repaints or throws.
      gateway.emit('watch-1', 'message.delta', {'text': 'tarde'});
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a child that is not terminal keeps its watch across roster updates',
    (tester) async {
      await pumpPage(tester);

      roster.value = [_running(phase: SubagentActivityPhase.tool)];
      await tester.pump();
      roster.value = [_running(phase: SubagentActivityPhase.thinking)];
      await tester.pump();

      expect(gateway.closed, isEmpty);
      expect(gateway.resumes, hasLength(1));
    },
  );

  testWidgets('a covered page releases the watch and reopens it when visible', (
    tester,
  ) async {
    await pumpPage(tester);
    expect(gateway.resumes, hasLength(1));

    final nav = tester.state<NavigatorState>(find.byType(Navigator));
    nav.push(MaterialPageRoute<void>(builder: (_) => const SizedBox()));
    await tester.pumpAndSettle();
    expect(gateway.closed, ['watch-1'], reason: 'no work while covered');

    nav.pop();
    await tester.pumpAndSettle();
    expect(gateway.resumes, hasLength(2));
    expect(gateway.retained, ['watch-1', 'watch-2']);
  });

  testWidgets('says so while the connection is lost and resumes by itself', (
    tester,
  ) async {
    await pumpPage(tester);
    final gate = Completer<void>();
    final original = gateway.answer;
    gateway.answer = (runtime) async {
      await gate.future;
      return original?.call(runtime) ?? watchTestSnapshot(runtime);
    };

    gateway.drop();
    await tester.pump();
    expect(find.text('Conexión perdida — reconectando…'), findsOneWidget);

    gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('Conexión perdida — reconectando…'), findsNothing);
    expect(gateway.resumes, hasLength(2));
  });

  testWidgets('without a watch opener the polled tail works as before', (
    tester,
  ) async {
    await pumpPage(tester, withWatch: false);

    expect(gateway.resumes, isEmpty);
    expect(tailCalls, 1);
    expect(find.text('cola sondeada'), findsOneWidget);
  });
}
