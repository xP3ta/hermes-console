import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/navigation/chat_route.dart';
import 'package:hermes_android/core/widgets/adaptive_list_detail.dart';

// A chat opened in the list's detail pane lives on a nested Navigator.
// openChatWithParent is what the drawer's «New chat» and recents use: it
// must rebuild the app's ROOT stack (Home -> list -> chat). Doing it on the
// pane's navigator nested the whole list screen inside the pane.

void main() {
  testWidgets('openChatWithParent from the detail pane uses the root navigator', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 900);
    addTearDown(tester.view.reset);

    final rootKey = GlobalKey<NavigatorState>();
    final paneKey = GlobalKey<AdaptiveListDetailState>();
    final inPane = GlobalKey();

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: rootKey,
        home: Scaffold(
          body: AdaptiveListDetail(
            key: paneKey,
            placeholder: const SizedBox.shrink(),
            list: const SizedBox.shrink(),
          ),
        ),
      ),
    );
    await tester.pump();

    paneKey.currentState!.show<void>(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          body: SizedBox.expand(key: inPane, child: const Text('pane chat')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(paneKey.currentState!.hasDetail, isTrue);

    final paneNavigator = Navigator.of(inPane.currentContext!);
    expect(paneNavigator, isNot(same(rootKey.currentState)));

    unawaited(
      openChatWithParent<void>(
        inPane.currentContext!,
        parentBuilder: (_) => const Scaffold(body: Text('parent list')),
        builder: (_) => const Scaffold(body: Text('new chat')),
      ),
    );
    await tester.pumpAndSettle();

    final chat = find.text('new chat');
    final parent = find.text('parent list', skipOffstage: false);
    expect(chat, findsOneWidget);
    expect(parent, findsOneWidget);
    expect(
      Navigator.of(tester.element(chat)),
      same(rootKey.currentState),
      reason: 'the new chat belongs to the root stack, not to the pane',
    );
    expect(
      Navigator.of(tester.element(parent)),
      same(rootKey.currentState),
      reason: 'the parent list belongs to the root stack, not to the pane',
    );
    // The pane keeps only its own chat: nothing was pushed inside it.
    final pushedInPane = <Route<dynamic>>[];
    paneNavigator.popUntil((route) {
      pushedInPane.add(route);
      return route.isFirst;
    });
    expect(pushedInPane.length, lessThanOrEqualTo(2));
  });
}
