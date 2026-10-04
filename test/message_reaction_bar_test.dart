// The reaction row under a message: chips for what is there, one picker for
// the user's own reaction, nothing at all when the feature is off.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/message_reaction.dart';
import 'package:hermes_android/core/services/message_reaction_prefs.dart';
import 'package:hermes_android/core/widgets/chat/message_reaction_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: Center(child: child)),
);

void main() {
  const mine = MessageReaction(emoji: '👍', author: MessageReactionAuthor.user);
  const theirs = MessageReaction(
    emoji: '🎉',
    author: MessageReactionAuthor.agent,
  );

  testWidgets('shows every reaction chip', (tester) async {
    await tester.pumpWidget(
      _host(
        MessageReactionBar(reactions: const [mine, theirs], onPick: (_) {}),
      ),
    );
    expect(find.text('👍'), findsOneWidget);
    expect(find.text('🎉'), findsOneWidget);
  });

  testWidgets('tapping a chip picks that emoji (toggle is the caller\'s)', (
    tester,
  ) async {
    final picked = <String>[];
    await tester.pumpWidget(
      _host(
        MessageReactionBar(
          reactions: const [mine, theirs],
          onPick: (e) => picked.add(e),
        ),
      ),
    );
    await tester.tap(find.text('🎉'));
    await tester.tap(find.text('👍'));
    expect(picked, ['🎉', '👍']);
  });

  testWidgets('the add button opens the quick set', (tester) async {
    final picked = <String>[];
    await tester.pumpWidget(
      _host(MessageReactionBar(reactions: const [], onPick: picked.add)),
    );
    await tester.tap(find.byKey(const ValueKey('message-react-add')));
    await tester.pumpAndSettle();
    for (final emoji in kQuickReactions) {
      expect(find.text(emoji), findsOneWidget);
    }
    await tester.tap(find.text('❤️'));
    await tester.pumpAndSettle();
    expect(picked, ['❤️']);
  });

  testWidgets('without the add button the row is read-only', (tester) async {
    await tester.pumpWidget(
      _host(const MessageReactionBar(reactions: [theirs], onPick: null)),
    );
    expect(find.byKey(const ValueKey('message-react-add')), findsNothing);
    expect(find.text('🎉'), findsOneWidget);
  });

  test('the preference is off by default and persists once switched', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = MessageReactionPrefs.forTesting(prefs);
    expect(store.enabled, isFalse);
    await store.setEnabled(true);
    expect(MessageReactionPrefs.forTesting(prefs).enabled, isTrue);
  });
}
