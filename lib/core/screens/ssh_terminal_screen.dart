// Terminal SSH interactiva. La sesión (shell PTY + Terminal de xterm) vive en
// SshSessionService, así que PERSISTE al salir de la pantalla y al segundo plano
// (no se corta un comando largo). Esta pantalla solo se engancha al Terminal.
// 1.4.0 (F1): terminal agrandable, fila de teclas auxiliares y reconexión
// automática acotada tras una caída de red. El terminal es un shell normal:
// sin banner ni panel de agentes (los agentes viven en su propia sección).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../../l10n/app_localizations.dart';
import '../../main.dart';
import '../services/connection_manager.dart';
import '../services/ssh_manager.dart';
import '../services/ssh_reconnect.dart';
import '../services/ssh_session_service.dart';
import '../services/ssh_working_directory.dart';
import '../services/terminal_sessions.dart';
import '../screens/lock_screen.dart';
import '../theme/app_theme.dart';
import '../theme/hermes_tokens.dart';
import '../theme/terminal_palette.dart';
import '../utils/ssh_error.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/ssh_host_key_dialog.dart';
import '../widgets/ssh_sessions_sheet.dart';
import '../widgets/ssh_terminal_controls.dart';
import '../widgets/workspace/chat_workspace.dart' show ChatWorkspaceTab;
import '../widgets/workspace/chat_workspace_host.dart'
    show
        ChatWorkspaceMenuEntry,
        ChatWorkspacePaneScope,
        ChatWorkspaceTokens,
        ChatWorkspaceToolbar;
import 'sftp_browser_screen.dart';
import '../widgets/console_loader.dart';
import '../widgets/secure_screen_scope.dart';

class SshTerminalScreen extends StatefulWidget {
  final SavedConnection connection;

  /// In the workspace pane (v25): the line naming the server, shown where
  /// the full-screen header would be (e.g. `user@host:22`).
  final String? paneTitle;

  /// In the workspace pane: what the hub offered around the terminal
  /// (credentials, host key, removing SSH), for the floating bar's «⋯».
  final List<ChatWorkspaceMenuEntry> paneMenu;

  /// A line to type into the shell once, as soon as it is ready: «attach
  /// this session». Only ever set by an explicit user action, and built from
  /// ids and names the app validated (see `TerminalAttach`).
  final String? initialCommand;

  const SshTerminalScreen({
    required this.connection,
    this.paneTitle,
    this.paneMenu = const [],
    this.initialCommand,
    super.key,
  });

  /// Terminal font size; one point larger while expanded.
  static const double fontSize = 13;
  static const double expandedFontSize = fontSize + 1;

  @override
  State<SshTerminalScreen> createState() => _SshTerminalScreenState();
}

class _SshTerminalScreenState extends State<SshTerminalScreen>
    with WidgetsBindingObserver {
  SshTerminalSession? _session;
  bool _preparing = true; // App Lock + conexión inicial

  /// Terminal agrandado: sin cabecera, todo el alto y la fuente un punto
  /// mayor. Solo en memoria: cada vez que se abre la pantalla empieza normal.
  bool _expanded = false;

  /// In the workspace pane (v25): no header of its own (the tab names it);
  /// the floating bar carries the key row toggle and «⋯».
  bool _inPane = false;

  /// v25's keyboard button on the floating bar: the key row and the quick
  /// commands under the terminal. Always shown outside the pane.
  bool _keysShown = true;

  /// Reconexión automática tras una caída de red; se libera en dispose.
  late final SshAutoReconnect _reconnect = SshAutoReconnect(
    attempt: _autoAttempt,
  );

  /// The last automatic attempt met a new or changed host key: only a
  /// manual reconnect (with the TOFU dialog) can go on.
  bool _hostKeyNeedsReview = false;

  /// Why the automatic attempts stopped when a retry cannot help
  /// (credentials, configuration); shown instead of a bare «Offline».
  Object? _offlineFailure;

  bool _foreground = true;

  /// [SshTerminalScreen.initialCommand] was typed already.
  bool _initialTyped = false;

  /// This screen is what the user sees: its route is on top (nothing pushed
  /// over it) and its tickers run (not an off-screen workspace tab or a
  /// covered route). A dropped connection is only reconnected from a screen
  /// that is seen.
  bool _visible = true;

  SshSessionService get _svc =>
      context.findAncestorStateOfType<HermesAppState>()!.sshSessions;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _inPane = ChatWorkspacePaneScope.isInPane(context);
    final visible =
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.of(context)?.isCurrent ?? true);
    if (visible == _visible) return;
    _visible = visible;
    _syncReconnect();
    // A drop that happened while this screen was not seen reconnects now.
    if (visible) _onPhase();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _session?.phase.removeListener(_onPhase);
    _reconnect.dispose();
    super.dispose();
  }

  /// In the pane, puts this terminal's controls on the floating bar after
  /// the frame (the bar is outside this screen).
  void _schedulePaneToolbar() {
    if (!_inPane) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _publishPaneToolbar());
  }

  /// Never during a build: it rebuilds the floating bar (see
  /// [_schedulePaneToolbar]).
  void _publishPaneToolbar() {
    if (!mounted || !_inPane) return;
    final strings = Strings.of(context);
    final ready = _session?.phase.value == SshSessionPhase.ready;
    ChatWorkspacePaneScope.publish(
      context,
      ChatWorkspaceToolbar(
        keysShown: ready ? _keysShown : null,
        onToggleKeys: ready ? _toggleKeys : null,
        menu: [
          ChatWorkspaceMenuEntry(
            key: const ValueKey('ssh-pane-menu-files'),
            label: strings.sshFilesSftp,
            icon: Icons.folder_open_outlined,
            onSelected: _openSftp,
          ),
          if (ready)
            ChatWorkspaceMenuEntry(
              key: const ValueKey('ssh-pane-menu-sessions'),
              label: strings.hdpSessionsTitle,
              icon: Icons.view_list_outlined,
              onSelected: _openSessions,
            ),
          ...widget.paneMenu,
          if (_session != null)
            ChatWorkspaceMenuEntry(
              key: const ValueKey('ssh-pane-menu-close'),
              label: strings.sshCloseSession,
              icon: Icons.power_settings_new,
              onSelected: _closeSession,
            ),
        ],
      ),
    );
  }

  void _toggleKeys() {
    setState(() => _keysShown = !_keysShown);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _foreground = true;
        _syncReconnect();
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        _foreground = false;
        _syncReconnect();
      case AppLifecycleState.inactive:
        break;
    }
  }

  Future<void> _init() async {
    final app = context.findAncestorStateOfType<HermesAppState>()!;
    // Si ya hay una sesión viva, reengánchate sin pedir App Lock de nuevo.
    final existing = _svc.of(widget.connection.id);
    if (existing != null && existing.isLive) {
      setState(() {
        _adopt(existing);
        _preparing = false;
      });
      _typeInitialCommand();
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

  /// Watches [session] instead of the previous one. Call inside setState.
  void _adopt(SshTerminalSession session) {
    if (identical(_session, session)) return;
    _session?.phase.removeListener(_onPhase);
    _session = session;
    session.phase.addListener(_onPhase);
  }

  /// The automatic attempts run only while this screen is seen and the app
  /// is in front. Hidden (an off-screen tab, a route covering it) or in the
  /// background, the next attempt waits (review R5A P2-B4-2: a covered
  /// terminal kept retrying beside the visible one on the same session,
  /// could hand it its «no» to a host key and announced the fresh shell a
  /// second time). An attempt already in flight is let finish.
  void _syncReconnect() {
    if (!_foreground || !_visible) {
      _reconnect.pause();
      return;
    }
    // Connected meanwhile (an attempt in flight, or by hand from another
    // screen): nothing left to reconnect.
    if (_session?.phase.value == SshSessionPhase.ready &&
        _reconnect.status.value != SshReconnectStatus.reconnected) {
      _reconnect.stop();
    }
    _reconnect.resume();
  }

  /// Only a dropped connection reconnects on its own: a shell that exited,
  /// or a session the app closed, waits for the user.
  void _onPhase() {
    final session = _session;
    if (session == null || !mounted) return;
    // Only the screen that is seen reconnects: an off-screen tab or a
    // covered route on the same session would retry (and announce the
    // fresh shell) a second time (review P1-F4-1).
    if (_visible &&
        session.phase.value == SshSessionPhase.closed &&
        session.end == SshSessionEnd.connectionLost &&
        !_reconnect.isActive) {
      _hostKeyNeedsReview = false;
      _offlineFailure = null;
      _reconnect.start();
    }
  }

  Future<void> _connect() async {
    _reconnect.stop();
    final previousEnd = (_session ?? _svc.of(widget.connection.id))?.end;
    setState(() {
      _preparing = true;
      _hostKeyNeedsReview = false;
      _offlineFailure = null;
    });
    final session = await _svc.connect(
      widget.connection.id,
      onHostKey: (p) => showSshHostKeyDialog(context, p),
    );
    if (!mounted) return;
    if (previousEnd == SshSessionEnd.connectionLost) {
      _announceFreshShell(session);
    }
    setState(() {
      _adopt(session);
      _preparing = false;
    });
    _typeInitialCommand();
  }

  /// Types the line the screen was opened with, once, when the shell is
  /// ready. A line with a control character is never typed: it could run a
  /// second command.
  void _typeInitialCommand() {
    final line = widget.initialCommand;
    final session = _session;
    if (_initialTyped || line == null || session == null) return;
    if (session.phase.value != SshSessionPhase.ready) return;
    _initialTyped = true;
    if (line.isEmpty || RegExp(r'[\x00-\x1F\x7F]').hasMatch(line)) return;
    _svc.send(widget.connection.id, '$line\n');
  }

  /// «Sessions»: tmux and Herdr sessions of the server, to attach this
  /// terminal to one of them. Typed only when the user picks a row.
  Future<void> _openSessions() async {
    final session = _session;
    final client = session?.client;
    if (session == null ||
        client == null ||
        session.phase.value != SshSessionPhase.ready) {
      return;
    }
    final app = context.findAncestorStateOfType<HermesAppState>()!;
    final recents = TerminalRecentStore(
      app.connManager.prefs,
      widget.connection.id,
    );
    final choice = await showSshSessionsSheet(
      context,
      run: (command) => SshSessionService.runRemote(client, command),
      recents: recents,
    );
    if (choice == null || !mounted) return;
    await recents.add(choice.recent);
    if (session.phase.value != SshSessionPhase.ready) return;
    _svc.send(widget.connection.id, '${choice.line}\n');
  }

  /// One automatic attempt. It never trusts a host key on its own: a new or
  /// changed key stops the attempts and leaves it to the manual button.
  Future<SshReconnectOutcome> _autoAttempt() async {
    final previous = _session;
    var hostKeyAsked = false;
    final session = await _svc.connect(
      widget.connection.id,
      onHostKey: (_) async {
        hostKeyAsked = true;
        return false;
      },
    );
    if (!mounted) return SshReconnectOutcome.stop;
    setState(() => _adopt(session));
    if (session.phase.value == SshSessionPhase.ready) {
      // An already-ready session (connected by an earlier attempt) was
      // announced then: say it once.
      if (!identical(previous, session)) _announceFreshShell(session);
      return SshReconnectOutcome.connected;
    }
    if (hostKeyAsked) {
      setState(() => _hostKeyNeedsReview = true);
      return SshReconnectOutcome.stop;
    }
    final failure = session.failure;
    if (failure != null && !SshManager.isTransientFailure(failure)) {
      setState(() => _offlineFailure = failure);
      return SshReconnectOutcome.stop;
    }
    if (session.end == SshSessionEnd.remoteExit) {
      return SshReconnectOutcome.stop;
    }
    return SshReconnectOutcome.retry;
  }

  /// A plain shell cannot survive a dropped connection: say so in the
  /// scrollback, which is kept, so it is clear the old process is gone.
  void _announceFreshShell(SshTerminalSession session) {
    if (session.phase.value != SshSessionPhase.ready ||
        session.kind.survivesDisconnect) {
      return;
    }
    final notice = Strings.of(context).sshReconnectedFreshShell;
    session.terminal.write('\r\n\x1b[90m[$notice]\x1b[0m\r\n');
  }

  void _toggleExpanded() => setState(() => _expanded = !_expanded);

  /// Files (SFTP). In the pane it is the workspace's Archivos tab (v25);
  /// full screen, the browser on top as before.
  void _openSftp() {
    final workspace = _inPane
        ? ChatWorkspacePaneScope.controllerOf(context)
        : null;
    if (workspace != null) {
      workspace.open(ChatWorkspaceTab.files);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SftpBrowserScreen(connection: widget.connection),
      ),
    );
  }

  Future<void> _closeSession() async {
    _reconnect.stop();
    _svc.close(widget.connection.id);
    if (mounted) Navigator.pop(context);
  }

  // H4: FLAG_SECURE mientras esta página está montada.
  @override
  Widget build(BuildContext context) =>
      SecureScreenScope(child: Builder(builder: _buildPage));

  Widget _buildPage(BuildContext context) {
    final colors = Theme.of(context).hermes;
    _schedulePaneToolbar();
    return PopScope(
      // Atrás con el terminal agrandado primero lo reduce.
      canPop: !_expanded,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _expanded) _toggleExpanded();
      },
      child: Scaffold(
        // In the pane the pane's own surface shows (audit T1).
        backgroundColor: ChatWorkspacePaneScope.backgroundOf(
          context,
          colors.background,
        ),
        appBar: _expanded || _inPane
            ? null
            : HermesAppBar(
                // No glass (Q9-CRISTAL): nothing scrolls under it.
                glass: false,
                centerTitle: false,
                title: Text(Strings.of(context).sshTitle),
                actions: [
                  if (_session?.phase.value == SshSessionPhase.ready)
                    IconButton(
                      key: const ValueKey('ssh-sessions-button'),
                      tooltip: Strings.of(context).hdpSessionsTitle,
                      icon: const Icon(Icons.view_list_outlined),
                      onPressed: _openSessions,
                    ),
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
        // Sin cabecera, el terminal agrandado respeta la barra de estado.
        // Mismo árbol en los dos modos: el TerminalView no se reconstruye.
        body: SafeArea(
          top: _expanded,
          left: _expanded,
          right: _expanded,
          bottom: false,
          child: _body(colors),
        ),
      ),
    );
  }

  Widget _body(HermesThemeColors colors) {
    final session = _session;
    if (_preparing || session == null) {
      return _loader(Strings.of(context).sshConnecting);
    }
    return ValueListenableBuilder<SshSessionPhase>(
      valueListenable: session.phase,
      builder: (context, phase, _) =>
          ValueListenableBuilder<SshReconnectStatus>(
            valueListenable: _reconnect.status,
            builder: (context, status, _) =>
                _sessionBody(colors, session, phase, status),
          ),
    );
  }

  Widget _sessionBody(
    HermesThemeColors colors,
    SshTerminalSession session,
    SshSessionPhase phase,
    SshReconnectStatus status,
  ) {
    // Mientras se reconecta, el terminal (con su scrollback) sigue a la
    // vista con la barra de estado; sin reconexión, como siempre.
    final recovering = status != SshReconnectStatus.idle;
    if (!recovering && phase == SshSessionPhase.connecting) {
      return _loader(Strings.of(context).sshConnecting);
    }
    if (!recovering && phase == SshSessionPhase.error) {
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
                    : localizedSshError(Strings.of(context), session.failure!),
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
    // ready o closed (o reconectando): mostramos el terminal (con
    // scrollback). Si no está listo, la barra ofrece reconectar.
    final ready = phase == SshSessionPhase.ready;
    // the owner (ronda Fold 2): with the keyboard up in the workspace pane the
    // terminal had one line left. Its host line steps
    // aside and the keys keep one thin row (their slots stay, so the
    // terminal is not rebuilt).
    final typingInPane = _inPane && MediaQuery.viewInsetsOf(context).bottom > 0;
    final terminal = Stack(
      children: [
        Positioned.fill(
          child: TerminalView(
            session.terminal,
            // Desktop: light or dark palette with the app.
            theme: hermesTerminalTheme(Theme.of(context)),
            textStyle: TerminalStyle(
              fontSize: _expanded
                  ? SshTerminalScreen.expandedFontSize
                  : SshTerminalScreen.fontSize,
            ),
            padding: const EdgeInsets.all(8),
            // In the workspace pane beside the chat the composer keeps the
            // focus (review P2-F4-5); full screen, the terminal takes it as
            // before.
            autofocus: !_inPane,
            readOnly: !ready,
            // U-03 (spec 028): con IME software (Gboard) el default
            // deleteDetection=false deja el editing state vacío y el
            // backspace nunca llega al terminal; y el keyboardType
            // emailAddress activa composición/autocorrección que corta la
            // entrada. visiblePassword = sin sugerencias (tradeoff: sin
            // swipe-typing, aceptable en un terminal).
            deleteDetection: true,
            keyboardType: TextInputType.visiblePassword,
          ),
        ),
        // In the pane the floating bar's «Ampliar» does this job.
        if (!_inPane)
          PositionedDirectional(
            end: 4,
            bottom: 4,
            child: SshTerminalExpandButton(
              key: const ValueKey('ssh-terminal-expand'),
              expanded: _expanded,
              onPressed: _toggleExpanded,
            ),
          ),
      ],
    );
    final reconnect = <Widget>[
      if (!ready || status != SshReconnectStatus.idle)
        _reconnectBar(colors, session, phase, status),
    ];
    // the owner (ronda Fold 2): only the key buttons. The quick commands row is
    // gone; the commands saved per server stay stored, untouched. Mock 136
    // v2-A (Cadu's look): the keys are one rounded pill under the terminal,
    // with air around it.
    final keys = <Widget>[
      if (ready && (!_inPane || _keysShown))
        Padding(
          padding: typingInPane
              ? const EdgeInsets.fromLTRB(4, 0, 4, 4)
              : const EdgeInsets.fromLTRB(
                  ChatWorkspaceTokens.inset,
                  0,
                  ChatWorkspaceTokens.inset,
                  ChatWorkspaceTokens.inset,
                ),
          child: SshTerminalKeyBar(
            terminal: session.terminal,
            ctrlArmed: session.ctrlArmed,
            dense: typingInPane,
            pill: true,
          ),
        ),
    ];
    return Column(
      children: [
        if (_inPane && widget.paneTitle != null)
          typingInPane ? const SizedBox.shrink() : _paneHeader(colors, session),
        if (_inPane) ...[
          // Mock 136 v2-A: the terminal in a rounded card with its own
          // margin, and the keys in a pill under it.
          Expanded(
            child: Padding(
              padding: typingInPane
                  ? const EdgeInsets.fromLTRB(4, 2, 4, 4)
                  : const EdgeInsets.fromLTRB(
                      ChatWorkspaceTokens.inset,
                      4,
                      ChatWorkspaceTokens.inset,
                      8,
                    ),
              child: DecoratedBox(
                key: const ValueKey('ssh-terminal-pane-card'),
                position: DecorationPosition.foreground,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(
                    ChatWorkspaceTokens.cardRadius,
                  ),
                  border: Border.all(color: HermesChrome.of(colors).line),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(
                    ChatWorkspaceTokens.cardRadius,
                  ),
                  child: Column(
                    children: [
                      Expanded(child: terminal),
                      ...reconnect,
                    ],
                  ),
                ),
              ),
            ),
          ),
          ...keys,
        ] else ...[
          Expanded(child: terminal),
          ...reconnect,
          ...keys,
        ],
      ],
    );
  }

  /// The two lines over the terminal in the pane (mock 136 v2-A `.ctx`,
  /// Cadu): the server in mono with its name, «SSH» with the shield; under
  /// it, the folder the shell is in, in mono, once the shell has said it
  /// (OSC 7 or bash's title). Two lines, so the name is no longer cut to
  /// make room for everything else.
  Widget _paneHeader(HermesThemeColors colors, SshTerminalSession session) {
    final strings = Strings.of(context);
    final ink = colors.textSecondary;
    final plain = HermesType.support.copyWith(color: ink);
    final mono = plain.copyWith(fontFamily: HermesType.monoFamily);
    final title = widget.paneTitle!;
    final user = title.contains('@') ? title.split('@').first : null;
    return Padding(
      key: const ValueKey('ssh-terminal-pane-header'),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.dns_outlined, size: HermesIcon.sm, color: ink),
              const SizedBox(width: HermesSpace.x2),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: title, style: mono),
                      const TextSpan(text: ' · '),
                      TextSpan(text: widget.connection.label),
                    ],
                  ),
                  key: const ValueKey('ssh-terminal-pane-host'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: plain,
                ),
              ),
              const SizedBox(width: HermesSpace.x2),
              Text(strings.sshProtocolLabel, style: plain),
              const SizedBox(width: HermesSpace.x1),
              ExcludeSemantics(
                child: Icon(
                  Icons.shield_outlined,
                  size: HermesIcon.sm,
                  color: ink,
                ),
              ),
            ],
          ),
          // The folder's line keeps its height before the shell says one:
          // a header growing mid-session would shrink the terminal by a row
          // and resize the server's shell under what is running.
          ValueListenableBuilder<String?>(
            valueListenable: session.workingDirectory,
            builder: (context, directory, _) => Visibility(
              visible: directory != null,
              maintainSize: true,
              maintainAnimation: true,
              maintainState: true,
              child: Padding(
                padding: const EdgeInsets.only(top: HermesSpace.x1),
                child: Row(
                  children: [
                    Icon(
                      Icons.folder_outlined,
                      size: HermesIcon.sm,
                      color: ink,
                    ),
                    const SizedBox(width: HermesSpace.x2),
                    Expanded(
                      child: Text(
                        directory == null
                            ? ''
                            : sshShortDirectory(directory, user),
                        key: directory == null
                            ? null
                            : const ValueKey('ssh-terminal-pane-folder'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: mono,
                        // The line's height from the style alone, never from
                        // its glyphs: empty (the place kept) and with the
                        // folder it is the same, to the pixel (gint47: an
                        // empty line measured 1 dp less).
                        strutStyle: StrutStyle.fromTextStyle(
                          mono,
                          forceStrutHeight: true,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _loader(String msg) => Center(child: ConsoleLoader.large(label: msg));

  /// Status bar under the terminal: session closed, reconnecting,
  /// reconnected or offline. The manual button shows whenever no attempt is
  /// in flight and the session is not ready.
  Widget _reconnectBar(
    HermesThemeColors colors,
    SshTerminalSession session,
    SshSessionPhase phase,
    SshReconnectStatus status,
  ) {
    final strings = Strings.of(context);
    final ready = phase == SshSessionPhase.ready;
    final String message = switch (status) {
      SshReconnectStatus.idle => strings.sshSessionClosed,
      SshReconnectStatus.waiting ||
      SshReconnectStatus.reconnecting => strings.sshReconnecting,
      SshReconnectStatus.reconnected =>
        session.kind.survivesDisconnect
            ? strings.sshReconnectedReattached
            : strings.sshReconnectedFreshShell,
      SshReconnectStatus.offline =>
        _hostKeyNeedsReview
            ? strings.sshHostKeyNeedsReview
            : _offlineFailure != null
            ? localizedSshError(strings, _offlineFailure!)
            : strings.sshOffline,
    };
    final busy = status == SshReconnectStatus.reconnecting;
    final showButton = !ready && !busy;
    return Semantics(
      liveRegion: true,
      container: true,
      child: Container(
        key: const ValueKey('ssh-reconnect-bar'),
        width: double.infinity,
        color: colors.surface,
        padding: const EdgeInsets.all(10),
        child: Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          runSpacing: 8,
          children: [
            if (status == SshReconnectStatus.waiting || busy)
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: colors.textSecondary,
                ),
              ),
            Text(
              message,
              key: const ValueKey('ssh-reconnect-message'),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, color: colors.textSecondary),
            ),
            if (showButton)
              FilledButton.icon(
                key: const ValueKey('ssh-reconnect-button'),
                onPressed: _connect,
                icon: const Icon(Icons.refresh, size: 15),
                label: Text(strings.sshReconnect),
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
