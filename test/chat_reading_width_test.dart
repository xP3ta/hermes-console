// Gate gint24 and mock 134: the chat reads at 640 dp only alone on an
// expanded window (state B, the open Fold with the list closed, or a tablet).
// Beside the list (state A) or the workspace (state C), and below 840 dp (a
// phone, the upright Fold, the 800 dp window of chat_screen_test), it takes
// all its room.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/utils/responsive.dart';
import 'package:hermes_android/core/widgets/workspace/chat_workspace.dart';
import 'package:hermes_android/core/widgets/workspace/chat_workspace_host.dart';

const _body = ValueKey('chat-body');

Future<void> _pump(
  WidgetTester tester,
  Size size,
  ChatWorkspaceController views,
) async {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Center(
        child: ChatReadingWidth(
          views: views,
          child: const SizedBox(key: _body, width: double.infinity, height: 10),
        ),
      ),
    ),
  );
}

double _width(WidgetTester tester) => tester.getSize(find.byKey(_body)).width;

ChatWorkspaceController _chats(double width) =>
    ChatWorkspaceController(screen: ChatWorkspaceScreen.chats)
      ..windowWidth = width;

void main() {
  test('the reading width is 640 dp', () {
    expect(Responsive.chatReadingWidth, 640);
  });

  for (final (size, expected) in const [
    (Size(1280, 800), 640.0),
    (Size(933, 704), 640.0),
    (Size(800, 600), 800.0),
    (Size(657, 870), 657.0),
    (Size(360, 640), 360.0),
  ]) {
    testWidgets('a chat alone at ${size.width.toInt()} dp: $expected', (
      tester,
    ) async {
      final views = ChatWorkspaceController();
      addTearDown(views.dispose);
      await _pump(tester, size, views);
      expect(_width(tester), expected);
    });
  }

  testWidgets('beside the list it takes all its room; the list closed, '
      '640 dp', (tester) async {
    final views = _chats(933);
    addTearDown(views.dispose);
    await _pump(tester, const Size(933, 704), views);
    expect(views.listVisible, isTrue);
    expect(_width(tester), 933);

    views.toggleList();
    await tester.pump();
    expect(views.listVisible, isFalse);
    expect(_width(tester), 640);

    views.toggleList();
    await tester.pump();
    expect(_width(tester), 933);
  });

  testWidgets('a tablet with the list open: no cap', (tester) async {
    final views = _chats(1280);
    addTearDown(views.dispose);
    await _pump(tester, const Size(1280, 800), views);
    expect(views.listVisible, isTrue);
    expect(_width(tester), 1280);
  });

  testWidgets('beside the workspace it takes all its room', (tester) async {
    final views = ChatWorkspaceController();
    addTearDown(views.dispose);
    await _pump(tester, const Size(1280, 800), views);
    expect(_width(tester), 640);
    views.open(ChatWorkspaceTab.terminal);
    await tester.pump();
    expect(views.workspaceVisible, isTrue);
    expect(_width(tester), 1280);
  });
}
