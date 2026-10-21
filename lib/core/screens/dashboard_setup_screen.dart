import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../l10n/app_localizations.dart';
import '../config/flavor.dart';
import '../services/connection_manager.dart';
import '../services/mobile_oauth.dart';
import '../services/native_password_login.dart';
import '../services/server_warmup.dart';
import '../utils/api_error.dart';
import '../utils/transport_privacy.dart';
import '../widgets/console_loader.dart';
import '../design/hermes_design.dart';
import '../widgets/hermes_ui.dart' show HermesField, HermesPrimaryButton;
import 'onboarding/manual_setup_page.dart';
import 'recover_access_page.dart';

/// Existing client authority only: never creates or rotates server credentials.
class DashboardCredsResult {
  final AuthMode mode;
  final String username;
  final String password;
  final String sessionToken;
  const DashboardCredsResult({
    required this.mode,
    this.username = '',
    this.password = '',
    this.sessionToken = '',
  });
}

/// Failures whose [localizedApiError] copy is typed, localized and never
/// carries a server body or exception text. Anything else (format or state
/// errors from discovery, refused tokens) keeps this screen's own copy: the
/// generic fallback of [localizedApiError] would surface raw text.
bool _hasTypedPresentation(Object error) =>
    error is DashboardAuthException ||
    error is DashboardHttpException ||
    error is TimeoutException ||
    error is SocketException ||
    error is HandshakeException ||
    error is http.ClientException;

class DashboardSetupScreen extends StatefulWidget {
  const DashboardSetupScreen({
    super.key,
    required this.connection,
    required this.authorityCurrent,
    this.openOAuthBrowser,
    this.browserFirst = kSimpleConnectEnabled,
    this.warmupClock,
  });
  final SavedConnection connection;

  /// Immutable editor lease, including endpoint, profile and credential epochs.
  final bool Function() authorityCurrent;
  final Future<bool> Function(Uri)? openOAuthBrowser;

  /// Simple connect (QA flag): the system browser is the primary way in, also
  /// for `basic`; the password form stays behind a secondary link.
  final bool browserFirst;

  final ServerWarmupClock? warmupClock;
  @override
  State<DashboardSetupScreen> createState() => _DashboardSetupScreenState();
}

class _DashboardSetupScreenState extends State<DashboardSetupScreen>
    with WidgetsBindingObserver {
  final _user = TextEditingController();
  final _secret = TextEditingController();
  final _http = http.Client();
  bool? _authRequired;
  bool _passwordSupported = false;
  bool _nativeSupported = false;
  bool _showPasswordForm = false;
  MobileOAuthLogin? _oauth;
  NativePasswordLogin? _pwLogin;
  bool _reveal = false;
  bool _noPasswordRoute = false;
  bool _loading = true;
  bool _busy = false;
  bool _consent = false;

  /// S3: the Dashboard answered 502/503/504 (or refused right after a good
  /// answer) and Console waits, bounded, for it to boot.
  bool _starting = false;
  bool _gaveUp = false;
  bool _answered = false;
  ServerWarmup? _warmup;

  bool get _foreground {
    final state = WidgetsBinding.instance.lifecycleState;
    return state != AppLifecycleState.paused &&
        state != AppLifecycleState.hidden &&
        state != AppLifecycleState.detached;
  }

  /// Resolved against the current [Strings] at build time: failures can land
  /// while [initState] is still running, before inherited lookups are legal.
  String Function(Strings s)? _error;
  int _epoch = 0;
  bool _valid(int epoch) =>
      mounted && epoch == _epoch && widget.authorityCurrent();
  void _expireAuthority(int epoch) {
    if (!mounted || epoch != _epoch || widget.authorityCurrent()) return;
    setState(() {
      _loading = false;
      _busy = false;
      _authRequired = null;
      _nativeSupported = false;
      _error = (s) => s.dashboardSetupAuthorityChanged;
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _probe();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _warmup?.cancel();
    _epoch++;
    _oauth?.cancel();
    _pwLogin?.cancel();
    _http.close();
    _user.dispose();
    _secret.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _warmup?.setForeground(_foreground); // hidden: no probes until it returns
  }

  /// Waits (bounded) for a booting Dashboard, then repeats the read ONCE.
  Future<void> _waitForServer(int epoch, String base) async {
    final warmup = ServerWarmup(
      probe: () => dashboardHealthOk(_http, base),
      now: widget.warmupClock?.now,
      delay: widget.warmupClock?.delay,
      foreground: _foreground,
    );
    _warmup = warmup;
    setState(() {
      _loading = false;
      _starting = true;
      _gaveUp = false;
      _error = null;
    });
    final ready = await warmup.run();
    if (!_valid(epoch)) {
      _expireAuthority(epoch);
      return;
    }
    if (ready) {
      await _probe(afterWarmup: true);
    } else {
      setState(() {
        _starting = false;
        _gaveUp = true;
      });
    }
  }

  Future<void> _probe({bool afterWarmup = false}) async {
    final epoch = ++_epoch;
    _oauth?.cancel();
    _warmup?.cancel();
    setState(() {
      _starting = false;
      _gaveUp = false;
      _loading = true;
      _error = null;
      _authRequired = null;
      _passwordSupported = false;
      _nativeSupported = false;
      _noPasswordRoute = false;
      _showPasswordForm = false;
    });
    final url = widget.connection.effectiveDashboardUrl;
    if (TransportPrivacy.classify(url) ==
        TransportPrivacyClass.publicCleartext) {
      // Policy refusal, not a server failure: nothing is sent.
      setState(() {
        _loading = false;
        _error = (s) => s.commonCleartextPublic;
      });
      return;
    }
    try {
      final base = TransportPrivacy.requireAllowed(url);
      final request = http.Request('GET', Uri.parse('$base/api/status'))
        ..followRedirects = false;
      final response = await _http
          .send(request)
          .then(http.Response.fromStream)
          .timeout(const Duration(seconds: 8));
      if (!_valid(epoch)) {
        _expireAuthority(epoch);
        return;
      }
      if (response.statusCode != 200) {
        // Status only: the body is never presented.
        throw DashboardHttpException(response.statusCode);
      }
      _answered = true;
      final payload = jsonDecode(response.body);
      if (payload is! Map || payload['auth_required'] is! bool) {
        throw const FormatException('Dashboard authentication status unknown');
      }
      final required = payload['auth_required'] as bool;
      bool password = false;
      bool native = false;
      if (required) {
        final providersRequest = http.Request(
          'GET',
          Uri.parse('$base/api/auth/providers'),
        )..followRedirects = false;
        final providersResponse = await _http
            .send(providersRequest)
            .then(http.Response.fromStream)
            .timeout(const Duration(seconds: 8));
        if (!_valid(epoch)) {
          _expireAuthority(epoch);
          return;
        }
        if (providersResponse.statusCode != 200) {
          throw DashboardHttpException(providersResponse.statusCode);
        }
        {
          final providers = jsonDecode(providersResponse.body);
          if (providers is! Map ||
              providers['providers'] is! List ||
              (providers['providers'] as List).isEmpty ||
              !(providers['providers'] as List).every(
                (p) =>
                    p is Map &&
                    p['name'] is String &&
                    (p['name'] as String).isNotEmpty &&
                    p['supports_password'] is bool &&
                    (p['supports_session'] == null ||
                        p['supports_session'] is bool),
              )) {
            throw const FormatException('Dashboard provider discovery unknown');
          }
          // Existing native DashboardClient has a verified basic-password seam.
          // Other providers require native OAuth, not a made-up password route.
          password = (providers['providers'] as List).any(
            (p) =>
                p is Map &&
                p['name'] == 'basic' &&
                p['supports_password'] == true,
          );
          native =
              payload['auth_flows'] is List &&
              (payload['auth_flows'] as List).contains('native_pkce') &&
              (providers['providers'] as List).any(
                (p) =>
                    p is Map &&
                    p['supports_session'] != false &&
                    (widget.browserFirst || (p['supports_password'] != true)) &&
                    p['name'] is String &&
                    p['name'] != 'drain' &&
                    (p['name'] as String).isNotEmpty,
              );
        }
      }
      if (!_valid(epoch)) {
        _expireAuthority(epoch);
        return;
      }
      setState(() {
        _authRequired = required;
        _passwordSupported = password;
        _nativeSupported = native;
        _loading = false;
      });
    } catch (error) {
      if (!_valid(epoch)) {
        _expireAuthority(epoch);
        return;
      }
      if (widget.browserFirst &&
          !afterWarmup &&
          (isServerStartingError(error) ||
              (_answered && isConnectionRefused(error)))) {
        unawaited(_waitForServer(epoch, TransportPrivacy.requireAllowed(url)));
        return;
      }
      setState(() {
        _loading = false;
        _error = _hasTypedPresentation(error)
            ? (s) =>
                  s.dashboardSetupProbeFailedReason(localizedApiError(s, error))
            : (s) => widget.browserFirst
                  ? s.walkProbeFailed
                  : s.dashboardSetupProbeFailed;
      });
    }
  }

  bool get _requiresConsent {
    final uri = Uri.parse(widget.connection.effectiveDashboardUrl);
    final host = uri.host.toLowerCase();
    final address = InternetAddress.tryParse(host);
    final loopback = host == 'localhost' || (address?.isLoopback ?? false);
    return uri.scheme != 'https' && !loopback;
  }

  Future<void> _login() async {
    if (!widget.authorityCurrent()) {
      _expireAuthority(_epoch);
      return;
    }
    if (_busy || _authRequired == null) return;
    if (_requiresConsent && !_consent) return;
    final epoch = _epoch;
    final secret = _secret.text;
    if (secret.isEmpty || (_authRequired! && _user.text.trim().isEmpty)) return;
    final result = _authRequired!
        ? DashboardCredsResult(
            mode: AuthMode.basicAuth,
            username: _user.text.trim(),
            password: secret,
          )
        : DashboardCredsResult(
            mode: AuthMode.sessionToken,
            sessionToken: secret,
          );
    final target = widget.connection.copyWith(dashboardAuthMode: result.mode);
    final client = DashboardClient.forConnection(
      target,
      secrets: DashboardSecrets(
        username: result.username,
        password: result.password,
        sessionToken: result.sessionToken,
      ),
    );
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (result.mode == AuthMode.basicAuth) {
        await client.authenticateExistingPassword(fresh: true);
        if (!_valid(epoch)) {
          _expireAuthority(epoch);
          return;
        }
      }
      final verified = await client.apiGet(
        result.mode == AuthMode.basicAuth ? 'auth/me' : 'profiles',
      );
      if (result.mode == AuthMode.sessionToken &&
          verified['profiles'] is! List) {
        throw const FormatException('Dashboard token authority not confirmed');
      }
      if (!_valid(epoch)) {
        _expireAuthority(epoch);
        return;
      }
      if (!mounted) return;
      Navigator.of(context).pop(result);
    } catch (error) {
      if (!_valid(epoch)) {
        _expireAuthority(epoch);
        return;
      }
      // Typed auth/HTTP/network causes are told apart (401, rate limit,
      // timeout...); the typed credentials stay in the fields for a retry.
      setState(
        () => _error = _hasTypedPresentation(error)
            ? (s) =>
                  s.dashboardSetupLoginFailedReason(localizedApiError(s, error))
            : (s) => s.dashboardSetupLoginFailed,
      );
    } finally {
      client.close();
      if (_valid(epoch)) setState(() => _busy = false);
    }
  }

  /// Desktop's connection: user name + password typed here and sent to the
  /// Dashboard's own native routes, no browser. Only the session is kept.
  bool get _credentialsFirst =>
      widget.browserFirst &&
      _passwordSupported &&
      _nativeSupported &&
      !_noPasswordRoute;

  Future<void> _loginPassword() async {
    final epoch = _epoch;
    final user = _user.text.trim(), secret = _secret.text;
    if (!_valid(epoch) ||
        _busy ||
        user.isEmpty ||
        secret.isEmpty ||
        (_requiresConsent && !_consent)) {
      return;
    }
    final attempt = NativePasswordLogin();
    _pwLogin = attempt;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final session = await attempt.run(
        connectionId: widget.connection.id,
        baseUrl: widget.connection.effectiveDashboardUrl,
        username: user,
        password: secret,
        authorityCurrent: () => _valid(epoch),
        allowPrivateHttp: _consent,
      );
      if (!_valid(epoch)) {
        _expireAuthority(epoch);
        return;
      }
      if (!mounted) return;
      Navigator.of(context).pop(
        DashboardCredsResult(
          mode: AuthMode.sessionToken,
          sessionToken: session.encode(),
        ),
      );
    } catch (error) {
      if (!_valid(epoch)) {
        _expireAuthority(epoch);
        return;
      }
      final failure = error is NativePasswordLoginException
          ? error.failure
          : NativePasswordFailure.failed;
      setState(() {
        _noPasswordRoute = failure == NativePasswordFailure.unsupported;
        if (_noPasswordRoute) _secret.clear();
        _error = switch (failure) {
          NativePasswordFailure.invalidCredentials =>
            (s) => s.onb2WrongPassword,
          NativePasswordFailure.rateLimited => (s) => s.onb2TooManyTries,
          NativePasswordFailure.unsupported => (s) => s.onb2PasswordUnsupported,
          _ => (s) => s.dashboardSetupLoginFailed,
        };
      });
    } finally {
      if (identical(_pwLogin, attempt)) _pwLogin = null;
      if (_valid(epoch)) setState(() => _busy = false);
    }
  }

  List<Widget> _credentialsForm(Strings s) => [
    Text(s.onb2CredentialsIntro, key: const ValueKey('onb2-credentials-intro')),
    const SizedBox(height: HermesSpace.x3),
    HermesField(
      fieldKey: const ValueKey('onb2-user'),
      controller: _user,
      label: s.commonUser,
      autocorrect: false,
      enableSuggestions: false,
      enabled: !_busy,
      textInputAction: TextInputAction.next,
    ),
    const SizedBox(height: HermesSpace.x4),
    HermesField(
      fieldKey: const ValueKey('onb2-password'),
      controller: _secret,
      obscure: !_reveal,
      autocorrect: false,
      enableSuggestions: false,
      enableIMEPersonalizedLearning: false,
      enabled: !_busy,
      label: s.commonPassword,
      textInputAction: TextInputAction.go,
      onSubmitted: (_) => unawaited(_loginPassword()),
      suffix: IconButton(
        key: const ValueKey('onb2-password-reveal'),
        tooltip: _reveal ? s.onb2HidePassword : s.onb2ShowPassword,
        icon: Icon(
          _reveal ? Icons.visibility_off_rounded : Icons.visibility_rounded,
        ),
        onPressed: () => setState(() => _reveal = !_reveal),
      ),
    ),
    const SizedBox(height: HermesSpace.x6),
    HermesPrimaryButton(
      key: const ValueKey('onb2-password-submit'),
      label: _busy ? s.commonLoading : s.dashboardSetupSignIn,
      onTap: _busy || (_requiresConsent && !_consent) ? null : _loginPassword,
    ),
  ];

  Future<void> _loginOAuth() async {
    final epoch = _epoch;
    if (!_valid(epoch) ||
        _busy ||
        !_nativeSupported ||
        (_requiresConsent && !_consent)) {
      return;
    }
    final attempt = MobileOAuthLogin(
      openBrowser: widget.openOAuthBrowser,
      retainRefresh: widget.browserFirst,
    );
    _oauth = attempt;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final session = await attempt.run(
        connectionId: widget.connection.id,
        baseUrl: widget.connection.effectiveDashboardUrl,
        authorityCurrent: () => _valid(epoch),
        allowPrivateHttp: _consent,
      );
      if (!_valid(epoch)) {
        _expireAuthority(epoch);
        return;
      }
      if (!mounted) return;
      Navigator.of(context).pop(
        DashboardCredsResult(
          mode: AuthMode.sessionToken,
          sessionToken: session.encode(),
        ),
      );
    } catch (_) {
      if (!_valid(epoch)) {
        _expireAuthority(epoch);
        return;
      }
      // Not localizedApiError: MobileOAuthLogin folds refusal, user cancel and
      // expiry into one opaque MobileOAuthException on purpose.
      setState(
        () => _error = (s) => widget.browserFirst
            ? s.dashboardSetupBrowserIncomplete
            : s.dashboardSetupOAuthFailed,
      );
    } finally {
      attempt.cancel();
      if (identical(_oauth, attempt)) _oauth = null;
      if (_valid(epoch)) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final oauthOnly = _authRequired == true && !_passwordSupported;
    final browserFirst = widget.browserFirst && _nativeSupported;
    final credFirst = _credentialsFirst;
    final showForm =
        _authRequired != null &&
        !oauthOnly &&
        (!browserFirst || _showPasswordForm);
    return PopScope(
      canPop: !_busy,
      child: HermesPage(
        title: s.o2SignIn,
        children: [
          if (_loading) const Center(child: ConsoleLoader.large()),
          if (!_loading) ...[
            if (_starting || _gaveUp)
              Semantics(
                liveRegion: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _starting
                          ? s.serverStartingTitle
                          : s.serverStartingGaveUp,
                      key: const ValueKey('server-warmup-title'),
                    ),
                    if (_starting) Text(s.serverStartingWait),
                    if (_gaveUp && widget.browserFirst) Text(s.walkStartHint),
                    if (isNousCloudHost(
                      Uri.parse(widget.connection.effectiveDashboardUrl).host,
                    ))
                      Text(s.serverStartingCloudHint),
                  ],
                ),
              ),
            if (_starting) const Center(child: ConsoleLoader.large()),
            if (_error != null)
              Semantics(
                liveRegion: true,
                child: Text(
                  _error!(s),
                  key: const ValueKey('dashboard-login-error'),
                ),
              ),
            if (_authRequired == null && !_starting)
              HermesPrimaryButton(
                key: const ValueKey('dashboard-probe-retry'),
                label: s.commonRetry,
                onTap: _probe,
              ),
            // A dead end gets its way out: the official command page.
            if (widget.browserFirst && _authRequired == null && !_starting)
              TextButton.icon(
                key: const ValueKey('dashboard-setup-help'),
                onPressed: () => unawaited(
                  Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => const ManualSetupPage(),
                    ),
                  ),
                ),
                icon: const Icon(Icons.terminal_rounded, size: 18),
                label: Text(s.homeOfflineDashboardSetup),
              ),
            if (_requiresConsent && _authRequired != null)
              CheckboxListTile(
                value: _consent,
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                onChanged: _busy
                    ? null
                    : (v) => setState(() => _consent = v == true),
                title: Text(
                  oauthOnly
                      ? s.dashboardSetupOAuthConsent
                      : s.dashboardSetupCredentialConsent,
                ),
              ),
            if (credFirst && _authRequired != null) ..._credentialsForm(s),
            if (_nativeSupported && credFirst)
              HermesListRow(
                key: const ValueKey('dashboard-oauth-browser'),
                title: s.dashboardSetupBrowserSignIn,
                onTap: _busy || (_requiresConsent && !_consent)
                    ? null
                    : _loginOAuth,
              )
            else if (_nativeSupported)
              HermesPrimaryButton(
                key: const ValueKey('dashboard-oauth-browser'),
                label: browserFirst
                    ? s.dashboardSetupBrowserSignIn
                    : s.dashboardSetupOAuthBrowser,
                onTap: _busy || (_requiresConsent && !_consent)
                    ? null
                    : _loginOAuth,
              ),
            if (browserFirst && !credFirst && !_noPasswordRoute)
              Padding(
                padding: const EdgeInsets.only(top: HermesSpace.x2),
                child: Text(
                  s.dashboardSetupBrowserHandlesPassword,
                  key: const ValueKey('dashboard-browser-handles-password'),
                ),
              ),
            if (browserFirst &&
                !credFirst &&
                !_noPasswordRoute &&
                _passwordSupported &&
                !_showPasswordForm &&
                !_busy)
              HermesListRow(
                key: const ValueKey('dashboard-use-password-here'),
                title: s.dashboardSetupUsePasswordHere,
                onTap: () => setState(() => _showPasswordForm = true),
              ),
            if (_authRequired == true &&
                _passwordSupported &&
                !showForm &&
                !_busy)
              HermesListRow(
                key: const ValueKey('dashboard-forgot-password'),
                title: s.dashboardSetupForgotPassword,
                onTap: () => unawaited(openRecoverAccess(context)),
              ),
            if (_busy && _oauth != null && browserFirst)
              Semantics(
                liveRegion: true,
                child: Padding(
                  padding: const EdgeInsets.only(top: HermesSpace.x2),
                  child: Text(
                    '${s.dashboardSetupBrowserOpening} '
                    '${s.dashboardSetupBrowserComeBack}',
                    key: const ValueKey('dashboard-browser-opening'),
                  ),
                ),
              ),
            if (_busy && _nativeSupported)
              HermesListRow(
                title: s.commonCancel,
                onTap: () {
                  _oauth?.cancel();
                  _pwLogin?.cancel();
                },
              ),
            if (oauthOnly && !_nativeSupported)
              Semantics(
                liveRegion: true,
                child: Text(
                  s.dashboardSetupOAuthUnavailable,
                  key: const ValueKey('dashboard-oauth-unavailable'),
                ),
              ),
            if (oauthOnly && !_nativeSupported)
              HermesPrimaryButton(
                key: const ValueKey('dashboard-unsupported-return'),
                label: s.sBackToConnection,
                onTap: () => Navigator.of(context).pop(),
              ),
            if (showForm) ...[
              if (_authRequired!)
                HermesField(
                  controller: _user,
                  label: s.commonUser,
                  autocorrect: false,
                  enabled: !_busy,
                  textInputAction: TextInputAction.next,
                ),
              const SizedBox(height: HermesSpace.x4),
              HermesField(
                controller: _secret,
                obscure: true,
                autocorrect: false,
                enableSuggestions: false,
                enableIMEPersonalizedLearning: false,
                enabled: !_busy,
                label: _authRequired!
                    ? s.commonPassword
                    : s.dashboardSetupSessionToken,
              ),
              const SizedBox(height: HermesSpace.x6),
              HermesPrimaryButton(
                key: const ValueKey('dashboard-login-submit'),
                label: _busy ? s.commonLoading : s.dashboardSetupSignIn,
                onTap: _busy || (_requiresConsent && !_consent) ? null : _login,
              ),
              if (_authRequired!)
                HermesListRow(
                  key: const ValueKey('dashboard-forgot-password'),
                  title: s.dashboardSetupForgotPassword,
                  onTap: () => unawaited(openRecoverAccess(context)),
                ),
            ],
          ],
        ],
      ),
    );
  }
}
