import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../feedback/feedback_policy.dart';
import '../models/connection.dart';
import '../screen/screen_controller.dart';
import '../screen/screen_chrome.dart';
import '../services/app_lock_sensitive_read_fence.dart';
import '../services/tui_gateway_client.dart';
import '../theme/app_theme.dart';
import '../widgets/console_loader.dart';
import '../widgets/owned_resource_host.dart';
import 'takeover_screen.dart';

/// How often the peek screen asks for a new thumbnail (Desktop
/// `screen-hero.tsx`, `REFRESH_MS`).
const Duration screenPeekPollInterval = Duration(seconds: 4);

/// Consecutive failed refreshes after which the last frame is shown as
/// "last seen" instead of live (Desktop `STALE_AFTER`).
const int screenPeekStaleAfter = 3;

enum _PeekPhase {
  loading,
  live,
  suppressed,
  stopped,
  unsupported,
  unavailable,
  failed,
}

/// Thumbnail of the bot's desktop, with a way into [TakeoverScreen].
class ScreenPeekScreen extends StatefulWidget {
  /// Creates a peek bound to [gateway], or to [controller] in tests.
  const ScreenPeekScreen({
    this.gateway,
    this.controller,
    this.dashboardBase,
    this.readOnly = false,
    this.profile = '',
    this.botName = '',
    super.key,
  }) : assert(
         controller != null || (gateway != null && dashboardBase != null),
         'A peek needs a controller or a gateway and dashboard URL',
       );

  /// Desktop gateway whose `display.*` methods this screen calls.
  final TuiGatewayClient? gateway;

  /// Injected controller. Production leaves this null and uses [gateway].
  final ScreenController? controller;

  /// Dashboard origin used to build `/api/display/ws`.
  final Uri? dashboardBase;

  /// Hides start and takeover when the connection cannot write.
  final bool readOnly;

  /// Active Hermes profile. Empty uses the gateway default.
  final String profile;

  /// Name shown in «Pantalla de `<bot>`». Empty uses the generic title.
  final String botName;

  @override
  State<ScreenPeekScreen> createState() => _ScreenPeekScreenState();
}

class _ScreenPeekScreenState extends State<ScreenPeekScreen>
    with WidgetsBindingObserver {
  late final ScreenController _controller;
  Timer? _timer;
  Uint8List? _frameBytes;
  var _phase = _PeekPhase.loading;
  var _suppressed = false;
  var _inFlight = false;
  var _starting = false;
  var _stopping = false;

  /// The takeover screen is on top: it owns the display, the peek waits.
  var _covered = false;

  /// Failed refreshes in a row; a success resets it.
  var _misses = 0;

  bool get _stale => _misses >= screenPeekStaleAfter;

  @override
  void initState() {
    super.initState();
    _controller =
        widget.controller ??
        ScreenController(
          rpc: widget.gateway!.displayRequest,
          leasePayloads: widget.gateway!.events
              .where((event) => event.type == 'display.lease')
              .map((event) => event.payload),
          dashboardBase: () => widget.dashboardBase!,
        );
    WidgetsBinding.instance.addObserver(this);
    _resume();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  /// Polls only while the app is in front, like Desktop's hero, which skips
  /// its refresh while the window is hidden (REVIEW-PR210 P6): a peek left
  /// open must not keep fetching frames in the background.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        if (_timer == null && !_covered) _resume();
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        _timer?.cancel();
        _timer = null;
      case AppLifecycleState.inactive:
        break;
    }
  }

  void _resume() {
    _timer?.cancel();
    unawaited(_poll());
    _timer = Timer.periodic(screenPeekPollInterval, (_) => unawaited(_poll()));
  }

  /// No display stack, or a Hermes without `display.*`: nothing will change
  /// on its own, so the peek stops asking (REVIEW-R4 P2-VNC-4). The refresh
  /// button and coming back to the app ask again.
  void _halt() {
    _timer?.cancel();
    _timer = null;
  }

  /// The refresh button: asks now, and restarts the interval if halted.
  void _refresh() {
    if (_timer == null && !_covered) {
      _resume();
    } else {
      unawaited(_poll());
    }
  }

  /// Nobody sees the peek under another screen or behind the app lock: it
  /// asks for nothing then, and the next tick after it is back asks again
  /// (REVIEW-R5-B #25).
  bool get _inView {
    final route = _route;
    if (route != null && !route.isCurrent) return false;
    return AppLockSensitiveReadFence.capture().isCurrent;
  }

  /// The peek's route, read where an inherited lookup is allowed (the first
  /// poll runs from initState).
  ModalRoute<Object?>? _route;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  Future<void> _poll() async {
    if (_inFlight || !mounted || !_inView) return;
    _inFlight = true;
    try {
      final status = await _controller.peekStatus(profile: widget.profile);
      if (!mounted) return;
      if (!displayHasDesktop(status)) {
        _halt();
        setState(() => _phase = _PeekPhase.unsupported);
        return;
      }
      if (!status.running) {
        setState(() {
          _phase = _PeekPhase.stopped;
          _frameBytes = null;
          _suppressed = false;
        });
        return;
      }
      final frame = await _controller.thumbnail(profile: widget.profile);
      if (!mounted) return;
      final bytes = _decodeFrame(frame.dataUrl);
      setState(() {
        _misses = 0;
        _suppressed = frame.suppressedByHuman;
        if (bytes != null) {
          _frameBytes = bytes;
          _phase = _PeekPhase.live;
        } else if (_suppressed) {
          _phase = _PeekPhase.suppressed;
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        if (_unavailable(error)) {
          _halt();
          _phase = _PeekPhase.unavailable;
          return;
        }
        // Desktop keeps the last good frame up and marks it "last seen"
        // after a few misses, so a dead gateway never keeps looking live.
        _misses += 1;
        if (_frameBytes == null) _phase = _PeekPhase.failed;
      });
    } finally {
      _inFlight = false;
    }
  }

  Future<void> _start() async {
    if (_starting || !mounted || widget.readOnly) return;
    final feedback = AppFeedback.of(context);
    final failed = Strings.of(context).screenStartFailed;
    setState(() => _starting = true);
    try {
      await _controller.start(profile: widget.profile);
      if (!mounted) return;
      setState(() => _phase = _PeekPhase.loading);
      await _poll();
    } catch (_) {
      if (!mounted) return;
      setState(() => _phase = _PeekPhase.stopped);
      feedback.error(failed);
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _takeover() async {
    _timer?.cancel();
    _timer = null;
    _covered = true;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TakeoverScreen(
          controller: _controller,
          profile: widget.profile,
          readOnly: widget.readOnly,
          botName: widget.botName,
        ),
      ),
    );
    _covered = false;
    if (!mounted) return;
    _resume();
  }

  /// Turns the bot's computer off after a confirmation. A person holding
  /// the screen refuses it, and the peek says so.
  Future<void> _powerOff() async {
    if (_stopping || widget.readOnly) return;
    final strings = Strings.of(context);
    final feedback = AppFeedback.of(context);
    final bot = widget.botName.trim().isEmpty
        ? strings.screenTitle
        : widget.botName.trim();
    if (!await confirmPowerOff(context, bot: bot) || !mounted) return;
    setState(() => _stopping = true);
    try {
      await _controller.stop(profile: widget.profile);
      if (!mounted) return;
      setState(() {
        _phase = _PeekPhase.stopped;
        _frameBytes = null;
        _suppressed = false;
        _misses = 0;
      });
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

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final showActions =
        _phase == _PeekPhase.live || _phase == _PeekPhase.suppressed;
    final bot = widget.botName.trim();
    final on = showActions;
    final subtitle = switch (_phase) {
      _PeekPhase.live || _PeekPhase.suppressed =>
        _suppressed
            ? strings.screenSuppressedPartial
            : _stale
            ? strings.screenStale
            : strings.bsaSubView(screenPeekPollInterval.inSeconds),
      _PeekPhase.stopped => strings.bsaSubOff,
      _PeekPhase.loading => strings.screenChecking,
      _ => strings.bsaSubOff,
    };
    return Scaffold(
      backgroundColor: colors.background,
      body: SafeArea(
        child: Column(
          children: [
            ScreenHeader(
              title: bot.isEmpty ? strings.screenTitle : strings.bsaTitle(bot),
              subtitleKey: const ValueKey('screen-peek-caption'),
              subtitle: subtitle,
              stateLabel: switch (_phase) {
                _PeekPhase.live || _PeekPhase.suppressed => strings.bsaStateOn,
                _PeekPhase.stopped => strings.bsaStateOff,
                _ => null,
              },
              on: on,
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 4, 14, 0),
                child: Center(child: _body(strings, colors)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(
                    spacing: 7,
                    runSpacing: 7,
                    children: [
                      if (showActions && !widget.readOnly)
                        ScreenPill(
                          key: const ValueKey('screen-peek-takeover'),
                          label: strings.screenTakeover,
                          kind: ScreenPillKind.primary,
                          onTap: () => unawaited(_takeover()),
                        ),
                      if (showActions && !widget.readOnly)
                        ScreenPill(
                          key: const ValueKey('screen-peek-power'),
                          label: strings.bsaPowerOff,
                          kind: ScreenPillKind.danger,
                          onTap: _stopping
                              ? null
                              : () => unawaited(_powerOff()),
                        ),
                      ScreenPill(
                        key: const ValueKey('screen-peek-refresh'),
                        label: strings.screenRefresh,
                        onTap: _refresh,
                      ),
                    ],
                  ),
                  if (showActions && widget.readOnly)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        strings.screenReadOnly,
                        style: TextStyle(
                          fontSize: 13,
                          color: colors.textSecondary,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(Strings strings, HermesThemeColors colors) {
    return switch (_phase) {
      _PeekPhase.live => _FrameView(
        bytes: _frameBytes!,
        label: strings.screenTitle,
        dimmed: _suppressed || _stale,
      ),
      _PeekPhase.suppressed => _Message(
        colors: colors,
        icon: Icons.back_hand_outlined,
        message: _frameBytes == null ? strings.screenSuppressed : null,
        child: _frameBytes == null
            ? null
            : _FrameView(
                bytes: _frameBytes!,
                label: strings.screenTitle,
                dimmed: true,
              ),
      ),
      _PeekPhase.stopped => _Stopped(
        colors: colors,
        starting: _starting,
        readOnly: widget.readOnly,
        onStart: _start,
      ),
      _PeekPhase.unsupported => _Message(
        colors: colors,
        icon: Icons.desktop_access_disabled_outlined,
        message: strings.screenUnsupported,
      ),
      _PeekPhase.unavailable => _Message(
        colors: colors,
        icon: Icons.system_update_alt_outlined,
        message: strings.screenUnavailable,
      ),
      _PeekPhase.loading => const ConsoleLoader.large(),
      _PeekPhase.failed => _Message(
        colors: colors,
        icon: Icons.error_outline,
        message: strings.screenFailed,
      ),
    };
  }
}

/// The bot's Hermes predates `display.*` (JSON-RPC method not found): there
/// is nothing to check, ever (Desktop `isDisplayUnavailable`).
bool _unavailable(Object error) => displayMethodMissing(error);

/// Whether [error] is the JSON-RPC "method not found" of a Hermes without
/// `display.*`.
bool displayMethodMissing(Object error) =>
    error is TuiGatewayRpcError && error.code == -32601;

/// Whether a bot's `display.status` says it has a desktop worth opening:
/// the display stack is installed. A stopped desktop still counts, the peek
/// offers to start it. The peek and the bot list share this rule.
bool displayHasDesktop(DisplayState status) => status.installed;

/// Pushes the peek of [profile]'s desktop on its own gateway client, the
/// way the chat header and the drawer do. [builder] is a test seam.
Future<void> pushBotScreen(
  BuildContext context, {
  required SavedConnection connection,
  required String profile,
  String botName = '',
  Widget Function(String profile)? builder,
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => builder != null
        ? builder(profile)
        : OwnedResourceHost<TuiGatewayClient>(
            create: () => TuiGatewayClient(connection),
            release: (gateway) => gateway.close(),
            builder: (_, gateway) => ScreenPeekScreen(
              gateway: gateway,
              readOnly: connection.readOnly,
              profile: profile,
              botName: botName,
              dashboardBase: Uri.parse(connection.effectiveDashboardUrl),
            ),
          ),
  ),
);

/// Largest frame the peek decodes; a thumbnail is a few hundred KiB.
const int screenPeekMaxFrameBytes = 4 * 1024 * 1024;

/// Only an image `data:` URL, as an `<img>` would take in Desktop's hero,
/// and never one larger than [screenPeekMaxFrameBytes].
Uint8List? _decodeFrame(String dataUrl) {
  final comma = dataUrl.indexOf(',');
  if (comma < 0) return null;
  final header = dataUrl.substring(0, comma).toLowerCase();
  if (!header.startsWith('data:image/') || !header.endsWith(';base64')) {
    return null;
  }
  final payload = dataUrl.length - comma - 1;
  if (payload > (screenPeekMaxFrameBytes ~/ 3 + 1) * 4) return null;
  try {
    return base64Decode(dataUrl.substring(comma + 1));
  } on FormatException {
    return null;
  }
}

class _FrameView extends StatelessWidget {
  const _FrameView({
    required this.bytes,
    required this.label,
    this.dimmed = false,
  });

  final Uint8List bytes;

  /// What a screen reader says the frame is («Pantalla del bot»).
  final String label;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: dimmed ? 0.45 : 1,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: InteractiveViewer(
          maxScale: 4,
          child: SizedBox.expand(
            child: Image.memory(
              bytes,
              semanticLabel: label,
              fit: BoxFit.contain,
              gaplessPlayback: true,
            ),
          ),
        ),
      ),
    );
  }
}

class _Stopped extends StatelessWidget {
  const _Stopped({
    required this.colors,
    required this.starting,
    required this.readOnly,
    required this.onStart,
  });

  final HermesThemeColors colors;
  final bool starting;
  final bool readOnly;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.desktop_windows_outlined, size: 48, color: colors.accent),
        const SizedBox(height: 16),
        Text(
          strings.screenStopped,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 14,
            height: 1.4,
            color: colors.textSecondary,
          ),
        ),
        const SizedBox(height: 16),
        if (readOnly)
          Text(
            strings.screenReadOnly,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: colors.textSecondary),
          )
        else if (starting)
          const ConsoleLoader.medium()
        else
          ScreenPill(
            key: const ValueKey('screen-peek-start'),
            label: strings.screenStart,
            kind: ScreenPillKind.primary,
            onTap: onStart,
          ),
      ],
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.colors,
    required this.icon,
    this.message,
    this.child,
  });

  final HermesThemeColors colors;
  final IconData icon;
  final String? message;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (child != null)
          Flexible(child: child!)
        else
          Icon(icon, size: 48, color: colors.textSecondary),
        if (message != null) ...[
          const SizedBox(height: 16),
          Text(
            message!,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              height: 1.4,
              color: colors.textSecondary,
            ),
          ),
        ],
      ],
    );
  }
}
