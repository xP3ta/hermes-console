import 'dart:async';

import 'package:flutter/material.dart';

/// Soft hand-off from Android's native splash to the real app.
///
/// The first Flutter frame paints what the native splash showed (its
/// background colour and the same centred mark), so the system splash can
/// leave without a cut. The hand-off starts on that first frame and never
/// waits for data: the mark fades and shrinks away while the app under it
/// (Home, onboarding or the App Lock screen) fades in from 0.98 scale. The
/// two opacities always add up to one, so no frame shows neither.
///
/// With reduced motion it is a plain [reducedDuration] crossfade.
class StartupHandoff extends StatefulWidget {
  const StartupHandoff({
    required this.background,
    required this.child,
    super.key,
  });

  /// The native splash background (see `NativeAppearance.splashBackground`).
  final Color background;
  final Widget child;

  static const Duration duration = Duration(milliseconds: 400);
  static const Duration reducedDuration = Duration(milliseconds: 150);

  /// Material's standard easing.
  static const Curve curve = Curves.fastOutSlowIn;

  /// The very image Android 12+ shows as the splash icon, so the mark on
  /// the first frame is the same pixels and follows any logo change.
  static const String markAsset =
      'android/app/src/main/res/drawable-nodpi/splash_logo.png';

  static const AssetImage markImage = AssetImage(markAsset);

  /// Android 12+ draws an icon without background at 288 dp, masked to a
  /// 192 dp circle, centred in the window.
  static const double markCanvas = 288;
  static const double markVisible = 192;

  /// Decodes the mark before the first frame (bootstrap), so frame one
  /// paints it instead of popping it in a frame later. Never throws.
  static Future<void> precacheMark() async {
    final stream = markImage.resolve(ImageConfiguration.empty);
    final done = Completer<void>();
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (_, _) {
        if (!done.isCompleted) done.complete();
      },
      onError: (_, _) {
        if (!done.isCompleted) done.complete();
      },
    );
    stream.addListener(listener);
    try {
      await done.future.timeout(const Duration(milliseconds: 400));
    } catch (_) {
      // A slow decode just shows the background a frame longer.
    } finally {
      stream.removeListener(listener);
    }
  }

  @override
  State<StartupHandoff> createState() => _StartupHandoffState();
}

class _StartupHandoffState extends State<StartupHandoff>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: StartupHandoff.duration,
  );
  late final Animation<double> _reveal = CurvedAnimation(
    parent: _controller,
    curve: StartupHandoff.curve,
  );
  late final Animation<double> _markOpacity = ReverseAnimation(_reveal);
  late final Animation<double> _uiScale = Tween<double>(
    begin: 0.98,
    end: 1,
  ).animate(_reveal);
  late final Animation<double> _markScale = Tween<double>(
    begin: 1,
    end: 0.92,
  ).animate(_reveal);
  bool _reduced = false;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) {
        setState(() => _done = true);
      }
    });
    // Starts with the first frame: nothing (network, storage) holds it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _controller.forward();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _controller.duration = _reduced
        ? StartupHandoff.reducedDuration
        : StartupHandoff.duration;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The app subtree keeps its key and place whether or not the hand-off
    // layers are there, so it is never rebuilt from scratch when they go.
    final app = KeyedSubtree(
      key: const ValueKey('startup-handoff-app'),
      child: FadeTransition(
        key: const ValueKey('startup-handoff-app-opacity'),
        opacity: _reveal,
        child: _reduced
            ? widget.child
            : ScaleTransition(scale: _uiScale, child: widget.child),
      ),
    );
    return Stack(
      fit: StackFit.expand,
      textDirection: TextDirection.ltr,
      children: [
        if (!_done)
          ColoredBox(
            key: const ValueKey('startup-handoff-background'),
            color: widget.background,
          ),
        app,
        if (!_done)
          IgnorePointer(
            key: const ValueKey('startup-handoff-mark-layer'),
            child: FadeTransition(
              key: const ValueKey('startup-handoff-mark-opacity'),
              opacity: _markOpacity,
              child: Center(
                child: ScaleTransition(
                  scale: _reduced ? kAlwaysCompleteAnimation : _markScale,
                  child: const _Mark(),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _Mark extends StatelessWidget {
  const _Mark();

  @override
  Widget build(BuildContext context) => ClipOval(
    child: SizedBox.square(
      dimension: StartupHandoff.markVisible,
      child: OverflowBox(
        maxWidth: StartupHandoff.markCanvas,
        maxHeight: StartupHandoff.markCanvas,
        child: const Image(
          key: ValueKey('startup-handoff-mark'),
          image: StartupHandoff.markImage,
          width: StartupHandoff.markCanvas,
          height: StartupHandoff.markCanvas,
          filterQuality: FilterQuality.medium,
          gaplessPlayback: true,
          excludeFromSemantics: true,
        ),
      ),
    ),
  );
}
