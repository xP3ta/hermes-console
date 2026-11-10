// «Sessions» for the terminal (1.4.0): what already runs on the server, to
// attach the terminal to it. Tabs: Shell (stay as it is), tmux (its
// sessions), Herdr (its named sessions and the default session's
// workspaces, with their state) and Recent. Everything is read first, with
// the app's own read-only commands; choosing a row only returns the line to
// type, built from a validated id or name.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../design/modal.dart';
import '../services/herdr_status.dart';
import '../services/terminal_sessions.dart';
import '../theme/app_theme.dart';
import '../theme/hermes_tokens.dart';
import 'console_loader.dart';
import 'herdr_agents_widgets.dart';

/// What the user chose: the line to type and how to remember it.
class TerminalSessionChoice {
  const TerminalSessionChoice(this.line, this.recent);

  final String line;
  final TerminalRecent recent;
}

/// Shows the sheet. Returns the choice, or null (closed, or «Shell»).
Future<TerminalSessionChoice?> showSshSessionsSheet(
  BuildContext context, {
  required SshRemoteRunner run,
  TerminalRecentStore? recents,
}) => showHermesSurface<TerminalSessionChoice>(
  context: context,
  surfaceKey: const ValueKey('ssh-sessions-sheet'),
  maxWidth: 520,
  maxHeightFactor: 0.9,
  scrim: HermesScrim.sheet,
  builder: (context) => _SessionsSheet(run: run, recents: recents),
);

enum _Tab { shell, tmux, herdr, recent }

class _SessionsSheet extends StatefulWidget {
  const _SessionsSheet({required this.run, required this.recents});

  final SshRemoteRunner run;
  final TerminalRecentStore? recents;

  @override
  State<_SessionsSheet> createState() => _SessionsSheetState();
}

class _SessionsSheetState extends State<_SessionsSheet> {
  _Tab _tab = _Tab.shell;
  TmuxListing? _tmux;
  HerdrListing? _herdr;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  void _reload() {
    setState(() {
      _tmux = null;
      _herdr = null;
    });
    unawaited(_load());
  }

  Future<void> _load() async {
    final results = await Future.wait<Object>([
      loadTmuxSessions(widget.run),
      loadHerdrSessions(widget.run),
    ]);
    if (!mounted) return;
    setState(() {
      _tmux = results[0] as TmuxListing;
      _herdr = results[1] as HerdrListing;
    });
  }

  void _choose(String? line, TerminalRecent recent) {
    if (line == null) return;
    Navigator.of(context).pop(TerminalSessionChoice(line, recent));
  }

  String _tabLabel(Strings strings, _Tab tab) => switch (tab) {
    _Tab.shell => strings.hdpTabShell,
    _Tab.tmux => strings.hdpTabTmux,
    _Tab.herdr => strings.hdpTabHerdr,
    _Tab.recent => strings.hdpTabRecent,
  };

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        HermesSurfaceHeader(title: strings.hdpSessionsTitle, showClose: true),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: HermesSpace.x4),
          // Wraps instead of scrolling: no tab hides off the edge.
          child: Wrap(
            spacing: HermesSpace.x2,
            runSpacing: HermesSpace.x1,
            children: [
              for (final tab in _Tab.values)
                HerdrGelButton(
                  key: ValueKey('ssh-sessions-tab-${tab.name}'),
                  selected: tab == _tab,
                  onTap: () => setState(() => _tab = tab),
                  child: Text(_tabLabel(strings, tab)),
                ),
            ],
          ),
        ),
        const SizedBox(height: HermesSpace.x2),
        Flexible(
          child: ListView(
            key: ValueKey('ssh-sessions-list-${_tab.name}'),
            shrinkWrap: true,
            padding: const EdgeInsets.only(bottom: HermesSpace.x4),
            children: switch (_tab) {
              _Tab.shell => _shell(context),
              _Tab.tmux => _tmuxRows(context),
              _Tab.herdr => _herdrRows(context),
              _Tab.recent => _recentRows(context),
            },
          ),
        ),
      ],
    );
  }

  Widget _note(BuildContext context, String text, {Key? key}) => Padding(
    key: key,
    padding: const EdgeInsets.all(HermesSpace.x5),
    child: Text(
      text,
      style: HermesType.text.copyWith(
        color: Theme.of(context).hermes.textSecondary,
      ),
    ),
  );

  Widget _loading() => const Padding(
    padding: EdgeInsets.all(HermesSpace.x6),
    child: Center(child: ConsoleLoader.medium()),
  );

  Widget _retry(BuildContext context, String text) {
    final strings = Strings.of(context);
    return Padding(
      padding: const EdgeInsets.all(HermesSpace.x5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            text,
            key: const ValueKey('ssh-sessions-failed'),
            style: HermesType.text.copyWith(
              color: Theme.of(context).hermes.textSecondary,
            ),
          ),
          const SizedBox(height: HermesSpace.x2),
          HerdrGelButton(onTap: _reload, child: Text(strings.commonRetry)),
        ],
      ),
    );
  }

  List<Widget> _shell(BuildContext context) {
    final strings = Strings.of(context);
    return [
      _SessionRow(
        key: const ValueKey('ssh-sessions-shell'),
        title: strings.hdpShellRow,
        subtitle: strings.hdpShellBody,
        onTap: () => Navigator.of(context).pop(),
      ),
    ];
  }

  List<Widget> _tmuxRows(BuildContext context) {
    final strings = Strings.of(context);
    final listing = _tmux;
    if (listing == null) return [_loading()];
    switch (listing.state) {
      case TerminalProgram.notInstalled:
        return [
          _note(
            context,
            strings.hdpNotInstalled,
            key: const ValueKey('ssh-sessions-tmux-missing'),
          ),
        ];
      case TerminalProgram.failed:
        return [_retry(context, strings.hdpSessionsFailed)];
      case TerminalProgram.ready:
        if (listing.sessions.isEmpty) {
          return [_note(context, strings.hdpNoSessions)];
        }
        return [
          for (final session in listing.sessions)
            _SessionRow(
              key: ValueKey('ssh-sessions-tmux-${session.id}'),
              title: session.name,
              subtitle: [
                strings.hdpSessionWindows(session.windows),
                if (session.attached > 0) strings.hdpSessionInUse,
              ].join(' · '),
              onTap: () => _choose(
                TerminalAttach.tmux(session.id),
                TerminalRecent(TerminalRecentKind.tmux, session.name),
              ),
            ),
        ];
    }
  }

  List<Widget> _herdrRows(BuildContext context) {
    final strings = Strings.of(context);
    final listing = _herdr;
    if (listing == null) return [_loading()];
    switch (listing.state) {
      case TerminalProgram.notInstalled:
        return [
          _note(
            context,
            strings.hdpNotInstalled,
            key: const ValueKey('ssh-sessions-herdr-missing'),
          ),
        ];
      case TerminalProgram.failed:
        return [_retry(context, strings.hdpSessionsFailed)];
      case TerminalProgram.ready:
        final rows = <Widget>[];
        for (final session in listing.sessions) {
          rows.add(
            _SessionRow(
              key: ValueKey('ssh-sessions-herdr-session-${session.name}'),
              title: session.isDefault
                  ? strings.hdpSessionDefault
                  : session.name,
              subtitle: session.running
                  ? strings.hdpSessionRunning
                  : strings.hdpSessionStopped,
              onTap: session.running
                  ? () => _choose(
                      TerminalAttach.herdrSession(
                        session.name,
                        isDefault: session.isDefault,
                        herdr: listing.herdr,
                      ),
                      TerminalRecent(
                        TerminalRecentKind.herdrSession,
                        session.name,
                      ),
                    )
                  : null,
            ),
          );
        }
        for (final workspace in listing.workspaces) {
          rows.add(
            _SessionRow(
              key: ValueKey('ssh-sessions-herdr-ws-${workspace.id}'),
              title: workspace.label,
              subtitle: [
                hdaStatusLabel(strings, workspace.status),
                if (workspace.focused) strings.hdpFocused,
              ].join(' · '),
              onTap: () => _choose(
                TerminalAttach.herdrWorkspace(
                  workspace.id,
                  herdr: listing.herdr,
                ),
                TerminalRecent(
                  TerminalRecentKind.herdrWorkspace,
                  workspace.label,
                ),
              ),
            ),
          );
        }
        return rows.isEmpty ? [_note(context, strings.hdpNoSessions)] : rows;
    }
  }

  List<Widget> _recentRows(BuildContext context) {
    final strings = Strings.of(context);
    final tmux = _tmux;
    final herdr = _herdr;
    if (tmux == null || herdr == null) return [_loading()];
    final rows = <Widget>[];
    for (final recent in widget.recents?.items ?? const <TerminalRecent>[]) {
      String? line;
      switch (recent.kind) {
        case TerminalRecentKind.tmux:
          for (final s in tmux.sessions) {
            if (s.name == recent.name) line = TerminalAttach.tmux(s.id);
          }
        case TerminalRecentKind.herdrSession:
          for (final s in herdr.sessions) {
            if (s.name == recent.name && s.running) {
              line = TerminalAttach.herdrSession(
                s.name,
                isDefault: s.isDefault,
                herdr: herdr.herdr,
              );
            }
          }
        case TerminalRecentKind.herdrWorkspace:
          for (final w in herdr.workspaces) {
            if (w.label == recent.name) {
              line = TerminalAttach.herdrWorkspace(w.id, herdr: herdr.herdr);
            }
          }
      }
      if (line == null) continue;
      final found = line;
      rows.add(
        _SessionRow(
          key: ValueKey(
            'ssh-sessions-recent-${recent.kind.name}-${recent.name}',
          ),
          title: recent.name,
          subtitle: switch (recent.kind) {
            TerminalRecentKind.tmux => strings.hdpTabTmux,
            TerminalRecentKind.herdrSession ||
            TerminalRecentKind.herdrWorkspace => strings.hdpTabHerdr,
          },
          onTap: () => _choose(found, recent),
        ),
      );
    }
    return rows.isEmpty ? [_note(context, strings.hdpNoRecent)] : rows;
  }
}

class _SessionRow extends StatelessWidget {
  const _SessionRow({
    required this.title,
    required this.subtitle,
    required this.onTap,
    super.key,
  });

  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: '$title, $subtitle',
      excludeSemantics: true,
      onTap: onTap,
      child: Opacity(
        opacity: onTap == null ? 0.55 : 1,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: HermesSpace.rowMin),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: HermesSpace.x5,
                vertical: HermesSpace.x2,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: HermesType.body.copyWith(
                            color: colors.textPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          subtitle,
                          style: HermesType.support.copyWith(
                            color: colors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (onTap != null)
                    Icon(
                      Icons.chevron_right_rounded,
                      color: colors.textSecondary,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
