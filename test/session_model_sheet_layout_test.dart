import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/account_usage_limits.dart';
import 'package:hermes_android/core/models/desktop_session_config.dart';
import 'package:hermes_android/core/models/model_favorites.dart';
import 'package:hermes_android/core/models/model_provider.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/account_limits_section.dart';
import 'package:hermes_android/core/widgets/session_model_sheet.dart';
import 'package:hermes_android/core/widgets/status_pill_sheet.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'support/design_shots.dart';

final _providers = [
  ModelProvider.fromJson({
    'slug': 'openai-codex',
    'name': 'ChatGPT',
    'authenticated': true,
    'models': ['gpt-6.1-sol'],
    'usage': {
      'accounts': [
        {'id': 'synthetic-1', 'state': 'unknown'},
        {'id': 'synthetic-2', 'state': 'unknown'},
      ],
    },
  }),
  ModelProvider.fromJson({
    'slug': 'anthropic',
    'name': 'Anthropic',
    'authenticated': true,
    'models': ['claude-sonnet-5.5', 'claude-opus-5.5'],
    'usage': {
      'accounts': [
        {
          'id': 'synthetic-3',
          'label': 'Personal',
          'state': 'ready',
          'windows': [
            {
              'label': 'Weekly',
              'used_percent': 91,
              'resets_at': '2026-11-07T04:00:00Z',
            },
          ],
        },
      ],
    },
  }),
];

void main() {
  for (final (width, scale) in [(412.0, 1.0), (320.0, 2.0)]) {
    testWidgets('plan limits before favourites, ${width.toInt()} dp x$scale', (
      tester,
    ) async {
      final limits = ValueNotifier<AccountUsageLimits?>(
        // This deliberately has an old route: presentation uses the same
        // effective provider as the composer, even before usage refreshes.
        AccountUsageLimits.fromProviderUsage(
          _providers,
          sessionProvider: 'openai-codex',
          now: DateTime.utc(2026, 11, 4),
        ),
      );
      addTearDown(limits.dispose);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 900);
      addTearDown(tester.view.reset);
      await loadDesignFonts();
      await tester.pumpWidget(
        RepaintBoundary(
          key: designShotKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            locale: const Locale('es'),
            localizationsDelegates: Strings.localizationsDelegates,
            supportedLocales: Strings.supportedLocales,
            theme: AppTheme.fromId('indigo-glass'),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showStatusPillSheet<void>(
                    context: context,
                    surfaceKey: const ValueKey('model-sheet-layout'),
                    title: Strings.of(context).chaModelSheetTitle,
                    scrollBody: false,
                    maxHeightFactor: 0.9,
                    builder: (_) => SessionModelSheetBody(
                      currentModel: (
                        modelId: 'claude-opus-5.5',
                        providerSlug: 'anthropic',
                      ),
                      providers: _providers,
                      isSelected: (slug, id) =>
                          slug == 'anthropic' && id == 'claude-opus-5.5',
                      isSelectedProvider: (slug) => slug == 'anthropic',
                      cardInfo: (_, _) => const SessionModelCardInfo(
                        reasoning: true,
                        fast: false,
                      ),
                      modelLabel: (id) => switch (id) {
                        'claude-opus-5.5' => 'Opus 5.5',
                        'claude-sonnet-5.5' => 'Sonnet 5.5',
                        _ => 'GPT-6.1-sol',
                      },
                      onPick: (_, _) {},
                      reasoning: DesktopReasoningEffort.high,
                      reasoningSupported: true,
                      onReasoning: (_) {},
                      fastMode: DesktopFastMode.normal,
                      fastSupported: false,
                      onFastMode: null,
                      accountLimits: limits,
                      favorites: ModelFavorites.empty
                          .toggled('anthropic', 'claude-sonnet-5.5')
                          .toggled('openai-codex', 'gpt-6.1-sol'),
                    ),
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
      final section = find.byType(AccountLimitsSection);
      expect(MediaQuery.textScalerOf(tester.element(section)).scale(1), scale);
      expect(
        tester.getSize(find.text('Todos los modelos')).height,
        lessThanOrEqualTo(48),
      );
      if (scale > 1.3) {
        final detail = tester.widget<Text>(
          find.text('Anthropic · Personal · Razona'),
        );
        expect(detail.maxLines, isNull);
        expect(detail.overflow, isNull);
      }
      final favorites = find.text('FAVORITOS');
      expect(
        tester.getTopLeft(section).dy,
        lessThan(tester.getTopLeft(favorites).dy),
      );
      expect(find.text('Sin datos de este proveedor'), findsOne);
      expect(find.textContaining('Uso aún sin informar'), findsNothing);
      expect(find.text('Cerca del límite'), findsOne);
      expect(find.text('Quedan 9 %'), findsOne);
      expect(find.textContaining('Se reinicia en'), findsOne);
      expect(
        tester.getTopLeft(find.text('Anthropic · Personal')).dy,
        lessThan(tester.getTopLeft(find.text('ChatGPT')).dy),
      );
      final bars = find.descendant(
        of: section,
        matching: find.byType(LinearProgressIndicator),
      );
      expect(bars, findsOne);
      final bar = tester.widget<LinearProgressIndicator>(bars);
      expect(bar.value, closeTo(0.91, 0.001));
      expect(bar.borderRadius, isNotNull);
      expect(bar.minHeight, greaterThanOrEqualTo(8));
      await saveDesignShot(tester, 'model-sheet-${width.toInt()}-x$scale');
      // Every row remains reachable in the same scroll region at large type.
      await tester.ensureVisible(find.text('Quedan 9 %'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await saveDesignShot(
        tester,
        'model-sheet-limits-${width.toInt()}-x$scale',
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('msv-fav-openai-codex-gpt-6.1-sol')),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  }
}
