// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hermes Console contributors
//
// The Nous Portal card: one state line per situation the server reports,
// the connect button only while there is something to connect, and a
// layout that holds at 2x in every language and theme.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/oauth_account.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/nous_account_card.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

OAuthAccount _nous({
  bool connected = false,
  bool freeTier = false,
  String tier = '',
  DateTime? expiresAt,
  bool refresh = false,
}) => OAuthAccount(
  id: 'nous',
  name: 'Nous Portal',
  flow: 'device_code',
  connected: connected,
  disconnectable: true,
  freeTier: freeTier,
  accountTier: tier,
  expiresAt: expiresAt,
  hasRefreshToken: refresh,
  docsUrl: 'https://portal.nousresearch.com',
  sourceLabel: 'https://portal.nousresearch.com',
);

Widget _app(
  Widget child, {
  Locale locale = const Locale('en'),
  ThemeData? theme,
  double textScale = 1,
  double width = 390,
}) => MaterialApp(
  locale: locale,
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: theme ?? AppTheme.hermesRedDark,
  builder: (context, c) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: c!,
  ),
  home: Scaffold(
    body: Center(
      child: SizedBox(
        width: width,
        child: ListView(children: [child]),
      ),
    ),
  ),
);

void main() {
  Finder key(String value) => find.byKey(ValueKey(value));
  String status(WidgetTester tester) =>
      tester.widget<Text>(key('nac-card-status')).data!;

  testWidgets('not connected: the state and the button', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _app(NousAccountCard(account: _nous(), onConnect: () => taps++)),
    );
    expect(status(tester), 'Not connected');
    expect(find.text('Connect with Nous Portal'), findsOneWidget);
    await tester.tap(key('nac-card-connect'));
    expect(taps, 1);
    expect(key('nac-card-manage'), findsNothing);
  });

  testWidgets('connected: tier, validity and the account menu', (tester) async {
    var manage = 0;
    await tester.pumpWidget(
      _app(
        NousAccountCard(
          account: _nous(
            connected: true,
            tier: 'pro',
            expiresAt: DateTime.now().toUtc().add(const Duration(days: 30)),
          ),
          onConnect: () {},
          onManage: () => manage++,
        ),
      ),
    );
    expect(status(tester), startsWith('Connected · Pro · valid until '));
    expect(key('nac-card-connect'), findsNothing);
    await tester.tap(key('nac-card-manage'));
    expect(manage, 1);
  });

  testWidgets('a credential the server renews shows no date', (tester) async {
    await tester.pumpWidget(
      _app(
        NousAccountCard(
          account: _nous(
            connected: true,
            tier: 'pro',
            expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
            refresh: true,
          ),
          onConnect: () {},
          onManage: () {},
        ),
      ),
    );
    expect(status(tester), 'Connected · Pro');
  });

  testWidgets('expired without a refresh token: reconnect', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _app(
        NousAccountCard(
          account: _nous(
            connected: true,
            expiresAt: DateTime.now().toUtc().subtract(
              const Duration(hours: 1),
            ),
          ),
          onConnect: () => taps++,
          onManage: () {},
        ),
      ),
    );
    expect(status(tester), 'Session expired, connect again');
    expect(find.text('Connect with Nous Portal'), findsOneWidget);
    expect(key('nac-card-manage'), findsNothing);
    await tester.tap(key('nac-card-connect'));
    expect(taps, 1);
  });

  testWidgets('the free tier is not an account', (tester) async {
    await tester.pumpWidget(
      _app(
        NousAccountCard(
          account: _nous(connected: true, freeTier: true),
          onConnect: () {},
          onManage: () {},
        ),
      ),
    );
    expect(status(tester), 'Free tier, no account');
    expect(key('nac-card-connect'), findsOneWidget);
    expect(key('nac-card-manage'), findsNothing);
  });

  testWidgets('a server without the card says so, with no button', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(const NousAccountCard(account: null, onConnect: null)),
    );
    expect(status(tester), 'Not available on this server');
    expect(key('nac-card-connect'), findsNothing);
  });

  testWidgets('disabled while the screen is busy', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _app(
        NousAccountCard(
          account: _nous(),
          onConnect: () => taps++,
          enabled: false,
        ),
      ),
    );
    await tester.tap(key('nac-card-connect'), warnIfMissed: false);
    expect(taps, 0);
  });

  group('fits every language, size, width and theme', () {
    final themes = <String, ThemeData>{
      'dark': AppTheme.hermesRedDark,
      'light': AppTheme.hermesRedLight,
      'midnight': AppTheme.fromId('midnight'),
    };
    for (final locale in Strings.supportedLocales) {
      for (final width in const [320.0, 1248.0]) {
        for (final theme in themes.entries) {
          if (width == 1248.0 && theme.key != 'dark') continue;
          testWidgets(
            '2x · ${locale.languageCode} · ${width.toInt()} dp · ${theme.key}',
            (tester) async {
              tester.view.physicalSize = Size(width, 1200);
              tester.view.devicePixelRatio = 1;
              addTearDown(tester.view.resetPhysicalSize);
              addTearDown(tester.view.resetDevicePixelRatio);
              for (final account in [
                _nous(),
                _nous(
                  connected: true,
                  tier: 'pro',
                  expiresAt: DateTime.utc(2026, 12, 24),
                ),
                null,
              ]) {
                await tester.pumpWidget(
                  _app(
                    NousAccountCard(
                      account: account,
                      onConnect: () {},
                      onManage: () {},
                    ),
                    locale: locale,
                    theme: theme.value,
                    textScale: 2,
                    width: width,
                  ),
                );
                await tester.pump();
                expect(tester.takeException(), isNull);
                expect(key('nac-card-status'), findsOneWidget);
              }
            },
          );
        }
      }
    }
  });
}
