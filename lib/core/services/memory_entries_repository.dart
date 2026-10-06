// Built-in memory entries (MEMORY.md / USER.md) through the dashboard.
//
// Same upstream route Hermes Desktop uses to edit memories:
//   GET    /api/learning/graph?profile=   entries as `kind: memory` nodes
//   GET    /api/learning/node?id=&profile= one entry's full text
//   PUT    /api/learning/node {id, content, profile}
//   DELETE /api/learning/node {id, profile}
// The server applies edits through the memory tool's own lock and size cap,
// and node ids carry a fingerprint of the entry's text, so an id minted
// before another surface changed the entry no longer resolves.
//
// Whole-file `/api/fs/write-text` is deliberately not used: it bypasses that
// lock (upstream #119668), needs the server's absolute home path, and with
// `?profile=` it targets the profile's SSH workspace when one is configured.
import 'dart:convert';

import 'connection_manager.dart';

/// Which built-in file an entry lives in.
enum MemoryFileKind {
  memory('memory'),
  user('profile');

  /// The `memorySource` value upstream uses for this file.
  final String source;
  const MemoryFileKind(this.source);

  static MemoryFileKind? fromKey(String key) => switch (key) {
    'memory' => MemoryFileKind.memory,
    'user' => MemoryFileKind.user,
    _ => null,
  };
}

/// One entry as listed by the learning graph.
class MemoryEntry {
  final String id;
  final String label;
  const MemoryEntry({required this.id, required this.label});
}

/// An entry's full text as it was when the editor loaded it.
class LoadedMemoryEntry {
  final String id;
  final String content;
  const LoadedMemoryEntry({required this.id, required this.content});
}

enum MemoryEntryFailureKind {
  /// The entry changed or disappeared since it was loaded.
  conflict,

  /// The text is over the client-side cap; nothing was sent.
  tooLarge,

  /// The server refused the write (for example its character limit).
  rejected,

  /// The server has no learning routes (older Hermes).
  unsupported,

  /// Network, auth or server failure.
  unavailable,
}

class MemoryEntryFailure implements Exception {
  final MemoryEntryFailureKind kind;

  /// Server-provided reason for [MemoryEntryFailureKind.rejected].
  final String detail;
  const MemoryEntryFailure(this.kind, {this.detail = ''});

  @override
  String toString() => 'MemoryEntryFailure($kind)';
}

/// Transport seam: the dashboard calls this repository makes.
abstract interface class MemoryEntriesRest {
  Future<Map<String, dynamic>> get(String endpoint);
  Future<Map<String, dynamic>> put(String endpoint, Map<String, dynamic> body);
  Future<void> delete(String endpoint, Map<String, dynamic> body);
}

class DashboardMemoryEntriesRest implements MemoryEntriesRest {
  final DashboardClient client;
  const DashboardMemoryEntriesRest(this.client);

  @override
  Future<Map<String, dynamic>> get(String endpoint) => client.apiGet(endpoint);

  @override
  Future<Map<String, dynamic>> put(
    String endpoint,
    Map<String, dynamic> body,
  ) => client.apiPut(endpoint, body: body);

  @override
  Future<void> delete(String endpoint, Map<String, dynamic> body) =>
      client.apiDelete(endpoint, body: body);
}

class MemoryEntriesRepository {
  /// Client-side ceiling for one entry. The server's own per-file character
  /// limit (memory_char_limit / user_char_limit) is far lower and is still
  /// enforced there; this only refuses a pasted megablob before sending it.
  static const int maxEntryBytes = 64 * 1024;

  final MemoryEntriesRest rest;
  final String _profile;

  /// [profile] empty means the default profile. It is always sent by name:
  /// a dashboard launched under another profile would otherwise act on its
  /// own home.
  MemoryEntriesRepository(this.rest, {String profile = ''})
    : _profile = profile.trim().isEmpty ? 'default' : profile.trim();

  String get profile => _profile;

  /// True when [content] is over [maxEntryBytes] once trimmed.
  static bool exceedsLimit(String content) =>
      utf8.encode(content.trim()).length > maxEntryBytes;

  String get _q => 'profile=${Uri.encodeQueryComponent(_profile)}';

  Future<List<MemoryEntry>> list(MemoryFileKind file) async {
    final result = await _guard(
      () => rest.get('learning/graph?$_q'),
      missingIsUnsupported: true,
    );
    final nodes = result['nodes'];
    if (nodes is! List) {
      throw const MemoryEntryFailure(MemoryEntryFailureKind.unavailable);
    }
    return [
      for (final node in nodes.whereType<Map>())
        if (node['kind'] == 'memory' &&
            node['memorySource'] == file.source &&
            node['id'] is String &&
            (node['id'] as String).startsWith('memory:'))
          MemoryEntry(
            id: node['id'] as String,
            label: '${node['label'] ?? ''}'.trim(),
          ),
    ];
  }

  Future<LoadedMemoryEntry> read(String id) async {
    final result = await _guard(
      () => rest.get('learning/node?id=${Uri.encodeQueryComponent(id)}&$_q'),
      // A node that no longer resolves is gone, not an old server.
      missingIsUnsupported: false,
    );
    final content = result['content'];
    if (result['ok'] != true || content is! String) {
      throw const MemoryEntryFailure(MemoryEntryFailureKind.unavailable);
    }
    return LoadedMemoryEntry(id: id, content: content);
  }

  /// Replaces [loaded] with [content] only if the entry still reads exactly
  /// as it did when loaded; otherwise throws a conflict and writes nothing.
  Future<void> save(LoadedMemoryEntry loaded, String content) async {
    final text = content.trim();
    if (exceedsLimit(text)) {
      throw const MemoryEntryFailure(MemoryEntryFailureKind.tooLarge);
    }
    await _ensureUnchanged(loaded);
    await _guard(
      () => rest.put('learning/node?$_q', {
        'id': loaded.id,
        'content': text,
        'profile': _profile,
      }),
      missingIsUnsupported: false,
      staleIsConflict: true,
    );
  }

  /// Removes [loaded] if it is still unchanged since it was loaded.
  Future<void> delete(LoadedMemoryEntry loaded) async {
    await _ensureUnchanged(loaded);
    await _guard(
      () async {
        await rest.delete('learning/node?$_q', {
          'id': loaded.id,
          'profile': _profile,
        });
        return const <String, dynamic>{};
      },
      missingIsUnsupported: false,
      staleIsConflict: true,
    );
  }

  Future<void> _ensureUnchanged(LoadedMemoryEntry loaded) async {
    final LoadedMemoryEntry current;
    try {
      current = await read(loaded.id);
    } on MemoryEntryFailure catch (failure) {
      // The id stopped resolving: someone changed or removed the entry.
      if (failure.kind == MemoryEntryFailureKind.rejected) {
        throw const MemoryEntryFailure(MemoryEntryFailureKind.conflict);
      }
      rethrow;
    }
    if (current.content.trim() != loaded.content.trim()) {
      throw const MemoryEntryFailure(MemoryEntryFailureKind.conflict);
    }
  }

  static String _detailOf(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['detail'] is String) {
        final detail = (decoded['detail'] as String).trim();
        return detail.length > 240 ? detail.substring(0, 240) : detail;
      }
    } on FormatException {
      // Not JSON: no detail.
    }
    return '';
  }

  Future<Map<String, dynamic>> _guard(
    Future<Map<String, dynamic>> Function() run, {
    required bool missingIsUnsupported,
    bool staleIsConflict = false,
  }) async {
    try {
      return await run();
    } on MemoryEntryFailure {
      rethrow;
    } on DashboardHttpException catch (error) {
      final status = error.statusCode;
      final detail = _detailOf(error.body);
      if (status == 405 || (status == 404 && missingIsUnsupported)) {
        throw const MemoryEntryFailure(MemoryEntryFailureKind.unsupported);
      }
      if (status == 404 || status == 400 || status == 409) {
        if (staleIsConflict && detail.contains('stale')) {
          throw const MemoryEntryFailure(MemoryEntryFailureKind.conflict);
        }
        throw MemoryEntryFailure(
          MemoryEntryFailureKind.rejected,
          detail: detail,
        );
      }
      if (status == 413) {
        throw const MemoryEntryFailure(MemoryEntryFailureKind.tooLarge);
      }
      throw const MemoryEntryFailure(MemoryEntryFailureKind.unavailable);
    } on TypeError {
      throw const MemoryEntryFailure(MemoryEntryFailureKind.unavailable);
    } on FormatException {
      throw const MemoryEntryFailure(MemoryEntryFailureKind.unavailable);
    } on Exception {
      throw const MemoryEntryFailure(MemoryEntryFailureKind.unavailable);
    }
  }
}
