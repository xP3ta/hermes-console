import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/command_descriptor.dart';
import 'package:hermes_android/core/services/compression_dispatcher.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

final class _RecordingCommandGateway implements HermesDesktopCommandGateway {
  final List<(String, Map<String, String>)> calls = [];
  DesktopCommandRpcResult slashResult = const DesktopCommandRpcResult(
    kind: DesktopCommandDispatchKind.output,
    accepted: DesktopCommandAcceptance.accepted,
    output: 'slash accepted',
  );
  DesktopCommandRpcResult dispatchResult = const DesktopCommandRpcResult(
    kind: DesktopCommandDispatchKind.output,
    accepted: DesktopCommandAcceptance.accepted,
    output: 'dispatch accepted',
  );
  Object? slashError;
  Object? dispatchError;
  Completer<void>? slashGate;

  @override
  Future<DesktopCommandCatalog> commandsCatalog() => throw UnimplementedError();

  @override
  Future<SlashCompletionBatch> completeSlash(String text) =>
      throw UnimplementedError();

  @override
  Future<DesktopCommandRpcResult> slashExec(
    String runtimeSessionId,
    String command,
  ) async {
    calls.add((
      'slash.exec',
      {'session_id': runtimeSessionId, 'command': command},
    ));
    await slashGate?.future;
    if (slashError case final error?) throw error;
    return slashResult;
  }

  @override
  Future<DesktopCommandRpcResult> commandDispatch(
    String runtimeSessionId, {
    required String name,
    String arg = '',
  }) async {
    calls.add((
      'command.dispatch',
      {'session_id': runtimeSessionId, 'name': name, 'arg': arg},
    ));
    if (dispatchError case final error?) throw error;
    return dispatchResult;
  }
}

void main() {
  test('slash.exec aceptado no ejecuta ningún fallback', () async {
    final gateway = _RecordingCommandGateway();
    final result = await CompressionDispatcher(gateway).compress(
      ' runtime-047 ',
      focusTopic: '  decisiones de release  ',
      connectionEpoch: 4,
      sessionEpoch: 7,
    );

    expect(gateway.calls, hasLength(1));
    expect(gateway.calls.single.$1, 'slash.exec');
    expect(gateway.calls.single.$2, {
      'session_id': 'runtime-047',
      'command': 'compress decisiones de release',
    });
    expect(result.attemptedRoute, DesktopCommandRoute.slashExec);
    expect(result.fallbackUsed, isFalse);
    expect(result.output, 'slash accepted');
    expect(result.accepted, DesktopCommandAcceptance.accepted);
    expect(result.connectionEpoch, 4);
    expect(result.sessionEpoch, 7);
  });

  test(
    'solo un error de slash.exec habilita command.dispatch una vez',
    () async {
      final gateway = _RecordingCommandGateway()
        ..slashError = const TuiGatewayRpcError(
          'slash.exec',
          'synthetic failure',
          code: 4018,
        );

      final result = await CompressionDispatcher(gateway).compress(
        'runtime-047',
        focusTopic: ' release decisions ',
        connectionEpoch: 1,
        sessionEpoch: 2,
      );

      expect(gateway.calls, hasLength(2));
      expect(gateway.calls.first.$1, 'slash.exec');
      expect(gateway.calls.first.$2, {
        'session_id': 'runtime-047',
        'command': 'compress release decisions',
      });
      expect(gateway.calls.last.$1, 'command.dispatch');
      expect(gateway.calls.last.$2, {
        'session_id': 'runtime-047',
        'name': 'compress',
        'arg': 'release decisions',
      });
      expect(result.attemptedRoute, DesktopCommandRoute.commandDispatch);
      expect(result.fallbackUsed, isTrue);
      expect(result.output, 'dispatch accepted');
    },
  );

  test(
    'respuesta vacía de slash sigue siendo aceptación y no hace fallback',
    () async {
      final gateway = _RecordingCommandGateway()
        ..slashResult = const DesktopCommandRpcResult(
          kind: DesktopCommandDispatchKind.none,
          accepted: DesktopCommandAcceptance.accepted,
        );

      final result = await CompressionDispatcher(
        gateway,
      ).compress('runtime-047', connectionEpoch: 1, sessionEpoch: 1);

      expect(gateway.calls, hasLength(1));
      expect(result.dispatchKind, DesktopCommandDispatchKind.none);
      expect(result.fallbackUsed, isFalse);
    },
  );

  test(
    'error del fallback queda unknown y nunca crea un tercer intento',
    () async {
      final gateway = _RecordingCommandGateway()
        ..slashError = StateError('synthetic primary failure')
        ..dispatchError = const TuiGatewayRpcError(
          'command.dispatch',
          'Timeout waiting for JSON-RPC response',
        );

      final result = await CompressionDispatcher(
        gateway,
      ).compress('runtime-047', connectionEpoch: 1, sessionEpoch: 1);

      expect(gateway.calls.map((call) => call.$1), [
        'slash.exec',
        'command.dispatch',
      ]);
      expect(result.accepted, DesktopCommandAcceptance.unknown);
      expect(result.failure?.kind, CommandFailureKind.timeout);
      expect(result.failure?.retryable, isFalse);
    },
  );

  test(
    'una valla vencida entre slash y dispatch impide el segundo RPC',
    () async {
      final slashGate = Completer<void>();
      var fallbackStillValid = true;
      final gateway = _RecordingCommandGateway()
        ..slashGate = slashGate
        ..slashError = const TuiGatewayRpcError(
          'slash.exec',
          'synthetic failure',
          code: 4018,
        );

      final running = CompressionDispatcher(gateway).compress(
        'runtime-047',
        connectionEpoch: 1,
        sessionEpoch: 2,
        fallbackStillValid: () => fallbackStillValid,
      );
      while (gateway.calls.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      fallbackStillValid = false;
      slashGate.complete();

      final result = await running;

      expect(gateway.calls.map((call) => call.$1), ['slash.exec']);
      expect(result.attemptedRoute, DesktopCommandRoute.slashExec);
      expect(result.fallbackUsed, isFalse);
      expect(result.accepted, DesktopCommandAcceptance.unknown);
    },
  );

  test('argumento mayor de 500 se rechaza antes de tocar el gateway', () async {
    final gateway = _RecordingCommandGateway();

    await expectLater(
      CompressionDispatcher(gateway).compress(
        'runtime-047',
        focusTopic: 'x' * 501,
        connectionEpoch: 1,
        sessionEpoch: 1,
      ),
      throwsFormatException,
    );
    expect(gateway.calls, isEmpty);
  });

  test('diagnóstico del dispatch excluye argumento, sesión y output', () async {
    final gateway = _RecordingCommandGateway();
    final result = await CompressionDispatcher(gateway).compress(
      'runtime-secret',
      focusTopic: 'texto privado',
      connectionEpoch: 1,
      sessionEpoch: 1,
    );

    expect(result.diagnosticFields, isNot(contains('arg')));
    expect(result.diagnosticFields, isNot(contains('session_id')));
    expect(result.diagnosticFields, isNot(contains('output')));
    expect(result.diagnosticFields.values, isNot(contains('texto privado')));
  });
}
