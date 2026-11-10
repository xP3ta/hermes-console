// SPDX-License-Identifier: GPL-3.0-only
// The Dashboard tunnel with fakes: bytes both ways, closing, limits, a
// changed server key, the Dashboard refusing, and suspending in the
// background and coming back.
import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/ssh_dashboard_tunnel.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';

import 'tunnel_fakes.dart';

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  late TunnelRig rig;

  setUp(() => rig = TunnelRig());

  group('bytes', () {
    test('travel both ways between the phone and the Dashboard', () async {
      final tunnels = rig.tunnels();
      final port = await tunnels.open(fakeSpec(), onHostKey: trustAll);
      expect(port, 41000);
      final local = rig.servers.single.accept();
      await _settle();
      final remote = rig.clients.single.remotes.last;
      expect(rig.clients.single.forwards.last, ('127.0.0.1', 9119));

      local.emit([1, 2, 3]);
      remote.emit([9, 8]);
      await _settle();
      expect(remote.sent, [1, 2, 3]);
      expect(local.sent, [9, 8]);
      await tunnels.closeAll();
    });

    test('a side that ends closes the other and frees its slot', () async {
      final tunnels = rig.tunnels();
      await tunnels.open(fakeSpec(), onHostKey: trustAll);
      final local = rig.servers.single.accept();
      await _settle();
      final remote = rig.clients.single.remotes.last;

      local.finish();
      await _settle();
      expect(remote.writeClosed, isTrue);
      remote.finish();
      await _settle();
      expect(local.writeClosed, isTrue);
      expect(local.destroyed && remote.destroyed, isTrue);
      await tunnels.closeAll();
    });

    test('a half-open pair is dropped after the grace', () async {
      final tunnels = rig.tunnels();
      await tunnels.open(fakeSpec(), onHostKey: trustAll);
      final local = rig.servers.single.accept();
      await _settle();
      final remote = rig.clients.single.remotes.last;

      local.finish();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(remote.destroyed, isTrue);
      await tunnels.closeAll();
    });

    test('connections beyond the limit are dropped at once', () async {
      final tunnels = rig.tunnels(
        limits: const TunnelLimits(maxConnections: 2),
      );
      await tunnels.open(fakeSpec(), onHostKey: trustAll);
      final a = rig.servers.single.accept();
      final b = rig.servers.single.accept();
      final c = rig.servers.single.accept();
      await _settle();
      expect(c.destroyed, isTrue);
      expect(a.destroyed || b.destroyed, isFalse);
      await tunnels.closeAll();
    });

    test('a Dashboard that never answers does not hold the socket', () async {
      final tunnels = rig.tunnels();
      await tunnels.open(fakeSpec(), onHostKey: trustAll);
      rig.clients.single.stall = Completer<void>();
      final local = rig.servers.single.accept();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(local.destroyed, isTrue);
      await tunnels.closeAll();
    });
  });

  group('opening', () {
    test('only the loopback listener is ever asked for', () async {
      // The real factory binds InternetAddress.loopbackIPv4 and nothing else.
      final a = await bindLoopbackTunnelServer(null);
      expect(a.port, greaterThan(0));
      final b = await bindLoopbackTunnelServer(a.port);
      expect(b.port, isNot(a.port), reason: 'a taken port gives another one');
      final probe = await Socket.connect(InternetAddress.loopbackIPv4, a.port);
      final end = await a.connections.first;
      expect(end, isNotNull);
      probe.destroy();
      await a.close();
      await b.close();
    });

    test('a Dashboard the server cannot reach is named, not generic', () async {
      rig.forwardError = SSHChannelOpenError(2, 'Connection refused');
      final tunnels = rig.tunnels();
      await expectLater(
        tunnels.open(fakeSpec(), onHostKey: trustAll),
        throwsA(
          isA<SshTunnelException>().having(
            (e) => e.failure,
            'failure',
            SshTunnelFailure.dashboardRefused,
          ),
        ),
      );
      expect(tunnels.has('c1'), isFalse);
      expect(rig.servers, isEmpty, reason: 'no listener for a dead target');
      expect(rig.clients.single.closed, isTrue);
    });

    test('a changed server key blocks until it is confirmed', () async {
      rig.prompt = const SshHostKeyPrompt(
        type: 'ssh-ed25519',
        fingerprint: 'SHA256:new',
        isNew: false,
        changed: true,
      );
      final tunnels = rig.tunnels();
      SshHostKeyPrompt? shown;
      await expectLater(
        tunnels.open(
          fakeSpec(),
          onHostKey: (p) async {
            shown = p;
            return false;
          },
        ),
        throwsA(
          isA<SshTunnelException>()
              .having((e) => e.failure, 'failure', SshTunnelFailure.ssh)
              .having((e) => e.ssh, 'ssh', SshFailure.hostKeyRejected),
        ),
      );
      expect(shown?.changed, isTrue);
      expect(rig.servers, isEmpty);

      // Confirmed by the person: it opens.
      await tunnels.open(fakeSpec(), onHostKey: trustAll);
      expect(tunnels.has('c1'), isTrue);
      await tunnels.closeAll();
    });

    test('the same login and Dashboard reuses the open tunnel', () async {
      final tunnels = rig.tunnels();
      final a = await tunnels.open(fakeSpec(), onHostKey: trustAll);
      final b = await tunnels.open(fakeSpec(), onHostKey: trustAll);
      expect(b, a);
      expect(rig.clients, hasLength(1));
      await tunnels.closeAll();
    });

    test('another Dashboard address on a tunnel in use is refused', () async {
      final tunnels = rig.tunnels();
      await tunnels.open(fakeSpec(), onHostKey: trustAll);
      await expectLater(
        tunnels.open(fakeSpec(dashPort: 8080), onHostKey: trustAll),
        throwsA(
          isA<SshTunnelException>().having(
            (e) => e.failure,
            'failure',
            SshTunnelFailure.otherAddress,
          ),
        ),
      );
      expect(tunnels.portOf('c1'), isNotNull, reason: 'the first one stays');
      await tunnels.closeAll();
    });

    test('a failed login is classified', () async {
      final tunnels = SshDashboardTunnels(
        clientFactory: (spec, ask) async => throw SSHAuthFailError('denied'),
        serverFactory: rig.server,
      );
      await expectLater(
        tunnels.open(fakeSpec(), onHostKey: trustAll),
        throwsA(
          isA<SshTunnelException>().having(
            (e) => e.ssh,
            'ssh',
            SshFailure.authRejected,
          ),
        ),
      );
    });
  });

  group('lifecycle', () {
    test(
      'the background closes everything; the foreground restores it',
      () async {
        final changes = <(String, int)>[];
        final tunnels = rig.tunnels(
          onPortChanged: (id, p) => changes.add((id, p)),
        );
        final port = await tunnels.open(fakeSpec(), onHostKey: trustAll);
        final local = rig.servers.single.accept();
        await _settle();
        final remote = rig.clients.single.remotes.last;

        tunnels.backgrounded();
        await _settle();
        expect(rig.servers.single.closed, isTrue);
        expect(rig.clients.single.closed, isTrue);
        expect(local.destroyed && remote.destroyed, isTrue);
        expect(tunnels.stateOf('c1')!.value, TunnelState.suspended);

        tunnels.foregrounded();
        await _settle();
        expect(rig.preferred.last, port, reason: 'asks for the same port');
        expect(tunnels.portOf('c1'), port);
        expect(changes, isEmpty);

        // The restored listener forwards again; the SSH link opens on demand
        // or in the background, never with a new key.
        final again = rig.servers.last.accept();
        await _settle();
        final fresh = rig.clients.last;
        expect(fresh, isNot(rig.clients.first));
        again.emit([5]);
        await _settle();
        expect(fresh.remotes.last.sent, [5]);
        expect(
          await rig.loginsWith.last(
            const SshHostKeyPrompt(
              type: 't',
              fingerprint: 'f',
              isNew: true,
              changed: false,
            ),
          ),
          isFalse,
        );
        await tunnels.closeAll();
      },
    );

    test('a port that was taken meanwhile changes the saved address', () async {
      final changes = <(String, int)>[];
      final tunnels = rig.tunnels(
        onPortChanged: (id, p) => changes.add((id, p)),
      );
      final port = await tunnels.open(fakeSpec(), onHostKey: trustAll);
      tunnels.backgrounded();
      await _settle();
      rig.taken.add(port);
      tunnels.foregrounded();
      await _settle();
      final now = tunnels.portOf('c1');
      expect(now, isNot(port));
      expect(changes, [('c1', now)]);
      await tunnels.closeAll();
    });

    test('a dropped SSH link is reopened by the next connection', () async {
      final tunnels = rig.tunnels();
      await tunnels.open(fakeSpec(), onHostKey: trustAll);
      rig.clients.single.drop();
      await _settle();
      final local = rig.servers.single.accept();
      await _settle();
      expect(rig.clients, hasLength(2));
      local.emit([7]);
      await _settle();
      expect(rig.clients.last.remotes.last.sent, [7]);
      await tunnels.closeAll();
    });

    test('a hold keeps the tunnel awake until it is released', () async {
      final tunnels = rig.tunnels();
      await tunnels.open(fakeSpec(), onHostKey: trustAll);
      final release = tunnels.hold('c1');
      tunnels.backgrounded();
      await _settle();
      expect(tunnels.stateOf('c1')!.value, TunnelState.up);
      release();
      await _settle();
      expect(tunnels.stateOf('c1')!.value, TunnelState.suspended);
      await tunnels.closeAll();
    });

    test(
      'adopting in the background opens nothing until the foreground',
      () async {
        final tunnels = rig.tunnels();
        tunnels.backgrounded();
        await tunnels.adopt(fakeSpec(preferredPort: 43210));
        expect(rig.servers, isEmpty);
        expect(rig.clients, isEmpty);
        tunnels.foregrounded();
        await _settle();
        expect(rig.preferred, [43210]);
        expect(tunnels.portOf('c1'), 43210);
        await tunnels.closeAll();
      },
    );

    test(
      'only saved tunnels close when another connection takes over',
      () async {
        final tunnels = rig.tunnels();
        await tunnels.open(fakeSpec(id: 'pending'), onHostKey: trustAll);
        await tunnels.open(fakeSpec(id: 'saved'), onHostKey: trustAll);
        tunnels.markPersisted('saved');
        await tunnels.closeSavedExcept('other');
        expect(tunnels.has('saved'), isFalse);
        expect(tunnels.has('pending'), isTrue);
        await tunnels.closeAll();
      },
    );
  });

  // M2: a half-open SSH link (NAT expired, Wi-Fi up without a way out) never
  // completes `done`; only a forward that never answers shows it.
  group('half-open link', () {
    test(
      'a forward that times out drops the link and the next one redials',
      () async {
        final tunnels = rig.tunnels(
          limits: const TunnelLimits(
            forwardTimeout: Duration(milliseconds: 50),
          ),
        );
        await tunnels.open(fakeSpec(), onHostKey: trustAll);
        final dead = rig.clients.single;
        dead.stall = Completer<void>();
        final first = rig.servers.single.accept();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(first.destroyed, isTrue);
        expect(dead.closed, isTrue, reason: 'the dead link is not reused');

        final second = rig.servers.single.accept();
        await _settle();
        expect(rig.clients, hasLength(2));
        second.emit([5]);
        await _settle();
        expect(rig.clients.last.remotes.last.sent, [5]);
        await tunnels.closeAll();
      },
    );

    test('a Dashboard refusing one connection keeps the SSH link', () async {
      final tunnels = rig.tunnels();
      await tunnels.open(fakeSpec(), onHostKey: trustAll);
      final live = rig.clients.single;
      live.forwardError = SSHChannelOpenError(2, 'Connection refused');
      final local = rig.servers.single.accept();
      await _settle();
      expect(local.destroyed, isTrue);
      expect(live.closed, isFalse);
      expect(rig.clients, hasLength(1));
      await tunnels.closeAll();
    });
  });
}
