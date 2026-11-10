import 'dart:convert';

/// Host of the virtual HTTPS origin that serves the vendored noVNC page.
///
/// Android's WebViewAssetLoader answers this host from the app assets, so
/// the page is not cleartext and is not requested from the network.
const String screenAssetHost = 'appassets.androidplatform.net';

/// Method channel that installs the asset loader on the takeover WebView.
const String screenAssetChannelName = 'hermes/screen_assets';

/// `bridge.html` on [screenAssetHost] with overlay [copy].
///
/// The display websocket (and its single-use ticket) is never part of this
/// URL: it is handed to the loaded page with [screenConnectScript], so it
/// stays out of the WebView history and of page-load logs (REVIEW-PR210 P4).
Uri screenAssetPageUri({Map<String, String> copy = const {}}) {
  final query = <String, String>{};
  for (final entry in copy.entries) {
    if (entry.key.isEmpty || entry.value.isEmpty) continue;
    query[entry.key] = entry.value;
  }
  return Uri(
    scheme: 'https',
    host: screenAssetHost,
    path: '/assets/novnc/bridge.html',
    queryParameters: query.isEmpty ? null : query,
  );
}

/// Script that connects the loaded bridge page to [wsUrl]. Run once the page
/// says `ready`; the URL is JSON-encoded, never spliced in raw.
String screenConnectScript(String wsUrl) =>
    'window.hermesScreen && window.hermesScreen.connect(${jsonEncode(wsUrl)})';
