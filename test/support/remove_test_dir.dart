import 'dart:io';

/// Removes a test's temporary folder.
///
/// A file still being written when the test ends (a face rendered off the
/// event loop) can land in the folder while it is being removed, and the
/// removal then fails with «Directory not empty». Trying again removes it.
Future<void> removeTestDir(Directory dir) async {
  for (var attempt = 0; ; attempt++) {
    try {
      if (dir.existsSync()) await dir.delete(recursive: true);
      return;
    } on FileSystemException {
      if (attempt == 80) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }
}
