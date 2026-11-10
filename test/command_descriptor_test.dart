import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/capability_descriptor.dart';
import 'package:hermes_android/core/models/command_descriptor.dart';

CommandDescriptor _descriptor({
  String name = 'compress',
  CommandOrigin origin = CommandOrigin.catalog,
}) => CommandDescriptor(
  canonicalName: name,
  aliases: const ['/SUMMARIZE', 'summarize'],
  description: 'Compress context',
  category: CommandCategory.context,
  origin: origin,
  surface: CommandSurface.remote,
  argumentSpec: CommandArgumentSpec(
    kind: CommandArgumentKind.freeText,
    maxLength: 500,
  ),
  executor: CommandExecutorKind.slashExec,
  capabilityKey: 'slash.exec',
  scope: OperationScope.session,
  risk: OperationRisk.medium,
  availability: CapabilityState.available,
);

void main() {
  test('normaliza canonical y aliases sin tocar argumentos free-text', () {
    final descriptor = _descriptor(name: ' /ComPress ');

    expect(descriptor.canonicalName, 'compress');
    expect(descriptor.aliases, {'summarize'});
    expect(
      descriptor.argumentSpec?.validate('  Release DECISIONS  '),
      'Release DECISIONS',
    );
  });

  test('rechaza nombres mayores de 64 o con separadores de shell', () {
    expect(() => _descriptor(name: 'x' * 65), throwsFormatException);
    expect(() => _descriptor(name: 'compress;rm'), throwsFormatException);
    expect(() => _descriptor(name: 'two words'), throwsFormatException);
  });

  test('precedencia coincide con native adapter catalog completion legacy', () {
    final values = CommandOrigin.values
        .map((origin) => _descriptor(origin: origin).precedence)
        .toList();

    expect(values, [5, 4, 3, 2, 1]);
  });

  test('request de scope session exige runtime y valida epochs', () {
    final descriptor = _descriptor();

    expect(
      () => CommandExecutionRequest(
        executionId: 'exec-1',
        command: descriptor,
        connectionId: 'conn-1',
        connectionEpoch: 1,
        sessionEpoch: 1,
        createdAt: DateTime.utc(2026, 7, 22),
      ),
      throwsFormatException,
    );
  });

  test('respuesta remota conserva solo texto acotado y aceptación tipada', () {
    final result = DesktopCommandRpcResult.fromJson({
      'type': 'exec',
      'output': 'x' * 5000,
      'secret': 'must-not-survive',
    });

    expect(result.kind, DesktopCommandDispatchKind.output);
    expect(result.accepted, DesktopCommandAcceptance.accepted);
    expect(result.output, hasLength(4000));
  });

  group('free-text arguments (ORDEN-COMANDOS)', () {
    final spec = CommandArgumentSpec(kind: CommandArgumentKind.freeText);
    final multiline = [
      'Primera línea con «comillas», "dobles" y \'simples\'',
      'Segunda: tildes áéíóú ñ ç, emoji 🚀👩🏽‍💻',
      '',
      '  sangría que se conserva dentro del texto',
    ].join('\n');

    test('Console sets no limit of its own: the bound is the safety one', () {
      expect(spec.maxLength, commandArgumentMaxLength);
      expect(commandArgumentMaxLength, greaterThanOrEqualTo(20000));
    });

    test('short, 600, 5000, multiline and unicode pass as typed', () {
      for (final arg in [
        'short',
        'a' * 600,
        'b' * 5000,
        multiline,
        'x' * commandArgumentMaxLength,
      ]) {
        expect(spec.validate(arg), arg, reason: '${arg.length} chars');
      }
      // Only the ends are trimmed, as before.
      expect(spec.validate('  \n$multiline\n  '), multiline);
    });

    test('past the safety bound it is refused before any RPC', () {
      expect(
        () => spec.validate('x' * (commandArgumentMaxLength + 1)),
        throwsFormatException,
      );
      expect(
        () => CommandArgumentSpec(
          kind: CommandArgumentKind.freeText,
          maxLength: commandArgumentMaxLength + 1,
        ),
        throwsFormatException,
      );
    });

    test('a command\'s kickoff prompt is kept whole', () {
      final prompt = 'p' * 100000;
      final result = DesktopCommandRpcResult.fromJson({
        'type': 'send',
        'message': prompt,
        'notice': 'Goal set',
      });
      expect(result.kind, DesktopCommandDispatchKind.send);
      expect(result.message, prompt);
    });
  });
}
