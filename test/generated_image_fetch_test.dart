import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/generated_image_fetch.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'official current producer timeout preserves failure without fallback',
    () async {
      final calls = <String>[];
      await expectLater(
        GeneratedImageFetch.fetch(
          '/home/demo/.hermes/cache/generated/images/same.png',
          apiGet: (e) async {
            calls.add(e);
            if (e == 'profiles') {
              return {
                'profiles': [
                  {'name': 'default', 'path': '/home/demo/.hermes'},
                ],
              };
            }
            if (e.startsWith('config?')) {
              return {
                'terminal': {'backend': 'local'},
              };
            }
            throw TimeoutException('fixture');
          },
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(calls.where((e) => e.startsWith('fs/')), hasLength(1));
      expect(calls.any((e) => e.startsWith('media?')), isFalse);
    },
  );
  test(
    'image security revoked official response is rejected before parsing',
    () async {
      var current = true;
      await expectLater(
        GeneratedImageFetch.readPath(
          '/home/demo/.hermes/cache/images/same.png',
          isCurrent: () => current,
          apiGet: (_) async {
            current = false;
            return {'dataUrl': 'not an image'};
          },
        ),
        throwsA(isA<StateError>()),
      );
    },
  );
  for (final source in [
    'id_ed25519.png',
    '.env.png',
    '/home/demo/.hermes/.env',
    '/home/demo/.hermes/cache/images/sensitive.invalid.png/..',
    '/home/demo/.hermes/cache/images/id_ed25519.png',
    '/home/demo/.ssh/id_ed25519.png',
    'file:///home/demo/.hermes/cache/images/secret.png',
    '/home/demo/.hermes/cache/images/%252e%252e/secret.png',
    '/home/demo/.hermes/cache/images/%2eenv.png',
    '/home/demo/.hermes/cache/images/%ZZ.png',
  ]) {
    test('image security rejects source before HTTP: $source', () async {
      final requests = <String>[];
      await expectLater(
        GeneratedImageFetch.fetch(
          source,
          apiGet: (e) async {
            requests.add(e);
            if (e == 'profiles') {
              return {
                'profiles': [
                  {'name': 'default', 'path': '/home/demo/.hermes'},
                ],
              };
            }
            if (e.startsWith('config?')) {
              return {
                'terminal': {'backend': 'local'},
              };
            }
            return {
              'dataUrl':
                  'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
            };
          },
        ),
        throwsA(anything),
      );
      expect(requests, isEmpty);
    });
  }
  test(
    'official current producer exact full path is resolved without rebasing',
    () async {
      const root = '/home/demo/.hermes/profiles/work_bot';
      const source = '$root/cache/generated/images/same.png';
      final path = await GeneratedImageFetch.resolvePath(
        source,
        profile: 'work_bot',
        apiGet: (endpoint) async {
          if (endpoint == 'profiles') {
            return {
              'profiles': [
                {'name': 'work_bot', 'path': root},
              ],
            };
          }
          return {
            'terminal': {'backend': 'local'},
          };
        },
      );
      expect(path, source);
    },
  );
  for (final source in [
    '/home/demo/.hermes/cache/generated/images/same.png',
    '/home/demo/.hermes/profiles/work_bot/cache/generated/images/../same.png',
    '/home/demo/.hermes/profiles/work_bot/cache//images/same.png',
    '/home/demo/.hermes/profiles/work_bot/cache/generated/images/same.png/extra',
    '/home/demo/.hermes/profiles/work_bot/cache/generated/images/same.png\n',
  ]) {
    test(
      'official current producer rejects foreign or noncanonical full source ${jsonEncode(source)}',
      () async {
        final endpoints = <String>[];
        await expectLater(
          GeneratedImageFetch.fetch(
            source,
            profile: 'work_bot',
            apiGet: (endpoint) async {
              endpoints.add(endpoint);
              if (endpoint == 'profiles') {
                return {
                  'profiles': [
                    {
                      'name': 'work_bot',
                      'path': '/home/demo/.hermes/profiles/work_bot',
                    },
                  ],
                };
              }
              if (endpoint.startsWith('config?')) {
                return {
                  'terminal': {'backend': 'local'},
                };
              }
              fail('invalid source must never read bytes');
            },
          ),
          throwsA(anyOf(isA<ArgumentError>(), isA<UnsupportedError>())),
        );
        expect(
          endpoints.any((e) => e.startsWith('fs/') || e.startsWith('media?')),
          isFalse,
        );
      },
    );
  }
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNQSFgAAAHEASFiX4r9AAAAAElFTkSuQmCC',
  );
  final pngUrl = 'data:image/png;base64,${base64Encode(png)}';
  Map<String, dynamic> profiles(String owner, String root) => {
    'profiles': [
      {'name': owner, 'path': root},
    ],
  };
  const local = {
    'terminal': {'backend': 'local'},
  };

  test(
    'official current producer legacy tilde alias uses authenticated owner root',
    () async {
      const root = '/home/demo/.hermes/profiles/work_bot';
      expect(
        await GeneratedImageFetch.resolvePath(
          '~/.hermes/cache/images/same.png',
          profile: 'work_bot',
          apiGet: (endpoint) async {
            if (endpoint == 'profiles') return profiles('work_bot', root);
            return local;
          },
        ),
        '$root/cache/images/same.png',
      );
    },
  );
  for (final owner in ['default', 'work_bot']) {
    for (final layout in ['images', 'generated/images']) {
      test(
        'official current producer $owner $layout preserves full path through read',
        () async {
          final root = owner == 'default'
              ? '/home/demo/.hermes'
              : '/home/demo/.hermes/profiles/work_bot';
          final source = '$root/cache/$layout/same.png';
          final endpoints = <String>[];
          expect(
            await GeneratedImageFetch.fetch(
              source,
              profile: owner,
              apiGet: (endpoint) async {
                endpoints.add(endpoint);
                if (endpoint == 'profiles') return profiles(owner, root);
                if (endpoint.startsWith('config?')) return local;
                expect(Uri.parse(endpoint).queryParameters['path'], source);
                expect(Uri.parse(endpoint).queryParameters['profile'], owner);
                return {'dataUrl': pngUrl};
              },
            ),
            png,
          );
          expect(endpoints, hasLength(3));
          expect(endpoints.any((e) => e.startsWith('media?')), isFalse);
        },
      );
    }
  }
  for (final status in [401, 403, 404, 413, 415, 500]) {
    test(
      'official current producer full path preserves error $status without global fallback',
      () async {
        const source =
            '/home/demo/.hermes/profiles/work_bot/cache/generated/images/same.png';
        final endpoints = <String>[];
        await expectLater(
          GeneratedImageFetch.fetch(
            source,
            profile: 'work_bot',
            apiGet: (endpoint) async {
              endpoints.add(endpoint);
              if (endpoint == 'profiles') {
                return profiles(
                  'work_bot',
                  '/home/demo/.hermes/profiles/work_bot',
                );
              }
              if (endpoint.startsWith('config?')) return local;
              if (endpoint.startsWith('media?')) return {'data_url': pngUrl};
              throw DashboardHttpException(status);
            },
          ),
          throwsA(
            isA<DashboardHttpException>().having(
              (e) => e.statusCode,
              'status',
              status,
            ),
          ),
        );
        expect(endpoints.where((e) => e.startsWith('fs/')), hasLength(1));
        expect(endpoints.any((e) => e.startsWith('media?')), isFalse);
      },
    );
  }
  for (final owner in ['default', 'work_bot']) {
    test('$owner resolves its official root before reading bytes', () async {
      final calls = <String>[];
      final root = owner == 'default' ? '/srv/agent/base' : '/srv/agent/work';
      final bytes = await GeneratedImageFetch.fetch(
        'same.png',
        profile: owner,
        apiGet: (endpoint) async {
          calls.add(endpoint);
          if (endpoint == 'profiles') {
            return profiles(owner, root);
          }
          if (endpoint.startsWith('config?')) return local;
          return {'data_url': pngUrl, 'dataUrl': pngUrl};
        },
      );
      expect(bytes, png);
      expect(calls, [
        'profiles',
        'config?profile=$owner',
        'fs/read-data-url?path=${Uri.encodeQueryComponent('$root/cache/images/same.png')}&profile=$owner',
      ]);
    });
  }
  for (final status in [401, 403, 404, 500]) {
    test('scoped official failure $status never reads global media', () async {
      final calls = <String>[];
      await expectLater(
        GeneratedImageFetch.fetch(
          'same.png',
          profile: 'work_bot',
          apiGet: (endpoint) async {
            calls.add(endpoint);
            if (endpoint == 'profiles') {
              return profiles('work_bot', '/srv/agent/work');
            }
            if (endpoint.startsWith('config?')) return local;
            if (endpoint.startsWith('media?')) return {'data_url': pngUrl};
            throw DashboardHttpException(status);
          },
        ),
        throwsA(
          isA<DashboardHttpException>().having(
            (e) => e.statusCode,
            'status',
            status,
          ),
        ),
      );
      expect(calls, hasLength(3));
      expect(calls.where((e) => e.startsWith('fs/')), hasLength(1));
      expect(calls.any((e) => e.startsWith('media?')), isFalse);
    });
    test(
      'profile metadata error $status propagates without a second request',
      () async {
        var calls = 0;
        await expectLater(
          GeneratedImageFetch.fetch(
            'gone.png',
            apiGet: (_) async {
              calls++;
              throw DashboardHttpException(status);
            },
          ),
          throwsA(
            isA<DashboardHttpException>().having(
              (e) => e.statusCode,
              'status',
              status,
            ),
          ),
        );
        expect(calls, 1);
      },
    );
  }
  test('unknown profile cannot return a process-global image', () async {
    final calls = <String>[];
    await expectLater(
      GeneratedImageFetch.fetch(
        'same.png',
        profile: 'missing',
        apiGet: (endpoint) async {
          calls.add(endpoint);
          return {'profiles': [], 'data_url': pngUrl};
        },
      ),
      throwsA(isA<UnsupportedError>()),
    );
    expect(calls, ['profiles']);
  });
  for (final root in [
    '~/.hermes',
    '/',
    '/srv/../other',
    '/srv//other',
    '/srv/./other',
    '/srv/other\n',
    '/srv/other/',
  ]) {
    test('unsafe profile root rejected: ${jsonEncode(root)}', () async {
      var calls = 0;
      await expectLater(
        GeneratedImageFetch.fetch(
          'same.png',
          profile: 'work_bot',
          apiGet: (_) async {
            calls++;
            return profiles('work_bot', root);
          },
        ),
        throwsA(isA<UnsupportedError>()),
      );
      expect(calls, 1);
    });
  }
  test('ambiguous profile metadata is refused', () async {
    await expectLater(
      GeneratedImageFetch.fetch(
        'same.png',
        apiGet: (_) async => {
          'profiles': [
            {'name': 'default', 'path': '/srv/a'},
            {'name': 'default', 'path': '/srv/b'},
          ],
        },
      ),
      throwsA(isA<UnsupportedError>()),
    );
  });
  test('SSH workspace cannot read a host profile path', () async {
    final calls = <String>[];
    await expectLater(
      GeneratedImageFetch.fetch(
        'same.png',
        profile: 'work_bot',
        apiGet: (endpoint) async {
          calls.add(endpoint);
          if (endpoint == 'profiles') {
            return profiles('work_bot', '/srv/agent/work');
          }
          if (endpoint.startsWith('config?')) {
            return {
              'terminal': {'backend': 'ssh'},
            };
          }
          return {'dataUrl': pngUrl};
        },
      ),
      throwsA(isA<UnsupportedError>()),
    );
    expect(calls.any((e) => e.startsWith('fs/')), isFalse);
  });
  test('hostile names never reach the server', () async {
    for (final name in const [
      '../secret.png',
      'a/b.png',
      '.hidden.png',
      'x.svg',
      'x.png?y=1',
      '',
      '..png',
    ]) {
      var calls = 0;
      await expectLater(
        GeneratedImageFetch.fetch(
          name,
          apiGet: (_) async {
            calls++;
            return {'data_url': pngUrl};
          },
        ),
        throwsArgumentError,
        reason: name,
      );
      expect(calls, 0, reason: name);
    }
  });
  test('non-image, empty and oversized payloads are refused', () {
    expect(
      () => GeneratedImageFetch.decodeImageDataUrl(
        'data:text/html;base64,${base64Encode(png)}',
        maxBytes: 100,
      ),
      throwsFormatException,
    );
    expect(
      () => GeneratedImageFetch.decodeImageDataUrl(
        'data:image/png;base64,',
        maxBytes: 100,
      ),
      throwsFormatException,
    );
    expect(
      () => GeneratedImageFetch.decodeImageDataUrl(pngUrl, maxBytes: 3),
      throwsFormatException,
    );
    expect(
      () => GeneratedImageFetch.decodeImageDataUrl(null, maxBytes: 100),
      throwsFormatException,
    );
  });
}
