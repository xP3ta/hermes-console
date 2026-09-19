import 'package:flutter/services.dart';

/// Flutter tests render every family with the fixed-width Ahem font unless a
/// family is registered explicitly. Suites that assert whether copy fits a
/// pill must measure with the font the app actually ships; Roboto is the
/// default Material family on the Android test platform.
Future<void> loadInterFont() async {
  for (final family in const ['Inter', 'Roboto']) {
    final loader = FontLoader(family)
      ..addFont(rootBundle.load('assets/fonts/Inter.ttf'));
    await loader.load();
  }
}
