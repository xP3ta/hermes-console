// Navegador SFTP sobre la conexión SSH: listar/navegar, descargar, subir y
// borrar. Respeta el modo solo-lectura de la instancia. App Lock al entrar.
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../main.dart';
import '../services/connection_manager.dart';
import '../services/sftp_transfer_service.dart';
import '../services/ssh_manager.dart';
import '../screens/lock_screen.dart';
import '../theme/app_theme.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/ssh_host_key_dialog.dart';
import '../widgets/ssh_transfer_bar.dart';

class SftpBrowserScreen extends StatefulWidget {
  final SavedConnection connection;
  const SftpBrowserScreen({required this.connection, super.key});

  @override
  State<SftpBrowserScreen> createState() => _SftpBrowserScreenState();
}

class _SftpBrowserScreenState extends State<SftpBrowserScreen> {
  SSHClient? _client;
  SftpClient? _sftp;
  String _path = '/';
  List<SftpName> _entries = const [];
  bool _loading = true;
  String? _error;
  bool _busy = false;

  bool get _readOnly => _mgr.isReadOnly(widget.connection.id);

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
    });
    try {
      final client = await _mgr.connect(
        widget.connection.id,
        onHostKey: (p) => showSshHostKeyDialog(context, p),
      );
      await client.authenticated;
      final sftp = await client.sftp();
      _client = client;
      _sftp = sftp;
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
      if (mounted) {
        setState(() {
          _error = SshManager.describeError(e);
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
      final items =
          raw.where((e) => e.filename != '.' && e.filename != '..').toList()
            ..sort((a, b) {
              final ad = a.attr.isDirectory ? 0 : 1;
              final bd = b.attr.isDirectory ? 0 : 1;
              if (ad != bd) return ad - bd;
              return a.filename.toLowerCase().compareTo(
                b.filename.toLowerCase(),
              );
            });
      if (!mounted) return;
      setState(() {
        _entries = items;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = Strings.of(
          context,
        ).sftpListError(_path, SshManager.describeError(e));
        _loading = false;
      });
    }
  }

  String _join(String base, String name) =>
      base == '/' ? '/$name' : '$base/$name';

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
    setState(() => _path = _join(_path, e.filename));
    _list();
  }

  void _goUp() {
    setState(() => _path = _parent(_path));
    _list();
  }

  void _snack(String m) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
    }
  }

  /// Descarga en segundo plano (sobrevive a salir de la pantalla/app). La hace
  /// el servicio con su propio cliente; aquí solo la lanzamos.
  void _download(SftpName e) {
    _transfers.download(
      connectionId: widget.connection.id,
      remotePath: _join(_path, e.filename),
      fileName: e.filename,
      totalBytes: e.attr.size ?? 0,
    );
    _snack(Strings.of(context).sftpDownloading(e.filename));
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
    final colors = Theme.of(context).hermes;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(Strings.of(context).sftpDeleteTitle),
        content: Text(Strings.of(context).sftpDeleteBody(e.filename)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(Strings.of(context).commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: colors.error),
            child: Text(
              Strings.of(context).commonDelete,
              style: TextStyle(color: colors.onAccent),
            ),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await sftp.remove(_join(_path, e.filename));
      _snack(s.sftpDeleted(e.filename));
      await _list();
    } catch (err) {
      _snack(s.sftpDeleteError(SshManager.describeError(err)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _sftp?.close();
    _client?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Scaffold(
      backgroundColor: colors.background,
      appBar: HermesAppBar(
        centerTitle: false,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(Strings.of(context).sftpFilesTitle),
            Text(
              widget.connection.label,
              style: TextStyle(fontSize: 10.5, color: colors.textSecondary),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: Strings.of(context).commonReload,
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _list,
          ),
        ],
      ),
      floatingActionButton: (_readOnly || _error != null)
          ? null
          : FloatingActionButton(
              tooltip: Strings.of(context).sftpUpload,
              onPressed: _busy ? null : _upload,
              child: const Icon(Icons.upload_file),
            ),
      body: Column(
        children: [
          _pathBar(colors),
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          SshTransferBar(service: _transfers),
          Expanded(child: _list_(colors)),
        ],
      ),
    );
  }

  Widget _pathBar(HermesThemeColors colors) {
    return Container(
      width: double.infinity,
      color: colors.surface,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
                color: colors.textSecondary,
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

  Widget _list_(HermesThemeColors colors) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
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
                onPressed: _connect,
                icon: const Icon(Icons.refresh, size: 16),
                label: Text(Strings.of(context).commonRetry),
              ),
            ],
          ),
        ),
      );
    }
    if (_entries.isEmpty) {
      return Center(
        child: Text(
          Strings.of(context).sftpEmpty,
          style: TextStyle(fontSize: 13, color: colors.textDisabled),
        ),
      );
    }
    return ListView.builder(
      itemCount: _entries.length,
      itemBuilder: (_, i) {
        final e = _entries[i];
        final isDir = e.attr.isDirectory;
        return ListTile(
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
                  style: TextStyle(fontSize: 11.5, color: colors.textDisabled),
                ),
          onTap: isDir ? () => _enter(e) : null,
          trailing: isDir
              ? Icon(Icons.chevron_right, size: 18, color: colors.textDisabled)
              : PopupMenuButton<String>(
                  icon: Icon(
                    Icons.more_vert,
                    size: 18,
                    color: colors.textSecondary,
                  ),
                  onSelected: (v) {
                    if (v == 'download') _download(e);
                    if (v == 'delete') _delete(e);
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'download',
                      child: Text(Strings.of(context).commonDownload),
                    ),
                    if (!_readOnly)
                      PopupMenuItem(
                        value: 'delete',
                        child: Text(Strings.of(context).commonDelete),
                      ),
                  ],
                ),
        );
      },
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
