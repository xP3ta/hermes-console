import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/home/board/home_board_data.dart';
import 'package:hermes_android/core/home/board/home_board_model.dart';

import '../support/home_board_fixtures.dart';

// «Aún no hay salas» is a fact only after a rooms answer. A live roster
// (botsLoaded) says nothing about it, so these must hold on any data that
// never received that answer.
void main() {
  Finder skeleton() => find.byKey(const ValueKey('home-widget-skeleton'));

  testWidgets('roster loaded but rooms never read: skeleton, not «no rooms»', (
    tester,
  ) async {
    for (final size in HomeWidgetSize.values) {
      await pumpHomeTile(
        tester,
        kind: HomeWidgetKind.room,
        size: size,
        data: HomeBoardData(
          now: homeFixtureNow,
          botsLoaded: true,
          server: const HomeBoardServer(label: 'Hermes', online: true),
        ),
      );
      expect(find.text('Aún no hay salas'), findsNothing, reason: '$size');
      expect(skeleton(), findsOneWidget, reason: '$size');
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('roster loaded, rooms never read, server offline: offline line', (
    tester,
  ) async {
    await pumpHomeTile(
      tester,
      kind: HomeWidgetKind.room,
      size: HomeWidgetSize.wide,
      data: HomeBoardData(
        now: homeFixtureNow,
        botsLoaded: true,
        server: const HomeBoardServer(label: 'Hermes', online: false),
      ),
    );
    expect(find.text('Aún no hay salas'), findsNothing);
    expect(find.text('Sin conexión'), findsOneWidget);
  });
}
