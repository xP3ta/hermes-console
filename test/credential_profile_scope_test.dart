// The profile a credential write names (Settings › Messaging and its
// pairing page). Naming `default` when nothing was ever picked reaches the
// installation root on a Dashboard launched for a named profile, so an
// unpicked profile must stay empty and travel unnamed.
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('no selection is empty, a picked default is named, a named profile '
      'is itself', () async {
    SharedPreferences.setMockInitialValues({});
    final manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    addTearDown(manager.dispose);
    const id = 'conn-1';

    expect(manager.credentialProfileFor(id), '');

    await manager.setActiveProfile(id, 'research');
    expect(manager.credentialProfileFor(id), 'research');

    await manager.setActiveProfile(id, 'default');
    expect(manager.activeProfileFor(id), '');
    expect(manager.credentialProfileFor(id), 'default');

    // Clearing the selection is not a pick of the default profile.
    await manager.setActiveProfile(id, '');
    expect(manager.credentialProfileFor(id), '');
  });
}
