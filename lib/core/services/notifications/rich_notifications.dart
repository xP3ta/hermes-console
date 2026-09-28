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
      return _t(
        'Necesita tu OK para ejecutar “$cmd”',
        'Needs your OK to run “$cmd”',
      );
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
        ? _t(
            'Ronda terminada · $names respondió',
            'Round done · $names replied',
          )
        : _t(
            'Ronda terminada · $names respondieron',
            'Round done · $names replied',
          );
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
  String get roomBlocked => _t(
    'La sala está bloqueada · abre para reintentar',
    'Room is blocked · open to retry',
  );
  String isWorking(String who) =>
      _t('$who está trabajando…', '$who is working…');
  String isThinking(String who) =>
      _t('$who está pensando…', '$who is thinking…');
  String roundReplied(int done, int total) =>
      _t('$done de $total respondieron', '$done of $total replied');
  String get roomWorking => _t('La sala está trabajando…', 'Room is working…');
  String get thinking => _t('Pensando…', 'Thinking…');
  String roundWorking(int round, int working, int total) => _t(
    'Ronda $round · $working de $total trabajando',
    'Round $round · $working of $total working',
  );
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

  /// Stop on a room's own Live Update: acts on that room only.
  String get actStopRoom => _t('Detener sala', 'Stop room');
  String replyHint(String who) => _t('Responder a $who', 'Reply to $who');

  String get confirmApproved => _t('Aprobado', 'Approved');
  String get confirmDenied => _t('Denegado', 'Denied');
  String get confirmStopping => _t('Deteniendo…', 'Stopping…');
  String get confirmRetrying => _t('Reintentando…', 'Retrying…');
  String get actRetry => _t('Reintentar', 'Retry');
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

  // ── Widgets / multi-room ────────────────────────────────────────────────
  String stepReplied(String who) => _t('$who respondió', '$who replied');
  String stepWorking(String who) => _t('$who trabajando…', '$who working…');
  String get working => _t('Trabajando…', 'Working…');

  /// Group summary suffix: "Atlas · 3 avisos".
  String get alertsLabel => _t('avisos', 'alerts');

  String routineDone(String routine, String line) => line.isEmpty
      ? _t('Terminó «$routine»', 'Finished “$routine”')
      : _t('Terminó «$routine» · $line', 'Finished “$routine” · $line');
  String routineFailed(String routine) =>
      _t('No pudo terminar «$routine»', 'Couldn’t finish “$routine”');

  // Generic Hermes cards (cron / kanban / runs / chats without a Bot).
  String get actViewResult => _t('Ver resultado', 'View result');
  String get actViewReason => _t('Ver motivo', 'See why');
  String get actOpenTask => _t('Abrir tarea', 'Open task');
  String cronDoneLine(String job) => job.isEmpty
      ? _t('Tarea programada terminó', 'Scheduled task finished')
      : _t('Tarea programada terminó · $job', 'Scheduled task finished · $job');
  String cronFailedLine(String job) => job.isEmpty
      ? _t('Tarea programada falló', 'Scheduled task failed')
      : _t('Tarea programada falló · $job', 'Scheduled task failed · $job');

  /// Sender of task-board cards (neutral ">_" face).
  String get senderTasks => _t('Tareas', 'Tasks');

  /// Sender of scheduled-job cards (neutral ">_" face).
  String get senderScheduled => _t('Tareas programadas', 'Scheduled tasks');

  /// Task-board line under the task's own title: "Terminada · Subir build".
  String kanbanStatusLine(String status, String task) {
    final head = switch (status) {
      'done' => _t('Terminada', 'Done'),
      'blocked' => _t('Bloqueada', 'Blocked'),
      'triage' => _t('Te necesita', 'Needs you'),
      _ => _t('Actualizada', 'Updated'),
    };
    return task.isEmpty ? head : '$head · $task';
  }

  /// Scheduled-job line under the job's own title.
  String cronStatusLine(bool ok, String job) {
    final head = ok ? _t('Terminada', 'Done') : _t('Falló', 'Failed');
    return job.isEmpty ? head : '$head · $job';
  }

  String kanbanLine(String status, String task) {
    final head = switch (status) {
      'done' => _t('Tarea terminada', 'Task done'),
      'blocked' => _t('Tarea bloqueada', 'Task blocked'),
      'triage' => _t('Una tarea te necesita', 'A task needs you'),
      _ => _t('Tarea actualizada', 'Task updated'),
    };
    return task.isEmpty ? head : '$head · $task';
  }

  // Lock-screen lines: the state, never names, commands or messages.
  String get publicDone => _t('Terminó', 'Finished');
  String get publicFailed => _t('No pudo terminar', 'Couldn’t finish');
  String get publicNeedsYou => _t('Te necesita', 'Needs you');

  /// Ongoing summary when more rooms work than Live Updates are shown.
  String roomsWorking(int n) => _t('$n salas trabajando', '$n rooms working');

  // ── Room Live Update polish (1.2.14) ────────────────────────────────────
  /// Stops the room's current round (same call as the room's Stop).
  String get actStopRound => _t('Parar ronda', 'Stop round');

  /// Opens that room.
  String get actOpenRoom => _t('Abrir sala', 'Open room');

  /// Expanded per-member row state ("Respondió · 00:41").
  String rowReplied(String? after) => after == null
      ? _t('Respondió', 'Replied')
      : _t('Respondió · $after', 'Replied · $after');
  String get rowTyping => _t('Escribiendo…', 'Typing…');
  String get rowWaiting => _t('En espera', 'Waiting');
  String get rowNeedsYou => _t('Te necesita', 'Needs you');
  String get rowFailed => _t('No pudo terminar', 'Couldn’t finish');

  /// Inline member state after the speaker ("Atlas respondió · 00:41").
  String inlineReplied(String who, String? after) => after == null
      ? _t('$who respondió', '$who replied')
      : _t('$who respondió · $after', '$who replied · $after');
  String inlineTyping(String who) => _t('$who escribiendo…', '$who typing…');
  String inlineWaiting(String who) => _t('$who en espera', '$who waiting');
  String inlineNeedsYou(String who) => _t('$who te necesita', '$who needs you');
  String inlineFailed(String who) =>
      _t('$who no pudo terminar', '$who couldn’t finish');

  /// Lock-safe state word of a quiet card in the grouped summary line.
  String summaryState(int accent) => switch (accent) {
    RichAccent.done => _t('hecho', 'done'),
    RichAccent.failed => _t('falló', 'failed'),
    RichAccent.needsYou => _t('te necesita', 'needs you'),
    _ => _t('nuevo', 'new'),
  };
}

/// "mm:ss" of a reply offset (minutes are not capped at 59).
String roundClock(int ms) {
  final total = ms < 0 ? 0 : ms ~/ 1000;
  final m = (total ~/ 60).toString().padLeft(2, '0');
  final sec = (total % 60).toString().padLeft(2, '0');
  return '$m:$sec';
}

/// Notification accent colours per state (ARGB). The small icon and
/// actions take this tint via `setColor` (never colorized).
abstract final class RichAccent {
  static const int working = 0xFF2F7CF6;
  static const int done = 0xFF32D74B;
  static const int needsYou = 0xFFF5A623;
  static const int failed = 0xFFEF4D4D;
  static const int brand = 0xFFE8821C;
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

  /// Scheduled job: `POST /api/cron/jobs/{id}/trigger` (Retry on a failed
  /// run), the same call as the Cron screen's "Run now".
  cron,
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

  static final RegExp _opaque = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9._:@+-]{0,255}$',
  );

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
            if (c is String &&
                const {'once', 'session', 'always', 'deny'}.contains(c))
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
    NotificationActionRoute.cron => taskId != null,
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
  static int approval(String requestId) => 1000 + (_fnv(requestId) & 0x7FFF);

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
    String? shortcutIconPath,
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
      'shortcutIconPath': ?(shortcutIconPath ?? botIconPath),
      'accent': RichAccent.needsYou,
      'summaryLabel': t.alertsLabel,
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
    int accent = RichAccent.brand,
    String? openLabel,
    String channel = 'conversations',
    String? subText,
    String? text,
    String? alertKey,
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
      'channel': channel,
      'title': isGroup
          ? conversationTitle
          : (last?.senderName ?? conversationTitle),
      'text': hideSensitive ? t.newActivity : (text ?? last?.text ?? ''),
      'subText': ?(hideSensitive ? null : subText),
      'selfName': t.you,
      'isGroup': isGroup,
      'conversationId': conversationId,
      'conversationTitle': conversationTitle,
      'groupKey': conversationId,
      'alert': alert,
      // Identity of the news this post carries: a re-post with the same key
      // updates in place without re-sounding; a new key alerts again even
      // on the same tag + id (a new round after a seen/dismissed card).
      'alertKey': ?alertKey,
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
        RichAction('open', openLabel ?? t.actOpen).toMap(),
      ],
      'publicTitle': conversationTitle,
      'publicText': switch (accent) {
        RichAccent.done => t.publicDone,
        RichAccent.failed => t.publicFailed,
        RichAccent.needsYou => t.publicNeedsYou,
        _ => t.newActivity,
      },
      'openPayload': open.toPayload(),
      'actionPayload': ?replyAction?.encode(),
      'shortcutIconPath': ?shortcutIconPath,
      'accent': accent,
      'summaryLabel': t.alertsLabel,
      // Lock-safe line of the grouped "Hermes Console · N more" summary:
      // the same name the public version already shows, plus the state.
      'summaryLine': '$conversationTitle · ${t.summaryState(accent)}',
    };
  }

  /// Every non-Bot Hermes event (Cron, Kanban, runs, normal chats, goals)
  /// in the same conversation-card style as Bot events: a "Hermes" (or
  /// owner) sender with the resolved face, one plain line, the state accent
  /// and verbs. [identityKey] is the per-source conversation (one shortcut
  /// per job/task/chat); the lock-screen version keeps only the state.
  Map<String, Object?> hermesCard({
    required String? tag,
    required int id,
    required String identityKey,
    required String senderName,
    required String line,
    required NotificationOpen open,
    required int accent,
    String? iconPath,
    String? subText,
    List<RichAction> actions = const [],
    NotificationActionPayload? action,
    bool alert = false,
    bool hideSensitive = false,
    String channel = 'conversations',
    String? conversationTitle,
    required int nowMs,
  }) => {
    'id': id,
    'tag': ?tag,
    'channel': channel,
    // A task/job card is its own conversation titled by the task/job name;
    // the sender ("Tareas", a Bot) speaks inside it.
    'title': (hideSensitive ? null : conversationTitle) ?? senderName,
    'text': hideSensitive ? t.newActivity : line,
    'selfName': t.you,
    'isGroup': conversationTitle != null && !hideSensitive,
    'conversationId': identityKey,
    'conversationTitle':
        (hideSensitive ? null : conversationTitle) ?? senderName,
    'groupKey': identityKey,
    'alert': alert,
    'onlyAlertOnce': true,
    'messages': [
      RichMessage(
        senderKey: 'hermes:$identityKey',
        senderName: senderName,
        text: hideSensitive ? t.newActivity : line,
        iconPath: iconPath,
        timeMs: nowMs,
      ).toMap(),
    ],
    'actions': [
      for (final a in actions.take(3))
        if (!hideSensitive || a.id == 'open') a.toMap(),
    ],
    'subText': ?subText,
    'publicTitle': senderName,
    'publicText': switch (accent) {
      RichAccent.done => t.publicDone,
      RichAccent.failed => t.publicFailed,
      RichAccent.needsYou => t.publicNeedsYou,
      _ => t.newActivity,
    },
    'openPayload': open.toPayload(),
    'actionPayload': ?action?.encode(),
    'shortcutIconPath': ?iconPath,
    'accent': accent,
    'summaryLabel': t.alertsLabel,
    'summaryLine': '$senderName · ${t.summaryState(accent)}',
  };

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
    bool thinking = false,
    String? trackerIconPath,
    String? largeIconPath,
    int? startedAtMs,
    int? round,
    Duration timeout = liveTimeout,
    Map<String, int> repliedAfterMs = const {},
  }) {
    final working = members.where((m) => m.state == 'working').length;
    final done = members.where((m) => m.state == 'done').length;
    final named = workingName != null && workingName.isNotEmpty;
    final needing = members.where((m) => m.state == 'needs_you').toList();
    // One headline that says who does what: someone needing you wins, then
    // the working Bot by name, else the room. Never a bare "Thinking…".
    final head = needing.isNotEmpty
        ? t.needsYou(needing.first.name)
        : named
        ? (thinking ? t.isThinking(workingName) : t.isWorking(workingName))
        : t.roomWorking;
    final headName = needing.isNotEmpty
        ? needing.first.name
        : (named ? workingName : null);
    // Replied members first, then the working one.
    int rank(String s) => switch (s) {
      'done' => 0,
      'working' => 1,
      'needs_you' => 2,
      _ => 3,
    };
    final ordered = [...members]
      ..sort((a, b) => rank(a.state).compareTo(rank(b.state)));
    String? after(String name) {
      final ms = repliedAfterMs[name];
      return ms == null ? null : roundClock(ms);
    }

    // One row per member (face + name + state + time) for the expanded
    // card. Android 16's ProgressStyle cannot host rows, so the promoted
    // card carries them inline in its 2-line expanded text, the speaker
    // first; the non-promoted fallback shows them one per line.
    final rows = [
      for (final m in ordered.take(12))
        {
          'name': m.name,
          'state': m.state,
          'line': switch (m.state) {
            'done' => t.rowReplied(after(m.name)),
            'working' => t.rowTyping,
            'needs_you' => t.rowNeedsYou,
            'failed' => t.rowFailed,
            _ => t.rowWaiting,
          },
        },
    ];
    final others = [
      for (final m in ordered.take(12))
        if (m.name != headName)
          switch (m.state) {
            'done' => t.inlineReplied(m.name, after(m.name)),
            'working' => t.inlineTyping(m.name),
            'needs_you' => t.inlineNeedsYou(m.name),
            'failed' => t.inlineFailed(m.name),
            _ => t.inlineWaiting(m.name),
          },
    ];
    final text = [head, ...others].join(' · ');
    return {
      'id': RichNotificationIds.live,
      'tag': tag,
      'title': title,
      'text': text,
      'rows': rows,
      'bigText': rows.isEmpty
          ? head
          : [for (final r in rows) '${r['name']} · ${r['line']}'].join('\n'),
      'subText': members.isEmpty
          ? null
          : round != null
          ? t.roundWorking(round, working, members.length)
          : t.roundReplied(done, members.length),
      // No progress bar: "2 of 4 replied" is not a percentage, and a bar
      // that moves without measuring anything only confuses. State is text.
      'trackerIconPath': ?trackerIconPath,
      'largeIconPath': ?(largeIconPath ?? trackerIconPath),
      'startedAtMs': ?startedAtMs,
      // Status-bar chip: a name, never an ambiguous "x/y" count.
      'shortText': ?(headName == null
          ? null
          : (headName.length > 7 ? headName.substring(0, 7) : headName)),
      'stopLabel': ?(stopAction == null ? null : t.actStopRound),
      'openLabel': t.actOpenRoom,
      'conversationId': conversationId,
      'openPayload': open.toPayload(),
      'actionPayload': ?stopAction?.encode(),
      'timeoutMs': timeout.inMilliseconds,
      'accent': RichAccent.working,
      // Lock screen: no room, Bot or command names; counts only.
      'publicTitle': t.liveWorkingPublic,
      'publicText': round != null && members.isNotEmpty
          ? t.roundWorking(round, working, members.length)
          : t.newActivity,
    };
  }

  /// Tag of the ongoing summary that stands in for rooms beyond the Live
  /// Update cap.
  static const liveSummaryTag = 'hermes.live.summary';

  /// Ongoing summary ("3 salas trabajando") listing the rooms that did not
  /// get their own Live Update. Not promoted and without Stop: each room's
  /// Stop lives only on its own card (or in the room).
  Map<String, Object?> liveSummary({
    required List<String> roomNames,
    required int total,
    NotificationOpen? open,
    Duration timeout = liveTimeout,
  }) => {
    'id': RichNotificationIds.live,
    'tag': liveSummaryTag,
    'title': t.roomsWorking(total),
    'text': roomNames.take(6).join(' · '),
    'promote': false,
    'openPayload': ?open?.toPayload(),
    'timeoutMs': timeout.inMilliseconds,
    'accent': RichAccent.working,
    'publicTitle': t.liveWorkingPublic,
    'publicText': t.newActivity,
  };
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

  /// Re-posts the foreground-service card with the neutral ">_" glyph as its
  /// large icon (the plugin otherwise shows the launcher portrait).
  Future<bool> decorateServiceNotification() async =>
      await _call<bool>('decorateServiceNotification') ?? false;

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

  /// Runs the scheduled job [NotificationActionPayload.taskId] now.
  Future<void> cronTrigger(NotificationActionPayload p);
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
    final object =
        p.requestId ?? p.runId ?? p.roomId ?? p.taskId ?? p.sessionId ?? '';
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
      !(a.action == 'reply' &&
          a.payload.route == NotificationActionRoute.botChat);

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
            case NotificationActionRoute.botChat ||
                NotificationActionRoute.cron:
              return await _fail(a, key);
          }
          confirmation = choice == 'deny' ? t.confirmDenied : t.confirmApproved;
        case 'retry':
          if (p.route != NotificationActionRoute.cron) {
            return await _fail(a, key);
          }
          await ops.cronTrigger(p);
          confirmation = t.confirmRetrying;
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
