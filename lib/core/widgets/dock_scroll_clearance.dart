import 'package:flutter/widgets.dart';

/// Space a scrolling body reserves inside its content for the floating dock.
/// Null leaves legacy or side-rail padding decisions with the consumer.
class DockScrollClearance extends InheritedWidget {
  const DockScrollClearance({
    required this.bottom,
    required super.child,
    super.key,
  });

  final double? bottom;

  static double? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DockScrollClearance>()?.bottom;

  @override
  bool updateShouldNotify(DockScrollClearance oldWidget) =>
      bottom != oldWidget.bottom;
}
