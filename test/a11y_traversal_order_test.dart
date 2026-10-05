import 'package:flutter_test/flutter_test.dart';

import 'support/a11y_main_screen_harness.dart';

List<String> traversalLabels(WidgetTester tester) => tester.semantics
    .simulatedAccessibilityTraversal()
    .map((node) => node.label)
    .where((label) => label.isNotEmpty)
    .toList();

void expectLabelsInOrder(List<String> labels, List<Pattern> expected) {
  final readingOrder = labels.join('\n');
  var cursor = 0;
  for (final pattern in expected) {
    final next = readingOrder.indexOf(pattern, cursor);
    expect(next, greaterThanOrEqualTo(cursor), reason: readingOrder);
    cursor = next + pattern.toString().length;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(installA11yPlatformMocks);
  tearDown(clearA11yPlatformMocks);

  testWidgets('profiles traversal follows app bar, content, primary action', (
    tester,
  ) async {
    useA11yPhoneView(tester);
    final semantics = tester.ensureSemantics();
    try {
      await pumpA11yProfiles(tester, textScale: 1);
      expectLabelsInOrder(traversalLabels(tester), [
        'profiles',
        'default',
        'release',
        'Create',
      ]);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('chat traversal follows app bar, transcript, composer', (
    tester,
  ) async {
    useA11yPhoneView(tester);
    final semantics = tester.ensureSemantics();
    try {
      await pumpA11yChat(tester, textScale: 1);
      expectLabelsInOrder(traversalLabels(tester), [
        'Model & session',
        'Hermes Console',
        'The release is ready.',
        'Ask Hermes…',
      ]);
    } finally {
      semantics.dispose();
    }
  });
}
