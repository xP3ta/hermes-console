import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/core_read.dart';
import 'connection_manager.dart';

/// Largest transcript, in JSON characters, the phone exports (Desktop's own
/// cap is 32 M; a phone has far less memory).
const sessionExportMaxJsonChars = 8000000;

enum SessionExportResult {
  /// The share sheet was opened once with the file.
  shared,

  /// The transcript passed [sessionExportMaxJsonChars]; no file was written.
  tooLarge,

  /// The session no longer exists on the server (404).
  notFound,

  /// The server could not read it now (503, network).
  unavailable,

  /// The screen was left before the file was ready; nothing was shared.
  cancelled,

  /// Anything else; no private detail is carried.
  failed,
}

/// `${slug(title) || 'session'}-${slug(id).slice(0, 8) || 'session'}.json`, the
/// name Desktop's `session-export.ts` gives the file. A slug is lower case,
/// runs outside `[a-z0-9._-]` become `-`, extreme dashes go, at most 48.
String sessionExportFileName(String? title, String id) {
  String slug(String? value) {
    final text = (value ?? '')
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9._-]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final cut = text.length <= 48 ? text : text.substring(0, 48);
    return cut.replaceAll(RegExp(r'-+$'), '');
  }

  final name = slug(title);
  final idSlug = slug(id);
  final short = idSlug.length <= 8 ? idSlug : idSlug.substring(0, 8);
  return '${name.isEmpty ? 'session' : name}-'
      '${short.isEmpty ? 'session' : short}.json';
}

/// The public scalars of a list row, for the `session` block of the export.
/// Free text of the conversation (previews) stays out.
Map<String, Object?> sessionExportRow(Session session) => {
  'id': session.id,
  'title': session.title,
  'model': session.model,
  'source': session.source,
  'message_count': session.messageCount,
  'started_at': session.startedAt,
  'ended_at': session.endedAt,
  'last_active': session.lastActivityAt,
  'cwd': session.cwd,
  'git_repo_root': session.gitRepoRoot,
  'git_branch': session.gitBranch,
  'profile': session.profile,
  'archived': session.archived,
  'input_tokens': session.inputTokens,
  'output_tokens': session.outputTokens,
  'estimated_cost_usd': session.estimatedCostUsd,
  'actual_cost_usd': session.actualCostUsd,
};

/// Reads a whole transcript, writes it as JSON to a temporary file, opens the
/// system share sheet once and deletes the file. The JSON may hold private
/// conversation data: it is never logged and never kept past the share.
final class SessionExportService {
  SessionExportService({
    required this.readMessages,
    Future<Directory> Function()? tempDir,
    Future<void> Function(File file)? shareFile,
    DateTime Function()? clock,
    this.maxJsonChars = sessionExportMaxJsonChars,
  }) : _tempDir = tempDir ?? getTemporaryDirectory,
       _shareFile = shareFile ?? _defaultShare,
       _clock = clock ?? DateTime.now;

  final Future<List<Map<String, dynamic>>> Function(
    String sessionId, {
    String? profile,
    int? maxJsonChars,
  })
  readMessages;
  final int maxJsonChars;
  final Future<Directory> Function() _tempDir;
  final Future<void> Function(File file) _shareFile;
  final DateTime Function() _clock;

  static Future<void> _defaultShare(File file) async {
    await Share.shareXFiles([XFile(file.path, mimeType: 'application/json')]);
  }

  /// Exports [session] under [title] (its display name). [isCancelled] is
  /// asked once the transcript is read: the screen may be gone by then.
  Future<SessionExportResult> export(
    Session session, {
    String? title,
    bool Function()? isCancelled,
  }) async {
    final List<Map<String, dynamic>> messages;
    try {
      messages = await readMessages(
        session.id,
        profile: session.profile,
        maxJsonChars: maxJsonChars,
      );
    } on SessionTranscriptTooLargeException {
      return SessionExportResult.tooLarge;
    } on CoreReadException catch (error) {
      return switch (error.kind) {
        CoreReadErrorKind.notFound => SessionExportResult.notFound,
        CoreReadErrorKind.temporarilyUnavailable =>
          SessionExportResult.unavailable,
        _ => SessionExportResult.failed,
      };
    } catch (_) {
      return SessionExportResult.unavailable;
    }
    if (isCancelled?.call() ?? false) return SessionExportResult.cancelled;

    File? file;
    try {
      final payload = <String, Object?>{
        'exported_at': _clock().toUtc().toIso8601String(),
        'session_id': session.id,
        'title': title,
        'session': sessionExportRow(session),
        'message_count': messages.length,
        'messages': messages,
      };
      final directory = await _tempDir();
      file = File(
        '${directory.path}/${sessionExportFileName(title, session.id)}',
      );
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(payload),
      );
      if (isCancelled?.call() ?? false) return SessionExportResult.cancelled;
      await _shareFile(file);
      return SessionExportResult.shared;
    } catch (_) {
      return SessionExportResult.failed;
    } finally {
      try {
        if (file != null && file.existsSync()) await file.delete();
      } catch (_) {
        // A temp file the OS will clear anyway.
      }
    }
  }
}
