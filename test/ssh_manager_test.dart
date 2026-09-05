import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';

void main() {
  group('SshAuthMethod', () {
    test('fromId mapea ids conocidos y cae a key', () {
      expect(SshAuthMethod.fromId('key'), SshAuthMethod.key);
      expect(SshAuthMethod.fromId('password'), SshAuthMethod.password);
      expect(SshAuthMethod.fromId(null), SshAuthMethod.key);
      expect(SshAuthMethod.fromId('???'), SshAuthMethod.key);
    });
  });

  group('SshConfig', () {
    test('target compone user@host:port', () {
      const cfg = SshConfig(
        host: '192.168.1.20',
        port: 22,
        username: 'demo',
        method: SshAuthMethod.key,
      );
      expect(cfg.target, 'demo@192.168.1.20:22');
    });
  });

  group('decodeFingerprint (TOFU)', () {
    test('devuelve tal cual la cadena canónica que pasa dartssh2', () {
      // dartssh2 entrega ya "SHA256:..." como bytes UTF-8: no re-hashear.
      const canonical = 'SHA256:0x0tuFfqUecXp5hOL5GzyfhWx4gzhdOBPUL36zhI22M';
      final raw = Uint8List.fromList(canonical.codeUnits);
      expect(SshManager.decodeFingerprint(raw), canonical);
    });

    test('fallback determinista si llega en crudo (no SHA256:)', () {
      final a = SshManager.decodeFingerprint(Uint8List.fromList([1, 2, 3]));
      final b = SshManager.decodeFingerprint(Uint8List.fromList([1, 2, 3]));
      final c = SshManager.decodeFingerprint(Uint8List.fromList([9, 9, 9]));
      expect(a, b);
      expect(a.startsWith('SHA256:'), isTrue);
      expect(a == c, isFalse);
    });
  });

  group('validateKey', () {
    test('rechaza texto vacío', () {
      expect(SshManager.validateKey('', null), isNotNull);
      expect(SshManager.validateKey('   ', null), isNotNull);
    });

    test('rechaza texto que no es una clave', () {
      expect(SshManager.validateKey('esto no es una clave', null), isNotNull);
    });

    test('isEncryptedKey no lanza con basura', () {
      expect(SshManager.isEncryptedKey('basura'), isFalse);
    });
  });

  group('describeError', () {
    test('config exception se propaga tal cual', () {
      expect(
        SshManager.describeError(const SshConfigException('falta host')),
        'falta host',
      );
    });

    test('mensajes de red reconocibles', () {
      expect(
        SshManager.describeError(Exception('Connection refused')),
        contains('refused'),
      );
      expect(
        SshManager.describeError(Exception('Connection timed out')),
        contains('espera'),
      );
    });
  });
}
