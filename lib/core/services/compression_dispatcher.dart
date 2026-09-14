import 'dart:async';

import '../models/command_descriptor.dart';
import '../models/desktop_compression_outcome.dart';
import '../models/desktop_compression_result.dart';
import 'tui_gateway_client.dart';

/// Routes and classifies compression; command failure text is presentation only.
/// Legacy payload certainty remains quarantined until its typed contract exists.
final class CompressionDispatcher {
  final Object _gateway;
  HermesDesktopCommandGateway get _commands =>
      _gateway as HermesDesktopCommandGateway;

  static DesktopCompressionOutcome failureOutcome(Object error) {
    if (error is TuiGatewayRpcError &&
        error.origin == CompressionFailureOrigin.malformed) {
      return DesktopCompressionOutcome.ambiguous;
    }
    if (error is TuiGatewayRpcError &&
        error.origin == CompressionFailureOrigin.localPreflight) {
      return DesktopCompressionOutcome.notDispatched;
    }
    if (error is TuiGatewayRpcError &&
        (error.code == 4090 ||
            error.compressionReason ==
                CompressionFailureReason.sessionNotOwned)) {
      return DesktopCompressionOutcome.ownershipLost;
    }
    if (error is TuiGatewayRpcError && error.code == -32601) {
      return DesktopCompressionOutcome.routeUnavailable;
    }
    return DesktopCompressionOutcome.ambiguous;
  }

  static DesktopCompressionEvidence nativeEvidence(
    DesktopCompressionResult result,
  ) => DesktopCompressionEvidence(switch (result.outcome) {
    DesktopCompressionStatus.pending =>
      DesktopCompressionOutcome.acceptedPending,
    DesktopCompressionStatus.lockHeld => DesktopCompressionOutcome.lockHeld,
    DesktopCompressionStatus.compressed ||
    DesktopCompressionStatus.noOp ||
    DesktopCompressionStatus.aborted => DesktopCompressionOutcome.settled,
  }, nativeResult: result);

  static DesktopCompressionOutcome legacyOutcome(
    DesktopCommandRpcResult response,
  ) =>
      response.compressionEvidence == LegacyCompressionEvidence.terminalRejected
      ? DesktopCompressionOutcome.terminalRejected
      : response.compressionWireEvidence.outcome;

  const CompressionDispatcher(this._gateway);

  Future<
    ({
      DesktopCompressionEvidence evidence,
      DesktopCommandDispatch? command,
      Object? error,
    })
  >
  dispatch(
    String runtimeId, {
    required String focusTopic,
    required int connectionEpoch,
    required int sessionEpoch,
    required bool Function() stillValid,
    required bool Function(DesktopCompressionResult) matchesRoot,
  }) => TuiGatewayClient.withCompressionAuthorization(stillValid, () async {
    if (!stillValid()) {
      return (
        evidence: const DesktopCompressionEvidence(
          DesktopCompressionOutcome.notDispatched,
        ),
        command: null,
        error: StateError('Compression cancelled'),
      );
    }
    if (_gateway case final HermesDesktopCompressionGateway native) {
      try {
        final result = await native.compressSession(
          runtimeId,
          focusTopic: focusTopic,
        );
        if (!matchesRoot(result)) {
          throw const TuiGatewayRpcError(
            'session.compress',
            'Compression lineage mismatch',
            code: 4004,
            origin: CompressionFailureOrigin.malformed,
          );
        }
        return (evidence: nativeEvidence(result), command: null, error: null);
      } catch (error) {
        final outcome = failureOutcome(error);
        if (outcome != DesktopCompressionOutcome.routeUnavailable) {
          return (
            evidence: DesktopCompressionEvidence(outcome),
            command: null,
            error: error,
          );
        }
        if (!stillValid() || _gateway is! HermesDesktopCommandGateway) {
          return (
            evidence: const DesktopCompressionEvidence(
              DesktopCompressionOutcome.terminalRejected,
            ),
            command: null,
            error: const TuiGatewayRpcError(
              'session.compress',
              'Compression continuation cancelled',
              code: 4009,
            ),
          );
        }
      }
    }
    var outcome = DesktopCompressionOutcome.ambiguous;
    final command = await compress(
      runtimeId,
      focusTopic: focusTopic,
      connectionEpoch: connectionEpoch,
      sessionEpoch: sessionEpoch,
      fallbackStillValid: stillValid,
      onOutcome: (value) => outcome = value,
    );
    if (outcome == DesktopCompressionOutcome.routeUnavailable) {
      outcome = DesktopCompressionOutcome.terminalRejected;
    }
    return (
      evidence: DesktopCompressionEvidence(outcome),
      command: command,
      error: null,
    );
  });

  Future<DesktopCommandDispatch> compress(
    String runtimeSessionId, {
    String focusTopic = '',
    required int connectionEpoch,
    required int sessionEpoch,
    bool Function()? fallbackStillValid,
    void Function(DesktopCompressionOutcome)? onOutcome,
  }) async {
    final sessionId = _validateSessionId(runtimeSessionId);
    final argument = _validateArgument(focusTopic);
    if (connectionEpoch < 0 || sessionEpoch < 0) {
      throw const FormatException('invalid compression epoch');
    }
    final slashCommand = argument.isEmpty ? 'compress' : 'compress $argument';

    try {
      final response = await _commands.slashExec(sessionId, slashCommand);
      onOutcome?.call(legacyOutcome(response));
      return _resultFromResponse(
        response,
        sessionId: sessionId,
        argument: argument,
        connectionEpoch: connectionEpoch,
        sessionEpoch: sessionEpoch,
        route: DesktopCommandRoute.slashExec,
        fallbackUsed: false,
      );
    } catch (error) {
      onOutcome?.call(failureOutcome(error));
      // `method not found` is a protocol-level, pre-acceptance rejection.
      // Anything else can mean the server accepted /compress before the
      // response path failed, so it must not be replayed on another route.
      if (!_canSafelyFallbackAfterSlashFailure(error) ||
          (fallbackStillValid != null && !fallbackStillValid())) {
        return DesktopCommandDispatch(
          commandName: 'compress',
          arg: argument,
          sessionId: sessionId,
          connectionEpoch: connectionEpoch,
          sessionEpoch: sessionEpoch,
          attemptedRoute: DesktopCommandRoute.slashExec,
          fallbackUsed: false,
          dispatchKind: DesktopCommandDispatchKind.error,
          accepted: DesktopCommandAcceptance.unknown,
          failure: _safeFailure(error),
        );
      }
    }

    try {
      final response = await _commands.commandDispatch(
        sessionId,
        name: 'compress',
        arg: argument,
      );
      onOutcome?.call(legacyOutcome(response));
      return _resultFromResponse(
        response,
        sessionId: sessionId,
        argument: argument,
        connectionEpoch: connectionEpoch,
        sessionEpoch: sessionEpoch,
        route: DesktopCommandRoute.commandDispatch,
        fallbackUsed: true,
      );
    } catch (error) {
      onOutcome?.call(failureOutcome(error));
      // No hay tercer intento. Tras un error de transporte/timeout no se puede
      // saber con seguridad si el backend aceptó la mutación.
      return DesktopCommandDispatch(
        commandName: 'compress',
        arg: argument,
        sessionId: sessionId,
        connectionEpoch: connectionEpoch,
        sessionEpoch: sessionEpoch,
        attemptedRoute: DesktopCommandRoute.commandDispatch,
        fallbackUsed: true,
        dispatchKind: DesktopCommandDispatchKind.error,
        accepted: DesktopCommandAcceptance.unknown,
        failure: _safeFailure(error),
      );
    }
  }

  DesktopCommandDispatch _resultFromResponse(
    DesktopCommandRpcResult response, {
    required String sessionId,
    required String argument,
    required int connectionEpoch,
    required int sessionEpoch,
    required DesktopCommandRoute route,
    required bool fallbackUsed,
  }) => DesktopCommandDispatch(
    commandName: 'compress',
    arg: argument,
    sessionId: sessionId,
    connectionEpoch: connectionEpoch,
    sessionEpoch: sessionEpoch,
    attemptedRoute: route,
    fallbackUsed: fallbackUsed,
    dispatchKind: response.kind,
    output: response.output ?? response.notice,
    accepted: response.accepted,
    failure: response.accepted == DesktopCommandAcceptance.rejected
        ? const CommandFailure(kind: CommandFailureKind.remote)
        : null,
  );

  CommandFailure _safeFailure(Object error) {
    if (error is TimeoutException) {
      return const CommandFailure(
        kind: CommandFailureKind.timeout,
        retryable: false,
      );
    }
    if (error is TuiGatewayRpcError) {
      final message = error.message.toLowerCase();
      final isTimeout =
          message.contains('timeout') || message.contains('timed out');
      final isTransport =
          message.contains('transport') ||
          message.contains('socket') ||
          message.contains('websocket');
      return CommandFailure(
        kind: isTimeout
            ? CommandFailureKind.timeout
            : isTransport
            ? CommandFailureKind.transport
            : CommandFailureKind.remote,
        code: error.code,
        retryable: false,
      );
    }
    return const CommandFailure(
      kind: CommandFailureKind.transport,
      retryable: false,
    );
  }

  bool _canSafelyFallbackAfterSlashFailure(Object error) =>
      failureOutcome(error) == DesktopCompressionOutcome.routeUnavailable;

  String _validateSessionId(String raw) {
    final value = raw.trim();
    if (value.isEmpty ||
        value.length > 512 ||
        value.contains(RegExp(r'[\x00-\x1F\x7F]'))) {
      throw const FormatException('invalid runtime session identity');
    }
    return value;
  }

  String _validateArgument(String raw) {
    final value = raw.trim();
    if (value.length > 500 ||
        value.contains(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'))) {
      throw const FormatException('invalid compression argument');
    }
    return value;
  }
}
