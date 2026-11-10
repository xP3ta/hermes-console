// Q9-CRISTAL (the owner, 29 Oct): the glass of the chat's composer at the top
// of every screen. A header's floating pieces (round buttons, the title
// pill, the actions pill, a chat's island and its pinned chip) let the page
// that scrolls behind them show through, frosted, under a soft fade of the
// page colour: denser at the top edge and over the status bar, lighter
// towards the pieces' foot, never a solid band.
//
// Cost (the owner's rules, REPORT-Q9-CHAT5): ONE blur per strip, whatever the
// number of pieces. The strip paints a single backdrop filter clipped to
// the union of its pieces' outlines; each piece only paints its veil and
// its hairline. The strip is a repaint boundary of its own: the list behind
// never repaints it, and a piece that moves or grows (the island, the
// pinned chip) repaints only the strip.
//
// A strip with `band` also holds a HermesGlassPiece.band: a screen's header
// is then a band of glass like the dock's, and the same one blur fills the
// whole measured band, not only the pieces (see HermesAppBar).
//
// Without blur (FrostedBackdropPolicy: a mid or low range device, battery
// saver, the system's blur switch; reduced motion; high contrast) the
// pieces and the fade are the ones of before, so sharp text never passes
// under a veil that does not frost it. When another strip of
// FrostedZone.top blurs (the owner's rule 2: one blur per zone: two headers on
// screen, the list's beside the chat's on the open Fold, or a page and the
// one being pushed over it) a strip keeps the glass's veil and fade and
// only drops its blur, so a route transition never flips a header between
// glass and chrome (REVIEW-Q9-CRISTAL C2). The pieces' ink reads at AA
// over that veil on a page of any colour.
import 'dart:async';
import 'dart:ui' show FragmentProgram, FragmentShader, ImageFilter;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import '../theme/app_theme.dart';
import '../theme/theme_contrast.dart';
import '../widgets/frosted_backdrop.dart';
import 'liquid_glass.dart';
import 'scrim_holes.dart';
import 'smoked_glass.dart';
import 'tokens.dart';

/// What a piece inside a frosting strip wears: the composer's veil.
@immutable
class HermesGlass {
  const HermesGlass({required this.veil, this.blurs = true, this.tone});

  /// [FrostedBackdrop.glassVeil]: the chrome's opaque colour at
  /// [FrostedBackdrop.glassVeilOpacity].
  final Color veil;

  final bool blurs;

  /// OPUS-CRISTAL: the smoked glass under the piece, when its strip is
  /// toned and frosting; a piece that adjusts an ink to what is under it
  /// (the context pill's status inks) measures with it.
  final HermesSmokedGlass? tone;

  @override
  bool operator ==(Object other) =>
      other is HermesGlass &&
      other.veil == veil &&
      other.blurs == blurs &&
      other.tone == tone;

  @override
  int get hashCode => Object.hash(veil, blurs, tone);
}

/// The band at the top of a screen that holds its floating pieces, frosted
/// as one (see the file's comment).
///
/// A piece joins it by wrapping its visible outline in a
/// [HermesGlassPiece], and paints its fill with [HermesGlassStrip.of]'s
/// veil while the strip frosts (the chrome of before otherwise).
///
/// Between the strip and its pieces there must be no other repaint
/// boundary: a piece moved by a layout the strip did not see is caught when
/// it paints, a frame late.
class HermesGlassStrip extends StatefulWidget {
  const HermesGlassStrip({
    required this.child,
    this.enabled = true,
    this.priority = 0,
    this.liquid,
    this.zone = FrostedZone.top,
    this.blurSigma = sigma,
    this.veil,
    this.weakInk,
    this.maxFilterArea,
    this.shaderEnabled = true,
    this.backdropFade = 0,
    this.tone,
    this.toneInks = const <Color>[],
    this.scrimHoles,
    this.band = false,
    super.key,
  }) : assert(tone == null || liquid == null);

  final Widget child;

  /// OPUS-CRISTAL: the smoked glass of the chat's foot. A toned strip has
  /// one look: its tone over the zone's one blur, where it owns the blur
  /// and every ink in [toneInks] reads on it ([HermesSmokedGlass.readsFor]);
  /// otherwise its pieces keep the opaque chrome of before. Never a veil
  /// without blur, never the shader. Null: the strip as before.
  final HermesSmokedGlass? tone;

  /// Every ink the pieces of a toned strip paint as text. Empty: the
  /// pieces keep the opaque chrome (nothing was checked).
  final List<Color> toneInks;

  /// OPUS-CRISTAL: where a toned strip that frosts tells the page's foot
  /// scrim (HermesBottomScrim.holes) to leave its still pieces alone, so
  /// the blur takes the real content under them. Null: as before.
  final HermesScrimHoles? scrimHoles;

  /// True when the strip holds a [HermesGlassPiece.band]: the one blur then
  /// covers the whole band, not only the pieces. The liquid shader draws
  /// nothing outside its shapes, so a banded strip keeps the plain glass:
  /// the band is what must be frosted.
  final bool band;

  final FrostedZone zone;
  final double blurSigma;
  final Color? veil;

  /// Weakest content actually painted on this band. Null includes the
  /// title badge; an icon-only band may specify its own foreground ink.
  final Color? weakInk;
  final double? maxFilterArea;
  final bool shaderEnabled;

  /// Guaranteed page fade behind every piece; zero on free-standing glass.
  final double backdropFade;

  /// The liquid touch of the strip's one layer
  /// ([HermesLiquid]), where the engine can run it (Impeller) and the strip
  /// blurs; the pieces then leave their veil to the shader. Null: the glass.
  final HermesLiquid? liquid;

  /// False: the pieces keep the chrome of before (a header nothing scrolls
  /// under has nothing to frost).
  final bool enabled;

  /// Of the strips on screen ([FrostedZone.top]) the highest blurs; the
  /// others keep the glass's veil and fade without blur. A chat's header
  /// outranks a list's.
  final int priority;

  /// The composer's blur (the owner: the reference is the composer).
  static const double sigma = FrostedBackdrop.glassSigma;

  /// The fade runs this far below the header.
  static const double fadeTail = 20;

  /// The fade's page colour at the top edge, at the foot of the status bar
  /// and at the header's foot; it is gone [fadeTail] below it. Over the
  /// pieces it adds to their veil: with it, their ink reads at AA over any
  /// page (test/glass_strip_test.dart).
  static const double fadeTop = 0.92;
  static const double fadeStatus = 0.82;
  static const double fadeEdge = 0.42;

  /// The glass the pieces below [context] wear; null without a strip, or
  /// with one the policy or its page keeps from frosting (the chrome of
  /// before). A strip that only lost [FrostedZone.top] to another keeps
  /// its glass, without blur.
  static HermesGlass? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_GlassScope>()?.glass;

  /// Whether [context] is inside a strip, frosting or not.
  static bool contains(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_GlassScope>() != null;

  /// OPUS-CRISTAL: whether the nearest strip around [context] is toned
  /// (the chat's foot). Fixed by where the widget sits, not by the policy.
  static bool tonedAround(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_GlassScope>()?.toned ?? false;

  /// The glass of the toned strip around [context], or null. The foot's
  /// pieces never take a veil from a header's or an overlay's strip.
  static HermesGlass? toneOf(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<_GlassScope>();
    return scope != null && scope.toned ? scope.glass : null;
  }

  /// Checks the material actually painted, rather than the requested role.
  @visibleForTesting
  static bool debugShaderActive(BuildContext context) =>
      context
          .getInheritedWidgetOfExactType<_GlassScope>()
          ?.handle
          .render
          ?._lastUsedShader ??
      false;

  /// The soft fade behind a strip's pieces, for a header of [extent] whose
  /// top [statusInset] is the status bar; paint it [fadeTail] taller.
  static LinearGradient fade({
    required Color page,
    required double statusInset,
    required double extent,
  }) {
    final total = extent + fadeTail;
    double at(double y) => total <= 0 ? 0 : (y / total).clamp(0.0, 1.0);
    return LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        page.withValues(alpha: fadeTop),
        page.withValues(alpha: fadeStatus),
        page.withValues(alpha: fadeEdge),
        page.withValues(alpha: 0),
      ],
      stops: [0, at(statusInset), at(extent), 1],
    );
  }

  /// The darkest (light theme) or lightest (dark theme) colour a piece's
  /// content can sit on while the strip frosts: the veil over the fade
  /// over a white page behind a dark theme, a black one behind a light
  /// theme. The fade is at its lightest, [fadeEdge]: no piece reaches below
  /// the header's foot. What sits on a piece reads at AA against this, and
  /// against the chrome of before ([HermesChrome.opaque]).
  static Color worstUnder(HermesThemeColors colors) {
    final chrome = HermesChrome.of(colors);
    final page = chrome.dark ? Colors.white : Colors.black;
    final faded = ThemeContrast.composite(
      colors.background.withValues(alpha: fadeEdge),
      page,
    );
    return ThemeContrast.composite(FrostedBackdrop.glassVeil(colors), faded);
  }

  /// The veil over the theme's own page: the other end of what a piece's
  /// content sits on while the strip frosts.
  static Color ownUnder(HermesThemeColors colors) => ThemeContrast.composite(
    FrostedBackdrop.glassVeil(colors),
    colors.background,
  );

  /// How much page colour [fade] lays at [y].
  static double fadeAt(
    double y, {
    required double statusInset,
    required double extent,
  }) {
    if (y <= 0) return fadeTop;
    if (y <= statusInset) {
      return fadeTop + (fadeStatus - fadeTop) * (y / statusInset);
    }
    if (y <= extent) {
      final span = extent - statusInset;
      final t = span <= 0 ? 1.0 : (y - statusInset) / span;
      return fadeStatus + (fadeEdge - fadeStatus) * t;
    }
    if (y >= extent + fadeTail) return 0;
    return fadeEdge * (1 - (y - extent) / fadeTail);
  }

  @override
  State<HermesGlassStrip> createState() => _HermesGlassStripState();
}

/// A moving ancestor (dock dismissal, modal drag) suspends the shader
/// while retaining the safe glass veil. Route motion is handled by the
/// strip itself. This scope never owns activity or an animation controller.
/// The veto accumulates: a locally still child cannot clear ancestor motion.
class HermesLiquidMotion extends StatelessWidget {
  const HermesLiquidMotion({
    required this.moving,
    required this.child,
    super.key,
  });

  final bool moving;
  final Widget child;

  static bool of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_LiquidMotionScope>()
          ?.moving ??
      false;

  @override
  Widget build(BuildContext context) {
    // Always depend on the ancestor, even while this scope itself moves.
    // Its later changes must reach retained children when the local veto ends.
    final ancestorMoving = of(context);
    return _LiquidMotionScope(moving: ancestorMoving || moving, child: child);
  }
}

class _LiquidMotionScope extends InheritedWidget {
  const _LiquidMotionScope({required this.moving, required super.child});

  final bool moving;

  @override
  bool updateShouldNotify(_LiquidMotionScope oldWidget) =>
      moving != oldWidget.moving;
}

/// A single free-standing piece using the same band, policy and shader.
/// The builder must use [Color] for its fill. Explicitly opaque fills and
/// zero sigma preserve the caller's choice and never register a blur.
class HermesLiquidSurface extends StatelessWidget {
  const HermesLiquidSurface({
    required this.builder,
    this.shape = const StadiumBorder(),
    this.liquid = HermesLiquid.overlay,
    this.tint,
    this.fallbackFill,
    this.sigma = HermesGlassStrip.sigma,
    this.enabled = true,
    this.zone = FrostedZone.overlay,
    this.priority = 0,
    this.maxFilterArea,
    this.shaderEnabled = true,
    super.key,
  });

  final Widget Function(BuildContext context, Color fill) builder;
  final OutlinedBorder shape;
  final HermesLiquid liquid;
  final Color? tint;
  final Color? fallbackFill;
  final double sigma;
  final bool enabled;
  final FrostedZone zone;
  final int priority;
  final double? maxFilterArea;
  final bool shaderEnabled;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final veil = tint ?? FrostedBackdrop.glassVeil(colors);
    final frosts = enabled && sigma > 0 && veil.a < 1;
    return HermesGlassStrip(
      enabled: frosts,
      zone: zone,
      priority: priority,
      blurSigma: sigma,
      veil: veil,
      liquid: liquid,
      maxFilterArea: maxFilterArea,
      shaderEnabled: shaderEnabled,
      child: Builder(
        builder: (context) => HermesGlassPiece(
          shape: shape,
          child: builder(
            context,
            HermesGlassStrip.of(context)?.veil ??
                (frosts
                    ? fallbackFill ?? Color.alphaBlend(veil, colors.background)
                    : fallbackFill ?? veil),
          ),
        ),
      ),
    );
  }
}

/// A free-standing panel that carries a lot of text (the side drawer) over
/// real glass: the zone's one blur, the smoked tone of
/// [HermesSmokedGlass.panelOf] under a heavy veil, certified against the
/// theme's text inks ([HermesSmokedGlass.panelInks]) and against [overs],
/// the tints its rows lay under their ink (a selected row).
///
/// [builder] paints its fill with the colour it is handed: the veil while
/// the glass frosts; [fallbackFill] (the opaque material of before) when the
/// device policy, reduced motion, high contrast or a palette that does not
/// read keep it from frosting. Never a shadow under the veil.
class HermesGlassPanel extends StatelessWidget {
  const HermesGlassPanel({
    required this.shape,
    required this.fallbackFill,
    required this.builder,
    this.overs = const <(Color ink, Color tint)>[],
    this.zone = FrostedZone.overlay,
    this.sigma = HermesGlassStrip.sigma,
    super.key,
  });

  final OutlinedBorder shape;
  final Color fallbackFill;
  final Widget Function(BuildContext context, Color fill, bool glass) builder;

  /// Inks that sit on a tint over the panel, with that tint.
  final List<(Color ink, Color tint)> overs;
  final FrostedZone zone;
  final double sigma;

  /// Whether the panel's glass reads for [colors] with [overs]: false is the
  /// opaque fallback, for that theme.
  static bool reads(
    HermesThemeColors colors, {
    List<(Color ink, Color tint)> overs = const <(Color ink, Color tint)>[],
  }) {
    final chrome = HermesChrome.of(colors);
    final tone = HermesSmokedGlass.panelOf(chrome);
    if (!tone.readsFor(colors, HermesSmokedGlass.panelInks(colors))) {
      return false;
    }
    for (final (ink, tint) in overs) {
      if (!tone.readsOver(ink, tint, chrome)) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final tone = HermesSmokedGlass.panelOf(HermesChrome.of(colors));
    return HermesGlassStrip(
      zone: zone,
      blurSigma: sigma,
      tone: tone,
      toneInks: reads(colors, overs: overs)
          ? HermesSmokedGlass.panelInks(colors)
          : const <Color>[],
      child: Builder(
        builder: (context) {
          final veil = HermesGlassStrip.toneOf(context)?.veil;
          return HermesGlassPiece(
            shape: shape,
            child: builder(context, veil ?? fallbackFill, veil != null),
          );
        },
      ),
    );
  }
}

class _HermesGlassStripState extends State<HermesGlassStrip>
    implements FrostedZoneMember, FrostedZoneFilterOwner {
  final _StripHandle _handle = _StripHandle();

  @override
  void frostedZoneLost() {
    _handle.render?.blur = false;
  }

  /// Whether this strip is on screen: its route not covered by another.
  bool _visible = true;
  bool _active = true;
  Animation<double>? _routeAnimation;
  Animation<double>? _secondaryAnimation;

  /// The device policy and who owns the zone. Listened to here, not through
  /// a `ListenableBuilder` (an `AnimatedWidget`): glass is still, and
  /// nothing that reads as an animation sits under it (gint67).
  final Listenable _changes = Listenable.merge([
    FrostedBackdropPolicy.changes,
    FrostedZones.revision,
  ]);

  @override
  FrostedZone get frostedZone => widget.zone;

  @override
  int get frostedZonePriority => widget.priority;

  /// A strip that is off never keeps the blur from one that is on.
  @override
  bool get frostedZoneVisible =>
      _active && _visible && widget.enabled && widget.blurSigma > 0;

  void _changed() {
    if (mounted && _active) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    FrostedZones.join(this);
    _changes.addListener(_changed);
  }

  /// The liquid shader loads once for the app; the strip shows the glass
  /// until it is there.
  bool _loadPending = false;

  void _loadLiquid() {
    if (_loadPending || HermesLiquidShader.program != null) return;
    _loadPending = true;
    unawaited(
      HermesLiquidShader.load().then((program) {
        if (mounted && _active && program != null) setState(() {});
      }),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (!identical(route?.animation, _routeAnimation) ||
        !identical(route?.secondaryAnimation, _secondaryAnimation)) {
      _routeAnimation?.removeStatusListener(_routeChanged);
      _secondaryAnimation?.removeStatusListener(_routeChanged);
      _routeAnimation = route?.animation;
      _secondaryAnimation = route?.secondaryAnimation;
      _routeAnimation?.addStatusListener(_routeChanged);
      _secondaryAnimation?.addStatusListener(_routeChanged);
    }
    final visible = TickerMode.valuesOf(context).enabled;
    if (visible == _visible) return;
    _visible = visible;
    FrostedZones.visibilityChanged();
  }

  void _routeChanged(AnimationStatus _) => _changed();

  bool get _routeSettled =>
      (_routeAnimation == null ||
          _routeAnimation!.status == AnimationStatus.completed) &&
      (_secondaryAnimation == null ||
          _secondaryAnimation!.status == AnimationStatus.dismissed);

  @override
  void didUpdateWidget(covariant HermesGlassStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.priority != widget.priority ||
        oldWidget.zone != widget.zone) {
      frostedZoneLost();
      FrostedZones.leave(this, oldWidget.zone);
      FrostedZones.join(this);
    } else if (oldWidget.enabled != widget.enabled ||
        oldWidget.blurSigma != widget.blurSigma) {
      FrostedZones.visibilityChanged();
    }
  }

  @override
  void deactivate() {
    _active = false;
    frostedZoneLost();
    if (widget.zone != FrostedZone.none) FrostedZones.visibilityChanged();
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _active = true;
    if (widget.zone != FrostedZone.none) FrostedZones.visibilityChanged();
  }

  @override
  void dispose() {
    _active = false;
    _changes.removeListener(_changed);
    _routeAnimation?.removeStatusListener(_routeChanged);
    _secondaryAnimation?.removeStatusListener(_routeChanged);
    FrostedZones.leave(this, widget.zone);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tier = FrostedBackdropPolicy.tierIn(
      context,
      shaderSupported: HermesLiquidShader.supported,
    );
    final glass = widget.enabled && tier != HermesGlassTier.chrome;
    // Only the zone's owner blurs; the others keep the glass's look (C2).
    final ownsBlur = glass && widget.blurSigma > 0 && FrostedZones.owns(this);
    final colors = Theme.of(context).hermes;
    final veil = widget.veil ?? FrostedBackdrop.glassVeil(colors);
    final chrome = HermesChrome.of(colors);
    final weakInk = widget.weakInk ?? HermesLiquid.weakestInk(colors);
    final safeVeil =
        widget.liquid?.fallbackVeil(
          veil,
          ink: chrome.ink,
          weakInk: weakInk,
          backdropTint: colors.background.withValues(
            alpha: widget.backdropFade,
          ),
        ) ??
        veil;
    final tone = widget.tone;
    final toneReads =
        tone != null &&
        ownsBlur &&
        widget.toneInks.isNotEmpty &&
        tone.readsFor(colors, widget.toneInks);
    final program = HermesLiquidShader.program;
    // Q9-LIQUID: only on the strip that blurs, with the shader at hand.
    final shaderAllowed =
        tone == null &&
        !widget.band &&
        ownsBlur &&
        widget.shaderEnabled &&
        tier == HermesGlassTier.liquid &&
        _routeSettled &&
        !HermesLiquidMotion.of(context) &&
        widget.liquid != null;
    final liquid = shaderAllowed && program != null
        ? widget.veil == null
              ? widget.liquid
              : widget.liquid!.withVeilFloor(veil.a)
        : null;
    final blur = tone != null
        ? toneReads
        : ownsBlur && (liquid != null || safeVeil.a < 1);
    return _GlassScope(
      handle: _handle,
      toned: tone != null,
      glass: tone != null
          ? toneReads
                ? HermesGlass(veil: tone.veilOf(chrome), tone: tone)
                : null
          : glass
          ? HermesGlass(
              veil: liquid == null ? safeVeil : Colors.transparent,
              blurs: blur,
            )
          : null,
      child: _GlassStripLayer(
        handle: _handle,
        blur: blur,
        tone: toneReads ? tone : null,
        scrimHoles: widget.scrimHoles,
        onShaderNeeded: shaderAllowed && program == null ? _loadLiquid : null,
        blurSigma: widget.blurSigma,
        touch:
            glass &&
                FrostedBackdropPolicy.effectCeiling.value ==
                    HermesGlassTier.liquid
            ? widget.liquid
            : null,
        maxFilterArea: widget.maxFilterArea,
        // A toned strip that loses its zone backs its pieces with this in
        // the same paint (see _RenderGlassStrip.paint).
        opaque: toneReads
            ? chrome.opaque
            : Color.alphaBlend(veil, colors.background),
        liquid: liquid == null ? null : (liquid, program!),
        veil: safeVeil,
        ink: HermesChrome.of(colors).ink,
        weakInk: liquid == null ? Colors.transparent : weakInk,
        devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
        child: widget.child,
      ),
    );
  }
}

class _GlassScope extends InheritedWidget {
  const _GlassScope({
    required this.handle,
    required this.glass,
    required this.toned,
    required super.child,
  });

  final _StripHandle handle;
  final HermesGlass? glass;
  final bool toned;

  @override
  bool updateShouldNotify(_GlassScope oldWidget) =>
      glass != oldWidget.glass ||
      toned != oldWidget.toned ||
      !identical(handle, oldWidget.handle);
}

/// Where a strip's pieces find its render object.
class _StripHandle {
  _RenderGlassStrip? render;
}

class _GlassStripLayer extends SingleChildRenderObjectWidget {
  const _GlassStripLayer({
    required this.handle,
    required this.blur,
    required this.tone,
    required this.scrimHoles,
    required this.onShaderNeeded,
    required this.blurSigma,
    required this.touch,
    required this.maxFilterArea,
    required this.opaque,
    required this.liquid,
    required this.veil,
    required this.ink,
    required this.weakInk,
    required this.devicePixelRatio,
    required super.child,
  });

  final _StripHandle handle;
  final bool blur;
  final HermesSmokedGlass? tone;
  final HermesScrimHoles? scrimHoles;
  final VoidCallback? onShaderNeeded;
  final double blurSigma;
  final HermesLiquid? touch;
  final double? maxFilterArea;
  final Color opaque;
  final (HermesLiquid, FragmentProgram)? liquid;
  final Color veil;
  final Color ink;
  final Color weakInk;
  final double devicePixelRatio;

  @override
  _RenderGlassStrip createRenderObject(BuildContext context) {
    final render = _RenderGlassStrip(blur: blur)
      ..tone = tone
      ..scrimHoles = scrimHoles
      ..onShaderNeeded = onShaderNeeded
      ..blurSigma = blurSigma
      ..touch = touch
      ..maxFilterArea = maxFilterArea
      ..opaque = opaque
      ..liquid = liquid
      ..veil = veil
      ..ink = ink
      ..weakInk = weakInk
      ..devicePixelRatio = devicePixelRatio;
    handle.render = render;
    return render;
  }

  @override
  void updateRenderObject(BuildContext context, _RenderGlassStrip render) {
    handle.render = render;
    render
      ..blur = blur
      ..tone = tone
      ..scrimHoles = scrimHoles
      ..onShaderNeeded = onShaderNeeded
      ..blurSigma = blurSigma
      ..touch = touch
      ..maxFilterArea = maxFilterArea
      ..opaque = opaque
      ..liquid = liquid
      ..veil = veil
      ..ink = ink
      ..weakInk = weakInk
      ..devicePixelRatio = devicePixelRatio;
  }

  @override
  void didUnmountRenderObject(_RenderGlassStrip render) {
    if (identical(handle.render, render)) handle.render = null;
  }
}

class _RenderGlassStrip extends RenderProxyBox
    implements HermesScrimHoleSource {
  _RenderGlassStrip({required this._blur});

  VoidCallback? onShaderNeeded;
  bool _shaderRequestScheduled = false;
  bool _lastUsedShader = false;

  void _requestShader() {
    if (_shaderRequestScheduled || onShaderNeeded == null) return;
    _shaderRequestScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _shaderRequestScheduled = false;
      if (attached) onShaderNeeded?.call();
    });
  }

  /// OPUS-CRISTAL: the foot scrim's holes this strip publishes, or null.
  HermesScrimHoles? _scrimHoles;
  set scrimHoles(HermesScrimHoles? value) {
    if (identical(value, _scrimHoles)) return;
    _scrimHoles?.clear();
    _scrimHoles = value;
    _holeCandidate = null;
    markNeedsPaint();
  }

  /// The holes' bounds seen at the last paint: holes open only for pieces
  /// that stayed put for a frame, so a hole never strays into a gap.
  List<Rect>? _holeCandidate;

  /// After the frame (a paint cannot notify the scrim): publish [paths], if
  /// this strip still owns [holes].
  void _publishHoles(HermesScrimHoles holes, List<Path> paths) {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (attached && identical(_scrimHoles, holes)) {
        holes.publish(paths, source: this);
      }
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  void _updateScrimHoles() {
    final holes = _scrimHoles;
    if (holes == null) return;
    // Only while the toned glass frosts; any veto or a lost zone closes them.
    if (!_blur || _tone == null) {
      _holeCandidate = null;
      if (!holes.isEmpty) _publishHoles(holes, const <Path>[]);
      return;
    }
    final paths = _holePaths();
    final bounds = [for (final path in paths) path.getBounds()];
    if (listEquals(bounds, holes.bounds)) {
      _holeCandidate = bounds;
      return;
    }
    final still = _holeCandidate != null && listEquals(bounds, _holeCandidate);
    _holeCandidate = bounds;
    if (still) {
      _publishHoles(holes, paths);
    } else {
      // Moving, or seen for the first time: the whole scrim until they stay.
      if (!holes.isEmpty) _publishHoles(holes, const <Path>[]);
      repaintSoon();
    }
  }

  /// The holes of the pieces this strip holds, from the current layout.
  List<Path> _holePaths() => [
    for (final piece in _pieces)
      if (piece.attached &&
          piece.hasSize &&
          !piece.size.isEmpty &&
          !piece.band &&
          holds(piece))
        piece._shape
            .getOuterPath(
              (Offset.zero & piece.size).deflate(HermesScrimHoles.inset),
              textDirection: piece._textDirection,
            )
            .transform(piece.getTransformTo(null).storage),
  ];

  /// Asked in the scrim's paint: none unless this toned strip frosts now.
  @override
  List<Path>? scrimHolesNow() =>
      attached && _blur && _tone != null ? _holePaths() : null;

  @override
  RenderObject? get scrimHolePass => hermesPaintPass(this);

  @override
  void detach() {
    _holeCandidate = null;
    _scrimHoles?.clear();
    super.detach();
  }

  /// OPUS-CRISTAL: toned after the blur, in the same layer, or null.
  HermesSmokedGlass? _tone;
  set tone(HermesSmokedGlass? value) {
    if (_tone == value) return;
    _tone = value;
    markNeedsPaint();
  }

  double _blurSigma = HermesGlassStrip.sigma;
  set blurSigma(double value) {
    if (_blurSigma == value) return;
    _blurSigma = value;
    markNeedsPaint();
  }

  HermesLiquid? _touch;
  set touch(HermesLiquid? value) {
    if (_touch == value) return;
    _touch = value;
    markNeedsPaint();
  }

  double? _maxFilterArea;
  set maxFilterArea(double? value) {
    if (_maxFilterArea == value) return;
    _maxFilterArea = value;
    markNeedsPaint();
  }

  Color _opaque = Colors.transparent;
  set opaque(Color value) {
    if (_opaque == value) return;
    _opaque = value;
    markNeedsPaint();
  }

  bool _blur;
  bool get blur => _blur;
  set blur(bool value) {
    if (value == _blur) return;
    _blur = value;
    markNeedsCompositingBitsUpdate();
    markNeedsPaint();
  }

  /// Q9-LIQUID: the touch and its program, or null (the glass).
  (HermesLiquid, FragmentProgram)? _liquid;
  set liquid((HermesLiquid, FragmentProgram)? value) {
    if (value == _liquid) return;
    // The shader lives as long as this render object. Retained layers can
    // still refer to it while a policy change is being composited.
    _liquid = value;
    markNeedsPaint();
  }

  FragmentShader? _shader;
  bool _shaderFailed = false;

  Color _veil = Colors.transparent;
  set veil(Color value) {
    if (value == _veil) return;
    _veil = value;
    if (_liquid != null) markNeedsPaint();
  }

  Color _ink = Colors.transparent;
  set ink(Color value) {
    if (value == _ink) return;
    _ink = value;
    if (_liquid != null) markNeedsPaint();
  }

  Color _weakInk = Colors.transparent;
  set weakInk(Color value) {
    if (value == _weakInk) return;
    _weakInk = value;
    if (_liquid != null) markNeedsPaint();
  }

  double _devicePixelRatio = 1;
  set devicePixelRatio(double value) {
    if (value == _devicePixelRatio) return;
    _devicePixelRatio = value;
    if (_liquid != null) markNeedsPaint();
  }

  /// The pieces, in the order they joined.
  final Set<_RenderGlassPiece> _pieces = {};

  /// Where each piece was when the strip last painted.
  final Map<_RenderGlassPiece, Matrix4> _painted = {};

  final LayerHandle<ClipPathLayer> _clip = LayerHandle<ClipPathLayer>();
  final LayerHandle<BackdropFilterLayer> _filter =
      LayerHandle<BackdropFilterLayer>();
  bool _repaintScheduled = false;

  void add(_RenderGlassPiece piece) {
    if (_pieces.add(piece)) markNeedsPaint();
  }

  void remove(_RenderGlassPiece piece) {
    if (!_pieces.remove(piece)) return;
    _painted.remove(piece);
    if (attached) markNeedsPaint();
  }

  /// A piece changed its outline.
  void changed() {
    if (attached && (_blur || _touch != null || _maxFilterArea != null)) {
      markNeedsPaint();
    }
  }

  /// Whether [piece] is below this strip in the render tree (a piece moved
  /// elsewhere by a global key never measures against it).
  bool holds(RenderObject piece) {
    for (var node = piece.parent; node != null; node = node.parent) {
      if (identical(node, this)) return true;
    }
    return false;
  }

  /// A piece moved by a layout the strip did not see: paint again next
  /// frame (a paint cannot ask for another paint).
  void repaintSoon() {
    if (_repaintScheduled) return;
    _repaintScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _repaintScheduled = false;
      if (attached) markNeedsPaint();
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  @override
  bool get isRepaintBoundary => true;

  @override
  bool get alwaysNeedsCompositing => _blur;

  @override
  void paint(PaintingContext context, Offset offset) {
    _painted.clear();
    Path? outline;
    Path? bands;
    if (_blur || _tone != null || _touch != null || _maxFilterArea != null) {
      for (final piece in _pieces) {
        if (!piece.attached || !piece.hasSize || piece.size.isEmpty) continue;
        if (!holds(piece)) continue;
        final transform = piece.getTransformTo(this);
        _painted[piece] = transform;
        final target = piece.band ? (bands ??= Path()) : (outline ??= Path());
        target.addPath(
          piece.outline(),
          Offset.zero,
          matrix4: transform.storage,
        );
      }
    }
    // What the one blur fills: the pieces and, in a banded strip, the band.
    final frosted = bands == null
        ? outline
        : outline == null
        ? bands
        : (Path()
            ..addPath(outline, Offset.zero)
            ..addPath(bands, Offset.zero));
    final bounds = outline?.getBounds();
    final tooLarge =
        bounds != null &&
        _maxFilterArea != null &&
        bounds.width * bounds.height > _maxFilterArea!;
    var shaderPainted = false;
    if (frosted == null || !_blur || tooLarge) {
      _clip.layer = null;
      _filter.layer = null;
    } else {
      final filter = _filter.layer ??= BackdropFilterLayer();
      final blur =
          _tone?.filter(_blurSigma) ??
          ImageFilter.blur(sigmaX: _blurSigma, sigmaY: _blurSigma);
      if (onShaderNeeded != null && _shaderShapes() != null) _requestShader();
      final liquidFilter = _liquidAfter(blur);
      shaderPainted = liquidFilter != null;
      filter.filter = liquidFilter ?? blur;
      // ONE blur for every piece, clipped to their outlines; what the strip
      // holds paints over it. Liquid: the shader draws the (joined) shape
      // itself, so the clip is a rectangle that holds the fusion's bridges.
      final clip = shaderPainted && outline != null
          ? _liquidClip(outline)
          : frosted;
      _clip.layer = context.pushClipPath(
        needsCompositing,
        offset,
        clip.getBounds(),
        clip,
        (context, offset) => context.pushLayer(filter, (_, _) {}, offset),
        oldLayer: _clip.layer,
      );
    }
    // The scope hands the veil to the shader only while it is eligible.
    // Unsupported geometry, too many pieces or a shader failure must
    // still paint the veil. Large modal frames use an opaque backing.
    if (outline != null && (tooLarge || (_liquid != null && !shaderPainted))) {
      context.canvas.drawPath(
        outline.shift(offset),
        Paint()..color = tooLarge ? _opaque : _veil,
      );
    }
    // OPUS-CRISTAL (Git R1, OPUS-WIRING-ZONE-FIRST-PAINT-1): a toned strip
    // that loses its zone drops its blur at once (frostedZoneLost), but its
    // pieces still wear the veil until the scope rebuilds after the frame.
    // In this same paint, back them with the opaque chrome: the veil is that
    // colour, so the pieces read as the opaque chrome, never as a bare veil
    // over sharp content. Untoned strips keep their veil without blur (C2).
    if (outline != null && _tone != null && !_blur) {
      context.canvas.drawPath(outline.shift(offset), Paint()..color = _opaque);
    }
    _lastUsedShader = shaderPainted;
    _updateScrimHoles();
    super.paint(context, offset);
    if (!shaderPainted && _touch != null && outline != null) {
      _touch!.paintRim(
        context.canvas,
        outline.shift(offset),
        bounds!.shift(offset),
      );
    }
  }

  /// Q9-LIQUID: the shader after [blur], in the same layer, told where the
  /// pieces are on screen (physical pixels: the shader's space).
  ImageFilter? _liquidAfter(ImageFilter blur) {
    final liquid = _liquid;
    if (liquid == null ||
        _shaderFailed ||
        _painted.keys.any((piece) => piece.band) ||
        _painted.length > HermesLiquid.maxPieces) {
      return null;
    }
    final (touch, program) = liquid;
    final shapes = _shaderShapes();
    if (shapes == null) return null;
    try {
      final shader = _shader ??= program.fragmentShader();
      touch.configure(
        shader,
        shapes,
        devicePixelRatio: _devicePixelRatio,
        veil: _veil,
        ink: _ink,
        weakInk: _weakInk,
      );
      return ImageFilter.compose(
        outer: ImageFilter.shader(shader),
        inner: blur,
      );
    } catch (error) {
      _shaderFailed = true;
      debugPrint('[glass] liquid filter unavailable: $error');
      return null;
    }
  }

  List<RRect>? _shaderShapes() {
    if (_painted.length > HermesLiquid.maxPieces) return null;
    final ratio = _devicePixelRatio;
    final shapes = <RRect>[];
    for (final piece in _painted.keys) {
      final shape = piece.shaderShape();
      final translation = MatrixUtils.getAsTranslation(
        piece.getTransformTo(null),
      );
      if (shape == null || translation == null) return null;
      final rect = shape.outerRect.shift(translation);
      shapes.add(
        RRect.fromRectAndRadius(
          _physical(rect, ratio),
          Radius.circular(shape.tlRadiusX * ratio),
        ),
      );
    }
    return shapes;
  }

  /// Q9-LIQUID: the rectangle around [outline], wide enough for the rim
  /// and the bridges between pieces that join.
  Path _liquidClip(Path outline) {
    final (touch, _) = _liquid!;
    final margin = touch.fusion + touch.rimWidth;
    return Path()..addRect(outline.getBounds().inflate(margin));
  }

  static Rect _physical(Rect rect, double ratio) =>
      (rect.topLeft * ratio) & (rect.size * ratio);

  @override
  void dispose() {
    _clip.layer = null;
    _filter.layer = null;
    final shader = _shader;
    _shader = null;
    super.dispose();
    shader?.dispose();
  }
}

/// A floating piece of a [HermesGlassStrip]: [shape] is its visible
/// outline, which the strip's one blur fills. Outside a strip it is
/// nothing.
class HermesGlassPiece extends SingleChildRenderObjectWidget {
  const HermesGlassPiece({required this.shape, super.child, super.key})
    : band = false;

  /// The whole band of a header: the strip's one blur also covers this
  /// rectangle (the measured size of [child]), and nothing else is asked of
  /// the strip for it: no rim, no shader shape, no veil of its own. The
  /// [child] paints the tint over the frosted page. Needs a strip with
  /// [HermesGlassStrip.band].
  const HermesGlassPiece.band({super.child, super.key})
    : shape = const RoundedRectangleBorder(),
      band = true;

  final ShapeBorder shape;

  /// Whether this is a header's band, not a piece (see [HermesGlassPiece.band]).
  final bool band;

  static _StripHandle? _handleOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_GlassScope>()?.handle;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderGlassPiece(
    handle: _handleOf(context),
    shape: shape,
    band: band,
    textDirection: Directionality.maybeOf(context),
  );

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderGlassPiece)
      ..handle = _handleOf(context)
      ..shape = shape
      ..textDirection = Directionality.maybeOf(context);
  }
}

class _RenderGlassPiece extends RenderProxyBox {
  _RenderGlassPiece({
    required this._handle,
    required this._shape,
    required this._textDirection,
    this.band = false,
  });

  /// A header's band: frosted by the strip, otherwise no piece (see
  /// [HermesGlassPiece.band]).
  final bool band;

  _StripHandle? _handle;
  set handle(_StripHandle? value) {
    if (identical(value, _handle)) return;
    if (attached) _handle?.render?.remove(this);
    _handle = value;
    if (attached) _handle?.render?.add(this);
  }

  ShapeBorder _shape;
  set shape(ShapeBorder value) {
    if (value == _shape) return;
    _shape = value;
    _handle?.render?.changed();
  }

  TextDirection? _textDirection;
  set textDirection(TextDirection? value) {
    if (value == _textDirection) return;
    _textDirection = value;
    _handle?.render?.changed();
  }

  Path outline() =>
      _shape.getOuterPath(Offset.zero & size, textDirection: _textDirection);

  /// The shader supports circles, stadiums and equal circular corners.
  /// Every other shape keeps the regular glass, never loses its veil.
  RRect? shaderShape() {
    final rect = Offset.zero & size;
    if (_shape is CircleBorder) {
      return RRect.fromRectAndRadius(
        Rect.fromCircle(center: rect.center, radius: size.shortestSide / 2),
        Radius.circular(size.shortestSide / 2),
      );
    }
    if (_shape is StadiumBorder) {
      return RRect.fromRectAndRadius(
        rect,
        Radius.circular(size.shortestSide / 2),
      );
    }
    if (_shape case RoundedRectangleBorder(:final borderRadius)) {
      final radius = borderRadius.resolve(_textDirection);
      if (radius.topLeft != radius.topRight ||
          radius.topLeft != radius.bottomLeft ||
          radius.topLeft != radius.bottomRight ||
          radius.topLeft.x != radius.topLeft.y) {
        return null;
      }
      return radius.toRRect(rect);
    }
    return null;
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _handle?.render?.add(this);
  }

  @override
  void detach() {
    _handle?.render?.remove(this);
    super.detach();
  }

  @override
  void performLayout() {
    final before = hasSize ? size : null;
    super.performLayout();
    if (before != size) _handle?.render?.changed();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final strip = _handle?.render;
    if (strip != null &&
        strip.attached &&
        (strip.blur ||
            strip._tone != null ||
            strip._touch != null ||
            strip._maxFilterArea != null) &&
        !size.isEmpty &&
        strip.holds(this)) {
      final painted = strip._painted[this];
      if (painted == null || painted != getTransformTo(strip)) {
        strip.repaintSoon();
      }
    }
    super.paint(context, offset);
  }
}

/// The lit rim of a piece of glass: a fine light edge, brightest along the
/// top and fading towards the foot, as the light of a pane. It paints only on
/// the 1 dp ring of the outline, never behind an ink, so it adds nothing to
/// what the certified inks sit on ([HermesSmokedGlass.readsFor]).
class HermesGlassRim extends CustomPainter {
  const HermesGlassRim({required this.chrome, required this.radius});

  final HermesChrome chrome;
  final double radius;

  /// The resting edge colour of a piece over the glass.
  static Color edgeOf(HermesChrome chrome) =>
      chrome.ink.withValues(alpha: chrome.dark ? 0.20 : 0.12);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(0.5);
    if (rect.isEmpty) return;
    final top = chrome.ink.withValues(alpha: chrome.dark ? 0.42 : 0.20);
    final foot = chrome.ink.withValues(alpha: chrome.dark ? 0.06 : 0.04);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(radius - 0.5)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [top, foot],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(HermesGlassRim oldDelegate) =>
      chrome != oldDelegate.chrome || radius != oldDelegate.radius;
}
