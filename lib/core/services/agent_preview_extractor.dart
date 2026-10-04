/// Agent previews of one conversation, from its transcript.
///
/// The agent's `desktop_preview` tool opens (`action: open`) and closes
/// (`action: close`) targets. Replaying those calls in transcript order gives
/// what is open now, whoever owned the turn and across app restarts.
library;

import '../models/deferred_tool_call.dart';
import 'agent_preview_target.dart';

const String agentPreviewToolName = 'desktop_preview';

final class AgentPreview {
  const AgentPreview({required this.target, required this.label});

  final AgentPreviewTarget target;

  /// The tool's label, else the host or the file name.
  final String label;
}

final RegExp _unsafeLabel = RegExp(r'[\u0000-\u001f\u007f  ]');

/// Open previews after replaying [newestFirst] (Console transcript order),
/// oldest opened first.
List<AgentPreview> collectAgentPreviews(
  List<Map<String, dynamic>> newestFirst,
) {
  final open = <String, AgentPreview>{};
  for (final message in newestFirst.reversed) {
    if (message['role']?.toString().trim().toLowerCase() != 'assistant') {
      continue;
    }
    final calls = message['tool_calls'];
    if (calls is! List) continue;
    for (final raw in calls) {
      if (raw is! Map) continue;
      final function = raw['function'];
      final name = (function is Map ? function['name'] : raw['name'])
          ?.toString();
      if (name == null) continue;
      final arguments = function is Map
          ? function['arguments']
          : raw['arguments'];
      final unwrapped = unwrapDeferredToolCall(name, arguments);
      final entries =
          unwrapped ??
          [(name: name, arguments: decodeToolArguments(arguments))];
      for (final entry in entries) {
        if (entry.name.trim().toLowerCase() != agentPreviewToolName) continue;
        _apply(open, entry.arguments);
      }
    }
  }
  return List.unmodifiable(open.values);
}

void _apply(Map<String, AgentPreview> open, Object? arguments) {
  if (arguments is! Map) return;
  final action = arguments['action'];
  final url = arguments['url'];
  switch (action is String ? action.trim().toLowerCase() : null) {
    case 'open':
      if (url is! String) return;
      final target = classifyAgentPreviewTarget(url);
      if (target == null) return;
      final label = _label(arguments['label'], target);
      // Opening an open target keeps its place and refreshes its label.
      open[target.url] = AgentPreview(target: target, label: label);
    case 'close':
      final text = url is String ? url.trim() : '';
      if (text.isEmpty) {
        open.clear();
        return;
      }
      final target = classifyAgentPreviewTarget(text);
      if (target != null) open.remove(target.url);
  }
}

String _label(Object? raw, AgentPreviewTarget target) {
  if (raw is String) {
    final text = raw.trim();
    if (text.isNotEmpty && text.length <= 120 && !text.contains(_unsafeLabel)) {
      return text;
    }
  }
  final path = target.filePath;
  if (path != null) {
    final name = path
        .split(RegExp(r'[\\/]'))
        .where((s) => s.isNotEmpty)
        .lastOrNull;
    return name ?? path;
  }
  final host = Uri.tryParse(target.url)?.host ?? target.url;
  return host.startsWith('www.') ? host.substring(4) : host;
}
