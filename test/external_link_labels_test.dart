// Port of Hermes Desktop's link labels (`lib/external-link.tsx`), with the
// cases of its own test (`external-link.test.tsx`).
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/utils/external_link_labels.dart';

void main() {
  test('URL fallbacks read as host + path (Desktop case)', () {
    expect(
      hostPathLabel(
        'https://www.getyourguide.com/culebra-island-l145468/'
        'from-fajardo-full-day-cordillera-islands-catamaran-tour-t19894/',
      ),
      'getyourguide.com/culebra-island-l145468/'
      'from-fajardo-full-day-cordillera-islands-catamaran-tour-t19894',
    );
    expect(hostPathLabel('https://example.com/'), 'example.com');
    expect(hostPathLabel('not a url'), 'not a url');
  });

  test('readable titles come from the URL slug (Desktop case)', () {
    expect(
      urlSlugTitleLabel(
        'https://www.getyourguide.com/fajardo-l882/'
        'from-fajardo-icacos-island-full-day-catamaran-trip-t19891/',
      ),
      'From Fajardo Icacos Island Full Day Catamaran Trip',
    );
    expect(
      urlSlugTitleLabel('https://example.com/blog/some-guide.html'),
      'Some Guide',
    );
  });

  test('identifiers keep their casing, words title-case (#121321)', () {
    expect(
      urlSlugTitleLabel('https://example.com/releases/tag/v1.0.1'),
      'v1.0.1',
    );
    expect(
      urlSlugTitleLabel('https://example.com/repository/blob/main/README.md'),
      'README.md',
    );
    expect(
      urlSlugTitleLabel('https://example.com/p/quantumcomputing'),
      'Quantumcomputing',
    );
  });

  test('ids and short slugs fall back to host + path', () {
    expect(
      urlSlugTitleLabel('https://example.com/123/ab'),
      'example.com/123/ab',
    );
    expect(urlSlugTitleLabel('https://example.com'), 'example.com');
  });

  test('bare domains get https; hosts lose www.', () {
    expect(
      normalizeExternalUrl(' example.com/docs '),
      'https://example.com/docs',
    );
    expect(normalizeExternalUrl('HTTP://x.org'), 'HTTP://x.org');
    expect(shortHostLabel('https://www.github.com/a'), 'github.com');
    expect(shortHostLabel('plain'), 'plain');
  });

  test('error and bot-check pages are not titles (Desktop filter)', () {
    expect(isUsableLinkTitle('Guía de Hermes'), isTrue);
    expect(isUsableLinkTitle('  '), isFalse);
    expect(isUsableLinkTitle('Just a moment...'), isFalse);
    expect(isUsableLinkTitle('404 Not Found'), isFalse);
    expect(isUsableLinkTitle('Access denied'), isFalse);
  });
}
