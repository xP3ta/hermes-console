import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import 'app_error_log.dart';

/// Builds the root widget. Everything awaited before `runApp` lives here so a
/// throw can be surfaced instead of leaving the native splash up forever.
typedef StartupBootstrap = Future<Widget> Function();

/// Runs [bootstrap] and hands its widget to [run]. When it throws, [run]
/// receives a recovery screen instead; Retry runs [bootstrap] again and swaps
/// in the app once it succeeds. Nothing is deleted on failure: the steps
/// keep their own fail-closed storage policies.
Future<void> runGuardedStartup({
  required StartupBootstrap bootstrap,
  required FutureOr<void> Function(Widget app) run,
}) async {
  final Widget app;
  try {
    app = await bootstrap();
  } catch (error) {
    AppErrorLog.record('startup', error);
    await run(StartupFailureApp(bootstrap: bootstrap));
    return;
  }
  await run(app);
}

/// Runs a startup step whose failure can be degraded. Returns false (and logs
/// only the error type) when it throws.
Future<bool> tryStartupStep(Future<void> Function() step) async {
  try {
    await step();
    return true;
  } catch (error) {
    AppErrorLog.record('startup', error);
    return false;
  }
}

/// Minimal recovery surface shown when startup failed before the app existed.
class StartupFailureApp extends StatefulWidget {
  static const retryKey = ValueKey('startup-failure-retry');

  final StartupBootstrap bootstrap;

  const StartupFailureApp({required this.bootstrap, super.key});

  @override
  State<StartupFailureApp> createState() => _StartupFailureAppState();
}

class _StartupFailureAppState extends State<StartupFailureApp> {
  Widget? _app;
  bool _retrying = false;

  Future<void> _retry() async {
    if (_retrying) return;
    setState(() => _retrying = true);
    try {
      final app = await widget.bootstrap();
      if (!mounted) return;
      setState(() {
        _app = app;
        _retrying = false;
      });
    } catch (error) {
      AppErrorLog.record('startup', error);
      if (mounted) setState(() => _retrying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = _app;
    if (app != null) return app;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      localeResolutionCallback: (locale, _) => locale?.languageCode == 'es'
          ? const Locale('es')
          : const Locale('en'),
      home: Builder(
        builder: (context) {
          final strings = Strings.of(context);
          return Scaffold(
            body: SafeArea(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.error_outline_rounded, size: 48),
                      const SizedBox(height: 16),
                      Text(
                        strings.s1216StartupFailedTitle,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        strings.s1216StartupFailedBody,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 24),
                      FilledButton(
                        key: StartupFailureApp.retryKey,
                        onPressed: _retrying ? null : _retry,
                        child: Text(strings.s1216StartupRetry),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
