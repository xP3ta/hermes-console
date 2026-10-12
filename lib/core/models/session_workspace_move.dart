/// Result of `session.workspace.move`: where the stored session now lives.
final class SessionWorkspaceMoveResult {
  final String cwd;
  final String? branch;
  final String? gitRepoRoot;

  const SessionWorkspaceMoveResult({
    required this.cwd,
    this.branch,
    this.gitRepoRoot,
  });

  /// Null when the gateway answered without a folder. A JSON `null` branch or
  /// git root is absent.
  static SessionWorkspaceMoveResult? tryParse(Map<String, dynamic> json) {
    final cwd = json['cwd'];
    if (cwd is! String || cwd.trim().isEmpty) return null;
    String? text(Object? value) =>
        value is String && value.trim().isNotEmpty ? value : null;
    return SessionWorkspaceMoveResult(
      cwd: cwd,
      branch: text(json['branch']),
      gitRepoRoot: text(json['git_repo_root']),
    );
  }
}
