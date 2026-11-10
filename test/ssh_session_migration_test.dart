// The stored session type of an SSH profile: what the plain terminal reads
// back, and the migration of values the old automatic detection may have
// left (`herdr`, `tmux`) to the plain shell.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_session_kind.dart';

class _FakeConnections implements ConnectionManager {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Map<String, String> secure;

  setUp(() {
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
            }
            return null;
          },
        );
  });

  SshManager manager() => SshManager(SecureStorage(), _FakeConnections());

  test('a profile with nothing stored is a plain shell', () async {
    expect(await manager().loadSessionKind('c1'), SshSessionKind.shell);
  });

  for (final legacy in ['herdr', 'tmux']) {
    test('a saved `$legacy` migrates to the plain shell', () async {
      secure['ssh_session_c1'] = legacy;
      secure['ssh_user_c1'] = 'demo';
      secure['ssh_host_c1'] = 'example.invalid';
      expect(await manager().loadSessionKind('c1'), SshSessionKind.shell);
      final config = await manager().loadConfig('c1');
      expect(config?.sessionKind, SshSessionKind.shell);
    });
  }

  test('saving a profile without a choice stores the plain shell', () async {
    final ssh = manager();
    await ssh.saveConfig(
      'c1',
      host: 'example.invalid',
      port: 22,
      username: 'demo',
      method: SshAuthMethod.password,
      sessionKind: SshSessionKind.shell,
      password: 'x',
    );
    expect(secure['ssh_session_c1'], 'shell');
    expect(await ssh.loadSessionKind('c1'), SshSessionKind.shell);
  });

  for (final kind in [SshSessionKind.herdr, SshSessionKind.tmux]) {
    test('${kind.id} picked by hand survives a save and a read', () async {
      final ssh = manager();
      await ssh.saveConfig(
        'c1',
        host: 'example.invalid',
        port: 22,
        username: 'demo',
        method: SshAuthMethod.password,
        sessionKind: kind,
        password: 'x',
      );
      expect(secure['ssh_session_c1'], kind.storedId);
      expect(await ssh.loadSessionKind('c1'), kind);
      expect((await ssh.loadConfig('c1'))?.sessionKind, kind);
    });
  }
}
