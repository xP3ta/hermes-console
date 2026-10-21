// The six Home widgets, one by one: what each shows at each size and in
// each state, what a tap opens, and that nothing overflows its cell.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/ui/roster/living_bot_face.dart';
import 'package:hermes_android/core/home/board/home_board_data.dart';
import 'package:hermes_android/core/home/board/home_board_model.dart';
import 'package:hermes_android/core/home/board/home_board_view.dart';
import 'package:hermes_android/core/home/board/home_board_tiles.dart';
import 'package:hermes_android/core/home/home_now.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import '../support/home_board_fixtures.dart';

const _small = HomeWidgetSize.small;
const _wide = HomeWidgetSize.wide;
const _large = HomeWidgetSize.large;

Finder _key(String key) => find.byKey(ValueKey(key));

/// Every text painted inside the tile, joined (rich text included).
String _plain(WidgetTester tester) => tester
    .widgetList<RichText>(find.byType(RichText))
    .map((t) => t.text.toPlainText())
    .join(' | ');

Finder _keys(String prefix) => find.byWidgetPredicate(
  (w) =>
      w.key is ValueKey<String> &&
      (w.key! as ValueKey<String>).value.startsWith(prefix),
);

void main() {
  setUp(() => debugLivingBotFacesStill = true);

  group('Ahora', () {
    final running = [
      homeChat('t1', homeT1, working: true, step: '2 subagentes'),
      homeChat(
        'bg',
        homeT2,
        working: true,
        step: 'Segundo plano',
        running: const Duration(minutes: 12, seconds: 40),
      ),
    ];
    final live = homeData(chats: running, bots: homeBots(), rooms: homeRooms());
    final asking = homeData(
      chats: running,
      bots: homeBots(astraWaits: true),
      rooms: homeRooms(),
      questions: [homeQuestionItem()],
    );
    final calm = homeData(
      chats: [
        homeChat('t3', homeT3, agent: 'Fable'),
        homeChat('t4', homeT4, ago: const Duration(hours: 1)),
      ],
      bots: [homeBot('Fable'), homeBot('Astra')],
    );

    testWidgets('small, a question: who asks, and one way to answer', (
      tester,
    ) async {
      final c = await pumpHomeTile(
        tester,
        kind: HomeWidgetKind.now,
        size: _small,
        data: asking,
      );
      expect(find.text('Ahora'), findsOneWidget);
      expect(find.text('Astra'), findsOneWidget);
      expect(find.text('te pregunta'), findsOneWidget);
      expect(find.text('Responder'), findsOneWidget);
      expect(find.text('Sí, úsalo'), findsNothing);
      await tester.tap(find.text('Responder'));
      expect(c.log, ['question:q1']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('small, an approval: «pide permiso» and Ver', (tester) async {
      final c = await pumpHomeTile(
        tester,
        kind: HomeWidgetKind.now,
        size: _small,
        data: homeData(approvals: [homeApproval()], bots: homeBots()),
      );
      expect(find.text('Forja'), findsOneWidget);
      expect(find.text('pide permiso'), findsOneWidget);
      expect(find.text('Ver'), findsOneWidget);
      expect(find.text('Permitir'), findsNothing);
      await tester.tap(find.text('Ver'));
      expect(c.log, ['approval:a1']);
      expect(c.answers, isEmpty);
    });

    testWidgets('small, running: who, where, what and for how long', (
      tester,
    ) async {
      final c = await pumpHomeTile(
        tester,
        kind: HomeWidgetKind.now,
        size: _small,
        data: live,
      );
      expect(find.text('Forja'), findsOneWidget);
      expect(find.text('Console Devs'), findsOneWidget);
      expect(find.text('Responde'), findsOneWidget);
      expect(find.text(' · 2:14'), findsOneWidget);
      await tester.tap(find.text('Forja'));
      expect(c.log, ['room:devs']);
    });

    testWidgets('small, calm: «Todo tranquilo» and the last thing that '
        'finished', (tester) async {
      final c = await pumpHomeTile(
        tester,
        kind: HomeWidgetKind.now,
        size: _small,
        data: calm,
      );
      expect(_key('home-now-calm'), findsOneWidget);
      expect(find.text('Todo tranquilo'), findsOneWidget);
      expect(find.text('Fable terminó'), findsOneWidget);
      expect(find.text('hace 20 min'), findsOneWidget);
      await tester.tap(find.text('Todo tranquilo'));
      expect(c.log, ['chat:t3']);
    });

    testWidgets('wide, a question: its text and its own choices answer it '
        'from Home', (tester) async {
      final c = await pumpHomeTile(
        tester,
        kind: HomeWidgetKind.now,
        size: _wide,
        data: asking,
      );
      expect(find.text('Astra te pregunta'), findsOneWidget);
      expect(find.text(homeQuestion), findsOneWidget);
      expect(find.text('3 en marcha'), findsOneWidget);
      expect(find.text('Sí, úsalo'), findsOneWidget);
      expect(find.text('No'), findsOneWidget);
      expect(find.text('Responder'), findsOneWidget);
      // A bot that asks through a question is listed once, not also as
      // «te espera».
      expect(find.textContaining('te espera'), findsNothing);
      await tester.tap(find.text('Sí, úsalo'));
      await tester.pump();
      expect(c.choices, [('q1', 'Sí, úsalo')]);
      await tester.tap(find.text('No'));
      await tester.pump();
      expect(c.choices.last, ('q1', 'No'));
      await tester.tap(find.text('Responder'));
      expect(c.log, ['question:q1']);
    });

    testWidgets('wide, a question without choices: only Responder', (
      tester,
    ) async {
      await pumpHomeTile(
        tester,
        kind: HomeWidgetKind.now,
        size: _wide,
        data: homeData(questions: [homeQuestionItem(choices: const [])]),
      );
      expect(find.text(homeQuestion), findsOneWidget);
      expect(_keys('home-now-choice'), findsNothing);
      expect(find.text('Responder'), findsOneWidget);
    });

    testWidgets('wide, an approval: Permitir and Rechazar answer the exact '
        'request, Ver opens it', (tester) async {
      final c = await pumpHomeTile(
        tester,
        kind: HomeWidgetKind.now,
        size: _wide,
        data: homeData(approvals: [homeApproval()]),
      );
      expect(find.text('Forja pide permiso'), findsOneWidget);
      expect(find.text('git push origin fix/dock'), findsOneWidget);
      await tester.tap(find.text('Permitir'));
      await tester.pump();
      expect(c.answers, [('a1', true)]);
      await tester.tap(find.text('Rechazar'));
      await tester.pump();
      expect(c.answers.last, ('a1', false));
      await tester.tap(find.text('Ver'));
      expect(c.log, ['approval:a1']);
    });

    testWidgets('while an answer is in flight no second answer is sent', (
      tester,
    ) async {
      final hold = Completer<void>();
      final calls = HomeCalls()..hold = hold.future;
      await pumpHomeTile(
        tester,
        kind: HomeWidgetKind.now,
        size: _wide,
        data: homeData(approvals: [homeApproval()]),
        calls: calls,
      );
      await tester.tap(find.text('Permitir'));
      await tester.pump();
      await tester.tap(find.text('Rechazar'));
      await tester.tap(find.text('Permitir'));
      await tester.pump();
      expect(calls.answers, [('a1', true)]);
      hold.complete();
      await tester.pump();
      await tester.pump();
      await tester.tap(find.text('Rechazar'));
      await tester.pump();
      expect(calls.answers, [('a1', true), ('a1', false)]);
    });

    testWidgets('no Permitir when the request does not offer it', (
      tester,
    ) async {
      await pumpHomeTile(
        tester,
        kind: HomeWidgetKind.now,
        size: _wide,
        data: homeData(approvals: [homeApproval(canAllow: false)]),
      );
      expect(find.text('Permitir'), findsNothing);
      expect(find.text('Rechazar'), findsOneWidget);
      expect(find.text('Ver'), findsOneWidget);
    });

    testWidgets('wide, running: a row per thing alive with its clock; each '
        'opens its own place', (tester) async {
      final c = await pumpHomeTile(
        tester,
        kind: HomeWidgetKind.now,
        size: _wide,
        data: live,
      );
      expect(_key('home-now-running'), findsOneWidget);
      expect(find.text('3 en marcha'), findsOneWidget);
      // Two rows fit a wide cell: the room, then the main agent's chat.
      expect(_keys('home-now-run-'), findsOneWidget);
      final text = _plain(tester);
      expect(text, contains('Console Devs'));
      expect(text, isNot(contains(homeT1)));
      expect(find.text('2 subagentes'), findsNothing);
      expect(find.text(' · 2:14'), findsOneWidget);
      expect(find.text('Ver'), findsOneWidget);
      await tester.tap(_key('home-now-run-room:devs'));
      expect(c.log, ['room:devs']);
      // Forja replies in a room: one row, not a second one for its chat.
      expect(_key('home-now-run-bot:forja'), findsNothing);
    });

    testWidgets('wide, calm: the last two that finished, who and when', (
      tester,
    ) async {
      final c = await pumpHomeTile(
        tester,
        kind: HomeWidgetKind.now,
        size: _wide,
        data: calm,
      );
      expect(find.text('Todo tranquilo'), findsOneWidget);
      final text = _plain(tester);
      expect(text, contains('Fable terminó · $homeT3'));
      expect(text, contains(homeT4));
      expect(find.text('hace 20 min'), findsOneWidget);
      expect(find.text('hace 1 h'), findsOneWidget);
      expect(_key('home-now-note'), findsNothing);
      await tester.tap(_key('home-now-done-done:t4'));
      expect(c.log, ['chat:t4']);
    });

    testWidgets('calm with nothing finished yet is only «Todo tranquilo»', (
      tester,
    ) async {
      for (final size in HomeWidgetSize.values) {
        await pumpHomeTile(
          tester,
          kind: HomeWidgetKind.now,
          size: size,
          data: homeData(),
        );
        expect(find.text('Todo tranquilo'), findsOneWidget, reason: '$size');
        expect(_keys('home-now-done-'), findsNothing);
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('large: what is for you first, with its answers, then '
        'everything alive', (tester) async {
      final c = await pumpHomeTile(
        tester,
        kind: HomeWidgetKind.now,
        size: _large,
        data: asking,
      );
      expect(find.text('1 para ti · 3 en marcha'), findsOneWidget);
      expect(find.text(homeQuestion), findsOneWidget);
      expect(find.text('Sí, úsalo'), findsOneWidget);
      expect(_keys('home-now-run-'), findsOneWidget);
      final ask = tester.getRect(find.text(homeQuestion));
      final answers = tester.getRect(find.text('Sí, úsalo'));
      final firstRun = tester.getRect(_key('home-now-run-room:devs'));
      final lastRun = tester.getRect(find.byType(HomeWidgetBody));
      expect(ask.bottom, lessThanOrEqualTo(answers.top));
      expect(answers.bottom, lessThanOrEqualTo(firstRun.top));
      expect(firstRun.bottom, lessThanOrEqualTo(lastRun.bottom));
      expect(_key('home-now-run-chat:bg'), findsNothing);
      await tester.tap(_key('home-now-run-room:devs'));
      expect(c.log, ['room:devs']);
    });

    testWidgets('a failed turn and a paused queue also wait for you', (
      tester,
    ) async {
      await pumpHomeTile(
        tester,
        kind: HomeWidgetKind.now,
        size: _large,
        data: homeData(
          chats: [
            homeChat('f', 'Migración', failed: true, unread: true),
            homeChat('ok', homeT3),
          ],
        ),
      );
      expect(find.text('Hermes falló'), findsOneWidget);
      expect(find.text('Migración'), findsOneWidget);
      expect(find.text('1 para ti'), findsOneWidget);
    });

    testWidgets('edit mode: nothing answers and nothing opens', (tester) async {
      final c = await pumpHomeTile(
        tester,
        kind: HomeWidgetKind.now,
        size: _large,
        data: homeData(
          approvals: [homeApproval()],
          chats: [homeChat('t1', homeT1, working: true)],
        ),
        editing: true,
      );
      await tester.tap(find.text('Permitir'), warnIfMissed: false);
      await tester.tap(find.text('Ver').first, warnIfMissed: false);
      await tester.tap(_key('home-now-run-chat:t1'), warnIfMissed: false);
      await tester.pump();
      expect(c.answers, isEmpty);
      expect(c.log, isEmpty);
    });

    testWidgets('English', (tester) async {
      await pumpHomeTile(
        tester,
        kind: HomeWidgetKind.now,
        size: _large,
        data: asking,
        locale: const Locale('en'),
      );
      expect(find.text('Now'), findsOneWidget);
      expect(find.text('Astra asks you'), findsOneWidget);
      expect(find.text('1 for you · 3 running'), findsOneWidget);
      expect(find.text('Reply'), findsOneWidget);
      expect(find.text('View'), findsOneWidget);
    });
  });

  group('Chats', () {
    final data = homeData(
      chats: homeChats(),
      questions: [
        homeQuestionItem(
          key: 'q2',
          sessionKey: 't2',
          actor: null,
          question: '¿Sigo con la versión de marzo?',
          choices: const [],
        ),
      ],
    );

    testWidgets('small: the newest chat and its state; working shows its '
        'clock', (tester) async {
      final c = await pumpHomeTile(
        tester,
        kind: HomeWidgetKind.continueChats,
        size: _small,
        data: data,
      );
      expect(find.text('Chats'), findsOneWidget);
      expect(find.text(homeT1), findsOneWidget);
      expect(find.text('2 subagentes'), findsOneWidget);
      expect(find.text('0:41'), findsOneWidget);
      expect(find.text(homeT2), findsNothing);
      await tester.tap(find.text(homeT1));
      expect(c.log, ['chat:t1']);
    });

    testWidgets('small, finished: «Terminó» and when', (tester) async {
      await pumpHomeTile(
        tester,
        kind: HomeWidgetKind.continueChats,
        size: _small,
        data: homeData(chats: homeChats().sublist(2)),
      );
      expect(find.text(homeT3), findsOneWidget);
      expect(find.text('Terminó'), findsOneWidget);
      expect(find.text('21:44'), findsOneWidget);
    });

    testWidgets('wide: two chats, each with its live state', (tester) async {
      final c = await pumpHomeTile(
        tester,
        kind: HomeWidgetKind.continueChats,
        size: _wide,
        data: data,
      );
      expect(_keys('home-continue-'), findsOneWidget);
      expect(find.text('2 subagentes'), findsOneWidget);
      expect(find.text('0:41'), findsOneWidget);
      expect(
        find.text('Te pregunta · ¿Sigo con la versión de marzo?'),
        findsNothing,
      );
      expect(find.text('Responder'), findsNothing);
      await tester.tap(_key('home-continue-t1'));
      expect(c.log, ['chat:t1']);
    });

    testWidgets('large: five chats; finished with its reply and time, an '
        'unsent draft with its text', (tester) async {
      final c = await pumpHomeTile(
        tester,
        kind: HomeWidgetKind.continueChats,
        size: _large,
        data: data,
      );
      expect(_keys('home-continue-'), findsNWidgets(4));
      expect(
        find.text('Terminó · Te dejo tres opciones de píldora'),
        findsOneWidget,
      );
      expect(find.text('21:44'), findsOneWidget);
      expect(
        find.text('Borrador · Hola, necesito hacer unos retoques'),
        findsOneWidget,
      );
      expect(find.text('20:15'), findsOneWidget);
      expect(_key('home-continue-t5'), findsNothing);
      // In the order of the list, top to bottom.
      final tops = [
        for (final key in ['t1', 't2', 't3', 't4'])
          tester.getRect(_key('home-continue-$key')).top,
      ];
      expect(tops, [...tops]..sort());
      await tester.tap(_key('home-continue-t4'));
      expect(c.log, ['chat:t4']);
      // The header opens the whole list.
      await tester.tap(find.text('Chats'));
      expect(c.log.last, 'sessions');
    });

    testWidgets('a chat that failed says so; an older one shows its day', (
      tester,
    ) async {
      await pumpHomeTile(
        tester,
        kind: HomeWidgetKind.continueChats,
        size: _wide,
        data: homeData(
          chats: [
            homeChat('f', 'Migración', failed: true),
            homeChat('old', 'Viaje', at: DateTime(2026, 9, 25, 10)),
          ],
        ),
      );
      expect(find.text('Falló'), findsOneWidget);
      expect(find.text('25 sept'), findsOneWidget);
    });

    testWidgets('no chats yet; and still loading on a cold start', (
      tester,
    ) async {
      for (final size in HomeWidgetSize.values) {
        await pumpHomeTile(
          tester,
          kind: HomeWidgetKind.continueChats,
          size: size,
          data: homeData(),
        );
        expect(find.text('Aún no hay chats'), findsOneWidget, reason: '$size');
        expect(_key('home-initial-loading'), findsNothing);
        await pumpHomeTile(
          tester,
          kind: HomeWidgetKind.continueChats,
          size: size,
          data: homeData(chatsLoaded: false),
        );
        expect(_key('home-initial-loading'), findsOneWidget, reason: '$size');
        expect(find.text('Aún no hay chats'), findsNothing);
      }
    });
  });

  group('Bots', () {
    final live = homeData(
      bots: homeBots(astraWaits: true),
      rooms: homeRooms(),
      questions: [homeQuestionItem()],
    );
    final working = homeData(bots: homeBots(), rooms: homeRooms());
    final calm = homeData(
      bots: [
        homeBot(
          'Forja',
          lastTitle: 'Publicar',
          lastAt: homeAgoAt(const Duration(hours: 3)),
        ),
        homeBot(
          'Fable',
          lastTitle: 'Diseño',
          lastAt: homeAgoAt(const Duration(minutes: 20)),
        ),
        homeBot('Astra'),
        homeBot('Radar'),
      ],
    );

    testWidgets('small, live: the faces, who waits for you and who works', (
      tester,
    ) async {
      final c = await pumpHomeTile(
        tester,
        kind: HomeWidgetKind.team,
        size: _small,
        data: live,
      );
      expect(find.text('Bots'), findsOneWidget);
      for (final name in ['forja', 'fable', 'astra', 'radar']) {
        expect(_key('home-face-$name'), findsOneWidget, reason: name);
      }
      expect(_key('home-face-dot-forja'), findsOneWidget);
      expect(_key('home-face-dot-astra'), findsOneWidget);
      expect(_key('home-face-dot-fable'), findsNothing);
      expect(find.text('Astra te espera'), findsOneWidget);
      expect(find.text('Forja trabaja'), findsOneWidget);
      expect(find.text(' · 2:14'), findsOneWidget);
      await tester.tap(find.text('Astra te espera'));
      expect(c.log, ['bot:astra']);
    });

    testWidgets('small, calm: «En calma» and who finished last', (
      tester,
    ) async {
      await pumpHomeTile(
        tester,
        kind: HomeWidgetKind.team,
        size: _small,
        data: calm,
      );
      expect(find.text('En calma'), findsOneWidget);
      expect(find.text('Fable · hace 20 min'), findsOneWidget);
      expect(_keys('home-face-dot-'), findsNothing);
    });

    testWidgets('wide: four faces with their state, in their own order', (
      tester,
    ) async {
      final c = await pumpHomeTile(
        tester,
        kind: HomeWidgetKind.team,
        size: _wide,
        data: live,
      );
      expect(find.text('1 trabaja · 1 te espera'), findsOneWidget);
      final names = ['forja', 'fable', 'astra', 'radar'];
      final lefts = [
        for (final name in names)
          tester.getRect(_key('home-team-bot-$name')).left,
      ];
      expect(lefts, [...lefts]..sort());
      expect(_key('home-team-bot-argos'), findsNothing);
      expect(find.text('trabaja'), findsOneWidget);
      expect(find.text('te espera'), findsOneWidget);
      expect(find.text('libre'), findsNWidgets(2));
      await tester.tap(_key('home-team-bot-fable'));
      expect(c.log, ['bot:fable']);
    });

    testWidgets('large: a row per bot with what it does now, or the last '
        'thing it did and when', (tester) async {
      final c = await pumpHomeTile(
        tester,
        kind: HomeWidgetKind.team,
        size: _large,
        data: working,
      );
      expect(find.text('1 trabaja'), findsOneWidget);
      // Who works first, then by what finished last; nothing done, last.
      final order = ['forja', 'radar', 'fable', 'astra', 'argos'];
      final tops = [
        for (final name in order)
          tester.getRect(_key('home-bot-row-$name')).top,
      ];
      expect(tops, [...tops]..sort());
      // Forja replies in a room: the room and the room's clock.
      expect(find.text('Console Devs'), findsOneWidget);
      expect(find.text('2:14'), findsOneWidget);
      expect(find.text('Revisar disco'), findsOneWidget);
      expect(find.text('22:00'), findsOneWidget);
      expect(find.text('Diseño de píldora de estados'), findsOneWidget);
      expect(find.text('21:44'), findsOneWidget);
      expect(find.text('21:12'), findsOneWidget);
      expect(find.text('libre'), findsOneWidget);
      await tester.tap(_key('home-bot-row-radar'));
      await tester.tap(_key('home-bot-row-argos'));
      expect(c.log, ['bot:radar', 'bot:argos']);
    });

    testWidgets('large: the bot that asks is first, with its question', (
      tester,
    ) async {
      await pumpHomeTile(
        tester,
        kind: HomeWidgetKind.team,
        size: _large,
        data: live,
      );
      expect(find.text('1 trabaja · 1 te espera'), findsOneWidget);
      expect(
        tester.getRect(_key('home-bot-row-astra')).top,
        lessThan(tester.getRect(_key('home-bot-row-forja')).top),
      );
      expect(_plain(tester), contains('Astra  te pregunta'));
      expect(find.text(homeQuestion), findsOneWidget);
    });

    testWidgets('only the chosen bots; «solo los que trabajan»', (
      tester,
    ) async {
      await pumpHomeTile(
        tester,
        kind: HomeWidgetKind.team,
        size: _large,
        data: working,
        options: const {
          'bots': ['fable', 'radar'],
        },
      );
      expect(_keys('home-bot-row-'), findsNWidgets(2));
      await pumpHomeTile(
        tester,
        kind: HomeWidgetKind.team,
        size: _large,
        data: working,
        options: const {'onlyWorking': true},
      );
      expect(_keys('home-bot-row-'), findsOneWidget);
      expect(_key('home-bot-row-forja'), findsOneWidget);
      await pumpHomeTile(
        tester,
        kind: HomeWidgetKind.team,
        size: _large,
        data: calm,
        options: const {'onlyWorking': true},
      );
      expect(find.text('En calma'), findsOneWidget);
    });

    testWidgets('no bots; still loading; offline before the first read', (
      tester,
    ) async {
      for (final size in HomeWidgetSize.values) {
        await pumpHomeTile(
          tester,
          kind: HomeWidgetKind.team,
          size: size,
          data: homeData(),
        );
        expect(find.text('Aún no hay bots'), findsOneWidget, reason: '$size');
        await pumpHomeTile(
          tester,
          kind: HomeWidgetKind.team,
          size: size,
          data: homeData(botsLoaded: false),
        );
        expect(_key('home-widget-skeleton'), findsOneWidget, reason: '$size');
        await pumpHomeTile(
          tester,
          kind: HomeWidgetKind.team,
          size: size,
          data: homeData(botsLoaded: false, online: false),
        );
        expect(find.text('Sin conexión'), findsOneWidget, reason: '$size');
        expect(tester.takeException(), isNull);
      }
    });
  });

  group('Salas', () {
    final live = homeData(bots: homeBots(), rooms: homeRooms());
    final quiet = homeData(bots: homeBots(), rooms: homeRooms(live: false));

    testWidgets('small, live: who replies and for how long, who is next, '
        'what is unread', (tester) async {
      final c = await pumpHomeTile(
        tester,
        kind: HomeWidgetKind.room,
        size: _small,
        data: live,
      );
      expect(find.text('Salas'), findsOneWidget);
      expect(find.text('Console Devs'), findsOneWidget);
      expect(_key('home-room-unread'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      expect(find.text('Forja responde'), findsOneWidget);
      expect(find.text('Luego, Astra'), findsOneWidget);
      expect(find.text('2:14'), findsOneWidget);
      expect(find.text('+2'), findsOneWidget, reason: 'five members');
      await tester.tap(find.text('Console Devs'));
      expect(c.log, ['room:devs']);
    });

    testWidgets('small, quiet: the new messages and whose the last one is', (
      tester,
    ) async {
      await pumpHomeTile(
        tester,
        kind: HomeWidgetKind.room,
        size: _small,
        data: quiet,
      );
      // Unread first, the newest room first among those.
      expect(find.text('Console Devs'), findsOneWidget);
      expect(find.text('2 mensajes nuevos'), findsOneWidget);
      expect(find.text('Astra · 21:50'), findsOneWidget);
      expect(find.textContaining('responde'), findsNothing);
    });

    testWidgets('wide: two rooms, the live one first, each with its last '
        'line', (tester) async {
      final c = await pumpHomeTile(
        tester,
        kind: HomeWidgetKind.room,
        size: _wide,
        data: live,
      );
      expect(find.text('1 respondiendo'), findsOneWidget);
      expect(_keys('home-room-last-'), findsNWidgets(2));
      expect(
        tester.getRect(_key('home-room-devs')).top,
        lessThan(tester.getRect(_key('home-room-ideas')).top),
      );
      expect(find.text('Forja'), findsOneWidget);
      expect(find.text(' · 2:14'), findsOneWidget);
      expect(find.text('luego, Astra'), findsOneWidget);
      final text = _plain(tester);
      expect(text, contains('Astra: Lo reviso cuando acabe Forja'));
      expect(text, contains('Fable: ¿Y si el sprite'));
      expect(find.text('21:50'), findsOneWidget);
      await tester.tap(_key('home-room-ideas'));
      expect(c.log, ['room:ideas']);
    });

    testWidgets('large: three rooms; replies for you are marked', (
      tester,
    ) async {
      final c = await pumpHomeTile(
        tester,
        kind: HomeWidgetKind.room,
        size: _large,
        data: live,
      );
      expect(_keys('home-room-last-'), findsNWidgets(3));
      expect(_key('home-room-mentions'), findsOneWidget);
      expect(find.text('1 para ti'), findsOneWidget);
      expect(find.text('Forja responde'), findsOneWidget);
      expect(find.text(' · 2:14'), findsOneWidget);
      expect(find.text(' · luego, Astra'), findsOneWidget);
      expect(find.text('14:05'), findsOneWidget);
      expect(_plain(tester), contains('Radar: Disco al 93 %'));
      await tester.tap(_key('home-room-homelab'));
      expect(c.log, ['room:homelab']);
    });

    testWidgets('rooms chosen by the user show in their order, whatever is '
        'live', (tester) async {
      await pumpHomeTile(
        tester,
        kind: HomeWidgetKind.room,
        size: _large,
        data: live,
        options: const {
          'rooms': ['homelab', 'devs'],
        },
      );
      expect(_keys('home-room-last-'), findsNWidgets(2));
      expect(
        tester.getRect(_key('home-room-homelab')).top,
        lessThan(tester.getRect(_key('home-room-devs')).top),
      );
      // A small one follows the first of them.
      await pumpHomeTile(
        tester,
        kind: HomeWidgetKind.room,
        size: _small,
        data: live,
        options: const {
          'rooms': ['homelab'],
        },
      );
      expect(find.text('Homelab'), findsOneWidget);
      expect(find.text('Console Devs'), findsNothing);
    });

    testWidgets('no rooms; chosen rooms that are gone; loading', (
      tester,
    ) async {
      for (final size in HomeWidgetSize.values) {
        await pumpHomeTile(
          tester,
          kind: HomeWidgetKind.room,
          size: size,
          data: homeData(),
        );
        expect(find.text('Aún no hay salas'), findsOneWidget, reason: '$size');
        await pumpHomeTile(
          tester,
          kind: HomeWidgetKind.room,
          size: size,
          data: live,
          options: const {
            'rooms': ['gone'],
          },
        );
        expect(_key('home-widget-missing'), findsOneWidget, reason: '$size');
        await pumpHomeTile(
          tester,
          kind: HomeWidgetKind.room,
          size: size,
          data: homeData(botsLoaded: false, roomsState: HomeRoomsState.unknown),
        );
        expect(_key('home-widget-skeleton'), findsOneWidget, reason: '$size');
        expect(tester.takeException(), isNull);
      }
    });
  });

  group('Cron', () {
    final data = homeData(automations: homeJobs());

    testWidgets('small: the next run, its name and how long until it; a '
        'failed last run shows on the header', (tester) async {
      final c = await pumpHomeTile(
        tester,
        kind: HomeWidgetKind.cron,
        size: _small,
        data: data,
      );
      expect(find.text('Cron'), findsOneWidget);
      expect(find.text('03:00'), findsOneWidget);
      expect(find.text('Copia de seguridad'), findsOneWidget);
      // 22:04 to 03:00, to the nearest hour.
      expect(find.text('en 5 h'), findsOneWidget);
      expect(_key('home-auto-failed'), findsOneWidget);
      expect(find.text('1 falló'), findsOneWidget);
      expect(find.text('Revisar disco'), findsNothing);
      await tester.tap(find.text('Copia de seguridad'));
      expect(c.log, ['cron:backup']);
    });

    testWidgets('small with a fixed job: that job, its day first when it is '
        'not for today', (tester) async {
      final c = await pumpHomeTile(
        tester,
        kind: HomeWidgetKind.cron,
        size: _small,
        data: homeData(automations: homeJobs(failure: false)),
        options: const {'job': 'hr'},
      );
      expect(find.text('lun 12'), findsOneWidget);
      expect(find.text('Entrada RRHH'), findsOneWidget);
      expect(find.text('07:00 · en 9 h'), findsOneWidget);
      expect(_key('home-auto-failed'), findsNothing);
      await tester.tap(find.text('Entrada RRHH'));
      expect(c.log, ['cron:hr']);
    });

    testWidgets('wide: the next three, by next run', (tester) async {
      final c = await pumpHomeTile(
        tester,
        kind: HomeWidgetKind.cron,
        size: _wide,
        data: data,
      );
      expect(find.text('1 falló'), findsOneWidget);
      expect(_keys('home-run-'), findsNWidgets(2));
      final tops = [
        for (final key in ['backup', 'disk'])
          tester.getRect(_key('home-run-$key')).top,
      ];
      expect(tops, [...tops]..sort());
      expect(find.text('03:00'), findsOneWidget);
      expect(find.text('04:00'), findsOneWidget);
      expect(_key('home-run-hr'), findsNothing);
      expect(find.text('en 5 h'), findsOneWidget);
      expect(find.text('en 6 h'), findsOneWidget);
      expect(find.text('lun 12 · en 9 h'), findsNothing);
      await tester.tap(_key('home-run-disk'));
      expect(c.log, ['cron:disk']);
      await tester.tap(find.text('Cron'));
      expect(c.log.last, 'cron:all');
    });

    testWidgets('large: every job by next run with its last result; the '
        'failed one says so, the paused one is last', (tester) async {
      final c = await pumpHomeTile(
        tester,
        kind: HomeWidgetKind.cron,
        size: _large,
        data: data,
      );
      expect(_keys('home-run-'), findsNWidgets(5));
      final order = ['backup', 'disk', 'hr', 'daily', 'social'];
      final tops = [
        for (final key in order) tester.getRect(_key('home-run-$key')).top,
      ];
      expect(tops, [...tops]..sort());
      expect(find.text('Bien · 03:00'), findsOneWidget);
      expect(find.text('Revisar disco · cada 6 h'), findsOneWidget);
      expect(find.text('Bien · 22:00'), findsOneWidget);
      expect(find.text('Bien · vie 9'), findsOneWidget);
      expect(find.text('Falló · 08:30'), findsOneWidget);
      expect(find.text('En pausa'), findsOneWidget);
      expect(find.text('lun 12'), findsNWidgets(2));
      expect(find.text('en 10 h'), findsOneWidget);
      expect(find.text('1 falló'), findsOneWidget);
      await tester.tap(_key('home-run-daily'));
      expect(c.log, ['cron:daily']);
    });

    testWidgets('a fixed job is first in the bigger sizes too', (tester) async {
      await pumpHomeTile(
        tester,
        kind: HomeWidgetKind.cron,
        size: _wide,
        data: data,
        options: const {'job': 'daily'},
      );
      final tops = [
        for (final key in ['daily', 'backup'])
          tester.getRect(_key('home-run-$key')).top,
      ];
      expect(tops, [...tops]..sort());
    });

    testWidgets('nothing scheduled, no jobs, a fixed job that is gone', (
      tester,
    ) async {
      await pumpHomeTile(
        tester,
        kind: HomeWidgetKind.cron,
        size: _small,
        data: homeData(
          automations: [homeJob('social', 'Publicar', enabled: false)],
        ),
      );
      expect(find.text('Nada programado'), findsOneWidget);
      for (final size in HomeWidgetSize.values) {
        final c = await pumpHomeTile(
          tester,
          kind: HomeWidgetKind.cron,
          size: size,
          data: homeData(),
        );
        expect(
          find.text('Sin automatizaciones'),
          findsOneWidget,
          reason: '$size',
        );
        await tester.tap(find.text('Sin automatizaciones'));
        expect(c.log, ['cron:all']);
      }
      await pumpHomeTile(
        tester,
        kind: HomeWidgetKind.cron,
        size: _small,
        data: data,
        options: const {'job': 'gone'},
      );
      expect(_key('home-widget-missing'), findsOneWidget);
    });

    testWidgets('loading; a read that failed says so and reads again; '
        'offline', (tester) async {
      for (final size in HomeWidgetSize.values) {
        await pumpHomeTile(
          tester,
          kind: HomeWidgetKind.cron,
          size: size,
          data: homeData(automations: null),
        );
        expect(_key('home-widget-skeleton'), findsOneWidget, reason: '$size');
        final c = await pumpHomeTile(
          tester,
          kind: HomeWidgetKind.cron,
          size: size,
          data: homeData(automations: null, automationsFailed: true),
        );
        expect(find.text('No se pudo leer'), findsOneWidget, reason: '$size');
        await tester.tap(_key('home-widget-retry'));
        expect(c.log, ['retry']);
        await pumpHomeTile(
          tester,
          kind: HomeWidgetKind.cron,
          size: size,
          data: homeData(
            automations: null,
            automationsFailed: true,
            online: false,
          ),
        );
        expect(find.text('Sin conexión'), findsOneWidget, reason: '$size');
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('a failed refresh marks the data unread', (tester) async {
      await pumpHomeTile(
        tester,
        kind: HomeWidgetKind.cron,
        size: _wide,
        data: homeData(automations: homeJobs(), automationsFailed: true),
      );
      expect(_keys('home-run-'), findsNothing);
      expect(find.text('No se pudo leer'), findsOneWidget);
    });
  });

  group('Tareas', () {
    final data = homeData(bots: homeBots(), tasks: homeTasksBoard());
    final idle = homeData(tasks: homeTasksBoard(running: false));

    testWidgets('small: what is in progress, who runs it, and how many '
        'wait', (tester) async {
      final c = await pumpHomeTile(
        tester,
        kind: HomeWidgetKind.tasks,
        size: _small,
        data: data,
      );
      expect(find.text('Tareas'), findsOneWidget);
      expect(find.text('2 en curso'), findsOneWidget);
      expect(find.text('Publicar 1.2.15'), findsOneWidget);
      expect(find.text('Forja · en curso'), findsOneWidget);
      expect(find.text('4 pendientes'), findsOneWidget);
      await tester.tap(find.text('Publicar 1.2.15'));
      expect(c.log, ['task:k1']);
    });

    testWidgets('small, nothing in progress: how many wait and the first', (
      tester,
    ) async {
      final c = await pumpHomeTile(
        tester,
        kind: HomeWidgetKind.tasks,
        size: _small,
        data: idle,
      );
      expect(_key('home-tasks-idle'), findsOneWidget);
      expect(find.text('4'), findsOneWidget);
      expect(find.text('pendientes'), findsOneWidget);
      expect(find.text('Probar GPT-Live con pantalla apagada'), findsOneWidget);
      await tester.tap(find.text('pendientes'));
      expect(c.log, ['task:all']);
    });

    testWidgets('wide: the tasks in progress with who runs them, then what '
        'waits', (tester) async {
      final c = await pumpHomeTile(
        tester,
        kind: HomeWidgetKind.tasks,
        size: _wide,
        data: data,
      );
      expect(find.text('2 en curso · 4 pendientes'), findsOneWidget);
      expect(_keys('home-task-'), findsNWidgets(2));
      expect(find.text('Publicar 1.2.15'), findsOneWidget);
      expect(find.text('Forja'), findsOneWidget);
      expect(find.text('Rediseñar Inicio'), findsOneWidget);
      expect(find.text('Astra'), findsOneWidget);
      expect(find.text('Probar GPT-Live con pantalla apagada'), findsNothing);
      await tester.tap(_key('home-task-k2'));
      expect(c.log, ['task:k2']);
      await tester.tap(find.text('Tareas'));
      expect(c.log.last, 'task:all');
    });

    testWidgets('large: En curso and Pendiente, each with its count', (
      tester,
    ) async {
      final c = await pumpHomeTile(
        tester,
        kind: HomeWidgetKind.tasks,
        size: _large,
        data: data,
      );
      final text = _plain(tester);
      expect(text, contains('EN CURSO  2'));
      expect(text, contains('PENDIENTE  4'));
      expect(_keys('home-task-'), findsNWidgets(5));
      final tops = [
        tester.getRect(_key('home-tasks-running')).top,
        tester.getRect(_key('home-task-k1')).top,
        tester.getRect(_key('home-task-k2')).top,
        tester.getRect(_key('home-tasks-pending')).top,
        tester.getRect(_key('home-task-k3')).top,
        tester.getRect(_key('home-task-k5')).top,
      ];
      expect(tops, [...tops]..sort());
      await tester.tap(_key('home-task-k5'));
      expect(c.log, ['task:k5']);
    });

    testWidgets('no tasks; loading; a read that failed; offline', (
      tester,
    ) async {
      for (final size in HomeWidgetSize.values) {
        final c = await pumpHomeTile(
          tester,
          kind: HomeWidgetKind.tasks,
          size: size,
          data: homeData(),
        );
        expect(find.text('Sin tareas'), findsOneWidget, reason: '$size');
        await tester.tap(find.text('Sin tareas'));
        expect(c.log, ['task:all']);
        await pumpHomeTile(
          tester,
          kind: HomeWidgetKind.tasks,
          size: size,
          data: homeData(tasks: null),
        );
        expect(_key('home-widget-skeleton'), findsOneWidget, reason: '$size');
        final failed = await pumpHomeTile(
          tester,
          kind: HomeWidgetKind.tasks,
          size: size,
          data: homeData(tasks: null, tasksFailed: true),
        );
        expect(find.text('No se pudo leer'), findsOneWidget, reason: '$size');
        await tester.tap(_key('home-widget-retry'));
        expect(failed.log, ['retry']);
        await pumpHomeTile(
          tester,
          kind: HomeWidgetKind.tasks,
          size: size,
          data: homeData(tasks: null, tasksFailed: true, online: false),
        );
        expect(find.text('Sin conexión'), findsOneWidget, reason: '$size');
        expect(tester.takeException(), isNull);
      }
    });
  });

  group('a widget fills its cell and never grows it', () {
    final full = homeData(
      chats: homeChats(),
      bots: homeBots(astraWaits: true),
      rooms: homeRooms(),
      questions: [homeQuestionItem()],
      approvals: [homeApproval()],
      automations: homeJobs(),
      tasks: homeTasksBoard(),
    );
    const kinds = [
      HomeWidgetKind.now,
      HomeWidgetKind.continueChats,
      HomeWidgetKind.team,
      HomeWidgetKind.room,
      HomeWidgetKind.cron,
      HomeWidgetKind.tasks,
    ];

    for (final scale in [1.0, 1.3, 2.0]) {
      testWidgets('text at ${scale}x: no overflow at any size, down to the '
          'shortest row and the narrowest phone', (tester) async {
        for (final kind in kinds) {
          for (final size in HomeWidgetSize.values) {
            // 104: the rows under a notice; 140: the shortest of an open
            // board.
            for (final row in [104.0, 140.0, 165.0]) {
              // 320 dp wide: cells of 137.5 and 286.
              for (final narrow in [false, true]) {
                final cell = homeCell(size, row: row);
                await pumpHomeTile(
                  tester,
                  kind: kind,
                  size: size,
                  data: full,
                  textScale: scale,
                  cell: narrow
                      ? Size(size == _small ? 137.5 : 286, cell.height)
                      : cell,
                );
                expect(
                  tester.takeException(),
                  isNull,
                  reason: '$kind $size row $row narrow $narrow',
                );
              }
            }
          }
        }
      });
    }

    testWidgets('a taller cell shows more rows of the same list, a shorter '
        'one fewer, never a cut one', (tester) async {
      final many = homeData(
        chats: [for (var i = 0; i < 12; i++) homeChat('c$i', 'Chat $i')],
      );
      Future<int> rows(double height, {double scale = 1}) async {
        await pumpHomeTile(
          tester,
          kind: HomeWidgetKind.continueChats,
          size: _large,
          data: many,
          cell: Size(356, height),
          textScale: scale,
        );
        final tile = tester.getRect(find.byType(Scaffold));
        final shown = _keys('home-continue-');
        for (final element in shown.evaluate()) {
          final rect = tester.getRect(find.byWidget(element.widget));
          expect(rect.bottom, lessThanOrEqualTo(17 + height - 12));
          expect(rect.top, greaterThanOrEqualTo(tile.top));
        }
        return shown.evaluate().length;
      }

      expect(await rows(315), 5);
      expect(await rows(341), 5);
      expect(await rows(400), 6);
      expect(await rows(165), 2);
      // Bigger text, fewer rows in the same cell.
      expect(await rows(341, scale: 2), lessThan(5));
      expect(await rows(341, scale: 2), greaterThan(0));
    });

    testWidgets('a row shorter than designed tightens its lists: the wide '
        'widgets show what they show at 152', (tester) async {
      final running = homeData(
        chats: [
          homeChat('t1', homeT1, working: true),
          homeChat('t2', homeT2, working: true),
          homeChat('t3', homeT3, working: true),
        ],
        automations: homeJobs(),
        tasks: homeTasksBoard(),
      );
      for (final (kind, prefix, count) in const [
        (HomeWidgetKind.now, 'home-now-run-', 1),
        (HomeWidgetKind.continueChats, 'home-continue-', 1),
        (HomeWidgetKind.cron, 'home-run-', 2),
        (HomeWidgetKind.tasks, 'home-task-', 2),
      ]) {
        for (final row in [140.0, 146.0, 152.0, 165.0]) {
          await pumpHomeTile(
            tester,
            kind: kind,
            size: _wide,
            data: running,
            cell: homeCell(_wide, row: row),
          );
          expect(
            _keys(prefix),
            findsNWidgets(row < 146 && count == 2 ? 1 : count),
            reason: '$kind at $row',
          );
          expect(tester.takeException(), isNull);
        }
      }
    });

    testWidgets('at 2x the small widgets keep what matters most', (
      tester,
    ) async {
      await pumpHomeTile(
        tester,
        kind: HomeWidgetKind.now,
        size: _small,
        data: full,
        textScale: 2,
      );
      // Who asks and the way to answer; the second line gives way.
      expect(find.text('Forja'), findsOneWidget);
      expect(find.text('Ver'), findsOneWidget);
      await pumpHomeTile(
        tester,
        kind: HomeWidgetKind.cron,
        size: _small,
        data: full,
        textScale: 2,
      );
      expect(find.text('03:00'), findsOneWidget);
      expect(find.text('Copia de seguridad'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('a notice above the board tightens its rows', () {
    // A phone's page under its header: 693 dp for the grid, four rows.
    Future<HomeBoardGeometry> pumpBoard(
      WidgetTester tester, {
      double notice = 0,
      double textScale = 1,
    }) async {
      tester.view.physicalSize = const Size(390, 788) * 3;
      tester.view.devicePixelRatio = 3;
      tester.platformDispatcher.textScaleFactorTestValue = textScale;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final key = GlobalKey<HomeBoardViewState>();
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          locale: const Locale('es'),
          theme: AppTheme.fromId('amber'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          home: Scaffold(
            body: HomeBoardView(
              key: key,
              layout: HomeBoardLayout.defaults(team: true),
              data: homeData(
                chats: homeChats(),
                bots: homeBots(astraWaits: true),
                rooms: homeRooms(),
                approvals: [homeApproval()],
                automations: homeJobs(),
              ),
              actions: HomeCalls().actions,
              onChanged: (_) {},
              newId: () => 'new',
              clock: () => homeFixtureNow,
              bottomPadding: 82,
              leading: [
                if (notice > 0)
                  SizedBox(key: const ValueKey('notice'), height: notice),
              ],
            ),
          ),
        ),
      );
      // The widgets glide to their rows.
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      return key.currentState!.geometry!;
    }

    void expectBetween(WidgetTester tester, HomeBoardGeometry geometry) {
      final top = find.byKey(const ValueKey('notice')).evaluate().isEmpty
          ? 0.0
          : tester.getRect(find.byKey(const ValueKey('notice'))).bottom;
      for (final item in geometry.plan.placed) {
        final rect = tester.getRect(
          _key('home-tile-${item.kind.name}-${item.id}'),
        );
        expect(rect.top, greaterThanOrEqualTo(top), reason: item.id);
        expect(rect.bottom, lessThanOrEqualTo(788 - 82), reason: item.id);
      }
    }

    testWidgets('no notice: four rows of 165', (tester) async {
      final geometry = await pumpBoard(tester);
      expect(geometry.plan.rows, 4);
      expect(geometry.rowHeight, closeTo(165, 0.01));
      expect(geometry.plan.hidden, isEmpty);
      expectBetween(tester, geometry);
    });

    testWidgets('a notice the size of «sin conexión»: the four rows stay, '
        'shorter, with every widget', (tester) async {
      final geometry = await pumpBoard(tester, notice: 124);
      expect(geometry.plan.rows, 4);
      expect(geometry.rowHeight, closeTo(132.5, 0.01));
      expect(geometry.plan.hidden, isEmpty);
      expect(geometry.plan.shrunk, isFalse);
      expectBetween(tester, geometry);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a tall notice: the rows go down to the least a row is, at '
        'any text size', (tester) async {
      for (final scale in [1.0, 2.0]) {
        final geometry = await pumpBoard(tester, notice: 230, textScale: scale);
        expect(geometry.plan.rows, 4, reason: '$scale');
        expect(geometry.rowHeight, closeTo(106, 0.01), reason: '$scale');
        expect(
          geometry.rowHeight,
          greaterThanOrEqualTo(HomeBoardGridRule.tightRowHeight),
        );
        expect(geometry.plan.hidden, isEmpty, reason: '$scale');
        expectBetween(tester, geometry);
        expect(tester.takeException(), isNull, reason: '$scale');
      }
    });

    testWidgets('a notice too tall for that takes the last row: its widgets '
        'wait, the rest have room again', (tester) async {
      final geometry = await pumpBoard(tester, notice: 260);
      expect(geometry.plan.rows, 3);
      expect(geometry.rowHeight, closeTo(135, 0.01));
      expect(geometry.plan.placed.map((i) => i.id), [
        'default-now',
        'default-bots',
      ]);
      expect(geometry.plan.hidden.map((i) => i.id), [
        'default-rooms',
        'default-cron',
      ]);
      expectBetween(tester, geometry);
      expect(tester.takeException(), isNull);
    });
  });

  group('«Ahora» from what Home knows', () {
    test('needs you first: approvals, questions, a bot that waits, a paused '
        'queue, failures; then what runs; then what finished', () {
      final now = HomeNow.derive(
        approvals: [homeApproval()],
        questions: [homeQuestionItem(sessionKey: 't2')],
        chats: [
          homeChat('t1', homeT1, working: true),
          homeChat('t2', homeT2, asks: true),
          homeChat('t3', homeT3, ago: const Duration(minutes: 5)),
          HomeChatItem(
            key: 'q',
            title: 'Cola',
            preview: '',
            at: homeFixtureNow,
            ref: 'q',
            queuedPaused: 2,
          ),
          homeChat('f', 'Migración', failed: true, unread: true),
          homeChat('d', 'Carta', draft: true),
        ],
        bots: [
          homeBot('Radar', state: HomeBotState.waiting),
          homeBot('Fable', state: HomeBotState.working),
          homeBot('Astra', state: HomeBotState.waiting),
        ],
        rooms: const [],
      );
      expect(now.asks.map((a) => (a.kind, a.key)), [
        (HomeNowAskKind.approval, 'approval:a1'),
        (HomeNowAskKind.question, 'question:q1'),
        // Astra asks through the question above: listed once.
        (HomeNowAskKind.waiting, 'waiting:radar'),
        (HomeNowAskKind.pausedQueue, 'queue:q'),
        (HomeNowAskKind.failed, 'failed-chat:f'),
      ]);
      expect(now.running.map((r) => r.key), ['chat:t1', 'bot:fable']);
      // Finished: not what works, asks, failed or is an unsent draft.
      expect(now.recent.map((d) => d.key), ['done:q', 'done:t3']);
      expect(now.calm, isFalse);
    });

    test('a bot replying in a room is that room\'s row; one whose chat is '
        'listed is that chat\'s row', () {
      final data = homeData(
        chats: [homeChat('c', 'Bot chat', working: true, agent: 'Fable')],
        bots: [
          homeBot('Forja', state: HomeBotState.working),
          homeBot('Fable', state: HomeBotState.working),
          homeBot('Radar', state: HomeBotState.working),
        ],
        rooms: homeRooms(),
      );
      expect(data.nowBoard.running.map((r) => r.key), [
        'room:devs',
        'chat:c',
        'bot:radar',
      ]);
      // The bot is seated in the room it replies in, with the room's clock.
      final forja = data.bot('forja')!;
      expect(forja.room, 'Console Devs');
      expect(forja.since, homeAgoAt(const Duration(minutes: 2, seconds: 14)));
    });

    test('calm keeps the four newest that finished; a bot\'s last work '
        'counts when its chat is not listed', () {
      final data = homeData(
        chats: [
          for (var i = 0; i < 5; i++)
            homeChat('c$i', 'Chat $i', ago: Duration(minutes: 10 + i)),
        ],
        bots: [
          homeBot(
            'Radar',
            lastTitle: 'Revisar disco',
            lastAt: homeAgoAt(const Duration(minutes: 4)),
          ),
        ],
      );
      expect(data.nowBoard.calm, isTrue);
      expect(data.nowBoard.recent.map((d) => d.key), [
        'done-bot:radar',
        'done:c0',
        'done:c1',
        'done:c2',
      ]);
    });
  });

  group('order of the lists', () {
    test('Salas: someone replying, then replies for you, then unread, then '
        'the newest; chosen rooms keep the user\'s order', () {
      final rooms = [
        homeRoom('old', 'Vieja', lastAt: homeAgoAt(const Duration(days: 2))),
        homeRoom('unread', 'Con nuevos', unread: 2),
        homeRoom('mine', 'Para ti', unread: 1, mentions: 1),
        homeRoom('live', 'Viva', replying: 'Forja'),
        homeRoom(
          'new',
          'Reciente',
          lastAt: homeAgoAt(const Duration(hours: 1)),
        ),
      ];
      final data = homeData(rooms: rooms);
      const auto = HomeWidgetInstance(
        id: 'r',
        kind: HomeWidgetKind.room,
        size: HomeWidgetSize.large,
      );
      expect(data.roomsFor(auto).map((r) => r.key), [
        'live',
        'mine',
        'unread',
        'new',
        'old',
      ]);
      expect(
        data
            .roomsFor(auto.withRooms(['old', 'gone', 'live']))
            .map((r) => r.key),
        ['old', 'live'],
      );
    });

    test('Cron: a fixed job, then by next run, then those without one, '
        'paused last', () {
      final ordered = HomeBoardData.cronOrder(
        [
          ...homeJobs(),
          homeJob('late', 'Sin hora'),
          homeJob('past', 'Pasada', next: homeAgoAt(const Duration(hours: 1))),
        ],
        homeFixtureNow,
        jobKey: 'hr',
      );
      expect(ordered.map((j) => j.key), [
        'hr',
        'backup',
        'disk',
        'daily',
        'late',
        'past',
        'social',
      ]);
    });
  });
}
