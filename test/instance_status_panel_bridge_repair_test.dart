import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/bridge_client.dart';
import 'package:hermes_android/core/services/bridge_manager.dart';
import 'package:hermes_android/core/services/bridge_update_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/widgets/instance_status_panel.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

void main() {
  testWidgets(
    'remote repair is single-flight, staged and verified at 360x800',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final updateGate = Completer<BridgeUpdateResult>();
      final manager = _FakeManager([
        _state(BridgeStatus.unreachable),
        _state(BridgeStatus.connected),
      ]);
      var updates = 0;
      await tester.pumpWidget(
        _app(
          InstanceStatusPanel(
            connection: _remote(),
            bridgeManager: manager,
            reachable: (_) async => true,
            updater: (_, {onProgress}) {
              updates++;
              return updateGate.future;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      final repair = find.text('Repair bridge');
      expect(repair, findsOneWidget);
      await tester.tap(repair);
      await tester.tap(repair);
      await tester.pump();
      expect(updates, 1);
      expect(find.text('Contacting bridge…'), findsOneWidget);
      await tester.pump();
      expect(find.text('Installing and restarting…'), findsOneWidget);

      updateGate.complete(const BridgeUpdateResult.success('accepted'));
      await tester.pumpAndSettle();
      expect(find.text('Bridge repaired and verified.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('unsupported repair shows retry and safe manual route', (
    tester,
  ) async {
    final manager = _FakeManager([_state(BridgeStatus.unreachable)]);
    await tester.pumpWidget(
      _app(
        InstanceStatusPanel(
          connection: _remote(),
          bridgeManager: manager,
          reachable: (_) async => true,
          updater: (_, {onProgress}) async => const BridgeUpdateResult.failure(
            BridgeUpdateFailure.repairUnsupported,
            'unsafe backend detail',
            manualAction: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Repair bridge'));
    await tester.pumpAndSettle();

    expect(
      find.text('Remote repair is not supported by this Gateway.'),
      findsOneWidget,
    );
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Open safe setup'), findsOneWidget);
    expect(find.textContaining('unsafe backend'), findsNothing);
  });

  testWidgets('typed provision failures stay distinct and localized', (
    tester,
  ) async {
    final cases = <BridgeProvisionFailure, String>{
      BridgeProvisionFailure.authRejected: 'The Gateway API key was rejected.',
      BridgeProvisionFailure.provisionDisabled:
          'Token provisioning is disabled on this bridge.',
      BridgeProvisionFailure.timeout:
          'The bridge did not respond within the safe time limit.',
      BridgeProvisionFailure.secureStorage:
          'The new token could not be saved securely.',
    };
    for (final entry in cases.entries) {
      final manager = _FakeManager([
        _state(BridgeStatus.needsToken),
      ], provisionResult: BridgeProvisionResult.failure(entry.key));
      await tester.pumpWidget(
        _app(
          InstanceStatusPanel(
            key: ValueKey(entry.key),
            connection: _remote(),
            bridgeManager: manager,
            reachable: (_) async => true,
            updater: (_, {onProgress}) async =>
                const BridgeUpdateResult.success('unexpected'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Repair bridge'));
      await tester.pumpAndSettle();
      expect(find.text(entry.value), findsOneWidget, reason: entry.key.name);
    }
  });

  testWidgets('late completion after dispose cannot mutate replacement UI', (
    tester,
  ) async {
    final gate = Completer<BridgeUpdateResult>();
    final manager = _FakeManager([_state(BridgeStatus.unreachable)]);
    await tester.pumpWidget(
      _app(
        InstanceStatusPanel(
          connection: _remote(),
          bridgeManager: manager,
          reachable: (_) async => true,
          updater: (_, {onProgress}) => gate.future,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Repair bridge'));
    await tester.pump();
    await tester.pumpWidget(_app(const Text('replacement')));
    gate.complete(const BridgeUpdateResult.success('accepted'));
    await tester.pumpAndSettle();

    expect(find.text('replacement'), findsOneWidget);
    expect(find.text('Bridge repaired and verified.'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

Widget _app(Widget child) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: const [
    Strings.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: Strings.supportedLocales,
  home: MediaQuery(
    data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
    child: Scaffold(body: child),
  ),
);

SavedConnection _remote() => SavedConnection(
  id: 'remote',
  label: 'Remote',
  host: 'example.com',
  port: 443,
  useHttps: true,
  apiKey: 'key',
);

BridgeState _state(BridgeStatus status) => BridgeState(
  status: status,
  url: 'https://example.com',
  urlIsDerived: true,
  hasToken: status != BridgeStatus.needsToken,
  caps: status == BridgeStatus.connected
      ? const BridgeCapabilities(online: true, authValid: true)
      : BridgeCapabilities.offline,
);

class _FakeManager implements BridgeManagerContract {
  final List<BridgeState> states;
  final BridgeProvisionResult provisionResult;
  var probes = 0;
  _FakeManager(
    this.states, {
    this.provisionResult = const BridgeProvisionResult.success('token'),
  });

  @override
  Future<BridgeState> probe(String connectionId) async => states[probes++];

  @override
  Future<BridgeProvisionResult> provision(String connectionId) async =>
      provisionResult;

  @override
  Future<bool> tryProvision(String connectionId) async => true;

  @override
  Future<BridgeClient?> clientFor(String connectionId) async => null;
}
