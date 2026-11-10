import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../l10n/app_localizations.dart';
import '../../design/modal.dart';
import '../../design/tokens.dart';
import '../../models/project_files.dart';
import '../../services/desktop_control_gateway.dart';
import '../../theme/app_theme.dart';
import '../../utils/chat_file_path_policy.dart';
import '../artifact_viewer/artifact_viewer_screen.dart';
import '../console_loader.dart';
import '../hermes_app_bar.dart';
import '../projects/project_files_browser.dart';
import 'chat_file_loader.dart';

/// The words for a file that could not be shown.
String chatFileErrorText(Strings strings, ChatFileErrorKind kind) =>
    switch (kind) {
      ChatFileErrorKind.notFound => strings.fcoErrNotFound,
      ChatFileErrorKind.forbidden => strings.fcoErrForbidden,
      ChatFileErrorKind.denied => strings.fcoErrDenied,
      ChatFileErrorKind.tooLarge => strings.fcoErrTooLarge,
      ChatFileErrorKind.binary => strings.fcoErrBinary,
      ChatFileErrorKind.timeout => strings.fcoErrTimeout,
      ChatFileErrorKind.unreachable => strings.fcoErrUnreachable,
      ChatFileErrorKind.unsupported => strings.fcoErrUnsupported,
      ChatFileErrorKind.outside => strings.fcoErrOutside,
      ChatFileErrorKind.badPath => strings.fcoErrBadPath,
      ChatFileErrorKind.noBase => strings.fcoErrNoBase,
      ChatFileErrorKind.needsConfirmation => strings.fcoSensitiveTitle,
    };

/// Kinds a second try can change.
bool chatFileErrorRetryable(ChatFileErrorKind kind) => switch (kind) {
  ChatFileErrorKind.notFound ||
  ChatFileErrorKind.forbidden ||
  ChatFileErrorKind.timeout ||
  ChatFileErrorKind.unreachable ||
  ChatFileErrorKind.outside => true,
  _ => false,
};

/// The page a file chip opens: reads the file (with a spinner), asks first
/// when it usually holds secrets, says in plain words why it could not be
/// read (with «Reintentar» and «Copiar ruta», and where it was looked for),
/// lets the user pick one when several files carry the name, and shows it
/// in the artifact viewer: Markdown rendered by the chat's own engine with
/// a switch to the source, code and text with line numbers, images
/// zoomable. Nothing is rendered actively (no HTML, no scripts) and nothing
/// is kept on disk.
class ChatFileViewerScreen extends StatefulWidget {
  const ChatFileViewerScreen({
    super.key,
    required this.name,
    required this.path,
    required this.load,
    this.loadChosen,
    this.line,
    this.endLine,
    this.onOpenFolder,
  });

  /// The name the page shows (`main.dart:42` keeps its line).
  final String name;

  /// The path to copy: the absolute one when it is known.
  final String path;

  /// Reads the file; [confirmed] is true once the user agreed to see a file
  /// that usually holds secrets.
  final Future<ChatFileContent> Function({required bool confirmed}) load;

  /// Reads the file the user picked when several carried the name
  /// ([ChatFileChoiceException]); null when there is no choice to offer.
  final Future<ChatFileContent> Function(
    String path, {
    required bool confirmed,
  })?
  loadChosen;
  final int? line;
  final int? endLine;

  /// Shows the file's folder in the explorer; null when it is not inside one.
  final VoidCallback? onOpenFolder;

  @override
  State<ChatFileViewerScreen> createState() => _ChatFileViewerScreenState();
}

class _ChatFileViewerScreenState extends State<ChatFileViewerScreen> {
  bool _confirmed = false;
  bool _showTried = false;

  /// The file picked among several; read instead of [widget.load] from
  /// then on, and the path «Copiar ruta» copies.
  String? _chosen;
  Future<ChatFileContent>? _future;

  @override
  void initState() {
    super.initState();
    _future = widget.load(confirmed: false);
  }

  void _retry() {
    final chosen = _chosen;
    final loadChosen = widget.loadChosen;
    final next = chosen != null && loadChosen != null
        ? loadChosen(chosen, confirmed: _confirmed)
        : widget.load(confirmed: _confirmed);
    setState(() {
      _future = next;
    });
  }

  void _confirm() {
    _confirmed = true;
    _retry();
  }

  /// The label of [path] in the choice list: relative to the folder of
  /// [folders] that holds it, with that folder under it.
  static (String, String?) _choiceLabel(String path, List<String> folders) {
    String? best;
    for (final folder in folders) {
      if (path.startsWith('$folder/') &&
          (best == null || folder.length > best.length)) {
        best = folder;
      }
    }
    if (best == null) return (path, null);
    return (path.substring(best.length + 1), best);
  }

  Future<void> _choose(ChatFileChoiceException choice) async {
    final strings = Strings.of(context);
    final picked = await showHermesOptions<String>(
      context: context,
      title: strings.cfxChoose,
      surfaceKey: const ValueKey('chat-file-choice-sheet'),
      options: [
        for (final path in choice.paths)
          () {
            final (label, folder) = _choiceLabel(path, choice.tried);
            return HermesOption<String>(
              value: path,
              label: label,
              subtitle: folder,
              icon: Icons.insert_drive_file_rounded,
            );
          }(),
      ],
    );
    if (picked == null || !mounted) return;
    _chosen = picked;
    _retry();
  }

  Future<void> _copyPath() async {
    await Clipboard.setData(ClipboardData(text: _chosen ?? widget.path));
    if (!mounted) return;
    final strings = Strings.of(context);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(strings.chcPathCopied),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    return FutureBuilder<ChatFileContent>(
      future: _future,
      builder: (context, snapshot) {
        final content = snapshot.data;
        if (snapshot.connectionState == ConnectionState.done &&
            content != null) {
          return ArtifactViewerScreen(
            key: ValueKey('chat-file-viewer-${content.path}'),
            name: content.name,
            mimeType: content.mimeType,
            loadBytes: () async => content.bytes,
            sizeBytes: content.byteSize,
            sourcePath: content.path,
            initialLine: widget.line,
            endLine: widget.endLine,
            allowActiveContent: false,
            // What may hold secrets never goes out through the share sheet.
            allowShare: !content.sensitive,
            notice: content.truncated
                ? strings.pf1215PreviewTruncated
                : content.bytes.isEmpty
                ? strings.fcoEmpty
                : null,
            onOpenFolder: widget.onOpenFolder,
          );
        }
        final Widget body;
        if (snapshot.hasError) {
          final error = snapshot.error!;
          final kind = chatFileErrorKindOf(error);
          if (error is ChatFileChoiceException && widget.loadChosen != null) {
            body = _Message(
              key: const ValueKey('chat-file-choice'),
              title: widget.name,
              text: strings.cfxSeveralMatches,
              primaryLabel: strings.cfxChoose,
              onPrimary: () => unawaited(_choose(error)),
              secondaryLabel: strings.fcoCopyPath,
              onSecondary: () => unawaited(_copyPath()),
            );
          } else if (kind == ChatFileErrorKind.needsConfirmation) {
            body = _Message(
              key: const ValueKey('chat-file-confirm'),
              title: strings.fcoSensitiveTitle,
              text: strings.fcoSensitiveBody(widget.name),
              primaryLabel: strings.fcoShow,
              onPrimary: _confirm,
              secondaryLabel: strings.commonCancel,
              onSecondary: () => Navigator.of(context).maybePop(),
            );
          } else {
            // On a miss, the folders it was looked for in, folded.
            final tried =
                error is ChatFileLoadException &&
                    kind == ChatFileErrorKind.notFound
                ? error.tried
                : const <String>[];
            body = _Message(
              key: const ValueKey('chat-file-error'),
              title: widget.name,
              text: chatFileErrorText(strings, kind),
              primaryLabel: chatFileErrorRetryable(kind)
                  ? strings.commonRetry
                  : null,
              onPrimary: _retry,
              secondaryLabel: strings.fcoCopyPath,
              onSecondary: () => unawaited(_copyPath()),
              details: tried,
              detailsLabel: strings.cfxSearchedIn(tried.length),
              detailsOpen: _showTried,
              onToggleDetails: () => setState(() => _showTried = !_showTried),
            );
          }
        } else {
          body = const Center(
            key: ValueKey('chat-file-loading'),
            child: ConsoleLoader.large(),
          );
        }
        return Scaffold(
          appBar: HermesAppBar(
            glass: false,
            title: Text(
              widget.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          body: SafeArea(child: body),
        );
      },
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    super.key,
    required this.title,
    required this.text,
    this.primaryLabel,
    this.onPrimary,
    this.secondaryLabel,
    this.onSecondary,
    this.details = const [],
    this.detailsLabel,
    this.detailsOpen = false,
    this.onToggleDetails,
  });

  final String title;
  final String text;
  final String? primaryLabel;
  final VoidCallback? onPrimary;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  /// Lines shown under the text when [detailsOpen] (the folders tried), in
  /// the code face; nothing when empty.
  final List<String> details;
  final String? detailsLabel;
  final bool detailsOpen;
  final VoidCallback? onToggleDetails;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    const target = Size(48, 48);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: colors.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.textSecondary, fontSize: 14),
            ),
            if (details.isNotEmpty && detailsLabel != null) ...[
              const SizedBox(height: HermesSpace.x2),
              TextButton.icon(
                key: const ValueKey('chat-file-tried-toggle'),
                style: TextButton.styleFrom(minimumSize: target),
                onPressed: onToggleDetails,
                icon: Icon(
                  detailsOpen
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                ),
                label: Text(detailsLabel!),
              ),
              if (detailsOpen)
                Padding(
                  key: const ValueKey('chat-file-tried'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: HermesSpace.x2,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final folder in details)
                        Padding(
                          padding: const EdgeInsets.only(
                            bottom: HermesSpace.x1,
                          ),
                          child: Text(
                            folder,
                            textAlign: TextAlign.center,
                            style: HermesType.caption.copyWith(
                              fontFamily: HermesType.monoFamily,
                              color: colors.textSecondary,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
            const SizedBox(height: 20),
            if (primaryLabel != null)
              FilledButton(
                style: FilledButton.styleFrom(minimumSize: target),
                onPressed: onPrimary,
                child: Text(primaryLabel!),
              ),
            if (secondaryLabel != null)
              TextButton(
                style: TextButton.styleFrom(minimumSize: target),
                onPressed: onSecondary,
                child: Text(secondaryLabel!),
              ),
          ],
        ),
      ),
    );
  }
}

/// A folder a chip names, shown in the project explorer (the read-only list
/// of `/api/fs/list`, which also opens the files in it). [root] is the
/// folder the explorer will not leave; [initialPath] where it starts.
class ChatFolderScreen extends StatefulWidget {
  const ChatFolderScreen({
    super.key,
    required this.files,
    required this.root,
    this.initialPath,
  });

  final HermesProjectFilesGateway files;
  final String root;
  final String? initialPath;

  @override
  State<ChatFolderScreen> createState() => _ChatFolderScreenState();
}

class _ChatFolderScreenState extends State<ChatFolderScreen> {
  late final ProjectFilesController _controller = ProjectFilesController(
    root: widget.root,
    gateway: widget.files,
    readOnlyConnection: true,
    initialPath: widget.initialPath,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// A file of the folder opens like a chip's: asks first when it usually
  /// holds secrets and never renders HTML.
  Future<void> _openEntry(ProjectFsEntry entry) {
    final files = widget.files;
    final roots = [widget.root];
    return Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ChatFileViewerScreen(
          name: entry.name,
          path: entry.path,
          load: ({required confirmed}) => loadChatFile(
            files: files,
            resolution: chatResolveFilePath(entry.path),
            roots: roots,
            askedRelative: false,
            confirmedSensitive: confirmed,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final name = widget.root.split('/').where((s) => s.isNotEmpty).lastOrNull;
    return Scaffold(
      appBar: HermesAppBar(
        glass: false,
        title: Text(name ?? '/', maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: SafeArea(
        child: ProjectFilesBrowser(
          controller: _controller,
          onOpenFile: (entry) => _openEntry(entry),
          failureText: (error) =>
              chatFileErrorText(strings, chatFileErrorKindOf(error)),
        ),
      ),
    );
  }
}
