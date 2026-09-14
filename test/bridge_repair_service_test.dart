import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/bridge_client.dart';
import 'package:hermes_android/core/services/bridge_manager.dart';
import 'package:hermes_android/core/services/bridge_repair_service.dart';
import 'package:hermes_android/core/services/bridge_update_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';

void main() {
  const connectedCaps = BridgeCapabilities(online: true, authValid: true);

  test('reachable needsToken provisions then probes; never installs', () async {
    final manager = _FakeManager(
      probes: [
        _state(BridgeStatus.needsToken),
        _state(BridgeStatus.connected, caps: connectedCaps),
      ],
      provisionResult: const BridgeProvisionResult.success('fresh-token'),
    );
    var updates = 0;
    final stages = <BridgeRepairStage>[];
    final service = BridgeRepairService(
      manager: manager,
      updater: (_, {onProgress}) async {
        updates++;
        return const BridgeUpdateResult.success('unexpected');
      },
    );

    final initial = await manager.probe('remote');
    final result = await service.repair(
      _remote(),
      initial: initial,
      onStage: stages.add,
    );

    expect(result.success, isTrue);
    expect(manager.provisionCalls, 1);
    expect(manager.probeCalls, 2);
    expect(updates, 0);
    expect(stages, [
      BridgeRepairStage.reprovisioning,
      BridgeRepairStage.verifying,
    ]);
  });

  test(
    'unreachable installs then verifies without provisioning dead bridge',
    () async {
      final manager = _FakeManager(
        probes: [
          _state(BridgeStatus.unreachable),
          _state(BridgeStatus.connected, caps: connectedCaps),
        ],
      );
      var updates = 0;
      final service = BridgeRepairService(
        manager: manager,
        updater: (_, {onProgress}) async {
          updates++;
          onProgress?.call(BridgeRepairStage.installing);
          return const BridgeUpdateResult.success('accepted');
        },
      );

      final result = await service.repair(
        _remote(),
        initial: await manager.probe('remote'),
      );

      expect(result.success, isTrue);
      expect(updates, 1);
      expect(manager.provisionCalls, 0);
      expect(manager.probeCalls, 2);
    },
  );

  test('installer accepted but auth verification fails is failure', () async {
    final manager = _FakeManager(
      probes: [
        _state(BridgeStatus.unreachable),
        _state(BridgeStatus.authFailed),
      ],
    );
    final service = BridgeRepairService(
      manager: manager,
      updater: (_, {onProgress}) async =>
          const BridgeUpdateResult.success('accepted'),
    );

    final result = await service.repair(
      _remote(),
      initial: await manager.probe('remote'),
    );

    expect(result.success, isFalse);
    expect(result.category, BridgeRepairFailure.verificationFailed);
    expect(result.manualAction, isTrue);
  });

  test(
    'unsupported installer remains actionable and never reports success',
    () async {
      final manager = _FakeManager(probes: [_state(BridgeStatus.unreachable)]);
      final service = BridgeRepairService(
        manager: manager,
        updater: (_, {onProgress}) async => const BridgeUpdateResult.failure(
          BridgeUpdateFailure.repairUnsupported,
          'unsupported',
          manualAction: true,
        ),
      );

      final result = await service.repair(
        _remote(),
        initial: await manager.probe('remote'),
      );

      expect(result.success, isFalse);
      expect(result.category, BridgeRepairFailure.repairUnsupported);
      expect(result.manualAction, isTrue);
      expect(manager.provisionCalls, 0);
    },
  );

  test('read-only and missing API key fail before any mutation', () async {
    for (final connection in [
      _remote().copyWith(readOnly: true),
      _remote().copyWith(apiKey: ''),
    ]) {
      final manager = _FakeManager(probes: [_state(BridgeStatus.unreachable)]);
      var updates = 0;
      final result = await BridgeRepairService(
        manager: manager,
        updater: (_, {onProgress}) async {
          updates++;
          return const BridgeUpdateResult.success('unexpected');
        },
      ).repair(connection, initial: await manager.probe('remote'));
      expect(result.success, isFalse);
      expect(result.manualAction, isTrue);
      expect(updates, 0);
      expect(manager.provisionCalls, 0);
    }
  });

  test(
    'local unreachable requires local control and never remote installs',
    () async {
      final manager = _FakeManager(probes: [_state(BridgeStatus.unreachable)]);
      var updates = 0;
      final result = await BridgeRepairService(
        manager: manager,
        updater: (_, {onProgress}) async {
          updates++;
          return const BridgeUpdateResult.success('unexpected');
        },
      ).repair(_local(), initial: await manager.probe('local'));

      expect(result.category, BridgeRepairFailure.localControlRequired);
      expect(result.openLocalControl, isTrue);
      expect(updates, 0);
    },
  );

  test('stage timeout is typed and bounded', () async {
    final never = Completer<BridgeProvisionResult>();
    final manager = _FakeManager(
      probes: [_state(BridgeStatus.needsToken)],
      provisionFuture: never.future,
    );
    final service = BridgeRepairService(
      manager: manager,
      updater: (_, {onProgress}) async =>
          const BridgeUpdateResult.success('unexpected'),
      provisionTimeout: const Duration(milliseconds: 5),
    );

    final result = await service.repair(
      _remote(),
      initial: await manager.probe('remote'),
    );

    expect(result.category, BridgeRepairFailure.timeout);
  });
}

SavedConnection _remote() => SavedConnection(
  id: 'remote',
  label: 'Remote',
  host: 'example.com',
  port: 443,
  useHttps: true,
  apiKey: 'gateway-key',
);

SavedConnection _local() => SavedConnection(
  id: 'local',
  label: 'Local',
  host: '127.0.0.1',
  port: 8642,
  apiKey: '',
  kind: InstanceKind.localhost,
  onDeviceLoopback: true,
);

BridgeState _state(BridgeStatus status, {BridgeCapabilities? caps}) =>
    BridgeState(
      status: status,
      url: 'https://example.com/proxy',
      urlIsDerived: true,
      hasToken: status != BridgeStatus.needsToken,
      caps: caps ?? const BridgeCapabilities(online: true, authValid: false),
    );

class _FakeManager implements BridgeManagerContract {
  final List<BridgeState> probes;
  final BridgeProvisionResult provisionResult;
  final Future<BridgeProvisionResult>? provisionFuture;
  int probeCalls = 0;
  int provisionCalls = 0;

  _FakeManager({
    required this.probes,
    this.provisionResult = const BridgeProvisionResult.failure(
      BridgeProvisionFailure.unexpectedResponse,
    ),
    this.provisionFuture,
  });

  @override
  Future<BridgeState> probe(String connectionId) async => probes[probeCalls++];

  @override
  Future<BridgeProvisionResult> provision(String connectionId) {
    provisionCalls++;
    return provisionFuture ?? Future.value(provisionResult);
  }

  @override
  Future<bool> tryProvision(String connectionId) async =>
      (await provision(connectionId)).ok;

  @override
  Future<BridgeClient?> clientFor(String connectionId) async => null;
}
