import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/subagent_activity.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/accent_card.dart';
import 'package:hermes_android/core/widgets/hermes_premium_ui.dart';
import 'package:hermes_android/core/widgets/subagent_activity_card.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

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

Widget _app({
  required List<SubagentActivity> activities,
  required bool Function(SubagentActivity) canInterrupt,
  bool Function(SubagentActivity)? canSteer,
  bool Function(SubagentActivity)? interruptPending,
  bool Function(SubagentActivity)? openPending,
  ValueChanged<SubagentActivity>? onOpen,
  ValueChanged<SubagentActivity>? onInterrupt,
  SubagentStopRequester? onStopRequested,
  SubagentSteerSender? onSteer,
  TextScaler textScaler = TextScaler.noScaling,
  DateTime? now,
}) => MaterialApp(
  locale: const Locale('es'),
  localizationsDelegates: const [
    Strings.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: Strings.supportedLocales,
  home: Scaffold(
    body: MediaQuery(
      data: MediaQueryData(size: const Size(390, 844), textScaler: textScaler),
      child: SingleChildScrollView(
        child: SubagentActivityCard(
          activities: activities,
          canInterrupt: canInterrupt,
          canSteer: canSteer,
          isInterruptPending: interruptPending,
          isOpenPending: openPending,
          onOpenConversation: onOpen,
          onInterrupt: onInterrupt,
          onStopRequested: onStopRequested,
          onSteer: onSteer,
          now: now,
        ),
      ),
    ),
  ),
);

Widget _chatLikeApp({
  required List<SubagentActivity> activities,
  TextScaler textScaler = TextScaler.noScaling,
}) => MaterialApp(
  locale: const Locale('es'),
  localizationsDelegates: const [
    Strings.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: Strings.supportedLocales,
  home: Scaffold(
    resizeToAvoidBottomInset: true,
    body: MediaQuery(
      data: MediaQueryData.fromView(
        WidgetsBinding.instance.platformDispatcher.views.single,
      ).copyWith(textScaler: textScaler),
      child: Column(
        children: [
          const Expanded(child: SizedBox.expand()),
          SubagentActivityCard(
            activities: activities,
            canInterrupt: (_) => true,
            onOpenConversation: (_) {},
            onInterrupt: (_) {},
          ),
          const SizedBox(height: 72),
        ],
      ),
    ),
  ),
);

void main() {
  testWidgets(
    'calm status exposes generic identity and authoritative safe facts only',
    (tester) async {
      await tester.pumpWidget(
        _app(
          activities: [
            _nativeActivity(
              phase: SubagentActivityPhase.tool,
              activeToolName: 'terminal',
              durationSeconds: 252,
              progress: const SubagentTaskProgress(taskIndex: 7, taskCount: 10),
              detailPreview: 'PRIVATE_REASONING',
              activeToolPreview: 'PRIVATE_TOOL_INPUT',
              summaryPreview: 'PRIVATE_RESULT',
            ),
          ],
          canInterrupt: (_) => false,
        ),
      );

      expect(find.text('Subagentes'), findsOneWidget);
      expect(find.textContaining('usando herramienta'), findsOneWidget);
      expect(find.textContaining('04:12'), findsOneWidget);
      expect(find.textContaining('terminal'), findsNothing);
      expect(find.textContaining('Revisar el proyecto'), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.textContaining('Tarea 7 de 10'), findsNothing);
      expect(find.textContaining('PRIVATE_REASONING'), findsNothing);
      expect(find.textContaining('PRIVATE_TOOL_INPUT'), findsNothing);
      expect(find.textContaining('PRIVATE_RESULT'), findsNothing);
    },
  );

  testWidgets(
    'failed work keeps generic identity and exposes an error signal',
    (tester) async {
      await tester.pumpWidget(
        _app(
          activities: [
            _nativeActivity(
              goalPreview: 'Verificar recuperación',
              phase: SubagentActivityPhase.failed,
              durationSeconds: 127,
            ),
          ],
          canInterrupt: (_) => false,
        ),
      );

      expect(find.text('Subagentes'), findsOneWidget);
      expect(find.text('Verificar recuperación'), findsNothing);
      expect(find.textContaining('falló'), findsOneWidget);
      expect(find.textContaining('02:07'), findsOneWidget);
      final icon = tester.widget<Icon>(
        find.byIcon(Icons.account_tree_outlined),
      );
      final colors = Theme.of(
        tester.element(find.byType(SubagentActivityCard)),
      ).hermes;
      expect(icon.color, colors.error);
    },
  );

  testWidgets('active status derives age only from authoritative start time', (
    tester,
  ) async {
    final now = DateTime.utc(2026, 9, 7, 15);
    final activity = SubagentActivity(
      key: SubagentActivityKey(
        scope: _scope,
        identityKind: SubagentIdentityKind.subagent,
        stableId: 'age-child',
      ),
      source: SubagentActivitySource.native,
      phase: SubagentActivityPhase.running,
      subagentId: 'age-child',
      details: SubagentActivityDetails(
        goalPreview: 'Comprobar antigüedad',
        startedAt: now.subtract(const Duration(seconds: 65)),
      ),
    );

    await tester.pumpWidget(
      _app(activities: [activity], canInterrupt: (_) => false, now: now),
    );

    expect(find.textContaining('01:05'), findsOneWidget);
  });

  testWidgets('expanded detail never publishes private activity metadata', (
    tester,
  ) async {
    final result = 'Resultado seguro ${'x' * 300} PRIVATE_TAIL';
    await tester.pumpWidget(
      _app(
        activities: [
          _nativeActivity(
            model: 'PRIVATE_MODEL',
            activeToolName: 'PRIVATE_TOOL_NAME',
            activeToolPreview: 'PRIVATE_TOOL_DETAILS',
            detailPreview: 'PRIVATE_REASONING',
            toolCount: 7,
            apiCalls: 5,
            filesReadCount: 3,
            filesWrittenCount: 2,
            progress: const SubagentTaskProgress(taskIndex: 7, taskCount: 10),
            summaryPreview: result,
          ),
        ],
        canInterrupt: (_) => false,
      ),
    );

    for (final privateText in [
      'PRIVATE_MODEL',
      'PRIVATE_TOOL_NAME',
      'PRIVATE_TOOL_DETAILS',
      'PRIVATE_REASONING',
      '7 herramientas',
      '5 llamadas',
      '3 leídos',
      '2 escritos',
      'Tarea 7 de 10',
      'Resultado seguro',
      'PRIVATE_TAIL',
    ]) {
      expect(find.textContaining(privateText), findsNothing);
    }

    await tester.tap(find.text('ver detalles'));
    await tester.pumpAndSettle();

    for (final privateText in [
      'PRIVATE_MODEL',
      'PRIVATE_TOOL_NAME',
      'PRIVATE_TOOL_DETAILS',
      'PRIVATE_REASONING',
      '7 herramientas',
      '5 llamadas',
      '3 leídos',
      '2 escritos',
      'Tarea 7 de 10',
      'Resultado seguro',
      'PRIVATE_TAIL',
    ]) {
      expect(find.textContaining(privateText), findsNothing);
    }
  });

  testWidgets('missing fields never invent a child name or destination', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        activities: [
          _nativeActivity(
            subagentId: 'opaque-private-id',
            childSessionId: null,
            goalPreview: '',
            phase: SubagentActivityPhase.unknown,
          ),
        ],
        canInterrupt: (_) => false,
        onOpen: (_) {},
      ),
    );

    expect(find.text('Subagentes'), findsOneWidget);
    expect(find.textContaining('estado desconocido'), findsOneWidget);
    expect(find.textContaining('opaque-private-id'), findsNothing);
    await tester.tap(find.text('ver detalles'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Subagente 1'), findsNWidgets(2));
    expect(find.text('Abrir conversación'), findsNothing);
  });

  testWidgets('durable unknown batch never invents in-progress liveness', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        activities: [
          _nativeActivity(
            subagentId: 'unknown-private-a',
            phase: SubagentActivityPhase.unknown,
          ),
          _nativeActivity(
            subagentId: 'unknown-private-b',
            phase: SubagentActivityPhase.unknown,
          ),
        ],
        canInterrupt: (_) => false,
      ),
    );

    expect(find.textContaining('en curso'), findsNothing);
    expect(find.text('estado desconocido'), findsOneWidget);
    expect(find.textContaining('unknown-private'), findsNothing);
    final icon = tester.widget<Icon>(find.byIcon(Icons.account_tree_outlined));
    final colors = Theme.of(
      tester.element(find.byType(SubagentActivityCard)),
    ).hermes;
    expect(icon.color, colors.textSecondary);
  });

  testWidgets('mixed batch preserves real liveness and marks unknown neutral', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        activities: [
          _nativeActivity(subagentId: 'real-running'),
          _nativeActivity(
            subagentId: 'durable-unknown',
            phase: SubagentActivityPhase.unknown,
          ),
          _nativeActivity(
            subagentId: 'real-completed',
            phase: SubagentActivityPhase.completed,
          ),
        ],
        canInterrupt: (_) => false,
      ),
    );

    expect(find.textContaining('1 en curso'), findsOneWidget);
    expect(find.textContaining('1 finalizado'), findsOneWidget);
    expect(find.textContaining('estado desconocido'), findsOneWidget);
    expect(find.textContaining('2 en curso'), findsNothing);
  });

  testWidgets('batch stays calm and keeps goals private when expanded', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        activities: [
          _nativeActivity(subagentId: 'a', goalPreview: 'Auditar Android'),
          _nativeActivity(
            subagentId: 'b',
            goalPreview: 'Revisar continuidad',
            phase: SubagentActivityPhase.completed,
          ),
          _nativeActivity(
            subagentId: 'c',
            goalPreview: 'Verificar notas',
            phase: SubagentActivityPhase.failed,
          ),
        ],
        canInterrupt: (_) => false,
      ),
    );

    expect(find.text('1 en curso · 2 finalizados'), findsOneWidget);
    expect(find.text('Auditar Android'), findsNothing);
    expect(find.text('Revisar continuidad'), findsNothing);
    await tester.tap(find.text('ver detalles'));
    await tester.pumpAndSettle();
    expect(find.text('Subagente 1'), findsOneWidget);
    expect(find.text('Subagente 2'), findsOneWidget);
    expect(find.text('Subagente 3'), findsOneWidget);
    expect(find.text('Auditar Android'), findsNothing);
    expect(find.text('Revisar continuidad'), findsNothing);
    expect(find.text('Verificar notas'), findsNothing);
  });

  testWidgets('hijo nativo abre transcript y detiene solo esa fila', (
    tester,
  ) async {
    final activity = _nativeActivity();
    SubagentActivity? opened;
    SubagentActivity? interrupted;
    await tester.pumpWidget(
      _app(
        activities: [activity],
        canInterrupt: (_) => true,
        onOpen: (value) => opened = value,
        onInterrupt: (value) => interrupted = value,
      ),
    );

    expect(find.byType(HermesInlineActivity), findsOneWidget);
    expect(find.byType(AccentCard), findsNothing);
    expect(
      find.byKey(const ValueKey('subagent-open-child-card')),
      findsNothing,
    );
    await tester.tap(find.text('ver detalles'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('subagent-open-child-card')));
    await tester.tap(find.byKey(const ValueKey('subagent-stop-child-card')));

    expect(opened, same(activity));
    expect(interrupted, same(activity));
    expect(
      tester
          .getSize(find.byKey(const ValueKey('subagent-open-child-card')))
          .height,
      greaterThanOrEqualTo(48),
    );
    expect(
      tester
          .getSize(find.byKey(const ValueKey('subagent-stop-child-card')))
          .height,
      greaterThanOrEqualTo(48),
    );
  });

  testWidgets(
    'RED-C homogeneous completion is terminal and remains privacy-safe',
    (tester) async {
      const privateId = 'sa-private-should-not-render';
      final data = SubagentCompletionCardData(
        completionKey: 'completion-safe',
        delegationId: 'deleg_c0ffee12',
        taskCount: 1,
        completedCount: 1,
        failedCount: 0,
        durationSeconds: 0.05,
        subagentIds: const [privateId],
      );

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
          home: Scaffold(
            body: Center(
              child: SubagentCompletionCard(
                key: const ValueKey('historical-subagents'),
                data: data,
              ),
            ),
          ),
        ),
      );

      expect(find.textContaining('Subagente 1'), findsOneWidget);
      expect(find.text('completado'), findsOneWidget);
      expect(find.text('estado desconocido'), findsNothing);
      expect(find.textContaining(privateId), findsNothing);
      expect(find.textContaining('deleg_c0ffee12'), findsNothing);
      expect(find.text('Detener'), findsNothing);
    },
  );

  testWidgets('homogeneous failure attributes failed to every neutral row', (
    tester,
  ) async {
    final data = SubagentCompletionCardData(
      completionKey: 'failure-safe',
      delegationId: 'deleg_failure1',
      taskCount: 2,
      completedCount: 0,
      failedCount: 2,
      subagentIds: const ['sa-private-failure-1', 'sa-private-failure-2'],
    );

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
        home: Scaffold(
          body: Center(child: SubagentCompletionCard(data: data)),
        ),
      ),
    );

    expect(find.text('falló'), findsNWidgets(2));
    expect(find.text('estado desconocido'), findsNothing);
    expect(find.textContaining('sa-private-failure'), findsNothing);
    expect(find.textContaining('deleg_failure1'), findsNothing);
  });

  testWidgets('mixed historical completion is unknown and privacy-safe', (
    tester,
  ) async {
    const privateId = 'sa-private-should-not-render';
    final data = SubagentCompletionCardData(
      completionKey: 'completion-safe',
      delegationId: 'deleg_c0ffee12',
      taskCount: 3,
      completedCount: 2,
      failedCount: 1,
      durationSeconds: 0.05,
      subagentIds: const [privateId, 'sa-two', 'sa-three'],
    );

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
        home: Scaffold(
          body: Center(
            child: SubagentCompletionCard(
              key: const ValueKey('historical-subagents'),
              data: data,
            ),
          ),
        ),
      ),
    );

    expect(find.text('Subagentes'), findsOneWidget);
    expect(find.textContaining('2 completados'), findsOneWidget);
    expect(find.textContaining('1 falló'), findsOneWidget);
    expect(find.textContaining('00:00'), findsOneWidget);
    expect(
      find.text('No se conservaron los objetivos ni los modelos individuales.'),
      findsOneWidget,
    );
    expect(find.textContaining('Subagente 1'), findsOneWidget);
    expect(find.textContaining('Subagente 2'), findsOneWidget);
    expect(find.textContaining('Subagente 3'), findsOneWidget);
    expect(find.textContaining('estado desconocido'), findsNWidgets(3));
    expect(find.text('Detener'), findsNothing);
    expect(find.textContaining(privateId), findsNothing);
    expect(find.textContaining('deleg_c0ffee12'), findsNothing);
  });

  testWidgets('pending deshabilita ambas acciones y muestra progreso', (
    tester,
  ) async {
    final activity = _nativeActivity();
    await tester.pumpWidget(
      _app(
        activities: [activity],
        canInterrupt: (_) => true,
        interruptPending: (_) => true,
        openPending: (_) => true,
        onOpen: (_) {},
        onInterrupt: (_) {},
      ),
    );

    await tester.tap(find.text('ver detalles'));
    await tester.pump(const Duration(milliseconds: 250));
    final open = tester.widget<TextButton>(
      find.byKey(const ValueKey('subagent-open-child-card')),
    );
    final stop = tester.widget<TextButton>(
      find.byKey(const ValueKey('subagent-stop-child-card')),
    );
    expect(open.onPressed, isNull);
    expect(stop.onPressed, isNull);
    expect(find.text('Abriendo…'), findsOneWidget);
    expect(find.text('Deteniendo…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNWidgets(2));
  });

  testWidgets('solo lectura conserva abrir pero oculta detener', (
    tester,
  ) async {
    final activity = _nativeActivity();
    await tester.pumpWidget(
      _app(
        activities: [activity],
        canInterrupt: (_) => false,
        onOpen: (_) {},
        onInterrupt: (_) {},
      ),
    );

    await tester.tap(find.text('ver detalles'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('subagent-open-child-card')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('subagent-stop-child-card')),
      findsNothing,
    );
  });

  testWidgets('fallback legacy no inventa transcript ni control', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        activities: [_legacyActivity()],
        canInterrupt: (_) => false,
        onOpen: (_) {},
        onInterrupt: (_) {},
      ),
    );

    await tester.tap(find.text('ver detalles'));
    await tester.pumpAndSettle();
    expect(find.text('Abrir conversación'), findsNothing);
    expect(find.text('Detener'), findsNothing);
  });

  testWidgets('detalle corto también permanece plegado por defecto', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        activities: [
          _nativeActivity(subagentId: 'child-1'),
          _nativeActivity(subagentId: 'child-2'),
        ],
        canInterrupt: (_) => false,
      ),
    );

    final scrollables = find.descendant(
      of: find.byType(SubagentActivityCard),
      matching: find.byType(Scrollable),
    );
    expect(scrollables, findsNothing);
    expect(find.text('Revisar el proyecto'), findsNothing);
    expect(find.text('ver detalles'), findsOneWidget);

    await tester.tap(find.text('ver detalles'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Subagente 1'), findsOneWidget);
    expect(find.textContaining('Subagente 2'), findsOneWidget);
    expect(find.text('Revisar el proyecto'), findsNothing);
    expect(
      find.descendant(
        of: find.byType(SubagentActivityCard),
        matching: find.byType(Scrollable),
      ),
      findsOneWidget,
    );
  });

  testWidgets('muchos subagentes colapsados no desbordan con teclado', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 500);
    tester.view.viewInsets = const FakeViewPadding(bottom: 220);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _chatLikeApp(
        activities: List.generate(
          8,
          (index) => _nativeActivity(
            subagentId: 'child-$index',
            childSessionId: 'child-session-$index',
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byType(SubagentActivityCard)).height,
      lessThanOrEqualTo(148),
    );
    expect(find.text('ver detalles'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(SubagentActivityCard),
        matching: find.byType(Scrollable),
      ),
      findsNothing,
    );

    await tester.tap(find.text('ver detalles'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byType(SubagentActivityCard)).height,
      lessThanOrEqualTo(208),
    );
  });

  testWidgets('historial largo se despliega en un scroll acotado', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        activities: List.generate(
          8,
          (index) => _nativeActivity(
            subagentId: 'child-$index',
            childSessionId: 'child-session-$index',
          ),
        ),
        canInterrupt: (_) => true,
        onOpen: (_) {},
        onInterrupt: (_) {},
      ),
    );

    await tester.tap(find.text('ver detalles'));
    await tester.pumpAndSettle();

    expect(find.text('ocultar detalles'), findsOneWidget);
    final scroll = find.descendant(
      of: find.byType(SubagentActivityCard),
      matching: find.byType(Scrollable),
    );
    expect(
      tester.state<ScrollableState>(scroll).position.maxScrollExtent,
      greaterThan(0),
    );
  });

  testWidgets('tarjetas activas nunca muestran objetivo, resultado ni IDs', (
    tester,
  ) async {
    const privateGoal = 'PRIVATE_SUBAGENT_GOAL';
    const privateResult = 'PRIVATE_SUBAGENT_RESULT';
    const privateId = 'PRIVATE_SUBAGENT_ID';
    await tester.pumpWidget(
      _app(
        activities: [
          _nativeActivity(
            subagentId: privateId,
            goalPreview: privateGoal,
            summaryPreview: privateResult,
          ),
        ],
        canInterrupt: (_) => false,
      ),
    );

    expect(find.textContaining(privateGoal), findsNothing);
    expect(find.textContaining(privateResult), findsNothing);
    await tester.tap(find.text('ver detalles'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Subagente 1'), findsWidgets);
    expect(find.textContaining(privateGoal), findsNothing);
    expect(find.textContaining(privateResult), findsNothing);
    expect(find.textContaining(privateId), findsNothing);
  });

  testWidgets('estado completado queda neutral y el disclosure mide 48 dp', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        activities: [_nativeActivity(phase: SubagentActivityPhase.completed)],
        canInterrupt: (_) => false,
      ),
    );

    final disclosure = find.ancestor(
      of: find.text('ver detalles'),
      matching: find.byType(InkWell),
    );
    expect(tester.getSize(disclosure.first).height, greaterThanOrEqualTo(48));

    await tester.tap(find.text('ver detalles'));
    await tester.pumpAndSettle();

    final completed = tester.widget<Text>(find.text('completado').last);
    final colors = Theme.of(
      tester.element(find.byType(SubagentActivityCard)),
    ).hermes;
    expect(completed.style?.color, colors.textSecondary);
    expect(completed.style?.fontSize, 12);
  });

  testWidgets('escala 2 conserva contenido y acciones sin overflow', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        activities: [_nativeActivity()],
        canInterrupt: (_) => true,
        onOpen: (_) {},
        onInterrupt: (_) {},
        textScaler: const TextScaler.linear(2),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('ver detalles'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey('subagent-open-child-card')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('subagent-stop-child-card')),
      findsOneWidget,
    );
  });

  testWidgets('D compact header selects one detail and exposes public goal', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 800);
    addTearDown(tester.view.reset);
    final first = _nativeActivity(
      subagentId: 'd-first',
      childSessionId: 'd-first-session',
      goalPreview: 'Verificar la interfaz móvil',
      durationSeconds: 65,
    );
    final second = _nativeActivity(
      subagentId: 'd-second',
      childSessionId: 'd-second-session',
      goalPreview: 'Comprobar el panel acotado',
      phase: SubagentActivityPhase.requested,
    );

    await tester.pumpWidget(
      _app(
        activities: [first, second],
        canInterrupt: (_) => true,
        canSteer: (_) => true,
        onSteer: (_, _) async => const SubagentSteerView(status: 'queued'),
        onOpen: (_) {},
        onInterrupt: (_) {},
        textScaler: const TextScaler.linear(1.3),
      ),
    );

    expect(find.text('Subagentes'), findsOneWidget);
    expect(find.textContaining('2'), findsWidgets);
    expect(find.text('Verificar la interfaz móvil'), findsNothing);
    final header = find.byKey(const ValueKey('subagent-disclosure'));
    expect(tester.getSize(header).height, greaterThanOrEqualTo(48));

    await tester.tap(header);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('subagent-row-d-first')), findsOneWidget);
    expect(find.byKey(const ValueKey('subagent-row-d-second')), findsOneWidget);
    expect(find.text('Verificar la interfaz móvil'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('subagent-row-d-first')));
    await tester.pumpAndSettle();
    expect(find.text('Verificar la interfaz móvil'), findsOneWidget);
    expect(find.text('Comprobar el panel acotado'), findsNothing);
    expect(
      tester.getSize(find.byKey(const ValueKey('subagent-panel'))).height,
      lessThanOrEqualTo(360),
    );
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('ocultar detalles'));
    await tester.pumpAndSettle();
    expect(find.text('Verificar la interfaz móvil'), findsNothing);
  });

  testWidgets('D stop remains disabled after ACK until terminal activity', (
    tester,
  ) async {
    final live = _nativeActivity(subagentId: 'stop-waits');
    var stopCalls = 0;
    Widget build(SubagentActivity activity) => _app(
      activities: [activity],
      canInterrupt: (value) => !value.isTerminal,
      onStopRequested: (_) async {
        stopCalls += 1;
        return true;
      },
    );

    await tester.pumpWidget(build(live));
    await tester.tap(find.text('ver detalles'));
    await tester.pumpAndSettle();
    final stop = find.byKey(const ValueKey('subagent-stop-stop-waits'));
    await tester.tap(stop);
    await tester.pump();
    expect(stopCalls, 1);
    expect(tester.widget<TextButton>(stop).onPressed, isNull);
    await tester.tap(stop, warnIfMissed: false);
    expect(stopCalls, 1);

    final terminal = _nativeActivity(
      subagentId: 'stop-waits',
      phase: SubagentActivityPhase.cancelled,
    );
    await tester.pumpWidget(build(terminal));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('subagent-stop-stop-waits')),
      findsNothing,
    );
  });

  testWidgets('D steer clears queued and retains producer rejection', (
    tester,
  ) async {
    final activity = _nativeActivity(subagentId: 'steer-safe');
    var disposition = const SubagentSteerView(status: 'rejected');
    await tester.pumpWidget(
      _app(
        activities: [activity],
        canInterrupt: (_) => false,
        canSteer: (_) => true,
        onSteer: (_, text) async => disposition,
      ),
    );
    await tester.tap(find.text('ver detalles'));
    await tester.pumpAndSettle();
    final input = find.byKey(const ValueKey('subagent-steer-input-steer-safe'));
    final send = find.byKey(const ValueKey('subagent-steer-steer-safe'));
    await tester.enterText(input, 'Conserva este borrador');
    await tester.ensureVisible(send);
    await tester.pumpAndSettle();
    await tester.tap(send);
    await tester.pump();
    expect(find.text('Conserva este borrador'), findsOneWidget);
    expect(find.text('No se confirmó la orientación.'), findsOneWidget);

    disposition = const SubagentSteerView(status: 'queued');
    await tester.tap(send);
    await tester.pump();
    expect(find.text('Conserva este borrador'), findsNothing);
    expect(find.text('Orientación en cola.'), findsOneWidget);

    disposition = const SubagentSteerView(status: 'rejected');
    await tester.enterText(input, 'Rechazo final');
    await tester.tap(send);
    await tester.pump();
    expect(find.text('Rechazo final'), findsOneWidget);
    expect(find.text('No se confirmó la orientación.'), findsOneWidget);
  });

  testWidgets('D detail polls tail only while expanded and foreground', (
    tester,
  ) async {
    final activity = _nativeActivity(subagentId: 'tail-safe');
    final scheduled = <VoidCallback>[];
    var tailCalls = 0;
    var foreground = true;
    var tailResult = const SubagentTailView(
      available: true,
      content: 'Salida pública acotada',
      truncated: true,
    );

    Widget build() => MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: const [
        Strings.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: Strings.supportedLocales,
      home: StatefulBuilder(
        builder: (context, setState) => Scaffold(
          body: SubagentActivityCard(
            activities: [activity],
            canInterrupt: (_) => false,
            appForeground: foreground,
            scheduleTailPoll: (delay, callback) {
              late final VoidCallback scheduledCallback;
              scheduledCallback = () {
                scheduled.remove(scheduledCallback);
                callback();
              };
              scheduled.add(scheduledCallback);
              return () => scheduled.remove(scheduledCallback);
            },
            onTail: (_) async {
              tailCalls += 1;
              return tailResult;
            },
          ),
          floatingActionButton: FloatingActionButton(
            onPressed: () => setState(() => foreground = !foreground),
          ),
        ),
      ),
    );

    await tester.pumpWidget(build());
    expect(tailCalls, 0);
    await tester.tap(find.byKey(const ValueKey('subagent-disclosure')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('subagent-row-tail-safe')));
    await tester.pump();
    expect(tailCalls, 1);
    expect(find.text('Salida pública acotada'), findsOneWidget);
    expect(find.textContaining('recortada'), findsOneWidget);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump();
    expect(scheduled, isEmpty);
    expect(find.text('Salida pública acotada'), findsNothing);
    expect(find.text('La salida reciente no está disponible.'), findsNothing);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump();
    expect(tailCalls, 2);
    await tester.pump();
    expect(find.text('Salida pública acotada'), findsOneWidget);
  });

  testWidgets(
    'transient tail failure preserves the last valid content until next poll',
    (tester) async {
      final activity = _nativeActivity(subagentId: 'tail-transient');
      final scheduled = <VoidCallback>[];
      var tailCalls = 0;
      Future<SubagentTailView> loadTail(_) {
        tailCalls += 1;
        if (tailCalls == 1) {
          return Future.value(
            const SubagentTailView(
              available: true,
              content: 'Última salida válida',
              truncated: false,
            ),
          );
        }
        return Future.error(StateError('transient transport failure'));
      }

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
          home: Scaffold(
            body: SubagentActivityCard(
              activities: [activity],
              canInterrupt: (_) => false,
              scheduleTailPoll: (_, callback) {
                scheduled.add(callback);
                return () => scheduled.remove(callback);
              },
              onTail: loadTail,
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('subagent-disclosure')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('subagent-row-tail-transient')),
      );
      await tester.pump();
      expect(find.text('Última salida válida'), findsOneWidget);

      scheduled.single();
      await tester.pump();

      expect(tailCalls, 2);
      expect(find.text('Última salida válida'), findsOneWidget);
      expect(find.text('La salida reciente no está disponible.'), findsNothing);
    },
  );

  testWidgets('English subagent controls contain no Spanish copy', (
    tester,
  ) async {
    final activity = _nativeActivity(subagentId: 'english-safe');
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: const [
          Strings.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: Strings.supportedLocales,
        home: Scaffold(
          body: SubagentActivityCard(
            activities: [activity],
            canInterrupt: (_) => false,
            canSteer: (_) => true,
            onSteer: (_, _) async =>
                const SubagentSteerView(status: 'rejected'),
            onTail: (_) async => const SubagentTailView(
              available: false,
              content: '',
              truncated: false,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('view details'));
    await tester.pumpAndSettle();
    expect(find.text('Guide'), findsWidgets);
    expect(find.text('Orientar'), findsNothing);
    expect(find.textContaining('salida reciente'), findsNothing);
  });

  testWidgets(
    '390x844 at 2x bounds generic title and status while preserving actions',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);
      final semantics = tester.ensureSemantics();
      final goal =
          '${('authoritative release verification ' * 20).substring(0, SubagentPayloadLimits.goalCharacters - 1)}Z';
      final tool = ('long status tool ' * 20).substring(
        0,
        SubagentPayloadLimits.toolNameCharacters,
      );

      await tester.pumpWidget(
        _chatLikeApp(
          activities: [
            _nativeActivity(
              goalPreview: goal,
              phase: SubagentActivityPhase.tool,
              activeToolName: tool,
              summaryPreview: 'safe failure detail ${'x' * 400}',
            ),
          ],
          textScaler: const TextScaler.linear(2),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      final titleFinder = find.text('Subagentes');
      final summaryFinder = find.byWidgetPredicate(
        (widget) =>
            widget is Text &&
            (widget.data?.contains('usando herramienta') ?? false),
      );
      final collapsedTitle = tester.widget<Text>(titleFinder);
      expect(collapsedTitle.maxLines, 1);
      expect(collapsedTitle.overflow, TextOverflow.ellipsis);
      final collapsedSummary = tester.widget<Text>(summaryFinder);
      expect(collapsedSummary.maxLines, 1);
      expect(collapsedSummary.overflow, TextOverflow.ellipsis);
      expect(find.textContaining(goal), findsNothing);
      expect(find.textContaining(tool.trim()), findsNothing);
      expect(find.textContaining('safe failure detail'), findsNothing);
      expect(
        tester
            .getSize(
              find
                  .ancestor(
                    of: find.text('ver detalles'),
                    matching: find.byType(InkWell),
                  )
                  .first,
            )
            .height,
        greaterThanOrEqualTo(48),
      );

      await tester.tap(find.text('ver detalles'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.textContaining('safe failure detail'), findsNothing);
      expect(
        find.bySemanticsLabel(RegExp(r'Subagente 1, usando herramienta')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('subagent-open-child-card')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('subagent-stop-child-card')),
        findsOneWidget,
      );
      expect(
        tester
            .getSize(find.byKey(const ValueKey('subagent-open-child-card')))
            .height,
        greaterThanOrEqualTo(48),
      );
      expect(
        tester
            .getSize(find.byKey(const ValueKey('subagent-stop-child-card')))
            .height,
        greaterThanOrEqualTo(48),
      );
      semantics.dispose();
    },
  );
}
