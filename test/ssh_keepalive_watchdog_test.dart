// SPDX-License-Identifier: GPL-3.0-only
// M2: dartssh2's own keepalive awaits the reply with no deadline, so a
// half-open link (the server or the path silently gone) is never noticed.
// The watchdog pings on its own clock and closes a link that stops answering.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/ssh_keepalive.dart';

const _interval = Duration(milliseconds: 50);
const _timeout = Duration(milliseconds: 100);

Future<void> _wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  test('a ping that never answers closes the link once', () async {
    var pings = 0;
    var closed = 0;
    final dog = SshKeepAliveWatchdog(
      ping: () {
        pings++;
        return Completer<void>().future;
      },
      onDead: () => closed++,
      interval: _interval,
      timeout: _timeout,
    )..start();
    await _wait(100);
    expect(pings, 1);
    expect(closed, 0, reason: 'still inside the deadline');
    await _wait(200);
    expect(closed, 1);
    await _wait(300);
    expect(closed, 1, reason: 'a dead link is closed once');
    expect(pings, 1, reason: 'no more pings after closing');
    dog.stop();
  });

  test('a link that answers is left alone', () async {
    var pings = 0;
    var closed = 0;
    final dog = SshKeepAliveWatchdog(
      ping: () async => pings++,
      onDead: () => closed++,
      interval: _interval,
      timeout: _timeout,
    )..start();
    await _wait(400);
    expect(pings, greaterThanOrEqualTo(3));
    expect(closed, 0);
    dog.stop();
    final stopped = pings;
    await _wait(200);
    expect(pings, stopped, reason: 'stop ends the pings');
  });

  test('a ping that fails (link already closing) is not a timeout', () async {
    var closed = 0;
    final dog = SshKeepAliveWatchdog(
      ping: () async => throw StateError('closed'),
      onDead: () => closed++,
      interval: _interval,
      timeout: _timeout,
    )..start();
    await _wait(400);
    expect(closed, 0);
    dog.stop();
  });

  test('every SSH client gets the watchdog, not the deadline-less timer', () {
    // ssh_manager builds the clients of the terminal, SFTP, the push pairing
    // and the Dashboard tunnel: the dartssh2 timer would keep pinging a dead
    // link forever, so it is switched off and the watchdog takes over.
    final source = File(
      'lib/core/services/ssh_manager.dart',
    ).readAsStringSync();
    expect(source, contains('keepAliveInterval: null'));
    expect(source, contains('watchSshKeepAlive('));
    expect(kSshKeepAliveInterval, const Duration(seconds: 60));
    expect(kSshKeepAliveTimeout, const Duration(seconds: 15));
  });
}
