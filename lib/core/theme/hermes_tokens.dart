/// The design tokens of Hermes Console in one import (audit 1.4.0, §3).
///
/// One scale per family, from the approved mocks (v25, 134 state A, 136 v2-A)
/// and Cadu: spacing, radii and type ([HermesSpace], [HermesRadius],
/// [HermesType]), surfaces and lines ([HermesChrome], [HermesSurfaces]),
/// motion ([HermesMotion]), sizes ([HermesSize], [HermesIcon]) and the
/// scrollbar ([HermesScrollbar]). A value the owner decides lives here once, so
/// changing it is changing one line.
library;

import 'package:flutter/material.dart';

import '../design/tokens.dart';
import 'app_theme.dart';

export '../design/tokens.dart';
export 'motion.dart' show HermesMotion;

/// Visible sizes of controls (§3.7). The touch target is always
/// [HermesSpace.tap] (48), whatever is drawn.
abstract final class HermesSize {
  /// Touch target of anything that can be tapped.
  static const double tap = HermesSpace.tap;

  /// A pill or bar: the header pill, the terminal's key pill, the pane's
  /// bottom bar (v2-A `--pill-h`).
  static const double pill = 44;

  /// A segment of a segmented control (v2-A `--seg-h`).
  static const double segment = 40;

  /// A round icon button of the chat header. the owner's default for 1.4.0.
  static const double iconButton = 44;
}

/// Icon sizes (§3.7): four steps instead of thirty.
abstract final class HermesIcon {
  /// Inside a line of text: a tool row, a badge.
  static const double sm = 16;

  /// Rows, segments, pane actions.
  static const double md = 18;

  /// Buttons and the composer.
  static const double lg = 20;

  /// Empty states and large affordances.
  static const double xl = 24;
}

/// The app's scrollbar (audit 1.4.0, T7): a thin thumb in the tertiary ink,
/// so a visible scrollbar never comes out as Material's bright default.
abstract final class HermesScrollbar {
  /// Thumb thickness.
  static const double thickness = 3;

  /// Opacity of the thumb over [HermesThemeColors.textTertiary].
  static const double thumbOpacity = 0.4;

  /// Gap between the thumb and the edge it runs along.
  static const double margin = 2;

  /// The theme for [colors]. It is not in `AppTheme` yet: wiring it in
  /// changes how every visible scrollbar looks, and the token wave makes no
  /// visual change. The wave that fixes the chat's thinking box wires it.
  static ScrollbarThemeData theme(HermesThemeColors colors) =>
      ScrollbarThemeData(
        thumbColor: WidgetStatePropertyAll(
          colors.textTertiary.withValues(alpha: thumbOpacity),
        ),
        thickness: const WidgetStatePropertyAll(thickness),
        radius: const Radius.circular(HermesRadius.tag),
        crossAxisMargin: margin,
        mainAxisMargin: margin,
      );
}
