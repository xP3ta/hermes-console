// QA (Pixel): opening Capabilities showed «Cargando…», then a false «No
// capability matches» flash, then the list, and when the last source answered
// the whole list jumped up as the progress line went away; every visit paid
// the full load again. Desktop paints its cached capabilities at once and
// refreshes behind. These pin: no false empty state, no jump, a cached first
// paint on reopen, and that a change never leaves the pre-change read cached.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/capabilities/capabilities_screen.dart';

import '../support/inter_font.dart';
import 'capabilities_fakes.dart';

/// REST whose reads under [gatedPrefixes] answer only when [release] fires.
class _GatedRest extends ScriptedRest {
  _GatedRest(this.gatedPrefixes);

  final List<String> gatedPrefixes;
  Completer<void> release = Completer<void>();

  @override
  Future<Map<String, dynamic>> get(String endpoint) async {
    final path = endpoint.split('?').first;
    if (gatedPrefixes.any(path.startsWith)) await release.future;
    return super.get(endpoint);
  }
}

_GatedRest _server(List<String> gated) {
  final rest = _GatedRest(gated);
  final source = populatedServer();
  rest.gets.addAll(source.gets);
  return rest;
}

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Widget _screen(
  ScriptedRest rest, {
  CapabilitiesSnapshotCache? cache,
  String key = 'conn|profile',
}) => CapabilitiesScreen(
  key: UniqueKey(),
  repository: repoOf(rest),
  snapshotCache: cache,
  snapshotKey: key,
  searchDebounce: Duration.zero,
);

void main() {
  setUpAll(loadInterFont);

  testWidgets('only local skills answered: no false «nothing matches»', (
    tester,
  ) async {
    // Like the Pixel: the installed list (all local skills, no install id)
    // answers first; the official catalog and the rest are still pending.
    final rest = _server(['skills/hub', 'dashboard/', 'mcp/']);
    rest.gets['skills'] = [
      {'name': 'notes', 'description': 'Local', 'provenance': 'agent'},
    ];
    await setPhone(tester);
    await tester.pumpWidget(spanishApp(_screen(rest)));
    await _frames(tester);
    expect(find.byKey(const ValueKey('cph-empty-catalog')), findsNothing);
    expect(find.byKey(const ValueKey('cph-loading-catalog')), findsOneWidget);
    rest.release.complete();
    await tester.pumpAndSettle();
    expect(find.text('docker'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the list does not jump when the last source answers', (
    tester,
  ) async {
    final rest = _server(['dashboard/plugins']);
    await setPhone(tester);
    await tester.pumpWidget(spanishApp(_screen(rest)));
    await _frames(tester);
    expect(find.byKey(const ValueKey('cph-loading-more')), findsOneWidget);
    final before = tester.getTopLeft(find.text('arxiv')).dy;
    rest.release.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('cph-loading-more')), findsNothing);
    expect(tester.getTopLeft(find.text('arxiv')).dy, before);
  });

  testWidgets('reopening paints the last read at once and refreshes behind', (
    tester,
  ) async {
    final cache = CapabilitiesSnapshotCache();
    final rest = _server(const []);
    await setPhone(tester);
    await tester.pumpWidget(spanishApp(_screen(rest, cache: cache)));
    await tester.pumpAndSettle();
    expect(find.text('Weather'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());

    final slow = _server(['skills', 'dashboard/', 'mcp/']);
    await tester.pumpWidget(spanishApp(_screen(slow, cache: cache)));
    await tester.pump();
    expect(find.byKey(const ValueKey('cph-loading')), findsNothing);
    expect(find.text('arxiv'), findsOneWidget);
    expect(find.text('Weather'), findsOneWidget);
    expect(find.byKey(const ValueKey('cph-loading-more')), findsOneWidget);
    slow.release.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('cph-loading-more')), findsNothing);

    // Another profile or server never sees this entry.
    final other = _server(['skills', 'dashboard/', 'mcp/']);
    await tester.pumpWidget(
      spanishApp(_screen(other, cache: cache, key: 'conn|bob')),
    );
    await tester.pump();
    expect(find.text('arxiv'), findsNothing);
    other.release.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('a failed or partial read is never cached', (tester) async {
    final cache = CapabilitiesSnapshotCache();
    final rest = _server(const []);
    rest.gets['dashboard/plugins/catalog'] = Exception('synthetic failure');
    await setPhone(tester);
    await tester.pumpWidget(spanishApp(_screen(rest, cache: cache)));
    await tester.pumpAndSettle();
    expect(cache.read('conn|profile'), isNull);
  });

  test('a change drops the entry; partial snapshots are refused', () {
    final cache = CapabilitiesSnapshotCache();
    const complete = CapabilitiesSnapshot(
      catalog: [],
      installed: [],
      skillsUpdatable: false,
    );
    cache.write('k', complete);
    expect(cache.read('k'), same(complete));
    cache.remove('k');
    expect(cache.read('k'), isNull);
    cache.write(
      'k',
      const CapabilitiesSnapshot(
        catalog: [],
        installed: [],
        skillsUpdatable: false,
        complete: false,
      ),
    );
    expect(cache.read('k'), isNull);
  });
}
