// Masking and validation helpers of the skills / plugins / MCP screens.
// Every secret below is an obviously fake value on example hosts.
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/capabilities/capability_models.dart';
import 'package:hermes_android/core/capabilities/spp_safety.dart';

void main() {
  group('sppSafeEndpoint', () {
    test('drops user info, query values and fragment', () {
      expect(
        sppSafeEndpoint(
          'https://user:hunter2@mcp.example.com:8443/v1?token=abc#x',
        ),
        'https://mcp.example.com:8443/v1?…',
      );
    });

    test('keeps a plain endpoint as it was', () {
      expect(
        sppSafeEndpoint('https://mcp.example.com/docs'),
        'https://mcp.example.com/docs',
      );
    });

    test('hides a path segment shaped like a credential', () {
      const key = 'a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8';
      expect(
        sppSafeEndpoint('https://mcp.example.com/hook/$key/sse'),
        'https://mcp.example.com/hook/$sppMask/sse',
      );
    });

    test('text that is not a URL passes through', () {
      expect(sppSafeEndpoint('npx'), 'npx');
    });
  });

  group('sppSafeTarget (a command line or a URL)', () {
    test('hides the value after a credential flag', () {
      expect(
        sppSafeTarget('node server.js --api-key not-a-real-key --port 80'),
        'node server.js --api-key $sppMask --port 80',
      );
    });

    test('hides name=value pairs with a credential name', () {
      expect(
        sppSafeTarget('uvx tool --token=fake-value --verbose'),
        'uvx tool --token=$sppMask --verbose',
      );
      expect(sppSafeTarget('run PASSWORD=fake'), 'run PASSWORD=$sppMask');
    });

    test('keeps ordinary values', () {
      expect(
        sppSafeTarget('npx -y @scope/server-files /workspace --port=8080'),
        'npx -y @scope/server-files /workspace --port=8080',
      );
    });

    test('hides token-shaped words even without a flag', () {
      expect(sppSafeTarget('tool sk-fakefakefakefakefake01'), 'tool $sppMask');
      expect(
        sppSafeTarget('tool ghp_fakefakefakefakefakefake01'),
        'tool $sppMask',
      );
    });

    test('a URL argument loses its query and user info', () {
      expect(
        sppSafeTarget('proxy https://u:p@host.example.com/x?key=fake'),
        'proxy https://host.example.com/x?…',
      );
    });

    test('a bare URL is cleaned the same way', () {
      expect(
        sppSafeTarget('https://mcp.example.com/sse?api_key=fake'),
        'https://mcp.example.com/sse?…',
      );
    });

    test('empty stays empty', () => expect(sppSafeTarget('  '), ''));
  });

  group('credential names', () {
    test('recognised', () {
      for (final name in [
        '--api-key',
        'API_KEY',
        'X_AUTH_TOKEN',
        'password',
        'client-secret',
        'Authorization',
      ]) {
        expect(sppIsSecretName(name), isTrue, reason: name);
      }
    });

    test('ordinary names are left alone', () {
      for (final name in ['--port', 'HOME', '--verbose', 'WORKSPACE']) {
        expect(sppIsSecretName(name), isFalse, reason: name);
      }
    });
  });

  group('sppSafeTarget: URLs behind name=value, any scheme', () {
    test('a credential flag hides the whole DSN', () {
      expect(
        sppSafeTarget(
          'node srv.js --dsn=postgres://user:pw@db.example.com/app',
        ),
        'node srv.js --dsn=$sppMask',
      );
    });

    test('an env URL keeps scheme and host, loses user info and query', () {
      expect(
        sppSafeTarget(
          'DATABASE_URL=postgres://u:pw@db.example.com:5432/app'
          '?sslmode=require#x node srv.js',
        ),
        'DATABASE_URL=postgres://db.example.com:5432/app?… node srv.js',
      );
    });

    test('postgres, mysql, redis, mongodb, amqp, ssh, git+https', () {
      const cases = {
        '--url=mysql://u:pw@h.example.com/db': '--url=mysql://h.example.com/db',
        '--cache=redis://:pw@c.example.com:6379/0':
            '--cache=redis://c.example.com:6379/0',
        '--db=mongodb+srv://u:pw@m.example.com/db':
            '--db=mongodb+srv://m.example.com/db',
        'AMQP=amqp://u:pw@mq.example.com:5672/vh':
            'AMQP=amqp://mq.example.com:5672/vh',
        '--remote=ssh://git@git.example.com/x/y':
            '--remote=ssh://git.example.com/x/y',
        'git+https://u:pw@git.example.com/org/repo.git':
            'git+https://git.example.com/org/repo.git',
        'jdbc:postgresql://u:pw@db.example.com/app':
            'jdbc:postgresql://db.example.com/app',
      };
      for (final entry in cases.entries) {
        expect(sppSafeTarget('tool ${entry.key}'), 'tool ${entry.value}');
      }
    });

    test('a URL that cannot be parsed shows only its scheme', () {
      expect(
        sppSafeTarget('tool --x=postgres://u:pa/ss@db.example.com/app'),
        'tool --x=postgres://$sppMask',
      );
    });

    test('quoted URL values are cleaned too', () {
      expect(
        sppSafeTarget('tool --endpoint="https://u:pw@api.example.com/v1?k=1"'),
        'tool --endpoint=https://api.example.com/v1?…',
      );
    });

    test('plain URLs keep their host', () {
      for (final url in [
        'https://mcp.example.com/docs',
        'http://localhost:8080/mcp',
        'https://[::1]:8443/sse',
      ]) {
        expect(sppSafeTarget(url), url);
        expect(sppSafeTarget('proxy $url'), 'proxy $url');
        expect(sppSafeTarget('proxy --upstream=$url'), 'proxy --upstream=$url');
      }
    });
  });

  group('sppSafeTarget: environment assignments before the command', () {
    test('the first word is masked when it carries a credential', () {
      expect(
        sppSafeTarget('TOKEN=abc123 node srv.js'),
        'TOKEN=$sppMask node srv.js',
      );
      expect(
        sppSafeTarget('DB_PASS=hunter2 API_KEY=abc PORT=80 node srv.js'),
        'DB_PASS=$sppMask API_KEY=$sppMask PORT=80 node srv.js',
      );
      expect(
        sppSafeTarget('env AWS_ACCESS_KEY_ID=AKIAFAKEFAKEFAKE1234 node'),
        'env AWS_ACCESS_KEY_ID=$sppMask node',
      );
    });

    test('an ordinary command word stays', () {
      expect(sppSafeTarget('node srv.js'), 'node srv.js');
      expect(sppSafeTarget('/usr/bin/some-tool'), '/usr/bin/some-tool');
      expect(sppSafeTarget('HOME=/srv node srv.js'), 'HOME=/srv node srv.js');
    });
  });

  group('sppSafeTarget: headers and short flags', () {
    test('the value after -H / --header is hidden, quoted or not', () {
      expect(
        sppSafeTarget('curl -H "Authorization: Bearer abc123xyz" -s'),
        'curl -H $sppMask -s',
      );
      expect(
        sppSafeTarget(
          "curl -H 'X-Api-Key: abc123' --header \"X-Auth-Token: z\"",
        ),
        'curl -H $sppMask --header $sppMask',
      );
      expect(
        sppSafeTarget('curl -H Authorization: Bearer abc123xyz --verbose'),
        'curl -H $sppMask --verbose',
      );
      expect(
        sppSafeTarget('curl --headers "Cookie: sid=abc" url'),
        'curl --headers $sppMask url',
      );
    });

    test('--header=value variants', () {
      expect(
        sppSafeTarget('curl --header="Authorization: Bearer abc123xyz"'),
        'curl --header=$sppMask',
      );
      expect(
        sppSafeTarget(
          'curl "--header=Proxy-Authorization: Basic dXNlcjpwdw=="',
        ),
        'curl --header=$sppMask',
      );
    });

    test('Authorization: and friends are recognised in any word', () {
      expect(
        sppSafeTarget('tool Authorization: Bearer abc123xyz --x 1'),
        'tool Authorization: $sppMask --x 1',
      );
      expect(
        sppSafeTarget('tool "Proxy-Authorization: Basic dXNlcjpwdw=="'),
        'tool Proxy-Authorization: $sppMask',
      );
      expect(
        sppSafeTarget('tool "X-Api-Key: abc"'),
        'tool X-Api-Key: $sppMask',
      );
      expect(
        sppSafeTarget('tool X-Auth-Token:abc'),
        'tool X-Auth-Token: $sppMask',
      );
    });

    test('Bearer / Basic <value> is hidden wherever it is', () {
      expect(
        sppSafeTarget('tool Bearer abc123xyz --x'),
        'tool Bearer $sppMask --x',
      );
      expect(sppSafeTarget('tool "Bearer abc123xyz"'), 'tool Bearer $sppMask');
      expect(
        sppSafeTarget('tool Basic dXNlcjpodW50ZXIy'),
        'tool Basic $sppMask',
      );
      expect(
        sppSafeTarget('tool --mode basic setup'),
        'tool --mode basic setup',
      );
    });

    test('-p / -P / --pass* / --key* / --accessKey and their = forms', () {
      for (final flag in [
        '-p',
        '-P',
        '--pass',
        '--passphrase',
        '--password',
        '--accessKey',
        '--AccessKeyId',
        '--secret-key',
        '--token',
        '--key',
        '--keyfile',
      ]) {
        expect(
          sppSafeTarget('mysql -u root $flag hunter2 --host db.example.com'),
          'mysql -u root $flag $sppMask --host db.example.com',
          reason: flag,
        );
      }
      expect(
        sppSafeTarget('tool --password=hunter2 --accesskey=abc'),
        'tool --password=$sppMask --accesskey=$sppMask',
      );
    });

    test('quoted values with blanks stay one word', () {
      expect(
        sppSafeTarget('tool --name "my server" --token "a b c" --x'),
        'tool --name "my server" --token $sppMask --x',
      );
    });

    test('an unbalanced quote still masks', () {
      expect(
        sppSafeTarget("tool don't --token abc"),
        "tool don't --token $sppMask",
      );
    });

    test('ordinary flags and values are left alone', () {
      const line =
          'tool --author "Jane Doe" --output=/tmp/x --verbose -u root '
          '--port 8080 https://mcp.example.com/docs';
      expect(sppSafeTarget(line), line);
      expect(sppSafeTarget('tool --author=jane'), 'tool --author=jane');
      expect(sppSafeTarget('tool -h --help'), 'tool -h --help');
    });
  });

  group('sppSplitWords', () {
    test('keeps quoted pieces whole, with their quotes', () {
      expect(sppSplitWords('a "b c" \'d e\'  f=g'), [
        'a',
        '"b c"',
        "'d e'",
        'f=g',
      ]);
    });

    test('an unbalanced quote splits on blanks', () {
      expect(sppSplitWords("a 'b c"), ['a', "'b", 'c']);
    });
  });

  group('credential names (wider)', () {
    test('recognised', () {
      for (final name in [
        '--accesskey',
        'AccessKeyId',
        'access_key',
        'aws-access-key-id',
        'secretKey',
        'PrivateKey',
        'passwd',
        'pass',
        '--pass',
        'PWD',
        'session',
        'SessionToken',
        'Cookie',
        'credential',
        'AUTH',
        '--auth',
        'connectionString',
        'CONNECTION_STRING',
        'DSN',
        'X-Api-Key',
        'Proxy-Authorization',
      ]) {
        expect(sppIsSecretName(name), isTrue, reason: name);
      }
    });

    test('author, output and friends are not credentials', () {
      for (final name in [
        '--author',
        'AUTHOR',
        '--output',
        '--verbose',
        'bypass',
        'passenger',
        'Content-Type',
      ]) {
        expect(sppIsSecretName(name), isFalse, reason: name);
      }
    });
  });

  group('sppMaskLogLine', () {
    test('URLs lose user info and query values', () {
      expect(
        sppMaskLogLine(
          'connecting to https://u:pw@mcp.example.com/sse?api_key=fake-1 failed.',
        ),
        'connecting to https://mcp.example.com/sse?… failed.',
      );
      expect(
        sppMaskLogLine('POST https://mcp.example.com/mcp, status 200'),
        'POST https://mcp.example.com/mcp, status 200',
      );
    });

    test('Authorization and Bearer values are hidden', () {
      expect(
        sppMaskLogLine('Authorization: Bearer abcdefghijkl'),
        'Authorization: $sppMask',
      );
      expect(
        sppMaskLogLine('headers {"Authorization": "Basic Zm9vOmJhcg=="}'),
        'headers {"Authorization": "$sppMask"}',
      );
      expect(
        sppMaskLogLine('sent bearer abcdefghijkl1234'),
        'sent bearer $sppMask',
      );
    });

    test('name=value pairs with a credential name are hidden', () {
      expect(
        sppMaskLogLine('env API_TOKEN=abc123 PORT=80'),
        'env API_TOKEN=$sppMask PORT=80',
      );
      expect(
        sppMaskLogLine('{"client_secret": "fake-secret"}'),
        '{"client_secret": "$sppMask"}',
      );
    });

    test('token-shaped words are hidden wherever they are', () {
      expect(
        sppMaskLogLine('key sk-fakefakefakefakefake01 used'),
        'key $sppMask used',
      );
    });

    test('an ordinary line is untouched', () {
      const line = '2026-01-01 12:00:00 INFO server started on port 8080';
      expect(sppMaskLogLine(line), line);
    });

    test('PASS, session and generic auth names are hidden', () {
      expect(
        sppMaskLogLine('env DB_PASS=hunter2 PORT=80'),
        'env DB_PASS=$sppMask PORT=80',
      );
      expect(
        sppMaskLogLine('PWD=hunter2 session=abc123 auth=abc123'),
        'PWD=$sppMask session=$sppMask auth=$sppMask',
      );
      expect(sppMaskLogLine('X-Auth: abc123'), 'X-Auth: $sppMask');
      expect(sppMaskLogLine('x-auth: Bearer abc123'), 'x-auth: $sppMask');
      expect(sppMaskLogLine('X-Api-Token: abc123'), 'X-Api-Token: $sppMask');
      expect(sppMaskLogLine('x_api_token = abc123'), 'x_api_token = $sppMask');
      expect(
        sppMaskLogLine('connectionString=Server=x'),
        'connectionString=$sppMask',
      );
    });

    test('key: value with a colon and blanks, and JSON', () {
      expect(sppMaskLogLine('password : hunter2'), 'password : $sppMask');
      expect(
        sppMaskLogLine('accessKeyId:   abc123'),
        'accessKeyId:   $sppMask',
      );
      expect(
        sppMaskLogLine('{"password":"abc123","user":"bob"}'),
        '{"password":"$sppMask","user":"bob"}',
      );
      expect(
        sppMaskLogLine('{"password": "my secret pass", "user": "bob"}'),
        '{"password": "$sppMask", "user": "bob"}',
      );
    });

    test('credential flags in a printed command line', () {
      expect(
        sppMaskLogLine('exec tool --password hunter2 --port 80'),
        'exec tool --password $sppMask --port 80',
      );
      expect(
        sppMaskLogLine('exec tool --api-key abc123 --token "a b"'),
        'exec tool --api-key $sppMask --token $sppMask',
      );
    });

    test('author and similar names are not touched', () {
      const line = 'author: bob bypass=1 passenger=2 keys: 3 sessions=4';
      expect(sppMaskLogLine(line), line);
    });
  });

  group('MCP form checks', () {
    test('name', () {
      expect(sppCheckMcpName(''), SppMcpIssue.nameEmpty);
      expect(sppCheckMcpName('has space'), SppMcpIssue.nameChars);
      expect(sppCheckMcpName('a/b'), SppMcpIssue.nameChars);
      expect(sppCheckMcpName('../x'), SppMcpIssue.nameChars);
      expect(sppCheckMcpName('docs-server.v2'), isNull);
    });

    test('url reasons are specific', () {
      expect(sppCheckMcpUrl(''), SppMcpIssue.urlEmpty);
      expect(sppCheckMcpUrl('ftp://x.example.com'), SppMcpIssue.urlScheme);
      expect(sppCheckMcpUrl('mcp.example.com/sse'), SppMcpIssue.urlScheme);
      expect(sppCheckMcpUrl('https:///path'), SppMcpIssue.urlHost);
      expect(
        sppCheckMcpUrl('https://u:p@mcp.example.com'),
        SppMcpIssue.urlUserInfo,
      );
      expect(
        sppCheckMcpUrl('https://mcp.example.com/sse?token=fake'),
        SppMcpIssue.urlQuery,
      );
      expect(
        sppCheckMcpUrl('https://mcp.example.com/sse#frag'),
        SppMcpIssue.urlFragment,
      );
      expect(sppCheckMcpUrl('https://mcp.example.com/sse'), isNull);
      expect(sppCheckMcpUrl('http://localhost:8080/mcp'), isNull);
    });

    test('command: hard errors and soft hints', () {
      expect(sppCheckMcpCommand(''), SppMcpIssue.commandEmpty);
      expect(sppCheckMcpCommand('npx\nrm'), SppMcpIssue.commandControl);
      expect(sppCheckMcpCommand('x' * 801), SppMcpIssue.commandTooLong);
      expect(sppCheckMcpCommand('npx'), isNull);
      // Hints never block.
      expect(sppCheckMcpCommand('npx -y pkg'), isNull);
      expect(sppMcpCommandHint('npx -y pkg'), SppMcpIssue.commandSpaces);
      expect(sppMcpCommandHint('a && b'), SppMcpIssue.commandShell);
      expect(sppMcpCommandHint('npx'), isNull);
    });

    test('cleartext classification: private is softer than public', () {
      expect(sppMcpUrlIsCleartext('http://mcp.example.com'), isTrue);
      expect(sppMcpUrlIsPublicCleartext('http://mcp.example.com'), isTrue);
      expect(sppMcpUrlIsPublicCleartext('http://localhost:9000'), isFalse);
      expect(sppMcpUrlIsCleartext('http://localhost:9000'), isTrue);
      expect(sppMcpUrlIsCleartext('https://mcp.example.com'), isFalse);
      expect(sppMcpUrlIsPublicCleartext('https://mcp.example.com'), isFalse);
    });
  });

  group('skill checks', () {
    const good = '---\nname: notes\ndescription: Keeps notes\n---\n\nUse it.\n';

    test('name follows the server rule', () {
      expect(sppCheckSkillName(''), SppSkillIssue.nameEmpty);
      expect(sppCheckSkillName('Notes'), SppSkillIssue.nameChars);
      expect(sppCheckSkillName('-notes'), SppSkillIssue.nameChars);
      expect(sppCheckSkillName('a' * 65), SppSkillIssue.nameTooLong);
      expect(sppCheckSkillName('my.skill_2-b'), isNull);
    });

    test('category is one directory name or empty', () {
      expect(sppCheckSkillCategory(''), isNull);
      expect(sppCheckSkillCategory('dev'), isNull);
      expect(sppCheckSkillCategory('a/b'), SppSkillIssue.categoryChars);
    });

    test('a new skill description fits the prompt budget', () {
      expect(sppCheckSkillDescription(' '), SppSkillIssue.descriptionEmpty);
      expect(
        sppCheckSkillDescription('d' * 61),
        SppSkillIssue.descriptionTooLong,
      );
      expect(sppCheckSkillDescription('d' * 60), isNull);
    });

    test('content, in the order the server checks it', () {
      expect(sppCheckSkillContent(good), isNull);
      expect(sppCheckSkillContent('  '), SppSkillIssue.contentEmpty);
      expect(
        sppCheckSkillContent('no header'),
        SppSkillIssue.contentNoFrontmatter,
      );
      expect(
        sppCheckSkillContent('---\nname: a\ndescription: b\n'),
        SppSkillIssue.contentUnclosed,
      );
      expect(
        sppCheckSkillContent('---\ndescription: b\n---\nbody'),
        SppSkillIssue.contentNoName,
      );
      expect(
        sppCheckSkillContent('---\nname: a\n---\nbody'),
        SppSkillIssue.contentNoDescription,
      );
      expect(
        sppCheckSkillContent('---\nname: a\ndescription: b\n---\n  \n'),
        SppSkillIssue.contentNoBody,
      );
      expect(
        sppCheckSkillContent('$good${'x' * sppSkillContentMax}'),
        SppSkillIssue.contentTooLong,
      );
      expect(sppCheckSkillContent('$good\u0000'), SppSkillIssue.contentNul);
    });

    test('a BOM before the header is tolerated, as on the server', () {
      expect(sppCheckSkillContent('﻿$good'), isNull);
    });

    test('split keeps fields and body, strips quotes', () {
      final parts = sppSplitSkill(
        '---\nname: notes\ndescription: "Keeps: notes"\nversion: 1.0\n---\n\n# Notes\n',
      );
      expect(parts.closed, isTrue);
      expect(parts.fields['name'], 'notes');
      expect(parts.fields['description'], 'Keeps: notes');
      expect(parts.fields['version'], '1.0');
      expect(parts.body, '# Notes\n');
    });

    test('split without a header is all body', () {
      final parts = sppSplitSkill('# Just text');
      expect(parts.hasFrontmatter, isFalse);
      expect(parts.body, '# Just text');
    });

    test('the template passes the checks it is meant for', () {
      final text = sppSkillTemplate(
        name: 'notes',
        description: 'Keeps "quoted" notes',
        body: 'Do it.',
      );
      expect(sppCheckSkillContent(text), isNull);
      expect(
        sppSplitSkill(text).fields['description'],
        r'Keeps \"quoted\" notes',
      );
    });
  });

  group('models fed by the server', () {
    test('a scan states its policy, counts and file:line', () {
      final scan = SkillScan.fromJson({
        'verdict': 'dangerous',
        'policy': 'block',
        'policy_reason': 'Community skills with dangerous findings are blocked',
        'summary': '2 findings',
        'severity_counts': {'critical': 1, 'high': 1, 'medium': 0, 'low': 0},
        'findings': [
          {
            'severity': 'critical',
            'description': 'curl piped to shell',
            'file': 'scripts/run.sh',
            'line': 3,
          },
          {'severity': 'high', 'description': 'reads ~/.ssh'},
        ],
      });
      expect(scan.gate, SkillScanGate.block);
      expect(scan.totalFindings, 2);
      expect(
        scan.findings.first,
        'critical: curl piped to shell (scripts/run.sh:3)',
      );
      expect(scan.findings.last, 'high: reads ~/.ssh');
      expect(scan.policyReason, contains('blocked'));
    });

    test('without a policy the verdict only asks', () {
      expect(SkillScan.fromJson({'verdict': 'safe'}).gate, SkillScanGate.allow);
      expect(
        SkillScan.fromJson({'verdict': 'dangerous'}).gate,
        SkillScanGate.ask,
      );
      expect(SkillScan.fromJson({}).gate, SkillScanGate.unknown);
      expect(SkillScan.fromJson({'policy': 'ask'}).gate, SkillScanGate.ask);
      expect(SkillScan.fromJson({'policy': 'allow'}).gate, SkillScanGate.allow);
    });

    test('a skill document keeps the text exactly', () {
      const raw =
          '---\r\nname: a\r\n---\r\n\r\n  body with trailing space \r\n';
      final doc = SkillDocument.fromJson({'name': 'a', 'content': raw});
      expect(doc.content, raw);
      expect(
        () => SkillDocument.fromJson({'name': 'a'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('an installed plugin row carries its origin', () {
      final item = CapabilityItem.installedPlugin({
        'name': 'weather',
        'key': 'tools/weather',
        'source': 'User',
        'version': '1.2.0',
        'runtime_status': 'enabled',
      })!;
      expect(item.origin, 'user');
      expect(item.version, '1.2.0');
    });
  });
}
