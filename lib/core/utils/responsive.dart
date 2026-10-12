// Responsive layout helpers.
//
// Material 3 window size classes:
//   compact  < 600dp  — phones: the original single-column UI and bottom dock
//   medium   600–839  — small tablets / foldables: navigation rail, one pane
//   expanded >= 840   — tablets and landscape: rail plus list-detail panes
//
// Every reader here depends on the window SIZE only (`MediaQuery.sizeOf`),
// never on the whole `MediaQueryData`: `MediaQuery.of` would rebuild every
// adaptive surface on each keyboard animation frame (see #141).
import 'package:flutter/material.dart';

enum WindowSizeClass { compact, medium, expanded }

class Responsive {
  /// 600dp breakpoint — the Material Design standard for phone/tablet.
  static const double tabletBreakpoint = 600;

  /// 840dp breakpoint — Material 3 "expanded": room for two panes.
  static const double expandedBreakpoint = 840;

  /// Widest a single-pane body gets on a tablet before it is centred.
  static const double maxContentWidth = 720;

  /// Widest a run of text should get (about 80–90 characters).
  static const double maxLineWidth = 760;

  /// Width of the list pane in a list-detail layout.
  static const double listPaneWidth = 360;

  /// Width of the categories pane of Settings in expanded windows.
  static const double settingsCategoryPaneWidth = 320;

  /// Width of the chat's activity side panel in expanded windows.
  static const double activitySidePanelWidth = 360;

  /// Narrowest the conversation column gets beside the activity side panel;
  /// a narrower chat keeps the modal panel.
  static const double minChatColumnWidth = 440;

  static WindowSizeClass sizeClassForWidth(double width) {
    if (width >= expandedBreakpoint) return WindowSizeClass.expanded;
    if (width >= tabletBreakpoint) return WindowSizeClass.medium;
    return WindowSizeClass.compact;
  }

  /// Window size class of the current window.
  static WindowSizeClass sizeClassOf(BuildContext context) =>
      sizeClassForWidth(MediaQuery.sizeOf(context).width);

  /// Whether the current screen is wide enough for tablet layout.
  static bool isTablet(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= tabletBreakpoint;

  /// Whether navigation is a side rail instead of the bottom dock.
  static bool usesRail(BuildContext context) =>
      sizeClassOf(context) != WindowSizeClass.compact;

  /// Whether there is room for list-detail panes.
  static bool isExpanded(BuildContext context) =>
      sizeClassOf(context) == WindowSizeClass.expanded;

  /// Returns appropriate cross-axis count for grid layouts.
  static int gridColumns(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    if (width >= 1200) return 4;
    if (width >= 900) return 3;
    if (width >= 600) return 2;
    return 1;
  }
}
