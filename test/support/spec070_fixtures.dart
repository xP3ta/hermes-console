import 'dart:convert';
import 'dart:io';

import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/desktop_active_session.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';

/// Loads a spec 070 contract fixture (`test/fixtures/spec070/<name>.json`).
Map<String, dynamic> spec070Fixture(String name) =>
    jsonDecode(File('test/fixtures/spec070/$name.json').readAsStringSync())
        as Map<String, dynamic>;

Map<String, dynamic> spec070Result(String name) =>
    Map<String, dynamic>.from(spec070Fixture(name)['result'] as Map);

GroupsCapabilities spec070Capabilities({int generation = 1}) =>
    GroupsCapabilities.tryParse(
      spec070Result('groups_capabilities'),
      connectionId: 'conn-home',
      generation: generation,
    )!;

HostedGroupRoom spec070Room() =>
    HostedGroupRoom.fromJson(spec070Result('groups_state')['room']);

RoomDriverStatus spec070DriverStatus() =>
    RoomDriverStatus.tryParse(spec070Result('groups_state')['driver_status'])!;

HostedGroupLogPage spec070LogPage(String name) {
  final fixture = spec070Fixture(name);
  final params = fixture['params'] as Map;
  return HostedGroupLogPage.fromJson(
    spec070Result(name),
    expectedRoomId: params['room_id'] as String,
    sinceSeq: params['since_seq'] as int,
  );
}

List<AgentProfile> spec070Profiles() => [
  for (final row in spec070Result('profiles_list')['profiles'] as List)
    AgentProfile.fromJson(Map<String, dynamic>.from(row as Map)),
];

DesktopActiveSessionList spec070ActiveSessions() =>
    DesktopActiveSessionList.fromJson(spec070Result('session_active_list'));
