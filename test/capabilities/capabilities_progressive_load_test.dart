// Skills already answered must not wait for slower sources. Desktop loads
// skills on their own query (skills-data.ts) and enriches the rest later;
// Console rendered nothing until plugins, MCP and connectors (several
// sequential gateway RPCs) had all finished.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/capabilities/capabilities_screen.dart';

import '../support/inter_font.dart';
import 'capabilities_fakes.dart';

/// REST whose plugin catalog answers only when [release] completes.
class _SlowPluginsRest extends ScriptedRest {
  final release = Completer<void>();

  @override
  Future<Map<String, dynamic>> get(String endpoint) async {
    if (endpoint.split('?').first.startsWith('dashboard/plugins')) {
      await release.future;
    }
    return super.get(endpoint);
  }
}

/// REST whose `skills` (installed) or `skills/hub/official` read answers only
/// when its gate completes.
class _GatedSkillsRest extends ScriptedRest {
  _GatedSkillsRest(this.gatedPath);

  final String gatedPath;
  final release = Completer<void>();
  bool fail = false;

  @override
  Future<Map<String, dynamic>> get(String endpoint) async {
    if (endpoint.split('?').first == gatedPath) {
      await release.future;
      if (fail) throw StateError('synthetic installed list failure');
    }
    return super.get(endpoint);
  }
}

Finder _rowStatus(String key, String label) =>
    find.descendant(of: find.byKey(ValueKey(key)), matching: find.text(label));

const _arxivRow = 'cph-row-skill:official:official/research/arxiv';

ScriptedRest _withServer(ScriptedRest rest) {
  final source = populatedServer();
  rest.gets.addAll(source.gets);
  rest.posts.addAll(source.posts);
  rest.puts.addAll(source.puts);
  return rest;
}

Future<void> _pump(WidgetTester tester, Widget screen) async {
  await setPhone(tester);
  await tester.pumpWidget(spanishApp(screen));
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUpAll(loadInterFont);

  testWidgets('skills show while the gateway RPCs are still pending', (
    tester,
  ) async {
    final rpcGate = Completer<Map<String, dynamic>>();
    final methods = <String>[];
    await _pump(
      tester,
      CapabilitiesScreen(
        repository: repoOf(
          populatedServer(),
          rpc: (method, params) {
            methods.add(method);
            return rpcGate.future;
          },
        ),
        searchDebounce: Duration.zero,
      ),
    );
    expect(methods, isNotEmpty);
    expect(find.text('arxiv'), findsOneWidget);
    expect(find.text('docker'), findsOneWidget);
    rpcGate.completeError(StateError('synthetic gateway closed'));
    await tester.pumpAndSettle();
    expect(find.text('arxiv'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('skills show while a slow plugin catalog is pending', (
    tester,
  ) async {
    final rest = _withServer(_SlowPluginsRest()) as _SlowPluginsRest;
    await _pump(
      tester,
      CapabilitiesScreen(
        repository: repoOf(rest),
        searchDebounce: Duration.zero,
      ),
    );
    expect(find.text('arxiv'), findsOneWidget);
    expect(find.text('Weather'), findsNothing);
    rest.release.complete();
    await tester.pumpAndSettle();
    expect(find.text('arxiv'), findsOneWidget);
    expect(find.text('Weather'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('installed skills show while the official catalog is pending', (
    tester,
  ) async {
    final rest =
        _withServer(_GatedSkillsRest('skills/hub/official'))
            as _GatedSkillsRest;
    await _pump(
      tester,
      CapabilitiesScreen(
        repository: repoOf(rest),
        searchDebounce: Duration.zero,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('cph-seg-installed')));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('arxiv'), findsOneWidget);
    expect(find.text('notes'), findsOneWidget);
    expect(find.text('docker'), findsNothing);
    rest.release.complete();
    await tester.pumpAndSettle();
    expect(find.text('arxiv'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'the official catalog shows with an unknown installed state while the '
    'installed list is pending',
    (tester) async {
      final rest = _withServer(_GatedSkillsRest('skills')) as _GatedSkillsRest;
      await _pump(
        tester,
        CapabilitiesScreen(
          repository: repoOf(rest),
          searchDebounce: Duration.zero,
        ),
      );
      expect(find.text('arxiv'), findsOneWidget);
      expect(find.text('docker'), findsOneWidget);
      // Pending, not "not installed" and not "installed".
      expect(_rowStatus(_arxivRow, 'Estado no disponible'), findsOneWidget);
      expect(_rowStatus(_arxivRow, 'Instalada'), findsNothing);
      rest.release.complete();
      await tester.pumpAndSettle();
      expect(_rowStatus(_arxivRow, 'Instalada'), findsOneWidget);
      expect(_rowStatus(_arxivRow, 'Estado no disponible'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a failed installed list keeps the catalog state unknown', (
    tester,
  ) async {
    final rest = _withServer(_GatedSkillsRest('skills')) as _GatedSkillsRest
      ..fail = true;
    await _pump(
      tester,
      CapabilitiesScreen(
        repository: repoOf(rest),
        searchDebounce: Duration.zero,
      ),
    );
    rest.release.complete();
    await tester.pumpAndSettle();
    expect(find.text('arxiv'), findsOneWidget);
    expect(_rowStatus(_arxivRow, 'Estado no disponible'), findsOneWidget);
    expect(_rowStatus(_arxivRow, 'Instalada'), findsNothing);
    expect(find.byKey(const ValueKey('cph-partial')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
