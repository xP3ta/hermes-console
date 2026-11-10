// The hub's data: route shapes, the classified reasons of a refused ship
// action (never the text), masking of anything the server sends, and
// which links the app hands to the browser.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/git_hub.dart';
import 'package:hermes_android/core/models/git_review.dart';

void main() {
  group('shapes', () {
    test('gh-auth', () {
      expect(
        GitGhAuth.fromJson(const {
          'available': true,
          'authenticated': true,
        }).authenticated,
        isTrue,
      );
      final none = GitGhAuth.fromJson(const {});
      expect(none.available, isFalse);
      expect(none.authenticated, isFalse);
    });

    test('worktree rows drop a missing path and name their folder', () {
      expect(GitWorktree.tryParse(const {'branch': 'x'}), isNull);
      expect(GitWorktree.tryParse('nope'), isNull);
      final tree = GitWorktree.tryParse(const {
        'path': '/srv/r/.worktrees/feat-x/',
        'branch': 'feat/x',
        'detached': false,
      })!;
      expect(tree.name, 'feat-x');
      expect(tree.branch, 'feat/x');
    });

    test('ship info with an OPEN PR lower-cases the state', () {
      final ship = GitShipInfo.fromJson(const {
        'ghReady': true,
        'pr': {
          'url': 'https://github.com/o/r/pull/1',
          'state': 'MERGED',
          'number': 1,
        },
      });
      expect(ship.pullRequest!.state, 'merged');
      expect(
        GitShipInfo.fromJson(const {
          'ghReady': true,
          'pr': {'state': 'open'},
        }).pullRequest,
        isNull,
      );
    });

    test('commit context keeps at most the budget of lines', () {
      final lines = List.generate(kGitCommitContextMaxLines + 5, (i) => '+$i');
      final ctx = GitCommitContext.fromJson({
        'diff': '${lines.join('\n')}\n',
        'recent': '',
      });
      expect(ctx.diffLines.length, kGitCommitContextMaxLines);
      expect(ctx.truncated, isTrue);
      expect(ctx.recentSubjects, isEmpty);
      expect(GitCommitContext.fromJson(const {}).isEmpty, isTrue);
    });
  });

  group('refusals are classified, never quoted', () {
    const cases = <String, GitActionProblem>{
      ' ! [rejected] main -> main (non-fast-forward)':
          GitActionProblem.pushRejected,
      'error: failed to push some refs to x': GitActionProblem.pushRejected,
      'fatal: Authentication failed for https://github.com/o/r/':
          GitActionProblem.remoteAuth,
      'fatal: could not read Username for https://github.com: terminal prompts disabled':
          GitActionProblem.remoteAuth,
      'ssh: Could not resolve hostname github.com':
          GitActionProblem.remoteUnreachable,
      'fatal: Could not read from remote repository.':
          GitActionProblem.remoteUnreachable,
      'fatal: No configured push destination.': GitActionProblem.noRemote,
      'gh pr create failed: is gh installed and authenticated?':
          GitActionProblem.ghNotReady,
      'gh pr create failed: To get started with GitHub CLI, please run: gh auth login':
          GitActionProblem.ghNotReady,
      'gh pr create failed: a pull request for branch "x" into branch "main" already exists:':
          GitActionProblem.prExists,
      'gh pr create failed: pull request create failed: GraphQL: No commits between main and x':
          GitActionProblem.prNoCommits,
      'error: Your local changes to the following files would be overwritten by checkout':
          GitActionProblem.localChanges,
      'fatal: /w contains modified or untracked files, use --force to delete it':
          GitActionProblem.localChanges,
      'fatal: invalid reference: nope': GitActionProblem.branchNotFound,
      'Branch name is required.': GitActionProblem.branchNotFound,
      'error: Committing is not possible because you have unmerged files.':
          GitActionProblem.conflict,
      'Author identity unknown': GitActionProblem.noIdentity,
    };
    cases.forEach((detail, problem) {
      test(problem.name, () {
        expect(
          classifyGitFailureDetail(jsonEncode({'detail': detail})),
          problem,
        );
        expect(classifyGitFailureDetail(detail), problem);
      });
    });

    test('an unknown text is null', () {
      expect(classifyGitFailureDetail('something odd happened'), isNull);
    });

    test('the failure carries the kind only', () {
      const failure = GitActionFailure(GitActionProblem.remoteAuth);
      expect(failure.toString(), 'GitActionFailure(remoteAuth)');
    });
  });

  group('masking', () {
    test('a URL with credentials loses them', () {
      final safe = gitSafeText(
        'remote: https://user:s3cr3tpass@github.com/o/r.git',
      );
      expect(safe, isNot(contains('s3cr3tpass')));
      expect(safe, contains('github.com'));
    });

    test('a token-shaped word and a secret pair are hidden', () {
      final safe = gitSafeText(
        'GITHUB_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123456789 bearer abcdefghijklmnop',
      );
      expect(safe, isNot(contains('ghp_abcdefghijklmnopqrstuvwxyz0123456789')));
      expect(safe, isNot(contains('abcdefghijklmnop')));
    });

    test('plain text passes', () {
      expect(gitSafeText('feat: add the hub'), 'feat: add the hub');
    });
  });

  group('links the app may open', () {
    test('a plain https link', () {
      expect(
        gitSafeHttpsUrl('https://github.com/o/r/pull/12')!.host,
        'github.com',
      );
    });

    test('http, user info, a query, a fragment or junk are refused', () {
      for (final raw in [
        'http://github.com/o/r/pull/12',
        'https://u:p@github.com/o/r/pull/12',
        'https://github.com/o/r/pull/12?token=abc',
        'https://github.com/o/r/pull/12#x',
        'javascript:alert(1)',
        '',
        'not a url',
      ]) {
        expect(gitSafeHttpsUrl(raw), isNull, reason: raw);
      }
    });
  });
}
