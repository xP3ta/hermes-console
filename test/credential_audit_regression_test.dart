import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final values = <String, String>{};
  String? failNextWrite;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    values.clear();
    failNextWrite = null;
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final args = (call.arguments as Map).cast<String, dynamic>();
            final key = args['key'] as String?;
            switch (call.method) {
              case 'read':
                return values[key];
              case 'readAll':
                return Map<String, String>.of(values);
              case 'write':
                if (key == failNextWrite) {
                  failNextWrite = null;
                  throw PlatformException(code: 'storage-unavailable');
                }
                values[key!] = args['value'] as String;
              case 'delete':
                values.remove(key);
            }
            return null;
          },
        );
  });

  SavedConnection connection() => SavedConnection(
    id: 'audit',
    label: 'Before',
    host: 'example.invalid',
    port: 443,
    useHttps: true,
    apiKey: 'test-key',
    dashboardUrl: 'https://dashboard.example.invalid',
    dashboardAuthMode: AuthMode.sessionToken,
    notes: 'keep notes',
    localChatMode: LocalChatMode.agent,
  );

  test(
    'SSH metadata edit preserves the existing encrypted key passphrase',
    () async {
      final manager = await ConnectionManager.create(
        await SharedPreferences.getInstance(),
      );
      addTearDown(manager.dispose);
      final secure = SecureStorage();
      final ssh = SshManager(secure, manager);
      await ssh.saveConfig(
        'audit',
        host: 'example.invalid',
        port: 22,
        username: 'test',
        method: SshAuthMethod.key,
        privateKeyPem: 'synthetic-key',
        passphrase: 'synthetic-passphrase',
      );
      await ssh.saveConfig(
        'audit',
        host: 'example.invalid',
        port: 2222,
        username: 'renamed',
        method: SshAuthMethod.key,
      );
      expect(await secure.readSsh('audit', 'privkey'), 'synthetic-key');
      expect(
        await secure.readSsh('audit', 'passphrase'),
        'synthetic-passphrase',
      );
      await ssh.saveConfig(
        'audit',
        host: 'example.invalid',
        port: 2222,
        username: 'renamed',
        method: SshAuthMethod.key,
        privateKeyPem: 'replacement-key',
      );
      expect(await secure.readSsh('audit', 'passphrase'), '');
    },
  );

  test(
    'a failed migration preserves the only existing copy of a key',
    () async {
      final legacy = connection().toMap()..['api_key'] = 'legacy-test-key';
      SharedPreferences.setMockInitialValues({
        'saved_connections': [jsonEncode(legacy)],
      });
      final prefs = await SharedPreferences.getInstance();
      failNextWrite = 'api_key_audit';
      await expectLater(
        ConnectionManager.create(prefs),
        throwsA(isA<PlatformException>()),
      );
      expect(
        jsonDecode(prefs.getStringList('saved_connections')!.single)['api_key'],
        'legacy-test-key',
      );
      final recovered = await ConnectionManager.create(prefs);
      addTearDown(recovered.dispose);
      expect(recovered.getConnections().single.apiKey, 'legacy-test-key');
    },
  );

  test(
    'metadata edits retain Dashboard configuration and blank keys',
    () async {
      final manager = await ConnectionManager.create(
        await SharedPreferences.getInstance(),
      );
      addTearDown(manager.dispose);
      await manager.upsertConnection(connection());
      await manager.updateConnection(
        'audit',
        label: 'After',
        host: 'example.invalid',
        port: 443,
        useHttps: true,
        kind: InstanceKind.vps,
        apiKey: '',
      );
      await manager.updateApiKey('audit', '   ');
      final saved = manager.getConnections().single;
      expect(saved.label, 'After');
      expect(saved.apiKey, 'test-key');
      expect(saved.dashboardUrl, connection().dashboardUrl);
      expect(saved.dashboardAuthMode, AuthMode.sessionToken);
      expect(saved.notes, 'keep notes');
      expect(saved.localChatMode, LocalChatMode.agent);
    },
  );

  test('failed password write rolls back its paired username', () async {
    final manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    addTearDown(manager.dispose);
    await manager.upsertConnection(connection());
    await manager.setDashboardSecrets(
      'audit',
      username: 'before',
      password: 'old-test-password',
    );
    failNextWrite = 'dash_pass_audit';
    await expectLater(
      manager.setDashboardSecrets(
        'audit',
        username: 'after',
        password: 'new-test-password',
      ),
      throwsA(isA<PlatformException>()),
    );
    final saved = await manager.getDashboardSecrets('audit');
    expect(saved.username, 'before');
    expect(saved.password, 'old-test-password');
    await manager.setDashboardSecrets(
      'audit',
      username: '',
      password: '',
      sessionToken: '',
    );
    expect(
      (await manager.getDashboardSecrets('audit')).password,
      'old-test-password',
    );
  });
}
