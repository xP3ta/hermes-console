import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Puts a secret on the system clipboard the careful way:
///  * on Android 13+ the clip is marked sensitive (`hermes/clipboard` channel,
///    `setSensitiveText`), so the system hides it from the paste preview.
///    Older systems and platforms without the channel use the plain
///    clipboard: there is no flag to set there;
///  * 30 s later the clipboard is emptied, but only if it still holds the same
///    text. The comparison uses a SHA-256 digest: the text itself is not kept
///    here while it waits. If the system will not let the app read the
///    clipboard at that moment (it is not in front), the check is repeated
///    when the app comes back.
///
/// The clearing outlives the sheet that asked for the copy.
class SensitiveClipboard {
  SensitiveClipboard._();

  static const MethodChannel channel = MethodChannel('hermes/clipboard');

  /// How long a copied secret may stay on the clipboard.
  static Duration clearAfter = const Duration(seconds: 30);

  static Timer? _timer;
  static String? _digest;
  static _ResumeWatcher? _watcher;

  static String _hash(String value) =>
      sha256.convert(utf8.encode(value)).toString();

  /// Copies [value] and schedules its clearing.
  static Future<void> copy(String value) async {
    _cancel();
    var done = false;
    try {
      done =
          await channel.invokeMethod<bool>('setSensitiveText', {
            'text': value,
          }) ??
          false;
    } on MissingPluginException {
      done = false;
    } on PlatformException {
      done = false;
    }
    if (!done) await Clipboard.setData(ClipboardData(text: value));
    _digest = _hash(value);
    _timer = Timer(clearAfter, () => unawaited(_clearIfSame()));
  }

  static Future<void> _clearIfSame() async {
    final digest = _digest;
    if (digest == null) return;
    String? current;
    try {
      current = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    } on PlatformException {
      current = null;
    }
    final state = WidgetsBinding.instance.lifecycleState;
    if (current == null &&
        state != null &&
        state != AppLifecycleState.resumed) {
      // Unreadable now (the app is not in front): try again on return.
      _watcher ??= _ResumeWatcher(() => unawaited(_clearIfSame()));
      return;
    }
    _stopWatching();
    _digest = null;
    if (current != null && current.isNotEmpty && _hash(current) == digest) {
      await Clipboard.setData(const ClipboardData(text: ''));
    }
  }

  static void _stopWatching() {
    _watcher?.dispose();
    _watcher = null;
  }

  static void _cancel() {
    _timer?.cancel();
    _timer = null;
    _digest = null;
    _stopWatching();
  }

  /// Test seam: drops any pending clearing.
  @visibleForTesting
  static void reset() {
    _cancel();
    clearAfter = const Duration(seconds: 30);
  }
}

class _ResumeWatcher with WidgetsBindingObserver {
  _ResumeWatcher(this._onResume) {
    WidgetsBinding.instance.addObserver(this);
  }

  final VoidCallback _onResume;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _onResume();
  }

  void dispose() => WidgetsBinding.instance.removeObserver(this);
}
