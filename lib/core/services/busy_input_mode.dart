/// The server owns this policy; Console keeps only connection/profile snapshots.
enum BusyInputMode { interrupt, queue, steer }

BusyInputMode normalizeBusyInputMode(Object? value) =>
    switch (value is String ? value.trim().toLowerCase() : '') {
      'queue' => BusyInputMode.queue,
      'steer' => BusyInputMode.steer,
      _ => BusyInputMode.interrupt,
    };

final class BusyInputModeCache {
  final _values = <(String, String), BusyInputMode>{};
  final _epochs = <(String, String), Object>{};

  static (String, String) _key(String connectionId, String profile) =>
      (connectionId, profile.trim().isEmpty ? 'default' : profile.trim());

  BusyInputMode mode(String connectionId, String profile) =>
      _values[_key(connectionId, profile)] ?? BusyInputMode.queue;

  Future<void> refresh(
    String connectionId,
    String profile,
    Future<Map<String, dynamic>> Function() read,
  ) async {
    final key = _key(connectionId, profile);
    final epoch = Object();
    _epochs[key] = epoch;
    try {
      final config = await read();
      final display = config['display'];
      final mode = normalizeBusyInputMode(
        display is Map ? display['busy_input_mode'] : null,
      );
      if (identical(_epochs[key], epoch)) _values[key] = mode;
    } catch (_) {
      // An unreadable policy must never turn a queued message into an interrupt.
      if (identical(_epochs[key], epoch)) _values.remove(key);
    }
  }
}
