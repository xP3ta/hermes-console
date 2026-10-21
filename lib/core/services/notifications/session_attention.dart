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
  });

  final SessionAttentionKind kind;
  final String connId;
  final String profile;
  final String storedSessionId;
  final String? requestId;
  final String? title;
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
    final (id, title, profile) = (s.storedSessionId, s.title ?? '', s.profile);
    final key = [s.kind, s.connId, profile, id, request].join('|');
    if (request.isNotEmpty && !_delivered.add(key)) return;
    await switch (s.kind) {
      SessionAttentionKind.approval => _notifications.approvalPending(
        tool: title,
        connId: s.connId,
        sessionId: id,
        sessionTitle: title,
        runId: id,
        approvalId: s.requestId,
        profile: profile,
      ),
      SessionAttentionKind.input => _notifications.questionPending(
        connId: s.connId,
        sessionId: id,
        requestId: request,
        profile: profile,
        sessionTitle: title,
        answerable: false,
      ),
      SessionAttentionKind.turnDone => _notifications.replyReady(
        preview: '',
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
