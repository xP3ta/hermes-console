import '../models/hosted_groups.dart';

/// Reads an open hosted room under the capability generation that is live
/// at each read, not the one the room was opened with.
///
/// A capability generation belongs to one gateway socket. After a
/// reconnect every call bound to the previous generation is refused, so a
/// room that kept the generation it was opened with could never refresh
/// again until it was reopened. Each read therefore asks for
/// `groups.capabilities` first and reads under that generation.
///
/// Generations only move forward. Once a read under a newer generation has
/// started, a read still in flight under an older one is discarded when it
/// lands: it can neither overwrite newer room state nor make the older
/// generation current again. Callers use [supersedes] to refuse acting
/// under a generation a newer read already replaced.
final class OpenHostedRoomReads {
  final Future<GroupsCapabilities> Function() capabilities;
  final Future<HostedGroupWorkspaceReadback> Function(
    HostedGroupRoom room,
    int generation,
  )
  readUnder;

  /// Called after a read under [GroupsCapabilities.generation] landed and is
  /// still the newest generation, so the caller can act under it.
  final void Function(GroupsCapabilities capabilities)? onProven;

  int? _newest;

  OpenHostedRoomReads({
    required this.capabilities,
    required this.readUnder,
    this.onProven,
  });

  /// The newest generation a read started under.
  int? get newestGeneration => _newest;

  /// True when a read under a newer generation than [generation] started.
  bool supersedes(int generation) {
    final newest = _newest;
    return newest != null && generation < newest;
  }

  Future<HostedGroupWorkspaceReadback> read(HostedGroupRoom room) async {
    final current = await capabilities();
    final generation = current.generation;
    if (!current.supports(GroupMethod.state)) {
      throw StateError('hosted group capability unavailable');
    }
    if (supersedes(generation)) {
      throw StateError('hosted room read superseded');
    }
    _newest = generation;
    final result = await readUnder(room, generation);
    if (result.capabilityGeneration != generation || supersedes(generation)) {
      throw StateError('hosted room read superseded');
    }
    onProven?.call(current);
    return result;
  }
}
