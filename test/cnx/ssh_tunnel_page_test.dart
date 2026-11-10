// SPDX-License-Identifier: GPL-3.0-only
// The SSH tab of Connect: Connect waits for what it needs, the server key is
// asked before anything else, each concrete failure shows its own words, and
// the Dashboard sign-in goes through the local end of the tunnel.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/onboarding/manual_connect_page.dart';
import 'package:hermes_android/core/screens/onboarding/onboarding_widgets.dart';
import 'package:hermes_android/core/services/native_password_login.dart';
import 'package:hermes_android/core/services/ssh_dashboard_tunnel.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_tunnel_connector.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import '../support/onboarding_fakes.dart';

const _publicKey =
    'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMDHdKnkEm4yKoupfcU/a8kGg03FD6W8w0cTKCEn5mS1 me@phone';
const _lockedKey = '''-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABCAQ4/lel
SBtqdfJMhQnslaAAAABAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIAcMJ65mib0cYrg3
wvznIkRJRzDi8+gZixMatGScEqmlAAAAkIaVa+DRCLcwADuOroT/cfqPHsQE70LDhaU9Zf
r1DOnJB8meSovvo7Y9B2T+/VcnjBwSrgdzMe408CqTQbXKWI1XBq8zyu2oF7YlZU/cXus6
QYxDGQt3qd32+NiaE5NI+6OQPH2Ya6l2yEyvXZAnomVzN6oOZyhgVrBiilc5yHlVqEqTsq
95UKQhIQF0FsZhXw==
-----END OPENSSH PRIVATE KEY-----''';

class _Opener implements SshTunnelOpener {
  final opened = <SshTunnelRequest>[];
  final discarded = <String>[];
  final persisted = <String>[];
  Future<int> Function(SshTunnelRequest, HostKeyDecision)? onOpen;

  @override
  Future<int> open(SshTunnelRequest request, HostKeyDecision onHostKey) {
    opened.add(request);
    return onOpen?.call(request, onHostKey) ?? Future.value(41234);
  }

  @override
  Future<void> persist(String id, {required bool remember}) async =>
      persisted.add(id);

  @override
  Future<void> discard(String id) async => discarded.add(id);

  @override
  VoidCallback hold(String id) => () {};
}

class _Launcher extends StatelessWidget {
  const _Launcher(this.page);

  final Widget page;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: TextButton(
        key: const ValueKey('launch'),
        onPressed: () => Navigator.of(
          context,
        ).push<bool>(MaterialPageRoute(builder: (_) => page)),
        child: const Text('open'),
      ),
    ),
  );
}

Future<void> _open(
  WidgetTester tester,
  _Opener opener, {
  Future<NativePasswordFailure?> Function(ConnectRequest)? connect,
  List<ConnectRequest>? seen,
}) async {
  await tester.pumpWidget(
    onboardingHost(
      _Launcher(
        ManualConnectPage(
          tunnels: opener,
          onHelp: () {},
          onScan: () {},
          connect: (r) async {
            seen?.add(r);
            return connect == null ? null : connect(r);
          },
        ),
      ),
      language: 'en',
    ),
  );
  await tester.tap(find.byKey(const ValueKey('launch')));
  await tester.pumpAndSettle();
  await _tap(tester, 'cnx-tab-ssh');
}

Strings _s(WidgetTester tester) =>
    Strings.of(tester.element(find.byType(ManualConnectPage)));

Future<void> _tap(WidgetTester tester, String key) async {
  final control = find.byKey(ValueKey(key));
  await tester.ensureVisible(control);
  await tester.tap(control);
  await tester.pumpAndSettle();
}

Future<void> _type(WidgetTester tester, String key, String text) async {
  await tester.enterText(find.byKey(ValueKey(key)), text);
  await tester.pump();
}

bool _canConnect(WidgetTester tester) =>
    tester
        .widget<OnbPrimary>(find.byKey(const ValueKey('manual-connect')))
        .onTap !=
    null;

Future<void> _fillPassword(WidgetTester tester) async {
  await _type(tester, 'cnx-ssh-host', 'srv.example.com');
  await _type(tester, 'cnx-ssh-user', 'root');
  await _type(tester, 'cnx-ssh-password', 'ssh-pw');
  await _type(tester, 'manual-user', 'owner');
  await _type(tester, 'manual-password', 'dash-pw');
}

void main() {
  testWidgets('Connect waits until nothing is missing', (tester) async {
    await _open(tester, _Opener());
    expect(_canConnect(tester), isFalse);
    await _type(tester, 'cnx-ssh-host', 'srv.example.com');
    await _type(tester, 'cnx-ssh-user', 'root');
    await _type(tester, 'cnx-ssh-password', 'ssh-pw');
    expect(_canConnect(tester), isFalse, reason: 'the sign-in is missing');
    await _type(tester, 'manual-user', 'owner');
    await _type(tester, 'manual-password', 'dash-pw');
    expect(_canConnect(tester), isTrue);

    await _type(tester, 'cnx-ssh-port', '0');
    expect(_canConnect(tester), isFalse);
    await _type(tester, 'cnx-ssh-port', '2222');
    expect(_canConnect(tester), isTrue);
    await _type(tester, 'cnx-dash-port', '70000');
    expect(_canConnect(tester), isFalse);
    await _type(tester, 'cnx-dash-port', '9119');
    await _type(tester, 'cnx-dash-host', '  ');
    expect(_canConnect(tester), isFalse);
  });

  testWidgets('the Browser sign-in needs no more than the SSH data', (
    tester,
  ) async {
    await _open(tester, _Opener());
    await _type(tester, 'cnx-ssh-host', 'srv.example.com');
    await _type(tester, 'cnx-ssh-user', 'root');
    await _type(tester, 'cnx-ssh-password', 'ssh-pw');
    await _tap(tester, 'cnx-method');
    await tester.tap(find.byKey(const ValueKey('cnx-method-browser')));
    await tester.pumpAndSettle();
    expect(_canConnect(tester), isTrue);
  });

  testWidgets('a public key is refused at once; an encrypted one asks', (
    tester,
  ) async {
    await _open(tester, _Opener());
    final s = _s(tester);
    await _type(tester, 'cnx-ssh-host', 'srv.example.com');
    await _type(tester, 'cnx-ssh-user', 'root');
    await _tap(tester, 'cnx-ssh-auth-key');
    await _type(tester, 'manual-user', 'owner');
    await _type(tester, 'manual-password', 'dash-pw');

    await _type(tester, 'cnx-ssh-key', _publicKey);
    expect(find.byKey(const ValueKey('cnx-ssh-key-public')), findsOneWidget);
    expect(find.text(s.sshTPublicKey), findsOneWidget);
    expect(_canConnect(tester), isFalse);

    await _type(tester, 'cnx-ssh-key', _lockedKey);
    expect(find.byKey(const ValueKey('cnx-ssh-key-public')), findsNothing);
    expect(find.byKey(const ValueKey('cnx-ssh-passphrase')), findsOneWidget);
    expect(find.text(s.sshTPassphraseNeeded), findsOneWidget);
    expect(_canConnect(tester), isFalse);

    await _type(tester, 'cnx-ssh-passphrase', 'fixture-phrase');
    expect(_canConnect(tester), isTrue);
  });

  testWidgets('a changed server key stops everything until confirmed', (
    tester,
  ) async {
    final opener = _Opener();
    final seen = <ConnectRequest>[];
    final answers = <bool>[];
    opener.onOpen = (request, ask) async {
      final ok = await ask(
        const SshHostKeyPrompt(
          type: 'ssh-ed25519',
          fingerprint: 'SHA256:changed',
          isNew: false,
          changed: true,
        ),
      );
      answers.add(ok);
      if (!ok) {
        throw const SshTunnelException(
          SshTunnelFailure.ssh,
          SshFailure.hostKeyRejected,
        );
      }
      return 41234;
    };
    await _open(tester, opener, seen: seen);
    final s = _s(tester);
    await _fillPassword(tester);

    await _tap(tester, 'manual-connect');
    expect(find.text(s.sshKeyChangedTitle), findsOneWidget);
    expect(find.text('SHA256:changed'), findsOneWidget);
    await tester.tap(find.text(s.commonCancel));
    await tester.pumpAndSettle();
    expect(answers, [false]);
    expect(seen, isEmpty, reason: 'no sign-in without a trusted server');
    expect(find.text(s.sshHostKeyRejected), findsOneWidget);

    await _tap(tester, 'manual-connect');
    await tester.tap(find.text(s.sshTrustAnyway));
    await tester.pumpAndSettle();
    expect(answers, [false, true]);
    expect(seen, hasLength(1));
  });

  testWidgets('each concrete failure shows its own words', (tester) async {
    final opener = _Opener();
    await _open(tester, opener);
    final s = _s(tester);
    await _fillPassword(tester);

    final cases = <SshTunnelException, String>{
      const SshTunnelException(SshTunnelFailure.dashboardRefused):
          s.sshTDashboardRefused,
      const SshTunnelException(SshTunnelFailure.otherAddress):
          s.sshTOtherAddress,
      const SshTunnelException(SshTunnelFailure.ssh, SshFailure.hostLookup):
          s.sshTServerNotFound,
      const SshTunnelException(SshTunnelFailure.ssh, SshFailure.authRejected):
          s.i18n1215SshAuthRejected,
      const SshTunnelException(
        SshTunnelFailure.ssh,
        SshFailure.wrongPassphrase,
      ): s.i18n1215SshWrongPassphrase,
    };
    for (final entry in cases.entries) {
      opener.onOpen = (request, ask) async => throw entry.key;
      await _tap(tester, 'manual-connect');
      expect(find.text(entry.value), findsOneWidget, reason: '${entry.key}');
      expect(_canConnect(tester), isTrue, reason: 'it can be tried again');
    }
  });

  testWidgets('the sign-in goes to the local end of the tunnel', (
    tester,
  ) async {
    final opener = _Opener();
    final seen = <ConnectRequest>[];
    await _open(tester, opener, seen: seen);
    await _fillPassword(tester);
    await _type(tester, 'cnx-dash-port', '9120');
    await _tap(tester, 'cnx-ssh-remember');
    await _tap(tester, 'manual-connect');

    final tunnel = opener.opened.single;
    expect(tunnel.host, 'srv.example.com');
    expect(tunnel.port, 22);
    expect(tunnel.username, 'root');
    expect(tunnel.method, SshAuthMethod.password);
    expect(tunnel.secret, 'ssh-pw');
    expect(tunnel.dashHost, '127.0.0.1');
    expect(tunnel.dashPort, 9120);
    expect(tunnel.remember, isTrue);

    final request = seen.single;
    expect(request.url, 'http://127.0.0.1:41234');
    expect(request.connectionId, tunnel.id);
    expect(request.tunnel?.sshHost, 'srv.example.com');
    expect(request.tunnel?.remember, isTrue);
    expect(request.name, 'srv.example.com', reason: 'named after the server');
    expect(request.user, 'owner');
    expect(request.secret, 'dash-pw');
    expect(request.method, ConnectMethod.password);
    expect(opener.discarded, isEmpty);
    expect(
      find.byType(ManualConnectPage),
      findsNothing,
      reason: 'it signed in',
    );
  });

  testWidgets('leaving without signing in closes the tunnel', (tester) async {
    final opener = _Opener();
    await _open(
      tester,
      opener,
      connect: (_) async => NativePasswordFailure.invalidCredentials,
    );
    final s = _s(tester);
    await _fillPassword(tester);
    await _tap(tester, 'manual-connect');
    expect(find.text(s.onb2WrongPassword), findsOneWidget);
    expect(opener.discarded, isEmpty, reason: 'kept for the next try');

    // A rejected Dashboard password is dropped; typing it again retries.
    await _type(tester, 'manual-password', 'dash-pw');
    await _tap(tester, 'manual-connect');
    expect(opener.opened, hasLength(2));
    expect(opener.opened.last.id, opener.opened.first.id);

    await tester.tap(find.byType(OnbBack));
    await tester.pumpAndSettle();
    expect(opener.discarded, [opener.opened.first.id]);
  });

  testWidgets('another login is another tunnel', (tester) async {
    final opener = _Opener();
    await _open(
      tester,
      opener,
      connect: (_) async => NativePasswordFailure.invalidCredentials,
    );
    await _fillPassword(tester);
    await _tap(tester, 'manual-connect');
    await _type(tester, 'cnx-dash-port', '9999');
    await _type(tester, 'manual-password', 'dash-pw');
    await _tap(tester, 'manual-connect');
    expect(opener.discarded, [opener.opened.first.id]);
  });
}
