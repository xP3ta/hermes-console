// The delegated-work capsule and header say «terminaron / terminados /
// listos» only with server terminal evidence for EACH child (stable key) the
// group counted while it worked: absence, or terminal rows of another batch,
// credit nothing (the capsule goes quiet, as Hermes Desktop's status stack).
// The clock runs from the start to the latest durable completion, never to
// «now», and there is no clock without a completion time. Background
// processes alone keep their previous behaviour.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/activity_snapshot.dart';
import 'package:hermes_android/core/models/session_activity.dart';
import 'package:hermes_android/core/models/subagent_activity.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat/delegated_work_pill.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

final _t0 = DateTime.utc(2026, 11, 15, 10);
final _now = DateTime.utc(2026, 11, 15, 12); // tras la ausencia
final _scope = SubagentActivityScope(
  connectionId: 'c',
  parentSessionId: 'p',
  runtimeSessionId: 'r',
  turnEpoch: 1,
);

SubagentActivity _child(
  String id,
  SubagentActivityPhase phase, {
  DateTime? started,
  DateTime? completed,
}) => SubagentActivity(
  key: SubagentActivityKey(
    scope: _scope,
    identityKind: SubagentIdentityKind.subagent,
    stableId: id,
  ),
  source: SubagentActivitySource.native,
  phase: phase,
  subagentId: id,
  details: SubagentActivityDetails(
    startedAt: started ?? _t0,
    completedAt: completed,
  ),
);

List<SubagentActivity> _batch(
  String prefix,
  int n,
  SubagentActivityPhase phase, {
  DateTime? started,
  DateTime? completed,
}) => [
  for (var i = 1; i <= n; i++)
    _child('$prefix$i', phase, started: started, completed: completed),
];

Widget _host(
  List<SubagentActivity> subagents, {
  List<SessionActivityProcess> processes = const [],
  int generic = 0,
  DateTime? backgroundStartedAt,
}) {
  final snapshot = ActivitySnapshot(
    subagents: subagents,
    processes: processes,
    subagentGenericCount: generic,
    backgroundStartedAt: backgroundStartedAt,
  );
  return MaterialApp(
    theme: AppTheme.fromId('dark'),
    locale: const Locale('es'),
    localizationsDelegates: Strings.localizationsDelegates,
    supportedLocales: Strings.supportedLocales,
    home: Scaffold(
      body: Column(
        children: [
          DelegatedWorkPill(
            key: const ValueKey('f1-capsule'),
            name: 'Chat',
            capsule: true,
            snapshot: snapshot,
            onOpen: () async {},
            clock: () => _now,
          ),
          DelegatedWorkPill(
            key: const ValueKey('f1-header'),
            name: 'Chat',
            snapshot: snapshot,
            onOpen: () async {},
            clock: () => _now,
          ),
        ],
      ),
    ),
  );
}

List<String> _texts(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
    .where((t) => t.isNotEmpty)
    .toList();

final _doneClaim = RegExp(r'✓|terminaron|terminados|\blistos?\b');
final _clock = RegExp(r'\b\d+:\d{2}\b');

/// Precondición: la píldora presentó el trabajo vivo antes de cualquier
/// negativa (no se prueba el silencio de algo que nunca se pintó).
Future<List<String>> _working(
  WidgetTester tester,
  List<SubagentActivity> live,
  String expectLabel,
) async {
  await tester.pumpWidget(_host(live));
  await tester.pump();
  final texts = _texts(tester);
  expect(
    texts.any((t) => t.contains(expectLabel)),
    isTrue,
    reason: 'precondición: «$expectLabel» visible',
  );
  return texts;
}

Future<void> _drain(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 4));
}

Future<List<String>> _then(
  WidgetTester tester,
  List<SubagentActivity> next,
  String tag,
) => _pumpTexts(tester, _host(next), tag);

Future<List<String>> _pumpTexts(
  WidgetTester tester,
  Widget w,
  String tag,
) async {
  await tester.pumpWidget(w);
  await tester.pump();
  final texts = _texts(tester);
  return texts;
}

void main() {
  group('delegated work: «terminaron» needs terminal evidence per child', () {
    testWidgets(
      'counted children that vanish without a closure: quiet — 8 vivos desaparecen sin cierre → silencio',
      (tester) async {
        await _working(
          tester,
          _batch('n', 8, SubagentActivityPhase.running),
          '8 subagentes',
        );
        final after = await _then(tester, const [], 'w1');
        expect(after.where(_doneClaim.hasMatch), isEmpty);
        expect(after.where(_clock.hasMatch), isEmpty);
        await _drain(tester);
      },
    );

    testWidgets(
      'terminal rows of an earlier batch credit nothing — 8 terminales VIEJOS presentes + 8 actuales '
      'desaparecen sin cierre → silencio',
      (tester) async {
        final old = _batch(
          'o',
          8,
          SubagentActivityPhase.completed,
          started: _t0.subtract(const Duration(hours: 2)),
          completed: _t0.subtract(const Duration(hours: 1)),
        );
        await _working(tester, [
          ...old,
          ..._batch('n', 8, SubagentActivityPhase.running),
        ], '16 subagentes');
        final after = await _then(tester, old, 'w2');
        expect(
          after.where(_doneClaim.hasMatch),
          isEmpty,
          reason: 'terminales de otra tanda no acreditan a los ausentes',
        );
        expect(after.where(_clock.hasMatch), isEmpty);
        await _drain(tester);
      },
    );

    testWidgets(
      'terminal without completedAt: done, credited count, no clock — terminal real de los 8 contados SIN completedAt '
      'tras la ausencia → done con recuento 8 y SIN hora',
      (tester) async {
        await _working(
          tester,
          _batch('n', 8, SubagentActivityPhase.running),
          '8 subagentes',
        );
        final after = await _then(
          tester,
          _batch('n', 8, SubagentActivityPhase.completed),
          'w3',
        );
        expect(
          after.any((t) => t.startsWith('✓ 8 subagentes termin')),
          isTrue,
          reason: 'evidencia terminal de las 8 identidades contadas',
        );
        expect(after.any((t) => t.contains('8 listos')), isTrue);
        expect(
          after.where(_clock.hasMatch),
          isEmpty,
          reason: 'sin completedAt no hay duración',
        );
        await _drain(tester);
      },
    );

    testWidgets(
      '3 of 8 terminal and 5 gone: never «8 terminaron» — 3 de 8 terminales y 5 desaparecen → nunca «8 '
      'terminaron»; silencio',
      (tester) async {
        await _working(
          tester,
          _batch('n', 8, SubagentActivityPhase.running),
          '8 subagentes',
        );
        final after = await _then(
          tester,
          _batch(
            'n',
            3,
            SubagentActivityPhase.completed,
            completed: _t0.add(const Duration(minutes: 5)),
          ),
          'w4',
        );
        expect(after.where((t) => t.contains('8 subagentes termin')), isEmpty);
        expect(after.where(_doneClaim.hasMatch), isEmpty);
        expect(after.where(_clock.hasMatch), isEmpty);
        await _drain(tester);
      },
    );

    testWidgets(
      'durable closure of all: done with the time to the last completion — cierre durable real de los 8 → «✓ 8 subagentes '
      'terminaron · 5:00» (hasta completedAt) y «8 listos»',
      (tester) async {
        await _working(
          tester,
          _batch('n', 8, SubagentActivityPhase.running),
          '8 subagentes',
        );
        final after = await _then(
          tester,
          _batch(
            'n',
            8,
            SubagentActivityPhase.completed,
            completed: _t0.add(const Duration(minutes: 5)),
          ),
          'w5',
        );
        expect(after, contains('✓ 8 subagentes terminaron · 5:00'));
        expect(after.any((t) => t.contains('8 listos')), isTrue);
        await _drain(tester);
      },
    );

    testWidgets('a failure: «Falló» until seen — fallo → «Falló» hasta verse', (
      tester,
    ) async {
      await _working(
        tester,
        _batch('n', 8, SubagentActivityPhase.running),
        '8 subagentes',
      );
      final after = await _then(tester, [
        ..._batch(
          'n',
          7,
          SubagentActivityPhase.completed,
          completed: _t0.add(const Duration(minutes: 5)),
        ),
        _child(
          'n8',
          SubagentActivityPhase.failed,
          completed: _t0.add(const Duration(minutes: 5)),
        ),
      ], 'w6');
      expect(after.any((t) => t.contains('Falló')), isTrue);
      await tester.pump(const Duration(seconds: 10));
      expect(_texts(tester).any((t) => t.contains('Falló')), isTrue);
      await _drain(tester);
    });

    testWidgets(
      'live children: the count — 8 vivos → «8 subagentes»',
      (tester) async {
        final texts = await _working(
          tester,
          _batch('n', 8, SubagentActivityPhase.running),
          '8 subagentes',
        );
        expect(texts.where((t) => t.contains('Sin confirmar')), isEmpty);
        await _drain(tester);
      },
    );
    testWidgets(
      'old terminal rows plus a background process that ends: as before — 8 terminales VIEJOS + 1 proceso vivo que '
      'acaba → igual que base (solo procesos, sin cambio)',
      (tester) async {
        final old = _batch(
          'o',
          8,
          SubagentActivityPhase.completed,
          started: _t0.subtract(const Duration(hours: 2)),
          completed: _t0.subtract(const Duration(hours: 1)),
        );
        final proc = SessionActivityProcess(
          id: 'p1',
          command: 'make build',
          notifyOnComplete: false,
          startedAt: _now.subtract(const Duration(minutes: 2)),
        );
        final working = await _pumpTexts(
          tester,
          _host(
            old,
            processes: [proc],
            backgroundStartedAt: _now.subtract(const Duration(minutes: 2)),
          ),
          'x1-working',
        );
        expect(
          working.any((t) => t.contains('proceso')),
          isTrue,
          reason: 'precondición: el proceso vivo está presentado',
        );
        final after = await _pumpTexts(tester, _host(old), 'x1-after');
        // Salida exacta de la base 0b40fd1 (f1-red2-base): «✓ 9 subagentes
        // terminaron · 2:00» y «9 listos» (recuento heredado _lastTotal).
        expect(after, contains('✓ 9 subagentes terminaron · 2:00'));
        expect(after.any((t) => t.contains('9 listos')), isTrue);
        await _drain(tester);
      },
    );

    testWidgets(
      'a finished child retired mid-work keeps its evidence — A termina (10:03) y se retira del snapshot '
      'mientras B sigue; B termina (10:05) → «✓ 2 subagentes terminaron · '
      '5:00», «2 listos»',
      (tester) async {
        await _working(tester, [
          _child('a', SubagentActivityPhase.running),
          _child('b', SubagentActivityPhase.running),
        ], '2 subagentes');
        await _pumpTexts(
          tester,
          _host([
            _child(
              'a',
              SubagentActivityPhase.completed,
              completed: _t0.add(const Duration(minutes: 3)),
            ),
            _child('b', SubagentActivityPhase.running),
          ]),
          'x2-a-done',
        );
        // chat_screen.dart:10038 → retireConversationSubagents: la fila
        // terminal de A sale del roster; B sigue vivo.
        final mid = await _pumpTexts(
          tester,
          _host([_child('b', SubagentActivityPhase.running)]),
          'x2-retired',
        );
        expect(
          mid.any((t) => t.contains('1 subagente')),
          isTrue,
          reason: 'precondición: el trabajo sigue presentado',
        );
        final after = await _pumpTexts(
          tester,
          _host([
            _child(
              'b',
              SubagentActivityPhase.completed,
              completed: _t0.add(const Duration(minutes: 5)),
            ),
          ]),
          'x2-after',
        );
        expect(after, contains('✓ 2 subagentes terminaron · 5:00'));
        expect(after.any((t) => t.contains('2 listos')), isTrue);
        await _drain(tester);
      },
    );

    testWidgets(
      'number-only roster: quiet — roster solo numérico: 3 sin filas → 0 → '
      'silencio conservador',
      (tester) async {
        final working = await _pumpTexts(
          tester,
          _host(const [], generic: 3),
          'x3-working',
        );
        expect(
          working.any((t) => t.contains('3')),
          isTrue,
          reason: 'precondición: el recuento numérico está presentado',
        );
        final after = await _pumpTexts(tester, _host(const []), 'x3-after');
        expect(after.where(_doneClaim.hasMatch), isEmpty);
        expect(after.where(_clock.hasMatch), isEmpty);
        await _drain(tester);
      },
    );
  });
}
