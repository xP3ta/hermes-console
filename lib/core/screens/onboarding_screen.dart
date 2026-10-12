import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';

import '../../l10n/app_localizations.dart';
import '../services/connection_diagnostics.dart';
import '../services/connection_manager.dart';
import '../services/connection_setup_activity.dart';
import '../services/dashboard_login_capabilities.dart';
import '../services/hermes_setup_commands.dart';
import '../services/pairing_link.dart';
import '../theme/app_theme.dart';
import '../utils/transport_privacy.dart';
import '../widgets/instance_kind_picker.dart';
import '../widgets/dashboard_password_help.dart';
import 'dashboard_setup_screen.dart';
import 'instance_edit_screen.dart';
import 'onboarding/onboarding_motion.dart';
import 'onboarding/onboarding_scanner.dart';
import 'onboarding/onboarding_widgets.dart';

enum _Step {
  welcome,
  help,
  scan,
  confirm,
  connecting,
  issue,
  duplicate,
  signIn,
  success,
}

enum _Hero { none, mark, ring, check }

double _wave(double turns) => math.sin(turns * 2 * math.pi);

/// One entrance for first launch, empty Home and Add another Hermes.
///
/// It is a short film more than a form: the logo draws itself out of the dark,
/// the light behind it follows the hero from screen to screen, the scanner
/// frame locks onto the code and the verifying ring completes only as the real
/// checks do. Camera and clipboard access follow a gesture, network access
/// follows confirmation, and completion requires a saved connection.
///
/// Nothing waits for an animation: every button works from the first frame, a
/// touch ends the opening, and reduced motion shows the end states.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({
    required this.connManager,
    required this.onDone,
    this.initialLink,
    this.diagnostics,
    this.scanCode,
    this.cameraBuilder,
    this.playOpening,
    super.key,
  });
  final ConnectionManager connManager;
  final VoidCallback onDone;
  final PairingLink? initialLink;
  final ConnectionDiagnostics? diagnostics;
  final Future<PairingLink?> Function(BuildContext)? scanCode;
  final Widget Function(ValueChanged<String>, ValueChanged<bool>)?
  cameraBuilder;

  /// Forces the opening on or off; by default it plays the first time the
  /// flow is shown in a process.
  final bool? playOpening;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen>
    with TickerProviderStateMixin {
  static const double _openMs = 2600;

  _Step _step = _Step.welcome;
  bool _forward = true;
  final List<_Step> _history = [];
  PairingLink? _link;
  SavedConnection? _saved;
  SavedConnection? _duplicate;
  late final ConnectionDiagnostics _diagnostics;
  late final VoidCallback _releaseSetup;
  bool _consent = false;
  bool _busy = false;
  String Function(Strings)? _issue;
  VoidCallback? _retry;
  SetupHostSystem _system = SetupHostSystem.unix;
  bool _prepared = false;
  bool _fromScan = false;

  // Where this Hermes lives: preselected from the code's address, changed on
  // the confirmation screen, saved with the connection.
  InstanceKind _where = InstanceKind.vps;

  // What the verifying screen shows: one state per real check.
  List<OnbCheck> _checks = const [OnbCheck.wait, OnbCheck.wait, OnbCheck.wait];
  double _ringTarget = 0;
  bool _verifyFailed = false;
  bool _exiting = false;

  // Motion.
  late final AnimationController _open = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  );
  late final AnimationController _ambient = AnimationController(
    vsync: this,
    duration: OnboardingMotion.ambientSpan,
  );
  late final AnimationController _move = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 650),
  );
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 800),
  );
  late final AnimationController _burst = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  );
  late final AnimationController _shake = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 520),
  );
  late final AnimationController _hold = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 520),
  );
  late final AnimationController _copied = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  );
  late final AnimationController _exit = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 360),
  );
  final ValueNotifier<int> _tick = ValueNotifier(0);
  bool _opening = false;
  bool _motionReady = false;

  // The hero's place: measured from the current screen's slot, tweened when
  // the screen changes, followed while it scrolls.
  final GlobalKey _stageKey = GlobalKey(debugLabel: 'onboarding-stage');
  final Map<_Step, GlobalKey> _slots = {
    for (final s in _Step.values) s: GlobalKey(debugLabel: 'slot-$s'),
  };
  Rect? _target;
  Rect? _from;
  bool _measureQueued = false;

  @override
  void initState() {
    super.initState();
    _releaseSetup = ConnectionSetupActivity.instance.hold();
    _diagnostics = widget.diagnostics ?? ConnectionDiagnostics();
    if (widget.initialLink != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _receive(widget.initialLink!);
      });
    }
  }

  bool get _reduced => OnboardingMotion.reduced(context);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_motionReady) return;
    _motionReady = true;
    if (_reduced) {
      _open.value = 1;
      _move.value = 1;
      return;
    }
    _opening =
        widget.playOpening ??
        (!OnboardingMotion.openingPlayed && widget.initialLink == null);
    if (_opening) {
      if (OnboardingMotion.lowPower) {
        _open.duration = const Duration(milliseconds: 1500);
      }
      OnboardingMotion.openingPlayed = true;
      _open.forward().whenComplete(() {
        if (mounted) setState(() => _opening = false);
      });
    } else {
      _open.value = 1;
    }
    if (!OnboardingMotion.lowPower) _ambient.forward();
    _move.value = 1;
  }

  @override
  void dispose() {
    for (final c in [
      _open,
      _ambient,
      _move,
      _pulse,
      _burst,
      _shake,
      _hold,
      _copied,
      _exit,
    ]) {
      c.dispose();
    }
    _tick.dispose();
    _diagnostics.close();
    _releaseSetup();
    super.dispose();
  }

  // ── Navigation ─────────────────────────────────────────────────────────

  void _go(_Step to, {bool back = false}) {
    if (!mounted || to == _step) return;
    if (!back && (_step == _Step.welcome || _step == _Step.help)) {
      _history.add(_step);
    }
    _from = _displayRect();
    if (_reduced) {
      _move.value = 1;
    } else {
      _move.forward(from: 0);
    }
    setState(() {
      _forward = !back;
      _step = to;
    });
    if (to == _Step.issue) _shakeIcon();
  }

  void _back() {
    if (_busy || _exiting) return;
    if (_step == _Step.welcome) return;
    _go(_history.isEmpty ? _Step.welcome : _history.removeLast(), back: true);
  }

  void _shakeIcon() {
    if (!_reduced) _shake.forward(from: 0);
  }

  void _skipOpening() {
    if (_open.isAnimating) _open.value = 1;
  }

  // ── Hero geometry ──────────────────────────────────────────────────────

  Rect? _displayRect() {
    final t = _target;
    if (t == null) return null;
    final f = _from;
    if (f == null) return t;
    return Rect.lerp(f, t, Curves.easeInOutCubic.transform(_move.value));
  }

  void _queueMeasure() {
    if (_measureQueued) return;
    _measureQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measureQueued = false;
      if (mounted) _measure();
    });
  }

  void _measure() {
    final slot = _slots[_step]!.currentContext?.findRenderObject();
    final stage = _stageKey.currentContext?.findRenderObject();
    if (slot is! RenderBox ||
        stage is! RenderBox ||
        !slot.attached ||
        !slot.hasSize) {
      return;
    }
    final rect = slot.localToGlobal(Offset.zero, ancestor: stage) & slot.size;
    if (rect == _target) return;
    _target = rect;
    _tick.value++;
  }

  // ── Flow ───────────────────────────────────────────────────────────────

  void _showIssue(String Function(Strings) message, VoidCallback retry) {
    if (!mounted) return;
    _issue = message;
    _retry = retry;
    _go(_Step.issue);
  }

  Future<void> _paste() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (!mounted) return;
      final link = PairingLink.tryParse(data?.text ?? '');
      if (link == null) {
        _showIssue((s) => s.o2InvalidCode, _paste);
      } else {
        _receive(link);
      }
    } catch (_) {
      _showIssue((s) => s.o2ClipboardFailed, _paste);
    }
  }

  Future<void> _scan() async {
    if (widget.scanCode != null) {
      final link = await widget.scanCode!(context);
      if (mounted && link != null) _receive(link);
      return;
    }
    _go(_Step.scan);
  }

  void _receive(PairingLink link, {bool fromScan = false}) {
    final duplicate = widget.connManager.findConnectionByEndpoint(
      host: link.host,
      port: link.port,
      useHttps: link.useHttps,
    );
    _link = link;
    _where = suggestInstanceKind(link.host);
    _consent = false;
    _duplicate = duplicate;
    _fromScan = fromScan || _step == _Step.scan;
    if (_fromScan && !_reduced) _pulse.forward(from: 0);
    _go(duplicate == null ? _Step.confirm : _Step.duplicate);
  }

  bool _needsConsent(SavedConnection connection) {
    final uri = Uri.tryParse(connection.effectiveDashboardUrl);
    if (uri == null || uri.scheme == 'https') return false;
    return uri.host != 'localhost' &&
        !(InternetAddress.tryParse(uri.host)?.isLoopback ?? false);
  }

  SavedConnection _draft(PairingLink link) => link.toDraftConnection().copyWith(
    id: const Uuid().v4(),
    dashboardAuthMode: link.hasDashboardLogin
        ? AuthMode.basicAuth
        : AuthMode.unknown,
    kind: _where,
  );

  static const _unreachable = {
    ProbeStatus.timeout,
    ProbeStatus.dnsError,
    ProbeStatus.refused,
    ProbeStatus.error,
    ProbeStatus.tlsError,
  };

  /// What the first surface's probes say about the first two checks.
  void _gatewayChecks(List<ProbeResult> results, bool hasDashboard) {
    final reach = !results.every((r) => _unreachable.contains(r.status));
    final key = results.any((r) => r.name == 'sessions' && r.status.isOk);
    _checks = [
      reach ? OnbCheck.ok : OnbCheck.no,
      !reach ? OnbCheck.wait : (key ? OnbCheck.ok : OnbCheck.no),
      key && hasDashboard ? OnbCheck.spin : OnbCheck.wait,
    ];
    _verifyFailed = !(reach && key);
    _ringTarget =
        (_checks.where((c) => c == OnbCheck.ok).length) /
        (hasDashboard ? 3 : 2);
  }

  void _dashboardCheck(List<ProbeResult> results) {
    final ok =
        results.any((r) => r.name == 'auth' && r.status.isOk) &&
        !results.any(
          (r) =>
              r.status == ProbeStatus.authInvalid ||
              r.status == ProbeStatus.authRequired,
        );
    _checks = [..._checks.take(2), ok ? OnbCheck.ok : OnbCheck.no];
    _verifyFailed = !ok;
    _ringTarget = ok ? 1 : 2 / 3;
  }

  Future<void> _pause() async {
    if (_reduced || !mounted) return;
    await _hold.forward(from: 0);
  }

  Future<void> _connect() async {
    final link = _link;
    if (_busy || link == null) return;
    final draft = _draft(link);
    if (link.hasDashboardLogin && _needsConsent(draft) && !_consent) return;
    // Validate both destinations before either credential can leave.
    if (TransportPrivacy.classify(draft.gatewayUrl) ==
            TransportPrivacyClass.publicCleartext ||
        TransportPrivacy.classify(draft.effectiveDashboardUrl) ==
            TransportPrivacyClass.publicCleartext) {
      _showIssue((s) => s.commonCleartextPublic, _goScan);
      return;
    }
    _busy = true;
    setState(() {
      _checks = [OnbCheck.spin, OnbCheck.wait, OnbCheck.wait];
      _ringTarget = 0.06;
      _verifyFailed = false;
    });
    _go(_Step.connecting);
    try {
      final report = await _diagnostics.run(
        Strings.of(context),
        draft,
        DashboardSecrets(
          username: link.dashboardUser,
          password: link.dashboardPassword,
        ),
        onStage: (stage, results) {
          if (!mounted) return;
          setState(() {
            if (stage == DiagnosticsStage.gateway) {
              _gatewayChecks(results, link.hasDashboardLogin);
            } else if (link.hasDashboardLogin) {
              _dashboardCheck(results);
            }
          });
        },
      );
      if (!mounted) return;
      // The report is the truth: settle the rows on it.
      setState(() {
        _gatewayChecks(report.gateway, link.hasDashboardLogin);
        if (link.hasDashboardLogin &&
            _checks[1] == OnbCheck.ok &&
            report.dashboard.isNotEmpty) {
          _dashboardCheck(report.dashboard);
        }
      });
      if (!report.gateway.any((r) => r.name == 'sessions' && r.status.isOk)) {
        final authFailed = report.gateway.any(
          (r) =>
              r.status == ProbeStatus.authInvalid ||
              r.status == ProbeStatus.authRequired,
        );
        await _pause();
        if (!mounted) return;
        _showIssue(
          (s) => authFailed ? s.o2KeyRejected : s.o2Unreachable,
          authFailed ? _goScan : _connect,
        );
        return;
      }
      final connection = draft.copyWith(
        readOnly:
            report.matrix.chatSupported.isNo &&
            report.matrix.sessionsWrite.isNo,
      );
      // Secure-storage writes finish before Home observes the connection.
      if (link.hasDashboardLogin) {
        await widget.connManager.setDashboardSecrets(
          connection.id,
          username: link.dashboardUser,
          password: link.dashboardPassword,
        );
      }
      await widget.connManager.upsertConnection(connection);
      await widget.connManager.setActiveConnection(connection.id);
      await widget.connManager.saveCapabilities(connection.id, report.matrix);
      if (!mounted) return;
      final dashboardReady =
          link.hasDashboardLogin && _checks[2] == OnbCheck.ok;
      _saved = connection;
      await _pause();
      if (!mounted) return;
      if (dashboardReady) {
        _celebrate();
        _go(_Step.success);
      } else {
        _go(_Step.signIn);
      }
    } catch (_) {
      if (mounted) _showIssue((s) => s.o2ConnectionFailed, _connect);
    } finally {
      _busy = false;
    }
  }

  void _celebrate() {
    unawaited(HapticFeedback.mediumImpact().catchError((_) {}));
    if (!_reduced) _burst.forward(from: 0);
  }

  void _goScan() => unawaited(_scan());

  Future<void> _signIn() async {
    final connection = _saved;
    if (connection == null) return;
    final revision = widget.connManager
        .connectionRevisionFor(connection.id)
        .value;
    final profileRevision = widget.connManager
        .activeProfileRevisionFor(connection.id)
        .value;
    bool current() =>
        widget.connManager.getConnections().any(
          (c) =>
              c.id == connection.id &&
              c.gatewayUrl == connection.gatewayUrl &&
              c.effectiveDashboardUrl == connection.effectiveDashboardUrl,
        ) &&
        widget.connManager.connectionRevisionFor(connection.id).value ==
            revision &&
        widget.connManager.activeProfileRevisionFor(connection.id).value ==
            profileRevision;
    final result = await Navigator.of(context).push<DashboardCredsResult>(
      MaterialPageRoute(
        builder: (_) => DashboardSetupScreen(
          connection: connection,
          authorityCurrent: current,
        ),
      ),
    );
    if (!mounted || result == null || !current()) return;
    try {
      await widget.connManager.setDashboardSecrets(
        connection.id,
        username: result.username,
        password: result.password,
        sessionToken: result.sessionToken,
      );
      final updated = connection.copyWith(dashboardAuthMode: result.mode);
      await widget.connManager.upsertConnection(updated);
      await widget.connManager.saveCapabilities(
        updated.id,
        capabilitiesAfterDashboardLogin(
          widget.connManager.loadCapabilities(updated.id),
        ),
      );
      if (mounted) {
        _saved = updated;
        setState(() => _checks = const [OnbCheck.ok, OnbCheck.ok, OnbCheck.ok]);
        _celebrate();
        _go(_Step.success);
      }
    } catch (_) {
      if (mounted) {
        _showIssue((s) => s.o2SaveFailed, _signIn);
      }
    }
  }

  Future<void> _manual({SavedConnection? initial}) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => InstanceEditScreen(
          connManager: widget.connManager,
          initial: initial,
          verifyChatBeforeSave: true,
          diagnostics: widget.diagnostics,
        ),
      ),
    );
    if (!mounted || saved != true) return;
    final connection = widget.connManager
        .getConnections()
        .where(
          (c) =>
              c.id ==
              (initial?.id ?? widget.connManager.activeConnectionId.value),
        )
        .firstOrNull;
    if (connection == null) return;
    await widget.connManager.setActiveConnection(connection.id);
    if (!mounted) return;
    _saved = connection;
    // Saving a form alone is not proof of Dashboard authentication.
    final ready =
        widget.connManager
            .loadCapabilities(connection.id)
            .dashboardAuthValid
            .isYes ==
        true;
    if (ready) {
      setState(() => _checks = const [OnbCheck.ok, OnbCheck.ok, OnbCheck.ok]);
      _celebrate();
    }
    _go(ready ? _Step.success : _Step.signIn);
  }

  Future<void> _finish() async {
    if (_saved == null ||
        !widget.connManager.getConnections().any((c) => c.id == _saved!.id)) {
      return;
    }
    if (_exiting) return;
    _exiting = true;
    if (!_reduced) {
      setState(() {});
      await _exit.forward();
    }
    if (mounted) widget.onDone();
  }

  Future<void> _copy(String command) async {
    await onbCopy(command);
    if (mounted && !_reduced) {
      await _copied.forward(from: 0);
    }
  }

  Future<void> _send(String command) async {
    try {
      await Share.share(command);
    } catch (_) {}
  }

  // ── Build ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).hermes;
    _queueMeasure();
    return PopScope(
      canPop: _step == _Step.welcome && !_busy && !_exiting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        key: _stageKey,
        backgroundColor: c.background,
        resizeToAvoidBottomInset: true,
        body: Listener(
          onPointerDown: (_) => _skipOpening(),
          child: AnimatedBuilder(
            animation: _exit,
            builder: (context, child) {
              final t = Curves.easeInCubic.transform(_exit.value);
              return Opacity(
                opacity: 1 - t,
                child: Transform.scale(scale: 1 + 0.08 * t, child: child),
              );
            },
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (_step != _Step.scan) _ambientLayer(c),
                NotificationListener<ScrollNotification>(
                  onNotification: (_) {
                    _queueMeasure();
                    return false;
                  },
                  child: AnimatedSwitcher(
                    duration: Duration(milliseconds: _reduced ? 150 : 260),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (child, animation) {
                      if (_reduced) {
                        return FadeTransition(opacity: animation, child: child);
                      }
                      final incoming = child.key == ValueKey(_step);
                      // Forward, the current scene recedes and the next one
                      // arrives from in front; back, the reverse.
                      final from = incoming
                          ? (_forward ? 1.04 : 0.96)
                          : (_forward ? 0.96 : 1.04);
                      return FadeTransition(
                        opacity: animation,
                        child: AnimatedBuilder(
                          animation: animation,
                          child: child,
                          builder: (_, child) => Transform.scale(
                            scale: from + (1 - from) * animation.value,
                            child: child,
                          ),
                        ),
                      );
                    },
                    child: KeyedSubtree(
                      key: ValueKey(_step),
                      child: _content(context),
                    ),
                  ),
                ),
                if (_step != _Step.scan) _heroLayer(c),
                _openingVeil(c),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Ambient light, hero, veil ──────────────────────────────────────────

  Widget _ambientLayer(HermesThemeColors c) {
    final reduced = _reduced;
    final tint = _step == _Step.issue || _verifyFailed && _step == _Step.signIn
        ? c.warning
        : c.accent;
    final rest = switch (_step) {
      _Step.welcome ||
      _Step.help ||
      _Step.confirm ||
      _Step.connecting ||
      _Step.success => 1.0,
      _ => 0.4,
    };
    final merged = Listenable.merge([_ambient, _move, _open, _tick, _burst]);
    return Positioned.fill(
      child: IgnorePointer(
        child: RepaintBoundary(
          child: LayoutBuilder(
            builder: (context, box) {
              final size = box.biggest;
              Offset center() =>
                  _displayRect()?.center.translate(0, _parallax()) ??
                  Offset(size.width / 2, size.height * 0.34);
              double radius() {
                final r = _displayRect();
                final base = r == null ? 150.0 : (r.shortestSide * 1.1 + 60);
                final openScale = _opening
                    ? 0.15 +
                          0.85 * ivl(_open.value, 0, 0.4 / 2.6, Curves.easeOut)
                    : 1.0;
                return base.clamp(110.0, 230.0) * openScale;
              }

              double strength() {
                final breath = reduced || _ambient.isDismissed
                    ? 1.0
                    : 0.8 +
                          0.2 *
                              (0.5 +
                                  0.5 *
                                      _wave(
                                        _ambient.value *
                                            OnboardingMotion
                                                .ambientSpan
                                                .inMilliseconds /
                                            4500,
                                      ));
                final fadeIn = _opening
                    ? ivl(_open.value, 0, 0.4 / 2.6, Curves.easeOut)
                    : 1.0;
                return breath * fadeIn * rest;
              }

              double motesT() =>
                  _ambient.value * OnboardingMotion.ambientSpan.inSeconds / 36;
              double motesStrength() {
                if (reduced || OnboardingMotion.lowPower) return 0;
                // Fade out when the run ends.
                final end = 1 - ivl(_ambient.value, 0.94, 1);
                final start = _opening ? ivl(_open.value, 0.45, 0.8) : 1.0;
                return rest * end * start;
              }

              return Stack(
                fit: StackFit.expand,
                children: [
                  CustomPaint(
                    painter: GlowPainter(
                      center: center,
                      radius: radius,
                      color: tint,
                      strength: strength,
                      repaint: merged,
                    ),
                  ),
                  CustomPaint(
                    painter: MotesPainter(
                      t: motesT,
                      color: tint,
                      strength: motesStrength,
                      repaint: _ambient,
                    ),
                  ),
                  CustomPaint(
                    painter: BurstPainter(
                      t: () => _burst.value,
                      center: () => center(),
                      color: tint,
                      radius: 80,
                      repaint: _burst,
                    ),
                  ),
                  CustomPaint(
                    painter: PulseRingPainter(
                      t: () => _pulse.value,
                      center: () => center(),
                      color: tint,
                      from: 40,
                      to: size.shortestSide * 0.8,
                      repaint: _pulse,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// The glow moves less than the mark while the camera glides.
  double _parallax() {
    if (!_opening || _step != _Step.welcome) return 0;
    final cam = ivl(_open.value, 1700 / _openMs, 1, Curves.easeInOutCubic);
    return 28 * 0.5 * (1 - cam);
  }

  _Hero get _kind => switch (_step) {
    _Step.welcome || _Step.help || _Step.confirm => _Hero.mark,
    _Step.connecting => _Hero.ring,
    _Step.success => _Hero.check,
    _ => _Hero.none,
  };

  Widget _heroLayer(HermesThemeColors c) {
    final merged = Listenable.merge([_move, _open, _tick]);
    return Positioned.fill(
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: merged,
          builder: (context, _) {
            if (_move.isAnimating) _queueMeasure();
            final rect = _displayRect();
            final kind = _kind;
            Widget? hero;
            if (rect != null && kind != _Hero.none) {
              hero = switch (kind) {
                _Hero.mark => _markHero(rect, c),
                _Hero.ring => _ringHero(rect, c),
                _Hero.check => _checkHero(rect, c),
                _Hero.none => null,
              };
            }
            return Stack(
              clipBehavior: Clip.none,
              children: [
                if (rect != null)
                  Positioned.fromRect(
                    rect: rect,
                    child: AnimatedSwitcher(
                      duration: Duration(milliseconds: _reduced ? 150 : 320),
                      child: hero == null
                          ? const SizedBox.shrink(key: ValueKey('none'))
                          : KeyedSubtree(key: ValueKey(kind), child: hero),
                    ),
                  ),
                if (rect != null &&
                    _opening &&
                    _open.value < 1 &&
                    _step == _Step.welcome &&
                    kind == _Hero.mark)
                  _wordmark(rect, c),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _markHero(Rect rect, HermesThemeColors c) {
    final size = rect.shortestSide;
    if (!(_opening && _step == _Step.welcome)) {
      return Center(child: ConsoleMark(size: size));
    }
    final t = _open.value;
    final arc = ivl(t, 300 / _openMs, 900 / _openMs, Curves.easeInOutCubic);
    final bar = ivl(t, 800 / _openMs, 1100 / _openMs, Curves.easeOut);
    // 0.9 -> 1.06 as it draws, then settles back to 1.
    final grow = ivl(t, 300 / _openMs, 1100 / _openMs, Curves.easeOut);
    final settle = ivl(t, 1100 / _openMs, 1400 / _openMs, Curves.easeInOut);
    final overshoot = 0.9 + 0.16 * grow - 0.06 * settle;
    final g = ivl(t, 900 / _openMs, 1500 / _openMs, Curves.easeInOut);
    final glint = g <= 0 || g >= 1 ? null : -0.3 + 1.6 * g;
    final cam = ivl(t, 1700 / _openMs, 1, Curves.easeInOutCubic);
    return Transform.translate(
      offset: Offset(0, 28 * (1 - cam)),
      child: Transform.scale(
        scale: (1 + 0.15 * (1 - cam)) * overshoot,
        child: Center(
          child: ConsoleMark(size: size, arc: arc, bar: bar, glint: glint),
        ),
      ),
    );
  }

  Widget _wordmark(Rect rect, HermesThemeColors c) {
    final t = _open.value;
    final inT = ivl(t, 1100 / _openMs, 1900 / _openMs, Curves.easeOut);
    final out = ivl(t, 2200 / _openMs, 2450 / _openMs);
    final cam = ivl(t, 1700 / _openMs, 1, Curves.easeInOutCubic);
    return Positioned(
      left: 0,
      right: 0,
      top: rect.bottom + 18 + 28 * (1 - cam),
      child: Opacity(
        opacity: inT * (1 - out),
        child: Text(
          'CONSOLE',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: c.textSecondary,
            letterSpacing: 16 - 12 * inT,
          ),
        ),
      ),
    );
  }

  Widget _ringHero(Rect rect, HermesThemeColors c) {
    final size = rect.shortestSide;
    final color = _verifyFailed ? c.warning : c.accent;
    return Center(
      child: SizedBox.square(
        dimension: size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            TweenAnimationBuilder<double>(
              tween: Tween(end: _ringTarget),
              duration: Duration(milliseconds: _reduced ? 0 : 450),
              curve: Curves.easeOutCubic,
              builder: (context, value, _) => CustomPaint(
                key: const ValueKey('onboarding-ring'),
                size: Size.square(size),
                painter: ProgressRingPainter(
                  progress: value,
                  color: color,
                  track: c.divider.withValues(alpha: .7),
                ),
              ),
            ),
            ConsoleMark(size: size * 0.5),
          ],
        ),
      ),
    );
  }

  Widget _checkHero(Rect rect, HermesThemeColors c) {
    final size = rect.shortestSide;
    return Center(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(shape: BoxShape.circle, color: c.accent),
        child: Padding(
          padding: EdgeInsets.all(size * 0.14),
          child: DrawnCheck(
            size: size * 0.72,
            color: c.onAccent,
            width: size * 0.07,
            duration: const Duration(milliseconds: 520),
          ),
        ),
      ),
    );
  }

  Widget _openingVeil(HermesThemeColors c) {
    if (!_opening) return const SizedBox.shrink();
    return Positioned.fill(
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: _open,
          builder: (_, _) {
            final a = 1 - ivl(_open.value, 0, 0.4 / 2.6, Curves.easeOut);
            return a <= 0
                ? const SizedBox.shrink()
                : ColoredBox(color: Colors.black.withValues(alpha: a));
          },
        ),
      ),
    );
  }

  // ── Screens ────────────────────────────────────────────────────────────

  Widget _content(BuildContext context) => switch (_step) {
    _Step.welcome => _welcome(context),
    _Step.help => _help(context),
    _Step.scan => QrScanView(
      cameraBuilder: widget.cameraBuilder,
      onBack: _back,
      onLink: (link) => _receive(link, fromScan: true),
    ),
    _Step.confirm => _confirm(context),
    _Step.connecting => _connecting(context),
    _Step.issue => _issueScreen(context, duplicate: false),
    _Step.duplicate => _issueScreen(context, duplicate: true),
    _Step.signIn => _signInScreen(context),
    _Step.success => _success(context),
  };

  /// The frame every screen shares: one gutter, safe areas, a scroll that only
  /// matters at 320 dp and 2x text, and a column that fills the screen so the
  /// actions sit at its foot.
  Widget _frame({required List<Widget> children, bool back = false}) {
    return SafeArea(
      child: LayoutBuilder(
        builder: (context, box) => SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            kOnbGutter,
            0,
            kOnbGutter,
            MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: box.maxHeight),
            child: IntrinsicHeight(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    height: 56,
                    child: back
                        ? Align(
                            alignment: Alignment.centerLeft,
                            child: Transform.translate(
                              offset: const Offset(-8, 0),
                              child: OnbBack(onTap: _back),
                            ),
                          )
                        : null,
                  ),
                  ...children,
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  double _slotSize(double fraction, double min, double max) =>
      (MediaQuery.sizeOf(context).height * fraction).clamp(min, max);

  Widget _slot(_Step step, {double min = 64, double max = 140}) {
    final size = _slotSize(0.12, min, max);
    return Expanded(
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: size),
        child: Center(
          child: SizedBox.square(key: _slots[step], dimension: size),
        ),
      ),
    );
  }

  Widget _rise(int i, Widget child) {
    if (!_opening && _open.value >= 1) return child;
    return AnimatedBuilder(
      animation: _open,
      child: child,
      builder: (_, child) {
        final a = ivl(
          _open.value,
          (1700 + 70 * i) / _openMs,
          (2150 + 70 * i) / _openMs,
          Curves.easeOutCubic,
        );
        return Opacity(
          opacity: a,
          child: Transform.translate(
            offset: Offset(0, 12 * (1 - a)),
            child: child,
          ),
        );
      },
    );
  }

  Widget _welcome(BuildContext context) {
    final s = Strings.of(context);
    final c = Theme.of(context).hermes;
    final heroSize = _slotSize(0.17, 72, 140);
    return _frame(
      children: [
        // The hero's place: the logo glides into it.
        Expanded(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: heroSize + 16),
            child: Center(
              child: SizedBox.square(
                key: _slots[_Step.welcome],
                dimension: heroSize,
              ),
            ),
          ),
        ),
        _rise(
          0,
          Semantics(
            header: true,
            child: Text(
              s.o2WelcomeTitle,
              textAlign: TextAlign.center,
              textScaler: onbTitleScaler(context),
              style: onbTitle(c),
            ),
          ),
        ),
        const SizedBox(height: 12),
        _rise(
          1,
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              s.o2WelcomeBody,
              textAlign: TextAlign.center,
              style: onbBody(c),
            ),
          ),
        ),
        const SizedBox(height: 30),
        AnimatedBuilder(
          animation: _open,
          builder: (_, _) {
            final e = _opening
                ? ivl(_open.value, 1700 / _openMs, 1, Curves.easeInOutCubic)
                : 1.0;
            final shown = _opening
                ? ivl(_open.value, 1450 / _openMs, 1700 / _openMs)
                : 1.0;
            return Opacity(
              opacity: shown,
              child: OnbPrimary(
                key: const ValueKey('onboarding-scan'),
                label: s.o2Scan,
                icon: Icons.qr_code_scanner_rounded,
                expand: e,
                onTap: _scan,
              ),
            );
          },
        ),
        const SizedBox(height: 6),
        _rise(
          3,
          OnbTextButton(
            key: const ValueKey('onboarding-help'),
            label: s.o2NoCode,
            onTap: () => _go(_Step.help),
          ),
        ),
        _rise(
          4,
          OnbTextButton(
            key: const ValueKey('onboarding-manual'),
            label: s.o2Manual,
            onTap: _manual,
          ),
        ),
      ],
    );
  }

  Widget _help(BuildContext context) {
    final s = Strings.of(context);
    final c = Theme.of(context).hermes;
    final windows = _system == SetupHostSystem.windows;
    final command = _prepared
        ? HermesSetupCommands.showCodeAgain(_system)
        : HermesSetupCommands.setup(_system);
    Widget step(int n, Widget body, {bool last = false}) {
      final delay = Duration(milliseconds: 160 + 140 * n);
      return IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 30,
              child: Column(
                children: [
                  PopIn(
                    delay: delay,
                    child: Container(
                      width: 30,
                      height: 30,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: c.surfaceVariant,
                      ),
                      child: Text(
                        '$n',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: c.textPrimary,
                        ),
                      ),
                    ),
                  ),
                  if (!last)
                    Expanded(
                      child: _Connector(delay: delay, color: c.divider),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(top: 4, bottom: last ? 0 : 18),
                child: RiseIn(delay: delay, child: body),
              ),
            ),
          ],
        ),
      );
    }

    Widget line(String text) => Text(
      text,
      style: TextStyle(
        fontSize: 15.5,
        fontWeight: FontWeight.w600,
        height: 1.3,
        color: c.textPrimary,
      ),
    );
    return _frame(
      back: true,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Semantics(
                header: true,
                child: Text(
                  s.o2HelpTitle,
                  textScaler: onbTitleScaler(context),
                  style: onbTitle(c, size: 26),
                ),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox.square(key: _slots[_Step.help], dimension: 44),
          ],
        ),
        const SizedBox(height: 20),
        OnbSegmented<SetupHostSystem>(
          value: _system,
          onChanged: (v) => setState(() => _system = v),
          options: [
            (
              SetupHostSystem.unix,
              s.o2MacLinux,
              const ValueKey('pairing-helper-unix'),
            ),
            (
              SetupHostSystem.windows,
              s.o2Windows,
              const ValueKey('pairing-helper-windows'),
            ),
          ],
        ),
        const SizedBox(height: 22),
        step(1, line(windows ? s.o2StepPowerShell : s.o2StepTerminal)),
        step(
          2,
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              line(s.o2StepPaste),
              const SizedBox(height: 10),
              KeyedSubtree(
                key: const ValueKey('pairing-helper-command'),
                child: OnbCodeBlock(command: command),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  AnimatedBuilder(
                    animation: _copied,
                    builder: (_, _) {
                      final done = _copied.isAnimating;
                      return OnbSmallPill(
                        key: const ValueKey('pairing-helper-copy'),
                        label: done ? s.o2Copied : s.o2Copy,
                        icon: done ? Icons.check_rounded : Icons.copy_rounded,
                        filled: true,
                        onTap: () => unawaited(_copy(command)),
                      );
                    },
                  ),
                  OnbSmallPill(
                    key: const ValueKey('pairing-helper-send'),
                    label: s.o2SendToComputer,
                    icon: Icons.ios_share_rounded,
                    onTap: () => unawaited(_send(command)),
                  ),
                ],
              ),
            ],
          ),
        ),
        step(3, line(s.o2StepCode), last: true),
        const Expanded(child: SizedBox(height: 24)),
        OnbPrimary(
          key: const ValueKey('onboarding-code-visible'),
          label: s.o2CodeVisible,
          icon: Icons.qr_code_scanner_rounded,
          onTap: _scan,
        ),
        const SizedBox(height: 6),
        OnbTextButton(
          key: const ValueKey('pairing-helper-prepared'),
          label: _prepared ? s.o2PrepareComputer : s.o2AlreadyPrepared,
          onTap: () => setState(() => _prepared = !_prepared),
        ),
        OnbTextButton(
          key: const ValueKey('onboarding-paste'),
          label: s.o2HaveLink,
          onTap: _paste,
        ),
      ],
    );
  }

  Widget _confirm(BuildContext context) {
    final s = Strings.of(context);
    final c = Theme.of(context).hermes;
    final link = _link!;
    final needsConsent = link.hasDashboardLogin && _needsConsent(_draft(link));
    return _frame(
      back: true,
      children: [
        _slot(_Step.confirm, min: 56, max: 104),
        RiseIn(
          child: Semantics(
            header: true,
            child: Text(
              s.o2ConfirmTitle(link.label ?? link.host),
              textAlign: TextAlign.center,
              textScaler: onbTitleScaler(context),
              style: onbTitle(c, size: 26),
            ),
          ),
        ),
        const SizedBox(height: 10),
        RiseIn(
          delay: const Duration(milliseconds: 70),
          child: Text(
            link.hasDashboardLogin ? s.o2ConfirmFull : s.o2ConfirmChat,
            textAlign: TextAlign.center,
            style: onbBody(c),
          ),
        ),
        const SizedBox(height: 22),
        RiseIn(
          delay: const Duration(milliseconds: 140),
          child: OnbCard(
            child: Column(
              children: [
                OnbCheckRow(
                  state: OnbCheck.ok,
                  title: s.o2SummaryChat,
                  note: link.host,
                ),
                OnbCheckRow(
                  state: link.hasDashboardLogin ? OnbCheck.ok : OnbCheck.wait,
                  title: s.o2SummaryDashboard,
                  note: link.hasDashboardLogin
                      ? null
                      : s.o2SummaryDashboardLater,
                  last: true,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 22),
        InstanceKindPicker(
          title: s.o2KindTitle,
          value: _where,
          onChanged: (kind) => setState(() => _where = kind),
          entrance: (i, child) => RiseIn(
            delay: Duration(milliseconds: 210 + 50 * (i + 1)),
            child: child,
          ),
        ),
        if (needsConsent)
          CheckboxListTile(
            key: const ValueKey('pairing-http-consent'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _consent,
            onChanged: (v) => setState(() => _consent = v == true),
            title: Text(s.dashboardSetupCredentialConsent),
          ),
        const Expanded(child: SizedBox(height: 24)),
        OnbPrimary(
          key: const ValueKey('onboarding-confirm'),
          label: s.o2Connect,
          onTap: needsConsent && !_consent ? null : _connect,
        ),
        const SizedBox(height: 6),
        OnbTextButton(
          key: const ValueKey('onboarding-other'),
          label: s.o2OtherCode,
          onTap: _goScan,
        ),
      ],
    );
  }

  Widget _checkCard(
    Strings s, {
    bool staggered = false,
    bool identity = false,
  }) {
    final hasDash = _link?.hasDashboardLogin ?? true;
    final saved = _saved;
    Widget row(int i, String title, {bool last = false}) {
      final r = OnbCheckRow(state: _checks[i], title: title, last: last);
      return staggered
          ? RiseIn(
              delay: Duration(milliseconds: 200 + 120 * i),
              child: r,
            )
          : r;
    }

    return OnbCard(
      child: Column(
        children: [
          if (identity && saved != null)
            RiseIn(
              delay: const Duration(milliseconds: 120),
              child: OnbIdentityRow(
                key: const ValueKey('onboarding-identity'),
                icon: instanceKindIcon(saved.kind),
                title: saved.label,
                note: instanceKindLabel(s, saved.kind),
              ),
            ),
          row(0, s.o2CheckFind),
          row(1, s.o2CheckChat, last: !hasDash && _step != _Step.success),
          if (hasDash || _step == _Step.success)
            row(2, s.o2CheckDashboard, last: true),
        ],
      ),
    );
  }

  Widget _connecting(BuildContext context) {
    final s = Strings.of(context);
    final c = Theme.of(context).hermes;
    return _frame(
      children: [
        _slot(_Step.connecting, min: 96, max: 150),
        Semantics(
          liveRegion: true,
          header: true,
          child: Text(
            s.o2Connecting,
            textAlign: TextAlign.center,
            textScaler: onbTitleScaler(context),
            style: onbTitle(c, size: 26),
          ),
        ),
        const SizedBox(height: 24),
        _checkCard(s),
        const Expanded(child: SizedBox(height: 24)),
      ],
    );
  }

  Widget _issueScreen(BuildContext context, {required bool duplicate}) {
    final s = Strings.of(context);
    final c = Theme.of(context).hermes;
    final tone = duplicate ? c.accent : c.error;
    final message = duplicate ? s.o2Duplicate : _issue!(s);
    return _frame(
      back: true,
      children: [
        const SizedBox(height: 8),
        Semantics(
          header: true,
          child: Text(
            duplicate ? s.o2DuplicateTitle : s.o2IssueTitle,
            textScaler: onbTitleScaler(context),
            style: onbTitle(c, size: 26),
          ),
        ),
        const SizedBox(height: 18),
        OnbCard(
          tone: tone,
          padding: const EdgeInsets.fromLTRB(13, 14, 15, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AnimatedBuilder(
                animation: _shake,
                builder: (_, child) => Transform.translate(
                  offset: Offset(
                    _wave(_shake.value * 3) * 6 * (1 - _shake.value),
                    0,
                  ),
                  child: child,
                ),
                child: Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: tone.withValues(alpha: .16),
                  ),
                  child: Icon(
                    duplicate ? Icons.link_rounded : Icons.wifi_off_rounded,
                    size: 17,
                    color: tone,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        message,
                        style: TextStyle(
                          fontSize: 15.5,
                          fontWeight: FontWeight.w600,
                          height: 1.35,
                          color: c.textPrimary,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (duplicate)
                          OnbSmallPill(
                            key: const ValueKey('onboarding-open-existing'),
                            label: s.o2OpenConnection,
                            filled: true,
                            onTap: () => _manual(initial: _duplicate),
                          )
                        else
                          OnbSmallPill(
                            key: const ValueKey('onboarding-retry'),
                            label: s.commonRetry,
                            icon: Icons.refresh_rounded,
                            filled: true,
                            onTap: _retry,
                          ),
                        OnbSmallPill(
                          key: const ValueKey('onboarding-other'),
                          label: s.o2OtherShort,
                          onTap: _goScan,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const Expanded(child: SizedBox(height: 24)),
      ],
    );
  }

  Widget _signInScreen(BuildContext context) {
    final s = Strings.of(context);
    final c = Theme.of(context).hermes;
    return _frame(
      children: [
        const SizedBox(height: 8),
        Semantics(
          header: true,
          child: Text(
            s.o2MissingStep,
            textScaler: onbTitleScaler(context),
            style: onbTitle(c, size: 26),
          ),
        ),
        const SizedBox(height: 10),
        Text(s.o2MissingDashboard, style: onbBody(c)),
        const SizedBox(height: 22),
        RiseIn(
          child: OnbCard(
            child: Column(
              children: [
                OnbCheckRow(state: OnbCheck.ok, title: s.o2SummaryChat),
                OnbCheckRow(
                  state: OnbCheck.no,
                  title: s.o2SummaryDashboard,
                  note: s.o2MissingPassword,
                  last: true,
                ),
              ],
            ),
          ),
        ),
        const Expanded(child: SizedBox(height: 24)),
        OnbPrimary(
          key: const ValueKey('onboarding-sign-in'),
          label: s.o2SignIn,
          onTap: _signIn,
        ),
        const SizedBox(height: 6),
        OnbTextButton(
          key: const ValueKey('onboarding-forgot'),
          label: s.o2ForgotPassword,
          onTap: () => unawaited(showDashboardPasswordHelp(context)),
        ),
        OnbTextButton(
          key: const ValueKey('onboarding-chat-only'),
          label: s.o2ChatOnly,
          onTap: _finish,
        ),
      ],
    );
  }

  Widget _success(BuildContext context) {
    final s = Strings.of(context);
    final c = Theme.of(context).hermes;
    final readOnly = _saved?.readOnly ?? false;
    return _frame(
      children: [
        _slot(_Step.success, min: 84, max: 120),
        RiseIn(
          delay: const Duration(milliseconds: 380),
          child: Semantics(
            header: true,
            liveRegion: true,
            child: Text(
              s.o2SuccessTitle,
              textAlign: TextAlign.center,
              textScaler: onbTitleScaler(context),
              style: onbTitle(c),
            ),
          ),
        ),
        const SizedBox(height: 10),
        RiseIn(
          delay: const Duration(milliseconds: 450),
          child: Text(
            readOnly ? s.o2ReadOnly : s.o2SuccessBody,
            textAlign: TextAlign.center,
            style: onbBody(c),
          ),
        ),
        const SizedBox(height: 24),
        _checkCard(s, staggered: true, identity: true),
        const Expanded(child: SizedBox(height: 24)),
        OnbPrimary(
          key: const ValueKey('onboarding-done'),
          label: s.o2GoHome,
          icon: Icons.home_outlined,
          onTap: _finish,
        ),
      ],
    );
  }
}

/// The line that draws itself down between two numbered discs.
class _Connector extends StatefulWidget {
  const _Connector({required this.delay, required this.color});
  final Duration delay;
  final Color color;

  @override
  State<_Connector> createState() => _ConnectorState();
}

class _ConnectorState extends State<_Connector>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: widget.delay + const Duration(milliseconds: 420),
  );
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (OnboardingMotion.reduced(context)) {
      _c.value = 1;
    } else {
      _c.forward();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final begin =
        (widget.delay + const Duration(milliseconds: 160)).inMicroseconds /
        _c.duration!.inMicroseconds;
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) => Align(
        alignment: Alignment.topCenter,
        child: FractionallySizedBox(
          heightFactor: ivl(_c.value, begin.clamp(0.0, 0.95), 1),
          child: Container(
            width: 2,
            margin: const EdgeInsets.symmetric(vertical: 4),
            decoration: BoxDecoration(
              color: widget.color,
              borderRadius: BorderRadius.circular(1),
            ),
          ),
        ),
      ),
    );
  }
}
