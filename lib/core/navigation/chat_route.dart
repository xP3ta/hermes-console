import 'package:flutter/material.dart';

/// Opens a chat as the only route above the app home.
///
/// Chats are destinations, not drill-down pages. Keeping section screens or
/// previous chats below them makes Android Back walk through stale
/// conversations. This helper preserves the first route (Home), removes every
/// intermediate route, and then opens the requested chat.
Future<T?> openChatFromHome<T extends Object?>(
  BuildContext context, {
  required WidgetBuilder builder,
}) => openChatFromHomeNavigator<T>(Navigator.of(context), builder: builder);

/// Opens a contextual chat while preserving its owning section below it.
///
/// Bot Chat and Rooms belong to Mission Control: Android Back must return to
/// that surface, not flatten the route to Home like a generic conversation.
Future<T?> openChatFromSection<T extends Object?>(
  BuildContext context, {
  required WidgetBuilder builder,
}) => Navigator.of(context).push<T>(MaterialPageRoute<T>(builder: builder));

/// Opens a chat above its canonical library, discarding stale sections/chats.
///
/// The resulting stack is always Home -> parent -> current chat. This keeps
/// Android Back predictable without resurrecting an earlier conversation.
Future<T?> openChatWithParent<T extends Object?>(
  BuildContext context, {
  required WidgetBuilder parentBuilder,
  required WidgetBuilder builder,
}) {
  // Root navigator: called from a drawer inside a tablet detail pane, the
  // nearest navigator would nest the list screen inside the pane.
  final navigator = Navigator.of(context, rootNavigator: true);
  navigator.pushAndRemoveUntil<void>(
    MaterialPageRoute<void>(builder: parentBuilder),
    (route) => route.isFirst,
  );
  return navigator.push<T>(MaterialPageRoute<T>(builder: builder));
}

/// [NavigatorState] variant for app-level entry points such as notifications,
/// widgets, shares and voice hand-offs.
Future<T?> openChatFromHomeNavigator<T extends Object?>(
  NavigatorState navigator, {
  required WidgetBuilder builder,
}) {
  return navigator.pushAndRemoveUntil<T>(
    MaterialPageRoute<T>(builder: builder),
    (route) => route.isFirst,
  );
}
