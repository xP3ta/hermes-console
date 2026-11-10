// Where "a session needs the user" enters the notification layer, like Desktop's
// `dispatchNativeNotification` (apps/desktop/src/store/native-notifications.ts).
// No producer, no transport: whatever detects a signal calls `deliver`.
import 'notification_service.dart';

enum SessionAttentionKind { approval, input, turnDone, turnError }

class SessionAttentionSignal {
  const SessionAttentionSignal({
    required this.kind,
    required this.connId,
    required this.profile,
    required this.storedSessionId,
    this.requestId,
    this.title,
    this.preview = '',
    this.tool = '',
    this.question = '',
    this.endedAtMs,
    this.backgroundCheck = false,
  });

  final SessionAttentionKind kind;
  final String connId;
  final String profile;
  final String storedSessionId;
  final String? requestId;
  final String? title;
  final String preview;
  final String tool;
  final String question;

  /// When the source stamped the end of the turn (the final row's time);
  /// a live row of a turn that began after it is not ended by this signal.
  final int? endedAtMs;

  /// The background check of a live row found the turn over by reading its
  /// durable rows (`LiveTurnBackgroundCheck`): a finished turn is told as
  /// «xPeta · terminó» ([NotificationService.liveTurnFinished]), and only if
  /// its row was still in the tray (the chat's own socket, still alive, may
  /// have ended it and told it already).
  final bool backgroundCheck;
}

abstract interface class SessionAttentionSink {
  Future<void> deliver(SessionAttentionSignal signal);
}

class NotificationSessionAttentionSink implements SessionAttentionSink {
  NotificationSessionAttentionSink(this._notifications);

  final NotificationService _notifications;
  final Set<String> _delivered = {};

  @override
  Future<void> deliver(SessionAttentionSignal s) async {
    final request = s.requestId?.trim() ?? '';
    final id = s.storedSessionId;
    final profile = s.profile;
    final title = _notifications.sessionNoticeTitle(s.connId, profile, s.title);
    final key = [s.kind, s.connId, profile, id, request].join('|');
    if (request.isNotEmpty && !_delivered.add(key)) return;
    final ending =
        s.kind == SessionAttentionKind.turnDone ||
        s.kind == SessionAttentionKind.turnError;
    // Read before the row goes: the check only tells a turn whose row it saw.
    final rowShown = ending && _notifications.liveTurnShown(id);
    if (ending) {
      // The turn is over: its live row («Pensando…») goes, even when the
      // chat's own socket, cut in the background, never said so.
      await _notifications.liveTurnEnded(id, endedAtMs: s.endedAtMs);
    }
    if (ending && s.backgroundCheck && !rowShown) return;
    await switch (s.kind) {
      SessionAttentionKind.approval => _notifications.approvalPending(
        tool: s.tool.isEmpty ? title : s.tool,
        description: s.tool.isEmpty ? null : s.tool,
        connId: s.connId,
        sessionId: id,
        sessionTitle: title,
        runId: id,
        approvalId: s.requestId,
        profile: profile,
        blind: true,
      ),
      SessionAttentionKind.input => _notifications.questionPending(
        connId: s.connId,
        sessionId: id,
        requestId: request,
        profile: profile,
        sessionTitle: title,
        question: s.question,
        answerable: false,
      ),
      SessionAttentionKind.turnDone when s.backgroundCheck =>
        _notifications.liveTurnFinished(
          connId: s.connId,
          profile: profile,
          sessionId: id,
          title: s.title,
          preview: s.preview,
        ),
      SessionAttentionKind.turnDone => _notifications.replyReady(
        preview: s.preview,
        session: title,
        connId: s.connId,
        sessionId: id,
        profile: profile,
      ),
      SessionAttentionKind.turnError => _notifications.replyFailed(
        session: title,
        connId: s.connId,
        sessionId: id,
        profile: profile,
      ),
    };
  }
}
