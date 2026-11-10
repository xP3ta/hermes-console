import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/compaction_progress.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat_status_pill.dart';
import 'package:hermes_android/core/widgets/session_context_usage.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

const _contextZone = ValueKey('desktop-context-usage-status');
const _modelZone = ValueKey('status-pill-model');
const _permissionsZone = ValueKey('status-pill-permissions');
const _limitDot = ValueKey('status-pill-limit-dot');

void main() {
  group('contextLevelColor', () {
    final colors = AppTheme.fromId('amber').hermes;

    test('accent below 75, amber from 75, red from 90', () {
      expect(contextLevelColor(null, colors), colors.accentText);
      expect(contextLevelColor(0, colors), colors.accentText);
      expect(contextLevelColor(74, colors), colors.accentText);
      expect(contextLevelColor(75, colors), colors.warning);
      expect(contextLevelColor(89, colors), colors.warning);
      expect(contextLevelColor(90, colors), colors.error);
      expect(contextLevelColor(100, colors), colors.error);
    });
  });

  testWidgets('pm1215: picking a model glows the model zone once instead of '
      'a toast', (tester) async {
    final metrics = ValueNotifier(const SessionContextMetrics(percent: 10));
    final pulse = ValueNotifier(0);
    addTearDown(metrics.dispose);
    addTearDown(pulse.dispose);
    await tester.pumpWidget(
      _TestApp(
        child: ChatStatusPill(
          metrics: metrics,
          onOpenContext: () {},
          modelLabel: 'Sonnet 5',
          onOpenModel: () {},
          modelPulse: pulse,
        ),
      ),
    );
    Color? glow() =>
        (tester
                    .widget<DecoratedBox>(
                      find.byKey(const ValueKey('status-pill-model-pulse')),
                    )
                    .decoration
                as BoxDecoration)
            .color;
    expect(glow()!.a, 0, reason: 'calm at rest');
    expect(tester.hasRunningAnimations, isFalse);
    pulse.value++;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));
    expect(glow()!.a, greaterThan(0.15));
    await tester.pump(const Duration(milliseconds: 600));
    expect(glow()!.a, 0);
    expect(tester.hasRunningAnimations, isFalse);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('three zones open their own sheet', (tester) async {
    final metrics = ValueNotifier(
      const SessionContextMetrics(
        contextUsed: 45,
        contextMax: 100,
        percent: 45,
      ),
    );
    addTearDown(metrics.dispose);
    final opened = <String>[];

    await tester.pumpWidget(
      _TestApp(
        child: ChatStatusPill(
          metrics: metrics,
          onOpenContext: () => opened.add('context'),
          modelLabel: 'Sonnet 5',
          onOpenModel: () => opened.add('model'),
          permissionsLabel: 'Ask',
          onOpenPermissions: () => opened.add('permissions'),
        ),
      ),
    );

    expect(find.text('45%'), findsOneWidget);
    expect(find.text('Sonnet 5'), findsOneWidget);
    expect(find.byIcon(Icons.shield_outlined), findsOneWidget);
    // The global mode is only a shield: no text.
    expect(find.text('Ask'), findsNothing);

    await tester.tap(find.byKey(_contextZone));
    await tester.tap(find.byKey(_modelZone));
    await tester.tap(find.byKey(_permissionsZone));
    expect(opened, ['context', 'model', 'permissions']);
  });

  testWidgets('each zone is a labelled button at least 40 px tall', (
    tester,
  ) async {
    final metrics = ValueNotifier(
      const SessionContextMetrics(contextUsed: 8, contextMax: 100, percent: 8),
    );
    addTearDown(metrics.dispose);

    await tester.pumpWidget(
      _TestApp(
        child: ChatStatusPill(
          metrics: metrics,
          onOpenContext: () {},
          modelLabel: 'Sonnet 5',
          onOpenModel: () {},
          limitLevel: SubscriptionLimitLevel.near,
          permissionsLabel: 'YOLO',
          permissionsFlag: 'YOLO',
          permissionsColor: Colors.red,
          onOpenPermissions: () {},
        ),
      ),
    );

    for (final key in [_contextZone, _modelZone, _permissionsZone]) {
      expect(
        tester.getSize(find.byKey(key)).height,
        // A thumb-sized target that does not swallow the screen around it.
        inInclusiveRange(40, 56),
        reason: '$key',
      );
      final node = tester.getSemantics(find.byKey(key));
      expect(
        node.getSemanticsData().hasAction(SemanticsAction.tap),
        isTrue,
        reason: '$key',
      );
      expect(node.flagsCollection.isButton, isTrue, reason: '$key');
    }
    expect(
      tester.getSemantics(find.byKey(_contextZone)).getSemanticsData().label,
      'Open context usage, 8% used',
    );
    expect(
      tester.getSemantics(find.byKey(_modelZone)).getSemanticsData().label,
      'Model: Sonnet 5. Change model and session · '
      'Subscription limit nearly reached',
    );
    expect(
      tester
          .getSemantics(find.byKey(_permissionsZone))
          .getSemanticsData()
          .label,
      'Permissions: YOLO',
    );
    // The pill itself stays a slim 30 px capsule; only the hit area grows.
    final capsule = tester.getSize(
      find.byKey(const ValueKey('status-pill-capsule')),
    );
    expect(capsule.height, closeTo(30, 0.5));
  });

  testWidgets('a global permission mode announces it is the global one', (
    tester,
  ) async {
    final metrics = ValueNotifier(SessionContextMetrics.unknown);
    addTearDown(metrics.dispose);
    await tester.pumpWidget(
      _TestApp(
        child: ChatStatusPill(
          metrics: metrics,
          onOpenContext: () {},
          permissionsLabel: 'Ask',
          onOpenPermissions: () {},
        ),
      ),
    );
    expect(
      tester
          .getSemantics(find.byKey(_permissionsZone))
          .getSemanticsData()
          .label,
      'Permissions: Ask, global setting',
    );
    // No model label → no model zone.
    expect(find.byKey(_modelZone), findsNothing);
  });

  testWidgets('a session flag shows its text in its colour', (tester) async {
    final metrics = ValueNotifier(SessionContextMetrics.unknown);
    addTearDown(metrics.dispose);
    await tester.pumpWidget(
      _TestApp(
        child: ChatStatusPill(
          metrics: metrics,
          onOpenContext: () {},
          permissionsLabel: 'Read only',
          permissionsFlag: 'Read only',
          permissionsColor: Colors.purple,
          onOpenPermissions: () {},
        ),
      ),
    );
    final text = tester.widget<Text>(find.text('Read only'));
    expect(text.style?.color, Colors.purple);
  });

  testWidgets('ring follows the context level colour', (tester) async {
    final colors = AppTheme.fromId('amber').hermes;
    final metrics = ValueNotifier(
      const SessionContextMetrics(
        contextUsed: 74,
        contextMax: 100,
        percent: 74,
      ),
    );
    addTearDown(metrics.dispose);
    await tester.pumpWidget(
      _TestApp(
        child: ChatStatusPill(metrics: metrics, onOpenContext: () {}),
      ),
    );
    Color? ring() => tester
        .widget<CircularProgressIndicator>(
          find.descendant(
            of: find.byKey(_contextZone),
            matching: find.byType(CircularProgressIndicator),
          ),
        )
        .color;
    expect(ring(), colors.accentText);
    metrics.value = const SessionContextMetrics(
      contextUsed: 80,
      contextMax: 100,
      percent: 80,
    );
    await tester.pump();
    expect(ring(), colors.warning);
    metrics.value = const SessionContextMetrics(
      contextUsed: 95,
      contextMax: 100,
      percent: 95,
    );
    await tester.pump();
    expect(ring(), colors.error);
  });

  testWidgets('limit dot: none hides it, near is amber, reached is red', (
    tester,
  ) async {
    final colors = AppTheme.fromId('amber').hermes;
    final metrics = ValueNotifier(SessionContextMetrics.unknown);
    addTearDown(metrics.dispose);
    Future<void> pumpLevel(SubscriptionLimitLevel level) => tester.pumpWidget(
      _TestApp(
        child: ChatStatusPill(
          metrics: metrics,
          onOpenContext: () {},
          modelLabel: 'Sonnet 5',
          onOpenModel: () {},
          limitLevel: level,
        ),
      ),
    );
    Color? dot() =>
        (tester.widget<Container>(find.byKey(_limitDot)).decoration!
                as BoxDecoration)
            .color;

    await pumpLevel(SubscriptionLimitLevel.none);
    expect(find.byKey(_limitDot), findsNothing);
    await pumpLevel(SubscriptionLimitLevel.near);
    expect(dot(), colors.warning);
    await pumpLevel(SubscriptionLimitLevel.reached);
    expect(dot(), colors.error);
    expect(
      tester.getSemantics(find.byKey(_modelZone)).getSemanticsData().label,
      'Model: Sonnet 5. Change model and session · '
      'Subscription limit reached',
    );
  });

  testWidgets('context zone announces the best value available', (
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
        child: ChatStatusPill(metrics: metrics, onOpenContext: () {}),
      ),
    );
    String label() =>
        tester.getSemantics(find.byKey(_contextZone)).getSemanticsData().label;
    expect(find.text('8%'), findsOneWidget);
    expect(label(), 'Open context usage, 8% used');

    metrics.value = const SessionContextMetrics(cumulativeTotal: 1200);
    await tester.pump();
    expect(find.text('1.2k tok'), findsOneWidget);
    expect(label(), 'Open context usage, 1.2k tok');

    metrics.value = SessionContextMetrics.unknown;
    await tester.pump();
    expect(find.text('—'), findsOneWidget);
    expect(
      label(),
      'Open context usage, Hermes has not published this session\'s '
      'context window yet.',
    );
  });

  testWidgets('entry: a pending usage paints no number and the zone keeps '
      'the width of a percentage, so the real value changes it once', (
    tester,
  ) async {
    final metrics = ValueNotifier(SessionContextMetrics.unknown);
    final pending = ValueNotifier(true);
    addTearDown(metrics.dispose);
    addTearDown(pending.dispose);
    await tester.pumpWidget(
      _TestApp(
        child: ChatStatusPill(
          metrics: metrics,
          contextPending: pending,
          onOpenContext: () {},
          modelLabel: 'Sonnet 5',
          onOpenModel: () {},
        ),
      ),
    );
    // What a reader can read in the zone: the texts that are painted.
    List<String> readable() => [
      for (final text in tester.widgetList<Text>(
        find.descendant(
          of: find.byKey(_contextZone),
          matching: find.byType(Text),
        ),
      ))
        if ((text.style?.color?.a ?? 1) > 0) text.data ?? '',
    ];
    double width() => tester.getSize(find.byKey(_contextZone)).width;
    String label() =>
        tester.getSemantics(find.byKey(_contextZone)).getSemanticsData().label;

    expect(readable(), isEmpty, reason: 'no default dressed as a value');
    expect(find.text('—'), findsNothing);
    expect(label(), 'Open context usage');
    final waiting = width();

    // The three steps of an opening: what was cached, the persisted
    // snapshot (never painted: the screen keeps the cached window) and the
    // live window. Only the first and the last differ.
    final seen = <(List<String>, double)>[(readable(), waiting)];
    metrics.value = const SessionContextMetrics(
      contextUsed: 250,
      contextMax: 1000,
      percent: 25,
    );
    pending.value = false;
    await tester.pump();
    seen.add((readable(), width()));
    metrics.value = const SessionContextMetrics(
      contextUsed: 250,
      contextMax: 1000,
      percent: 25,
      cumulativeTotal: 150000,
    );
    await tester.pump();
    seen.add((readable(), width()));
    await tester.pump(const Duration(milliseconds: 300));
    seen.add((readable(), width()));

    expect(seen[1].$1, ['25%']);
    expect(
      seen.skip(1).every((s) => s.$1.length == 1 && s.$1[0] == '25%'),
      isTrue,
    );
    expect(
      seen.map((s) => s.$2).toSet().length,
      1,
      reason: 'the zone is as wide pending as with a two-digit percentage',
    );
  });

  testWidgets('compacted sessions keep the compacted mark', (tester) async {
    final metrics = ValueNotifier(
      const SessionContextMetrics(contextUsed: 8, contextMax: 100, percent: 8),
    );
    addTearDown(metrics.dispose);
    await tester.pumpWidget(
      _TestApp(
        child: ChatStatusPill(
          metrics: metrics,
          onOpenContext: () {},
          compressionCount: 3,
        ),
      ),
    );
    expect(find.byIcon(Icons.compress_rounded), findsOneWidget);
    expect(
      tester.getSemantics(find.byKey(_contextZone)).getSemanticsData().label,
      'Open context usage, 8% used · '
      'This conversation has been compacted 3 times',
    );
  });

  testWidgets('a running compaction replaces ring and percentage', (
    tester,
  ) async {
    final metrics = ValueNotifier(
      const SessionContextMetrics(contextUsed: 8, contextMax: 100, percent: 8),
    );
    addTearDown(metrics.dispose);
    final start = DateTime(2026, 10, 6, 12);
    await tester.pumpWidget(
      _TestApp(
        child: ChatStatusPill(
          metrics: metrics,
          onOpenContext: () {},
          compaction: CompactionProgress(startedAt: start, manual: true),
          clock: () => start.add(const Duration(seconds: 3)),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('8%'), findsNothing);
    expect(find.byKey(const ValueKey('context-pill-compaction')), findsOne);
  });

  for (final width in [320.0, 360.0]) {
    testWidgets('fits at ${width.toInt()} dp with text at 200 %', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 700);
      addTearDown(tester.view.reset);
      final metrics = ValueNotifier(
        const SessionContextMetrics(
          contextUsed: 92,
          contextMax: 100,
          percent: 92,
        ),
      );
      addTearDown(metrics.dispose);
      await tester.pumpWidget(
        _TestApp(
          textScale: 2,
          child: ChatStatusPill(
            metrics: metrics,
            onOpenContext: () {},
            compressionCount: 2,
            modelLabel: 'claude-sonnet-5-20261001-extended-thinking',
            onOpenModel: () {},
            limitLevel: SubscriptionLimitLevel.reached,
            permissionsLabel: 'Conservative',
            permissionsFlag: 'Conservative',
            permissionsColor: Colors.orange,
            onOpenPermissions: () {},
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      // The pill text really grows with the system scale.
      final percent = tester.renderObject<RenderParagraph>(find.text('92%'));
      expect(percent.textScaler.scale(10) / 10, closeTo(2, 0.01));
      final pill = tester.getRect(find.byType(ChatStatusPill));
      expect(pill.left, greaterThanOrEqualTo(0));
      expect(pill.right, lessThanOrEqualTo(width));
      // Context and permissions never shrink away; the model name yields.
      expect(find.text('92%'), findsOneWidget);
      expect(find.text('Conservative'), findsOneWidget);
    });
  }

  // ORDEN-WS-FIDELIDAD point 6: in a chat pane about 330 dp wide the model
  // was cut («Sonne…»): the bare shield, a second Flexible, held half of
  // the free room.
  testWidgets('a narrow chat keeps the whole model name', (tester) async {
    tester.view.physicalSize = const Size(330, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final metrics = ValueNotifier(const SessionContextMetrics(percent: 10));
    addTearDown(metrics.dispose);
    await tester.pumpWidget(
      _TestApp(
        child: ChatStatusPill(
          metrics: metrics,
          onOpenContext: () {},
          modelLabel: 'Sonnet 4.5',
          onOpenModel: () {},
          permissionsLabel: 'Ask',
          onOpenPermissions: () {},
        ),
      ),
    );
    final label = tester.renderObject<RenderParagraph>(find.text('Sonnet 4.5'));
    expect(label.didExceedMaxLines, isFalse);
    expect(find.byKey(_permissionsZone), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('model detail', () {
    test('level and fast mark, joined; nothing when neither applies', () {
      expect(statusPillModelDetail(), isNull);
      expect(statusPillModelDetail(level: '', fast: ''), isNull);
      expect(statusPillModelDetail(level: 'High'), 'High');
      expect(statusPillModelDetail(fast: 'Fast'), 'Fast');
      expect(statusPillModelDetail(level: 'High', fast: 'Fast'), 'High · Fast');
    });

    Future<void> pumpDetail(
      WidgetTester tester, {
      String? detail,
      double width = 420,
      double textScale = 1,
    }) async {
      tester.view.physicalSize = Size(width, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final metrics = ValueNotifier(const SessionContextMetrics(percent: 14));
      addTearDown(metrics.dispose);
      await tester.pumpWidget(
        _TestApp(
          textScale: textScale,
          child: ChatStatusPill(
            metrics: metrics,
            onOpenContext: () {},
            modelLabel: 'Sonnet 5',
            modelDetail: detail,
            onOpenModel: () {},
            permissionsLabel: 'YOLO',
            permissionsFlag: 'YOLO',
            onOpenPermissions: () {},
          ),
        ),
      );
    }

    testWidgets('the pill reads «model · level · fast» in one line', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpDetail(tester, detail: 'High · Fast', width: 800);
      expect(find.text('Sonnet 5 · High · Fast'), findsOneWidget);
      final label = tester.renderObject<RenderParagraph>(
        find.text('Sonnet 5 · High · Fast'),
      );
      expect(label.didExceedMaxLines, isFalse);
      expect(
        tester.getSemantics(find.byKey(_modelZone)).label,
        contains('High · Fast'),
      );
      handle.dispose();
    });

    testWidgets('without detail the name stays a plain keyed text', (
      tester,
    ) async {
      await pumpDetail(tester);
      expect(find.byKey(const ValueKey('Sonnet 5')), findsOneWidget);
      expect(find.text('Sonnet 5'), findsOneWidget);
    });

    testWidgets('narrow and large text: the detail yields, no overflow', (
      tester,
    ) async {
      await pumpDetail(
        tester,
        detail: 'Very high · Fast',
        width: 320,
        textScale: 2,
      );
      expect(tester.takeException(), isNull);
      final pill = tester.getRect(find.byType(ChatStatusPill));
      expect(pill.right, lessThanOrEqualTo(320));
    });
  });
}

class _TestApp extends StatelessWidget {
  const _TestApp({required this.child, this.textScale = 1});

  final Widget child;
  final double textScale;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.fromId('amber'),
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
