import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/compaction_progress.dart';
import 'package:hermes_android/core/models/desktop_context_breakdown.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/models/session.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/session_context_usage.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

void main() {
  test(
    'usa la ocupación real y nunca convierte total acumulado en contexto',
    () {
      final live = SessionContextMetrics.fromUsage(
        DesktopUsageStats.fromJson(const {
          'context_used': 3100,
          'context_max': 10000,
          'total': 99000,
        }),
      );
      final cumulativeOnly = SessionContextMetrics.fromUsage(
        DesktopUsageStats.fromJson(const {'total': 99000}),
      );

      expect(live.contextUsed, 3100);
      expect(live.contextMax, 10000);
      expect(live.percent, 31);
      expect(cumulativeOnly.hasWindow, isFalse);
      expect(cumulativeOnly.percent, isNull);
      expect(cumulativeOnly.cumulativeTotal, 99000);
    },
  );

  test('el breakdown prevalece y acota porcentajes como Desktop', () {
    final metrics = SessionContextMetrics.fromBreakdown(
      DesktopContextBreakdown.fromJson(const {
        'context_used': 1500,
        'context_max': 1000,
        'context_percent': 900,
      }),
    );
    const fallback = SessionContextMetrics(
      contextUsed: 42,
      contextMax: 100,
      percent: 42,
    );
    final missingWindow = SessionContextMetrics.fromBreakdown(
      const DesktopContextBreakdown(contextUsed: 500, estimatedTotal: 500),
      fallback: fallback,
    );

    expect(metrics.percent, 100);
    expect(missingWindow, fallback);
  });

  test('proyecta caché publicada y conserva TTFT al cargar breakdown', () {
    final live = SessionContextMetrics.fromUsage(
      DesktopUsageStats.fromJson(const {
        'input': 100,
        'cache_read_tokens': 50,
        'cache_write_tokens': 50,
      }),
      observedFirstTokenLatencyMs: 840,
    );
    final afterBreakdown = SessionContextMetrics.fromBreakdown(
      const DesktopContextBreakdown(
        contextUsed: 250,
        contextMax: 1000,
        contextPercent: 25,
      ),
      fallback: live,
    );
    final absent = SessionContextMetrics.fromUsage(
      DesktopUsageStats.fromJson(const {'input': 100}),
    );

    expect(afterBreakdown.cacheReadTokens, 50);
    expect(afterBreakdown.cacheWriteTokens, 50);
    expect(afterBreakdown.cacheReadPercent, 25);
    expect(afterBreakdown.observedFirstTokenLatencyMs, 840);
    expect(absent.cacheReadTokens, isNull);
    expect(absent.cacheWriteTokens, isNull);
  });

  test('completa caché REST cuando session.info no la publica', () {
    const session = Session(
      id: 'session-rest-usage',
      title: 'Usage',
      model: 'model-a',
      source: 'mobile',
      messageCount: 2,
      isActive: false,
      preview: '',
      startedAt: 1,
      inputTokens: 16000,
      outputTokens: 179,
      cacheReadTokens: 5000,
      cacheWriteTokens: 0,
    );
    final metrics = SessionContextMetrics.fromUsage(
      DesktopUsageStats.fromJson(const {
        'context_used': 21000,
        'context_max': 128000,
        'input': 0,
      }),
      sessionFallback: session,
      observedFirstTokenLatencyMs: 3543,
    );

    expect(metrics.contextUsed, 21000);
    expect(metrics.contextMax, 128000);
    expect(metrics.cacheReadTokens, 5000);
    expect(metrics.cacheWriteTokens, 0);
    expect(metrics.inputTokens, 16000);
    expect(metrics.cacheReadPercent, closeTo(23.809, 0.001));
    expect(metrics.observedFirstTokenLatencyMs, 3543);
  });

  testWidgets('muestra TTFT local y desconocidos sin inventar ceros', (
    tester,
  ) async {
    await tester.pumpWidget(
      const _TestApp(
        child: SessionContextPerformance(
          metrics: SessionContextMetrics(
            inputTokens: 100,
            cacheReadTokens: 0,
            observedFirstTokenLatencyMs: 840,
          ),
        ),
      ),
    );

    expect(find.text('840 ms'), findsOneWidget);
    expect(find.text('0'), findsOneWidget);
    expect(find.text('Not published by Hermes'), findsOneWidget);
  });

  test('formatea tokens igual que el formatter compartido de Desktop', () {
    expect(compactSessionContextTokens(999), '999');
    expect(compactSessionContextTokens(1000), '1k');
    expect(compactSessionContextTokens(1230), '1.2k');
    expect(compactSessionContextTokens(10000), '10k');
    expect(compactSessionContextTokens(1500000), '1.5M');
  });

  testWidgets('una ventana conocida muestra y anuncia la ocupación', (
    tester,
  ) async {
    final metrics = ValueNotifier(
      const SessionContextMetrics(
        contextUsed: 3100,
        contextMax: 10000,
        percent: 31,
      ),
    );
    addTearDown(metrics.dispose);
    var hostBuilds = 0;
    var taps = 0;

    await tester.pumpWidget(
      _TestApp(
        child: Builder(
          builder: (context) {
            hostBuilds += 1;
            return SessionContextTrigger(
              metrics: metrics,
              onPressed: () => taps += 1,
            );
          },
        ),
      ),
    );

    expect(find.text('31%'), findsOneWidget);
    expect(hostBuilds, 1);
    var semantics = tester.getSemantics(
      find.byKey(const ValueKey('desktop-context-usage-status')),
    );
    expect(semantics.getSemanticsData().label, 'Open context usage, 31% used');
    expect(semantics.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);

    metrics.value = const SessionContextMetrics(
      contextUsed: 5200,
      contextMax: 10000,
      percent: 52,
    );
    await tester.pump();

    expect(find.text('52%'), findsOneWidget);
    expect(find.text('31%'), findsNothing);
    expect(hostBuilds, 1);
    semantics = tester.getSemantics(
      find.byKey(const ValueKey('desktop-context-usage-status')),
    );
    expect(semantics.getSemanticsData().label, 'Open context usage, 52% used');

    await tester.tap(
      find.byKey(const ValueKey('desktop-context-usage-status')),
    );
    expect(taps, 1);
  });

  testWidgets('sin porcentaje muestra los tokens acumulados disponibles', (
    tester,
  ) async {
    final metrics = ValueNotifier(
      const SessionContextMetrics(cumulativeTotal: 99000),
    );
    addTearDown(metrics.dispose);

    await tester.pumpWidget(
      _TestApp(
        child: SessionContextTrigger(metrics: metrics, onPressed: () {}),
      ),
    );

    expect(find.text('99k tok'), findsOneWidget);
    expect(find.text('—'), findsNothing);
    final semantics = tester.getSemantics(
      find.byKey(const ValueKey('desktop-context-usage-status')),
    );
    expect(semantics.getSemanticsData().label, 'Open context usage, 99k tok');
  });

  testWidgets('sin porcentaje ni acumulado muestra solo el marcador', (
    tester,
  ) async {
    final metrics = ValueNotifier(SessionContextMetrics.unknown);
    addTearDown(metrics.dispose);

    await tester.pumpWidget(
      _TestApp(
        child: SessionContextTrigger(metrics: metrics, onPressed: () {}),
      ),
    );

    expect(find.text('—'), findsOneWidget);
    final semantics = tester.getSemantics(
      find.byKey(const ValueKey('desktop-context-usage-status')),
    );
    expect(
      semantics.getSemanticsData().label,
      'Open context usage, Hermes has not published this session\'s context window yet.',
    );
  });

  testWidgets('el panel etiqueta los tokens acumulados en inglés y español', (
    tester,
  ) async {
    final metrics = ValueNotifier(
      const SessionContextMetrics(cumulativeTotal: 99000),
    );
    addTearDown(metrics.dispose);

    for (final (locale, label) in [
      (const Locale('en'), 'Session total tokens'),
      (const Locale('es'), 'Tokens acumulados de la sesión'),
    ]) {
      await tester.pumpWidget(
        _TestApp(
          locale: locale,
          child: SessionContextSheetBody(
            key: ValueKey(locale.languageCode),
            metrics: metrics,
            loadBreakdown: () async => null,
            onMetricsSnapshot: (value) => metrics.value = value,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text(label), findsOneWidget);
      expect(find.text('99k'), findsOneWidget);
      expect(find.text('99k tok'), findsNothing);
    }
  });

  testWidgets('el panel flotante carga una vez y cabe a 320 dp al 200 %', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 560);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    final metrics = ValueNotifier(
      const SessionContextMetrics(
        contextUsed: 5000,
        contextMax: 20000,
        percent: 25,
      ),
    );
    addTearDown(metrics.dispose);
    final result = Completer<DesktopContextBreakdown?>();
    var calls = 0;

    await tester.pumpWidget(
      _TestApp(
        textScale: 2,
        child: SingleChildScrollView(
          child: SessionContextSheetBody(
            metrics: metrics,
            loadBreakdown: () {
              calls += 1;
              return result.future;
            },
            onMetricsSnapshot: (value) => metrics.value = value,
            onCompact: () {},
          ),
        ),
      ),
    );

    expect(calls, 1);
    expect(find.text('Calculating this session\'s breakdown…'), findsOneWidget);

    result.complete(
      DesktopContextBreakdown.fromJson(const {
        'categories': [
          {'id': 'system_prompt', 'label': 'System prompt', 'tokens': 1200},
          {
            'id': 'tool_definitions',
            'label': 'Tool definitions',
            'tokens': 900,
          },
          {'id': 'rules', 'label': 'Rules', 'tokens': 400},
          {'id': 'skills', 'label': 'Skills', 'tokens': 300},
          {'id': 'mcp', 'label': 'MCP', 'tokens': 200},
          {
            'id': 'subagent_definitions',
            'label': 'Subagent definitions',
            'tokens': 200,
          },
          {'id': 'memory', 'label': 'Memory', 'tokens': 300},
          {'id': 'conversation', 'label': 'Conversation', 'tokens': 1500},
        ],
        'context_used': 5000,
        'context_max': 20000,
        'context_percent': 25,
        'estimated_total': 5000,
      }),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('25%'), findsOneWidget);
    expect(find.text('5k of 20k tokens'), findsOneWidget);
    expect(find.textContaining('~5k'), findsNothing);
    expect(find.text('System prompt'), findsOneWidget);
    expect(find.text('Subagent definitions'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('session-context-segmented-bar')),
      findsOneWidget,
    );
    expect(calls, 1);
    expect(tester.takeException(), isNull);

    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -280),
    );
    await tester.pump();
    expect(find.text('Conversation'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('context sheet body', () {
    Future<void> pumpBody(
      WidgetTester tester, {
      required ValueNotifier<SessionContextMetrics> metrics,
      VoidCallback? onCompact,
      ValueListenable<CompactionProgress?>? compaction,
      Future<DesktopContextBreakdown?> Function()? load,
    }) => tester.pumpWidget(
      _TestApp(
        locale: const Locale('es'),
        child: SingleChildScrollView(
          child: SessionContextSheetBody(
            metrics: metrics,
            loadBreakdown: load ?? () async => null,
            onMetricsSnapshot: (value) => metrics.value = value,
            onCompact: onCompact,
            compaction: compaction,
            clock: () => DateTime(2026, 10, 6, 12, 0, 3),
          ),
        ),
      ),
    );

    testWidgets('big ring, tokens of the window and Compactar', (tester) async {
      final colors = AppTheme.fromId('amber').hermes;
      final metrics = ValueNotifier(
        const SessionContextMetrics(
          contextUsed: 89600,
          contextMax: 200000,
          percent: 80,
        ),
      );
      addTearDown(metrics.dispose);
      var compacts = 0;
      var loads = 0;
      await pumpBody(
        tester,
        metrics: metrics,
        onCompact: () => compacts++,
        load: () async {
          loads++;
          return null;
        },
      );
      await tester.pump();

      expect(find.text('80%'), findsOneWidget);
      expect(find.text('89.6k de 200k tokens'), findsOneWidget);
      final ring = tester.widget<SessionContextRing>(
        find.byKey(const ValueKey('context-sheet-ring')),
      );
      expect(ring.color, colors.warning);
      // Honest notice: this server publishes no breakdown.
      expect(
        find.text(
          Strings.of(
            tester.element(find.byType(SessionContextSheetBody)),
          ).chaContextUsageUnavailable,
        ),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('context-compress-now')));
      expect(compacts, 1);
      expect(loads, 1);
    });

    testWidgets('no compact action without a callback', (tester) async {
      final metrics = ValueNotifier(SessionContextMetrics.unknown);
      addTearDown(metrics.dispose);
      await pumpBody(tester, metrics: metrics);
      expect(find.byKey(const ValueKey('context-compress-now')), findsNothing);
    });

    testWidgets('while compacting the button waits and the row says so', (
      tester,
    ) async {
      final metrics = ValueNotifier(
        const SessionContextMetrics(
          contextUsed: 45,
          contextMax: 100,
          percent: 45,
        ),
      );
      addTearDown(metrics.dispose);
      final progress = ValueNotifier<CompactionProgress?>(null);
      addTearDown(progress.dispose);
      var compacts = 0;
      await pumpBody(
        tester,
        metrics: metrics,
        onCompact: () => compacts++,
        compaction: progress,
      );
      expect(
        find.byKey(const ValueKey('context-panel-compaction')),
        findsNothing,
      );

      progress.value = CompactionProgress(
        startedAt: DateTime(2026, 10, 6, 12),
        manual: true,
        messagesBefore: 340,
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('context-panel-compaction')),
        findsOneWidget,
      );
      expect(find.text('Compactando…'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('context-compress-now')));
      expect(compacts, 0);
    });

    testWidgets('red ring from 90 %', (tester) async {
      final colors = AppTheme.fromId('amber').hermes;
      final metrics = ValueNotifier(
        const SessionContextMetrics(
          contextUsed: 92,
          contextMax: 100,
          percent: 92,
        ),
      );
      addTearDown(metrics.dispose);
      await pumpBody(tester, metrics: metrics);
      expect(
        tester
            .widget<SessionContextRing>(
              find.byKey(const ValueKey('context-sheet-ring')),
            )
            .color,
        colors.error,
      );
    });
  });

  testWidgets('usa tokens semánticos en temas dark, OLED y light', (
    tester,
  ) async {
    final metrics = ValueNotifier(
      const SessionContextMetrics(
        contextUsed: 42,
        contextMax: 100,
        percent: 42,
      ),
    );
    addTearDown(metrics.dispose);

    for (final themeId in ['amber', 'amber-oled', 'claude-light']) {
      await tester.pumpWidget(
        _TestApp(
          theme: AppTheme.fromId(themeId),
          child: SessionContextTrigger(metrics: metrics, onPressed: () {}),
        ),
      );
      expect(find.text('42%'), findsOneWidget, reason: themeId);
      expect(tester.takeException(), isNull, reason: themeId);
    }
  });
}

class _TestApp extends StatelessWidget {
  const _TestApp({
    required this.child,
    this.textScale = 1,
    this.theme,
    this.locale = const Locale('en'),
  });

  final Widget child;
  final double textScale;
  final ThemeData? theme;
  final Locale locale;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      locale: locale,
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: theme ?? AppTheme.fromId('amber'),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(body: Center(child: child)),
    );
  }
}
