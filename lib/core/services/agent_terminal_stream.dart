import 'package:flutter/foundation.dart';

import '../models/terminal_exec.dart';

/// In-memory output of the agent's background processes while the terminal
/// page is open. Bounded like Hermes Desktop: 256 000 characters per process,
/// 24 processes, 2 000 000 characters in all, and the process on screen is
/// never evicted. Disposing it drops everything and ignores later chunks.
class AgentTerminalStream extends ChangeNotifier {
  AgentTerminalStream({
    this.maxBacklog = 256000,
    this.maxProcesses = 24,
    this.maxTotal = 2000000,
  });

  final int maxBacklog;
  final int maxProcesses;
  final int maxTotal;

  final Map<String, _Proc> _procs = {};
  String? _visible;
  bool _disposed = false;
  int _tick = 0;

  List<String> get ids => _procs.keys.toList(growable: false);

  String backlog(String id) => _procs[id]?.text ?? '';

  String command(String id) => _procs[id]?.command ?? '';

  /// Characters ever appended to [id], trimmed or not. A view that has shown
  /// `n` of them writes only the difference.
  int received(String id) => _procs[id]?.received ?? 0;

  bool isClosed(String id) => _procs[id]?.closed ?? false;

  int get totalChars => _procs.values.fold(0, (sum, p) => sum + p.text.length);

  /// The process the page shows; it is exempt from eviction.
  void setVisible(String? id) => _visible = id;

  /// First read of `process.list`. A process that already received chunks
  /// keeps them; the tail only fills processes the page has not seen.
  void seed(List<AgentProcessSeed> seeds) {
    if (_disposed) return;
    for (final seed in seeds) {
      final known = _procs[seed.id];
      if (known != null) {
        if (known.command.isEmpty) known.command = seed.command;
        known.closed = known.closed || seed.closed;
        continue;
      }
      final proc = _proc(seed.id);
      proc.command = seed.command;
      proc.closed = seed.closed;
      _append(proc, seed.outputTail);
    }
    _enforce();
    notifyListeners();
  }

  void onChunk(String id, String chunk) {
    if (_disposed || id.isEmpty) return;
    final proc = _proc(id);
    _append(proc, chunk);
    proc.touched = ++_tick;
    _enforce();
    notifyListeners();
  }

  void onClose(String id) {
    if (_disposed) return;
    final proc = _procs[id];
    if (proc == null || proc.closed) return;
    proc.closed = true;
    notifyListeners();
  }

  _Proc _proc(String id) => _procs.putIfAbsent(id, () {
    final proc = _Proc();
    proc.touched = ++_tick;
    return proc;
  });

  void _append(_Proc proc, String chunk) {
    if (chunk.isEmpty) return;
    proc.received += chunk.length;
    var text = proc.text + chunk;
    if (text.length > maxBacklog) {
      text = text.substring(text.length - maxBacklog);
    }
    proc.text = text;
  }

  void _enforce() {
    while (_procs.length > maxProcesses && _evictOldest()) {}
    while (totalChars > maxTotal && _evictOldest()) {}
  }

  bool _evictOldest() {
    String? victim;
    var oldest = 1 << 62;
    for (final entry in _procs.entries) {
      if (entry.key == _visible) continue;
      if (entry.value.touched < oldest) {
        oldest = entry.value.touched;
        victim = entry.key;
      }
    }
    if (victim == null) return false;
    _procs.remove(victim);
    return true;
  }

  @override
  void dispose() {
    _disposed = true;
    _procs.clear();
    super.dispose();
  }
}

class _Proc {
  String text = '';
  String command = '';
  int received = 0;
  bool closed = false;
  int touched = 0;
}
