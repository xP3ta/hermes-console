// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hermes Console contributors
//
// The Nous door reads a copied agent address back: only a Nous Cloud host is
// taken, whatever else the clipboard holds.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/onboarding/manual_connect_page.dart';
import 'package:hermes_android/core/screens/onboarding/onboarding_widgets.dart';
import 'package:hermes_android/core/services/dashboard_address.dart';
import 'package:hermes_android/core/widgets/animated_hermes_logo.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import 'support/onboarding_fakes.dart';

class _Browser extends UrlLauncherPlatform {
  final opened = <String>[];

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    opened.add(url);
    return true;
  }
}

Future<void> _open(
  WidgetTester tester, {
  String language = 'es',
  String theme = 'dark',
  double scale = 1,
  ValueChanged<ConnectRequest>? onConnect,
}) async {
  tester.view.physicalSize = const Size(320, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    onboardingHost(
      ManualConnectPage(
        way: ConnectWay.nous,
        onHelp: () {},
        onScan: () {},
        connect: (request) async {
          onConnect?.call(request);
          return null;
        },
        probe: (_) async => const HostProbeResult(HostVerdict.silent),
      ),
      language: language,
      theme: theme,
      scale: scale,
    ),
  );
  await tester.pumpAndSettle();
}

OnbPrimary _connectButton(WidgetTester tester) =>
    tester.widget(find.byKey(const ValueKey('manual-connect')));

void _clipboard(String? text, {bool fail = false}) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.getData') {
          if (fail) throw PlatformException(code: 'unavailable');
          return text == null ? null : {'text': text};
        }
        return null;
      });
  addTearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null),
  );
}

_Browser _browser() {
  final previous = UrlLauncherPlatform.instance;
  final browser = _Browser();
  UrlLauncherPlatform.instance = browser;
  addTearDown(() => UrlLauncherPlatform.instance = previous);
  return browser;
}

Future<void> _returnFromPortal(WidgetTester tester) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Nous starts with a centred still logo and a manual entry link', (
    tester,
  ) async {
    await _open(tester);
    final logo = find.byKey(const ValueKey('manual-nous-logo'));
    final mark = tester.widget<AnimatedHermesLogo>(logo);
    expect(mark.animate, isFalse);
    expect(mark.orbit, isFalse);
    expect(mark.glow, isFalse);
    expect(mark.size, inInclusiveRange(72, 88));
    expect(tester.getCenter(logo).dx, 160);
    expect(find.byKey(const ValueKey('manual-address')), findsNothing);
    expect(find.byKey(const ValueKey('manual-nous-paste')), findsNothing);
    expect(find.byKey(const ValueKey('manual-nous-waiting')), findsNothing);
    expect(_connectButton(tester).onTap, isNull);
    final link = find.byKey(const ValueKey('manual-nous-write-address'));
    expect(tester.getSize(link).height, greaterThanOrEqualTo(48));
    final s = Strings.of(tester.element(find.byType(ManualConnectPage)));
    expect(find.text(s.nacNousWriteAddress), findsOneWidget);
    await tapOnboarding(tester, 'manual-nous-write-address');
    expect(find.byKey(const ValueKey('manual-address')), findsOneWidget);
    expect(find.byKey(const ValueKey('manual-nous-paste')), findsOneWidget);
    expect(_connectButton(tester).onTap, isNull);
    await tester.enterText(
      find.byKey(const ValueKey('manual-address')),
      'https://',
    );
    await tester.pumpAndSettle();
    expect(_connectButton(tester).onTap, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a copied address enables the existing browser connection flow', (
    tester,
  ) async {
    final browser = _browser();
    _clipboard('My agent: https://mine.agents.nousresearch.com/dashboard');
    ConnectRequest? sent;
    await _open(tester, onConnect: (request) => sent = request);
    await tapOnboarding(tester, 'manual-nous-portal');
    expect(browser.opened, ['https://portal.nousresearch.com/agents']);
    final s = Strings.of(tester.element(find.byType(ManualConnectPage)));
    expect(find.text(s.nacNousWaitingAddress), findsOneWidget);
    expect(_connectButton(tester).onTap, isNull);
    await _returnFromPortal(tester);
    expect(find.byKey(const ValueKey('manual-nous-waiting')), findsNothing);
    expect(find.byKey(const ValueKey('manual-address')), findsNothing);
    expect(
      find.byKey(const ValueKey('manual-nous-paste-failed')),
      findsNothing,
    );
    expect(_connectButton(tester).onTap, isNotNull);
    await tapOnboarding(tester, 'manual-connect');
    expect(sent?.url, 'https://mine.agents.nousresearch.com');
    expect(sent?.method, ConnectMethod.browser);
    expect(tester.takeException(), isNull);
  });

  for (final (name, text, fail) in [
    ('empty', '', false),
    ('missing', null, false),
    ('unrelated', 'https://example.com', false),
    ('unavailable', null, true),
  ]) {
    testWidgets('an $name clipboard reveals manual entry after returning', (
      tester,
    ) async {
      _browser();
      _clipboard(text, fail: fail);
      await _open(tester);
      // A resume unrelated to the portal must not expose the fallback.
      await _returnFromPortal(tester);
      expect(find.byKey(const ValueKey('manual-address')), findsNothing);
      await tapOnboarding(tester, 'manual-nous-portal');
      await _returnFromPortal(tester);
      expect(find.byKey(const ValueKey('manual-nous-waiting')), findsNothing);
      expect(find.byKey(const ValueKey('manual-address')), findsOneWidget);
      expect(find.byKey(const ValueKey('manual-nous-paste')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('manual-nous-paste-failed')),
        findsOneWidget,
      );
      expect(_connectButton(tester).onTap, isNull);
      await tester.enterText(
        find.byKey(const ValueKey('manual-address')),
        'mine.agents.nousresearch.com',
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('manual-nous-paste-failed')),
        findsNothing,
      );
      expect(_connectButton(tester).onTap, isNotNull);
      expect(tester.takeException(), isNull);
    });
  }

  for (final language in [
    'es',
    'en',
    'pt',
    'de',
    'fr',
    'it',
    'ja',
    'ko',
    'zh',
  ]) {
    for (final theme in ['dark', 'light', 'midnight', 'midnight-light']) {
      testWidgets('$language/$theme: Nous fits at 320 dp with 2x text', (
        tester,
      ) async {
        _clipboard('');
        await _open(tester, language: language, theme: theme, scale: 2);
        expect(find.byKey(const ValueKey('manual-nous-logo')), findsOneWidget);
        await tapOnboarding(tester, 'manual-nous-write-address');
        expect(find.byKey(const ValueKey('manual-address')), findsOneWidget);
        expect(
          tester.getSize(find.byKey(const ValueKey('manual-connect'))).height,
          greaterThanOrEqualTo(48),
        );
        await tapOnboarding(tester, 'manual-nous-paste');
        expect(
          find.byKey(const ValueKey('manual-nous-paste-failed')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      });
    }
  }

  test('a Nous Cloud host is found in a URL, a bare host or a sentence', () {
    expect(
      ManualConnectPageHosts.nousCloudHostIn(
        'https://Ana-Lab.agents.nousresearch.com/dashboard?x=1',
      ),
      'ana-lab.agents.nousresearch.com',
    );
    expect(
      ManualConnectPageHosts.nousCloudHostIn('ana.agents.nousresearch.com'),
      'ana.agents.nousresearch.com',
    );
    expect(
      ManualConnectPageHosts.nousCloudHostIn(
        'mi agente: https://ana.agents.nousresearch.com y más',
      ),
      'ana.agents.nousresearch.com',
    );
  });

  test('anything else is left alone', () {
    for (final text in [
      '',
      'hola',
      'https://example.com',
      'https://agents.nousresearch.com',
      'https://evil.com/?u=ana.agents.nousresearch.com.evil.com',
      'https://portal.nousresearch.com/agents',
    ]) {
      expect(
        ManualConnectPageHosts.nousCloudHostIn(text),
        isNull,
        reason: text,
      );
    }
  });
}
