import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../design/page.dart';
import '../models/foreign_session.dart';
import '../services/foreign_session_import_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/chat/chat_markdown_body.dart';
import '../widgets/hermes_notice.dart';
import '../widgets/hermes_premium_ui.dart';
import '../widgets/hermes_ui.dart';
import '../widgets/console_loader.dart';

/// Browse Claude Code / Codex sessions found on the server and import one
/// into Hermes history. Reached from the Conversations overflow menu.
class ForeignSessionImportScreen extends StatefulWidget {
  final HermesForeignSessionGateway gateway;
  final String? profile;

  /// Called with the Hermes session id once an import (or an existing copy)
  /// should be opened. The caller refreshes its list and navigates.
  final ValueChanged<String> onOpenSession;

  const ForeignSessionImportScreen({
    required this.gateway,
    required this.onOpenSession,
    this.profile,
    super.key,
  });

  @override
  State<ForeignSessionImportScreen> createState() =>
      _ForeignSessionImportScreenState();
}

class _ForeignSessionImportScreenState
    extends State<ForeignSessionImportScreen> {
  late final ForeignSessionImportController _controller =
      ForeignSessionImportController(
        gateway: widget.gateway,
        profile: widget.profile,
      );
  final TextEditingController _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
    _controller.loadFirst();
  }

  void _onChanged() {
    if (!mounted) return;
    if (_controller.unsupported && Navigator.of(context).canPop()) {
      // The server has no such method: nothing to show here.
      Navigator.of(context).pop();
      return;
    }
    setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _openPreview(ForeignSessionRow row) async {
    final s = Strings.of(context);
    final preview = await _controller.preview(row);
    if (!mounted) return;
    if (preview == null) {
      HermesNotice.of(context).showSnackBar(
        SnackBar(content: Text(s.fsImportPreviewFailed)),
        kind: HermesNoticeKind.error,
      );
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => _ForeignPreviewPage(
          row: row,
          preview: preview,
          controller: _controller,
          onOpenSession: widget.onOpenSession,
        ),
      ),
    );
  }

  String _titleOf(Strings s, ForeignSessionRow row) {
    if (row.title.trim().isNotEmpty) return row.title.trim();
    if (row.excerpt.trim().isNotEmpty) return row.excerpt.trim();
    return s.fsImportUntitled;
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final rows = _controller.rows;
    return Scaffold(
      appBar: AppBar(title: Text(s.fsImportTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          HermesSegmentedControl<ForeignSource?>(
            value: _controller.source,
            segments: [
              HermesSegment(value: null, label: s.fsImportSourceAll),
              HermesSegment(
                value: ForeignSource.claude,
                label: s.fsImportSourceClaude,
              ),
              HermesSegment(
                value: ForeignSource.codex,
                label: s.fsImportSourceCodex,
              ),
            ],
            onChanged: _controller.setSource,
          ),
          const SizedBox(height: 12),
          HermesSearchField(
            controller: _search,
            hintText: s.fsImportSearchHint,
            clearTooltip: s.fsImportSearchClear,
            onChanged: _controller.setQuery,
          ),
          if (_controller.host.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              s.fsImportReadingFrom(_controller.host),
              style: TextStyle(fontSize: 12, color: colors.textSecondary),
            ),
          ],
          if (_controller.unreadable > 0) ...[
            const SizedBox(height: 4),
            Text(
              s.fsImportUnreadable,
              style: TextStyle(fontSize: 12, color: colors.textSecondary),
            ),
          ],
          const SizedBox(height: 12),
          if (rows.isNotEmpty)
            HermesGroup(
              children: [
                for (final row in rows)
                  HermesNavRow(
                    icon: row.source == ForeignSource.codex
                        ? Icons.terminal_rounded
                        : Icons.chat_bubble_outline_rounded,
                    title: _titleOf(s, row),
                    subtitle: [
                      '${row.label} · ${s.fsImportTurns(row.turnCount)}',
                      ?row.cwd,
                    ].join(' · '),
                    onTap: () => _openPreview(row),
                  ),
              ],
            )
          else if (_controller.failed)
            TextButton(
              onPressed: _controller.loadFirst,
              child: Text(s.fsImportLoadFailed),
            )
          else if (!_controller.loading)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(
                s.fsImportEmpty,
                textAlign: TextAlign.center,
                style: TextStyle(color: colors.textSecondary),
              ),
            ),
          if (_controller.loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(child: ConsoleLoader.medium(showLabel: true)),
            )
          else if (_controller.hasMore)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: _controller.loadMore,
                child: Text(s.fsImportLoadMore),
              ),
            ),
        ],
      ),
    );
  }
}

class _ForeignPreviewPage extends StatelessWidget {
  final ForeignSessionRow row;
  final ForeignPreview preview;
  final ForeignSessionImportController controller;
  final ValueChanged<String> onOpenSession;

  const _ForeignPreviewPage({
    required this.row,
    required this.preview,
    required this.controller,
    required this.onOpenSession,
  });

  Future<void> _act(BuildContext context) async {
    final s = Strings.of(context);
    final existing = preview.alreadyImported;
    final String? id = existing != null
        ? await controller.open(preview)
        : await controller.import(row);
    if (!context.mounted) return;
    if (id == null) {
      // A double tap returns null while the first import is still running.
      if (!controller.importing) {
        HermesNotice.of(context).showSnackBar(
          SnackBar(content: Text(s.fsImportFailed)),
          kind: HermesNoticeKind.error,
        );
      }
      return;
    }
    // Preview page, then the list: back to where the import started.
    final navigator = Navigator.of(context);
    navigator.pop();
    navigator.pop();
    onOpenSession(id);
  }

  String _role(Strings s, String role) => switch (role) {
    'user' => s.fsImportRoleUser,
    'assistant' => s.fsImportRoleAssistant,
    _ => role,
  };

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          row.title.trim().isNotEmpty ? row.title.trim() : s.fsImportTitle,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) => Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                children: [
                  Text(
                    preview.alreadyImported != null
                        ? s.fsImportAlreadyNote
                        : s.fsImportCopyNote,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: colors.textSecondary,
                    ),
                  ),
                  if (preview.truncated) ...[
                    const SizedBox(height: 6),
                    Text(
                      s.fsImportTruncated(preview.total),
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  for (final message in preview.messages) ...[
                    Text(
                      _role(s, message.role),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: colors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    ChatMarkdownBody(
                      data: message.content,
                      selectable: false,
                      onLinkTap: (_) {},
                    ),
                    const SizedBox(height: 14),
                  ],
                ],
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: HermesActionButton(
                  key: const ValueKey('foreign-import-primary'),
                  primary: true,
                  label: preview.alreadyImported != null
                      ? s.fsImportOpen
                      : s.fsImportContinue,
                  onPressed: controller.importing ? null : () => _act(context),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
