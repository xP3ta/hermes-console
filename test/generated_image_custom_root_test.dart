// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Hermes Console contributors
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/generated_image_fetch.dart';
import 'package:hermes_android/core/services/generated_image_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final root in [
    '/home/demo/.hermes',
    '/srv/agent/work',
    '/var/lib/agent-prod',
    '/data/hermes',
  ]) {
    for (final owner in ['default', 'work_bot']) {
      test('custom producer preserves exact $owner root $root', () async {
        final source = '$root/cache/generated/images/same.png';
        final refs = GeneratedImageService.imageReferencesFromResult({
          'success': true,
          'host_image': source,
          'image': source,
        });
        expect(refs, hasLength(1));
        expect(refs.single.source, source);
        final calls = <String>[];
        final target = await GeneratedImageFetch.resolvePath(
          source,
          profile: owner,
          apiGet: (endpoint) async {
            calls.add(endpoint);
            if (endpoint == 'profiles') {
              return {
                'profiles': [
                  {'name': owner, 'path': root},
                ],
              };
            }
            return {
              'terminal': {'backend': 'local'},
            };
          },
        );
        expect(target, source);
        expect(calls, ['profiles', 'config?profile=$owner']);
        final segments = GeneratedImageService.segments('Output `$source`');
        expect(segments.whereType<ImageSegment>().single.source, source);
      });
    }
  }
  for (final source in [
    '/srv/agent/work/cache/generated/images/id_ed25519.png',
    '/srv/agent/work/cache/generated/images/.env.png',
    '/srv/agent/work/.ssh/cache/generated/images/same.png',
    '/srv/agent/work/cache/generated/images/%2e%2e/same.png',
    '/srv/agent/work/cache/generated/images/%ZZ.png',
    '/srv/agent/work/cache/generated/images/../same.png',
    '/srv/agent/work/cache//generated/images/same.png',
    'file:///srv/agent/work/cache/generated/images/same.png',
  ]) {
    test('custom sensitive/alias source denied before HTTP $source', () async {
      final calls = <String>[];
      expect(
        GeneratedImageService.imageReferencesFromResult({'host_image': source}),
        isEmpty,
      );
      await expectLater(
        GeneratedImageFetch.fetch(
          source,
          apiGet: (e) async {
            calls.add(e);
            return {};
          },
        ),
        throwsA(anything),
      );
      expect(calls, isEmpty);
    });
  }
  test(
    'custom foreign source remains display identity, never owner read',
    () async {
      const source = '/srv/other/cache/generated/images/same.png';
      final calls = <String>[];
      await expectLater(
        GeneratedImageFetch.fetch(
          source,
          profile: 'work_bot',
          apiGet: (e) async {
            calls.add(e);
            if (e == 'profiles') {
              return {
                'profiles': [
                  {'name': 'work_bot', 'path': '/srv/agent/work'},
                ],
              };
            }
            if (e.startsWith('config?')) {
              return {
                'terminal': {'backend': 'local'},
              };
            }
            fail('foreign source cannot read bytes or use a global fallback');
          },
        ),
        throwsArgumentError,
      );
      expect(calls, ['profiles', 'config?profile=work_bot']);
    },
  );
}
