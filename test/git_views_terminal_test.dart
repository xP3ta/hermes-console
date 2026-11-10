// REVIEW-R5-C C-G9: Git opened from «Vistas» on a narrow screen offers the
// same Terminal way out as Git from the notch (its conflict line and the
// refused-action notices use it).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/screens/ssh_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';

final _connection = SavedConnection(
  id: 'c1',
  label: 'Home',
  host: 'hermes.local',
  port: 8642,
  apiKey: 'k',
);

void main() {
  testWidgets('with SSH in the app, Git gets the instance terminal', (
    tester,
  ) async {
    final builder = gitViewsTerminalBuilder(_connection, sshAvailable: true);
    expect(builder, isNotNull);
    late Widget built;
    await tester.pumpWidget(
      Builder(
        builder: (context) {
          built = builder!(context);
          return const SizedBox.shrink();
        },
      ),
    );
    expect(built, isA<SshScreen>());
    expect((built as SshScreen).connection.id, 'c1');
  });

  test('without SSH, no Terminal way out', () {
    expect(
      gitViewsTerminalBuilder(_connection, sshAvailable: false),
      isNull,
    );
  });
}
