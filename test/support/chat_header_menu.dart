import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// fh1215: the chat header no longer shows search, model or ⋮ buttons. Their
/// actions live in the header pill's menu (a long press on the pill always
/// opens it) until the notch sheet hosts them.
Future<void> openChatHeaderMenu(WidgetTester tester) async {
  await tester.longPress(find.byKey(const ValueKey('chat-activity-pill')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

Future<void> closeChatHeaderMenu(WidgetTester tester) async {
  await tester.binding.handlePopRoute();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

/// Opens the chat controls sheet the old ⋮ (`chat-control-trigger`) opened.
Future<void> openChatControlsFromHeader(WidgetTester tester) async {
  await openChatHeaderMenu(tester);
  await tester.tap(find.byKey(const ValueKey('chat-menu-controls')));
}

/// Opens the in-chat search the old search icon opened.
Future<void> openChatFindFromHeader(WidgetTester tester) async {
  await openChatHeaderMenu(tester);
  await tester.tap(find.byKey(const ValueKey('chat-menu-find')));
}
