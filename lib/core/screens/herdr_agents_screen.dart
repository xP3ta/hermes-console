// Sección «Agentes» (1.4.0): los agentes de Herdr del servidor, vivos, desde
// la conexión SSH que la app ya tiene. Lista (los que te esperan primero),
// detalle con su salida, instrucción y teclas, alta de un agente nuevo y UNA
// línea discreta cuando Herdr no está instalado. No abre puertos, no instala
// nada y no toca el pty del terminal.
import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../../main.dart';
import '../config/feature_flags.dart';
import '../design/hermes_design.dart'
    show
        HermesAction,
        HermesDialogAction,
        HermesDialogActionStyle,
        HermesMenuButton,
        HermesOption,
        showHermesDialog,
        showHermesOptions;
import '../feedback/feedback_policy.dart';
import '../services/agent_processes.dart';
import '../services/connection_manager.dart';
import '../services/herdr_agents.dart';
import '../services/herdr_flat_list.dart';
import '../services/herdr_folders.dart';
import '../services/herdr_session_files.dart';
import '../services/herdr_status.dart';
import '../services/ssh_manager.dart';
import '../services/ssh_session_kind.dart';
import '../services/ssh_session_service.dart';
import '../services/terminal_sessions.dart';
import '../theme/app_theme.dart';
import '../theme/hermes_tokens.dart';
import '../utils/responsive.dart';
import '../utils/short_server_path.dart';
import '../widgets/console_loader.dart';
import '../widgets/herdr_agent_detail.dart';
import '../widgets/herdr_agents_widgets.dart';
import '../widgets/herdr_create_sheet.dart';
import '../widgets/herdr_flat_widgets.dart';
import '../widgets/herdr_list_widgets.dart';
import '../widgets/hermes_premium_ui.dart'
    show HermesEmptyState, HermesSearchField;
import '../widgets/ssh_host_key_dialog.dart';
import '../widgets/workspace/chat_workspace_host.dart'
    show ChatWorkspacePaneScope, ChatWorkspaceToolbar;
import 'lock_screen.dart';
import 'ssh_credentials_screen.dart';
import 'ssh_terminal_screen.dart';

/// Where the commands of the Agents section go: the live terminal's SSH
/// client when there is one, else a client of its own (opened on demand,
/// host key asked like the terminal does, closed with the section). Each
/// command runs on a fresh `execute` channel with the time and size limits
/// of [SshSessionService.runRemote].
class HerdrAgentsTransport {
  HerdrAgentsTransport({required this.open, required this.shared});

  /// Opens and authenticates a client of its own.
  final Future<SSHClient> Function() open;

  /// The terminal session's client, when it is ready.
  final SSHClient? Function() shared;

  SSHClient? _own;
  Future<SSHClient>? _opening;
  bool _closed = false;

  Future<SSHClient> _client() async {
    final live = shared();
    if (live != null) return live;
    final own = _own;
    if (own != null) return own;
    return _opening ??= open().then(
      (client) {
        _opening = null;
        if (_closed) {
          client.close();
          throw StateError('transport closed');
        }
        return _own = client;
      },
      onError: (Object e) {
        _opening = null;
        throw e;
      },
    );
  }

  Future<SshRemoteResult> run(String command) async {
    final client = await _client();
    try {
      return await SshSessionService.runRemote(client, command);
    } catch (e) {
      // A client of our own that failed is dropped: the next command opens
      // a new one. The terminal's is not ours to close.
      if (identical(client, _own) && e is! TimeoutException) {
        _own = null;
        client.close();
      }
      rethrow;
    }
  }

  /// An SFTP channel on the same connection, for the folder picker.
  Future<SftpClient> sftp() async => (await _client()).sftp();

  void close() {
    _closed = true;
    _own?.close();
    _own = null;
  }
}

/// The wiring: SSH set up, App Lock, transport and controller; the section
/// itself is [HerdrAgentsView].
class HerdrAgentsScreen extends StatefulWidget {
  const HerdrAgentsScreen({
    required this.connection,
    this.embedded = false,
    this.runner,
    this.onPickServer,
    this.onClose,
    super.key,
  });

  final SavedConnection connection;

  /// Leaves the section (a back arrow in its header); null when the section
  /// is a top-level destination and has nowhere to go back to.
  final VoidCallback? onClose;

  /// Opens the choice of server; null when there is only one (no ▾).
  final VoidCallback? onPickServer;

  /// Replaces the SSH transport (tests): where every command goes.
  @visibleForTesting
  final SshRemoteRunner? runner;

  /// Under another screen's app bar (the Agents section): no title of its
  /// own, only the server's name.
  final bool embedded;

  @override
  State<HerdrAgentsScreen> createState() => _HerdrAgentsScreenState();
}

class _HerdrAgentsScreenState extends State<HerdrAgentsScreen> {
  HerdrAgentsController? _controller;
  HerdrAgentsTransport? _transport;
  AgentProcessScanner? _scanner;
  HerdrFolderSource? _folders;
  bool _loading = true;
  bool _configured = false;
  bool _loadFailed = false;

  /// The App Lock check was refused: a tab cannot pop itself like the
  /// terminal's route, so it says so and offers to ask again.
  bool _denied = false;

  HermesAppState get _app => context.findAncestorStateOfType<HermesAppState>()!;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  Future<void> _init() async {
    final app = _app;
    final strings = Strings.of(context);
    SshConfig? config;
    try {
      config = await app.sshManager.loadConfig(widget.connection.id);
    } catch (e) {
      debugPrint('[herdr-agents] SSH settings unreadable (${e.runtimeType})');
      if (mounted) {
        setState(() {
          _loading = false;
          _loadFailed = true;
        });
      }
      return;
    }
    if (!mounted) return;
    if (config == null) {
      setState(() {
        _loading = false;
        _configured = false;
      });
      return;
    }
    // Agents can type into code agents on the server: same gate as the
    // terminal, which a live session already passed.
    final live = app.sshSessions.of(widget.connection.id);
    final lock = app.appLock;
    if ((live == null || !live.isLive) && lock.enabled) {
      final ok = await LockScreen.verify(
        context,
        lock,
        reason: strings.hdaUnlockReason(widget.connection.label),
      );
      if (!mounted) return;
      if (!ok) {
        setState(() {
          _loading = false;
          _denied = true;
        });
        return;
      }
    }
    final id = widget.connection.id;
    final transport = HerdrAgentsTransport(
      open: () async {
        final client = await app.sshManager.connect(
          id,
          onHostKey: (p) async =>
              mounted ? await showSshHostKeyDialog(context, p) : false,
        );
        await client.authenticated.timeout(const Duration(seconds: 15));
        return client;
      },
      shared: () {
        final session = app.sshSessions.of(id);
        return session != null && session.phase.value == SshSessionPhase.ready
            ? session.client
            : null;
      },
    );
    final SshRemoteRunner run = widget.runner ?? transport.run;
    final controller = HerdrAgentsController(
      run: run,
      store: PrefsHerdrAgentsStore(app.connManager.prefs, id),
      serverId: id,
      sessionFiles: widget.runner == null
          ? SftpSessionFiles(transport.sftp)
          : null,
    );
    _scanner?.dispose();
    setState(() {
      _transport = transport;
      _folders = widget.runner == null
          ? SftpFolderSource(transport.sftp)
          : null;
      _scanner = AgentProcessScanner(run: run);
      _controller = controller;
      _configured = true;
      _loading = false;
    });
  }

  Future<void> _configure() async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => SshCredentialsScreen(connection: widget.connection),
      ),
    );
    if (saved == true && mounted) {
      setState(() => _loading = true);
      await _init();
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    _scanner?.dispose();
    _transport?.close();
    super.dispose();
  }

  /// «Open in terminal»: the line goes into the user's terminal, a fresh one
  /// when there is none. A terminal that is already open may be running
  /// Herdr, an editor or anything else that would read the text as input
  /// (and a profile of kind Herdr or tmux starts that program itself), so the
  /// user decides: type it there, or copy it.
  Future<void> _openTerminal(String line) async {
    final app = _app;
    final id = widget.connection.id;
    final session = app.sshSessions.of(id);
    // A profile set to open Herdr or tmux types its program right after
    // connecting: a line typed next would land inside it.
    var multiplexer = false;
    try {
      multiplexer =
          await app.sshManager.loadSessionKind(id) != SshSessionKind.shell;
    } catch (_) {
      multiplexer = true;
    }
    if (!mounted) return;
    if ((session != null && session.isLive) || multiplexer) {
      final strings = Strings.of(context);
      final choice = await showHermesDialog<String>(
        context: context,
        surfaceKey: const ValueKey('hda-terminal-live'),
        title: strings.hdpTerminalLiveTitle,
        message: strings.hdpTerminalLiveBody,
        actions: [
          HermesDialogAction(
            key: const ValueKey('hda-terminal-cancel'),
            label: strings.commonCancel,
            value: 'cancel',
            style: HermesDialogActionStyle.cancel,
          ),
          HermesDialogAction(
            key: const ValueKey('hda-terminal-copy'),
            label: strings.hdpTerminalCopy,
            value: 'copy',
          ),
          HermesDialogAction(
            key: const ValueKey('hda-terminal-type'),
            label: strings.hdpTerminalType,
            value: 'type',
          ),
        ],
      );
      if (!mounted || choice == null || choice == 'cancel') return;
      if (choice == 'copy') {
        final feedback = AppFeedback.of(context);
        final copied = strings.sshCopied;
        await Clipboard.setData(ClipboardData(text: line));
        feedback.notify(FeedbackKind.routine, copied);
        return;
      }
    }
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => SshTerminalScreen(
          connection: widget.connection,
          initialCommand: line,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final inPane = ChatWorkspacePaneScope.isInPane(context);
    if (inPane) {
      // Nothing of a terminal's on the bar for this tab.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ChatWorkspacePaneScope.publish(context, ChatWorkspaceToolbar.none);
        }
      });
    }
    final controller = _controller;
    final Widget body;
    if (_loading) {
      body = const Center(child: ConsoleLoader.large());
    } else if (_loadFailed) {
      body = Center(
        child: HermesEmptyState(
          icon: Icons.error_outline,
          title: strings.sftpUnreadableTitle,
          body: strings.sshHubLoadError,
          primaryLabel: strings.sftpTryAgain,
          primaryIcon: Icons.refresh,
          onPrimary: () {
            setState(() {
              _loading = true;
              _loadFailed = false;
            });
            _init();
          },
        ),
      );
    } else if (_denied) {
      body = Center(
        child: HermesEmptyState(
          icon: Icons.lock_outline,
          title: strings.hdaTitle,
          body: strings.hdaUnlockReason(widget.connection.label),
          primaryLabel: strings.commonRetry,
          primaryIcon: Icons.refresh,
          onPrimary: () {
            setState(() {
              _loading = true;
              _denied = false;
            });
            _init();
          },
        ),
      );
    } else if (!_configured || controller == null) {
      body = Center(
        child: HermesEmptyState(
          icon: Icons.terminal_rounded,
          title: strings.ssh2AccessTitle,
          body: strings.ssh2AccessBody(widget.connection.label),
          primaryLabel: strings.ssh2Configure,
          primaryIcon: Icons.settings_ethernet_rounded,
          onPrimary: _configure,
        ),
      );
    } else {
      body = HerdrAgentsView(
        controller: controller,
        server: widget.connection.label,
        processes: _scanner,
        folders: _folders,
        onOpenTerminal: _openTerminal,
        showTitle: !widget.embedded,
        onPickServer: widget.onPickServer,
        onClose: widget.onClose,
      );
    }
    return Scaffold(
      backgroundColor: ChatWorkspacePaneScope.backgroundOf(
        context,
        colors.background,
      ),
      body: SafeArea(child: body),
    );
  }
}

/// Types a line into the user's terminal (see [HerdrAgentsScreen]): the
/// view asks, the screen that owns the SSH session decides how.
typedef HerdrOpenTerminal = Future<void> Function(String line);

/// The section for one server: follows the screen's visibility and the
/// app's foreground, so the server is asked only while it can be seen.
class HerdrAgentsView extends StatefulWidget {
  const HerdrAgentsView({
    required this.controller,
    required this.server,
    this.processes,
    this.folders,
    this.onOpenTerminal,
    this.showTitle = true,
    this.onPickServer,
    this.onClose,
    super.key,
  });

  final HerdrAgentsController controller;

  /// A back arrow in the header (the section was pushed as a page).
  final VoidCallback? onClose;

  /// Opens the choice of server (the name in the header gets a ▾); null
  /// leaves the name alone.
  final VoidCallback? onPickServer;

  /// Looks for code agents running without Herdr when there is no Herdr (or
  /// no server of its) to ask; null leaves that line out.
  final AgentProcessScanner? processes;

  /// Where the folder picker reads; null leaves only the typed path.
  final HerdrFolderSource? folders;

  /// Opens the terminal with a line typed in it; null hides every «Open in
  /// terminal» action.
  final HerdrOpenTerminal? onOpenTerminal;

  /// The «Agents» title over the server's name; off under an app bar that
  /// already says it.
  final bool showTitle;

  /// What the user calls the server (the saved connection's name).
  final String server;

  @override
  State<HerdrAgentsView> createState() => _HerdrAgentsViewState();
}

class _HerdrAgentsViewState extends State<HerdrAgentsView>
    with WidgetsBindingObserver {
  bool _foreground = true;
  bool _visible = true;
  bool _doneOpen = false;
  bool _shellsOpen = false;
  final TextEditingController _search = TextEditingController();

  HerdrAgentsController get _c => widget.controller;

  /// Two panes (list and the open agent) from the tablet width (the unfolded
  /// Fold, about 700 dp, is one); below it the list and the agent take the
  /// screen in turn.
  static const double wideFrom = Responsive.tabletBreakpoint;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _c.peekScreens = true;
    _c.addListener(_onChange);
    _scheduleSync();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible =
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.of(context)?.isCurrent ?? true);
    _scheduleSync();
  }

  @override
  void didUpdateWidget(HerdrAgentsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller
        ..removeListener(_onChange)
        ..peekScreens = false
        ..setActive(false);
      widget.controller.peekScreens = true;
      widget.controller.addListener(_onChange);
      _scheduleSync();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _foreground = true;
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        _foreground = false;
      case AppLifecycleState.inactive:
        return;
    }
    // At once, not after a frame: a backgrounded app draws none, and the
    // reads must stop with it.
    _c.setActive(_foreground && _visible);
  }

  /// Never inside a build: asking the server notifies the controller's
  /// listeners, and this view is one of them.
  void _scheduleSync() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _c.setActive(_foreground && _visible);
      _syncProcesses();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _c.removeListener(_onChange);
    _c.setActive(false);
    _search.dispose();
    super.dispose();
  }

  /// Code agents outside Herdr are only looked for when Herdr has nothing to
  /// show: not installed, no server, or no agent.
  void _syncProcesses() {
    final scanner = widget.processes;
    if (scanner == null) return;
    final phase = _c.phase;
    final nothingInHerdr =
        phase == HerdrAgentsPhase.notInstalled ||
        phase == HerdrAgentsPhase.serverStopped ||
        (phase == HerdrAgentsPhase.ready && _c.allRows.isEmpty);
    if (nothingInHerdr) {
      unawaited(scanner.scan());
    } else if (phase == HerdrAgentsPhase.probing) {
      scanner.reset();
    }
  }

  void _onChange() {
    if (!mounted) return;
    _syncProcesses();
    final blocked = _c.newlyBlocked;
    if (blocked.isNotEmpty) {
      _c.newlyBlocked = const {};
      final strings = Strings.of(context);
      final names = [
        for (final row in _c.allRows)
          if (blocked.contains(row.paneId)) row.title,
      ];
      if (names.isNotEmpty) {
        AppFeedback.of(
          context,
        ).notify(FeedbackKind.routine, strings.hdaBlockedTitle(names.first));
      }
    }
    setState(() {});
  }

  /// A failure the user must know about. Routine successes say nothing (the
  /// row and the screen show them), so nothing floats over the header.
  void _error(String message) =>
      AppFeedback.of(context).notify(FeedbackKind.error, message);

  Future<void> _howToInstall() async {
    final installed = await showHerdrInstallSheet(context);
    if (installed == true) await _c.recheck();
  }

  Future<void> _new() async {
    final strings = Strings.of(context);
    final choice = await showHerdrCreateSheet(
      context,
      controller: _c,
      server: widget.server,
      folders: widget.folders,
    );
    if (choice == null || !mounted) return;
    final confirmed = await confirmHerdrCreate(
      context,
      choice: choice,
      server: widget.server,
    );
    if (!confirmed || !mounted) return;
    final result = await _c.createAgent(
      folder: choice.folder,
      kind: choice.kind,
      label: choice.label,
    );
    if (!mounted) return;
    if (result != HerdrActionResult.ok) {
      _error(
        hdaResultMessage(strings, result, agent: choice.kind) ??
            strings.hdaErrFailed,
      );
    }
  }

  Future<bool> _sendPrompt(String text) async {
    final strings = Strings.of(context);
    final row = _c.detailRow;
    final paneId = _c.detailPaneId;
    if (row == null || paneId == null) return false;
    final result = await _c.sendPrompt(paneId, text);
    if (!mounted) return false;
    if (result == HerdrActionResult.ok) return true;
    _error(
      hdaResultMessage(
            strings,
            result,
            agent: row.title,
            problem: hdaPromptProblem(text),
          ) ??
          strings.hdaErrFailed,
    );
    return false;
  }

  Future<void> _sendKey(HerdrKey key) async {
    final strings = Strings.of(context);
    final row = _c.detailRow;
    final paneId = _c.detailPaneId;
    if (row == null || paneId == null) return;
    final result = await _c.sendKey(paneId, key);
    if (!mounted || result == HerdrActionResult.ok) return;
    _error(
      hdaResultMessage(strings, result, agent: row.title) ??
          strings.hdaErrFailed,
    );
  }

  /// «Open in terminal» for a workspace, an agent or Herdr itself: the line
  /// is built from the ids Herdr gave, validated, and typed only after the
  /// screen that owns the terminal says so.
  VoidCallback? _terminalAction(String? Function(String? herdr) line) {
    final open = widget.onOpenTerminal;
    if (open == null) return null;
    return () {
      final text = line(_c.herdrPath);
      if (text != null) unawaited(open(text));
    };
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth >= wideFrom;
        final detail = _c.detailPaneId;
        final colors = Theme.of(context).hermes;
        final Widget body;
        if (wide) {
          body = Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: (box.maxWidth * 0.38).clamp(300.0, 380.0),
                child: _list(context, selected: detail),
              ),
              VerticalDivider(
                width: 1,
                thickness: 1,
                color: HermesSurfaces.divider(colors),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: HermesSpace.inset,
                  ),
                  child: detail == null
                      ? HerdrAgentsMessage(
                          icon: Icons.smart_toy_outlined,
                          title: Strings.of(context).tplAgentsPickAgent,
                        )
                      : _detail(wide: true),
                ),
              ),
            ],
          );
        } else {
          body = detail == null
              ? _list(context)
              : Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: HermesSpace.inset,
                  ),
                  child: _detail(wide: false),
                );
        }
        return PopScope(
          // Two panes: nothing to go back to, the list is always there.
          canPop: detail == null || wide,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _c.closeDetail();
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: HermesSpace.inset),
            child: body,
          ),
        );
      },
    );
  }

  Widget _detail({required bool wide}) {
    final paneId = _c.detailPaneId;
    return HerdrAgentDetail(
      key: ValueKey('hda-detail-$paneId'),
      controller: _c,
      row: _c.detailRow,
      server: widget.server,
      // Two panes: the list is beside the agent, nothing to go back to.
      onBack: wide ? null : _c.closeDetail,
      onOpenTerminal: paneId == null
          ? null
          : _terminalAction((h) => TerminalAttach.herdrAgent(paneId, herdr: h)),
      onSend: _sendPrompt,
      onKey: _sendKey,
    );
  }

  Widget _serverName(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final name = Text(
      widget.server,
      key: const ValueKey('hda-server-name'),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: widget.showTitle
          ? HermesType.support.copyWith(color: colors.textSecondary)
          : HermesType.title.copyWith(color: colors.textPrimary),
    );
    final pick = widget.onPickServer;
    if (pick == null) return name;
    return Semantics(
      button: true,
      container: true,
      excludeSemantics: true,
      label: '${widget.server}. ${strings.agfServerPick}',
      onTap: pick,
      child: InkWell(
        key: const ValueKey('hda-server-pick'),
        onTap: pick,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: HermesSpace.tap),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(child: name),
              Icon(Icons.arrow_drop_down_rounded, color: colors.textSecondary),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context, {required double width}) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final installed = _c.phase != HerdrAgentsPhase.notInstalled;
    final canCreate = _c.phase == HerdrAgentsPhase.ready && _c.canWrite;
    final labelled = width >= 440;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: HermesSpace.inset),
      child: Row(
        children: [
          if (widget.onClose != null)
            IconButton(
              key: const ValueKey('hda-close'),
              tooltip: strings.hdaBack,
              constraints: const BoxConstraints(
                minWidth: HermesSpace.tap,
                minHeight: HermesSpace.tap,
              ),
              onPressed: widget.onClose,
              icon: const Icon(Icons.arrow_back_rounded),
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (widget.showTitle)
                  Semantics(
                    header: true,
                    child: Text(
                      strings.hdaTitle,
                      style: HermesType.title.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                _serverName(context),
                if (_c.phase == HerdrAgentsPhase.ready)
                  HerdrUpdatedAgo(at: () => _c.listUpdatedAt, now: _c.clockNow),
              ],
            ),
          ),
          if (canCreate)
            Padding(
              padding: const EdgeInsetsDirectional.only(end: HermesSpace.x1),
              child: HerdrGelButton(
                key: const ValueKey('hda-new'),
                accent: true,
                semanticLabel: strings.hdaNew,
                onTap: _new,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.add_rounded),
                    if (labelled) ...[
                      const SizedBox(width: HermesSpace.x2),
                      Flexible(child: Text(strings.hdaNew)),
                    ],
                  ],
                ),
              ),
            ),
          HermesMenuButton<String>(
            key: const ValueKey('hda-menu'),
            tooltip: strings.hdaMore,
            onSelected: (value) {
              if (value == 'install') _howToInstall();
              if (value == 'recheck') _c.recheck();
              if (value == 'refresh') _c.refresh();
            },
            actions: (_) => [
              if (installed)
                HermesAction<String>(
                  key: const ValueKey('hda-menu-refresh'),
                  value: 'refresh',
                  label: strings.commonRefresh,
                ),
              HermesAction<String>(
                key: const ValueKey('hda-menu-install'),
                value: 'install',
                label: strings.hdaHowToInstall,
              ),
              HermesAction<String>(
                key: const ValueKey('hda-menu-recheck'),
                value: 'recheck',
                label: strings.hdaRecheck,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _controls(BuildContext context, List<HerdrFolderEntry> folders) {
    final strings = Strings.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: HermesSpace.inset),
          child: HermesSearchField(
            key: const ValueKey('hda-search'),
            controller: _search,
            hintText: strings.hdpSearchHint,
            clearTooltip: strings.hdpSearchClear,
            onChanged: _c.setQuery,
          ),
        ),
        const SizedBox(height: HermesSpace.x2),
        HerdrChipsRow(
          folders: folders,
          folder: _c.folderFilter,
          filter: _c.filter,
          onAll: () {
            _c
              ..setFolderFilter(null)
              ..setFilter(HerdrStatusFilter.all);
          },
          onFolder: _c.setFolderFilter,
          onFilter: _c.setFilter,
        ),
      ],
    );
  }

  /// The line under an agent's name: what its screen says it does or asks,
  /// else its kind and how long it has been in this state.
  String? _subtitle(Strings strings, HerdrAgentRow row) {
    final activity = _c.activityFor(row);
    if (activity != null) return activity;
    final pane = row.pane;
    final kind = pane.name != null && pane.agent != pane.name
        ? pane.agent ?? ''
        : '';
    final since = _c.inState(row.paneId);
    return [
      kind,
      if (since != null) strings.hdaInState(hdaDurationText(strings, since)),
    ].where((p) => p.isNotEmpty).join(' · ');
  }

  Widget _flatRow(
    BuildContext context,
    HerdrAgentRow row, {
    String? selected,
    String? folderLabel,
  }) {
    final strings = Strings.of(context);
    final base = _subtitle(strings, row);
    final line = [
      ?folderLabel,
      if (base != null && base.isNotEmpty) base,
    ].join(' · ');
    return HerdrFlatRow(
      key: ValueKey('hda-tile-${row.paneId}'),
      row: row,
      ask: _c.askFor(row),
      subtitle: line.isEmpty ? null : line,
      inState: _c.inState(row.paneId),
      selected: row.paneId == selected,
      onTap: () => _c.openDetail(row.paneId),
    );
  }

  /// Rows with the thin line between them.
  List<Widget> _lined(List<Widget> rows) => [
    for (var i = 0; i < rows.length; i++) ...[
      if (i > 0) const HerdrRowLine(),
      rows[i],
    ],
  ];

  Widget _list(BuildContext context, {String? selected}) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final phase = _c.phase;
    final canCreate = phase == HerdrAgentsPhase.ready && _c.canWrite;
    final all = _c.allRows;
    final jobs = _c.startJobs;
    final entries = herdrFolderEntries(
      all,
      unknownLabel: strings.hdaFolderUnknown,
    );
    // A folder filter whose agents are gone shows everything again.
    final folder =
        entries.any((e) => e.path != null && e.path == _c.folderFilter)
        ? _c.folderFilter
        : null;
    final flat = herdrFlatList(
      all,
      unknownLabel: strings.hdaFolderUnknown,
      filter: _c.filter,
      folder: folder,
      query: _c.query,
    );
    final outside = widget.processes;
    final showOutside =
        outside != null &&
        (phase == HerdrAgentsPhase.notInstalled ||
            phase == HerdrAgentsPhase.serverStopped ||
            (phase == HerdrAgentsPhase.ready && all.isEmpty));
    final herdrInstalled = phase != HerdrAgentsPhase.notInstalled;
    final outsideCard = showOutside
        ? ValueListenableBuilder<Map<String, int>>(
            valueListenable: outside.found,
            builder: (_, found, _) => found.isEmpty
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: HermesSpace.inset,
                    ),
                    child: HerdrOutsideCard(
                      found: found,
                      onOpenHerdr: herdrInstalled
                          ? _terminalAction(
                              (h) => TerminalAttach.herdrSession(
                                'default',
                                isDefault: true,
                                herdr: h,
                              ),
                            )
                          : null,
                    ),
                  ),
          )
        : const SizedBox.shrink();
    final Widget content;
    switch (phase) {
      case HerdrAgentsPhase.probing:
        content = Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ConsoleLoader.large(),
              const SizedBox(height: HermesSpace.x3),
              Text(
                strings.hdaProbing,
                style: HermesType.support.copyWith(color: colors.textSecondary),
              ),
            ],
          ),
        );
      case HerdrAgentsPhase.notInstalled:
        // One quiet line; once dismissed (remembered for this server) not
        // even that.
        content = ListView(
          padding: const EdgeInsets.symmetric(horizontal: HermesSpace.inset),
          children: [
            if (_c.hintDismissed)
              HerdrAgentsMessage(
                icon: Icons.smart_toy_outlined,
                title: strings.hdaEmptyTitle,
              )
            else
              Align(
                alignment: Alignment.topCenter,
                child: HerdrInstallHintLine(
                  onHowToInstall: _howToInstall,
                  onDismiss: _c.dismissHint,
                ),
              ),
            outsideCard,
          ],
        );
      case HerdrAgentsPhase.serverStopped:
        content = ListView(
          padding: const EdgeInsets.symmetric(horizontal: HermesSpace.inset),
          children: [
            HerdrAgentsMessage(
              icon: Icons.power_settings_new_rounded,
              title: strings.hdaServerStoppedTitle,
              body: strings.hdaServerStoppedBody,
              actionLabel: strings.commonRetry,
              onAction: _c.refresh,
            ),
            outsideCard,
          ],
        );
      case HerdrAgentsPhase.connectionError:
      case HerdrAgentsPhase.timedOut:
        content = Center(
          child: HerdrAgentsMessage(
            icon: Icons.cloud_off_rounded,
            title: phase == HerdrAgentsPhase.timedOut
                ? strings.hdaTimedOut
                : strings.hdaConnectionError,
            actionLabel: strings.commonRetry,
            onAction: _c.recheck,
          ),
        );
      case HerdrAgentsPhase.ready:
        final nothing = all.isEmpty && jobs.isEmpty;
        // Workspaces with only shells: one folded line, not a heading each.
        final jobSpaces = {
          for (final job in jobs)
            if (job.workspaceId != null) job.workspaceId!,
        };
        final shells = [
          if (_c.filter == HerdrStatusFilter.all &&
              folder == null &&
              _c.query.trim().isEmpty)
            for (final workspace
                in _c.snapshot?.workspaces ?? const <HerdrWorkspace>[])
              if (!workspace.panes.any((p) => p.hasAgent) &&
                  !jobSpaces.contains(workspace.id))
                workspace,
        ];
        final needs = [
          for (final row in flat.needsYou)
            HerdrNeedItem(
              row: row,
              ask: _c.askFor(row),
              folder: _folderLabel(entries, row, strings),
            ),
        ];
        content = ListView(
          key: const ValueKey('hda-scroll'),
          children: [
            if (nothing)
              HerdrAgentsMessage(
                icon: Icons.smart_toy_outlined,
                title: strings.hdaEmptyTitle,
                body: strings.hdaEmptyBody,
                actionLabel: canCreate ? strings.hdaNew : null,
                onAction: canCreate ? _new : null,
              ),
            if (_c.stale)
              Padding(
                padding: const EdgeInsets.only(
                  left: HermesSpace.inset,
                  right: HermesSpace.inset,
                  bottom: HermesSpace.x2,
                ),
                child: Text(
                  strings.hdaStale,
                  key: const ValueKey('hda-stale'),
                  style: HermesType.caption.copyWith(color: colors.warning),
                ),
              ),
            if (needs.isNotEmpty) ...[
              HerdrNeedsStrip(items: needs, onOpen: _openRow),
              const SizedBox(height: HermesSpace.x2),
            ],
            if (jobs.isNotEmpty)
              Column(
                key: const ValueKey('hda-starting'),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: _lined([
                  for (final job in jobs)
                    HerdrStartTile(
                      key: ValueKey('hda-start-tile-${job.paneId}'),
                      job: job,
                      onRetry: () => _c.retryStart(job.paneId),
                      onDismiss: () => _c.dismissStart(job.paneId),
                      onOpenTerminal: job.workspaceId == null
                          ? null
                          : _terminalAction(
                              (h) => TerminalAttach.herdrWorkspace(
                                job.workspaceId!,
                                herdr: h,
                              ),
                            ),
                    ),
                ]),
              ),
            if (!nothing && flat.isEmpty && jobs.isEmpty)
              Padding(
                padding: const EdgeInsets.all(HermesSpace.x6),
                child: Text(
                  strings.hdpNoMatches,
                  key: const ValueKey('hda-no-matches'),
                  textAlign: TextAlign.center,
                  style: HermesType.text.copyWith(color: colors.textSecondary),
                ),
              ),
            for (final group in flat.groups)
              Column(
                key: ValueKey('hda-group-${group.folder.path ?? 'unknown'}'),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  HerdrFolderHeader(folder: group.folder),
                  ..._lined([
                    for (final row in group.rows)
                      _flatRow(context, row, selected: selected),
                  ]),
                ],
              ),
            if (flat.done.isNotEmpty)
              HerdrFoldSection(
                title: strings.agfDoneTitle(flat.done.length),
                expanded: _doneOpen,
                onToggle: () => setState(() => _doneOpen = !_doneOpen),
                children: _lined([
                  for (final row in flat.done)
                    _flatRow(
                      context,
                      row,
                      selected: selected,
                      folderLabel: _folderLabel(entries, row, strings),
                    ),
                ]),
              ),
            if (shells.isNotEmpty)
              HerdrFoldSection(
                idKey: 'shells',
                title: strings.agfShellsTitle(shells.length),
                expanded: _shellsOpen,
                onToggle: () => setState(() => _shellsOpen = !_shellsOpen),
                children: _lined([
                  for (final workspace in shells)
                    HerdrShellRow(
                      workspace: workspace,
                      folder: workspace.cwd == null
                          ? ''
                          : shortServerPath(workspace.cwd!),
                      onTap: _terminalAction(
                        (h) => TerminalAttach.herdrWorkspace(
                          workspace.id,
                          herdr: h,
                        ),
                      ),
                    ),
                ]),
              ),
            outsideCard,
          ],
        );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, box) => _header(context, width: box.maxWidth),
        ),
        if (phase == HerdrAgentsPhase.ready && all.isNotEmpty) ...[
          const SizedBox(height: HermesSpace.x2),
          _controls(context, entries),
        ],
        const SizedBox(height: HermesSpace.x2),
        Expanded(child: content),
      ],
    );
  }

  void _openRow(HerdrAgentRow row) => _c.openDetail(row.paneId);

  /// The short folder name of [row], as the headings show it.
  String _folderLabel(
    List<HerdrFolderEntry> entries,
    HerdrAgentRow row,
    Strings strings,
  ) {
    final path = herdrFolderOf(row);
    for (final entry in entries) {
      if (entry.path == path) return entry.label;
    }
    return strings.hdaFolderUnknown;
  }
}

/// Whether the Agents section has anything to open: at least one saved
/// connection with SSH set up. The dock shows its «Agents» destination only
/// when this is true (call it again when connections or SSH change).
Future<bool> agentsHomeAvailable({
  required ConnectionManager connections,
  required SshManager ssh,
}) async {
  if (!FeatureFlags.instance.agentsSection) return false;
  final servers = await agentsHomeServers(connections: connections, ssh: ssh);
  return servers.isNotEmpty;
}

/// The saved connections that have SSH set up, the active one first: the
/// servers the Agents section can read.
Future<List<SavedConnection>> agentsHomeServers({
  required ConnectionManager connections,
  required SshManager ssh,
}) async {
  final all = connections.getConnections();
  final activeId = connections.activeConnectionId.value;
  final servers = <SavedConnection>[];
  for (final connection in all) {
    try {
      if (await ssh.loadConfig(connection.id) != null) servers.add(connection);
    } catch (e) {
      debugPrint('[agents-home] SSH settings unreadable (${e.runtimeType})');
    }
  }
  servers.sort((a, b) {
    if (a.id == activeId) return b.id == activeId ? 0 : -1;
    return b.id == activeId ? 1 : 0;
  });
  return servers;
}

/// «Agents» as a section of its own (first level, no chat or workspace
/// needed): the SSH servers on top (a selector when there are several) and
/// under it the Herdr agents of the chosen server. On wide screens the list
/// and the open agent sit side by side; on a phone they take the screen in
/// turn. The same content as the workspace's Agents tab
/// ([HerdrAgentsScreen]); only the frame differs.
///
/// Mounting it from elsewhere (the dock): push [AgentsHomeScreen.route] or
/// show an [AgentsHomeScreen] as the destination's body (it brings its own
/// Scaffold and no bar of its own; `showAppBar: true`, the default, is for a
/// page pushed on the stack and puts a back arrow in the section's header).
class AgentsHomeScreen extends StatefulWidget {
  const AgentsHomeScreen({
    this.initialConnectionId,
    this.showAppBar = true,
    this.runnerFor,
    super.key,
  });

  /// Replaces the SSH transport of each server (tests).
  @visibleForTesting
  final SshRemoteRunner Function(SavedConnection server)? runnerFor;

  /// Route name for [route] and for anything that wants to compare routes.
  static const String routeName = '/agents';

  /// A route that opens the section on top of the current stack.
  static Route<void> route({String? connectionId}) => MaterialPageRoute<void>(
    settings: const RouteSettings(name: routeName),
    builder: (_) => AgentsHomeScreen(initialConnectionId: connectionId),
  );

  /// The server to start on; the active one when null or not set up.
  final String? initialConnectionId;

  /// False when the host (a dock destination) already has its own bar.
  final bool showAppBar;

  @override
  State<AgentsHomeScreen> createState() => _AgentsHomeScreenState();
}

class _AgentsHomeScreenState extends State<AgentsHomeScreen> {
  List<SavedConnection>? _servers;
  String? _selectedId;
  bool _failed = false;

  HermesAppState? get _app => context.findAncestorStateOfType<HermesAppState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final app = _app;
    if (app == null) {
      if (mounted) setState(() => _servers = const []);
      return;
    }
    try {
      final servers = await agentsHomeServers(
        connections: app.connManager,
        ssh: app.sshManager,
      );
      if (!mounted) return;
      final keep = _selectedId ?? widget.initialConnectionId;
      setState(() {
        _servers = servers;
        _failed = false;
        _selectedId = servers.any((c) => c.id == keep)
            ? keep
            : servers.isEmpty
            ? null
            : servers.first.id;
      });
    } catch (e) {
      debugPrint('[agents-home] servers unreadable (${e.runtimeType})');
      if (mounted) setState(() => _failed = true);
    }
  }

  /// Where «Configure SSH» goes: the active connection, else the first.
  SavedConnection? get _setupTarget {
    final manager = _app?.connManager;
    if (manager == null) return null;
    final all = manager.getConnections();
    final active = manager.activeConnectionId.value;
    for (final c in all) {
      if (c.id == active) return c;
    }
    return all.isEmpty ? null : all.first;
  }

  Future<void> _configure() async {
    final target = _setupTarget;
    if (target == null) return;
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => SshCredentialsScreen(connection: target),
      ),
    );
    if (saved == true && mounted) {
      setState(() => _servers = null);
      await _load();
    }
  }

  /// The server choice: the options sheet, opened from the name in the
  /// section's header.
  Future<void> _pickServer(
    List<SavedConnection> servers,
    SavedConnection current,
  ) async {
    final strings = Strings.of(context);
    final id = await showHermesOptions<String>(
      context: context,
      title: strings.tplAgentsServerLabel,
      selected: current.id,
      surfaceKey: const ValueKey('agents-servers'),
      options: [
        for (final server in servers)
          HermesOption<String>(
            key: ValueKey('agents-server-${server.id}'),
            value: server.id,
            label: server.label,
          ),
      ],
    );
    if (id != null && mounted) setState(() => _selectedId = id);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final servers = _servers;
    final Widget body;
    if (_failed) {
      body = Center(
        child: HermesEmptyState(
          icon: Icons.error_outline,
          title: strings.sftpUnreadableTitle,
          body: strings.sshHubLoadError,
          primaryLabel: strings.sftpTryAgain,
          primaryIcon: Icons.refresh,
          onPrimary: _load,
        ),
      );
    } else if (servers == null) {
      body = const Center(child: ConsoleLoader.large());
    } else if (servers.isEmpty) {
      body = Center(
        child: HermesEmptyState(
          key: const ValueKey('agents-no-ssh'),
          icon: Icons.terminal_rounded,
          title: strings.tplAgentsAddSshTitle,
          body: strings.tplAgentsAddSshBody,
          primaryLabel: _setupTarget == null ? null : strings.ssh2Configure,
          primaryIcon: Icons.settings_ethernet_rounded,
          onPrimary: _setupTarget == null ? null : _configure,
        ),
      );
    } else {
      final selected = servers.firstWhere(
        (c) => c.id == _selectedId,
        orElse: () => servers.first,
      );
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            // One section per server: switching disposes the old one, which
            // closes the client it opened.
            child: HerdrAgentsScreen(
              key: ValueKey('agents-home-${selected.id}'),
              connection: selected,
              embedded: true,
              runner: widget.runnerFor?.call(selected),
              onPickServer: servers.length > 1
                  ? () => _pickServer(servers, selected)
                  : null,
              onClose: widget.showAppBar
                  ? () => Navigator.of(context).maybePop()
                  : null,
            ),
          ),
        ],
      );
    }
    return Scaffold(
      key: const ValueKey('agents-home'),
      backgroundColor: colors.background,
      // One header only: the section draws its own (server, «+», menu); a
      // page pushed from elsewhere gets a back arrow in it, not a bar above.
      body: SafeArea(
        child: widget.showAppBar && (_failed || _servers?.isEmpty != false)
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: IconButton(
                      key: const ValueKey('hda-close'),
                      tooltip: strings.hdaBack,
                      onPressed: () => Navigator.of(context).maybePop(),
                      icon: const Icon(Icons.arrow_back_rounded),
                    ),
                  ),
                  Expanded(child: body),
                ],
              )
            : body,
      ),
    );
  }
}
