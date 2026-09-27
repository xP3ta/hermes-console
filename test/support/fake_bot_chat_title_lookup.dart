import 'package:hermes_android/core/bots/state/bot_chat_target.dart';
import 'package:hermes_android/core/models/agent_profile.dart';

/// In-memory Bot Chat registry (`session.list {title: "Bot Chat"}`) for
/// widget tests: returns the configured row per profile, `null` otherwise.
final class FakeBotChatTitleLookup implements BotChatTitleLookup {
  final Map<String, AgentProfileSessionSummary> rows;
  final calls = <String>[];
  bool fail = false;

  FakeBotChatTitleLookup([this.rows = const {}]);

  @override
  Future<AgentProfileSessionSummary?> findBotChatByTitle(String profile) async {
    calls.add(profile);
    if (fail) throw StateError('registry unavailable');
    return rows[profile];
  }
}
