import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../models/session.dart';
import '../theme/app_theme.dart';
import '../utils/session_branch_tree.dart';
import '../widgets/hermes_ui.dart';

/// Compact tree of one session's branch family, built from rows the app
/// already holds. Reached on demand from a session menu or its detail page.
class SessionBranchesScreen extends StatefulWidget {
  final List<Session> sessions;
  final String currentId;
  final String Function(Session session) titleOf;
  final ValueChanged<Session> onOpen;

  /// Reuses the caller's paged list read when the family may be incomplete.
  /// Resolves to the rows held after the read; the tree rebuilds from them.
  final Future<List<Session>> Function()? onLoadMore;

  const SessionBranchesScreen({
    required this.sessions,
    required this.currentId,
    required this.titleOf,
    required this.onOpen,
    this.onLoadMore,
    super.key,
  });

  /// The entry is only worth showing for a family of two or more rows.
  static bool isAvailable(List<Session> sessions, String id) =>
      branchFamily(sessions, id).length >= 2;

  @override
  State<SessionBranchesScreen> createState() => _SessionBranchesScreenState();
}

class _SessionBranchesScreenState extends State<SessionBranchesScreen> {
  late List<Session> _rows = widget.sessions;
  bool _loading = false;

  Future<void> _loadMore() async {
    final load = widget.onLoadMore;
    if (load == null || _loading) return;
    setState(() => _loading = true);
    try {
      final rows = await load();
      if (mounted) setState(() => _rows = rows);
    } catch (_) {
      // Keep what is known; the user can retry.
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final family = branchFamily(_rows, widget.currentId);
    final entries = flattenSessionsWithBranches(family);
    final current = entries.any((e) => e.session.id == widget.currentId)
        ? widget.currentId
        : null;
    return Scaffold(
      appBar: AppBar(title: Text(s.sesBranchesTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          HermesGroup(
            children: [
              for (final entry in entries)
                HermesNavRow(
                  key: ValueKey('session-branch-${entry.session.id}'),
                  icon: entry.session.id == current
                      ? Icons.radio_button_checked_rounded
                      : Icons.subdirectory_arrow_right_rounded,
                  title: '${entry.prefix}${widget.titleOf(entry.session)}',
                  subtitle: entry.session.id == current
                      ? s.sesBranchesCurrent
                      : null,
                  onTap: () => widget.onOpen(entry.session),
                ),
            ],
          ),
          if (widget.onLoadMore != null) ...[
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: _loading ? null : _loadMore,
                child: Text(
                  s.sesBranchesLoadMore,
                  style: TextStyle(color: colors.accent),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
