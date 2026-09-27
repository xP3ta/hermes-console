// Rich, interactive notifications for Bot Mode (spec 070 Phase 6).
//
// Dart owns every decision: plain-text copy, which actions exist, lock-screen
// redaction, and every server call. Kotlin (`HermesRichNotifications.kt`) only
// renders the Android templates and records button taps in a durable inbox.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../utils/markdown_clipboard.dart';
import 'notification_service.dart';
import 'notification_strings.dart';

/// Short, human, plain text: no Markdown symbols, one line, bounded.
String plainNotificationText(String? raw, {int max = 180}) {
  if (raw == null) return '';
  var text = markdownToCompactText(raw);
  // Residual inline markers some previews keep after flattening.
  text = text
      .replaceAll(RegExp(r'[`*_~]{1,3}'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (text.length <= max) return text;
  final cut = text.substring(0, max - 1);
  final space = cut.lastIndexOf(' ');
  return '${(space > max * 0.6 ? cut.substring(0, space) : cut).trimRight()}…';
}

/// First line of a reply, plain.
String firstLinePlain(String? raw, {int max = 120}) {
  if (raw == null) return '';
  for (final line in raw.split('\n')) {
    final plain = plainNotificationText(line, max: max);
    if (plain.isNotEmpty) return plain;
  }
  return '';
}

/// Bot Mode copy (en/es), resolved without BuildContext like [NotifL10n].
extension BotNotificationCopy on NotifL10n {
  String _t(String esText, String enText) => es ? esText : enText;

  String approvalNeedsOk(String? command, String? description) {
    final cmd = plainNotificationText(command, max: 90);
    if (cmd.isNotEmpty) {
      return _t('Necesita tu OK para ejecutar “$cmd”',
          'Needs your OK to run “$cmd”');
    }
    final what = plainNotificationText(description, max: 90);
    if (what.isNotEmpty) {
      return _t('Necesita tu OK · $what', 'Needs your OK · $what');
    }
    return _t('Necesita tu OK', 'Needs your OK');
  }

  String needsYou(String who) => _t('$who te necesita', '$who needs you');
  String get newActivity => _t('Nueva actividad', 'New activity');
  String roundDone(List<String> replied) {
    if (replied.isEmpty) return _t('Ronda terminada', 'Round done');
    final names = _joinNames(replied);
    return replied.length == 1
        ? _t('Ronda terminada · $names respondió', 'Round done · $names replied')
        : _t('Ronda terminada · $names respondieron',
            'Round done · $names replied');
  }

  String _joinNames(List<String> names) {
    final unique = names.toSet().toList();
    if (unique.length == 1) return unique.first;
    final and = _t('y', 'and');
    if (unique.length == 2) return '${unique[0]} $and ${unique[1]}';
    final head = unique.take(2).join(', ');
    final rest = unique.length - 2;
    return _t('$head y $rest más', '$head and $rest more');
  }

  String memberFailed(String who) =>
      _t('$who no pudo terminar', '$who couldn’t finish');
  String get roomBlocked => _t('La sala está bloqueada · abre para reintentar',
      'Room is blocked · open to retry');
  String isWorking(String who) =>
      _t('$who está trabajando…', '$who is working…');
  String get roomWorking => _t('La sala está trabajando…', 'Room is working…');
  String get thinking => _t('Pensando…', 'Thinking…');
  String roundWorking(int round, int working, int total) => _t(
      'Ronda $round · $working de $total trabajando',
      'Round $round · $working of $total working');
  String botFinished(String bot, String firstLine) => firstLine.isEmpty
      ? _t('$bot terminó', '$bot finished')
      : _t('$bot terminó · $firstLine', '$bot finished · $firstLine');
  String get you => _t('Tú', 'You');

  String get actApprove => _t('Aprobar', 'Approve');
  String get actDeny => _t('Denegar', 'Deny');
  String get actAlways => _t('Siempre', 'Always');
  String get actReply => _t('Responder', 'Reply');
  String get actStop => _t('Detener', 'Stop');
  String get actStopAll => _t('Detener todo', 'Stop all');
  String replyHint(String who) => _t('Responder a $who', 'Reply to $who');

  String get confirmApproved => _t('Aprobado', 'Approved');
  String get confirmDenied => _t('Denegado', 'Denied');
  String get confirmStopping => _t('Deteniendo…', 'Stopping…');
  String get confirmSent => _t('Enviado', 'Sent');
  String get confirmAlreadyAnswered =>
      _t('Ya estaba respondido', 'Already answered');
  String get confirmAnsweredElsewhere =>
      _t('Respondido en otro dispositivo', 'Answered elsewhere');
  String get confirmFailed =>
      _t('No se pudo enviar · abre Hermes', 'Couldn’t send · open Hermes');

  /// A reply that could not be delivered; the text waits in the composer.
  String get confirmReplyFailed => _t(
    'No se pudo enviar · abre para reintentar',
    'Couldn’t send · open to retry',
  );

  /// The server may have accepted the message but did not confirm it.
  String get confirmMaybeSent =>
      _t('Enviado · abre Hermes para verlo', 'Sent · open Hermes to check');

  /// Lock-screen / hidden-content Live Update copy.
  String get liveWorkingPublic => _t('Trabajando…', 'Working…');
}

/// Which executor handles an action.
enum NotificationActionRoute {
  /// Hosted room: `groups.approve` / `groups.stop` / `groups.send`.
  room,

  /// `/v1/runs/{id}/approval` (REST watched runs).
  run,

  /// Live chat approval owned by the UI `ActiveChatService`.
  chat,

  /// Bot Chat inline reply: `session.resume` + `prompt.submit`.
  botChat,
}

/// Secret-free action payload carried by notification/widget buttons.
///
/// It only holds opaque identifiers the server already validates; tokens and
/// URLs with credentials never enter it.
@immutable
class NotificationActionPayload {
  static const int version = 1;

  final NotificationActionRoute route;
  final String connId;
  final String? profile;
  final String? roomId;
  final String? requestId;
  final String? taskId;
  final String? memberId;
  final int? executionGeneration;
  final List<String> choices;
  final String? runId;
  final String? sessionId;
  final String? threadId;
  final String? title;

  /// Room authority gateway (only used to address the room draft when a
  /// reply has to wait in the composer).
  final String? authorityId;

  const NotificationActionPayload({
    required this.route,
    required this.connId,
    this.profile,
    this.roomId,
    this.requestId,
    this.taskId,
    this.memberId,
    this.executionGeneration,
    this.choices = const [],
    this.runId,
    this.sessionId,
    this.threadId,
    this.title,
    this.authorityId,
  });

  static final RegExp _opaque = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:@+-]{0,255}$');

  String encode() => jsonEncode({
    'v': version,
    'route': route.name,
    'conn': connId,
    'profile': ?profile,
    'room': ?roomId,
    'rid': ?requestId,
    'task': ?taskId,
    'member': ?memberId,
    'gen': ?executionGeneration,
    if (choices.isNotEmpty) 'choices': choices,
    'run': ?runId,
    'sid': ?sessionId,
    'thread': ?threadId,
    'title': ?title,
    'auth': ?authorityId,
  });

  static NotificationActionPayload? tryParse(String? raw) {
    if (raw == null || raw.isEmpty || raw.length > 8000) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded['v'] != version) return null;
      final route = NotificationActionRoute.values
          .where((r) => r.name == decoded['route'])
          .firstOrNull;
      final conn = decoded['conn'];
      if (route == null || conn is! String || !_opaque.hasMatch(conn)) {
        return null;
      }
      String? id(String key) {
        final value = decoded[key];
        if (value == null) return null;
        if (value is! String || !_opaque.hasMatch(value)) {
          throw const FormatException('invalid id');
        }
        return value;
      }

      final gen = decoded['gen'];
      if (gen != null && (gen is! int || gen < 0)) return null;
      final rawChoices = decoded['choices'];
      final choices = <String>[
        if (rawChoices is List)
          for (final c in rawChoices)
            if (c is String && const {'once', 'session', 'always', 'deny'}
                .contains(c))
              c,
      ];
      final title = decoded['title'];
      final payload = NotificationActionPayload(
        route: route,
        connId: conn,
        profile: id('profile'),
        roomId: id('room'),
        requestId: id('rid'),
        taskId: id('task'),
        memberId: id('member'),
        executionGeneration: gen as int?,
        choices: List.unmodifiable(choices),
        runId: id('run'),
        sessionId: id('sid'),
        threadId: id('thread'),
        title: title is String && title.length <= 120 ? title : null,
        authorityId: id('auth'),
      );
      return payload._valid ? payload : null;
    } catch (_) {
      return null;
    }
  }

  bool get _valid => switch (route) {
    NotificationActionRoute.room => roomId != null,
    NotificationActionRoute.run => runId != null,
    NotificationActionRoute.chat => sessionId != null && requestId != null,
    NotificationActionRoute.botChat => sessionId != null && profile != null,
  };

  bool get isRoomApproval =>
      route == NotificationActionRoute.room &&
      requestId != null &&
      taskId != null &&
      memberId != null &&
      executionGeneration != null;
}

/// One tapped button delivered by the native inbox.
@immutable
class PendingNotificationAction {
  final String uid;
  final String action;
  final NotificationActionPayload payload;
  final String? text;
  final int notificationId;
  final String? tag;
  final String source;

  /// A previous executor claimed this tap but never acknowledged it (its
  /// isolate died mid-flight). Idempotent routes run again; others must not.
  final bool reclaimed;

  /// Nobody executed the tap in time and the user was already told it
  /// failed. It is never executed; a reply's text moves to the composer.
  final bool expired;

  const PendingNotificationAction({
    required this.uid,
    required this.action,
    required this.payload,
    required this.notificationId,
    this.text,
    this.tag,
    this.source = 'notification',
    this.reclaimed = false,
    this.expired = false,
  });

  static PendingNotificationAction? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final payload = NotificationActionPayload.tryParse(
      raw['payload'] as String?,
    );
    final uid = raw['uid'];
    final action = raw['action'];
    if (payload == null || uid is! String || action is! String) return null;
    final id = raw['notificationId'];
    return PendingNotificationAction(
      uid: uid,
      action: action,
      payload: payload,
      text: raw['text'] as String?,
      notificationId: id is int ? id : 0,
      tag: raw['tag'] as String?,
      source: raw['source'] as String? ?? 'notification',
      reclaimed: raw['reclaimed'] == true,
      expired: raw['expired'] == true,
    );
  }
}

/// A message in a conversation notification.
@immutable
class RichMessage {
  final String? senderKey;
  final String senderName;
  final String text;
  final String? iconPath;
  final int timeMs;

  const RichMessage({
    required this.senderKey,
    required this.senderName,
    required this.text,
    required this.timeMs,
    this.iconPath,
  });

  Map<String, Object?> toMap() => {
    'senderKey': senderKey ?? 'hermes-user',
    'senderName': senderName,
    'text': text,
    'iconPath': ?iconPath,
    'timeMs': timeMs,
  };
}

@immutable
class RichAction {
  final String id;
  final String label;
  final bool remoteInput;
  final String? hint;
  final bool smartReplies;

  const RichAction(
    this.id,
    this.label, {
    this.remoteInput = false,
    this.hint,
    this.smartReplies = false,
  });

  Map<String, Object?> toMap() => {
    'id': id,
    'label': label,
    if (remoteInput) 'remoteInput': true,
    'hint': ?hint,
    if (smartReplies) 'smartReplies': true,
  };
}

/// Stable notification addresses (tag + id) per Bot/room.
abstract final class RichNotificationIds {
  static const int conversation = 1;
  static const int live = 2;
  static String roomTag(String connId, String roomId) =>
      'hermes.room.${_short('$connId/$roomId')}';
  static String botTag(String connId, String profile) =>
      'hermes.bot.${_short('$connId/$profile')}';
  static int approval(String requestId) =>
      1000 + (_fnv(requestId) & 0x7FFF);

  static String _short(String value) =>
      _fnv(value).toRadixString(16).padLeft(8, '0');

  static int _fnv(String value) {
    var hash = 0x811C9DC5;
    for (final unit in utf8.encode(value)) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash;
  }
}

/// Pure builders for the `hermes/rich_notifications` channel arguments.
class RichNotificationBuilder {
  const RichNotificationBuilder(this.t);

  final NotifL10n t;

  /// Approval: time-sensitive conversation card with the offered choices.
  /// The public (lock-screen) version hides the command.
  Map<String, Object?> approval({
    required String tag,
    required String conversationId,
    required String conversationTitle,
    required bool isGroup,
    required String botKey,
    required String botName,
    String? botIconPath,
    String? command,
    String? description,
    required NotificationActionPayload action,
    required NotificationOpen open,
    required List<String> offered,
    required int nowMs,
    bool hideSensitive = false,
    bool allowAlways = true,
  }) {
    final text = t.approvalNeedsOk(command, description);
    final actions = <RichAction>[
      if (offered.contains('once')) RichAction('approve', t.actApprove),
      if (offered.contains('deny')) RichAction('deny', t.actDeny),
      if (allowAlways &&
          offered.contains('always') &&
          !offered.contains('once'))
        RichAction('always', t.actAlways),
      RichAction('open', t.actOpen),
    ].take(3).toList();
    final visibleText = hideSensitive ? t.needsYou(botName) : text;
    return {
      'id': RichNotificationIds.approval(action.requestId ?? ''),
      'tag': tag,
      'channel': 'approvals',
      'title': isGroup ? conversationTitle : botName,
      'text': visibleText,
      'selfName': t.you,
      'isGroup': isGroup,
      'conversationId': conversationId,
      'conversationTitle': conversationTitle,
      'groupKey': conversationId,
      'alert': true,
      // Re-posting the same pending request never re-sounds.
      'onlyAlertOnce': true,
      'messages': [
        RichMessage(
          senderKey: botKey,
          senderName: botName,
          text: visibleText,
          iconPath: botIconPath,
          timeMs: nowMs,
        ).toMap(),
      ],
      'actions': [for (final a in actions) a.toMap()],
      'publicTitle': t.needsYou(botName),
      'publicText': t.privateBody,
      'openPayload': open.toPayload(),
      'actionPayload': action.encode(),
      'shortcutIconPath': ?botIconPath,
    };
  }

  /// Conversation update (mention, round summary, failure, Bot Chat reply).
  Map<String, Object?> conversation({
    required String tag,
    required String conversationId,
    required String conversationTitle,
    required bool isGroup,
    required List<RichMessage> messages,
    required NotificationOpen open,
    NotificationActionPayload? replyAction,
    String? replyTo,
    bool alert = false,
    String? shortcutIconPath,
    bool hideSensitive = false,
  }) {
    final last = messages.isEmpty ? null : messages.last;
    final shown = hideSensitive
        ? [
            for (final m in messages.take(1))
              RichMessage(
                senderKey: m.senderKey,
                senderName: m.senderName,
                text: t.newActivity,
                iconPath: m.iconPath,
                timeMs: m.timeMs,
              ),
          ]
        : messages.length > 6
        ? messages.sublist(messages.length - 6)
        : messages;
    return {
      'id': RichNotificationIds.conversation,
      'tag': tag,
      'channel': 'conversations',
      'title': isGroup ? conversationTitle : (last?.senderName ?? conversationTitle),
      'text': hideSensitive ? t.newActivity : (last?.text ?? ''),
      'selfName': t.you,
      'isGroup': isGroup,
      'conversationId': conversationId,
      'conversationTitle': conversationTitle,
      'groupKey': conversationId,
      'alert': alert,
      'messages': [for (final m in shown) m.toMap()],
      'actions': [
        if (replyAction != null && !hideSensitive)
          RichAction(
            'reply',
            t.actReply,
            remoteInput: true,
            hint: t.replyHint(replyTo ?? conversationTitle),
            smartReplies: true,
          ).toMap(),
        RichAction('open', t.actOpen).toMap(),
      ],
      'publicTitle': conversationTitle,
      'publicText': t.newActivity,
      'openPayload': open.toPayload(),
      'actionPayload': ?replyAction?.encode(),
      'shortcutIconPath': ?shortcutIconPath,
    };
  }

  /// Default Live Update lifetime: two 30 s working ticks plus margin. Every
  /// tick re-posts (and so renews) it; a listener that stops ticking lets it
  /// expire instead of claiming work without server evidence.
  static const Duration liveTimeout = Duration(seconds: 90);

  /// Live Update: one segment per round member; tracker = working Bot face.
  /// [stopAction] is null on read-only connections (no Stop button).
  Map<String, Object?> liveUpdate({
    required String tag,
    required String conversationId,
    required String title,
    required List<({String name, String state})> members,
    required NotificationOpen open,
    required NotificationActionPayload? stopAction,
    String? workingName,
    String? trackerIconPath,
    int? startedAtMs,
    int? round,
    Duration timeout = liveTimeout,
  }) {
    final working = members.where((m) => m.state == 'working').length;
    final text = workingName != null && workingName.isNotEmpty
        ? t.isWorking(workingName)
        : working > 0
        ? t.roomWorking
        : t.thinking;
    return {
      'id': RichNotificationIds.live,
      'tag': tag,
      'title': title,
      'text': text,
      'subText': round != null && members.isNotEmpty
          ? t.roundWorking(round, working, members.length)
          : null,
      'segments': [
        for (final m in members.take(12)) {'state': m.state},
      ],
      'trackerIconPath': ?trackerIconPath,
      'startedAtMs': ?startedAtMs,
      'shortText': ?(workingName == null || workingName.isEmpty
          ? null
          : workingName.length > 7
          ? workingName.substring(0, 7)
          : workingName),
      'stopLabel': ?(stopAction == null ? null : t.actStopAll),
      'conversationId': conversationId,
      'openPayload': open.toPayload(),
      'actionPayload': ?stopAction?.encode(),
      'timeoutMs': timeout.inMilliseconds,
      // Lock screen: no room, Bot or command names.
      'publicTitle': t.liveWorkingPublic,
      'publicText': t.newActivity,
    };
  }
}

/// Narrow platform surface, faked in tests.
abstract interface class RichNotificationSink {
  /// True when the native renderer accepted the card.
  Future<bool> postConversation(Map<String, Object?> args);
  Future<void> postLiveUpdate(Map<String, Object?> args);
  Future<void> confirm({
    required int id,
    String? tag,
    String? title,
    required String text,
    int timeoutMs,
    bool onlyIfActive,
  });
  Future<void> cancel({required int id, String? tag});
}

/// `hermes/rich_notifications` wrapper. Every call is best effort: a missing
/// native side (tests, iOS, older builds) never breaks the caller.
class PlatformRichNotifications
    implements RichNotificationSink, NotificationActionInbox {
  PlatformRichNotifications({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'hermes/rich_notifications';
  final MethodChannel _channel;

  Future<T?> _call<T>(String method, [Object? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (error) {
      if (kDebugMode) debugPrint('[hermes-rich] $method failed: ${error.code}');
      return null;
    }
  }

  Future<Map<String, Object?>> capabilities() async {
    final raw = await _call<Map<Object?, Object?>>('capabilities');
    return {for (final e in (raw ?? const {}).entries) '${e.key}': e.value};
  }

  Future<bool> openPromotionSettings() async =>
      await _call<bool>('openPromotionSettings') ?? false;

  @override
  Future<bool> postConversation(Map<String, Object?> args) async =>
      await _call<bool>('postConversation', args) ?? false;

  @override
  Future<void> postLiveUpdate(Map<String, Object?> args) =>
      _call<Object?>('postLiveUpdate', args);

  @override
  Future<void> confirm({
    required int id,
    String? tag,
    String? title,
    required String text,
    int timeoutMs = 4000,
    bool onlyIfActive = false,
  }) => _call<bool>('confirm', {
    'id': id,
    'tag': ?tag,
    'title': ?title,
    'text': text,
    'timeoutMs': timeoutMs,
    if (onlyIfActive) 'onlyIfActive': true,
  });

  @override
  Future<void> cancel({required int id, String? tag}) =>
      _call<bool>('cancel', {'id': id, 'tag': ?tag});

  @override
  Future<List<PendingNotificationAction>> takePendingActions(
    Set<NotificationActionRoute> routes,
  ) async {
    final raw = await _call<List<Object?>>('takePendingActions', {
      'routes': [for (final r in routes) r.name],
    });
    return [
      for (final entry in raw ?? const <Object?>[])
        ?PendingNotificationAction.tryParse(entry),
    ];
  }

  /// Removes executed taps from the native inbox (at-least-once delivery:
  /// a tap claimed by an isolate that dies is handed out again).
  @override
  Future<void> ackActions(Iterable<String> uids) async {
    final list = uids.toList();
    if (list.isEmpty) return;
    await _call<bool>('ackPendingActions', {'uids': list});
  }

  /// Tells a headless drain worker this engine is done.
  Future<void> drainFinished() => _call<bool>('drainFinished');

  /// Wakes [onActions] whenever the native inbox receives a tap.
  @override
  void listen(void Function() onActions) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'actionsAvailable') onActions();
      return null;
    });
  }
}

/// Native action inbox (faked in tests).
abstract interface class NotificationActionInbox {
  Future<List<PendingNotificationAction>> takePendingActions(
    Set<NotificationActionRoute> routes,
  );
  Future<void> ackActions(Iterable<String> uids);
  void listen(void Function() onActions);
}

/// Server operations an action may need. Implementations perform exactly
/// the call the in-app control makes.
abstract interface class NotificationActionOps {
  Future<void> roomApprove(NotificationActionPayload p, String choice);
  Future<void> roomStop(NotificationActionPayload p);
  Future<void> roomSend(
    NotificationActionPayload p,
    String text,
    String clientEventId,
  );
  Future<void> runApprove(NotificationActionPayload p, String choice);
  Future<void> chatApprove(NotificationActionPayload p, String choice);
  Future<void> botChatReply(
    NotificationActionPayload p,
    String text,
    String clientTurnId,
  );
}

/// A request that the server no longer holds (answered from Desktop, the app
/// or a second tap) is the outcome the user wanted, not a failure.
bool isAlreadyAnsweredError(Object error) {
  final text = error.toString().toLowerCase();
  const markers = [
    'already',
    'not pending',
    'no longer pending',
    'no pending',
    'unknown request',
    'request not found',
    'approval not found',
    'stale',
    'superseded',
    'http 404',
    'http 409',
    'not_found',
    'conflict',
  ];
  return markers.any(text.contains);
}

/// The request left the device but no acknowledgement came back (timeout,
/// dropped socket, or an ack shape this client cannot verify). The server may
/// have accepted it: never report a retryable failure, never resend.
class AmbiguousDeliveryError implements Exception {
  const AmbiguousDeliveryError(this.cause);
  final Object cause;
  @override
  String toString() => 'AmbiguousDeliveryError(${cause.runtimeType})';
}

enum ActionOutcome { done, alreadyAnswered, maybeDone, failed, ignored }

/// Durable semantic dedupe shared by every drain of one install (UI isolate,
/// listener isolate and headless worker read the same store).
abstract interface class ActionDedupeStore {
  /// `inflight` / `done` / null, pruned by [window].
  Future<String?> stateOf(String key, DateTime now, Duration window);
  Future<void> mark(String key, String state, DateTime now);
  Future<void> forget(String key);
}

class MemoryActionDedupeStore implements ActionDedupeStore {
  final Map<String, ({String state, DateTime at})> _entries = {};

  @override
  Future<String?> stateOf(String key, DateTime now, Duration window) async {
    _entries.removeWhere((_, e) => now.difference(e.at) > window);
    return _entries[key]?.state;
  }

  @override
  Future<void> mark(String key, String state, DateTime now) async =>
      _entries[key] = (state: state, at: now);

  @override
  Future<void> forget(String key) async => _entries.remove(key);
}

/// Executes tapped actions once and updates the card in place.
///
/// Keep ONE router per isolate; its dedupe store is persistent so two taps in
/// different drains (or engines) still count once.
class NotificationActionRouter {
  NotificationActionRouter({
    required this.ops,
    required this.sink,
    required this.t,
    DateTime Function()? now,
    this.dedupeWindow = const Duration(minutes: 2),
    ActionDedupeStore? dedupe,
  }) : _now = now ?? DateTime.now,
       _dedupe = dedupe ?? MemoryActionDedupeStore();

  final NotificationActionOps ops;
  final RichNotificationSink sink;
  NotifL10n t;
  final Duration dedupeWindow;
  final DateTime Function() _now;
  final ActionDedupeStore _dedupe;

  static String semanticKey(PendingNotificationAction a) {
    final p = a.payload;
    final object = p.requestId ?? p.runId ?? p.roomId ?? p.sessionId ?? '';
    // Replies are never deduplicated by meaning: each uid is a new message.
    final discriminator = a.action == 'reply' ? a.uid : a.action;
    return '${p.route.name}/${p.connId}/$object/$discriminator';
  }

  static String? choiceFor(String action, NotificationActionPayload p) {
    final offered = p.choices.isEmpty ? const ['once', 'deny'] : p.choices;
    final choice = switch (action) {
      'approve' => 'once',
      'deny' => 'deny',
      'always' => 'always',
      'session' => 'session',
      _ => null,
    };
    if (choice == null || !offered.contains(choice)) return null;
    // Hosted rooms only accept once|deny (`approve_room_task`).
    if (p.route == NotificationActionRoute.room &&
        choice != 'once' &&
        choice != 'deny') {
      return null;
    }
    return choice;
  }

  /// A retried tap is safe only where the server dedupes it: room approvals
  /// (`request_id`), room replies (`event_id`), runs (`request_id`), chat
  /// approvals (`request_id`). A Bot Chat reply without a verified turn id
  /// could start a second turn.
  static bool _safeToReplay(PendingNotificationAction a) =>
      !(a.action == 'reply' && a.payload.route == NotificationActionRoute.botChat);

  Future<ActionOutcome> handle(PendingNotificationAction a) async {
    final now = _now();
    final key = semanticKey(a);
    final state = await _dedupe.stateOf(key, now, dedupeWindow);
    if (state == 'done') return ActionOutcome.ignored;
    if (state == 'inflight' && !a.reclaimed) return ActionOutcome.ignored;
    if (a.reclaimed && !_safeToReplay(a)) {
      // The previous executor may have delivered it before dying.
      await _dedupe.mark(key, 'done', now);
      await _confirm(a, t.confirmMaybeSent);
      return ActionOutcome.maybeDone;
    }
    await _dedupe.mark(key, 'inflight', now);
    final p = a.payload;
    String confirmation;
    try {
      switch (a.action) {
        case 'approve' || 'deny' || 'always' || 'session':
          final choice = choiceFor(a.action, p);
          if (choice == null) return await _fail(a, key);
          switch (p.route) {
            case NotificationActionRoute.room:
              if (!p.isRoomApproval) return await _fail(a, key);
              await ops.roomApprove(p, choice);
            case NotificationActionRoute.run:
              await ops.runApprove(p, choice);
            case NotificationActionRoute.chat:
              await ops.chatApprove(p, choice);
            case NotificationActionRoute.botChat:
              return await _fail(a, key);
          }
          confirmation = choice == 'deny' ? t.confirmDenied : t.confirmApproved;
        case 'stop':
          if (p.route != NotificationActionRoute.room) {
            return await _fail(a, key);
          }
          await ops.roomStop(p);
          confirmation = t.confirmStopping;
        case 'reply':
          final text = a.text?.trim() ?? '';
          if (text.isEmpty) {
            await _dedupe.forget(key);
            return ActionOutcome.ignored;
          }
          switch (p.route) {
            case NotificationActionRoute.room:
              await ops.roomSend(p, text, 'notif-${a.uid}');
            case NotificationActionRoute.botChat:
              await ops.botChatReply(p, text, 'notif-${a.uid}');
            default:
              return await _fail(a, key);
          }
          confirmation = t.confirmSent;
        default:
          await _dedupe.forget(key);
          return ActionOutcome.ignored;
      }
    } on AmbiguousDeliveryError {
      // Possibly accepted: keep the dedupe mark so nothing resends it.
      await _dedupe.mark(key, 'done', _now());
      await _confirm(a, t.confirmMaybeSent);
      return ActionOutcome.maybeDone;
    } catch (error) {
      if (a.action != 'reply' && isAlreadyAnsweredError(error)) {
        await _dedupe.mark(key, 'done', _now());
        await _confirm(a, t.confirmAlreadyAnswered);
        return ActionOutcome.alreadyAnswered;
      }
      // Nothing reached the server: allow a deliberate retry.
      return _fail(a, key);
    }
    await _dedupe.mark(key, 'done', _now());
    await _confirm(a, confirmation);
    return ActionOutcome.done;
  }

  Future<ActionOutcome> _fail(PendingNotificationAction a, String key) async {
    await _dedupe.forget(key);
    await _confirm(
      a,
      a.action == 'reply' ? t.confirmReplyFailed : t.confirmFailed,
      timeoutMs: a.action == 'reply' ? 0 : 15000,
    );
    return ActionOutcome.failed;
  }

  Future<void> _confirm(
    PendingNotificationAction a,
    String text, {
    int timeoutMs = 4000,
  }) async {
    if (a.source != 'notification') return;
    try {
      await sink.confirm(
        id: a.notificationId,
        tag: a.tag,
        text: text,
        timeoutMs: timeoutMs,
      );
    } catch (_) {}
  }
}
