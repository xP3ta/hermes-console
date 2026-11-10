// Navegador SFTP sobre la conexión SSH: listar/navegar, descargar, subir y
// borrar. Respeta el modo solo-lectura de la instancia. App Lock al entrar.
import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../l10n/app_localizations.dart';
import '../../main.dart';
import '../services/connection_manager.dart';
import '../services/save_to_device.dart';
import '../services/sftp_downloads.dart' show sftpSafeFileName;
import '../services/sftp_transfer_service.dart';
import '../services/ssh_manager.dart';
import '../screens/lock_screen.dart';
import '../theme/app_theme.dart';
import '../theme/hermes_tokens.dart'
    show
        HermesIcon,
        HermesRadius,
        HermesSize,
        HermesSpace,
        HermesSurfaces,
        HermesType;
import '../utils/ssh_error.dart';
import '../widgets/chat/back_to_chat_notch.dart';
import '../widgets/hermes_tree_rows.dart';
import '../widgets/hermes_app_bar.dart';
import 'sftp_file_preview_screen.dart';
import '../widgets/hermes_premium_ui.dart' show HermesEmptyState;
import '../widgets/save_to_device_feedback.dart';
import '../widgets/ssh_host_key_dialog.dart';
import '../widgets/ssh_transfer_bar.dart';
import '../widgets/console_loader.dart';
import '../design/hermes_design.dart'
    show
        HermesChrome,
        HermesAction,
        HermesDialogAction,
        HermesDialogActionStyle,
        HermesMenuButton,
        HermesFloatingSurface,
        HermesStickyControls,
        showHermesDialog;
import '../feedback/feedback_policy.dart';
import '../widgets/hermes_notice.dart' show HermesNoticeAction;
import '../widgets/workspace/chat_workspace_host.dart'
    show ChatWorkspaceMenuEntry, ChatWorkspacePaneScope, ChatWorkspaceToolbar;

/// The path in the pane's pill (mock 136 v2-A «proyecto › lib › core»): the
/// last [max] folders, «…» before them when there are more; «/» at the root.
String sftpBreadcrumb(String path, {int max = 3}) {
  final parts = path.split('/').where((part) => part.isNotEmpty).toList();
  if (parts.isEmpty) return '/';
  final shown = parts.length > max
      ? ['…', ...parts.sublist(parts.length - max)]
      : parts;
  return shown.join(' › ');
}

/// Past this size, «Compartir» warns first: the whole file is copied to
/// the phone for a moment.
const int sftpShareWarnBytes = 100 * 1024 * 1024;

/// Past this size, «Compartir» says to download it instead (no temporary
/// copy that big).
const int sftpShareMaxBytes = 2 * 1024 * 1024 * 1024;

class SftpBrowserScreen extends StatefulWidget {
  final SavedConnection connection;

  /// Set when Files was reached from a chat (narrow screens): a notch at
  /// the bottom, as in the in-app browser, returns to that chat.
  final VoidCallback? onBackToChat;

  const SftpBrowserScreen({
    required this.connection,
    this.onBackToChat,
    super.key,
  });

  @override
  State<SftpBrowserScreen> createState() => _SftpBrowserScreenState();
}

class _SftpBrowserScreenState extends State<SftpBrowserScreen> {
  SSHClient? _client;
  SftpClient? _sftp;
  String _path = '/';
  List<SftpName> _entries = const [];

  /// The tree under the current folder: folders opened in place, their
  /// listings, and the full path of every entry shown.
  final Set<String> _expanded = {};
  final Map<String, List<SftpName>> _children = {};
  final Map<SftpName, String> _entryPaths = {};
  bool _loading = true;
  String? _error;

  /// The error came from listing a folder of a live connection (Desktop's
  /// «No legible»): retrying lists the same folder again instead of
  /// reconnecting from the home folder.
  bool _listFailed = false;
  bool _busy = false;

  /// Downloads to share started here: their temporary copies go when this
  /// screen does (a running one stops).
  final List<SftpTransfer> _shares = [];
  SftpTransferService? _shareService;

  bool get _readOnly => _mgr.isReadOnly(widget.connection.id);

  /// In the workspace pane (audit 2.8, as the Terminal): the pane's bar
  /// already names the tab, so there is no header of its own; upload and
  /// reload go to the bar's «⋯».
  bool _inPane = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _inPane = ChatWorkspacePaneScope.isInPane(context);
  }

  /// Never during a build: it rebuilds the pane's bar.
  void _publishPaneToolbar() {
    if (!mounted || !_inPane) return;
    final strings = Strings.of(context);
    ChatWorkspacePaneScope.publish(
      context,
      ChatWorkspaceToolbar(
        menu: [
          if (!_readOnly && _error == null && !_busy)
            ChatWorkspaceMenuEntry(
              key: const ValueKey('sftp-pane-menu-upload'),
              label: strings.sftpUpload,
              icon: Icons.upload_file,
              onSelected: () => unawaited(_upload()),
            ),
          if (!_loading)
            ChatWorkspaceMenuEntry(
              key: const ValueKey('sftp-pane-menu-reload'),
              label: strings.commonReload,
              icon: Icons.refresh,
              onSelected: () => unawaited(_list()),
            ),
        ],
      ),
    );
  }

  SshManager get _mgr =>
      context.findAncestorStateOfType<HermesAppState>()!.sshManager;

  SftpTransferService get _transfers =>
      context.findAncestorStateOfType<HermesAppState>()!.sftpTransfers;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  Future<void> _init() async {
    final lock = context.findAncestorStateOfType<HermesAppState>()!.appLock;
    if (lock.enabled) {
      final ok = await LockScreen.verify(
        context,
        lock,
        reason: Strings.of(context).sftpOpenOf(widget.connection.label),
      );
      if (!ok) {
        if (mounted) Navigator.pop(context);
        return;
      }
    }
    await _connect();
  }

  Future<void> _connect() async {
    setState(() {
      _loading = true;
      _error = null;
      _listFailed = false;
    });
    // A retry must not leave the previous connection open.
    _sftp?.close();
    _client?.close();
    _sftp = null;
    _client = null;
    SSHClient? pending;
    try {
      final client = await _mgr.connect(
        widget.connection.id,
        onHostKey: (p) => showSshHostKeyDialog(context, p),
      );
      pending = client;
      await client.authenticated;
      final sftp = await client.sftp();
      _client = client;
      _sftp = sftp;
      pending = null;
      // Punto de partida: el home del usuario (pwd), o '/' si falla.
      try {
        final pwd = utf8.decode(await client.run('pwd')).trim();
        _path = pwd.isNotEmpty ? pwd : '/';
      } catch (e) {
        debugPrint('[sftp] no se pudo obtener el pwd remoto, se usa "/": $e');
        _path = '/';
      }
      await _list();
    } catch (e) {
      // Connected but no SFTP (or auth failed): close what was opened.
      pending?.close();
      if (mounted) {
        setState(() {
          _error = localizedSshError(Strings.of(context), e);
          _loading = false;
        });
      }
    }
  }

  Future<void> _list() async {
    final sftp = _sftp;
    if (sftp == null) return;
    setState(() => _loading = true);
    try {
      final raw = await sftp.listdir(_path);
      final items = _sortedNames(raw);
      if (!mounted) return;
      setState(() {
        _expanded.clear();
        _children.clear();
        _entryPaths.clear();
        _entries = items;
        _loading = false;
        _error = null;
        _listFailed = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        // Permission denied / no such file are named (SshFailure), not
        // reported as a connection error.
        _error = Strings.of(
          context,
        ).sftpUnreadableBody(localizedSshError(Strings.of(context), e));
        _listFailed = true;
        _loading = false;
      });
    }
  }

  /// «Intentar de nuevo»: the same folder when the connection is up,
  /// otherwise a new connection.
  void _retry() {
    if (_listFailed && _sftp != null) {
      _list();
    } else {
      _connect();
    }
  }

  String _join(String base, String name) =>
      base == '/' ? '/$name' : '$base/$name';

  /// Folders first, then by name (the order of the tree at every level).
  List<SftpName> _sortedNames(Iterable<SftpName> raw) =>
      raw.where((e) => e.filename != '.' && e.filename != '..').toList()..sort(
        (a, b) => compareFileTreeNames(
          aIsDirectory: a.attr.isDirectory,
          aName: a.filename,
          bIsDirectory: b.attr.isDirectory,
          bName: b.filename,
        ),
      );

  /// Full remote path of an entry, wherever it sits in the tree.
  String _pathOf(SftpName e) => _entryPaths[e] ?? _join(_path, e.filename);

  /// The rows on screen: the folder's entries and, under each folder opened
  /// in place, its own.
  List<FileTreeRow<SftpName>> _treeRows() {
    final rows = flattenFileTree<SftpName>(
      roots: _entries,
      rootPath: _path,
      isDirectory: (e) => e.attr.isDirectory,
      nameOf: (e) => e.filename,
      expanded: _expanded,
      children: _children,
      join: _join,
    );
    for (final row in rows) {
      _entryPaths[row.entry] = row.path;
    }
    return rows;
  }

  /// Opens or closes a folder in place, listing it the first time.
  Future<void> _toggle(FileTreeRow<SftpName> row) async {
    final path = row.path;
    if (_expanded.contains(path)) {
      setState(() => _expanded.remove(path));
      return;
    }
    if (_children.containsKey(path)) {
      setState(() => _expanded.add(path));
      return;
    }
    final sftp = _sftp;
    if (sftp == null) return;
    try {
      final items = _sortedNames(await sftp.listdir(path));
      if (!mounted) return;
      setState(() {
        _children[path] = items;
        _expanded.add(path);
      });
    } catch (e) {
      if (!mounted) return;
      _snack(
        Strings.of(
          context,
        ).sftpUnreadableBody(localizedSshError(Strings.of(context), e)),
      );
    }
  }

  String _parent(String path) {
    if (path == '/' || !path.contains('/')) return '/';
    final trimmed = path.endsWith('/')
        ? path.substring(0, path.length - 1)
        : path;
    final idx = trimmed.lastIndexOf('/');
    return idx <= 0 ? '/' : trimmed.substring(0, idx);
  }

  void _enter(SftpName e) {
    if (!e.attr.isDirectory) return;
    setState(() => _path = _pathOf(e));
    _list();
  }

  /// Reads [path] over this screen's SFTP session: the first [maxBytes], or
  /// all of it when null.
  Future<Uint8List> _readFile(String path, int? maxBytes) async {
    final sftp = _sftp;
    if (sftp == null) throw StateError('sftp closed');
    final file = await sftp.open(path);
    try {
      return await file.readBytes(length: maxBytes);
    } finally {
      await file.close();
    }
  }

  /// Desktop: a file opens its preview; Back returns to the list.
  void _preview(SftpName e) {
    final path = _pathOf(e);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SftpFilePreviewScreen(
          name: e.filename,
          size: e.attr.size,
          read: (max) => _readFile(path, max),
          onDownload: () => unawaited(_download(e)),
          onBackToChat: widget.onBackToChat,
        ),
      ),
    );
  }

  void _goUp() {
    setState(() => _path = _parent(_path));
    _list();
  }

  void _snack(String m, [FeedbackKind kind = FeedbackKind.error]) {
    if (mounted) AppFeedback.notify(context, kind, m);
  }

  /// «Descargar»: Android's «Guardar como» asks where, then the file is
  /// written straight there, in the background (it outlives this screen
  /// and the app going away), with no copy in the app. Closing the dialog
  /// does nothing. The end is said with «Ver» (Abrir, Compartir, Guardar
  /// otra copia…) or, if it failed, with the reason and «Reintentar». Also
  /// from the preview and the Files panel, which use this screen.
  Future<void> _download(SftpName e) async {
    saveLog('tap source=sftp action=download');
    final strings = Strings.of(context);
    final notice = AppFeedback.of(context);
    final transfers = _transfers;
    final String? document;
    try {
      document = await transfers.device.pick(e.filename);
    } on SaveFailure catch (failure) {
      notifySaveFailure(
        notice,
        strings,
        failure,
        retry: () {
          if (mounted) unawaited(_download(e));
        },
      );
      return;
    }
    if (document == null || !mounted) return;
    _snack(strings.sftpDownloading(e.filename), FeedbackKind.routine);
    final t = await transfers.download(
      connectionId: widget.connection.id,
      remotePath: _pathOf(e),
      fileName: e.filename,
      totalBytes: e.attr.size ?? 0,
      document: document,
    );
    if (mounted) _announce(t, transfers);
  }

  /// The end of a download, said while this screen is there (over a
  /// preview too); once it is gone, the notification says it.
  void _announce(SftpTransfer t, SftpTransferService transfers) {
    final strings = Strings.of(context);
    final saved = t.saved;
    if (t.status == TransferStatus.done && saved != null) {
      notifySaved(context, saved, device: transfers.device);
      return;
    }
    if (t.status == TransferStatus.done) return;
    // Cancelled by the user: nothing to say.
    if (t.problem == SaveProblem.cancelled) return;
    AppFeedback.of(context).notify(
      FeedbackKind.critical,
      t.error ?? saveProblemMessage(strings, t.problem ?? SaveProblem.failed),
      warning: true,
      action: HermesNoticeAction(
        label: strings.commonRetry,
        onPressed: () {
          if (mounted) unawaited(_retryDownload(t, transfers));
        },
      ),
    );
  }

  /// «Reintentar»: a download to share starts again; one to a document
  /// asks where again (the failed document was deleted).
  Future<void> _retryDownload(
    SftpTransfer failed,
    SftpTransferService transfers,
  ) async {
    saveLog('tap source=sftp action=retry');
    if (failed.forShare) {
      transfers.transfers.value = List.unmodifiable(
        transfers.transfers.value.where((t) => !identical(t, failed)),
      );
      await _shareRemote(
        remotePath: failed.remotePath,
        name: failed.name,
        size: failed.totalBytes,
      );
      return;
    }
    final strings = Strings.of(context);
    final notice = AppFeedback.of(context);
    final String? document;
    try {
      document = await transfers.device.pick(failed.name);
    } on SaveFailure catch (failure) {
      notifySaveFailure(
        notice,
        strings,
        failure,
        retry: () {
          if (mounted) unawaited(_retryDownload(failed, transfers));
        },
      );
      return;
    }
    if (document == null) return;
    final t = await transfers.retry(failed, document: document);
    if (mounted) _announce(t, transfers);
  }

  /// «Compartir» a server file without saving it: it is downloaded to a
  /// temporary copy in the app's cache, shared, and deleted on leaving this
  /// screen (and at start, and before the next share). A very large file
  /// asks first; past [sftpShareMaxBytes] it is refused.
  Future<void> _share(SftpName e) => _shareRemote(
    remotePath: _pathOf(e),
    name: e.filename,
    size: e.attr.size ?? 0,
  );

  Future<void> _shareRemote({
    required String remotePath,
    required String name,
    required int size,
  }) async {
    saveLog('tap source=sftp action=share bytes=$size');
    final strings = Strings.of(context);
    final notice = AppFeedback.of(context);
    if (size > sftpShareMaxBytes) {
      notice.notify(
        FeedbackKind.error,
        strings.sftpShareTooLarge(name, _fmtSize(size)),
        warning: true,
      );
      return;
    }
    if (size > sftpShareWarnBytes) {
      final go = await showHermesDialog<bool>(
        context: context,
        title: strings.sftpShareLargeTitle,
        message: strings.sftpShareLargeBody(name, _fmtSize(size)),
        actions: [
          HermesDialogAction(
            label: strings.commonCancel,
            value: false,
            style: HermesDialogActionStyle.cancel,
          ),
          HermesDialogAction(label: strings.commonShare, value: true),
        ],
      );
      if (go != true || !mounted) return;
    }
    final transfers = _shareService = _transfers;
    // Only the copy being made now stays in the cache.
    await transfers.clearShareCopies();
    if (!mounted) return;
    _snack(strings.sftpSharePreparing(name), FeedbackKind.routine);
    final pending = transfers.downloadToShare(
      connectionId: widget.connection.id,
      remotePath: remotePath,
      fileName: name,
      totalBytes: size,
    );
    final running = transfers.transfers.value.lastOrNull;
    if (running != null && running.forShare) _shares.add(running);
    final t = await pending;
    final path = t.localPath;
    if (!mounted) return;
    if (t.status != TransferStatus.done || path == null) {
      _announce(t, transfers);
      return;
    }
    try {
      await Share.shareXFiles([XFile(path, name: sftpSafeFileName(name))]);
      saveLog('result method=shareXFiles ok=true bytes=${t.doneBytes}');
    } on PlatformException catch (error) {
      saveLog(
        'error method=shareXFiles type=PlatformException code=${error.code}',
      );
      if (mounted) {
        notice.notify(
          FeedbackKind.error,
          saveProblemMessage(strings, SaveProblem.unsupported),
          warning: true,
        );
      }
    } on MissingPluginException {
      saveLog('error method=shareXFiles type=MissingPluginException');
      if (mounted) {
        notice.notify(
          FeedbackKind.error,
          saveProblemMessage(strings, SaveProblem.unavailable),
          warning: true,
        );
      }
    }
  }

  Future<void> _upload() async {
    final s = Strings.of(context);
    if (_readOnly) return;
    final res = await FilePicker.platform.pickFiles(withData: false);
    if (res == null || res.files.isEmpty) return;
    final picked = res.files.first;
    final localPath = picked.path;
    if (localPath == null || localPath.isEmpty) {
      _snack(s.sftpReadError);
      return;
    }
    final t = await _transfers.upload(
      connectionId: widget.connection.id,
      remotePath: _join(_path, picked.name),
      fileName: picked.name,
      localPath: localPath,
      totalBytes: picked.size,
    );
    // Si seguimos en la pantalla y la subida acabó bien, refresca el listado.
    if (mounted && t.status == TransferStatus.done) _list();
  }

  Future<void> _delete(SftpName e) async {
    final s = Strings.of(context);
    final sftp = _sftp;
    if (sftp == null || _readOnly || e.attr.isDirectory) return;
    final ok = await showHermesDialog<bool>(
      context: context,
      title: Strings.of(context).sftpDeleteTitle,
      message: Strings.of(context).sftpDeleteBody(e.filename),
      actions: [
        HermesDialogAction(
          label: Strings.of(context).commonCancel,
          value: false,
          style: HermesDialogActionStyle.cancel,
        ),
        HermesDialogAction(
          label: Strings.of(context).commonDelete,
          value: true,
          style: HermesDialogActionStyle.destructive,
        ),
      ],
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await sftp.remove(_pathOf(e));
      _snack(s.sftpDeleted(e.filename), FeedbackKind.routine);
      await _list();
    } catch (err) {
      _snack(s.sftpDeleteError(localizedSshError(s, err)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    // A share that has nobody to share with any more stops, and its
    // temporary copies go.
    final shares = _shareService;
    if (shares != null) {
      for (final t in _shares) {
        shares.cancel(t);
      }
      unawaited(shares.clearShareCopies());
    }
    _sftp?.close();
    _client?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    if (_inPane) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _publishPaneToolbar(),
      );
    }
    return Scaffold(
      // In the pane the pane's own surface shows (audit T1).
      backgroundColor: ChatWorkspacePaneScope.backgroundOf(
        context,
        colors.background,
      ),
      appBar: _inPane
          ? null
          : HermesAppBar(
              centerTitle: false,
              title: Text(Strings.of(context).sftpFilesTitle),
              actions: [
                // Uploading starts from up here, not from a button over the
                // list.
                if (!_readOnly && _error == null)
                  IconButton(
                    key: const ValueKey('sftp-upload'),
                    tooltip: Strings.of(context).sftpUpload,
                    icon: const Icon(Icons.upload_file),
                    onPressed: _busy ? null : _upload,
                  ),
                IconButton(
                  tooltip: Strings.of(context).commonReload,
                  icon: const Icon(Icons.refresh),
                  onPressed: _loading ? null : _list,
                ),
              ],
            ),
      // In the pane, mock 136 v2-A (Cadu): the files in a card, the path in
      // a pill at the foot. Full screen, the path floats over the list.
      body: _inPane ? _paneBody(colors) : _screenBody(colors),
    );
  }

  /// Full screen (SSH › Archivos): the path floats in place and the files
  /// scroll under it and under the header. The column is laid out upwards
  /// so the list is painted first: the progress line, when it shows, stays
  /// on top of the rows that pass behind it. The transfers sit at the foot,
  /// under the list (audit 2.8: laid out after the list they ended up above
  /// it).
  Widget _screenBody(HermesThemeColors colors) {
    return Column(
      verticalDirection: VerticalDirection.up,
      children: [
        if (widget.onBackToChat != null)
          SafeArea(
            top: false,
            child: BackToChatNotch(
              notchKey: const ValueKey('sftp-notch'),
              label: Strings.of(context).brwBackToChat,
              onTap: widget.onBackToChat!,
            ),
          ),
        _transferBar(),
        Expanded(
          child: HermesStickyControls(
            controls: _pathBar(colors),
            child: _list_(colors),
          ),
        ),
        if (_busy) const LinearProgressIndicator(minHeight: 2),
      ],
    );
  }

  Widget _transferBar() => SshTransferBar(
    service: _transfers,
    onShowDownload: (t) => unawaited(
      showSavedDocumentActions(context, t.saved!, device: _transfers.device),
    ),
    onRetry: (t) => unawaited(_retryDownload(t, _transfers)),
  );

  /// In the pane, mock 136 v2-A (Cadu's look): the files in a rounded card
  /// with its own margin, each row with its icon in a small box; under it
  /// the transfers' pill when there are any, and at the foot the path in a
  /// pill with «Subir nivel» beside it.
  Widget _paneBody(HermesThemeColors colors) {
    final chrome = HermesChrome.of(colors);
    final radius = BorderRadius.circular(HermesRadius.card);
    return Column(
      children: [
        if (_busy) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              HermesSpace.inset,
              HermesSpace.x1,
              HermesSpace.inset,
              HermesSpace.x2,
            ),
            child: DecoratedBox(
              key: const ValueKey('sftp-pane-card'),
              position: DecorationPosition.foreground,
              decoration: BoxDecoration(
                borderRadius: radius,
                border: Border.all(color: chrome.line),
              ),
              child: ClipRRect(
                borderRadius: radius,
                child: ColoredBox(
                  color: HermesSurfaces.group(colors),
                  child: _list_(colors, pane: true),
                ),
              ),
            ),
          ),
        ),
        _transferBar(),
        _pathPill(colors),
      ],
    );
  }

  /// v2-A `.pillbar`: the folder as a breadcrumb (the whole path for a
  /// screen reader) and «Subir nivel», each a 48 dp pill of the chrome.
  Widget _pathPill(HermesThemeColors colors) {
    final strings = Strings.of(context);
    final chrome = HermesChrome.of(colors);
    final atRoot = _path == '/';
    final label = HermesType.value.copyWith(color: chrome.mutedInk);
    return Padding(
      key: const ValueKey('sftp-pane-path'),
      padding: const EdgeInsets.fromLTRB(
        HermesSpace.inset,
        0,
        HermesSpace.inset,
        HermesSpace.inset,
      ),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              // The padlock is drawn, not read: say it (REVIEW-T2-D P3-5).
              label: [_path, if (_readOnly) strings.statusReadOnly].join(', '),
              excludeSemantics: true,
              child: _pill(
                chrome,
                child: Row(
                  children: [
                    Icon(
                      Icons.folder_outlined,
                      size: HermesIcon.sm,
                      color: chrome.mutedInk,
                    ),
                    const SizedBox(width: HermesSpace.x2),
                    Expanded(
                      child: Text(
                        sftpBreadcrumb(_path),
                        key: const ValueKey('sftp-pane-breadcrumb'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: label.copyWith(fontWeight: FontWeight.w500),
                      ),
                    ),
                    if (_readOnly)
                      Padding(
                        padding: const EdgeInsets.only(left: HermesSpace.x2),
                        child: Icon(
                          Icons.lock_outline,
                          size: HermesIcon.sm,
                          color: colors.warning,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: HermesSpace.x2),
          _pill(
            chrome,
            key: const ValueKey('sftp-pane-up'),
            onTap: atRoot ? null : _goUp,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.arrow_upward,
                  size: HermesIcon.sm,
                  color: atRoot ? colors.textDisabled : chrome.ink,
                ),
                const SizedBox(width: HermesSpace.x1),
                Text(
                  strings.sftpUpLevel,
                  style: HermesType.value.copyWith(
                    fontWeight: FontWeight.w600,
                    color: atRoot ? colors.textDisabled : chrome.ink,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// A 48 dp pill of the floating chrome; tappable when [onTap] is given.
  Widget _pill(
    HermesChrome chrome, {
    Key? key,
    VoidCallback? onTap,
    required Widget child,
  }) => Material(
    key: key,
    color: chrome.opaque,
    shape: StadiumBorder(side: BorderSide(color: chrome.line)),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: HermesSize.tap),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: HermesSpace.x4),
          child: Align(widthFactor: 1, child: child),
        ),
      ),
    ),
  );

  Widget _pathBar(HermesThemeColors colors) {
    return HermesFloatingSurface(
      key: const ValueKey('sftp-path'),
      padding: const EdgeInsets.fromLTRB(4, 0, 16, 0),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_upward, size: 18),
            tooltip: Strings.of(context).sftpUpLevel,
            onPressed: _path == '/' ? null : _goUp,
            visualDensity: VisualDensity.compact,
          ),
          Expanded(
            child: Text(
              _path,
              style: TextStyle(
                fontSize: 12.5,
                fontFamily: 'monospace',
                color: HermesChrome.of(colors).mutedInk,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (_readOnly)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Icon(Icons.lock_outline, size: 15, color: colors.warning),
            ),
        ],
      ),
    );
  }

  /// The listing and its states. [pane]: inside the pane's card, with no
  /// room left for a floating path bar over it.
  Widget _list_(HermesThemeColors colors, {bool pane = false}) {
    final top = pane ? 0.0 : HermesStickyControls.extent;
    if (_loading) {
      return const Center(child: ConsoleLoader.large());
    }
    if (_error != null && _listFailed) {
      // Desktop's files tree: «No legible» + the reason + «Intentar de
      // nuevo». The path bar stays, so the user can also go up a level.
      return Center(
        child: SingleChildScrollView(
          padding: EdgeInsets.only(top: top),
          child: HermesEmptyState(
            key: const ValueKey('sftp-unreadable'),
            icon: Icons.folder_off_outlined,
            title: Strings.of(context).sftpUnreadableTitle,
            body: _error!,
            primaryLabel: Strings.of(context).sftpTryAgain,
            primaryIcon: Icons.refresh,
            onPrimary: _retry,
          ),
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 40, color: colors.error),
              const SizedBox(height: 14),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: colors.textSecondary),
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                key: const ValueKey('sftp-retry'),
                onPressed: _retry,
                icon: const Icon(Icons.refresh, size: 16),
                label: Text(Strings.of(context).commonRetry),
              ),
            ],
          ),
        ),
      );
    }
    if (_entries.isEmpty) {
      // Desktop: «Vacío» + «Esta carpeta está vacía.»
      return Center(
        child: SingleChildScrollView(
          padding: EdgeInsets.only(top: top),
          child: HermesEmptyState(
            key: const ValueKey('sftp-empty'),
            icon: Icons.folder_open_outlined,
            title: Strings.of(context).sftpEmptyTitle,
            body: Strings.of(context).sftpEmptyBody,
            compact: true,
          ),
        ),
      );
    }
    final rows = _treeRows();
    if (pane) {
      return ListView.builder(
        key: const ValueKey('sftp-pane-list'),
        padding: const EdgeInsets.all(HermesSpace.x1 + 2),
        itemCount: rows.length,
        itemBuilder: (_, i) => _paneRow(colors, rows[i]),
      );
    }
    return ListView.builder(
      clipBehavior: hermesUnderHeader,
      padding: EdgeInsets.only(top: top),
      itemCount: rows.length,
      itemBuilder: (_, i) {
        final row = rows[i];
        final e = row.entry;
        final isDir = e.attr.isDirectory;
        return HermesTreeGuide(
          depth: row.depth,
          leading: 16,
          child: ListTile(
            contentPadding: EdgeInsetsDirectional.only(
              start: 16 + row.depth * hermesTreeIndent,
              end: 16,
            ),
            dense: true,
            leading: Icon(
              isDir ? Icons.folder_outlined : Icons.insert_drive_file_outlined,
              color: isDir ? colors.secondary : colors.textSecondary,
              size: 20,
            ),
            title: Text(
              e.filename,
              style: TextStyle(fontSize: 14, color: colors.textPrimary),
            ),
            subtitle: isDir
                ? null
                : Text(
                    _fmtSize(e.attr.size),
                    style: TextStyle(
                      fontSize: 11.5,
                      color: colors.textTertiary,
                    ),
                  ),
            onTap: isDir ? () => _enter(e) : () => _preview(e),
            trailing: isDir
                ? HermesTreeToggle(
                    key: ValueKey('sftp-toggle-${e.filename}'),
                    expanded: row.expanded,
                    onTap: () => unawaited(_toggle(row)),
                  )
                : _fileMenu(colors, e),
          ),
        );
      },
    );
  }

  /// A file's «⋮»: download, share and (writable) delete.
  Widget _fileMenu(HermesThemeColors colors, SftpName e) =>
      HermesMenuButton<String>(
        icon: Icon(
          Icons.more_vert,
          size: HermesIcon.md,
          color: colors.textSecondary,
        ),
        onSelected: (v) {
          if (v == 'download') unawaited(_download(e));
          if (v == 'share') unawaited(_share(e));
          if (v == 'delete') _delete(e);
        },
        actions: (context) => [
          HermesAction(
            value: 'download',
            label: Strings.of(context).commonDownload,
          ),
          HermesAction(value: 'share', label: Strings.of(context).commonShare),
          if (!_readOnly)
            HermesAction(
              value: 'delete',
              label: Strings.of(context).commonDelete,
              destructive: true,
            ),
        ],
      );

  /// A row of the pane's card (v2-A `.frow`): the icon in a 32 dp box, the
  /// name in 13/600, the size under it; 48 dp to touch, radius 16.
  Widget _paneRow(HermesThemeColors colors, FileTreeRow<SftpName> row) {
    final e = row.entry;
    final isDir = e.attr.isDirectory;
    final chrome = HermesChrome.of(colors);
    return HermesTreeGuide(
      depth: row.depth,
      leading: HermesSpace.x2 + 2,
      child: Padding(
        padding: EdgeInsetsDirectional.only(
          bottom: 2,
          start: row.depth * hermesTreeIndent,
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            key: ValueKey('sftp-row-${e.filename}'),
            borderRadius: BorderRadius.circular(HermesRadius.row),
            onTap: isDir ? () => _enter(e) : () => _preview(e),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: HermesSize.tap),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: HermesSpace.x2 + 2,
                  vertical: HermesSpace.x2,
                ),
                child: Row(
                  children: [
                    Container(
                      key: ValueKey('sftp-row-icon-${e.filename}'),
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: chrome.opaque,
                        borderRadius: BorderRadius.circular(
                          HermesRadius.control,
                        ),
                      ),
                      child: Icon(
                        isDir
                            ? Icons.folder_outlined
                            : Icons.insert_drive_file_outlined,
                        size: HermesIcon.sm,
                        color: isDir ? colors.secondary : colors.textSecondary,
                      ),
                    ),
                    const SizedBox(width: HermesSpace.gap),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            e.filename,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: HermesType.value.copyWith(
                              fontWeight: FontWeight.w600,
                              color: colors.textPrimary,
                            ),
                          ),
                          if (!isDir)
                            Text(
                              _fmtSize(e.attr.size),
                              style: HermesType.support.copyWith(
                                color: colors.textTertiary,
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (isDir)
                      HermesTreeToggle(
                        key: ValueKey('sftp-toggle-${e.filename}'),
                        expanded: row.expanded,
                        onTap: () => unawaited(_toggle(row)),
                      )
                    else
                      _fileMenu(colors, e),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _fmtSize(int? bytes) {
    if (bytes == null) return '';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
