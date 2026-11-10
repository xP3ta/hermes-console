import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../design/modal.dart';
import '../feedback/feedback_policy.dart';
import '../screen/screen_chrome.dart';
import '../screen/screen_control_prefs.dart';
import '../screen/screen_controller.dart';
import '../screen/screen_server.dart';
import '../screen/takeover_view.dart';
import '../screen/trackpad_pad.dart';
import '../services/tui_gateway_client.dart';
import '../theme/app_theme.dart';
import '../utils/transport_privacy.dart';
import '../widgets/console_loader.dart';

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
    this.botName = '',
    super.key,
  });

  /// Name shown in «Pantalla de `<bot>`». Empty uses the generic title.
  final String botName;

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

  /// Ticketed websocket the page connects to; never part of [_page].
  String? _ws;
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
  var _zoom = 100;
  var _stopping = false;
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
        _closeView();
    }
  }

  /// Unmounts the noVNC page in the background: with the lease released its
  /// socket would only keep streaming the desktop, spending data and battery
  /// (REVIEW-R4 P2-VNC-2). Coming back mints a new ticket ([_refreshTicket]).
  void _closeView() {
    _cancelTimers();
    if (!mounted || (_page == null && _ws == null)) return;
    setState(() {
      _page = null;
      _ws = null;
      _keyboardOpen = false;
    });
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
      final ws = _wsFor(session);
      await _listen();
      if (!mounted) return;
      setState(() {
        // Taken while the app went to the background: the page waits for
        // the next ticket on resume.
        _page = _foreground ? _pageUri() : null;
        _ws = _foreground ? ws : null;
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
      final ws = _wsFor(session);
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
      if (!mounted || !_foreground) return;
      setState(() {
        _page = _pageUri();
        _ws = ws;
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

  /// This viewer's identity is computed from the id the server minted, as
  /// Desktop does (`leaseHeldBy`), not adopted from the acquire reply: a
  /// reply without a lease must not leave us unable to tell another person
  /// took the screen.
  void _remember(DisplaySession session, DisplayLeaseInfo lease) {
    _session = session;
    _ourViewerHash = displayViewerHash(session.viewerId);
    _ourEpoch = lease.epoch;
    _holding = displayLeaseHeldBy(lease, session.viewerId);
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
      case final token when token.startsWith('zoom:'):
        final percent = int.tryParse(token.substring(5));
        if (percent != null && percent != _zoom) {
          setState(() => _zoom = percent);
        }
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
        ? ScreenFailureKind.outdated
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

  String _wsFor(DisplaySession session) =>
      widget.controller.displayWsUri(session.path, session.ticket).toString();

  // `pad` carries the touchpad mode at load/reconnect time, when the page
  // cannot yet be commanded through runJavaScript.
  // `chrome=0`: the app draws the keyboard, zoom and pad controls itself.
  Uri _pageUri() => screenAssetPageUri(
    copy: {
      ..._bridgeCopy(Strings.of(context)),
      'pad': _touchpad ? '1' : '0',
      'chrome': '0',
      if (MediaQuery.disableAnimationsOf(context)) 'rm': '1',
    },
  );

  /// Turns the bot's computer off. Our own hold on the screen does not
  /// block it (it is forced then); somebody else's does.
  Future<void> _powerOff() async {
    if (_stopping || widget.readOnly) return;
    final strings = Strings.of(context);
    final feedback = AppFeedback.of(context);
    final bot = widget.botName.trim().isEmpty
        ? strings.screenTitle
        : widget.botName.trim();
    final navigator = Navigator.of(context);
    if (!await confirmPowerOff(context, bot: bot) || !mounted) return;
    setState(() => _stopping = true);
    try {
      await widget.controller.stop(
        profile: widget.profile,
        force: _holding && !_releasedByOther,
      );
      if (!mounted) return;
      // The gateway released the lease with the desktop.
      _session = null;
      _cancelTimers();
      navigator.pop();
    } on ScreenControllerException catch (error) {
      feedback.error(
        error.kind == ScreenFailureKind.humanControl
            ? strings.bsaPowerOffHeld
            : strings.bsaPowerOffFailed,
      );
    } finally {
      if (mounted) setState(() => _stopping = false);
    }
  }

  late final _pad = _ViewPad(() => _viewKey.currentState);

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
    final ws = _ws;
    final holding = active && _holding && !_releasedByOther;
    final bot = widget.botName.trim();
    return Scaffold(
      backgroundColor: colors.background,
      body: SafeArea(
        child: Column(
          children: [
            ScreenHeader(
              title: bot.isEmpty ? strings.screenTitle : strings.bsaTitle(bot),
              subtitleKey: const ValueKey('screen-takeover-subtitle'),
              subtitle: switch (_phase) {
                _Phase.active =>
                  holding ? strings.bsaSubControl : strings.bsaStateOn,
                _Phase.stopped => strings.bsaSubOff,
                _Phase.checking => strings.screenChecking,
                _Phase.starting => strings.screenStarting,
                _Phase.acquiring => strings.screenAcquiring,
                _Phase.failed => strings.bsaSubOff,
              },
              stateLabel: switch (_phase) {
                _Phase.active =>
                  holding ? strings.bsaStateControl : strings.bsaStateOn,
                _Phase.stopped => strings.bsaStateOff,
                _ => null,
              },
              on: active,
            ),
            Expanded(child: _content(strings, colors, page, ws)),
          ],
        ),
      ),
    );
  }

  Widget _content(
    Strings strings,
    HermesThemeColors colors,
    Uri? page,
    String? ws,
  ) {
    return switch (_phase) {
      _Phase.active =>
        page == null || ws == null
            ? const SizedBox.shrink()
            : _controls(strings, colors, page, ws),
      _Phase.stopped => _Centered(
        colors: colors,
        icon: Icons.desktop_windows_outlined,
        message: _blocked ? strings.screenBlocked : strings.screenStopped,
        note: _blocked ? null : strings.bsaStoppedNote,
        action: _blocked
            ? null
            : ScreenPill(
                key: const ValueKey('screen-takeover-start'),
                label: strings.screenStartDisplay,
                kind: ScreenPillKind.primary,
                onTap: () => unawaited(_startDisplay()),
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
        action: ScreenPill(
          key: const ValueKey('screen-takeover-retry'),
          label: strings.screenRetry,
          onTap: () {
            setState(() => _phase = _Phase.checking);
            unawaited(_prepare());
          },
        ),
      ),
    };
  }

  /// The live page, then the pill bar, then the trackpad (when it is on).
  Widget _controls(
    Strings strings,
    HermesThemeColors colors,
    Uri page,
    String ws,
  ) {
    final lost = _releasedByOther;
    return LayoutBuilder(
      builder: (context, whole) {
        // The pad gives way on a short window or with the keyboard up, so
        // the page and the pills always fit; the buttons stay.
        final scale = MediaQuery.textScalerOf(context).scale(1);
        final spare =
            whole.maxHeight - (padSurfaceMin + 100) * scale - 200 * scale;
        final padHeight =
            MediaQuery.viewInsetsOf(context).bottom > 0 || spare < padSurfaceMin
            ? 0.0
            : spare.clamp(padSurfaceMin, padSurfaceHeight).toDouble();
        return _controlsColumn(strings, colors, page, ws, lost, padHeight);
      },
    );
  }

  Widget _controlsColumn(
    Strings strings,
    HermesThemeColors colors,
    Uri page,
    String ws,
    bool lost,
    double padHeight,
  ) {
    return Column(
      children: [
        // A fixed slot: the view below keeps its place when it comes and goes.
        lost || !_holding ? _banner(strings, colors) : const SizedBox.shrink(),
        Expanded(
          child: LayoutBuilder(
            builder: (context, box) {
              // The same view in both modes (a new one would reconnect);
              // with the pad it keeps a 16:10 window above it.
              final height = _touchpad
                  ? (box.maxWidth * 10 / 16)
                        .clamp(0.0, box.maxHeight)
                        .toDouble()
                  : box.maxHeight;
              return Align(
                alignment: Alignment.topCenter,
                child: SizedBox(
                  width: box.maxWidth,
                  height: height,
                  child: TakeoverView(
                    key: _viewKey,
                    pageUri: page,
                    wsUrl: ws,
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
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 7,
                runSpacing: 7,
                children: [
                  ScreenPill(
                    key: const ValueKey('screen-pill-trackpad'),
                    label: strings.bsaTrackpad,
                    selected: _touchpad,
                    onTap: () => unawaited(_toggleTouchpad()),
                  ),
                  ScreenPill(
                    key: const ValueKey('screen-pill-keyboard'),
                    label: strings.bsaKeyboard,
                    selected: _keyboardOpen,
                    onTap: () => unawaited(_toggleKeyboard()),
                  ),
                  _ZoomPill(
                    percent: _zoom,
                    onZoomOut: () => unawaited(
                      _viewKey.currentState?.zoomBy(zoomIn: false) ??
                          Future<void>.value(),
                    ),
                    onZoomIn: () => unawaited(
                      _viewKey.currentState?.zoomBy(zoomIn: true) ??
                          Future<void>.value(),
                    ),
                  ),
                  if (!widget.readOnly)
                    ScreenPill(
                      key: const ValueKey('screen-pill-power'),
                      label: strings.bsaPowerOff,
                      kind: ScreenPillKind.danger,
                      onTap: _stopping ? null : () => unawaited(_powerOff()),
                    ),
                  ScreenPill(
                    key: const ValueKey('screen-pill-handback'),
                    label: strings.screenHandBack,
                    onTap: _releaseAndClose,
                  ),
                ],
              ),
              // Plain ws inside a private network (LAN, Tailscale) is not
              // worth a line; towards a public host it is.
              screenSocketUnencrypted(ws) &&
                      TransportPrivacy.classify(ws) ==
                          TransportPrivacyClass.publicCleartext
                  ? _unencrypted(strings, colors)
                  : const SizedBox.shrink(),
              if (_touchpad) ...[
                const SizedBox(height: 10),
                ScreenTrackpad(sink: _pad, surfaceHeight: padHeight),
              ] else
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    strings.bsaDirectHint,
                    style: TextStyle(color: colors.textSecondary, fontSize: 11),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _banner(Strings strings, HermesThemeColors colors) {
    final lost = _releasedByOther;
    final message = lost ? strings.screenLeaseLost : strings.screenLeaseAgent;
    // A live region: a screen reader hears that another person took the
    // screen instead of typing on into a desktop it no longer controls.
    return Semantics(
      key: const ValueKey('screen-lease-banner'),
      liveRegion: true,
      container: true,
      child: Container(
        width: double.infinity,
        color: lost ? colors.error : colors.surfaceVariant,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Text(
          message,
          style: TextStyle(
            fontSize: 12,
            color: lost ? colors.onAccent : colors.textPrimary,
          ),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

/// Feeds the page's virtual pointer from the app's own trackpad.
class _ViewPad implements PadSink {
  _ViewPad(this._view);

  final TakeoverViewState? Function() _view;

  @override
  void move(double dx, double dy) => unawaited(_view()?.padMove(dx, dy));

  @override
  void click(int mask) => unawaited(_view()?.padClick(mask));

  @override
  void down(int mask) => unawaited(_view()?.padDown(mask));

  @override
  void up(int mask) => unawaited(_view()?.padUp(mask));

  @override
  void wheel(int steps) => unawaited(_view()?.padWheel(steps));
}

/// «− 100% +» as one pill.
class _ZoomPill extends StatelessWidget {
  const _ZoomPill({
    required this.percent,
    required this.onZoomOut,
    required this.onZoomIn,
  });

  final int percent;
  final VoidCallback onZoomOut;
  final VoidCallback onZoomIn;

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    Widget step(String glyph, String label, Key key, VoidCallback onTap) =>
        Semantics(
          button: true,
          label: label,
          excludeSemantics: true,
          child: InkWell(
            key: key,
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox.square(
              dimension: 44,
              child: Center(
                child: Text(
                  glyph,
                  style: TextStyle(color: colors.textSecondary, fontSize: 16),
                ),
              ),
            ),
          ),
        );
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: colors.surface,
        shape: StadiumBorder(side: BorderSide(color: colors.divider)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          step(
            '−',
            strings.bsaZoomOut,
            const ValueKey('screen-zoom-out'),
            onZoomOut,
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 46),
            child: Text(
              '$percent%',
              key: const ValueKey('screen-zoom-percent'),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: colors.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          step(
            '+',
            strings.bsaZoomIn,
            const ValueKey('screen-zoom-in'),
            onZoomIn,
          ),
        ],
      ),
    );
  }
}

/// The Dashboard is plain http towards a public host: the session, keystrokes
/// included, travels unencrypted. Only shown there; private networks (LAN,
/// Tailscale) say nothing. One discreet line; a tap shows the whole warning.
Widget _unencrypted(Strings strings, HermesThemeColors colors) => Builder(
  builder: (context) => Semantics(
    liveRegion: true,
    container: true,
    button: true,
    child: InkWell(
      key: const ValueKey('screen-unencrypted'),
      onTap: () => unawaited(
        showHermesDialog<void>(
          context: context,
          title: strings.bsaHttpShort,
          message: strings.screenUnencrypted,
          actions: [
            HermesDialogAction<void>(label: strings.bsaClose, value: null),
          ],
        ),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 36),
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_open_rounded, size: 13, color: colors.warning),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  strings.bsaHttpShort,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: colors.warning),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  ),
);

String _failureText(Strings strings, ScreenFailureKind? kind) {
  return switch (kind) {
    ScreenFailureKind.unsupported => strings.screenUnsupportedDetail,
    // Desktop isDisplayUnavailable: update the bot's Hermes.
    ScreenFailureKind.outdated => strings.screenUnavailable,
    ScreenFailureKind.readOnly => strings.screenReadOnly,
    ScreenFailureKind.humanControl => strings.bsaPowerOffHeld,
    ScreenFailureKind.stopFailed => strings.bsaPowerOffFailed,
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
    this.note,
  });

  final HermesThemeColors colors;
  final IconData icon;
  final String message;
  final bool busy;
  final Widget? action;
  final String? note;

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
            if (note != null) ...[
              const SizedBox(height: 12),
              Text(
                note!,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: colors.textSecondary),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
