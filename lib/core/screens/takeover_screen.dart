import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../screen/screen_control_prefs.dart';
import '../screen/screen_controller.dart';
import '../screen/screen_server.dart';
import '../screen/takeover_view.dart';
import '../services/tui_gateway_client.dart';
import '../theme/app_theme.dart';
import '../widgets/console_loader.dart';
import '../widgets/hermes_app_bar.dart';

enum _Phase { checking, stopped, starting, acquiring, active, failed }

/// Waits before each automatic reconnect of a lost display socket.
const _reconnectDelays = [Duration(seconds: 1), Duration(seconds: 3)];

/// How long a page must stay connected before the reconnect budget is back.
const _stableAfter = Duration(seconds: 10);

/// Full control of the bot's desktop over the display websocket.
class TakeoverScreen extends StatefulWidget {
  /// Creates a takeover for [controller].
  const TakeoverScreen({
    required this.controller,
    this.profile = '',
    this.readOnly = false,
    super.key,
  });

  /// Shared display client, kept alive by the peek route underneath.
  final ScreenController controller;

  /// Active Hermes profile. Empty uses the gateway default.
  final String profile;

  /// A read-only connection can open this screen but cannot start or acquire.
  final bool readOnly;

  @override
  State<TakeoverScreen> createState() => _TakeoverScreenState();
}

class _TakeoverScreenState extends State<TakeoverScreen>
    with WidgetsBindingObserver {
  DisplaySession? _session;
  StreamSubscription<DisplayLeaseInfo>? _events;
  Uri? _page;
  var _phase = _Phase.checking;
  var _blocked = false;
  var _releasedByOther = false;
  var _holding = false;
  var _foreground = true;
  var _refreshing = false;
  var _retries = 0;
  Timer? _retryTimer;
  Timer? _stableTimer;
  var _ourViewerHash = '';
  var _ourEpoch = 0;
  ScreenFailureKind? _failure;
  var _touchpad = false;
  var _keyboardOpen = false;
  ScreenControlPrefs? _prefs;
  final _viewKey = GlobalKey<TakeoverViewState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_loadPrefs());
    unawaited(_prepare());
  }

  Future<void> _loadPrefs() async {
    final prefs = await ScreenControlPrefs.load();
    _prefs = prefs;
    if (!mounted) return;
    setState(() => _touchpad = prefs.touchpadMode);
  }

  Future<void> _toggleTouchpad() async {
    final next = !_touchpad;
    setState(() => _touchpad = next);
    unawaited(_viewKey.currentState?.setTouchpad(next));
    await _prefs?.setTouchpad(next);
  }

  Future<void> _toggleKeyboard() async {
    final next = !_keyboardOpen;
    setState(() => _keyboardOpen = next);
    await _viewKey.currentState?.showKeyboard(next);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        final back = !_foreground;
        _foreground = true;
        if (back && mounted && _phase == _Phase.active && _session == null) {
          unawaited(_refreshTicket());
        }
        break;
      case AppLifecycleState.inactive:
        break;
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _foreground = false;
        _releaseLease();
    }
  }

  void _releaseLease() {
    final session = _session;
    if (session == null) return;
    _session = null;
    unawaited(
      widget.controller
          .release(session.viewerId, profile: widget.profile)
          .then<DisplayLeaseInfo>(
            (lease) => lease,
            onError: (_) => DisplayLeaseInfo.empty,
          ),
    );
  }

  Future<void> _prepare() async {
    if (widget.readOnly) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.failed;
        _failure = ScreenFailureKind.readOnly;
      });
      return;
    }
    try {
      final runtime = await widget.controller.status(profile: widget.profile);
      if (!mounted) return;
      if (!runtime.supported || !runtime.installed) {
        setState(() {
          _phase = _Phase.failed;
          _failure = ScreenFailureKind.unsupported;
        });
        return;
      }
      if (!runtime.running) {
        setState(() {
          _phase = _Phase.stopped;
          _blocked = runtime.blocker.isNotEmpty;
          _failure = null;
        });
        return;
      }
      await _acquire();
    } catch (error) {
      if (!mounted) return;
      setState(() => _fail(error));
    }
  }

  Future<void> _startDisplay() async {
    if (widget.readOnly || _blocked) return;
    setState(() {
      _phase = _Phase.starting;
      _failure = null;
    });
    try {
      await widget.controller.start(profile: widget.profile);
      if (!mounted) return;
      await _acquire();
    } catch (error) {
      if (!mounted) return;
      setState(() => _fail(error));
    }
  }

  Future<void> _acquire() async {
    _retries = 0;
    setState(() {
      _phase = _Phase.acquiring;
      _releasedByOther = false;
      _failure = null;
    });
    try {
      final session = await widget.controller.observe(profile: widget.profile);
      final lease = await widget.controller.acquire(
        session.viewerId,
        profile: widget.profile,
      );
      _remember(session, lease);
      if (!_foreground) _releaseLease();
      if (!mounted) return;
      final page = _pageFor(session);
      await _listen();
      if (!mounted) return;
      setState(() {
        _page = page;
        _phase = _Phase.active;
        _keyboardOpen = false;
      });
    } finally {
      if (_phase != _Phase.active) _releaseLease();
    }
  }

  /// Replaces the single-use display ticket.
  ///
  /// The lease is taken again only when this screen no longer holds it (the
  /// app was in the background) or the gateway minted a new viewer id, and
  /// never when another client has taken the screen in the meantime.
  Future<void> _refreshTicket() async {
    if (_refreshing || widget.readOnly || !_foreground) return;
    _refreshing = true;
    try {
      final session = await widget.controller.observe(profile: widget.profile);
      if (!mounted) return;
      final page = _pageFor(session);
      final previous = _session;
      final retake = previous == null || previous.viewerId != session.viewerId;
      if (_releasedByOther ||
          (retake && _heldByAnother(session.runtime.lease))) {
        _session = session;
        _holding = false;
        _releasedByOther = true;
      } else if (retake) {
        if (previous != null) _releaseLease();
        final lease = await widget.controller.acquire(
          session.viewerId,
          profile: widget.profile,
        );
        _remember(session, lease);
        if (!_foreground) _releaseLease();
      } else {
        _session = session;
      }
      if (!mounted) return;
      setState(() {
        _page = page;
        _keyboardOpen = false;
      });
    } catch (error) {
      _releaseLease();
      if (!mounted) return;
      setState(() => _fail(error));
    } finally {
      _refreshing = false;
    }
  }

  /// Whether [lease] is held by a person other than this viewer.
  bool _heldByAnother(DisplayLeaseInfo lease) =>
      lease.heldByHuman &&
      lease.viewerHash.isNotEmpty &&
      _ourViewerHash.isNotEmpty &&
      lease.viewerHash != _ourViewerHash;

  void _remember(DisplaySession session, DisplayLeaseInfo lease) {
    _session = session;
    _ourViewerHash = lease.viewerHash;
    _ourEpoch = lease.epoch;
    _holding = lease.heldByHuman;
  }

  Future<void> _listen() async {
    await _events?.cancel();
    _events = widget.controller.watchLease().listen(
      _onLease,
      onError: (Object _) {},
    );
  }

  /// Reacts to the page's status tokens.
  ///
  /// A lost socket is retried on its own a few times, spaced out, so a dead
  /// display cannot make this screen mint tickets in a loop. A page that
  /// connects but drops again at once does not get the budget back: that
  /// takes [_stableAfter] of staying connected. After the budget the page
  /// waits for a tap, which sends `reconnect`.
  void _onBridge(String message) {
    if (!_foreground || _phase != _Phase.active) return;
    switch (message) {
      case 'connected':
        _stableTimer?.cancel();
        _stableTimer = Timer(_stableAfter, () => _retries = 0);
        // A (re)loaded page starts with the pad off; re-apply the mode.
        unawaited(_viewKey.currentState?.setTouchpad(_touchpad));
      case 'lost':
        _stableTimer?.cancel();
        _scheduleReconnect();
      case 'reconnect':
        _stableTimer?.cancel();
        _retries = 0;
        _retryTimer?.cancel();
        unawaited(_refreshTicket());
      case 'kbd-on' when !_keyboardOpen:
        setState(() => _keyboardOpen = true);
      case 'kbd-off' when _keyboardOpen:
        setState(() => _keyboardOpen = false);
    }
  }

  void _scheduleReconnect() {
    if (_releasedByOther || _retries >= _reconnectDelays.length) return;
    _retryTimer?.cancel();
    _retryTimer = Timer(_reconnectDelays[_retries++], () {
      if (!mounted || _phase != _Phase.active) return;
      unawaited(_refreshTicket());
    });
  }

  void _cancelTimers() {
    _retryTimer?.cancel();
    _stableTimer?.cancel();
  }

  void _onLease(DisplayLeaseInfo lease) {
    // Whoever holds no lease cannot have lost one: this also drops the echo of
    // our own release.
    if (!mounted || _phase != _Phase.active || _session == null) return;
    if (!displayLeaseTakenOver(
      lease,
      ourViewerHash: _ourViewerHash,
      ourEpoch: _ourEpoch,
    )) {
      return;
    }
    setState(() => _releasedByOther = true);
  }

  void _releaseAndClose() {
    _cancelTimers();
    _releaseLease();
    if (mounted) Navigator.of(context).pop();
  }

  void _fail(Object error) {
    _cancelTimers();
    _failure = error is ScreenControllerException
        ? error.kind
        : error is TuiGatewayRpcError && error.code == -32601
        ? ScreenFailureKind.unsupported
        : ScreenFailureKind.unavailable;
    _phase = _Phase.failed;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cancelTimers();
    unawaited(_events?.cancel() ?? Future<void>.value());
    _releaseLease();
    super.dispose();
  }

  Uri _pageFor(DisplaySession session) {
    final ws = widget.controller
        .displayWsUri(session.path, session.ticket)
        .toString();
    // `pad` carries the touchpad mode at load/reconnect time, when the page
    // cannot yet be commanded through runJavaScript.
    return screenAssetPageUri(
      ws,
      copy: {..._bridgeCopy(Strings.of(context)), 'pad': _touchpad ? '1' : '0'},
    );
  }

  Map<String, String> _bridgeCopy(Strings strings) => {
    'connecting': strings.screenBridgeConnecting,
    'missing': strings.screenBridgeMissing,
    'closed': strings.screenBridgeClosed,
    'lost': strings.screenBridgeLost,
    'security': strings.screenBridgeSecurity,
    'credentials': strings.screenBridgeCredentials,
  };

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final active = _phase == _Phase.active;
    final page = _page;
    return Scaffold(
      backgroundColor: active ? const Color(0xFF000000) : colors.background,
      appBar: HermesAppBar(
        title: Text(strings.screenTakeoverTitle),
        backgroundColor: active ? const Color(0xFF000000) : null,
        foregroundColor: active ? const Color(0xFFFFFFFF) : null,
        actions: [
          if (active) ...[
            IconButton(
              onPressed: () => unawaited(_toggleKeyboard()),
              icon: Icon(
                _keyboardOpen
                    ? Icons.keyboard_hide_outlined
                    : Icons.keyboard_outlined,
              ),
              tooltip: _keyboardOpen
                  ? strings.screenHideKeyboard
                  : strings.screenShowKeyboard,
            ),
            IconButton(
              onPressed: () => unawaited(_toggleTouchpad()),
              icon: Icon(_touchpad ? Icons.mouse : Icons.touch_app_outlined),
              tooltip: _touchpad
                  ? strings.screenSwitchToTouch
                  : strings.screenSwitchToTouchpad,
            ),
            TextButton.icon(
              onPressed: _releaseAndClose,
              icon: const Icon(Icons.back_hand_outlined, size: 18),
              label: Text(strings.screenHandBack),
            ),
          ],
        ],
      ),
      body: SafeArea(
        child: switch (_phase) {
          _Phase.active =>
            page == null
                ? const SizedBox.shrink()
                : Column(
                    children: [
                      _banner(strings, colors),
                      Expanded(
                        child: TakeoverView(
                          key: _viewKey,
                          pageUri: page,
                          onBridgeMessage: _onBridge,
                          onUnavailable: () {
                            if (_phase != _Phase.active) return;
                            _releaseLease();
                            if (!mounted) return;
                            setState(
                              () => _fail(
                                const ScreenControllerException(
                                  ScreenFailureKind.unavailable,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
          _Phase.stopped => _Centered(
            colors: colors,
            icon: Icons.desktop_windows_outlined,
            message: _blocked ? strings.screenBlocked : strings.screenStopped,
            action: _blocked
                ? null
                : FilledButton.icon(
                    onPressed: () => unawaited(_startDisplay()),
                    icon: const Icon(Icons.play_arrow),
                    label: Text(strings.screenStartDisplay),
                  ),
          ),
          _Phase.starting => _Centered(
            colors: colors,
            icon: Icons.power_settings_new,
            message: strings.screenStarting,
            busy: true,
          ),
          _Phase.acquiring => _Centered(
            colors: colors,
            icon: Icons.front_hand_outlined,
            message: strings.screenAcquiring,
            busy: true,
          ),
          _Phase.checking => _Centered(
            colors: colors,
            icon: Icons.monitor_outlined,
            message: strings.screenChecking,
            busy: true,
          ),
          _Phase.failed => _Centered(
            colors: colors,
            icon: Icons.error_outline,
            message: _failureText(strings, _failure),
            action: FilledButton.tonalIcon(
              onPressed: () {
                setState(() => _phase = _Phase.checking);
                unawaited(_prepare());
              },
              icon: const Icon(Icons.refresh),
              label: Text(strings.screenRetry),
            ),
          ),
        },
      ),
    );
  }

  Widget _banner(Strings strings, HermesThemeColors colors) {
    final lost = _releasedByOther;
    final message = lost
        ? strings.screenLeaseLost
        : _holding
        ? strings.screenActiveHint
        : strings.screenLeaseAgent;
    return Container(
      width: double.infinity,
      color: lost ? colors.error : colors.surfaceVariant,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Text(
        message,
        style: TextStyle(
          fontSize: 12,
          color: lost ? const Color(0xFFFFFFFF) : colors.textPrimary,
        ),
        textAlign: TextAlign.center,
      ),
    );
  }
}

String _failureText(Strings strings, ScreenFailureKind? kind) {
  return switch (kind) {
    ScreenFailureKind.unsupported => strings.screenUnsupportedDetail,
    ScreenFailureKind.readOnly => strings.screenReadOnly,
    ScreenFailureKind.invalidResponse ||
    ScreenFailureKind.unavailable ||
    null => strings.screenTakeoverFailed,
  };
}

class _Centered extends StatelessWidget {
  const _Centered({
    required this.colors,
    required this.icon,
    required this.message,
    this.busy = false,
    this.action,
  });

  final HermesThemeColors colors;
  final IconData icon;
  final String message;
  final bool busy;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busy)
              const ConsoleLoader.large()
            else
              Icon(icon, size: 48, color: colors.accent),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                height: 1.45,
                color: colors.textSecondary,
              ),
            ),
            if (action != null) ...[const SizedBox(height: 20), action!],
          ],
        ),
      ),
    );
  }
}
