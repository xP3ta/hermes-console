import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/app_error_log.dart';
import 'package:hermes_android/core/services/startup_guard.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    AppErrorLog.resetForTesting();
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
    'a throw before the app exists shows a recoverable error screen and '
    'Retry starts the app once storage recovers',
    (tester) async {
      var attempts = 0;
      Future<Widget> bootstrap() async {
        attempts++;
        if (attempts == 1) {
          throw const FormatException('invalid cancelled-turn tombstone root');
        }
        return const Directionality(
          textDirection: TextDirection.ltr,
          child: Text('hermes-ready'),
        );
      }

      await runGuardedStartup(
        bootstrap: bootstrap,
        run: (app) => tester.pumpWidget(app),
      );
      await tester.pumpAndSettle();

      expect(attempts, 1);
      expect(find.byType(StartupFailureApp), findsOneWidget);
      expect(find.text('hermes-ready'), findsNothing);
      expect(
        AppErrorLog.recent.map((r) => (r.source, r.errorType)),
        contains(('startup', 'FormatException')),
      );
      final retry = find.byKey(StartupFailureApp.retryKey);
      expect(retry, findsOneWidget);

      await tester.tap(retry);
      await tester.pumpAndSettle();

      expect(attempts, 2);
      expect(find.byKey(StartupFailureApp.retryKey), findsNothing);
      expect(find.text('hermes-ready'), findsOneWidget);
    },
  );

  testWidgets('a retry that fails again keeps the error screen usable', (
    tester,
  ) async {
    var attempts = 0;
    Future<Widget> bootstrap() async {
      attempts++;
      throw StateError('keystore unavailable');
    }

    await runGuardedStartup(
      bootstrap: bootstrap,
      run: (app) => tester.pumpWidget(app),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(StartupFailureApp.retryKey));
    await tester.pumpAndSettle();

    expect(attempts, 2);
    expect(find.byKey(StartupFailureApp.retryKey), findsOneWidget);
    await tester.tap(find.byKey(StartupFailureApp.retryKey));
    await tester.pumpAndSettle();
    expect(attempts, 3);
  });

  testWidgets('the error screen follows the device language', (tester) async {
    tester.platformDispatcher.localesTestValue = const [Locale('es')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);

    await runGuardedStartup(
      bootstrap: () async => throw StateError('boom'),
      run: (app) => tester.pumpWidget(app),
    );
    await tester.pumpAndSettle();

    expect(find.text('Reintentar'), findsOneWidget);
  });

  testWidgets('a locale read that never completes cannot hide recovery', (tester) async {
    tester.platformDispatcher.localesTestValue = const [Locale('es')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    final pending = Completer<String?>();
    Widget? root;
    final startup = runGuardedStartup(
      bootstrap: () async => throw StateError('storage unavailable'),
      readLocalePreference: () => pending.future,
      run: (app) { root = app; },
    );

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1999));
    expect(root, isNull);
    await tester.pump(const Duration(milliseconds: 1));
    expect(root, isA<StartupFailureApp>());
    await startup;
    await tester.pumpWidget(root!);
    await tester.pumpAndSettle();
    expect(find.text('Reintentar'), findsOneWidget);
    final retry = tester.widget<FilledButton>(find.byKey(StartupFailureApp.retryKey));
    expect(retry.onPressed, isNotNull);

    // A late storage result must not replace the device-language recovery UI.
    pending.complete('en');
    await tester.pumpAndSettle();
    expect(find.text('Reintentar'), findsOneWidget);
  });

  testWidgets('a failing locale read falls back to the device language', (tester) async {
    tester.platformDispatcher.localesTestValue = const [Locale('es')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    await runGuardedStartup(
      bootstrap: () async => throw StateError('storage unavailable'),
      readLocalePreference: () async => throw StateError('locale unavailable'),
      run: (app) => tester.pumpWidget(app),
    );
    await tester.pumpAndSettle();
    expect(find.text('Reintentar'), findsOneWidget);
  });

  testWidgets('the stored language still takes precedence over the device', (tester) async {
    tester.platformDispatcher.localesTestValue = const [Locale('es')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    SharedPreferences.setMockInitialValues({'app_locale': 'pt'});
    await runGuardedStartup(
      bootstrap: () async => throw StateError('boom'),
      run: (app) => tester.pumpWidget(app),
    );
    await tester.pumpAndSettle();
    expect(find.text('Tentar novamente'), findsOneWidget);
  });

  testWidgets('a healthy startup runs the app directly', (tester) async {
    await runGuardedStartup(
      readLocalePreference: () => throw StateError('must not read locale on success'),
      bootstrap: () async => const Directionality(
        textDirection: TextDirection.ltr,
        child: Text('hermes-ready'),
      ),
      run: (app) => tester.pumpWidget(app),
    );
    await tester.pump();

    expect(find.text('hermes-ready'), findsOneWidget);
    expect(find.byType(StartupFailureApp), findsNothing);
    expect(AppErrorLog.recent, isEmpty);
  });
}
