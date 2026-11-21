import 'dart:async';

import 'package:flutter/material.dart';

import 'browser_loopback_reach.dart';
import 'in_app_browser_policy.dart';
import 'in_app_browser_screen.dart';

/// Opens an `http`/`https` link inside the app, in the in-app browser
/// ([InAppBrowserScreen], with its scheme and popup rules and its «Abrir en
/// el navegador» action). Its notch and Back return to where the link was
/// tapped; [backLabel] says where that is.
///
/// When [loopbackReach] is provided (for example from a standalone SSH
/// terminal), the pushed screen owns that reach's full lifecycle: forwards
/// close on route pop, suspend after [hiddenGraceDuration] in the background,
/// and tear down immediately if [loopbackReachChanges] fires with a changed or
/// removed [loopbackReachScope].
///
/// Returns false, opening nothing, for any other address: `mailto:`, `tel:`
/// and intents keep their own handling.
bool openWebLinkInApp(
  BuildContext context,
  Uri uri, {
  String? backLabel,
  BrowserLoopbackReach Function()? loopbackReach,
  Object? Function()? loopbackReachScope,
  Listenable? loopbackReachChanges,
  Duration hiddenGraceDuration = const Duration(seconds: 60),
}) {
  if (!isBrowsableWebUri(uri)) return false;
  Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => loopbackReach == null
          ? InAppBrowserScreen(initialUrl: uri, backLabel: backLabel)
          : _OwnedReachBrowserScreen(
              initialUrl: uri,
              backLabel: backLabel,
              loopbackReach: loopbackReach,
              loopbackReachScope: loopbackReachScope,
              loopbackReachChanges: loopbackReachChanges,
              hiddenGraceDuration: hiddenGraceDuration,
            ),
    ),
  );
  return true;
}

class _OwnedReachBrowserScreen extends StatefulWidget {
  const _OwnedReachBrowserScreen({
    required this.initialUrl,
    required this.loopbackReach,
    required this.hiddenGraceDuration,
    this.backLabel,
    this.loopbackReachScope,
    this.loopbackReachChanges,
  });

  final Uri initialUrl;
  final String? backLabel;
  final BrowserLoopbackReach Function() loopbackReach;
  final Object? Function()? loopbackReachScope;
  final Listenable? loopbackReachChanges;
  final Duration hiddenGraceDuration;

  @override
  State<_OwnedReachBrowserScreen> createState() =>
      _OwnedReachBrowserScreenState();
}

class _OwnedReachBrowserScreenState extends State<_OwnedReachBrowserScreen>
    with WidgetsBindingObserver {
  BrowserLoopbackReach? _reach;
  Object? _scope;
  bool _appInBackground = false;
  Timer? _hiddenTimer;

  static bool _isBackground(AppLifecycleState? state) =>
      state == AppLifecycleState.hidden ||
      state == AppLifecycleState.paused ||
      state == AppLifecycleState.detached;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _appInBackground = _isBackground(WidgetsBinding.instance.lifecycleState);
    _scope = widget.loopbackReachScope?.call();
    _reach = widget.loopbackReachScope == null || _scope != null
        ? widget.loopbackReach()
        : null;
    widget.loopbackReachChanges?.addListener(_onReachChanged);
    _syncBackgroundTimer();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      _hiddenTimer?.cancel();
      _hiddenTimer = null;
      final reach = _reach;
      if (reach != null) unawaited(reach.suspend());
      return;
    }
    final bg = _isBackground(state);
    if (bg != _appInBackground) {
      _appInBackground = bg;
      _syncBackgroundTimer();
    }
  }

  void _onReachChanged() {
    final nextScope = widget.loopbackReachScope?.call();
    if (nextScope == _scope && widget.loopbackReachScope != null) return;
    final oldReach = _reach;
    _scope = nextScope;
    _reach = widget.loopbackReachScope != null && nextScope == null
        ? null
        : widget.loopbackReach();
    if (oldReach != null) unawaited(oldReach.close());
    _syncBackgroundTimer();
    if (mounted) setState(() {});
  }

  void _syncBackgroundTimer() {
    if (!_appInBackground) {
      _hiddenTimer?.cancel();
      _hiddenTimer = null;
      return;
    }
    if (_reach == null || _hiddenTimer != null) return;
    _hiddenTimer = Timer(widget.hiddenGraceDuration, () {
      _hiddenTimer = null;
      if (!mounted || !_appInBackground) return;
      final reach = _reach;
      if (reach != null) unawaited(reach.suspend());
    });
  }

  @override
  void dispose() {
    _hiddenTimer?.cancel();
    _hiddenTimer = null;
    widget.loopbackReachChanges?.removeListener(_onReachChanged);
    WidgetsBinding.instance.removeObserver(this);
    final reach = _reach;
    _reach = null;
    if (reach != null) unawaited(reach.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => InAppBrowserScreen(
    initialUrl: widget.initialUrl,
    backLabel: widget.backLabel,
    loopbackReach: _reach,
  );
}
