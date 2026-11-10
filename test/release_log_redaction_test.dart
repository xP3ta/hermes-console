// SPDX-License-Identifier: GPL-3.0-only
// H8: debugPrint also writes to logcat in release builds. A few lines carry a
// full error text (`$e`) that can cite a URL with its query, a host or a
// token. In release every line goes through the redactor; debug and test
// builds keep the full text.
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/release_log.dart';

void main() {
  test('URLs, IPs, mail addresses and long tokens are masked', () {
    final line = redactLogLine(
      '[about] no se pudo abrir https://user:pw@'
      'example.com/a?token=abc123: '
      'SocketException: Connection refused (OS Error, errno = 111), '
      'address = 192.168.1.50, port = 9119 for wss://srv.example.org/api/ws '
      'mail ana@'
      'example.com key sk_'
      'live_AbCdEf0123456789AbCdEf0123',
    );
    expect(line, startsWith('[about] no se pudo abrir <url>'));
    expect(line, isNot(contains('example.com/a')));
    expect(line, isNot(contains('token=abc123')));
    expect(line, isNot(contains('192.168.1.50')));
    expect(line, isNot(contains('srv.example.org')));
    expect(line, isNot(contains('ana@')));
    expect(line, isNot(contains('AbCdEf0123456789')));
    expect(line, contains('SocketException'), reason: 'the kind stays');
  });

  test('ordinary diagnostic lines are left as they are', () {
    const plain = '[push-pair] request failed (TimeoutException)';
    expect(redactLogLine(plain), plain);
  });

  test('very long lines are cut', () {
    expect(redactLogLine('x ' * 1000).length, lessThanOrEqualTo(320));
  });

  test('the release hook redacts before printing; debug is untouched', () {
    final out = <String?>[];
    final original = debugPrint;
    addTearDown(() => debugPrint = original);
    debugPrint = (m, {wrapWidth}) => out.add(m);

    installReleaseLogRedaction(release: false);
    debugPrint('see http://10.0.0.2:8642/x');
    expect(out.last, 'see http://10.0.0.2:8642/x');

    installReleaseLogRedaction(release: true);
    debugPrint('see http://10.0.0.2:8642/x');
    expect(out.last, 'see <url>');
    debugPrint(null);
    expect(out.last, isNull);
  });
}
