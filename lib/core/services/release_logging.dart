import 'package:flutter/foundation.dart';

import '../config/flavor.dart';

/// M5: `debugPrint` is not stripped from release builds, so every log line
/// still builds its string and goes to logcat. A release build of a store
/// flavour (`full`, `play`) drops them; QA builds and debug/profile keep
/// theirs. Nothing in the app reads logcat back: the diagnostics bundle is
/// built from its own records.
void silenceDebugPrintInRelease({
  bool releaseMode = kReleaseMode,
  String flavor = kHermesFlavor,
}) {
  if (!releaseMode || flavor == 'qa') return;
  debugPrint = _dropDebugPrint;
}

void _dropDebugPrint(String? message, {int? wrapWidth}) {}
