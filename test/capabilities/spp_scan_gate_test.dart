// The hub reads the security scan BEFORE it offers the install, and the
// server's own policy decides what the person is allowed to do with it.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/capabilities/capability_detail_screen.dart';
import 'package:hermes_android/core/capabilities/capability_models.dart';
import 'package:hermes_android/core/services/connection_manager.dart'
    show DashboardHttpException;

import '../support/inter_font.dart';
import 'capabilities_fakes.dart';

const _docker = CapabilityItem(
  kind: CapabilityKind.skill,
  id: 'skill:official:official/devops/docker',
  name: 'docker',
  description: 'Manage containers and compose stacks',
  category: 'devops',
  source: 'community',
  trust: CapabilityTrust.community,
  installId: 'community/devops/docker',
  installedName: 'docker',
  provenance: 'hub',
  canRemove: true,
);

final class _SlowScanRest extends ScriptedRest {
  /// While set, a scan read waits for it.
  Completer<void>? gate;

  @override
  Future<Map<String, dynamic>> get(String endpoint) async {
    final held = gate;
    if (held != null && endpoint.startsWith('skills/hub/scan')) {
      await held.future;
    }
    return super.get(endpoint);
  }
}

ScriptedRest _serverWith(Map<String, Object?> scan) => ScriptedRest()
  ..gets['skills/hub/scan'] = scan.cast<String, Object>()
  ..posts['skills/hub/install'] = {'ok': true, 'name': 'install-docker'}
  ..statusQueue.add({
    'name': 'install-docker',
    'running': false,
    'exit_code': 0,
  });

Future<void> _open(WidgetTester tester, ScriptedRest rest) async {
  await setPhone(tester);
  await tester.pumpWidget(
    spanishApp(CapabilityDetailScreen(item: _docker, repository: repoOf(rest))),
  );
  await tester.pumpAndSettle();
}

Future<void> _tapInstall(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('cph-primary')));
  await tester.pumpAndSettle();
}

List<String> _installs(ScriptedRest rest) =>
    rest.mutations.where((c) => c.contains('install')).toList();

void main() {
  setUpAll(loadInterFont);

  testWidgets('policy block: findings only, nothing to confirm, no install', (
    tester,
  ) async {
    final rest = _serverWith({
      'verdict': 'dangerous',
      'policy': 'block',
      'policy_reason': 'Blocked by policy',
      'findings': [
        {
          'severity': 'critical',
          'description': 'curl piped to shell',
          'file': 'run.sh',
          'line': 3,
        },
      ],
    });
    await _open(tester, rest);
    await _tapInstall(tester);

    expect(find.byKey(const ValueKey('spp-scan-blocked')), findsOneWidget);
    expect(find.text('Instalación bloqueada'), findsOneWidget);
    expect(
      find.textContaining('curl piped to shell (run.sh:3)'),
      findsOneWidget,
    );
    expect(find.textContaining('Blocked by policy'), findsOneWidget);
    // No way forward from this dialog.
    expect(find.byKey(const ValueKey('spp-scan-install-anyway')), findsNothing);
    await tester.tap(find.text('Cerrar'));
    await tester.pumpAndSettle();
    expect(_installs(rest), isEmpty);
    expect(find.text('No instalada'), findsOneWidget);
    // The primary is usable again afterwards.
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton).first).onPressed,
      isNotNull,
    );
  });

  testWidgets('policy ask: findings first, then an explicit install anyway', (
    tester,
  ) async {
    final rest = _serverWith({
      'verdict': 'caution',
      'policy': 'ask',
      'findings': [
        {'severity': 'medium', 'description': 'writes outside its folder'},
      ],
    });
    await _open(tester, rest);

    await _tapInstall(tester);
    expect(find.byKey(const ValueKey('spp-scan-ask')), findsOneWidget);
    expect(find.textContaining('writes outside its folder'), findsOneWidget);
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    expect(_installs(rest), isEmpty, reason: 'cancel installs nothing');

    await _tapInstall(tester);
    await tester.tap(find.byKey(const ValueKey('spp-scan-install-anyway')));
    await tester.pumpAndSettle();
    expect(_installs(rest), ['POST skills/hub/install']);
    expect(
      rest.calls.indexWhere((c) => c.startsWith('GET skills/hub/scan')),
      lessThan(rest.calls.indexOf('POST skills/hub/install')),
    );
    expect(find.text('Activa'), findsOneWidget);
  });

  testWidgets('policy allow: no extra dialog, the scan came first', (
    tester,
  ) async {
    final rest = _serverWith({'verdict': 'safe', 'policy': 'allow'});
    await _open(tester, rest);
    await _tapInstall(tester);

    expect(find.byKey(const ValueKey('spp-scan-ask')), findsNothing);
    expect(find.byKey(const ValueKey('spp-scan-blocked')), findsNothing);
    expect(_installs(rest), ['POST skills/hub/install']);
    expect(
      rest.calls.where((c) => c.startsWith('GET skills/hub/scan')),
      hasLength(1),
    );
    expect(
      rest.calls.indexWhere((c) => c.startsWith('GET skills/hub/scan')),
      lessThan(rest.calls.indexOf('POST skills/hub/install')),
    );
  });

  testWidgets('the scan could not be read: a warning, then the choice', (
    tester,
  ) async {
    final rest = ScriptedRest()
      ..gets['skills/hub/scan'] = const DashboardHttpException(503)
      ..posts['skills/hub/install'] = {'ok': true, 'name': 'install-docker'}
      ..statusQueue.add({
        'name': 'install-docker',
        'running': false,
        'exit_code': 0,
      });
    await _open(tester, rest);

    await _tapInstall(tester);
    expect(find.byKey(const ValueKey('spp-scan-failed')), findsOneWidget);
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    expect(_installs(rest), isEmpty);

    await _tapInstall(tester);
    await tester.tap(find.byKey(const ValueKey('spp-scan-continue')));
    await tester.pumpAndSettle();
    expect(_installs(rest), ['POST skills/hub/install']);
  });

  testWidgets('a server without the scan route installs as before', (
    tester,
  ) async {
    final rest = ScriptedRest()
      ..posts['skills/hub/install'] = {'ok': true, 'name': 'install-docker'}
      ..statusQueue.add({
        'name': 'install-docker',
        'running': false,
        'exit_code': 0,
      });
    await _open(tester, rest);
    await _tapInstall(tester);

    expect(find.byKey(const ValueKey('spp-scan-failed')), findsNothing);
    expect(_installs(rest), ['POST skills/hub/install']);
  });

  testWidgets('a second tap during the scan opens no second flow', (
    tester,
  ) async {
    final rest = _SlowScanRest()
      ..gate = Completer<void>()
      ..gets['skills/hub/scan'] = {'verdict': 'safe', 'policy': 'allow'}
      ..posts['skills/hub/install'] = {'ok': true, 'name': 'install-docker'}
      ..statusQueue.add({
        'name': 'install-docker',
        'running': false,
        'exit_code': 0,
      });
    await _open(tester, rest);

    await tester.tap(find.byKey(const ValueKey('cph-primary')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Analizando docker…'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton).first).onPressed,
      isNull,
      reason: 'busy from the first tap',
    );

    rest.gate!.complete();
    await tester.pumpAndSettle();
    expect(
      rest.calls.where((c) => c.startsWith('GET skills/hub/scan')),
      hasLength(1),
    );
    expect(_installs(rest), ['POST skills/hub/install']);
  });

  testWidgets('the scan row cannot open two lookups at once', (tester) async {
    final rest = _SlowScanRest()
      ..gets['skills/hub/scan'] = {'verdict': 'safe', 'summary': 'Clean'};
    final repo = repoOf(rest);
    // An earlier answer confirmed the route, so the row is painted.
    await repo.skillScan(_docker.installId);
    rest.calls.clear();
    rest.gate = Completer<void>();
    await setPhone(tester);
    await tester.pumpWidget(
      spanishApp(CapabilityDetailScreen(item: _docker, repository: repo)),
    );
    await tester.pumpAndSettle();
    final row = find.byKey(const ValueKey('cph-row-scan'));
    await tester.ensureVisible(row);
    await tester.tap(row);
    await tester.pump();
    await tester.tap(row, warnIfMissed: false);
    await tester.pump();
    rest.gate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('Cerrar'), findsOneWidget, reason: 'one dialog');
    await tester.tap(find.text('Cerrar'));
    await tester.pumpAndSettle();
    expect(rest.calls.where((c) => c.contains('scan')), hasLength(1));
  });
}
