import 'package:flutter/widgets.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

/// In-memory WebView platform for widget tests (webview_flutter's documented
/// approach: replace [WebViewPlatform.instance]). It records every setting
/// the viewer applies and lets a test drive navigation requests the way the
/// native WebViewClient would.
class FakeWebViewPlatform extends WebViewPlatform {
  final List<FakeWebViewController> controllers = [];
  final List<FakeNavigationDelegate> delegates = [];

  FakeWebViewController get last => controllers.last;

  /// When set, every controller created afterwards waits on it inside
  /// `enableZoom`, i.e. while the viewer is still configuring the WebView.
  Future<void>? holdConfigure;

  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) {
    final controller = FakeWebViewController(params)
      ..configureGate = holdConfigure;
    controllers.add(controller);
    return controller;
  }

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) {
    final delegate = FakeNavigationDelegate(params);
    delegates.add(delegate);
    return delegate;
  }

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) => FakeWebViewWidget(params);

  @override
  PlatformWebViewCookieManager createPlatformCookieManager(
    PlatformWebViewCookieManagerCreationParams params,
  ) => throw UnimplementedError();
}

class FakeWebViewController extends PlatformWebViewController {
  FakeWebViewController(super.params) : super.implementation();

  final List<JavaScriptMode> javaScriptModes = [];
  final List<String> loadedHtml = [];
  final List<String> loadedFiles = [];
  final List<Uri> loadedRequests = [];
  FakeNavigationDelegate? navigationDelegate;
  void Function(PlatformWebViewPermissionRequest request)? permissionHandler;
  bool? zoomEnabled;
  Future<void>? configureGate;

  JavaScriptMode? get javaScriptMode =>
      javaScriptModes.isEmpty ? null : javaScriptModes.last;

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async =>
      javaScriptModes.add(javaScriptMode);

  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate handler,
  ) async => navigationDelegate = handler as FakeNavigationDelegate;

  @override
  Future<void> loadHtmlString(String html, {String? baseUrl}) async =>
      loadedHtml.add(html);

  @override
  Future<void> loadFile(String absoluteFilePath) async =>
      loadedFiles.add(absoluteFilePath);

  @override
  Future<void> loadRequest(LoadRequestParams params) async =>
      loadedRequests.add(params.uri);

  @override
  Future<void> enableZoom(bool enabled) async {
    await configureGate;
    zoomEnabled = enabled;
  }

  /// Every JavaScript bridge the code under test tried to expose.
  final List<String> javaScriptChannels = [];

  @override
  Future<void> addJavaScriptChannel(
    JavaScriptChannelParams javaScriptChannelParams,
  ) async => javaScriptChannels.add(javaScriptChannelParams.name);

  @override
  Future<void> setOnPlatformPermissionRequest(
    void Function(PlatformWebViewPermissionRequest request) onPermissionRequest,
  ) async => permissionHandler = onPermissionRequest;
}

class FakeNavigationDelegate extends PlatformNavigationDelegate {
  FakeNavigationDelegate(super.params) : super.implementation();

  NavigationRequestCallback? onNavigationRequest;

  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback onNavigationRequest,
  ) async => this.onNavigationRequest = onNavigationRequest;

  @override
  Future<void> setOnPageStarted(PageEventCallback onPageStarted) async {}

  @override
  Future<void> setOnPageFinished(PageEventCallback onPageFinished) async {}

  @override
  Future<void> setOnProgress(ProgressCallback onProgress) async {}

  @override
  Future<void> setOnWebResourceError(
    WebResourceErrorCallback onWebResourceError,
  ) async {}

  @override
  Future<void> setOnUrlChange(UrlChangeCallback onUrlChange) async {}

  @override
  Future<void> setOnHttpAuthRequest(
    HttpAuthRequestCallback onHttpAuthRequest,
  ) async {}

  @override
  Future<void> setOnHttpError(HttpResponseErrorCallback onHttpError) async {}

  /// Simulates the native WebViewClient asking whether to follow [url].
  Future<NavigationDecision> request(
    String url, {
    bool mainFrame = true,
  }) async => await onNavigationRequest!(
    NavigationRequest(url: url, isMainFrame: mainFrame),
  );
}

class FakeWebViewWidget extends PlatformWebViewWidget {
  FakeWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) =>
      const SizedBox.expand(key: ValueKey('fake-platform-webview'));
}

class FakePermissionRequest extends PlatformWebViewPermissionRequest {
  FakePermissionRequest()
    : super(types: {WebViewPermissionResourceType.camera});

  final List<String> outcomes = [];

  bool get granted => outcomes.contains('grant');
  bool get denied => outcomes.contains('deny');

  @override
  Future<void> grant() async => outcomes.add('grant');

  @override
  Future<void> deny() async => outcomes.add('deny');
}

/// Records `launchUrl` calls made through url_launcher.
class FakeUrlLauncher extends UrlLauncherPlatform
    with MockPlatformInterfaceMixin {
  final List<(String, PreferredLaunchMode)> launches = [];

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> canLaunch(String url) async => true;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launches.add((url, options.mode));
    return true;
  }
}
