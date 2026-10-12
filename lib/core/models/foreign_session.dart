/// Claude Code / Codex sessions found on the serving backend, read through
/// `session.foreign.*`. Ids are opaque handles: never shown, logged or
/// persisted.
enum ForeignSource {
  claude('claude'),
  codex('codex');

  final String wire;
  const ForeignSource(this.wire);

  static ForeignSource? tryParse(Object? value) {
    for (final source in values) {
      if (source.wire == value) return source;
    }
    return null;
  }
}

String _text(Object? value, int max) =>
    value is String ? String.fromCharCodes(value.runes.take(max)) : '';

String? _nullableText(Object? value, int max) {
  final text = _text(value, max).trim();
  return text.isEmpty ? null : text;
}

final class ForeignSessionRow {
  final String id;
  final ForeignSource source;
  final String label;
  final String title;
  final String? cwd;
  final double mtime;
  final int turnCount;
  final String excerpt;

  const ForeignSessionRow({
    required this.id,
    required this.source,
    required this.label,
    this.title = '',
    this.cwd,
    this.mtime = 0,
    this.turnCount = 0,
    this.excerpt = '',
  });

  static ForeignSessionRow? tryParse(Object? value) {
    if (value is! Map) return null;
    final id = value['id'];
    final source = ForeignSource.tryParse(value['source']);
    if (id is! String || id.isEmpty || id.length > 1024 || source == null) {
      return null;
    }
    final mtime = value['mtime'];
    final turns = value['turn_count'];
    return ForeignSessionRow(
      id: id,
      source: source,
      label: _text(value['label'], 128),
      title: _text(value['title'], 512),
      cwd: _nullableText(value['cwd'], 1024),
      mtime: mtime is num ? mtime.toDouble() : 0,
      turnCount: turns is int && turns > 0 ? turns : 0,
      excerpt: _text(value['excerpt'], 1024),
    );
  }
}

final class ForeignSessionPage {
  final List<ForeignSessionRow> sessions;
  final int? nextOffset;
  final String host;

  /// Logs on this page that failed to parse.
  final int unreadable;

  const ForeignSessionPage({
    required this.sessions,
    this.nextOffset,
    this.host = '',
    this.unreadable = 0,
  });

  factory ForeignSessionPage.fromJson(Map<String, dynamic> json) {
    final rows = json['sessions'];
    final next = json['next_offset'];
    final unreadable = json['unreadable'];
    return ForeignSessionPage(
      sessions: rows is List
          ? rows
                .map(ForeignSessionRow.tryParse)
                .whereType<ForeignSessionRow>()
                .toList(growable: false)
          : const [],
      nextOffset: next is int && next >= 0 ? next : null,
      host: _text(json['host'], 256),
      unreadable: unreadable is int && unreadable > 0 ? unreadable : 0,
    );
  }
}

final class ForeignMessage {
  final String role;
  final String content;

  const ForeignMessage({required this.role, required this.content});
}

final class ForeignPreview {
  final List<ForeignMessage> messages;
  final int total;
  final bool truncated;

  /// The local session id of an earlier import, when there is one.
  final String? alreadyImported;
  final String? cwd;

  const ForeignPreview({
    required this.messages,
    this.total = 0,
    this.truncated = false,
    this.alreadyImported,
    this.cwd,
  });

  factory ForeignPreview.fromJson(Map<String, dynamic> json) {
    final rows = json['messages'];
    final messages = <ForeignMessage>[];
    if (rows is List) {
      for (final row in rows) {
        if (row is! Map) continue;
        final role = row['role'];
        final content = row['content'];
        if (role is! String || content is! String) continue;
        messages.add(
          ForeignMessage(
            role: _text(role, 32),
            content: String.fromCharCodes(content.runes.take(8000)),
          ),
        );
      }
    }
    final total = json['total'];
    return ForeignPreview(
      messages: messages,
      total: total is int && total > 0 ? total : 0,
      truncated: json['truncated'] == true,
      alreadyImported: _nullableText(json['already_imported'], 1024),
      cwd: _nullableText(json['cwd'], 1024),
    );
  }
}

final class ForeignImportResult {
  final String sessionId;
  final bool alreadyImported;

  const ForeignImportResult({
    required this.sessionId,
    this.alreadyImported = false,
  });

  static ForeignImportResult? tryParse(Map<String, dynamic> json) {
    final id = json['session_id'];
    if (id is! String || id.trim().isEmpty) return null;
    return ForeignImportResult(
      sessionId: id.trim(),
      alreadyImported: json['already_imported'] == true,
    );
  }
}

/// Gateway reads and the one write behind the import screen. A missing method
/// (`-32601`) surfaces as an unsupported `DesktopControlFailure`.
abstract interface class HermesForeignSessionGateway {
  Future<ForeignSessionPage> foreignList({
    String? profile,
    ForeignSource? source,
    int? offset,
  });

  Future<ForeignPreview> foreignPreview(String id, {String? profile});

  Future<ForeignImportResult> foreignImport(String id, {String? profile});
}
