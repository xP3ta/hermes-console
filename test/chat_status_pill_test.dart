import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/semantics.dart';
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
