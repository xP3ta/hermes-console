import 'package:flutter/widgets.dart';

import 'app_theme.dart';
import 'theme_contrast.dart';

/// The roles a highlighter's classes fall into. Everything else keeps the
/// text colour.
enum CodeSyntaxRole { keyword, literal, comment }

/// Restrained syntax colours from the app theme: three roles on top of the
/// text colour, each nudged toward the text colour until it reads at
/// [minimumContrast] on the surface the code sits on, in every theme, light
/// or dark. Code read in the chat and in the viewer speaks one language.
final class CodeSyntaxPalette {
  CodeSyntaxPalette(HermesThemeColors colors, Color background)
    : keyword = _readable(colors.accent, colors.textPrimary, background),
      literal = _readable(colors.secondary, colors.textPrimary, background),
      comment = _readable(colors.textSecondary, colors.textPrimary, background);

  /// WCAG AA for normal text.
  static const double minimumContrast = 4.5;

  /// Keywords, types, built-ins and tags.
  final Color keyword;

  /// Strings, numbers, attributes and additions.
  final Color literal;

  /// Comments, quotes and deletions.
  final Color comment;

  /// The role of a highlighter class, or null when it keeps the text colour.
  static CodeSyntaxRole? roleOf(String? cls) => switch (cls) {
    'keyword' ||
    'built_in' ||
    'literal' ||
    'type' ||
    'meta' ||
    'meta-keyword' ||
    'selector-tag' ||
    'tag' ||
    'name' => CodeSyntaxRole.keyword,
    'string' ||
    'regexp' ||
    'symbol' ||
    'template-string' ||
    'number' ||
    'addition' ||
    'attr' ||
    'attribute' => CodeSyntaxRole.literal,
    'comment' || 'quote' || 'deletion' => CodeSyntaxRole.comment,
    _ => null,
  };

  Color colorOf(CodeSyntaxRole role) => switch (role) {
    CodeSyntaxRole.keyword => keyword,
    CodeSyntaxRole.literal => literal,
    CodeSyntaxRole.comment => comment,
  };

  static Color _readable(Color tint, Color text, Color background) {
    for (var step = 0; step <= 10; step++) {
      final color = Color.lerp(tint, text, step / 10)!;
      if (ThemeContrast.ratio(color, background) >= minimumContrast) {
        return color;
      }
    }
    return text;
  }
}
