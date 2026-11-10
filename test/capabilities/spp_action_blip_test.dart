// A hub action keeps running on the server when the phone loses the line for
// a moment: a blip is tolerated, a long silence is "uncertain", never "failed".
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/capabilities/capabilities_repository.dart';
import 'package:hermes_android/core/capabilities/capability_detail_screen.dart';
import 'package:hermes_android/core/capabilities/capability_models.dart';
import 'package:hermes_android/core/services/connection_manager.dart'
    show DashboardHttpException;

import '../support/inter_font.dart';
import 'capabilities_fakes.dart';

final class _BlipRest extends ScriptedRest {
  _BlipRest(this.blips);

  int blips;

  @override
  Future<Map<String, dynamic>> get(String endpoint) async {
    if (endpoint.startsWith('actions/') && blips > 0) {
      blips--;
      calls.add('GET $endpoint');
      throw const DashboardHttpException(503);
    }
    return super.get(endpoint);
  }
}

_BlipRest _server(int blips) => _BlipRest(blips)
  ..posts['skills/hub/install'] = {'ok': true, 'name': 'install-docker'}
  ..statusQueue.addAll([
    {
      'name': 'install-docker',
      'running': true,
      'lines': ['working'],
    },
    {'name': 'install-docker', 'running': false, 'exit_code': 0},
  ]);

const _docker = CapabilityItem(
  kind: CapabilityKind.skill,
  id: 'skill:official:official/devops/docker',
  name: 'docker',
  installId: 'official/devops/docker',
  installedName: 'docker',
  provenance: 'hub',
  canRemove: true,
);

void main() {
  setUpAll(loadInterFont);

  test('one lost read does not fail the install', () async {
    final rest = _server(1);
    final status = await repoOf(rest).installSkill('official/devops/docker');
    expect(status.succeeded, isTrue);
  });

  test('two lost reads in a row are still tolerated', () async {
    final rest = _server(2);
    final status = await repoOf(rest).installSkill('official/devops/docker');
    expect(status.succeeded, isTrue);
  });

  test('a long silence is uncertain, not a failure', () async {
    final rest = _server(9);
    await expectLater(
      repoOf(rest).installSkill('official/devops/docker'),
      throwsA(
        isA<CapabilityFailure>().having(
          (e) => e.kind,
          'kind',
          CapabilityFailureKind.uncertain,
        ),
      ),
    );
    expect(rest.calls.where((c) => c.startsWith('GET actions/')), hasLength(3));
  });

  test('a real refusal from the server is still a failure', () async {
    final rest = _server(0)
      ..statusQueue.clear()
      ..statusQueue.add({
        'name': 'install-docker',
        'running': false,
        'exit_code': 1,
        'lines': ['fatal: nope'],
      });
    await expectLater(
      repoOf(rest).installSkill('official/devops/docker'),
      throwsA(
        isA<CapabilityFailure>().having(
          (e) => e.kind,
          'kind',
          CapabilityFailureKind.rejected,
        ),
      ),
    );
  });

  testWidgets('the screen refreshes instead of saying the install failed', (
    tester,
  ) async {
    var changed = 0;
    final rest = _server(9);
    await setPhone(tester);
    await tester.pumpWidget(
      spanishApp(
        CapabilityDetailScreen(
          item: _docker,
          repository: repoOf(rest),
          onChanged: () => changed++,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('cph-primary')));
    await tester.pumpAndSettle();
    expect(changed, 1, reason: 'the hub is told to read the truth');
    expect(find.textContaining('No se pudo instalar'), findsNothing);
  });
}
