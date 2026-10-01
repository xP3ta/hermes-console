// mp1215: a memory write the gateway confirmed shows a distinct «Guardado en
// memoria» marker in the chat; pending, failed, staged or private writes do
// not. Fixtures are synthetic.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/activity_snapshot.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/services/active_chat_service.dart'
    show normalizeTranscriptMessageForDisplay;
import 'package:hermes_android/core/services/session_reconciler.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat_event_cards.dart';
import 'package:hermes_android/core/widgets/hermes_premium_ui.dart'
    show HermesShimmerText;
import 'package:hermes_android/l10n/app_localizations.dart';

Widget _host(Widget child, {bool reduceMotion = false}) => MaterialApp(
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.hermesRedDark,
  home: Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
      child: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: 380, child: child),
        ),
      ),
    ),
  ),
);

Map<String, dynamic> _call(String id, Map<String, Object?> args) => {
  'role': 'assistant',
  'content': '',
  'tool_calls': [
    {
      'id': id,
      'type': 'function',
      'function': {'name': 'memory', 'arguments': jsonEncode(args)},
    },
  ],
};

Map<String, dynamic> _result(String id, Map<String, Object?> result) => {
  'role': 'tool',
  'tool_name': 'memory',
  'tool_call_id': id,
  'content': jsonEncode(result),
};

const _ok = {'success': true, 'done': true, 'entry_count': 4};

/// The live chat path: steps exactly as `_activity_trace` stores them.
ChatTraceEvent _event(
  String id,
  Map<String, Object?> args, {
  Object? result,
  String status = 'completed',
}) {
  final call = MemoryWrite.fromArgs('memory', args);
  final write = result == null ? call : MemoryWrite.settle(call, result);
  final step = normalizeAssistantActivityStep({
    'kind': 'tool',
    'label': 'memory',
    'status': status,
    'id': id,
    'memory': ?write?.toStep(),
  })!;
  return ChatTraceEvent(
    id: id,
    label: 'memory',
    status: step['status'] as String,
    memory: MemoryWrite.fromStep(step['memory']),
  );
}

Widget _trace(List<ChatTraceEvent> events, {bool active = false}) =>
    ThinkingTraceCard(
      events: events,
      active: active,
      liveInPill: true,
      duration: const Duration(seconds: 4),
      headerBuilder: (context, summary, details) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [summary, details],
      ),
    );

String _summaryText(WidgetTester tester) => tester
    .widget<Text>(find.byKey(const ValueKey('tool-run-summary')))
    .textSpan!
    .toPlainText();

DesktopSessionSnapshot _snap(List<Map<String, dynamic>> messages) =>
    DesktopSessionSnapshot.fromJson(
      {
        'session_id': 'runtime-mp1215',
        'session_key': 'stored-mp1215',
        'messages': messages,
      },
      requestedStoredSessionId: 'stored-mp1215',
      created: false,
      method: 'session.resume',
    );

List<Map<String, dynamic>> _historyMemory(List<Map<String, dynamic>> rows) {
  final projection = const DesktopSessionReconciler().project(_snap(rows));
  return [
    for (final message in projection.messagesNewestFirst)
      for (final step in normalizeAssistantActivityTrace(
        message[assistantActivityTraceKey],
      ))
        if (step['memory'] != null) step['memory'] as Map<String, dynamic>,
  ];
}

void main() {
  group('legacy activity group (REST rows)', () {
    testWidgets('a landed add shows «Guardado en memoria» with its text', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          ToolActivityGroup(
            events: [
              ChatEventInfo.classify(
                _call('m1', {
                  'action': 'add',
                  'content': 'El proyecto usa Flutter 3.38.',
                }),
              ),
              ChatEventInfo.classify(_result('m1', _ok)),
            ],
          ),
        ),
      );
      expect(find.text('Guardado en memoria'), findsOneWidget);
      expect(find.text('El proyecto usa Flutter 3.38.'), findsOneWidget);
      expect(_summaryText(tester), contains('memoria'));
      expect(_summaryText(tester), isNot(contains('memory')));
    });

    testWidgets('a pending call (no result yet) is not marked', (tester) async {
      await tester.pumpWidget(
        _host(
          ToolActivityGroup(
            events: [
              ChatEventInfo.classify(
                _call('m1', {'action': 'add', 'content': 'Algo'}),
              ),
            ],
          ),
        ),
      );
      expect(find.byKey(const ValueKey('memory-saved-marker')), findsNothing);
    });

    testWidgets('a failed or staged write is not marked', (tester) async {
      await tester.pumpWidget(
        _host(
          ToolActivityGroup(
            events: [
              ChatEventInfo.classify(
                _call('m1', {'action': 'add', 'content': 'Algo'}),
              ),
              ChatEventInfo.classify(
                _result('m1', {'success': false, 'error': 'Memory is full.'}),
              ),
              ChatEventInfo.classify(
                _call('m2', {'action': 'remove', 'old_text': 'Otra'}),
              ),
              ChatEventInfo.classify(
                _result('m2', {
                  'success': true,
                  'staged': true,
                  'pending_id': 'p1',
                }),
              ),
            ],
          ),
        ),
      );
      expect(find.byKey(const ValueKey('memory-saved-marker')), findsNothing);
    });
  });

  group('activity trace marker', () {
    for (final (args, label) in [
      (
        {'action': 'add', 'content': 'Prefiere respuestas cortas.'},
        'Guardado en memoria',
      ),
      (
        {
          'action': 'add',
          'target': 'user',
          'content': 'Prefiere respuestas cortas.',
        },
        'Guardado en tu perfil',
      ),
      (
        {
          'action': 'replace',
          'old_text': 'Flutter 3.35',
          'content': 'Prefiere respuestas cortas.',
        },
        'Memoria actualizada',
      ),
      (
        {
          'action': 'replace',
          'target': 'user',
          'old_text': 'x',
          'content': 'Prefiere respuestas cortas.',
        },
        'Perfil actualizado',
      ),
      (
        {'action': 'remove', 'old_text': 'Prefiere respuestas cortas.'},
        'Quitado de memoria',
      ),
      (
        {
          'action': 'remove',
          'target': 'user',
          'old_text': 'Prefiere respuestas cortas.',
        },
        'Quitado de tu perfil',
      ),
      (
        {
          'operations': [
            {'action': 'add', 'content': 'Prefiere respuestas cortas.'},
            {'action': 'add', 'content': 'Usa Linux.'},
          ],
        },
        'Guardado en memoria',
      ),
    ]) {
      testWidgets('$label from ${args.keys.join('+')}', (tester) async {
        await tester.pumpWidget(
          _host(_trace([_event('m', args, result: _ok)])),
        );
        expect(find.text(label), findsOneWidget);
        expect(find.text('Prefiere respuestas cortas.'), findsOneWidget);
        expect(
          _summaryText(tester).replaceAll('\uFFFC', ''),
          startsWith('memoria'),
        );
        expect(
          find.byKey(const ValueKey('tool-run-memory-icon')),
          findsOneWidget,
        );
      });
    }

    testWidgets('running, failed and unknown-result calls are not marked', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          _trace([
            _event('a', {'action': 'add', 'content': 'x'}, status: 'running'),
            _event(
              'b',
              {'action': 'add', 'content': 'y'},
              result: {'success': false, 'error': 'Memory is full.'},
              status: 'failed',
            ),
            _event('c', {'action': 'add', 'content': 'z'}),
          ]),
        ),
      );
      expect(find.byKey(const ValueKey('memory-saved-marker')), findsNothing);
    });

    testWidgets('a landed write without args still says what happened', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          _trace([
            ChatTraceEvent(
              id: 'r',
              label: 'memory',
              status: 'completed',
              memory: MemoryWrite.settle(null, {
                'success': true,
                'target': 'user',
                'removed_entry': 'dato',
              }),
            ),
          ]),
        ),
      );
      expect(find.text('Quitado de tu perfil'), findsOneWidget);
      expect(find.byKey(const ValueKey('memory-saved-preview')), findsNothing);
    });

    testWidgets('a long preview folds to two lines and expands on tap', (
      tester,
    ) async {
      final long = List.filled(30, 'El agente recuerda este dato.').join(' ');
      await tester.pumpWidget(
        _host(
          _trace([
            _event('m', {'action': 'add', 'content': long}, result: _ok),
          ]),
          reduceMotion: true,
        ),
      );
      Text preview() => tester.widget<Text>(
        find.byKey(const ValueKey('memory-saved-preview')),
      );
      expect(preview().maxLines, 2);
      expect(find.text('Ver más'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('memory-saved-marker')));
      await tester.pump();
      expect(preview().maxLines, isNull);
      expect(find.text('Ver menos'), findsOneWidget);
      // Static chrome: no shimmer, and it settles once the ink fades.
      expect(find.byType(HermesShimmerText), findsNothing);
      await tester.pumpAndSettle();
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('a short preview has no toggle', (tester) async {
      await tester.pumpWidget(
        _host(
          _trace([
            _event('m', {'action': 'add', 'content': 'Corto.'}, result: _ok),
          ]),
        ),
      );
      expect(find.byKey(const ValueKey('memory-saved-toggle')), findsNothing);
    });

    testWidgets('the live, still-working block shows a landed write', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          _trace([
            _event('m', {'action': 'add', 'content': 'Dato.'}, result: _ok),
          ], active: true),
        ),
      );
      expect(find.text('Guardado en memoria'), findsOneWidget);
    });

    testWidgets('the semantics label reads the action and the text', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(
          _trace([
            _event('m', {'action': 'add', 'content': 'Dato.'}, result: _ok),
          ]),
        ),
      );
      expect(
        find.bySemanticsLabel('Guardado en memoria. Dato.'),
        findsOneWidget,
      );
      handle.dispose();
    });
  });

  group('summary chip', () {
    test('memory is its own entry after skills, counted', () {
      final items = summarizeToolRun([
        for (final label in ['terminal', 'memory', 'memory'])
          (label: label, skill: false, detail: null, running: false),
        (
          label: 'skill_view',
          skill: false,
          detail: 'github-pr-workflow',
          running: false,
        ),
      ]);
      expect(items.map((i) => (i.label, i.count, i.skill, i.memory)).toList(), [
        ('github-pr-workflow', 1, true, false),
        ('memory', 2, false, true),
        ('terminal', 1, false, false),
      ]);
    });
  });

  group('projection', () {
    test('args: preview is screened, collapsed and capped', () {
      expect(
        MemoryWrite.fromArgs('memory', {
          'action': 'add',
          'content': 'api_key=sk-abc123',
        })!.preview,
        isNull,
      );
      expect(
        MemoryWrite.fromArgs('memory', {
          'action': 'add',
          'content': 'línea uno\n\n  línea\u202e dos',
        })!.preview,
        'línea uno línea dos',
      );
      final capped = MemoryWrite.fromArgs('memory', {
        'action': 'add',
        'content': 'x' * 1000,
      })!.preview!;
      expect(capped.length, lessThanOrEqualTo(280));
      expect(MemoryWrite.fromArgs('terminal', {'action': 'add'}), isNull);
      expect(MemoryWrite.fromArgs('memory', {'action': 'read'}), isNull);
    });

    test('a non-memory step can never carry a memory write', () {
      final step = normalizeAssistantActivityStep({
        'kind': 'tool',
        'label': 'terminal',
        'status': 'completed',
        'memory': {'action': 'add', 'landed': true, 'preview': 'x'},
      })!;
      expect(step.containsKey('memory'), isFalse);
    });

    test('durable history settles the call with its result', () {
      final memory = _historyMemory([
        {'role': 'user', 'content': 'Recuerda esto', 'message_id': 'u1'},
        {
          ..._call('m1', {
            'action': 'add',
            'target': 'user',
            'content': 'Vive en Lisboa.',
          }),
          'message_id': 'a1',
        },
        {
          ..._result('m1', {..._ok, 'target': 'user'}),
          'message_id': 't1',
        },
        {'role': 'assistant', 'content': 'Hecho.', 'message_id': 'a2'},
      ]);
      expect(memory, [
        {
          'action': 'add',
          'target': 'user',
          'landed': true,
          'preview': 'Vive en Lisboa.',
        },
      ]);
    });

    test('durable history: a failed result stays unlanded', () {
      final memory = _historyMemory([
        {'role': 'user', 'content': 'Recuerda esto', 'message_id': 'u1'},
        {
          ..._call('m1', {'action': 'add', 'content': 'Algo'}),
          'message_id': 'a1',
        },
        {
          ..._result('m1', {'success': false, 'error': 'full'}),
          'message_id': 't1',
        },
      ]);
      expect(memory.single['landed'], isFalse);
    });

    test('privacy veto: a privately classified call yields no marker', () {
      final memory = _historyMemory([
        {'role': 'user', 'content': 'Recuerda esto', 'message_id': 'u1'},
        {
          ..._call('m1', {'action': 'add', 'content': 'Secreto privado'}),
          'message_id': 'a1',
          'hidden': true,
        },
        {..._result('m1', _ok), 'message_id': 't1', 'hidden': true},
        {'role': 'assistant', 'content': 'Hecho.', 'message_id': 'a2'},
      ]);
      expect(memory, isEmpty);
    });

    test('REST rows: no call args survive, the result still lands', () {
      final call = normalizeTranscriptMessageForDisplay(
        _call('m1', {
          'action': 'add',
          'target': 'user',
          'content': 'Dato público',
          'extra': 'NO-DEBE-SALIR',
        }),
        retainMediaEvidence: true,
      )!;
      expect(jsonEncode(call), isNot(contains('NO-DEBE-SALIR')));
      final other = normalizeTranscriptMessageForDisplay({
        'role': 'assistant',
        'content': '',
        'tool_calls': [
          {
            'id': 't1',
            'function': {
              'name': 'terminal',
              'arguments': '{"command":"echo SECRETO"}',
            },
          },
        ],
      }, retainMediaEvidence: true)!;
      expect(jsonEncode(other), isNot(contains('SECRETO')));
      final steps = normalizeAssistantActivityTrace(
        coalesceAssistantTurnsNewestFirst([
          normalizeTranscriptMessageForDisplay(
            _result('m1', _ok),
            retainMediaEvidence: true,
          )!,
          call,
        ]).single[assistantActivityTraceKey],
      );
      // The public REST projection drops call args; the label comes from
      // the result alone and no text is shown.
      expect(jsonEncode(call), isNot(contains('Dato público')));
      expect(steps.single['memory'], {
        'action': 'add',
        'target': 'memory',
        'landed': true,
      });
      expect(
        normalizeTranscriptMessageForDisplay({
          ..._call('m2', {'action': 'add', 'content': 'privado'}),
          'hidden': true,
        }, retainMediaEvidence: true),
        isNull,
      );
    });

    test('privacy veto: a hidden result cannot land a visible call', () {
      final memory = _historyMemory([
        {'role': 'user', 'content': 'Recuerda esto', 'message_id': 'u1'},
        {
          ..._call('m1', {'action': 'add', 'content': 'Dato'}),
          'message_id': 'a1',
        },
        {..._result('m1', _ok), 'message_id': 't1', 'is_hidden': true},
      ]);
      expect(memory.every((m) => m['landed'] == false), isTrue);
    });
  });
}
