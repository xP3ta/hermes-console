import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_session_kind.dart';
import 'package:hermes_android/core/services/ssh_session_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Exact strings sent to the server (checked by hand in a Debian-like
/// HOME: the old bare `command -v herdr` missed ~/.local/bin).
const _herdrProbe = r""""${SHELL:-/bin/sh}" -lc 'command -v herdr'""";
const _tmuxProbe = r""""${SHELL:-/bin/sh}" -lc 'command -v tmux'""";

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('sshInLoginShell wraps constants and refuses single quotes', () {
    expect(
      sshInLoginShell('herdr api snapshot'),
      r""""${SHELL:-/bin/sh}" -lc 'herdr api snapshot'""",
    );
    expect(() => sshInLoginShell("x'; reboot; '"), throwsArgumentError);
  });

  group('SshSessionKind', () {
    test('fromId maps known ids and falls back to the plain shell', () {
      expect(SshSessionKind.fromId('shell'), SshSessionKind.shell);
      expect(SshSessionKind.fromId('herdr'), SshSessionKind.herdr);
      expect(SshSessionKind.fromId('tmux'), SshSessionKind.tmux);
      expect(SshSessionKind.fromId(null), SshSessionKind.shell);
      expect(SshSessionKind.fromId(''), SshSessionKind.shell);
      expect(SshSessionKind.fromId('screen'), SshSessionKind.shell);
    });

    test('fromStored: only the explicit markers give Herdr or tmux', () {
      // What 1.4.0 builds before the plain terminal saved by detection or by
      // choice (`herdr`, `tmux`) cannot be told apart: it counts as nothing.
      expect(SshSessionKind.fromStored('herdr'), SshSessionKind.shell);
      expect(SshSessionKind.fromStored('tmux'), SshSessionKind.shell);
      expect(SshSessionKind.fromStored(null), SshSessionKind.shell);
      expect(SshSessionKind.fromStored('shell'), SshSessionKind.shell);
      expect(SshSessionKind.fromStored('screen'), SshSessionKind.shell);
      for (final kind in SshSessionKind.values) {
        expect(SshSessionKind.fromStored(kind.storedId), kind);
      }
      expect(SshSessionKind.herdr.storedId, isNot(SshSessionKind.herdr.id));
      expect(SshSessionKind.tmux.storedId, isNot(SshSessionKind.tmux.id));
    });

    test('the remote commands are exact constants', () {
      expect(sshTmuxSessionName, 'hermes-console');
      expect(sshHerdrLaunchCommand, 'herdr');
      expect(sshTmuxLaunchCommand, 'tmux new-session -A -D -s hermes-console');
      // Probes run in the user's login shell (PATH with ~/.local/bin).
      expect(sshHerdrProbeCommand, _herdrProbe);
      expect(sshTmuxProbeCommand, _tmuxProbe);

      expect(SshSessionKind.herdr.probeCommand, _herdrProbe);
      expect(SshSessionKind.herdr.launchCommand, 'herdr');
      expect(SshSessionKind.tmux.probeCommand, _tmuxProbe);
      expect(
        SshSessionKind.tmux.launchCommand,
        'tmux new-session -A -D -s hermes-console',
      );
    });

    test('the plain shell probes and launches nothing', () {
      expect(SshSessionKind.shell.probeCommand, isNull);
      expect(SshSessionKind.shell.launchCommand, isNull);
      expect(SshSessionKind.shell.installCommand, isNull);
      expect(SshSessionKind.shell.installUrl, isNull);
      expect(SshSessionKind.shell.survivesDisconnect, isFalse);
      expect(SshSessionKind.herdr.survivesDisconnect, isTrue);
      expect(SshSessionKind.tmux.survivesDisconnect, isTrue);
    });

    test('install help: Herdr command from its README, tmux only a link', () {
      expect(
        SshSessionKind.herdr.installCommand,
        'curl -fsSL https://herdr.dev/install.sh | sh',
      );
      expect(
        SshSessionKind.herdr.installUrl,
        'https://github.com/herdrdev/herdr',
      );
      expect(SshSessionKind.tmux.installCommand, isNull);
      expect(
        SshSessionKind.tmux.installUrl,
        'https://github.com/tmux/tmux/wiki/Installing',
      );
    });
  });

  group('sshCtrlChord', () {
    test('letters and C0 symbols become control characters', () {
      expect(sshCtrlChord('c'), '\x03');
      expect(sshCtrlChord('C'), '\x03');
      expect(sshCtrlChord('b'), '\x02');
      expect(sshCtrlChord('a'), '\x01');
      expect(sshCtrlChord('z'), '\x1a');
      expect(sshCtrlChord('['), '\x1b');
      expect(sshCtrlChord('@'), '\x00');
      expect(sshCtrlChord(' '), '\x00');
      expect(sshCtrlChord('?'), '\x7f');
    });

    test('anything else passes through untouched', () {
      expect(sshCtrlChord('1'), '1');
      expect(sshCtrlChord('/'), '/');
      expect(sshCtrlChord('ab'), 'ab');
      expect(sshCtrlChord('\x1b[A'), '\x1b[A');
      expect(sshCtrlChord(''), '');
    });
  });

  group('SshManager.isTransientFailure', () {
    test('network failures retry; credentials, config and keys do not', () {
      expect(
        SshManager.isTransientFailure(Exception('Connection refused')),
        isTrue,
      );
      expect(SshManager.isTransientFailure(TimeoutException('x')), isTrue);
      expect(
        SshManager.isTransientFailure(Exception('Failed host lookup')),
        isTrue,
      );
      expect(
        SshManager.isTransientFailure(
          const SshConfigException(SshFailure.notConfigured),
        ),
        isFalse,
      );
      expect(
        SshManager.isTransientFailure(SSHAuthFailError('denied')),
        isFalse,
      );
      expect(
        SshManager.isTransientFailure(
          SSHHostkeyError('Hostkey verification failed'),
        ),
        isFalse,
      );
    });
  });

  group('session type stored with the SSH profile', () {
    late Map<String, String> secure;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      secure = <String, String>{};
      TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            (call) async {
              final args = (call.arguments as Map?) ?? {};
              switch (call.method) {
                case 'read':
                  return secure[args['key']];
                case 'write':
                  secure[args['key'] as String] = args['value'] as String;
                  return null;
                case 'delete':
                  secure.remove(args['key']);
                  return null;
                case 'readAll':
                  return Map<String, String>.from(secure);
                case 'containsKey':
                  return secure.containsKey(args['key']);
                case 'deleteAll':
                  secure.clear();
                  return null;
              }
              return null;
            },
          );
    });

    Future<SshManager> manager() async => SshManager(
      SecureStorage(),
      await ConnectionManager.create(await SharedPreferences.getInstance()),
    );

    test('defaults to the plain shell', () async {
      final ssh = await manager();
      await ssh.saveConfig(
        'c1',
        host: 'example.invalid',
        port: 22,
        username: 'demo',
        method: SshAuthMethod.password,
        password: 'not-a-real-secret',
      );
      expect((await ssh.loadConfig('c1'))!.sessionKind, SshSessionKind.shell);
      expect(await ssh.loadSessionKind('c1'), SshSessionKind.shell);
      expect(secure.containsKey('ssh_session_c1'), isFalse);
    });

    test('saves, keeps when omitted and clears with the profile', () async {
      final ssh = await manager();
      await ssh.saveConfig(
        'c1',
        host: 'example.invalid',
        port: 22,
        username: 'demo',
        method: SshAuthMethod.password,
        sessionKind: SshSessionKind.tmux,
      );
      expect(secure['ssh_session_c1'], 'tmux-explicit');
      expect((await ssh.loadConfig('c1'))!.sessionKind, SshSessionKind.tmux);

      await ssh.saveConfig(
        'c1',
        host: 'example.invalid',
        port: 22,
        username: 'demo',
        method: SshAuthMethod.password,
      );
      expect(await ssh.loadSessionKind('c1'), SshSessionKind.tmux);

      await ssh.clear('c1');
      expect(secure.containsKey('ssh_session_c1'), isFalse);
      expect(await ssh.loadSessionKind('c1'), SshSessionKind.shell);
    });

    test('an unreadable store falls back to the plain shell', () async {
      final ssh = await manager();
      TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            (call) async => throw PlatformException(code: 'boom'),
          );
      expect(await ssh.loadSessionKind('c1'), SshSessionKind.shell);
    });
  });
}
