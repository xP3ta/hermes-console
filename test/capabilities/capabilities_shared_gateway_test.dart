// The capabilities hub borrows the connection's shared gateway instead of
// opening its own WebSocket per visit, and gives it back when it closes.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/capabilities/capabilities_screen.dart';
import 'package:hermes_android/core/models/connection.dart';
import 'package:hermes_android/core/services/shared_gateway_pool.dart';

import '../support/inter_font.dart';
import 'capabilities_fakes.dart';

SavedConnection _connection({bool readOnly = false}) => SavedConnection(
  id: 'cph-shared-gateway',
  label: 'Synthetic hub',
  host: '127.0.0.1',
  port: 9,
  apiKey: 'synth...ub',
  kind: InstanceKind.vps,
  readOnly: readOnly,
);

void main() {
  setUpAll(loadInterFont);

  // Suites pin the idle linger to zero; these tests need the real reuse
  // window and close it themselves before the tree is torn down.
  setUp(
    () => SharedGatewayPool.debugDefaultLinger = const Duration(minutes: 5),
  );
  tearDown(() {
    SharedGatewayPool.instance.disconnectIdle();
    SharedGatewayPool.debugDefaultLinger = Duration.zero;
  });

  Future<void> open(WidgetTester tester, SavedConnection connection) async {
    await setPhone(tester);
    await tester.pumpWidget(
      spanishApp(CapabilitiesHub(connection: connection)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }

  testWidgets('reopening the hub reuses the shared gateway', (tester) async {
    final pool = SharedGatewayPool.instance;
    final leasesBefore = pool.leaseCount;
    final socketsBefore = pool.liveClientCount;

    await open(tester, _connection());
    expect(pool.leaseCount, leasesBefore + 1);
    expect(pool.liveClientCount, socketsBefore + 1);

    await close(tester);
    expect(pool.leaseCount, leasesBefore);
    // Lingering for the next visit, not torn down per screen.
    expect(pool.liveClientCount, socketsBefore + 1);

    await open(tester, _connection());
    expect(pool.liveClientCount, socketsBefore + 1);
    await close(tester);
    expect(pool.leaseCount, leasesBefore);
    pool.disconnectIdle();
  });

  testWidgets('a read-only connection never shares a writable socket', (
    tester,
  ) async {
    final pool = SharedGatewayPool.instance;
    final socketsBefore = pool.liveClientCount;
    await open(tester, _connection());
    await close(tester);
    await open(tester, _connection(readOnly: true));
    expect(pool.liveClientCount, socketsBefore + 2);
    await close(tester);
    pool.disconnectIdle();
  });

  testWidgets('a profile change rebuilds the hub for the new owner', (
    tester,
  ) async {
    Future<void> show(String profile, {bool readOnly = false}) async {
      await setPhone(tester);
      await tester.pumpWidget(
        spanishApp(
          CapabilitiesHub(
            connection: _connection(readOnly: readOnly),
            profile: profile,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }

    CapabilitiesScreen screen() =>
        tester.widget<CapabilitiesScreen>(find.byType(CapabilitiesScreen));

    await show('ana');
    final first = screen().repository;
    expect(first.profile, 'ana');
    await show('bob');
    expect(screen().repository.profile, 'bob');
    expect(identical(screen().repository, first), isFalse);
    expect(screen().destinationLabel, endsWith('bob'));
    await show('bob', readOnly: true);
    expect(screen().readOnly, isTrue);
    expect(screen().repository.profile, 'bob');
    await close(tester);
    expect(SharedGatewayPool.instance.leaseCount, 0);
    SharedGatewayPool.instance.disconnectIdle();
  });
}
