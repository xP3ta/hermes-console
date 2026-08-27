import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/memory_draft_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('memory drafts stay isolated per profile', () async {
    SharedPreferences.setMockInitialValues({});
    final store = MemoryDraftStore(await SharedPreferences.getInstance());

    await store.write('instance', 'memory.md', 'tierra', profile: 'tierra');
    await store.write('instance', 'memory.md', 'luna', profile: 'luna');

    expect(store.read('instance', 'memory.md', profile: 'tierra'), 'tierra');
    expect(store.read('instance', 'memory.md', profile: 'luna'), 'luna');
    expect(store.read('instance', 'memory.md'), isNull);
  });
}
