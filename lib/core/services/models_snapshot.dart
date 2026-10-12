import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/fallback_chain.dart';
import '../models/oauth_account.dart';
import '../models/provider_key_groups.dart';
import 'connection_manager.dart';
import 'custom_endpoints_api.dart';

/// What the Models screen showed after its last complete read.
final class ModelsSnapshot {
  const ModelsSnapshot({
    required this.active,
    required this.providers,
    required this.auxiliary,
    required this.accounts,
    this.auxError,
    this.accountsError,
    this.fallback,
    this.agentDefaults,
    this.keyGroups,
    this.endpoints,
    this.excluded,
  });

  final ModelActiveInfo? active;
  final List<ModelProvider> providers;
  final Map<String, dynamic>? auxiliary;

  /// Accounts of the profile (`GET /api/providers/oauth`); null when that
  /// read failed.
  final List<OAuthAccount>? accounts;

  /// Why the optional reads failed, so a painted snapshot degrades exactly
  /// like the live read did.
  final Object? auxError;
  final Object? accountsError;

  /// Sections read on their own, beside the catalog: the fallback chain and
  /// the model defaults (`GET /api/config`), the provider keys
  /// (`GET /api/env`) and the custom endpoints. Null until that read has
  /// answered once, so a reopen paints them with the rest instead of leaving
  /// their rows to pop in.
  final List<FallbackEntry>? fallback;
  final Map<String, dynamic>? agentDefaults;
  final List<ProviderKeyGroup>? keyGroups;
  final List<CustomEndpoint>? endpoints;

  /// The providers the profile leaves out of its catalog
  /// (`model_catalog.excluded_providers`, from the same config read).
  final List<String>? excluded;

  ModelsSnapshot copyWith({
    List<FallbackEntry>? fallback,
    Map<String, dynamic>? agentDefaults,
    List<ProviderKeyGroup>? keyGroups,
    List<CustomEndpoint>? endpoints,
    List<OAuthAccount>? accounts,
    List<String>? excluded,
  }) => ModelsSnapshot(
    active: active,
    providers: providers,
    auxiliary: auxiliary,
    accounts: accounts ?? this.accounts,
    auxError: auxError,
    accountsError: accounts == null ? accountsError : null,
    fallback: fallback ?? this.fallback,
    agentDefaults: agentDefaults ?? this.agentDefaults,
    keyGroups: keyGroups ?? this.keyGroups,
    endpoints: endpoints ?? this.endpoints,
    excluded: excluded ?? this.excluded,
  );
}

/// Last Models read per connection and profile, in memory only.
///
/// Desktop keeps the model catalog in its query cache, so reopening the model
/// settings paints at once and refreshes behind. The server can take several
/// seconds to build `/api/model/options` (live provider discovery, key
/// helpers); this cache lets Console show the last answer meanwhile. It is
/// never a write authority: every change still goes through the server and
/// the screen reloads. Nothing is written to disk.
final class ModelsSnapshotCache {
  ModelsSnapshotCache({this.capacity = 8});

  static final shared = ModelsSnapshotCache();

  final int capacity;
  final Map<String, ModelsSnapshot> _entries = {};

  /// Same saved connection pointed at another server, or another profile,
  /// is another key.
  static String keyOf(SavedConnection connection, String profileOwner) =>
      '${connection.id}|${connection.baseUrl}|'
      '${connection.effectiveDashboardUrl}|$profileOwner';

  ModelsSnapshot? read(SavedConnection connection, String profileOwner) =>
      _entries[keyOf(connection, profileOwner)];

  void write(
    SavedConnection connection,
    String profileOwner,
    ModelsSnapshot snapshot,
  ) {
    final key = keyOf(connection, profileOwner);
    _entries.remove(key);
    _entries[key] = snapshot;
    while (_entries.length > capacity) {
      _entries.remove(_entries.keys.first);
    }
  }

  /// A change was written: this answer is no longer current.
  void remove(SavedConnection connection, String profileOwner) =>
      _entries.remove(keyOf(connection, profileOwner));

  /// Adds a section that answered on its own to the answer already kept.
  /// Without a kept answer there is nothing to complete.
  void amend(
    SavedConnection connection,
    String profileOwner,
    ModelsSnapshot Function(ModelsSnapshot current) change,
  ) {
    final key = keyOf(connection, profileOwner);
    final current = _entries[key];
    if (current != null) _entries[key] = change(current);
  }

  void clear() => _entries.clear();
}

typedef ModelsPrewarmClientFactory =
    DashboardClient Function(SavedConnection connection);

/// One background Models read per connection and profile, so the first open
/// of Models paints the catalog instead of waiting for the server to build
/// it (Desktop loads the same data at startup for its model menu).
///
/// Like Bot Mode's prewarm it only runs for a connection on which the user
/// has opened Models before, after Home has been idle in the foreground.
final class ModelsSnapshotPrewarm {
  ModelsSnapshotPrewarm({
    ModelsSnapshotCache? cache,
    ModelsPrewarmClientFactory? clientFactory,
    // After the chat picker's own prewarm (3 s), so the two expensive
    // catalog builds do not hit the server at the same time.
    this.idleDelay = const Duration(seconds: 15),
  }) : _cache = cache ?? ModelsSnapshotCache.shared,
       _clientFactory = clientFactory ?? DashboardClient.lazy;

  static final shared = ModelsSnapshotPrewarm();

  final ModelsSnapshotCache _cache;
  final ModelsPrewarmClientFactory _clientFactory;
  final Duration idleDelay;

  final Set<String> _done = {};
  Timer? _timer;
  String? _timerKey;
  _Warm? _warm;

  static String flagKey(String connectionId) =>
      'models_opened_v1.$connectionId';

  static bool wasOpened(SharedPreferences prefs, String connectionId) =>
      prefs.getBool(flagKey(connectionId)) == true;

  static Future<void> markOpened(
    SharedPreferences prefs,
    String connectionId,
  ) async {
    if (wasOpened(prefs, connectionId)) return;
    await prefs.setBool(flagKey(connectionId), true);
  }

  /// Arms the one-shot idle timer. [stillIdle] is checked when it fires.
  void schedule({
    required SharedPreferences prefs,
    required SavedConnection connection,
    required String profileOwner,
    required bool Function() stillIdle,
  }) {
    final key = ModelsSnapshotCache.keyOf(connection, profileOwner);
    if (_done.contains(key)) return;
    if (_timerKey == key && _timer != null) return;
    if (!wasOpened(prefs, connection.id)) return;
    if (_cache.read(connection, profileOwner) != null) return;
    cancel();
    _timerKey = key;
    _timer = Timer(idleDelay, () {
      _timer = null;
      _timerKey = null;
      if (!stillIdle()) return;
      _start(connection, profileOwner, key);
    });
  }

  void _start(SavedConnection connection, String profileOwner, String key) {
    if (_done.contains(key) || _cache.read(connection, profileOwner) != null) {
      return;
    }
    _done.add(key);
    final client = _clientFactory(connection);
    final warm = _Warm(key);
    _warm = warm;
    warm.future =
        readModelsSnapshot(
              client,
              profile: profileOwner == 'default' ? '' : profileOwner,
            )
            .then(
              (snapshot) {
                if (!warm.cancelled) {
                  _cache.write(connection, profileOwner, snapshot);
                }
                return snapshot;
              },
              onError: (Object error, StackTrace stack) {
                // A failed read may be retried by a later idle Home.
                if (!warm.claimed) _done.remove(key);
                return Future<ModelsSnapshot>.error(error, stack);
              },
            )
            .whenComplete(() {
              client.close();
              if (identical(_warm, warm)) _warm = null;
            });
    // An unclaimed failure is dropped; Models reads again on open.
    unawaited(warm.future.then((_) {}, onError: (_) {}));
  }

  /// Models is opening: stop a pending timer and hand over the in-flight
  /// read, if any, so it is not issued twice.
  Future<ModelsSnapshot>? claim(
    SavedConnection connection,
    String profileOwner,
  ) {
    final key = ModelsSnapshotCache.keyOf(connection, profileOwner);
    _done.add(key);
    if (_timerKey == key) {
      _timer?.cancel();
      _timer = null;
      _timerKey = null;
    }
    final warm = _warm;
    // Single use: any later read of this screen goes to the server.
    if (warm == null || warm.key != key || warm.cancelled || warm.claimed) {
      return null;
    }
    warm.claimed = true;
    return warm.future;
  }

  /// App went to background or the active connection changed: drop the
  /// pending timer. A read already in flight is keyed by its connection and
  /// profile, so its answer is still right and is kept.
  void cancel() {
    _timer?.cancel();
    _timer = null;
    _timerKey = null;
  }

  /// A change was written for ([connection], [profileOwner]): a read issued
  /// before it must neither answer Models nor reach the cache.
  void discard(SavedConnection connection, String profileOwner) {
    final key = ModelsSnapshotCache.keyOf(connection, profileOwner);
    if (_timerKey == key) cancel();
    _done.add(key);
    final warm = _warm;
    if (warm == null || warm.key != key) return;
    warm.cancelled = true;
    _warm = null;
  }
}

/// The complete Models read: the inventory is required; the other sources
/// degrade to null like Desktop's `Promise.allSettled`.
Future<ModelsSnapshot> readModelsSnapshot(
  DashboardClient client, {
  required String profile,
}) async {
  ModelActiveInfo? active;
  Map<String, dynamic>? auxiliary;
  List<OAuthAccount>? accounts;
  Object? auxError;
  Object? accountsError;
  final results = await Future.wait<Object?>([
    client
        .getModelInfo(profile: profile)
        .then<Object?>((v) => active = v, onError: (Object _) => null),
    client.getModelOptions(profile: profile),
    client
        .getAuxiliaryModels(profile: profile)
        .then<Object?>((v) {
          if (v['tasks'] is! List) {
            throw const FormatException('Invalid auxiliary response');
          }
          auxiliary = v;
          return null;
        })
        .catchError((Object error) => auxError = error),
    client
        .getOAuthProviders(profile: profile)
        .then<Object?>(
          (v) => accounts = OAuthAccount.listFromJson(v),
          onError: (Object error) => accountsError = error,
        ),
  ]);
  return ModelsSnapshot(
    active: active,
    providers: results[1] as List<ModelProvider>,
    auxiliary: auxiliary,
    auxError: auxError,
    accounts: accounts,
    accountsError: accountsError,
  );
}

final class _Warm {
  _Warm(this.key);
  final String key;
  late final Future<ModelsSnapshot> future;
  bool claimed = false;
  bool cancelled = false;
}
