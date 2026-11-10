import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderBackdropFilter;
import 'package:flutter/scheduler.dart' show SchedulerBinding, SchedulerPhase;
import 'package:flutter/services.dart';

import '../design/tokens.dart' show HermesChrome;
import '../design/glass_strip.dart';
import '../design/liquid_glass.dart';
import '../design/smoked_glass.dart';
import '../theme/app_theme.dart';

/// The single material decision shared by bands and individual surfaces.
enum HermesGlassTier { chrome, glass, liquid }

/// Device-wide switches for backdrop blur.
///
/// A backdrop blur re-samples and filters whatever is behind it on every
/// frame in which that backdrop changes, so over a scrolling list it costs
/// raster time per frame. On devices that report themselves as constrained
/// that cost is dropped.
abstract final class FrostedBackdropPolicy {
  /// True when the platform reports a low-RAM device or battery saver.
  /// Onboarding and the voice prewarm read it too: it keeps that meaning.
  static final reducedPerformance = ValueNotifier<bool>(false);

  /// Whether a frosted surface may blur at all on this device (Q9-CHAT5,
  /// the owner's cost rules 4 and 6). False with [reducedPerformance], when the
  /// person switched blurs off («Allow window-level blurs» in the developer
  /// options, One UI's «Reduce transparency and blur») and, while
  /// [blurNeedsHighEnd] holds, on a mid or low range device.
  ///
  /// Not when the device merely lacks blurs between windows
  /// (`WindowManager.isCrossWindowBlurEnabled` false): that is the system
  /// blurring one window behind another, not the app frosting its own
  /// pieces. Samsung devices report it off, and the Fold showed the chrome
  /// of before for it (Q9-CRISTAL-DETRAS).
  static final blurAllowed = ValueNotifier<bool>(true);

  /// A physical GPU measurement must precede the expensive effect's
  /// default activation. QA can opt in on the same production widgets;
  /// this never overrides accessibility, battery or the user's dock fill.
  static final liquidGpuValidated = ValueNotifier<bool>(
    const bool.fromEnvironment('HERMES_LIQUID_GPU_VALIDATED'),
  );

  /// Unlike legacy blur, liquid never assumes unknown hardware is fast.
  static final knownHighEnd = ValueNotifier<bool>(false);

  /// A measurement may lower the material without changing platform or
  /// persisted user choices. Raising it never bypasses any device veto.
  static final effectCeiling = ValueNotifier<HermesGlassTier>(
    HermesGlassTier.liquid,
  );

  /// What the last platform report decided, and why: `[glass] blur=on` or
  /// `[glass] blur=off (…)`, written to the log once per change.
  static String lastDecision = '[glass] blur=on (no report)';

  /// Rule 6: a mid or low range device gets the surface without blur until
  /// the measured cost says it can pay for it (REPORT-Q9-CHAT5, the frame
  /// cost with and without glass).
  static const bool blurNeedsHighEnd = true;

  /// A high-end device: one that declares an Android media performance
  /// class (S, 31, or later), or has this much memory.
  static const int highEndMemoryBytes = 7500 * 1024 * 1024;

  /// Whether a surface below [context] may blur now: the device allows it
  /// ([blurAllowed], [reducedPerformance]) and the person asked neither for
  /// less motion nor for more contrast (Android has no «reduce
  /// transparency» Flutter can read; high contrast stands for it). Listen
  /// to [changes] to follow it. One rule for every frosted surface: these
  /// and the header strips (Q9-CRISTAL, `HermesGlassStrip`).
  static bool blursIn(BuildContext context) =>
      effectCeiling.value != HermesGlassTier.chrome &&
      !MediaQuery.disableAnimationsOf(context) &&
      !MediaQuery.highContrastOf(context) &&
      !reducedPerformance.value &&
      blurAllowed.value;

  static HermesGlassTier tierIn(
    BuildContext context, {
    required bool shaderSupported,
  }) {
    if (!blursIn(context)) return HermesGlassTier.chrome;
    return effectCeiling.value == HermesGlassTier.liquid &&
            liquidGpuValidated.value &&
            knownHighEnd.value &&
            shaderSupported
        ? HermesGlassTier.liquid
        : HermesGlassTier.glass;
  }

  /// Fires when [blursIn] may have changed for the device.
  static final Listenable changes = Listenable.merge([
    reducedPerformance,
    blurAllowed,
    liquidGpuValidated,
    knownHighEnd,
    effectCeiling,
  ]);

  static const _channel = MethodChannel('hermes/platform_info');

  /// Re-reads the platform's performance class. Safe to call repeatedly;
  /// any platform failure keeps the current value.
  static Future<void> refresh() async {
    try {
      final info = await _channel.invokeMapMethod<String, Object?>(
        'getPerformanceClass',
      );
      if (info == null) return;
      apply(info);
    } on MissingPluginException {
      // No handler (tests, other platforms): keep the blur.
    } catch (error) {
      // The Android side failed: the blur stays as it was, and the log
      // says so, rather than a device frosting for no reason anyone sees.
      lastDecision = '[glass] blur=? (platform error: $error)';
      debugPrint(lastDecision);
    }
  }

  /// Applies what `getPerformanceClass` said. Keys a platform did not send
  /// keep the blur (an older build of the Android side sends only the
  /// first two).
  @visibleForTesting
  static void apply(Map<String, Object?> info) {
    final reduced =
        info['lowRamDevice'] == true || info['powerSaveMode'] == true;
    reducedPerformance.value = reduced;
    final switchedOff =
        info['windowBlursDisabled'] == true ||
        info['reduceTransparency'] == true;
    final highEnd = _highEnd(info);
    knownHighEnd.value =
        (info['mediaPerformanceClass'] is int ||
            info['totalMemoryBytes'] is int) &&
        highEnd;
    blurAllowed.value =
        !reduced && !switchedOff && (!blurNeedsHighEnd || highEnd);
    final decision = describe(info);
    if (decision != lastDecision) {
      lastDecision = decision;
      // One line in the log (logcat), so a device that shows the chrome of
      // before says why: `adb logcat | grep '\[glass\]'`.
      debugPrint(decision);
    }
  }

  static bool _highEnd(Map<String, Object?> info) {
    final mediaClass = info['mediaPerformanceClass'];
    final memory = info['totalMemoryBytes'];
    final known = mediaClass is int || memory is int;
    return !known ||
        (mediaClass is int && mediaClass >= 31) ||
        (memory is int && memory >= highEndMemoryBytes);
  }

  /// What [apply] decides for [info], and why, in one line.
  static String describe(Map<String, Object?> info) {
    final reasons = [
      if (info['lowRamDevice'] == true) 'low RAM',
      if (info['powerSaveMode'] == true) 'battery saver',
      if (info['windowBlursDisabled'] == true) 'window blurs switched off',
      if (info['reduceTransparency'] == true) 'reduce transparency',
      if (blurNeedsHighEnd && !_highEnd(info)) 'mid or low range',
    ];
    final facts =
        'crossWindowBlur=${info['crossWindowBlurEnabled']} '
        'mediaClass=${info['mediaPerformanceClass']} '
        'memory=${info['totalMemoryBytes']}';
    if (reasons.isEmpty) return '[glass] blur=on ($facts)';
    return '[glass] blur=off (${reasons.join(', ')}; $facts)';
  }
}

/// Where a frosted surface sits on screen (Q9-CHAT5, the owner's cost rule 2:
/// ONE blurring layer per zone). Of the mounted surfaces of a zone only the
/// one with the highest priority blurs; the others keep their translucent
/// veil and hairline. [none] never shares.
enum FrostedZone {
  none,

  /// The foot of the screen: the chat's composer and the live turn's
  /// pills, the dock.
  bottom,

  /// The top of the screen: a header's floating pieces, frosted as one
  /// strip (Q9-CRISTAL, `HermesGlassStrip`). Two headers on screen (the
  /// list beside a chat on the open Fold): the higher priority blurs.
  top,

  /// A modal frame, menu or popover. Nested overlays share one filter.
  overlay,
}

/// A surface of a [FrostedZone]: a [FrostedBackdrop], or a header's strip
/// that frosts several pieces with one blur (Q9-CRISTAL).
abstract interface class FrostedZoneMember {
  FrostedZone get frostedZone;

  /// Of the zone's visible members, the highest blurs.
  int get frostedZonePriority;

  /// Its route is on screen, not covered by another (its tickers on).
  bool get frostedZoneVisible;
}

/// A member can revoke a retained filter immediately when it loses a zone.
/// Widget rebuild notifications still wait until after the current build.
abstract interface class FrostedZoneFilterOwner {
  void frostedZoneLost();
}

/// Who blurs in each zone, for a member that is not a [FrostedBackdrop]:
/// it joins on mount, leaves on dispose, says when it is covered, and
/// listens to [revision] to learn whether it [owns] its zone.
abstract final class FrostedZones {
  static void join(FrostedZoneMember member) => _FrostedZones.join(member);

  static void leave(FrostedZoneMember member, FrostedZone zone) =>
      _FrostedZones.leave(member, zone);

  static void visibilityChanged() => _FrostedZones.visibilityChanged();

  /// Whether [member] is the one of its zone that blurs.
  static bool owns(FrostedZoneMember member) =>
      member.frostedZone == FrostedZone.none ||
      identical(_FrostedZones.ownerOf(member.frostedZone), member);

  /// Changes after the frame in which who blurs changed.
  static Listenable get revision => _FrostedZones.revision;
}

/// Who blurs in each zone. Changes are told after the frame, never while
/// one is being built.
abstract final class _FrostedZones {
  static final _members = <FrostedZone, List<FrostedZoneMember>>{};
  static final revision = ValueNotifier<int>(0);
  static bool _notifyScheduled = false;

  static void join(FrostedZoneMember member) {
    if (member.frostedZone == FrostedZone.none) return;
    _members.putIfAbsent(member.frostedZone, () => []).add(member);
    _changed();
  }

  static void leave(FrostedZoneMember member, FrostedZone zone) {
    if (zone == FrostedZone.none) return;
    _members[zone]?.remove(member);
    _changed();
  }

  /// The surface of [zone] that blurs: of the visible ones, the highest
  /// priority, the first mounted among equals. A surface on a route covered
  /// by another (its tickers off) never keeps the blur from the one on
  /// screen (REVIEW-Q9-CHAT5: a chat left under another chat's route).
  static FrostedZoneMember? ownerOf(FrostedZone zone) {
    FrostedZoneMember? owner;
    for (final member in _members[zone] ?? const <FrostedZoneMember>[]) {
      if (!member.frostedZoneVisible) continue;
      if (owner == null ||
          member.frostedZonePriority > owner.frostedZonePriority) {
        owner = member;
      }
    }
    return owner;
  }

  /// A member became visible or hidden.
  static void visibilityChanged() => _changed();

  static void _changed() {
    // An old retained layer must not keep filtering for the frame before
    // its widget receives revision. Revoke losers now; a new owner may
    // start in its own build, with at most one actual filter in the zone.
    for (final zone in _members.keys) {
      final owner = ownerOf(zone);
      for (final member in _members[zone]!) {
        if (identical(owner, member)) continue;
        if (member case FrostedZoneFilterOwner filterOwner) {
          filterOwner.frostedZoneLost();
        }
      }
    }
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.idle ||
        phase == SchedulerPhase.postFrameCallbacks) {
      revision.value += 1;
      return;
    }
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _notifyScheduled = false;
      revision.value += 1;
    });
  }
}

/// A rounded surface that frosts the content behind it.
///
/// [builder] paints the surface with the fill colour to use. At rest that is
/// [tint] over a blur of radius [sigma], clipped to [borderRadius] and
/// isolated in its own repaint boundary (rule 3: always, so a frame of the
/// list behind never repaints what sits on the surface, and the surface's
/// own changes never repaint the list).
///
/// The blur is dropped when it cannot be seen or must not be paid for:
///  * [sigma] is zero: the surface is painted as is (no clip, no layer);
///  * [tint] is opaque: nothing shows through, so a blur has no effect;
///  * reduced motion, high contrast or [FrostedBackdropPolicy.blurAllowed]
///    say so: the fill becomes [tint] over the app background, which is how
///    the surface looks at rest over the empty app canvas, so sharp rows
///    never show through a translucent surface. Android has no «reduce
///    transparency» switch Flutter can read; high contrast stands for it,
///    and the system's own blur switch reaches [FrostedBackdropPolicy];
///  * another surface of its [zone] blurs: this one keeps [tint] as is, a
///    translucent veil.
class FrostedBackdrop extends StatefulWidget {
  final double sigma;

  /// Non-null opts this existing API into the shared liquid band.
  /// Legacy glass keeps its widget contract until its owner migrates it.
  final HermesLiquid? liquid;

  /// OPUS-CRISTAL: with [liquid] set, the band's smoked tone instead of the
  /// liquid touch (HermesGlassStrip.tone): one blur, no shader, the opaque
  /// fallback where an ink of [toneInks] would not read. Null: as before.
  final HermesSmokedGlass? tone;

  /// Every ink the surface paints, checked on the tone.
  final List<Color> toneInks;
  final double? maxFilterArea;

  /// Null: the glass veil of everything that floats ([glassVeil]).
  final Color? tint;
  final BorderRadius borderRadius;
  final Widget Function(BuildContext context, Color fill)? builder;

  /// See [FrostedZone]. Zones share one blur.
  final FrostedZone zone;

  /// Which surface of the [zone] blurs: the highest.
  final int zonePriority;

  /// [FrostedBackdrop.glass]: what sits on the glass.
  final Widget? _glassChild;

  const FrostedBackdrop({
    required this.sigma,
    required this.tint,
    required this.borderRadius,
    required Widget Function(BuildContext context, Color fill) this.builder,
    this.zone = FrostedZone.none,
    this.zonePriority = 0,
    this.liquid,
    this.maxFilterArea,
    this.tone,
    this.toneInks = const <Color>[],
    super.key,
  }) : _glassChild = null;

  /// Glass of the floating chrome (Q9-CHAT5 v2: the live turn's pills, the
  /// composer; the dock can take it as is): the chrome's light veil
  /// ([glassVeil]) over a moderate blur ([glassSigma]), with the chrome's
  /// 1 dp hairline. Without blur (the fallbacks of the class) the veil is
  /// laid on the page and gains the chrome's soft shadow, so the surface
  /// still reads as floating (rule 4).
  const FrostedBackdrop.glass({
    required Widget child,
    required this.borderRadius,
    this.sigma = glassSigma,
    this.zone = FrostedZone.none,
    this.zonePriority = 0,
    this.liquid,
    this.maxFilterArea,
    this.tone,
    this.toneInks = const <Color>[],
    super.key,
  }) : tint = null,
       builder = null,
       _glassChild = child;

  /// Rule 1: a moderate blur (16-20); the light veil does the effect.
  static const double glassSigma = 16;

  /// How much of the chrome's opaque colour the glass veil lays over what
  /// is behind it. the owner's D2 (Q9-CRISTAL): 0.80 at the foot and at the
  /// top, «no tan transparente»; with the header strip's fade the pieces'
  /// ink reads at AA over any page in every theme.
  static const double glassVeilOpacity = HermesChrome.veilOpacity;

  /// The light veil of the glass for [colors].
  static Color glassVeil(HermesThemeColors colors) =>
      HermesChrome.of(colors).opaque.withValues(alpha: glassVeilOpacity);

  @override
  State<FrostedBackdrop> createState() => _FrostedBackdropState();
}

/// How a frosted surface is painted this frame.
enum _Frost { blur, veil, fallback, plain }

class _FrostedBackdropState extends State<FrostedBackdrop>
    implements FrostedZoneMember, FrostedZoneFilterOwner {
  /// Whether this surface is on screen: its route not covered by another.
  bool _visible = true;
  bool _active = true;
  RenderBackdropFilter? _legacyFilter;

  @override
  void frostedZoneLost() {
    _legacyFilter?.enabled = false;
  }

  @override
  FrostedZone get frostedZone => widget.zone;

  @override
  int get frostedZonePriority => widget.zonePriority;

  @override
  bool get frostedZoneVisible =>
      _active &&
      _visible &&
      widget.liquid == null &&
      widget.sigma > 0 &&
      (widget.tint?.a ?? FrostedBackdrop.glassVeilOpacity) < 1;

  /// What the frost depends on beyond the widget: the device policy and
  /// who owns the zone. Listened to here rather than through a
  /// `ListenableBuilder`, an `AnimatedWidget`: glass is still, and nothing
  /// that reads as an animation sits under it (ct1215; gint67).
  final Listenable _policy = Listenable.merge([
    FrostedBackdropPolicy.changes,
    _FrostedZones.revision,
  ]);

  void _policyChanged() {
    if (mounted && _active) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _FrostedZones.join(this);
    _policy.addListener(_policyChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = TickerMode.valuesOf(context).enabled;
    if (visible == _visible) return;
    _visible = visible;
    if (widget.zone != FrostedZone.none) _FrostedZones.visibilityChanged();
  }

  @override
  void didUpdateWidget(covariant FrostedBackdrop oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.zone != widget.zone ||
        oldWidget.zonePriority != widget.zonePriority ||
        oldWidget.liquid != widget.liquid) {
      frostedZoneLost();
      _FrostedZones.leave(this, oldWidget.zone);
      _FrostedZones.join(this);
    } else if (oldWidget.sigma != widget.sigma ||
        oldWidget.tint != widget.tint) {
      _FrostedZones.visibilityChanged();
    }
  }

  @override
  void deactivate() {
    _active = false;
    frostedZoneLost();
    _legacyFilter = null;
    if (widget.zone != FrostedZone.none) _FrostedZones.visibilityChanged();
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _active = true;
    if (widget.zone != FrostedZone.none) _FrostedZones.visibilityChanged();
  }

  @override
  void dispose() {
    _active = false;
    _legacyFilter = null;
    _policy.removeListener(_policyChanged);
    _FrostedZones.leave(this, widget.zone);
    super.dispose();
  }

  Widget _surface(BuildContext context, Color fill) {
    final glass = widget._glassChild;
    if (glass == null) return widget.builder!(context, fill);
    final chrome = HermesChrome.of(Theme.of(context).hermes);
    // One key whatever the frost: a key that changed with the policy would
    // remount what sits on the glass (and lose its state).
    return DecoratedBox(
      key: const ValueKey('frosted-glass'),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: widget.borderRadius,
        border: Border.all(color: chrome.line),
      ),
      child: glass,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final tint = widget.tint ?? FrostedBackdrop.glassVeil(colors);
    if (widget.liquid != null) {
      frostedZoneLost();
      _legacyFilter = null;
      final enabled = widget.sigma > 0 && tint.a < 1;
      return RepaintBoundary(
        key: const ValueKey('frosted-backdrop-boundary'),
        child: HermesGlassStrip(
          enabled: enabled,
          zone: widget.zone,
          priority: widget.zonePriority,
          blurSigma: widget.sigma,
          veil: tint,
          liquid: widget.tone == null ? widget.liquid : null,
          tone: widget.tone,
          toneInks: widget.toneInks,
          maxFilterArea: widget.maxFilterArea,
          child: Builder(
            builder: (context) {
              final glass = HermesGlassStrip.of(context);
              final fill = !enabled
                  ? tint
                  : glass == null
                  ? Color.alphaBlend(tint, colors.background)
                  : glass.veil;
              final piece = HermesGlassPiece(
                shape: RoundedRectangleBorder(
                  borderRadius: widget.borderRadius,
                ),
                child: ClipRRect(
                  borderRadius: widget.borderRadius,
                  child: _surface(context, fill),
                ),
              );
              if (widget._glassChild == null) return piece;
              return DecoratedBox(
                key: const ValueKey('frosted-glass-shadow'),
                decoration: BoxDecoration(
                  borderRadius: widget.borderRadius,
                  boxShadow: enabled && glass == null
                      ? HermesChrome.of(colors).shadow
                      : const [],
                ),
                child: piece,
              );
            },
          ),
        ),
      );
    }
    // Rule 3: in a boundary of its own even without blur.
    if (widget.sigma <= 0) {
      frostedZoneLost();
      _legacyFilter = null;
      return RepaintBoundary(
        key: const ValueKey('frosted-backdrop-boundary'),
        child: _surface(context, tint),
      );
    }
    final opaque = tint.a >= 1;
    final allowed = FrostedBackdropPolicy.blursIn(context);
    final shares =
        widget.zone != FrostedZone.none &&
        !identical(_FrostedZones.ownerOf(widget.zone), this);
    final frost = opaque
        ? _Frost.plain
        : !allowed
        ? _Frost.fallback
        : shares
        ? _Frost.veil
        : _Frost.blur;
    // Glass that shares its zone keeps the chrome's own translucent
    // fill (what floats has always worn without blur); a fallback is the
    // veil laid on the page, solid.
    final fill = switch (frost) {
      _Frost.fallback => Color.alphaBlend(tint, colors.background),
      _Frost.veil when widget.tint == null => HermesChrome.of(colors).fill,
      _ => tint,
    };
    // The same widgets whatever the policy says: `enabled` and an empty
    // shadow instead of removing them keep the subtree (and any state
    // below it) mounted when the policy flips.
    final clipped = ClipRRect(
      borderRadius: widget.borderRadius,
      child: BackdropFilter(
        enabled: frost == _Frost.blur,
        filter: ImageFilter.blur(sigmaX: widget.sigma, sigmaY: widget.sigma),
        child: Builder(
          builder: (context) {
            // Bind while this child is active. Revocation can happen while
            // another member is being unmounted; it must not query Elements.
            _legacyFilter = context
                .findAncestorRenderObjectOfType<RenderBackdropFilter>();
            return _surface(context, fill);
          },
        ),
      ),
    );
    return RepaintBoundary(
      key: const ValueKey('frosted-backdrop-boundary'),
      child: widget._glassChild == null
          ? clipped
          // Rule 4: without blur the glass keeps the chrome's soft
          // shadow, outside the clip; an empty one otherwise.
          : DecoratedBox(
              key: const ValueKey('frosted-glass-shadow'),
              decoration: BoxDecoration(
                borderRadius: widget.borderRadius,
                boxShadow: frost == _Frost.fallback
                    ? HermesChrome.of(colors).shadow
                    : const [],
              ),
              child: clipped,
            ),
    );
  }
}
