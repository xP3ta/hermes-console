import '../../models/agent_profile.dart';
import 'bot_presence.dart';

/// Exact Bot Chat title: the registry key Desktop and the gateway use.
const botChatTitle = 'Bot Chat';

/// Optional gateway capability: `session.list {title, include_hidden, profile}`
/// — the window-free registry lookup Desktop runs on every Bot row click.
abstract interface class BotChatTitleLookup {
  /// The profile's canonical "Bot Chat" row, or `null` when none exists.
  Future<AgentProfileSessionSummary?> findBotChatByTitle(String profile);
}

enum BotChatTargetSource {
  /// Resolved server-side (`canonical_session` or a title lookup).
  canonical,

  /// No row exists yet: open a draft that creates it titled "Bot Chat".
  create,
}

/// Where a bot row opens, plus the row preview (spec 070 T206).
///
/// Per Desktop's invariant (apps/desktop/src/AGENTS.md "one bot = ONE
/// canonical forever-chat, identified by NAME") the only identity is the
/// session titled exactly "Bot Chat". Legacy `ui_meta['hermes-bots'].chat`
/// pins and Console-local pins are ignored: preview identity and click
/// identity are the same server row by construction.
final class BotChatTarget {
  final BotChatTargetSource source;

  /// Session to resume (the lineage tip when the server resolved one).
  final String? sessionId;
  final String preview;

  /// Row time: the newest of the canonical chat and a fresh worker session.
  final DateTime? lastActivityAt;

  /// Title of a fresh background worker, shown as "working on".
  final String? workingOn;

  const BotChatTarget._({
    required this.source,
    this.sessionId,
    this.preview = '',
    this.lastActivityAt,
    this.workingOn,
  });

  bool get exists => sessionId != null;

  /// Session.source wire value Console's chat screen understands.
  String get chatSource =>
      source == BotChatTargetSource.canonical ? 'bot-mode-canonical' : 'mobile-bot';

  static BotChatTarget resolve(
    AgentProfile profile, {
    AgentProfileSessionSummary? titleLookup,
    DateTime? now,
  }) {
    final summary = profile.canonicalSession ?? titleLookup;
    final sessionId = summary == null ? null : _sessionIdOf(summary);
    final worker = profile.workerSession;
    final freshWorker =
        worker != null && BotPresence.workerIsFresh(worker, now ?? DateTime.now());
    final times = <double>[
      ?summary?.lastActive,
      if (freshWorker) worker.lastActive,
    ];
    final latest = times.isEmpty
        ? null
        : times.reduce((a, b) => a > b ? a : b);
    return BotChatTarget._(
      source: sessionId == null
          ? BotChatTargetSource.create
          : BotChatTargetSource.canonical,
      sessionId: sessionId,
      preview: summary?.preview ?? '',
      lastActivityAt: latest == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch((latest * 1000).round()),
      workingOn: freshWorker && worker.title.trim().isNotEmpty
          ? worker.title.trim()
          : null,
    );
  }

  static String? _sessionIdOf(AgentProfileSessionSummary summary) {
    for (final candidate in [summary.resolvedId, summary.id]) {
      if (candidate == null) continue;
      final value = candidate.trim();
      if (value.isNotEmpty &&
          value == candidate &&
          !value.startsWith('mob-') &&
          value.length <= 512 &&
          !value.codeUnits.any((u) => u < 0x20 || u == 0x7f)) {
        return value;
      }
    }
    return null;
  }
}
