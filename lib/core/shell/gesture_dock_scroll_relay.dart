import 'package:flutter/widgets.dart';

import '../config/feature_flags.dart';
import 'gesture_dock_state.dart';

/// Forwards vertical list scrolling to the gesture dock's auto mode.
///
/// Mounted once above the root navigator so it sees every screen's lists,
/// including Home's, which lays its dock out as a sibling of its content.
/// It never consumes a notification and does nothing while the gesture
/// dock flag is off; the controller also ignores it unless the hide mode
/// is "auto" and a dock is on the visible route.
class GestureDockScrollRelay extends StatelessWidget {
  final Widget child;
  final GestureDockController? controller;
  final FeatureFlags? flags;

  const GestureDockScrollRelay({
    required this.child,
    this.controller,
    this.flags,
    super.key,
  });

  @override
  Widget build(BuildContext context) =>
      NotificationListener<ScrollUpdateNotification>(
        onNotification: (notification) {
          if (!(flags ?? FeatureFlags.instance).gestureDock.value) return false;
          final metrics = notification.metrics;
          if (metrics.axis != Axis.vertical) return false;
          final delta = notification.scrollDelta;
          if (delta == null) return false;
          (controller ?? GestureDockController.instance).handleScroll(
            delta: delta,
            pixels: metrics.pixels,
            minExtent: metrics.minScrollExtent,
          );
          return false;
        },
        child: child,
      );
}
