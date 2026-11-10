import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/activity_snapshot.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat/turn_memory_pill.dart';
import 'package:hermes_android/core/widgets/chat_event_cards.dart';
import 'package:hermes_android/core/widgets/chat_turn_activity.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

// Memory steps (mock approved on 10 nov 2026): the OMH plugin's
// `omh_remember` counts as memory like Hermes' own `memory`, and the live
// window shows the four states of a memory write.

final _start = DateTime(2026, 11, 10);

String _omh(String status, {Map<String, Object?> extra = const {}}) =>
    jsonEncode({
      'schema_version': 'omh_memory_capture/v1',
      'plugin_tool': 'omh_remember',
      'action': 'save',
      'status': status,
      ...extra,
    });

ChatTraceEvent _event(
  String id, {
  String label = 'omh_remember',
  String status = 'completed',
  Object? args = const {'summary': 'Prefiere respuestas cortas.'},
  Object? result,
}) {
  final call = MemoryWrite.fromArgs(label, args);
  return ChatTraceEvent(
    id: id,
    label: label,
    status: status,
    startedAt: _start,
    memory: result == null ? call : MemoryWrite.settle(call, result),
  );
}

Widget _turn(List<ChatTraceEvent> events) => MaterialApp(
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.fromMode(AppThemeMode.dark),
  home: Scaffold(
    body: SingleChildScrollView(
      child: LiveTurnScope(
        inlineActivity: true,
        status: LiveTurnStatus(
          active: true,
          startedAt: _start,
          headline: 'Pensando…',
        ),
        clock: () => _start.add(const Duration(seconds: 5)),
        child: ThinkingTraceCard(
          active: true,
          stepCards: true,
          events: events,
          headerBuilder: (_, summary, details) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [summary, details],
          ),
        ),
      ),
    ),
  ),
);

void main() {
  group('which tools are memory', () {
    test('memory and omh remember, however the name is written', () {
      for (final name in [
        'memory',
        'omh_remember',
        'Omh Remember',
        'omh-remember',
        ' OMH_REMEMBER ',
      ]) {
        expect(isMemoryTool(name), isTrue, reason: name);
      }
    });

    test('other tools are not memory', () {
      for (final name in [
        'terminal',
        'omh_memory',
        'memory_search',
        'session_search',
        'read_file',
        '',
      ]) {
        expect(isMemoryTool(name), isFalse, reason: name);
      }
    });
  });

  group('omh remember as a memory write', () {
    test('save adds, save with replaces updates, recall is not a write', () {
      expect(
        MemoryWrite.fromArgs('omh_remember', {'summary': 'x'})?.action,
        MemoryWriteAction.add,
      );
      expect(
        MemoryWrite.fromArgs('omh_remember', {
          'action': 'save',
          'summary': 'x',
          'replaces': 'rec_1',
        })?.action,
        MemoryWriteAction.replace,
      );
      expect(
        MemoryWrite.fromArgs('omh_remember', {'action': 'recall', 'query': 'q'}),
        isNull,
      );
      expect(MemoryWrite.fromArgs('omh_remember', {'summary': 'x'})?.userTarget,
          isFalse);
    });

    test('only a stored status lands; queued, refused and error do not', () {
      for (final status in ['remembered', 'corrected', 'already_remembered']) {
        expect(memoryResultLanded(_omh(status)), isTrue, reason: status);
      }
      for (final status in ['pending_review', 'refused', 'error']) {
        expect(memoryResultLanded(_omh(status)), isFalse, reason: status);
      }
      expect(memoryResultLanded('not json at all'), isFalse);
      expect(memoryResultLanded(_omh('remembered').replaceAll('save', 'recall')),
          isFalse);
    });

    test('settle: corrected is an update, refused is rejected, queued is neither',
        () {
      final call = MemoryWrite.fromArgs('omh_remember', {'summary': 'x'});
      final fixed = MemoryWrite.settle(null, _omh('corrected'))!;
      expect(fixed.action, MemoryWriteAction.replace);
      expect(fixed.landed, isTrue);
      final refused = MemoryWrite.settle(call, _omh('refused'))!;
      expect([refused.landed, refused.rejected], [false, true]);
      final queued = MemoryWrite.settle(call, _omh('pending_review'))!;
      expect([queued.landed, queued.rejected], [false, false]);
      expect(MemoryWrite.settle(null, _omh('remembered').replaceAll('save', 'recall')),
          isNull);
    });

    test('the built-in memory tool keeps its rules', () {
      expect(memoryResultLanded({'success': true, 'done': true}), isTrue);
      expect(memoryResultLanded({'success': true, 'staged': true}), isFalse);
      final failed = MemoryWrite.settle(null, {'success': false, 'error': 'x'})!;
      expect([failed.landed, failed.rejected], [false, true]);
      expect(
        MemoryWrite.fromStep(failed.toStep())!.rejected,
        isTrue,
      );
    });
  });

  group('the live window', () {
    testWidgets('saving: spinner and «Guardando en memoria» with the text', (
      tester,
    ) async {
      await tester.pumpWidget(_turn([_event('m1', status: 'running')]));
      expect(find.textContaining('Guardando en memoria'), findsOneWidget);
      expect(find.textContaining('Prefiere respuestas cortas'), findsWidgets);
      expect(find.byKey(const ValueKey('live-turn-glyph-memory')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('live-turn-row-m1')),
          matching: find.byKey(const ValueKey('live-ring-spinner')),
        ),
        findsOneWidget,
      );
    });

    testWidgets('saved: ring with check and «Guardado en memoria»', (
      tester,
    ) async {
      await tester.pumpWidget(_turn([_event('m1', result: _omh('remembered'))]));
      expect(find.textContaining('Guardado en memoria'), findsOneWidget);
      expect(find.byKey(const ValueKey('live-ring-check')), findsOneWidget);
      expect(find.byKey(const ValueKey('live-ring-bang')), findsNothing);
    });

    testWidgets('user profile: «Perfil actualizado»', (tester) async {
      await tester.pumpWidget(
        _turn([
          _event(
            'm1',
            label: 'memory',
            args: const {'action': 'add', 'target': 'user', 'content': 'Vive en Cádiz.'},
            result: const {'success': true, 'target': 'user'},
          ),
        ]),
      );
      expect(find.textContaining('Perfil actualizado'), findsOneWidget);
    });

    testWidgets('remove: «Quitando…» while running, «Quitado» once done', (
      tester,
    ) async {
      const args = {'action': 'remove', 'target': 'memory', 'old_text': 'Vive en Cádiz.'};
      await tester.pumpWidget(
        _turn([_event('m1', label: 'memory', status: 'running', args: args)]),
      );
      expect(find.textContaining('Quitando de memoria'), findsOneWidget);
      expect(find.textContaining('Guardando'), findsNothing);
      await tester.pumpWidget(
        _turn([
          _event('m1', label: 'memory', args: args, result: const {'success': true, 'target': 'memory'}),
        ]),
      );
      expect(find.textContaining('Quitado de memoria'), findsOneWidget);
      expect(find.textContaining('Guardado'), findsNothing);
    });

    testWidgets('operations batch of removes says removed, never saved', (
      tester,
    ) async {
      await tester.pumpWidget(
        _turn([
          _event(
            'm1',
            label: 'memory',
            args: const {
              'target': 'user',
              'operations': [
                {'action': 'remove', 'old_text': 'a'},
                {'action': 'remove', 'old_text': 'b'},
              ],
            },
            result: const {'success': true, 'target': 'user'},
          ),
        ]),
      );
      expect(find.textContaining('Quitado de tu perfil'), findsOneWidget);
      expect(find.textContaining('Guardado'), findsNothing);
    });

    testWidgets('a failure never says saved: orange ring with «!»', (
      tester,
    ) async {
      for (final event in [
        _event('m1', status: 'failed'),
        _event('m1', result: _omh('refused', extra: {'reason': 'summary_too_long'})),
        _event(
          'm1',
          label: 'memory',
          args: const {'action': 'add', 'target': 'memory', 'content': 'x'},
          result: const {'success': false, 'error': 'full'},
        ),
      ]) {
        await tester.pumpWidget(_turn([event]));
        expect(find.textContaining('No se pudo guardar'), findsOneWidget);
        expect(find.textContaining('Guardado'), findsNothing);
        expect(find.textContaining('Perfil actualizado'), findsNothing);
        expect(find.byKey(const ValueKey('live-ring-bang')), findsOneWidget);
        expect(find.byKey(const ValueKey('live-ring-check')), findsNothing);
      }
    });

    testWidgets('queued for review is not «guardado» either', (tester) async {
      await tester.pumpWidget(
        _turn([_event('m1', result: _omh('pending_review'))]),
      );
      expect(find.textContaining('Guardado'), findsNothing);
      expect(find.byKey(const ValueKey('live-ring-check')), findsNothing);
    });

    testWidgets('memory rows are not folded into a run; other tools unchanged', (
      tester,
    ) async {
      await tester.pumpWidget(
        _turn([
          _event('m1', result: _omh('remembered')),
          _event('m2', result: _omh('remembered')),
          ChatTraceEvent(id: 't1', label: 'terminal', status: 'completed'),
        ]),
      );
      expect(find.textContaining('Guardado en memoria'), findsNWidgets(2));
      expect(find.byKey(const ValueKey('live-turn-glyph-terminal')), findsOneWidget);
      expect(find.byKey(const ValueKey('live-turn-glyph-memory')), findsNWidgets(2));
    });
  });

  group('the final receipt', () {
    test('counts omh remember writes that landed, not the ones that did not', () {
      final writes = confirmedTurnMemory([
        _event('m1', result: _omh('remembered')),
        _event('m2', result: _omh('corrected', extra: {'replaces': 'r'})),
        _event('m3', result: _omh('refused')),
        _event('m4', result: _omh('pending_review')),
        _event('m5', status: 'failed'),
      ]);
      expect(writes.map((w) => w.id), ['m1', 'm2']);
    });

    test('a removal receipt says removed, a mixed batch says updated', () {
      ChatTraceEvent rm(String id, String target) => _event(
        id,
        label: 'memory',
        args: {'action': 'remove', 'target': target, 'old_text': 'x'},
        result: {'success': true, 'target': target},
      );
      final s = lookupStrings(const Locale('es'));
      expect(
        confirmedMemoryLabel(s, confirmedTurnMemory([rm('a', 'memory')])),
        'Quitado de memoria',
      );
      expect(
        confirmedMemoryLabel(s, confirmedTurnMemory([rm('a', 'user')])),
        'Quitado de tu perfil',
      );
    });

    testWidgets('one receipt opens a sheet listing both writes', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('es'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          theme: AppTheme.fromMode(AppThemeMode.dark),
          home: Scaffold(
            body: TurnMemoryPill(
              events: [
                _event('m1', args: const {'summary': 'Primera preferencia.'}, result: _omh('remembered')),
                _event('m2', args: const {'summary': 'Segunda preferencia.'}, result: _omh('remembered')),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('turn-memory-pill')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('turn-memory-pill')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('turn-memory-preview')), findsOneWidget);
      expect(find.textContaining('Primera preferencia'), findsOneWidget);
      expect(find.textContaining('Segunda preferencia'), findsOneWidget);
    });
  });
}
