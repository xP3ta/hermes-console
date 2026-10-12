// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hermes Console contributors

/// One provider card built from `GET /api/env`, the source Desktop's
/// Providers settings use (`buildProviderKeyGroups`): every provider Hermes
/// knows about, configured or not, independent of the model inventory.
class ProviderKeyGroup {
  const ProviderKeyGroup({
    required this.slug,
    required this.name,
    required this.keyEnv,
    required this.isSet,
    this.setKeys = const [],
  });

  /// Backend provider id (`provider`), empty when only a label is published.
  final String slug;

  /// Display name: `provider_label`, else `provider`.
  final String name;

  /// The card's primary credential variable: where a key is saved.
  final String keyEnv;

  /// Whether the card holds a key of its own ([setKeys] is not empty). A
  /// provider with only its base URL or another non-key variable saved still
  /// needs its key.
  final bool isSet;

  /// The key variables of the card that are set and are this provider's to
  /// clear, the primary one first. A card can have more than one
  /// (`KIMI_API_KEY` and `KIMI_CODING_API_KEY`) and any of them connects the
  /// provider, so removing its key clears them all (Desktop keeps a set
  /// second variable on the card for that). A variable the card only
  /// borrows from another provider's card is that provider's key.
  final List<String> setKeys;

  /// The primary variable itself is set: what a save is checked against.
  bool get primarySet => setKeys.contains(keyEnv);
}

/// Desktop `isKeyVar`: a password field or a `*_API_KEY|*_TOKEN|*_KEY` name.
bool _isKeyVar(String key, Map<String, dynamic> info) =>
    info['is_password'] == true ||
    RegExp(r'(?:_API_KEY|_TOKEN|_KEY)$').hasMatch(key);

/// One variable serving several provider cards (`provider_profiles`).
bool _isShared(Map<String, dynamic> info) {
  final profiles = info['provider_profiles'];
  return profiles is List && profiles.length > 1;
}

String _text(Object? value) => value is String ? value.trim() : '';

/// Groups the provider credentials of a `GET /api/env` payload exactly like
/// Desktop: only `category == 'provider'`; a shared credential expands into one
/// card per `provider_profiles` entry while keeping the same variable; cards
/// group by `provider_label`, then `provider`; the primary key is the
/// `provider_primary` key var, else the first non-advanced key var, else any
/// key var. Rows without backend provider identity are skipped rather than
/// guessed. Values are never read: only `is_set` is kept.
List<ProviderKeyGroup> providerKeyGroupsFromEnv(Map<String, dynamic> vars) {
  final buckets = <String, List<(String, Map<String, dynamic>)>>{};
  final slugs = <String, String>{};
  for (final entry in vars.entries) {
    final raw = entry.value;
    if (raw is! Map) continue;
    final info = raw.cast<String, dynamic>();
    if (info['category'] != 'provider') continue;
    final profiles = info['provider_profiles'];
    final scoped = <Map<String, dynamic>>[
      if (profiles is List && profiles.isNotEmpty)
        for (final profile in profiles.whereType<Map>())
          {
            ...info,
            'provider': profile['provider'],
            'provider_label': profile['provider_label'],
            'provider_primary': profile['primary'] == true,
          }
      else
        info,
    ];
    for (final item in scoped) {
      final label = _text(item['provider_label']);
      final id = _text(item['provider']);
      final name = label.isNotEmpty ? label : id;
      if (name.isEmpty || name == 'Other') continue;
      (buckets[name] ??= []).add((entry.key, item));
      if (id.isNotEmpty) slugs.putIfAbsent(name, () => id);
    }
  }
  final groups = <ProviderKeyGroup>[];
  for (final MapEntry(key: name, value: entries) in buckets.entries) {
    (String, Map<String, dynamic>)? pick(
      bool Function((String, Map<String, dynamic>)) test,
    ) {
      for (final candidate in entries) {
        if (test(candidate)) return candidate;
      }
      return null;
    }

    final primary =
        pick(
          (e) => e.$2['provider_primary'] == true && _isKeyVar(e.$1, e.$2),
        ) ??
        pick((e) => e.$2['advanced'] != true && _isKeyVar(e.$1, e.$2)) ??
        pick((e) => _isKeyVar(e.$1, e.$2));
    if (primary == null) continue;
    final setKeys = [
      if (primary.$2['is_set'] == true) primary.$1,
      for (final candidate in entries)
        if (candidate.$1 != primary.$1 &&
            candidate.$2['is_set'] == true &&
            !_isShared(candidate.$2) &&
            _isKeyVar(candidate.$1, candidate.$2))
          candidate.$1,
    ];
    groups.add(
      ProviderKeyGroup(
        slug: slugs[name] ?? '',
        name: name,
        keyEnv: primary.$1,
        isSet: setKeys.isNotEmpty,
        setKeys: List.unmodifiable(setKeys),
      ),
    );
  }
  groups.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return groups;
}
