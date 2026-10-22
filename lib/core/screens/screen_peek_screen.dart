import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../feedback/feedback_policy.dart';
import '../screen/screen_controller.dart';
import '../services/tui_gateway_client.dart';
import '../theme/app_theme.dart';
import '../widgets/console_loader.dart';
import '../widgets/hermes_app_bar.dart';
import 'takeover_screen.dart';

/// How often the peek screen asks for a new thumbnail.
const Duration screenPeekPollInterval = Duration(seconds: 4);

enum _PeekPhase { loading, live, suppressed, stopped, unsupported, failed }

/// Thumbnail of the bot's desktop, with a way into [TakeoverScreen].
class ScreenPeekScreen extends StatefulWidget {
  /// Creates a peek bound to [gateway], or to [controller] in tests.
  const ScreenPeekScreen({
    this.gateway,
    this.controller,
    this.dashboardBase,
    this.readOnly = false,
    this.profile = '',
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

  @override
  State<ScreenPeekScreen> createState() => _ScreenPeekScreenState();
}

class _ScreenPeekScreenState extends State<ScreenPeekScreen> {
  late final ScreenController _controller;
  Timer? _timer;
  Uint8List? _frameBytes;
  var _phase = _PeekPhase.loading;
  var _suppressed = false;
  var _inFlight = false;
  var _starting = false;

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
    unawaited(_poll());
    _timer = Timer.periodic(screenPeekPollInterval, (_) => unawaited(_poll()));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
    if (_inFlight || !mounted) return;
    _inFlight = true;
    try {
      final status = await _controller.peekStatus(profile: widget.profile);
      if (!mounted) return;
      if (!status.installed) {
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
      setState(
        () => _phase = _unsupported(error)
            ? _PeekPhase.unsupported
            : _PeekPhase.failed,
      );
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
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TakeoverScreen(
          controller: _controller,
          profile: widget.profile,
          readOnly: widget.readOnly,
        ),
      ),
    );
    if (!mounted) return;
    _timer = Timer.periodic(screenPeekPollInterval, (_) => unawaited(_poll()));
    unawaited(_poll());
  }

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final showActions =
        _phase == _PeekPhase.live || _phase == _PeekPhase.suppressed;
    return Scaffold(
      backgroundColor: colors.background,
      appBar: HermesAppBar(
        title: Text(strings.screenTitle),
        actions: [
          IconButton(
            tooltip: strings.screenRefresh,
            onPressed: () => unawaited(_poll()),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          children: [
            Expanded(child: Center(child: _body(strings, colors))),
            if (showActions)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Column(
                  children: [
                    Text(
                      _suppressed
                          ? strings.screenSuppressedPartial
                          : strings.screenPollHint(
                              screenPeekPollInterval.inSeconds,
                            ),
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.textSecondary,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    if (widget.readOnly)
                      Text(
                        strings.screenReadOnly,
                        style: TextStyle(
                          fontSize: 13,
                          color: colors.textSecondary,
                        ),
                        textAlign: TextAlign.center,
                      )
                    else
                      FilledButton.icon(
                        onPressed: () => unawaited(_takeover()),
                        icon: const Icon(Icons.front_hand_outlined),
                        label: Text(strings.screenTakeover),
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
      _PeekPhase.live => _FrameView(bytes: _frameBytes!, dimmed: _suppressed),
      _PeekPhase.suppressed => _Message(
        colors: colors,
        icon: Icons.back_hand_outlined,
        message: _frameBytes == null ? strings.screenSuppressed : null,
        child: _frameBytes == null
            ? null
            : _FrameView(bytes: _frameBytes!, dimmed: true),
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
      _PeekPhase.loading => const ConsoleLoader.large(),
      _PeekPhase.failed => _Message(
        colors: colors,
        icon: Icons.error_outline,
        message: strings.screenFailed,
      ),
    };
  }
}

bool _unsupported(Object error) =>
    error is TuiGatewayRpcError && error.code == -32601;

Uint8List? _decodeFrame(String dataUrl) {
  final comma = dataUrl.indexOf(',');
  if (comma < 0) return null;
  try {
    return base64Decode(dataUrl.substring(comma + 1));
  } on FormatException {
    return null;
  }
}

class _FrameView extends StatelessWidget {
  const _FrameView({required this.bytes, this.dimmed = false});

  final Uint8List bytes;
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
          FilledButton.icon(
            onPressed: onStart,
            icon: const Icon(Icons.power_settings_new),
            label: Text(strings.screenStart),
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
