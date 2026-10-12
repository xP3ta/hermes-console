import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_control_center.dart';
import 'package:hermes_android/core/models/project_move_targets.dart';

ProjectTreeSnapshot _tree(List<Map<String, dynamic>> projects) =>
    ProjectTreeSnapshot.fromJson({'projects': projects});

Map<String, dynamic> _project(
  String id, {
  String path = '',
  bool archived = false,
  bool noProject = false,
  List<String> repos = const [],
}) => {
  'id': id,
  'label': 'Project $id',
  'path': path,
  'archived': archived,
  'isNoProject': noProject,
  'repos': [
    for (var i = 0; i < repos.length; i++)
      {'id': '$id-r$i', 'label': 'repo $i', 'path': repos[i]},
  ],
};

List<String> _ids(List<ProjectMoveTarget> targets) => [
  for (final t in targets) t.id,
];

void main() {
  group('projectMoveTargets', () {
    test('keeps active projects that have a folder', () {
      final targets = projectMoveTargets(
        _tree([
          _project('a', path: '/srv/work/a'),
          _project('b', path: '/srv/work/b'),
        ]),
      );
      expect(_ids(targets), ['a', 'b']);
      expect(targets.first.cwd, '/srv/work/a');
      expect(targets.first.label, 'Project a');
    });

    test('drops archived, "no project" and folderless projects', () {
      final targets = projectMoveTargets(
        _tree([
          _project('keep', path: '/srv/work/keep'),
          _project('old', path: '/srv/work/old', archived: true),
          _project('none', path: '/srv/work/none', noProject: true),
          _project('empty'),
        ]),
      );
      expect(_ids(targets), ['keep']);
    });

    test('a project without its own path uses its first repository path', () {
      final targets = projectMoveTargets(
        _tree([
          _project('mono', repos: ['', '/srv/work/mono/app', '/srv/work/x']),
        ]),
      );
      expect(targets.single.cwd, '/srv/work/mono/app');
    });

    test('the project path wins over its repositories', () {
      final targets = projectMoveTargets(
        _tree([
          _project('p', path: '/srv/work/p', repos: ['/srv/work/other']),
        ]),
      );
      expect(targets.single.cwd, '/srv/work/p');
    });

    test('drops the project the session already lives in', () {
      final tree = _tree([
        _project('a', path: '/srv/work/a'),
        _project('b', path: '/srv/work/b/'),
      ]);
      expect(_ids(projectMoveTargets(tree, sessionCwd: '/srv/work/a')), ['b']);
      expect(
        _ids(projectMoveTargets(tree, sessionGitRepoRoot: '/srv/work/b')),
        ['a'],
      );
    });

    test('a session inside the project folder is already in it', () {
      final tree = _tree([
        _project('a', path: '/srv/work/a'),
        _project('b', path: '/srv/work/b'),
      ]);
      expect(
        _ids(projectMoveTargets(tree, sessionCwd: '/srv/work/a/src')),
        ['b'],
      );
      expect(
        _ids(
          projectMoveTargets(tree, sessionGitRepoRoot: '/srv/work/b/pkg/x'),
        ),
        ['a'],
      );
    });

    test('a session in a subfolder is not in another project', () {
      final tree = _tree([_project('a', path: '/srv/work/a')]);
      expect(_ids(projectMoveTargets(tree, sessionCwd: '/srv/work/a-extra')), [
        'a',
      ]);
    });

    test('no projects with a folder is an empty list', () {
      expect(projectMoveTargets(_tree(const [])), isEmpty);
      expect(
        projectMoveTargets(_tree([_project('x', noProject: true)])),
        isEmpty,
      );
    });
  });

  group('sessionInProjectFolder', () {
    test('the folder itself and anything under it', () {
      expect(sessionInProjectFolder('/srv/work/a', cwd: '/srv/work/a'), isTrue);
      expect(
        sessionInProjectFolder('/srv/work/a', cwd: '/srv/work/a/src'),
        isTrue,
      );
      expect(
        sessionInProjectFolder('/srv/work/a/', gitRepoRoot: '/srv/work/a'),
        isTrue,
      );
    });

    test('a sibling with the same prefix is another project', () {
      expect(
        sessionInProjectFolder('/srv/work/a', cwd: '/srv/work/ab'),
        isFalse,
      );
    });

    test('a session without a folder is in no project', () {
      expect(sessionInProjectFolder('/srv/work/a'), isFalse);
      expect(sessionInProjectFolder('/srv/work/a', cwd: ''), isFalse);
    });
  });
}
