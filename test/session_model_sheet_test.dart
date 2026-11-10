import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/tokens.dart' show HermesChrome;
import 'package:hermes_android/core/models/desktop_session_config.dart';
import 'package:hermes_android/core/models/model_favorites.dart';
import 'package:hermes_android/core/models/model_provider.dart';
import 'package:hermes_android/core/models/provider_usage.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/theme_contrast.dart';
import 'package:hermes_android/core/widgets/pill_morph.dart';
import 'package:hermes_android/core/widgets/reasoning_squares_track.dart';
import 'package:hermes_android/core/widgets/session_model_sheet.dart';
import 'package:hermes_android/core/widgets/status_pill_sheet.dart';
import 'package:hermes_android/core/widgets/subscription_limit_block.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/l10n/app_localizations_es.dart';

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

const _local = ModelProvider(
  slug: 'local',
  name: 'Local',
  isCurrent: false,
  authenticated: true,
  authType: '',
  oauthProviderId: '',
  keyEnv: '',
  warning: '',
  source: 'local-runtime',
  models: ['hermes-8b'],
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
  'claude-sonnet-5-20251001': 'Sonnet 5',
  'claude-opus-5': 'Opus 5',
  'claude-haiku-5': 'Haiku 5',
};

void main() {
  late List<(String, String)> picks;
  late List<DesktopReasoningEffort> efforts;
  late List<DesktopFastMode> fasts;
  late int settingsOpened;
  late List<(String, String)> stars;

  setUp(() {
    stars = [];
    picks = [];
    efforts = [];
    fasts = [];
    settingsOpened = 0;
  });

  final allLink = find.byKey(const ValueKey('model-all-link'));
  final backButton = find.byKey(const ValueKey('msv-back'));

  /// Opens page two and lets the slide finish.
  Future<void> openAll(WidgetTester tester) async {
    await tester.tap(allLink);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

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
    bool reduceMotion = false,
    bool highContrast = false,
    Locale locale = const Locale('es'),
    String? profileName = 'Hermes',
    bool withSettingsLink = false,
    SessionModelCardInfo Function(String, String)? cardInfo,
    ModelFavorites favorites = ModelFavorites.empty,
    List<({String provider, String model})> frequent = const [],
    bool allModels = false,
    bool starsBlocked = false,
    ({String modelId, String? providerSlug})? currentModel,
    bool modelLoading = false,
  }) async {
    tester.view.devicePixelRatio = 1;
    if (tester.view.physicalSize.width > 500) {
      tester.view.physicalSize = const Size(420, 1400);
    }
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.fromId('amber'),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            disableAnimations: reduceMotion,
            highContrast: highContrast,
          ),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            child: SessionModelSheetBody(
              providers: providers,
              currentModel: currentModel,
              modelLoading: modelLoading,
              isSelected: (slug, id) =>
                  slug == selectedProvider && id == selectedModel,
              isSelectedProvider: (slug) => slug == selectedProvider,
              cardInfo: cardInfo ?? _info,
              profileName: profileName,
              onOpenModelSettings: withSettingsLink
                  ? () => settingsOpened++
                  : null,
              modelLabel: (id) => _labels[id] ?? id,
              onPick: busy ? null : (p, id) => picks.add((p.slug, id)),
              reasoning: effort,
              reasoningSupported: reasoningSupported,
              onReasoning: busy ? null : efforts.add,
              fastMode: fast,
              fastSupported: fastSupported,
              onFastMode: busy ? null : fasts.add,
              limits: limits,
              favorites: favorites,
              frequent: frequent,
              onToggleFavorite: starsBlocked
                  ? null
                  : (p, id) => stars.add((p.slug, id)),
            ),
          ),
        ),
      ),
    );
    if (allModels && allLink.evaluate().isNotEmpty) await openAll(tester);
  }

  final track = find.byKey(const ValueKey('model-picker-reasoning-track'));
  Finder pillOf(String slug) =>
      find.byKey(ValueKey('model-provider-pill-$slug'));
  final searchToggle = find.byKey(const ValueKey('model-search-toggle'));
  final searchField = find.byKey(const ValueKey('chat-model-search'));
  Finder row(String slug, String id) =>
      find.byKey(ValueKey('model-card-$slug-$id'));

  // Center of step [i] of the reasoning track.
  Offset stepAt(WidgetTester tester, int i) {
    final rect = tester.getRect(track);
    final usable = rect.width - 2 * kReasoningTrackInset;
    return Offset(
      rect.left + kReasoningTrackInset + usable * i / 7,
      rect.center.dy,
    );
  }

  String? labelText(WidgetTester tester) => tester
      .widget<Text>(find.byKey(const ValueKey('model-picker-reasoning-label')))
      .data;

  testWidgets('page one order: current model, reasoning, tiles, favourites', (
    tester,
  ) async {
    await pump(tester);
    double top(Finder f) => tester.getTopLeft(f).dy;
    expect(find.text('RAZONAMIENTO'), findsOneWidget);
    expect(find.text('FAVORITOS'), findsOneWidget);
    expect(find.text('Todos los modelos'), findsOneWidget);
    final order = [
      top(find.byKey(const ValueKey('msv-current'))),
      top(find.text('RAZONAMIENTO')),
      top(track),
      top(find.byKey(const ValueKey('msv-tile-think'))),
      top(find.text('FAVORITOS')),
      top(find.byKey(const ValueKey('msv-fav-anthropic-claude-sonnet-5'))),
      top(find.byKey(const ValueKey('msv-fav-hint'))),
      top(find.text('Se aplica desde el próximo turno.')),
      top(find.byKey(const ValueKey('model-picker-profile'))),
    ];
    for (var i = 1; i < order.length; i++) {
      expect(order[i], greaterThan(order[i - 1]), reason: 'block $i');
    }
    // The two switch chips share one row.
    final tiles = [
      for (final k in ['msv-tile-think', 'session-fast-switch'])
        tester.getTopLeft(find.byKey(ValueKey(k))).dy,
    ];
    expect(tiles.toSet(), hasLength(1));
    // The model list belongs to page two.
    expect(find.byKey(const ValueKey('model-picker-list')), findsNothing);
    expect(pillOf('anthropic'), findsNothing);
    expect(
      find.text(
        'Marca un modelo con la estrella en «Todos los modelos» '
        'para tenerlo aquí.',
      ),
      findsOneWidget,
    );
    expect(find.text('Perfil · Hermes'), findsOneWidget);
  });

  testWidgets('the current card names the model and its provider', (
    tester,
  ) async {
    await pump(tester);
    final card = find.byKey(const ValueKey('msv-current'));
    expect(
      find.descendant(of: card, matching: find.text('Sonnet 5')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: card, matching: find.text('Anthropic · Razona')),
      findsOneWidget,
    );
    // No model selected yet: it says so, and still opens page two.
    await pump(tester, selectedModel: 'none');
    expect(
      find.descendant(of: card, matching: find.text('Modelo no disponible')),
      findsOneWidget,
    );
    await tester.tap(card);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(backButton, findsOneWidget);
  });

  testWidgets('page two order: providers, models, search', (tester) async {
    await pump(tester, allModels: true);
    double top(Finder f) => tester.getTopLeft(f).dy;
    final models = find.byKey(const ValueKey('model-models-title'));
    // The back button, the title and the magnifier share a line.
    expect(
      tester.getCenter(searchToggle).dy,
      closeTo(tester.getCenter(backButton).dy, 1),
    );
    expect(find.text('Todos los modelos'), findsOneWidget);
    expect(find.text('MODELOS DE ANTHROPIC'), findsOneWidget);
    final order = [
      top(backButton),
      top(pillOf('anthropic')),
      top(models),
      top(row('anthropic', 'claude-sonnet-5')),
    ];
    for (var i = 1; i < order.length; i++) {
      expect(order[i], greaterThan(order[i - 1]), reason: 'block $i');
    }
    // Page one is gone, not hidden behind.
    expect(find.byKey(const ValueKey('msv-current')), findsNothing);
    expect(find.text('RAZONAMIENTO'), findsNothing);
    // Only the open provider's models are listed.
    expect(find.text('Opus 5'), findsOneWidget);
    expect(find.text('gpt-6'), findsNothing);
  });

  testWidgets('back returns to page one, the search closes on the way', (
    tester,
  ) async {
    await pump(tester, allModels: true);
    await tester.tap(searchToggle);
    await tester.pump();
    expect(searchField, findsOneWidget);
    await tester.tap(backButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('msv-current')), findsOneWidget);
    expect(track, findsOneWidget);
    expect(searchField, findsNothing);
    await openAll(tester);
    expect(searchField, findsNothing);
    expect(find.text('MODELOS DE ANTHROPIC'), findsOneWidget);
  });

  testWidgets('the pages slide; reduce motion swaps them at once', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(allLink);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    // Mid-way both pages are on screen and the second one is not in place.
    expect(find.byKey(const ValueKey('msv-current')), findsOneWidget);
    expect(backButton, findsOneWidget);
    final midLeft = tester.getTopLeft(backButton).dx;
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('msv-current')), findsNothing);
    expect(tester.getTopLeft(backButton).dx, lessThan(midLeft));

    await tester.pumpWidget(const SizedBox());
    await pump(tester, reduceMotion: true);
    await tester.tap(allLink);
    await tester.pump();
    expect(backButton, findsOneWidget);
    expect(find.byKey(const ValueKey('msv-current')), findsNothing);
  });

  testWidgets('provider pills: one per row, open one lists its models', (
    tester,
  ) async {
    await pump(tester, allModels: true);
    expect(pillOf('anthropic'), findsOneWidget);
    expect(pillOf('openai'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('provider-logo-picker-provider-anthropic')),
      findsOneWidget,
    );
    await tester.tap(pillOf('openai'));
    await tester.pump();
    expect(find.text('MODELOS DE OPENAI'), findsOneWidget);
    expect(find.text('gpt-6'), findsOneWidget);
    expect(find.text('Opus 5'), findsNothing);
    final semantics = tester.getSemantics(pillOf('openai'));
    expect(semantics.flagsCollection.isButton, isTrue);
    expect(semantics.flagsCollection.isSelected, Tristate.isTrue);
  });

  testWidgets('another account of a provider is another pill, told apart', (
    tester,
  ) async {
    const second = ModelProvider(
      slug: 'anthropic-work',
      name: 'Anthropic',
      isCurrent: false,
      authenticated: true,
      authType: '',
      oauthProviderId: '',
      keyEnv: '',
      warning: '',
      models: ['claude-sonnet-5'],
    );
    await pump(tester, providers: const [_anthropic, second], allModels: true);
    expect(pillOf('anthropic'), findsOneWidget);
    expect(pillOf('anthropic-work'), findsOneWidget);
    expect(find.text('Anthropic · anthropic'), findsOneWidget);
    expect(find.text('Anthropic · anthropic-work'), findsOneWidget);
  });

  group('provider dot', () {
    ModelProvider withUsage(ProviderUsage? usage, {bool auth = true}) =>
        ModelProvider(
          slug: 'p',
          name: 'P',
          isCurrent: false,
          authenticated: auth,
          authType: '',
          oauthProviderId: '',
          keyEnv: '',
          warning: '',
          models: const ['m'],
          usage: usage,
        );
    ProviderUsage windows(double used) => ProviderUsage(
      windows: [ProviderUsageWindow(label: 'w', usedPercent: used)],
    );

    test('ready, near the limit, down', () {
      ModelProviderStatus status(ModelProvider p, {bool usable = true}) =>
          modelProviderStatus(p, anyUsable: usable);
      expect(status(withUsage(null)), ModelProviderStatus.ready);
      expect(status(withUsage(windows(79))), ModelProviderStatus.ready);
      expect(status(withUsage(windows(80))), ModelProviderStatus.near);
      expect(status(withUsage(windows(100))), ModelProviderStatus.down);
      expect(status(withUsage(null, auth: false)), ModelProviderStatus.down);
      expect(status(withUsage(null), usable: false), ModelProviderStatus.down);
    });

    test('a pool: some limited is near, all limited is down', () {
      ProviderUsageAccount account(String id, ProviderUsageState state) =>
          ProviderUsageAccount(id: id, state: state);
      expect(
        modelProviderStatus(
          withUsage(
            ProviderUsage(
              accounts: [
                account('a', ProviderUsageState.ready),
                account('b', ProviderUsageState.limited),
              ],
            ),
          ),
          anyUsable: true,
        ),
        ModelProviderStatus.near,
      );
      expect(
        modelProviderStatus(
          withUsage(
            ProviderUsage(accounts: [account('a', ProviderUsageState.limited)]),
          ),
          anyUsable: true,
        ),
        ModelProviderStatus.down,
      );
    });

    testWidgets('green, amber and red dots in the theme colours', (
      tester,
    ) async {
      final near = ModelProvider(
        slug: 'anthropic',
        name: 'Anthropic',
        isCurrent: true,
        authenticated: true,
        authType: '',
        oauthProviderId: '',
        keyEnv: '',
        warning: '',
        models: const ['claude-sonnet-5'],
        usage: windows(91),
      );
      const down = ModelProvider(
        slug: 'openai',
        name: 'OpenAI',
        isCurrent: false,
        authenticated: false,
        authType: '',
        oauthProviderId: '',
        keyEnv: '',
        warning: '',
        models: ['gpt-6'],
      );
      await pump(tester, providers: [near, down, _local], allModels: true);
      final colors = AppTheme.fromId('amber').hermes;
      Color? dot(String slug) =>
          ((tester
                      .widget<DecoratedBox>(
                        find.byKey(ValueKey('model-provider-dot-$slug')),
                      )
                      .decoration)
                  as BoxDecoration)
              .color;
      expect(dot('anthropic'), colors.warning);
      expect(dot('openai'), colors.error);
      expect(dot('local'), colors.success);
    });
  });

  testWidgets('rows: round selector, no check, one short line on the right', (
    tester,
  ) async {
    await pump(tester, providers: const [_anthropic, _local], allModels: true);
    final active = row('anthropic', 'claude-sonnet-5');
    expect(
      find.descendant(
        of: active,
        matching: find.byKey(const ValueKey('model-select-dot-on')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: row('anthropic', 'claude-opus-5'),
        matching: find.byKey(const ValueKey('model-select-dot-off')),
      ),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.check_rounded), findsNothing);
    // 46 dp tall pills, the star and the round selector at their end.
    expect(tester.getSize(active).height, 46);
    expect(
      find.descendant(
        of: active,
        matching: find.byKey(
          const ValueKey('msv-star-anthropic-claude-sonnet-5'),
        ),
      ),
      findsOneWidget,
    );
    // Sonnet reasons and is fast: one tag, the first that applies.
    expect(
      find.descendant(of: active, matching: find.text('Razona')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: active, matching: find.text('Rápido')),
      findsNothing,
    );
    expect(
      find.descendant(
        of: row('anthropic', 'claude-haiku-5'),
        matching: find.text('Rápido'),
      ),
      findsOneWidget,
    );
    final handle = tester.ensureSemantics();
    final semantics = tester.getSemantics(
      find.bySemanticsLabel(RegExp(r'^Sonnet 5\.')),
    );
    expect(semantics.flagsCollection.isSelected, Tristate.isTrue);
    expect(semantics.flagsCollection.isButton, isTrue);
    handle.dispose();

    await tester.tap(pillOf('local'));
    await tester.pump();
    expect(
      find.descendant(
        of: row('local', 'hermes-8b'),
        matching: find.text('Local'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('tapping a row picks it; unavailable ones cannot be picked', (
    tester,
  ) async {
    await pump(tester, allModels: true);
    await tester.tap(find.text('Opus 5'));
    expect(picks, [('anthropic', 'claude-opus-5')]);
    // The active row is not re-applied.
    await tester.tap(find.text('Sonnet 5'));
    expect(picks, hasLength(1));

    await tester.tap(pillOf('openai'));
    await tester.pump();
    expect(
      find.descendant(
        of: row('openai', 'gpt-6-mini'),
        matching: find.text('no disponible'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('gpt-6-mini'));
    expect(picks, hasLength(1));
    // Unknown capabilities: no invented tags.
    for (final tag in ['Razona', 'Rápido', 'Sin coste']) {
      expect(
        find.descendant(of: row('openai', 'gpt-6'), matching: find.text(tag)),
        findsNothing,
        reason: tag,
      );
    }
  });

  testWidgets('models the friendly names cannot tell apart show their id', (
    tester,
  ) async {
    const twin = ModelProvider(
      slug: 'anthropic',
      name: 'Anthropic',
      isCurrent: true,
      authenticated: true,
      authType: '',
      oauthProviderId: '',
      keyEnv: '',
      warning: '',
      models: ['claude-sonnet-5', 'claude-sonnet-5-20251001', 'claude-opus-5'],
    );
    await pump(tester, providers: const [twin], allModels: true);
    expect(
      find.descendant(
        of: row('anthropic', 'claude-sonnet-5-20251001'),
        matching: find.textContaining('claude-sonnet-5-20251001'),
      ),
      findsOneWidget,
    );
    // A name that is unique stays clean.
    expect(
      find.descendant(
        of: row('anthropic', 'claude-opus-5'),
        matching: find.textContaining('claude-opus-5'),
      ),
      findsNothing,
    );
  });

  group('global search', () {
    testWidgets('the magnifier opens a pill field and closes it again', (
      tester,
    ) async {
      await pump(tester, allModels: true);
      expect(searchField, findsNothing);
      await tester.tap(searchToggle);
      await tester.pump();
      expect(searchField, findsOneWidget);
      await tester.enterText(searchField, 'mini');
      await tester.pump();
      expect(find.text('RESULTADOS'), findsOneWidget);
      await tester.tap(searchToggle);
      await tester.pump();
      expect(searchField, findsNothing);
      expect(find.text('MODELOS DE ANTHROPIC'), findsOneWidget);
    });

    testWidgets('looks in every provider, by id, name and provider', (
      tester,
    ) async {
      await pump(tester, allModels: true);
      await tester.tap(searchToggle);
      await tester.pump();
      await tester.enterText(searchField, 'mini');
      await tester.pump();
      // Another provider's model, with its provider named on the right.
      expect(row('openai', 'gpt-6-mini'), findsOneWidget);
      expect(
        find.descendant(
          of: row('openai', 'gpt-6-mini'),
          matching: find.textContaining('OpenAI'),
        ),
        findsOneWidget,
      );
      expect(find.text('Sonnet 5'), findsNothing);

      // The friendly name counts, not just the id (`claude-sonnet-5`).
      await tester.enterText(searchField, 'opus 5');
      await tester.pump();
      expect(row('anthropic', 'claude-opus-5'), findsOneWidget);
      expect(row('openai', 'gpt-6'), findsNothing);

      // A provider name lists all its models.
      await tester.enterText(searchField, 'openai');
      await tester.pump();
      expect(row('openai', 'gpt-6'), findsOneWidget);
      expect(row('openai', 'gpt-6-mini'), findsOneWidget);
    });

    testWidgets('marks the match and picking a result picks it', (
      tester,
    ) async {
      await pump(tester, allModels: true);
      await tester.tap(searchToggle);
      await tester.pump();
      await tester.enterText(searchField, 'pus');
      await tester.pump();
      final name = tester.widget<Text>(
        find
            .descendant(
              of: row('anthropic', 'claude-opus-5'),
              matching: find.byType(Text),
            )
            .first,
      );
      final marked = <String>[];
      name.textSpan!.visitChildren((span) {
        if (span is TextSpan && span.style?.color != null) {
          marked.add(span.text!);
        }
        return true;
      });
      expect(marked, ['pus']);
      await tester.tap(row('anthropic', 'claude-opus-5'));
      expect(picks, [('anthropic', 'claude-opus-5')]);
    });

    testWidgets('no match: says so and links to Settings > Models', (
      tester,
    ) async {
      await pump(tester, withSettingsLink: true, allModels: true);
      await tester.tap(searchToggle);
      await tester.pump();
      await tester.enterText(searchField, 'zzz');
      await tester.pump();
      expect(
        find.text('Ningún modelo coincide con la búsqueda.'),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('model-search-open-settings')),
      );
      expect(settingsOpened, 1);

      await tester.pumpWidget(const SizedBox());
      await pump(tester, allModels: true);
      await tester.tap(searchToggle);
      await tester.pump();
      await tester.enterText(searchField, 'zzz');
      await tester.pump();
      expect(
        find.byKey(const ValueKey('model-search-open-settings')),
        findsNothing,
      );
    });
  });

  testWidgets('free only: pill shows only with free models and filters', (
    tester,
  ) async {
    await pump(tester, allModels: true);
    expect(find.byKey(const ValueKey('model-free-only')), findsNothing);

    SessionModelCardInfo free(String slug, String id) => id == 'gpt-6'
        ? const SessionModelCardInfo(free: true)
        : _info(slug, id);
    await pump(tester, cardInfo: free, allModels: true);
    expect(find.byKey(const ValueKey('model-free-only')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('model-free-only')));
    await tester.pump();
    // The anthropic row had no free model: its pill goes, openai stays.
    expect(pillOf('anthropic'), findsNothing);
    expect(pillOf('openai'), findsOneWidget);
    expect(row('openai', 'gpt-6'), findsOneWidget);
    expect(row('openai', 'gpt-6-mini'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('model-free-only')));
    await tester.pump();
    expect(pillOf('anthropic'), findsOneWidget);
  });

  testWidgets('a long model list builds only what is on screen', (
    tester,
  ) async {
    final many = ModelProvider(
      slug: 'router',
      name: 'Router',
      isCurrent: true,
      authenticated: true,
      authType: '',
      oauthProviderId: '',
      keyEnv: '',
      warning: '',
      models: [for (var i = 0; i < 300; i++) 'model-$i'],
    );
    await pump(
      tester,
      providers: [many],
      selectedProvider: 'router',
      selectedModel: 'model-0',
      allModels: true,
    );
    expect(find.text('model-1'), findsOneWidget);
    expect(find.text('model-250'), findsNothing);
    await tester.drag(
      find.byKey(const ValueKey('model-picker-list')),
      const Offset(0, -400),
    );
    await tester.pump();
    expect(find.text('model-1'), findsNothing);
  });

  testWidgets('resolved model survives an incomplete or hidden catalog', (
    tester,
  ) async {
    await pump(
      tester,
      providers: const [],
      currentModel: (
        modelId: 'configured-model',
        providerSlug: 'custom-endpoint',
      ),
    );
    final card = find.byKey(const ValueKey('msv-current'));
    expect(
      find.descendant(of: card, matching: find.text('configured-model')),
      findsOne,
    );
    expect(
      find.descendant(of: card, matching: find.text('custom-endpoint')),
      findsOne,
    );
    expect(find.text('?'), findsNothing);
  });

  testWidgets(
    'unknown model has a loading state then displays the resolved default',
    (tester) async {
      await pump(tester, providers: const [], modelLoading: true);
      expect(find.text('Cargando modelo…'), findsOne);
      expect(find.text('?'), findsNothing);
      await pump(
        tester,
        currentModel: (modelId: 'gpt-6', providerSlug: 'openai'),
      );
      expect(find.text('Cargando modelo…'), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('msv-current')),
          matching: find.text('gpt-6'),
        ),
        findsOne,
      );
    },
  );

  group('tiles', () {
    final fast = find.byKey(const ValueKey('session-fast-switch'));
    final think = find.byKey(const ValueKey('msv-tile-think'));
    Finder stateOf(Finder tile, String text) =>
        find.descendant(of: tile, matching: find.text(text));

    testWidgets('fast mode is a tile that toggles', (tester) async {
      await pump(tester);
      expect(stateOf(fast, 'Normal'), findsOneWidget);
      await tester.tap(fast);
      expect(fasts, [DesktopFastMode.fast]);
      await pump(tester, fast: DesktopFastMode.fast);
      expect(stateOf(fast, 'Activo'), findsOneWidget);
      await tester.tap(fast);
      expect(fasts.last, DesktopFastMode.normal);
      expect(find.text('Se aplica desde el próximo turno.'), findsOneWidget);
    });

    testWidgets('only Razonar and Rápido: no Permisos tile (the chat status '
        'pill sets them), nothing invented', (tester) async {
      await pump(tester);
      expect(find.text('Contexto largo'), findsNothing);
      expect(think, findsOneWidget);
      expect(fast, findsOneWidget);
      expect(find.text('Razonar'), findsOneWidget);
      expect(find.text('Rápido'), findsOneWidget);
      expect(find.text('Permisos'), findsNothing);
      expect(find.byKey(const ValueKey('msv-tile-permissions')), findsNothing);
      expect(find.byIcon(Icons.shield_outlined), findsNothing);
    });

    testWidgets('selection buttons show icons and checked state, no switches', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pump(tester);
      expect(find.byKey(const ValueKey('msv-switch')), findsNothing);
      expect(find.byType(Switch), findsNothing);
      expect(find.byType(SwitchListTile), findsNothing);
      expect(find.byType(AnimatedAlign), findsNothing);
      for (final (tile, icon, checked) in [
        (think, Icons.auto_awesome_rounded, true),
        (fast, Icons.speed_rounded, false),
      ]) {
        expect(
          find.descendant(of: tile, matching: find.byIcon(icon)),
          findsOne,
        );
        expect(tester.getSize(tile).height, greaterThanOrEqualTo(48));
        expect(tester.getSize(tile).width, greaterThanOrEqualTo(48));
        final node = tester.getSemantics(tile);
        expect(node.flagsCollection.isButton, isTrue);
        expect(
          node.flagsCollection.isToggled,
          checked ? Tristate.isTrue : Tristate.isFalse,
        );
      }
      await pump(tester, fast: DesktopFastMode.fast);
      expect(
        find.descendant(
          of: fast,
          matching: find.byIcon(Icons.check_circle_rounded),
        ),
        findsOne,
      );
      handle.dispose();
    });

    testWidgets('a selection button can be activated through accessibility', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pump(tester);
      final node = tester.getSemantics(think);
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      node.owner!.performAction(node.id, SemanticsAction.tap);
      await tester.pump();
      expect(efforts, [DesktopReasoningEffort.none]);
      handle.dispose();
    });

    testWidgets('button glyph respects reduced motion', (tester) async {
      await pump(tester);
      Duration durationOf() => tester
          .widget<TweenAnimationBuilder<Color?>>(
            find.descendant(
              of: fast,
              matching: find.byType(TweenAnimationBuilder<Color?>),
            ),
          )
          .duration;
      expect(durationOf(), greaterThan(Duration.zero));
      expect(
        durationOf(),
        lessThanOrEqualTo(const Duration(milliseconds: 200)),
      );
      await pump(tester, reduceMotion: true);
      expect(durationOf(), Duration.zero);
    });

    testWidgets('unsupported buttons explain the reason and are inert', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      tester.view.physicalSize = const Size(320, 900);
      await pump(
        tester,
        reasoningSupported: false,
        fastSupported: false,
        textScale: 2,
      );
      expect(find.text('No disponible en este modelo'), findsNWidgets(2));
      for (final tile in [think, fast]) {
        final node = tester.getSemantics(tile);
        expect(node.flagsCollection.isEnabled, Tristate.isFalse);
        expect(node.flagsCollection.isButton, isTrue);
        expect(node.label, contains('No disponible en este modelo'));
        expect(tester.getSize(tile).height, greaterThanOrEqualTo(48));
        expect(tester.getSize(tile).width, greaterThanOrEqualTo(48));
        await tester.ensureVisible(tile);
        await tester.tap(tile);
      }
      expect(efforts, isEmpty);
      expect(fasts, isEmpty);
      expect(tester.takeException(), isNull);
      handle.dispose();
    });

    testWidgets('fast: not available on the model, dim and not selectable', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pump(tester, fastSupported: false);
      await tester.tap(fast);
      expect(fasts, isEmpty);
      final dim = tester.widget<Opacity>(
        find.descendant(of: fast, matching: find.byType(Opacity)),
      );
      expect(dim.opacity, lessThan(0.6));
      final node = tester.getSemantics(
        find.bySemanticsLabel(RegExp(r'^Rápido\.')),
      );
      expect(node.flagsCollection.isEnabled, Tristate.isFalse);
      expect(node.flagsCollection.isButton, isTrue);
      handle.dispose();
    });

    testWidgets('busy: the tiles do not act', (tester) async {
      await pump(tester, busy: true);
      await tester.tap(fast);
      await tester.tap(think);
      expect(fasts, isEmpty);
      expect(efforts, isEmpty);
    });

    testWidgets('Razonar sets the explicit «off» level and brings the last '
        'level back', (tester) async {
      await pump(tester, effort: DesktopReasoningEffort.high);
      expect(stateOf(think, 'Sí'), findsOneWidget);
      await tester.tap(think);
      expect(efforts, [DesktopReasoningEffort.none]);

      // Off: the tile says No and the pill is dim and does not answer.
      await pump(tester, effort: DesktopReasoningEffort.none);
      expect(stateOf(think, 'No'), findsOneWidget);
      expect(find.byKey(const ValueKey('msv-reasoning-dim')), findsOneWidget);
      await tester.tapAt(stepAt(tester, 5));
      expect(efforts, hasLength(1));
      expect(
        tester
            .widget<Opacity>(find.byKey(const ValueKey('msv-reasoning-dim')))
            .opacity,
        lessThan(0.6),
      );
      // On again: the level it had before, not a fixed one.
      await tester.tap(think);
      expect(efforts.last, DesktopReasoningEffort.high);

      await pump(tester, effort: DesktopReasoningEffort.high);
      expect(find.byKey(const ValueKey('msv-reasoning-dim')), findsNothing);
    });

    testWidgets('Razonar with no level before it goes to medium; the model '
        'default counts as reasoning', (tester) async {
      await pump(tester, effort: null);
      expect(stateOf(think, 'Sí'), findsOneWidget);
      await tester.tap(think);
      expect(efforts, [DesktopReasoningEffort.none]);

      await tester.pumpWidget(const SizedBox());
      efforts.clear();
      await pump(tester, effort: DesktopReasoningEffort.none);
      await tester.tap(think);
      expect(efforts, [DesktopReasoningEffort.medium]);
    });

    testWidgets('Razonar: a model that does not reason dims it and the pill', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pump(tester, reasoningSupported: false);
      expect(stateOf(think, 'No disponible en este modelo'), findsOneWidget);
      await tester.tap(think);
      expect(efforts, isEmpty);
      final dim = tester.widget<Opacity>(
        find.descendant(of: think, matching: find.byType(Opacity)),
      );
      expect(dim.opacity, lessThan(0.6));
      final node = tester.getSemantics(
        find.bySemanticsLabel(RegExp(r'^Razonar\.')),
      );
      expect(node.flagsCollection.isEnabled, Tristate.isFalse);
      handle.dispose();
    });

    testWidgets('large text, narrow screen, German: no overflow', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 640);
      await pump(tester, textScale: 1.3, locale: const Locale('de'));
      expect(tester.takeException(), isNull);
      for (final tile in [think, fast]) {
        expect(tester.getRect(tile).right, lessThanOrEqualTo(360));
        expect(tester.getRect(tile).left, greaterThanOrEqualTo(0));
      }
    });
  });

  group('favourites', () {
    const mini = (provider: 'openai', model: 'gpt-6-mini');
    final favs = ModelFavorites.empty
        .toggled('anthropic', 'claude-opus-5')
        .toggled('openai', 'gpt-6');

    Finder fav(String slug, String id) =>
        find.byKey(ValueKey('msv-fav-$slug-$id'));
    Finder star(String slug, String id) =>
        find.byKey(ValueKey('msv-star-$slug-$id'));

    testWidgets('starred models are listed in the order they were starred', (
      tester,
    ) async {
      await pump(tester, favorites: favs);
      expect(
        tester.getTopLeft(fav('anthropic', 'claude-opus-5')).dy,
        lessThan(tester.getTopLeft(fav('openai', 'gpt-6')).dy),
      );
      // The hint is for an empty list; the current model is not added.
      expect(find.byKey(const ValueKey('msv-fav-hint')), findsNothing);
      expect(fav('anthropic', 'claude-sonnet-5'), findsNothing);
      expect(
        find.descendant(
          of: fav('openai', 'gpt-6'),
          matching: find.text('OpenAI'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: fav('anthropic', 'claude-opus-5'),
          matching: find.text('Anthropic · Razona'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('a favourite is picked like any model, the star only stars', (
      tester,
    ) async {
      await pump(tester, favorites: favs);
      await tester.tap(find.text('Opus 5'));
      expect(picks, [('anthropic', 'claude-opus-5')]);
      expect(stars, isEmpty);
      await tester.tap(star('openai', 'gpt-6'));
      expect(stars, [('openai', 'gpt-6')]);
      expect(picks, hasLength(1));
    });

    testWidgets('the chosen favourite shows the filled selector', (
      tester,
    ) async {
      await pump(
        tester,
        favorites: favs,
        selectedProvider: 'openai',
        selectedModel: 'gpt-6',
      );
      expect(
        find.descendant(
          of: fav('openai', 'gpt-6'),
          matching: find.byKey(const ValueKey('model-select-dot-on')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: fav('anthropic', 'claude-opus-5'),
          matching: find.byKey(const ValueKey('model-select-dot-off')),
        ),
        findsOneWidget,
      );
    });

    testWidgets('the star is its own button for the screen reader', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pump(tester, favorites: favs);
      final node = tester.getSemantics(
        find.bySemanticsLabel('Quitar Opus 5 de favoritos'),
      );
      expect(node.flagsCollection.isButton, isTrue);
      expect(node.flagsCollection.isToggled, Tristate.isTrue);
      expect(find.bySemanticsLabel(RegExp(r'^Opus 5\. ')), findsOneWidget);
      handle.dispose();
    });

    testWidgets('no favourites: the current model, the frequent ones and the '
        'hint', (tester) async {
      await pump(tester, frequent: const [mini]);
      expect(fav('anthropic', 'claude-sonnet-5'), findsOneWidget);
      expect(find.text('FRECUENTES'), findsOneWidget);
      expect(fav('openai', 'gpt-6-mini'), findsOneWidget);
      expect(find.byKey(const ValueKey('msv-fav-hint')), findsOneWidget);
      // Unstarred: its star adds it.
      await tester.tap(star('anthropic', 'claude-sonnet-5'));
      expect(stars, [('anthropic', 'claude-sonnet-5')]);
      // The unusable frequent one cannot be picked.
      await tester.tap(fav('openai', 'gpt-6-mini'));
      expect(picks, isEmpty);

      await pump(tester);
      expect(find.text('FRECUENTES'), findsNothing);
    });

    testWidgets('a favourite the catalog no longer lists is not shown', (
      tester,
    ) async {
      final gone = favs.toggled('anthropic', 'claude-retired');
      await pump(tester, favorites: gone);
      expect(fav('anthropic', 'claude-retired'), findsNothing);
      expect(fav('anthropic', 'claude-opus-5'), findsOneWidget);
    });

    testWidgets('a full list: stars of other models are dim, stars on stay', (
      tester,
    ) async {
      var full = ModelFavorites.empty;
      for (var i = 0; i < ModelFavorites.maxEntries; i++) {
        full = full.toggled('anthropic', 'claude-opus-5-x$i');
      }
      expect(full.isFull, isTrue);
      expect(full.toggled('openai', 'gpt-6'), same(full));
      const many = ModelProvider(
        slug: 'anthropic',
        name: 'Anthropic',
        isCurrent: true,
        authenticated: true,
        authType: '',
        oauthProviderId: '',
        keyEnv: '',
        warning: '',
        models: [
          'claude-sonnet-5',
          'claude-opus-5-x0',
          'claude-opus-5-x1',
          'claude-opus-5-x2',
          'claude-opus-5-x3',
          'claude-opus-5-x4',
          'claude-opus-5-x5',
          'claude-opus-5-x6',
          'claude-opus-5-x7',
          'claude-opus-5-x8',
          'claude-opus-5-x9',
          'claude-opus-5-x10',
          'claude-opus-5-x11',
        ],
      );
      await pump(
        tester,
        providers: const [many],
        favorites: full,
        allModels: true,
      );
      await tester.tap(
        star('anthropic', 'claude-sonnet-5'),
        warnIfMissed: false,
      );
      expect(stars, isEmpty, reason: 'a full list takes no more');
      await tester.tap(star('anthropic', 'claude-opus-5-x0'));
      expect(stars, [('anthropic', 'claude-opus-5-x0')]);
    });

    testWidgets('page two: a star marks, a filled one unmarks', (tester) async {
      await pump(tester, favorites: favs, allModels: true);
      expect(
        find.descendant(
          of: star('anthropic', 'claude-opus-5'),
          matching: find.byIcon(Icons.star_rounded),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: star('anthropic', 'claude-haiku-5'),
          matching: find.byIcon(Icons.star_outline_rounded),
        ),
        findsOneWidget,
      );
      await tester.tap(star('anthropic', 'claude-haiku-5'));
      await tester.tap(star('anthropic', 'claude-opus-5'));
      expect(stars, [
        ('anthropic', 'claude-haiku-5'),
        ('anthropic', 'claude-opus-5'),
      ]);
      // Starring never picks the row.
      expect(picks, isEmpty);
    });

    testWidgets('page two: stars are inert when nothing can change them', (
      tester,
    ) async {
      await pump(tester, favorites: favs, allModels: true, starsBlocked: true);
      await tester.tap(
        star('anthropic', 'claude-haiku-5'),
        warnIfMissed: false,
      );
      expect(stars, isEmpty);
    });

    testWidgets('search results carry their stars too', (tester) async {
      await pump(tester, allModels: true);
      await tester.tap(searchToggle);
      await tester.pump();
      await tester.enterText(searchField, 'mini');
      await tester.pump();
      await tester.tap(star('openai', 'gpt-6-mini'), warnIfMissed: false);
      expect(stars, [('openai', 'gpt-6-mini')]);
    });
  });

  testWidgets('the profile is named quietly at the foot, or not at all', (
    tester,
  ) async {
    await pump(tester, profileName: 'Lucía');
    expect(find.text('Perfil · Lucía'), findsOneWidget);
    await pump(tester, profileName: null);
    expect(find.byKey(const ValueKey('model-picker-profile')), findsNothing);
  });

  group('reasoning slider', () {
    testWidgets('live label follows the level; the phrase lives in semantics', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pump(tester);
      expect(find.text('RAZONAMIENTO'), findsOneWidget);
      expect(labelText(tester), 'Medio');
      expect(
        tester.getSemantics(track).hint,
        'Equilibrio entre velocidad, calidad y coste.',
      );
      // No long phrase on screen.
      expect(
        find.text('Equilibrio entre velocidad, calidad y coste.'),
        findsNothing,
      );
      await pump(tester, effort: DesktopReasoningEffort.ultra);
      expect(labelText(tester), 'Ultra');
      expect(
        tester.getSemantics(track).hint,
        'Piensa a fondo: más lento y más caro.',
      );
      await pump(tester, effort: DesktopReasoningEffort.none);
      expect(labelText(tester), 'Apagado');
      expect(tester.getSemantics(track).hint, contains('Sin razonamiento'));
      await pump(tester, effort: null);
      expect(labelText(tester), 'Predeterminado');
      handle.dispose();
    });

    testWidgets('the thumb is a ball: hollow when off, glowing otherwise', (
      tester,
    ) async {
      final squares = find.descendant(
        of: find.byKey(const ValueKey('model-picker-reasoning-squares')),
        matching: find.byType(CustomPaint),
      );
      await pump(tester, effort: DesktopReasoningEffort.none);
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        tester.renderObject(squares),
        paints
          ..circle(style: PaintingStyle.fill)
          ..circle(style: PaintingStyle.stroke),
      );
      expect(
        tester.renderObject(squares),
        isNot(paints..circle(hasMaskFilter: true)),
      );
      await pump(tester, effort: DesktopReasoningEffort.high);
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        tester.renderObject(squares),
        paints
          ..circle(hasMaskFilter: true)
          ..circle(),
      );
      // No text inside the pill: the level is named under it.
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('model-picker-reasoning-squares')),
          matching: find.byType(Text),
        ),
        findsNothing,
      );
    });

    testWidgets('level names sit under their steps, a mark under the current', (
      tester,
    ) async {
      await pump(tester);
      tester.view.physicalSize = const Size(1000, 1400);
      await tester.pump();
      for (final (i, name) in [(2, 'Bajo'), (4, 'Alto')]) {
        expect(
          tester.getCenter(find.text(name)).dx,
          closeTo(stepAt(tester, i).dx, 1.5),
          reason: name,
        );
        expect(
          tester.getTopLeft(find.text(name)).dy,
          greaterThan(
            tester.getRect(find.byType(ReasoningSquaresTrack)).bottom,
          ),
          reason: name,
        );
      }
      final mark = find.byKey(const ValueKey('model-picker-reasoning-mark'));
      expect(mark, findsOneWidget);
      expect(tester.getCenter(mark).dx, closeTo(stepAt(tester, 3).dx, 1.5));
      await pump(tester, effort: DesktopReasoningEffort.xhigh);
      expect(
        tester
            .getCenter(
              find.byKey(const ValueKey('model-picker-reasoning-mark')),
            )
            .dx,
        closeTo(stepAt(tester, 5).dx, 1.5),
      );
    });

    testWidgets('a tap on a step applies that level once', (tester) async {
      await pump(tester);
      await tester.tapAt(stepAt(tester, 4));
      await tester.pump();
      expect(efforts, [DesktopReasoningEffort.high]);
      // Tapping the current step changes nothing.
      efforts.clear();
      await tester.tapAt(stepAt(tester, 3));
      expect(efforts, isEmpty);
    });

    testWidgets('a drag previews every step and applies once on release', (
      tester,
    ) async {
      await pump(tester);
      final haptics = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            haptics.add(call.arguments as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final gesture = await tester.startGesture(stepAt(tester, 3));
      await gesture.moveTo(stepAt(tester, 6));
      await tester.pump();
      expect(labelText(tester), 'Máximo');
      expect(efforts, isEmpty);
      await gesture.moveTo(stepAt(tester, 5));
      await tester.pump();
      expect(labelText(tester), 'Muy alto');
      await gesture.up();
      await tester.pump();
      expect(efforts, [DesktopReasoningEffort.xhigh]);
      expect(haptics, isNotEmpty);
      expect(haptics, everyElement('HapticFeedbackType.selectionClick'));
    });

    testWidgets('semantics: value, neighbours and increase / decrease', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pump(tester);
      var node = tester.getSemantics(track);
      expect(node.value, 'Medio');
      expect(node.label, 'Razonamiento');
      expect(node.increasedValue, 'Alto');
      expect(node.decreasedValue, 'Bajo');
      expect(node.getSemanticsData().hasAction(SemanticsAction.increase), true);
      node.owner!.performAction(node.id, SemanticsAction.increase);
      node.owner!.performAction(node.id, SemanticsAction.decrease);
      expect(efforts, [
        DesktopReasoningEffort.high,
        DesktopReasoningEffort.low,
      ]);

      // At the ends there is nothing further to reach.
      await pump(tester, effort: DesktopReasoningEffort.ultra);
      node = tester.getSemantics(track);
      expect(
        node.getSemanticsData().hasAction(SemanticsAction.increase),
        false,
      );
      expect(node.getSemanticsData().hasAction(SemanticsAction.decrease), true);
      handle.dispose();
    });

    testWidgets('arrow keys move one step each', (tester) async {
      await pump(tester);
      await tester.tapAt(stepAt(tester, 3));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      expect(efforts, [DesktopReasoningEffort.high]);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      expect(efforts.last, DesktopReasoningEffort.low);
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      expect(efforts.last, DesktopReasoningEffort.ultra);
    });

    testWidgets('unsupported by the model: disabled, with the reason', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pump(tester, reasoningSupported: false);
      expect(
        find.text('Este modelo no admite razonamiento ajustable.'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('model-picker-reasoning-label')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('model-picker-reasoning-dim')),
        findsOneWidget,
      );
      await tester.tapAt(stepAt(tester, 5));
      expect(efforts, isEmpty);
      final node = tester.getSemantics(track);
      expect(
        node.getSemanticsData().hasAction(SemanticsAction.increase),
        false,
      );
      handle.dispose();
    });

    testWidgets('busy: shown but not changeable', (tester) async {
      await pump(tester, busy: true);
      expect(labelText(tester), 'Medio');
      await tester.tapAt(stepAt(tester, 5));
      final gesture = await tester.startGesture(stepAt(tester, 3));
      await gesture.moveTo(stepAt(tester, 6));
      await gesture.up();
      expect(efforts, isEmpty);
    });

    testWidgets('reduce motion moves the thumb without animating', (
      tester,
    ) async {
      Duration thumbDuration() => tester
          .widget<TweenAnimationBuilder<double>>(
            find.descendant(
              of: track,
              matching: find.byType(TweenAnimationBuilder<double>),
            ),
          )
          .duration;
      await pump(tester, reduceMotion: true);
      expect(thumbDuration(), Duration.zero);
      await pump(tester);
      expect(thumbDuration(), isNot(Duration.zero));
    });

    testWidgets('the track is a grid of squares that blinks', (tester) async {
      await pump(tester);
      final squares = find.byKey(
        const ValueKey('model-picker-reasoning-squares'),
      );
      expect(squares, findsOneWidget);
      expect(tester.getSize(squares).height, kReasoningSquaresHeight);
      final paint = find.descendant(
        of: squares,
        matching: find.byType(CustomPaint),
      );
      expect(tester.renderObject(paint), paints..rect());
      // The blinking runs: a ticker keeps asking for frames.
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.binding.transientCallbackCount, greaterThan(0));
    });

    testWidgets('density of lit squares grows with the level', (tester) async {
      for (final width in [300.0, 380.0, 900.0, 4000.0]) {
        final grid = ReasoningSquaresGrid.fit(
          Size(width, kReasoningSquaresHeight),
        );
        expect(grid.cells, lessThanOrEqualTo(kReasoningSquaresMaxCells));
        var previous = -1;
        for (var level = 1; level < 8; level++) {
          final p = level / 7;
          final lit = grid.litCount(
            p,
            reasoningThumbX(width, kReasoningTrackInset, p),
          );
          expect(
            lit,
            greaterThan(previous),
            reason: 'width $width level $level',
          );
          previous = lit;
        }
        // Deterministic: the same level always lights the same squares.
        expect(
          grid.litCount(0.5, reasoningThumbX(width, kReasoningTrackInset, 0.5)),
          grid.litCount(0.5, reasoningThumbX(width, kReasoningTrackInset, 0.5)),
        );
      }
    });

    testWidgets('colour warms from the accent as the level grows', (
      tester,
    ) async {
      final colors = AppTheme.fromId('amber').hermes;
      final low = HSLColor.fromColor(reasoningSquaresColor(colors, 0));
      final high = HSLColor.fromColor(reasoningSquaresColor(colors, 1));
      expect(low.toColor(), colors.accent);
      expect(high.toColor(), isNot(low.toColor()));
      expect(high.lightness, greaterThan(low.lightness));
    });

    testWidgets('reduce motion: no ticker, still picture', (tester) async {
      await pump(tester, reduceMotion: true);
      await tester.pumpAndSettle();
      expect(tester.binding.transientCallbackCount, 0);
      // A change of level does not start one either.
      await tester.tapAt(stepAt(tester, 5));
      await tester.pumpAndSettle();
      expect(tester.binding.transientCallbackCount, 0);
    });

    testWidgets('no ticker once the sheet is gone', (tester) async {
      await pump(tester);
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.binding.transientCallbackCount, greaterThan(0));
      await tester.pumpWidget(const SizedBox());
      expect(tester.binding.transientCallbackCount, 0);
    });

    testWidgets('high contrast: plain track, no squares, no ticker', (
      tester,
    ) async {
      await pump(tester, highContrast: true);
      await tester.pumpAndSettle();
      expect(find.byType(ReasoningSquaresTrack), findsNothing);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.tapAt(stepAt(tester, 6));
      expect(efforts, [DesktopReasoningEffort.max]);
    });

    testWidgets('a wide sheet writes every level name, the active one in '
        'bold', (tester) async {
      await pump(tester);
      tester.view.physicalSize = const Size(1000, 1400);
      await tester.pump();
      TextStyle? styleOf(String text) =>
          tester.widget<Text>(find.text(text)).style;
      expect(find.byType(ReasoningLevelLabels), findsOneWidget);
      for (final name in [
        'Apagado',
        'Mínimo',
        'Bajo',
        'Alto',
        'Muy alto',
        'Máximo',
        'Ultra',
      ]) {
        expect(styleOf(name)?.fontWeight, FontWeight.w400, reason: name);
      }
      final active = tester
          .widgetList<Text>(find.text('Medio'))
          .firstWhere((t) => t.style?.fontWeight == FontWeight.w700);
      expect(active.style?.color, AppTheme.fromId('amber').hermes.accentText);
    });

    testWidgets('a phone: marks for every step, names only at the ends and '
        'under the active one (bold, accent)', (tester) async {
      await pump(tester);
      final labels = find.byType(ReasoningLevelLabels);
      Finder name(String text) =>
          find.descendant(of: labels, matching: find.text(text));
      expect(name('Apagado'), findsOneWidget);
      expect(name('Ultra'), findsOneWidget);
      expect(name('Medio'), findsOneWidget);
      for (final gone in ['Mínimo', 'Bajo', 'Alto', 'Muy alto', 'Máximo']) {
        expect(name(gone), findsNothing, reason: gone);
      }
      final active = tester.widget<Text>(name('Medio'));
      expect(active.style?.fontWeight, FontWeight.w700);
      expect(active.style?.color, AppTheme.fromId('amber').hermes.accentText);
      expect(
        tester.widget<Text>(name('Apagado')).style?.fontWeight,
        FontWeight.w400,
      );
      // The active name moves with the level and the end it would touch
      // gives way (its name is also in the header).
      await pump(tester, effort: DesktopReasoningEffort.minimal);
      expect(name('Mínimo'), findsOneWidget);
      expect(name('Medio'), findsNothing);
      await pump(tester, effort: DesktopReasoningEffort.minimal, textScale: 2);
      expect(name('Mínimo'), findsOneWidget);
      expect(name('Apagado'), findsNothing);
      await pump(tester, effort: DesktopReasoningEffort.ultra);
      expect(
        tester.widget<Text>(name('Ultra')).style?.fontWeight,
        FontWeight.w700,
      );
    });

    for (final lang in ['es', 'en', 'pt', 'de', 'fr', 'it', 'ja', 'ko', 'zh']) {
      testWidgets('level names never overlap or get cut: $lang, text x1 and '
          'x2, 320 and 360 dp wide', (tester) async {
        for (final width in [320.0, 360.0]) {
          for (final scale in [1.0, 2.0]) {
            for (final effort in [
              DesktopReasoningEffort.none,
              DesktopReasoningEffort.minimal,
              DesktopReasoningEffort.medium,
              DesktopReasoningEffort.max,
              DesktopReasoningEffort.ultra,
            ]) {
              await tester.pumpWidget(const SizedBox());
              tester.view.physicalSize = Size(width, 1400);
              await pump(
                tester,
                effort: effort,
                textScale: scale,
                locale: Locale(lang),
              );
              final why = '$lang ${width.toInt()} x$scale ${effort.wire}';
              expect(tester.takeException(), isNull, reason: why);
              final box = tester.getRect(find.byType(ReasoningLevelLabels));
              final fitted = find.descendant(
                of: find.byType(ReasoningLevelLabels),
                matching: find.byType(FittedBox),
              );
              final count = fitted.evaluate().length;
              expect(count, inInclusiveRange(1, 8), reason: why);
              final rects = [
                for (var i = 0; i < count; i++) tester.getRect(fitted.at(i)),
              ];
              for (var i = 0; i < count; i++) {
                expect(rects[i].left, greaterThanOrEqualTo(box.left - 0.01));
                expect(rects[i].right, lessThanOrEqualTo(box.right + 0.01));
                // Fitted down, but still legible (the test font is far wider
                // than a real one): never below half of its size.
                final text = tester.getSize(
                  find
                      .descendant(of: fitted.at(i), matching: find.byType(Text))
                      .first,
                );
                expect(
                  rects[i].width / text.width,
                  greaterThanOrEqualTo(0.5),
                  reason: '$why: label $i fitted too small',
                );
                for (var j = i + 1; j < count; j++) {
                  expect(
                    rects[i].inflate(2).overlaps(rects[j]),
                    isFalse,
                    reason: '$why: labels $i and $j touch',
                  );
                }
              }
            }
          }
        }
      });
    }

    testWidgets('a drag lands on the nearest step and applies once', (
      tester,
    ) async {
      await pump(tester);
      final gesture = await tester.startGesture(stepAt(tester, 3));
      await gesture.moveTo(stepAt(tester, 4) + const Offset(-6, 0));
      await tester.pump();
      expect(labelText(tester), 'Alto');
      await gesture.moveTo(stepAt(tester, 2));
      await gesture.up();
      await tester.pump();
      expect(efforts, [DesktopReasoningEffort.low]);
    });

    testWidgets('large text on a narrow screen: no overflow', (tester) async {
      tester.view.physicalSize = const Size(320, 1400);
      await pump(tester, textScale: 2, locale: const Locale('de'));
      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.byType(ReasoningLevelLabels)).width,
        lessThanOrEqualTo(320),
      );
    });

    testWidgets('large text: wraps, still reachable', (tester) async {
      tester.view.physicalSize = const Size(320, 1400);
      await pump(tester, textScale: 2, locale: const Locale('de'));
      expect(tester.takeException(), isNull);
      await tester.tapAt(stepAt(tester, 7));
      expect(efforts, [DesktopReasoningEffort.ultra]);
    });
  });

  testWidgets('busy: no model can be picked', (tester) async {
    await pump(tester, busy: true, allModels: true);
    await tester.tap(find.text('Opus 5'));
    expect(picks, isEmpty);
    await tester.tap(backButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const ValueKey('session-fast-switch')));
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

  group('pinned layout in the real sheet', () {
    const five = ModelProvider(
      slug: 'anthropic',
      name: 'Anthropic',
      isCurrent: true,
      authenticated: true,
      authType: '',
      oauthProviderId: '',
      keyEnv: '',
      warning: '',
      models: ['m-1', 'm-2', 'm-3', 'm-4', 'm-5', 'm-6'],
    );
    final starred = ModelFavorites.empty
        .toggled('anthropic', 'm-2')
        .toggled('anthropic', 'm-3')
        .toggled('anthropic', 'm-4')
        .toggled('anthropic', 'm-5')
        .toggled('anthropic', 'm-6');

    Future<void> openSheet(
      WidgetTester tester, {
      required Size size,
      double textScale = 1,
      String theme = 'amber',
      String locale = 'es',
      List<ModelProvider> providers = const [five],
      String selectedModel = 'm-1',
      ModelFavorites? favorites,
    }) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          locale: Locale(locale),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          theme: AppTheme.fromId(theme),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(textScale),
              disableAnimations: true,
            ),
            child: child!,
          ),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showStatusPillSheet<void>(
                  context: context,
                  surfaceKey: const ValueKey('chat-model-dialog'),
                  title: 'Modelo y sesión',
                  subtitle: 'Se aplicará al crear esta conversación',
                  scrollBody: false,
                  maxHeightFactor: 0.9,
                  builder: (_) => SessionModelSheetBody(
                    providers: providers,
                    isSelected: (slug, id) => id == selectedModel,
                    isSelectedProvider: (slug) => true,
                    cardInfo: (slug, id) =>
                        const SessionModelCardInfo(reasoning: true),
                    profileName: 'Hermes',
                    modelLabel: (id) => id,
                    onPick: (p, id) => picks.add((p.slug, id)),
                    reasoning: DesktopReasoningEffort.medium,
                    reasoningSupported: true,
                    onReasoning: efforts.add,
                    fastMode: DesktopFastMode.normal,
                    fastSupported: true,
                    onFastMode: fasts.add,
                    favorites: favorites ?? starred,
                    onToggleFavorite: (p, id) => stars.add((p.slug, id)),
                  ),
                ),
                child: const Text('abrir'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('abrir'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    }

    void expectInView(WidgetTester tester, Finder f, Size screen, String why) {
      expect(f, findsOneWidget, reason: why);
      final r = tester.getRect(f);
      expect(r.top, greaterThanOrEqualTo(0), reason: '$why: top');
      expect(r.bottom, lessThanOrEqualTo(screen.height), reason: '$why: foot');
      expect(r.left, greaterThanOrEqualTo(0), reason: '$why: left');
      expect(r.right, lessThanOrEqualTo(screen.width), reason: '$why: right');
      expect(f.hitTestable(), findsOneWidget, reason: '$why: hit');
    }

    Future<void> toPageTwo(WidgetTester tester) async {
      await tester.tap(allLink);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    }

    for (final (height, scale) in [
      (640.0, 1.3),
      (800.0, 1.3),
      (800.0, 1.0),
      (640.0, 1.0),
    ]) {
      testWidgets('page one at ${height.toInt()} dp, text x$scale: the model, '
          'the reasoning pill with every level and the tiles are in view; '
          'only the favourites scroll', (tester) async {
        final size = Size(400, height);
        await openSheet(tester, size: size, textScale: scale);
        expect(tester.takeException(), isNull);
        // No scroll around the whole body, no scroll of the sheet itself.
        expect(find.byKey(const ValueKey('status-sheet-scroll')), findsNothing);
        expectInView(
          tester,
          find.byKey(const ValueKey('msv-current')),
          size,
          'current model',
        );
        expectInView(tester, track, size, 'reasoning track');
        final Strings strings = StringsEs();
        for (final effort in [
          DesktopReasoningEffort.none,
          DesktopReasoningEffort.medium,
          DesktopReasoningEffort.ultra,
        ]) {
          expectInView(
            tester,
            find.descendant(
              of: find.byType(ReasoningLevelLabels),
              matching: find.text(reasoningEffortLabel(strings, effort)),
            ),
            size,
            'level ${effort.wire}',
          );
        }
        for (final key in ['msv-tile-think', 'session-fast-switch']) {
          expectInView(tester, find.byKey(ValueKey(key)), size, key);
        }
        expectInView(tester, allLink, size, 'all models link');
        // The favourites are the scrolling part, and sit under the pill.
        final scroll = find.byKey(const ValueKey('msv-fav-scroll'));
        expect(scroll, findsOneWidget);
        expect(
          tester.getTopLeft(scroll).dy,
          greaterThan(tester.getBottomLeft(track).dy),
        );
        expect(tester.getBottomLeft(scroll).dy, lessThanOrEqualTo(size.height));
        // There is room for a whole favourite in it.
        expect(
          tester.getSize(scroll).height,
          greaterThanOrEqualTo(60),
          reason: 'room left for the favourites',
        );
        // Favourites remain reachable below the plan limits and their heading.
        final first = find.byKey(const ValueKey('msv-fav-anthropic-m-2'));
        expect(first, findsOneWidget);
        await tester.ensureVisible(first);
        await tester.pump();
        expect(
          tester.getRect(first).bottom,
          lessThanOrEqualTo(tester.getBottomLeft(scroll).dy),
        );
        // Dragging the favourites moves them, never the pill above.
        final trackTop = tester.getTopLeft(track).dy;
        final position = tester
            .state<ScrollableState>(
              find.descendant(of: scroll, matching: find.byType(Scrollable)),
            )
            .position;
        await tester.drag(scroll, const Offset(0, -2000));
        await tester.pump();
        expect(position.pixels, closeTo(position.maxScrollExtent, 0.5));
        expect(tester.getTopLeft(track).dy, trackTop);
        expectInView(tester, track, size, 'reasoning track after the drag');
      });
    }

    testWidgets('page one at 360 x 640, German, text x1.3: nothing overflows', (
      tester,
    ) async {
      const size = Size(360, 640);
      await openSheet(tester, size: size, textScale: 1.3, locale: 'de');
      expect(tester.takeException(), isNull);
      expectInView(tester, track, size, 'reasoning track');
      for (final key in ['msv-tile-think', 'session-fast-switch']) {
        expectInView(tester, find.byKey(ValueKey(key)), size, key);
      }
    });

    for (final (height, scale) in [(640.0, 1.3), (800.0, 1.3), (800.0, 1.0)]) {
      testWidgets('page two at ${height.toInt()} dp, text x$scale: back, '
          'providers, search and 3 models are all in view', (tester) async {
        final size = Size(400, height);
        await openSheet(tester, size: size, textScale: scale);
        await toPageTwo(tester);
        expect(tester.takeException(), isNull);
        expect(find.byKey(const ValueKey('status-sheet-scroll')), findsNothing);
        expectInView(tester, backButton, size, 'back');
        expectInView(tester, pillOf('anthropic'), size, 'provider pill');
        expectInView(tester, searchToggle, size, 'magnifier');
        final list = tester.getRect(
          find.byKey(const ValueKey('model-picker-list')),
        );
        var whole = 0;
        for (final id in ['m-1', 'm-2', 'm-3', 'm-4', 'm-5', 'm-6']) {
          final rows = row('anthropic', id);
          if (rows.evaluate().isEmpty) continue;
          final r = tester.getRect(rows);
          if (r.top >= list.top && r.bottom <= list.bottom) whole++;
        }
        expect(whole, greaterThanOrEqualTo(3), reason: 'whole model rows');
        // The first row is not cut by the top of the list.
        expect(
          tester.getRect(row('anthropic', 'm-1')).top,
          greaterThanOrEqualTo(list.top),
        );
        expect(tester.getSize(row('anthropic', 'm-1')).height, 46);
      });
    }

    testWidgets('a single provider still shows its row and the magnifier', (
      tester,
    ) async {
      await openSheet(tester, size: const Size(400, 640), textScale: 1.3);
      await toPageTwo(tester);
      expect(find.byKey(const ValueKey('model-provider-row')), findsOneWidget);
      expect(pillOf('anthropic').hitTestable(), findsOneWidget);
      expect(searchToggle.hitTestable(), findsOneWidget);
    });

    testWidgets('a chosen model far down the list is brought into view', (
      tester,
    ) async {
      await openSheet(
        tester,
        size: const Size(400, 640),
        textScale: 1.3,
        selectedModel: 'm-6',
      );
      await toPageTwo(tester);
      await tester.pump();
      final list = tester.getRect(
        find.byKey(const ValueKey('model-picker-list')),
      );
      final chosen = row('anthropic', 'm-6');
      expect(chosen, findsOneWidget);
      expect(tester.getRect(chosen).bottom, lessThanOrEqualTo(list.bottom));
      expect(tester.getRect(chosen).top, greaterThanOrEqualTo(list.top));
      // Revealing it never scrolled the provider row's ancestors away.
      expect(pillOf('anthropic').hitTestable(), findsOneWidget);
    });

    testWidgets('picking a favourite in the real sheet picks it', (
      tester,
    ) async {
      await openSheet(tester, size: const Size(400, 800));
      await tester.tap(find.byKey(const ValueKey('msv-fav-anthropic-m-3')));
      expect(picks, [('anthropic', 'm-3')]);
    });

    for (final id in ['amber', 'console', 'console-light', 'classic-dark']) {
      testWidgets('theme $id: the sheet is opaque, outlines and selector '
          'rings read on it', (tester) async {
        await openSheet(tester, size: const Size(400, 800), theme: id);
        final colors = AppTheme.fromId(id).hermes;
        final chrome = HermesChrome.of(colors);
        final surface = tester.widget<PillMorphSurface>(
          find.byType(PillMorphSurface),
        );
        expect(surface.color.a, 1.0, reason: 'opaque sheet');
        expect(surface.color, chrome.opaque);

        Material materialOf(Finder f) => tester.widget<Material>(
          find.descendant(of: f, matching: find.byType(Material)).first,
        );
        Color outlineOf(Material m) => (m.shape! as StadiumBorder).side.color;
        Color ringOf(Finder f) {
          final dot =
              tester
                      .widget<DecoratedBox>(
                        find
                            .descendant(
                              of: f,
                              matching: find.byKey(
                                const ValueKey('model-select-dot-off'),
                              ),
                            )
                            .first,
                      )
                      .decoration
                  as BoxDecoration;
          return (dot.border! as Border).top.color;
        }

        // Page one: a favourite, a tile at rest and the chosen state.
        final favourite = find.byKey(const ValueKey('msv-fav-anthropic-m-2'));
        final tile = find.byKey(const ValueKey('msv-tile-think'));
        final fast = find.byKey(const ValueKey('session-fast-switch'));
        for (final resting in [materialOf(favourite), materialOf(fast)]) {
          for (final bg in [chrome.opaque, chrome.raised]) {
            expect(
              ThemeContrast.ratio(outlineOf(resting), bg),
              greaterThanOrEqualTo(1.4),
              reason: 'outline on $bg',
            );
          }
          expect(resting.color, chrome.raised);
        }
        for (final bg in [chrome.opaque, chrome.raised]) {
          expect(
            ThemeContrast.ratio(ringOf(favourite), bg),
            greaterThanOrEqualTo(3.0),
            reason: 'selector ring on $bg',
          );
        }
        expect(outlineOf(materialOf(tile)), colors.accent);
        expect(
          outlineOf(materialOf(find.byKey(const ValueKey('msv-current')))),
          colors.accent,
        );
        // The unstarred glyph reads as a control (3:1) on the pill.
        expect(
          ThemeContrast.ratio(colors.textSecondary, chrome.raised),
          greaterThanOrEqualTo(3.0),
        );

        // Page two: the same, for the list.
        await toPageTwo(tester);
        final resting = materialOf(row('anthropic', 'm-2'));
        for (final bg in [chrome.opaque, chrome.raised]) {
          expect(
            ThemeContrast.ratio(outlineOf(resting), bg),
            greaterThanOrEqualTo(1.4),
            reason: 'row outline on $bg',
          );
          expect(
            ThemeContrast.ratio(ringOf(row('anthropic', 'm-2')), bg),
            greaterThanOrEqualTo(3.0),
            reason: 'selector ring on $bg',
          );
        }
        expect(resting.color, chrome.raised);
        // The chosen row: accent outline, a soft accent fill, a filled dot.
        final chosen = materialOf(row('anthropic', 'm-1'));
        expect(outlineOf(chosen), colors.accent);
        expect(chosen.color, isNot(chrome.raised));
        final dotOn = find.descendant(
          of: row('anthropic', 'm-1'),
          matching: find.byKey(const ValueKey('model-select-dot-on')),
        );
        expect(
          find.descendant(
            of: dotOn,
            matching: find.byWidgetPredicate(
              (w) =>
                  w is DecoratedBox &&
                  w.decoration is BoxDecoration &&
                  (w.decoration as BoxDecoration).color == colors.accent,
            ),
          ),
          findsOneWidget,
        );
      });
    }
  });
}
