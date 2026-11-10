import 'package:flutter/widgets.dart';

/// The cross-fade of F5's [AnimatedSwitcher]s (REPORT-AUDITORIA-FLUIDEZ §3)
/// with TalkBack and touch on the right side of it.
///
/// The default transition is a [FadeTransition] that starts at opacity 0,
/// and an opacity of 0 hides its child from the semantics tree: for the
/// fade's first frames TalkBack did not hear what was coming in (a video's
/// controls, gint58), though it could already be touched. Here what comes
/// in is read from its first frame, and what goes out is neither read nor
/// touched, so nothing is said twice while both are on screen.
Widget accessibleFadeTransition(Widget child, Animation<double> animation) =>
    FadeTransition(
      opacity: animation,
      alwaysIncludeSemantics: true,
      child: AnimatedBuilder(
        animation: animation,
        child: child,
        builder: (context, child) {
          final leaving =
              animation.status == AnimationStatus.reverse ||
              animation.status == AnimationStatus.dismissed;
          return IgnorePointer(
            ignoring: leaving,
            child: ExcludeSemantics(excluding: leaving, child: child),
          );
        },
      ),
    );
