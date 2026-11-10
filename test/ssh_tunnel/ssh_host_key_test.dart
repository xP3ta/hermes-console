// SPDX-License-Identifier: GPL-3.0-only
// The server key check that decides whether a tunnel may open: the same key
// passes, a different one is asked about as "changed" and never replaces the
// saved one unless it is trusted.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';

import '../support/onboarding_fakes.dart';

Uint8List _fp(String canonical) => Uint8List.fromList(canonical.codeUnits);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SshManager manager;
  late List<String> scopes;
  final asked = <SshHostKeyPrompt>[];

  Future<bool> check(String fp, {required bool trust}) =>
      manager.verifyHostKey(scopes, 'ssh-ed25519', _fp(fp), (prompt) async {
        asked.add(prompt);
        return trust;
      });

  setUp(() async {
    manager = SshManager(SecureStorage(), await onboardingManager());
    scopes = [SshManager.serverScope('srv.example.com', 22)];
    asked.clear();
  });

  test('a new server is asked about once and then remembered', () async {
    expect(await check('SHA256:one', trust: true), isTrue);
    expect(asked.single.isNew, isTrue);
    expect(asked.single.changed, isFalse);
    expect(await manager.knownFingerprint(scopes.single), 'SHA256:one');

    asked.clear();
    expect(await check('SHA256:one', trust: false), isTrue);
    expect(asked, isEmpty, reason: 'the known key passes unasked');
  });

  test('a changed key blocks and keeps the key on record', () async {
    await check('SHA256:one', trust: true);
    asked.clear();

    expect(await check('SHA256:two', trust: false), isFalse);
    expect(asked.single.changed, isTrue);
    expect(asked.single.fingerprint, 'SHA256:two');
    expect(await manager.knownFingerprint(scopes.single), 'SHA256:one');
  });

  test('a changed key confirmed by the person replaces the old one', () async {
    await check('SHA256:one', trust: true);
    expect(await check('SHA256:two', trust: true), isTrue);
    expect(await manager.knownFingerprint(scopes.single), 'SHA256:two');
    asked.clear();
    expect(await check('SHA256:two', trust: false), isTrue);
    expect(asked, isEmpty);
  });

  test('the key belongs to the server, whatever the connection', () async {
    await check('SHA256:one', trust: true);
    final other = [
      SshManager.serverScope('SRV.example.com', 22),
      'another-connection',
    ];
    asked.clear();
    final ok = await manager.verifyHostKey(
      other,
      'ssh-ed25519',
      _fp('SHA256:one'),
      (prompt) async => false,
    );
    expect(ok, isTrue, reason: 'same server, written in capitals');
    final elsewhere = SshManager.serverScope('srv.example.com', 2222);
    expect(await manager.knownFingerprint(elsewhere), isNull);
  });
}
