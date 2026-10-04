import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../../../l10n/app_localizations.dart';
import '../../../theme/app_theme.dart';
import '../../artifact_viewer/artifact_html_policy.dart';
import 'embed_consent_store.dart';
import 'embed_detector.dart';
import 'svg_sanitizer.dart';

/// Only one media WebView lives at a time: loading a second one puts the
/// previous card back to its placeholder instead of keeping both decoded.
final class EmbedLiveRegistry {
  EmbedLiveRegistry._();

  static final EmbedLiveRegistry instance = EmbedLiveRegistry._();

  Object? _owner;
  VoidCallback? _release;

  Object? get owner => _owner;

  void claim(Object owner, VoidCallback release) {
    if (!identical(_owner, owner)) _release?.call();
    _owner = owner;
    _release = release;
  }

  void drop(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    _release = null;
  }
}

/// A consent-gated embed: a placeholder of the final size until the user
/// agrees, then a single sandboxed WebView. [fallback] is what the message
/// showed before embeds existed (the link or the code block); it is shown
/// whenever the embed cannot be created.
class EmbedCard extends StatefulWidget {
  /// Link embed, or null for an SVG fence.
  final EmbedDescriptor? descriptor;

  /// Source of an ```svg fence when [descriptor] is null.
  final String? svgSource;

  final Widget fallback;
  final EmbedConsentStore? consent;

  @visibleForTesting
  final Future<bool> Function(Uri uri)? launchExternal;

  @visibleForTesting
  final ArtifactWebViewSettingsFactory settingsFor;

  const EmbedCard({
    required this.fallback,
    this.descriptor,
    this.svgSource,
    this.consent,
    this.launchExternal,
    this.settingsFor = defaultArtifactWebViewSettings,
    super.key,
  }) : assert((descriptor == null) != (svgSource == null));

  @override
  State<EmbedCard> createState() => _EmbedCardState();
}

class _EmbedCardState extends State<EmbedCard> {
  WebViewController? _controller;
  ArtifactHtmlNavigationPolicy? _policy;
  bool _live = false;
  bool _failed = false;
  bool _visible = true;
  bool _covered = false;
  ScrollPosition? _position;
  String? _sanitizedSvg;

  EmbedConsentStore get _consent => widget.consent ?? EmbedConsentStore.shared;

  EmbedType get _type => widget.descriptor?.provider ?? EmbedType.svg;

  String get _label => widget.descriptor?.label ?? EmbedType.svg.label;

  @override
  void initState() {
    super.initState();
    final svg = widget.svgSource;
    if (svg != null) {
      _sanitizedSvg = sanitizeSvgForEmbed(svg);
      _failed = _sanitizedSvg == null;
    } else if (!isAllowedEmbedFrameUrl(widget.descriptor!.embedUrl)) {
      _failed = true;
    }
    _consent.addListener(_onConsentChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final covered = !TickerMode.valuesOf(context).enabled;
    if (covered != _covered) {
      _covered = covered;
      if (covered) _release();
    }
    final position = Scrollable.maybeOf(context)?.position;
    if (!identical(position, _position)) {
      _position?.removeListener(_checkVisibility);
      _position = position?..addListener(_checkVisibility);
    }
    _maybeAutoLoad();
  }

  @override
  void dispose() {
    _consent.removeListener(_onConsentChanged);
    _position?.removeListener(_checkVisibility);
    EmbedLiveRegistry.instance.drop(this);
    super.dispose();
  }

  void _onConsentChanged() {
    if (!mounted) return;
    if (_consent.modeFor(_type) == EmbedMode.off) _release();
    setState(() {});
    _maybeAutoLoad();
  }

  void _maybeAutoLoad() {
    if (_live || _failed || _covered || !_visible) return;
    if (_consent.modeFor(_type) != EmbedMode.always) return;
    if (EmbedLiveRegistry.instance.owner != null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_live && _consent.modeFor(_type) == EmbedMode.always) {
        _load();
      }
    });
  }

  /// Back to the placeholder: scrolled away, route covered, another embed took
  /// the single live slot, or consent was withdrawn. Never reloads by itself.
  void _release() {
    EmbedLiveRegistry.instance.drop(this);
    if (!_live && _controller == null) return;
    _controller = null;
    _policy = null;
    if (mounted) setState(() => _live = false);
  }

  void _checkVisibility() {
    if (!mounted) return;
    final box = context.findRenderObject();
    final scrollable = Scrollable.maybeOf(context);
    final viewport = scrollable?.context.findRenderObject();
    if (box is! RenderBox ||
        !box.attached ||
        viewport is! RenderBox ||
        !viewport.attached) {
      return;
    }
    final top = box.localToGlobal(Offset.zero, ancestor: viewport).dy;
    final bottom = top + box.size.height;
    final visible = bottom > 0 && top < viewport.size.height;
    if (visible == _visible) return;
    _visible = visible;
    if (!visible) _release();
  }

  Future<void> _load() async {
    if (_live || _failed) return;
    final policy = ArtifactHtmlNavigationPolicy(
      launchExternal: widget.launchExternal,
    );
    final controller = WebViewController(
      onPermissionRequest: denyArtifactPermissionRequest,
    );
    _policy = policy;
    _controller = controller;
    EmbedLiveRegistry.instance.claim(this, _release);
    setState(() => _live = true);
    try {
      await configureArtifactWebView(
        controller,
        policy: policy,
        settingsFor: widget.settingsFor,
      );
      final svg = _sanitizedSvg;
      if (svg != null) {
        await controller.loadHtmlString(buildGuardedSvgHtml(svg));
      } else {
        // The page itself needs scripts; it still gets no JavaScript channel,
        // no file access, no window.open and cannot navigate anywhere.
        await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
        await controller.loadRequest(Uri.parse(widget.descriptor!.embedUrl!));
      }
    } catch (_) {
      if (!mounted) return;
      EmbedLiveRegistry.instance.drop(this);
      setState(() {
        _failed = true;
        _live = false;
        _controller = null;
      });
    }
  }

  Future<void> _chooseMode() async {
    final s = Strings.of(context);
    final choice = await showModalBottomSheet<EmbedMode>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const ValueKey('embed-load-once'),
              leading: const Icon(Icons.play_arrow_rounded),
              title: Text(s.embedLoadOnce),
              onTap: () => Navigator.pop(ctx, EmbedMode.ask),
            ),
            ListTile(
              key: const ValueKey('embed-always-allow'),
              leading: const Icon(Icons.verified_user_outlined),
              title: Text(s.embedAlwaysAllow(_label)),
              onTap: () => Navigator.pop(ctx, EmbedMode.always),
            ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == EmbedMode.always) {
      await _consent.setMode(_type, EmbedMode.always);
    }
    await _load();
  }

  double _heightFor(double width) {
    final d = widget.descriptor;
    final screen = MediaQuery.sizeOf(context).height;
    if (d == null) {
      final aspect = _svgAspect(_sanitizedSvg ?? '');
      return (width / aspect).clamp(48.0, screen / 3);
    }
    if (d.aspectRatio != null) return width / d.aspectRatio!;
    return d.height ?? width * 0.56;
  }

  @override
  Widget build(BuildContext context) {
    final mode = _consent.modeFor(_type);
    if (mode == EmbedMode.off || _failed) return widget.fallback;
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final maxWidth = widget.descriptor?.maxWidth ?? 640;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Align(
        alignment: Alignment.centerLeft,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth.isFinite
                ? constraints.maxWidth.clamp(0.0, maxWidth)
                : maxWidth;
            final height = _heightFor(width);
            final controller = _controller;
            return SizedBox(
              key: const ValueKey('embed-card-box'),
              width: width,
              height: height,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: _live && controller != null
                    ? Listener(
                        behavior: HitTestBehavior.translucent,
                        onPointerUp: (_) => _policy?.registerUserTap(),
                        child: WebViewWidget(
                          key: const ValueKey('embed-webview'),
                          controller: controller,
                        ),
                      )
                    : Material(
                        color: colors.surfaceVariant.withValues(alpha: 0.3),
                        child: InkWell(
                          key: const ValueKey('embed-placeholder'),
                          onTap: _load,
                          onLongPress: _chooseMode,
                          child: Center(
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.play_circle_outline_rounded,
                                    color: colors.textSecondary,
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    _type == EmbedType.svg
                                        ? s.embedSvgLabel
                                        : s.embedLoad(_label),
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                      color: colors.textPrimary,
                                    ),
                                  ),
                                  if (_type != EmbedType.svg) ...[
                                    const SizedBox(height: 2),
                                    Text(
                                      s.embedLoadNote(_label),
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        fontSize: 11.5,
                                        color: colors.textSecondary,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Aspect ratio (width / height) of an SVG from its `viewBox`, else 1.5.
double _svgAspect(String svg) {
  final box = RegExp(
    r'viewBox\s*=\s*"\s*[-\d.]+[ ,]+[-\d.]+[ ,]+([\d.]+)[ ,]+([\d.]+)',
  ).firstMatch(svg);
  final w = double.tryParse(box?.group(1) ?? '');
  final h = double.tryParse(box?.group(2) ?? '');
  if (w == null || h == null || w <= 0 || h <= 0) return 1.5;
  return (w / h).clamp(0.2, 8.0);
}
