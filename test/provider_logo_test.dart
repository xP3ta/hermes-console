import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/provider_logo.dart';

import 'support/provider_logo_probe.dart';

Future<void> _pumpLogo(
  WidgetTester tester,
  Widget logo, {
  ThemeData? theme,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: theme ?? AppTheme.hermesRedDark,
      home: Scaffold(body: Center(child: logo)),
    ),
  );
}

Color _paintedColor(WidgetTester tester) =>
    providerLogoTint(tester, find.byType(ProviderLogo));

void main() {
  group('resolveProviderLogo mapping', () {
    // (provider slug, provider name, model) -> brand id
    const cases = <(String?, String?, String?, String)>[
      // Provider slugs Hermes publishes.
      ('anthropic', null, null, 'anthropic'),
      ('claude-code', null, null, 'anthropic'),
      ('openai', null, null, 'openai'),
      ('openai-codex', null, null, 'openai'),
      ('gemini', null, null, 'gemini'),
      ('google', null, null, 'google'),
      ('openrouter', null, null, 'openrouter'),
      ('nous', null, null, 'nous'),
      ('copilot', null, null, 'githubcopilot'),
      ('huggingface', null, null, 'huggingface'),
      ('ai-gateway', null, null, 'vercel'),
      ('nvidia', null, null, 'nvidia'),
      ('ollama-cloud', null, null, 'ollama'),
      ('minimax-cn', null, null, 'minimax'),
      ('alibaba', null, null, 'alibaba'),
      ('qwen-oauth', null, null, 'alibaba'),
      ('xai', null, null, 'xai'),
      ('deepseek', null, null, 'deepseek'),
      ('mistral', null, null, 'mistral'),
      ('kimi-coding', null, null, 'moonshot'),
      ('zai', null, null, 'zai'),
      ('lmstudio', null, null, 'lmstudio'),
      ('cloudflare', null, null, 'cloudflare'),
      ('perplexity', null, null, 'perplexity'),
      // Custom endpoints: slug is opaque, the name tells.
      ('custom:box', 'Ollama box', null, 'ollama'),
      ('custom:lab', 'LM Studio lab', null, 'lmstudio'),
      ('custom:cpp', 'llama.cpp server', null, 'llamacpp'),
      // The model's own maker wins over the serving provider.
      ('openrouter', 'OpenRouter', 'anthropic/claude-sonnet-4.5', 'anthropic'),
      ('openrouter', null, 'claude-opus-4', 'anthropic'),
      (null, null, 'gpt-5.5', 'openai'),
      (null, null, 'o3-mini', 'openai'),
      (null, null, 'o4-mini-high', 'openai'),
      (null, null, 'gemini-2.5-pro', 'gemini'),
      (null, null, 'meta-llama/llama-3.3-70b-instruct', 'meta'),
      (null, null, 'llama3.1:8b', 'meta'),
      (null, null, 'qwen3:8b', 'alibaba'),
      (null, null, 'mixtral-8x7b', 'mistral'),
      (null, null, 'codestral-latest', 'mistral'),
      (null, null, 'deepseek-r1', 'deepseek'),
      (null, null, 'grok-4', 'xai'),
      ('openrouter', null, 'nousresearch/hermes-4-405b', 'nous'),
      (null, null, 'kimi-k2', 'moonshot'),
      (null, null, 'glm-4.6', 'zai'),
      (null, null, 'nemotron-70b', 'nvidia'),
      (null, null, 'MiniMax-M2', 'minimax'),
      // An unknown model on a known provider shows the provider.
      ('openrouter', null, 'mystery-model', 'openrouter'),
    ];
    for (final (slug, name, model, want) in cases) {
      test('$slug / $name / $model -> $want', () {
        expect(
          resolveProviderLogo(
            provider: slug,
            providerName: name,
            model: model,
          ).id,
          want,
        );
      });
    }

    test('words that merely contain a brand do not match', () {
      // "o3" only as a model family prefix; "photo3" or "solo3" are not.
      expect(resolveProviderLogo(model: 'photo3-large').id, 'monogram');
      expect(resolveProviderLogo(model: 'demo4').id, 'monogram');
    });

    test('unknown provider falls back to a monogram of its name', () {
      final spec = resolveProviderLogo(
        provider: 'custom:acme',
        providerName: 'acme labs',
        model: 'thing-7b',
      );
      expect(spec.id, 'monogram');
      expect(spec.hasGlyph, isFalse);
      expect(spec.monogram, 'A');
      expect(spec.label, 'acme labs');
    });

    test('nothing known at all still yields a monogram, never throws', () {
      final spec = resolveProviderLogo();
      expect(spec.id, 'monogram');
      expect(spec.monogram, isNotEmpty);
    });

    test(
      'brands with a permissive glyph carry one; the rest use monograms',
      () {
        for (final id in const [
          'anthropic',
          'gemini',
          'google',
          'meta',
          'mistral',
          'nvidia',
          'ollama',
          'huggingface',
          'cloudflare',
          'openrouter',
          'perplexity',
          'alibaba',
          'minimax',
          'githubcopilot',
          'vercel',
        ]) {
          expect(providerLogoSpecFor(id)!.hasGlyph, isTrue, reason: id);
        }
        for (final id in const [
          'openai',
          'deepseek',
          'xai',
          'nous',
          'moonshot',
          'zai',
          'lmstudio',
          'llamacpp',
        ]) {
          final spec = providerLogoSpecFor(id)!;
          expect(spec.hasGlyph, isFalse, reason: id);
          expect(spec.monogram, spec.label.characters.first.toUpperCase());
        }
      },
    );
  });

  group('ProviderLogo rendering', () {
    for (final (themeName, theme) in [
      ('dark', AppTheme.hermesRedDark),
      ('light', AppTheme.hermesRedLight),
    ]) {
      testWidgets('glyph is tinted with textSecondary ($themeName)', (
        tester,
      ) async {
        await _pumpLogo(
          tester,
          const ProviderLogo(provider: 'anthropic'),
          theme: theme,
        );
        expect(_paintedColor(tester), theme.hermes.textSecondary);
        expect(tester.getSize(find.byType(ProviderLogo)), const Size(18, 18));
      });

      testWidgets('selected glyph is tinted with the accent ($themeName)', (
        tester,
      ) async {
        await _pumpLogo(
          tester,
          const ProviderLogo(provider: 'anthropic', selected: true),
          theme: theme,
        );
        expect(_paintedColor(tester), theme.hermes.accent);
      });

      testWidgets('monogram is tinted with textSecondary ($themeName)', (
        tester,
      ) async {
        await _pumpLogo(
          tester,
          const ProviderLogo(provider: 'custom:x', providerName: 'Zeta box'),
          theme: theme,
        );
        expect(find.text('Z'), findsOneWidget);
        expect(_paintedColor(tester), theme.hermes.textSecondary);
      });
    }

    testWidgets('glyph paints real path data with the tint', (tester) async {
      await _pumpLogo(tester, const ProviderLogo(provider: 'openrouter'));
      final painter = tester
          .widgetList<CustomPaint>(
            find.descendant(
              of: find.byType(ProviderLogo),
              matching: find.byType(CustomPaint),
            ),
          )
          .map((p) => p.painter)
          .whereType<ProviderGlyphPainter>()
          .single;
      final bounds = painter.path.getBounds();
      expect(bounds.width, greaterThan(10));
      expect(bounds.height, greaterThan(10));
      expect(bounds.right, lessThanOrEqualTo(24.01));
      expect(bounds.bottom, lessThanOrEqualTo(24.01));
    });

    testWidgets('semantics label is the provider name', (tester) async {
      final handle = tester.ensureSemantics();
      await _pumpLogo(
        tester,
        const ProviderLogo(provider: 'openrouter', model: 'claude-opus-4'),
      );
      expect(find.bySemanticsLabel('Anthropic'), findsOneWidget);
      handle.dispose();
    });

    test('provider_logo.dart holds no brand colours', () {
      final source = File(
        'lib/core/widgets/provider_logo.dart',
      ).readAsStringSync();
      expect(source, isNot(matches(RegExp(r'Color\(0x|Colors\.'))));
      expect(source, isNot(contains('fill=')));
    });

    test('every glyph is credited in the third-party notice', () {
      final notice = File('ASSET_PROVENANCE.md');
      expect(notice.existsSync(), isTrue);
      final text = notice.readAsStringSync();
      expect(text, contains('CC0-1.0'));
      expect(text, contains('simple-icons@16.1.0'));
      for (final id in providerLogoGlyphSources.keys) {
        expect(
          text,
          contains('`${providerLogoGlyphSources[id]}`'),
          reason: '$id glyph source missing from ASSET_PROVENANCE.md',
        );
      }
    });
  });
}
