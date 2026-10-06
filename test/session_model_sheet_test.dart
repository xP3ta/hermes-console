import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_session_config.dart';
import 'package:hermes_android/core/models/model_provider.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/session_model_sheet.dart';
import 'package:hermes_android/core/widgets/subscription_limit_block.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

const _anthropic = ModelProvider(
  slug: 'anthropic',
  name: 'Anthropic',
  isCurrent: true,
  authenticated: true,
  authType: '',
  oauthProviderId: '',
  keyEnv: '',
  warning: '',
  models: ['claude-sonnet-5', 'claude-opus-5', 'claude-haiku-5'],
);
const _openai = ModelProvider(
  slug: 'openai',
  name: 'OpenAI',
  isCurrent: false,
  authenticated: true,
  authType: '',
  oauthProviderId: '',
  keyEnv: '',
  warning: '',
  models: ['gpt-6', 'gpt-6-mini'],
);

SessionModelCardInfo _info(String slug, String id) => switch (id) {
  'claude-sonnet-5' => const SessionModelCardInfo(reasoning: true, fast: true),
  'claude-opus-5' => const SessionModelCardInfo(reasoning: true, fast: false),
  'claude-haiku-5' => const SessionModelCardInfo(reasoning: false, fast: true),
  'gpt-6-mini' => const SessionModelCardInfo(usable: false),
  _ => const SessionModelCardInfo(),
};

const _labels = {
  'claude-sonnet-5': 'Sonnet 5',
  'claude-opus-5': 'Opus 5',
  'claude-haiku-5': 'Haiku 5',
};

void main() {
  late List<(String, String)> picks;
  late List<DesktopReasoningEffort> efforts;
  late List<DesktopFastMode> fasts;

  setUp(() {
    picks = [];
    efforts = [];
    fasts = [];
  });

  Future<void> pump(
    WidgetTester tester, {
    List<ModelProvider> providers = const [_anthropic, _openai],
    String selectedProvider = 'anthropic',
    String selectedModel = 'claude-sonnet-5',
    bool reasoningSupported = true,
    bool fastSupported = true,
    DesktopReasoningEffort? effort = DesktopReasoningEffort.medium,
    DesktopFastMode? fast = DesktopFastMode.normal,
    SubscriptionLimits? limits,
    bool busy = false,
    double textScale = 1,
    Locale locale = const Locale('es'),
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.fromId('amber'),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            child: SessionModelSheetBody(
              providers: providers,
              isSelected: (slug, id) =>
                  slug == selectedProvider && id == selectedModel,
              isSelectedProvider: (slug) => slug == selectedProvider,
              cardInfo: _info,
              modelLabel: (id) => _labels[id] ?? id,
              onPick: busy ? null : (p, id) => picks.add((p.slug, id)),
              reasoning: effort,
              reasoningSupported: reasoningSupported,
              onReasoning: busy ? null : efforts.add,
              fastMode: fast,
              fastSupported: fastSupported,
              onFastMode: busy ? null : fasts.add,
              limits: limits,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('provider tabs: the active provider opens, others on tap', (
    tester,
  ) async {
    await pump(tester);
    expect(
      find.byKey(const ValueKey('model-provider-tab-anthropic')),
      findsOne,
    );
    expect(find.byKey(const ValueKey('model-provider-tab-openai')), findsOne);
    expect(find.text('Sonnet 5'), findsOneWidget);
    expect(find.text('Opus 5'), findsOneWidget);
    expect(find.text('gpt-6'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('model-provider-tab-openai')));
    await tester.pump();
    expect(find.text('Sonnet 5'), findsNothing);
    expect(find.text('gpt-6'), findsOneWidget);
    // The tab of the session's provider keeps its dot.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('model-provider-tab-anthropic')),
        matching: find.byKey(const ValueKey('model-provider-active-dot')),
      ),
      findsOneWidget,
    );
  });

  testWidgets('cards: ✓ on the active one, capability subtitles', (
    tester,
  ) async {
    await pump(tester);
    final active = find.byKey(
      const ValueKey('model-card-anthropic-claude-sonnet-5'),
    );
    expect(
      find.descendant(of: active, matching: find.byIcon(Icons.check_rounded)),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('model-card-anthropic-claude-opus-5')),
        matching: find.byIcon(Icons.check_rounded),
      ),
      findsNothing,
    );
    expect(find.text('Razona · Rápido'), findsOneWidget);
    expect(find.text('Razona'), findsOneWidget);
    expect(find.text('Rápido'), findsOneWidget);
    final semantics = tester.getSemantics(active);
    expect(semantics.flagsCollection.isSelected, Tristate.isTrue);
    expect(semantics.flagsCollection.isButton, isTrue);
  });

  testWidgets('tapping a card picks it; unavailable ones cannot be picked', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.text('Opus 5'));
    expect(picks, [('anthropic', 'claude-opus-5')]);
    // The active card is not re-applied.
    await tester.tap(find.text('Sonnet 5'));
    expect(picks, hasLength(1));

    await tester.tap(find.byKey(const ValueKey('model-provider-tab-openai')));
    await tester.pump();
    expect(find.text('gpt-6-mini · no disponible'), findsOneWidget);
    await tester.tap(find.text('gpt-6-mini'));
    expect(picks, hasLength(1));
    // Unknown capabilities: no invented badges, and no repeated raw id.
    expect(find.text('gpt-6'), findsOneWidget);
  });

  testWidgets('search spans every provider and ignores the tabs', (
    tester,
  ) async {
    await pump(tester);
    await tester.enterText(
      find.byKey(const ValueKey('chat-model-search')),
      'mini',
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('model-provider-tab-openai')),
      findsNothing,
    );
    expect(find.text('gpt-6-mini'), findsOneWidget);
    expect(find.text('Sonnet 5'), findsNothing);
  });

  testWidgets('a single provider shows its header, no tabs', (tester) async {
    await pump(tester, providers: const [_anthropic]);
    expect(
      find.byKey(const ValueKey('model-provider-tab-anthropic')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('provider-logo-picker-provider-anthropic')),
      findsOneWidget,
    );
  });

  testWidgets('reasoning Bajo/Medio/Alto and fast mode when supported', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('Razonamiento'), findsOneWidget);
    expect(
      tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Medio'))
          .selected,
      isTrue,
    );
    await tester.tap(find.widgetWithText(ChoiceChip, 'Alto'));
    expect(efforts, [DesktopReasoningEffort.high]);
    await tester.tap(find.byKey(const ValueKey('session-fast-switch')));
    expect(fasts, [DesktopFastMode.fast]);
    expect(find.text('Se aplica desde el próximo turno.'), findsOneWidget);
  });

  testWidgets('other reasoning levels stay reachable and visible', (
    tester,
  ) async {
    await pump(tester, effort: DesktopReasoningEffort.xhigh);
    // The current level is shown even if it is not one of the three.
    expect(
      tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'xhigh'))
          .selected,
      isTrue,
    );
    await tester.tap(find.text('Más niveles'));
    await tester.pump();
    await tester.tap(find.widgetWithText(ChoiceChip, 'minimal'));
    expect(efforts, [DesktopReasoningEffort.minimal]);
  });

  testWidgets('unsupported reasoning and fast mode say so, no controls', (
    tester,
  ) async {
    await pump(tester, reasoningSupported: false, fastSupported: false);
    expect(find.byType(ChoiceChip), findsNothing);
    expect(find.byKey(const ValueKey('session-fast-switch')), findsNothing);
    expect(
      find.text('Este modelo no admite razonamiento ajustable.'),
      findsOneWidget,
    );
    expect(find.text('Este modelo no admite modo rápido.'), findsOneWidget);
  });

  testWidgets('busy: nothing can be changed', (tester) async {
    await pump(tester, busy: true);
    await tester.tap(find.text('Opus 5'));
    await tester.tap(find.widgetWithText(ChoiceChip, 'Alto'));
    await tester.tap(find.byKey(const ValueKey('session-fast-switch')));
    expect(picks, isEmpty);
    expect(efforts, isEmpty);
    expect(fasts, isEmpty);
  });

  testWidgets('limits block only with real data', (tester) async {
    await pump(tester);
    expect(
      find.byKey(const ValueKey('subscription-limit-block')),
      findsNothing,
    );
    await pump(
      tester,
      limits: const SubscriptionLimits(
        kind: SubscriptionLimitKind.windows,
        plan: 'Claude Max 5x',
        windows: [SubscriptionLimitWindow(label: 'Semana', usedPercent: 38)],
      ),
    );
    expect(find.byKey(const ValueKey('subscription-limit-block')), findsOne);
    expect(find.text('Claude Max 5x'), findsOneWidget);
  });

  for (final width in [320.0, 360.0]) {
    testWidgets('fits at ${width.toInt()} dp with text at 200 %', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 900);
      addTearDown(tester.view.reset);
      await pump(tester, textScale: 2, locale: const Locale('en'));
      expect(tester.takeException(), isNull);
    });
  }
}
