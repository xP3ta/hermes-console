import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/browser/in_app_browser_policy.dart';

// The address bar behaves like a browser: an address navigates, anything else
// is a web search. Only http/https ever load; the agent's own browser control
// keeps normalizeBrowserAddress and its narrower rules.

void main() {
  group('addresses navigate', () {
    test('a dotted host gets https', () {
      expect(browserBarTarget('youtube.com').toString(), 'https://youtube.com');
      expect(
        browserBarTarget('  example.com/path?q=1 ').toString(),
        'https://example.com/path?q=1',
      );
      expect(browserBarTarget('www.rae.es').toString(), 'https://www.rae.es');
    });

    test('loopback and local hosts, with ports', () {
      expect(
        browserBarTarget('localhost:3000').toString(),
        'http://localhost:3000',
      );
      expect(
        browserBarTarget('127.0.0.1:8080/app').toString(),
        'http://127.0.0.1:8080/app',
      );
      expect(browserBarTarget('[::1]:3000')?.scheme, 'http');
      expect(
        browserBarTarget('192.168.1.5:8080').toString(),
        'https://192.168.1.5:8080',
      );
      expect(
        browserBarTarget('miservidor.local:8443/x').toString(),
        'https://miservidor.local:8443/x',
      );
    });

    test('a typed http/https scheme navigates as typed', () {
      expect(browserBarTarget('https://x.dev')?.scheme, 'https');
      expect(browserBarTarget('http://x.dev')?.scheme, 'http');
      expect(browserBarTarget('HTTP://Example.com')?.host, 'example.com');
    });
  });

  group('everything else searches', () {
    test('a single word with no dot is a search, not https://word', () {
      final uri = browserBarTarget('youtube')!;
      expect(uri.scheme, 'https');
      expect(uri.host, 'www.google.com');
      expect(uri.path, '/search');
      expect(uri.queryParameters['q'], 'youtube');
    });

    test('text with spaces is a search, encoded', () {
      final uri = browserBarTarget('mi gato & su perro')!;
      expect(uri.host, 'www.google.com');
      expect(uri.queryParameters['q'], 'mi gato & su perro');
      expect(uri.toString(), isNot(contains(' ')));
    });

    test('looks like a name but has spaces: still a search', () {
      expect(browserBarTarget('example.com es lento')!.host, 'www.google.com');
    });

    test('a word with a port but no dot is a search (not loopback)', () {
      expect(browserBarTarget('youtube:8080')!.host, 'www.google.com');
    });
  });

  group('never navigates, never searches', () {
    for (final typed in [
      '',
      '   ',
      'javascript:alert(1)',
      'JavaScript:alert(1)',
      'file:///etc/passwd',
      'data:text/html,<h1>x</h1>',
      'intent://scan/#Intent;scheme=zxing;end',
      'chrome://settings',
      'about:blank',
      'view-source:https://x.dev',
      'mailto:a@b.c',
      'tel:123',
    ]) {
      test('«$typed»', () {
        expect(browserBarTarget(typed), isNull);
      });
    }

    test('only http/https ever come out', () {
      for (final typed in [
        'youtube',
        'youtube.com',
        'mi gato',
        'localhost:3000',
        '[::1]:80',
        'a b c',
        'x.y/z',
      ]) {
        final uri = browserBarTarget(typed)!;
        expect(isBrowsableWebUri(uri), isTrue, reason: typed);
      }
    });
  });

  group('the agent keeps its narrower rule', () {
    test('a single word is still not an address for the agent', () {
      expect(normalizeBrowserAddress('youtube').toString(), 'https://youtube');
      expect(normalizeBrowserAddress('javascript:alert(1)'), isNull);
    });
  });
}
