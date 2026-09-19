import 'agent_profile.dart';
import 'hosted_groups.dart';

final class RoomMirrorIdentity {
  final String? roomId;
  final String? name;
  final AgentProfileAvatar? image;

  const RoomMirrorIdentity({this.roomId, this.name, this.image});
}

final class RoomMirror {
  static const empty = RoomMirror._([]);
  static const maxImageCharacters = 24000;
  static const maxRooms = 128;
  final List<RoomMirrorIdentity> rooms;

  const RoomMirror._(this.rooms);

  static RoomMirror parse(Object? raw) {
    if (raw is! Map || raw['version'] != 3) return empty;
    final entries = raw['rooms'];
    if (entries is! Map || entries.length > maxRooms) return empty;
    final deleted = raw['deleted'];
    final result = <RoomMirrorIdentity>[];
    var imageBudget = 48000;
    for (final entry in entries.entries) {
      final room = entry.value;
      if (entry.key is! String || room is! Map) continue;
      final id = _text(room['roomId'], 128);
      final name = _text(room['name'], 64);
      if (room['roomId'] != null && id == null) continue;
      if (id == null && name == null) continue;
      // Desktop never reuses a durable room id after disbanding it.
      if (id != null && deleted is Map && deleted.containsKey('id:$id')) {
        continue;
      }
      final revision = room['revision'];
      final tombstone = deleted is Map ? deleted[entry.key] : null;
      if (tombstone != null &&
          (tombstone is! num ||
              !tombstone.isFinite ||
              revision is! num ||
              !revision.isFinite ||
              tombstone >= revision)) {
        continue;
      }
      AgentProfileAvatar? image;
      final data = room['image'];
      if (data is String &&
          data.length <= maxImageCharacters &&
          data.length <= imageBudget) {
        imageBudget -= data.length;
        try {
          image = AgentProfileAvatar.fromDataUri(data);
        } on FormatException {
          // Identity remains useful when another client's image is corrupt.
        }
      }
      result.add(RoomMirrorIdentity(roomId: id, name: name, image: image));
    }
    return RoomMirror._(List.unmodifiable(result));
  }

  RoomMirrorIdentity? match(
    HostedGroupRoom room,
    Iterable<HostedGroupRoom> hosted,
  ) {
    final byId = rooms.where((entry) => entry.roomId == room.roomId).toList();
    if (byId.isNotEmpty) return byId.length == 1 ? byId.single : null;
    final byName = rooms.where((entry) => entry.name == room.name).toList();
    if (byName.length != 1 || byName.single.roomId != null) return null;
    if (hosted.where((entry) => entry.name == room.name).length != 1) {
      return null;
    }
    return byName.single;
  }

  static String? _text(Object? raw, int cap) {
    if (raw is! String || raw.length > cap) return null;
    if (raw.trim().isEmpty || RegExp(r'[\x00-\x1f\x7f]').hasMatch(raw)) {
      return null;
    }
    return raw;
  }
}
