// Hub del módulo SSH de una instancia: estado de configuración y accesos a
// terminal, archivos (SFTP) y edición de credenciales. Entrada desde el drawer.
import 'package:hermes_android/core/design/hicons.dart';
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../main.dart';
import '../browser/ssh_terminal_link.dart';
import '../services/connection_manager.dart';
import '../services/ssh_manager.dart';
import '../theme/app_theme.dart';
import '../theme/hermes_tokens.dart';
import '../theme/terminal_palette.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/hermes_premium_ui.dart' show HermesEmptyState;
import 'sftp_browser_screen.dart';
import 'ssh_credentials_screen.dart';
import 'ssh_terminal_screen.dart';
import '../widgets/console_loader.dart';
import '../widgets/workspace/chat_workspace_host.dart'
    show ChatWorkspaceMenuEntry, ChatWorkspacePaneScope, ChatWorkspaceToolbar;
import '../widgets/workspace/workspace_panel_frame.dart';
import '../design/hermes_design.dart'
    show HermesDialogAction, HermesDialogActionStyle, showHermesDialog;
import '../feedback/feedback_policy.dart';

class SshScreen extends StatefulWidget {
  final SavedConnection connection;

  /// Set when the hub was opened from a chat: Files gets a notch back to it.
  final VoidCallback? onBackToChat;

  /// A web link tapped inside the terminal. When set (such as from the chat's
  /// Terminal workspace panel), links open in that host's browser; otherwise
  /// they open in an in-app browser with SSH loopback reach for this host.
  final ValueChanged<Uri>? onOpenLink;

  const SshScreen({
    required this.connection,
    this.onBackToChat,
    this.onOpenLink,
    super.key,
  });

  @override
  State<SshScreen> createState() => _SshScreenState();
}

class _SshScreenState extends State<SshScreen> {
  SshConfig? _config;
  bool _loading = true;

  /// The settings could not be read (secure storage failed). Desktop's
  /// pattern: say it could not be read and offer «Intentar de nuevo».
  bool _loadFailed = false;

  SshManager get _mgr =>
      context.findAncestorStateOfType<HermesAppState>()!.sshManager;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    SshConfig? cfg;
    var failed = false;
    try {
      cfg = await _mgr.loadConfig(widget.connection.id);
    } catch (e) {
      debugPrint('[ssh-screen] settings unreadable (${e.runtimeType})');
      failed = true;
    }
    if (!mounted) return;
    setState(() {
      _config = cfg;
      _loadFailed = failed;
      _loading = false;
    });
  }

  void _retryLoad() {
    setState(() {
      _loading = true;
      _loadFailed = false;
    });
    _load();
  }

  Future<void> _configure() async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => SshCredentialsScreen(connection: widget.connection),
      ),
    );
    if (saved == true) _load();
  }

  void _openTerminalLink(Uri uri) {
    final open = widget.onOpenLink;
    if (open != null) {
      open(uri);
      return;
    }
    openSshTerminalLink(
      context,
      connectionId: widget.connection.id,
      uri: uri,
      config: () => _config,
    );
  }

  void _terminal() => Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => SshTerminalScreen(
        connection: widget.connection,
        onOpenLink: _openTerminalLink,
      ),
    ),
  );

  void _sftp() => Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => SftpBrowserScreen(
        connection: widget.connection,
        onBackToChat: widget.onBackToChat,
      ),
    ),
  );

  Future<void> _forgetHostKey() async {
    await _mgr.forgetFingerprint(widget.connection.id);
    if (mounted) {
      AppFeedback.of(
        context,
      ).notify(FeedbackKind.routine, Strings.of(context).ssh2HostKeyForgotten);
    }
  }

  Future<void> _remove() async {
    final sessions = context
        .findAncestorStateOfType<HermesAppState>()!
        .sshSessions;
    final ok = await showHermesDialog<bool>(
      context: context,
      title: Strings.of(context).ssh2RemoveSsh,
      message: Strings.of(context).ssh2RemoveSshBody,
      actions: [
        HermesDialogAction(
          label: Strings.of(context).commonCancel,
          value: false,
          style: HermesDialogActionStyle.cancel,
        ),
        HermesDialogAction(
          label: Strings.of(context).ssh2Remove,
          value: true,
          style: HermesDialogActionStyle.destructive,
        ),
      ],
    );
    if (ok == true) {
      // Close the live shell too (including a connect in flight): otherwise
      // the terminal would reattach to it without credentials or App Lock.
      sessions.close(widget.connection.id);
      await _mgr.clear(widget.connection.id);
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    // In the workspace pane (v25) the Terminal tab is the terminal itself,
    // not this hub: what the hub offers around it moves to the floating
    // bar's «⋯». Without SSH set up, the hub's empty state stays.
    final inPane = ChatWorkspacePaneScope.isInPane(context);
    final config = _config;
    if (inPane && !_loading && !_loadFailed && config != null) {
      return SshTerminalScreen(
        key: ValueKey('ssh-pane-terminal-${config.target}'),
        connection: widget.connection,
        paneTitle: config.target,
        onOpenLink: _openTerminalLink,
        paneMenu: [
          ChatWorkspaceMenuEntry(
            key: const ValueKey('ssh-pane-menu-credentials'),
            label: Strings.of(context).ssh2EditCreds,
            icon: HIcons.edit_outlined,
            onSelected: _configure,
          ),
          ChatWorkspaceMenuEntry(
            key: const ValueKey('ssh-pane-menu-host-key'),
            label: Strings.of(context).ssh2ForgetHostKey,
            icon: HIcons.gpp_maybe_outlined,
            onSelected: _forgetHostKey,
          ),
          ChatWorkspaceMenuEntry(
            key: const ValueKey('ssh-pane-menu-remove'),
            label: Strings.of(context).ssh2RemoveSsh,
            icon: HIcons.delete_outline,
            onSelected: _remove,
            destructive: true,
          ),
        ],
      );
    }
    if (inPane) {
      // Nothing of a terminal's on the bar while there is none.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ChatWorkspacePaneScope.publish(context, ChatWorkspaceToolbar.none);
        }
      });
      // 1.4.3: the panel keeps the Terminal's look (its context line, its
      // card) before there is a terminal: loading, an unreadable profile
      // and, without SSH, a prompt in the terminal's own colours with the
      // one way on, instead of the SSH hub.
      return ChatWorkspacePanel(
        header: ChatWorkspacePanelHeader(
          icon: HIcons.dns_outlined,
          title: widget.connection.label,
          mono: false,
          tag: Strings.of(context).sshProtocolLabel,
        ),
        child: _loading
            ? const Center(child: ConsoleLoader.large())
            : _loadFailed
            ? _loadError()
            : _SshPanePrompt(
                label: widget.connection.label,
                onConfigure: _configure,
              ),
      );
    }
    return Scaffold(
      backgroundColor: ChatWorkspacePaneScope.backgroundOf(
        context,
        colors.background,
      ),
      // In the pane the tab already says what this is; a header pill of its
      // own sat over the first card there.
      appBar: inPane ? null : HermesAppBar(title: const Text('SSH')),
      body: _loading
          ? const Center(child: ConsoleLoader.large())
          : _loadFailed
          ? _loadError()
          : _config == null
          ? _empty(colors)
          : _configured(colors, _config!),
    );
  }

  Widget _loadError() => Center(
    child: HermesEmptyState(
      key: const ValueKey('ssh-hub-load-error'),
      icon: HIcons.error_outline,
      title: Strings.of(context).sftpUnreadableTitle,
      body: Strings.of(context).sshHubLoadError,
      primaryLabel: Strings.of(context).sftpTryAgain,
      primaryIcon: HIcons.refresh,
      onPrimary: _retryLoad,
    ),
  );

  Widget _empty(HermesThemeColors colors) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(HIcons.terminal_rounded, size: 48, color: colors.accent),
            const SizedBox(height: 16),
            Text(
              Strings.of(context).ssh2AccessTitle,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: colors.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              Strings.of(context).ssh2AccessBody(widget.connection.label),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                height: 1.45,
                color: colors.textSecondary,
              ),
            ),
            const SizedBox(height: 22),
            FilledButton.icon(
              onPressed: _configure,
              icon: const Icon(HIcons.settings_ethernet_rounded, size: 18),
              label: Text(Strings.of(context).ssh2Configure),
            ),
          ],
        ),
      ),
    );
  }

  Widget _configured(HermesThemeColors colors, SshConfig cfg) {
    return ListView(
      clipBehavior: hermesUnderHeader,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: colors.surfaceVariant.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              Icon(HIcons.dns_outlined, size: 22, color: colors.secondary),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      cfg.target,
                      style: TextStyle(
                        fontSize: 14.5,
                        fontFamily: 'monospace',
                        color: colors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      Strings.of(
                        context,
                      ).sshAuthMethodLabel(switch (cfg.method) {
                        SshAuthMethod.key => Strings.of(context).sshcPrivateKey,
                        SshAuthMethod.password => Strings.of(
                          context,
                        ).commonPassword,
                      }),
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        _action(
          colors,
          icon: HIcons.terminal_rounded,
          title: Strings.of(context).ssh2OpenTerminal,
          subtitle: Strings.of(context).ssh2OpenTerminalSub,
          onTap: _terminal,
          primary: true,
        ),
        _action(
          colors,
          icon: HIcons.folder_open_outlined,
          title: Strings.of(context).sshFilesSftp,
          subtitle: Strings.of(context).ssh2FilesSub,
          onTap: _sftp,
        ),
        _action(
          colors,
          icon: HIcons.edit_outlined,
          title: Strings.of(context).ssh2EditCreds,
          subtitle: Strings.of(context).ssh2EditCredsSub,
          onTap: _configure,
        ),
        const SizedBox(height: 8),
        const Divider(),
        _action(
          colors,
          icon: HIcons.gpp_maybe_outlined,
          title: Strings.of(context).ssh2ForgetHostKey,
          subtitle: Strings.of(context).ssh2ForgetHostKeySub,
          onTap: _forgetHostKey,
        ),
        _action(
          colors,
          icon: HIcons.delete_outline,
          title: Strings.of(context).ssh2RemoveSsh,
          subtitle: Strings.of(context).ssh2RemoveSshSub,
          onTap: _remove,
          danger: true,
        ),
      ],
    );
  }

  Widget _action(
    HermesThemeColors colors, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    bool primary = false,
    bool danger = false,
  }) {
    final tint = danger
        ? colors.error
        : primary
        ? colors.accent
        : colors.textSecondary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
            child: Row(
              children: [
                Icon(icon, size: 22, color: tint),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w500,
                          color: danger ? colors.error : colors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(HIcons.chevron_right, size: 18, color: colors.textTertiary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The Terminal panel before the connection has an SSH profile (1.4.3):
/// the terminal's own colours and type (`hermesTerminalTheme`, Desktop's
/// palette), a prompt that says what is missing and the one way on.
class _SshPanePrompt extends StatelessWidget {
  const _SshPanePrompt({required this.label, required this.onConfigure});

  final String label;
  final VoidCallback onConfigure;

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final terminal = hermesTerminalTheme(Theme.of(context));
    final mono = HermesType.text.copyWith(
      fontFamily: HermesType.monoFamily,
      color: terminal.foreground,
    );
    return ColoredBox(
      key: const ValueKey('ssh-pane-prompt'),
      color: terminal.background,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(HermesSpace.x4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '\$ ',
                    style: mono.copyWith(color: terminal.green),
                  ),
                  TextSpan(text: strings.ssh2AccessTitle),
                ],
              ),
              style: mono,
            ),
            const SizedBox(height: HermesSpace.x1),
            Text(
              strings.ssh2AccessBody(label),
              style: mono.copyWith(color: terminal.brightBlack),
            ),
            const SizedBox(height: HermesSpace.x2),
            ExcludeSemantics(
              child: SizedBox(
                width: HermesSpace.x2,
                height: HermesSpace.x4,
                child: ColoredBox(color: terminal.cursor),
              ),
            ),
            const SizedBox(height: HermesSpace.x5),
            FilledButton.icon(
              key: const ValueKey('ssh-pane-add-profile'),
              onPressed: onConfigure,
              icon: const Icon(HIcons.settings_ethernet_rounded),
              label: Text(strings.ssh2Configure),
            ),
          ],
        ),
      ),
    );
  }
}
