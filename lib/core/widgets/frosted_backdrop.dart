import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';

/// Device-wide switches for backdrop blur.
///
/// A backdrop blur re-samples and filters whatever is behind it on every
/// frame in which that backdrop changes, so over a scrolling list it costs
/// raster time per frame. On devices that report themselves as constrained
/// that cost is dropped.
abstract final class FrostedBackdropPolicy {
  /// True when the platform reports a low-RAM device or battery saver.
  static final reducedPerformance = ValueNotifier<bool>(false);

  static const _channel = MethodChannel('hermes/platform_info');

  /// Re-reads the platform's performance class. Safe to call repeatedly;
  /// any platform failure keeps the current value.
  static Future<void> refresh() async {
    try {
      final info = await _channel.invokeMapMethod<String, Object?>(
        'getPerformanceClass',
      );
      if (info == null) return;
      reducedPerformance.value =
          info['lowRamDevice'] == true || info['powerSaveMode'] == true;
    } catch (_) {
      // Missing handler (tests, other platforms): keep the blur.
    }
  }
}

/// A rounded surface that frosts the content behind it.
///
/// [builder] paints the surface with the fill colour to use. At rest that is
/// [tint] over a blur of radius [sigma], clipped to [borderRadius] and
/// isolated in its own repaint boundary.
///
/// The blur is dropped when it cannot be seen or must not be paid for:
///  * [sigma] is zero: the surface is painted as is (no clip, no layer);
///  * [tint] is opaque: nothing shows through, so a blur has no effect;
///  * reduced motion, high contrast or [FrostedBackdropPolicy] report a
///    constrained setting: the fill becomes [tint] over the app background,
///    which is how the surface looks at rest over the empty app canvas, so
///    sharp rows never show through a translucent surface.
class FrostedBackdrop extends StatelessWidget {
  final double sigma;
  final Color tint;
  final BorderRadius borderRadius;
  final Widget Function(BuildContext context, Color fill) builder;

  const FrostedBackdrop({
    required this.sigma,
    required this.tint,
    required this.borderRadius,
    required this.builder,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    if (sigma <= 0) return builder(context, tint);
    final suppressed =
        MediaQuery.disableAnimationsOf(context) ||
        MediaQuery.highContrastOf(context);
    return ValueListenableBuilder<bool>(
      valueListenable: FrostedBackdropPolicy.reducedPerformance,
      builder: (context, lowEnd, _) {
        final opaque = tint.a >= 1;
        final blur = !opaque && !suppressed && !lowEnd;
        final fill = blur || opaque
            ? tint
            : Color.alphaBlend(tint, Theme.of(context).hermes.background);
        // `enabled` instead of removing the filter keeps the subtree (and
        // any state below it) mounted when the policy flips.
        return RepaintBoundary(
          child: ClipRRect(
            borderRadius: borderRadius,
            child: BackdropFilter(
              enabled: blur,
              filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
              child: builder(context, fill),
            ),
          ),
        );
      },
    );
  }
}
