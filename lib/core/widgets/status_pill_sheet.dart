import 'package:flutter/material.dart';

import '../design/modal.dart' show releaseTextFocusIfKeyboardHidden;
import '../design/tokens.dart' show HermesChrome;
import '../theme/app_theme.dart';
import 'pill_morph.dart';

/// Distance (logical px) past which releasing a downward drag closes a
/// status-pill sheet (the shared pill-morph threshold).
const double kStatusSheetCloseDistance = kPillMorphDismissDistance;

/// Downward release speed (px/s) that closes a status-pill sheet even when
/// it moved less than [kStatusSheetCloseDistance].
const double kStatusSheetCloseVelocity = kPillMorphDismissVelocity;

/// Opens one of the status pill's floating sheets (context, model and
/// session, permissions) anchored above the bottom edge.
///
/// pm1215: a pill morph. It grows out of [origin] (the zone of the bottom
/// pill that was tapped) and shrinks back into it when it closes.
/// * No ✕ (owner decision): it closes on a tap outside, on system Back /
///   Esc, on the screen reader's dismiss action, and by dragging it down:
///   from the header always, from the content only once its scroll is at
///   the top. Released short of the threshold it springs back.
/// * The content scrolls inside the sheet.
/// * Closing never brings back a keyboard the user had already hidden.
/// * Reduced motion: no geometry morph and no spring, only a short fade.
/// * [onRoute] hands the pushed route to its owner, so a screen that goes
///   away can remove the sheet it opened instead of leaving it orphaned.
Future<T?> showStatusPillSheet<T>({
  required BuildContext context,
  required Key surfaceKey,
  required String title,
  required WidgetBuilder builder,
  String? subtitle,
  double maxHeightFactor = 0.85,
  Rect? Function()? origin,
  ValueChanged<Route<T>>? onRoute,
}) {
  final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
  // QA 9490: the chat route gives focus back to the composer when a route on
  // top pops, and a focused field shows the keyboard again by itself.
  releaseTextFocusIfKeyboardHidden(context);
  final dismissLabel = MaterialLocalizations.of(
    context,
  ).modalBarrierDismissLabel;
  late final _StatusSheetRoute<T> route;
  route = _StatusSheetRoute<T>(
    reduceMotion: reduceMotion,
    dismissLabel: dismissLabel,
    builder: (routeContext, animation) {
      final media = MediaQuery.of(routeContext);
      final colors = Theme.of(routeContext).hermes;
      final bottomInset =
          (media.padding.bottom > media.viewInsets.bottom
              ? media.padding.bottom
              : media.viewInsets.bottom) +
          10;
      final free = media.size.height - media.padding.top - bottomInset - 14;
      return FocusScope(
        node: route._focusScopeNode,
        child: PillMorphSurface(
          animation: animation,
          origin: origin ?? () => null,
          edge: PillMorphEdge.bottom,
          color: HermesChrome.of(colors).opaque,
          borderColor: HermesChrome.of(colors).line,
          maxHeight: free < 0 ? 0 : free * maxHeightFactor,
          scrimOpacity: HermesChrome.scrimSheet,
          reduceMotion: reduceMotion,
          dismissLabel: dismissLabel,
          surfaceKey: surfaceKey,
          onDismiss: () => Navigator.of(routeContext).maybePop(),
          child: _StatusSheetBody(
            title: title,
            subtitle: subtitle,
            child: Builder(builder: builder),
          ),
        ),
      );
    },
  );
  onRoute?.call(route);
  return Navigator.of(context).push<T>(route);
}

class _StatusSheetRoute<T> extends PillMorphRoute<T> {
  _StatusSheetRoute({
    required super.builder,
    required super.reduceMotion,
    required super.dismissLabel,
  });

  final FocusScopeNode _focusScopeNode = FocusScopeNode(
    debugLabel: 'StatusPillSheet',
  );

  @override
  bool didPop(T? result) {
    _focusScopeNode.unfocus(disposition: UnfocusDisposition.scope);
    return super.didPop(result);
  }

  @override
  void dispose() {
    _focusScopeNode.dispose();
    super.dispose();
  }
}

/// Grabber, title and the scrolling content. The header always drags the
/// sheet (the morph surface owns the drag).
class _StatusSheetBody extends StatelessWidget {
  const _StatusSheetBody({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String title;
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final header = Padding(
      key: const ValueKey('status-sheet-handle'),
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: ExcludeSemantics(
              child: Container(
                width: 32,
                height: 4,
                margin: const EdgeInsets.only(bottom: 10),
                decoration: BoxDecoration(
                  color: colors.textSecondary.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
          Semantics(
            header: true,
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: colors.textPrimary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (subtitle != null)
            Text(
              subtitle!,
              style: TextStyle(fontSize: 12.5, color: colors.textSecondary),
            ),
        ],
      ),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        Flexible(
          child: SingleChildScrollView(
            key: const ValueKey('status-sheet-scroll'),
            primary: false,
            physics: const ClampingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
            child: child,
          ),
        ),
      ],
    );
  }
}
