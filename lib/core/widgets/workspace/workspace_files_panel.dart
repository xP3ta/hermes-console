// The workspace's Files panel without SSH (1.4.3). Hermes Desktop's Files
// pane lists the conversation's folder through the server's own `/api/fs`
// routes (`apps/desktop/src/app/contrib/panes.tsx`, `FilesPane` →
// `RightSidebarPane`), no SSH involved. The app already reads those routes
// for Projects › Files (`ProjectFilesBrowser`, `HermesProjectFilesGateway`);
// the panel is that browser, rooted at the conversation's folder, with its
// viewers. With an SSH profile Files stays the SFTP browser.
import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../screens/projects_center_screen.dart' show projectFailureText;
import '../../services/desktop_control_gateway.dart';
import '../../theme/hermes_tokens.dart';
import '../projects/project_files_browser.dart';
import 'chat_workspace_host.dart' show ChatWorkspacePaneScope;

/// Where the Files panel reads.
enum ChatFilesSource {
  /// The SSH profile's SFTP (also before the profile has been read: what
  /// Files always was).
  sftp,

  /// The server's `/api/fs`, rooted at the conversation's folder.
  server,

  /// No SSH profile and nothing the server can list for this chat.
  none,
}

/// The Files panel's source: SFTP unless the connection is known to have no
/// SSH profile; then the server's folder routes when the gateway has them
/// (or has not said otherwise) and the conversation has a folder.
ChatFilesSource chatFilesSource({
  required bool withoutSsh,
  required HermesProjectFilesGateway? files,
  required String? folder,
}) {
  if (!withoutSsh) return ChatFilesSource.sftp;
  if (files == null ||
      files.projectFilesKnownUnsupported ||
      folder == null ||
      folder.trim().isEmpty) {
    return ChatFilesSource.none;
  }
  return ChatFilesSource.server;
}

/// The conversation's folder on the server, browsed through `/api/fs`.
/// The parent keys it by the folder: another folder is another browser.
class ChatWorkspaceServerFiles extends StatefulWidget {
  const ChatWorkspaceServerFiles({
    required this.files,
    required this.root,
    this.writes,
    this.readOnlyConnection = false,
    super.key,
  });

  final HermesProjectFilesGateway files;
  final HermesProjectFileWritesGateway? writes;

  /// The conversation's folder; the browser never leaves it.
  final String root;

  /// The saved connection is read-only: nothing is written.
  final bool readOnlyConnection;

  @override
  State<ChatWorkspaceServerFiles> createState() =>
      _ChatWorkspaceServerFilesState();
}

class _ChatWorkspaceServerFilesState extends State<ChatWorkspaceServerFiles> {
  late final ProjectFilesController _controller = ProjectFilesController(
    root: widget.root,
    gateway: widget.files,
    writes: widget.writes,
    readOnlyConnection: widget.readOnlyConnection,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    // The browser is a column of its own: the panel scrolls it.
    return ListView(
      key: const ValueKey('chat-files-server'),
      padding: const EdgeInsets.all(HermesSpace.x3),
      children: [
        ProjectFilesBrowser(
          controller: _controller,
          failureText: (error) => projectFailureText(error, strings),
          showListSurface: !ChatWorkspacePaneScope.isInPane(context),
        ),
      ],
    );
  }
}
