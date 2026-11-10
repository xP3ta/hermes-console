import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/models/subagent_activity.dart';
import 'package:hermes_android/core/screens/subagent_detail_screen.dart';
import 'package:hermes_android/core/services/subagent_live_watch.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/subagent_activity_card.dart';
import 'package:hermes_android/core/widgets/subagent_stream_view.dart'
    show SubagentTailToolRow;
import 'package:hermes_android/core/widgets/chat/chat_markdown_body.dart';
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
  String? summaryPreview,
  String goalPreview = 'Revisar el proyecto',
  String? detailPreview,
  String? activeToolName,
  String? activeToolPreview,
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
  details: SubagentActivityDetails(
    goalPreview: goalPreview,
    summaryPreview: summaryPreview,
    detailPreview: detailPreview,
    activeToolName: activeToolName,
    activeToolPreview: activeToolPreview,
  ),
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
    double textScale = 1,
    String tailText = 'cola sondeada',
    bool hideGoal = false,
    DateTime Function()? clock,
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
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
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
                      return SubagentTailView(
                        available: true,
                        content: tailText,
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
                    clock: clock ?? () => DateTime.utc(2026, 9, 27, 12),
                    routeObserver: observer,
                    hideGoal: hideGoal,
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

  testWidgets(
    'a long transcript stays anchored when the roster seals the watch',
    (tester) async {
      await pumpPage(tester);
      final paragraphs = List.generate(
        50,
        (i) => 'Bloque $i ${'palabra ' * 80}',
      ).join('\n\n');
      final text = 'Inicio conservado.\n\n$paragraphs';
      expect(text.length, greaterThan(SubagentLiveTail.maxChars));
      gateway.emit('watch-1', 'message.delta', {'text': text});
      await tester.pump();
      final first = find.byKey(const ValueKey('subagent-markdown-0-0'));
      final firstWidget = tester.widget<ChatMarkdownBody>(first);
      final panel = find.byKey(const ValueKey('subagent-live-panel'));
      await tester.drag(panel, const Offset(0, 300));
      await tester.pumpAndSettle();
      final controller = tester.widget<CustomScrollView>(panel).controller!;
      final height = controller.position.viewportDimension;
      final before = tester.getTopLeft(first).dy;
      // The last delta and roster close may arrive before the next frame.
      gateway.emit('watch-1', 'message.delta', {
        'text': '\n\nÚltimo texto antes de cerrar.',
      });
      roster.value = [_running(phase: SubagentActivityPhase.completed)];
      await tester.pump();
      expect(first, findsOneWidget);
      expect(tester.widget<ChatMarkdownBody>(first), same(firstWidget));
      expect(find.text('Último texto antes de cerrar.'), findsOneWidget);
      expect(controller.position.viewportDimension, height);
      expect(tester.getTopLeft(first).dy, closeTo(before, .01));
      expect(find.text('Terminado'), findsOneWidget);
      expect(gateway.closed, ['watch-1']);
    },
  );

  testWidgets(
    'a finished text stream does not invent a terminal roster state',
    (tester) async {
      await pumpPage(tester);
      gateway.emit('watch-1', 'message.delta', {'text': 'Texto recibido'});
      gateway.emit('watch-1', 'message.complete', {'text': 'Texto recibido'});
      await tester.pump();
      expect(find.textContaining('Trabajando'), findsOneWidget);
      expect(find.text('Terminado'), findsNothing);
      roster.value = [_running(phase: SubagentActivityPhase.completed)];
      await tester.pump();
      expect(find.text('Terminado'), findsOneWidget);
    },
  );

  testWidgets('live output is integrated in the detail without a composer', (
    tester,
  ) async {
    await pumpPage(tester);
    gateway.emit('watch-1', 'message.delta', {'text': 'hola'});
    await tester.pump();
    expect(find.byKey(const ValueKey('subagent-live-panel')), findsOneWidget);
    expect(find.text('hola'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets(
    'stream follows in layout, pauses on drag, preserves position, and resumes at bottom',
    (tester) async {
      await pumpPage(tester);
      gateway.emit('watch-1', 'message.delta', {
        'text': List.generate(80, (i) => 'Línea $i.').join('\n\n'),
      });
      await tester.pump();
      final panel = find.byKey(const ValueKey('subagent-live-panel'));
      final controller = tester.widget<CustomScrollView>(panel).controller!;
      expect(controller.position.pixels, controller.position.maxScrollExtent);
      var screenBuilds = 0;
      debugOnRebuildDirtyWidget = (element, _) {
        if (element.widget is SubagentDetailScreen) screenBuilds++;
      };
      addTearDown(() => debugOnRebuildDirtyWidget = null);
      for (var i = 0; i < 5; i++) {
        gateway.emit('watch-1', 'message.delta', {
          'text': '\n\nNueva línea $i.',
        });
        await tester.pump();
        expect(controller.position.pixels, controller.position.maxScrollExtent);
      }
      await tester.drag(panel, const Offset(0, 300));
      await tester.pumpAndSettle();
      final before = controller.offset;
      final textBefore = tester
          .getTopLeft(find.byKey(const ValueKey('subagent-text-0')))
          .dy;
      gateway.emit('watch-1', 'message.delta', {
        'text': '\n\nOtra línea mientras lee.',
      });
      await tester.pump();
      expect(controller.offset, closeTo(before, .01));
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('subagent-text-0'))).dy,
        closeTo(textBefore, .01),
      );
      expect(screenBuilds, 0);
      expect(
        find.byKey(const ValueKey('subagent-live-follow')),
        findsOneWidget,
      );
      await tester.drag(panel, const Offset(0, -10000));
      await tester.pumpAndSettle();
      expect(controller.position.pixels, controller.position.maxScrollExtent);
      expect(find.byKey(const ValueKey('subagent-live-follow')), findsNothing);
      gateway.emit('watch-1', 'message.delta', {'text': '\n\nSigue al fondo.'});
      await tester.pump();
      expect(controller.position.pixels, controller.position.maxScrollExtent);
    },
  );

  testWidgets('folded prompt and stable live tool row settle immediately', (
    tester,
  ) async {
    await pumpPage(tester);
    final prompt = find.byKey(const ValueKey('subagent-prompt-toggle'));
    expect(prompt, findsOneWidget);
    await tester.tap(prompt);
    await tester.pump();
    gateway.emit('watch-1', 'message.delta', {'text': 'Reviso.'});
    gateway.emit('watch-1', 'tool.start', {
      'name': 'git',
      'tool_call_id': 'git-1',
    });
    await tester.pump();
    final row = find.byKey(const ValueKey('subagent-stream-tool-git-1'));
    final element = tester.element(row);
    expect(find.text('Ejecutando git'), findsOneWidget);
    gateway.emit('watch-1', 'tool.start', {
      'name': 'git',
      'tool_call_id': 'git-1',
    });
    await tester.pump();
    expect(row, findsOneWidget);
    gateway.emit('watch-1', 'tool.complete', {
      'name': 'git',
      'tool_call_id': 'git-1',
    });
    await tester.pump();
    expect(tester.element(row), same(element));
    expect(find.text('git · Terminado'), findsOneWidget);
    roster.value = [_running(phase: SubagentActivityPhase.completed)];
    await tester.pump();
    expect(find.text('Terminado'), findsOneWidget);
    expect(find.textContaining('Trabajando'), findsNothing);
    expect(gateway.closed, ['watch-1']);
  });

  testWidgets(
    'ordinary taps keep following and closed Markdown never rebuilds per delta',
    (tester) async {
      await pumpPage(tester);
      gateway.emit('watch-1', 'message.delta', {
        'text': 'Párrafo cerrado.\n\nAbierto',
      });
      await tester.pump();
      final first = find.byKey(const ValueKey('subagent-markdown-0-0'));
      final widget = tester.widget<ChatMarkdownBody>(first);
      var closedBuilds = 0;
      debugOnRebuildDirtyWidget = (element, _) {
        if (identical(element.widget, widget)) closedBuilds++;
      };
      addTearDown(() => debugOnRebuildDirtyWidget = null);
      await tester.tap(find.text('Abierto'));
      await tester.pump();
      expect(find.byKey(const ValueKey('subagent-live-follow')), findsNothing);
      for (var i = 0; i < 10; i++) {
        gateway.emit('watch-1', 'message.delta', {'text': ' token'});
        await tester.pump();
        expect(tester.widget<ChatMarkdownBody>(first), same(widget));
      }
      expect(closedBuilds, 0);
      expect(find.text('Abierto${' token' * 10}'), findsOneWidget);
    },
  );

  testWidgets(
    'tool identities survive the 100-row window; public markers stay prose',
    (tester) async {
      await pumpPage(tester);
      gateway.emit('watch-1', 'message.delta', {
        'text': '› Esto es texto público\n',
      });
      for (var i = 0; i < 105; i++) {
        gateway.emit('watch-1', 'tool.start', {
          'name': 'git-$i',
          'tool_id': 'id-$i',
        });
        gateway.emit('watch-1', 'tool.complete', {
          'tool_id': 'id-$i',
          'status': i.isEven ? 'failed' : 'ok',
        });
      }
      await tester.pump();
      expect(find.text('› Esto es texto público'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('subagent-stream-tool-id-0')),
        findsNothing,
      );
      for (var i = 5; i < 105; i++) {
        expect(
          find.byKey(ValueKey('subagent-stream-tool-id-$i')),
          findsOneWidget,
        );
        expect(
          find.text('git-$i · ${i.isEven ? 'Falló' : 'Terminado'}'),
          findsOneWidget,
        );
      }
      expect(find.textContaining('Ejecutando'), findsNothing);
    },
  );

  testWidgets(
    'polling after a refused reconnect clears stale live status and tool rows',
    (tester) async {
      await pumpPage(tester);
      gateway.emit('watch-1', 'tool.start', {
        'name': 'git',
        'tool_id': 'stale',
      });
      await tester.pump();
      final gate = Completer<DesktopSessionSnapshot>();
      gateway.answer = (_) => gate.future;
      gateway.drop();
      await tester.pump();
      expect(find.text('Sin confirmar'), findsWidgets);
      gate.completeError(StateError('resume unavailable'));
      await tester.pump();
      await tester.pump();
      expect(tailCalls, greaterThan(0));
      expect(scheduled, isNotEmpty);
      expect(find.text('cola sondeada'), findsOneWidget);
      expect(find.text('Sin confirmar'), findsNothing);
      expect(
        find.byKey(const ValueKey('subagent-stream-tool-stale')),
        findsNothing,
      );
      expect(find.textContaining('Trabajando'), findsOneWidget);
    },
  );

  testWidgets('live prompt, text and tools fit at 320dp and 2x text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pumpPage(tester, textScale: 2);
    gateway.emit('watch-1', 'message.delta', {
      'text': 'Streaming legible. ' * 20,
    });
    gateway.emit('watch-1', 'tool.start', {
      'name': 'git',
      'tool_call_id': 'git-large',
    });
    await tester.pump();
    expect(find.text('Ejecutando git'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'terminal detail renders the roster result without opening a watch',
    (tester) async {
      await pumpPage(
        tester,
        activity: _running(
          phase: SubagentActivityPhase.failed,
          summaryPreview: 'Resultado final recibido',
        ),
      );
      expect(find.text('Resultado final recibido'), findsOneWidget);
      expect(find.text('Falló'), findsOneWidget);
      expect(find.text('Esperando actividad…'), findsNothing);
      expect(gateway.resumes, isEmpty);
    },
  );

  testWidgets('polled public markers do not invent executing tools', (
    tester,
  ) async {
    gateway.answer = (_) => Future.error(StateError('Method not found'));
    await pumpPage(tester, tailText: '› git\nTexto del agente');
    expect(
      tester.widget<ChatMarkdownBody>(find.byType(ChatMarkdownBody)).data,
      '› git\nTexto del agente',
    );
    expect(find.textContaining('Ejecutando'), findsNothing);
    expect(
      find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith(
              'subagent-stream-tool-',
            ),
      ),
      findsNothing,
    );
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
    'a roster that ends the child while the resume is in flight leaks nothing',
    (tester) async {
      final pending = Completer<DesktopSessionSnapshot>();
      gateway.answer = (_) => pending.future;
      await pumpPage(tester);
      expect(gateway.resumes, hasLength(1));

      roster.value = [_running(phase: SubagentActivityPhase.completed)];
      await tester.pump();
      pending.complete(watchTestSnapshot('watch-1'));
      await tester.pump();
      await tester.pump();

      expect(gateway.closed, ['watch-1']);
      expect(gateway.retained, isEmpty);
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

  testWidgets(
    'covering a reconnect clears its view while the replacement watch opens',
    (tester) async {
      await pumpPage(tester);
      final stale = Completer<DesktopSessionSnapshot>();
      gateway.answer = (_) => stale.future;
      gateway.drop();
      await tester.pump();
      expect(find.text('Sin confirmar'), findsWidgets);
      final nav = tester.state<NavigatorState>(find.byType(Navigator));
      nav.push(MaterialPageRoute<void>(builder: (_) => const SizedBox()));
      await tester.pumpAndSettle();
      final fresh = Completer<DesktopSessionSnapshot>();
      gateway.answer = (_) => fresh.future;
      nav.pop();
      await tester.pumpAndSettle();
      expect(gateway.resumes, hasLength(3));
      expect(find.text('Sin confirmar'), findsNothing);
      stale.complete(watchTestSnapshot('watch-2'));
      fresh.complete(watchTestSnapshot('watch-3'));
      await tester.pump();
      expect(gateway.closed, ['watch-2']);
      expect(gateway.retained, ['watch-1', 'watch-3']);
    },
  );

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
    expect(find.text('Sin confirmar'), findsWidgets);

    gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('Sin confirmar'), findsNothing);
    expect(gateway.resumes, hasLength(2));
  });

  testWidgets(
    'a watch opened while a command already ran stays quiet: the polled log '
    'fills the page as rows until the watch speaks',
    (tester) async {
      await pumpPage(
        tester,
        tailText:
            '16:48:58 tool     | -> terminal(echo hola)\n'
            '16:48:58 result   | terminal ok 0.1s: {"output": "hola", "exit_code": 0, "error": null}\n'
            '16:49:00 tool     | -> terminal(for i in 1 2 3 4 5 6 + 3 comandos)',
      );
      expect(gateway.resumes, hasLength(1));
      expect(tailCalls, 0);
      final grace = scheduled.single;
      expect(grace.$1, SubagentDetailScreen.watchQuietGrace);

      // The grace elapses with the watch still quiet: the log is read.
      scheduled.remove(grace);
      grace.$2();
      await tester.pump();
      await tester.pump();
      expect(tailCalls, 1);
      expect(find.byType(SubagentTailToolRow), findsNWidgets(2));
      expect(find.text('hola'), findsOneWidget);
      expect(find.text('for i in 1 2 3 4 5 6 + 3 comandos'), findsOneWidget);
      expect(find.text('ok · 0,1 s'), findsOneWidget);
      // And keeps being read while the watch stays quiet.
      expect(scheduled, hasLength(1));

      // The watch speaks: it is the source again and the reads stop.
      gateway.emit('watch-1', 'message.delta', {'text': 'paso 1 … paso 6'});
      await tester.pump();
      expect(scheduled, isEmpty);
      expect(find.textContaining('paso 1 … paso 6'), findsOneWidget);
      expect(find.byType(SubagentTailToolRow), findsNothing);
    },
  );

  testWidgets('without a watch opener the polled tail works as before', (
    tester,
  ) async {
    await pumpPage(tester, withWatch: false);

    expect(gateway.resumes, isEmpty);
    expect(tailCalls, 1);
    expect(find.text('cola sondeada'), findsOneWidget);
  });

  // The sequence `tui_gateway.agent_callbacks._mirror_subagent_to_child`
  // emits for a child that runs one slow shell command and then answers
  // (tests/tui_gateway/test_subagent_child_mirror.py): the goal as a first
  // delta, `tool.start` with the command as `preview`, and no
  // `tool.complete` until the next tool or the end.
  const command = r'for i in 1 2 3 4 5 6; do echo paso $i; sleep 5; done';

  void replayStart(FakeWatchGateway gateway) {
    gateway.emit('watch-1', 'message.start');
    gateway.emit('watch-1', 'message.delta', {
      'text': 'Ejecuta el bucle y dime el resultado\n',
    });
    gateway.emit('watch-1', 'tool.start', {
      'name': 'terminal',
      'tool_id': 'submirror:$watchTestChild:1',
      'args': <String, dynamic>{},
      'preview': command,
    });
  }

  Finder toolRow() =>
      find.byKey(const ValueKey('subagent-stream-tool-submirror:child-stored-1:1'));

  testWidgets(
    'a running command shows its name, its command line to the owner and '
    'its clock, and settles when the child writes again',
    (tester) async {
      var now = DateTime.utc(2026, 9, 27, 12);
      await pumpPage(tester, clock: () => now);
      replayStart(gateway);
      await tester.pump();

      expect(find.text('Ejecutando terminal'), findsOneWidget);
      expect(find.text(command), findsOneWidget);
      expect(find.text('0:00'), findsOneWidget);

      now = now.add(const Duration(seconds: 12));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('0:12'), findsOneWidget);

      // The child answers: its tool is done although the mirror never said
      // so.
      gateway.emit('watch-1', 'message.delta', {'text': 'paso 1 … paso 6'});
      await tester.pump();
      expect(find.text('terminal · Terminado'), findsOneWidget);
      expect(find.text('Ejecutando terminal'), findsNothing);
      // The live stream keeps what each tool ran.
      expect(find.text(command), findsOneWidget);
      expect(find.text('0:12'), findsNothing);
      expect(find.textContaining('paso 1 … paso 6'), findsOneWidget);

      gateway.emit('watch-1', 'message.complete', {'text': 'paso 1 … paso 6'});
      await tester.pump();
      expect(tailCalls, 0);
    },
  );

  testWidgets('the owner sees a file, a URL and a command line, never a '
      'secret in them', (tester) async {
    await pumpPage(tester);
    gateway.emit('watch-1', 'message.start');
    gateway.emit('watch-1', 'tool.start', {
      'name': 'read_file',
      'tool_id': 'submirror:$watchTestChild:1',
      'args': <String, dynamic>{},
      'preview': '/srv/relay/rollback.md',
    });
    gateway.emit('watch-1', 'tool.start', {
      'name': 'web_fetch',
      'tool_id': 'submirror:$watchTestChild:2',
      'args': <String, dynamic>{},
      'preview': 'https://user:pw@example.com/a/b?token=SECRETO',
    });
    gateway.emit('watch-1', 'tool.start', {
      'name': 'terminal',
      'tool_id': 'submirror:$watchTestChild:3',
      'args': <String, dynamic>{},
      'preview': 'curl -H "Authorization: Bearer SECRETO" https://api.x.dev',
    });
    gateway.emit('watch-1', 'tool.start', {
      'name': 'terminal',
      'tool_id': 'submirror:$watchTestChild:4',
      'args': <String, dynamic>{},
      'preview':
          'deploy --token abc123secret API_KEY=sk-SECRETOabcdef '
          'https://user:pass@api.example.com/v1?token=SECRETO',
    });
    await tester.pump();
    expect(find.text('/srv/relay/rollback.md'), findsOneWidget);
    expect(
      find.text('https://•••@example.com/a/b?token=•••'),
      findsOneWidget,
    );
    expect(
      find.text('curl -H "Authorization: Bearer •••" https://api.x.dev'),
      findsOneWidget,
    );
    expect(
      find.text(
        'deploy --token ••• API_KEY=••• https://•••@api.example.com/v1?token=•••',
      ),
      findsOneWidget,
    );
    for (final secret in ['SECRETO', 'pw@', 'pass@', 'abc123secret', 'sk-']) {
      expect(find.textContaining(secret), findsNothing, reason: secret);
    }
  });

  testWidgets('another opener sees the tool name but never its command', (
    tester,
  ) async {
    await pumpPage(tester, hideGoal: true);
    replayStart(gateway);
    await tester.pump();
    expect(find.text('Ejecutando terminal'), findsOneWidget);
    expect(find.text(command), findsNothing);
    expect(find.textContaining('paso'), findsNothing);
  });

  testWidgets(
    'a short stream reads from the top, cannot be scrolled away and keeps '
    'its last row on screen',
    (tester) async {
      await pumpPage(tester);
      replayStart(gateway);
      await tester.pump();
      final panel = find.byKey(const ValueKey('subagent-live-panel'));
      final controller = tester.widget<CustomScrollView>(panel).controller!;
      // Before: a reversed list with its center at the bottom had a scroll
      // range as tall as the content, so one drag pushed the rows under the
      // bottom edge and left a gap above them.
      expect(controller.position.minScrollExtent, 0);
      expect(controller.position.maxScrollExtent, 0);
      final top = tester.getTopLeft(panel).dy;
      expect(
        tester
                .getTopLeft(
                  find.byKey(const ValueKey('subagent-prompt-toggle')),
                )
                .dy -
            top,
        lessThan(40),
      );
      await tester.drag(panel, const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(controller.position.pixels, 0);
      expect(
        tester.getBottomLeft(toolRow()).dy,
        lessThanOrEqualTo(tester.getBottomLeft(panel).dy),
      );
      expect(find.byKey(const ValueKey('subagent-live-follow')), findsNothing);
    },
  );

  testWidgets(
    'a long stream keeps its newest row above the footer, also with the '
    'keyboard up',
    (tester) async {
      await pumpPage(tester);
      gateway.emit('watch-1', 'message.delta', {
        'text': List.generate(60, (i) => 'Línea $i.').join('\n\n'),
      });
      replayStart(gateway);
      await tester.pump();
      final panel = find.byKey(const ValueKey('subagent-live-panel'));
      final controller = tester.widget<CustomScrollView>(panel).controller!;
      expect(controller.position.maxScrollExtent, greaterThan(0));
      expect(controller.position.pixels, controller.position.maxScrollExtent);
      expect(
        tester.getBottomLeft(toolRow()).dy,
        lessThanOrEqualTo(tester.getBottomLeft(panel).dy),
      );

      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      await tester.pump();
      await tester.pump();
      expect(controller.position.pixels, controller.position.maxScrollExtent);
      expect(
        tester.getBottomLeft(toolRow()).dy,
        lessThanOrEqualTo(tester.getBottomLeft(panel).dy),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a sealed stream adds no live activity line',
    (tester) async {
      await pumpPage(
        tester,
        activity: _running(
          phase: SubagentActivityPhase.thinking,
          detailPreview: 'Comparo las dos salidas antes de responder.',
        ),
      );
      gateway.emit('watch-1', 'message.delta', {'text': 'Empiezo.'});
      gateway.emit('watch-1', 'message.complete', {'text': ''});
      await tester.pump();
      // A sealed stream is not a live one: nothing to add.
      expect(find.byKey(const ValueKey('subagent-stream-activity')), findsNothing);
    },
  );

  testWidgets('a thinking child says so at the end of its stream', (
    tester,
  ) async {
    await pumpPage(
      tester,
      activity: _running(
        phase: SubagentActivityPhase.thinking,
        detailPreview: 'Comparo las dos salidas antes de responder.',
      ),
    );
    final activity = find.byKey(const ValueKey('subagent-stream-activity'));
    expect(activity, findsOneWidget);
    expect(find.text('Pensando el siguiente paso'), findsOneWidget);
    expect(
      find.text('Comparo las dos salidas antes de responder.'),
      findsOneWidget,
    );
    expect(find.text('Esperando salida…'), findsNothing);

    // A running tool row already says what it does.
    replayStart(gateway);
    await tester.pump();
    expect(activity, findsNothing);
    // The child thinks again (its reasoning stays private).
    gateway.emit('watch-1', 'reasoning.delta', {'text': 'secreto'});
    await tester.pump();
    expect(find.text('terminal · Terminado'), findsOneWidget);
    expect(activity, findsOneWidget);
    expect(find.textContaining('secreto'), findsNothing);
  });

  testWidgets('another opener gets the roster state but not the thought', (
    tester,
  ) async {
    await pumpPage(
      tester,
      hideGoal: true,
      activity: _running(
        phase: SubagentActivityPhase.tool,
        activeToolName: 'terminal',
        activeToolPreview: 'ls -la',
      ),
    );
    expect(find.text('Usando terminal'), findsOneWidget);
    expect(find.text('ls -la'), findsNothing);
  });

  testWidgets('opened while a file is read: the roster shows its path', (
    tester,
  ) async {
    await pumpPage(
      tester,
      activity: _running(
        phase: SubagentActivityPhase.tool,
        activeToolName: 'read_file',
        activeToolPreview: '/srv/relay/notas.md',
      ),
    );
    expect(find.text('/srv/relay/notas.md'), findsOneWidget);
  });

  testWidgets(
    'opened while a command already runs: the roster names it and its '
    'command until the stream shows its own row',
    (tester) async {
      await pumpPage(
        tester,
        activity: _running(
          phase: SubagentActivityPhase.tool,
          activeToolName: 'terminal',
          activeToolPreview: command,
        ),
      );
      final activity = find.byKey(const ValueKey('subagent-stream-activity'));
      expect(activity, findsOneWidget);
      expect(find.text('Usando terminal'), findsOneWidget);
      expect(find.text(command), findsOneWidget, reason: 'its command line');

      replayStart(gateway);
      await tester.pump();
      expect(activity, findsNothing);
      expect(find.text('Ejecutando terminal'), findsOneWidget);
      // Once, on its own row.
      expect(find.text(command), findsOneWidget);
    },
  );
}
