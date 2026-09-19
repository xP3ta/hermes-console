import 'mission_control.dart';

final class BotSectionGroup {
  final String? id;
  final String? name;
  final List<MissionAgent> agents;

  const BotSectionGroup(this.id, this.name, this.agents);
}

List<BotSectionGroup> groupBotSections(
  Iterable<MissionAgent> rows,
  Iterable<MissionAgent> visible,
) {
  final names = <String, String>{};
  for (final agent in visible) {
    final id = agent.profile.botSectionId;
    final name = agent.profile.botSectionName;
    if (id == null || name == null) continue;
    // Stable during a partially synced rename, regardless of activity order.
    if (!names.containsKey(id) || name.compareTo(names[id]!) < 0) {
      names[id] = name;
    }
  }
  final grouped = <String?, List<MissionAgent>>{};
  for (final agent in rows) {
    final id = agent.profile.botSectionId;
    (grouped[names.containsKey(id) ? id : null] ??= []).add(agent);
  }
  final ids = grouped.keys.whereType<String>().toList()
    ..sort((a, b) {
      final byName = names[a]!.toLowerCase().compareTo(names[b]!.toLowerCase());
      return byName != 0 ? byName : a.compareTo(b);
    });
  return [
    for (final id in ids)
      BotSectionGroup(id, names[id], List.unmodifiable(grouped[id]!)),
    if (grouped[null] case final loose?)
      BotSectionGroup(null, null, List.unmodifiable(loose)),
  ];
}
