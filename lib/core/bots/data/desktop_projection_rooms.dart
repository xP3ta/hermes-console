/// Read-only model of Desktop's local group chats as projected into the
/// default profile's `ui_meta['hermes-bots-groups']` (v3 envelope written by
/// apps/desktop/src/plugins/hermes-bots/group-chat.ts).
///
/// These rooms are orchestrated by a Desktop window, not by the gateway, so
/// Console only reads them (spec 070 T207). Rooms that also exist as hosted
/// rooms (same `roomId`) are excluded: the hosted room is authoritative.
library;

final class ProjectionAuthor {
  final bool isUser;
  final String name;
  final String? source;

  const ProjectionAuthor({required this.isUser, required this.name, this.source});
}

final class ProjectionMessage {
  final String? id;
  final ProjectionAuthor from;
  final String text;
  final DateTime at;
  final String? thread;
  final bool truncated;

  const ProjectionMessage({
    required this.from,
    required this.text,
    required this.at,
    this.id,
    this.thread,
    this.truncated = false,
  });

  bool get mentionsUser =>
      !from.isUser && RegExp(r'@user\b', caseSensitive: false).hasMatch(text);
}

final class ProjectionRoom {
  /// Projection key (`id:<roomId>` or legacy `name:<name>`).
  final String key;
  final String? roomId;
  final String name;
  final int revision;
  final List<String> memberNames;

  /// Newest-last, bounded to [DesktopProjectionRooms.maxMessagesPerRoom].
  final List<ProjectionMessage> messages;

  /// Earlier entries Desktop did not project plus those Console dropped.
  final int omitted;

  const ProjectionRoom({
    required this.key,
    required this.name,
    required this.revision,
    required this.memberNames,
    required this.messages,
    this.roomId,
    this.omitted = 0,
  });

  bool get readOnly => true;

  ProjectionMessage? get lastMessage => messages.isEmpty ? null : messages.last;

  DateTime? get lastActivityAt => lastMessage?.at;

  /// Desktop's needs-you badge: the latest member entry mentions @user and
  /// the user has not replied after it.
  bool get needsYou {
    for (final message in messages.reversed) {
      if (message.from.isUser) return false;
      if (message.mentionsUser) return true;
    }
    return false;
  }
}

final class DesktopProjectionRooms {
  static const version = 3;
  static const maxRooms = 128;
  static const maxMessagesPerRoom = 16;
  static const maxTextChars = 1200;

  final List<ProjectionRoom> rooms;
  final DateTime? updatedAt;

  const DesktopProjectionRooms._(this.rooms, this.updatedAt);

  static const empty = DesktopProjectionRooms._([], null);

  /// Parses the envelope; anything malformed degrades to fewer rooms, never
  /// an exception. [hostedRoomIds] removes rooms the gateway already hosts.
  static DesktopProjectionRooms parse(
    Object? raw, {
    Set<String> hostedRoomIds = const {},
    int maxMessages = maxMessagesPerRoom,
  }) {
    if (raw is! Map || raw['version'] != version) return empty;
    final entries = raw['rooms'];
    if (entries is! Map || entries.length > maxRooms) return empty;
    final deleted = raw['deleted'] is Map ? raw['deleted'] as Map : const {};
    final rooms = <ProjectionRoom>[];
    for (final entry in entries.entries) {
      final key = entry.key;
      final room = entry.value;
      if (key is! String || room is! Map) continue;
      final roomId = _text(room['roomId'], 128);
      if (room['roomId'] != null && roomId == null) continue;
      final name = _text(room['name'], 64) ??
          (key.startsWith('name:') ? _text(key.substring(5), 64) : null);
      if (name == null) continue;
      if (roomId != null && hostedRoomIds.contains(roomId)) continue;
      if (roomId != null && deleted.containsKey('id:$roomId')) continue;
      final revision = room['revision'] is int ? room['revision'] as int : 0;
      final tombstone = deleted[key];
      if (tombstone is num && tombstone >= revision) continue;
      final members = <String>[
        if (room['members'] is List)
          for (final member in (room['members'] as List).take(64))
            if (member is Map && _text(member['name'], 64) != null)
              member['name'] as String,
      ];
      final parsed = <ProjectionMessage>[];
      final log = room['log'];
      if (log is List) {
        for (final item in log) {
          final message = _message(item);
          if (message != null) parsed.add(message);
        }
      }
      final keep = maxMessages < 0 ? 0 : maxMessages;
      final dropped = parsed.length > keep ? parsed.length - keep : 0;
      final projectedOmitted =
          room['omitted'] is int && (room['omitted'] as int) > 0
          ? room['omitted'] as int
          : 0;
      rooms.add(
        ProjectionRoom(
          key: key,
          roomId: roomId,
          name: name,
          revision: revision,
          memberNames: List.unmodifiable(members),
          messages: List.unmodifiable(parsed.sublist(dropped)),
          omitted: projectedOmitted + dropped,
        ),
      );
    }
    rooms.sort((a, b) {
      final at = a.lastActivityAt?.millisecondsSinceEpoch ?? 0;
      final bt = b.lastActivityAt?.millisecondsSinceEpoch ?? 0;
      return bt != at ? bt.compareTo(at) : a.name.compareTo(b.name);
    });
    final updated = raw['updatedAt'];
    return DesktopProjectionRooms._(
      List.unmodifiable(rooms),
      updated is num && updated.isFinite && updated > 0
          ? DateTime.fromMillisecondsSinceEpoch(updated.round())
          : null,
    );
  }

  static ProjectionMessage? _message(Object? raw) {
    if (raw is! Map) return null;
    final from = raw['from'];
    if (from is! Map) return null;
    final kind = from['kind'];
    if (kind != 'user' && kind != 'member') return null;
    final name = _text(from['name'], 128);
    final text = raw['text'];
    final at = raw['at'];
    if (name == null || text is! String || at is! num || !at.isFinite) {
      return null;
    }
    final bounded = text.length > maxTextChars
        ? text.substring(0, maxTextChars)
        : text;
    return ProjectionMessage(
      id: _text(raw['id'], 256),
      from: ProjectionAuthor(
        isUser: kind == 'user',
        name: name,
        source: _text(from['source'], 128),
      ),
      text: bounded,
      at: DateTime.fromMillisecondsSinceEpoch(at.round()),
      thread: _text(raw['thread'], 256),
      truncated: raw['truncated'] == true || bounded.length != text.length,
    );
  }

  static String? _text(Object? raw, int cap) {
    if (raw is! String || raw.length > cap) return null;
    if (raw.trim().isEmpty || RegExp(r'[\x00-\x1f\x7f]').hasMatch(raw)) {
      return null;
    }
    return raw;
  }
}
