// Bot Mode widget snapshot (spec 070 Phase 7). Published by the background
// listener (and warmed by the UI) as ONE atomic JSON string under
// [storageKey]; the Glance widgets only read it. Secret-free: opaque ids,
// plain display text and local file paths of pre-rendered faces.
import 'dart:convert';

import 'package:flutter/foundation.dart';

enum WidgetBotState { idle, thinking, working, needsYou }

@immutable
class WidgetBot {
  final String profile;
  final String name;
  final WidgetBotState state;
  final String? line;
  final String? facePath;
  final String openPayload;

  const WidgetBot({
    required this.profile,
    required this.name,
    required this.state,
    required this.openPayload,
    this.line,
    this.facePath,
  });

  Map<String, Object?> toJson() => {
    'profile': profile,
    'name': name,
    'state': state.name,
    'line': ?line,
    'face': ?facePath,
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
  const WidgetRoomMember(this.name, this.state, {this.facePath});

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

  const WidgetRoom({
    required this.roomId,
    required this.name,
    required this.working,
    required this.members,
    required this.openPayload,
    this.lastSpeaker,
    this.lastMessage,
    this.stopPayload,
  });

  Map<String, Object?> toJson() => {
    'id': roomId,
    'name': name,
    'working': working,
    'members': [for (final m in members.take(6)) m.toJson()],
    'last_speaker': ?lastSpeaker,
    'last_message': ?lastMessage,
    'open': openPayload,
    'stop': ?stopPayload,
  };
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
  final WidgetRoom? room;
  final int updatedAtMs;

  const BotModeWidgetSnapshot({
    required this.connectionId,
    required this.connectionLabel,
    required this.connected,
    required this.bots,
    required this.approvals,
    required this.updatedAtMs,
    this.room,
  });

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
      if (b.state != WidgetBotState.idle) return b;
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
    'quick': ?quickBot?.toJson(),
    'updated_at_ms': updatedAtMs,
  });
}
