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
  Future<void> setBackgroundColor(Color color) async {}

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

  /// Callbacks registered with [addJavaScriptChannel], keyed by channel name.
  final Map<String, void Function(JavaScriptMessage)> channelHandlers = {};

  /// Every `runJavaScript` / `runJavaScriptReturningResult` script.
  final List<String> javaScriptCalls = [];

  /// What `runJavaScriptReturningResult` answers for a script ('' default).
  Object Function(String script)? javaScriptResponder;

  /// What `getTitle` answers.
  String? title;

  @override
  Future<void> runJavaScript(String javaScript) async =>
      javaScriptCalls.add(javaScript);

  @override
  Future<Object> runJavaScriptReturningResult(String javaScript) async {
    javaScriptCalls.add(javaScript);
    return javaScriptResponder?.call(javaScript) ?? '';
  }

  @override
  Future<String?> getTitle() async => title;

  @override
  Future<void> addJavaScriptChannel(
    JavaScriptChannelParams javaScriptChannelParams,
  ) async {
    javaScriptChannels.add(javaScriptChannelParams.name);
    channelHandlers[javaScriptChannelParams.name] =
        javaScriptChannelParams.onMessageReceived;
  }

  @override
  Future<void> setOnPlatformPermissionRequest(
    void Function(PlatformWebViewPermissionRequest request) onPermissionRequest,
  ) async => permissionHandler = onPermissionRequest;

  /// History the test sets; the WebView answers from it.
  bool canGoBackValue = false;
  bool canGoForwardValue = false;
  int goBackCalls = 0;
  int goForwardCalls = 0;
  int reloadCalls = 0;

  @override
  Future<bool> canGoBack() async => canGoBackValue;

  @override
  Future<bool> canGoForward() async => canGoForwardValue;

  @override
  Future<void> goBack() async => goBackCalls++;

  @override
  Future<void> goForward() async => goForwardCalls++;

  @override
  Future<void> reload() async => reloadCalls++;
}

class FakeNavigationDelegate extends PlatformNavigationDelegate {
  FakeNavigationDelegate(super.params) : super.implementation();

  NavigationRequestCallback? onNavigationRequest;

  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback onNavigationRequest,
  ) async => this.onNavigationRequest = onNavigationRequest;

  PageEventCallback? onPageStarted;
  PageEventCallback? onPageFinished;
  WebResourceErrorCallback? onWebResourceError;
  UrlChangeCallback? onUrlChange;

  @override
  Future<void> setOnPageStarted(PageEventCallback onPageStarted) async =>
      this.onPageStarted = onPageStarted;

  @override
  Future<void> setOnPageFinished(PageEventCallback onPageFinished) async =>
      this.onPageFinished = onPageFinished;

  @override
  Future<void> setOnProgress(ProgressCallback onProgress) async {}

  @override
  Future<void> setOnWebResourceError(
    WebResourceErrorCallback onWebResourceError,
  ) async => this.onWebResourceError = onWebResourceError;

  @override
  Future<void> setOnUrlChange(UrlChangeCallback onUrlChange) async =>
      this.onUrlChange = onUrlChange;

  /// Simulates a main-frame load that starts and finishes at [url].
  void load(String url) {
    onPageStarted?.call(url);
    onUrlChange?.call(UrlChange(url: url));
    onPageFinished?.call(url);
  }

  /// Simulates the native client reporting a failed load.
  void fail(
    String url, {
    String description = 'net::ERR_NAME_NOT_RESOLVED',
    int code = -2,
    bool mainFrame = true,
  }) {
    if (mainFrame) onPageStarted?.call(url);
    onWebResourceError?.call(
      WebResourceError(
        errorCode: code,
        description: description,
        isForMainFrame: mainFrame,
        url: url,
      ),
    );
    if (mainFrame) onPageFinished?.call(url);
  }

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
