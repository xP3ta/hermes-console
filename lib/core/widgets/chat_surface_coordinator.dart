import 'package:flutter/material.dart';

/// Route-owned presentation authority for the Mission Control root surface.
///
/// Coordinates are expressed in the post-Scaffold body space. That viewport has
/// already been resized for the IME, so [viewInsets] is recorded for diagnostics
/// but is deliberately not added to [bottomInset].
class ChatSurfaceCoordinator extends ChangeNotifier {
  final Object routeOwner;

  Rect safeViewportRect = Rect.zero;
  EdgeInsets viewInsets = EdgeInsets.zero;
  double textScale = 1;
  bool reducedMotion = false;
  bool createExpanded = false;
  bool routeActive = true;
  AppLifecycleState lifecycle = AppLifecycleState.resumed;
  double safeBottom = 0;
  FocusNode? focusOwner;

  ChatSurfaceCoordinator({required this.routeOwner});

  static const double dockExtent = 48;
  static const double dockGap = 10;
  static const double contentGap = 12;

  // The Scaffold body is already resized for the IME. The safe-area inset is
  // still physical body padding and must be cleared exactly once.
  double get bottomInset => safeBottom + dockGap;
  double get scrollReservation =>
      dockExtent + dockGap + contentGap + safeBottom;
  bool get dockVisible => routeActive && lifecycle == AppLifecycleState.resumed;

  void updateViewport({
    required Size postLayoutSize,
    required EdgeInsets safePadding,
    required EdgeInsets viewInsets,
    required double textScale,
    required bool reducedMotion,
  }) {
    this.viewInsets = viewInsets;
    this.textScale = textScale;
    this.reducedMotion = reducedMotion;
    safeBottom = safePadding.bottom;
    safeViewportRect = Rect.fromLTWH(
      safePadding.left,
      0,
      (postLayoutSize.width - safePadding.horizontal).clamp(0, double.infinity),
      postLayoutSize.height,
    );
  }

  void openCreate() {
    if (!dockVisible || createExpanded) return;
    createExpanded = true;
    notifyListeners();
  }

  void closeCreate() {
    if (!createExpanded) return;
    createExpanded = false;
    notifyListeners();
  }

  void claimFocus(FocusNode owner) {
    if (!dockVisible) return;
    focusOwner = owner;
    owner.requestFocus();
  }

  void setRouteActive(bool value) {
    if (routeActive == value) return;
    routeActive = value;
    if (!value) {
      createExpanded = false;
      focusOwner?.unfocus();
      focusOwner = null;
    }
    notifyListeners();
  }

  void handleLifecycle(AppLifecycleState value) {
    lifecycle = value;
    if (value != AppLifecycleState.resumed) {
      createExpanded = false;
      focusOwner?.unfocus();
      focusOwner = null;
    }
    notifyListeners();
  }
}
