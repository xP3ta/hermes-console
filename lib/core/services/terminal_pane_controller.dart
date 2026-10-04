import 'package:flutter/foundation.dart';

import '../models/terminal_exec.dart';

/// Where the terminal page stands before it may run anything.
enum TerminalPaneAccess {
  /// Nothing checked yet.
  idle,

  /// App Lock is off: the page only explains how to turn it on.
  appLockRequired,

  /// App Lock is on but not verified for this visit (or it re-locked).
  locked,

  /// The server has no `shell.exec`, or the connection is read-only.
  unsupported,

  ready,
}

/// Joins a pasted block into one line. A paste never runs anything: the user
/// edits it and taps Run.
String joinPastedLines(String text) =>
    text.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();

/// Logic of the terminal page. Everything it holds (history, the shown
/// result, the pasted text) lives in memory for the life of the page and is
/// wiped on dispose, on re-lock and on a profile switch. Nothing is logged or
/// written anywhere.
class TerminalPaneController extends ChangeNotifier {
  TerminalPaneController({
    required HermesTerminalGateway gateway,
    required String profile,
    required bool Function() appLockEnabled,
    required Future<bool> Function() verify,
    ValueListenable<bool>? appLocked,
  }) : _gateway = gateway,
       _profile = profile,
       _appLockEnabled = appLockEnabled,
       _verify = verify,
       _appLocked = appLocked {
    _appLocked?.addListener(_onAppLocked);
  }

  static const int historyLimit = 20;

  final HermesTerminalGateway _gateway;
  final bool Function() _appLockEnabled;
  final Future<bool> Function() _verify;
  final ValueListenable<bool>? _appLocked;
  String _profile;
  int _epoch = 0;
  bool _disposed = false;

  TerminalPaneAccess _access = TerminalPaneAccess.idle;
  bool _busy = false;
  ShellExecResult? _lastResult;
  ShellExecRefusal? _refusal;
  ShellInputProblem? _inputProblem;
  bool _failed = false;
  String _pasted = '';
  final List<String> _history = [];
  int _recall = -1;

  TerminalPaneAccess get access => _access;
  bool get busy => _busy;
  ShellExecResult? get lastResult => _lastResult;
  ShellExecRefusal? get refusal => _refusal;
  ShellInputProblem? get inputProblem => _inputProblem;
  bool get failed => _failed;
  String get pasted => _pasted;

  /// Newest first.
  List<String> get history => List.unmodifiable(_history);

  @override
  String toString() => 'TerminalPaneController($_access)';

  /// Checks App Lock, verifies the user, then probes the server once with an
  /// empty command (which the server refuses with 4004 without running
  /// anything) to learn whether `shell.exec` exists.
  Future<void> open() async {
    if (_disposed) return;
    if (!_appLockEnabled()) {
      _setAccess(TerminalPaneAccess.appLockRequired);
      return;
    }
    await unlock();
  }

  /// Verifies the user again, then probes. Used for the first open and after
  /// a re-lock.
  Future<void> unlock() async {
    if (_disposed) return;
    if (!_appLockEnabled()) {
      _setAccess(TerminalPaneAccess.appLockRequired);
      return;
    }
    final epoch = _epoch;
    final ok = await _verify();
    if (_disposed || epoch != _epoch) return;
    if (!ok) {
      _setAccess(TerminalPaneAccess.locked);
      return;
    }
    if (!_gateway.shellExecAvailable) {
      _setAccess(TerminalPaneAccess.unsupported);
      return;
    }
    try {
      await _gateway.shellExec('', profile: _profile);
    } on ShellExecUnsupported {
      if (_disposed || epoch != _epoch) return;
      _setAccess(TerminalPaneAccess.unsupported);
      return;
    } catch (_) {
      // 4004 (empty command) proves the method exists; any other failure
      // surfaces on the first real run.
    }
    if (_disposed || epoch != _epoch) return;
    _setAccess(TerminalPaneAccess.ready);
  }

  Future<void> run(String raw) async {
    if (_disposed || _busy) return;
    if (_access != TerminalPaneAccess.ready) return;
    if (!_appLockEnabled()) {
      _setAccess(TerminalPaneAccess.appLockRequired);
      return;
    }
    final checked = sanitizeShellCommand(raw);
    _refusal = null;
    _failed = false;
    _inputProblem = checked.problem;
    final command = checked.command;
    if (command == null) {
      notifyListeners();
      return;
    }
    _remember(command);
    _busy = true;
    _lastResult = null;
    final epoch = _epoch;
    notifyListeners();
    try {
      final result = await _gateway.shellExec(command, profile: _profile);
      if (_disposed || epoch != _epoch) return;
      _lastResult = result;
    } on ShellExecUnsupported {
      if (_disposed || epoch != _epoch) return;
      _access = TerminalPaneAccess.unsupported;
    } on ShellExecRefusal catch (error) {
      if (_disposed || epoch != _epoch) return;
      _refusal = error;
    } catch (_) {
      if (_disposed || epoch != _epoch) return;
      _failed = true;
    } finally {
      if (!_disposed && epoch == _epoch) {
        _busy = false;
        notifyListeners();
      } else if (!_disposed) {
        _busy = false;
      }
    }
  }

  void onPaste(String text) {
    _pasted = joinPastedLines(text);
    notifyListeners();
  }

  void _remember(String command) {
    _recall = -1;
    if (_history.isNotEmpty && _history.first == command) return;
    _history.insert(0, command);
    if (_history.length > historyLimit) _history.removeLast();
  }

  /// Steps back through the history; stays on the oldest entry.
  String recallOlder() {
    if (_history.isEmpty) return '';
    if (_recall < _history.length - 1) _recall += 1;
    return _history[_recall];
  }

  /// Steps forward; an empty string means back to a blank input.
  String recallNewer() {
    if (_recall <= 0) {
      _recall = -1;
      return '';
    }
    _recall -= 1;
    return _history[_recall];
  }

  void switchProfile(String profile) {
    if (_disposed || profile == _profile) return;
    _profile = profile;
    _epoch += 1;
    _wipe();
    notifyListeners();
  }

  void _onAppLocked() {
    if (_disposed || _appLocked?.value != true) return;
    _epoch += 1;
    _wipe();
    _access = TerminalPaneAccess.locked;
    notifyListeners();
  }

  void _wipe() {
    _history.clear();
    _recall = -1;
    _lastResult = null;
    _refusal = null;
    _inputProblem = null;
    _failed = false;
    _pasted = '';
    _busy = false;
  }

  void _setAccess(TerminalPaneAccess access) {
    if (_access == access) return;
    _access = access;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _epoch += 1;
    _appLocked?.removeListener(_onAppLocked);
    _wipe();
    super.dispose();
  }
}
