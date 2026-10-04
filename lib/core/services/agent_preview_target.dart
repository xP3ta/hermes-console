/// Where an agent «preview» (the `desktop_preview` tool's target) can be
/// opened from the phone.
///
/// Desktop shows these in an Electron webview next to the chat; Console has no
/// such surface, so each target is either handed to the system browser, opened
/// through the existing server-file flow, or declared reachable only from the
/// machine the agent runs on.
library;

enum AgentPreviewReach {
  /// `http(s)` on a public host: the system browser can open it.
  web,

  /// A file on the Hermes server: the existing server-file flow opens it.
  serverFile,

  /// `localhost`, loopback, `0.0.0.0`, private ranges: the agent's own
  /// machine, not reachable from here.
  serverOnly,
}

final class AgentPreviewTarget {
  const AgentPreviewTarget({
    required this.url,
    required this.reach,
    this.filePath,
  });

  /// Normalized target, the identity used to open and to close a preview.
  final String url;
  final AgentPreviewReach reach;

  /// Absolute server path for [AgentPreviewReach.serverFile].
  final String? filePath;
}

/// Normalizes [raw] like the tool does (`www.x.com` → `https://www.x.com`,
/// `localhost:3000` → `http://localhost:3000`, paths and `file:` kept) and
/// classifies it. Null when it is not a usable preview target.
AgentPreviewTarget? classifyAgentPreviewTarget(String raw) => null;
