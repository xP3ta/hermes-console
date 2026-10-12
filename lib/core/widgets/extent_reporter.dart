import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Height of the soft fade painted right above a floating composer: the
/// transcript scrolls under the composer and fades out over this band
/// instead of meeting an opaque edge.
const double kComposerFadeHeight = 28;

/// Reports its child's laid-out height whenever it changes, so a screen can
/// reserve that much below a list that runs under a floating overlay.
///
/// The report is delivered after the frame (with a frame scheduled for it):
/// the listener may rebuild widgets under a [LayoutBuilder] that is being
/// laid out right now, which must not be dirtied during layout.
class ExtentReporter extends SingleChildRenderObjectWidget {
  const ExtentReporter({
    super.key,
    required this.onExtent,
    required super.child,
  });

  final ValueChanged<double> onExtent;

  @override
  RenderExtentReporter createRenderObject(BuildContext context) =>
      RenderExtentReporter(onExtent);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderExtentReporter renderObject,
  ) {
    renderObject.onExtent = onExtent;
  }
}

class RenderExtentReporter extends RenderProxyBox {
  RenderExtentReporter(this.onExtent);

  ValueChanged<double> onExtent;
  double? _reported;
  bool _pending = false;

  @override
  void performLayout() {
    super.performLayout();
    if (_reported == size.height || _pending) return;
    _pending = true;
    SchedulerBinding.instance
      ..addPostFrameCallback((_) {
        _pending = false;
        if (!attached || !hasSize) return;
        _reported = size.height;
        onExtent(size.height);
      })
      ..scheduleFrame();
  }
}
