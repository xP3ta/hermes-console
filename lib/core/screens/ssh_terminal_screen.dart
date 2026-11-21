// Terminal SSH interactiva. La sesión (shell PTY + Terminal de xterm) vive en
// SshSessionService, así que PERSISTE al salir de la pantalla y al segundo plano
// (no se corta un comando largo). Esta pantalla solo se engancha al Terminal.
// 1.4.0 (F1): terminal agrandable, fila de teclas auxiliares y reconexión
// automática acotada tras una caída de red. El terminal es un shell normal:
// sin banner ni panel de agentes (los agentes viven en su propia sección).
// 1.4.3: a terminal a phone can work in (SshTerminalSurface): selection and
// copy by touch, Paste and Compose, sticky Ctrl/Alt, a pinch for the font
// size (kept on this device), tappable links, answers to a waiting y/n
// question. An open terminal is never closed for being idle.
import 'package:hermes_android/core/design/hicons.dart';

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/app_localizations.dart';
import '../../main.dart';
import '../bots/ui/room/room_dictation.dart';
import '../browser/open_web_link.dart';
import '../config/flavor.dart' show kVoiceRuntimeEnabled;
import '../design/modal.dart' show HermesAction, HermesMenuButton;
import '../services/connection_manager.dart';
import '../services/ssh_manager.dart';
import '../services/ssh_reconnect.dart';
import '../services/ssh_session_service.dart';
import '../services/ssh_terminal_input.dart';
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
import '../widgets/ssh_terminal_compose.dart';
import '../widgets/ssh_terminal_controls.dart';
import '../widgets/ssh_terminal_surface.dart';
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

  /// A web address tapped in the terminal. The workspace can send it to
  /// its own browser tab; without it, the in-app browser opens over the
  /// screen ([openWebLinkInApp]).
  final ValueChanged<Uri>? onOpenLink;

  /// Where Compose's attachments come from: the platform's camera, photo
  /// library and files when null.
  final SshComposePicker? composePicker;

  /// Compose's microphone: the chat composer's dictation when null (and
  /// voice is part of this build).
  final RoomDictation? composeDictation;

  const SshTerminalScreen({
    required this.connection,
    this.paneTitle,
    this.paneMenu = const [],
    this.initialCommand,
    this.onOpenLink,
    this.composePicker,
    this.composeDictation,
    super.key,
  });

  /// Terminal font size; one point larger while expanded. A pinch changes
  /// it, kept on this device under [fontSizePrefsKey].
  static const double fontSize = 13;
  static const double expandedFontSize = fontSize + 1;

  /// Where the size a pinch chose is kept (the size when not expanded).
  static const String fontSizePrefsKey = 'ssh_terminal_font_size';

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

  /// The touch layer of the terminal: its selection, its paste.
  GlobalKey<SshTerminalSurfaceState> _surface =
      GlobalKey<SshTerminalSurfaceState>();

  /// The device's preferences (font size, key row); read once.
  SharedPreferences? _prefs;

  /// The font size when not expanded: the default, or the one a pinch
  /// chose before.
  double _baseFont = SshTerminalScreen.fontSize;

  /// The Compose card is open over the dock.
  bool _composeOpen = false;

  /// The dock's arrow pad (✥) is open above it.
  final ValueNotifier<bool> _arrowsOpen = ValueNotifier<bool>(false);

  /// Compose's microphone ([SshTerminalScreen.composeDictation], else the
  /// chat composer's engine, made when Compose first opens).
  RoomDictation? _dictation;
  bool _ownDictation = false;

  /// The shell's window title and the server, for the header.
  String? _sshHost;

  /// The service this screen attaches to while visible and in the foreground.
  SshSessionService? _viewing;
  bool _viewAttached = false;
  bool _resumed = true;

  SshSessionService get _svc =>
      context.findAncestorStateOfType<HermesAppState>()!.sshSessions;

  SshTerminalSession? get _visibleTerminal => _session?.visibleTerminal;
  bool get _canReturnToShell => _session?.attachment.value != null;

  void _syncViewing() {
    final viewing = _viewing;
    if (viewing == null) return;
    final active = _visible && _resumed;
    if (active == _viewAttached) return;
    if (active) {
      viewing.attachView(widget.connection.id);
    } else {
      viewing.detachView(widget.connection.id);
    }
    _viewAttached = active;
  }

  @override
  void initState() {
    super.initState();
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _resumed = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    _foreground = _resumed || lifecycle == AppLifecycleState.inactive;
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_viewing == null) {
      final app = context.findAncestorStateOfType<HermesAppState>()!;
      _viewing = app.sshSessions;
      final prefs = app.connManager.prefs;
      _prefs = prefs;
      final stored = prefs.getDouble(SshTerminalScreen.fontSizePrefsKey);
      _baseFont = _clampFont(stored ?? SshTerminalScreen.fontSize);
      unawaited(_loadHost(app));
    }
    _inPane = ChatWorkspacePaneScope.isInPane(context);
    final visible =
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.of(context)?.isCurrent ?? true);
    final changed = visible != _visible;
    _visible = visible;
    _syncViewing();
    if (!changed) return;
    _syncReconnect();
    // A drop that happened while this screen was not seen reconnects now.
    if (visible) _onPhase();
  }

  @override
  void didUpdateWidget(SshTerminalScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.connection.id != widget.connection.id && _viewAttached) {
      _viewing?.detachView(oldWidget.connection.id);
      _viewAttached = false;
      _syncViewing();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _session?.phase.removeListener(_onPhase);
    _session?.attachment.removeListener(_onAttachment);
    _reconnect.dispose();
    if (_viewAttached) {
      _viewing?.detachView(widget.connection.id);
      _viewAttached = false;
    }
    _arrowsOpen.dispose();
    if (_ownDictation) _dictation?.dispose();
    super.dispose();
  }

  /// The server's address for the header's second line (herdr's `name ·
  /// host`); nothing when the profile has no SSH settings yet.
  Future<void> _loadHost(HermesAppState app) async {
    try {
      final config = await app.sshManager.loadConfig(widget.connection.id);
      if (!mounted || config == null) return;
      setState(() => _sshHost = config.host);
    } on Object catch (error) {
      debugPrint('[ssh] header host not read (${error.runtimeType})');
    }
  }

  /// The font size the terminal is drawn at.
  double get _fontSize => _baseFont + (_expanded ? 1 : 0);

  static double _clampFont(double size) {
    const min = SshTerminalSurface.minFontSize;
    const max = SshTerminalSurface.maxFontSize;
    return size.clamp(min, max).toDouble();
  }

  /// A pinch chose [size] (as drawn): kept as the size when not expanded.
  void _setFontSize(double size) {
    final base = _clampFont(size - (_expanded ? 1 : 0));
    if (base == _baseFont) return;
    setState(() => _baseFont = base);
    unawaited(_prefs?.setDouble(SshTerminalScreen.fontSizePrefsKey, base));
  }

  /// A web address the user tapped: the workspace's browser when it gave
  /// one, else the in-app browser (http and https only are detected).
  void _openLink(Uri uri) {
    final open = widget.onOpenLink;
    if (open != null) {
      open(uri);
      return;
    }
    openWebLinkInApp(context, uri);
  }

  /// The key row's Paste: the clipboard into the shell.
  void _paste() {
    final surface = _surface.currentState;
    if (surface != null) {
      unawaited(surface.paste());
      return;
    }
    final session = _visibleTerminal;
    if (session == null || session.phase.value != SshSessionPhase.ready) {
      return;
    }
    unawaited(
      sshPasteClipboard(session.terminal, modifiers: session.modifiers),
    );
  }

  /// The pencil: opens the Compose card over the dock, or closes it. Its
  /// draft is kept in memory for this connection until it is sent
  /// ([SshSessionService.composeDraft]), so closing loses nothing.
  void _compose() {
    final open = !_composeOpen;
    if (open) {
      _arrowsOpen.value = false;
      _surface.currentState?.hideKeyboard();
      _dictation ??= _makeDictation();
    } else {
      FocusManager.instance.primaryFocus?.unfocus();
    }
    setState(() => _composeOpen = open);
  }

  RoomDictation? _makeDictation() {
    final given = widget.composeDictation;
    if (given != null) return given;
    if (!kVoiceRuntimeEnabled) return null;
    final app = context.findAncestorStateOfType<HermesAppState>()!;
    _ownDictation = true;
    return VoiceRoomDictation(
      voice: app.voice,
      connection: widget.connection,
      profile: app.connManager.activeProfileFor(widget.connection.id),
    );
  }

  /// The dock's keyboard key: the keyboard for typing straight into the
  /// terminal (Compose steps aside), or, up already, it goes down.
  void _keyboard({required bool up}) {
    final surface = _surface.currentState;
    if (up) {
      surface?.hideKeyboard();
      return;
    }
    if (_composeOpen) {
      FocusManager.instance.primaryFocus?.unfocus();
      setState(() => _composeOpen = false);
    }
    surface?.showKeyboard();
  }

  /// Why Compose cannot attach files now: they go up over this
  /// connection, so it must be connected and allowed to write.
  String? _attachUnavailable() {
    final strings = Strings.of(context);
    final app = context.findAncestorStateOfType<HermesAppState>()!;
    if (app.sshManager.isReadOnly(widget.connection.id)) {
      return strings.termUxAttachReadOnly;
    }
    final session = _session;
    if (session == null ||
        session.phase.value != SshSessionPhase.ready ||
        session.client == null) {
      return strings.termUxAttachOffline;
    }
    return null;
  }

  /// Writes Compose's [text] into the shell in one go: one (bracketed)
  /// paste, Enter after it when [enter]. False, with nothing written, when
  /// the session is not ready or the write fails: the sheet keeps the text.
  bool _sendComposed(String text, {required bool enter}) {
    final session = _visibleTerminal;
    if (session == null ||
        session.phase.value != SshSessionPhase.ready ||
        session.isClientClosed) {
      return false;
    }
    final terminal = session.terminal;
    final payload = sshPastePayload(terminal, text, enter: enter);
    try {
      session.modifiers.unmodified(() => terminal.textInput(payload));
    } on Object catch (error) {
      debugPrint('[ssh] compose not sent (${error.runtimeType})');
      return false;
    }
    _svc.rememberComposed(widget.connection.id, text);
    _svc.composeDraft(widget.connection.id).markQueuedSend(text);
    // The card lists what was sent this session: it is one more now.
    setState(() {});
    return true;
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
          if (ready)
            ChatWorkspaceMenuEntry(
              key: const ValueKey('ssh-pane-menu-compose'),
              label: strings.termUxCompose,
              icon: HIcons.edit_note_outlined,
              onSelected: () {
                if (!_composeOpen) _compose();
              },
            ),
          ChatWorkspaceMenuEntry(
            key: const ValueKey('ssh-pane-menu-files'),
            label: strings.sshFilesSftp,
            icon: HIcons.folder_open_outlined,
            onSelected: _openSftp,
          ),
          if (ready)
            ChatWorkspaceMenuEntry(
              key: const ValueKey('ssh-pane-menu-sessions'),
              label: strings.hdpSessionsTitle,
              icon: HIcons.view_list_outlined,
              onSelected: _openSessions,
            ),
          if (_canReturnToShell)
            ChatWorkspaceMenuEntry(
              key: const ValueKey('ssh-pane-return-to-shell'),
              label: strings.hdpReturnToShell,
              icon: HIcons.arrow_back_rounded,
              onSelected: _returnToShell,
            ),
          ...widget.paneMenu,
          if (_session != null)
            ChatWorkspaceMenuEntry(
              key: const ValueKey('ssh-pane-menu-close'),
              label: strings.sshCloseSession,
              icon: HIcons.power_settings_new,
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
    _resumed = state == AppLifecycleState.resumed;
    _syncViewing();
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
    if (!identical(
      _visibleTerminal?.terminal,
      session.visibleTerminal.terminal,
    )) {
      _surface = GlobalKey<SshTerminalSurfaceState>();
    }
    _session?.phase.removeListener(_onPhase);
    _session?.attachment.removeListener(_onAttachment);
    _session = session;
    session.phase.addListener(_onPhase);
    session.attachment.addListener(_onAttachment);
  }

  void _onAttachment() {
    _arrowsOpen.value = false;
    if (_composeOpen) FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _composeOpen = false;
      // A selection and scroll position belong to this PTY's own buffer.
      _surface = GlobalKey<SshTerminalSurfaceState>();
    });
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
    if ((session.phase.value == SshSessionPhase.closed &&
            session.end == SshSessionEnd.connectionLost) ||
        session.phase.value == SshSessionPhase.error) {
      _svc.composeDraftIfPresent(widget.connection.id)?.recoverUncertainSend();
    }
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

  Future<void> _openSessions() async {
    final session = _session;
    if (session == null) return;
    final app = context.findAncestorStateOfType<HermesAppState>()!;
    await chooseSshTerminalSession(
      context,
      service: _svc,
      session: session,
      recents: TerminalRecentStore(app.connManager.prefs, widget.connection.id),
    );
  }

  void _returnToShell() {
    final session = _session;
    if (session != null) _svc.showPlainShell(session);
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
      canPop: !_expanded && !_composeOpen && !_canReturnToShell,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_composeOpen) {
          _compose();
        } else if (_expanded) {
          _toggleExpanded();
        } else if (_canReturnToShell) {
          _returnToShell();
        }
      },
      child: Scaffold(
        // In the pane the pane's own surface shows (audit T1).
        // Full screen, the page is the terminal's own surface (herdr: the
        // dock floats over the terminal, a shade darker).
        backgroundColor: ChatWorkspacePaneScope.backgroundOf(
          context,
          colors.surface,
        ),
        appBar: _expanded || _inPane
            ? null
            : HermesAppBar(
                // No glass (Q9-CRISTAL): nothing scrolls under it.
                glass: false,
                // herdr's header: the shell's window title, and under it,
                // dim, the profile and the server; the rest in «⋮».
                title: _headerTitle(colors),
                leading: _canReturnToShell
                    ? IconButton(
                        key: const ValueKey('ssh-terminal-return-to-shell'),
                        tooltip: Strings.of(context).hdpReturnToShell,
                        icon: const Icon(HIcons.arrow_back_rounded),
                        onPressed: _returnToShell,
                      )
                    : null,
                actions: [
                  IconButton(
                    key: const ValueKey('ssh-terminal-expand'),
                    tooltip: Strings.of(context).sshExpandTerminal,
                    icon: Icon(
                      HIcons.open_in_full,
                      semanticLabel: Strings.of(context).sshExpandTerminal,
                    ),
                    onPressed: _toggleExpanded,
                  ),
                  _headerMenu(),
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

  /// The shell's window title (as the shell sets it, `user@host: ~`), the
  /// profile's name until it does; the profile and the server under it.
  Widget _headerTitle(HermesThemeColors colors) {
    final strings = Strings.of(context);
    final session = _visibleTerminal;
    final host = _sshHost;
    final label = widget.connection.label;
    final fallbackTitle = _canReturnToShell ? session?.kind.programName : null;
    // Two lines in the bar's height: past 1.3x they would not fit it.
    Widget lines(String? title) => MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.3,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title ??
                fallbackTitle ??
                (label.isEmpty ? strings.sshTitle : label),
            key: const ValueKey('ssh-terminal-title'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            host == null || host.isEmpty ? label : '$label · $host',
            key: const ValueKey('ssh-terminal-subtitle'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: HermesType.support.copyWith(color: colors.textSecondary),
          ),
        ],
      ),
    );
    if (session == null) return lines(null);
    return ValueListenableBuilder<String?>(
      valueListenable: session.windowTitle,
      builder: (context, title, _) => lines(title),
    );
  }

  /// «⋮»: Sessions, Files (SFTP), Compose and closing the session.
  Widget _headerMenu() {
    final strings = Strings.of(context);
    return HermesMenuButton<VoidCallback>(
      key: const ValueKey('ssh-terminal-menu'),
      tooltip: strings.commonMoreOptions,
      onSelected: (action) => action(),
      actions: (_) {
        final ready = _session?.phase.value == SshSessionPhase.ready;
        return [
          if (ready)
            HermesAction(
              key: const ValueKey('ssh-sessions-button'),
              value: _openSessions,
              label: strings.hdpSessionsTitle,
            ),
          if (_canReturnToShell)
            HermesAction(
              key: const ValueKey('ssh-menu-return-to-shell'),
              value: _returnToShell,
              label: strings.hdpReturnToShell,
            ),
          HermesAction(value: _openSftp, label: strings.sshFilesSftp),
          if (ready)
            HermesAction(
              value: () {
                if (!_composeOpen) _compose();
              },
              label: strings.termUxCompose,
            ),
          if (_session != null)
            HermesAction(
              value: _closeSession,
              label: strings.sshCloseSession,
              destructive: true,
            ),
        ];
      },
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
                _sessionBody(colors, session.visibleTerminal, phase, status),
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
              Icon(HIcons.error_outline, size: 44, color: colors.error),
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
                icon: const Icon(HIcons.refresh, size: 16),
                label: Text(Strings.of(context).sshRetry),
              ),
              if (_expanded && !_inPane) ...[
                const SizedBox(height: HermesSpace.x2),
                TextButton.icon(
                  key: const ValueKey('ssh-terminal-expand'),
                  onPressed: _toggleExpanded,
                  icon: const Icon(
                    HIcons.close_fullscreen,
                    size: HermesIcon.md,
                  ),
                  label: Text(Strings.of(context).sshShrinkTerminal),
                ),
              ],
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
    final keyboard = MediaQuery.viewInsetsOf(context).bottom > 0;
    final typingInPane = _inPane && keyboard;
    final terminal = Stack(
      children: [
        Positioned.fill(
          // A touch on the terminal closes the arrow pad.
          child: Listener(
            onPointerDown: (_) => _arrowsOpen.value = false,
            child: SshTerminalSurface(
              key: _surface,
              terminal: session.terminal,
              // Desktop: light or dark palette with the app.
              theme: hermesTerminalTheme(Theme.of(context)),
              fontSize: _fontSize,
              modifiers: session.modifiers,
              onFontSize: _setFontSize,
              onOpenLink: _openLink,
              // In the workspace pane beside the chat the composer keeps the
              // focus (review P2-F4-5); full screen, the terminal takes it as
              // before.
              autofocus: !_inPane,
              readOnly: !ready,
            ),
          ),
        ),

        // ✥'s arrow pad, just above the dock at its end; it floats, so the
        // terminal does not resize.
        ValueListenableBuilder<bool>(
          valueListenable: _arrowsOpen,
          // Always a positioned child: a plain one would size the stack.
          builder: (context, open, _) => !open || !ready
              ? const PositionedDirectional(
                  end: 0,
                  bottom: 0,
                  child: SizedBox.shrink(),
                )
              : PositionedDirectional(
                  end: HermesSpace.x2,
                  bottom: HermesSpace.x2,
                  child: SshDockEntrance(
                    child: SshTerminalArrowPad(
                      terminal: session.terminal,
                      modifiers: session.modifiers,
                    ),
                  ),
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
    final dockShown = ready && (!_inPane || _keysShown);
    final svc = _svc;
    final id = widget.connection.id;
    return LayoutBuilder(
      builder: (context, constraints) {
        final bodyHeight = constraints.maxHeight;
        final tightCompose = _composeOpen && bodyHeight <= 360;
        final dockGap = typingInPane || tightCompose
            ? HermesSpace.x1
            : ChatWorkspaceTokens.inset;
        final dockReserve = dockShown
            ? SshTerminalDock.keyHeight + dockGap
            : 0.0;
        final aboveDock = math.max(0.0, bodyHeight - dockReserve);
        final composeGap = tightCompose ? HermesSpace.x1 : HermesSpace.x2;
        final composeSide = typingInPane
            ? HermesSpace.x1
            : ChatWorkspaceTokens.inset;
        // Measure Compose against the actual panel height above the dock so
        // narrow or compact viewports preserve terminal context and let long
        // multiline drafts scroll inside the pill.
        final composeCap = tightCompose ? 104.0 : aboveDock * 0.42;
        final composeShare = bodyHeight < 220 ? 0.44 : 0.42;
        final composeMaxHeight = math.max(
          0.0,
          math.min(aboveDock, math.min(aboveDock * composeShare, composeCap)),
        );
        final keys = <Widget>[
          if (ready && _composeOpen)
            Padding(
              padding: EdgeInsets.fromLTRB(
                composeSide,
                0,
                composeSide,
                composeGap,
              ),
              child: SshDockEntrance(
                child: SshComposeCard(
                  draft: svc.composeDraft(id),
                  history: svc.composeHistory(id),
                  attachUnavailable: _attachUnavailable(),
                  pick: widget.composePicker,
                  dictation: _dictation,
                  send: _sendComposed,
                  maxHeight: composeMaxHeight,
                ),
              ),
            ),
          if (dockShown)
            Padding(
              padding: EdgeInsets.fromLTRB(
                composeSide,
                0,
                composeSide,
                dockGap,
              ),
              child: SshTerminalDock(
                terminal: session.terminal,
                ctrlArmed: session.ctrlArmed,
                modifiers: session.modifiers,
                arrowsOpen: _arrowsOpen,
                onPaste: _paste,
                onCompose: _compose,
                onKeyboard: () => _keyboard(up: keyboard && !_composeOpen),
                onShrink: _expanded && !_inPane ? _toggleExpanded : null,
                composeOpen: _composeOpen,
                keyboardUp: keyboard && !_composeOpen,
                dense: typingInPane || tightCompose,
              ),
            ),
        ];
        return Column(
          children: [
            if (_inPane && widget.paneTitle != null)
              typingInPane
                  ? const SizedBox.shrink()
                  : _paneHeader(colors, session),
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
      },
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
              Icon(HIcons.dns_outlined, size: HermesIcon.sm, color: ink),
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
                  HIcons.shield_outlined,
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
                      HIcons.folder_outlined,
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
                icon: const Icon(HIcons.refresh, size: 15),
                label: Text(strings.sshReconnect),
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
              ),
            if (_expanded && !_inPane && !ready)
              IconButton(
                key: const ValueKey('ssh-terminal-expand'),
                tooltip: strings.sshShrinkTerminal,
                icon: Icon(
                  HIcons.close_fullscreen,
                  size: HermesIcon.md,
                  semanticLabel: strings.sshShrinkTerminal,
                ),
                onPressed: _toggleExpanded,
              ),
          ],
        ),
      ),
    );
  }
}
