import 'dart:typed_data';

import 'package:hermes_android/core/models/desktop_control_center.dart';
import 'package:hermes_android/core/models/project_files.dart';
import 'package:hermes_android/core/services/desktop_control_gateway.dart';

/// Synthetic Projects fixture shared by the capture and behaviour tests.
Map<String, dynamic> pj1215SampleTreeJson() => {
  'active_id': 'p_console',
  'projects': [
    {
      'id': 'p_console',
      'label': 'Hermes Console',
      'path': '/home/demo/code/hermes-console',
      'color': 'hsl(210 68% 58%)',
      'icon': 'device-mobile',
      'isAuto': false,
      'isNoProject': false,
      'sessionCount': 7,
      'lastActive': _ago(const Duration(minutes: 20)),
      'previewSessions': [
        {'id': 's1', 'title': 'Rediseñar Proyectos'},
        {'id': 's2', 'title': 'Arreglar notificaciones'},
      ],
      'repos': [
        {
          'id': '/home/demo/code/hermes-console',
          'label': 'hermes-console',
          'path': '/home/demo/code/hermes-console',
          'sessionCount': 7,
          'groups': [
            {
              'id': '/home/demo/code/hermes-console::branch::main',
              'label': 'main',
              'path': '/home/demo/code/hermes-console',
              'isMain': true,
            },
            {
              'id': '/home/demo/code/hermes-console-wt/projects',
              'label': 'feat/projects',
              'path': '/home/demo/code/hermes-console-wt/projects',
              'isMain': false,
            },
          ],
        },
      ],
    },
    {
      'id': 'p_notes',
      'label': 'Notas de viaje',
      'path': '/home/demo/notes/travel',
      'color': 'hsl(120 68% 58%)',
      'icon': 'book',
      'isAuto': false,
      'sessionCount': 2,
      'lastActive': _ago(const Duration(days: 3)),
      'repos': [],
    },
    {
      'id': '/srv/work/homelab',
      'label': 'homelab',
      'path': '/srv/work/homelab',
      'isAuto': true,
      'sessionCount': 3,
      'lastActive': _ago(const Duration(hours: 5)),
      'repos': [
        {
          'id': '/srv/work/homelab',
          'label': 'homelab',
          'path': '/srv/work/homelab',
          'sessionCount': 3,
          'groups': [
            {
              'id': '/srv/work/homelab::branch::master',
              'label': 'master',
              'path': '/srv/work/homelab',
              'isMain': true,
            },
          ],
        },
      ],
    },
    {
      'id': '__no_project__',
      'label': 'Home',
      'isNoProject': true,
      'sessionCount': 4,
      'lastActive': _ago(const Duration(hours: 1)),
      'repos': [],
    },
  ],
};

Map<String, dynamic> pj1215ConsoleDetailJson() => {
  'id': 'p_console',
  'label': 'Hermes Console',
  'path': '/home/demo/code/hermes-console',
  'color': 'hsl(210 68% 58%)',
  'icon': 'device-mobile',
  'sessionCount': 7,
  'repos': [
    {
      'id': '/home/demo/code/hermes-console',
      'label': 'hermes-console',
      'path': '/home/demo/code/hermes-console',
      'sessionCount': 7,
      'groups': [
        {
          'id': '/home/demo/code/hermes-console::branch::main',
          'label': 'main',
          'path': '/home/demo/code/hermes-console',
          'isMain': true,
          'totalCount': 5,
          'sessions': [
            for (final (i, title) in const [
              'Arreglar notificaciones',
              'Revisar el login',
              'Subir versión 1.2.16',
              'Limpiar avisos del analizador',
              'Probar modo oscuro',
            ].indexed)
              {
                'id': 'main-$i',
                'title': title,
                'last_active': _ago(Duration(hours: 2 + i * 9)),
                'message_count': 12 + i,
              },
          ],
        },
        {
          'id': '/home/demo/code/hermes-console-wt/projects',
          'label': 'feat/projects',
          'path': '/home/demo/code/hermes-console-wt/projects',
          'isMain': false,
          'totalCount': 2,
          'sessions': [
            {
              'id': 'wt-0',
              'title': 'Rediseñar Proyectos',
              'last_active': _ago(const Duration(minutes: 20)),
            },
            {
              'id': 'wt-1',
              'title': 'Selector de rama base',
              'last_active': _ago(const Duration(hours: 1)),
            },
          ],
        },
      ],
    },
  ],
};

double _ago(Duration duration) =>
    DateTime.now().subtract(duration).millisecondsSinceEpoch / 1000;

/// Fake gateway exposing the read RPCs only (an older Hermes, or a
/// connection whose gateway has no project write surface).
class Pj1215ReadOnlyProjectsGateway implements HermesDesktopControlGateway {
  ProjectTreeSnapshot tree;
  final Map<String, ProjectNode> details;
  final List<String> calls = [];

  Pj1215ReadOnlyProjectsGateway({
    this.tree = const ProjectTreeSnapshot(projects: []),
    Map<String, ProjectNode>? details,
  }) : details = details ?? {};

  factory Pj1215ReadOnlyProjectsGateway.sample() =>
      Pj1215ReadOnlyProjectsGateway(
        tree: ProjectTreeSnapshot.fromJson(pj1215SampleTreeJson()),
        details: {
          'p_console': ProjectNode.tryParse(pj1215ConsoleDetailJson())!,
        },
      );

  @override
  Future<ProjectTreeSnapshot> projectTree() async {
    calls.add('projects.tree');
    return tree;
  }

  @override
  Future<ProjectNode?> projectSessions(String projectId) async {
    calls.add('projects.project_sessions:$projectId');
    return details[projectId];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

/// Fake of a current Hermes: read RPCs plus the project write RPCs and the
/// Dashboard git routes Desktop uses. Records every call with its params.
class Pj1215FakeProjectsGateway extends Pj1215ReadOnlyProjectsGateway
    implements HermesProjectManagementGateway {
  bool writesAllowed;
  Object? writeFailure;
  Object? gitFailure;
  final List<(String, Map<String, Object?>)> writes = [];
  List<ProjectGitBaseBranch> baseBranches = const [
    ProjectGitBaseBranch(name: 'origin/main', isRemote: true, isDefault: true),
    ProjectGitBaseBranch(name: 'main'),
    ProjectGitBaseBranch(name: 'develop'),
  ];
  List<ProjectGitBranch> branches = const [
    ProjectGitBranch(
      name: 'main',
      checkedOut: true,
      isDefault: true,
      worktreePath: '/home/demo/code/hermes-console',
    ),
    ProjectGitBranch(
      name: 'feat/projects',
      checkedOut: true,
      worktreePath: '/home/demo/code/hermes-console-wt/projects',
    ),
    ProjectGitBranch(name: 'fix/login'),
    ProjectGitBranch(name: 'origin/release', isRemote: true),
  ];

  Pj1215FakeProjectsGateway({
    super.tree,
    super.details,
    this.writesAllowed = true,
  });

  factory Pj1215FakeProjectsGateway.sample() {
    final gateway = Pj1215FakeProjectsGateway(
      tree: ProjectTreeSnapshot.fromJson(pj1215SampleTreeJson()),
    );
    gateway.details['p_console'] = ProjectNode.tryParse(
      pj1215ConsoleDetailJson(),
    )!;
    return gateway;
  }

  void _write(String method, Map<String, Object?> params) {
    writes.add((method, params));
    final failure = writeFailure;
    if (failure != null) throw failure;
  }

  void _git(String route, Map<String, Object?> params) {
    writes.add((route, params));
    final failure = gitFailure;
    if (failure != null) throw failure;
  }

  @override
  bool get projectWritesAllowed => writesAllowed;

  @override
  Future<void> updateProject(
    String id, {
    String? name,
    String? color,
    String? icon,
  }) async => _write('projects.update', {
    'id': id,
    'name': ?name,
    'color': ?color,
    'icon': ?icon,
  });

  @override
  Future<void> createProject({
    required String name,
    required String primaryPath,
    String? color,
    String? icon,
  }) async => _write('projects.create', {
    'name': name,
    'primary_path': primaryPath,
    'color': ?color,
    'icon': ?icon,
  });

  @override
  Future<void> deleteProject(String id) async =>
      _write('projects.delete', {'id': id});

  @override
  Future<void> setActiveProject(String id) async =>
      _write('projects.set_active', {'id': id});

  @override
  Future<List<ProjectGitBaseBranch>> listBaseBranches(String repoPath) async {
    _git('GET /api/git/base-branches', {'path': repoPath});
    return baseBranches;
  }

  @override
  Future<List<ProjectGitBranch>> listBranches(String repoPath) async {
    _git('GET /api/git/branches', {'path': repoPath});
    return branches;
  }

  @override
  Future<ProjectWorktreeResult> addWorktree(
    String repoPath, {
    String? branch,
    String? base,
    String? existingBranch,
  }) async {
    _git('POST /api/git/worktree/add', {
      'path': repoPath,
      'branch': ?branch,
      'base': ?base,
      'existingBranch': ?existingBranch,
    });
    final name = branch ?? existingBranch!;
    return ProjectWorktreeResult(
      path: '$repoPath-wt/${name.replaceAll('/', '-')}',
      branch: name,
    );
  }

  @override
  Future<void> switchBranch(String repoPath, String branch) async =>
      _git('POST /api/git/branch/switch', {'path': repoPath, 'branch': branch});
}

/// Adds Desktop's project creation surface (`projects.create`,
/// `projects.add_folder`, `llm.oneshot`, `/api/fs/default-cwd`,
/// `projects.discover_repos`) plus the file routes the server folder picker
/// and IDEA.md use. Every call is recorded in [writes] with its wire params.
class Pc1215CreatingProjectsGateway extends Pj1215FakeProjectsGateway
    implements
        HermesProjectCreationGateway,
        HermesProjectFilesGateway,
        HermesProjectFileWritesGateway {
  Pc1215CreatingProjectsGateway({super.tree, super.writesAllowed});

  factory Pc1215CreatingProjectsGateway.sample() {
    final gateway = Pc1215CreatingProjectsGateway(
      tree: ProjectTreeSnapshot.fromJson(pj1215SampleTreeJson()),
    );
    gateway.details['p_console'] = ProjectNode.tryParse(
      pj1215ConsoleDetailJson(),
    )!;
    return gateway;
  }

  Object? createFailure;
  bool creationUnsupported = false;
  bool filesUnsupported = false;
  String idea = 'A tiny garden planner.\n\n- Track seeds';
  String? defaultFolder = '/home/demo';
  final Map<String, List<ProjectFsEntry>> folders = {};

  /// Tree served after a successful create (the server's next answer).
  ProjectTreeSnapshot? treeAfterCreate;

  @override
  bool get projectCreationKnownUnsupported => creationUnsupported;

  @override
  Future<ProjectCreated> createProjectFromFolders({
    required String name,
    required List<String> folders,
    String? primaryPath,
    bool use = true,
  }) async {
    writes.add((
      'projects.create',
      {
        'name': name,
        'folders': folders,
        'primary_path': ?primaryPath,
        'use': use,
      },
    ));
    final failure = createFailure;
    if (failure != null) throw failure;
    final next = treeAfterCreate;
    if (next != null) tree = next;
    return ProjectCreated(
      id: 'p_new',
      primaryPath: primaryPath ?? folders.first,
    );
  }

  @override
  Future<void> addProjectFolder(String id, String path) async => _write(
    'projects.add_folder',
    {'id': id, 'path': path, 'is_primary': false},
  );

  @override
  Future<String> generateProjectIdea(String name) async {
    writes.add(('llm.oneshot', {'name': name}));
    return idea;
  }

  @override
  Future<String?> projectDefaultFolder() async {
    calls.add('GET /api/fs/default-cwd');
    return defaultFolder;
  }

  @override
  Future<void> scanProjectRepos() async {
    calls.add('projects.discover_repos:scan');
  }

  @override
  bool get projectFilesKnownUnsupported => filesUnsupported;

  @override
  Future<ProjectDirectoryListing> listProjectDirectory(String path) async {
    calls.add('GET /api/fs/list:$path');
    return ProjectDirectoryListing(entries: folders[path] ?? const []);
  }

  @override
  Future<ProjectFilePreview> readProjectFileText(String path) async {
    calls.add('GET /api/fs/read-text:$path');
    return ProjectFilePreview(
      path: path,
      text: 'contents of $path',
      binary: false,
      truncated: false,
      byteSize: 16,
      mimeType: 'text/plain',
    );
  }

  @override
  Future<Uint8List> readProjectFileBytes(String path) async {
    calls.add('GET /api/fs/read-data-url:$path');
    return Uint8List(0);
  }

  @override
  bool get projectFileWritesAllowed => writesAllowed;

  @override
  bool projectFileWriteKnownUnsupported(ProjectFileWriteAction action) => false;

  @override
  Future<void> writeProjectFileText(String path, String content) async {
    writes.add(('POST /api/fs/write-text', {'path': path, 'content': content}));
  }

  @override
  Future<String> createProjectFolder(String path) async {
    writes.add(('POST /api/files/mkdir', {'path': path}));
    return path;
  }
}
