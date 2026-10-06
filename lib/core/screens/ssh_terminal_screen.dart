// Terminal SSH interactiva. La sesión (shell PTY + Terminal de xterm) vive en
// SshSessionService, así que PERSISTE al salir de la pantalla y al segundo plano
// (no se corta un comando largo). Esta pantalla solo se engancha al Terminal.
import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../../l10n/app_localizations.dart';
import '../../main.dart';
import '../services/connection_manager.dart';
import '../services/ssh_commands.dart';
import '../services/ssh_session_service.dart';
import '../screens/lock_screen.dart';
import '../theme/app_theme.dart';
import '../utils/ssh_error.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/hermes_premium_ui.dart';
import '../widgets/ssh_host_key_dialog.dart';
import 'sftp_browser_screen.dart';
import '../design/hermes_design.dart'
    show HermesDialogAction, HermesDialogActionStyle, showHermesFormDialog;

class SshTerminalScreen extends StatefulWidget {
  final SavedConnection connection;
  const SshTerminalScreen({required this.connection, super.key});

  @override
  State<SshTerminalScreen> createState() => _SshTerminalScreenState();
}

class _SshTerminalScreenState extends State<SshTerminalScreen> {
  SshTerminalSession? _session;
  bool _preparing = true; // App Lock + conexión inicial

  late final SshCommandsStore _cmdStore;
  List<SshQuickCommand> _commands = const [];

  SshSessionService get _svc =>
      context.findAncestorStateOfType<HermesAppState>()!.sshSessions;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  Future<void> _init() async {
    final app = context.findAncestorStateOfType<HermesAppState>()!;
    // Si ya hay una sesión viva, reengánchate sin pedir App Lock de nuevo.
    final existing = _svc.of(widget.connection.id);
    _cmdStore = SshCommandsStore(app.connManager.prefs);
    _commands = _cmdStore.load(widget.connection.id);
    if (existing != null && existing.isLive) {
      setState(() {
        _session = existing;
        _preparing = false;
      });
      return;
    }
    // Nueva sesión: App Lock (acceso shell es sensible).
    final lock = app.appLock;
    if (lock.enabled) {
      final ok = await LockScreen.verify(
        context,
        lock,
        reason: Strings.of(context).sshOpenTerminalOf(widget.connection.label),
      );
      if (!ok) {
        if (mounted) Navigator.pop(context);
        return;
      }
    }
    await _connect();
  }

  Future<void> _connect() async {
    setState(() => _preparing = true);
    final session = await _svc.connect(
      widget.connection.id,
      onHostKey: (p) => showSshHostKeyDialog(context, p),
    );
    if (!mounted) return;
    setState(() {
      _session = session;
      _preparing = false;
    });
  }

  void _runCommand(SshQuickCommand cmd) =>
      _svc.send(widget.connection.id, '${cmd.command}\n');

  void _openSftp() => Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => SftpBrowserScreen(connection: widget.connection),
    ),
  );

  Future<void> _closeSession() async {
    _svc.close(widget.connection.id);
    if (mounted) Navigator.pop(context);
  }

  Future<void> _manageCommands() async {
    final updated = await showHermesFloatingSurface<List<SshQuickCommand>>(
      context: context,
      surfaceKey: const ValueKey('ssh-quick-commands-surface'),
      maxWidth: 620,
      maxHeightFactor: 0.88,
      builder: (surfaceContext) => SizedBox(
        height: MediaQuery.sizeOf(surfaceContext).height * 0.68,
        child: _CommandsEditor(commands: List.of(_commands)),
      ),
    );
    if (updated != null) {
      await _cmdStore.save(widget.connection.id, updated);
      if (mounted) setState(() => _commands = updated);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Scaffold(
      backgroundColor: colors.background,
      appBar: HermesAppBar(
        centerTitle: false,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(Strings.of(context).sshTitle),
            Text(
              widget.connection.label,
              style: TextStyle(fontSize: 10.5, color: colors.textSecondary),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: Strings.of(context).sshFilesSftp,
            icon: const Icon(Icons.folder_open_outlined),
            onPressed: _openSftp,
          ),
          if (_session != null)
            IconButton(
              tooltip: Strings.of(context).sshCloseSession,
              icon: const Icon(Icons.power_settings_new),
              onPressed: _closeSession,
            ),
        ],
      ),
      body: _body(colors),
    );
  }

  Widget _body(HermesThemeColors colors) {
    final session = _session;
    if (_preparing || session == null) {
      return _loader(colors, Strings.of(context).sshConnecting);
    }
    return ValueListenableBuilder<SshSessionPhase>(
      valueListenable: session.phase,
      builder: (context, phase, _) {
        if (phase == SshSessionPhase.connecting) {
          return _loader(colors, Strings.of(context).sshConnecting);
        }
        if (phase == SshSessionPhase.error) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.error_outline, size: 44, color: colors.error),
                  const SizedBox(height: 16),
                  Text(
                    session.failure == null
                        ? Strings.of(context).sshConnError
                        : localizedSshError(
                            Strings.of(context),
                            session.failure!,
                          ),
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: colors.textSecondary),
                  ),
                  const SizedBox(height: 22),
                  FilledButton.icon(
                    onPressed: _connect,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: Text(Strings.of(context).sshRetry),
                  ),
                ],
              ),
            ),
          );
        }
        // ready o closed: mostramos el terminal (con scrollback). Si closed,
        // ofrecemos reconectar en la barra.
        return Column(
          children: [
            Expanded(
              child: TerminalView(
                session.terminal,
                theme: TerminalThemes.defaultTheme,
                textStyle: const TerminalStyle(fontSize: 13),
                padding: const EdgeInsets.all(8),
                autofocus: true,
                readOnly: phase == SshSessionPhase.closed,
                // U-03 (spec 028): con IME software (Gboard) el default
                // deleteDetection=false deja el editing state vacío y el
                // backspace nunca llega al terminal; y el keyboardType
                // emailAddress activa composición/autocorrección que corta
                // la entrada. visiblePassword = sin sugerencias (tradeoff:
                // sin swipe-typing, aceptable en un terminal).
                deleteDetection: true,
                keyboardType: TextInputType.visiblePassword,
              ),
            ),
            if (phase == SshSessionPhase.closed)
              _reconnectBar(colors)
            else
              _commandsBar(colors),
          ],
        );
      },
    );
  }

  Widget _loader(HermesThemeColors colors, String msg) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const CircularProgressIndicator(strokeWidth: 2),
        const SizedBox(height: 16),
        Text(msg, style: TextStyle(fontSize: 13, color: colors.textSecondary)),
      ],
    ),
  );

  Widget _reconnectBar(HermesThemeColors colors) => Container(
    width: double.infinity,
    color: colors.surface,
    padding: const EdgeInsets.all(10),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          Strings.of(context).sshSessionClosed,
          style: TextStyle(fontSize: 12.5, color: colors.textSecondary),
        ),
        const SizedBox(width: 12),
        FilledButton.icon(
          onPressed: _connect,
          icon: const Icon(Icons.refresh, size: 15),
          label: Text(Strings.of(context).sshReconnect),
          style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
        ),
      ],
    ),
  );

  Widget _commandsBar(HermesThemeColors colors) {
    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(
          top: BorderSide(color: colors.divider.withValues(alpha: 0.55)),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(8, 8, 4, 8),
      child: Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 34,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _commands.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (_, i) {
                  final c = _commands[i];
                  return ActionChip(
                    label: Text(c.label, style: const TextStyle(fontSize: 12)),
                    onPressed: () => _runCommand(c),
                    backgroundColor: colors.surfaceVariant.withValues(
                      alpha: 0.6,
                    ),
                    side: BorderSide(
                      color: colors.divider.withValues(alpha: 0.4),
                    ),
                    visualDensity: VisualDensity.compact,
                  );
                },
              ),
            ),
          ),
          IconButton(
            tooltip: Strings.of(context).sshEditQuickCmds,
            icon: Icon(Icons.tune, size: 20, color: colors.textSecondary),
            onPressed: _manageCommands,
          ),
        ],
      ),
    );
  }
}

/// Editor de comandos rápidos (bottom sheet). Devuelve la lista actualizada o
/// null si se cancela.
class _CommandsEditor extends StatefulWidget {
  final List<SshQuickCommand> commands;
  const _CommandsEditor({required this.commands});

  @override
  State<_CommandsEditor> createState() => _CommandsEditorState();
}

class _CommandsEditorState extends State<_CommandsEditor> {
  late List<SshQuickCommand> _items;

  @override
  void initState() {
    super.initState();
    _items = List.of(widget.commands);
  }

  Future<void> _edit([int? index]) async {
    final labelCtrl = TextEditingController(
      text: index != null ? _items[index].label : '',
    );
    final cmdCtrl = TextEditingController(
      text: index != null ? _items[index].command : '',
    );
    final saved = await showHermesFormDialog<bool>(
      context: context,
      title: index == null
          ? Strings.of(context).sshNewCommand
          : Strings.of(context).sshEditCommand,
      body: (context, setState) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: labelCtrl,
            decoration: InputDecoration(labelText: Strings.of(context).sshLabel),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: cmdCtrl,
            autocorrect: false,
            enableSuggestions: false,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            decoration: InputDecoration(
              labelText: Strings.of(context).sshCommand,
            ),
          ),
        ],
      ),
      actions: [
        HermesDialogAction(
          label: Strings.of(context).commonCancel,
          value: false,
          style: HermesDialogActionStyle.cancel,
        ),
        HermesDialogAction(label: Strings.of(context).commonSave, value: true),
      ],
    );
    if (saved == true) {
      final label = labelCtrl.text.trim();
      final cmd = cmdCtrl.text.trim();
      if (label.isNotEmpty && cmd.isNotEmpty) {
        setState(() {
          final entry = SshQuickCommand(label, cmd);
          if (index == null) {
            _items.add(entry);
          } else {
            _items[index] = entry;
          }
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                Strings.of(context).sshQuickCommands,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: colors.textPrimary,
                ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: () => _edit(),
                icon: const Icon(Icons.add, size: 18),
                label: Text(Strings.of(context).commonAdd),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Flexible(
            child: _items.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                      Strings.of(context).sshNoCommands,
                      style: TextStyle(
                        fontSize: 13,
                        color: colors.textTertiary,
                      ),
                    ),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: _items.length,
                    itemBuilder: (_, i) => ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text(
                        _items[i].label,
                        style: TextStyle(
                          fontSize: 14,
                          color: colors.textPrimary,
                        ),
                      ),
                      subtitle: Text(
                        _items[i].command,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          fontFamily: 'monospace',
                          color: colors.textSecondary,
                        ),
                      ),
                      onTap: () => _edit(i),
                      trailing: IconButton(
                        icon: Icon(
                          Icons.delete_outline,
                          size: 18,
                          color: colors.error.withValues(alpha: 0.8),
                        ),
                        tooltip: Strings.of(context).commonDelete,
                        onPressed: () => setState(() => _items.removeAt(i)),
                      ),
                    ),
                  ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(Strings.of(context).commonCancel),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: () => Navigator.pop(context, _items),
                  child: Text(Strings.of(context).commonSave),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
