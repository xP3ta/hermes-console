// Children that a fenced roster of this connection no longer lists, with no
// closure: the capsule says «N subagentes · No activos · Resultado final no
// disponible» — not busy, no clock, no outcome — and the rows keep their
// phase. It is said whole at a phone width and at the largest supported text
// size (Android 200 % × the reader's 150 %, measured with Inter), never cut.
// A child still unconfirmed keeps «Sin confirmar»; live children keep
// their count; confirmed-absent ones are never counted as occupation.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/activity_snapshot.dart';
import 'package:hermes_android/core/models/subagent_activity.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat/delegated_work_pill.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'support/inter_font.dart';

final _t0 = DateTime.utc(2026, 11, 15, 10);
final _now = DateTime.utc(2026, 11, 15, 12);
final _scope = SubagentActivityScope(
  connectionId: 'c',
  parentSessionId: 'p',
  runtimeSessionId: 'r',
  turnEpoch: 1,
);

SubagentActivity _child(String id, SubagentActivityPhase phase) =>
    SubagentActivity(
      key: SubagentActivityKey(
        scope: _scope,
        identityKind: SubagentIdentityKind.subagent,
        stableId: id,
      ),
      source: SubagentActivitySource.native,
      phase: phase,
      subagentId: id,
      details: SubagentActivityDetails(startedAt: _t0),
    );

List<SubagentActivity> _batch(String prefix, int n, SubagentActivityPhase p) =>
    [for (var i = 1; i <= n; i++) _child('$prefix$i', p)];

Widget _host(
  List<SubagentActivity> subagents, {
  Set<SubagentActivityKey> absent = const {},
  double textScale = 1.1,
}) => MaterialApp(
  theme: AppTheme.fromId('dark'),
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  builder: (context, body) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: body!,
  ),
  home: Scaffold(
    body: Align(
      alignment: Alignment.bottomCenter,
      child: DelegatedWorkPill(
        name: 'Chat',
        capsule: true,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        snapshot: ActivitySnapshot(
          subagents: subagents,
          subagentsAbsentConfirmed: absent,
        ),
        onOpen: () async {},
        clock: () => _now,
      ),
    ),
  ),
);

final _capText = find.byKey(const ValueKey('delegates-capsule-text'));
final _cap = find.byKey(const ValueKey('delegates-capsule'));
final _doneClaim = RegExp(r'✓|terminaron|terminados|\blistos?\b');
final _clock = RegExp(r'\b\d+:\d{2}\b');

String _label(WidgetTester tester) => tester.widget<Text>(_capText).data!;

Set<SubagentActivityKey> _keys(List<SubagentActivity> rows) => {
  for (final a in rows) a.key,
};

void main() {
  setUpAll(loadInterFont);

  // Hermes' density (1.10) under Android's scale × the reader's factor:
  // normal, 2.2× and the maximum 3.3×.
  for (final scale in const [1.1, 2.2, 3.3]) {
    testWidgets('8 confirmed not active, phone width, text ${scale}x: the '
        'whole label, no overflow, no clock, no outcome', (tester) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final rows = _batch('n', 8, SubagentActivityPhase.unknown);
      await tester.pumpWidget(
        _host(rows, absent: _keys(rows), textScale: scale),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(
        _label(tester),
        '8 subagentes · No activos · Resultado final no disponible',
      );
      final paragraph = tester.renderObject<RenderParagraph>(_capText);
      expect(paragraph.didExceedMaxLines, isFalse, reason: 'never cut');
      final rect = tester.getRect(_cap);
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(360));
      expect(_doneClaim.hasMatch(_label(tester)), isFalse);
      expect(_clock.hasMatch(_label(tester)), isFalse);
    });
  }

  testWidgets('one confirmed not active: singular', (tester) async {
    final rows = [_child('n1', SubagentActivityPhase.unknown)];
    await tester.pumpWidget(_host(rows, absent: _keys(rows)));
    await tester.pump();
    expect(
      _label(tester),
      '1 subagente · No activo · Resultado final no disponible',
    );
  });

  testWidgets('a child still unconfirmed keeps «Sin confirmar» beside the '
      'confirmed-absent ones', (tester) async {
    final absent = _batch('a', 3, SubagentActivityPhase.unknown);
    final gap = _child('g1', SubagentActivityPhase.unknown);
    await tester.pumpWidget(_host([...absent, gap], absent: _keys(absent)));
    await tester.pump();
    expect(_label(tester), 'Sin confirmar');
  });

  testWidgets('live children are the occupation; confirmed-absent ones are '
      'not counted', (tester) async {
    final absent = _batch('a', 3, SubagentActivityPhase.unknown);
    final live = _batch('l', 2, SubagentActivityPhase.running);
    await tester.pumpWidget(_host([...live, ...absent], absent: _keys(absent)));
    await tester.pump();
    // Running, the capsule paints the count of the live ones (the clock
    // sits beside it); the absent ones are not in it.
    expect(_label(tester), '2 subagentes');
    expect(_label(tester), isNot(contains('No activo')));
  });

  testWidgets('working, then all confirmed not active: the explicit state, '
      'never «terminaron»', (tester) async {
    final live = _batch('n', 8, SubagentActivityPhase.running);
    await tester.pumpWidget(_host(live));
    await tester.pump();
    expect(_label(tester), '8 subagentes');
    final rows = _batch('n', 8, SubagentActivityPhase.unknown);
    await tester.pumpWidget(_host(rows, absent: _keys(rows)));
    await tester.pump();
    expect(
      _label(tester),
      '8 subagentes · No activos · Resultado final no disponible',
    );
    await tester.pump(const Duration(seconds: 4));
    expect(_cap, findsOneWidget, reason: 'it stays, it does not flash');
  });
}
