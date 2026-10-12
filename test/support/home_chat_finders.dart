import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/home/board/home_board_model.dart';
import 'package:hermes_android/core/home/board/home_board_store.dart';

/// Home names a chat by its bare title in the «Continuar» widget. A test
/// that means "Home lists this chat" calls [useRecentsHomeBoard] first so
/// the board's Continuar lists every recent chat (the default small one
/// shows only the newest); a chat that must be gone from Home must match
/// nothing.
Finder findHomeChat(String title, {bool skipOffstage = true}) =>
    find.byWidgetPredicate((widget) {
      if (widget is! Text) return false;
      final text = widget.data ?? widget.textSpan?.toPlainText();
      return text == title;
    }, skipOffstage: skipOffstage);

/// Makes Home's default board a large «Continuar» (five chats) for this
/// test file.
void useRecentsHomeBoard() {
  setUp(
    () => HomeBoardStore.debugDefaultLayout = () => HomeBoardLayout([
      const HomeWidgetInstance(
        id: 'recents',
        kind: HomeWidgetKind.continueChats,
        size: HomeWidgetSize.large,
      ),
    ]),
  );
  tearDown(() => HomeBoardStore.debugDefaultLayout = null);
}
