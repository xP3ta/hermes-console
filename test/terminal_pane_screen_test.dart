// The terminal page as the user meets it: a notice when App Lock is off,
// a locked state, one input and one Run button when ready, the server's
// refusal in plain sight, and FLAG_SECURE held for exactly as long as the
// page is on screen.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/connection.dart';
import 'package:hermes_android/core/models/terminal_exec.dart';
import 'package:hermes_android/core/screens/terminal_pane_screen.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_terminal_gateway.dart';

final _connection = SavedConnection(
  id: 'term-screen',
  label: 'Test',
  host: 'hermes.example.test',
  port: 8642,
  apiKey: 'k',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final secure = <bool>[];

  setUp(() {
    secure.clear();
    FlutterSecureStorage.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('hermes/security'), (
          call,
        ) async {
          if (call.method == 'setSecureScreen') {
            secure.add(call.arguments as bool);
          }
          return null;
        });
  });

  Future<AppLockService> lock({required bool enabled}) async {
    SharedPreferences.setMockInitialValues({'app_lock_enabled': enabled});
    return AppLockService(await SharedPreferences.getInstance());
  }

  Widget app(
    FakeTerminalGateway gateway,
    AppLockService appLock, {
    Future<bool> Function(BuildContext, AppLockService, String)? verify,
  }) => MaterialApp(
    theme: AppTheme.fromId('dark'),
    locale: const Locale('en'),
    localizationsDelegates: Strings.localizationsDelegates,
    supportedLocales: Strings.supportedLocales,
    home: TerminalPaneScreen(
      connection: _connection,
      profile: 'default',
      gateway: gateway,
      appLock: appLock,
      verifyLock: verify ?? (_, _, _) async => true,
    ),
  );

  testWidgets('App Lock off: one notice, no input, no request', (tester) async {
    final gateway = FakeTerminalGateway();
    await tester.pumpWidget(app(gateway, await lock(enabled: false)));
    await tester.pumpAndSettle();
    expect(find.text('Turn on App Lock to use the terminal'), findsOneWidget);
    expect(find.byKey(const ValueKey('terminal-input')), findsNothing);
    expect(find.byKey(const ValueKey('terminal-run')), findsNothing);
    expect(gateway.commands, isEmpty);
  });

  testWidgets('a failed verify shows the locked state and sends nothing', (
    tester,
  ) async {
    final gateway = FakeTerminalGateway();
    await tester.pumpWidget(
      app(gateway, await lock(enabled: true), verify: (_, _, _) async => false),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('terminal-unlock')), findsOneWidget);
    expect(find.byKey(const ValueKey('terminal-input')), findsNothing);
    expect(gateway.commands, isEmpty);
  });

  testWidgets('ready: Run sends the command and shows stdout and the code', (
    tester,
  ) async {
    final gateway = FakeTerminalGateway()
      ..handler = (_, _) async =>
          const ShellExecResult(stdout: 'hello', stderr: 'warn', exitCode: 3);
    await tester.pumpWidget(app(gateway, await lock(enabled: true)));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('terminal-input')),
      'echo hello',
    );
    await tester.tap(find.byKey(const ValueKey('terminal-run')));
    await tester.pumpAndSettle();
    expect(gateway.ran, ['echo hello']);
    expect(find.text('hello'), findsOneWidget);
    expect(find.text('warn'), findsOneWidget);
    expect(find.text('Exit code 3'), findsOneWidget);
  });

  testWidgets('a 4005 refusal is shown verbatim', (tester) async {
    final gateway = FakeTerminalGateway()
      ..handler = (_, _) => Future.error(
        const ShellExecRefusal(
          4005,
          'blocked: recursive delete. Use the agent.',
        ),
      );
    await tester.pumpWidget(app(gateway, await lock(enabled: true)));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('terminal-input')),
      'rm -rf /',
    );
    await tester.tap(find.byKey(const ValueKey('terminal-run')));
    await tester.pumpAndSettle();
    expect(
      find.text('blocked: recursive delete. Use the agent.'),
      findsOneWidget,
    );
  });

  testWidgets('a pasted block is joined into one line and never run', (
    tester,
  ) async {
    final gateway = FakeTerminalGateway();
    await tester.pumpWidget(app(gateway, await lock(enabled: true)));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('terminal-input')),
      'ls\nrm -rf x',
    );
    await tester.pump();
    expect(gateway.ran, isEmpty);
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('terminal-input')),
    );
    expect(field.controller!.text, 'ls rm -rf x');
  });

  testWidgets('empty input shows a hint and sends nothing', (tester) async {
    final gateway = FakeTerminalGateway();
    await tester.pumpWidget(app(gateway, await lock(enabled: true)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('terminal-run')));
    await tester.pumpAndSettle();
    expect(find.text('Type a command'), findsOneWidget);
    expect(gateway.ran, isEmpty);
  });

  testWidgets('the input is disabled while a command is in flight', (
    tester,
  ) async {
    final gateway = FakeTerminalGateway();
    final done = Completer<ShellExecResult>();
    gateway.handler = (_, _) => done.future;
    await tester.pumpWidget(app(gateway, await lock(enabled: true)));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('terminal-input')),
      'sleep 9',
    );
    await tester.tap(find.byKey(const ValueKey('terminal-run')));
    await tester.pump();
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('terminal-input')),
    );
    expect(field.enabled, isFalse);
    done.complete(const ShellExecResult(stdout: '', stderr: '', exitCode: 0));
    await tester.pumpAndSettle();
  });

  testWidgets('FLAG_SECURE is on while visible and restored on leave', (
    tester,
  ) async {
    final gateway = FakeTerminalGateway();
    await tester.pumpWidget(app(gateway, await lock(enabled: true)));
    await tester.pumpAndSettle();
    expect(secure, isNotEmpty);
    expect(secure.last, isTrue);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pumpAndSettle();
    expect(secure.last, isFalse);
  });

  testWidgets('FLAG_SECURE also covers the App Lock notice page', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(FakeTerminalGateway(), await lock(enabled: false)),
    );
    await tester.pumpAndSettle();
    expect(secure.last, isTrue);
  });

  testWidgets('without a chat there is no agent segment', (tester) async {
    await tester.pumpWidget(
      app(FakeTerminalGateway(), await lock(enabled: true)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Agent'), findsNothing);
  });
}
