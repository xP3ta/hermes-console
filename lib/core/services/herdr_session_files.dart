// Finding and reading the session file of a code agent on the server
// (1.4.0), read-only and over SFTP, the connection the app already has.
// Nothing here runs a command, writes a file or builds a shell line: a path
// goes to the server as an SFTP path made from names this file checks.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

/// One entry of a remote listing.
class HerdrRemoteFile {
  const HerdrRemoteFile({
    required this.name,
    required this.isDir,
    required this.size,
    required this.modified,
  });

  final String name;
  final bool isDir;
  final int size;
  final DateTime modified;
}

/// Where the transcripts are read from.
abstract interface class HerdrSessionFiles {
  /// The user's home folder on the server.
  Future<String> home();

  /// The entries of [dir]; empty when it does not exist.
  Future<List<HerdrRemoteFile>> list(String dir);

  /// Size and time of [path]; null when it does not exist.
  Future<HerdrRemoteFile?> stat(String path);

  /// Up to [length] bytes of [path] from [offset] (at most
  /// [SftpSessionFiles.maxRead] per call).
  Future<Uint8List> read(
    String path, {
    required int offset,
    required int length,
  });
}

/// SFTP-backed [HerdrSessionFiles]: read-only calls only.
class SftpSessionFiles implements HerdrSessionFiles {
  SftpSessionFiles(this._open);

  /// Most bytes one read returns.
  static const int maxRead = 1024 * 1024;

  static const Duration timeout = Duration(seconds: 12);

  final Future<SftpClient> Function() _open;
  Future<SftpClient>? _sftp;

  Future<SftpClient> _client() => _sftp ??= _open().timeout(timeout);

  Future<T> _use<T>(Future<T> Function(SftpClient sftp) body) async {
    try {
      return await body(await _client()).timeout(timeout);
    } catch (e) {
      _sftp = null;
      rethrow;
    }
  }

  static DateTime _time(int? seconds) =>
      DateTime.fromMillisecondsSinceEpoch((seconds ?? 0) * 1000, isUtc: true);

  @override
  Future<String> home() => _use((sftp) => sftp.absolute('.'));

  @override
  Future<List<HerdrRemoteFile>> list(String dir) => _use((sftp) async {
    try {
      final raw = await sftp.listdir(dir);
      return [
        for (final entry in raw)
          if (entry.filename != '.' && entry.filename != '..')
            HerdrRemoteFile(
              name: entry.filename,
              isDir: entry.attr.isDirectory,
              size: entry.attr.size ?? 0,
              modified: _time(entry.attr.modifyTime),
            ),
      ];
    } on SftpStatusError {
      return const [];
    }
  });

  @override
  Future<HerdrRemoteFile?> stat(String path) => _use((sftp) async {
    try {
      final attr = await sftp.stat(path);
      return HerdrRemoteFile(
        name: path.split('/').last,
        isDir: attr.isDirectory,
        size: attr.size ?? 0,
        modified: _time(attr.modifyTime),
      );
    } on SftpStatusError {
      return null;
    }
  });

  @override
  Future<Uint8List> read(
    String path, {
    required int offset,
    required int length,
  }) => _use((sftp) async {
    final file = await sftp.open(path);
    try {
      return await file.readBytes(
        offset: offset,
        length: length.clamp(0, maxRead),
      );
    } finally {
      await file.close();
    }
  });
}

/// Which tool wrote a session file.
enum HerdrTranscriptFormat { claude, codex }

/// A session file found for an agent.
class HerdrSessionRef {
  const HerdrSessionRef(this.path, this.format);

  final String path;
  final HerdrTranscriptFormat format;

  @override
  bool operator ==(Object other) =>
      other is HerdrSessionRef && other.path == path && other.format == format;

  @override
  int get hashCode => Object.hash(path, format);
}

/// A Claude Code project folder name: every character of the working folder
/// that is not a letter or digit becomes a dash.
String herdrClaudeProjectName(String cwd) =>
    cwd.replaceAll(RegExp(r'[^A-Za-z0-9]'), '-');

final RegExp _claudeFile = RegExp(r'^[A-Za-z0-9._-]+\.jsonl$');
final RegExp _codexFile = RegExp(r'^rollout-[A-Za-z0-9._-]+\.jsonl$');
final RegExp _datePart = RegExp(r'^[0-9]{1,4}$');
final RegExp _cwdField = RegExp(r'"cwd"\s*:\s*"((?:[^"\\]|\\.)*)"');

/// Most day folders and files looked at for a Codex session.
const int herdrCodexDays = 7;
const int herdrCodexFiles = 12;

/// How long a working agent may go without touching its file before the file
/// is not trusted to be its.
const Duration herdrSessionStale = Duration(minutes: 10);

/// From how long an agent has been quiet the check on «who wrote the file»
/// applies, and the slack allowed between its last word and the file's time.
const Duration herdrQuietCheck = Duration(seconds: 20);
const Duration herdrQuietMargin = Duration(seconds: 5);

/// The session file of the agent of [kind] that works in [cwd], or null when
/// there is no file that can be tied to it with certainty: no file, more
/// than one agent of that kind in the same folder ([sameKindInFolder] > 1,
/// the files cannot be told apart), or a working agent whose newest file has
/// not changed for [herdrSessionStale].
///
/// Claude Code keeps one folder per working directory; the newest file in it
/// is the agent's session. Codex keeps files by date: the newest ones are
/// opened at their first lines, which name the working directory.
Future<HerdrSessionRef?> herdrLocateSession(
  HerdrSessionFiles files, {
  required String kind,
  required String cwd,
  required DateTime now,
  required bool working,
  int sameKindInFolder = 1,
  Duration? quietFor,
}) async {
  if (sameKindInFolder > 1 || !cwd.startsWith('/')) return null;
  final home = await files.home();
  ({String path, DateTime modified, HerdrTranscriptFormat format})? found;
  if (kind == 'claude') {
    final dir = '$home/.claude/projects/${herdrClaudeProjectName(cwd)}';
    final listed = [
      for (final f in await files.list(dir))
        if (!f.isDir && _claudeFile.hasMatch(f.name)) f,
    ]..sort((a, b) => b.modified.compareTo(a.modified));
    if (listed.isNotEmpty) {
      found = (
        path: '$dir/${listed.first.name}',
        modified: listed.first.modified,
        format: HerdrTranscriptFormat.claude,
      );
    }
  } else if (kind == 'codex') {
    final candidates = await _codexCandidates(files, '$home/.codex/sessions');
    for (final candidate in candidates) {
      final head = await files.read(candidate.$1, offset: 0, length: 16384);
      final match = _cwdField.firstMatch(
        utf8.decode(head, allowMalformed: true),
      );
      if (match == null) continue;
      if (match.group(1)!.replaceAll(r'\/', '/') == cwd) {
        found = (
          path: candidate.$1,
          modified: candidate.$2.modified,
          format: HerdrTranscriptFormat.codex,
        );
        break;
      }
    }
  }
  if (found == null) return null;
  if (working && now.difference(found.modified) > herdrSessionStale) {
    return null;
  }
  // An agent that has been waiting or idle for a while writes nothing: a
  // file that changed after it went quiet belongs to someone else (a session
  // of the same tool started outside Herdr in this folder).
  if (!working &&
      quietFor != null &&
      quietFor > herdrQuietCheck &&
      found.modified.isAfter(now.subtract(quietFor).add(herdrQuietMargin))) {
    return null;
  }
  return HerdrSessionRef(found.path, found.format);
}

/// The newest Codex rollout files as (path, entry), newest first.
Future<List<(String, HerdrRemoteFile)>> _codexCandidates(
  HerdrSessionFiles files,
  String root,
) async {
  Future<List<String>> subdirs(String dir) async => [
    for (final f in await files.list(dir))
      if (f.isDir && _datePart.hasMatch(f.name)) f.name,
  ]..sort((a, b) => int.parse(b).compareTo(int.parse(a)));

  final days = <String>[];
  for (final year in await subdirs(root)) {
    for (final month in await subdirs('$root/$year')) {
      for (final day in await subdirs('$root/$year/$month')) {
        days.add('$root/$year/$month/$day');
        if (days.length >= herdrCodexDays) break;
      }
      if (days.length >= herdrCodexDays) break;
    }
    if (days.length >= herdrCodexDays) break;
  }
  final found = <(String, HerdrRemoteFile)>[];
  for (final day in days) {
    for (final f in await files.list(day)) {
      if (!f.isDir && _codexFile.hasMatch(f.name)) {
        found.add(('$day/${f.name}', f));
      }
    }
  }
  found.sort((a, b) => b.$2.modified.compareTo(a.$2.modified));
  return found.take(herdrCodexFiles).toList();
}
