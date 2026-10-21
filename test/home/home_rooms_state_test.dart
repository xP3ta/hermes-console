import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/home/board/home_board_data.dart';
import 'package:hermes_android/core/home/board/home_board_model.dart';
import 'package:hermes_android/core/models/mission_control.dart';

import '../support/home_board_fixtures.dart';

MissionBackendSnapshot _snap(MissionCapabilityState rooms, {int second = 0}) =>
    MissionBackendSnapshot(
      hostedGroupsCapability: rooms,
      loadedAt: DateTime(2026, 10, 11, 22, 4, second),
    );

void main() {
  Finder skeleton() => find.byKey(const ValueKey('home-widget-skeleton'));
  Finder text(String t) => find.text(t);

  group('HomeRoomsReads', () {
    test('no snapshot: unknown; only an available read is known', () {
      final reads = HomeRoomsReads();
      expect(reads.observe('c', null), HomeRoomsState.unknown);
      expect(
        reads.observe('c', _snap(MissionCapabilityState.available)),
        HomeRoomsState.known,
      );
      expect(
        reads.observe(
          'c',
          _snap(MissionCapabilityState.unsupported, second: 1),
        ),
        HomeRoomsState.unsupported,
      );
      expect(
        reads.observe(
          'c',
          _snap(MissionCapabilityState.unavailable, second: 2),
        ),
        HomeRoomsState.unavailable,
      );
    });

    test(
      'counts one failure per snapshot, not per repaint; success resets',
      () {
        final reads = HomeRoomsReads();
        final failed = _snap(MissionCapabilityState.unavailable);
        reads.observe('c', failed);
        reads.observe('c', failed);
        reads.observe('c', failed);
        expect(reads.failedReads, 1);
        reads.observe(
          'c',
          _snap(MissionCapabilityState.unavailable, second: 5),
        );
        expect(reads.failedReads, 2);
        reads.observe('c', _snap(MissionCapabilityState.available, second: 9));
        expect(reads.failedReads, 0);
      },
    );

    test('another connection starts from zero', () {
      final reads = HomeRoomsReads();
      reads.observe('a', _snap(MissionCapabilityState.unavailable));
      reads.observe('b', null);
      expect(reads.failedReads, 0);
    });
  });

  group('Salas tile by rooms state', () {
    Future<void> pump(
      WidgetTester tester,
      HomeBoardData data, {
      HomeWidgetSize size = HomeWidgetSize.wide,
      Map<String, Object?> options = const {},
    }) => pumpHomeTile(
      tester,
      kind: HomeWidgetKind.room,
      size: size,
      data: data,
      options: options,
    );

    testWidgets('known and empty: «no rooms»; known with rooms: the rows', (
      tester,
    ) async {
      await pump(tester, homeData());
      expect(text('Aún no hay salas'), findsOneWidget);
      await pump(tester, homeData(rooms: homeRooms()));
      expect(text('Aún no hay salas'), findsNothing);
      expect(text('Console Devs'), findsOneWidget);
    });

    testWidgets('unavailable with nothing cached: skeleton, never «no rooms»', (
      tester,
    ) async {
      for (final size in HomeWidgetSize.values) {
        await pump(
          tester,
          homeData(roomsState: HomeRoomsState.unavailable, roomsFailedReads: 1),
          size: size,
        );
        expect(text('Aún no hay salas'), findsNothing, reason: '$size');
        expect(skeleton(), findsOneWidget, reason: '$size');
      }
    });

    testWidgets(
      'unavailable on the second failed read: could not load + retry',
      (tester) async {
        await pump(
          tester,
          homeData(roomsState: HomeRoomsState.unavailable, roomsFailedReads: 2),
        );
        expect(text('Aún no hay salas'), findsNothing);
        expect(text('No se pudo leer'), findsOneWidget);
        expect(find.byKey(const ValueKey('home-widget-retry')), findsOneWidget);
      },
    );

    testWidgets('unavailable but rooms cached: the cached rooms', (
      tester,
    ) async {
      await pump(
        tester,
        homeData(
          rooms: homeRooms(),
          roomsState: HomeRoomsState.unavailable,
          roomsFailedReads: 3,
        ),
      );
      expect(text('Console Devs'), findsOneWidget);
      expect(text('No se pudo leer'), findsNothing);
    });

    testWidgets('unavailable with chosen rooms: not «gone»', (tester) async {
      await pump(
        tester,
        homeData(roomsState: HomeRoomsState.unavailable, roomsFailedReads: 1),
        options: const {
          'rooms': ['gone'],
        },
      );
      expect(find.byKey(const ValueKey('home-widget-missing')), findsNothing);
      expect(skeleton(), findsOneWidget);
    });

    testWidgets('unsupported: the quiet «no rooms» line', (tester) async {
      await pump(tester, homeData(roomsState: HomeRoomsState.unsupported));
      expect(text('Aún no hay salas'), findsOneWidget);
      expect(skeleton(), findsNothing);
    });

    testWidgets('unknown and offline: offline line', (tester) async {
      await pump(
        tester,
        homeData(roomsState: HomeRoomsState.unknown, online: false),
      );
      expect(text('Sin conexión'), findsOneWidget);
      expect(text('Aún no hay salas'), findsNothing);
    });
  });
}
