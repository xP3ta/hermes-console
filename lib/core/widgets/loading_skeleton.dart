// Static placeholders while the chat or the list of chats loads (Ola 7,
// AUDITORIA-PULIDO §4.2): the shape of what is coming in place of
// «Cargando…». No shimmer and no frames, like Home's (`HomeSkeleton`).
import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/hermes_tokens.dart';

/// One line of text still loading: a rounded bar [widthFactor] of the
/// width it is given.
class SkeletonBar extends StatelessWidget {
  const SkeletonBar({
    required this.widthFactor,
    this.height = HermesSpace.x3,
    super.key,
  });

  final double widthFactor;
  final double height;

  @override
  Widget build(BuildContext context) => FractionallySizedBox(
    widthFactor: widthFactor,
    alignment: AlignmentDirectional.centerStart,
    child: SizedBox(
      height: height,
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: Theme.of(context).hermes.surfaceVariant,
          shape: const StadiumBorder(),
        ),
      ),
    ),
  );
}

/// What a screen reader hears for a skeleton: «Cargando…», once, instead
/// of empty shapes.
class SkeletonSemantics extends StatelessWidget {
  const SkeletonSemantics({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    liveRegion: true,
    label: Strings.of(context).commonLoading,
    excludeSemantics: true,
    child: child,
  );
}

/// The chat's first load: a few turns' shapes resting on the composer, as
/// the transcript will (it is anchored at the bottom). The owner's rule
/// for loading holds: no identity here, it lives in the pill.
class ChatLoadingSkeleton extends StatelessWidget {
  const ChatLoadingSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    Widget assistant(List<double> lines) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, width) in lines.indexed) ...[
          if (i > 0) const SizedBox(height: HermesSpace.x2),
          SkeletonBar(widthFactor: width),
        ],
      ],
    );
    final user = Align(
      alignment: AlignmentDirectional.centerEnd,
      child: FractionallySizedBox(
        widthFactor: 0.46,
        child: SizedBox(
          height: HermesSpace.x8,
          child: DecoratedBox(
            decoration: ShapeDecoration(
              color: Theme.of(context).hermes.surfaceVariant,
              shape: const StadiumBorder(),
            ),
          ),
        ),
      ),
    );
    return SkeletonSemantics(
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          key: const ValueKey('chat-loading-skeleton'),
          padding: const EdgeInsets.fromLTRB(
            HermesSpace.x4,
            0,
            HermesSpace.x4,
            HermesSpace.x6,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              assistant(const [0.72, 0.9, 0.48]),
              const SizedBox(height: HermesSpace.x6),
              user,
              const SizedBox(height: HermesSpace.x6),
              assistant(const [0.84, 0.6]),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shows [child] (a skeleton) only once [delay] has passed since it was
/// mounted; before that, nothing. A load that ends sooner swaps nothing in
/// and out, so no placeholder flashes.
class DelayedSkeleton extends StatefulWidget {
  const DelayedSkeleton({
    required this.child,
    this.delay = HermesMotion.skeletonGrace,
    super.key,
  });

  final Widget child;
  final Duration delay;

  @override
  State<DelayedSkeleton> createState() => _DelayedSkeletonState();
}

class _DelayedSkeletonState extends State<DelayedSkeleton> {
  Timer? _timer;
  bool _show = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(widget.delay, () {
      if (mounted) setState(() => _show = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _show ? widget.child : const SizedBox.expand();
}
