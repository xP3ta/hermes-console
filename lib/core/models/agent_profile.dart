import 'dart:convert';
import 'dart:typed_data';

/// Bounded roster projection returned by `profiles.list(include_sessions)`.
///
/// This is deliberately not a raw JSON holder: profile rows can cross a
/// remote boundary and may gain fields in newer Gateways. Console retains only
/// the small, documented summary needed to paint native roster/work state.
final class AgentProfileSessionSummary {
  final String id;
  final String? resolvedId;
  final String title;
  final String rootTitle;
  final String preview;
  final double? startedAt;
  final double? lastActive;
  final int messageCount;

  const AgentProfileSessionSummary({
    required this.id,
    this.resolvedId,
    this.title = '',
    this.rootTitle = '',
    this.preview = '',
    this.startedAt,
    this.lastActive,
    this.messageCount = 0,
  });

  static AgentProfileSessionSummary? tryParse(Object? raw) {
    final map = _stringKeyedMap(raw);
    if (map == null) return null;
    final id = _boundedText(map['id'], 512);
    if (id == null) return null;
    return AgentProfileSessionSummary(
      id: id,
      resolvedId: _boundedText(map['resolved_id'], 512),
      title: _boundedText(map['title'], 512) ?? '',
      rootTitle: _boundedText(map['root_title'], 512) ?? '',
      preview: _boundedText(map['preview'], 512) ?? '',
      startedAt: _nonNegativeFinite(map['started_at']),
      lastActive: _nonNegativeFinite(map['last_active']),
      messageCount: _nonNegativeInt(map['message_count']) ?? 0,
    );
  }
}

/// Freshest hidden Kanban/tool worker reported by Hermes for one profile.
///
/// The row is a liveness hint, not a conversation entry. Only the two
/// upstream worker sources are accepted so an arbitrary hidden session cannot
/// be surfaced as background work.
final class AgentProfileWorkerSession {
  final String id;
  final String source;
  final String title;
  final double lastActive;

  const AgentProfileWorkerSession({
    required this.id,
    required this.source,
    required this.title,
    required this.lastActive,
  });

  static AgentProfileWorkerSession? tryParse(Object? raw) {
    final map = _stringKeyedMap(raw);
    if (map == null) return null;
    final id = _boundedText(map['id'], 512);
    final source = _boundedText(map['source'], 32)?.toLowerCase();
    final title = _boundedText(map['title'], 512) ?? '';
    final lastActive = _nonNegativeFinite(map['last_active']);
    if (id == null ||
        source == null ||
        !const {'kanban', 'tool'}.contains(source) ||
        lastActive == null) {
      return null;
    }
    return AgentProfileWorkerSession(
      id: id,
      source: source,
      title: title,
      lastActive: lastActive,
    );
  }
}

Map<String, dynamic>? _stringKeyedMap(Object? raw) {
  if (raw is! Map) return null;
  try {
    return Map<String, dynamic>.from(raw);
  } catch (_) {
    return null;
  }
}

String? _boundedText(Object? raw, int maxLength) {
  if (raw is! String) return null;
  final value = raw.trim();
  if (value.isEmpty ||
      value.length > maxLength ||
      value.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
    return null;
  }
  return value;
}

double? _nonNegativeFinite(Object? raw) {
  if (raw is! num) return null;
  final value = raw.toDouble();
  return value.isFinite && value >= 0 ? value : null;
}

int? _nonNegativeInt(Object? raw) {
  if (raw is! num || !raw.isFinite || raw < 0 || raw != raw.truncate()) {
    return null;
  }
  return raw.toInt();
}

/// Perfil de agente devuelto por GET /api/profiles (Dashboard, puerto 9119).
///
/// Cada perfil es un home aislado (`~/.hermes/profiles/<name>/`) con su propio
/// config.yaml, SOUL.md, .env, skills y cron. El perfil `default` vive en
/// `~/.hermes` directamente y no se puede borrar.
class AgentProfile {
  final String name;
  final String path;
  final bool isDefault;
  final String model;
  final String provider;
  final bool hasEnv;
  final int skillCount;
  final bool gatewayRunning;
  final String description;
  final String? botChatSessionId;
  final Map<String, dynamic> botModeUiMeta;
  final bool botModeMetadataPublished;
  final bool hasInvalidBotModeMetadata;
  final bool hasAvatar;
  final AgentProfileSessionSummary? lastSession;
  final AgentProfileSessionSummary? preferredSession;
  final AgentProfileWorkerSession? workerSession;

  /// Si proviene de una distribución (perfil compartido como repo Git).
  final String? distributionName;
  final String? distributionVersion;
  final String? distributionSource;
  final bool hasAlias;

  const AgentProfile({
    required this.name,
    this.path = '',
    this.isDefault = false,
    this.model = '',
    this.provider = '',
    this.hasEnv = false,
    this.skillCount = 0,
    this.gatewayRunning = false,
    this.description = '',
    this.botChatSessionId,
    this.botModeUiMeta = const {},
    this.botModeMetadataPublished = false,
    this.hasInvalidBotModeMetadata = false,
    this.hasAvatar = false,
    this.lastSession,
    this.preferredSession,
    this.workerSession,
    this.distributionName,
    this.distributionVersion,
    this.distributionSource,
    this.hasAlias = false,
  });

  bool get isDistribution =>
      distributionName != null && distributionName!.isNotEmpty;

  /// The key is authoritative when absent, explicitly null or a validated
  /// durable id. Desktop signals "no canonical chat" by writing `chat: null`
  /// (the hermes-bots plugin resets the pin that way before recreating it),
  /// and the gateway returns that null verbatim, so a present-but-null key is
  /// an empty slot, not corruption. Keeping the distinction for non-null
  /// malformed values prevents a concurrent Desktop value from being treated
  /// as an empty slot during Bot Mode read-modify-write.
  bool get hasInvalidBotChatPin =>
      hasInvalidBotModeMetadata ||
      (botModeUiMeta.containsKey('chat') &&
          botModeUiMeta['chat'] != null &&
          botChatSessionId == null);

  /// Desktop writes `chat: null` while recreating the forever-chat.
  /// A missing `chat` key is not a reset: appearance-only `hermes-bots`
  /// metadata is common on stock Agent installs.
  bool get desktopClearedBotChatPin =>
      botModeUiMeta.containsKey('chat') && botModeUiMeta['chat'] == null;

  /// Gateway-native Bot Chat from `profiles.list(include_sessions: true)`.
  String? get gatewayBotChatSessionId {
    final preferred = preferredSession;
    if (preferred == null) return null;
    final title = preferred.rootTitle.isNotEmpty
        ? preferred.rootTitle
        : preferred.title;
    if (title != 'Bot Chat') return null;
    final id = (preferred.resolvedId ?? preferred.id).trim();
    if (id.isEmpty ||
        id.startsWith('mob-') ||
        id.length > 512 ||
        id.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
      return null;
    }
    return id;
  }

  String? get botTitle => _botMetaText('title', 128);

  String? get botGroup => _botMetaText('group', 128);

  String? get botShape {
    final value = _botMetaText('shape', 82)?.toLowerCase();
    if (value == null || !RegExp(r'^[a-z][a-z0-9:_-]{0,81}$').hasMatch(value)) {
      return null;
    }
    return value;
  }

  String? get botImageKind {
    final value = _botMetaText('imageKind', 16)?.toLowerCase();
    return value == 'photo' || value == 'shape' ? value : null;
  }

  bool get hasCustomBotAppearance => botModeUiMeta['custom'] == true;

  bool get botHidden => botModeUiMeta['hidden'] == true;

  bool get botPinned => botModeUiMeta['pinned'] == true;

  String? get botColorHex {
    final value = _botMetaText('color', 7)?.toLowerCase();
    return value != null && RegExp(r'^#[0-9a-f]{6}$').hasMatch(value)
        ? value
        : null;
  }

  String? _botMetaText(String key, int maxRunes) {
    final raw = botModeUiMeta[key];
    if (raw is! String) return null;
    final value = raw.trim();
    if (value.isEmpty || value.runes.length > maxRunes) return null;
    return value;
  }

  factory AgentProfile.fromJson(Map<String, dynamic> json) {
    String? str(Object? v) {
      final s = v?.toString();
      return (s == null || s.isEmpty) ? null : s;
    }

    var botModeMetadataPublished = false;
    var hasInvalidBotModeMetadata = false;

    Map<String, dynamic> botModeUiMeta() {
      final uiMeta = json['ui_meta'];
      if (uiMeta == null) return const {};
      if (uiMeta is! Map) {
        hasInvalidBotModeMetadata = true;
        return const {};
      }
      if (!uiMeta.containsKey('hermes-bots')) return const {};
      final botMeta = uiMeta['hermes-bots'];
      if (botMeta is! Map) {
        hasInvalidBotModeMetadata = true;
        return const {};
      }
      try {
        // JSON object keys are strings. Preserve the authoritative namespace
        // byte-for-byte at the key/value level; silently filtering an unknown
        // Desktop field here would make the later read-modify-write destructive.
        final normalized = Map<String, dynamic>.unmodifiable(
          Map<String, dynamic>.from(botMeta),
        );
        botModeMetadataPublished = true;
        return normalized;
      } catch (_) {
        hasInvalidBotModeMetadata = true;
        return const {};
      }
    }

    String? botChatSessionId(Map<String, dynamic> botMeta) {
      final raw = botMeta['chat'];
      if (raw is! String) return null;
      final value = raw.trim();
      if (value.isEmpty ||
          value.startsWith('mob-') ||
          value.length > 512 ||
          value.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
        return null;
      }
      return value;
    }

    final botMeta = botModeUiMeta();

    return AgentProfile(
      name: (json['name'] ?? '').toString(),
      path: (json['path'] ?? '').toString(),
      isDefault: json['is_default'] == true,
      model: (json['model'] ?? '').toString(),
      provider: (json['provider'] ?? '').toString(),
      hasEnv: json['has_env'] == true,
      skillCount: (json['skill_count'] as num?)?.toInt() ?? 0,
      gatewayRunning: json['gateway_running'] == true,
      description: (json['description'] ?? '').toString(),
      botChatSessionId: botChatSessionId(botMeta),
      botModeUiMeta: botMeta,
      botModeMetadataPublished: botModeMetadataPublished,
      hasInvalidBotModeMetadata: hasInvalidBotModeMetadata,
      hasAvatar: json['has_avatar'] == true,
      lastSession: AgentProfileSessionSummary.tryParse(json['last_session']),
      preferredSession: AgentProfileSessionSummary.tryParse(
        json['preferred_session'],
      ),
      workerSession: AgentProfileWorkerSession.tryParse(json['worker_session']),
      distributionName: str(json['distribution_name']),
      distributionVersion: str(json['distribution_version']),
      distributionSource: str(json['distribution_source']),
      hasAlias: json['has_alias'] == true,
    );
  }
}

/// Avatar raster profile-aware almacenado por Hermes en
/// `profiles.set_asset(..., asset: 'avatar')`.
///
/// Bot Mode guarda aquí tanto imágenes como el frame estático de PetDex. La
/// app acepta sólo formatos raster y limita el payload antes de decodificarlo:
/// un asset remoto corrupto nunca debe disparar una asignación sin cota.
final class AgentProfileAvatar {
  static const maxBytes = 2000000;
  static const maxBase64Characters = 2666668;
  static const maxEdge = 4096;
  static const maxPixels = 16777216;

  final String mimeType;
  final Uint8List bytes;
  final int width;
  final int height;

  const AgentProfileAvatar({
    required this.mimeType,
    required this.bytes,
    this.width = 0,
    this.height = 0,
  });

  factory AgentProfileAvatar.fromDataUri(String raw) {
    const prefixes = <String, String>{
      'data:image/png;base64,': 'image/png',
      'data:image/webp;base64,': 'image/webp',
      'data:image/jpeg;base64,': 'image/jpeg',
    };
    String? mimeType;
    String? encoded;
    for (final entry in prefixes.entries) {
      if (raw.startsWith(entry.key)) {
        mimeType = entry.value;
        encoded = raw.substring(entry.key.length);
        break;
      }
    }
    if (mimeType == null || encoded == null || encoded.isEmpty) {
      throw const FormatException('Unsupported profile avatar data URI');
    }
    // Base64 crece aproximadamente 4/3. La cota previa evita reservar un
    // string decodificado desproporcionado antes de comprobar bytes reales.
    if (encoded.length > maxBase64Characters) {
      throw const FormatException('Profile avatar exceeds size limit');
    }
    if (!_isCanonicalBase64(encoded)) {
      throw const FormatException('Invalid profile avatar base64');
    }
    final bytes = base64Decode(encoded);
    if (bytes.isEmpty || bytes.length > maxBytes) {
      throw const FormatException('Invalid profile avatar payload');
    }
    final matchesMime = switch (mimeType) {
      'image/png' =>
        bytes.length >= 8 &&
            bytes[0] == 0x89 &&
            bytes[1] == 0x50 &&
            bytes[2] == 0x4e &&
            bytes[3] == 0x47 &&
            bytes[4] == 0x0d &&
            bytes[5] == 0x0a &&
            bytes[6] == 0x1a &&
            bytes[7] == 0x0a,
      'image/jpeg' =>
        bytes.length >= 3 &&
            bytes[0] == 0xff &&
            bytes[1] == 0xd8 &&
            bytes[2] == 0xff,
      'image/webp' =>
        bytes.length >= 12 &&
            bytes[0] == 0x52 &&
            bytes[1] == 0x49 &&
            bytes[2] == 0x46 &&
            bytes[3] == 0x46 &&
            bytes[8] == 0x57 &&
            bytes[9] == 0x45 &&
            bytes[10] == 0x42 &&
            bytes[11] == 0x50,
      _ => false,
    };
    if (!matchesMime) {
      throw const FormatException('Profile avatar MIME does not match bytes');
    }
    final dimensions = _rasterDimensions(bytes, mimeType);
    if (dimensions == null ||
        dimensions.$1 <= 0 ||
        dimensions.$2 <= 0 ||
        dimensions.$1 > maxEdge ||
        dimensions.$2 > maxEdge ||
        dimensions.$1 * dimensions.$2 > maxPixels) {
      throw const FormatException('Invalid profile avatar dimensions');
    }
    return AgentProfileAvatar(
      mimeType: mimeType,
      bytes: bytes,
      width: dimensions.$1,
      height: dimensions.$2,
    );
  }

  /// Canonical payload accepted by `profiles.set_asset`.
  ///
  /// Keeping this conversion on the validated value lets compensating writes
  /// restore the previous asset without retaining an untrusted remote string.
  String toDataUri() => 'data:$mimeType;base64,${base64Encode(bytes)}';
}

bool _isCanonicalBase64(String value) {
  if (value.isEmpty || value.length % 4 != 0) return false;
  var paddingStarted = false;
  var padding = 0;
  for (var index = 0; index < value.length; index++) {
    final unit = value.codeUnitAt(index);
    final isAlphabet =
        (unit >= 0x41 && unit <= 0x5a) ||
        (unit >= 0x61 && unit <= 0x7a) ||
        (unit >= 0x30 && unit <= 0x39) ||
        unit == 0x2b ||
        unit == 0x2f;
    if (isAlphabet && !paddingStarted) continue;
    if (unit == 0x3d && index >= value.length - 2) {
      paddingStarted = true;
      padding++;
      if (padding <= 2) continue;
    }
    return false;
  }
  return true;
}

(int, int)? _rasterDimensions(Uint8List bytes, String mimeType) {
  int u16be(int offset) => (bytes[offset] << 8) | bytes[offset + 1];
  int u24le(int offset) =>
      bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16);
  int u32be(int offset) =>
      (bytes[offset] << 24) |
      (bytes[offset + 1] << 16) |
      (bytes[offset + 2] << 8) |
      bytes[offset + 3];

  if (mimeType == 'image/png') {
    if (bytes.length < 24 ||
        bytes[12] != 0x49 ||
        bytes[13] != 0x48 ||
        bytes[14] != 0x44 ||
        bytes[15] != 0x52) {
      return null;
    }
    return (u32be(16), u32be(20));
  }

  if (mimeType == 'image/jpeg') {
    var offset = 2;
    while (offset + 8 < bytes.length) {
      if (bytes[offset] != 0xff) {
        offset++;
        continue;
      }
      while (offset < bytes.length && bytes[offset] == 0xff) {
        offset++;
      }
      if (offset >= bytes.length) return null;
      final marker = bytes[offset++];
      if (marker == 0xd8 || marker == 0xd9) continue;
      if (offset + 1 >= bytes.length) return null;
      final length = u16be(offset);
      if (length < 2 || offset + length > bytes.length) return null;
      final isStartOfFrame =
          marker >= 0xc0 &&
          marker <= 0xcf &&
          !const {0xc4, 0xc8, 0xcc}.contains(marker);
      if (isStartOfFrame && length >= 7) {
        return (u16be(offset + 5), u16be(offset + 3));
      }
      offset += length;
    }
    return null;
  }

  if (mimeType == 'image/webp') {
    if (bytes.length < 16) return null;
    final tag = String.fromCharCodes(bytes.sublist(12, 16));
    if (tag == 'VP8X' && bytes.length >= 30) {
      return (1 + u24le(24), 1 + u24le(27));
    }
    if (tag == 'VP8L' && bytes.length >= 25 && bytes[20] == 0x2f) {
      final bits =
          bytes[21] | (bytes[22] << 8) | (bytes[23] << 16) | (bytes[24] << 24);
      return ((bits & 0x3fff) + 1, ((bits >> 14) & 0x3fff) + 1);
    }
    if (tag == 'VP8 ' &&
        bytes.length >= 30 &&
        bytes[23] == 0x9d &&
        bytes[24] == 0x01 &&
        bytes[25] == 0x2a) {
      final width = bytes[26] | (bytes[27] << 8);
      final height = bytes[28] | (bytes[29] << 8);
      return (width & 0x3fff, height & 0x3fff);
    }
  }
  return null;
}
