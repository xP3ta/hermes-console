import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';

import '../../l10n/app_localizations.dart';
import '../../main.dart';
import '../models/connection.dart';
import '../models/terminal_exec.dart';
import '../services/active_chat_service.dart';
import '../services/agent_terminal_stream.dart';
import '../services/app_lock.dart';
import '../services/screen_security.dart';
import '../services/shared_gateway_pool.dart';
import '../services/terminal_availability.dart';
import '../services/terminal_pane_controller.dart';
import '../design/modal.dart' show HermesAction, showHermesMenu;
import '../design/page.dart' show HermesActionButton;
import '../theme/app_theme.dart';
import '../widgets/hermes_notice.dart';
import '../widgets/hermes_premium_ui.dart';
import 'lock_screen.dart';

typedef TerminalLockVerifier =
    Future<bool> Function(
      BuildContext context,
      AppLockService lock,
      String reason,
    );

enum _Segment { command, agent }

/// Full-screen terminal: run a command on the server through `shell.exec`
/// and watch the live output of the chat's background processes. Nothing runs
/// on the phone, nothing is stored, and the page is blocked from screenshots
/// while it is visible.
class TerminalPaneScreen extends StatefulWidget {
  const TerminalPaneScreen({
    required this.connection,
    required this.profile,
    this.chat,
    this.onOpenSecurity,
    this.gateway,
    this.appLock,
    this.verifyLock,
    super.key,
  });

  final SavedConnection connection;
  final String profile;

  /// The chat whose background processes the Agent segment shows. Null when
  /// the page is opened from Settings.
  final ActiveChat? chat;

  /// Opens Security settings from the App Lock notice.
  final VoidCallback? onOpenSecurity;

  // Test seams.
  final HermesTerminalGateway? gateway;
  final AppLockService? appLock;
  final TerminalLockVerifier? verifyLock;

  @override
  State<TerminalPaneScreen> createState() => _TerminalPaneScreenState();
}

class _TerminalPaneScreenState extends State<TerminalPaneScreen> {
  SharedGatewayLease? _lease;
  late final HermesTerminalGateway _gateway;
  late final TerminalPaneController _controller;
  final TextEditingController _input = TextEditingController();
  AppLockService? _appLock;
  SecureScopeLease? _secureScope;
  bool _disposed = false;
  _Segment _segment = _Segment.command;
  AgentTerminalStream? _stream;
  Timer? _resizeTimer;
  int? _lastCols;
  bool _agentLoadFailed = false;

  @override
  void initState() {
    super.initState();
    final chatGateway = widget.chat?.terminalGateway;
    if (widget.gateway != null) {
      _gateway = widget.gateway!;
    } else if (chatGateway != null) {
      _gateway = chatGateway;
    } else {
      final lease = SharedGatewayPool.instance.acquire(widget.connection);
      _lease = lease;
      _gateway = lease.client;
    }
    _appLock =
        widget.appLock ??
        context.findAncestorStateOfType<HermesAppState>()?.appLock;
    _controller = TerminalPaneController(
      gateway: _gateway,
      profile: widget.profile,
      appLockEnabled: () => _appLock?.enabled ?? false,
      verify: _verify,
      appLocked: _appLock?.locked,
    )..addListener(_onController);
    // Nothing is verified, probed or shown until FLAG_SECURE is applied.
    final secured = _enterSecureScope();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await secured;
      } catch (_) {
        return;
      }
      if (!_disposed) unawaited(_controller.open());
    });
  }

  Future<void> _enterSecureScope() async {
    final prefs = await SharedPreferences.getInstance();
    final lease = await ScreenSecurityService(prefs).pushSecureScope();
    if (_disposed) {
      await lease.release();
      return;
    }
    _secureScope = lease;
  }

  Future<bool> _verify() async {
    final lock = _appLock;
    if (!mounted || lock == null) return false;
    final reason = Strings.of(context).termVerifyReason;
    final verify = widget.verifyLock ?? _defaultVerify;
    return verify(context, lock, reason);
  }

  static Future<bool> _defaultVerify(
    BuildContext context,
    AppLockService lock,
    String reason,
  ) => LockScreen.verify(context, lock, reason: reason);

  void _onController() {
    if (_disposed) return;
    if (_controller.access == TerminalPaneAccess.ready && _stream == null) {
      unawaited(_startAgentStream());
    } else if (_controller.access != TerminalPaneAccess.ready) {
      _stopAgentStream();
    }
    if (_controller.access == TerminalPaneAccess.unsupported) {
      TerminalAvailability.markUnsupported(widget.connection);
    } else if (_controller.access == TerminalPaneAccess.ready) {
      TerminalAvailability.markConfirmed(widget.connection);
    }
    setState(() {});
  }

  Future<void> _startAgentStream() async {
    final chat = widget.chat;
    final runtime = chat?.desktopRuntimeSessionId;
    if (chat == null || runtime == null || runtime.isEmpty) return;
    final stream = AgentTerminalStream();
    _stream = stream;
    chat.setAgentTerminalListener((type, id, chunk) {
      if (type == 'terminal.close') {
        stream.onClose(id);
      } else {
        stream.onChunk(id, chunk);
      }
    });
    try {
      final seeds = await _gateway.agentProcessSeeds(
        runtime,
        profile: widget.profile,
      );
      if (_disposed || !identical(_stream, stream)) return;
      stream.seed(seeds);
    } catch (_) {
      if (_disposed || !identical(_stream, stream)) return;
      setState(() => _agentLoadFailed = true);
    }
  }

  void _stopAgentStream() {
    widget.chat?.setAgentTerminalListener(null);
    _stream?.dispose();
    _stream = null;
  }

  void _onWidth(double width) {
    final runtime = widget.chat?.desktopRuntimeSessionId;
    if (runtime == null || runtime.isEmpty) return;
    final cols = (width / 8).floor().clamp(20, 400);
    if (cols == _lastCols) return;
    _lastCols = cols;
    _resizeTimer?.cancel();
    _resizeTimer = Timer(const Duration(milliseconds: 250), () {
      if (_disposed || _controller.access != TerminalPaneAccess.ready) return;
      unawaited(_gateway.terminalResize(runtime, cols));
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _resizeTimer?.cancel();
    _stopAgentStream();
    _controller
      ..removeListener(_onController)
      ..dispose();
    _input.dispose();
    _lease?.release();
    final scope = _secureScope;
    if (scope != null) unawaited(scope.release());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(s.termTitle)),
      body: SafeArea(
        child: switch (_controller.access) {
          TerminalPaneAccess.idle => const SizedBox.shrink(),
          TerminalPaneAccess.appLockRequired => _notice(
            s.termLockNotice,
            action: widget.onOpenSecurity == null
                ? null
                : HermesNoticeAction(
                    label: s.termLockAction,
                    onPressed: widget.onOpenSecurity!,
                    closesNotice: false,
                  ),
          ),
          TerminalPaneAccess.locked => _locked(s),
          TerminalPaneAccess.unsupported => _notice(s.termUnsupported),
          TerminalPaneAccess.unreachable => _unreachable(s),
          TerminalPaneAccess.ready => _ready(s),
        },
      ),
    );
  }

  Widget _notice(String message, {HermesNoticeAction? action}) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      HermesNoticeCard(
        noticeKey: const ValueKey('terminal-lock-notice'),
        message: message,
        action: action,
        onDismissed: () {},
      ),
    ],
  );

  Widget _locked(Strings s) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(s.termLocked),
        const SizedBox(height: 16),
        HermesActionButton(
          key: const ValueKey('terminal-unlock'),
          label: s.termUnlock,
          primary: true,
          onPressed: () => unawaited(_controller.unlock()),
        ),
      ],
    ),
  );

  Widget _unreachable(Strings s) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(s.termUnreachable),
        const SizedBox(height: 16),
        HermesActionButton(
          key: const ValueKey('terminal-retry'),
          label: s.termRetry,
          primary: true,
          onPressed: () => unawaited(_controller.unlock()),
        ),
      ],
    ),
  );

  Widget _ready(Strings s) {
    final hasAgent = widget.chat != null && _stream != null;
    return LayoutBuilder(
      builder: (context, box) {
        _onWidth(box.maxWidth);
        return Column(
          children: [
            if (hasAgent)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: HermesSegmentedControl<_Segment>(
                  value: _segment,
                  onChanged: (v) => setState(() => _segment = v),
                  segments: [
                    HermesSegment(
                      value: _Segment.command,
                      label: s.termSegCommand,
                    ),
                    HermesSegment(value: _Segment.agent, label: s.termSegAgent),
                  ],
                ),
              ),
            Expanded(
              child: hasAgent && _segment == _Segment.agent
                  ? _AgentProcesses(
                      stream: _stream!,
                      loadFailed: _agentLoadFailed,
                    )
                  : _commandView(s),
            ),
          ],
        );
      },
    );
  }

  String? _problemText(Strings s) => switch (_controller.inputProblem) {
    ShellInputProblem.empty => s.termInputEmpty,
    ShellInputProblem.tooLong => s.termInputTooLong,
    ShellInputProblem.controlCharacter => s.termInputControl,
    null => null,
  };

  Future<void> _pickFromHistory() async {
    final command = await showHermesMenu<String>(
      context: context,
      actions: [
        for (final entry in _controller.history)
          HermesAction(value: entry, label: entry),
      ],
    );
    if (command != null && mounted) _input.text = command;
  }

  void _run() {
    unawaited(_controller.run(_input.text));
  }

  Widget _commandView(Strings s) {
    final colors = Theme.of(context).hermes;
    final result = _controller.lastResult;
    final refusal = _controller.refusal;
    final problem = _problemText(s);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        TextField(
          key: const ValueKey('terminal-input'),
          controller: _input,
          enabled: !_controller.busy,
          minLines: 1,
          maxLines: 4,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.visiblePassword,
          inputFormatters: [_JoinPastedLines(_controller.onPaste)],
          decoration: InputDecoration(
            hintText: s.termCommandHint,
            errorText: problem,
            suffixIcon: _controller.history.isEmpty
                ? null
                : IconButton(
                    key: const ValueKey('terminal-history'),
                    tooltip: s.termHistory,
                    icon: const Icon(Icons.history),
                    onPressed: _pickFromHistory,
                  ),
          ),
        ),
        const SizedBox(height: 12),
        HermesActionButton(
          key: const ValueKey('terminal-run'),
          label: s.termRun,
          primary: true,
          onPressed: _controller.busy ? null : _run,
        ),
        const SizedBox(height: 8),
        Text(
          s.termNote,
          style: TextStyle(fontSize: 12, color: colors.textSecondary),
        ),
        if (_controller.failed) ...[
          const SizedBox(height: 12),
          _notice2(s.termFailed),
        ],
        if (refusal != null) ...[
          const SizedBox(height: 12),
          _notice2(refusal.message),
        ],
        if (result != null) ...[
          const SizedBox(height: 16),
          if (result.stdout.isNotEmpty)
            _block(s.termOutput, result.stdout, colors.textPrimary),
          if (result.stderr.isNotEmpty)
            _block(s.termErrors, result.stderr, colors.textSecondary),
          Text(s.termExit(result.exitCode)),
        ],
      ],
    );
  }

  Widget _notice2(String message) => HermesNoticeCard(
    noticeKey: ValueKey('terminal-notice-${message.hashCode}'),
    kind: HermesNoticeKind.warning,
    message: message,
    onDismissed: () {},
  );

  Widget _block(String label, String text, Color color) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 12)),
        const SizedBox(height: 4),
        SelectableText(
          text,
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 12.5,
            color: color,
          ),
        ),
      ],
    ),
  );
}

/// Turns a multi-line insertion into one line. The text is never run by the
/// paste itself; the user edits it and taps Run.
class _JoinPastedLines extends TextInputFormatter {
  _JoinPastedLines(this.onPaste);

  final void Function(String text) onPaste;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (!newValue.text.contains(RegExp(r'[\r\n]'))) return newValue;
    final joined = joinPastedLines(newValue.text);
    onPaste(newValue.text);
    return TextEditingValue(
      text: joined,
      selection: TextSelection.collapsed(offset: joined.length),
    );
  }
}

class _AgentProcesses extends StatefulWidget {
  const _AgentProcesses({required this.stream, required this.loadFailed});

  final AgentTerminalStream stream;
  final bool loadFailed;

  @override
  State<_AgentProcesses> createState() => _AgentProcessesState();
}

class _AgentProcessesState extends State<_AgentProcesses> {
  String? _selected;
  Terminal? _terminal;
  int _shown = 0;

  @override
  void initState() {
    super.initState();
    widget.stream.addListener(_onStream);
    _ensureSelection();
  }

  @override
  void dispose() {
    widget.stream.setVisible(null);
    widget.stream.removeListener(_onStream);
    super.dispose();
  }

  void _ensureSelection() {
    final ids = widget.stream.ids;
    if (_selected != null && ids.contains(_selected)) return;
    _select(ids.isEmpty ? null : ids.first);
  }

  void _select(String? id) {
    _selected = id;
    widget.stream.setVisible(id);
    if (id == null) {
      _terminal = null;
      _shown = 0;
      return;
    }
    final terminal = Terminal(maxLines: 5000);
    final backlog = widget.stream.backlog(id);
    terminal.write(_crlf(backlog));
    _terminal = terminal;
    _shown = widget.stream.received(id);
  }

  static String _crlf(String text) => text.replaceAll(RegExp(r'\r?\n'), '\r\n');

  void _onStream() {
    if (!mounted) return;
    final id = _selected;
    if (id == null || !widget.stream.ids.contains(id)) {
      setState(_ensureSelection);
      return;
    }
    final received = widget.stream.received(id);
    final delta = received - _shown;
    if (delta > 0) {
      final backlog = widget.stream.backlog(id);
      final start = delta >= backlog.length ? 0 : backlog.length - delta;
      _terminal?.write(_crlf(backlog.substring(start)));
      _shown = received;
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final ids = widget.stream.ids;
    if (ids.isEmpty) {
      return Center(
        child: Text(
          widget.loadFailed ? s.termAgentLoadFailed : s.termAgentEmpty,
        ),
      );
    }
    return Column(
      children: [
        SizedBox(
          height: 48,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              for (final id in ids)
                Padding(
                  padding: const EdgeInsets.only(right: 8, top: 8, bottom: 4),
                  child: ChoiceChip(
                    key: ValueKey('terminal-proc-$id'),
                    selected: id == _selected,
                    label: Text(
                      widget.stream.isClosed(id)
                          ? '${_label(id)} · ${s.termAgentClosed}'
                          : _label(id),
                    ),
                    onSelected: (_) => setState(() => _select(id)),
                  ),
                ),
            ],
          ),
        ),
        if (_terminal != null)
          Expanded(
            child: TerminalView(
              _terminal!,
              theme: TerminalThemes.defaultTheme,
              textStyle: const TerminalStyle(fontSize: 12),
              padding: const EdgeInsets.all(8),
              readOnly: true,
              hardwareKeyboardOnly: true,
            ),
          ),
      ],
    );
  }

  String _label(String id) {
    final command = widget.stream.command(id).trim();
    if (command.isEmpty) return id;
    return command.length > 24 ? '${command.substring(0, 24)}…' : command;
  }
}
