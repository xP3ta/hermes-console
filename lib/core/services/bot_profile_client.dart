import 'dart:convert';

import '../models/agent_profile.dart';

typedef BotProfileRpc =
    Future<Map<String, dynamic>> Function(
      String method,
      Map<String, dynamic> params,
    );

abstract interface class BotProfileGateway {
  Future<void> patchBotMetadata(
    String profile,
    Map<String, dynamic> patch, {
    Set<String> remove = const {},
  });
  Future<Map<String, dynamic>> describeBotProfile(String profile);
  Future<Map<String, dynamic>> configureBotProfile(
    String profile,
    Map<String, dynamic> changes,
  );
  Future<String> duplicateBotProfile(String profile);
}

abstract interface class BotAvatarGenerationGateway {
  Future<bool> canGenerateBotAvatar();
  Future<AgentProfileAvatar> generateBotAvatar(String prompt);
}

final class BotDuplicateIncomplete implements Exception {
  final String name;
  const BotDuplicateIncomplete(this.name);
}

/// All mutations use the owning connection's RPC, never a cached roster.
final class BotProfileClient
    implements BotProfileGateway, BotAvatarGenerationGateway {
  final BotProfileRpc request;
  final _pendingCopies =
      <String, ({String name, Map<String, dynamic> patch})>{};
  BotProfileClient(this.request);

  @override
  Future<bool> canGenerateBotAvatar() async {
    try {
      return (await request('image.generate', {'probe': true}))['available'] ==
          true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<AgentProfileAvatar> generateBotAvatar(String prompt) async {
    if (prompt.trim().isEmpty || prompt.length > 2048) {
      throw const FormatException('Invalid avatar prompt');
    }
    final result = await request('image.generate', {
      'prompt':
          '${prompt.trim()}. Avatar for an AI agent: centered, solid color background, no text.',
      'aspect_ratio': 'square',
      'max_bytes': AgentProfileAvatar.maxBytes,
    });
    if (result['success'] != true || result['image_data'] is! String) {
      throw StateError('Avatar generation unavailable');
    }
    // Never fetch a server path or provider URL with the mobile credentials.
    return AgentProfileAvatar.fromDataUri(result['image_data'] as String);
  }

  static void validateProfile(String profile) {
    if (!RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$').hasMatch(profile)) {
      throw const FormatException('Invalid profile');
    }
  }

  Future<List<Map<String, dynamic>>> _profiles() async {
    final result = await request('profiles.list', {'include_sessions': false});
    final rows = result['profiles'];
    if (rows is! List) throw const FormatException('Invalid profile roster');
    return rows
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  @override
  Future<void> patchBotMetadata(
    String profile,
    Map<String, dynamic> patch, {
    Set<String> remove = const {},
  }) async {
    validateProfile(profile);
    if (patch.isEmpty && remove.isEmpty) return;
    if (patch.containsKey('image') || patch.containsKey('pet')) {
      throw const FormatException('Assets do not belong in bot metadata');
    }
    // JSON freezes the caller's patch across awaits and rejects non-wire values.
    final frozen = jsonDecode(jsonEncode(patch)) as Map<String, dynamic>;
    for (var attempt = 0; attempt < 3; attempt++) {
      final matches = (await _profiles()).where(
        (row) => row['name'] == profile,
      );
      if (matches.length != 1) throw StateError('Profile is unavailable');
      final row = matches.single;
      final ui = row['ui_meta'];
      if (ui != null && ui is! Map) {
        throw const FormatException('Invalid metadata');
      }
      final previous = (ui as Map?)?['hermes-bots'];
      if (previous != null && previous is! Map) {
        throw const FormatException('Invalid bot metadata');
      }
      final merged = <String, dynamic>{
        if (previous is Map) ...Map<String, dynamic>.from(previous),
      };
      for (final key in remove) {
        merged.remove(key);
      }
      merged.addAll(frozen);
      merged.remove('image');
      merged.remove('pet');
      final incoming = {'hermes-bots': merged};
      if (pythonJsonLength(incoming) > 65536) {
        throw const FormatException('Bot metadata exceeds the server limit');
      }
      final revisions = row['ui_meta_revisions'];
      final cas = revisions is Map;
      final revision = cas ? revisions['hermes-bots'] ?? 0 : null;
      if (cas && (revision is! int || revision < 0)) {
        throw const FormatException('Invalid metadata revision');
      }
      final result = await request('profiles.configure', {
        'name': profile,
        'ui_meta': incoming,
        if (cas) 'ui_meta_expected_revisions': {'hermes-bots': revision},
      });
      final applied = result['applied'];
      if (applied is Map && applied['ui_meta'] == true) return;
      final conflicts = applied is Map ? applied['ui_meta_conflicts'] : null;
      if (cas && conflicts is Map && conflicts.containsKey('hermes-bots')) {
        continue;
      }
      throw StateError('Bot metadata was not saved');
    }
    throw StateError('Bot metadata changed concurrently');
  }

  /// Python json.dumps uses ASCII escapes and spaces after separators.
  static int pythonJsonLength(Object? value) {
    final encoded = jsonEncode(value);
    var length = 0;
    var quoted = false;
    var escaped = false;
    for (final unit in encoded.codeUnits) {
      length += unit > 127 ? 6 : 1;
      if (!quoted && (unit == 44 || unit == 58)) length++;
      if (!escaped && unit == 34) quoted = !quoted;
      if (!escaped && unit == 92) {
        escaped = true;
      } else {
        escaped = false;
      }
    }
    return length;
  }

  @override
  Future<Map<String, dynamic>> describeBotProfile(String profile) {
    validateProfile(profile);
    return request('profiles.describe', {'name': profile});
  }

  @override
  Future<Map<String, dynamic>> configureBotProfile(
    String profile,
    Map<String, dynamic> changes,
  ) async {
    validateProfile(profile);
    const allowed = {
      'description',
      'soul',
      'model',
      'provider',
      'confirm_expensive_model',
      'disabled_skills',
      'enabled_toolsets',
      'enabled_mcp_servers',
    };
    if (changes.keys.any((key) => !allowed.contains(key))) {
      throw const FormatException('Unsupported profile change');
    }
    return request('profiles.configure', {'name': profile, ...changes});
  }

  @override
  Future<String> duplicateBotProfile(String profile) async {
    validateProfile(profile);
    final pending = _pendingCopies[profile];
    if (pending != null) {
      return _finishDuplicate(profile, pending.name, pending.patch);
    }
    final rows = await _profiles();
    final source = rows.where((row) => row['name'] == profile).single;
    final names = rows.map((row) => row['name']).toSet();
    String? name;
    for (var n = 2; n < 100; n++) {
      final suffix = '-$n';
      final base = profile.length > 64 - suffix.length
          ? profile.substring(0, 64 - suffix.length)
          : profile;
      if (!names.contains('$base$suffix')) {
        name = '$base$suffix';
        break;
      }
    }
    if (name == null) throw StateError('No free duplicate name');
    final result = await request('profiles.create', {
      'name': name,
      'clone_from': profile,
      'clone_all': true,
      'mirror_credentials': false,
      'no_alias': true,
      'description': source['description'] is String
          ? source['description']
          : '',
    });
    if (result['ok'] != true) throw StateError('Profile was not duplicated');
    // Full clone already copies assets, pets and memory on the server.
    final original = AgentProfile.fromJson(source);
    final title = String.fromCharCodes(
      (original.botTitle ?? profile).runes.take(121),
    );
    final patch = <String, dynamic>{
      'title': '$title (copy)',
      'created': DateTime.now().millisecondsSinceEpoch,
    };
    _pendingCopies[profile] = (name: name, patch: patch);
    return _finishDuplicate(profile, name, patch);
  }

  Future<String> _finishDuplicate(
    String source,
    String name,
    Map<String, dynamic> patch,
  ) async {
    try {
      await patchBotMetadata(name, patch, remove: {'chat'});
      _pendingCopies.remove(source);
      return name;
    } catch (_) {
      throw BotDuplicateIncomplete(name);
    }
  }
}
