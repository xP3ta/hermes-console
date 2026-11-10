import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/activity_snapshot.dart';

// «Completo» (the approved v4 video): the live row names the whole command,
// «Ejecutando uname -a». It never shows a secret: whatever names or looks
// like one shows the executable alone (or nothing).

void main() {
  group('maskedCommandLine shows what the user can read', () {
    test('plain commands in full', () {
      expect(maskedCommandLine('date'), 'date');
      expect(maskedCommandLine('uname -a'), 'uname -a');
      expect(maskedCommandLine('ls /tmp'), 'ls /tmp');
      expect(
        maskedCommandLine('for i in 1 2 3; do sleep 5; done'),
        'for i in 1 2 3; do sleep 5; done',
      );
    });

    test('the executable by name, never by absolute path', () {
      expect(maskedCommandLine('/usr/bin/git status'), 'git status');
      expect(maskedCommandLine(r'C:\tools\node.exe app.js'), 'node.exe app.js');
    });

    test('first line only, capped on one line', () {
      expect(maskedCommandLine('echo hi\nrm -rf /'), 'echo hi');
      final long = maskedCommandLine('echo ${'word ' * 40}')!;
      expect(long.length, lessThanOrEqualTo(64));
      expect(long, endsWith('…'));
    });

    test('URL queries and NAME=value values are masked', () {
      expect(
        maskedCommandLine('curl https://x.io/a?b=1&c=2'),
        'curl https://x.io/a?…',
      );
      expect(maskedCommandLine('make DEBUG=1 build'), 'make DEBUG=••• build');
    });
  });

  group('maskedCommandLine never shows a secret', () {
    const secretive = [
      'API_KEY=abc123 deploy',
      'curl -H "Authorization: Bearer sk-live-123" https://x.io?token=abc',
      'git push --token=ghp_privatevalue123',
      'mysql --password hunter2 -u root',
      'curl https://user:pass@host/x',
      'psql postgres://u:p@h/db',
      'echo 0123456789abcdef0123456789abcdef01234567',
      'aws s3 ls AKIAABCDEFGH1234',
      'curl -H "x-key: eyJhbGciOiJIUzI1NiJ9.payload.sig" https://x.io',
      'export SECRET=1',
      'login --credential a',
    ];
    for (final command in secretive) {
      test('hides: $command', () {
        expect(maskedCommandLine(command), isNull);
      });
    }

    test('unreadable input shows nothing', () {
      expect(maskedCommandLine(''), isNull);
      expect(maskedCommandLine('   '), isNull);
      expect(maskedCommandLine('echo \u202e hi'), isNull);
      expect(maskedCommandLine('echo ${'a ' * 3000}'), isNull);
      expect(maskedCommandLine('-rf /'), isNull);
      expect(maskedCommandLine('FOO=bar make'), isNull);
    });

    test('the tool detail falls back to the executable, as before', () {
      expect(activityToolDetail('terminal', {'command': 'uname -a'}), 'uname -a');
      expect(
        activityToolDetail('terminal', {
          'command':
              'curl -H "Authorization: Bearer sk-live-123" https://x.io?token=abc',
        }),
        'curl',
      );
      expect(
        activityToolDetail('terminal', {'command': 'API_KEY=abc123 deploy'}),
        isNull,
      );
    });
  });

  group('ActivityStep.commandLine', () {
    ActivityStep step(String label, String? detail) => ActivityStep(
      id: label,
      kind: ActivityStepKind.tool,
      label: label,
      status: ActivityStepStatus.running,
      detail: detail,
    );

    test('a terminal step reads its command; the detail stays the executable',
        () {
      final terminal = step('terminal', 'uname -a');
      expect(terminal.commandLine, 'uname -a');
      expect(terminal.detail, 'uname');
    });

    test('other tools and unsafe commands have none', () {
      expect(step('read_file', 'main.dart').commandLine, isNull);
      expect(step('terminal', 'API_KEY=1 deploy').commandLine, isNull);
      expect(step('terminal', null).commandLine, isNull);
      expect(
        const ActivityStep(
          id: 's',
          kind: ActivityStepKind.skill,
          label: 'skill',
          status: ActivityStepStatus.running,
          detail: 'ls /tmp',
        ).commandLine,
        isNull,
      );
    });
  });

  group('maskedGoalLine describes a delegated task', () {
    test('the first line, readable', () {
      expect(
        maskedGoalLine('Contar .md en ~/.hermes/skills'),
        'Contar .md en ~/.hermes/skills',
      );
      expect(maskedGoalLine('Revisar el diff\nluego resumir'), 'Revisar el diff');
    });

    test('masks URL queries and caps the line', () {
      expect(
        maskedGoalLine('Leer https://x.io/doc?id=7'),
        'Leer https://x.io/doc?…',
      );
      final long = maskedGoalLine('Revisar ${'archivo '.padRight(200, 'a ')}')!;
      expect(long.length, lessThanOrEqualTo(72));
    });

    test('hides anything secret-looking or unreadable', () {
      expect(maskedGoalLine('Usar el token abc para entrar'), isNull);
      expect(maskedGoalLine('Con la clave sk-live-12345678'), isNull);
      expect(maskedGoalLine('Entrar con https://u:p@h/x'), isNull);
      expect(maskedGoalLine(null), isNull);
      expect(maskedGoalLine('   '), isNull);
    });
  });
}
