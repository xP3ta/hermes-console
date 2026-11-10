import 'dart:ui' show SemanticsRole;

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import 'hermes_loader.dart';

/// Sizes of [ConsoleLoader].
enum ConsoleLoaderSize {
  /// 16–20 dp, mark only: inline in rows and next to short text.
  small,

  /// 32 dp with an optional label: panels, sheets and list initial loads.
  medium,

  /// 56 dp with the label: full-screen loading states.
  large,
}

/// The loading state used by screens, sections and sheets: a [HermesLoader]
/// (three dots that spin and breathe) with an optional localized
/// "Cargando…" / "Loading…" label under it.
///
/// It keeps the size presets the screens already use ([ConsoleLoader.small],
/// [.medium], [.large]); the mark itself, its colour (theme accent), its
/// motion, reduce-motion behaviour and semantics live in [HermesLoader].
class ConsoleLoader extends StatelessWidget {
  /// Generic constructor; prefer [ConsoleLoader.small], [.medium], [.large].
  const ConsoleLoader({
    super.key,
    this.size = ConsoleLoaderSize.medium,
    this.showLabel,
    this.label,
    this.dimension,
    this.typing,
  });

  /// Mark only, 16–20 dp (default 18): for rows and inline states.
  const ConsoleLoader.small({super.key, this.label, this.dimension})
    : size = ConsoleLoaderSize.small,
      showLabel = false,
      typing = false;

  /// 32 dp mark with an optional label: for panels and sheets.
  const ConsoleLoader.medium({super.key, this.showLabel = false, this.label})
    : size = ConsoleLoaderSize.medium,
      dimension = null,
      typing = false;

  /// 56 dp mark with the label: for full-screen states.
  const ConsoleLoader.large({
    super.key,
    this.showLabel = true,
    this.label,
    this.typing = true,
  }) : size = ConsoleLoaderSize.large,
       dimension = null;

  final ConsoleLoaderSize size;

  /// Whether to show the text label under the mark. Defaults per size: no for
  /// small and medium, yes for large. The small size never shows it.
  final bool? showLabel;

  /// Text of the label and of the semantics announcement. Defaults to the
  /// localized "Cargando…" / "Loading…".
  final String? label;

  /// Small size only: the mark's side, clamped to 16–20 dp.
  final double? dimension;

  /// Kept for source compatibility; the mark has no typing phase.
  final bool? typing;

  static double markDimensionFor(ConsoleLoaderSize size, [double? asked]) =>
      switch (size) {
        ConsoleLoaderSize.small => (asked ?? 18).clamp(16, 20).toDouble(),
        ConsoleLoaderSize.medium => 32,
        ConsoleLoaderSize.large => 56,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Harnesses without the app's delegates still get a readable label.
    final text =
        label ??
        Localizations.of<Strings>(context, Strings)?.commonLoading ??
        'Loading…';
    final withLabel =
        size != ConsoleLoaderSize.small &&
        (showLabel ?? size == ConsoleLoaderSize.large);
    final mark = HermesLoader(
      size: markDimensionFor(size, dimension),
      semanticLabel: text,
    );
    if (!withLabel) return mark;

    final large = size == ConsoleLoaderSize.large;
    final base = large ? theme.textTheme.bodyMedium : theme.textTheme.bodySmall;
    return Semantics(
      container: true,
      role: SemanticsRole.loadingSpinner,
      label: text,
      child: ExcludeSemantics(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            mark,
            SizedBox(height: large ? 14 : 8),
            Text(
              text,
              textAlign: TextAlign.center,
              style: (base ?? const TextStyle()).copyWith(
                color: theme.hermes.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
