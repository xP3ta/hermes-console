import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/utils/transport_privacy.dart';

void main() {
  group('TransportPrivacy.classify · secure', () {
    test('https:// es seguro', () {
      expect(
        TransportPrivacy.classify('https://ejemplo.com:8642'),
        TransportPrivacyClass.secure,
      );
    });

    test('wss:// es seguro', () {
      expect(
        TransportPrivacy.classify('wss://ejemplo.com:8642'),
        TransportPrivacyClass.secure,
      );
    });

    test('https:// hacia IPv6 con puerto sigue siendo seguro', () {
      expect(
        TransportPrivacy.classify('https://[::1]:8642'),
        TransportPrivacyClass.secure,
      );
    });

    test('URL vacía no clasifica como aviso (secure por defecto)', () {
      expect(TransportPrivacy.classify(''), TransportPrivacyClass.secure);
      expect(TransportPrivacy.classify('   '), TransportPrivacyClass.secure);
    });
  });

  group('TransportPrivacy.classify · privateCleartext', () {
    test('http:// a localhost', () {
      expect(
        TransportPrivacy.classify('http://localhost:8642'),
        TransportPrivacyClass.privateCleartext,
      );
    });

    test('http:// a loopback 127.0.0.1', () {
      expect(
        TransportPrivacy.classify('http://127.0.0.1:8642'),
        TransportPrivacyClass.privateCleartext,
      );
    });

    test('IPv6 loopback ::1 sin esquema ni corchetes ni puerto', () {
      expect(
        TransportPrivacy.classify('::1'),
        TransportPrivacyClass.privateCleartext,
      );
    });

    test('ws:// a IPv6 loopback entre corchetes', () {
      expect(
        TransportPrivacy.classify('ws://[::1]:8642'),
        TransportPrivacyClass.privateCleartext,
      );
    });

    test('http:// a LAN 10.0.0.0/8', () {
      expect(
        TransportPrivacy.classify('http://10.1.2.3:8642'),
        TransportPrivacyClass.privateCleartext,
      );
    });

    test('http:// a LAN 172.16-31.x.x (dentro de rango)', () {
      expect(
        TransportPrivacy.classify('http://172.20.0.5:8642'),
        TransportPrivacyClass.privateCleartext,
      );
    });

    test('172.15.x.x y 172.32.x.x quedan fuera del rango 172.16-31', () {
      expect(
        TransportPrivacy.classify('http://172.15.0.5:8642'),
        TransportPrivacyClass.publicCleartext,
      );
      expect(
        TransportPrivacy.classify('http://172.32.0.5:8642'),
        TransportPrivacyClass.publicCleartext,
      );
    });

    test('http:// a LAN 192.168.0.0/16', () {
      expect(
        TransportPrivacy.classify('http://192.168.1.5:8642'),
        TransportPrivacyClass.privateCleartext,
      );
    });

    test('http:// a CGNAT de Tailscale 100.64.0.0/10', () {
      expect(
        TransportPrivacy.classify('http://100.64.0.1:8642'),
        TransportPrivacyClass.privateCleartext,
      );
      expect(
        TransportPrivacy.classify('http://100.100.50.7:8642'),
        TransportPrivacyClass.privateCleartext,
      );
    });

    test('100.63.x.x y 100.128.x.x quedan fuera del rango CGNAT', () {
      expect(
        TransportPrivacy.classify('http://100.63.0.1:8642'),
        TransportPrivacyClass.publicCleartext,
      );
      expect(
        TransportPrivacy.classify('http://100.128.0.1:8642'),
        TransportPrivacyClass.publicCleartext,
      );
    });

    test('http:// a host MagicDNS de Tailscale (*.ts.net)', () {
      expect(
        TransportPrivacy.classify('http://mi-servidor.ts.net:8642'),
        TransportPrivacyClass.privateCleartext,
      );
    });

    test('sin esquema explícito se asume http:// (cleartext)', () {
      expect(
        TransportPrivacy.classify('192.168.1.5:8642'),
        TransportPrivacyClass.privateCleartext,
      );
    });
  });

  group('TransportPrivacy.classify · publicCleartext', () {
    test('http:// a dominio público', () {
      expect(
        TransportPrivacy.classify('http://ejemplo.com:8642'),
        TransportPrivacyClass.publicCleartext,
      );
    });

    test('http:// a IP pública', () {
      expect(
        TransportPrivacy.classify('http://8.8.8.8:8642'),
        TransportPrivacyClass.publicCleartext,
      );
    });

    test('ws:// a host público', () {
      expect(
        TransportPrivacy.classify('ws://chat.ejemplo.com'),
        TransportPrivacyClass.publicCleartext,
      );
    });

    test('sin esquema hacia host público también avisa', () {
      expect(
        TransportPrivacy.classify('ejemplo.com:8642'),
        TransportPrivacyClass.publicCleartext,
      );
    });
  });

  group('IPv4 literal, strict (#14)', () {
    test('octal, hex or signed octets are not loopback nor private', () {
      for (final host in [
        '0127.0.0.1',
        '0x7f.0.0.1',
        '+127.0.0.1',
        '010.0.0.1',
      ]) {
        expect(
          TransportPrivacy.isEncryptedPath('http://$host:9119'),
          isFalse,
          reason: host,
        );
        expect(
          TransportPrivacy.classify('http://$host:9119'),
          TransportPrivacyClass.publicCleartext,
          reason: host,
        );
      }
      expect(TransportPrivacy.isEncryptedPath('http://127.0.0.1:9119'), isTrue);
      expect(TransportPrivacy.isEncryptedPath('http://127.0.0.0:9119'), isTrue);
    });
  });

  group('TransportPrivacy.requireAllowed', () {
    test('bloquea HTTP público', () {
      expect(
        () => TransportPrivacy.requireAllowed('http://8.8.8.8:8642'),
        throwsArgumentError,
      );
    });

    test('permite HTTPS y HTTP privado/Tailscale', () {
      expect(
        TransportPrivacy.requireAllowed('https://hermes.example.com'),
        'https://hermes.example.com',
      );
      expect(
        TransportPrivacy.requireAllowed('http://100.100.50.7:8642'),
        'http://100.100.50.7:8642',
      );
    });
  });
}
