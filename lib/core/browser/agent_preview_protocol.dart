/// Wire contract between the gateway client and whatever answers the
/// window-owned preview bridges (`preview.read`, `preview.act`). Kept free of
/// Flutter so the client can depend on it.
///
/// Hermes Desktop answers these from the window that shows the session and
/// declines from every other window with [previewNotShownCode]; the backend
/// settles the request with its "not shown" message once every attached
/// client declined (`tui_gateway/server_requests.py`, NOT_SHOWN_CODE).
library;

/// Error code a client answers when it does not show the request's session
/// (`tui_gateway/server_requests.py`, `NOT_SHOWN_CODE`).
const int previewNotShownCode = 4404;

/// Server→client methods the in-app browser may answer.
const Set<String> previewBridgeMethods = {'preview.read', 'preview.act'};

/// One `preview.read` / `preview.act` request for a session.
class PreviewBridgeRequest {
  const PreviewBridgeRequest({
    required this.method,
    required this.connectionId,
    required this.sessionId,
    required this.params,
    required this.isOpen,
  });

  final String method;

  /// The connection the request came in on (`SavedConnection.id`): a
  /// runtime id only names a session on its own gateway, so the same id on
  /// another connection is another chat.
  final String connectionId;

  /// The runtime session the request names.
  final String sessionId;

  /// Request params without `session_id` (`start`/`count` for a read).
  final Map<String, dynamic> params;

  /// False once Hermes withdrew the request (timeout, interrupt, transport
  /// replaced): nothing may be read for an answer nobody waits for.
  final bool Function() isOpen;
}

/// What the browser answers: a `value` string (JSON, or empty for nothing),
/// or a decline because this app does not show that session's page.
class PreviewBridgeAnswer {
  const PreviewBridgeAnswer.value(this.value) : notShown = false;

  const PreviewBridgeAnswer.notShown() : value = '', notShown = true;

  final String value;
  final bool notShown;
}

/// Answers window-owned preview requests (the app's agent browser bridge).
abstract interface class PreviewRequestBridge {
  Future<PreviewBridgeAnswer> answer(PreviewBridgeRequest request);
}
