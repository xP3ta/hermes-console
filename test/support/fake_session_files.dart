// An in-memory stand-in for the session files a code agent keeps on the
// server, behind the same read-only interface the app uses over SFTP.
import 'dart:convert';
import 'dart:typed_data';

import 'package:hermes_android/core/services/herdr_session_files.dart';

class FakeSessionFiles implements HerdrSessionFiles {
  FakeSessionFiles({this.homePath = '/home/demo'});

  final String homePath;

  /// Path -> content.
  final Map<String, String> files = {};

  /// Path -> modification time (the epoch when missing).
  final Map<String, DateTime> times = {};

  int reads = 0;
  int lists = 0;

  void put(String path, String content, {DateTime? modified}) {
    files[path] = content;
    if (modified != null) times[path] = modified;
  }

  void append(String path, String more, {DateTime? modified}) {
    files[path] = (files[path] ?? '') + more;
    if (modified != null) times[path] = modified;
  }

  @override
  Future<String> home() async => homePath;

  @override
  Future<List<HerdrRemoteFile>> list(String dir) async {
    lists++;
    final prefix = dir.endsWith('/') ? dir : '$dir/';
    final seen = <String>{};
    final out = <HerdrRemoteFile>[];
    for (final path in files.keys) {
      if (!path.startsWith(prefix)) continue;
      final rest = path.substring(prefix.length);
      final slash = rest.indexOf('/');
      if (slash < 0) {
        out.add(
          HerdrRemoteFile(
            name: rest,
            isDir: false,
            size: utf8.encode(files[path]!).length,
            modified: times[path] ?? DateTime.utc(2026),
          ),
        );
      } else if (seen.add(rest.substring(0, slash))) {
        out.add(
          HerdrRemoteFile(
            name: rest.substring(0, slash),
            isDir: true,
            size: 0,
            modified: DateTime.utc(2026),
          ),
        );
      }
    }
    return out;
  }

  @override
  Future<HerdrRemoteFile?> stat(String path) async {
    final content = files[path];
    if (content == null) return null;
    return HerdrRemoteFile(
      name: path.split('/').last,
      isDir: false,
      size: utf8.encode(content).length,
      modified: times[path] ?? DateTime.utc(2026),
    );
  }

  @override
  Future<Uint8List> read(
    String path, {
    required int offset,
    required int length,
  }) async {
    reads++;
    final bytes = utf8.encode(files[path] ?? '');
    final end = (offset + length).clamp(0, bytes.length);
    final start = offset.clamp(0, bytes.length);
    return Uint8List.fromList(bytes.sublist(start, end));
  }
}
