// Git review data read from the Dashboard `/api/git/*` routes, in the shapes
// Hermes Desktop uses (`apps/desktop/src/global.d.ts`), and the unified diff
// parser behind the full-screen diff.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/git_review.dart';

void main() {
  group('GitRepoStatus', () {
    test('reads the coding-row status', () {
      final status = GitRepoStatus.tryParse({
        'branch': 'release/1.3.1',
        'defaultBranch': 'main',
        'detached': false,
        'ahead': 1,
        'behind': 2,
        'staged': 1,
        'unstaged': 2,
        'untracked': 1,
        'conflicted': 0,
        'changed': 4,
        'added': 82,
        'removed': 1,
        'files': [],
      })!;
      expect(status.branch, 'release/1.3.1');
      expect(status.defaultBranch, 'main');
      expect(status.ahead, 1);
      expect(status.behind, 2);
      expect(status.changed, 4);
      expect(status.added, 82);
      expect(status.removed, 1);
      expect(status.hasLineDelta, isTrue);
      expect(status.untrackedOnly, isFalse);
    });

    test('a null body (not a repository) is null', () {
      // DashboardClient wraps a JSON null as {data: null}.
      expect(GitRepoStatus.tryParse({'data': null}), isNull);
      expect(GitRepoStatus.tryParse({}), isNull);
    });

    test('detached HEAD and untracked-only changes', () {
      final status = GitRepoStatus.tryParse({
        'branch': null,
        'detached': true,
        'changed': 2,
        'untracked': 2,
        'added': 0,
        'removed': 0,
      })!;
      expect(status.detached, isTrue);
      expect(status.branch, isNull);
      expect(status.hasLineDelta, isFalse);
      expect(status.untrackedOnly, isTrue);
    });

    test('a clean repository has no counts to show', () {
      final status = GitRepoStatus.tryParse({'branch': 'main', 'changed': 0})!;
      expect(status.changed, 0);
      expect(status.hasLineDelta, isFalse);
      expect(status.untrackedOnly, isFalse);
    });
  });

  group('GitReviewList', () {
    test('rows: modified, added, deleted, renamed, conflicted, untracked', () {
      final list = GitReviewList.fromJson({
        'files': [
          {'path': 'lib/z.dart', 'added': 4, 'removed': 1, 'status': 'M'},
          {
            'path': 'lib/core/models/session.dart',
            'added': 16,
            'removed': 0,
            'status': 'A',
            'staged': true,
          },
          {'path': 'old.txt', 'added': 0, 'removed': 3, 'status': 'D'},
          {'path': 'docs/new name.md', 'status': 'R'},
          {'path': 'f.txt', 'status': 'U'},
          {'path': 'test/new_test.dart', 'added': 19, 'status': '?'},
        ],
        'base': null,
      });
      expect(list.files.map((f) => f.path), [
        'docs/new name.md',
        'f.txt',
        'lib/core/models/session.dart',
        'lib/z.dart',
        'old.txt',
        'test/new_test.dart',
      ]);
      final session = list.files[2];
      expect(session.name, 'session.dart');
      expect(session.directory, 'lib/core/models');
      expect(session.added, 16);
      expect(session.status, 'A');
      expect(session.staged, isTrue);
      expect(list.files[1].status, 'U');
      expect(list.files.last.status, '?');
      expect(list.files[4].directory, '');
      expect(list.base, isNull);
    });

    test('drops always-excluded paths, like Desktop', () {
      final list = GitReviewList.fromJson({
        'files': [
          {'path': 'node_modules/.bin/x', 'status': '?'},
          {'path': 'build/app.apk', 'status': '?'},
          {'path': '.DS_Store', 'status': '?'},
          {'path': 'lib/main.dart', 'status': 'M'},
        ],
      });
      expect(list.files.map((f) => f.path), ['lib/main.dart']);
    });

    test('an empty or malformed body is an empty list', () {
      expect(GitReviewList.fromJson({}).files, isEmpty);
      expect(GitReviewList.fromJson({'files': null}).files, isEmpty);
      expect(
        GitReviewList.fromJson({
          'files': [
            'x',
            {'path': ''},
            {'nope': 1},
          ],
        }).files,
        isEmpty,
      );
    });
  });

  test('isExcludedReviewPath matches whole segments only', () {
    expect(isExcludedReviewPath('a/node_modules/b'), isTrue);
    expect(isExcludedReviewPath(r'a\dist\b'), isTrue);
    expect(isExcludedReviewPath('lib/builder.dart'), isFalse);
    expect(isExcludedReviewPath('lib/outline.dart'), isFalse);
  });

  group('parseGitDiff', () {
    test('numbers added, removed and context lines from the hunk', () {
      const raw =
          'diff --git a/lib/a.dart b/lib/a.dart\n'
          'index de98044..d68dd40 100644\n'
          '--- a/lib/a.dart\n'
          '+++ b/lib/a.dart\n'
          '@@ -210,4 +210,5 @@ String titleWith(String? raw) {\n'
          ' String titleWith(String? raw) {\n'
          '-  return raw;\n'
          '+  final t = humanizedTitle(raw);\n'
          '+  return t;\n'
          ' }\n'
          r'\ No newline at end of file' '\n';
      final diff = parseGitDiff(raw);
      expect(diff.binary, isFalse);
      expect(diff.tooLarge, isFalse);
      expect(diff.lines.map((l) => l.kind), [
        GitDiffLineKind.hunk,
        GitDiffLineKind.context,
        GitDiffLineKind.removed,
        GitDiffLineKind.added,
        GitDiffLineKind.added,
        GitDiffLineKind.context,
        GitDiffLineKind.note,
      ]);
      expect(diff.lines.map((l) => l.number), [
        null,
        210,
        211,
        211,
        212,
        213,
        null,
      ]);
      expect(diff.lines[3].text, '  final t = humanizedTitle(raw);');
    });

    test('an untracked file is an all-add diff', () {
      const raw =
          'diff --git a/new file.txt b/new file.txt\n'
          'new file mode 100644\n'
          'index 0000000..8ba3a16\n'
          '--- /dev/null\n'
          '+++ b/new file.txt\t\n'
          '@@ -0,0 +1 @@\n'
          '+n\n';
      final diff = parseGitDiff(raw);
      expect(diff.lines.last.kind, GitDiffLineKind.added);
      expect(diff.lines.last.number, 1);
    });

    test('binary', () {
      const raw =
          'diff --git a/bin.dat b/bin.dat\n'
          'index 8352675..0bc9965 100644\n'
          'Binary files a/bin.dat and b/bin.dat differ\n';
      final diff = parseGitDiff(raw);
      expect(diff.binary, isTrue);
      expect(diff.isEmpty, isFalse);
    });

    test('empty', () {
      expect(parseGitDiff('').isEmpty, isTrue);
      expect(parseGitDiff('\n').isEmpty, isTrue);
    });

    test('a huge diff is cut and marked too large', () {
      final raw = StringBuffer('@@ -1,0 +1,9000 @@\n');
      for (var i = 0; i < 9000; i++) {
        raw.writeln('+line $i');
      }
      final diff = parseGitDiff(raw.toString(), maxLines: 100);
      expect(diff.tooLarge, isTrue);
      expect(diff.lines.length, 100);
      expect(diff.isEmpty, isFalse);
    });
  });

  group('classifyGitFailureDetail (F2b)', () {
    String detail(String text) => jsonEncode({'detail': text});

    test('conflict, identity and nothing to commit', () {
      expect(
        classifyGitFailureDetail(
          detail(
            'error: Committing is not possible because you have unmerged '
            'files.',
          ),
        ),
        GitActionProblem.conflict,
      );
      expect(
        classifyGitFailureDetail(detail('Author identity unknown')),
        GitActionProblem.noIdentity,
      );
      expect(
        classifyGitFailureDetail(
          detail('nothing to commit, working tree clean'),
        ),
        GitActionProblem.nothingToCommit,
      );
    });

    test('raw text and unknown reasons', () {
      expect(
        classifyGitFailureDetail('Author identity unknown'),
        GitActionProblem.noIdentity,
      );
      expect(classifyGitFailureDetail(detail('hook failed')), isNull);
      expect(classifyGitFailureDetail(''), isNull);
    });
  });

  test('CRLF lines lose their carriage return (REVIEW-F2 P3)', () {
    final diff = parseGitDiff('@@ -1 +1 @@\r\n-old\r\n+new\r\n');
    expect(diff.lines.map((l) => l.text), ['@@ -1 +1 @@', 'old', 'new']);
  });

  group('REVIEW-R5-C', () {
    test('C-G1: a conflicted file\'s combined diff is shown, not empty', () {
      // `git diff` of an unmerged path (two parents, one marker column
      // each), as the server returns it.
      const raw =
          'diff --cc lib/a.dart\n'
          'index 1111111,2222222..0000000\n'
          '--- a/lib/a.dart\n'
          '+++ b/lib/a.dart\n'
          '@@@ -1,3 -1,3 +1,7 @@@\n'
          '  void main() {\n'
          '++<<<<<<< HEAD\n'
          ' +  print(1);\n'
          '++=======\n'
          '+   print(2);\n'
          '++>>>>>>> feat\n'
          '- old line\n'
          '  }\n';
      final diff = parseGitDiff(raw);
      expect(diff.isEmpty, isFalse);
      expect(diff.binary, isFalse);
      expect(diff.lines.first.kind, GitDiffLineKind.hunk);
      expect(diff.lines.first.text, '@@@ -1,3 -1,3 +1,7 @@@');
      final body = diff.lines.skip(1).toList();
      expect(body.map((l) => l.kind), [
        GitDiffLineKind.context,
        GitDiffLineKind.added,
        GitDiffLineKind.added,
        GitDiffLineKind.added,
        GitDiffLineKind.added,
        GitDiffLineKind.added,
        GitDiffLineKind.removed,
        GitDiffLineKind.context,
      ]);
      // The marker columns are not part of the text.
      expect(body.map((l) => l.text), [
        'void main() {',
        '<<<<<<< HEAD',
        '  print(1);',
        '=======',
        '  print(2);',
        '>>>>>>> feat',
        'old line',
        '}',
      ]);
      // Numbered in the working-tree file; a removed line has no number.
      expect(body.map((l) => l.number), [1, 2, 3, 4, 5, 6, null, 7]);
    });

    test('C-G1: a plain unified diff still parses as before', () {
      final diff = parseGitDiff('@@ -3 +3,2 @@\n-a\n+b\n+c\n');
      expect(diff.lines.map((l) => (l.kind, l.number)), [
        (GitDiffLineKind.hunk, null),
        (GitDiffLineKind.removed, 3),
        (GitDiffLineKind.added, 3),
        (GitDiffLineKind.added, 4),
      ]);
    });

    test('C-G2: an untracked folder keeps its name', () {
      const folder = GitReviewFile(path: 'nueva/', status: '?');
      expect(folder.name, 'nueva');
      expect(folder.directory, '');
      const nested = GitReviewFile(path: 'src/nueva/', status: '?');
      expect(nested.name, 'nueva');
      expect(nested.directory, 'src');
      const file = GitReviewFile(path: 'src/a.dart');
      expect(file.name, 'a.dart');
      expect(file.directory, 'src');
    });

    test('C-G10: the staged dot names one file', () {
      String staged(String lang) {
        final arb = File('lib/l10n/app_$lang.arb').readAsStringSync();
        return (jsonDecode(arb) as Map<String, dynamic>)['gitStaged']
            as String;
      }

      expect(staged('es'), 'Preparado');
      expect(staged('pt'), 'Preparado');
      expect(staged('it'), 'Preparato');
    });

    test('C-G11: the uncommitted and branch scopes, no last-turn one', () {
      expect(GitReviewScope.values, [
        GitReviewScope.uncommitted,
        GitReviewScope.branch,
      ]);
      expect(GitReviewScope.uncommitted.wire, 'uncommitted');
      expect(GitReviewScope.branch.wire, 'branch');
    });
  });
}
