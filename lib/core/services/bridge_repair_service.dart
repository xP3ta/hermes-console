import 'dart:async';

import 'bridge_client.dart';
import 'bridge_manager.dart';
import 'bridge_update_service.dart';
import 'connection_manager.dart';

enum BridgeRepairStage {
  contacting,
  reprovisioning,
  installing,
  restarting,
  verifying,
}

enum BridgeRepairFailure {
  timeout,
  unreachable,
  tls,
  authRejected,
  provisionDisabled,
  unexpectedHttp,
  invalidResponse,
  secureStorage,
  repairUnsupported,
  repairFailed,
  verificationFailed,
  readOnly,
  missingApiKey,
  localControlRequired,
}

class BridgeRepairResult {
  final bool success;
  final BridgeRepairFailure? category;
  final bool manualAction;
  final bool openLocalControl;

  const BridgeRepairResult.success()
    : success = true,
      category = null,
      manualAction = false,
      openLocalControl = false;

  const BridgeRepairResult.failure(
    this.category, {
    this.manualAction = false,
    this.openLocalControl = false,
  }) : success = false;
}

typedef BridgeRepairUpdater =
    Future<BridgeUpdateResult> Function(
      SavedConnection connection, {
      void Function(BridgeRepairStage stage)? onProgress,
    });

/// State-driven repair policy. It never provisions an endpoint already proven
/// unreachable; remote process repair goes through BridgeUpdateService instead.
class BridgeRepairService {
  final BridgeManagerContract manager;
  final BridgeRepairUpdater updater;
  final Duration provisionTimeout;
  final Duration updateTimeout;
  final Duration verificationTimeout;

  const BridgeRepairService({
    required this.manager,
    required this.updater,
    this.provisionTimeout = const Duration(seconds: 10),
    this.updateTimeout = const Duration(minutes: 3),
    this.verificationTimeout = const Duration(seconds: 12),
  });

  Future<BridgeRepairResult> repair(
    SavedConnection connection, {
    required BridgeState initial,
    void Function(BridgeRepairStage stage)? onStage,
  }) async {
    if (connection.readOnly) {
      return const BridgeRepairResult.failure(
        BridgeRepairFailure.readOnly,
        manualAction: true,
      );
    }

    final local = connection.kind == InstanceKind.localhost;
    if (initial.status == BridgeStatus.needsToken ||
        initial.status == BridgeStatus.authFailed) {
      if (!local && connection.apiKey.trim().isEmpty) {
        return const BridgeRepairResult.failure(
          BridgeRepairFailure.missingApiKey,
          manualAction: true,
        );
      }
      onStage?.call(BridgeRepairStage.reprovisioning);
      late final BridgeProvisionResult provisioned;
      try {
        provisioned = await manager
            .provision(connection.id)
            .timeout(provisionTimeout);
      } on TimeoutException {
        return const BridgeRepairResult.failure(BridgeRepairFailure.timeout);
      } catch (_) {
        return const BridgeRepairResult.failure(
          BridgeRepairFailure.invalidResponse,
          manualAction: true,
        );
      }
      if (!provisioned.ok) return _fromProvision(provisioned.failure);
      return _verify(connection.id, onStage);
    }

    if (local) {
      return const BridgeRepairResult.failure(
        BridgeRepairFailure.localControlRequired,
        manualAction: true,
        openLocalControl: true,
      );
    }
    if (connection.apiKey.trim().isEmpty) {
      return const BridgeRepairResult.failure(
        BridgeRepairFailure.missingApiKey,
        manualAction: true,
      );
    }

    onStage?.call(BridgeRepairStage.installing);
    late final BridgeUpdateResult updated;
    try {
      updated = await updater(
        connection,
        onProgress: (stage) => onStage?.call(stage),
      ).timeout(updateTimeout);
    } on TimeoutException {
      return const BridgeRepairResult.failure(
        BridgeRepairFailure.timeout,
        manualAction: true,
      );
    } catch (_) {
      return const BridgeRepairResult.failure(
        BridgeRepairFailure.repairFailed,
        manualAction: true,
      );
    }
    if (!updated.ok) {
      return BridgeRepairResult.failure(
        updated.failure == BridgeUpdateFailure.repairUnsupported
            ? BridgeRepairFailure.repairUnsupported
            : BridgeRepairFailure.repairFailed,
        manualAction: updated.manualAction,
      );
    }
    return _verify(connection.id, onStage);
  }

  Future<BridgeRepairResult> _verify(
    String connectionId,
    void Function(BridgeRepairStage stage)? onStage,
  ) async {
    onStage?.call(BridgeRepairStage.verifying);
    late final BridgeState state;
    try {
      state = await manager.probe(connectionId).timeout(verificationTimeout);
    } on TimeoutException {
      return const BridgeRepairResult.failure(BridgeRepairFailure.timeout);
    } catch (_) {
      return const BridgeRepairResult.failure(
        BridgeRepairFailure.verificationFailed,
        manualAction: true,
      );
    }
    if (state.status == BridgeStatus.connected &&
        state.connected &&
        state.caps.online &&
        state.caps.authValid) {
      return const BridgeRepairResult.success();
    }
    return const BridgeRepairResult.failure(
      BridgeRepairFailure.verificationFailed,
      manualAction: true,
    );
  }

  static BridgeRepairResult _fromProvision(BridgeProvisionFailure failure) {
    final mapped = switch (failure) {
      BridgeProvisionFailure.timeout => BridgeRepairFailure.timeout,
      BridgeProvisionFailure.unreachable => BridgeRepairFailure.unreachable,
      BridgeProvisionFailure.tls => BridgeRepairFailure.tls,
      BridgeProvisionFailure.authRejected => BridgeRepairFailure.authRejected,
      BridgeProvisionFailure.provisionDisabled =>
        BridgeRepairFailure.provisionDisabled,
      BridgeProvisionFailure.unexpectedHttp =>
        BridgeRepairFailure.unexpectedHttp,
      BridgeProvisionFailure.invalidResponse ||
      BridgeProvisionFailure.invalidUrl ||
      BridgeProvisionFailure.unexpectedResponse =>
        BridgeRepairFailure.invalidResponse,
      BridgeProvisionFailure.secureStorage => BridgeRepairFailure.secureStorage,
      BridgeProvisionFailure.missingApiKey => BridgeRepairFailure.missingApiKey,
      BridgeProvisionFailure.none => BridgeRepairFailure.invalidResponse,
    };
    return BridgeRepairResult.failure(mapped, manualAction: true);
  }
}
