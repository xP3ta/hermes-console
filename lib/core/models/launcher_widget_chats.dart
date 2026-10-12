// Chats section of the launcher widgets: the most recent conversations of one
// connection. Written as ONE atomic JSON string under
// [LauncherWidgetChatsSnapshot.storageKey] when the Chats list has just been
// read; the Android widget only reads it, and adds on its own which of them
// run or wait right now (from the app's snapshot). Secret-free: opaque ids,
// public titles and, unless the owner hides them, one line of the last answer.
import 'dart:convert';

import 'package:flutter/foundation.dart';

@immutable
class LauncherWidgetChat {
  const LauncherWidgetChat({
    required this.id,
    required this.title,
    this.line,
    this.atMs,
    this.profile,
  });

  /// The session's server id: what the widget opens.
  final String id;
  final String title;

  /// One line of the last answer; null when there is none or it is hidden.
  final String? line;

  /// Last activity.
  final int? atMs;

  /// Profile that owns the chat (null for the default one).
  final String? profile;

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'line': ?line,
    'at_ms': ?atMs,
    'profile': ?profile,
  };

  static LauncherWidgetChat? fromJson(Object? value) {
    if (value is! Map) return null;
    final id = _text(value['id'], 256);
    final title = _text(value['title'], 120);
    if (id == null || title == null || !_opaque.hasMatch(id)) return null;
    final at = value['at_ms'];
    return LauncherWidgetChat(
      id: id,
      title: title,
      line: _text(value['line'], 120),
      atMs: at is num && at.isFinite && at > 0 ? at.round() : null,
      profile: _text(value['profile'], 64),
    );
  }

  /// What the widget's "open this conversation" link accepts as an id.
  static bool addressable(String id) =>
      id.isNotEmpty && id.length <= 256 && _opaque.hasMatch(id);

  static final RegExp _opaque = RegExp(r'^[A-Za-z0-9._:-]+$');
}

@immutable
class LauncherWidgetChatsSnapshot {
  const LauncherWidgetChatsSnapshot({
    required this.connectionId,
    required this.updatedAtMs,
    required this.chats,
  });

  static const storageKey = 'hermes_widget_chats_v1';
  static const schemaVersion = 1;

  /// More than the largest widget ever draws; bounds the stored string.
  static const maxChats = 8;

  final String connectionId;

  /// When the list was read from the server.
  final int updatedAtMs;

  /// Most recent first.
  final List<LauncherWidgetChat> chats;

  /// Everything but the time of the read: equal content is not rewritten.
  String get content => jsonEncode({
    'conn_id': connectionId,
    'chats': [for (final chat in chats.take(maxChats)) chat.toJson()],
  });

  String encode() => jsonEncode({
    'schema_version': schemaVersion,
    'conn_id': connectionId,
    'updated_at_ms': updatedAtMs,
    'chats': [for (final chat in chats.take(maxChats)) chat.toJson()],
  });

  /// Null for anything that is not a snapshot of this schema.
  static LauncherWidgetChatsSnapshot? tryDecode(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded['schema_version'] != schemaVersion) {
        return null;
      }
      final connectionId = _text(decoded['conn_id'], 256);
      if (connectionId == null) return null;
      final chats = decoded['chats'];
      final updated = decoded['updated_at_ms'];
      return LauncherWidgetChatsSnapshot(
        connectionId: connectionId,
        updatedAtMs: updated is num && updated.isFinite && updated > 0
            ? updated.round()
            : 0,
        chats: [
          if (chats is List)
            for (final chat in chats.take(maxChats))
              ?LauncherWidgetChat.fromJson(chat),
        ],
      );
    } on FormatException {
      return null;
    }
  }
}

String? _text(Object? value, int max) {
  if (value is! String) return null;
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  return trimmed.length <= max ? trimmed : trimmed.substring(0, max);
}
