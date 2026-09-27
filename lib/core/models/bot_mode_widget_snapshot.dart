// Bot Mode widget snapshot (spec 070 Phase 7). Published by the background
// listener (and warmed by the UI) as ONE atomic JSON string under
// [storageKey]; the Glance widgets only read it. Secret-free: opaque ids,
// plain public display text and local file paths of pre-rendered faces.
import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Live presence plus the two short-lived outcomes the widgets show for
/// `BotWidgetActivityTracker.outcomeWindow` after a Bot stops working.
enum WidgetBotState { idle, thinking, working, needsYou, done, failed }

extension WidgetBotStateX on WidgetBotState {
  bool get isLive =>
      this == WidgetBotState.thinking ||
      this == WidgetBotState.working ||
      this == WidgetBotState.needsYou;

  bool get isOutcome =>
      this == WidgetBotState.done || this == WidgetBotState.failed;

  /// Widget priority (lower first): needs you > failed > working > done.
  int get priority => switch (this) {
    WidgetBotState.needsYou => 0,
    WidgetBotState.failed => 1,
    WidgetBotState.working => 2,
    WidgetBotState.thinking => 2,
    WidgetBotState.done => 3,
    WidgetBotState.idle => 4,
  };

  /// Face expression key (`profile/faceState`).
  String get faceState => switch (this) {
    WidgetBotState.thinking || WidgetBotState.working => 'working',
    WidgetBotState.needsYou => 'needsYou',
    WidgetBotState.done => 'done',
    WidgetBotState.failed => 'failed',
    WidgetBotState.idle => 'idle',
  };
}

/// Room round phase as a widget state (same priority/colour language).
WidgetBotState roomPhaseState(String phase) => switch (phase) {
  'needs_you' => WidgetBotState.needsYou,
  'failed' => WidgetBotState.failed,
  'working' => WidgetBotState.working,
  'done' => WidgetBotState.done,
  _ => WidgetBotState.idle,
};

@immutable
class WidgetBot {
  final String profile;
  final String name;
  final WidgetBotState state;
  final String? line;
  final String? facePath;
  final String openPayload;

  /// Idle face: shown when the widget itself demotes the Bot (stale
  /// snapshot, expired done/failed window).
  final String? idleFacePath;

  /// Public-display-safe recent steps, oldest first, current last (max 3).
  final List<String> steps;

  /// When the current state began (outcomes expire from here).
  final int? sinceMs;

  /// Short role line for idle list rows (the Bot's public title).
  final String? role;

  /// Identity colour of the face (ARGB), for name pills.
  final int? color;

  /// Room the current work belongs to (hero: "en Room name").
  final String? roomId;
  final String? roomName;

  /// The owner pinned this Bot (roster pin): the hero does not rotate away.
  final bool pinned;

  const WidgetBot({
    required this.profile,
    required this.name,
    required this.state,
    required this.openPayload,
    this.line,
    this.facePath,
    this.idleFacePath,
    this.steps = const [],
    this.sinceMs,
    this.role,
    this.color,
    this.roomId,
    this.roomName,
    this.pinned = false,
  });

  WidgetBot copyWith({
    WidgetBotState? state,
    String? facePath,
    String? idleFacePath,
    List<String>? steps,
    int? sinceMs,
    bool clearRoom = false,
  }) => WidgetBot(
    profile: profile,
    name: name,
    state: state ?? this.state,
    openPayload: openPayload,
    line: line,
    facePath: facePath ?? this.facePath,
    idleFacePath: idleFacePath ?? this.idleFacePath,
    steps: steps ?? this.steps,
    sinceMs: sinceMs ?? this.sinceMs,
    role: role,
    color: color,
    roomId: clearRoom ? null : roomId,
    roomName: clearRoom ? null : roomName,
    pinned: pinned,
  );

  Map<String, Object?> toJson() => {
    'profile': profile,
    'name': name,
    'state': state.name,
    'line': ?line,
    'face': ?facePath,
    'face_idle': ?idleFacePath,
    if (steps.isNotEmpty) 'steps': steps.take(3).toList(),
    'since_ms': ?sinceMs,
    'role': ?role,
    'color': ?color,
    'room_id': ?roomId,
    'room_name': ?roomName,
    'open': openPayload,
  };
}

@immutable
class WidgetApproval {
  final String requestId;
  final String title;
  final String text;
  final String? facePath;
  final String actionPayload;
  final String openPayload;
  final bool canApprove;

  const WidgetApproval({
    required this.requestId,
    required this.title,
    required this.text,
    required this.actionPayload,
    required this.openPayload,
    this.facePath,
    this.canApprove = true,
  });

  Map<String, Object?> toJson() => {
    'rid': requestId,
    'title': title,
    'text': text,
    'face': ?facePath,
    'action': actionPayload,
    'open': openPayload,
    'approve': canApprove,
  };
}

@immutable
class WidgetRoomMember {
  final String name;
  final String state; // working | done | needs_you | queued | idle
  final String? facePath;

  /// Owner profile (face lookup only; not serialized).
  final String? profile;
  const WidgetRoomMember(this.name, this.state, {this.facePath, this.profile});

  WidgetRoomMember withFace(String? path) => WidgetRoomMember(
    name,
    state,
    facePath: path ?? facePath,
    profile: profile,
  );

  /// Face expression for this member state.
  String get faceState => switch (state) {
    'working' || 'queued' => 'working',
    'done' => 'done',
    'needs_you' => 'needsYou',
    _ => 'idle',
  };

  Map<String, Object?> toJson() => {
    'name': name,
    'state': state,
    'face': ?facePath,
  };
}

@immutable
class WidgetRoom {
  final String roomId;
  final String name;
  final bool working;
  final List<WidgetRoomMember> members;
  final String? lastSpeaker;
  final String? lastMessage;
  final String openPayload;
  final String? stopPayload;

  /// Round ticker (member progress), oldest first, max 3.
  final List<String> steps;

  /// Round state for the glow: working | needs_you | failed | done | idle.
  final String phase;

  /// When [phase] began (done/failed expire from here).
  final int? sinceMs;

  const WidgetRoom({
    required this.roomId,
    required this.name,
    required this.working,
    required this.members,
    required this.openPayload,
    this.lastSpeaker,
    this.lastMessage,
    this.stopPayload,
    this.steps = const [],
    this.phase = 'idle',
    this.sinceMs,
  });

  WidgetBotState get state => roomPhaseState(phase);

  WidgetRoom copyWith({
    List<WidgetRoomMember>? members,
    List<String>? steps,
    String? phase,
    int? sinceMs,
  }) => WidgetRoom(
    roomId: roomId,
    name: name,
    working: working,
    members: members ?? this.members,
    openPayload: openPayload,
    lastSpeaker: lastSpeaker,
    lastMessage: lastMessage,
    stopPayload: stopPayload,
    steps: steps ?? this.steps,
    phase: phase ?? this.phase,
    sinceMs: sinceMs ?? this.sinceMs,
  );

  Map<String, Object?> toJson() => {
    'id': roomId,
    'name': name,
    'working': working,
    'members': [for (final m in members.take(6)) m.toJson()],
    'last_speaker': ?lastSpeaker,
    'last_message': ?lastMessage,
    'open': openPayload,
    'stop': ?stopPayload,
    if (steps.isNotEmpty) 'steps': steps.take(3).toList(),
    'phase': phase,
    'since_ms': ?sinceMs,
  };
}

/// One active item of the widgets (a Bot or a room), by stable identity.
@immutable
class WidgetActiveRef {
  final String kind; // bot | room
  final String id; // profile | room id
  const WidgetActiveRef.bot(this.id) : kind = 'bot';
  const WidgetActiveRef.room(this.id) : kind = 'room';

  Map<String, Object?> toJson() => {'k': kind, 'id': id};

  @override
  bool operator ==(Object other) =>
      other is WidgetActiveRef && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);

  @override
  String toString() => '$kind:$id';
}

@immutable
class BotModeWidgetSnapshot {
  static const storageKey = 'hermes_widget_botmode_v2';
  static const schemaVersion = 2;

  final String? connectionId;
  final String? connectionLabel;
  final bool connected;
  final List<WidgetBot> bots;
  final List<WidgetApproval> approvals;

  /// Rooms by relevance (most relevant first), max 4.
  final List<WidgetRoom> rooms;
  final int updatedAtMs;

  /// Active Bots and rooms in widget priority order (a room whose work is
  /// already shown through one of its Bots is not repeated).
  final List<WidgetActiveRef> active;

  /// Item the 2x2 hero shows this update (rotates within the top tier).
  final WidgetActiveRef? hero;

  const BotModeWidgetSnapshot({
    required this.connectionId,
    required this.connectionLabel,
    required this.connected,
    required this.bots,
    required this.approvals,
    required this.updatedAtMs,
    this.rooms = const [],
    this.active = const [],
    this.hero,
  });

  WidgetRoom? get room => rooms.isEmpty ? null : rooms.first;

  BotModeWidgetSnapshot copyWith({
    List<WidgetBot>? bots,
    List<WidgetRoom>? rooms,
    List<WidgetActiveRef>? active,
    WidgetActiveRef? hero,
    bool clearHero = false,
  }) => BotModeWidgetSnapshot(
    connectionId: connectionId,
    connectionLabel: connectionLabel,
    connected: connected,
    bots: bots ?? this.bots,
    approvals: approvals,
    rooms: rooms ?? this.rooms,
    updatedAtMs: updatedAtMs,
    active: active ?? this.active,
    hero: clearHero ? null : hero ?? this.hero,
  );

  /// Faces the snapshot needs, as `profile/state` keys (see [withFaces]).
  Set<String> get faceKeys => {
    for (final b in bots) ...{
      '${b.profile}/${b.state.faceState}',
      '${b.profile}/idle',
    },
    for (final r in rooms)
      for (final m in r.members)
        if (m.profile != null) '${m.profile}/${m.faceState}',
  };

  /// Same snapshot with face paths resolved from `profile/state` keys.
  BotModeWidgetSnapshot withFaces(Map<String, String?> faces) => copyWith(
    bots: [
      for (final b in bots)
        b.copyWith(
          facePath: faces['${b.profile}/${b.state.faceState}'],
          idleFacePath: faces['${b.profile}/idle'],
        ),
    ],
    rooms: [
      for (final r in rooms)
        r.copyWith(
          members: [
            for (final m in r.members)
              m.withFace(
                m.profile == null ? null : faces['${m.profile}/${m.faceState}'],
              ),
          ],
        ),
    ],
  );

  WidgetBot? botOf(String profile) {
    for (final b in bots) {
      if (b.profile == profile) return b;
    }
    return null;
  }

  WidgetRoom? roomOf(String id) {
    for (final r in rooms) {
      if (r.roomId == id) return r;
    }
    return null;
  }

  /// The hero Bot, when the hero is a Bot.
  WidgetBot? get heroBot => hero?.kind == 'bot' ? botOf(hero!.id) : null;

  /// Other active items besides the hero ("+N").
  int get othersCount => active.isEmpty ? 0 : active.length - 1;

  int get workingCount => bots
      .where(
        (b) =>
            b.state == WidgetBotState.working ||
            b.state == WidgetBotState.thinking,
      )
      .length;

  int get needsYouCount => approvals.length;

  /// Bot shown by Quick ask: the most recently active, else the first.
  WidgetBot? get quickBot {
    for (final b in bots) {
      if (b.state.isLive) return b;
    }
    return bots.isEmpty ? null : bots.first;
  }

  String encode() => jsonEncode({
    'schema_version': schemaVersion,
    'conn_id': ?connectionId,
    'conn_label': ?connectionLabel,
    'connected': connected,
    'working_count': workingCount,
    'needs_you_count': needsYouCount,
    'bots': [for (final b in bots.take(16)) b.toJson()],
    'approvals': [for (final a in approvals.take(6)) a.toJson()],
    'room': ?room?.toJson(),
    'rooms': [for (final r in rooms.take(4)) r.toJson()],
    'active': [for (final a in active.take(12)) a.toJson()],
    'hero': ?hero?.toJson(),
    'quick': ?quickBot?.toJson(),
    'updated_at_ms': updatedAtMs,
  });
}
