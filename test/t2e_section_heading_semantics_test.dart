// Wave 8 (audit 1.4.0 §1.3, T6): the settings and vault section headers
// were plain text, so TalkBack could not jump from section to section.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_ui.dart';

void main() {
  testWidgets('a section header is a heading for TalkBack', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.fromId('console'),
        home: const Scaffold(body: HermesSectionHeader('Notifications')),
      ),
    );

    expect(
      tester.getSemantics(find.text('Notifications')),
      isSemantics(label: 'Notifications', isHeader: true),
    );
    semantics.dispose();
  });
}
