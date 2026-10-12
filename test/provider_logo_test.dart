import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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

/// Every brand id that must paint a real glyph, from either source.
const _glyphBrands = [
  // Simple Icons 16.1.0 (CC0-1.0).
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
  // LobeHub Icons 1.95.1 (MIT).
  'openai',
  'deepseek',
  'xai',
  'nous',
  'moonshot',
  'zai',
  'microsoft',
  'lmstudio',
];

ProviderGlyphPainter _glyphPainter(WidgetTester tester) => tester
    .widgetList<CustomPaint>(
      find.descendant(
        of: find.byType(ProviderLogo),
        matching: find.byType(CustomPaint),
      ),
    )
    .map((p) => p.painter)
    .whereType<ProviderGlyphPainter>()
    .single;

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
        for (final id in _glyphBrands) {
          expect(providerLogoSpecFor(id)!.hasGlyph, isTrue, reason: id);
        }
        // No permissively licensed mark exists for llama.cpp.
        for (final id in const ['llamacpp']) {
          final spec = providerLogoSpecFor(id)!;
          expect(spec.hasGlyph, isFalse, reason: id);
          expect(spec.monogram, spec.label.characters.first.toUpperCase());
        }
      },
    );

    test('Microsoft models and Azure resolve to the Microsoft mark', () {
      expect(resolveProviderLogo(model: 'phi-4').id, 'microsoft');
      expect(resolveProviderLogo(provider: 'azure').id, 'microsoft');
      expect(resolveProviderLogo(model: 'phi-4').hasGlyph, isTrue);
    });
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

    for (final (what, logo) in [
      for (final id in _glyphBrands)
        ('$id glyph', ProviderLogo(provider: id, size: 48)),
      ('monogram', const ProviderLogo(providerName: 'Zeta box', size: 48)),
    ]) {
      testWidgets('every painted pixel of the $what is the theme tint', (
        tester,
      ) async {
        final key = GlobalKey();
        final theme = AppTheme.hermesRedLight;
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Center(
              child: RepaintBoundary(key: key, child: logo),
            ),
          ),
        );
        final tint = theme.hermes.textSecondary;
        final bytes = await tester.runAsync(() async {
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await boundary.toImage();
          return (await image.toByteData(
            format: ui.ImageByteFormat.rawStraightRgba,
          ))!;
        });
        var inked = 0;
        int channel(double c) => (c * 255).round();
        for (var i = 0; i < bytes!.lengthInBytes; i += 4) {
          final a = bytes.getUint8(i + 3);
          if (a < 128) continue;
          inked++;
          final got = [
            bytes.getUint8(i),
            bytes.getUint8(i + 1),
            bytes.getUint8(i + 2),
          ];
          final want = [channel(tint.r), channel(tint.g), channel(tint.b)];
          // Straight-alpha unpremultiplication may round by a unit or two.
          for (var c = 0; c < 3; c++) {
            if ((got[c] - want[c]).abs() > 3) {
              fail('pixel ${i ~/ 4} is $got, not the tint $want');
            }
          }
        }
        expect(inked, greaterThan(100), reason: 'the $what painted nothing');
        if (what != 'monogram') {
          expect(
            tester
                .widget<ProviderLogo>(find.byType(ProviderLogo))
                .spec
                .hasGlyph,
            isTrue,
            reason: '$what fell back to a monogram',
          );
        }
      });
    }

    testWidgets('glyph paints real path data with the tint', (tester) async {
      await _pumpLogo(tester, const ProviderLogo(provider: 'openrouter'));
      final painter = _glyphPainter(tester);
      final bounds = painter.path.getBounds();
      expect(bounds.width, greaterThan(10));
      expect(bounds.height, greaterThan(10));
      expect(bounds.right, lessThanOrEqualTo(24.01));
      expect(bounds.bottom, lessThanOrEqualTo(24.01));
    });

    testWidgets('glyphs keep their holes (OpenAI centre)', (tester) async {
      await _pumpLogo(tester, const ProviderLogo(provider: 'openai'));
      final path = _glyphPainter(tester).path;
      // The hexagon in the middle of the OpenAI knot is a hole; the knot
      // band around it is ink.
      expect(path.contains(const Offset(12, 12)), isFalse);
      expect(path.contains(const Offset(12, 15.6)), isTrue);
    });

    test(
      'LobeHub glyphs fill the same as under their even-odd source rule',
      () {
        // The app fills with non-zero; a glyph whose holes depend on the
        // even-odd rule would paint wrong, so every point must agree.
        for (final MapEntry(key: id, value: parts)
            in providerLogoLobeGlyphPaths.entries) {
          for (final d in parts) {
            final nonZero = parseSvgPathData(d);
            final evenOdd = parseSvgPathData(d)
              ..fillType = ui.PathFillType.evenOdd;
            for (var y = 0.05; y < 24; y += 0.1) {
              for (var x = 0.05; x < 24; x += 0.1) {
                final p = Offset(x, y);
                if (nonZero.contains(p) != evenOdd.contains(p)) {
                  fail('$id differs at $p between fill rules');
                }
              }
            }
          }
        }
      },
    );

    test('arc flags packed with a fractional number parse as flags', () {
      // "00.5.5" is large-arc 0, sweep 0, then the point (.5, .5).
      final packed = parseSvgPathData('M0 0a1 1 0 00.5.5l1 1').getBounds();
      final spaced = parseSvgPathData('M0 0a1 1 0 0 0 .5 .5l1 1').getBounds();
      expect(packed, spaced);
      expect(packed.bottomRight, const Offset(1.5, 1.5));
    });

    testWidgets('multi-path glyphs paint every source path', (tester) async {
      // Microsoft: four separate squares, one <path> each.
      await _pumpLogo(tester, const ProviderLogo(provider: 'microsoft'));
      final path = _glyphPainter(tester).path;
      for (final p in const [
        Offset(6, 6),
        Offset(18, 6),
        Offset(6, 18),
        Offset(18, 18),
      ]) {
        expect(path.contains(p), isTrue, reason: '$p');
      }
      expect(path.contains(const Offset(12, 12)), isFalse);
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

    test('glyph data files hold no colours or fills', () {
      for (final f in const [
        'lib/core/widgets/provider_logo_glyphs.dart',
        'lib/core/widgets/provider_logo_glyphs_lobehub.dart',
      ]) {
        final source = File(f).readAsStringSync();
        expect(
          source,
          isNot(matches(RegExp(r'Color\(|Colors\.|#[0-9a-fA-F]{6}'))),
          reason: f,
        );
        expect(source, isNot(matches(RegExp(r'fill[-=]|opacity'))), reason: f);
      }
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

    test('every LobeHub glyph is credited with its MIT notice', () {
      final provenance = File('ASSET_PROVENANCE.md').readAsStringSync();
      final notices = File('THIRD_PARTY_NOTICES.md').readAsStringSync();
      final reuse = File('REUSE.toml').readAsStringSync();
      expect(providerLogoLobeGlyphSources, isNotEmpty);
      // Every painted LobeHub glyph has a source entry, and vice versa.
      expect(
        providerLogoLobeGlyphSources.keys.toSet(),
        providerLogoLobeGlyphPaths.keys.toSet(),
      );
      expect(provenance, contains('@lobehub/icons-static-svg@1.95.1'));
      expect(provenance, contains(lobeHubIconsCommit));
      expect(notices, contains('Copyright (c) 2023 LobeHub'));
      expect(notices, contains('Permission is hereby granted, free of charge'));
      expect(
        reuse,
        contains('path = "lib/core/widgets/provider_logo_glyphs_lobehub.dart"'),
      );
      for (final MapEntry(key: id, value: file)
          in providerLogoLobeGlyphSources.entries) {
        expect(
          provenance,
          contains('`icons/$file.svg`'),
          reason: '$id glyph source missing from ASSET_PROVENANCE.md',
        );
        expect(providerLogoSpecFor(id)?.hasGlyph, isTrue, reason: id);
      }
      // Each glyph has exactly one source.
      expect(
        providerLogoLobeGlyphSources.keys.toSet().intersection(
          providerLogoGlyphSources.keys.toSet(),
        ),
        isEmpty,
      );
    });
  });
}
