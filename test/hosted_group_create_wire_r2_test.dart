import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';

void main() {
  test('local create member emits exact official discriminated target', () {
    final member = HostedGroupCreateMember.localProfile(
      profile: 'builder',
      handle: 'Builder',
    );

    expect(member.toWire(memberId: 'member-1'), {
      'member_id': 'member-1',
      'profile': 'builder',
      'handle': 'Builder',
      'target': {'kind': 'local', 'profile': 'builder'},
    });
    expect(
      jsonEncode(member.toWire(memberId: 'member-1')),
      isNot(contains('connection_id')),
    );
  });

  test('peer create member cannot omit any official authority coordinate', () {
    expect(
      HostedGroupCreateMember.peer(
        profile: 'reviewer',
        handle: 'Reviewer',
        peerId: 'peer-1',
        installationId: 'install-1',
        capabilityDigest: List.filled(64, 'a').join(),
      ).toWire(memberId: 'member-2'),
      {
        'member_id': 'member-2',
        'profile': 'reviewer',
        'handle': 'Reviewer',
        'target': {
          'kind': 'peer',
          'peer_id': 'peer-1',
          'installation_id': 'install-1',
          'profile': 'reviewer',
          'capability_digest': List.filled(64, 'a').join(),
        },
      },
    );
    for (final digest in [
      '',
      List.filled(63, 'a').join(),
      List.filled(64, 'A').join(),
    ]) {
      expect(
        () => HostedGroupCreateMember.peer(
          profile: 'reviewer',
          handle: 'Reviewer',
          peerId: 'peer-1',
          installationId: 'install-1',
          capabilityDigest: digest,
        ),
        throwsFormatException,
      );
    }
  });

  test(
    'exact external upstream parser accepts local fixture and rejects mixed fields',
    () async {
      final upstream = Platform.environment['HERMES_UPSTREAM_CHECKOUT'];
      if (upstream == null || upstream.trim().isEmpty) {
        // The exact-upstream comparison is a local release gate; CI has no
        // hermes-agent checkout, so it must not fail the suite there.
        markTestSkipped(
          'set HERMES_UPSTREAM_CHECKOUT to the exact upstream checkout',
        );
        return;
      }
      final upstreamPath = upstream;
      final roster = [
        HostedGroupCreateMember.localProfile(
          profile: 'builder',
          handle: 'Builder',
        ).toWire(memberId: 'member-1'),
        HostedGroupCreateMember.localProfile(
          profile: 'reviewer',
          handle: 'Reviewer',
        ).toWire(memberId: 'member-2'),
      ];
      final script = r'''
import json, os, sys
sys.path.insert(0, os.environ["HERMES_UPSTREAM_CHECKOUT"])
from gateway.hosted_room_discussion import DiscussionValidationError, validate_roster
roster = json.loads(sys.stdin.read())
parsed = validate_roster(roster, local_profiles=("builder", "reviewer"))
assert [m.target for m in parsed] == [
    {"kind": "local", "profile": "builder"},
    {"kind": "local", "profile": "reviewer"},
]
invalid = []
invalid.append([{**roster[0], "connection_id": "console-connection"}, roster[1]])
invalid.append([{k: v for k, v in roster[0].items() if k != "profile"}, roster[1]])
invalid.append([{**roster[0], "target": {**roster[0]["target"], "connection_id": "console-connection"}}, roster[1]])
invalid.append([{**roster[0], "target": {"kind": "local", "profile": "reviewer"}}, roster[1]])
for candidate in invalid:
    try:
        validate_roster(candidate, local_profiles=("builder", "reviewer"))
    except DiscussionValidationError:
        continue
    raise AssertionError(candidate)
print("upstream-compatible=1 invalid-rejected=4")
''';
      final argumentScript = '$script\n';
      final check = await Process.run(
        'python3',
        [
          '-c',
          argumentScript.replaceFirst(
            'json.loads(sys.stdin.read())',
            'json.loads(sys.argv[1])',
          ),
          jsonEncode(roster),
        ],
        environment: {
          ...Platform.environment,
          'HERMES_UPSTREAM_CHECKOUT': upstreamPath,
        },
      );
      expect(check.exitCode, 0, reason: '${check.stdout}\n${check.stderr}');
      expect(
        check.stdout,
        contains('upstream-compatible=1 invalid-rejected=4'),
      );
    },
  );
}
