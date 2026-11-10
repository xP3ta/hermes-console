// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab
//
// Linking a provider account from the phone: the Dashboard's device-code
// routes (`POST /api/providers/oauth/{id}/start`, `GET …/poll/{session}`,
// `DELETE /api/providers/oauth/sessions/{session}`, `DELETE
// /api/providers/oauth/{id}`). The server talks to the provider; this side
// only shows the code, opens the page and asks, at a bounded pace, whether
// the person has finished.
//
// The state sequence (starting, code shown and waiting, approved or a
// terminal verdict with a retry) follows the one the Hermes Desktop client
// renders for the same routes (hermes-agent, MIT licensed); reimplemented
// here in Dart.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'connection_manager.dart';

/// Where a link attempt is.
enum AccountLinkPhase {
  /// Nothing started yet.
  idle,

  /// `start` is on its way.
  starting,

  /// The code is shown; the server is asked at intervals.
  waiting,

  /// The server saved the credential.
  approved,

  /// The person declined in the browser.
  denied,

  /// The code ran out (locally or on the server) before it was used.
  expired,

  /// Cancelled from this side.
  cancelled,

  /// The server could not finish; see [ProviderAccountLink.retryable].
  failed,

  /// This phone could not reach the Dashboard.
  offline,

  /// The Dashboard has no such route (an older server).
  unsupported,

  /// The connection is read-only: nothing is sent.
  readOnly,
}

/// What `start` handed over: enough to show and to poll, never the device
/// secret (the server keeps that).
@immutable
class AccountLinkCode {
  const AccountLinkCode({
    required this.sessionId,
    required this.userCode,
    required this.verificationUrl,
    required this.pollInterval,
    required this.expiresAt,
    this.unvettedUrl = '',
  });

  final String sessionId;

  /// The short code the person may have to type. The only secret-like value
  /// this side ever shows, and only because the person needs it.
  final String userCode;

  /// The page to open; already normalized and vetted by the policy.
  final Uri? verificationUrl;

  /// A page the policy would not launch (another host, plain http): shown as
  /// text the person may copy, never opened from here. Empty otherwise.
  final String unvettedUrl;
  final Duration pollInterval;
  final DateTime expiresAt;
}

/// Which pages a link flow may open in the system browser.
///
/// Nous Portal: https on `nousresearch.com` or one of its subdomains, and
/// nothing else, whatever the server names. Any other provider: https on
/// any host (its sign-in page is wherever that provider keeps it), or plain
/// http only on the Dashboard's own origin. Never an address carrying
/// credentials.
@immutable
class AccountLinkUrlPolicy {
  const AccountLinkUrlPolicy({this.nousOnly = false, this.dashboardOrigin});

  /// The Nous Portal policy.
  static const nous = AccountLinkUrlPolicy(nousOnly: true);

  /// The domain every Nous Portal page lives on.
  static const nousDomain = 'nousresearch.com';

  /// Only [nousDomain] and its subdomains.
  final bool nousOnly;

  /// The Dashboard's base URL: the one origin plain http may point at.
  final String? dashboardOrigin;

  /// The policy for [providerId] behind the Dashboard at [dashboardBaseUrl].
  factory AccountLinkUrlPolicy.forProvider(
    String providerId, {
    String? dashboardBaseUrl,
  }) => providerId == 'nous'
      ? nous
      : AccountLinkUrlPolicy(dashboardOrigin: dashboardBaseUrl);

  /// The vetted page, or null when [raw] may not be opened.
  Uri? allow(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
      return null;
    }
    final host = uri.host.toLowerCase();
    if (nousOnly) {
      if (uri.scheme != 'https') return null;
      return host == nousDomain || host.endsWith('.$nousDomain') ? uri : null;
    }
    if (uri.scheme == 'https') return uri;
    if (uri.scheme != 'http') return null;
    final origin = Uri.tryParse(dashboardOrigin ?? '');
    if (origin == null || origin.host.isEmpty || origin.scheme != 'http') {
      return null;
    }
    return origin.host.toLowerCase() == host && origin.port == uri.port
        ? uri
        : null;
  }
}

/// The three calls a link needs, so a screen can be driven by a fake.
typedef AccountLinkRequest = Future<Map<String, dynamic>> Function();
typedef AccountLinkSessionCall = Future<void> Function(String sessionId);
typedef AccountLinkPoll =
    Future<Map<String, dynamic>> Function(String sessionId);

/// One link attempt of one provider account on one profile. Owns the single
/// timer of the flow: cancelled when the app leaves the foreground, when the
/// flow ends and on [dispose]. Nothing here logs a code or a token.
class ProviderAccountLink extends ChangeNotifier {
  ProviderAccountLink({
    required this.providerId,
    required AccountLinkRequest start,
    required AccountLinkPoll poll,
    required AccountLinkSessionCall cancelSession,
    required Future<void> Function() disconnect,
    this.readOnly = false,
    this.policy = const AccountLinkUrlPolicy(),
    String Function(String url)? normalizeUrl,
    DateTime Function()? now,
    this.minInterval = const Duration(seconds: 3),
    this.maxInterval = const Duration(seconds: 15),
    this.tick = const Duration(seconds: 1),
  }) : _requests = (
         start: start,
         poll: poll,
         cancelSession: cancelSession,
         disconnect: disconnect,
       ),
       _normalizeUrl = normalizeUrl ?? ((url) => url),
       _now = now ?? DateTime.now;

  /// Bound to the Dashboard routes of [client] for [providerId] on
  /// [profile] (null: the gateway's current profile).
  factory ProviderAccountLink.forClient(
    DashboardClient client, {
    required String providerId,
    String? profile,
    bool readOnly = false,
    AccountLinkUrlPolicy policy = const AccountLinkUrlPolicy(),
    String Function(String url)? normalizeUrl,
    DateTime Function()? now,
    Duration minInterval = const Duration(seconds: 3),
    Duration maxInterval = const Duration(seconds: 15),
    Duration tick = const Duration(seconds: 1),
  }) => ProviderAccountLink(
    providerId: providerId,
    start: () => client.startOAuth(providerId, profile: profile),
    poll: (sid) => client.pollOAuth(providerId, sid, profile: profile),
    cancelSession: (sid) => client.cancelOAuthSession(sid, profile: profile),
    disconnect: () => client.disconnectOAuth(providerId, profile: profile),
    readOnly: readOnly,
    policy: policy,
    normalizeUrl: normalizeUrl,
    now: now,
    minInterval: minInterval,
    maxInterval: maxInterval,
    tick: tick,
  );

  final String providerId;
  final bool readOnly;
  final AccountLinkUrlPolicy policy;
  final Duration minInterval;
  final Duration maxInterval;

  /// How often the one timer wakes (to count down and to see whether a poll
  /// is due).
  final Duration tick;

  final ({
    AccountLinkRequest start,
    AccountLinkPoll poll,
    AccountLinkSessionCall cancelSession,
    Future<void> Function() disconnect,
  })
  _requests;
  final String Function(String url) _normalizeUrl;
  final DateTime Function() _now;

  AccountLinkPhase _phase = AccountLinkPhase.idle;
  AccountLinkCode? _code;
  String? _accountEmail;
  bool? _retryable;
  Duration? _retryAfter;
  bool _foreground = true;
  bool _disposed = false;
  bool _polling = false;
  int _attempt = 0;
  Timer? _timer;
  int _ticksToPoll = 0;

  AccountLinkPhase get phase => _phase;

  /// The code of the current or last attempt (kept on a verdict so the
  /// screen can still show what was tried).
  AccountLinkCode? get code => _code;

  /// Who signed in, when the server says (Nous Portal does).
  String? get accountEmail => _accountEmail;

  /// On [AccountLinkPhase.failed]: whether the server thinks another attempt
  /// can work (null: it did not say).
  bool? get retryable => _retryable;

  /// On [AccountLinkPhase.failed]: how long the server asked to wait.
  Duration? get retryAfter => _retryAfter;

  /// Whether a timer is live (tests: none after the flow ends or disposes).
  @visibleForTesting
  bool get hasTimer => _timer != null;

  bool get isPending =>
      _phase == AccountLinkPhase.starting || _phase == AccountLinkPhase.waiting;

  /// Whether "try again" makes sense in the current phase. A failure is
  /// always worth a fresh code: the server's `retryable` only changes what
  /// the page says (a refusal in the browser arrives as a plain failure).
  bool get canRetry => switch (_phase) {
    AccountLinkPhase.denied ||
    AccountLinkPhase.expired ||
    AccountLinkPhase.cancelled ||
    AccountLinkPhase.offline ||
    AccountLinkPhase.failed => true,
    _ => false,
  };

  /// Time left on the code; zero once it ran out or when there is none.
  Duration get remaining {
    final code = _code;
    if (code == null) return Duration.zero;
    final left = code.expiresAt.difference(_now());
    return left.isNegative ? Duration.zero : left;
  }

  /// Starts (or restarts) the flow. Never throws: the outcome is [phase].
  Future<void> start() async {
    if (_disposed || isPending) return;
    final attempt = ++_attempt;
    _stopTimer();
    _code = null;
    _accountEmail = null;
    _retryable = null;
    _retryAfter = null;
    if (readOnly) {
      _set(AccountLinkPhase.readOnly);
      return;
    }
    _set(AccountLinkPhase.starting);
    Map<String, dynamic> body;
    try {
      body = await _requests.start();
    } catch (error) {
      if (_stale(attempt)) return;
      _set(_phaseOf(error, starting: true));
      return;
    }
    if (_stale(attempt)) return;
    final sessionId = _field(body, const ['session_id', 'session']);
    final userCode = _field(body, const ['user_code', 'code']);
    final rawUrl = _field(body, const [
      'verification_uri_complete',
      'verification_url_complete',
      'verification_url',
      'verification_uri',
      'auth_url',
      'authorization_url',
      'url',
    ]);
    if (sessionId.isEmpty || (userCode.isEmpty && rawUrl.isEmpty)) {
      _set(AccountLinkPhase.failed);
      return;
    }
    final seconds = (body['expires_in'] as num?)?.toInt() ?? 900;
    final interval = Duration(
      seconds: (body['poll_interval'] as num?)?.toInt() ?? 5,
    );
    final page = rawUrl.isEmpty ? '' : _normalizeUrl(rawUrl);
    final vetted = page.isEmpty ? null : policy.allow(page);
    _code = AccountLinkCode(
      sessionId: sessionId,
      userCode: userCode,
      verificationUrl: vetted,
      unvettedUrl: vetted == null ? _displayable(page) : '',
      pollInterval: _clamp(interval),
      expiresAt: _now().add(Duration(seconds: seconds.clamp(30, 3600))),
    );
    _set(AccountLinkPhase.waiting);
    _schedule(_code!.pollInterval);
  }

  /// Asks the server once, now (the "check now" button, or the return to the
  /// foreground). Safe to call while a scheduled poll is due.
  Future<void> checkNow() async {
    if (_disposed || _phase != AccountLinkPhase.waiting || _polling) return;
    final code = _code;
    if (code == null) return;
    if (remaining == Duration.zero) {
      _stopTimer();
      _set(AccountLinkPhase.expired);
      return;
    }
    final attempt = _attempt;
    _polling = true;
    Map<String, dynamic> body;
    try {
      body = await _requests.poll(code.sessionId);
    } catch (error) {
      _polling = false;
      if (_stale(attempt) || _phase != AccountLinkPhase.waiting) return;
      if (error is DashboardHttpException && error.statusCode == 404) {
        // The server forgot the session: it expired or was cancelled there.
        _stopTimer();
        _set(AccountLinkPhase.expired);
      } else if (_isOffline(error)) {
        // A blip: the next tick asks again; the deadline still bounds it.
        notifyListeners();
      } else {
        _stopTimer();
        _set(AccountLinkPhase.failed);
      }
      return;
    }
    _polling = false;
    if (_stale(attempt) || _phase != AccountLinkPhase.waiting) return;
    _apply(body);
  }

  /// Tells the flow whether the app is in front. Off: the timer stops (no
  /// polling from the background). On: one check at once, then the pace
  /// resumes.
  void setForeground(bool foreground) {
    if (_disposed || _foreground == foreground) return;
    _foreground = foreground;
    if (_phase != AccountLinkPhase.waiting) return;
    if (!foreground) {
      _stopTimer();
      return;
    }
    unawaited(checkNow());
    _schedule(_code?.pollInterval ?? minInterval);
  }

  /// Ends a pending attempt from this side and tells the server, so a late
  /// approval in the browser is not saved behind the person's back.
  Future<void> cancel() async {
    if (_disposed || !isPending) return;
    _attempt++;
    _stopTimer();
    final sessionId = _code?.sessionId;
    _set(AccountLinkPhase.cancelled);
    if (sessionId != null && !readOnly) {
      try {
        await _requests.cancelSession(sessionId);
      } catch (_) {
        // Best effort: the session expires on the server by itself.
      }
    }
  }

  /// Removes the stored credential of [providerId] on the server. False when
  /// the server refused or could not be reached; the phase then says why
  /// ([AccountLinkPhase.unsupported], [offline], [failed], [readOnly]).
  Future<bool> disconnect() async {
    if (_disposed) return false;
    if (readOnly) {
      _set(AccountLinkPhase.readOnly);
      return false;
    }
    try {
      await _requests.disconnect();
    } catch (error) {
      _set(_phaseOf(error, starting: false));
      return false;
    }
    _set(AccountLinkPhase.idle);
    return true;
  }

  @override
  void dispose() {
    _disposed = true;
    _stopTimer();
    final sessionId = _code?.sessionId;
    if (isPending && sessionId != null && !readOnly) {
      // Closing the screen is a cancellation: nothing keeps waiting, here
      // or there.
      unawaited(_requests.cancelSession(sessionId).catchError((_) {}));
    }
    super.dispose();
  }

  // ── Internals ───────────────────────────────────────────────────────────

  void _apply(Map<String, dynamic> body) {
    final status = (body['status'] ?? '').toString().trim().toLowerCase();
    final reason = (body['reason'] ?? '').toString().trim().toLowerCase();
    if (_pendingStatuses.contains(status) || status.isEmpty) {
      if (remaining == Duration.zero) {
        _stopTimer();
        _set(AccountLinkPhase.expired);
      } else {
        notifyListeners();
      }
      return;
    }
    _stopTimer();
    if (_approvedStatuses.contains(status)) {
      final email = body['account_email'];
      _accountEmail = email is String && email.trim().isNotEmpty
          ? email.trim()
          : null;
      _set(AccountLinkPhase.approved);
      return;
    }
    switch (status) {
      case 'denied':
        _set(AccountLinkPhase.denied);
      case 'expired':
        _set(AccountLinkPhase.expired);
      case 'cancelled' || 'canceled':
        _set(AccountLinkPhase.cancelled);
      default:
        if (reason == 'timeout' || reason == 'expired') {
          _set(AccountLinkPhase.expired);
          return;
        }
        final retryable = body['retryable'];
        _retryable = retryable is bool ? retryable : null;
        final after = body['retry_after'];
        _retryAfter = after is num && after > 0
            ? Duration(seconds: after.toInt())
            : null;
        _set(AccountLinkPhase.failed);
    }
  }

  void _schedule(Duration interval) {
    _stopTimer();
    if (!_foreground || _disposed) return;
    // Counted in ticks of the timer itself, not read off the wall clock, so
    // the pace is the timer's own.
    final every = tick.inMicroseconds <= 0
        ? 1
        : (interval.inMicroseconds / tick.inMicroseconds).ceil().clamp(
            1,
            3600,
          );
    _ticksToPoll = every;
    // One timer: it ticks every second so the screen can count down, and
    // asks the server only when the interval has passed.
    _timer = Timer.periodic(tick, (_) {
      if (_phase != AccountLinkPhase.waiting) {
        _stopTimer();
        return;
      }
      if (remaining == Duration.zero) {
        _stopTimer();
        _set(AccountLinkPhase.expired);
        return;
      }
      if (--_ticksToPoll <= 0) {
        _ticksToPoll = every;
        unawaited(checkNow());
      } else {
        notifyListeners();
      }
    });
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
    _ticksToPoll = 0;
  }

  bool _stale(int attempt) => _disposed || attempt != _attempt;

  void _set(AccountLinkPhase phase) {
    _phase = phase;
    if (!_disposed) notifyListeners();
  }

  Duration _clamp(Duration interval) => interval < minInterval
      ? minInterval
      : interval > maxInterval
      ? maxInterval
      : interval;

  AccountLinkPhase _phaseOf(Object error, {required bool starting}) {
    if (error is DashboardHttpException) {
      if (error.statusCode == 404 || error.statusCode == 405) {
        return AccountLinkPhase.unsupported;
      }
      return AccountLinkPhase.failed;
    }
    if (error is DashboardWriteRevoked) return AccountLinkPhase.readOnly;
    return _isOffline(error)
        ? AccountLinkPhase.offline
        : AccountLinkPhase.failed;
  }

  static bool _isOffline(Object error) =>
      error is SocketException ||
      error is TimeoutException ||
      error is HandshakeException ||
      error is http.ClientException;

  /// An address worth showing as text: http(s), no credentials, a sane
  /// length. Anything else is not shown at all.
  static String _displayable(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        !(uri.scheme == 'https' || uri.scheme == 'http') ||
        raw.length > 512) {
      return '';
    }
    return raw;
  }

  static String _field(Map<String, dynamic> body, List<String> keys) {
    for (final key in keys) {
      final value = body[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
    }
    return '';
  }

  static const _pendingStatuses = {
    'pending',
    'waiting',
    'slow_down',
    'authorization_pending',
    'in_progress',
    'started',
  };

  static const _approvedStatuses = {
    'approved',
    'success',
    'completed',
    'complete',
    'ok',
    'authorized',
    'saved',
    'linked',
    'authenticated',
    'connected',
    'done',
  };
}
