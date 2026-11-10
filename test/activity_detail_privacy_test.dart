import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/activity_snapshot.dart';

void main() {
  test('MEDIO-2: queries, q and patterns never become visible details', () {
    for (final key in ['query', 'q', 'pattern']) {
      for (final value in [
        'workers_dev',
        'Bearer private-value',
        'https://h/p?sig=abc&token=private-value',
        'authorization=private-value',
      ]) {
        expect(activityToolDetail('web_search', {key: value}), isNull);
        expect(activityToolDetail('search_files', {key: value}), isNull);
      }
    }
  });

  test(
    'MEDIO-2: signed URLs in file/target/path fields expose only the host',
    () {
      for (final key in [
        'path',
        'file_path',
        'filepath',
        'file',
        'filename',
        'target',
      ]) {
        expect(
          activityToolDetail('read_file', {
            key: 'https://user:private-value@h/p?sig=abc&token=xyz',
          }),
          'h',
        );
        expect(
          activityToolDetail('read_file', {
            key: '/private/customer/config.yaml',
          }),
          'config.yaml',
        );
        expect(
          activityToolDetail('read_file', {
            key: r'C:\private\customer\config.yaml',
          }),
          'config.yaml',
        );
        expect(activityToolDetail('read_file', {key: 'p?sig=abc'}), isNull);
        expect(activityToolDetail('read_file', {key: 'p&sig=abc'}), isNull);
      }
    },
  );

  test(
    'MEDIO-2: commands reveal only the executable, never subcommands/flags',
    () {
      for (final key in ['command', 'cmd', 'script']) {
        expect(
          activityToolDetail('terminal', {
            key: '/usr/bin/git status --short --token=private-value',
          }),
          'git',
        );
        expect(
          activityToolDetail('terminal', {
            key: 'flutter test --token=private-value',
          }),
          'flutter',
        );
        expect(
          activityToolDetail('terminal', {
            key: 'node /private/private-value.js --token=abc',
          }),
          'node',
        );
        expect(
          activityToolDetail('terminal', {key: 'API_KEY=private-value deploy'}),
          isNull,
        );
      }
    },
  );

  test(
    'MEDIO-2: trace and direct snapshot details are sanitized on the client',
    () {
      final cases = [
        ('terminal', '/usr/bin/git status --token=private-value', 'git'),
        ('mcp__terminal', 'flutter test --token=private-value', 'flutter'),
        ('read_file', '/private/customer/deploy.sh', 'deploy.sh'),
        ('read_file', '/private/README.md --force', null),
        ('read_file', 'https://h/p?sig=abc', 'h'),
        (
          'web_extract',
          'https://u:private-value@host.test/p?sig=abc',
          'host.test',
        ),
        ('web_extract', 'h', 'h'),
        ('web_search', 'workers_dev', null),
        ('search_files', 'private query --token=abc', null),
        ('search_files', '/private/query/pattern', null),
      ];
      for (final (tool, raw, expected) in cases) {
        final step = ActivityStep.fromTrace({
          'id': 'wire',
          'kind': 'tool',
          'label': tool,
          'status': 'done',
          'detail': raw,
        })!;
        final direct = ActivityStep(
          id: 'direct',
          kind: ActivityStepKind.tool,
          label: tool,
          status: ActivityStepStatus.running,
          detail: raw,
        );
        final snapshot = ActivitySnapshot(current: direct, done: [step]);
        expect(snapshot.current!.detail, expected, reason: tool);
        expect(snapshot.done.single.detail, expected, reason: tool);
      }
    },
  );

  test(
    'MEDIO-2: non-string snapshot details are not coerced into filenames',
    () {
      for (final detail in [
        123,
        ['private-value'],
        {'path': '/private/customer'},
      ]) {
        expect(
          ActivityStep.fromTrace({
            'kind': 'tool',
            'label': 'read_file',
            'detail': detail,
          })!.detail,
          isNull,
        );
      }
    },
  );

  test(
    'category-qualified catalogue skills survive live and stored projection',
    () {
      for (final name in ['hyperframes', 'creative/hyperframes']) {
        final detail = '$name → api.md';
        expect(
          activityToolDetail('skill_view', {
            'name': name,
            'file_path': 'references/api.md',
          }),
          detail,
        );
        expect(
          ActivityStep.fromTrace({
            'kind': 'tool',
            'label': 'skill_view',
            'detail': detail,
          })!.detail,
          detail,
        );
      }
      for (final name in [
        '/private/hyperframes',
        '../hyperframes',
        'creative//hyperframes',
        'creative/my-api-token',
        'creative/hyperframes --flag',
      ]) {
        expect(activityToolDetail('skill_view', {'name': name}), isNull);
        expect(sanitizeActivityDetail('skill_view', '$name → api.md'), isNull);
      }
    },
  );

  test('skill details reject relative paths deeper than category/name', () {
    for (final name in ['a/b/c', 'home/user/x', 'home/xpeta/proyecto']) {
      expect(activityToolDetail('skill_view', {'name': name}), isNull);
      for (final detail in [name, '$name → api.md']) {
        expect(sanitizeActivityDetail('skill_view', detail), isNull);
        for (final kind in ['tool', 'skill']) {
          expect(
            ActivityStep.fromTrace({
              'kind': kind,
              'label': kind == 'skill' ? 'hyperframes' : 'skill_view',
              'detail': detail,
            })!.detail,
            isNull,
          );
        }
      }
    }
  });

  test('MEDIO-2: control characters and secret filenames are rejected', () {
    for (final value in [
      'token.txt',
      'api_key.txt',
      'config\u202e.yaml',
      'config\n.yaml',
    ]) {
      expect(activityToolDetail('read_file', {'path': value}), isNull);
      expect(
        ActivityStep.fromTrace({
          'kind': 'tool',
          'label': 'read_file',
          'detail': value,
        })!.detail,
        isNull,
      );
    }
  });
}
