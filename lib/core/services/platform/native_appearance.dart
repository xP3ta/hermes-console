import 'dart:io';

import 'package:flutter/services.dart';

/// Keeps Android's per-app day/night resources aligned with the active Hermes
/// profile. Android 12 draws its splash before Flutter's first frame, so this
/// setting is what lets the next cold start select the matching native splash.
final class NativeAppearance {
  static const MethodChannel _channel = MethodChannel('hermes/appearance');

  const NativeAppearance._();

  /// `@color/splash_background` (values / values-night): the colour Android
  /// paints under the native splash. The first Flutter frame starts from
  /// the same colour so the hand-off shows no flash. A test keeps these in
  /// step with colors.xml (a brand change there must update them).
  static const Color splashBackgroundLight = Color(0xFF26262A);
  static const Color splashBackgroundDark = Color(0xFF26262A);

  /// The native splash background Android picks for [brightness] once
  /// [sync] has set the app's night mode.
  static Color splashBackground(Brightness brightness) =>
      brightness == Brightness.light
      ? splashBackgroundLight
      : splashBackgroundDark;

  static Future<void> sync(Brightness brightness) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('setBrightness', {
        'brightness': brightness == Brightness.light ? 'light' : 'dark',
      });
    } on MissingPluginException {
      // Widget tests and non-Android embedders do not register this channel.
    } on PlatformException {
      // Appearance sync is best-effort; it must never block app startup.
    }
  }
}
