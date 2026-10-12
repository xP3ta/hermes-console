import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/home/board/home_board_model.dart';
import 'package:hermes_android/core/home/board/home_board_tiles.dart';
import 'package:hermes_android/core/home/home_now.dart';
import 'package:hermes_android/core/home/home_sources.dart';
import 'package:hermes_android/core/models/session_live_status.dart';
import 'package:hermes_android/l10n/app_localizations_es.dart';

import '../support/home_board_fixtures.dart';

void main() {
  testWidgets(
    'the running tool uses the chat phrase and a centred full title',
    (tester) async {
      const title = 'Acceder a VM de Windows en Proxmox';
      final step = homeStepLabel(
        StringsEs(),
        const SessionLiveStatus(
          phase: SessionLivePhase.runningTool,
          toolLabel: 'execute_code',
        ),
      );
      await pumpHomeTile(
        tester,
        kind: HomeWidgetKind.now,
        size: HomeWidgetSize.wide,
        data: homeData(
          chats: [homeChat('running', title, working: true, step: step)],
        ),
      );
      expect(find.text('execute_code'), findsNothing);
      expect(find.text('Ejecutando código'), findsOneWidget);
      final titleWidget = tester.widget<Text>(find.text(title));
      expect(titleWidget.maxLines, 2);
      final titleRect = tester.getRect(find.text(title));
      final header = tester.getRect(find.text('Ahora'));
      expect(titleRect.top - header.bottom, greaterThan(16));
      expect(find.text('Hermes'), findsOneWidget);
      expect(find.text(' · 0:41'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('an unknown turn start has no clock in any chat tile', (
    tester,
  ) async {
    final data = homeData(
      chats: [
        HomeChatItem(
          key: 'unknown',
          title: 'Turno en otro dispositivo',
          preview: '',
          at: homeFixtureNow.subtract(const Duration(hours: 2)),
          ref: 'unknown',
          working: true,
        ),
      ],
    );
    for (final kind in [
      HomeWidgetKind.now,
      HomeWidgetKind.continueChats,
      HomeWidgetKind.chat,
    ]) {
      for (final size in HomeWidgetSize.values) {
        await pumpHomeTile(
          tester,
          kind: kind,
          size: size,
          data: data,
          options: const {'chat': 'unknown'},
        );
        expect(find.byType(HomeElapsed), findsNothing, reason: '$kind $size');
      }
    }
  });

  testWidgets(
    'failed reads replace yesterday\'s Cron and Tasks at every size',
    (tester) async {
      for (final size in HomeWidgetSize.values) {
        for (final kind in [HomeWidgetKind.cron, HomeWidgetKind.tasks]) {
          await pumpHomeTile(
            tester,
            kind: kind,
            size: size,
            data: homeData(
              automations: homeJobs(),
              automationsFailed: true,
              tasks: homeTasksBoard(),
              tasksFailed: true,
            ),
          );
          expect(
            find.text('No se pudo leer'),
            findsOneWidget,
            reason: '$kind $size',
          );
          expect(find.text('Publicar 1.2.15'), findsNothing);
          expect(find.text('Resumen diario'), findsNothing);
        }
      }
    },
  );

  testWidgets('elapsed information ticks even with reduced motion', (
    tester,
  ) async {
    var clock = homeFixtureNow;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: HomeElapsed(
            since: clock.subtract(const Duration(minutes: 59, seconds: 59)),
            clock: () => clock,
          ),
        ),
      ),
    );
    expect(find.text('59:59'), findsOneWidget);
    clock = clock.add(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('1:00:00'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
