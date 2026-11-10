// SPDX-License-Identifier: GPL-3.0-only
// H4: the screens that show an SSH private key or password, the live terminal
// and the instance editor (API keys, Dashboard password) keep FLAG_SECURE on
// while they are visible, whatever the global «block screenshots» preference.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/widgets/secure_screen_scope.dart';

void main() {
  testWidgets('holds the scope while mounted and releases it once', (
    tester,
  ) async {
    var pushed = 0;
    var released = 0;
    Future<Future<void> Function()> scope() async {
      pushed++;
      return () async => released++;
    }

    await tester.pumpWidget(
      MaterialApp(
        home: SecureScreenScope(scope: scope, child: const Text('key')),
      ),
    );
    await tester.pump();
    expect(find.text('key'), findsOneWidget);
    expect(pushed, 1);
    expect(released, 0);

    // A rebuild keeps the same scope.
    await tester.pumpWidget(
      MaterialApp(
        home: SecureScreenScope(scope: scope, child: const Text('key 2')),
      ),
    );
    await tester.pump();
    expect(pushed, 1);

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();
    expect(released, 1);
  });

  testWidgets('leaving before the scope is granted still releases it', (
    tester,
  ) async {
    var released = 0;
    Future<Future<void> Function()> slow() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      return () async => released++;
    }

    await tester.pumpWidget(
      MaterialApp(
        home: SecureScreenScope(scope: slow, child: const SizedBox()),
      ),
    );
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump(const Duration(milliseconds: 100));
    expect(released, 1);
  });

  test('the SSH credentials, terminal and instance editor use it', () {
    for (final path in [
      'lib/core/screens/ssh_credentials_screen.dart',
      'lib/core/screens/ssh_terminal_screen.dart',
      'lib/core/screens/instance_edit_screen.dart',
    ]) {
      expect(
        File(path).readAsStringSync(),
        contains('SecureScreenScope('),
        reason: path,
      );
    }
  });
}
