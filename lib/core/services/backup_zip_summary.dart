import 'dart:io';

import 'package:archive/archive_io.dart';

/// Top-level parts of a profile home that a restore overwrites.
enum BackupItem {
  config,
  env,
  auth,
  sessions,
  memories,
  skills,
  cron,
  profiles,
}

enum BackupZipProblem { notAZip, empty, tooLarge, unsafePath }

class BackupZipRefused implements Exception {
  const BackupZipRefused(this.reason);

  final BackupZipProblem reason;

  @override
  String toString() => 'BackupZipRefused(${reason.name})';
}

/// What restoring a backup zip will touch, read from the zip's central
/// directory only. Nothing is extracted and nothing leaves the phone.
class BackupZipSummary {
  const BackupZipSummary({
    required this.profile,
    required this.fileCount,
    required this.totalBytes,
    required this.replaces,
    required this.profileNames,
    required this.otherFiles,
    required this.keptRuntimeFiles,
  });

  static const int defaultMaxBytes = 2 * 1024 * 1024 * 1024;

  /// Runtime files `hermes import` never writes.
  static const Set<String> runtimeFiles = {
    'gateway_state.json',
    'gateway.pid',
    'cron.pid',
    'gateway.lock',
    'processes.json',
  };

  final String profile;
  final int fileCount;
  final int totalBytes;
  final List<BackupItem> replaces;
  final List<String> profileNames;
  final int otherFiles;
  final List<String> keptRuntimeFiles;

  static Future<BackupZipSummary> inspect(
    File file, {
    required String profile,
    int maxBytes = defaultMaxBytes,
  }) async {
    if (await file.length() > maxBytes) {
      throw const BackupZipRefused(BackupZipProblem.tooLarge);
    }
    final input = InputFileStream(file.path);
    final Archive archive;
    try {
      archive = ZipDecoder().decodeStream(input);
    } catch (_) {
      throw const BackupZipRefused(BackupZipProblem.notAZip);
    } finally {
      await input.close();
    }
    final entries = [
      for (final entry in archive.files)
        if (entry.isFile) entry,
    ];
    if (archive.files.isEmpty && entries.isEmpty) {
      // decodeStream returns an empty archive for bytes with no directory.
      final length = await file.length();
      throw BackupZipRefused(
        length < 22 || !await _hasZipSignature(file)
            ? BackupZipProblem.notAZip
            : BackupZipProblem.empty,
      );
    }
    if (entries.isEmpty) throw const BackupZipRefused(BackupZipProblem.empty);

    final replaces = <BackupItem>{};
    final profileNames = <String>{};
    final kept = <String>[];
    var other = 0;
    var total = 0;
    for (final entry in entries) {
      final path = _normalize(entry.name);
      if (path == null) {
        throw const BackupZipRefused(BackupZipProblem.unsafePath);
      }
      total += entry.size;
      final segments = path.split('/');
      final first = segments.first;
      if (segments.length == 1 && runtimeFiles.contains(first)) {
        kept.add(first);
        continue;
      }
      switch (first) {
        case 'config.yaml' when segments.length == 1:
          replaces.add(BackupItem.config);
        case '.env' when segments.length == 1:
          replaces.add(BackupItem.env);
        case 'auth.json' when segments.length == 1:
          replaces.add(BackupItem.auth);
        case 'state.db' when segments.length == 1:
          replaces.add(BackupItem.sessions);
        case 'memories':
          replaces.add(BackupItem.memories);
        case 'skills':
          replaces.add(BackupItem.skills);
        case 'cron':
          replaces.add(BackupItem.cron);
        case 'profiles':
          replaces.add(BackupItem.profiles);
          if (segments.length > 2) profileNames.add(segments[1]);
        default:
          other += 1;
      }
    }
    return BackupZipSummary(
      profile: profile,
      fileCount: entries.length,
      totalBytes: total,
      replaces: [
        for (final item in BackupItem.values)
          if (replaces.contains(item)) item,
      ],
      profileNames: profileNames.toList()..sort(),
      otherFiles: other,
      keptRuntimeFiles: kept..sort(),
    );
  }

  static Future<bool> _hasZipSignature(File file) async {
    final raf = await file.open();
    try {
      final head = await raf.read(4);
      return head.length == 4 &&
          head[0] == 0x50 &&
          head[1] == 0x4b &&
          (head[2] == 0x03 || head[2] == 0x05);
    } finally {
      await raf.close();
    }
  }

  /// Entry path without a leading `./`; null when it could leave the profile.
  static String? _normalize(String raw) {
    var path = raw.replaceAll('\\', '/');
    while (path.startsWith('./')) {
      path = path.substring(2);
    }
    if (path.isEmpty || path.startsWith('/')) return null;
    if (RegExp(r'^[A-Za-z]:').hasMatch(path)) return null;
    for (final segment in path.split('/')) {
      if (segment == '..') return null;
    }
    return path;
  }
}
