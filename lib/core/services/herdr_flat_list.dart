// The flat list of the Agents section (1.4.0): agents grouped by the folder
// they work in, those waiting on the user pulled out on top, the finished
// ones apart. Pure data work on the rows of the controller.
import 'herdr_agents.dart';
import 'herdr_status.dart';

/// A folder with at least one agent, for the group headings and the chips.
class HerdrFolderEntry {
  const HerdrFolderEntry({required this.path, required this.label});

  /// The agents' working folder as Herdr reported it; null for agents whose
  /// folder is unknown.
  final String? path;

  /// Short, and told apart from the other folders' labels.
  final String label;
}

/// The agents of one folder, those that need attention first.
class HerdrFolderGroup {
  const HerdrFolderGroup({required this.folder, required this.rows});

  final HerdrFolderEntry folder;
  final List<HerdrAgentRow> rows;
}

/// What the list shows, in order.
class HerdrFlatList {
  const HerdrFlatList({
    required this.needsYou,
    required this.groups,
    required this.done,
  });

  /// Agents waiting on the user (the tray on top), also listed in their
  /// folder.
  final List<HerdrAgentRow> needsYou;

  /// Folders with their working, waiting and idle agents.
  final List<HerdrFolderGroup> groups;

  /// Finished agents, apart, at the end.
  final List<HerdrAgentRow> done;

  bool get isEmpty => groups.isEmpty && done.isEmpty;
}

int _rank(HerdrAgentStatus status) => switch (status) {
  HerdrAgentStatus.blocked => 0,
  HerdrAgentStatus.working => 1,
  HerdrAgentStatus.idle => 2,
  HerdrAgentStatus.unknown => 3,
  HerdrAgentStatus.done => 4,
};

final RegExp _homeFolder = RegExp(r'^(/home/[^/]+|/Users/[^/]+|/root)$');

List<String> _segments(String path) =>
    path.split('/').where((p) => p.isNotEmpty).toList();

/// Short labels for [paths], one per distinct path: the last folder name,
/// with as many parent names as it takes to tell two folders with the same
/// name apart (`a/app` and `b/app`); `~` for a home folder. A null path is
/// not in the map.
Map<String, String> herdrFolderLabels(Iterable<String> paths) {
  final unique = paths.toSet().toList();
  final depth = {for (final p in unique) p: 1};
  String label(String path) {
    if (_homeFolder.hasMatch(path)) return '~';
    final parts = _segments(path);
    if (parts.isEmpty) return '/';
    final take = depth[path]!.clamp(1, parts.length);
    return parts.sublist(parts.length - take).join('/');
  }

  // Deepen only the folders that share a label, until they differ or run
  // out of parents.
  for (var round = 0; round < 8; round++) {
    final byLabel = <String, List<String>>{};
    for (final path in unique) {
      byLabel.putIfAbsent(label(path), () => []).add(path);
    }
    var changed = false;
    for (final group in byLabel.values) {
      if (group.length < 2) continue;
      for (final path in group) {
        if (depth[path]! < _segments(path).length) {
          depth[path] = depth[path]! + 1;
          changed = true;
        }
      }
    }
    if (!changed) break;
  }
  return {for (final path in unique) path: label(path)};
}

/// The folder an agent works in, or null when Herdr did not report one.
String? herdrFolderOf(HerdrAgentRow row) {
  final cwd = row.pane.cwd;
  return cwd == null || cwd.isEmpty ? null : cwd;
}

bool _hit(String? haystack, String needle) =>
    haystack != null && haystack.toLowerCase().contains(needle);

/// The folders of [rows] in the order the list shows them (the one with the
/// most pressing agent first), for the chips. [unknownLabel] names the group
/// of agents whose folder Herdr did not report.
List<HerdrFolderEntry> herdrFolderEntries(
  List<HerdrAgentRow> rows, {
  required String unknownLabel,
}) {
  final paths = <String?>[];
  final best = <String?, int>{};
  for (final row in rows) {
    final key = herdrFolderOf(row);
    if (!paths.contains(key)) paths.add(key);
    final rank = _rank(row.status);
    if (!best.containsKey(key) || rank < best[key]!) best[key] = rank;
  }
  final labels = herdrFolderLabels(paths.whereType<String>());
  final order = {for (var i = 0; i < paths.length; i++) paths[i]: i};
  paths.sort((a, b) {
    // The unknown folder is always last.
    if (a == null || b == null) return a == null ? (b == null ? 0 : 1) : -1;
    final byRank = best[a]!.compareTo(best[b]!);
    return byRank != 0 ? byRank : order[a]!.compareTo(order[b]!);
  });
  return [
    for (final path in paths)
      HerdrFolderEntry(
        path: path,
        label: path == null ? unknownLabel : labels[path]!,
      ),
  ];
}

/// The list for [rows] (every agent, any state): narrowed by [filter],
/// [folder] (a path from [herdrFolderEntries], null for all) and [query]
/// (agent, kind, folder or workspace name); the finished agents split off.
HerdrFlatList herdrFlatList(
  List<HerdrAgentRow> rows, {
  required String unknownLabel,
  HerdrStatusFilter filter = HerdrStatusFilter.all,
  String? folder,
  String query = '',
}) {
  final needle = query.trim().toLowerCase();
  final entries = herdrFolderEntries(rows, unknownLabel: unknownLabel);
  final kept = <HerdrAgentRow>[];
  for (final row in rows) {
    if (!filter.matches(row.status)) continue;
    final path = herdrFolderOf(row);
    if (folder != null && path != folder) continue;
    if (needle.isNotEmpty &&
        !(_hit(row.title, needle) ||
            _hit(row.pane.agent, needle) ||
            _hit(path, needle) ||
            _hit(row.workspaceLabel, needle))) {
      continue;
    }
    kept.add(row);
  }
  final order = {for (var i = 0; i < kept.length; i++) kept[i].paneId: i};
  kept.sort((a, b) {
    final byRank = _rank(a.status).compareTo(_rank(b.status));
    return byRank != 0 ? byRank : order[a.paneId]!.compareTo(order[b.paneId]!);
  });
  final groups = <HerdrFolderGroup>[];
  for (final entry in entries) {
    final inFolder = [
      for (final row in kept)
        if (row.status != HerdrAgentStatus.done &&
            herdrFolderOf(row) == entry.path)
          row,
    ];
    if (inFolder.isNotEmpty) {
      groups.add(HerdrFolderGroup(folder: entry, rows: inFolder));
    }
  }
  return HerdrFlatList(
    needsYou: [
      for (final row in kept)
        if (row.status == HerdrAgentStatus.blocked) row,
    ],
    groups: groups,
    done: [
      for (final row in kept)
        if (row.status == HerdrAgentStatus.done) row,
    ],
  );
}
