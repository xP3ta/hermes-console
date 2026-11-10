import 'dart:ui' show SemanticsAction;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/activity_snapshot.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/theme_contrast.dart';
import 'package:hermes_android/core/widgets/chat/turn_memory_pill.dart';
import 'package:hermes_android/core/widgets/chat_event_cards.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

ChatTraceEvent _event(
  String id, {
  String action = 'add',
  bool user = false,
  String status = 'completed',
  Object? result = const {'success': true},
  String preview = 'La preferencia confirmada.',
  String label = 'memory',
}) {
  final call = MemoryWrite.fromArgs('memory', {
    'action': action,
    'target': user ? 'user' : 'memory',
    'content': preview,
    'old_text': preview,
    'new_text': preview,
  });
  return ChatTraceEvent(
    id: id,
    label: label,
    status: status,
    memory: result == null ? call : MemoryWrite.settle(call, result),
  );
}

Widget _host(
  Widget child, {
  bool dark = true,
  bool reduced = false,
  double width = 320,
  double scale = 1,
  Locale locale = const Locale('es'),
}) => MaterialApp(
  locale: locale,
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: dark ? AppTheme.hermesRedDark : AppTheme.hermesRedLight,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      disableAnimations: reduced,
      textScaler: TextScaler.linear(scale),
    ),
    child: child!,
  ),
  home: Scaffold(
    body: SingleChildScrollView(
      child: SizedBox(width: width, child: child),
    ),
  ),
);

void main() {
  testWidgets('the confirmed receipt and preview use the English catalog', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        TurnMemoryPill(events: [_event('english')]),
        locale: const Locale('en'),
      ),
    );
    await tester.pumpAndSettle();
    final pill = find.byKey(const ValueKey('turn-memory-pill'));
    expect(
      find.descendant(of: pill, matching: find.text('Saved to memory')),
      findsOneWidget,
    );
    await tester.tap(pill);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('turn-memory-preview')), findsOneWidget);
    expect(find.text('Guardado en memoria'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test(
    'only the latest confirmed, completed memory write produces a receipt',
    () {
      final good = _event('good');
      final events = [
        good,
        good,
        _event('pending', result: null),
        _event('staged', result: {'success': true, 'staged': true}),
        _event('failed', status: 'failed'),
        _event('running', status: 'running'),
        _event('no', result: {'success': false}),
        _event('foreign', label: 'terminal'),
        _event('superseded'),
        _event('superseded', status: 'failed'),
      ];
      expect(confirmedTurnMemory(events).map((entry) => entry.id), ['good']);
      expect(events.length, 10, reason: 'presentation does not mutate source');
    },
  );

  for (final user in [false, true]) {
    for (final action in ['add', 'replace', 'remove']) {
      testWidgets(
        '$action to ${user ? 'profile' : 'memory'}: one live/settled pill opens its safe preview',
        (tester) async {
          final events = [_event('m', action: action, user: user)];
          final semantics = tester.ensureSemantics();
          try {
            await tester.pumpWidget(
              _host(TurnMemoryPill(events: events, active: true)),
            );
            await tester.pumpAndSettle();
            final pill = find.byKey(const ValueKey('turn-memory-pill'));
            expect(pill, findsOneWidget);
            final node = tester.getSemantics(pill);
            expect(node.flagsCollection.isButton, isTrue);
            expect(node.flagsCollection.isLiveRegion, isFalse);
            expect(
              node.getSemanticsData().hasAction(SemanticsAction.tap),
              isTrue,
            );
            final context = tester.element(pill);
            final label = memoryWriteLabel(
              Strings.of(context),
              events.single.memory!,
            );
            expect(node.label, label);
            await tester.pumpWidget(
              _host(TurnMemoryPill(events: [...events, ...events])),
            );
            await tester.pumpAndSettle();
            expect(pill, findsOneWidget);
            expect(
              tester.getSemantics(pill).flagsCollection.isLiveRegion,
              isFalse,
            );
            await tester.tap(pill);
            await tester.pumpAndSettle();
            expect(
              find.byKey(const ValueKey('turn-memory-preview')),
              findsOneWidget,
            );
            expect(find.text('La preferencia confirmada.'), findsOneWidget);
            expect(find.textContaining('tool_id'), findsNothing);
            expect(tester.takeException(), isNull);
          } finally {
            semantics.dispose();
          }
        },
      );
    }
  }

  testWidgets(
    'multiple confirmed writes aggregate once and leave no duplicate successful memory step',
    (tester) async {
      final events = [
        _event('a'),
        _event('b', action: 'remove'),
        _event('f', status: 'failed'),
      ];
      await tester.pumpWidget(
        _host(
          Column(
            children: [
              ThinkingTraceCard(
                events: events,
                active: false,
                stepCards: true,
                headerBuilder: (_, summary, details) => details,
              ),
              const Text('Respuesta final'),
              TurnMemoryPill(events: events),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('turn-memory-pill')), findsOneWidget);
      expect(find.text('Memoria actualizada'), findsOneWidget);
      expect(find.byKey(const ValueKey('turn-step-card-a')), findsNothing);
      expect(find.byKey(const ValueKey('turn-step-card-b')), findsNothing);
      // The failed write is a call of the turn: one closed line, no card.
      expect(find.byKey(const ValueKey('turn-line-f')), findsOneWidget);
      expect(find.byKey(const ValueKey('turn-step-card-f')), findsNothing);
      expect(find.byKey(const ValueKey('memory-saved-marker')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('turn-memory-pill')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey(('memory-preview', 'a'))),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey(('memory-preview', 'b'))),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey(('memory-preview', 'f'))), findsNothing);
    },
  );

  testWidgets(
    'pending, staged and failed writes never show a confirmation or unsafe preview',
    (tester) async {
      final events = [
        _event('a', result: null),
        _event('b', status: 'failed'),
        _event('c', result: {'success': true, 'proposal_staged': true}),
      ];
      await tester.pumpWidget(_host(TurnMemoryPill(events: events)));
      expect(find.byKey(const ValueKey('turn-memory-pill')), findsNothing);
      final private = _event('private', preview: 'token=SECRET_VALUE_CANARY');
      await tester.pumpWidget(_host(TurnMemoryPill(events: [private])));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('turn-memory-pill')));
      await tester.pumpAndSettle();
      expect(find.textContaining('SECRET_VALUE_CANARY'), findsNothing);
    },
  );

  for (final width in [320.0, 884.0]) {
    for (final dark in [false, true]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets(
          '$width dp, ${dark ? 'dark' : 'light'}, ${scale}x: full label and 48 dp target at reduced motion',
          (tester) async {
            tester.view.physicalSize = Size(width, 884);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            await tester.pumpWidget(
              _host(
                TurnMemoryPill(events: [_event('m', user: true)]),
                width: width,
                dark: dark,
                scale: scale,
                reduced: true,
              ),
            );
            final pill = find.byKey(const ValueKey('turn-memory-pill'));
            expect(tester.getSize(pill).height, greaterThanOrEqualTo(48));
            final rect = tester.getRect(pill);
            expect(rect.left, greaterThanOrEqualTo(0));
            expect(rect.right, lessThanOrEqualTo(width));
            expect(pill.hitTestable(), findsOneWidget);
            final text = tester.widget<Text>(
              find.descendant(of: pill, matching: find.byType(Text)),
            );
            expect(text.maxLines, isNull);
            expect(text.overflow, isNull);
            final material = tester.widget<Material>(
              find.ancestor(of: pill, matching: find.byType(Material)).first,
            );
            expect(
              ThemeContrast.ratio(text.style!.color!, material.color!),
              greaterThanOrEqualTo(4.5),
            );
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }
}
