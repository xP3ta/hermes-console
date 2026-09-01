import 'dart:async';

import '../models/command_descriptor.dart';
import 'tui_gateway_client.dart';

/// Replica exactamente el routing de Hermes Desktop para `/compress`.
///
/// No conoce `session.compress`: solo intenta `slash.exec` y, si ese Future
/// termina con error, un único `command.dispatch`. Los argumentos nunca se
/// interpolan en logs o mensajes de error.
final class CompressionDispatcher {
  final HermesDesktopCommandGateway _gateway;

  const CompressionDispatcher(this._gateway);

  Future<DesktopCommandDispatch> compress(
    String runtimeSessionId, {
    String focusTopic = '',
    required int connectionEpoch,
    required int sessionEpoch,
    bool Function()? fallbackStillValid,
  }) async {
    final sessionId = _validateSessionId(runtimeSessionId);
    final argument = _validateArgument(focusTopic);
    if (connectionEpoch < 0 || sessionEpoch < 0) {
      throw const FormatException('invalid compression epoch');
    }
    final slashCommand = argument.isEmpty ? 'compress' : 'compress $argument';

    try {
      final response = await _gateway.slashExec(sessionId, slashCommand);
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
      // Desktop usa el error como única señal para probar command.dispatch.
      // No se conserva el error primario porque podría incluir texto remoto.
      if (fallbackStillValid != null && !fallbackStillValid()) {
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
      final response = await _gateway.commandDispatch(
        sessionId,
        name: 'compress',
        arg: argument,
      );
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
      final isTimeout = error.message.toLowerCase().contains('timeout');
      return CommandFailure(
        kind: isTimeout
            ? CommandFailureKind.timeout
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
