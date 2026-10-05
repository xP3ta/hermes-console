/// Pure, synchronous link detection for inline rich embeds. Only `http` and
/// `https` URLs match; hosts are disjoint per provider, so the first match
/// wins. Nothing here touches the network: a descriptor only names the frame
/// Console may load after the user consents.
library;

/// Everything the user can consent to, one switch per type.
enum EmbedType {
  youtube('YouTube'),
  vimeo('Vimeo'),
  spotify('Spotify'),
  twitter('X'),
  instagram('Instagram'),
  tiktok('TikTok'),
  pinterest('Pinterest'),
  maps('Maps'),
  svg('SVG'),
  mermaid('Mermaid');

  final String label;
  const EmbedType(this.label);

  /// Link providers; `svg` and `mermaid` are code fences.
  bool get isLink => this != svg && this != mermaid;
}

enum EmbedRenderer { frame, tweet }

final class EmbedDescriptor {
  final String id;
  final String label;
  final EmbedType provider;
  final EmbedRenderer renderer;
  final String sourceUrl;
  final String? embedUrl;
  final String? tweetId;
  final double? aspectRatio;
  final double? height;
  final double? maxWidth;

  const EmbedDescriptor({
    required this.id,
    required this.label,
    required this.provider,
    required this.renderer,
    required this.sourceUrl,
    this.embedUrl,
    this.tweetId,
    this.aspectRatio,
    this.height,
    this.maxWidth,
  });

  @override
  bool operator ==(Object other) =>
      other is EmbedDescriptor &&
      other.id == id &&
      other.provider == provider &&
      other.embedUrl == embedUrl &&
      other.sourceUrl == sourceUrl;

  @override
  int get hashCode => Object.hash(id, provider, embedUrl, sourceUrl);
}

/// Hosts a frame may ever be loaded from. The card refuses anything else.
const Set<String> embedFrameHosts = {
  'www.youtube-nocookie.com',
  'player.vimeo.com',
  'open.spotify.com',
  'platform.twitter.com',
  'www.instagram.com',
  'www.tiktok.com',
  'assets.pinterest.com',
  'www.google.com',
  'www.openstreetmap.org',
};

/// True when [url] is an https frame URL on one of [embedFrameHosts].
bool isAllowedEmbedFrameUrl(String? url) {
  final uri = url == null ? null : Uri.tryParse(url);
  return uri != null &&
      uri.scheme == 'https' &&
      !uri.hasPort &&
      uri.userInfo.isEmpty &&
      embedFrameHosts.contains(uri.host);
}

final RegExp _youtubeId = RegExp(r'^[A-Za-z0-9_-]{11}$');
final RegExp _digits = RegExp(r'^\d{1,20}$');
final RegExp _spotifyId = RegExp(r'^[A-Za-z0-9]{22}$');
final RegExp _codeId = RegExp(r'^[A-Za-z0-9_-]{4,64}$');

/// Detects the embed [url] stands for, or null.
EmbedDescriptor? detectEmbed(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  if (uri.userInfo.isNotEmpty ||
      uri.hasPort && uri.port != 80 && uri.port != 443) {
    return null;
  }
  var host = uri.host.toLowerCase();
  if (host.isEmpty) return null;
  if (host.startsWith('www.')) host = host.substring(4);
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  final source = uri.toString();
  return _youtube(host, segments, uri, source) ??
      _vimeo(host, segments, source) ??
      _instagram(host, segments, source) ??
      _pinterest(host, segments, source) ??
      _tiktok(host, segments, source) ??
      _twitter(host, segments, source) ??
      _spotify(host, segments, source) ??
      _maps(host, segments, uri, source);
}

/// `90`, `90s` or `1h2m3s` to seconds; null when it is neither.
int? parseEmbedTimestamp(String? raw) {
  if (raw == null) return null;
  final value = raw.trim().toLowerCase();
  if (value.isEmpty) return null;
  final plain = RegExp(r'^(\d{1,7})s?$').firstMatch(value);
  if (plain != null) return int.parse(plain.group(1)!);
  final hms = RegExp(
    r'^(?:(\d{1,4})h)?(?:(\d{1,4})m)?(?:(\d{1,7})s)?$',
  ).firstMatch(value);
  if (hms == null) return null;
  final h = int.tryParse(hms.group(1) ?? '') ?? 0;
  final m = int.tryParse(hms.group(2) ?? '') ?? 0;
  final s = int.tryParse(hms.group(3) ?? '') ?? 0;
  return h * 3600 + m * 60 + s;
}

EmbedDescriptor? _youtube(
  String host,
  List<String> segments,
  Uri uri,
  String source,
) {
  const hosts = {
    'youtube.com',
    'm.youtube.com',
    'music.youtube.com',
    'youtu.be',
    'youtube-nocookie.com',
  };
  if (!hosts.contains(host)) return null;
  String? id;
  if (host == 'youtu.be') {
    id = segments.length == 1 ? segments.first : null;
  } else if (segments.length == 1 && segments.first == 'watch') {
    id = uri.queryParameters['v'];
  } else if (segments.length == 2 &&
      const {'embed', 'shorts', 'live', 'v'}.contains(segments.first)) {
    id = segments[1];
  }
  if (id == null || !_youtubeId.hasMatch(id)) return null;
  final start = parseEmbedTimestamp(
    uri.queryParameters['t'] ?? uri.queryParameters['start'],
  );
  return EmbedDescriptor(
    id: 'youtube:$id',
    label: 'YouTube',
    provider: EmbedType.youtube,
    renderer: EmbedRenderer.frame,
    sourceUrl: source,
    embedUrl:
        'https://www.youtube-nocookie.com/embed/$id?modestbranding=1&rel=0'
        '${start != null && start > 0 ? '&start=$start' : ''}',
    aspectRatio: 16 / 9,
    maxWidth: 640,
  );
}

EmbedDescriptor? _vimeo(String host, List<String> segments, String source) {
  String? id;
  String? hash;
  if (host == 'player.vimeo.com') {
    if (segments.length == 2 && segments.first == 'video') id = segments[1];
  } else if (host == 'vimeo.com') {
    final tail = segments.isNotEmpty && segments.first == 'channels'
        ? segments.skip(2).toList()
        : segments;
    if (tail.isNotEmpty) {
      id = tail.first;
      if (tail.length == 2 && RegExp(r'^[0-9a-f]{8,12}$').hasMatch(tail[1])) {
        hash = tail[1];
      } else if (tail.length > 1) {
        id = null;
      }
    }
  } else {
    return null;
  }
  if (id == null || !_digits.hasMatch(id)) return null;
  return EmbedDescriptor(
    id: 'vimeo:$id',
    label: 'Vimeo',
    provider: EmbedType.vimeo,
    renderer: EmbedRenderer.frame,
    sourceUrl: source,
    embedUrl:
        'https://player.vimeo.com/video/$id?dnt=1${hash != null ? '&h=$hash' : ''}',
    aspectRatio: 16 / 9,
    maxWidth: 640,
  );
}

EmbedDescriptor? _instagram(String host, List<String> segments, String source) {
  if (host != 'instagram.com') return null;
  final rest = segments.length == 3 ? segments.skip(1).toList() : segments;
  if (rest.length != 2) return null;
  const kinds = {'p', 'reel', 'reels', 'tv'};
  if (!kinds.contains(rest.first) || !_codeId.hasMatch(rest[1])) return null;
  final kind = rest.first == 'reels' ? 'reel' : rest.first;
  return EmbedDescriptor(
    id: 'instagram:${rest[1]}',
    label: 'Instagram',
    provider: EmbedType.instagram,
    renderer: EmbedRenderer.frame,
    sourceUrl: source,
    embedUrl: 'https://www.instagram.com/$kind/${rest[1]}/embed/',
    height: 560,
    maxWidth: 540,
  );
}

EmbedDescriptor? _pinterest(String host, List<String> segments, String source) {
  if (host != 'pinterest.com' && !host.endsWith('.pinterest.com')) return null;
  if (segments.length < 2 || segments.first != 'pin') return null;
  final id = segments[1];
  if (!_digits.hasMatch(id)) return null;
  return EmbedDescriptor(
    id: 'pinterest:$id',
    label: 'Pinterest',
    provider: EmbedType.pinterest,
    renderer: EmbedRenderer.frame,
    sourceUrl: source,
    embedUrl: 'https://assets.pinterest.com/ext/embed.html?id=$id',
    height: 500,
    maxWidth: 400,
  );
}

EmbedDescriptor? _tiktok(String host, List<String> segments, String source) {
  if (host != 'tiktok.com') return null;
  if (segments.length != 3 ||
      !segments.first.startsWith('@') ||
      segments[1] != 'video' ||
      !_digits.hasMatch(segments[2])) {
    return null;
  }
  final id = segments[2];
  return EmbedDescriptor(
    id: 'tiktok:$id',
    label: 'TikTok',
    provider: EmbedType.tiktok,
    renderer: EmbedRenderer.frame,
    sourceUrl: source,
    embedUrl: 'https://www.tiktok.com/embed/v2/$id',
    height: 740,
    maxWidth: 605,
  );
}

EmbedDescriptor? _twitter(String host, List<String> segments, String source) {
  const hosts = {'twitter.com', 'x.com', 'mobile.twitter.com'};
  if (!hosts.contains(host)) return null;
  if (segments.length < 3 || segments[1] != 'status') return null;
  final id = segments[2];
  if (!_digits.hasMatch(id)) return null;
  return EmbedDescriptor(
    id: 'twitter:$id',
    label: 'X',
    provider: EmbedType.twitter,
    renderer: EmbedRenderer.tweet,
    sourceUrl: source,
    tweetId: id,
    embedUrl: 'https://platform.twitter.com/embed/Tweet.html?id=$id&dnt=true',
    height: 450,
    maxWidth: 550,
  );
}

EmbedDescriptor? _spotify(String host, List<String> segments, String source) {
  if (host != 'open.spotify.com') return null;
  final rest = segments.isNotEmpty && segments.first.startsWith('intl-')
      ? segments.skip(1).toList()
      : segments;
  if (rest.length != 2) return null;
  const kinds = {'track', 'album', 'playlist', 'episode', 'show', 'artist'};
  if (!kinds.contains(rest.first) || !_spotifyId.hasMatch(rest[1])) return null;
  final compact = rest.first == 'track' || rest.first == 'episode';
  return EmbedDescriptor(
    id: 'spotify:${rest.first}:${rest[1]}',
    label: 'Spotify',
    provider: EmbedType.spotify,
    renderer: EmbedRenderer.frame,
    sourceUrl: source,
    embedUrl: 'https://open.spotify.com/embed/${rest.first}/${rest[1]}',
    height: compact ? 152 : 352,
    maxWidth: 640,
  );
}

EmbedDescriptor? _maps(
  String host,
  List<String> segments,
  Uri uri,
  String source,
) {
  if (host == 'openstreetmap.org') {
    final match = RegExp(
      r'map=\d{1,2}/(-?\d{1,2}(?:\.\d+)?)/(-?\d{1,3}(?:\.\d+)?)',
    ).firstMatch(uri.fragment);
    final lat = double.tryParse(
      match?.group(1) ?? uri.queryParameters['mlat'] ?? '',
    );
    final lon = double.tryParse(
      match?.group(2) ?? uri.queryParameters['mlon'] ?? '',
    );
    if (lat == null || lon == null || lat.abs() > 90 || lon.abs() > 180) {
      return null;
    }
    const d = 0.01;
    return EmbedDescriptor(
      id: 'openstreetmap:$lat,$lon',
      label: 'OpenStreetMap',
      provider: EmbedType.maps,
      renderer: EmbedRenderer.frame,
      sourceUrl: source,
      embedUrl:
          'https://www.openstreetmap.org/export/embed.html?bbox='
          '${lon - d},${lat - d},${lon + d},${lat + d}'
          '&layer=mapnik&marker=$lat,$lon',
      height: 320,
      maxWidth: 640,
    );
  }
  final googleMaps =
      (host == 'google.com' &&
          segments.isNotEmpty &&
          segments.first == 'maps') ||
      (host == 'maps.google.com');
  if (!googleMaps) return null;
  String? query = uri.queryParameters['q'] ?? uri.queryParameters['query'];
  if (query == null || query.trim().isEmpty) {
    final place = segments.indexOf('place');
    if (place >= 0 && place + 1 < segments.length) query = segments[place + 1];
  }
  query = query?.replaceAll('+', ' ').trim();
  if (query == null || query.isEmpty || query.length > 200) return null;
  return EmbedDescriptor(
    id: 'googlemaps:$query',
    label: 'Google Maps',
    provider: EmbedType.maps,
    renderer: EmbedRenderer.frame,
    sourceUrl: source,
    embedUrl:
        'https://www.google.com/maps?q=${Uri.encodeQueryComponent(query)}&output=embed',
    height: 320,
    maxWidth: 640,
  );
}

final RegExp _bareUrl = RegExp(r'^<?(https?://[^\s<>()]+)>?$');
final RegExp _linkOnly = RegExp(r'^\[[^\]]*\]\((https?://[^\s()]+)\)$');

/// Embeds whose link is the only content of a paragraph of [markdown], in
/// order, without duplicates and outside code fences, at most [limit].
List<EmbedDescriptor> detectStandaloneEmbeds(String markdown, {int limit = 3}) {
  final found = <EmbedDescriptor>[];
  var inFence = false;
  for (final raw in markdown.split('\n')) {
    final line = raw.trim();
    if (line.startsWith('```') || line.startsWith('~~~')) {
      inFence = !inFence;
      continue;
    }
    if (inFence || line.isEmpty) continue;
    final url =
        _bareUrl.firstMatch(line)?.group(1) ??
        _linkOnly.firstMatch(line)?.group(1);
    if (url == null) continue;
    final embed = detectEmbed(url);
    if (embed != null && !found.contains(embed)) {
      found.add(embed);
      if (found.length >= limit) break;
    }
  }
  return found;
}
