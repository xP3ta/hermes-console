// Hub del módulo SSH de una instancia: estado de configuración y accesos a
// terminal, archivos (SFTP) y edición de credenciales. Entrada desde el drawer.
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../main.dart';
import '../services/connection_manager.dart';
import '../services/ssh_manager.dart';
import '../theme/app_theme.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/hermes_notice.dart';
import 'sftp_browser_screen.dart';
import 'ssh_credentials_screen.dart';
import 'ssh_terminal_screen.dart';

class SshScreen extends StatefulWidget {
  final SavedConnection connection;
  const SshScreen({required this.connection, super.key});

  @override
  State<SshScreen> createState() => _SshScreenState();
}

class _SshScreenState extends State<SshScreen> {
  SshConfig? _config;
  bool _loading = true;

  SshManager get _mgr =>
      context.findAncestorStateOfType<HermesAppState>()!.sshManager;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final cfg = await _mgr.loadConfig(widget.connection.id);
    if (!mounted) return;
    setState(() {
      _config = cfg;
      _loading = false;
    });
  }

  Future<void> _configure() async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => SshCredentialsScreen(connection: widget.connection),
      ),
    );
    if (saved == true) _load();
  }

  void _terminal() => Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SshTerminalScreen(connection: widget.connection)));

  void _sftp() => Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SftpBrowserScreen(connection: widget.connection)));

  Future<void> _forgetHostKey() async {
    await _mgr.forgetFingerprint(widget.connection.id);
    if (mounted) {
      HermesNotice.of(context).showSnackBar(
        SnackBar(content: Text(Strings.of(context).ssh2HostKeyForgotten)),
        kind: HermesNoticeKind.success,
      );
    }
  }

  Future<void> _remove() async {
    final colors = Theme.of(context).hermes;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(Strings.of(context).ssh2RemoveSsh),
        content: Text(Strings.of(context).ssh2RemoveSshBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(Strings.of(context).commonCancel)),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: colors.error),
            child: Text(Strings.of(context).ssh2Remove, style: TextStyle(color: colors.onAccent)),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _mgr.clear(widget.connection.id);
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Scaffold(
      backgroundColor: colors.background,
      appBar: HermesAppBar(title: const Text('SSH')),
      body: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : _config == null
              ? _empty(colors)
              : _configured(colors, _config!),
    );
  }

  Widget _empty(HermesThemeColors colors) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.terminal_rounded, size: 48, color: colors.accent),
            const SizedBox(height: 16),
            Text(Strings.of(context).ssh2AccessTitle,
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: colors.textPrimary)),
            const SizedBox(height: 8),
            Text(
              Strings.of(context).ssh2AccessBody(widget.connection.label),
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 13, height: 1.45, color: colors.textSecondary),
            ),
            const SizedBox(height: 22),
            FilledButton.icon(
              onPressed: _configure,
              icon: const Icon(Icons.settings_ethernet_rounded, size: 18),
              label: Text(Strings.of(context).ssh2Configure),
            ),
          ],
        ),
      ),
    );
  }

  Widget _configured(HermesThemeColors colors, SshConfig cfg) {
    return ListView(
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
              Icon(Icons.dns_outlined, size: 22, color: colors.secondary),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(cfg.target,
                        style: TextStyle(
                            fontSize: 14.5,
                            fontFamily: 'monospace',
                            color: colors.textPrimary)),
                    const SizedBox(height: 3),
                    Text(Strings.of(context).sshAuthMethodLabel(cfg.method.label.toLowerCase()),
                        style: TextStyle(
                            fontSize: 12, color: colors.textSecondary)),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        _action(colors,
            icon: Icons.terminal_rounded,
            title: Strings.of(context).ssh2OpenTerminal,
            subtitle: Strings.of(context).ssh2OpenTerminalSub,
            onTap: _terminal,
            primary: true),
        _action(colors,
            icon: Icons.folder_open_outlined,
            title: Strings.of(context).sshFilesSftp,
            subtitle: Strings.of(context).ssh2FilesSub,
            onTap: _sftp),
        _action(colors,
            icon: Icons.edit_outlined,
            title: Strings.of(context).ssh2EditCreds,
            subtitle: Strings.of(context).ssh2EditCredsSub,
            onTap: _configure),
        const SizedBox(height: 8),
        const Divider(),
        _action(colors,
            icon: Icons.gpp_maybe_outlined,
            title: Strings.of(context).ssh2ForgetHostKey,
            subtitle: Strings.of(context).ssh2ForgetHostKeySub,
            onTap: _forgetHostKey),
        _action(colors,
            icon: Icons.delete_outline,
            title: Strings.of(context).ssh2RemoveSsh,
            subtitle: Strings.of(context).ssh2RemoveSshSub,
            onTap: _remove,
            danger: true),
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
                      Text(title,
                          style: TextStyle(
                              fontSize: 14.5,
                              fontWeight: FontWeight.w500,
                              color:
                                  danger ? colors.error : colors.textPrimary)),
                      const SizedBox(height: 2),
                      Text(subtitle,
                          style: TextStyle(
                              fontSize: 12, color: colors.textSecondary)),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, size: 18, color: colors.textDisabled),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
