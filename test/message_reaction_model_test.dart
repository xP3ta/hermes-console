// Reaction rules shared by the optimistic UI and the server echo: one emoji
// per author, the same emoji again retracts, null clears.
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/message_reaction.dart';

void main() {
  const user = MessageReactionAuthor.user;
  const agent = MessageReactionAuthor.agent;

  test('one reaction per author; a new emoji replaces the old one', () {
    var list = applyReaction(const [], user, '👍');
    list = applyReaction(list, user, '🎉');
    expect(list.map((r) => r.emoji), ['🎉']);
  });

  test('the same emoji again retracts it', () {
    final list = applyReaction(applyReaction(const [], user, '👍'), user, '👍');
    expect(list, isEmpty);
  });

  test('a null emoji clears only that author', () {
    var list = applyReaction(const [], user, '👍');
    list = applyReaction(list, agent, '❤️');
    list = applyReaction(list, user, null);
    expect(list.single.author, agent);
  });

  test('parsing drops malformed rows and keeps the first per author', () {
    final list = parseReactions([
      {'emoji': '👍', 'author': 'user', 'at': 1.5, 'seen': true},
      {'emoji': '', 'author': 'agent'},
      {'emoji': '🎉', 'author': 'user'},
      {'emoji': '❤️', 'author': 'robot'},
      'nope',
      {'emoji': '🔥', 'author': 'agent'},
    ]);
    expect(list.map((r) => '${r.author.name}:${r.emoji}'), [
      'user:👍',
      'agent:🔥',
    ]);
    expect(parseReactions(null), isEmpty);
    expect(parseReactions('x'), isEmpty);
  });

  test('the quick set is small and fixed', () {
    expect(kQuickReactions, ['👍', '❤️', '😂', '🎉', '👀']);
  });
}
