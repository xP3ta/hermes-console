import '../models/session.dart';

/// One row of the flattened branch tree.
class BranchTreeEntry {
  final Session session;

  /// 0 for roots.
  final int depth;

  /// Guide characters in front of the title: ancestors' continuation guides
  /// followed by this row's own stem (`├─ ` / `└─ `). Empty for roots.
  final String prefix;

  const BranchTreeEntry({
    required this.session,
    required this.depth,
    required this.prefix,
  });
}

/// The session this row was forked from, or null when it is not a fork.
///
/// `/new` and idle rotation start a new conversation (`_reset_from`), a real
/// `/branch` carries `_branched_from`, and older servers only set
/// `parent_session_id`.
String? forkParentId(Session session) {
  if (session.resetFromId?.trim().isNotEmpty == true) return null;
  final branchedFrom = session.branchedFromId?.trim();
  if (branchedFrom != null && branchedFrom.isNotEmpty) return branchedFrom;
  final parent = session.parentSessionId?.trim();
  return parent == null || parent.isEmpty ? null : parent;
}

String _lineageKey(Session session) {
  final profile = session.profile?.trim();
  final root = session.lineageRootId?.trim();
  return '${profile == null || profile.isEmpty ? 'default' : profile}::'
      '${root == null || root.isEmpty ? session.id : root}';
}

/// Rows sharing a lineage key are one conversation compressed over time.
/// Keeps the row nothing else in its lineage continues from, then the
/// freshest, in the order the kept rows first appeared.
List<Session> collapseCompressionLineages(List<Session> sessions) {
  final groups = <String, List<Session>>{};
  for (final session in sessions) {
    groups.putIfAbsent(_lineageKey(session), () => []).add(session);
  }
  final kept = <String, Session>{};
  for (final entry in groups.entries) {
    final rows = entry.value;
    if (rows.length == 1) {
      kept[entry.key] = rows.single;
      continue;
    }
    final continued = {
      for (final row in rows)
        if (row.parentSessionId?.trim().isNotEmpty == true)
          row.parentSessionId!.trim(),
    };
    final tips = rows.where((row) => !continued.contains(row.id)).toList();
    final pool = tips.isEmpty ? rows : tips;
    kept[entry.key] = pool.reduce(
      (best, row) => row.lastActivityAt > best.lastActivityAt ? row : best,
    );
  }
  final out = <Session>[];
  final emitted = <String>{};
  for (final session in sessions) {
    final key = _lineageKey(session);
    if (emitted.add(key)) out.add(kept[key]!);
  }
  return out;
}

/// Depth-first tree of [sessions] with fork children nested under their
/// parent. Children are newest first; roots are newest first unless
/// [preserveOrder] keeps the order given. Every row is emitted exactly once.
List<BranchTreeEntry> flattenSessionsWithBranches(
  List<Session> sessions, {
  bool preserveOrder = false,
}) {
  final rows = collapseCompressionLineages(sessions);
  final byKey = {for (final row in rows) _lineageKey(row): row};
  final byId = <String, Session>{};
  for (final session in sessions) {
    final keeper = byKey[_lineageKey(session)];
    if (keeper == null) continue;
    byId[session.id] = keeper;
    for (final id in session.lineageIds) {
      byId.putIfAbsent(id, () => keeper);
    }
  }
  for (final row in rows) {
    byId[row.id] = row;
  }

  Session? parentOf(Session row) {
    final parentId = forkParentId(row);
    if (parentId == null) return null;
    final parent = byId[parentId];
    if (parent == null || identical(parent, row)) return null;
    if (_lineageKey(parent) == _lineageKey(row)) return null;
    return parent;
  }

  final children = <Session, List<Session>>{};
  final roots = <Session>[];
  for (final row in rows) {
    final parent = parentOf(row);
    if (parent == null) {
      roots.add(row);
    } else {
      children.putIfAbsent(parent, () => []).add(row);
    }
  }
  int byRecency(Session a, Session b) =>
      b.lastActivityAt.compareTo(a.lastActivityAt);
  for (final list in children.values) {
    list.sort(byRecency);
  }
  // A root ranks by the freshest activity anywhere in its subtree, so an old
  // conversation with a live branch is not buried (Desktop folds group
  // recency the same way). The visiting set keeps a parent cycle finite.
  final subtreeAt = <Session, double>{};
  double freshest(Session row, Set<Session> visiting) {
    final known = subtreeAt[row];
    if (known != null) return known;
    if (!visiting.add(row)) return row.lastActivityAt;
    var best = row.lastActivityAt;
    for (final kid in children[row] ?? const <Session>[]) {
      final at = freshest(kid, visiting);
      if (at > best) best = at;
    }
    visiting.remove(row);
    return subtreeAt[row] = best;
  }

  if (!preserveOrder) {
    roots.sort((a, b) => freshest(b, {}).compareTo(freshest(a, {})));
  }

  final out = <BranchTreeEntry>[];
  final seen = <Session>{};
  void walk(Session row, int depth, String guide, String stem) {
    if (!seen.add(row)) return;
    out.add(BranchTreeEntry(session: row, depth: depth, prefix: guide + stem));
    final kids = children[row] ?? const <Session>[];
    final childGuide = depth == 0
        ? ''
        : guide + (stem.startsWith('└') ? '   ' : '│  ');
    for (var i = 0; i < kids.length; i++) {
      walk(
        kids[i],
        depth + 1,
        childGuide,
        i == kids.length - 1 ? '└─ ' : '├─ ',
      );
    }
  }

  for (final root in roots) {
    walk(root, 0, '', '');
  }
  // Parent cycles leave rows without a root: emit them rather than drop them.
  for (final row in rows) {
    if (!seen.contains(row)) walk(row, 0, '', '');
  }
  return out;
}

/// The family of [id]: the root of its fork chain and every descendant, from
/// the rows already loaded. Empty when [id] is not among [sessions].
List<Session> branchFamily(List<Session> sessions, String id) {
  final rows = collapseCompressionLineages(sessions);
  final byId = <String, Session>{};
  final byKey = {for (final row in rows) _lineageKey(row): row};
  for (final session in sessions) {
    final keeper = byKey[_lineageKey(session)];
    if (keeper == null) continue;
    byId[session.id] = keeper;
    for (final lineageId in session.lineageIds) {
      byId.putIfAbsent(lineageId, () => keeper);
    }
  }
  for (final row in rows) {
    byId[row.id] = row;
  }
  final start = byId[id];
  if (start == null) return const [];

  Session? parentOf(Session row) {
    final parent = byId[forkParentId(row) ?? ''];
    if (parent == null || identical(parent, row)) return null;
    if (_lineageKey(parent) == _lineageKey(row)) return null;
    return parent;
  }

  var root = start;
  final climbed = <Session>{start};
  while (true) {
    final parent = parentOf(root);
    if (parent == null || !climbed.add(parent)) break;
    root = parent;
  }
  final family = <Session>{root};
  var grew = true;
  while (grew) {
    grew = false;
    for (final row in rows) {
      if (family.contains(row)) continue;
      final parent = parentOf(row);
      if (parent != null && family.contains(parent)) {
        family.add(row);
        grew = true;
      }
    }
  }
  return [
    for (final row in rows)
      if (family.contains(row)) row,
  ];
}
