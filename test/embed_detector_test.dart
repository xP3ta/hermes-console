// Port of the matcher contract of Hermes Desktop's embed providers. The cases
// below follow the rules quoted in the issue (http/https only, 11-char
// YouTube ids, `t`/`start` as `90` or `1h2m3s`, nocookie embed URL, disjoint
// hosts, first match wins).
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/widgets/chat/embeds/embed_detector.dart';

void main() {
  group('YouTube', () {
    const id = 'dQw4w9WgXcQ';

    test('watch, short, embed, shorts and live links share one embed url', () {
      for (final url in [
        'https://www.youtube.com/watch?v=$id',
        'https://youtube.com/watch?v=$id&feature=share',
        'https://m.youtube.com/watch?v=$id',
        'https://music.youtube.com/watch?v=$id',
        'https://youtu.be/$id',
        'https://www.youtube.com/embed/$id',
        'https://www.youtube.com/shorts/$id',
        'https://www.youtube.com/live/$id',
        'https://www.youtube-nocookie.com/embed/$id',
        'http://youtu.be/$id',
      ]) {
        final embed = detectEmbed(url);
        expect(embed, isNotNull, reason: url);
        expect(
          embed!.embedUrl,
          'https://www.youtube-nocookie.com/embed/$id?modestbranding=1&rel=0',
          reason: url,
        );
        expect(embed.provider, EmbedType.youtube);
        expect(embed.renderer, EmbedRenderer.frame);
        expect(embed.aspectRatio, 16 / 9);
        expect(embed.maxWidth, 640);
        expect(embed.sourceUrl, url);
      }
    });

    test('t and start accept seconds and h/m/s', () {
      expect(
        detectEmbed('https://youtu.be/$id?t=90')!.embedUrl,
        endsWith('&start=90'),
      );
      expect(
        detectEmbed('https://youtu.be/$id?t=1h2m3s')!.embedUrl,
        endsWith('&start=3723'),
      );
      expect(
        detectEmbed('https://www.youtube.com/watch?v=$id&start=45')!.embedUrl,
        endsWith('&start=45'),
      );
      expect(
        detectEmbed('https://youtu.be/$id?t=abc')!.embedUrl,
        isNot(contains('start')),
      );
      expect(
        detectEmbed('https://youtu.be/$id?t=0')!.embedUrl,
        isNot(contains('start')),
      );
    });

    test('ids must be exactly 11 safe characters', () {
      for (final bad in [
        'https://youtu.be/short',
        'https://youtu.be/dQw4w9WgXcQQ',
        'https://youtu.be/dQw4w9WgX!Q',
        'https://www.youtube.com/watch?v=dQw4w9WgXc',
        'https://www.youtube.com/watch',
        'https://www.youtube.com/watch?v=<script>x</script>',
      ]) {
        expect(detectEmbed(bad), isNull, reason: bad);
      }
    });
  });

  test('only http and https are considered', () {
    for (final bad in [
      'ftp://youtu.be/dQw4w9WgXcQ',
      'javascript:alert(1)',
      'file:///etc/passwd',
      'data:text/html,hi',
      'intent://youtu.be/dQw4w9WgXcQ',
      '//youtu.be/dQw4w9WgXcQ',
      'youtu.be/dQw4w9WgXcQ',
      '',
    ]) {
      expect(detectEmbed(bad), isNull, reason: bad);
    }
  });

  test('unknown or look-alike hosts never match', () {
    for (final bad in [
      'https://example.com/watch?v=dQw4w9WgXcQ',
      'https://evil-youtube.com/watch?v=dQw4w9WgXcQ',
      'https://youtube.com.evil.test/watch?v=dQw4w9WgXcQ',
      'https://notyoutu.be/dQw4w9WgXcQ',
      'https://user:pw@youtu.be/dQw4w9WgXcQ',
      'https://youtu.be:8443/dQw4w9WgXcQ',
      'https://vimeo.com.evil.test/123456',
      'https://nottwitter.com/a/status/123',
    ]) {
      expect(detectEmbed(bad), isNull, reason: bad);
    }
  });

  group('Vimeo', () {
    test('page and player links', () {
      final page = detectEmbed('https://vimeo.com/76979871')!;
      expect(page.embedUrl, 'https://player.vimeo.com/video/76979871?dnt=1');
      expect(page.provider, EmbedType.vimeo);
      expect(
        detectEmbed('https://player.vimeo.com/video/76979871')!.embedUrl,
        page.embedUrl,
      );
      expect(
        detectEmbed('https://vimeo.com/channels/staffpicks/76979871')!.embedUrl,
        page.embedUrl,
      );
    });
    test('unlisted hash is kept, junk is rejected', () {
      expect(
        detectEmbed('https://vimeo.com/76979871/abcdef1234')!.embedUrl,
        'https://player.vimeo.com/video/76979871?dnt=1&h=abcdef1234',
      );
      expect(detectEmbed('https://vimeo.com/about'), isNull);
      expect(detectEmbed('https://vimeo.com/76979871/zz'), isNull);
    });
  });

  group('Spotify', () {
    const id = '4uLU6hMCjMI75M1A2tKUQC';
    test('compact players for tracks and episodes, tall for the rest', () {
      final track = detectEmbed('https://open.spotify.com/track/$id?si=abc')!;
      expect(track.embedUrl, 'https://open.spotify.com/embed/track/$id');
      expect(track.height, 152);
      final album = detectEmbed('https://open.spotify.com/intl-es/album/$id')!;
      expect(album.embedUrl, 'https://open.spotify.com/embed/album/$id');
      expect(album.height, 352);
    });
    test('bad ids and kinds are rejected', () {
      expect(detectEmbed('https://open.spotify.com/track/short'), isNull);
      expect(detectEmbed('https://open.spotify.com/user/$id'), isNull);
    });
  });

  group('X', () {
    test('status links use the tweet renderer', () {
      for (final url in [
        'https://twitter.com/jack/status/20',
        'https://x.com/jack/status/20?s=46',
        'https://mobile.twitter.com/jack/status/20',
      ]) {
        final embed = detectEmbed(url)!;
        expect(embed.renderer, EmbedRenderer.tweet, reason: url);
        expect(embed.tweetId, '20');
        expect(embed.provider, EmbedType.twitter);
      }
      expect(detectEmbed('https://x.com/jack'), isNull);
      expect(detectEmbed('https://x.com/jack/status/abc'), isNull);
    });
  });

  test('Instagram, TikTok and Pinterest', () {
    expect(
      detectEmbed('https://www.instagram.com/p/CxYz_12-ab/')!.embedUrl,
      'https://www.instagram.com/p/CxYz_12-ab/embed/',
    );
    expect(
      detectEmbed('https://www.instagram.com/reel/CxYz_12-ab/')!.embedUrl,
      'https://www.instagram.com/reel/CxYz_12-ab/embed/',
    );
    expect(detectEmbed('https://www.instagram.com/someone/'), isNull);
    expect(
      detectEmbed(
        'https://www.tiktok.com/@user/video/7234567890123456789',
      )!.embedUrl,
      'https://www.tiktok.com/embed/v2/7234567890123456789',
    );
    expect(detectEmbed('https://www.tiktok.com/@user'), isNull);
    expect(
      detectEmbed('https://www.pinterest.com/pin/123456789/')!.embedUrl,
      'https://assets.pinterest.com/ext/embed.html?id=123456789',
    );
    expect(
      detectEmbed('https://es.pinterest.com/pin/123456789/')!.provider,
      EmbedType.pinterest,
    );
    expect(detectEmbed('https://www.pinterest.com/pin/abc/'), isNull);
  });

  group('Maps', () {
    test('Google Maps query and place links', () {
      final q = detectEmbed('https://www.google.com/maps?q=Eiffel+Tower')!;
      expect(q.provider, EmbedType.maps);
      expect(
        q.embedUrl,
        'https://www.google.com/maps?q=Eiffel%20Tower&output=embed'.replaceAll(
          '%20',
          '+',
        ),
      );
      expect(
        detectEmbed('https://www.google.com/maps/place/Louvre')!.embedUrl,
        contains('q=Louvre'),
      );
      expect(detectEmbed('https://www.google.com/search?q=maps'), isNull);
      expect(detectEmbed('https://www.google.com/maps'), isNull);
    });
    test('OpenStreetMap map fragment', () {
      final osm = detectEmbed(
        'https://www.openstreetmap.org/#map=15/48.8584/2.2945',
      )!;
      expect(osm.provider, EmbedType.maps);
      expect(osm.embedUrl, contains('marker=48.8584,2.2945'));
      expect(osm.embedUrl, startsWith('https://www.openstreetmap.org/'));
      expect(detectEmbed('https://www.openstreetmap.org/'), isNull);
      expect(
        detectEmbed('https://www.openstreetmap.org/#map=15/999/2.2945'),
        isNull,
      );
    });
  });

  test('every embed url is on the frame host allow-list', () {
    for (final url in [
      'https://youtu.be/dQw4w9WgXcQ',
      'https://vimeo.com/76979871',
      'https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC',
      'https://x.com/jack/status/20',
      'https://www.instagram.com/p/CxYz_12-ab/',
      'https://www.tiktok.com/@user/video/7234567890123456789',
      'https://www.pinterest.com/pin/123456789/',
      'https://www.google.com/maps?q=Louvre',
      'https://www.openstreetmap.org/#map=15/48.8584/2.2945',
    ]) {
      expect(isAllowedEmbedFrameUrl(detectEmbed(url)!.embedUrl), isTrue);
    }
    expect(
      isAllowedEmbedFrameUrl('http://www.youtube-nocookie.com/embed/x'),
      isFalse,
    );
    expect(isAllowedEmbedFrameUrl('https://evil.example.test/embed'), isFalse);
    expect(isAllowedEmbedFrameUrl(null), isFalse);
  });

  group('detectStandaloneEmbeds', () {
    test('finds links that are the only content of a line', () {
      final found = detectStandaloneEmbeds(
        'Look at this:\n\nhttps://youtu.be/dQw4w9WgXcQ\n\n'
        '[clip](https://vimeo.com/76979871)\n\n<https://x.com/jack/status/20>',
      );
      expect(found.map((e) => e.provider), [
        EmbedType.youtube,
        EmbedType.vimeo,
        EmbedType.twitter,
      ]);
    });
    test('ignores inline links, code fences and duplicates', () {
      final found = detectStandaloneEmbeds(
        'see https://youtu.be/dQw4w9WgXcQ for details\n\n'
        '```\nhttps://vimeo.com/76979871\n```\n\n'
        'https://youtu.be/dQw4w9WgXcQ\nhttps://youtu.be/dQw4w9WgXcQ',
      );
      expect(found.length, 1);
      expect(found.single.provider, EmbedType.youtube);
    });
    test('is capped', () {
      final text = [
        for (var i = 0; i < 9; i++) 'https://vimeo.com/7697987$i',
      ].join('\n\n');
      expect(detectStandaloneEmbeds(text).length, 3);
    });
  });
}
