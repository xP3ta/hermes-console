// Compose's attachments (1.4.3): a photo or a file the user picks goes to
// the server over SFTP on the terminal's own SSH connection, into a folder
// of the user's (`~/.cache/hermes-console/uploads`, mode 700), under a
// cleaned, never reused name; its absolute path is then written into the
// text, shell-quoted, the way a terminal program (an agent's CLI) takes a
// file. Nothing is uploaded until the user picks it; nothing here is
// stored on the phone, and the draft lives in memory only.
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/widgets.dart';

import 'attachment_uploader.dart';

/// The folder under the user's home where Compose uploads go.
const String sshComposeUploadFolder = '.cache/hermes-console/uploads';

/// [value] as one shell word: in single quotes, a quote inside it closed,
/// escaped and reopened (`'\''`), so spaces, `$`, `*` or quotes in a name
/// reach the program as they are.
String sshShellQuote(String value) => "'${value.replaceAll("'", r"'\''")}'";

/// The name a picked file gets on the server: [name]'s last part, only
/// letters, digits, `.`, `_` and `-` (anything else becomes `_`), no
/// leading dot, at most 80 characters, after a stamp ([now], [serial])
/// that keeps two uploads apart.
String sshUploadFileName(
  String name, {
  required DateTime now,
  required int serial,
}) {
  final base = name.split(RegExp(r'[/\\]')).last;
  var clean = base
      .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .replaceFirst(RegExp(r'^[._]+'), '');
  if (clean.length > 80) clean = clean.substring(clean.length - 80);
  if (clean.isEmpty) clean = 'file';
  String two(int value) => value.toString().padLeft(2, '0');
  final stamp =
      '${now.year}${two(now.month)}${two(now.day)}-'
      '${two(now.hour)}${two(now.minute)}${two(now.second)}';
  return '$stamp-$serial-$clean';
}

/// Where a picked file is read from.
typedef SshUploadSource = Stream<List<int>> Function();

/// A file the user picked for Compose.
class SshComposePick {
  const SshComposePick({
    required this.name,
    required this.size,
    required this.open,
    this.image = false,
  });

  /// [bytes] already in memory (an image pasted or sent by the keyboard).
  SshComposePick.bytes(this.name, Uint8List bytes, {this.image = true})
    : size = bytes.length,
      open = (() => Stream<List<int>>.value(bytes));

  final String name;
  final int size;
  final SshUploadSource open;
  final bool image;

  /// The most Compose takes: the chat composer's limits (an image, a file).
  int get limit =>
      image ? AttachmentUploader.maxImageBytes : AttachmentUploader.maxBytes;

  bool get tooLarge => size > limit;
}

enum SshUploadState { uploading, done, failed, cancelled }

/// One attachment of the draft: its upload, then its path in the text.
class SshComposeAttachment extends ChangeNotifier {
  SshComposeAttachment(this.pick);

  final SshComposePick pick;
  SshUploadState state = SshUploadState.uploading;
  int sent = 0;

  /// Where it is on the server, once uploaded.
  String? remotePath;

  /// Why the last upload failed.
  Object? error;

  bool _cancelled = false;
  bool _sent = false;
  int? _remoteSize;
  int? _remoteModifyTime;
  Completer<void>? _cancelSignal;

  Future<void> get _cancelledFuture =>
      (_cancelSignal ??= Completer<void>()).future;

  void _resetCancel() {
    _cancelled = false;
    _cancelSignal = null;
  }

  void _signalCancel() {
    _cancelled = true;
    final signal = _cancelSignal;
    if (signal != null && !signal.isCompleted) signal.complete();
  }

  String get name => pick.name;

  double? get fraction => pick.size > 0 ? sent / pick.size : null;

  /// Its path as written into the text.
  String? get quotedPath {
    final path = remotePath;
    return path == null ? null : sshShellQuote(path);
  }

  void _set(SshUploadState value) {
    state = value;
    notifyListeners();
  }

  void _progress(int bytes) {
    sent = bytes;
    notifyListeners();
  }
}

/// Uploads Compose's attachments over one SFTP session of the terminal's
/// SSH connection.
class SshComposeUploader {
  SshComposeUploader(
    this._open, {
    this.stepTimeout = defaultStepTimeout,
    this.uploadTimeout = defaultUploadTimeout,
    this.cleanupTimeout = defaultCleanupTimeout,
    this.onSessionDone,
  });

  /// Opens SFTP on the terminal's connection; throws when it cannot.
  final Future<SftpClient> Function() _open;
  final Duration stepTimeout;
  final Duration uploadTimeout;
  final Duration cleanupTimeout;
  final Future<void>? Function()? onSessionDone;

  SftpClient? _sftp;
  String? _home;
  String? _folder;
  int _serial = 0;

  /// Bytes written per SFTP request.
  static const int chunk = 64 * 1024;

  /// Per-step SFTP deadline (open, mkdir, stat, chunk write, close).
  static const Duration defaultStepTimeout = Duration(seconds: 20);

  /// Overall deadline for one attachment upload.
  static const Duration defaultUploadTimeout = Duration(seconds: 180);

  /// Short bound for best-effort cleanup (close/remove on abort or close).
  static const Duration defaultCleanupTimeout = Duration(seconds: 3);

  void _dropClient() {
    final existing = _sftp;
    _sftp = null;
    _home = null;
    _folder = null;
    if (existing != null) {
      try {
        existing.close();
      } on Object {
        // Channel already closed or minimal test double.
      }
    }
  }

  /// Races [future] against [stepLimit]/[deadline], [attachment] cancellation,
  /// and session close so no SFTP call can hang Send indefinitely.
  Future<T> _run<T>(
    Future<T> future, {
    SshComposeAttachment? attachment,
    DateTime? deadline,
    Duration? stepLimit,
    bool watchSession = true,
  }) {
    if (attachment != null && attachment._cancelled) {
      unawaited(future.then((_) {}, onError: (_) {}));
      return Future<T>.error(const _Cancelled());
    }
    var limit = stepLimit ?? stepTimeout;
    if (deadline != null) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        unawaited(future.then((_) {}, onError: (_) {}));
        return Future<T>.error(
          TimeoutException('SFTP upload timed out', uploadTimeout),
        );
      }
      if (remaining < limit) limit = remaining;
    }

    final completer = Completer<T>();
    Timer? timer;
    void finishValue(T value) {
      if (completer.isCompleted) return;
      timer?.cancel();
      completer.complete(value);
    }

    void finishError(Object error, [StackTrace? stack]) {
      if (completer.isCompleted) return;
      timer?.cancel();
      completer.completeError(error, stack);
    }

    timer = Timer(limit, () {
      finishError(TimeoutException('SFTP operation timed out', limit));
    });

    future.then(finishValue, onError: finishError);

    if (attachment != null) {
      unawaited(
        attachment._cancelledFuture.then((_) {
          finishError(const _Cancelled());
        }),
      );
    }

    if (watchSession) {
      final done = onSessionDone?.call();
      if (done != null) {
        unawaited(
          done.then(
            (_) => finishError(StateError('SSH session closed')),
            onError: (_) => finishError(StateError('SSH session closed')),
          ),
        );
      }
    }

    return completer.future;
  }

  Future<SftpClient> _client({
    SshComposeAttachment? attachment,
    DateTime? deadline,
    Duration? stepLimit,
    bool watchSession = true,
  }) async {
    final existing = _sftp;
    if (existing != null) return existing;
    final opened = await _run(
      _open(),
      attachment: attachment,
      deadline: deadline,
      stepLimit: stepLimit,
      watchSession: watchSession,
    );
    return _sftp ??= opened;
  }

  /// Verifies every component of [folder] below [home] using `lstat`
  /// (`followLink: false`) so no parent directory is a symbolic link.
  Future<bool> _verifyDirNoSymlink(
    SftpClient sftp,
    String home,
    String folder, {
    SshComposeAttachment? attachment,
    DateTime? deadline,
    Duration? stepLimit,
    bool watchSession = true,
  }) async {
    final prefix = home.endsWith('/') ? home : '$home/';
    if (!folder.startsWith(prefix)) return false;
    final relative = folder.substring(prefix.length);
    if (relative.isEmpty) return false;
    var current = home.endsWith('/') ? home.substring(0, home.length - 1) : home;
    for (final part in relative.split('/')) {
      if (part.isEmpty || part == '.' || part == '..') return false;
      current = '$current/$part';
      final attrs = await _run(
        sftp.stat(current, followLink: false),
        attachment: attachment,
        deadline: deadline,
        stepLimit: stepLimit,
        watchSession: watchSession,
      );
      if (attrs.isSymbolicLink || !attrs.isDirectory) return false;
    }
    return true;
  }

  /// Creates a fresh private fallback upload directory directly under [home]
  /// when any component of the default path is a symlink or non-directory.
  Future<String> _createFallbackFolder(
    SftpClient sftp,
    String home, {
    required SshComposeAttachment attachment,
    required DateTime deadline,
  }) async {
    final base = home.endsWith('/') ? home.substring(0, home.length - 1) : home;
    for (var attempt = 0; ; attempt++) {
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final candidate = '$base/.hermes-console-uploads-$stamp-${++_serial}';
      try {
        await _run(
          sftp.mkdir(
            candidate,
            SftpFileAttrs(mode: const SftpFileMode.value(0x1C0)),
          ),
          attachment: attachment,
          deadline: deadline,
        );
        final attrs = await _run(
          sftp.stat(candidate, followLink: false),
          attachment: attachment,
          deadline: deadline,
        );
        if (attrs.isSymbolicLink || !attrs.isDirectory) {
          throw StateError('Upload folder is not a private directory');
        }
        return candidate;
      } on SftpStatusError {
        if (attempt >= 2) rethrow;
      }
    }
  }

  /// `~/.cache/hermes-console/uploads`, made if missing; the private folders
  /// are mode 700. Never follows symbolic links or calls `setStat` on one.
  Future<String> _uploads(
    SftpClient sftp, {
    required SshComposeAttachment attachment,
    required DateTime deadline,
  }) async {
    final known = _folder;
    final knownHome = _home;
    if (known != null && knownHome != null) {
      try {
        final safe = await _verifyDirNoSymlink(
          sftp,
          knownHome,
          known,
          attachment: attachment,
          deadline: deadline,
        );
        if (safe) return known;
      } on SftpStatusError {
        // Re-create or fall back below.
      }
      _folder = null;
    }
    final String home =
        _home ??
        await _run<String>(
          sftp.absolute('.'),
          attachment: attachment,
          deadline: deadline,
        );
    _home = home;
    var path = home;
    final parts = sshComposeUploadFolder.split('/');
    var needsFallback = false;
    for (var i = 0; i < parts.length; i++) {
      path = '$path/${parts[i]}';
      final private = i > 0;
      try {
        await _run(
          sftp.mkdir(
            path,
            private
                ? SftpFileAttrs(mode: const SftpFileMode.value(0x1C0))
                : null,
          ),
          attachment: attachment,
          deadline: deadline,
        );
      } on SftpStatusError {
        // Already exists: inspect with lstat so symlinks are never followed
        // or passed to setStat.
        final attrs = await _run(
          sftp.stat(path, followLink: false),
          attachment: attachment,
          deadline: deadline,
        );
        if (attrs.isSymbolicLink || !attrs.isDirectory) {
          needsFallback = true;
          break;
        }
        final modeBits = (attrs.mode?.value ?? 0) & 0xFFF;
        if (private && modeBits != 0x1C0) {
          await _run(
            sftp.setStat(
              path,
              SftpFileAttrs(mode: const SftpFileMode.value(0x1C0)),
            ),
            attachment: attachment,
            deadline: deadline,
          );
        }
      }
    }
    if (needsFallback) {
      final fallback = await _createFallbackFolder(
        sftp,
        home,
        attachment: attachment,
        deadline: deadline,
      );
      _folder = fallback;
      return fallback;
    }
    _folder = path;
    return path;
  }

  /// Uploads [attachment], its progress on it as it goes. A failure leaves
  /// it [SshUploadState.failed] (retry with this again); a cancel,
  /// [SshUploadState.cancelled]. A half-written file is removed.
  Future<void> upload(SshComposeAttachment attachment) async {
    attachment
      .._resetCancel()
      ..sent = 0
      ..error = null
      ..remotePath = null
      .._set(SshUploadState.uploading);
    final deadline = DateTime.now().add(uploadTimeout);
    String? target;
    SftpFile? file;
    StreamIterator<List<int>>? reader;
    var maxWritten = 0;
    try {
      final sftp = await _client(attachment: attachment, deadline: deadline);
      final folder = await _uploads(
        sftp,
        attachment: attachment,
        deadline: deadline,
      );
      _checkCancel(attachment);
      final (opened, path) = await _create(
        sftp,
        folder,
        attachment.name,
        attachment: attachment,
        deadline: deadline,
      );
      file = opened;
      target = path;
      var offset = 0;
      reader = StreamIterator<List<int>>(attachment.pick.open());
      while (await _run(
        reader.moveNext(),
        attachment: attachment,
        deadline: deadline,
      )) {
        final bytes = reader.current;
        var start = 0;
        while (start < bytes.length) {
          _checkCancel(attachment);
          final end = math.min(start + chunk, bytes.length);
          maxWritten = offset + (end - start);
          await _run(
            opened.writeBytes(
              Uint8List.fromList(bytes.sublist(start, end)),
              offset: offset,
            ),
            attachment: attachment,
            deadline: deadline,
          );
          offset += end - start;
          start = end;
          attachment._progress(offset);
        }
      }
      _checkCancel(attachment);
      int? remoteSize = offset;
      int? remoteModifyTime;
      try {
        final fstat = await _run(
          opened.stat(),
          attachment: attachment,
          deadline: deadline,
        );
        remoteSize = fstat.size ?? offset;
        remoteModifyTime = fstat.modifyTime;
      } on Object {
        // Minimal server or fake omitted fstat; retain written byte count.
      }
      file = null;
      await _run(opened.close(), attachment: attachment, deadline: deadline);
      attachment
        ..remotePath = target
        .._remoteSize = remoteSize
        .._remoteModifyTime = remoteModifyTime
        .._sent = false
        .._set(SshUploadState.done);
    } catch (error) {
      // The local source's cancellation can wait on its own teardown.
      // Start it here so a stalled source cannot delay closing the SFTP
      // handle or removing the partial file.
      reader?.cancel().ignore();
      if (file != null) {
        try {
          await _run(
            file.close(),
            stepLimit: cleanupTimeout,
            watchSession: false,
          );
        } on Object {
          // The channel is gone; the removal below says it all.
        }
      }
      final partial = target;
      if (partial != null) {
        await _remove(partial, partial: true, maxSize: maxWritten);
      }
      // Drop a failed or timed-out SFTP session so retry opens a fresh one.
      if (error is! _Cancelled) _dropClient();
      attachment
        ..error = error is _Cancelled ? null : error
        .._set(
          error is _Cancelled
              ? SshUploadState.cancelled
              : SshUploadState.failed,
        );
    }
  }

  /// A new file for [name] in [folder]: a new name each time, opened
  /// `exclusive` (refused if it is already there), so nothing on the
  /// server is ever overwritten.
  Future<(SftpFile, String)> _create(
    SftpClient sftp,
    String folder,
    String name, {
    required SshComposeAttachment attachment,
    required DateTime deadline,
  }) async {
    for (var attempt = 0; ; attempt++) {
      final file = sshUploadFileName(
        name,
        now: DateTime.now(),
        serial: ++_serial,
      );
      final path = '$folder/$file';
      try {
        final opened = await _run(
          sftp.open(
            path,
            mode:
                SftpFileOpenMode.create |
                SftpFileOpenMode.write |
                SftpFileOpenMode.exclusive,
          ),
          attachment: attachment,
          deadline: deadline,
        );
        return (opened, path);
      } on SftpStatusError {
        if (attempt >= 2) rethrow;
      }
    }
  }

  void _checkCancel(SshComposeAttachment attachment) {
    if (attachment._cancelled) throw const _Cancelled();
  }

  /// Stops [attachment]'s upload immediately; what was written is removed.
  void cancel(SshComposeAttachment attachment) {
    attachment._signalCancel();
  }

  /// Removes an uploaded file the text no longer names (its chip was
  /// removed before it was sent). Already-sent attachments are never removed.
  Future<void> discard(SshComposeAttachment attachment) async {
    if (attachment._sent) return;
    attachment._signalCancel();
    final path = attachment.remotePath;
    if (path == null) return;
    attachment.remotePath = null;
    await _remove(
      path,
      expectedSize: attachment._remoteSize,
      expectedModifyTime: attachment._remoteModifyTime,
    );
  }

  /// Removes [path] only after verifying via `lstat` that no parent directory
  /// became a symlink and that [path] is still the regular file we uploaded.
  ///
  /// SFTP v3 has no `unlinkat`/`O_NOFOLLOW`, so a narrow TOCTOU window remains
  /// between `lstat` and `remove`.
  Future<void> _remove(
    String path, {
    int? expectedSize,
    int? expectedModifyTime,
    bool partial = false,
    int? maxSize,
  }) async {
    try {
      final sftp = await _client(
        stepLimit: cleanupTimeout,
        watchSession: false,
      );
      final home = _home;
      final slash = path.lastIndexOf('/');
      if (home != null && slash > 0) {
        final parent = path.substring(0, slash);
        final safeParent = await _verifyDirNoSymlink(
          sftp,
          home,
          parent,
          stepLimit: cleanupTimeout,
          watchSession: false,
        );
        if (!safeParent) return;
      }
      final attrs = await _run(
        sftp.stat(path, followLink: false),
        stepLimit: cleanupTimeout,
        watchSession: false,
      );
      if (attrs.isSymbolicLink || !attrs.isFile) return;
      if (expectedSize != null &&
          attrs.size != null &&
          attrs.size != expectedSize) {
        return;
      }
      if (expectedModifyTime != null &&
          attrs.modifyTime != null &&
          attrs.modifyTime != expectedModifyTime) {
        return;
      }
      if (partial &&
          maxSize != null &&
          attrs.size != null &&
          attrs.size! > maxSize) {
        return;
      }
      await _run(
        sftp.remove(path),
        stepLimit: cleanupTimeout,
        watchSession: false,
      );
    } on Object catch (error) {
      // Left in the user's private upload folder.
      debugPrint('[compose] upload not removed (${error.runtimeType})');
    }
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}

/// What is being written in Compose for one connection: the text, its
/// attachments and their uploads. In memory only; it outlives the sheet
/// (closed and opened again, a rotation, a fold) until it is sent or the
/// session is closed.
class SshComposeDraft {
  SshComposeDraft(this.uploader);

  final SshComposeUploader uploader;
  final TextEditingController text = TextEditingController();
  final ValueNotifier<List<SshComposeAttachment>> attachments =
      ValueNotifier<List<SshComposeAttachment>>(const []);

  /// True when the SSH link dropped shortly after Compose queued a write and
  /// delivery to the remote shell cannot be confirmed.
  final ValueNotifier<bool> deliveryUncertain = ValueNotifier<bool>(false);

  /// How long after a queued write a link that drops WITHOUT the server
  /// having answered anything in between still counts as «not known to have
  /// arrived». A link that died silently is only noticed by the keep-alive
  /// (one probe a minute and its timeout), so the window covers that; five
  /// seconds, as it was, almost never did.
  static const Duration defaultUncertainWindow = Duration(seconds: 90);

  String? _lastQueuedText;
  DateTime? _lastQueuedAt;

  /// Records a queued write so a sudden connection drop can restore it and
  /// warn the user without ever resending automatically.
  void markQueuedSend(String sent, {DateTime? at}) {
    if (_disposed) return;
    _lastQueuedText = sent;
    _lastQueuedAt = at ?? DateTime.now();
    deliveryUncertain.value = false;
  }

  /// The server sent something after the write was queued: the link was
  /// alive past it, so the write is not in doubt any more (its echo is the
  /// usual proof). Keeps the long window from flagging writes that arrived.
  void noteRemoteOutput() {
    if (_lastQueuedAt == null) return;
    _lastQueuedText = null;
    _lastQueuedAt = null;
  }

  /// Clears any pending uncertainty notice and queued recovery copy.
  void clearDeliveryUncertain() {
    if (_disposed) return;
    _lastQueuedText = null;
    _lastQueuedAt = null;
    deliveryUncertain.value = false;
  }

  /// Called when the SSH link drops unexpectedly. If a write was queued
  /// within [window], restores the copy into an empty draft and flags
  /// [deliveryUncertain] so the user can check the terminal before resending.
  bool recoverUncertainSend({
    DateTime? now,
    Duration window = defaultUncertainWindow,
  }) {
    if (_disposed) return false;
    final queued = _lastQueuedText;
    final at = _lastQueuedAt;
    if (queued == null || at == null) return false;
    final elapsed = (now ?? DateTime.now()).difference(at);
    _lastQueuedText = null;
    _lastQueuedAt = null;
    if (elapsed > window) return false;
    if (text.text.isEmpty) {
      text.value = TextEditingValue(
        text: queued,
        selection: TextSelection.collapsed(offset: queued.length),
      );
    }
    deliveryUncertain.value = true;
    return true;
  }

  /// Some attachment is still uploading: its path is not in the text yet.
  bool get uploading =>
      attachments.value.any((a) => a.state == SshUploadState.uploading);

  /// Adds [pick] and uploads it; once uploaded, its quoted path goes into
  /// the text where the cursor is. Returns it, its upload ended.
  Future<SshComposeAttachment> attach(SshComposePick pick) async {
    final attachment = SshComposeAttachment(pick);
    attachments.value = [...attachments.value, attachment];
    await _upload(attachment);
    return attachment;
  }

  /// Tries a failed upload again.
  Future<SshComposeAttachment> retry(SshComposeAttachment attachment) async {
    await _upload(attachment);
    return attachment;
  }

  bool _disposed = false;

  Future<void> _upload(SshComposeAttachment attachment) async {
    await uploader.upload(attachment);
    if (attachment.state != SshUploadState.done) return;
    if (_disposed || !attachments.value.contains(attachment)) {
      // Removed while it uploaded.
      await uploader.discard(attachment);
      return;
    }
    _insert(attachment.quotedPath!);
  }

  /// [word] at the cursor (at the end without one), a blank on each side
  /// where the text has none.
  void _insert(String word) {
    final value = text.value;
    final at = value.selection.isValid
        ? value.selection.start
        : value.text.length;
    final before = value.text.substring(0, at);
    final after = value.text.substring(at);
    final lead = before.isEmpty || RegExp(r'\s$').hasMatch(before) ? '' : ' ';
    final trail = after.startsWith(RegExp(r'\s')) ? '' : ' ';
    final inserted = '$lead$word$trail';
    text.value = TextEditingValue(
      text: '$before$inserted$after',
      selection: TextSelection.collapsed(offset: at + inserted.length),
    );
  }

  /// Takes [attachment] out: its upload stops, its path leaves the text,
  /// and the file, never sent, is removed from the server.
  Future<void> remove(SshComposeAttachment attachment) async {
    attachments.value = [
      for (final other in attachments.value)
        if (!identical(other, attachment)) other,
    ];
    final quoted = attachment.quotedPath;
    if (quoted != null) {
      final current = text.text;
      final index = current.indexOf(quoted);
      if (index >= 0) {
        var end = index + quoted.length;
        if (end < current.length && current[end] == ' ') end++;
        text.value = TextEditingValue(
          text: current.replaceRange(index, end, ''),
          selection: TextSelection.collapsed(offset: index),
        );
      }
    }
    if (attachment.state == SshUploadState.uploading) {
      uploader.cancel(attachment);
    } else {
      await uploader.discard(attachment);
    }
  }

  /// Whether any attachment in this draft has not been sent and still needs
  /// cancellation or remote cleanup when the session closes.
  bool get hasUnsentUploads => attachments.value.any(
    (a) =>
        !a._sent &&
        (a.remotePath != null || a.state == SshUploadState.uploading),
  );

  /// Cancels in-flight uploads and removes unsent uploaded files on the server.
  Future<void> cleanupUnsent() async {
    final pending = List<SshComposeAttachment>.from(attachments.value);
    for (final attachment in pending) {
      if (attachment._sent) continue;
      if (attachment.state == SshUploadState.uploading) {
        uploader.cancel(attachment);
      } else if (attachment.remotePath != null) {
        await uploader.discard(attachment);
      }
    }
  }

  /// The text was sent: start a new draft (the uploaded files stay on the
  /// server for the program that was given their paths).
  void clear() {
    for (final attachment in attachments.value) {
      attachment._sent = true;
    }
    text.clear();
    attachments.value = const [];
  }

  void dispose() {
    _disposed = true;
    final pending = List<SshComposeAttachment>.from(attachments.value);
    for (final attachment in pending) {
      if (attachment._sent) continue;
      if (attachment.state == SshUploadState.uploading) {
        uploader.cancel(attachment);
      } else if (attachment.remotePath != null) {
        unawaited(uploader.discard(attachment));
      }
    }
    text.dispose();
    attachments.dispose();
    deliveryUncertain.dispose();
  }
}
