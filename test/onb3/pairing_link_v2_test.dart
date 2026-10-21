import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/pairing_link.dart';

String v2({
  String url = 'http%3A%2F%2F127.0.0.1%3A9119',
  String user = 'admin',
  String? pass = 's3cret%21',
  String? label,
  String extra = '',
}) =>
    'hermes://pair?v=2&url=$url&user=$user'
    '${pass == null ? '' : '&pass=$pass'}'
    '${label == null ? '' : '&label=$label'}$extra';

void main() {
  group('v2 Dashboard link', () {
    test('valid link with every field', () {
      final r = PairingLink.parse(v2(label: 'Casa%20PC'));
      expect(r.version, PairingLinkVersion.v2);
      expect(r.v1, isNull);
      expect(r.v2!.url, 'http://127.0.0.1:9119');
      expect(r.v2!.user, 'admin');
      expect(r.v2!.password, 's3cret!');
      expect(r.v2!.label, 'Casa PC');
    });

    test('password and label are optional', () {
      final l = PairingLink.parse(v2(pass: null)).v2!;
      expect(l.password, isNull);
      expect(l.hasPassword, isFalse);
      expect(l.label, isNull);
    });

    test('Gateway keys are ignored and never produce a Gateway link', () {
      final raw = v2(extra: '&token=tk&host=h.example&port=8642&https=1');
      final r = PairingLink.parse(raw);
      expect(r.version, PairingLinkVersion.v2);
      expect(r.v1, isNull);
      expect(PairingLink.tryParse(raw), isNull);
      expect(r.v2.toString(), isNot(contains('tk')));
      expect(r.v2.toString(), isNot(contains('h.example')));
    });

    test('toString, equality and hashCode never include the password', () {
      final a = PairingLink.parse(v2(pass: 'AAAA1111')).v2!;
      final b = PairingLink.parse(v2(pass: 'BBBB2222')).v2!;
      expect(a.toString(), isNot(contains('AAAA1111')));
      expect(a.toString(), contains('hasPassword: true'));
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('invalid forms', () {
      for (final raw in [
        v2(user: ''),
        v2().replaceAll('&user=admin', ''),
        v2(user: '%20%20'),
        v2(pass: ''),
        v2(pass: '%ZZ'),
        v2(pass: 'ab%2'),
        v2(label: '%G1'),
        v2(url: 'example.com'),
        v2(url: 'ftp%3A%2F%2Fexample.com'),
        v2(url: 'javascript%3Aalert(1)'),
        v2(url: 'http%3A%2F%2F'),
        v2().replaceAll('&url=http%3A%2F%2F127.0.0.1%3A9119', ''),
        v2().replaceFirst('v=2', 'v=3'),
        v2().replaceFirst('v=2', 'v='),
        '${v2()}&v=1',
        '${v2()}&url=http%3A%2F%2Fother.example',
        'hermes://pair?url=http%3A%2F%2Fx&user=a',
        'https://pair?v=2&url=http%3A%2F%2Fx&user=a',
      ]) {
        final r = PairingLink.parse(raw);
        expect(r.version, PairingLinkVersion.invalid, reason: raw);
        expect(PairingLink.tryParse(raw), isNull, reason: raw);
      }
    });

    test('v1 stays intact, with or without explicit v=1', () {
      const base = 'hermes://pair?host=10.0.0.5&port=8642&token=abc';
      for (final raw in [base, '$base&v=1']) {
        final r = PairingLink.parse(raw);
        expect(r.version, PairingLinkVersion.v1, reason: raw);
        expect(r.v2, isNull);
        expect(r.v1!.host, '10.0.0.5');
        expect(r.v1!.token, 'abc');
        expect(PairingLink.tryParse(raw), isNotNull);
      }
      expect(PairingLink.parse('nonsense').version, PairingLinkVersion.invalid);
      expect(PairingLink.parse('').version, PairingLinkVersion.invalid);
    });
  });
}
