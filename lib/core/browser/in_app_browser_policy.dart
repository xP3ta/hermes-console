import 'package:webview_flutter/webview_flutter.dart';

import '../widgets/artifact_viewer/artifact_html_policy.dart';

// Security and address rules of the in-app browser, copied from Hermes
// Desktop's Browser tab (`apps/desktop/src/app/chat/right-rail/
// preview-pane.tsx`, `preview-browser-bar.tsx`, `src/lib/preview-external.ts`)
// and narrowed where the brief asks for less:
//
// * the WebView only ever shows `http`/`https` pages: every other scheme
//   (`intent:`, `market:`, `tel:`, `file:`, `javascript:` …) is refused and
//   never launched;
// * guest content never opens anything by itself (Desktop `AGENTS.md`,
//   GHSA-9f4c-93c8-jc8g): no popup ever appears and nothing leaves the app
//   unless the user taps «Abrir en el navegador», which only hands over an
//   `http`/`https` address;
// * no JavaScript channel is ever added, so a page cannot call into the app.

/// Hosts that mean "the machine this resolved on" (Desktop
/// `electron/preview-reach.ts`, `LOOPBACK_HOSTS`).
const Set<String> _loopbackHosts = {
  'localhost',
  '127.0.0.1',
  '0.0.0.0',
  '::1',
};

/// Same test Desktop's address bar uses to pick `http` for a bare loopback
/// host (`preview-browser-bar.tsx`, `normalizePreviewAddress`).
final RegExp _bareLoopback = RegExp(
  r'^(localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\])(?::\d+)?(?:[/?#]|$)',
  caseSensitive: false,
);

/// Schemes recognised as "the user typed a scheme" rather than a host and a
/// port (`localhost:5173`). Desktop's list plus the mobile ones a page or a
/// person may try on Android.
final RegExp _typedScheme = RegExp(
  r'^(about|blob|chrome|content|data|devtools|file|ftp|https?|intent|'
  r'javascript|mailto|market|sms|tel|view-source):',
  caseSensitive: false,
);

final RegExp _whitespace = RegExp(r'\s');

/// An absolute `http`/`https` address with a host: the only thing the
/// browser loads and the only thing it ever hands to another app.
bool isBrowsableWebUri(Uri uri) =>
    (uri.scheme == 'http' || uri.scheme == 'https') && uri.host.isNotEmpty;

/// True for an address on the device's own loopback. On a phone it can never
/// be the agent's dev server: Desktop explains the same mismatch against a
/// remote gateway (`isRemoteLoopbackUrl`), and Console is always remote.
bool isLoopbackBrowserUrl(String url) {
  final uri = Uri.tryParse(url);
  return uri != null && _loopbackHosts.contains(uri.host.toLowerCase());
}

/// What the user typed, as an address the browser can load, or `null`.
///
/// Desktop's ladder: a bare loopback host gets `http`, any other bare host
/// gets `https`, and junk that does not parse never navigates. Narrower than
/// Desktop: only `http`/`https` survive (Desktop also lets `about:` and
/// `file:` through because there the user owns the machine).
Uri? normalizeBrowserAddress(String value) {
  final address = value.trim();
  if (address.isEmpty) return null;
  final scheme = _typedScheme.firstMatch(address)?.group(1)?.toLowerCase();
  if (scheme != null && scheme != 'http' && scheme != 'https') return null;
  final candidate = scheme != null
      ? address
      : '${_bareLoopback.hasMatch(address) ? 'http' : 'https'}://$address';
  final uri = Uri.tryParse(candidate);
  if (uri == null || !isBrowsableWebUri(uri)) return null;
  // Dart percent-encodes what a browser would reject in a host.
  if (_whitespace.hasMatch(uri.host) || uri.host.contains('%')) return null;
  return uri;
}

/// What the address bar does with what the user typed, like any browser:
/// an address navigates, anything else is a web search.
///
/// - `http`/`https` typed: navigates (through [normalizeBrowserAddress]).
/// - Any other typed scheme (`javascript:`, `file:`, `data:`…): nothing at all,
///   never a search either.
/// - No spaces and it reads as a host (a dot, an IPv4/IPv6 literal, loopback,
///   a domain with a port): navigates, `https` (`http` for loopback).
/// - A word with no dot («youtube»), or any text with spaces: a Google search.
///
/// The agent's browser control keeps [normalizeBrowserAddress] and its
/// narrower rules; only the person's address bar searches.
Uri? browserBarTarget(String value) {
  final text = value.trim();
  if (text.isEmpty) return null;
  if (_typedScheme.hasMatch(text)) return normalizeBrowserAddress(text);
  if (_readsAsHost(text)) return normalizeBrowserAddress(text);
  return Uri.https('www.google.com', '/search', {'q': text});
}

/// A host the way a browser's bar reads one: no whitespace and either a
/// bracketed IPv6 literal, loopback, or a dotted name (IPv4 included), with an
/// optional port, path, query or fragment.
bool _readsAsHost(String text) {
  if (_whitespace.hasMatch(text)) return false;
  if (_bareLoopback.hasMatch(text)) return true;
  final authority = text.split(RegExp(r'[/?#]')).first;
  if (authority.startsWith('[')) return RegExp(r'^\[[0-9a-fA-F:.]+\](:\d{1,5})?$').hasMatch(authority);
  final host = authority.split('@').last.split(':').first;
  return host.contains('.') && !host.startsWith('.') && !host.endsWith('.');
}

/// The page the WebView may move to. The main frame only goes to `http` and
/// `https`; a frame inside the page may also use the inert `about:`, `data:`
/// and `blob:` documents pages build themselves. Anything else is refused and
/// nothing is launched: there is no side effect here at all.
NavigationDecision inAppBrowserNavigationDecision(NavigationRequest request) {
  final uri = Uri.tryParse(request.url);
  if (uri == null) return NavigationDecision.prevent;
  if (isBrowsableWebUri(uri)) return NavigationDecision.navigate;
  if (!request.isMainFrame &&
      (uri.scheme == 'about' || uri.scheme == 'data' || uri.scheme == 'blob')) {
    return NavigationDecision.navigate;
  }
  return NavigationDecision.prevent;
}

/// The address «Abrir en el navegador» hands to the system browser: the page
/// on screen, only when it is `http`/`https` (Desktop `admitPreviewExternalUrl`
/// and `browserTabExternalUrl`). `null` disables the action.
Uri? browserExternalUri(String url) {
  final uri = Uri.tryParse(url.trim());
  return uri != null && isBrowsableWebUri(uri) ? uri : null;
}

/// [url] as the error state shows it: without `user:password@`, which a
/// page could put in an address and must never be painted on screen.
String browserDisplayUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.userInfo.isEmpty) return url;
  return uri.replace(userInfo: '').toString();
}

/// Title of a failed load (Desktop `loadErrorTitle`, without its Vite
/// module-script case, which needs the page console Console does not read).
///
/// [cleartextBlocked] has no Desktop counterpart: the app's manifest refuses
/// cleartext (`usesCleartextTraffic="false"`), so every `http://` page (typed,
/// or reached by a redirect) fails with `ERR_CLEARTEXT_NOT_PERMITTED`. It gets
/// its own explanation and offers the system browser (REVIEW-F3 P2-2).
enum InAppBrowserErrorKind { cleartextBlocked, serverNotFound, failedToLoad }

InAppBrowserErrorKind classifyBrowserLoadError(String description) {
  final lower = description.toLowerCase();
  if (lower.contains('err_cleartext_not_permitted')) {
    return InAppBrowserErrorKind.cleartextBlocked;
  }
  if (lower.contains('connection') ||
      lower.contains('refused') ||
      lower.contains('not found')) {
    return InAppBrowserErrorKind.serverNotFound;
  }
  return InAppBrowserErrorKind.failedToLoad;
}

/// Locks the WebView down before any page loads: the artifact viewer's
/// platform settings (no file or `content:` access, no geolocation, no mixed
/// content, media only after a gesture, no file chooser) with JavaScript on,
/// because this one shows real web pages. Camera/microphone requests are
/// denied where the controller is built ([denyArtifactPermissionRequest]).
/// The Android plugin turns `window.open`/`target=_blank` into a request on
/// [navigationDelegate], so a "new window" is at most a navigation of this
/// same WebView: never a popup, never another app.
Future<void> configureInAppBrowserWebView(
  WebViewController controller, {
  required NavigationDelegate navigationDelegate,
  ArtifactWebViewSettingsFactory settingsFor = defaultArtifactWebViewSettings,
}) async {
  await controller.setJavaScriptMode(JavaScriptMode.disabled);
  await controller.setNavigationDelegate(navigationDelegate);
  await controller.enableZoom(true);
  final settings = settingsFor(controller);
  if (settings != null) {
    await settings.setAllowFileAccess(false);
    await settings.setAllowContentAccess(false);
    await settings.setGeolocationEnabled(false);
    await settings.denyGeolocationPrompts();
    await settings.setMixedContentNeverAllow();
    await settings.setMediaPlaybackRequiresUserGesture(true);
    await settings.refuseFileChooser();
  }
  await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
}
