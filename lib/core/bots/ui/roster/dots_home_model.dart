import '../../../models/agent_profile.dart';
import 'roster_model.dart';

/// The main bot: the connection's default profile ("Hermes"). It always
/// leads the Bots home's team grid (its first tile).
bool isMainBot(AgentProfile profile) =>
    profile.isDefault || profile.name == 'default';

/// Pure layout of the Bots home in the Dots style (owner decision 1.2.15,
/// variant C).
///
/// - [pinned]: the bots the user pinned (`ui_meta` `pinned`, the same flag
///   Desktop and the long-press Pin/Unpin write), in roster order whatever
///   their state, shown on top as bigger tiles. The main bot joins them only
///   when it is pinned itself.
/// - [main]: the default profile when not pinned, always first and stable
///   (the grid's first tile), whatever its state (even when another bot is
///   waiting). It is shown even when Desktop
///   marked it hidden: the main bot cannot disappear from its own home.
/// - [team]: the other visible, unpinned bots, in Hermex's attention order:
///   waiting for you, then working, then the rest by recent activity.
///   Desktop sections do not reorder the grid (they stay manageable from the "+"
///   menu), and hidden bots are left out unless [showHidden].
/// - [rooms]: needing you, then working, then by recent activity.
/// - [working] / [waiting]: counts over the main bot and the visible team,
///   for the "N working · M waiting for you" line (the search query does not
///   change them).
///
/// State comes only from each entry's signal, which [BotRosterEntry.from]
/// derives from the bot's canonical Bot Chat alone.
final class DotsHomeLayout {
  final List<BotRosterEntry> pinned;
  final BotRosterEntry? main;
  final List<BotRosterEntry> team;
  final List<RoomRosterEntry> rooms;
  final int working;
  final int waiting;
  final int hiddenCount;

  const DotsHomeLayout({
    this.pinned = const [],
    required this.main,
    required this.team,
    required this.rooms,
    required this.working,
    required this.waiting,
    required this.hiddenCount,
  });

  bool get isEmpty =>
      pinned.isEmpty && main == null && team.isEmpty && rooms.isEmpty;

  static DotsHomeLayout build({
    required List<BotRosterEntry> bots,
    required List<RoomRosterEntry> rooms,
    String query = '',
    bool showHidden = false,
  }) {
    BotRosterEntry? main;
    final others = <BotRosterEntry>[];
    for (final bot in bots) {
      if (main == null && isMainBot(bot.profile)) {
        main = bot;
      } else {
        others.add(bot);
      }
    }
    final hiddenCount = others.where((b) => b.profile.botHidden).length;
    final visible = others
        .where((b) => showHidden || !b.profile.botHidden)
        .toList();
    final counted = [?main, ...visible];
    final working = counted.where((b) => b.working).length;
    final waiting = counted.where((b) => b.needsYou).length;

    final folded = foldRosterSearch(query);
    bool matches(RosterEntry entry) {
      if (folded.isEmpty) return true;
      final fields = switch (entry) {
        BotRosterEntry(:final profile) => [
          profile.name,
          profile.botTitle,
          profile.description,
          profile.botSectionName,
        ],
        RoomRosterEntry(:final title, :final members) => [
          title,
          for (final m in members) m.handle,
        ],
      };
      return fields.whereType<String>().any(
        (value) => foldRosterSearch(value).contains(folded),
      );
    }

    int byRecency(RosterEntry a, RosterEntry b) {
      final at = a.at?.millisecondsSinceEpoch ?? 0;
      final bt = b.at?.millisecondsSinceEpoch ?? 0;
      if (at != bt) return bt.compareTo(at);
      final byTitle = a.title.toLowerCase().compareTo(b.title.toLowerCase());
      return byTitle != 0 ? byTitle : a.key.compareTo(b.key);
    }

    int tier(BotRosterEntry bot) => bot.needsYou
        ? 0
        : bot.working
        ? 1
        : 2;

    final shown = {...visible, ?main};
    final pinned = [
      for (final bot in bots)
        if (shown.contains(bot) && bot.profile.botPinned && matches(bot)) bot,
    ];
    final team =
        visible.where((b) => !b.profile.botPinned && matches(b)).toList()
          ..sort((a, b) {
            final byTier = tier(a).compareTo(tier(b));
            return byTier != 0 ? byTier : byRecency(a, b);
          });

    int roomTier(RoomRosterEntry room) => room.needsYou
        ? 0
        : room.working
        ? 1
        : 2;
    final sortedRooms = rooms.where(matches).toList()
      ..sort((a, b) {
        final byTier = roomTier(a).compareTo(roomTier(b));
        return byTier != 0 ? byTier : byRecency(a, b);
      });

    return DotsHomeLayout(
      pinned: pinned,
      main: main != null && !main.profile.botPinned && matches(main)
          ? main
          : null,
      team: team,
      rooms: sortedRooms,
      working: working,
      waiting: waiting,
      hiddenCount: hiddenCount,
    );
  }
}
