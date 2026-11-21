import 'dart:convert';

import 'connection_manager.dart';

/// Desktop `lib/platform-status.ts` `platformStatusTone`: one reading of a
/// platform's runtime state. Anything enabled that is neither connected nor
/// failed is waiting on something.
enum MessagingTone { good, warn, bad, muted }

/// One credential or option of a platform, as `GET /api/messaging/platforms`
/// describes it (Desktop `types/hermes.ts` `MessagingEnvVarInfo`). The form
/// is built from these: nothing about a platform's fields is hard-coded.
class MessagingEnvField {
  const MessagingEnvField({
    required this.key,
    this.prompt = '',
    this.description = '',
    this.url = '',
    this.isPassword = false,
    this.isSet = false,
    this.isList = false,
    this.required = false,
    this.advanced = false,
    this.redactedValue = '',
    this.value = '',
  });

  final String key;
  final String prompt;
  final String description;

  /// Where to get the value; empty when the server names none.
  final String url;
  final bool isPassword;
  final bool isSet;

  /// A comma-separated allowlist, edited one entry per box.
  final bool isList;
  final bool required;
  final bool advanced;

  /// Display-only preview of a saved value (`«redacted:…»`). Never sent
  /// back and never put in a field: it is only a hint.
  final String redactedValue;

  /// The plain saved value, which the server sends for allowlists only
  /// (they are ids, not secrets).
  final String value;

  /// Desktop `app/messaging/index.tsx` `FIELD_COPY`: options it folds under
  /// "Advanced" even when the server does not mark them.
  static const desktopAdvancedKeys = {
    'TELEGRAM_PROXY',
    'DISCORD_REPLY_TO_MODE',
    'DISCORD_ALLOW_ALL_USERS',
    'DISCORD_HOME_CHANNEL',
    'DISCORD_HOME_CHANNEL_NAME',
    'BLUEBUBBLES_ALLOW_ALL_USERS',
    'MATTERMOST_ALLOW_ALL_USERS',
    'MATTERMOST_HOME_CHANNEL',
    'QQ_ALLOW_ALL_USERS',
    'QQBOT_HOME_CHANNEL',
    'QQBOT_HOME_CHANNEL_NAME',
    'WHATSAPP_ENABLED',
    'WHATSAPP_MODE',
  };

  bool get isAdvanced => advanced || desktopAdvancedKeys.contains(key);

  static MessagingEnvField? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final key = _text(raw['key']);
    if (key.isEmpty) return null;
    return MessagingEnvField(
      key: key,
      prompt: _text(raw['prompt']),
      description: _text(raw['description']),
      url: _text(raw['url']),
      isPassword: raw['is_password'] == true,
      isSet: raw['is_set'] == true,
      isList: raw['is_list'] == true,
      required: raw['required'] == true,
      advanced: raw['advanced'] == true,
      redactedValue: _text(raw['redacted_value']),
      value: raw['is_list'] == true ? _text(raw['value']) : '',
    );
  }
}

/// One messaging platform of the profile (Desktop `MessagingPlatformInfo`).
class MessagingPlatform {
  const MessagingPlatform({
    required this.id,
    required this.name,
    this.description = '',
    this.docsUrl = '',
    this.enabled = false,
    this.configured = false,
    this.gatewayRunning = false,
    this.state = '',
    this.errorMessage = '',
    this.envVars = const [],
    this.ingressUrl = '',
    this.relayFronted = false,
    this.relayExclusive = false,
    this.disabledByRelay = false,
  });

  final String id;
  final String name;
  final String description;
  final String docsUrl;
  final bool enabled;
  final bool configured;
  final bool gatewayRunning;

  /// `connected`, `disabled`, `not_configured`, `pending_restart`,
  /// `gateway_stopped`, `startup_failed`, `fatal`, `connecting`,
  /// `retrying`… or empty when the server says nothing.
  final String state;
  final String errorMessage;
  final List<MessagingEnvField> envVars;

  /// A served secondary's address on the shared gateway listener.
  final String ingressUrl;

  /// Team Gateway's shared bot carries this platform: setup is linking an
  /// account to it.
  final bool relayFronted;

  /// The relay owns the platform outright: a direct bot is switched off at
  /// every start, so there is nothing to configure here.
  final bool relayExclusive;

  /// Team Gateway turns the direct connection off at every start.
  final bool disabledByRelay;

  MessagingTone get tone {
    if (!enabled) return MessagingTone.muted;
    return switch (state) {
      'connected' => MessagingTone.good,
      'disabled' => MessagingTone.muted,
      'fatal' || 'startup_failed' => MessagingTone.bad,
      _ => MessagingTone.warn,
    };
  }

  /// The row as the server sent it, with [enabled] and [state] replaced the
  /// way Desktop paints a toggle before the next read (`handleToggle`).
  MessagingPlatform toggled(bool on) => MessagingPlatform(
    id: id,
    name: name,
    description: description,
    docsUrl: docsUrl,
    enabled: on,
    configured: configured,
    gatewayRunning: gatewayRunning,
    state: on
        ? (configured ? 'pending_restart' : 'not_configured')
        : 'disabled',
    errorMessage: errorMessage,
    envVars: envVars,
    ingressUrl: ingressUrl,
    relayFronted: relayFronted,
    relayExclusive: relayExclusive,
    disabledByRelay: disabledByRelay,
  );

  static MessagingPlatform? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final id = _text(raw['id']);
    if (id.isEmpty) return null;
    final fields = raw['env_vars'];
    return MessagingPlatform(
      id: id,
      name: _text(raw['name']).isEmpty ? id : _text(raw['name']),
      description: _text(raw['description']),
      docsUrl: _text(raw['docs_url']),
      enabled: raw['enabled'] == true,
      configured: raw['configured'] == true,
      gatewayRunning: raw['gateway_running'] == true,
      state: _text(raw['state']),
      errorMessage: _text(raw['error_message']),
      envVars: fields is List
          ? [for (final field in fields) ?MessagingEnvField.tryParse(field)]
          : const [],
      ingressUrl: _text(raw['ingress_url']),
      relayFronted: raw['relay_fronted'] == true,
      relayExclusive: raw['relay_exclusive'] == true,
      disabledByRelay: raw['disabled_by_relay'] == true,
    );
  }
}

/// The body of `PUT /api/messaging/platforms/{id}` (Desktop
/// `MessagingPlatformUpdate`).
class MessagingPlatformUpdate {
  const MessagingPlatformUpdate({
    this.enabled,
    this.env = const {},
    this.clearEnv = const [],
  });

  final bool? enabled;
  final Map<String, String> env;
  final List<String> clearEnv;

  /// Desktop `hasChanges`: there is something to save.
  bool get hasChanges => env.isNotEmpty || clearEnv.isNotEmpty;

  Map<String, dynamic> toJson() => {
    'enabled': ?enabled,
    if (env.isNotEmpty) 'env': env,
    if (clearEnv.isNotEmpty) 'clear_env': clearEnv,
  };
}

/// Desktop `platformChanges` and `trimEdits`: what saving [draft] sends.
///
/// The draft holds only what the user typed. A field that was not touched,
/// or was emptied, is not sent, so a saved secret is never replaced by its
/// preview or by nothing; the server keeps it. The one exception is an
/// allowlist that was saved and is now emptied: that is a clear.
MessagingPlatformUpdate messagingChanges(
  MessagingPlatform platform,
  Map<String, String> draft,
) {
  final fields = {for (final field in platform.envVars) field.key: field};
  final env = <String, String>{
    for (final entry in draft.entries)
      if (entry.value.trim().isNotEmpty &&
          !_isShownMask(fields[entry.key], entry.value.trim()))
        entry.key: entry.value.trim(),
  };
  final clear = [
    for (final field in platform.envVars)
      if (field.isList && field.isSet && draft[field.key]?.trim() == '')
        field.key,
  ];
  return MessagingPlatformUpdate(env: env, clearEnv: clear);
}

/// Whether [typed] is only the mask the form shows for the saved value of
/// [field] (its preview, the server's redacted form, or bullets). Typing the
/// mask back is not an edit: the saved value stays, and the mask is never
/// sent as if it were the credential.
bool _isShownMask(MessagingEnvField? field, String typed) {
  if (typed.startsWith('«redacted') || RegExp(r'^[•*]+$').hasMatch(typed)) {
    return true;
  }
  if (field == null || !field.isSet || field.redactedValue.isEmpty) {
    return false;
  }
  return typed == field.redactedValue ||
      typed == credentialPreview(field.redactedValue);
}

/// Desktop `settings/helpers.ts` `credentialPreview`: the text a saved
/// secret shows as its hint.
String credentialPreview(String value) {
  if (!value.startsWith('«redacted')) return value;
  final inner =
      RegExp(r'^«redacted:(.+)»$').firstMatch(value)?.group(1)?.trim() ?? '';
  return inner.isEmpty ? '••••••••' : inner;
}

/// Desktop `allowlist-field.tsx` `splitAllowlist`: one entry per id; a
/// pasted list may use commas or new lines.
List<String> splitAllowlist(String raw) => [
  for (final entry in raw.split(RegExp('[,\n]')))
    if (entry.trim().isNotEmpty) entry.trim(),
];

/// Desktop `joinAllowlist`: the saved form, without blanks or repeats.
String joinAllowlist(List<String> entries) {
  final seen = <String>{};
  return [
    for (final entry in entries)
      if (entry.trim().isNotEmpty && seen.add(entry.trim())) entry.trim(),
  ].join(',');
}

/// What `PUT /api/messaging/platforms/{id}` answered. [hotServed]: a live
/// multiplexer already rebuilt the platform from the new settings, so no
/// gateway restart is needed.
class MessagingUpdateResult {
  const MessagingUpdateResult({this.hotServed = false});

  final bool hotServed;
}

/// `POST /api/messaging/platforms/{id}/test` (Desktop
/// `testMessagingPlatform`; the dashboard's Channels "Test").
class MessagingTestResult {
  const MessagingTestResult({required this.ok, this.message = ''});

  final bool ok;
  final String message;
}

/// The server does not have the route (404 "Not Found", or 405).
class MessagingRouteMissing implements Exception {
  const MessagingRouteMissing();
}

/// The server refused the request; [detail] is its own sentence, when it
/// gave one. Never carries a value that was sent.
class MessagingRequestFailed implements Exception {
  const MessagingRequestFailed(this.statusCode, {this.detail = ''});

  final int statusCode;
  final String detail;

  @override
  String toString() => 'HTTP $statusCode';
}

/// `POST /api/messaging/telegram/onboarding/start`.
class TelegramOnboardingStart {
  const TelegramOnboardingStart({
    required this.pairingId,
    required this.deepLink,
    required this.expiresAt,
  });

  final String pairingId;

  /// The link that opens Telegram on the bot the service is creating.
  final String deepLink;
  final DateTime? expiresAt;
}

/// `GET /api/messaging/telegram/onboarding/{id}`: still waiting, or ready
/// with the bot's name and, when Telegram said who confirmed it, the
/// owner's numeric id.
class TelegramOnboardingStatus {
  const TelegramOnboardingStatus({
    required this.ready,
    this.botUsername = '',
    this.ownerUserId = '',
  });

  final bool ready;
  final String botUsername;
  final String ownerUserId;
}

/// The pairing is gone for good (410: expired or claimed).
class TelegramOnboardingGone implements Exception {
  const TelegramOnboardingGone();
}

/// `POST /api/messaging/telegram/onboarding/{id}/apply`.
class TelegramOnboardingApplied {
  const TelegramOnboardingApplied({
    this.botUsername = '',
    this.needsRestart = false,
    this.restartStarted = false,
    this.restartError = '',
  });

  final String botUsername;
  final bool needsRestart;
  final bool restartStarted;
  final String restartError;
}

/// One chat account linked to Team Gateway's shared bot.
class RelayAccount {
  const RelayAccount({
    required this.platformUserId,
    this.displayName = '',
    this.handle = '',
  });

  final String platformUserId;
  final String displayName;
  final String handle;
}

/// `GET /api/messaging/relay`, the part of it about one platform.
class RelayLinks {
  const RelayLinks({
    this.accounts = const [],
    this.botUrl = '',
    this.portalUrl = '',
  });

  final List<RelayAccount> accounts;
  final String botUrl;

  /// Set when the Nous Portal governs this agent: accounts are linked
  /// there, not here.
  final String portalUrl;
}

/// `POST /api/messaging/relay/{platform}/link`: the one-time code.
class RelayLinkCode {
  const RelayLinkCode({
    required this.code,
    required this.command,
    this.botUrl = '',
    this.expiresAt,
  });

  final String code;

  /// The exact message to send the shared bot.
  final String command;
  final String botUrl;
  final DateTime? expiresAt;
}

enum RelayLinkState { pending, inactive, refused }

/// Messaging platform setup: `/api/messaging/platforms`, its update and
/// test, Telegram's QR onboarding, Team Gateway account links and the
/// gateway restart (Desktop `api/messaging.ts`, `api/system.ts`
/// `restartGateway` / `getActionStatus`). A selected profile is named on
/// every call. An empty one travels unnamed, and the server then acts on the
/// profile it was launched for: naming `default` instead would read and write
/// the installation root's credentials on a Dashboard that serves a named
/// profile.
class MessagingPlatformsClient {
  MessagingPlatformsClient(
    this._dashboard, {
    Future<void> Function(Duration)? sleep,
  }) : _sleep = sleep ?? Future<void>.delayed;

  final DashboardClient _dashboard;
  final Future<void> Function(Duration) _sleep;

  static String _scoped(String endpoint, String profile) {
    final named = profile.trim();
    if (named.isEmpty) return endpoint;
    final separator = endpoint.contains('?') ? '&' : '?';
    return '$endpoint${separator}profile=${Uri.encodeQueryComponent(named)}';
  }

  static String _segment(String value) => Uri.encodeComponent(value);

  /// Maps a Dashboard failure to [MessagingRouteMissing] or
  /// [MessagingRequestFailed]; anything else is rethrown as it is.
  static Future<T> _guard<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on DashboardHttpException catch (error) {
      final detail = _detailOf(error.body);
      final missing =
          error.statusCode == 405 ||
          (error.statusCode == 404 &&
              (detail.isEmpty || detail == 'Not Found'));
      if (missing) throw const MessagingRouteMissing();
      throw MessagingRequestFailed(error.statusCode, detail: detail);
    }
  }

  /// The server's `detail`: a sentence, or `{code, message}` for the relay
  /// routes (Desktop `relay-link.tsx` `relayErrorText`).
  static String _detailOf(String body) {
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      return '';
    }
    if (decoded is! Map) return '';
    final detail = decoded['detail'];
    if (detail is String) return detail.trim();
    if (detail is Map) return _text(detail['message']);
    return '';
  }

  Future<List<MessagingPlatform>> load(String profile) => _guard(() async {
    final answer = await _dashboard.apiGet(
      _scoped('messaging/platforms', profile),
    );
    final raw = answer['platforms'];
    if (raw is! List) return const [];
    return [for (final item in raw) ?MessagingPlatform.tryParse(item)];
  });

  /// Desktop `updateMessagingPlatform`: the profile rides on the query.
  Future<MessagingUpdateResult> update(
    String platformId,
    MessagingPlatformUpdate update,
    String profile,
  ) => _guard(() async {
    final answer = await _dashboard.apiPut(
      _scoped('messaging/platforms/${_segment(platformId)}', profile),
      body: update.toJson(),
    );
    return MessagingUpdateResult(hotServed: answer['hot_served'] == true);
  });

  Future<MessagingTestResult> test(String platformId, String profile) =>
      _guard(() async {
        final answer = await _dashboard.apiPost(
          _scoped('messaging/platforms/${_segment(platformId)}/test', profile),
        );
        return MessagingTestResult(
          ok: answer['ok'] == true,
          message: _text(answer['message']),
        );
      });

  // Telegram QR onboarding. The pairing lives in the memory of the server
  // process that started it, so every call of one flow names the same
  // profile (Desktop `startTelegramOnboarding` and the rest).

  Future<TelegramOnboardingStart> startTelegram(String profile) =>
      _guard(() async {
        final answer = await _dashboard.apiPost(
          _scoped('messaging/telegram/onboarding/start', profile),
          body: const {},
        );
        final pairingId = _text(answer['pairing_id']);
        final deepLink = _text(answer['deep_link']);
        if (pairingId.isEmpty || deepLink.isEmpty) {
          throw const MessagingRequestFailed(502);
        }
        return TelegramOnboardingStart(
          pairingId: pairingId,
          deepLink: deepLink,
          expiresAt: DateTime.tryParse(_text(answer['expires_at'])),
        );
      });

  /// Throws [TelegramOnboardingGone] once the pairing expired or was
  /// claimed (Desktop `isTerminalTelegramOnboardingError`, 410).
  Future<TelegramOnboardingStatus> telegramStatus(
    String pairingId,
    String profile,
  ) async {
    try {
      return await _guard(() async {
        final answer = await _dashboard.apiGet(
          _scoped(
            'messaging/telegram/onboarding/${_segment(pairingId)}',
            profile,
          ),
        );
        if (_text(answer['status']) != 'ready') {
          return const TelegramOnboardingStatus(ready: false);
        }
        final owner = _text(answer['owner_user_id']);
        return TelegramOnboardingStatus(
          ready: true,
          botUsername: _text(answer['bot_username']),
          ownerUserId: telegramUserIdPattern.hasMatch(owner) ? owner : '',
        );
      });
    } on MessagingRequestFailed catch (error) {
      if (error.statusCode == 410) throw const TelegramOnboardingGone();
      rethrow;
    }
  }

  /// Desktop `applyTelegramOnboarding`: the profile goes on the query and
  /// in the body, which is where the server reads it first.
  Future<TelegramOnboardingApplied> applyTelegram(
    String pairingId,
    List<String> allowedUserIds,
    String profile,
  ) => _guard(() async {
    final named = profile.trim();
    final answer = await _dashboard.apiPost(
      _scoped(
        'messaging/telegram/onboarding/${_segment(pairingId)}/apply',
        profile,
      ),
      body: {
        'allowed_user_ids': allowedUserIds,
        if (named.isNotEmpty) 'profile': named,
      },
    );
    return TelegramOnboardingApplied(
      botUsername: _text(answer['bot_username']),
      needsRestart: answer['needs_restart'] == true,
      restartStarted: answer['restart_started'] == true,
      restartError: _text(answer['restart_error']),
    );
  });

  Future<void> cancelTelegram(String pairingId, String profile) => _guard(
    () => _dashboard.apiDelete(
      _scoped('messaging/telegram/onboarding/${_segment(pairingId)}', profile),
    ),
  );

  /// Desktop `TELEGRAM_USER_ID_RE`.
  static final telegramUserIdPattern = RegExp(r'^\d{3,20}$');

  // Team Gateway account links (Desktop `getRelayLinks` and the rest).

  Future<RelayLinks> relayLinks(String platformId, String profile) =>
      _guard(() async {
        final answer = await _dashboard.apiGet(
          _scoped('messaging/relay', profile),
        );
        final portal = answer['managed_by'] == 'portal'
            ? _text(answer['portal_url'])
            : '';
        final rows = answer['platforms'];
        if (rows is List) {
          for (final row in rows) {
            if (row is! Map || _text(row['platform']) != platformId) continue;
            final accounts = row['accounts'];
            return RelayLinks(
              accounts: accounts is List
                  ? [
                      for (final account in accounts)
                        if (account is Map &&
                            _text(account['platformUserId']).isNotEmpty)
                          RelayAccount(
                            platformUserId: _text(account['platformUserId']),
                            displayName: _text(account['displayName']),
                            handle: _text(account['handle']),
                          ),
                    ]
                  : const [],
              botUrl: _text(row['bot_url']),
              portalUrl: portal,
            );
          }
        }
        return RelayLinks(portalUrl: portal);
      });

  Future<RelayLinkCode> requestRelayLink(String platformId, String profile) =>
      _guard(() async {
        final answer = await _dashboard.apiPost(
          _scoped('messaging/relay/${_segment(platformId)}/link', profile),
        );
        final code = _text(answer['code']);
        if (code.isEmpty) throw const MessagingRequestFailed(502);
        final command = _text(answer['command']);
        return RelayLinkCode(
          code: code,
          command: command.isEmpty ? '/link $code' : command,
          botUrl: _text(answer['bot_url']),
          expiresAt: DateTime.tryParse(_text(answer['expires_at'])),
        );
      });

  Future<RelayLinkState> relayLinkState(String code, String profile) =>
      _guard(() async {
        final answer = await _dashboard.apiGet(
          _scoped('messaging/relay/link/${_segment(code)}', profile),
        );
        return switch (_text(answer['state'])) {
          'pending' => RelayLinkState.pending,
          'refused' => RelayLinkState.refused,
          _ => RelayLinkState.inactive,
        };
      });

  Future<void> unlinkRelayAccount(
    String platformId,
    String platformUserId,
    String profile,
  ) => _guard(
    () => _dashboard.apiDelete(
      _scoped(
        'messaging/relay/${_segment(platformId)}/accounts/'
        '${_segment(platformUserId)}',
        profile,
      ),
    ),
  );

  // Gateway restart (Desktop `store/system-actions.ts` `runGatewayRestart`
  // and `awaitAction`).

  static const restartPollAttempts = 18;
  static const restartPollInterval = Duration(seconds: 1, milliseconds: 200);

  /// `POST /api/gateway/restart` for [profile].
  Future<void> requestGatewayRestart(String profile) =>
      _guard(() => _dashboard.apiPost(_scoped('gateway/restart', profile)));

  /// Follows the `gateway-restart` action the way Desktop's `awaitAction`
  /// does. The poll talks to the server the restart takes down, so a
  /// refused read mid-window is expected, and a fresh process that never
  /// saw the action answers "not running, no exit code": both keep waiting.
  /// Only a recorded non-zero exit is a failure, and a window in which no
  /// read was ever answered is one too. Still running when the window
  /// closes counts as done (a no-service install keeps the child as the
  /// foreground gateway).
  Future<bool> awaitGatewayRestart(String profile) async {
    var answered = false;
    for (var attempt = 0; attempt < restartPollAttempts; attempt += 1) {
      await _sleep(restartPollInterval);
      final Map<String, dynamic> status;
      try {
        status = await _dashboard.apiGet(
          _scoped('actions/gateway-restart/status?lines=200', profile),
        );
      } catch (_) {
        continue;
      }
      answered = true;
      final code = status['exit_code'];
      if (status['running'] == true || code == null) continue;
      return code == 0;
    }
    return answered;
  }
}

String _text(Object? value) => value?.toString().trim() ?? '';
