import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_session_service.dart';
import 'package:hermes_android/core/utils/ssh_error.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final en = lookupStrings(const Locale('en'));
  final es = lookupStrings(const Locale('es'));

  test('network failures follow the English app language', () {
    expect(
      localizedSshError(en, const SocketException('Connection refused')),
      'Connection refused (is SSH running?).',
    );
    expect(
      localizedSshError(en, const SocketException('Connection timed out')),
      'Timed out (host/port unreachable).',
    );
    expect(
      localizedSshError(en, const SocketException('Failed host lookup: x')),
      'Could not resolve the host.',
    );
    expect(localizedSshError(en, StateError('boom')), en.sshConnError);
  });

  test('authentication and handshake failures follow Spanish', () {
    expect(
      localizedSshError(es, SSHAuthFailError('denied')),
      'Autenticación rechazada: revisa el usuario, la clave o la contraseña.',
    );
    expect(
      localizedSshError(es, SSHHandshakeError('bad banner')),
      'Falló la negociación SSH (¿es un servidor SSH?).',
    );
    expect(
      localizedSshError(es, const SshConfigException(SshFailure.missingUser)),
      'Falta el nombre de usuario.',
    );
  });

  test('key validation failures are localized at the UI edge', () {
    final empty = SshManager.validateKey('   ', null);
    final garbage = SshManager.validateKey('not a key', null);
    expect(empty, SshFailure.emptyKey);
    expect(garbage, isNotNull);
    expect(localizedSshFailure(en, empty!), 'Paste or import a private key.');
    expect(
      localizedSshFailure(es, garbage!),
      isNot(anyOf(contains('Invalid'), contains('Unrecognized'))),
    );
  });

  test('a session without credentials exposes a localizable failure', () async {
    SharedPreferences.setMockInitialValues(const {});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => call.method == 'readAll' ? <String, String>{} : null,
        );
    final manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    final service = SshSessionService(SshManager(SecureStorage(), manager));

    final session = await service.connect(
      'missing',
      onHostKey: (_) async => false,
    );

    expect(session.phase.value, SshSessionPhase.error);
    expect(
      localizedSshError(en, session.failure!),
      'No SSH credentials configured.',
    );
    expect(
      localizedSshError(es, session.failure!),
      'No hay credenciales SSH configuradas.',
    );
  });

  test('the terminal close banner follows the app language', () async {
    for (final (locale, banner) in [
      ('en', '[session closed]'),
      ('es', '[sesión cerrada]'),
    ]) {
      SharedPreferences.setMockInitialValues({'app_locale': locale});
      final manager = await ConnectionManager.create(
        await SharedPreferences.getInstance(),
      );
      final ssh = SshManager(SecureStorage(), manager);
      expect(ssh.appStrings.i18n1215SshSessionClosedBanner, banner);
    }
  });
}
