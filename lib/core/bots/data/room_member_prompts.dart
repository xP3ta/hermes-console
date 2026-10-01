/// Human prompts (clarify questions, command approvals) that block a hosted
/// room member's bound session.
///
/// The hosted room projection (`groups.state.driver_status.pending_actions`)
/// only carries approvals the driver itself observed; a `clarify` question
/// raised inside the member's hidden `Group: <room_id>` session never reaches
/// the room. Desktop recovers it from the member session's `open_requests`
/// (`apps/desktop/src/plugins/hermes-bots/group-turns.ts::syncGroupClarify`).
/// Console reads the same server state without attaching to the session:
///
/// * `session.active_list` — the runtime row whose `session_key` is the
///   member's stored room session; `status: "waiting"` means a server→client
///   request is open (`tui_gateway/server.py::_session_live_status`).
/// * `session.list {profile, title: "Group: <room_id>", include_hidden}` —
///   the member's canonical room session (`hosted_room_driver.py`
///   `room_session_title`).
/// * `session.events.since {session_id, last_seen}` — read-only; its
///   `open_requests` lists the unanswered requests of that runtime.
///
/// Answers use the exact upstream methods Desktop uses for a room window
/// that never received the request frame: `request.answer {id, result}`
/// (single clarify), `clarify.lock {request_id, question_id, answer}`
/// (batch clarify), `approval.respond {session_id, request_id, choice}`.
/// The last resort is `session.interrupt` of that runtime only.
library;

import '../../models/hosted_groups.dart';

/// `last_seen` above any replay sequence: `session.events.since` then returns
/// no events (only `open_requests`), so the probe never ships a transcript.
const int roomPromptProbeLastSeen = 9007199254740991;

/// Canonical hidden session title of a hosted room member.
String roomMemberSessionTitle(String roomId) => 'Group: $roomId';

sealed class RoomMemberPrompt {
  final String memberId;

  /// Live runtime id (`session.active_list` row `id`).
  final String runtimeSessionId;

  /// Durable session id (`session_key`), for opening the member's chat.
  final String storedSessionId;

  const RoomMemberPrompt({
    required this.memberId,
    required this.runtimeSessionId,
    required this.storedSessionId,
  });

  /// Stable identity for UI keys and in-flight guards.
  String get key;
}

/// One open `clarify` request. For a batch, [questionId] is the first
/// question not yet locked and [index]/[total] locate it.
final class RoomMemberClarify extends RoomMemberPrompt {
  final String requestId;
  final String question;
  final List<String> choices;
  final String? questionId;
  final int index;
  final int total;

  const RoomMemberClarify({
    required super.memberId,
    required super.runtimeSessionId,
    required super.storedSessionId,
    required this.requestId,
    required this.question,
    this.choices = const [],
    this.questionId,
    this.index = 1,
    this.total = 1,
  });

  @override
  String get key => 'clarify-$requestId-${questionId ?? ''}';
}

/// One open `approval` request the room driver did not report.
final class RoomMemberApproval extends RoomMemberPrompt {
  final String requestId;
  final String? command;
  final String? description;

  /// Same restriction as the hosted room driver (`hosted_room_driver.py`
  /// `_report_pending_action`): a room approval is once or deny only.
  final List<String> choices;

  const RoomMemberApproval({
    required super.memberId,
    required super.runtimeSessionId,
    required super.storedSessionId,
    required this.requestId,
    this.command,
    this.description,
    this.choices = const ['once', 'deny'],
  });

  @override
  String get key => 'approval-$requestId';

  /// Display model for the shared approval card.
  RoomApprovalAction toDisplayAction() => RoomApprovalAction(
    taskId: '',
    memberId: memberId,
    executionGeneration: 0,
    requestId: requestId,
    choices: choices,
    sessionId: runtimeSessionId,
    command: command,
    description: description,
  );
}

/// The runtime says it waits on a human, but the room cannot show or answer
/// the request (no readable `open_requests`, or a kind Console must not
/// answer here such as sudo/secret).
final class RoomMemberWaitingUnreachable extends RoomMemberPrompt {
  final String? method;

  const RoomMemberWaitingUnreachable({
    required super.memberId,
    required super.runtimeSessionId,
    required super.storedSessionId,
    this.method,
  });

  @override
  String get key => 'waiting-$runtimeSessionId';
}

/// A member whose room turn cannot start: the hosted driver keeps the task
/// queued and retries it (`hosted_room_driver.py` `_defer_unavailable_route`)
/// while no live runtime holds the member's durable room session.
final class RoomMemberStall {
  final String memberId;
  final String profile;

  /// Durable `Group: <room_id>` session id of that member.
  final String storedSessionId;

  const RoomMemberStall({
    required this.memberId,
    required this.profile,
    required this.storedSessionId,
  });

  String get key => 'stall-$memberId-$storedSessionId';
}

/// Raw JSON-RPC used by [GatewayRoomMemberPrompts].
typedef RoomPromptRpc =
    Future<Map<String, dynamic>> Function(
      String method,
      Map<String, dynamic> params,
    );

/// What the Room screen needs to see and answer member prompts.
abstract interface class RoomMemberPromptSource {
  /// Current prompts of the room's members (empty when nobody waits).
  /// [skipApprovalIds] are approvals already shown from `driver_status`.
  Future<List<RoomMemberPrompt>> probe(
    HostedGroupRoom room, {
    Set<String> skipApprovalIds = const {},
  });

  Future<void> answerClarify(RoomMemberClarify prompt, String answer);

  Future<void> answerApproval(RoomMemberApproval prompt, String choice);

  /// `session.interrupt` of that runtime only; never closes the session.
  Future<void> cancelWait(RoomMemberPrompt prompt, {String? expectedTaskId});

  /// [member]'s durable room session when nothing live holds it and no
  /// member of the room is executing; null otherwise. Reads only.
  Future<RoomMemberStall?> findStall(
    HostedGroupRoom room,
    HostedGroupMember member,
  );

  /// Re-opens exactly that member's room session (`session.resume`).
  Future<void> resumeStalled(RoomMemberStall stall);
}

/// Gateway implementation over the room authority's socket.
final class GatewayRoomMemberPrompts implements RoomMemberPromptSource {
  final RoomPromptRpc rpc;

  const GatewayRoomMemberPrompts(this.rpc);

  @override
  Future<List<RoomMemberPrompt>> probe(
    HostedGroupRoom room, {
    Set<String> skipApprovalIds = const {},
  }) async {
    // Only members hosted by this gateway have a session it can read.
    final local = [
      for (final m in room.members)
        if (m.owner.connectionId == room.authorityGatewayId) m,
    ];
    if (local.isEmpty) return const [];
    final active = await rpc('session.active_list', const {});
    final rows = active['sessions'];
    if (rows is! List) return const [];
    final waiting = <String, String>{}; // session_key -> runtime id
    for (final row in rows) {
      if (row is! Map || row['status'] != 'waiting') continue;
      final id = row['id'];
      final key = row['session_key'];
      if (id is String && id.isNotEmpty) {
        waiting[key is String && key.isNotEmpty ? key : id] = id;
      }
    }
    // No runtime waits on a human: nothing else to read.
    if (waiting.isEmpty) return const [];
    final out = <RoomMemberPrompt>[];
    for (final member in local) {
      final listed = await rpc('session.list', {
        'profile': member.owner.profile,
        'title': roomMemberSessionTitle(room.roomId),
        'include_hidden': true,
      });
      final sessions = listed['sessions'];
      if (sessions is! List || sessions.isEmpty || sessions.first is! Map) {
        continue;
      }
      final first = sessions.first as Map;
      final ids = <String>{
        for (final k in const ['resolved_id', 'id'])
          if (first[k] is String && (first[k] as String).isNotEmpty)
            first[k] as String,
      };
      String? stored;
      String? runtime;
      for (final id in ids) {
        if (waiting.containsKey(id)) {
          stored = id;
          runtime = waiting[id];
          break;
        }
      }
      if (stored == null || runtime == null) continue;
      out.addAll(
        await _promptsFor(
          member.memberId,
          runtime,
          stored,
          skipApprovalIds: skipApprovalIds,
        ),
      );
    }
    return List.unmodifiable(out);
  }

  Future<List<RoomMemberPrompt>> _promptsFor(
    String memberId,
    String runtime,
    String stored, {
    required Set<String> skipApprovalIds,
  }) async {
    RoomMemberPrompt unreachable([String? method]) =>
        RoomMemberWaitingUnreachable(
          memberId: memberId,
          runtimeSessionId: runtime,
          storedSessionId: stored,
          method: method,
        );
    Map<String, dynamic> replay;
    try {
      replay = await rpc('session.events.since', {
        'session_id': runtime,
        'last_seen': roomPromptProbeLastSeen,
      });
    } catch (_) {
      return [unreachable()];
    }
    final open = replay['open_requests'];
    if (open is! List || open.isEmpty) return [unreachable()];
    final out = <RoomMemberPrompt>[];
    String? other;
    var skipped = false;
    for (final entry in open) {
      if (entry is! Map) continue;
      final id = entry['id'];
      final method = entry['method'];
      final params = entry['params'];
      if (id is! String || id.isEmpty || params is! Map) continue;
      if (method == 'clarify') {
        final parsed = _clarify(memberId, runtime, stored, id, params);
        if (parsed != null) {
          out.add(parsed);
          continue;
        }
      } else if (method == 'approval') {
        final requestId = params['request_id'];
        if (requestId is String && requestId.isNotEmpty) {
          if (skipApprovalIds.contains(requestId)) {
            skipped = true;
            continue;
          }
          out.add(
            RoomMemberApproval(
              memberId: memberId,
              runtimeSessionId: runtime,
              storedSessionId: stored,
              requestId: requestId,
              command: _text(params['command'], 4000),
              description: _text(params['description'], 1000),
            ),
          );
          continue;
        }
      }
      other ??= method is String ? method : '';
    }
    if (out.isEmpty && !skipped) return [unreachable(other)];
    return out;
  }

  static RoomMemberClarify? _clarify(
    String memberId,
    String runtime,
    String stored,
    String requestId,
    Map params,
  ) {
    final questions = params['questions'];
    if (questions is List && questions.isNotEmpty) {
      final answers = params['answers'];
      final locked = <Object?>{if (answers is Map) ...answers.keys};
      for (var i = 0; i < questions.length; i++) {
        final q = questions[i];
        if (q is! Map) return null;
        final qid = q['qid'];
        final text = _text(q['question'], 4000);
        if (qid is! String || qid.isEmpty || text == null) return null;
        if (locked.contains(qid)) continue;
        return RoomMemberClarify(
          memberId: memberId,
          runtimeSessionId: runtime,
          storedSessionId: stored,
          requestId: requestId,
          question: text,
          choices: _choices(q['choices']),
          questionId: qid,
          index: i + 1,
          total: questions.length,
        );
      }
      return null;
    }
    final text = _text(params['question'], 4000);
    if (text == null) return null;
    return RoomMemberClarify(
      memberId: memberId,
      runtimeSessionId: runtime,
      storedSessionId: stored,
      requestId: requestId,
      question: text,
      choices: _choices(params['choices']),
    );
  }

  @override
  Future<void> answerClarify(RoomMemberClarify prompt, String answer) async {
    final qid = prompt.questionId;
    if (qid != null) {
      await rpc('clarify.lock', {
        'request_id': prompt.requestId,
        'question_id': qid,
        'answer': answer,
      });
      return;
    }
    await rpc('request.answer', {
      'id': prompt.requestId,
      'result': {'answer': answer},
    });
  }

  @override
  Future<void> answerApproval(RoomMemberApproval prompt, String choice) async {
    if (!prompt.choices.contains(choice)) {
      throw StateError('approval choice not offered');
    }
    await rpc('approval.respond', {
      'session_id': prompt.runtimeSessionId,
      'request_id': prompt.requestId,
      'choice': choice,
    });
  }

  @override
  Future<void> cancelWait(
    RoomMemberPrompt prompt, {
    String? expectedTaskId,
  }) async {
    final result = await rpc('session.interrupt', {
      'session_id': prompt.runtimeSessionId,
      'expected_hosted_task_id': ?expectedTaskId,
    });
    // The fenced form answers `not_interrupted` when that runtime no longer
    // runs the expected room task: nothing was cancelled.
    if (result['interrupted'] == false) {
      throw StateError('runtime was not interrupted');
    }
  }

  @override
  Future<RoomMemberStall?> findStall(
    HostedGroupRoom room,
    HostedGroupMember member,
  ) async {
    if (member.owner.connectionId != room.authorityGatewayId) return null;
    final title = roomMemberSessionTitle(room.roomId);
    final active = await rpc('session.active_list', const {});
    final rows = active['sessions'];
    if (rows is! List) return null;
    final live = <String>{};
    for (final row in rows) {
      if (row is! Map) continue;
      for (final k in const ['id', 'session_key']) {
        if (row[k] is String && (row[k] as String).isNotEmpty) {
          live.add(row[k] as String);
        }
      }
      // Every member's room session shares the title. One of them
      // executing (or building) means the room is moving, not stalled.
      if (row['title'] == title &&
          const {'working', 'waiting', 'starting'}.contains(row['status'])) {
        return null;
      }
    }
    final listed = await rpc('session.list', {
      'profile': member.owner.profile,
      'title': title,
      'include_hidden': true,
    });
    final sessions = listed['sessions'];
    if (sessions is! List || sessions.isEmpty || sessions.first is! Map) {
      return null;
    }
    final first = sessions.first as Map;
    final ids = [
      for (final k in const ['resolved_id', 'id'])
        if (first[k] is String && (first[k] as String).isNotEmpty)
          first[k] as String,
    ];
    if (ids.isEmpty || ids.any(live.contains)) return null;
    return RoomMemberStall(
      memberId: member.memberId,
      profile: member.owner.profile,
      storedSessionId: ids.first,
    );
  }

  @override
  Future<void> resumeStalled(RoomMemberStall stall) async {
    // The driver's own shape (`hosted_room_server_rpc.py::resume`). Resume
    // never submits: hosted room sessions skip auto-continue
    // (`session_auto_continue.py`), so no turn is replayed.
    final result = await rpc('session.resume', {
      'session_id': stall.storedSessionId,
      'profile': stall.profile,
      'source': 'bot_room',
      'omit_messages': true,
    });
    final runtime = result['session_id'];
    if (runtime is! String || runtime.isEmpty) {
      throw StateError('resume returned no runtime');
    }
  }
}

List<String> _choices(Object? raw) => [
  if (raw is List)
    for (final c in raw.take(12))
      if (_text(c, 300) case final String text) text,
];

String? _text(Object? raw, int max) {
  if (raw is! String) return null;
  final value = raw.trim();
  if (value.isEmpty) return null;
  return value.length > max ? value.substring(0, max) : value;
}
