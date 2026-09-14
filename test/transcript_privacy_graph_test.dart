import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/services/session_reconciler.dart';

Map<String, dynamic> row(int? id, String? messageId, {bool private = false}) =>
    {
      'row_id': ?id,
      'message_id': ?messageId,
      'role': 'assistant',
      'content': private ? 'PRIVATE_GRAPH' : 'PUBLIC_GRAPH',
      if (private) 'hidden': true,
    };

Iterable<List<T>> permutations<T>(List<T> values) sync* {
  if (values.isEmpty) {
    yield [];
    return;
  }
  for (var i = 0; i < values.length; i++) {
    final remaining = List<T>.of(values)..removeAt(i);
    for (final rest in permutations(remaining)) {
      yield [values[i], ...rest];
    }
  }
}

void main() {
  const reconciler = DesktopSessionReconciler();
  test(
    'exact negative survives a conflicting island without vetoing peers',
    () {
      final evidence = [row(2, 'A', private: true), row(2, 'B'), row(2, null)];
      final negativeCopy = row(2, 'A');
      final peers = [row(2, 'B'), row(2, null), row(null, 'A')];
      for (final order in permutations(evidence)) {
        expect(
          reconciler.overlayDurableDisplayMetadata([
            negativeCopy,
            ...peers,
          ], order.map((r) => DesktopSessionMessage.tryParse(r)!).toList()),
          peers,
        );
      }
    },
  );
}
