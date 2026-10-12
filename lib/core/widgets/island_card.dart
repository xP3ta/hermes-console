import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:flutter/foundation.dart' show ValueListenable;

import '../design/modal.dart' show releaseTextFocusIfKeyboardHidden;
import '../design/tokens.dart';
import '../models/activity_snapshot.dart';
import '../theme/app_theme.dart';
import 'floating_chat_header.dart';
import 'pill_morph.dart';
import 'running_work.dart';

/// The card stops growing here (about five rows under its first line) and
/// scrolls what is left inside.
const double kIslandCardMaxHeight = 404;

/// Opens the card the island grows into: it starts where the island's pill
/// is and grows downward and to the sides, the face on the island staying
/// in view above it. Its first line is [header] (the island's own line,
/// repeated), then [builder]'s rows, which scroll when they do not fit.
///
/// It is closed by a tap outside, by Back, by dragging it up or by whatever
/// [header] does with the `close` it is given; it never reaches into
/// [reserveBelow] (the composer and what floats on it), keyboard included.
///
/// [origin] is the island's pill, read live (`ChatIsland.surfaceRectIn`);
/// nothing opens while there is none.
Future<void> showIslandCard({
  required BuildContext context,
  required Rect? Function() origin,
  required Widget Function(BuildContext context, VoidCallback close) header,
  required WidgetBuilder builder,
  required String dismissLabel,
  double Function()? reserveBelow,
  Key surfaceKey = const ValueKey('island-card'),
}) {
  final first = origin();
  if (first == null) return Future<void>.value();
  final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
  releaseTextFocusIfKeyboardHidden(context);
  return Navigator.of(context).push<void>(
    PillMorphRoute<void>(
      reduceMotion: reduce,
      dismissLabel: dismissLabel,
      builder: (routeContext, animation) {
        void close() {
          if (routeContext.mounted) Navigator.of(routeContext).maybePop();
        }

        final media = MediaQuery.of(routeContext);
        final colors = Theme.of(routeContext).hermes;
        final chrome = HermesChrome.of(colors);
        final pill = origin() ?? first;
        final below =
            math.max(media.viewInsets.bottom, media.padding.bottom) +
            (reserveBelow?.call() ?? 132) +
            8;
        final room = media.size.height - below - pill.top;
        final maxHeight = math.max(120.0, math.min(kIslandCardMaxHeight, room));
        return PillMorphSurface(
          animation: animation,
          origin: () => origin() ?? first,
          edge: PillMorphEdge.top,
          // Over the pill it grows out of, not under it: the card's first
          // line is the island's.
          target: (pill, screen, size) => Rect.fromLTWH(
            (screen.width - size.width) / 2,
            pill.top,
            size.width,
            size.height,
          ),
          color: chrome.opaque,
          borderColor: chrome.line,
          maxHeight: maxHeight,
          radius: 26,
          scrimOpacity: HermesChrome.scrimSheet,
          scrimTop: pill.top,
          reduceMotion: reduce,
          dismissLabel: dismissLabel,
          surfaceKey: surfaceKey,
          onDismiss: close,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // The island's own line: at the island's text scale.
              MediaQuery.withClampedTextScaling(
                maxScaleFactor: FloatingChatHeader.maxTextScale,
                child: Builder(builder: (context) => header(context, close)),
              ),
              Divider(
                height: 1,
                thickness: 1,
                color: colors.divider.withValues(alpha: 0.5),
              ),
              Flexible(
                child: SingleChildScrollView(
                  key: const ValueKey('island-card-rows'),
                  child: Builder(builder: builder),
                ),
              ),
              ExcludeSemantics(
                child: SizedBox(
                  key: const ValueKey('island-card-grabber'),
                  height: 17,
                  child: Center(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: colors.textSecondary.withValues(alpha: 0.35),
                        borderRadius: BorderRadius.circular(2),
                      ),
                      child: const SizedBox(width: 30, height: 3.5),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
}

/// The island's card of what a conversation has alive outside its turn:
/// [header] (the island's line) and one row per thing ([RunningWork]). It
/// follows [snapshot] while it is open and closes itself once nothing is
/// left to show. [actions] gets what closes the card, for the rows that
/// take the reader somewhere else.
Future<void> showRunningWorkCard({
  required BuildContext context,
  required Rect? Function() origin,
  required ValueListenable<ActivitySnapshot> snapshot,
  required Widget Function(BuildContext context, VoidCallback close) header,
  required RunningWorkActions Function(VoidCallback close) actions,
  required String dismissLabel,
  DateTime Function()? clock,
  double Function()? reserveBelow,
}) => showIslandCard(
  context: context,
  origin: origin,
  header: header,
  dismissLabel: dismissLabel,
  reserveBelow: reserveBelow,
  builder: (cardContext) => _ClosesWhenEmpty(
    snapshot: snapshot,
    child: RunningWork(
      key: const ValueKey('island-running-work'),
      snapshot: snapshot,
      clock: clock,
      // The card's first line already says it.
      title: false,
      // At once: what the row opens next goes on top of a card that is
      // already leaving (a deferred pop would be dropped by that push).
      actions: actions(() {
        final route = ModalRoute.of(cardContext);
        if (route != null && route.isCurrent) Navigator.of(cardContext).pop();
      }),
    ),
  ),
);

/// Closes the card it is in once there is nothing left to show in it.
class _ClosesWhenEmpty extends StatefulWidget {
  const _ClosesWhenEmpty({required this.snapshot, required this.child});

  final ValueListenable<ActivitySnapshot> snapshot;
  final Widget child;

  @override
  State<_ClosesWhenEmpty> createState() => _ClosesWhenEmptyState();
}

class _ClosesWhenEmptyState extends State<_ClosesWhenEmpty> {
  @override
  void initState() {
    super.initState();
    widget.snapshot.addListener(_check);
  }

  @override
  void dispose() {
    widget.snapshot.removeListener(_check);
    super.dispose();
  }

  void _check() {
    if (!mounted || RunningWork.hasContent(widget.snapshot.value)) return;
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
