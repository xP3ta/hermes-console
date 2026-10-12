import 'connection_manager.dart';

String _credentialPoolProfileQuery(String? profile) {
  final value = profile?.trim() ?? '';
  if (value.isEmpty || value == 'default') return '';
  return '?profile=${Uri.encodeQueryComponent(value)}';
}

final class CredentialPoolEntry {
  final int index;
  final String id;
  final String label;
  final String authType;
  final String source;
  final int priority;
  final String lastStatus;
  final int requestCount;
  final bool hasRefresh;

  const CredentialPoolEntry({
    required this.index,
    required this.id,
    required this.label,
    required this.authType,
    required this.source,
    required this.priority,
    required this.lastStatus,
    required this.requestCount,
    required this.hasRefresh,
  });

  factory CredentialPoolEntry.fromJson(Object? value) {
    final json = value is Map ? value.cast<String, dynamic>() : const {};
    return CredentialPoolEntry(
      index: json['index'] is int ? json['index'] as int : 0,
      id: (json['id'] ?? '').toString(),
      label: (json['label'] ?? '').toString(),
      authType: (json['auth_type'] ?? '').toString(),
      source: (json['source'] ?? '').toString(),
      priority: json['priority'] is int ? json['priority'] as int : 0,
      lastStatus: (json['last_status'] ?? '').toString(),
      requestCount: json['request_count'] is int
          ? json['request_count'] as int
          : 0,
      hasRefresh: json['has_refresh'] == true,
    );
  }
}

final class CredentialPoolProvider {
  final String provider;
  final List<CredentialPoolEntry> entries;

  const CredentialPoolProvider({required this.provider, required this.entries});

  factory CredentialPoolProvider.fromJson(Object? value) {
    final json = value is Map ? value.cast<String, dynamic>() : const {};
    final rawEntries = json['entries'];
    return CredentialPoolProvider(
      provider: (json['provider'] ?? '').toString(),
      entries: rawEntries is List
          ? List<CredentialPoolEntry>.unmodifiable(
              rawEntries.map(CredentialPoolEntry.fromJson),
            )
          : const [],
    );
  }
}

final class CredentialPool {
  final List<CredentialPoolProvider> providers;

  const CredentialPool(this.providers);

  factory CredentialPool.fromJson(Map<String, dynamic> json) {
    final rawProviders = json['providers'];
    return CredentialPool(
      rawProviders is List
          ? List<CredentialPoolProvider>.unmodifiable(
              rawProviders.map(CredentialPoolProvider.fromJson),
            )
          : const [],
    );
  }
}

extension CredentialPoolApi on DashboardClient {
  Future<CredentialPool?> getCredentialPool({String? profile}) async {
    try {
      return CredentialPool.fromJson(
        await apiGet('credentials/pool${_credentialPoolProfileQuery(profile)}'),
      );
    } on DashboardHttpException catch (error) {
      if (error.statusCode == 404 || error.statusCode == 405) return null;
      rethrow;
    }
  }
}
