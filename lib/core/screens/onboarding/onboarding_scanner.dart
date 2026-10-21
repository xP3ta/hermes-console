import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_code_scanner_plus/qr_code_scanner_plus.dart';

import '../../../l10n/app_localizations.dart';
import '../../services/pairing_link.dart';
import '../../theme/app_theme.dart';
import 'onboarding_motion.dart';
import 'onboarding_widgets.dart';

/// The camera, the four corner brackets that fly in and lock onto a square,
/// the line that scans it, and what happens when the code is read: the
/// brackets snap onto it, a ring of light leaves it and a short tick says so.
///
/// Used full-bleed by the first-run flow and, in a route of its own, to scan a
/// new code into a saved connection. Camera access is requested by the
/// camera view itself, when this widget first shows it.
class QrScanView extends StatefulWidget {
  const QrScanView({
    required this.onLink,
    this.onDashboardLink,
    required this.onBack,
    this.cameraBuilder,
    this.aimHint,
    this.help,
    this.onManual,
    super.key,
  });

  /// Called once, after the lock-on has played, with the code that was read.
  final ValueChanged<PairingLink> onLink;

  /// v2 Dashboard links; without it only v1 codes are accepted.
  final ValueChanged<DashboardPairingLink>? onDashboardLink;
  final VoidCallback onBack;
  final Widget Function(ValueChanged<String>, ValueChanged<bool>)?
  cameraBuilder;

  /// First run only: the hint, the panel under the viewfinder and the way to
  /// type the address. With [onManual] there is no pasted link.
  final String? aimHint;
  final Widget? help;
  final VoidCallback? onManual;

  @override
  State<QrScanView> createState() => _QrScanViewState();
}

class _QrScanViewState extends State<QrScanView> with TickerProviderStateMixin {
  static const double _frame = 244;
  static const double _helpFrameTop = 64;
  final GlobalKey _qrKey = GlobalKey(debugLabel: 'hermesQrScanner');
  QRViewController? _controller;
  StreamSubscription<Barcode>? _sub;
  late final AnimationController _fly = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 720),
  );
  late final AnimationController _lock = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 240),
  );
  late final AnimationController _ring = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );

  /// The scan line and the frame's breathing: a finite run, then it rests.
  late final AnimationController _loop = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 60),
  );
  bool _handled = false;
  bool _denied = false;
  bool _invalid = false;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (OnboardingMotion.reduced(context)) {
      _fly.value = 1;
    } else {
      _fly.forward();
      _loop.forward();
    }
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    _fly.dispose();
    _lock.dispose();
    _ring.dispose();
    _loop.dispose();
    super.dispose();
  }

  void _permission(bool granted) {
    if (!granted && mounted) setState(() => _denied = true);
  }

  void _onCreated(QRViewController controller) {
    _controller = controller;
    unawaited(_sub?.cancel());
    _sub = controller.scannedDataStream.listen((barcode) {
      if (barcode.code != null) unawaited(_read(barcode.code!));
    }, onError: (_) => _permission(false));
  }

  Future<void> _read(String raw) async {
    if (_handled || _invalid || !mounted) return;
    final parsed = PairingLink.parse(raw);
    final v1 = parsed.v1, v2 = parsed.v2;
    if (v1 == null && (v2 == null || widget.onDashboardLink == null)) {
      setState(() => _invalid = true);
      return;
    }
    _handled = true;
    unawaited(HapticFeedback.lightImpact().catchError((_) {}));
    if (!OnboardingMotion.reduced(context)) {
      unawaited(_ring.forward(from: 0));
      await _lock.forward();
    }
    if (!mounted) return;
    if (v1 != null) {
      widget.onLink(v1);
    } else {
      widget.onDashboardLink!(v2!);
    }
  }

  Future<void> _paste() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (mounted) await _read(data?.text ?? '');
    } catch (_) {
      if (mounted) setState(() => _invalid = true);
    }
  }

  Future<void> _torch() async {
    try {
      await _controller?.toggleFlash();
    } catch (_) {
      _permission(false);
    }
  }

  Future<void> _settings() async {
    try {
      await const MethodChannel(
        'hermes/android_apps',
      ).invokeMethod<bool>('openAppSettings');
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final c = Theme.of(context).hermes;
    final size = MediaQuery.sizeOf(context);
    final withHelp = widget.help != null;
    final frame = (size.shortestSide * (withHelp ? 0.5 : 0.62)).clamp(
      150.0,
      withHelp ? 200.0 : _frame,
    );
    final frameTop = MediaQuery.paddingOf(context).top + _helpFrameTop;
    Widget alt(String key) => widget.onManual == null
        ? OnbSmallPill(
            key: ValueKey(key),
            label: s.qrPasteLink,
            icon: Icons.content_paste,
            onDark: true,
            onTap: _paste,
          )
        : OnbSmallPill(
            key: const ValueKey('qr-manual'),
            label: s.o2Manual,
            onDark: true,
            onTap: widget.onManual,
          );
    final body = _denied
        ? _stateBody(
            icon: Icons.no_photography_outlined,
            text: s.qrCameraError,
            actions: [
              alt('qr-denied-paste'),
              OnbSmallPill(
                key: const ValueKey('qr-open-settings'),
                label: s.o2OpenSettings,
                onDark: true,
                onTap: _settings,
              ),
            ],
          )
        : _invalid
        ? _stateBody(
            icon: Icons.qr_code_2_rounded,
            text: s.o2InvalidCode,
            actions: [
              OnbSmallPill(
                key: const ValueKey('qr-retry'),
                label: s.commonRetry,
                filled: true,
                onTap: () => setState(() => _invalid = false),
              ),
              alt('qr-paste'),
            ],
          )
        : withHelp
        ? _helpBody(s, frame, frameTop)
        : _scanBody(s, frame);
    return ColoredBox(
      color: const Color(0xFF15151B),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (!_denied && !_invalid)
            Positioned.fill(
              child: widget.cameraBuilder != null
                  ? widget.cameraBuilder!(
                      (raw) => unawaited(_read(raw)),
                      _permission,
                    )
                  : QRView(
                      key: _qrKey,
                      onQRViewCreated: _onCreated,
                      onPermissionSet: (_, granted) => _permission(granted),
                      formatsAllowed: const [BarcodeFormat.qrcode],
                      overlay: QrScannerOverlayShape(
                        borderColor: Colors.transparent,
                        borderWidth: 0.1,
                        overlayColor: const Color(0x99101015),
                        cutOutSize: frame,
                        cutOutBottomOffset: withHelp
                            ? size.height / 2 - (frameTop + frame / 2)
                            : 0,
                        borderRadius: frame * 0.12,
                      ),
                    ),
            ),
          if (_denied || _invalid)
            const Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment(0, -0.24),
                    radius: 1.2,
                    colors: [Color(0xFF34343F), Color(0xFF15151B)],
                  ),
                ),
              ),
            ),
          Positioned.fill(
            child: SafeArea(
              bottom: !(withHelp && !_denied && !_invalid),
              child: body,
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.only(left: kOnbGutter - 8, top: 8),
              child: Align(
                alignment: Alignment.topLeft,
                child: OnbBack(onDark: true, onTap: widget.onBack),
              ),
            ),
          ),
          // The ring that leaves the code and lights the next screen.
          Positioned.fill(
            child: IgnorePointer(
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: PulseRingPainter(
                    t: () => _ring.value,
                    center: () => size.center(Offset.zero),
                    color: c.accent,
                    from: frame * 0.5,
                    to: size.longestSide * 0.7,
                    repaint: _ring,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _helpBody(Strings s, double frame, double frameTop) {
    final c = Theme.of(context).hermes;
    final size = MediaQuery.sizeOf(context);
    return Column(
      children: [
        const SizedBox(height: _helpFrameTop),
        SizedBox.square(
          dimension: frame,
          child: RepaintBoundary(
            child: CustomPaint(
              key: const ValueKey('qr-frame'),
              painter: ScanFramePainter(
                color: c.accent,
                fly: () => _fly.value,
                lock: () => _lock.value,
                line: () => (_loop.value * 25) % 1,
                pulse: () => (_loop.value * 25) % 1,
                screen: size,
                repaint: Listenable.merge([_fly, _lock, _loop]),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(kOnbGutter, 12, kOnbGutter, 12),
          child: Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 10,
            runSpacing: 8,
            children: [
              Text(
                widget.aimHint ?? s.qrAimHint,
                textAlign: TextAlign.center,
                textScaler: onbTitleScaler(context),
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFFF1EFE6),
                ),
              ),
              OnbSmallPill(
                key: const ValueKey('qr-torch'),
                label: s.qrTorch,
                icon: Icons.flash_on_rounded,
                onDark: true,
                onTap: _torch,
              ),
            ],
          ),
        ),
        Expanded(
          child: AnimatedBuilder(
            animation: _fly,
            builder: (_, child) {
              final t = ivl(_fly.value, .2, 1, Curves.easeOutCubic);
              return Opacity(
                opacity: t,
                child: Transform.translate(
                  offset: Offset(0, 48 * (1 - t)),
                  child: child,
                ),
              );
            },
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: c.background,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(28),
                ),
              ),
              child: SingleChildScrollView(
                key: const ValueKey('qr-help-panel'),
                padding: EdgeInsets.fromLTRB(
                  kOnbGutter,
                  kOnbGutter,
                  kOnbGutter,
                  kOnbGutter + MediaQuery.paddingOf(context).bottom,
                ),
                child: widget.help,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _scanBody(Strings s, double frame) {
    final c = Theme.of(context).hermes;
    final size = MediaQuery.sizeOf(context);
    return Column(
      children: [
        const Spacer(),
        // The frame sits on the camera's own cut-out: the middle of the view.
        SizedBox.square(
          dimension: frame,
          child: RepaintBoundary(
            child: CustomPaint(
              key: const ValueKey('qr-frame'),
              painter: ScanFramePainter(
                color: c.accent,
                fly: () => _fly.value,
                lock: () => _lock.value,
                line: () => (_loop.value * 25) % 1,
                pulse: () => (_loop.value * 25) % 1,
                screen: size,
                repaint: Listenable.merge([_fly, _lock, _loop]),
              ),
            ),
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, box) => SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: box.maxHeight),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        kOnbGutter,
                        30,
                        kOnbGutter,
                        0,
                      ),
                      child: Text(
                        s.qrAimHint,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          height: 1.3,
                          color: Color(0xFFF1EFE6),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        kOnbGutter,
                        16,
                        kOnbGutter,
                        32,
                      ),
                      child: Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          OnbSmallPill(
                            key: const ValueKey('qr-torch'),
                            label: s.qrTorch,
                            icon: Icons.flash_on_rounded,
                            onDark: true,
                            onTap: _torch,
                          ),
                          OnbSmallPill(
                            key: const ValueKey('qr-paste'),
                            label: s.qrPasteLink,
                            icon: Icons.content_paste,
                            onDark: true,
                            onTap: _paste,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _stateBody({
    required IconData icon,
    required String text,
    required List<Widget> actions,
  }) {
    return LayoutBuilder(
      builder: (context, box) => SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: kOnbGutter),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: box.maxHeight),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 56),
                RiseIn(
                  child: Container(
                    width: 74,
                    height: 74,
                    decoration: BoxDecoration(
                      color: const Color(0xFF3A3A46),
                      borderRadius: BorderRadius.circular(26),
                    ),
                    child: Icon(icon, size: 36, color: const Color(0xFFF1EFE6)),
                  ),
                ),
                const SizedBox(height: 28),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    text,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      height: 1.3,
                      color: Color(0xFFF1EFE6),
                    ),
                  ),
                ),
                const SizedBox(height: 26),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 10,
                  runSpacing: 10,
                  children: actions,
                ),
                const SizedBox(height: 32),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
