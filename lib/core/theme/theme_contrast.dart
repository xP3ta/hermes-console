import 'dart:math' as math;

import 'package:flutter/material.dart';

@immutable
final class ThemeContrastAdjustment {
  final Color color;
  final bool achieved;
  final double worstRatio;

  const ThemeContrastAdjustment({
    required this.color,
    required this.achieved,
    required this.worstRatio,
  });
}

abstract final class ThemeContrast {
  static bool meets(
    Color foreground,
    Color background, {
    required double minimum,
  }) => ratio(foreground, background) + 1e-9 >= minimum;

  static double ratio(Color foreground, Color background) {
    final opaqueBackground = _alpha(background) == 255
        ? background
        : composite(background, const Color(0xFF000000));
    final opaqueForeground = _alpha(foreground) == 255
        ? foreground
        : composite(foreground, opaqueBackground);
    final foregroundLuminance = luminance(opaqueForeground);
    final backgroundLuminance = luminance(opaqueBackground);
    final high = math.max(foregroundLuminance, backgroundLuminance);
    final low = math.min(foregroundLuminance, backgroundLuminance);
    return (high + 0.05) / (low + 0.05);
  }

  static double luminance(Color color) {
    double linear(int channel) {
      final value = channel / 255;
      return value <= 0.04045
          ? value / 12.92
          : math.pow((value + 0.055) / 1.055, 2.4).toDouble();
    }

    return 0.2126 * linear(_red(color)) +
        0.7152 * linear(_green(color)) +
        0.0722 * linear(_blue(color));
  }

  static Color composite(Color foreground, Color background) {
    final foregroundAlpha = _alpha(foreground) / 255;
    final backgroundAlpha = _alpha(background) / 255;
    final outAlpha = foregroundAlpha + backgroundAlpha * (1 - foregroundAlpha);
    if (outAlpha <= 0) return const Color(0x00000000);

    int channel(int foregroundChannel, int backgroundChannel) =>
        ((foregroundChannel * foregroundAlpha +
                    backgroundChannel *
                        backgroundAlpha *
                        (1 - foregroundAlpha)) /
                outAlpha)
            .round()
            .clamp(0, 255);

    return Color.fromARGB(
      (outAlpha * 255).round().clamp(0, 255),
      channel(_red(foreground), _red(background)),
      channel(_green(foreground), _green(background)),
      channel(_blue(foreground), _blue(background)),
    );
  }

  static Color blend(Color from, Color to, double amount) {
    final t = amount.clamp(0.0, 1.0);
    int channel(int left, int right) =>
        (left + (right - left) * t).round().clamp(0, 255);
    return Color.fromARGB(
      channel(_alpha(from), _alpha(to)),
      channel(_red(from), _red(to)),
      channel(_green(from), _green(to)),
      channel(_blue(from), _blue(to)),
    );
  }

  static Color bestBlackOrWhite(Color background) {
    const black = Color(0xFF000000);
    const white = Color(0xFFFFFFFF);
    return ratio(black, background) >= ratio(white, background) ? black : white;
  }

  /// Returns the smallest deterministic RGB adjustment towards black or white
  /// that reaches [minimum] against every supplied background. When given,
  /// [maximumHueShift] also bounds the hue change, in degrees, after RGB
  /// rounding. A chromatic ink retains enough chroma to encode its hue.
  static Color adjustForContrast(
    Color original,
    Iterable<Color> backgrounds, {
    required double minimum,
    double? maximumHueShift,
  }) => adjustForContrastResult(
    original,
    backgrounds,
    minimum: minimum,
    maximumHueShift: maximumHueShift,
  ).color;

  /// Same search as [adjustForContrast], but makes an impossible target
  /// explicit. Returning only the best-effort color made callers treat an
  /// unresolved contrast conflict as a successful repair.
  static ThemeContrastAdjustment adjustForContrastResult(
    Color original,
    Iterable<Color> backgrounds, {
    required double minimum,
    double? maximumHueShift,
  }) {
    assert(maximumHueShift == null || maximumHueShift > 0);
    final targets = List<Color>.unmodifiable(backgrounds);
    final originalWorst = targets.isEmpty
        ? double.infinity
        : targets
              .map((background) => ratio(original, background))
              .reduce(math.min);
    if (targets.isEmpty || originalWorst + 1e-9 >= minimum) {
      return ThemeContrastAdjustment(
        color: original,
        achieved: true,
        worstRatio: originalWorst,
      );
    }

    final hueLimit = maximumHueShift;
    final originalHsl = hueLimit == null ? null : HSLColor.fromColor(original);
    bool keepsHue(Color candidate) {
      final hsl = originalHsl;
      if (hsl == null || hueLimit == null || hsl.saturation == 0) return true;
      final next = HSLColor.fromColor(candidate);
      if (next.saturation == 0) return false;
      final delta = (next.hue - hsl.hue).abs();
      return math.min(delta, 360 - delta) < hueLimit;
    }

    final channels = [_red(original), _green(original), _blue(original)];
    final originalLow = channels.reduce(math.min);
    final originalSpan = channels.reduce(math.max) - originalLow;
    Color? matchHue(Color candidate, {required bool lighter}) {
      if (keepsHue(candidate)) return candidate;
      final values = [_red(candidate), _green(candidate), _blue(candidate)];
      final low = values.reduce(math.min);
      final high = values.reduce(math.max);
      // Near black or white, rounding can erase the smaller channel
      // differences. Keep only as much of the original chroma as the hue
      // needs, anchored at the channel moving towards the endpoint.
      for (var span = high - low; span <= originalSpan; span++) {
        final floor = lighter ? high - span : low;
        if (floor < 0 || floor + span > 255) continue;
        int channel(int value) =>
            floor + ((value - originalLow) * span / originalSpan).round();
        final matched = Color.fromARGB(
          _alpha(candidate),
          channel(channels[0]),
          channel(channels[1]),
          channel(channels[2]),
        );
        if (keepsHue(matched)) return matched;
      }
      return null;
    }

    const endpoints = [Color(0xFF000000), Color(0xFFFFFFFF)];
    Color? best;
    var bestStep = 1001;
    var bestWorstRatio = 0.0;
    for (final endpoint in endpoints) {
      for (var step = 1; step <= 1000; step++) {
        final candidate = matchHue(
          blend(original, endpoint, step / 1000),
          lighter: endpoint == endpoints.last,
        );
        if (candidate == null) continue;
        final worst = targets
            .map((background) => ratio(candidate, background))
            .reduce(math.min);
        if (worst > bestWorstRatio) {
          bestWorstRatio = worst;
          best = candidate;
        }
        if (worst + 1e-9 >= minimum) {
          if (step < bestStep) {
            bestStep = step;
            best = candidate;
          }
          break;
        }
      }
    }
    final resolved = best ?? original;
    final resolvedWorst = targets
        .map((background) => ratio(resolved, background))
        .reduce(math.min);
    return ThemeContrastAdjustment(
      color: resolved,
      achieved: resolvedWorst + 1e-9 >= minimum,
      worstRatio: resolvedWorst,
    );
  }

  static int _argb(Color color) => color.toARGB32();
  static int _alpha(Color color) => (_argb(color) >> 24) & 0xFF;
  static int _red(Color color) => (_argb(color) >> 16) & 0xFF;
  static int _green(Color color) => (_argb(color) >> 8) & 0xFF;
  static int _blue(Color color) => _argb(color) & 0xFF;
}
