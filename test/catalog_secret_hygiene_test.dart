import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/capabilities/capabilities_repository.dart';
import 'package:hermes_android/core/capabilities/capability_models.dart';
import 'package:hermes_android/core/services/connection_manager.dart'
    show DashboardHttpException;

import 'capabilities/capabilities_fakes.dart';

const _secret = 'sentinel-secret-value-123';

void main() {
  late List<String> printed;
  late DebugPrintCallback original;

  setUp(() {
    printed = [];
    original = debugPrint;
    debugPrint = (message, {wrapWidth}) => printed.add('$message');
  });

  tearDown(() => debugPrint = original);

  test('a credential never reaches logs, errors or state', () async {
    // The server even echoes the value in its error body.
    final rest = ScriptedRest()
      ..posts['mcp/catalog/install'] = DashboardHttpException(
        400,
        body: '{"detail":"bad value $_secret"}',
      )
      ..puts['env'] = DashboardHttpException(
        400,
        body: '{"detail":"bad value $_secret"}',
      );
    final repo = repoOf(rest);
    final seen = <String>[];

    for (final run in <Future<void> Function()>[
      () => repo.installMcp(
        'docs',
        environment: {'DOCS_KEY': _secret},
        declaredEnv: const ['DOCS_KEY'],
      ),
      () => repo.setPluginEnv(
        {'WEATHER_KEY': _secret},
        declared: const ['WEATHER_KEY'],
      ),
    ]) {
      try {
        await run();
        fail('expected a failure');
      } on CapabilityFailure catch (error) {
        seen
          ..add(error.toString())
          ..add(error.detail);
      }
    }

    expect(seen, hasLength(4));
    for (final text in [...seen, ...printed]) {
      expect(text, isNot(contains(_secret)));
    }
    // Models never carry values: the env field is a name and a prompt only.
    const field = CapabilityEnvField(name: 'DOCS_KEY', prompt: 'API key');
    expect('${field.name} ${field.prompt}', isNot(contains(_secret)));
    expect(printed, isEmpty);
  });
}
