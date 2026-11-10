// SPDX-License-Identifier: GPL-3.0-only
// The connector: what a pasted key may be, what is kept on the phone and
// what comes back when the app starts again.
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/ssh_dashboard_tunnel.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_tunnel_connector.dart';
import 'package:hermes_android/core/utils/ssh_error.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import '../support/onboarding_fakes.dart';
import 'tunnel_fakes.dart';

// Throwaway keys made for these tests; they open nothing.
const _plainKey = '''-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACDAx3Sp5BJuMiqLqX3FP2vJBoNNxQ+lvMNHEyghJ+ZktQAAAIgSLIe2EiyH
tgAAAAtzc2gtZWQyNTUxOQAAACDAx3Sp5BJuMiqLqX3FP2vJBoNNxQ+lvMNHEyghJ+ZktQ
AAAEDkqeSBOhVgocthlebnvS6GteWJ+ruw4b/lo4AnoWTSiMDHdKnkEm4yKoupfcU/a8kG
g03FD6W8w0cTKCEn5mS1AAAAAAECAwQF
-----END OPENSSH PRIVATE KEY-----''';

const _lockedKey = '''-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABCAQ4/lel
SBtqdfJMhQnslaAAAABAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIAcMJ65mib0cYrg3
wvznIkRJRzDi8+gZixMatGScEqmlAAAAkIaVa+DRCLcwADuOroT/cfqPHsQE70LDhaU9Zf
r1DOnJB8meSovvo7Y9B2T+/VcnjBwSrgdzMe408CqTQbXKWI1XBq8zyu2oF7YlZU/cXus6
QYxDGQt3qd32+NiaE5NI+6OQPH2Ya6l2yEyvXZAnomVzN6oOZyhgVrBiilc5yHlVqEqTsq
95UKQhIQF0FsZhXw==
-----END OPENSSH PRIVATE KEY-----''';

const _lockedPhrase = 'fixture-phrase';

const _publicKey =
    'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMDHdKnkEm4yKoupfcU/a8kGg03FD6W8w0cTKCEn5mS1 me@phone';

SshTunnelRequest _request({
  String id = 'c1',
  SshAuthMethod method = SshAuthMethod.password,
  String secret = 'pw',
  String passphrase = '',
  bool remember = false,
  int dashPort = 9119,
}) => SshTunnelRequest(
  id: id,
  host: 'srv.example.com',
  port: 22,
  username: 'root',
  method: method,
  secret: secret,
  passphrase: passphrase,
  dashHost: '127.0.0.1',
  dashPort: dashPort,
  remember: remember,
);

Matcher _fails(SshTunnelFailure failure, [SshFailure? ssh]) => throwsA(
  isA<SshTunnelException>()
      .having((e) => e.failure, 'failure', failure)
      .having((e) => e.ssh, 'ssh', ssh),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ConnectionManager connections;
  late SshManager manager;
  late TunnelRig rig;
  late SshDashboardTunnels tunnels;
  late SshTunnelConnector connector;

  SshTunnelConnector build() {
    tunnels = rig.tunnels();
    return SshTunnelConnector(
      tunnels: tunnels,
      manager: manager,
      connections: connections,
    );
  }

  setUp(() async {
    connections = await onboardingManager();
    manager = SshManager(SecureStorage(), connections);
    rig = TunnelRig();
    connector = build();
  });

  group('keys', () {
    test('a public key is told apart before anything is sent', () async {
      expect(checkSshKey(_publicKey, ''), SshKeyState.publicKey);
      expect(checkSshKey('  $_publicKey', ''), SshKeyState.publicKey);
      await expectLater(
        connector.open(
          _request(method: SshAuthMethod.key, secret: _publicKey),
          trustAll,
        ),
        _fails(SshTunnelFailure.publicKey),
      );
      expect(rig.clients, isEmpty);
    });

    test('an encrypted key asks for its passphrase', () async {
      expect(checkSshKey(_lockedKey, ''), SshKeyState.needsPassphrase);
      await expectLater(
        connector.open(
          _request(method: SshAuthMethod.key, secret: _lockedKey),
          trustAll,
        ),
        _fails(SshTunnelFailure.passphraseNeeded),
      );
    });

    test('a wrong passphrase is a clear error, the right one opens', () async {
      await expectLater(
        connector.open(
          _request(
            method: SshAuthMethod.key,
            secret: _lockedKey,
            passphrase: 'not-it',
          ),
          trustAll,
        ),
        _fails(SshTunnelFailure.ssh, SshFailure.wrongPassphrase),
      );
      final port = await connector.open(
        _request(
          method: SshAuthMethod.key,
          secret: _lockedKey,
          passphrase: _lockedPhrase,
        ),
        trustAll,
      );
      expect(port, greaterThan(0));
      expect(
        rig.clients.single.forwards,
        isNotEmpty,
        reason: 'the Dashboard was probed',
      );
      await tunnels.closeAll();
    });

    test('a plain private key is ready', () {
      expect(checkSshKey(_plainKey, ''), SshKeyState.ready);
      expect(checkSshKey('', ''), SshKeyState.empty);
      expect(checkSshKey('not a key', ''), SshKeyState.invalid);
    });
  });

  group('messages', () {
    test('every concrete failure has its own words in every language', () {
      const langs = ['es', 'en', 'pt', 'de', 'fr', 'it', 'ja', 'ko', 'zh'];
      for (final lang in langs) {
        final s = lookupStrings(Locale(lang));
        final texts = <String>{
          for (final f in SshTunnelFailure.values)
            localizedTunnelError(s, SshTunnelException(f)),
          localizedTunnelError(
            s,
            const SshTunnelException(
              SshTunnelFailure.ssh,
              SshFailure.hostLookup,
            ),
          ),
          localizedTunnelError(
            s,
            const SshTunnelException(
              SshTunnelFailure.ssh,
              SshFailure.authRejected,
            ),
          ),
          localizedTunnelError(
            s,
            const SshTunnelException(
              SshTunnelFailure.ssh,
              SshFailure.wrongPassphrase,
            ),
          ),
        };
        expect(texts.every((t) => t.trim().isNotEmpty), isTrue, reason: lang);
        expect(texts, hasLength(SshTunnelFailure.values.length + 3));
      }
      final es = lookupStrings(const Locale('es'));
      expect(
        localizedTunnelError(
          es,
          const SshTunnelException(SshTunnelFailure.dashboardRefused),
        ),
        contains('no abrió la conexión al dashboard'),
      );
    });
  });

  group('what stays on the phone', () {
    test('the password is kept only when asked', () async {
      await connector.open(_request(), trustAll);
      await connector.persist('c1', remember: false);
      expect((await manager.loadCredentials('c1')).password, isNull);
      expect((await manager.loadConfig('c1'))?.host, 'srv.example.com');
      final target = await manager.loadTunnelTarget('c1');
      expect((target?.host, target?.port), ('127.0.0.1', 9119));

      await connector.open(_request(id: 'c2', remember: true), trustAll);
      await connector.persist('c2', remember: true);
      expect((await manager.loadCredentials('c2')).password, 'pw');
      await tunnels.closeAll();
    });

    test('the server key is kept per server, not per connection', () async {
      await manager.saveFingerprint(
        SshManager.serverScope('SRV.example.com', 22),
        'SHA256:abc',
      );
      expect(
        await manager.knownFingerprint(
          SshManager.serverScope('srv.example.com', 22),
        ),
        'SHA256:abc',
      );
      expect(await manager.knownFingerprint('c1'), isNull);
    });
  });

  group('after a restart', () {
    Future<void> saveConnection({int port = 43111}) async {
      await connections.upsertConnection(
        SavedConnection(
          id: 'c1',
          label: 'srv',
          host: '127.0.0.1',
          port: port,
          apiKey: '',
          dashboardUrl: 'http://127.0.0.1:$port',
          onDeviceLoopback: true,
        ),
      );
    }

    test('the saved tunnel comes back on the saved port', () async {
      await saveConnection();
      await connector.open(_request(remember: true), trustAll);
      await connector.persist('c1', remember: true);
      await tunnels.closeAll();

      rig = TunnelRig();
      connector = build();
      await connector.ensureActive('c1');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(tunnels.portOf('c1'), 43111);
      expect(rig.preferred, [43111]);
      await tunnels.closeAll();
    });

    test('nothing is sent without the password that was not kept', () async {
      await saveConnection();
      await connector.open(_request(), trustAll);
      await connector.persist('c1', remember: false);
      await tunnels.closeAll();

      rig = TunnelRig();
      connector = build();
      await connector.ensureActive('c1');
      expect(tunnels.has('c1'), isFalse);
      expect(rig.clients, isEmpty);
    });

    test('a connection that is not a tunnel is left alone', () async {
      await saveConnection();
      await connector.ensureActive('c1');
      expect(tunnels.has('c1'), isFalse);
    });

    test('another local port rewrites the saved address', () async {
      await saveConnection();
      await connector.portChanged('c1', 44222);
      final saved = connections.getConnections().single;
      expect(saved.dashboardUrl, 'http://127.0.0.1:44222');
      expect(saved.port, 44222);
    });

    test(
      'switching connections closes the saved tunnels of the old one',
      () async {
        await saveConnection();
        await connector.open(_request(remember: true), trustAll);
        await connector.persist('c1', remember: true);
        await connector.ensureActive('other');
        expect(tunnels.has('c1'), isFalse);
      },
    );
  });

  test('discarding a tunnel clears everything it kept', () async {
    await connector.open(_request(remember: true), trustAll);
    await connector.persist('c1', remember: true);
    await connector.discard('c1');
    expect(tunnels.has('c1'), isFalse);
    expect(await manager.loadConfig('c1'), isNull);
    expect(await manager.loadTunnelTarget('c1'), isNull);
  });
}
