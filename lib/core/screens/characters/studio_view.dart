import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// Zoom and pan of the editor's canvas, and whether one finger pans.
class StudioViewController extends ChangeNotifier {
  static const double minZoom = 0.5;
  static const double maxZoom = 4;
  static const double step = 0.25;

  double _zoom = 1;
  Offset _pan = Offset.zero;
  bool _panMode = false;

  double get zoom => _zoom;
  Offset get pan => _pan;
  bool get panMode => _panMode;
  int get percent => (_zoom * 100).round();
  bool get canZoomIn => _zoom < maxZoom - 1e-9;
  bool get canZoomOut => _zoom > minZoom + 1e-9;

  void setZoom(double value) {
    final next = value.isNaN ? 1.0 : value.clamp(minZoom, maxZoom).toDouble();
    if (next == _zoom) return;
    _zoom = next;
    notifyListeners();
  }

  void setPan(Offset value) {
    if (value == _pan) return;
    _pan = value;
    notifyListeners();
  }

  void zoomIn() => setZoom(_zoom + step);
  void zoomOut() => setZoom(_zoom - step);

  /// 100 %: the canvas at its natural size, where it is.
  void actualSize() => setZoom(1);

  /// The whole character in view: 100 % and centred.
  void fit() {
    if (_zoom == 1 && _pan == Offset.zero) return;
    _zoom = 1;
    _pan = Offset.zero;
    notifyListeners();
  }

  void togglePanMode() {
    _panMode = !_panMode;
    notifyListeners();
  }
}

/// The maths between a point of the editor's canvas widget and a point of
/// the 100 x 100 drawing, for a square canvas of [side] logical pixels
/// scaled by [zoom] about its centre and shifted by [pan].
@immutable
final class StudioViewport {
  final double side;
  final double zoom;
  final Offset pan;

  const StudioViewport({
    required this.side,
    this.zoom = 1,
    this.pan = Offset.zero,
  });

  Offset get _centre => Offset(side / 2, side / 2);

  /// Widget point to drawing point.
  Offset toCanvas(Offset local) {
    final content = _centre + (local - _centre - pan) / zoom;
    return content * (100 / side);
  }

  /// Drawing point to widget point.
  Offset fromCanvas(Offset point) {
    final content = point * (side / 100);
    return _centre + pan + (content - _centre) * zoom;
  }
}
