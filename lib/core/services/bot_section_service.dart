import 'dart:math';

import '../models/agent_profile.dart';
import 'bot_profile_client.dart';

final class BotSectionChange {
  final String? id;
  final String? name;
  const BotSectionChange(this.id, this.name);
  Map<String, dynamic> get patch => {'sectionId': id, 'sectionName': name};

  factory BotSectionChange.create(String name) {
    final clean = name.trim();
    if (clean.isEmpty ||
        clean.length > 40 ||
        clean.codeUnits.any((c) => c < 32 || c == 127)) {
      throw const FormatException('Invalid section name');
    }
    return BotSectionChange(
      'sec-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}-'
      '${Random.secure().nextInt(60466176).toRadixString(36)}',
      clean,
    );
  }
}

final class BotSectionResult {
  final Map<String, BotSectionChange> succeeded;
  final Map<String, BotSectionChange> failed;
  const BotSectionResult(this.succeeded, this.failed);
}

/// The supplied profiles and gateway must belong to this same connection.
final class BotSectionService {
  final String connectionId;
  final BotProfileGateway gateway;
  const BotSectionService(this.connectionId, this.gateway);

  Future<BotSectionResult> apply(
    String ownerConnection,
    Map<String, BotSectionChange> changes,
  ) async {
    if (ownerConnection != connectionId) {
      throw StateError('Wrong section owner');
    }
    final succeeded = <String, BotSectionChange>{};
    final failed = <String, BotSectionChange>{};
    for (final entry in changes.entries) {
      try {
        await gateway.patchBotMetadata(entry.key, entry.value.patch);
        succeeded[entry.key] = entry.value;
      } catch (_) {
        failed[entry.key] = entry.value;
      }
    }
    return BotSectionResult(succeeded, failed);
  }

  static Map<String, BotSectionChange> members(
    Iterable<AgentProfile> profiles,
    String id,
    BotSectionChange change,
  ) => {
    for (final profile in profiles)
      if (profile.botSectionId == id) profile.name: change,
  };
}
