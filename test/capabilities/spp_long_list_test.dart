// ignore_for_file: deprecated_member_use
// Long lists (153 skills, 64 plugins), large text, scroll, refresh and the
// hub search while it is still answering.
import 'dart:async';
import 'dart:ui' show SemanticsFlag;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/capabilities/capabilities_screen.dart';

import '../support/inter_font.dart';
import 'capabilities_fakes.dart';

ScriptedRest _bigServer() {
  final rest = ScriptedRest()
    ..gets['skills'] = [
      for (var i = 0; i < 153; i++)
        {
          'name': 'skill-${i.toString().padLeft(3, '0')}',
          'description': 'Skill number $i',
          'enabled': i.isEven,
          'provenance': i % 3 == 0 ? 'bundled' : 'hub',
        },
    ]
    ..gets['skills/hub/official'] = {'skills': <Object>[]}
    ..gets['dashboard/plugins/catalog'] = {'entries': <Object>[]}
    ..gets['dashboard/plugins/hub'] = {
      'plugins': [
        for (var i = 0; i < 64; i++)
          {
            'name': 'plugin-${i.toString().padLeft(2, '0')}',
            'key': 'tools/plugin-${i.toString().padLeft(2, '0')}',
            'version': '1.$i.0',
            'source': i.isEven ? 'bundled' : 'user',
            'runtime_status': i % 4 == 0 ? 'disabled' : 'enabled',
          },
      ],
    }
    ..gets['mcp/catalog'] = {'entries': <Object>[]}
    ..gets['mcp/servers'] = {'servers': <Object>[]};
  return rest;
}

/// 153 hub skills that are NOT installed: a long catalog.
ScriptedRest _bigCatalog() => ScriptedRest()
  ..gets['skills'] = <Object>[]
  ..gets['skills/hub/official'] = {
    'skills': [
      for (var i = 0; i < 153; i++)
        {
          'name': 'cat-${i.toString().padLeft(3, '0')}',
          'identifier': 'official/x/cat-$i',
          'description': 'Catalog skill $i',
        },
    ],
  };

final class _SlowSearchRest extends ScriptedRest {
  Completer<void>? gate;

  @override
  Future<Map<String, dynamic>> get(String endpoint) async {
    final held = gate;
    if (held != null && endpoint.startsWith('skills/hub/search')) {
      await held.future;
    }
    return super.get(endpoint);
  }
}

Future<void> _pump(
  WidgetTester tester,
  ScriptedRest rest, {
  CapabilitiesSegment segment = CapabilitiesSegment.installed,
}) async {
  await setPhone(tester);
  await tester.pumpWidget(
    spanishApp(
      CapabilitiesScreen(
        repository: repoOf(rest),
        initialSegment: segment,
        searchDebounce: Duration.zero,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

int _rows(String prefix) => find
    .byWidgetPredicate((w) {
      final key = w.key;
      return key is ValueKey<String> && key.value.startsWith(prefix);
    })
    .evaluate()
    .length;

Finder get _list => find.byKey(const ValueKey('cph-list'));

/// Drags the list until [target] sits inside the visible page.
Future<void> _bringToView(WidgetTester tester, Finder target) async {
  for (var i = 0; i < 80; i++) {
    if (target.evaluate().isNotEmpty) {
      final y = tester.getCenter(target).dy;
      if (y > 140 && y < 760) return;
    }
    await tester.drag(_list, const Offset(0, -300));
    await tester.pump();
  }
}

Finder get _scrollable =>
    find.descendant(of: _list, matching: find.byType(Scrollable)).first;

double _offset(WidgetTester tester) => tester
    .state<ScrollableState>(
      find.descendant(of: _list, matching: find.byType(Scrollable)).first,
    )
    .position
    .pixels;

void main() {
  setUpAll(loadInterFont);

  testWidgets('153 skills and 64 plugins: each tab builds a bounded set', (
    tester,
  ) async {
    await _pump(tester, _bigServer());

    expect(find.text('153 instalados · 77 activos'), findsOneWidget);
    // Skills open at 30 rows; the plugins live in their own tab and are not
    // even built yet.
    expect(_rows('cph-row-skill:installed:'), 30);
    expect(_rows('cph-row-plugin:'), 0);
    expect(find.byType(Switch).evaluate().length, lessThanOrEqualTo(40));
    // Painted, never blurred over the content, row by row.
    expect(find.byType(BackdropFilter), findsNothing);
    await tester.tap(find.byKey(const ValueKey('exu-tab-plugins')));
    await tester.pumpAndSettle();
    expect(find.text('64 instalados · 48 activos'), findsOneWidget);
    expect(_rows('cph-row-skill:'), 0);
    expect(_rows('cph-row-plugin:installed:'), 30);
    expect(tester.takeException(), isNull);
  });

  testWidgets('"show more" reveals the list in steps, never all at once', (
    tester,
  ) async {
    await _pump(tester, _bigServer());
    Future<void> more() async {
      final button = find.byKey(const ValueKey('cph-show-all-skill'));
      await _bringToView(tester, button);
      await tester.tap(button);
      await tester.pumpAndSettle();
    }

    await more();
    expect(_rows('cph-row-skill:installed:'), 90);
    await more();
    expect(_rows('cph-row-skill:installed:'), 150);
    await more();
    expect(_rows('cph-row-skill:installed:'), 153);
    expect(find.byKey(const ValueKey('cph-show-all-skill')), findsNothing);
    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('a plugin row states its version and origin', (tester) async {
    await _pump(tester, _bigServer());
    await tester.tap(find.byKey(const ValueKey('exu-tab-plugins')));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('cph-row-plugin:installed:plugin-00')),
        matching: find.textContaining('v1.0.0 · Integrado'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('cph-row-plugin:installed:plugin-01')),
        matching: find.textContaining('v1.1.0 · Usuario'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('the state filter and the search work on the long list', (
    tester,
  ) async {
    await _pump(tester, _bigServer());
    await tester.tap(find.byKey(const ValueKey('spp-status-inactive')));
    await tester.pumpAndSettle();
    expect(_rows('cph-row-skill:installed:'), 30);
    await tester.enterText(
      find.byKey(const ValueKey('cph-search')),
      'skill-151',
    );
    await tester.pumpAndSettle();
    expect(_rows('cph-row-skill:installed:'), 1);
    expect(
      find.byKey(const ValueKey('cph-row-skill:installed:skill-151')),
      findsOneWidget,
    );
    await tester.enterText(
      find.byKey(const ValueKey('cph-search')),
      'skill-150',
    );
    await tester.pumpAndSettle();
    // skill-150 is on, so the "inactive" filter hides it.
    expect(find.byKey(const ValueKey('cph-empty-installed')), findsOneWidget);
  });

  testWidgets('large text: no overflow and the switch keeps a 48 dp target', (
    tester,
  ) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await _pump(tester, _bigServer());

    expect(tester.takeException(), isNull);
    final size = tester.getSize(
      find.byKey(const ValueKey('spp-switch-skill:installed:skill-000')),
    );
    expect(size.height, greaterThanOrEqualTo(48));
    expect(size.width, greaterThanOrEqualTo(48));
    // The name is still there and not squeezed out by the control.
    expect(find.text('skill-000'), findsOneWidget);
  });

  testWidgets('every switch is named for a screen reader', (tester) async {
    await _pump(tester, _bigServer());
    final handle = tester.ensureSemantics();
    final named = find.bySemanticsLabel(RegExp('Activar skill-000'));
    expect(named, findsOneWidget);
    final data = tester.getSemantics(named).getSemanticsData();
    expect(data.hasFlag(SemanticsFlag.hasToggledState), isTrue);
    // skill-000 is on.
    expect(data.hasFlag(SemanticsFlag.isToggled), isTrue);
    handle.dispose();
  });

  testWidgets('each tab keeps its own scroll position', (tester) async {
    await _pump(tester, _bigServer());
    // The tabs scroll with the page, so they can only be reached near the
    // top: leave the list a little way down, with its tabs still in reach.
    tester.state<ScrollableState>(_scrollable).position.jumpTo(10);
    await tester.pump();
    expect(_offset(tester), 10);

    await tester.tap(find.byKey(const ValueKey('exu-tab-plugins')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('cph-row-plugin:installed:plugin-00')),
      findsOneWidget,
      reason: 'the tab changed',
    );
    expect(_offset(tester), 0, reason: 'its own list starts at the top');

    await tester.tap(find.byKey(const ValueKey('exu-tab-skills')));
    await tester.pumpAndSettle();
    expect(_offset(tester), closeTo(10, 0.5));
  });

  testWidgets('coming back from a detail keeps the scroll', (tester) async {
    await _pump(tester, _bigCatalog(), segment: CapabilitiesSegment.catalog);
    await tester.drag(_list, const Offset(0, -500));
    await tester.pumpAndSettle();
    final before = _offset(tester);
    await tester.ensureVisible(find.text('cat-010'));
    await tester.pumpAndSettle();
    final shown = _offset(tester);
    await tester.tap(find.text('cat-010'));
    await tester.pumpAndSettle();
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    expect(_offset(tester), closeTo(shown, 1));
    expect(shown, greaterThan(before - 1));
  });

  testWidgets('pulling down reads the server again', (tester) async {
    final rest = _bigServer();
    await _pump(tester, rest);
    final before = rest.calls.where((c) => c == 'GET skills').length;
    await tester.fling(_list, const Offset(0, 500), 1000);
    await tester.pumpAndSettle();
    expect(rest.calls.where((c) => c == 'GET skills').length, before + 1);
  });

  group('hub search', () {
    ScriptedRest server() => _SlowSearchRest()
      ..gets['skills'] = <Object>[]
      ..gets['skills/hub/official'] = {'skills': <Object>[]}
      ..gets['skills/hub/search'] = {
        'results': [
          {
            'name': 'remote-one',
            'identifier': 'github/x/remote-one',
            'description': 'From the hub',
            'trust_level': 'community',
          },
        ],
        'installed': <String, Object>{},
      };

    testWidgets('says it is searching instead of "no results"', (tester) async {
      final rest = server() as _SlowSearchRest;
      await _pump(tester, rest, segment: CapabilitiesSegment.catalog);
      rest.gate = Completer<void>();
      await tester.enterText(
        find.byKey(const ValueKey('cph-search')),
        'remote',
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byKey(const ValueKey('spp-hub-searching')), findsOneWidget);
      expect(find.byKey(const ValueKey('cph-empty-catalog')), findsNothing);

      rest.gate!.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('spp-hub-searching')), findsNothing);
      expect(find.text('remote-one'), findsOneWidget);
    });

    testWidgets(
      'an answer that arrives after the query was cleared is dropped',
      (tester) async {
        final rest = server() as _SlowSearchRest;
        await _pump(tester, rest, segment: CapabilitiesSegment.catalog);
        rest.gate = Completer<void>();
        await tester.enterText(
          find.byKey(const ValueKey('cph-search')),
          'remote',
        );
        await tester.pump(const Duration(milliseconds: 50));
        await tester.enterText(find.byKey(const ValueKey('cph-search')), 're');
        await tester.pump(const Duration(milliseconds: 50));
        rest.gate!.complete();
        await tester.pumpAndSettle();
        expect(find.text('remote-one'), findsNothing);
        expect(find.byKey(const ValueKey('spp-hub-searching')), findsNothing);
      },
    );
  });
}
