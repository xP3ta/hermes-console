import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_local_models_server.dart';

/// Desktop stopped polling local-models status every 2 s while idle
/// (NousResearch/hermes-agent #129638). Console already polls only while a
/// job runs or is paused (job polling itself is covered in
/// local_models_screen_test); this pins that an idle screen stays quiet.
int _reads(FakeLocalModelsServer server) =>
    server.calls.where((c) => c.method == 'GET').length;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('an idle Local models screen does not poll', (tester) async {
    final server = FakeLocalModelsServer();
    await pumpLocalModels(tester, server);
    final reads = _reads(server);
    await tester.pump(const Duration(minutes: 1));
    await tester.pumpAndSettle();
    expect(_reads(server), reads);
  });
}
