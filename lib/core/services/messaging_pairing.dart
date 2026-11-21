import 'connection_manager.dart';

/// One row of `GET /api/pairing`: someone waiting to be approved, or already
/// approved, for one messaging platform (Desktop `types/hermes.ts`
/// `PairingUser`).
class PairingEntry {
  const PairingEntry({
    required this.platform,
    required this.userId,
    this.userName = '',
    this.requestId = '',
    this.ageMinutes,
  });

  final String platform;
  final String userId;
  final String userName;

  /// Pending rows only: the id an approval grants on. Never the one-time
  /// code, which the server does not return. Empty for a legacy pending row,
  /// which cannot be approved from here.
  final String requestId;
  final int? ageMinutes;

  /// Desktop `pairingLabel`: the name, or the id of an unnamed requester.
  String get label => userName.isNotEmpty ? userName : userId;

  bool get canApprove => requestId.isNotEmpty;

  /// The row as the list shows it; null for a row with no platform or user.
  static PairingEntry? tryParse(Object? raw) {
    if (raw is! Map) return null;
    String text(String key) => raw[key]?.toString().trim() ?? '';
    final platform = text('platform');
    final userId = text('user_id');
    if (platform.isEmpty || userId.isEmpty) return null;
    final age = raw['age_minutes'];
    return PairingEntry(
      platform: platform,
      userId: userId,
      userName: text('user_name'),
      requestId: text('request_id'),
      ageMinutes: age is num ? age.toInt() : null,
    );
  }
}

class PairingSnapshot {
  const PairingSnapshot({this.pending = const [], this.approved = const []});

  final List<PairingEntry> pending;
  final List<PairingEntry> approved;

  bool get isEmpty => pending.isEmpty && approved.isEmpty;
}

/// The server has no `/api/pairing` (404/405).
class PairingRouteMissing implements Exception {
  const PairingRouteMissing();
}

/// The approval was refused with 429: the platform is locked out after too
/// many failed approvals (Desktop `pairingLockedOut`).
class PairingLockedOut implements Exception {
  const PairingLockedOut();
}

/// Who may message the bot: `/api/pairing`, `/approve` and `/revoke`
/// (Desktop `api/messaging.ts` `getPairing`, `approvePairing`,
/// `revokePairing`). A selected profile is named on every call; the approve
/// and revoke routes read it from the body. An empty profile travels
/// unnamed, which the server resolves to the profile it was launched for.
class MessagingPairingClient {
  MessagingPairingClient(this._dashboard);

  final DashboardClient _dashboard;

  Future<PairingSnapshot> load(String profile) async {
    final Map<String, dynamic> answer;
    try {
      final named = profile.trim();
      answer = await _dashboard.apiGet(
        named.isEmpty
            ? 'pairing'
            : 'pairing?profile=${Uri.encodeQueryComponent(named)}',
      );
    } on DashboardHttpException catch (error) {
      if (error.statusCode == 404 || error.statusCode == 405) {
        throw const PairingRouteMissing();
      }
      rethrow;
    }
    List<PairingEntry> rows(String key) {
      final raw = answer[key];
      if (raw is! List) return const [];
      return [
        for (final item in raw) ?PairingEntry.tryParse(item),
      ];
    }

    return PairingSnapshot(
      pending: rows('pending'),
      approved: rows('approved'),
    );
  }

  /// Grants on the row's `request_id`, never on a code.
  Future<void> approve(PairingEntry entry, String profile) async {
    try {
      await _dashboard.apiPost(
        'pairing/approve',
        body: {
          'platform': entry.platform,
          'request_id': entry.requestId,
          if (profile.trim().isNotEmpty) 'profile': profile.trim(),
        },
      );
    } on DashboardHttpException catch (error) {
      if (error.statusCode == 429) throw const PairingLockedOut();
      rethrow;
    }
  }

  Future<void> revoke(PairingEntry entry, String profile) async {
    await _dashboard.apiPost(
      'pairing/revoke',
      body: {
        'platform': entry.platform,
        'user_id': entry.userId,
        if (profile.trim().isNotEmpty) 'profile': profile.trim(),
      },
    );
  }
}
