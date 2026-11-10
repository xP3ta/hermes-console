// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hermes Console contributors
//
// The device-code page: the code is shown large and copied on tap, the
// provider's page opens in the system browser only on an allowed host, the
// wait pauses in the background and checks once on return, every verdict
// is localized without server text, and closing leaves no timer.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/provider_account_link.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/account_link_screen.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

/// A Dashboard reduced to the three calls of the flow.
class _Fake {
  _Fake({
    this.url = 'https://portal.nousresearch.com/device?user_code=HRMS-2026',
  });

  final String userCode = 'HRMS-2026';
  String url;
  final int expiresIn = 600;
  Object? startError;
  Map<String, dynamic> pollBody = {'status': 'pending'};
  Object? pollError;
  int starts = 0;
  int polls = 0;
  final cancelled = <String>[];
  int sessions = 0;

  ProviderAccountLink link({bool readOnly = false, DateTime Function()? now}) =>
      ProviderAccountLink(
        providerId: 'nous',
        readOnly: readOnly,
        policy: AccountLinkUrlPolicy.nous,
        now: now,
        start: () async {
          starts++;
          if (startError case final error?) throw error;
          return {
            'session_id': 'synthetic-session-${++sessions}',
            'flow': 'device_code',
            'user_code': userCode,
            'verification_url': url,
            'expires_in': expiresIn,
            'poll_interval': 5,
          };
        },
        poll: (_) async {
          polls++;
          if (pollError case final error?) throw error;
          return pollBody;
        },
        cancelSession: (sid) async => cancelled.add(sid),
        disconnect: () async {},
      );
}

Widget _app(
  Widget home, {
  Locale locale = const Locale('en'),
  ThemeData? theme,
  double textScale = 1,
}) => MaterialApp(
  locale: locale,
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: theme ?? AppTheme.hermesRedDark,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: child!,
  ),
  home: home,
);

Future<void> _close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

void main() {
  late List<MethodCall> clipboard;
  setUp(() {
    clipboard = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          clipboard.add(call);
          return null;
        });
  });

  Finder key(String value) => find.byKey(ValueKey(value));

  testWidgets('the page opens the provider once and shows the code large', (
    tester,
  ) async {
    final fake = _Fake();
    final opened = <Uri>[];
    await tester.pumpWidget(
      _app(
        AccountLinkScreen(
          link: fake.link(),
          providerName: 'Nous Portal',
          openUrl: (uri) async {
            opened.add(uri);
            return true;
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(fake.starts, 1);
    expect(opened.map((u) => u.toString()), [fake.url]);
    expect(find.text('HRMS-2026'), findsOneWidget);
    expect(
      tester.widget<Text>(key('nac-link-code-text')).style!.fontSize,
      greaterThanOrEqualTo(28),
    );
    expect(find.text('Open again'), findsOneWidget);
    expect(find.textContaining('The code expires in '), findsOneWidget);

    await tester.tap(key('nac-link-code'));
    await tester.pump();
    final copied = clipboard.where((c) => c.method == 'Clipboard.setData');
    expect(copied.single.arguments, {'text': 'HRMS-2026'});

    await tester.tap(key('nac-link-open'));
    await tester.pump();
    expect(opened, hasLength(2));
    await _close(tester);
  });

  testWidgets('a page off the provider\'s hosts is never launched', (
    tester,
  ) async {
    final fake = _Fake(url: 'https://evil.example.test/device');
    var launched = false;
    await tester.pumpWidget(
      _app(
        AccountLinkScreen(
          link: fake.link(),
          providerName: 'Nous Portal',
          openUrl: (_) async => launched = true,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(launched, isFalse);
    expect(key('nac-link-open'), findsNothing);
    expect(
      find.text('Open Nous Portal in a browser and enter this code:'),
      findsOneWidget,
    );
    expect(find.text('HRMS-2026'), findsOneWidget);
    // The address is there to read and copy, never a button.
    expect(
      tester.widget<SelectableText>(key('nac-link-address-text')).data,
      'https://evil.example.test/device',
    );
    await tester.ensureVisible(key('nac-link-copy-address'));
    await tester.tap(key('nac-link-copy-address'));
    await tester.pump();
    final copied = clipboard.where((c) => c.method == 'Clipboard.setData');
    expect(copied.single.arguments, {
      'text': 'https://evil.example.test/device',
    });
    expect(launched, isFalse);
    await _close(tester);
  });

  testWidgets('a Nous page on a subdomain opens; plain http does not', (
    tester,
  ) async {
    for (final (url, opens) in [
      ('https://auth.nousresearch.com/device?code=HRMS-2026', true),
      ('http://portal.nousresearch.com/device', false),
      ('https://nousresearch.com.example.test/device', false),
    ]) {
      final fake = _Fake(url: url);
      final opened = <Uri>[];
      await tester.pumpWidget(
        _app(
          AccountLinkScreen(
            link: fake.link(),
            providerName: 'Nous Portal',
            openUrl: (uri) async {
              opened.add(uri);
              return true;
            },
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(opened.isNotEmpty, opens, reason: url);
      expect(key('nac-link-open'), opens ? findsOneWidget : findsNothing);
      await _close(tester);
    }
  });

  testWidgets('approval pops true and names the account', (tester) async {
    final fake = _Fake();
    bool? result;
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => TextButton(
            key: const ValueKey('go'),
            onPressed: () async {
              result = await Navigator.of(context).push<bool>(
                MaterialPageRoute(
                  builder: (_) => AccountLinkScreen(
                    link: fake.link(),
                    providerName: 'Nous Portal',
                    openUrl: (_) async => true,
                  ),
                ),
              );
            },
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(key('go'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    fake.pollBody = {'status': 'approved', 'account_email': 'me@example.test'};
    await tester.tap(key('nac-link-check'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Nous Portal connected'), findsOneWidget);
    expect(find.text('Connected as me@example.test'), findsOneWidget);
    await tester.tap(key('nac-link-done'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(result, isTrue);
    await _close(tester);
  });

  testWidgets('polling pauses in the background and checks once on return', (
    tester,
  ) async {
    final fake = _Fake();
    final link = fake.link();
    await tester.pumpWidget(
      _app(
        AccountLinkScreen(
          link: link,
          providerName: 'Nous Portal',
          openUrl: (_) async => true,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 7));
    final before = fake.polls;
    expect(before, greaterThanOrEqualTo(1));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(link.hasTimer, isFalse);
    await tester.pump(const Duration(seconds: 30));
    expect(fake.polls, before, reason: 'nothing asked while hidden');
    fake.pollBody = {'status': 'approved'};
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(fake.polls, before + 1);
    expect(find.text('Nous Portal connected'), findsOneWidget);
    expect(link.hasTimer, isFalse);
    await _close(tester);
  });

  testWidgets('closing while waiting cancels the session on the server', (
    tester,
  ) async {
    final fake = _Fake();
    final link = fake.link();
    bool? result;
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => TextButton(
            key: const ValueKey('go'),
            onPressed: () async {
              result = await Navigator.of(context).push<bool>(
                MaterialPageRoute(
                  builder: (_) => AccountLinkScreen(
                    link: link,
                    providerName: 'Nous Portal',
                    openUrl: (_) async => true,
                  ),
                ),
              );
            },
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(key('go'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(link.hasTimer, isTrue);
    await tester.tap(key('nac-link-cancel'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(result, isFalse);
    expect(fake.cancelled, ['synthetic-session-1']);
    expect(link.hasTimer, isFalse);
    await _close(tester);
  });

  group('verdicts are localized and carry no server text', () {
    const cases = <String, Map<String, dynamic>>{
      'Access declined': {'status': 'denied'},
      'The code has expired': {
        'status': 'error',
        'reason': 'timeout',
        'error_message': 'RAW SERVER TEXT',
      },
      'Sign-in cancelled': {'status': 'cancelled'},
      'Sign-in did not finish': {
        'status': 'error',
        'reason': 'anon_rate_limited',
        'retryable': true,
        'retry_after': 120,
        'error_message': 'RAW SERVER TEXT',
      },
    };
    for (final entry in cases.entries) {
      testWidgets(entry.key, (tester) async {
        final fake = _Fake();
        await tester.pumpWidget(
          _app(
            AccountLinkScreen(
              link: fake.link(),
              providerName: 'Nous Portal',
              openUrl: (_) async => true,
            ),
          ),
        );
        await tester.pump();
        await tester.pump();
        fake.pollBody = entry.value;
        await tester.tap(key('nac-link-check'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text(entry.key), findsOneWidget);
        expect(find.textContaining('RAW SERVER TEXT'), findsNothing);
        if (entry.value['retry_after'] != null) {
          expect(
            find.text('The service asks for a pause. Try again in 2 min.'),
            findsOneWidget,
          );
        }
        expect(key('nac-link-retry'), findsOneWidget);
        // Try again starts a new session.
        fake.pollBody = {'status': 'pending'};
        await tester.tap(key('nac-link-retry'));
        await tester.pump();
        await tester.pump();
        expect(fake.starts, 2);
        expect(find.text('HRMS-2026'), findsOneWidget);
        await _close(tester);
      });
    }

    testWidgets('a failure the server calls final still offers a new code', (
      tester,
    ) async {
      final fake = _Fake();
      await tester.pumpWidget(
        _app(
          AccountLinkScreen(
            link: fake.link(),
            providerName: 'Nous Portal',
            openUrl: (_) async => true,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      fake.pollBody = {
        'status': 'error',
        'reason': 'anon_gate_closed',
        'retryable': false,
      };
      await tester.tap(key('nac-link-check'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.text('This server cannot complete the sign-in right now.'),
        findsOneWidget,
      );
      // A refusal in the browser arrives the same way: a fresh code is
      // always offered.
      expect(key('nac-link-retry'), findsOneWidget);
      expect(key('nac-link-verdict-close'), findsOneWidget);
      await _close(tester);
    });

    testWidgets('a read-only link never starts', (tester) async {
      final fake = _Fake();
      await tester.pumpWidget(
        _app(
          AccountLinkScreen(
            link: fake.link(readOnly: true),
            providerName: 'Nous Portal',
            openUrl: (_) async => true,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(fake.starts, 0);
      expect(find.text('Read-only connection'), findsOneWidget);
      expect(key('nac-link-retry'), findsNothing);
      await _close(tester);
    });
  });

  group('fits every language, size and theme', () {
    final themes = <String, ThemeData>{
      'dark': AppTheme.hermesRedDark,
      'light': AppTheme.hermesRedLight,
      'midnight': AppTheme.fromId('midnight'),
      'midnight-light': AppTheme.fromId('midnight-light'),
    };
    for (final locale in Strings.supportedLocales) {
      for (final scale in const [1.0, 2.0]) {
        for (final theme in themes.entries) {
          if (scale == 1.0 && theme.key != 'dark') continue;
          testWidgets(
            'waiting and verdict · ${locale.languageCode} · ${scale}x · ${theme.key}',
            (tester) async {
              tester.view.physicalSize = const Size(320, 900);
              tester.view.devicePixelRatio = 1;
              addTearDown(tester.view.resetPhysicalSize);
              addTearDown(tester.view.resetDevicePixelRatio);
              final fake = _Fake();
              await tester.pumpWidget(
                _app(
                  AccountLinkScreen(
                    link: fake.link(),
                    providerName: 'Nous Portal',
                    openUrl: (_) async => true,
                  ),
                  locale: locale,
                  theme: theme.value,
                  textScale: scale,
                ),
              );
              await tester.pump();
              await tester.pump();
              expect(tester.takeException(), isNull);
              expect(key('nac-link-waiting'), findsOneWidget);
              fake.pollBody = {'status': 'denied'};
              // At 2x the button sits below the fold: scroll to it first.
              await tester.ensureVisible(key('nac-link-check'));
              await tester.pump();
              await tester.tap(key('nac-link-check'));
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 300));
              expect(tester.takeException(), isNull);
              expect(key('nac-link-verdict'), findsOneWidget);
              await _close(tester);
            },
          );
        }
      }
    }
  });
}
