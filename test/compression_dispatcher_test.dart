import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/command_descriptor.dart';
import 'package:hermes_android/core/models/desktop_compression_outcome.dart';
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
  for (final fallback in [false, true]) {
    test(
      'REGRESSION_COMP_FIX3_LEGACY parser evidence fallback=$fallback',
      () async {
        final cases = <(Map<String, Object?>, DesktopCompressionOutcome)>[
          ({'accepted': false}, DesktopCompressionOutcome.terminalRejected),
          ({'status': 'rejected'}, DesktopCompressionOutcome.terminalRejected),
          (
            {'type': 'error', 'accepted': false, 'status': 'rejected'},
            DesktopCompressionOutcome.terminalRejected,
          ),
          (
            {
              'type': 'exec',
              'accepted': false,
              'status': 'pending',
              'output': 'queued',
            },
            DesktopCompressionOutcome.ambiguous,
          ),
          (
            {'accepted': false, 'type': 'exec'},
            DesktopCompressionOutcome.ambiguous,
          ),
          (
            {'accepted': false, 'status': 'pending'},
            DesktopCompressionOutcome.ambiguous,
          ),
          (
            {'accepted': false, 'output': 'rejected'},
            DesktopCompressionOutcome.ambiguous,
          ),
          (
            {'accepted': true, 'status': 'rejected'},
            DesktopCompressionOutcome.ambiguous,
          ),
          (
            {'accepted': 'false', 'status': 'rejected'},
            DesktopCompressionOutcome.ambiguous,
          ),
          (
            {'accepted': null, 'status': 'rejected'},
            DesktopCompressionOutcome.ambiguous,
          ),
          ({'accepted': false, 'type': 1}, DesktopCompressionOutcome.ambiguous),
          (
            {'accepted': false, 'status': 'failed'},
            DesktopCompressionOutcome.ambiguous,
          ),
          (
            {'accepted': false, 'status': 'REJECTED'},
            DesktopCompressionOutcome.ambiguous,
          ),
          (
            {'accepted': false, 'pending': true},
            DesktopCompressionOutcome.ambiguous,
          ),
          ({}, DesktopCompressionOutcome.ambiguous),
        ];
        for (final (payload, expected) in cases) {
          final parsed = DesktopCommandRpcResult.fromJson(payload);
          final gateway = _RecordingCommandGateway()
            ..slashResult = parsed
            ..dispatchResult = parsed;
          if (fallback) {
            gateway.slashError = const TuiGatewayRpcError(
              'slash.exec',
              'unavailable',
              code: -32601,
            );
          }
          final result = await CompressionDispatcher(gateway).dispatch(
            'runtime',
            focusTopic: '',
            connectionEpoch: 1,
            sessionEpoch: 1,
            stillValid: () => true,
            matchesRoot: (_) => true,
          );
          expect(result.evidence.outcome, expected, reason: '$payload');
          expect(gateway.calls, hasLength(fallback ? 2 : 1));
        }
      },
    );
  }

  test(
    'REGRESSION_COMP_FIX3_LEGACY hand-built rejection has no settlement proof',
    () async {
      final gateway = _RecordingCommandGateway()
        ..slashResult = const DesktopCommandRpcResult(
          kind: DesktopCommandDispatchKind.none,
          accepted: DesktopCommandAcceptance.rejected,
        );
      final result = await CompressionDispatcher(gateway).dispatch(
        'runtime',
        focusTopic: '',
        connectionEpoch: 1,
        sessionEpoch: 1,
        stillValid: () => true,
        matchesRoot: (_) => true,
      );
      expect(result.evidence.outcome, DesktopCompressionOutcome.ambiguous);
      expect(gateway.calls, hasLength(1));
    },
  );
  test(
    'REGRESSION_COMP_TYPED_LEGACY_INVALID_ACCEPTED never proves acceptance',
    () {
      final evidence = DesktopCompressionLegacyEvidence.fromWire({
        'output': 'free text must be irrelevant',
        'accepted': 'yes',
      });
      expect(evidence.outcome, DesktopCompressionOutcome.ambiguous);
    },
  );

  test('REGRESSION_COMP_TYPED_LEGACY_CONTRADICTION stays ambiguous', () {
    final evidence = DesktopCompressionLegacyEvidence.fromWire({
      'type': 'exec',
      'status': 'failed',
      'output': 'looks successful but is not authority',
    });
    expect(evidence.outcome, DesktopCompressionOutcome.ambiguous);
  });

  test(
    'REGRESSION_COMP_TYPED_LEGACY_REJECTED contradictory positive signals stay ambiguous',
    () {
      for (final wire in <Map<String, Object>>[
        {'accepted': false, 'type': 'exec'},
        {'accepted': false, 'status': 'pending'},
        {'accepted': false, 'output': 'presentation text'},
      ]) {
        expect(
          DesktopCompressionLegacyEvidence.fromWire(wire).outcome,
          DesktopCompressionOutcome.ambiguous,
          reason: '$wire',
        );
      }
    },
  );

  test(
    'REGRESSION_COMP_TYPED evidence precedence and route exclusion',
    () async {
      for (final message in [
        'neutral',
        'timeout',
        'transport',
        'sesión ajena',
      ]) {
        final error = TuiGatewayRpcError('slash.exec', message, code: 4090);
        expect(
          CompressionDispatcher.failureOutcome(error),
          DesktopCompressionOutcome.ownershipLost,
        );
        final gateway = _RecordingCommandGateway()
          ..slashError = error
          ..dispatchError = const TuiGatewayRpcError(
            'command.dispatch',
            'denied',
            origin: CompressionFailureOrigin.localPreflight,
          );
        final result = await CompressionDispatcher(gateway).dispatch(
          'runtime',
          focusTopic: '',
          connectionEpoch: 1,
          sessionEpoch: 1,
          stillValid: () => true,
          matchesRoot: (_) => true,
        );
        expect(gateway.calls, hasLength(1));
        expect(
          result.evidence.outcome,
          DesktopCompressionOutcome.ownershipLost,
        );
      }
      expect(
        CompressionDispatcher.failureOutcome(
          const TuiGatewayRpcError(
            'session.compress',
            'x',
            code: 4090,
            origin: CompressionFailureOrigin.malformed,
          ),
        ),
        DesktopCompressionOutcome.ambiguous,
      );
      final gateway = _RecordingCommandGateway()
        ..slashError = const FormatException('unknown')
        ..dispatchError = const TuiGatewayRpcError(
          'command.dispatch',
          'denied',
          origin: CompressionFailureOrigin.localPreflight,
        );
      final result = await CompressionDispatcher(gateway).dispatch(
        'runtime',
        focusTopic: '',
        connectionEpoch: 1,
        sessionEpoch: 1,
        stillValid: () => true,
        matchesRoot: (_) => true,
      );
      expect(
        gateway.calls,
        hasLength(1),
        reason: 'later preflight cannot erase possible acceptance',
      );
      expect(result.evidence.outcome, DesktopCompressionOutcome.ambiguous);
    },
  );
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
    'solo method-not-found de slash.exec habilita command.dispatch una vez',
    () async {
      final gateway = _RecordingCommandGateway()
        ..slashError = const TuiGatewayRpcError(
          'slash.exec',
          'Method not found',
          code: -32601,
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
    'timeout de slash queda unknown y nunca lo reintenta por command.dispatch',
    () async {
      final gateway = _RecordingCommandGateway()
        ..slashError = TimeoutException(
          'Timeout waiting for JSON-RPC response',
        );

      final result = await CompressionDispatcher(
        gateway,
      ).compress('runtime-047', connectionEpoch: 1, sessionEpoch: 1);

      expect(gateway.calls.map((call) => call.$1), ['slash.exec']);
      expect(result.attemptedRoute, DesktopCommandRoute.slashExec);
      expect(result.fallbackUsed, isFalse);
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
          'Method not found',
          code: -32601,
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

  test('desconexión de slash no habilita command.dispatch', () async {
    final gateway = _RecordingCommandGateway()
      ..slashError = StateError('websocket closed before response');

    final result = await CompressionDispatcher(
      gateway,
    ).compress('runtime-047', connectionEpoch: 1, sessionEpoch: 1);

    expect(gateway.calls.map((call) => call.$1), ['slash.exec']);
    expect(result.accepted, DesktopCommandAcceptance.unknown);
    expect(result.failure?.kind, CommandFailureKind.transport);
    expect(result.fallbackUsed, isFalse);
  });

  test(
    'fallo de transporte redactado de slash tampoco habilita fallback',
    () async {
      final gateway = _RecordingCommandGateway()
        ..slashError = const TuiGatewayRpcError(
          'slash.exec',
          'Sensitive response transport failed',
        );

      final result = await CompressionDispatcher(
        gateway,
      ).compress('runtime-047', connectionEpoch: 1, sessionEpoch: 1);

      expect(gateway.calls.map((call) => call.$1), ['slash.exec']);
      expect(result.accepted, DesktopCommandAcceptance.unknown);
      expect(result.failure?.kind, CommandFailureKind.transport);
      expect(result.fallbackUsed, isFalse);
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
