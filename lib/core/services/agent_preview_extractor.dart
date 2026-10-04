/// Agent previews of one conversation, from its transcript.
///
/// The agent's `desktop_preview` tool opens (`action: open`) and closes
/// (`action: close`) targets. Replaying those calls in transcript order gives
/// what is open now, whoever owned the turn and across app restarts.
library;

import 'agent_preview_target.dart';

final class AgentPreview {
  const AgentPreview({required this.target, required this.label});

  final AgentPreviewTarget target;

  /// The tool's label, else the host or the file name.
  final String label;
}

/// Open previews after replaying [newestFirst] (Console transcript order),
/// oldest opened first.
List<AgentPreview> collectAgentPreviews(
  List<Map<String, dynamic>> newestFirst,
) => const [];
