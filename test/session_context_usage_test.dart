import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
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
    expect(
      semantics.getSemanticsData().label,
      'Open context usage, 31% used',
    );
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
    expect(
      semantics.getSemanticsData().label,
      'Open context usage, 52% used',
    );

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
    expect(
      semantics.getSemanticsData().label,
      'Open context usage, 99k tok',
    );
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
          child: SessionContextFloatingPanel(
            key: ValueKey(locale.languageCode),
            width: 296,
            maxHeight: 440,
            metrics: metrics,
            loadBreakdown: () async => null,
            onMetricsSnapshot: (value) => metrics.value = value,
            onClose: () {},
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
        child: SessionContextFloatingPanel(
          width: 296,
          maxHeight: 440,
          metrics: metrics,
          loadBreakdown: () {
            calls += 1;
            return result.future;
          },
          onMetricsSnapshot: (value) => metrics.value = value,
          onClose: () {},
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

  testWidgets('la píldora anuncia descripción y el mejor valor disponible', (
    tester,
  ) async {
    final metrics = ValueNotifier(
      const SessionContextMetrics(
        contextUsed: 800,
        contextMax: 10000,
        percent: 8,
        cumulativeTotal: 1200,
      ),
    );
    addTearDown(metrics.dispose);

    await tester.pumpWidget(
      _TestApp(
        child: SessionContextPopoverButton(
          metrics: metrics,
          loadBreakdown: () async => null,
          onMetricsSnapshot: (value) => metrics.value = value,
        ),
      ),
    );

    final trigger = find.byKey(
      const ValueKey('desktop-context-usage-status'),
    );
    expect(find.text('8%'), findsOneWidget);
    expect(
      tester.getSemantics(trigger).getSemanticsData().label,
      'Open context usage, 8% used',
    );

    metrics.value = const SessionContextMetrics(cumulativeTotal: 1200);
    await tester.pump();
    expect(find.text('1.2k tok'), findsOneWidget);
    expect(
      tester.getSemantics(trigger).getSemanticsData().label,
      'Open context usage, 1.2k tok',
    );

    metrics.value = SessionContextMetrics.unknown;
    await tester.pump();
    expect(find.text('—'), findsOneWidget);
    expect(
      tester.getSemantics(trigger).getSemanticsData().label,
      'Open context usage, Hermes has not published this session\'s context window yet.',
    );
  });

  testWidgets(
    'la marca de compactación persiste y solo aparece cuando ya se compactó',
    (tester) async {
      final metrics = ValueNotifier(
        const SessionContextMetrics(
          contextUsed: 800,
          contextMax: 10000,
          percent: 8,
        ),
      );
      addTearDown(metrics.dispose);

      await tester.pumpWidget(
        _TestApp(
          child: SessionContextPopoverButton(
            metrics: metrics,
            loadBreakdown: () async => null,
            onMetricsSnapshot: (value) => metrics.value = value,
          ),
        ),
      );

      final trigger = find.byKey(
        const ValueKey('desktop-context-usage-status'),
      );
      // Sin compactar nunca: nada de esto se muestra.
      expect(find.byIcon(Icons.compress_rounded), findsNothing);
      expect(
        tester.getSemantics(trigger).getSemanticsData().label,
        'Open context usage, 8% used',
      );

      await tester.pumpWidget(
        _TestApp(
          child: SessionContextPopoverButton(
            metrics: metrics,
            loadBreakdown: () async => null,
            onMetricsSnapshot: (value) => metrics.value = value,
            compressionCount: 1,
          ),
        ),
      );
      expect(find.byIcon(Icons.compress_rounded), findsOneWidget);
      expect(
        tester.getSemantics(trigger).getSemanticsData().label,
        'Open context usage, 8% used · This conversation has been compacted once',
      );

      await tester.pumpWidget(
        _TestApp(
          child: SessionContextPopoverButton(
            metrics: metrics,
            loadBreakdown: () async => null,
            onMetricsSnapshot: (value) => metrics.value = value,
            compressionCount: 3,
          ),
        ),
      );
      expect(find.byIcon(Icons.compress_rounded), findsOneWidget);
      expect(
        tester.getSemantics(trigger).getSemanticsData().label,
        'Open context usage, 8% used · This conversation has been compacted 3 times',
      );
    },
  );

  testWidgets('el trigger abre una tarjeta anclada y el cierre la retira', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(393, 800);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    final metrics = ValueNotifier(
      const SessionContextMetrics(
        contextUsed: 2900,
        contextMax: 10000,
        percent: 29,
      ),
    );
    addTearDown(metrics.dispose);
    var calls = 0;

    await tester.pumpWidget(
      _TestApp(
        child: Align(
          alignment: Alignment.topRight,
          child: SessionContextPopoverButton(
            metrics: metrics,
            loadBreakdown: () async {
              calls += 1;
              return const DesktopContextBreakdown(
                contextUsed: 2900,
                contextMax: 10000,
                contextPercent: 29,
              );
            },
            onMetricsSnapshot: (value) => metrics.value = value,
          ),
        ),
      ),
    );

    final trigger = find.byKey(const ValueKey('desktop-context-usage-status'));
    expect(find.text('29%'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('desktop-context-usage-popover')),
      findsNothing,
    );

    await tester.tap(trigger);
    await tester.pumpAndSettle();

    final popover = find.byKey(const ValueKey('desktop-context-usage-popover'));
    expect(popover, findsOneWidget);
    expect(calls, 1);
    expect(
      tester.getTopLeft(popover).dy,
      greaterThanOrEqualTo(tester.getBottomLeft(trigger).dy),
    );
    expect(tester.getTopRight(popover).dx, lessThanOrEqualTo(393));

    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();
    expect(popover, findsNothing);
    expect(calls, 1);
    expect(tester.takeException(), isNull);
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
