import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'provider_logo_glyphs.dart';
import 'provider_logo_glyphs_lobehub.dart';

export 'provider_logo_glyphs.dart' show providerLogoGlyphSources;
export 'provider_logo_glyphs_lobehub.dart'
    show
        lobeHubIconsCommit,
        providerLogoLobeGlyphPaths,
        providerLogoLobeGlyphSources;

/// Identity of the company behind a model or provider: a display name, plus
/// a monochrome glyph when a permissively licensed one exists (Simple Icons,
/// CC0-1.0, or LobeHub Icons, MIT). Without a glyph the logo is a monogram
/// of [label].
@immutable
class ProviderLogoSpec {
  const ProviderLogoSpec(this.id, this.label);

  /// Stable brand id (`anthropic`, `openai`, …) or `monogram` when unknown.
  final String id;

  /// Provider name, used as the accessibility label.
  final String label;

  bool get hasGlyph =>
      providerLogoGlyphPaths.containsKey(id) ||
      providerLogoLobeGlyphPaths.containsKey(id);

  /// The glyph in a 24x24 box, or null for a monogram.
  ui.Path? get glyphPath => hasGlyph ? _glyphPath(id) : null;

  String get monogram {
    final match = RegExp(r'[A-Za-z0-9]').firstMatch(label);
    return match == null ? '?' : match.group(0)!.toUpperCase();
  }
}

const Map<String, String> _labels = {
  'anthropic': 'Anthropic',
  'openai': 'OpenAI',
  'gemini': 'Google Gemini',
  'google': 'Google',
  'meta': 'Meta',
  'mistral': 'Mistral AI',
  'nvidia': 'NVIDIA',
  'ollama': 'Ollama',
  'huggingface': 'Hugging Face',
  'cloudflare': 'Cloudflare',
  'openrouter': 'OpenRouter',
  'perplexity': 'Perplexity',
  'alibaba': 'Alibaba Cloud',
  'minimax': 'MiniMax',
  'githubcopilot': 'GitHub Copilot',
  'vercel': 'Vercel',
  'deepseek': 'DeepSeek',
  'xai': 'xAI',
  'nous': 'Nous Research',
  'moonshot': 'Moonshot AI',
  'zai': 'Z.ai',
  'microsoft': 'Microsoft',
  'lmstudio': 'LM Studio',
  'llamacpp': 'llama.cpp',
};

/// The spec of a known brand id, or null.
ProviderLogoSpec? providerLogoSpecFor(String id) {
  final label = _labels[id];
  return label == null ? null : ProviderLogoSpec(id, label);
}

/// Model families, matched against each word of a model id in order, so
/// `deepseek-r1-distill-qwen` is DeepSeek's and `o3-mini` is OpenAI's while
/// `photo3` matches nothing.
final List<(RegExp, String)> _modelRules = [
  (RegExp(r'^claude'), 'anthropic'),
  (
    RegExp(r'^(gpt|chatgpt|davinci|dall)|^o[134](mini|pro|preview)?$'),
    'openai',
  ),
  (RegExp(r'^gemini'), 'gemini'),
  (RegExp(r'^gemma'), 'google'),
  (RegExp(r'^(llama|meta)'), 'meta'),
  (RegExp(r'^(qwen|qwq)'), 'alibaba'),
  (
    RegExp(
      r'^(mistral|mixtral|codestral|devstral|magistral|ministral|pixtral)',
    ),
    'mistral',
  ),
  (RegExp(r'^deepseek'), 'deepseek'),
  (RegExp(r'^grok'), 'xai'),
  (RegExp(r'^(hermes|nous)'), 'nous'),
  (RegExp(r'^(kimi|moonshot)'), 'moonshot'),
  (RegExp(r'^(glm|chatglm|zhipu)'), 'zai'),
  (RegExp(r'^nemotron'), 'nvidia'),
  (RegExp(r'^(minimax|abab)'), 'minimax'),
  (RegExp(r'^sonar'), 'perplexity'),
  (RegExp(r'^phi\d*$'), 'microsoft'),
];

/// Provider slugs and names. Long keys match anywhere in the compacted text
/// (`Ollama box`, `openai-codex`, `LM Studio`); short keys must be a whole
/// word so `nous` or `xai` never match inside another name.
const List<(String, String)> _providerRules = [
  ('llamacpp', 'llamacpp'),
  ('lmstudio', 'lmstudio'),
  ('anthropic', 'anthropic'),
  ('claude', 'anthropic'),
  ('openrouter', 'openrouter'),
  ('openai', 'openai'),
  ('codex', 'openai'),
  ('gemini', 'gemini'),
  ('google', 'google'),
  ('vertex', 'google'),
  ('copilot', 'githubcopilot'),
  ('huggingface', 'huggingface'),
  ('hf', 'huggingface'),
  ('aigateway', 'vercel'),
  ('vercel', 'vercel'),
  ('nvidia', 'nvidia'),
  ('nim', 'nvidia'),
  ('ollama', 'ollama'),
  ('minimax', 'minimax'),
  ('alibaba', 'alibaba'),
  ('dashscope', 'alibaba'),
  ('qwen', 'alibaba'),
  ('deepseek', 'deepseek'),
  ('mistral', 'mistral'),
  ('xai', 'xai'),
  ('grok', 'xai'),
  ('nous', 'nous'),
  ('kimi', 'moonshot'),
  ('moonshot', 'moonshot'),
  ('zai', 'zai'),
  ('zhipu', 'zai'),
  ('glm', 'zai'),
  ('cloudflare', 'cloudflare'),
  ('perplexity', 'perplexity'),
  ('meta', 'meta'),
  ('microsoft', 'microsoft'),
  ('azure', 'microsoft'),
];

final RegExp _wordSplit = RegExp(r'[^a-z0-9]+');

List<String> _words(String text) =>
    text.toLowerCase().split(_wordSplit).where((w) => w.isNotEmpty).toList();

String? _modelBrand(String model) {
  for (final word in _words(model)) {
    for (final (rule, id) in _modelRules) {
      if (rule.hasMatch(word)) return id;
    }
  }
  return null;
}

String? _providerBrand(String text) {
  final words = _words(text);
  if (words.isEmpty) return null;
  final compact = words.join();
  for (final (key, id) in _providerRules) {
    if (key.length > 4 ? compact.contains(key) : words.contains(key)) {
      return id;
    }
  }
  return null;
}

/// One lookup for every surface that names a model or a provider. The
/// model's own maker wins (Claude served by OpenRouter shows Anthropic);
/// then the serving provider by slug, by display name, by the model's
/// `vendor/` prefix; otherwise a monogram of the best name available.
ProviderLogoSpec resolveProviderLogo({
  String? provider,
  String? providerName,
  String? model,
}) {
  final slug = (provider ?? '').replaceFirst(RegExp(r'^custom:'), '');
  final m = model ?? '';
  final slash = m.indexOf('/');
  final id =
      _modelBrand(m) ??
      _providerBrand(slug) ??
      _providerBrand(providerName ?? '') ??
      (slash > 0 ? _providerBrand(m.substring(0, slash)) : null);
  if (id != null) return providerLogoSpecFor(id)!;
  final name = [
    providerName,
    slug,
    model,
  ].firstWhere((v) => v != null && v.trim().isNotEmpty, orElse: () => '?')!;
  return ProviderLogoSpec('monogram', name.trim());
}

/// Monochrome provider mark, tinted with the theme (secondary text, or the
/// accent when [selected]). Never paints brand colours.
class ProviderLogo extends StatelessWidget {
  const ProviderLogo({
    super.key,
    this.provider,
    this.providerName,
    this.model,
    this.size = 18,
    this.selected = false,
    this.color,
  });

  final String? provider;
  final String? providerName;
  final String? model;
  final double size;
  final bool selected;

  /// Explicit tint (e.g. disabled rows). Defaults to the theme tokens.
  final Color? color;

  ProviderLogoSpec get spec => resolveProviderLogo(
    provider: provider,
    providerName: providerName,
    model: model,
  );

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final tint = color ?? (selected ? colors.accent : colors.textSecondary);
    final s = spec;
    final glyph = s.glyphPath;
    return Semantics(
      label: s.label,
      image: true,
      excludeSemantics: true,
      child: SizedBox.square(
        dimension: size,
        child: glyph != null
            ? CustomPaint(
                painter: ProviderGlyphPainter(path: glyph, color: tint),
              )
            : Container(
                key: const ValueKey('provider-logo-monogram'),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(size * 0.28),
                  border: Border.all(color: tint, width: 1.2),
                ),
                child: Text(
                  s.monogram,
                  textScaler: TextScaler.noScaling,
                  style: TextStyle(
                    color: tint,
                    fontSize: size * 0.58,
                    fontWeight: FontWeight.w700,
                    height: 1,
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
      ),
    );
  }
}

final Map<String, ui.Path> _glyphCache = {};

/// Simple Icons glyphs are one path. LobeHub glyphs may have several
/// `<path>`s, unioned so each one paints. Their sources declare the even-odd
/// rule, but every shipped glyph fills identically under non-zero, which a
/// test checks for each glyph.
ui.Path _glyphPath(String id) => _glyphCache.putIfAbsent(id, () {
  final simple = providerLogoGlyphPaths[id];
  if (simple != null) return parseSvgPathData(simple);
  return providerLogoLobeGlyphPaths[id]!
      .map(parseSvgPathData)
      .reduce((a, b) => ui.Path.combine(ui.PathOperation.union, a, b));
});

/// Paints a 24x24 glyph path scaled to its box in a single [color].
class ProviderGlyphPainter extends CustomPainter {
  ProviderGlyphPainter({required this.path, required this.color});

  final ui.Path path;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);
    canvas.drawPath(path, Paint()..color = color);
    canvas.restore();
  }

  @override
  bool shouldRepaint(ProviderGlyphPainter old) =>
      old.color != color || old.path != path;
}

/// Minimal SVG path-data parser (M L H V C S Q T A Z, absolute and
/// relative), enough for single-path brand glyphs.
ui.Path parseSvgPathData(String data) {
  final path = ui.Path();
  final tokens = RegExp(
    r'[MmLlHhVvCcSsQqTtAaZz]|[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?',
  ).allMatches(data).map((m) => m.group(0)!).toList();
  var i = 0;
  var cmd = '';
  var x = 0.0, y = 0.0, startX = 0.0, startY = 0.0;
  var ctrlX = 0.0, ctrlY = 0.0;
  var prev = '';
  bool isCmd(String t) => RegExp(r'^[A-Za-z]$').hasMatch(t);
  double num() => double.parse(tokens[i++]);
  bool flag() {
    // Arc flags are one digit and may be packed with the next number
    // ("0 01.5", "00.5.5"), so only the first character is the flag.
    final t = tokens[i];
    if (t.length > 1 && (t[0] == '0' || t[0] == '1')) {
      tokens[i] = t.substring(1);
      return t[0] == '1';
    }
    i++;
    return t == '1' || (double.tryParse(t) ?? 0) != 0;
  }

  while (i < tokens.length) {
    if (isCmd(tokens[i])) {
      cmd = tokens[i++];
    } else if (cmd == '') {
      i++;
      continue;
    }
    final rel = cmd == cmd.toLowerCase();
    final dx = rel ? x : 0.0;
    final dy = rel ? y : 0.0;
    switch (cmd.toUpperCase()) {
      case 'M':
        x = num() + dx;
        y = num() + dy;
        path.moveTo(x, y);
        startX = x;
        startY = y;
        // Following pairs are implicit line-tos.
        cmd = rel ? 'l' : 'L';
      case 'L':
        x = num() + dx;
        y = num() + dy;
        path.lineTo(x, y);
      case 'H':
        x = num() + dx;
        path.lineTo(x, y);
      case 'V':
        y = num() + dy;
        path.lineTo(x, y);
      case 'C':
        final x1 = num() + dx, y1 = num() + dy;
        ctrlX = num() + dx;
        ctrlY = num() + dy;
        x = num() + dx;
        y = num() + dy;
        path.cubicTo(x1, y1, ctrlX, ctrlY, x, y);
      case 'S':
        final reflect = 'CS'.contains(prev);
        final x1 = reflect ? 2 * x - ctrlX : x;
        final y1 = reflect ? 2 * y - ctrlY : y;
        ctrlX = num() + dx;
        ctrlY = num() + dy;
        x = num() + dx;
        y = num() + dy;
        path.cubicTo(x1, y1, ctrlX, ctrlY, x, y);
      case 'Q':
        ctrlX = num() + dx;
        ctrlY = num() + dy;
        x = num() + dx;
        y = num() + dy;
        path.quadraticBezierTo(ctrlX, ctrlY, x, y);
      case 'T':
        final reflect = 'QT'.contains(prev);
        ctrlX = reflect ? 2 * x - ctrlX : x;
        ctrlY = reflect ? 2 * y - ctrlY : y;
        x = num() + dx;
        y = num() + dy;
        path.quadraticBezierTo(ctrlX, ctrlY, x, y);
      case 'A':
        final rx = num(), ry = num(), rotation = num();
        final large = flag(), sweep = flag();
        x = num() + dx;
        y = num() + dy;
        path.arcToPoint(
          Offset(x, y),
          radius: Radius.elliptical(rx, ry),
          rotation: rotation,
          largeArc: large,
          clockwise: sweep,
        );
      case 'Z':
        path.close();
        x = startX;
        y = startY;
        // Z takes no arguments: stray numbers after it are skipped.
        cmd = '';
    }
    prev = cmd.toUpperCase();
  }
  return path;
}
