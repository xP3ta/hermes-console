import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/new_session_factory.dart';

void main() {
  test('generateSessionId keeps the mob-<ms>-<uuid v4> format', () {
    final ids = {for (var i = 0; i < 20; i++) generateSessionId()};
    expect(ids, hasLength(20));
    for (final id in ids) {
      expect(id, matches(RegExp(r'^mob-\d+-[0-9a-f-]{36}$')));
      expect(
        id.substring(id.length - 36),
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ),
        ),
      );
    }
  });

  test('the factory uses the same ids', () {
    final session = NewSessionFactory().create(title: 'x');
    expect(session.id, matches(RegExp(r'^mob-\d+-[0-9a-f-]{36}$')));
  });

  // Production never builds an ApiClient without its Dashboard: the reads Desktop
  // makes there must not fall to the Gateway port. Every construction in lib is
  // `forConnection` or passes `profileDashboard` (hermes_drawer, home dashboard).
  test('every ApiClient built in lib carries its Dashboard', () {
    final builds = <String>[];
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (!lines[i].contains('ApiClient(')) continue;
        if (lines[i].contains('ApiClient({') ||
            lines[i].contains('Future<') ||
            lines[i].trimLeft().startsWith('//')) {
          continue;
        }
        final window = lines.skip(i).take(8).join('\n');
        builds.add(
          '${f.path}:${i + 1} ${window.contains('profileDashboard:')}',
        );
      }
    }
    expect(builds, isNotEmpty);
    expect(
      builds.where((b) => !b.endsWith('true')),
      isEmpty,
      reason: '$builds',
    );
    expect(builds, hasLength(3), reason: '$builds');
  });
}
