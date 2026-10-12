import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/pairing_link.dart';

void main() {
  group('PairingLink', () {
    test('roundtrip build → parse conserva todos los campos', () {
      const link = PairingLink(
        host: '100.101.102.103',
        port: 8642,
        token: 'test-pairing-token',
        label: 'Hermes lab',
        useHttps: true,
        dashboardUrl: 'http://100.101.102.103:9119',
      );
      final parsed = PairingLink.tryParse(link.build())!;
      expect(parsed.host, link.host);
      expect(parsed.port, link.port);
      expect(parsed.token, link.token);
      expect(parsed.label, link.label);
      expect(parsed.useHttps, isTrue);
      expect(parsed.dashboardUrl, link.dashboardUrl);
    });

    test(
      'mínimo (solo host+port+token) válido; https/dashboard por defecto',
      () {
        const link = PairingLink(
          host: '192.168.1.10',
          port: 8642,
          token: 'abc',
        );
        final s = link.build();
        expect(s, startsWith('hermes://pair?'));
        final parsed = PairingLink.tryParse(s)!;
        expect(parsed.host, '192.168.1.10');
        expect(parsed.token, 'abc');
        expect(parsed.useHttps, isFalse);
        expect(parsed.label, isNull);
        expect(parsed.dashboardUrl, isNull);
      },
    );

    test('a link can carry the existing Dashboard sign-in', () {
      final parsed = PairingLink.tryParse(
        'hermes://pair?host=lab.example&port=8642&token=gateway-key'
        '&dashboard=http%3A%2F%2Flab.example%3A9119'
        '&dash_user=%20owner%20&dash_pass=p%40ss%20word%2B%26',
      )!;
      expect(parsed.hasDashboardLogin, isTrue);
      expect(parsed.dashboardUser, 'owner');
      // The password keeps every character, spaces included.
      expect(parsed.dashboardPassword, 'p@ss word+&');
      final again = PairingLink.tryParse(parsed.build())!;
      expect(again.dashboardUser, 'owner');
      expect(again.dashboardPassword, 'p@ss word+&');
      expect(again.dashboardUrl, 'http://lab.example:9119');
      // The login never becomes part of the saved connection metadata.
      final draft = parsed.toDraftConnection();
      expect(draft.toMap().toString(), isNot(contains('p@ss word+&')));
      expect(draft.toMap().toString(), isNot(contains('owner')));
    });

    // The exact text the setup helper prints (xP3ta/hermes-setup, branch
    // v2-no-bridge): its Unix script encodes with Python's urlencode ("+"
    // for a space), its Windows script with [Uri]::EscapeDataString ("%20").
    // Both have to give back the same sign-in, character for character.
    test('the code the setup helper shows gives back its sign-in exactly', () {
      const user = 'ana maría';
      const password = 'p@ss word+&=%/é"\'#?';
      const unix =
          'hermes://pair?host=192.168.1.40&port=8642&token=SYNTHETIC-KEY'
          '&dashboard=http%3A%2F%2F192.168.1.40%3A9119'
          '&dash_user=ana+mar%C3%ADa'
          '&dash_pass=p%40ss+word%2B%26%3D%25%2F%C3%A9%22%27%23%3F';
      const windows =
          'hermes://pair?host=192.168.1.40&port=8642&token=SYNTHETIC-KEY'
          '&dashboard=http%3A%2F%2F192.168.1.40%3A9119'
          '&dash_user=ana%20mar%C3%ADa'
          '&dash_pass=p%40ss%20word%2B%26%3D%25%2F%C3%A9%22%27%23%3F';
      for (final raw in [unix, windows]) {
        final link = PairingLink.tryParse(raw)!;
        expect(link.host, '192.168.1.40');
        expect(link.port, 8642);
        expect(link.token, 'SYNTHETIC-KEY');
        expect(link.dashboardUrl, 'http://192.168.1.40:9119');
        expect(link.hasDashboardLogin, isTrue);
        expect(link.dashboardUser, user);
        expect(link.dashboardPassword, password);
        // What the app would show again carries the same sign-in.
        final again = PairingLink.tryParse(link.build())!;
        expect(again.dashboardUser, user);
        expect(again.dashboardPassword, password);
      }
    });

    test('a helper code without the sign-in connects the Gateway alone', () {
      // What the helper prints when Hermes already had a Dashboard password
      // it does not know: the app then asks for it once.
      final link = PairingLink.tryParse(
        'hermes://pair?host=192.168.1.40&port=8642&token=SYNTHETIC-KEY'
        '&dashboard=http%3A%2F%2F192.168.1.40%3A9119',
      )!;
      expect(link.hasDashboardLogin, isFalse);
      expect(link.dashboardUser, isNull);
      expect(link.dashboardPassword, isNull);
      expect(link.toDraftConnection().apiKey, 'SYNTHETIC-KEY');
    });

    test('half a Dashboard sign-in is no sign-in', () {
      for (final query in [
        'dash_user=owner',
        'dash_pass=secret',
        'dash_user=&dash_pass=secret',
        'dash_user=owner&dash_pass=',
        'dash_user=owner&dash_pass=%FF',
      ]) {
        final parsed = PairingLink.tryParse(
          'hermes://pair?host=lab.example&port=8642&token=gateway-key&$query',
        )!;
        expect(parsed.token, 'gateway-key', reason: query);
        expect(parsed.hasDashboardLogin, isFalse, reason: query);
        expect(parsed.dashboardUser, isNull, reason: query);
        expect(parsed.dashboardPassword, isNull, reason: query);
        expect(parsed.build(), isNot(contains('dash_')), reason: query);
      }
    });

    test('a link without the Dashboard sign-in is what it was', () {
      const link = PairingLink(host: 'h.example', port: 8642, token: 'tok');
      expect(link.hasDashboardLogin, isFalse);
      expect(link.build(), 'hermes://pair?host=h.example&port=8642&token=tok');
    });

    test('genera un draft de conexión usable', () {
      const link = PairingLink(
        host: 'h.example',
        port: 9000,
        token: 'tok',
        label: 'Mi Hermes',
      );
      final c = link.toDraftConnection();
      expect(c.host, 'h.example');
      expect(c.port, 9000);
      expect(c.apiKey, 'tok');
      expect(c.label, 'Mi Hermes');
      expect(c.id, isNotEmpty);
    });

    test('label por defecto = host cuando falta', () {
      const link = PairingLink(host: 'h.example', port: 9000, token: 'tok');
      expect(link.toDraftConnection().label, 'h.example');
    });

    test('rechaza esquema/authority/campos inválidos', () {
      expect(PairingLink.tryParse(''), isNull);
      expect(
        PairingLink.tryParse('https://pair?host=h&port=1&token=t'),
        isNull,
      );
      expect(
        PairingLink.tryParse('hermes://other?host=h&port=1&token=t'),
        isNull,
      );
      expect(
        PairingLink.tryParse('hermes://pair?port=1&token=t'),
        isNull,
      ); // sin host
      expect(
        PairingLink.tryParse('hermes://pair?host=h&port=1'),
        isNull,
      ); // sin token
      expect(
        PairingLink.tryParse('hermes://pair?host=h&port=0&token=t'),
        isNull,
      );
      expect(
        PairingLink.tryParse('hermes://pair?host=h&port=99999&token=t'),
        isNull,
      );
      expect(
        PairingLink.tryParse('hermes://pair?host=h&port=abc&token=t'),
        isNull,
      );
    });

    test('parsea el formato que emite el comando del servidor', () {
      // Usa direcciones y credenciales reservadas exclusivamente para tests.
      const real =
          'hermes://pair?host=192.0.2.40&port=8642&token=test-pairing-token&label=hermes-lab';
      final p = PairingLink.tryParse(real)!;
      expect(p.host, '192.0.2.40');
      expect(p.port, 8642);
      expect(p.token, 'test-pairing-token');
      expect(p.label, 'hermes-lab');
    });

    test('tolera espacios y token con caracteres URL-sensibles', () {
      const tok = 'a+b/c=d_e-f';
      const link = PairingLink(host: 'h', port: 8642, token: tok);
      final parsed = PairingLink.tryParse('  ${link.build()}  ')!;
      expect(parsed.token, tok);
    });
  });
}
