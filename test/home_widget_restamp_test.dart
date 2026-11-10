import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/home_widget_snapshot.dart';
import 'package:hermes_android/core/services/home_widget_publisher.dart';

class _Store implements HomeWidgetStore {
  final values = <String, Object?>{};

  @override
  Future<Object?> read(String key) async => values[key];

  @override
  Future<void> write(String key, Object? value) async => values[key] = value;

  @override
  Future<void> requestUpdate() async {}
}

void main() {
  test('a write that is not news keeps the snapshot time', () async {
    var now = 1000000;
    final publisher = HermesHomeWidgetPublisher(
      store: _Store(),
      nowMs: () => now,
    );
    await publisher.publish(
      const HermesHomeWidgetSnapshot(
        configured: true,
        instanceId: 'home',
        connectionState: HomeWidgetConnectionState.connected,
      ),
    );
    expect(publisher.latest.updatedAtMs, 1000000);

    // The app goes to the background 10 minutes later: the state is still
    // the one from minute 0 and must keep saying so.
    now += 10 * 60000;
    await publisher.update((s) => s, restamp: false);
    expect(publisher.latest.updatedAtMs, 1000000);

    await publisher.update((s) => s);
    expect(
      publisher.latest.updatedAtMs,
      now,
      reason: 'a real change still stamps the time',
    );
  });
}
