import '../models/memory_provider_config.dart';
import 'connection_manager.dart';

/// The Dashboard calls behind the memory provider settings, the same ones
/// Hermes Desktop makes (`apps/desktop/src/api/system.ts:60-112`,
/// `app/settings/config-settings.tsx`). Every call carries the profile the
/// way Desktop's settings do: named when one was picked, unnamed otherwise
/// (the server then acts on the profile it was launched for; see
/// [ConnectionManager.credentialProfileFor]).
///
/// Nothing here is logged: a provider's values include its credentials.
class MemorySettingsApi {
  MemorySettingsApi(this._client, {required String profile})
    : profile = profile.trim();

  final DashboardClient _client;

  /// Empty for an unnamed request.
  final String profile;

  String _scoped(String endpoint) {
    if (profile.isEmpty) return endpoint;
    final sep = endpoint.contains('?') ? '&' : '?';
    return '$endpoint${sep}profile=${Uri.encodeQueryComponent(profile)}';
  }

  static String _provider(String name) => Uri.encodeComponent(name);

  /// `GET /api/config`: only `memory.*` is read from it.
  Future<Map<String, dynamic>> memoryConfig() async {
    final config = await _client.apiGet(_scoped('config'));
    final memory = config['memory'];
    return memory is Map ? memory.cast<String, dynamic>() : const {};
  }

  /// The providers the server offers for `memory.provider`
  /// (`GET /api/config/schema` → `fields["memory.provider"].options`), or
  /// null when the schema does not list them.
  Future<List<String>?> providerOptions() async {
    final schema = await _client.apiGet(_scoped('config/schema'));
    final fields = schema['fields'];
    final field = fields is Map ? fields['memory.provider'] : null;
    final options = field is Map ? field['options'] : null;
    if (options is! List) return null;
    return [
      for (final option in options)
        if (option is String) option,
    ];
  }

  /// `PUT /api/config` with only the `memory` keys given.
  Future<void> putMemoryConfig(Map<String, dynamic> memory) =>
      _client.apiPut(
        _scoped('config'),
        body: {
          'config': {'memory': memory},
        },
      );

  /// The settings [provider] declares; null when the server answers
  /// something other than the declared surface (an older server).
  Future<MemoryProviderConfig?> providerConfig(String provider) async =>
      MemoryProviderConfig.tryParse(
        await _client.apiGet(
          _scoped('memory/providers/${_provider(provider)}/config'
              '?surface=declared'),
        ),
      );

  /// Saves only [values] (key → text), like Desktop's one-key autosave and
  /// its changed-keys modal save.
  Future<void> saveProviderConfig(
    String provider,
    Map<String, String> values,
  ) => _client.apiPut(
    _scoped('memory/providers/${_provider(provider)}/config'
        '?surface=declared'),
    body: {'values': values},
  );

  Future<MemoryProviderOAuthStatus> oauthStatus(String provider) async =>
      MemoryProviderOAuthStatus.fromJson(
        await _client.apiGet(
          _scoped('memory/providers/${_provider(provider)}/oauth/status'),
        ),
      );

  Future<MemoryProviderOAuthStatus> oauthStart(String provider) async =>
      MemoryProviderOAuthStatus.fromJson(
        await _client.apiPost(
          _scoped('memory/providers/${_provider(provider)}/oauth/start'),
        ),
      );
}

/// The route does not exist on this server (older Hermes).
bool memoryRouteMissing(Object error) =>
    error is DashboardHttpException &&
    (error.statusCode == 404 || error.statusCode == 405);

/// The server's own short reason for a refused save («Invalid value for
/// 'recall_budget'»), when it gave one; never the submitted values.
String? memoryServerDetail(Object error) {
  if (error is! DashboardHttpException) return null;
  final match = RegExp(r'"detail"\s*:\s*"((?:[^"\\]|\\.){1,200})"')
      .firstMatch(error.body);
  final detail = match?.group(1)?.replaceAll(r'\"', '"').trim();
  return detail == null || detail.isEmpty ? null : detail;
}
