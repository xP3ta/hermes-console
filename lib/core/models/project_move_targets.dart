import 'desktop_control_center.dart';

/// A project a session may be moved to.
final class ProjectMoveTarget {
  final String id;
  final String label;

  /// The folder `session.workspace.move` receives.
  final String cwd;

  const ProjectMoveTarget({
    required this.id,
    required this.label,
    required this.cwd,
  });
}

String _clean(String path) {
  final trimmed = path.trim();
  return trimmed.length > 1 && trimmed.endsWith('/')
      ? trimmed.substring(0, trimmed.length - 1)
      : trimmed;
}

/// Desktop's `projectRootCwd`: the project's own path, else the first
/// repository with one.
String _projectFolder(ProjectNode project) {
  if (project.path.trim().isNotEmpty) return _clean(project.path);
  for (final repo in project.repositories) {
    if (repo.path.trim().isNotEmpty) return _clean(repo.path);
  }
  return '';
}

/// Destinations for a move (Desktop's `MoveToProjectItems`): projects of the
/// tree that are not archived, not "no project", have a folder, and are not
/// the one the session already lives in ([sessionCwd] or [sessionGitRepoRoot]
/// is that folder or something under it).
List<ProjectMoveTarget> projectMoveTargets(
  ProjectTreeSnapshot tree, {
  String? sessionCwd,
  String? sessionGitRepoRoot,
}) {
  return [
    for (final project in tree.projects)
      if (!project.archived && !project.noProject)
        if (_projectFolder(project) case final folder
            when folder.isNotEmpty &&
                !sessionInProjectFolder(
                  folder,
                  cwd: sessionCwd,
                  gitRepoRoot: sessionGitRepoRoot,
                ))
          ProjectMoveTarget(id: project.id, label: project.label, cwd: folder),
  ];
}

/// Whether a session works inside [folder]: its `cwd` or git root is the
/// folder or something under it.
bool sessionInProjectFolder(String folder, {String? cwd, String? gitRepoRoot}) {
  final root = _clean(folder);
  if (root.isEmpty) return false;
  bool inside(String? path) {
    if (path == null || path.trim().isEmpty) return false;
    final value = _clean(path);
    return value == root || value.startsWith('$root/');
  }

  return inside(cwd) || inside(gitRepoRoot);
}
